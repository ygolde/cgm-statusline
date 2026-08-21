#!/usr/bin/env python3
"""
Poll Dexcom Share and write a JSON cache the Claude Code status line reads.

Design notes:
  * Long-lived, so one Dexcom login serves many reads. Creating a Dexcom() per
    poll would mean ~2900 logins/day and risks SSO_AuthenticateMaxAttemptsExceeded,
    which would lock the account and break his real Follow alerts.
  * Sleeps until the NEXT expected reading (last reading + 5min + skew).
  * Auth failures back off hard and escalate. Never retries a bad password fast.
  * Password lives in the macOS Keychain, held in memory only, never logged.
  * Sparklines are PRE-RENDERED here (with ANSI colour) so the status line does
    no work per keystroke - it just picks a string out of the cache.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from pathlib import Path

from pydexcom import Dexcom, Region
from pydexcom.errors import AccountError, DexcomError

DIR = Path(__file__).resolve().parent
CONFIG = DIR / "config.json"
CACHE = DIR / "cgm.json"
LOG = DIR / "cgm.log"

READING_INTERVAL = 300
SKEW = 20
MIN_SLEEP = 30
IDLE_SLEEP = 150
AUTH_BACKOFF = [300, 900, 1800, 3600]

HISTORY_MIN = 185          # one request covers every window we render
HISTORY_MAX = 37

BLOCKS = "▁▂▃▄▅▆▇█"
BAND_LO, BAND_HI = 70, 180     # target band: anchors the adaptive scale
PAD = 15
RESET = "\033[0m"
DIM = "\033[2m"

logging.basicConfig(filename=LOG, level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("cgm")


def colour(v: int) -> str:
    if v < 55:
        return "\033[1;97;41m"
    if v < 70:
        return "\033[1;31m"
    if v > 250:
        return "\033[1;33m"
    if v > 180:
        return "\033[33m"
    return "\033[32m"


def sparkline(series: list[tuple[int, int]], now: int, minutes: int) -> str:
    """
    Render `minutes` of history as one coloured line.

    Bins by TIMESTAMP, not by list position, so a sensor dropout renders as a
    visible gap instead of silently compressing the time axis - otherwise
    12 characters quietly stop meaning one hour.
    """
    if not series:
        return ""
    slots = minutes // 5
    # Anchor the axis on the NEWEST READING, not on `now`. Anchoring on now
    # leaves the final slot permanently empty (the latest reading is always up
    # to 5 min old), which renders as a phantom dropout on every single draw.
    # Genuine staleness is already carried by the age/dim logic downstream.
    end = max(e for e, _ in series)
    # ROUND to the nearest slot, never floor. Dexcom stamps readings a second
    # or two either side of the 5-minute grid, so a reading 899s back floors
    # into its neighbour's slot: the two collide, one value is lost, and the
    # slot they vacated renders as a phantom dropout. Rounding absorbs up to
    # +/-150s of jitter, which is far more than the sensor ever produces.
    best: dict[int, tuple[int, int]] = {}      # idx -> (distance, value)
    for epoch, value in series:
        offset = end - epoch
        steps = round(offset / READING_INTERVAL)
        idx = slots - 1 - steps
        if not 0 <= idx < slots:
            continue
        # A genuine collision (a duplicate or backfilled reading) keeps
        # whichever reading actually sits closest to the slot it claims.
        dist = abs(offset - steps * READING_INTERVAL)
        if idx not in best or dist < best[idx][0]:
            best[idx] = (dist, value)
    buckets = {i: v for i, (_, v) in best.items()}

    present = list(buckets.values())
    if not present:
        return ""
    lo = min(BAND_LO, min(present) - PAD)
    hi = max(BAND_HI, max(present) + PAD)
    rng = max(hi - lo, 1)

    out = []
    for i in range(slots):
        v = buckets.get(i)
        if v is None:
            out.append(f"{DIM}·{RESET}")
            continue
        level = int(round((min(max(v, lo), hi) - lo) / rng * (len(BLOCKS) - 1)))
        out.append(f"{colour(v)}{BLOCKS[level]}{RESET}")
    return "".join(out)


def keychain_password(service: str, account: str) -> str:
    out = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        capture_output=True, text=True, check=False,
    )
    if out.returncode != 0:
        raise SystemExit(
            f"No Keychain item for service={service!r} account={account!r}.\n"
            f"  security add-generic-password -U -s {service} -a {account} -w"
        )
    return out.stdout.strip()


def write_cache(payload: dict) -> None:
    tmp = CACHE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload))
    os.replace(tmp, CACHE)


def main() -> None:
    if not CONFIG.exists():
        raise SystemExit(f"missing {CONFIG}")
    cfg = json.loads(CONFIG.read_text())
    username = cfg["username"]
    region = Region(cfg.get("region", "ous"))
    service = cfg.get("keychain_service", "claude-cgm-dexcom")

    password = keychain_password(service, username)
    dexcom: Dexcom | None = None
    auth_fails = 0
    last_epoch = 0

    log.info("starting: user=%s region=%s", username, region.value)

    while True:
        try:
            if dexcom is None:
                dexcom = Dexcom(username=username, password=password, region=region)
                log.info("authenticated")
                auth_fails = 0

            readings = dexcom.get_glucose_readings(
                minutes=HISTORY_MIN, max_count=HISTORY_MAX)
            if not readings:
                log.info("no readings in window")
                time.sleep(IDLE_SLEEP)
                continue

            latest = readings[0]                       # API returns newest first
            epoch = int(latest.datetime.timestamp())
            series = [(int(r.datetime.timestamp()), r.value) for r in readings]

            if epoch != last_epoch:
                now = int(time.time())
                write_cache({
                    "value_mgdl": latest.value,
                    "value_mmol": latest.mmol_l,
                    "trend_arrow": latest.trend_arrow,
                    "trend": latest.trend_direction,
                    "trend_description": latest.trend_description,
                    "epoch": epoch,
                    "fetched_at": now,
                    "source": "dexcom-share",
                    "spark": {
                        "1h": sparkline(series, now, 60),
                        "2h": sparkline(series, now, 120),
                        "3h": sparkline(series, now, 180),
                    },
                    "series": series,
                })
                log.info("%s mg/dL %s (%d readings, reading @ %s)",
                         latest.value, latest.trend_arrow, len(readings),
                         latest.datetime.isoformat())
                last_epoch = epoch

            due = epoch + READING_INTERVAL + SKEW
            time.sleep(max(MIN_SLEEP, due - int(time.time())))

        except AccountError as e:
            wait = AUTH_BACKOFF[min(auth_fails, len(AUTH_BACKOFF) - 1)]
            auth_fails += 1
            log.error("auth failed (%s); backing off %ss", e, wait)
            dexcom = None
            time.sleep(wait)
        except DexcomError as e:
            log.warning("dexcom error: %s", e)
            dexcom = None
            time.sleep(120)
        except Exception as e:                          # noqa: BLE001
            log.warning("transient error: %s: %s", type(e).__name__, e)
            time.sleep(60)


if __name__ == "__main__":
    main()
