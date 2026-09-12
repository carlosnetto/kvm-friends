# HELMCHARTS.md — Helm settings for Java on k3s inside these VMs

Companion to CLAUDE.md's "Guests running k3s with Java workloads". That
section covers the **host** side (balloon, swap, swappiness) and concludes
that host swap does the real work. This file covers the **guest** side:
what to change in a Helm chart so 30-60 JVMs behave inside a 32 GB VM.

Scope and constraint: no Java source changes, no image rebuilds. Everything
here is `values.yaml` or an admission policy. It is all optional — the VMs
work without any of it — but the first section prevents a failure mode that
will otherwise bite eventually.

## The three layers

Most confusion here comes from mixing these up:

| Layer | Enforced by | On exceeding it |
|---|---|---|
| Java heap (`-Xmx` / `MaxRAMPercentage`) | The JVM | `OutOfMemoryError` — an exception, with a stack trace |
| Container limit (`resources.limits.memory`) | The kernel cgroup | **OOMKill** — SIGKILL, no trace, exit code 137 |
| VM RAM, then host RAM | Guest kernel, then the hypervisor | Guest OOM killer; or host swap (see CLAUDE.md) |

The goal is to make layer 1 fit comfortably inside layer 2, so failures
arrive as readable Java errors rather than processes vanishing.

## 1. Always set a memory limit (the one that matters)

Every JDK since 8u191/10 has `-XX:+UseContainerSupport` on by default: the
JVM reads the cgroup limit and sets max heap to **25% of it**. That default
explains two opposite surprises:

- **No limit set** — the JVM sees the whole node. In a 32 GB VM every pod
  claims a max heap of ~8 GB. Forty pods have promised 320 GB. It appears to
  work until real traffic arrives, and then the *node* dies rather than a pod.
- **Limit of 1 GiB** — max heap is ~256 MiB, and a service with a gigabyte
  throws `OutOfMemoryError`.

So set `resources.limits.memory` on everything, and set the percentage
explicitly rather than inheriting 25%.

## 2. Heap is not the whole footprint

The limit must cover everything the process maps:

| Region | Typical | Note |
|---|---|---|
| Java heap | what you configure | the only part `MaxRAMPercentage` governs |
| Metaspace | 50-150 MB | Spring Boot sits at the high end |
| JIT code cache | 30-100 MB | grows as hot paths compile |
| Thread stacks | **1 MB x threads** | 200 threads = 200 MB; the usual surprise |
| GC structures | 5-10% of heap | G1 remembered sets, card tables |
| Direct/NIO buffers | 0 - hundreds of MB | Netty, gRPC, Kafka clients |
| JVM baseline | ~50 MB | |

Rule of thumb: **heap = 60-75% of the container limit**, not 90%. Low end
for large thread pools or heavy off-heap I/O, high end for small CPU-bound
services.

```
limit 1 GiB, MaxRAMPercentage=70  ->  ~716 MB heap, ~300 MB for the rest
limit 1 GiB, MaxRAMPercentage=90  ->  ~920 MB heap, ~100 MB for the rest -> OOMKill
```

`-XX:MaxDirectMemorySize` caps off-heap NIO explicitly; it is the usual
culprit when heap looks healthy and the container still dies.

## 3. Injecting flags without touching the code

`-XX:` flags are not code and need no rebuild. The JVM reads
**`JAVA_TOOL_OPTIONS`** at startup, before `main()` — honoured by the normal
launcher, executable JARs, Spring Boot, Tomcat, Quarkus, and images whose
entrypoint you do not control. It announces itself on stderr
(`Picked up JAVA_TOOL_OPTIONS: ...`), which is how you confirm it landed.

```yaml
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:MaxRAMPercentage=70
      -XX:+ExitOnOutOfMemoryError
```

Near neighbours, in case a chart already sets one:

- `JAVA_TOOL_OPTIONS` — read by the JVM itself via the JNI invocation API.
  Widest support; prefer it.
- `JDK_JAVA_OPTIONS` — JDK 9+, only the `java` launcher honours it.
- `JAVA_OPTS` — **not a JVM feature.** A convention some startup shell
  scripts implement (Tomcat, certain Spring Boot images). Works only if that
  image's entrypoint happens to read it.

If a chart already sets `JAVA_TOOL_OPTIONS`, your value may be replaced
rather than merged — check `helm template` output before assuming.

## 4. requests, limits and QoS

| requests vs limits | QoS class | Consequence |
|---|---|---|
| unset | BestEffort | evicted first; avoid |
| requests < limits | Burstable | can use spare node memory; **swap-eligible** |
| requests == limits | Guaranteed | strongest eviction protection; **no swap under kubelet's `LimitedSwap`** |

The trap is that "Guaranteed is safest" is true for eviction and false for
swap: `requests == limits` silently disables swap for exactly the pods you
would most want swapped.

**On these VMs it does not currently bite**, because the decision recorded
in CLAUDE.md is host swap only — no swap inside the guest, so no pod is
swap-eligible either way and Guaranteed is a clean choice. It matters only
if guest swap is ever enabled (`k3s ... --kubelet-arg=fail-swap-on=false`),
at which point requests must drop below limits to get any benefit.

Host swap is invisible to all of this. When the hypervisor pages out the
whole VM, neither kubelet nor the JVM is consulted or aware.

## 5. Giving memory back — and why you probably should not

A JVM that has grown its heap **never returns it to the OS** by default, and
the reason is specific: GC is triggered by allocation, so **an idle JVM never
collects**. A service with no traffic never uncommits anything. A pod idle
for a week still holds every page it ever touched.

