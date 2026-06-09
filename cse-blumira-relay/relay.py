#!/usr/bin/env python3
"""
CSE -> Blumira relay (lean, with flattening).

Pull every event CSE returns, ship the ones we haven't shipped before, repeat.
The only state is a set of already-forwarded event ids so we don't re-ship CSE's
rolling window every poll.

Because SonicWall CSE isn't a parsed vendor in Blumira, raw nested JSON lands but
nothing gets field-extracted. So by default we FLATTEN each event into clean
top-level keys (source IP, user email, device, action, geo, etc.) before
shipping, and keep the original nested event under "raw" for a future parser.

Confirmed against trcs-hq and baked in as constants:
  * CSE wraps events in a top-level "data" array
  * each event has a unique top-level "id"
  * Blumira auth scheme is "Blumira <token>" (not Bearer)
  * Blumira accepts one JSON event per POST
  * real public source IP + geo live on Identity events (client.ip_address);
    tunnel/Access events carry the CSE overlay address (100.64.0.0/10)
"""

import json
import logging
import os
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

CONFIG_PATH = os.environ.get("RELAY_CONFIG", "/config/config.yaml")
STATE_DIR = Path(os.environ.get("RELAY_STATE_DIR", "/data"))
HEARTBEAT = STATE_DIR / "heartbeat"

SEEN_CACHE_MAX = 50_000     # ids remembered per tenant for dedupe
POST_RETRIES = 4

_shutdown = False


def _handle_signal(signum, _frame):
    global _shutdown
    logging.info("signal %s received; finishing cycle then exiting", signum)
    _shutdown = True


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


# --------------------------------------------------------------------------- #
#  flattening
# --------------------------------------------------------------------------- #
def _dig(obj, *path, default=""):
    cur = obj
    for key in path:
        if isinstance(cur, dict) and key in cur:
            cur = cur[key]
        else:
            return default
    return cur if cur is not None else default


def _split_ip(raw):
    """'65.128.71.22:57515' -> ('65.128.71.22','57515');
    '100.64.0.0,10.60.0.22:60086' -> ('100.64.0.0',''). Full string kept in raw."""
    if not raw:
        return "", ""
    first = str(raw).split(",")[0].strip()
    if ":" in first:
        host, _, port = first.rpartition(":")
        return host, port
    return first, ""


def flatten_event(ev: dict) -> dict:
    up = ev.get("user_principal") or {}
    user = up.get("user") or {}
    dev = up.get("device") or {}
    client = up.get("client") or {}
    geo = client.get("geo_location") or {}
    ts = ev.get("trustscore") or {}
    svc = ev.get("service") or {}
    pol = ev.get("policy") or {}
    rep = ev.get("reported_by") or {}

    client_ip, client_port = _split_ip(client.get("ip_address"))
    dev_ip, _ = _split_ip(dev.get("last_ip_address"))

    created = ev.get("created_at")
    try:
        iso = (datetime.fromtimestamp(created / 1000, tz=timezone.utc).isoformat()
               if created else "")
    except (TypeError, ValueError, OSError):
        iso = ""

    return {
        "event_id": ev.get("id", ""),
        "correlation_id": ev.get("correlation_id", ""),
        "external_id": ev.get("external_id", ""),
        "org_name": ev.get("org_name", ""),
        "severity": ev.get("severity", ""),
        "event_type": ev.get("type", ""),
        "event_subtype": ev.get("sub_type", ""),
        "action": ev.get("action", ""),
        "message": ev.get("message", ""),
        "result": ev.get("result", ""),
        "timestamp_ms": created if created is not None else "",
        "timestamp": iso,
        "user_name": user.get("name", ""),
        "user_email": user.get("email", ""),
        "user_groups": ",".join(user.get("groups") or []),
        "user_roles": ",".join(user.get("roles") or []),
        "device_name": dev.get("friendly_name", ""),
        "device_serial": dev.get("serial_number", ""),
        "device_model": dev.get("model", ""),
        "device_platform": dev.get("platform", ""),
        "device_os": dev.get("os", ""),
        "device_ownership": dev.get("ownership", ""),
        "device_ip": dev_ip,
        "device_user_agent": dev.get("last_user_agent", ""),
        "app_version": _dig(dev, "trust_score_feature", "spec", "app_version"),
        "client_ip": client_ip,
        "client_port": client_port,
        "client_user_agent": client.get("user_agent", ""),
        "geo_city": geo.get("city", ""),
        "geo_region": geo.get("region", ""),
        "geo_country": geo.get("country", ""),
        "geo_lat": geo.get("latitude", ""),
        "geo_lon": geo.get("longitude", ""),
        "trust_score": ts.get("score", ""),
        "trust_level": ts.get("trust_level", ""),
        "service_name": svc.get("name", ""),
        "service_type": svc.get("type", ""),
        "is_saas_app": svc.get("is_saas_app", ""),
        "policy_name": pol.get("name", ""),
        "policy_enabled": pol.get("enabled", ""),
        "reported_by_host": rep.get("host_name", ""),
        "raw": ev,
    }


