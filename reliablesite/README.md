# ReliableSite — API notes, security findings, and an outage runbook

Field notes from operating a ReliableSite dedicated server and driving their v2 REST
API. Written down because most of it is not in their documentation, and two of the
findings are things you would want to know **before** an incident rather than during
one.

Nothing here is specific to any one server or account. No credentials, addresses, or
identifiers appear in this repository.

---

## 1 · The API, and the four things that will waste your afternoon

**Base URL** — `https://dedicated-servers.reliablesite.dev/v2`

There is also an older SOAP/WCF API referenced in their knowledge base. Ignore it; the
v2 REST API above is the current one and is what this document covers.

### 1.1 · The OpenAPI spec is at `/v2/swagger/v2/swagger.json`

Note **`v2` twice**. The intuitive `/v2/swagger/v1/swagger.json` does not exist. The
UI is at `/v2/swagger/index.html`.

### 1.2 · The Swagger UI is behind a Cloudflare bot challenge

A plain HTTP client (`curl`, `requests`, `urllib`) gets **HTTP 403 and a
`Just a moment...` challenge page** instead of the spec — including for the raw
`swagger.json`. This is not an authentication or IP problem, and no header will fix
it.

**Open it in a real browser.** The API *paths themselves* are not challenged, so once
you know the endpoint names you can call them from anything.

### 1.3 · The API key goes in the QUERY STRING, not the body

This is the single biggest time-waster. All three body encodings — JSON object, form
URL-encoded, multipart — return:

```json
{"errors": {"ApiKey": ["The ApiKey field is required."]}, "status": 400}
```

…which reads like a *wrong key*, not a wrong place to put it. The working call is:

```bash
curl -X POST "$BASE/Login/Token?ApiKey=$KEY" -H 'Content-Length: 0'
# → {"status": true, "message": "<JWT>"}
```

The JWT arrives in the `message` field (not `token`), is valid for **24 hours**, and
is then sent as `Authorization: Bearer <jwt>`. Verify it with
`GET /Login/VerifyToken`, which returns the expiry timestamp.

Every response is wrapped as `{status, message, data}`. Check `status` — a `200` with
`status: false` is a failure.

### 1.4 · The calling IP must be authorised, and there are TWO separate allow-lists

The control panel has an **API access list** (which IPs may use the key) and a
separate **IPMI/KVM access list** (which IPs may reach the BMC). They are not the
same list and authorising one does not authorise the other. From an unauthorised
address the key is simply rejected, which looks like a bad key.

The IPMI grant is also **time-limited** — it expires after a few hours and must be
re-enabled. `GET /Server/GetIPMISessions` shows the active grant and its expiry.

### 1.5 · Rate limiting is Cloudflare's, and it bites hard

Bursting requests earns **`error code: 1015`** and a temporary block. Do not
enumerate endpoints by guessing paths — that is exactly what trips it, and losing API
access during an outage is the worst possible time.

Two things make this easy to trip accidentally:

* **Bare controller paths 404 even when the controller exists.** `GET /Login` is a
  404 because the controller only has `/Login/Token` and `/Login/VerifyToken`. So a
  404 tells you nothing, which invites more guessing.
* Space calls **2–3 seconds apart** and work from the spec instead.

---

## 2 · Security findings

### 2.1 · 🔴 `GET /Server/{serverId}` returns the root password in cleartext

The server-detail endpoint returns, in the same object as the CPU model and disk
size:

```json
{ "username": "root", "password": "<the actual root password, in plaintext>" }
```

**A read-only GET, authenticated by the API key alone, discloses root credentials.**
Consequences worth being explicit about:

* The API key is not a lower-privilege credential than the root password — it is a
  superset of it. Treat the key exactly as you would treat root.
* Any log, ticket, screenshot, or CI artifact containing a raw response from this
  endpoint contains your root password. `rs_status.py` in this repo redacts the field
  by default for exactly this reason.
* If the API key is ever exposed, **rotating the key is not sufficient** — the root
  password must be rotated too, because it may already have been read.

### 2.2 · 🔴 One POST with the same key reinstalls the OS

`POST /Server/{serverId}/OSInstallStart` starts a fresh OS install, destroying
everything on the disk. There is no confirmation step, no second factor, and no
separate scope: the key that reads your bandwidth graph can wipe the machine.

There is no way to obtain a read-only credential. The only available mitigations are
external: keep the key at mode `600`, keep the authorised-IP list as narrow as
possible, and use tooling that is *structurally* incapable of calling write
endpoints.

### 2.3 · No credential scoping at all

The token carries `IsAdmin` and `IsReseller` claims, but for a normal customer
account there is no read-only mode, no per-endpoint permission, and no way to issue a
second key with reduced rights. One key, full control.

---

## 3 · Diagnosing an outage

### 3.1 · The single most useful test: is the BMC alive?

