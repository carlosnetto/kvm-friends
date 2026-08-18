#!/usr/bin/env python3
"""
================================================================================
rs_status.py — read-only health check for a ReliableSite dedicated server
================================================================================
Answers "what does the provider think is happening?" when a box stops responding
and you cannot tell a dead server from a dead network.

    ./rs_status.py                     # everything, human-readable
    ./rs_status.py --json              # same data, machine-readable
    ./rs_status.py --server 1234       # one server instead of all
    ./rs_status.py --quick             # server list + power/bandwidth only

THIS SCRIPT CANNOT CHANGE ANYTHING, BY CONSTRUCTION
--------------------------------------------------------------------------------
Every request is a GET. The single exception is `POST /Login/Token`, which is the
authentication call and carries no payload. There is no code path here that can
issue PUT, PATCH, DELETE, or any POST other than that one — see `_get()`, which
hardcodes the method and is the only function that talks to the network.

That matters more than it sounds. The same API key that authorises these reads
also authorises `POST /Server/{id}/OSInstallStart`, which reinstalls the operating
system and destroys everything on the disk. A diagnostic script is exactly the
thing you run half-awake during an outage, so it should be incapable of that.

IT REDACTS THE ROOT PASSWORD, AND THAT IS NOT PARANOIA
--------------------------------------------------------------------------------
`GET /Server/{id}` returns the server's **root password in cleartext**, in the
same object as the CPU model and the disk size. A status tool whose output gets
pasted into a ticket, a chat, or a CI log must not carry that. It is replaced with
«redacted» unless you pass --show-secrets, and the report says so explicitly so
nobody concludes the field is absent.

RATE LIMITING IS REAL AND IT IS CLOUDFLARE'S, NOT THE API'S
--------------------------------------------------------------------------------
The service sits behind Cloudflare. Bursting requests earns `error code: 1015`
and a temporary block on the key — which is the worst possible moment to lose API
access. Hence PAUSE below, and hence no endpoint enumeration: this script calls a
fixed, known list.

REQUIREMENTS
--------------------------------------------------------------------------------
* An API key from the control panel, in ~/.rs.key (mode 600) or $RS_API_KEY.
* THE CALLING IP MUST BE ON THE AUTHORIZED LIST in the control panel. This is not
  optional and it is not the same list as the KVM/IPMI allow-list. From an
  unauthorised address the key is simply rejected, which reads like a bad key.
* Python 3.9+. No third-party packages, deliberately — this runs during an
  incident, possibly on a machine you have just rebuilt.
================================================================================
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

BASE = "https://dedicated-servers.reliablesite.dev/v2"

# The OpenAPI document is at /v2/swagger/v2/swagger.json — note v2 TWICE. The
# obvious /v2/swagger/v1/swagger.json does not exist, and the Swagger UI itself is
# behind Cloudflare's bot challenge, so a plain HTTP client gets a 403 challenge
# page rather than a spec. Open it in a real browser if you need to re-read it.
SPEC_URL = f"{BASE}/swagger/v2/swagger.json"

# A browser-shaped User-Agent. Not an attempt to be sneaky: the default urllib
# agent is met by the bot challenge on some paths, and a diagnostic tool failing
# with an HTML challenge page is a confusing way to learn that.
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")

PAUSE = 2.5          # seconds between calls; see the rate-limit note above
TIMEOUT = 45

SECRET_KEYS = {"password", "ipmipassword", "kvmpassword", "apikey", "token"}


# ── transport ────────────────────────────────────────────────────────────────
def _login(key: str) -> str:
    """The ONLY non-GET call in this file. Returns a bearer token.

    The key goes in the QUERY STRING. It is not a JSON body and not a form field
    — all three body encodings answer `The ApiKey field is required`, which reads
    like a wrong key rather than a wrong encoding and is worth an hour if you do
    not know it.
    """
    url = f"{BASE}/Login/Token?ApiKey={urllib.parse.quote(key)}"
    req = urllib.request.Request(url, method="POST")
    req.add_header("User-Agent", UA)
    req.add_header("Accept", "application/json")
    req.add_header("Content-Length", "0")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            body = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        if "1015" in raw:
            die("rate limited by Cloudflare (error 1015). Wait a few minutes; do "
                "not retry in a loop — that extends the block.")
        die(f"login failed: HTTP {e.code} {raw[:200]}")
    except Exception as e:                                   # noqa: BLE001
        die(f"login failed: {e}")
    tok = body.get("message") if isinstance(body, dict) else None
    if not tok or not body.get("status"):
        die(f"login returned no token: {str(body)[:200]}")
    return tok


def _get(path: str, tok: str, pause: float = PAUSE):
    """Issue a GET. The method is hardcoded; this is the only network call used
    for data, so nothing in this script can mutate state."""
    req = urllib.request.Request(BASE + path)                # GET, always
    req.add_header("User-Agent", UA)
    req.add_header("Accept", "application/json")
    req.add_header("Authorization", "Bearer " + tok)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            code, raw = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        code, raw = e.code, e.read().decode(errors="replace")
    except Exception as e:                                   # noqa: BLE001
        return 0, {"error": str(e)}
    time.sleep(pause)
    if "error code: 1015" in raw:
        return 429, {"error": "rate limited by Cloudflare (1015)"}
    try:
        return code, json.loads(raw)
    except Exception:                                        # noqa: BLE001
        return code, {"error": raw[:300]}


def die(msg: str) -> "None":
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(2)


# ── helpers ──────────────────────────────────────────────────────────────────
def load_key(path: str | None) -> str:
    if os.environ.get("RS_API_KEY"):
        return os.environ["RS_API_KEY"].strip()
    for cand in ([path] if path else []) + ["~/.rs.key", "~/rs.key"]:
        p = pathlib.Path(os.path.expanduser(cand))
        if p.is_file():
            mode = p.stat().st_mode & 0o777
            if mode & 0o077:
                print(f"warning: {p} is mode {mode:o} — should be 600. "
                      f"This key alone can reinstall the OS.", file=sys.stderr)
            return p.read_text().strip()
    die("no API key. Put it in ~/.rs.key (mode 600) or set $RS_API_KEY.")


def redact(obj, show: bool):
    """Strip secret-looking fields. Recursive, so it survives nesting changes."""
    if show:
        return obj
    if isinstance(obj, dict):
        return {k: ("«redacted»" if k.lower() in SECRET_KEYS and v else redact(v, show))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(v, show) for v in obj]
    return obj


def unwrap(code, body, what: str):
    """The API wraps everything as {status, message, data}. Returns data or None."""
    if code == 429:
        print(f"  ! {what}: rate limited — stopping to protect the key")
        raise SystemExit(3)
    if code != 200 or not isinstance(body, dict):
        print(f"  ! {what}: HTTP {code} {str(body)[:120]}")
        return None
    if not body.get("status"):
        print(f"  ! {what}: {body.get('message')}")
        return None
    return body.get("data")


def series(logs: dict) -> list[tuple[datetime, list]]:
    out = []
    for k, v in (logs or {}).items():
        try:
            out.append((datetime.fromisoformat(k), v))
        except ValueError:
            continue
    return sorted(out, key=lambda x: x[0])


# ── report ───────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(
        description="Read-only ReliableSite server status. Cannot change anything.")
    ap.add_argument("--key-file", help="path to the API key (default ~/.rs.key, ~/rs.key)")
    ap.add_argument("--server", type=int, help="only this serverId")
    ap.add_argument("--quick", action="store_true", help="skip account-wide checks")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a report")
    ap.add_argument("--show-secrets", action="store_true",
                    help="do NOT redact the root password the API returns")
    ap.add_argument("--pause", type=float, default=PAUSE,
                    help=f"seconds between calls (default {PAUSE}; lower risks a 1015 block)")
    a = ap.parse_args()

    tok = _login(load_key(a.key_file))
    now = datetime.now(timezone.utc)
    result: dict = {"generatedAtUtc": now.isoformat(), "servers": []}

    if not a.json:
        print(f"\n  ReliableSite status — {now:%Y-%m-%d %H:%M:%S} UTC")
        print(f"  {'─' * 66}")

    data = unwrap(*_get("/Account/GetProfile", tok, a.pause), "account")
    if data:
        result["account"] = redact(data, a.show_secrets)
        if not a.json:
            print(f"  account   {data.get('userName')}  ({data.get('accountType')})")

    servers = unwrap(*_get("/Server/GetServers?page=1", tok, a.pause), "server list") or []
    if a.server:
        servers = [s for s in servers if s.get("serverId") == a.server]
        if not servers:
            die(f"serverId {a.server} not in this account")

    # ── account-wide signals. Each of these being EMPTY is itself the finding:
    # it rules out a provider-side cause, which is most of triage.
    if not a.quick:
        checks = [
            ("/Maintenance/GetMaintenance?page=1", "maintenance",
             "no maintenance logged for this account"),
            ("/NullRoutes/GetNullRoutes?page=1&onlyActive=false", "nullRoutes",
             "no IP has ever been null-routed"),
            ("/DDoS/GetDDoSAttacks?page=1", "ddosAttacks",
             "no DDoS attack recorded"),
            ("/Server/GetIPMISessions?page=1", "ipmiSessions",
             "no active KVM/IPMI session"),
        ]
        if not a.json:
            print(f"  {'─' * 66}")
        for path, key, empty_msg in checks:
            d = unwrap(*_get(path, tok, a.pause), key)
            result[key] = redact(d, a.show_secrets) if d is not None else None
            if not a.json:
                if not d:
                    print(f"  {key:<14} — {empty_msg}")
                else:
                    print(f"  {key:<14} {len(d)} entr{'y' if len(d) == 1 else 'ies'}:")
                    for row in d[:6]:
                        print(f"                 {json.dumps(redact(row, a.show_secrets))[:150]}")

    # ── per server
    for s in servers:
        sid = s["serverId"]
        detail = unwrap(*_get(f"/Server/{sid}", tok, a.pause), f"server {sid}")
        graph = unwrap(*_get(f"/Server/{sid}/BandwidthGraph?period=Day&timeZone=UTC",
                             tok, a.pause), f"bandwidth {sid}")
        entry = {"serverId": sid, "label": s.get("serverLabel"), "status": s.get("status"),
                 "detail": redact(detail, a.show_secrets), "traffic": None}

        if not a.json:
            print(f"  {'─' * 66}")
            print(f"  server {sid}  “{s.get('serverLabel')}”   status: {s.get('status')}")
            if detail and (srv := detail.get("server")):
                print(f"     {srv.get('cpuName')} · {srv.get('memorySize')} {srv.get('memoryType')}"
                      f" · {srv.get('hardDrive1')} · {srv.get('operatingSystem')}")
                print(f"     {srv.get('dataCenterLabel')} · {srv.get('serverDescription')}"
                      f" · {srv.get('bandwidthUsed')} GB used")
                if srv.get("password") and not a.show_secrets:
                    print("     ⚠  the API returned this server's ROOT PASSWORD in cleartext;"
                          " redacted here (--show-secrets to see it)")

        # The hourly series is the useful one: a clean step to zero is an outage,
        # and its timestamp is the provider's own account of when traffic stopped.
        if graph:
            rows = series(graph.get("bandwidthLogs", {}))
            entry["traffic"] = {"samples": len(rows),
                                "from": rows[0][0].isoformat() if rows else None,
                                "to": rows[-1][0].isoformat() if rows else None}
            if rows and not a.json:
                live = [(t, v) for t, v in rows if max(v or [0]) > 0.01]
                dead = [(t, v) for t, v in rows if max(v or [0]) <= 0.01]
                print(f"     traffic   {len(rows)} hourly samples, "
                      f"{rows[0][0]:%m-%d %H:%M} → {rows[-1][0]:%m-%d %H:%M} UTC")
                print(f"               {len(live)} with traffic, {len(dead)} at zero")
                edges = [(rows[i - 1], rows[i]) for i in range(1, len(rows))
                         if (max(rows[i - 1][1] or [0]) > 0.5) != (max(rows[i][1] or [0]) > 0.5)]
                for (t0, v0), (t1, v1) in edges:
                    kind = "STOPS " if max(v0 or [0]) > 0.5 else "RESUMES"
                    print(f"               ⇢ traffic {kind} between "
                          f"{t0:%m-%d %H:%M} and {t1:%m-%d %H:%M} UTC")
                if not edges:
                    state = "flowing throughout" if live and not dead else (
                        "ZERO throughout — the whole window is an outage" if dead and not live
                        else "mixed, no clean transition")
                    print(f"               ⇢ {state}")
            if not a.json and entry["traffic"]["samples"]:
                print("     note      this series LAGS by up to an hour, so a recovery in the "
                      "last hour\n               may not appear yet. The 30-second series in "
                      "/Server/{id} has been\n               observed to disagree with it — trust "
                      "this one. See README.md.")
        result["servers"].append(entry)

    if a.json:
        print(json.dumps(result, indent=2, default=str))
    else:
        print(f"  {'─' * 66}")
        print("  Nothing above changed any state: every call was a GET.")
        print("  If a server is unreachable but its IPMI/BMC answers, it has POWER —")
        print("  that is a boot or OS problem, not a dead machine. See README.md.\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