# --------------------------------------------------------------------------- #
#  config / state
# --------------------------------------------------------------------------- #
def load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)
    if not cfg or not cfg.get("tenants"):
        raise SystemExit(f"No tenants defined in {CONFIG_PATH}")
    return cfg


def state_file(name: str) -> Path:
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in name)
    return STATE_DIR / f"{safe}.seen.json"


def load_seen(name: str) -> list:
    path = state_file(name)
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            logging.warning("[%s] couldn't read state (%s); starting fresh", name, exc)
    return []


def save_seen(name: str, seen: list) -> None:
    seen = seen[-SEEN_CACHE_MAX:]
    tmp = state_file(name).with_suffix(".tmp")
    tmp.write_text(json.dumps(seen), encoding="utf-8")
    tmp.replace(state_file(name))


# --------------------------------------------------------------------------- #
#  CSE pull / Blumira push
# --------------------------------------------------------------------------- #
def fetch_events(tenant: dict) -> list:
    base = tenant["cse_command_center"].rstrip("/")
    resp = requests.get(
        f"{base}/api/v1/events",
        headers={"Authorization": f"Bearer {tenant['cse_api_key']}"},
        timeout=30,
    )
    resp.raise_for_status()
    body = resp.json()
    if isinstance(body, list):
        return body
    for key in ("data", "Data", "events", "Events", "results"):
        if isinstance(body, dict) and isinstance(body.get(key), list):
            return body[key]
    logging.warning("[%s] unexpected payload shape: %s",
                    tenant["name"], type(body).__name__)
    return []


def event_id(event: dict) -> str:
    val = event.get("id")
    return str(val) if val else str(hash(json.dumps(event, sort_keys=True)))


def ship(tenant: dict, payload: dict) -> None:
    headers = {
        "Authorization": f"Blumira {tenant['blumira_token']}",
        "Content-Type": "application/json",
    }
    data = json.dumps(payload)
    delay = 2
    for attempt in range(1, POST_RETRIES + 1):
        try:
            resp = requests.post(tenant["blumira_url"], headers=headers,
                                 data=data, timeout=30)
            if resp.status_code < 300:
                return
            if 400 <= resp.status_code < 500 and resp.status_code != 429:
                raise RuntimeError(
                    f"Blumira rejected POST {resp.status_code}: {resp.text[:300]}")
        except requests.RequestException as exc:
            logging.warning("[%s] POST attempt %d failed: %s",
                            tenant["name"], attempt, exc)
        if attempt < POST_RETRIES:
            time.sleep(delay)
            delay *= 2
    raise RuntimeError(f"[{tenant['name']}] Blumira POST failed after {POST_RETRIES} tries")


def poll_tenant(tenant: dict, flatten: bool, drop_debug: bool) -> None:
    name = tenant["name"]
    seen = set(load_seen(name))
    events = fetch_events(tenant)

    candidates = [e for e in events if event_id(e) not in seen]
    shipped = 0
    for e in candidates:
        seen.add(event_id(e))   # mark seen whether or not we ship it
        if drop_debug and str(e.get("severity", "")).upper() == "DEBUG":
            continue
        ship(tenant, flatten_event(e) if flatten else e)
        shipped += 1

    logging.info("[%s] pulled %d, shipped %d new", name, len(events), shipped)
    if candidates:
        save_seen(name, list(seen))


# --------------------------------------------------------------------------- #
#  main loop
# --------------------------------------------------------------------------- #
def main() -> None:
    logging.basicConfig(
        level=os.environ.get("RELAY_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    cfg = load_config()
    interval = cfg.get("poll_interval_seconds", 60)
    flatten = cfg.get("flatten", True)        # flatten by default
    drop_debug = cfg.get("drop_debug", False)  # keep DEBUG by default
    logging.info("relay starting; %d tenant(s); interval %ds; flatten=%s drop_debug=%s",
                 len(cfg["tenants"]), interval, flatten, drop_debug)

    while not _shutdown:
        start = time.monotonic()
        for tenant in cfg["tenants"]:
            if _shutdown:
                break
            try:
                poll_tenant(tenant, flatten, drop_debug)
            except Exception as exc:
                logging.error("[%s] cycle error: %s", tenant.get("name", "?"), exc)
        try:
            HEARTBEAT.write_text(datetime.now(timezone.utc).isoformat())
        except OSError:
            pass
        sleep_for = max(1, interval - (time.monotonic() - start))
        slept = 0.0
        while slept < sleep_for and not _shutdown:
            time.sleep(min(2, sleep_for - slept))
            slept += 2

    logging.info("relay stopped cleanly")


if __name__ == "__main__":
    main()
