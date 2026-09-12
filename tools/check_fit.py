#!/usr/bin/env python3
"""Check what Solar Harvest actually wrote into an activity .FIT file.

Run this on a FIT downloaded from the watch after a test activity. It answers the
question "why does Garmin Connect show nothing?" by reporting, in order:

  1. The Connect IQ application_id. All zeros means the id never made it into
     the file and Connect has nothing to attach the fields to. An id that simply
     differs from manifest.xml is NOT a fault for a store beta: Garmin issues a
     beta its own store identifier and the device records that one.
  2. Which developer fields were declared, and on which message type.
  3. Whether every lap carries its own value. A lap reading None, or carrying the
     previous lap's number, means lap fields are being set from onTimerLap()
     instead of from compute().
  4. The session summary values.
  5. How noisy the recorded solar channel is, which is what decides whether the
     Connect graph is a readable curve or a solid band.

Usage:  python3 tools/check_fit.py ACTIVITY.fit
Needs:  pip install fitparse
"""

import re
import sys
from collections import Counter
from pathlib import Path


def manifest_uuid():
    """The app id this repo builds, as lowercase hex with no dashes.

    Read from manifest.xml next to the tool rather than hard-coded, so the
    comparison keeps working after the id is changed.
    """
    for candidate in (Path(__file__).resolve().parent.parent / "manifest.xml",
                      Path.cwd() / "manifest.xml"):
        if candidate.exists():
            m = re.search(r'iq:application\s+id="([^"]+)"', candidate.read_text())
            if m:
                return m.group(1).replace("-", "").lower()
    return None

try:
    from fitparse import FitFile
except ImportError:
    sys.exit("fitparse is required: pip install fitparse")

# Developer fields this app declares, and the message each belongs on.
EXPECTED = {
    "solar_intensity": "record",
    "battery": "record",
    "full_sun": "session",
    "avg_solar": "session",
    "peak_solar": "session",
    "time_in_sun": "session",
    "battery_used": "session",
    "battery_rate": "session",
    "solar_saving": "session",
    "lap_full_sun": "lap",
    "lap_avg_solar": "lap",
}

LAP_FIELDS = ("lap_full_sun", "lap_avg_solar")
SESSION_FIELDS = ("full_sun", "avg_solar", "peak_solar", "time_in_sun",
                  "battery_used", "battery_rate", "solar_saving")


def values(message):
    return {field.name: field.value for field in message.fields}