| Collector | Returns memory when idle? | How |
|---|---|---|
| **G1** (default) | only at a full GC — effectively never | `-XX:G1PeriodicGCInterval=300000` runs a cycle every 5 min and uncommits |
| **ZGC** | yes | uncommits after `-XX:ZUncommitDelay` (300 s default) |
| **Shenandoah** | yes | `-XX:+ShenandoahUncommit` |
| **Serial / Parallel** | essentially no | — |

**But do not turn periodic GC on here without thinking.** It conflicts with
the strategy these VMs actually use. Host swap works precisely *because*
nothing touches the cold heap: the pages go out to NVMe and stay there.
`G1PeriodicGCInterval` walks the entire heap every five minutes, faulting
all of it back in — defeating the reclaim it was meant to help.

Pick one, not both:

- **Host swap (current choice).** No Helm change. Idle VM drifts to disk,
  one slow warm-up when someone returns.
- **Return memory properly.** Periodic GC or ZGC, plus the balloon's
  free-page reporting (already on — see CLAUDE.md). The guest hands pages
  back, the host reclaims them without disk I/O. Better if the VM must stay
  responsive at all times; costs CPU every interval.

## 6. Charts you do not control

In increasing order of effort:

1. **Global values.** Umbrella charts thread `global:` into subcharts; a
   shared library chart takes the env block once in `_helpers.tpl`.
2. **`--post-renderer`.** Pipe rendered manifests through kustomize and
   patch env vars into any container. No chart cooperation needed.
3. **Mutating admission policy.** Most robust for a fleet — applies to
   charts installed later and survives upgrades:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-java-tool-options
spec:
  rules:
    - name: add-jvm-flags
      match:
        any:
          - resources:
              kinds: [Pod]
              selector:
                matchLabels:
                  runtime: java
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                env:
                  - name: JAVA_TOOL_OPTIONS
                    value: "-XX:MaxRAMPercentage=70"
```

Kyverno runs fine on k3s; the cost is one more controller. Worth it above
roughly a dozen charts.

## 7. Verifying it took effect

```bash
# Did the JVM read the variable? It says so at startup.
kubectl logs <pod> | head -5          # "Picked up JAVA_TOOL_OPTIONS: ..."

# What did the JVM actually decide? This is the number that matters.
kubectl exec <pod> -- jcmd 1 VM.flags | tr ' ' '\n' | grep -E 'MaxHeapSize|MaxRAM'

# What is the container really using (what the OOM killer watches)?
kubectl top pod <pod>

# Has anything been OOMKilled?
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'
```

If `MaxHeapSize` is 25% of the limit, the variable did not land — look for a
chart that overwrote it.

## 8. Worked example

A 32 GB VM: reserve ~3 GB for the OS, k3s and system pods, leaving ~29 GB
allocatable. Across 40 pods that averages ~700 MB, so size in tiers rather
than giving everything the same.

```yaml
# values.yaml — mid-sized Spring Boot service
resources:
  requests:
    memory: 512Mi          # what it actually uses at rest
    cpu: 100m
  limits:
    memory: 1Gi            # the ceiling the kernel enforces
    cpu: 1000m

env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:MaxRAMPercentage=70
      -XX:MaxMetaspaceSize=128m
      -XX:MaxDirectMemorySize=64m
      -XX:+ExitOnOutOfMemoryError
      -XX:+HeapDumpOnOutOfMemoryError
      -XX:HeapDumpPath=/tmp
```

A 1 GiB ceiling, ~716 MB heap, metaspace and direct buffers capped so they
cannot quietly consume the remainder. **No `G1PeriodicGCInterval`** — see
section 5; it would fight the host swapping these VMs rely on.

`ExitOnOutOfMemoryError` earns its place: without it a JVM that exhausts its
heap often limps on — threads dying, requests failing, the process still
"up" and still passing a TCP liveness probe. Failing fast is better where
restarting is cheap.

## 9. Pitfalls

- **Exit code 137 is not a Java problem.** SIGKILL from the cgroup: the
  *container* exceeded its limit. No heap dump, no stack trace. Look at the
  total footprint, not the heap.
- **`OutOfMemoryError` while the container has room** means the heap is too
  small relative to the limit — raise `MaxRAMPercentage`.
- **Thread stacks are invisible** on every heap graph. 500 threads is half a
  gigabyte that nothing will show you.
- **Sidecars share the pod, not the limit.** Limits are per-container; a mesh
  sidecar needs its own 100-200 MB in the pod budget.
- **Per-pod limits do not protect the node.** Scheduling counts *requests*
  only, so low requests plus high limits is exactly how a node ends up
  overcommitted. Forty pods under a 1 GiB limit still total 40 GiB.
- **Init containers are sized separately** and inherit none of this.
- **`requests == limits` disables swap** under `LimitedSwap` — see section 4.

## 10. What this cannot do for the host

Worth being explicit, since these VMs sit on a deliberately overbooked host.

**Helm tuning gives you:** bounded, predictable per-pod memory; failures that
surface as readable Java errors instead of silent kills; and, if an
uncommitting GC is ever enabled, pods that hand memory back to the guest
kernel where the balloon's free-page reporting can return it to the host.

**Helm tuning does not give you:** any guarantee for the host. The planning
number on the hypervisor stays the **sum of every VM's configured RAM**,
because a guest that has touched its memory looks fully resident whether or
not the workload is idle, and page cache inside the guest is never returned
by free-page reporting.

Which is why CLAUDE.md treats **host swap as the mechanism that works
regardless** — it needs no cooperation from Helm, kubelet or the JVM, and an
unattended VM is its best case. Everything here makes the guest better
behaved and its failures more legible. It is not a substitute for sizing the
host's swap correctly.