**A BMC / IPMI board runs on standby power.** It is reachable whenever the PSU has AC
and the board is intact — independently of whether the host OS is running.

```bash
ping -c3 <kvm-ip>
# then check tcp/80, tcp/443, tcp/5900, tcp/623
```

| BMC reachable? | Conclusion |
|---|---|
| **Yes** | The machine has power **at this moment** and the datacenter network is up. *Probably* a boot or OS problem — powered off, kernel panic, failed POST, or waiting at a prompt — which you can often fix yourself via KVM or the power endpoints. |
| **No** | Power or upstream network. PSU failure, tripped circuit, or a switch problem. **Needs the provider.** |

This separates "click power on" from "open a ticket" and is worth doing first every
time. The *host* being unreachable proves nothing if you have firewalled it (see § 4).

> #### ⚠ The BMC test describes NOW, not the moment of failure — and we got this wrong
>
> On an outage we diagnosed, the BMC answered ICMP and had tcp/80, 443, 5900 and 623
> open **9.3 hours after the host went silent**. We concluded the machine had power and
> that a PSU failure was therefore ruled out.
>
> **The root cause was a failed PSU.** The provider replaced the power supply and
> cables, and the host booted about an hour after we ran that test.
>
> The reasoning error is worth naming, because the test itself is sound: **BMC
> reachability is a point-in-time observation, and we applied it to a nine-hour-old
> event.** By the time we looked, a technician was already working on the machine —
> quite possibly with the replacement PSU already fitted and the board sitting in
> standby, not yet booted. That is indistinguishable, from outside, from "it never lost
> power at all". Redundant PSUs produce the same ambiguity: one dead supply can leave
> the BMC up on the survivor while the board still refuses to boot.
>
> **So: trust `BMC alive` as a reason to try the console and the power endpoints
> yourself. Do not trust it as evidence about what happened hours ago, and never use
> it to argue a cause back to the provider.** If the outage is already old, the honest
> statement is the one you can prove: *"it stopped responding at HH:MM UTC and has not
> returned."*

### 3.1b · After recovery, `last -x` settles clean-shutdown vs crash

This is the check that actually answers what happened, and it takes one command:

```bash
last -x reboot shutdown | head -5
journalctl --list-boots | tail -3
journalctl -b -1 -n 60          # last 60 lines of the PREVIOUS boot
```

A `shutdown` record at the failure time means something told the machine to go down. **No
`shutdown` record — a `reboot` line with no `shutdown` before it — means it was killed**,
which is what a PSU failure looks like:

```
reboot   Mon Aug 17 17:18     <- the recovery boot, after the PSU swap
reboot   Thu Aug  6 20:41     <- the boot that was running when it died
shutdown Thu Aug  6 20:36     <- the last clean shutdown: ELEVEN DAYS EARLIER
```

Do this before replying to the ticket. It is the difference between an evidenced claim
and a guess — and it also disposes of a tempting false signal: when several VMs and
their host all drop off a mesh VPN within a few seconds, the *order* looks like an
orderly shutdown cascade. It is not. Mesh heartbeats are not synchronised between
nodes, so a spread of ten or twenty seconds is noise, not sequence.

### 3.2 · Absence of provider-side records is itself evidence

Three read-only endpoints, and **empty is the informative answer**:

| Endpoint | Empty means |
|---|---|
| `GET /Maintenance/GetMaintenance` | No planned or logged maintenance — the provider cannot attribute the outage to scheduled work |
| `GET /NullRoutes/GetNullRoutes?onlyActive=false` | The IP was never null-routed — rules out DDoS mitigation as the cause |
| `GET /DDoS/GetDDoSAttacks` | No attack recorded |

Pass `onlyActive=false` on null routes — the default hides expired entries, which are
exactly what you want when investigating something that already ended.

### 3.3 · The bandwidth counters date the outage independently

`GET /Server/{serverId}/BandwidthGraph?period=Day&timeZone=UTC` returns **hourly**
samples. An outage appears as a clean step to `0.0` and the recovery as a step back:

```
… 04:51   0.0   0.08   2.04   35.30      steady
   05:51   0.0   0.07   2.06   32.02
   06:51   0.0   0.07   1.69   30.48
   07:51   0.0   0.00   0.00    0.00      ← traffic stops
   …                                       (nine hours of zeros)
   16:51   0.0   0.00   0.00    0.00
   17:51   0.0   0.07   1.98   31.10      ← traffic resumes
```

This is the **provider's own switch counter**, so it is the number to quote in a
ticket — independent of your monitoring, and hard to argue with.

Two quirks:

* **It lags by up to an hour.** A recovery in the last hour may not appear yet. This
  is easy to misread as "still down".
* **The 30-second series inside `GET /Server/{serverId}` disagrees with it.** That
  series has been observed showing small non-zero values during hours when the
  machine was provably down. Trust the hourly graph; do not build a timeline on the
  30-second one.