def main(path):
    fit = FitFile(path)
    fit.parse()

    app_ids, descriptions, laps, sessions, records = [], [], [], [], []
    for message in fit.messages:
        if message.name == "developer_data_id":
            app_ids.append(values(message))
        elif message.name == "field_description":
            descriptions.append(values(message))
        elif message.name == "lap":
            laps.append(values(message))
        elif message.name == "session":
            sessions.append(values(message))
        elif message.name == "record":
            records.append(values(message))

    problems = []

    print("=" * 70)
    print("1. CONNECT IQ APPLICATION ID")
    print("=" * 70)
    if not app_ids:
        print("  none written - no developer data in this file at all")
        problems.append("no developer_data_id message")
    for entry in app_ids:
        raw = entry.get("application_id") or ()
        as_bytes = bytes(raw) if raw else b""
        print(f"  application_id: {as_bytes.hex() or '(empty)'}")
        print(f"  developer_data_index: {entry.get('developer_data_index')}")
        if not any(as_bytes):
            print("  >> ALL ZEROS. Garmin Connect keys developer fields to this id,")
            print("     so it has nothing to attach them to. This is a property of")
            print("     how the app was installed, not of the source: a raw sideload")
            print("     onto GARMIN/APPS can leave it blank. Install through the")
            print("     Connect IQ store (a private beta release works) and retest.")
            problems.append("application_id is all zeros")
        else:
            declared = manifest_uuid()
            if declared is None:
                print("  (no manifest.xml found to compare against)")
            elif as_bytes.hex() == declared:
                print("  matches manifest.xml - this build recorded the activity")
            else:
                print(f"  differs from manifest.xml ({declared}) - EXPECTED for a")
                print("  beta install. Garmin gives a beta app its own store")
                print("  identifier, and that is what the device records here, so")
                print("  this is not evidence of anything on its own. It is only")
                print("  worth chasing if the app was NOT installed as a beta, in")
                print("  which case the watch is running a build this source did")
                print("  not produce.")

    print()
    print("=" * 70)
    print("2. DECLARED DEVELOPER FIELDS")
    print("=" * 70)
    declared = {}
    for entry in descriptions:
        name = entry.get("field_name")
        mesg = entry.get("native_mesg_num")
        declared[name] = mesg
        units = entry.get("units") or ""
        print(f"  {name:18s} on {str(mesg):10s} units={units!r:8s} "
              f"type={entry.get('fit_base_type_id')}")
    for name, mesg in EXPECTED.items():
        if name not in declared:
            print(f"  MISSING: {name} (expected on {mesg})")
            problems.append(f"{name} was never declared")

    print()
    print("=" * 70)
    print("3. LAP FIELDS - every lap must carry its own value")
    print("=" * 70)
    for index, lap in enumerate(laps):
        elapsed = lap.get("total_elapsed_time")
        shown = "  ".join(f"{f}={lap.get(f)}" for f in LAP_FIELDS)
        print(f"  lap {index}: elapsed={elapsed}s  {shown}")
    empty = [i for i, lap in enumerate(laps)
             if all(lap.get(f) is None for f in LAP_FIELDS)]
    if empty:
        print(f"  >> laps with no developer values: {empty}")
        print("     A missing first lap is the signature of setting lap fields")
        print("     inside onTimerLap(); the lap message is already written by")
        print("     then, so each value lands on the following lap.")
        problems.append(f"laps {empty} carry no developer values")

    print()
    print("=" * 70)
    print("4. SESSION SUMMARY")
    print("=" * 70)
    for session in sessions:
        for name in SESSION_FIELDS:
            value = session.get(name)
            flag = "" if value is not None else "   <- missing"
            print(f"  {name:14s} = {value}{flag}")
            if value is None:
                problems.append(f"session.{name} is missing")

    print()
    print("=" * 70)
    print("5. RECORDED SOLAR CHANNEL")
    print("=" * 70)
    solar = [r["solar_intensity"] for r in records if r.get("solar_intensity") is not None]
    battery = [r["battery"] for r in records if r.get("battery") is not None]
    print(f"  records: {len(records)}   with solar: {len(solar)}   with battery: {len(battery)}")
    if solar:
        deltas = [abs(b - a) for a, b in zip(solar, solar[1:])]
        jitter = sum(deltas) / len(deltas) if deltas else 0.0
        big = sum(1 for d in deltas if d > 30) / len(deltas) if deltas else 0.0
        print(f"  mean {sum(solar)/len(solar):.1f}%   peak {max(solar)}%   "
              f"full-sun equivalent {sum(solar)/6000:.2f} min")
        print(f"  second-to-second jitter: {jitter:.1f} points   "
              f"jumps over 30 points: {big:.1%}")
        if jitter > 6.0:
            print("  >> This is the raw sensor. In Connect it plots as a solid band")
            print("     rather than a curve; the field should record a smoothed value.")
            problems.append(f"solar channel jitter is {jitter:.1f} points/s")
    else:
        problems.append("no solar_intensity on any record")
    if not battery:
        print("  >> No battery channel, so Connect can draw no battery curve.")
        problems.append("no battery channel on records")

    print()
    print("=" * 70)
    if problems:
        print(f"{len(problems)} PROBLEM(S)")
        for problem in problems:
            print(f"  - {problem}")
    else:
        print("No problems found: every expected field is present and populated.")
    print("=" * 70)
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