`period` accepts `Hour`, `Day`, `Month`, `Year`.

### 3.4 · Endpoint inventory — 44 operations

**Read-only (28)** — account profile and notification settings; FTP backup spaces;
DDoS attack history, per-attack detail and FlowSpec bandwidth charts; DDoS profiles;
maintenance log; null routes; rDNS records and per-block IP lists; server list and
detail; KVM details; active IPMI sessions; MAC address; compatible OS and
partitioning schemes; OS-install status; bandwidth graphs; hardware upgrade pricing.

**Mutating (16)** — handle deliberately:

| Risk | Operations |
|---|---|
| **Destroys data** | `Server/{id}/OSInstallStart`, `Reseller/DeleteCustomer` |
| **Takes the host down** | `Server/{id}/PowerOff`, `Server/{id}/PowerOn`, `NullRoutes/AddNullRoute` |
| Changes access | `EnableKVM`, `DisableKVM`, `SetMacAddress`, `Backup/SetFTPAccount` |
| Configuration | `Account/SetProfile`, `Account/SetEmailNotification`, `rDNS` set, `RemoveNullRoute`, DDoS `AssignIp` / remove IP |
| Reseller only | `AddCustomer`, `UpdateCustomer`, `AssignServer`, `UnassignServer`, `UpdateUpgradePricing` |

Reseller endpoints return an error on a plain customer account — check the
`accountType` in `GET /Account/GetProfile`.

**`PowerOn` / `PowerOff` are the useful pair**: they mean a stuck host can be
recovered from a script, without the web portal, and without waiting on support.

### 3.5 · What the provider is like

Worth calibrating expectations. Publicly reported experiences with the Miami facility
include **no on-site staff overnight** and multi-hour first responses, with at least
one reported case of a server dark for over six hours traced to a power supply
failure. Assume that anything requiring hands takes hours, and that **anything you
can do through IPMI you should do yourself.**

**Power supplies appear to be a recurring failure mode there.** We have a first-hand
PSU failure (PSU and power cables replaced, ~10 hours end to end) in addition to the
publicly reported one above. When a host goes completely dark with no clean shutdown
record, a dead PSU should be near the top of the list rather than dismissed — and the
resolution requires the provider regardless of what the BMC appears to say (§ 3.1).

---

## 4 · Best practices we adopted

These are deliberate choices, and § 2 is why.

**The host has no root access and no login access at all from the public internet.**
Not "root login disabled" — *no* SSH exposure. The public IP accepts nothing. The
only route in is over a **[Tailscale](https://tailscale.com) tailnet**, as an
unprivileged user, and root is reachable only by `sudo` once already inside.

Given § 2.1 — that the root password is readable through a GET by anyone holding the
API key — a password-authenticated root login on a public IP would mean the API key
is a remote root shell. Closing the network path is what removes that. The password
still leaks; it just stops being useful.

**The only maintenance path when the tailnet is down is KVM/IPMI.** That is the
intended design, not a gap. If Tailscale cannot reach the box, the box is not
reachable at all — which forces the diagnosis in § 3.1 and means recovery goes
through the console, where you can see *why* it is broken rather than guessing.

The consequences are worth accepting knowingly:

* **Record the KVM/IPMI address somewhere reachable when the host is not** — a
  password manager or a note on a different machine. When the tailnet is down, an
  address stored only on the box or only in its own repository is useless.
* **Re-enabling IPMI access needs the control panel or `EnableKVM`**, because the
  grant is time-limited and per-IP. Do not discover this during an incident.
* **Keep a second machine on the tailnet.** A single-workstation tailnet plus a
  firewalled host means one lost laptop locks you out entirely.

**Treat the API key as root, because it is.** Mode `600`, never committed, narrow
authorised-IP list, and rotate the **root password** as well as the key if it is ever
exposed.

**Rotate the root password after provisioning.** It was set by the provider,
transmitted to you, and is retrievable through their API indefinitely.

**Use read-only tooling for diagnosis.** `rs_status.py` here makes exactly one
non-GET call — `/Login/Token` — and never names a mutating endpoint in code. During
an incident you want a tool that cannot make things worse.

---

## 5 · `rs_status.py`

Read-only health check. No dependencies beyond the standard library.

```bash
chmod 600 ~/.rs.key            # or export RS_API_KEY=...
./rs_status.py                 # full report
./rs_status.py --json          # machine-readable
./rs_status.py --server 1234   # one server
./rs_status.py --quick         # skip account-wide checks
```

It reports the account, maintenance log, null routes, DDoS history, active IPMI
sessions, and per server the hardware, status and hourly bandwidth series with the
stop/resume transitions marked.

**It redacts the root password by default** and says that it did so, so the field is
not mistaken for absent. `--show-secrets` overrides that; think about where the
output is going first.

It paces requests 2.5 s apart (`--pause`) and aborts on a `1015` rather than
retrying, because retrying extends the block.
