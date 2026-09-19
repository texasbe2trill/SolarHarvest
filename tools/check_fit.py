#!/usr/bin/env python3
"""Check what Solar Harvest actually wrote into an activity .FIT file.

Run this on a FIT downloaded from the watch after an activity. It separates
recording faults from fields that were simply not measured on that activity,
and reports, in order:

  1. The Connect IQ application id. All zeros means Garmin Connect has nothing
     to attach the fields to. An app installed from the Connect IQ Store records
     the id the store issued, not the one in manifest.xml; only a build loaded
     straight onto the watch records the manifest id.
  2. Every developer field declared, and where Garmin Connect shows it
     (activity summary, charts or laps), read from fitContributions.xml.
  3. Whether every lap carries its own values.
  4. The session summary. Five values are written on every activity. Battery
     rate, runtime left and solar saving are only written once the watch has
     measured them, so for those the tool replays the app's own rules over the
     recorded battery channel to work out whether they should be there.
  5. The per-second channels, including whether catching and sun elevation
     should be present: both need a GPS fix, and catching needs the sun at
     least 15 degrees up.

Only real faults are listed as problems and give a non-zero exit code. Fields
that were not measured are listed separately, with the reason.

Usage:  python3 tools/check_fit.py ACTIVITY.fit
Needs:  pip install fitparse

Given several FIT files it reports each and then pools the days gauge's fit
across them the way the watch does, and says how many more such activities
the watch's gate needs.
"""

import re
import sys
from pathlib import Path

try:
    from fitparse import FitFile
except ImportError:
    sys.exit("fitparse is required: pip install fitparse")

ROOT = Path(__file__).resolve().parent.parent

# The id the Connect IQ Store issued to the published listing:
# https://apps.garmin.com/en-US/apps/b0d0fd86-bc11-4d9a-9f78-40db5c7b7fa0
STORE_APP_ID = "b0d0fd86bc114d9a9f7840db5c7b7fa0"

# Used only when the tool runs outside the repo. Inside it, each of these is
# read from the source it mirrors, so the tool cannot drift from the app.
FALLBACK_FIELDS = {  # name: (field id, message)
    "solar_intensity": (0, "record"),
    "full_sun": (1, "session"),
    "lap_full_sun": (2, "lap"),
    "battery": (3, "record"),
    "avg_solar": (4, "session"),
    "peak_solar": (5, "session"),
    "time_in_sun": (6, "session"),
    "battery_used": (7, "session"),
    "battery_rate": (8, "session"),
    "solar_saving": (9, "session"),
    "lap_avg_solar": (10, "lap"),
    "catching_percent": (11, "record"),
    "sun_elevation": (12, "record"),
    "projected_hours": (13, "session"),
    "battery_days": (14, "record"),
    "life_spent": (15, "session"),
    "lap_life_spent": (16, "lap"),
    "full_sun_so_far": (17, "record"),
    "sun_saving_fine": (18, "session"),
}
FALLBACK_GATES = {  # source/BatteryModel.mc and source/SolarGeometry.mc
    "DEBOUNCE": 10,
    "MIN_EDGES": 2,
    "MIN_SECONDS": 600,
    "MIN_SPAN_SECONDS": 300,
    "REG_MIN_INTERVALS": 12,
    "REG_MIN_SPREAD": 25.0,
    "MIN_USEFUL_ELEVATION": 15.0,
}

ALWAYS_SESSION = ("full_sun", "avg_solar", "peak_solar", "time_in_sun", "battery_used")
MEASURED_SESSION = ("battery_rate", "projected_hours", "solar_saving")
LAP_FIELDS = ("lap_full_sun", "lap_avg_solar")
# The days gauge, on the dev branch only: the gauge itself, what it says the
# activity and each lap spent, the harvest curve, and the fit on the gauge.
EXPERIMENT_FIELDS = ("battery_days", "life_spent", "lap_life_spent", "full_sun_so_far", "sun_saving_fine")
FINE_WINDOW = 300          # source/BatteryModel.mc FINE_WINDOW
TIMER_STOPS = ("stop", "stop_all", "stop_disable", "stop_disable_all")

# The watch fits solar saving against the raw sensor, but the file only holds
# the smoothed value, so the replay's answer is approximate. It only calls a
# missing solar saving a fault when the replayed result is clear of the app's
# 0.05 %/h threshold by this much.
SAVING_MARGIN = 0.5


def read(relative):
    path = ROOT / relative
    return path.read_text() if path.exists() else None


def manifest_uuid():
    """The app id this repo builds, as lowercase hex with no dashes."""
    text = read("manifest.xml")
    match = re.search(r'iq:application\s+id="([^"]+)"', text) if text else None
    return match.group(1).replace("-", "").lower() if match else None


def expected_fields():
    """Field name -> (field id, message type), from FitRecorder.mc."""
    text = read("source/FitRecorder.mc")
    if not text:
        return FALLBACK_FIELDS
    ids = {name: int(value) for name, value in re.findall(r"static const (ID_\w+) = (\d+);", text)}
    found = {}
    for name, const, mesg in re.findall(
            r'make\(field,\s*"(\w+)",\s*(ID_\w+),\s*FitContributor\.DATA_TYPE_\w+,\s*'
            r"FitContributor\.MESG_TYPE_(\w+)", text):
        found[name] = (ids[const], mesg.lower())
    return found or FALLBACK_FIELDS


def connect_display():
    """Field id -> where Garmin Connect shows it, from fitContributions.xml."""
    text = read("resources/fitContributions/fitContributions.xml")
    if not text:
        return None
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    places = {}
    for body in re.findall(r"<fitField\b(.*?)/?>", text, flags=re.S):
        attrs = dict(re.findall(r'(\w+)="([^"]*)"', body))
        places[int(attrs["id"])] = [
            label for key, label in (("displayInActivitySummary", "summary"),
                                     ("displayInChart", "chart"),
                                     ("displayInActivityLaps", "laps"))
            if attrs.get(key) == "true"]
    return places


def gates():
    """The thresholds the app measures against, from its own source."""
    values = dict(FALLBACK_GATES)
    for relative in ("source/BatteryModel.mc", "source/SolarGeometry.mc"):
        text = read(relative)
        if not text:
            continue
        for name, number in re.findall(r"(?:static )?const (\w+) = ([\d.]+);", text):
            if name in values:
                values[name] = float(number) if "." in number else int(number)
    return values


def values(message):
    return {field.name: field.value for field in message.fields}


def active_clock(events, records):
    """Returns a function giving timer-running seconds at a moment.

    The app's gates count active seconds, so a stop in the middle of an
    activity must not be counted as time spent measuring.
    """
    spans, started = [], None
    for event in events:
        if event.get("event") != "timer" or event.get("timestamp") is None:
            continue
        if event.get("event_type") == "start" and started is None:
            started = event["timestamp"]
        elif event.get("event_type") in TIMER_STOPS and started is not None:
            spans.append((started, event["timestamp"]))
            started = None
    if records and started is not None:
        spans.append((started, records[-1]["timestamp"]))
    if records and not spans:
        spans = [(records[0]["timestamp"], records[-1]["timestamp"])]

    def at(moment):
        return sum(max(0.0, (min(end, moment) - begin).total_seconds())
                   for begin, end in spans if begin <= moment)
    return at


def replay_battery(records, at, g):
    """The battery transitions the app would have accepted, as
    (active seconds, level, mean solar since the previous transition).

    Mirrors BatteryModel.addSampleWhen: a new level only counts once it has held
    for DEBOUNCE samples, and is dated to when it was first seen. The recorded
    battery is the level rounded to a whole percent, which is the resolution
    the supported watches report.
    """
    edges = []
    stable, run_length, run_dir, run_start, run_level = None, 0, 0, None, None
    solar_sum, solar_count = 0.0, 0
    for record in records:
        level = record.get("battery")
        if level is None:
            continue
        if stable is None:
            stable = level
            continue
        if record.get("solar_intensity") is not None:
            solar_sum += record["solar_intensity"]
            solar_count += 1
        diff = level - stable
        if diff == 0:
            if run_length > 0:
                run_length -= 1
            continue
        direction = 1 if diff > 0 else -1
        if run_length == 0 or direction != run_dir:
            run_dir, run_length = direction, 1
            run_start, run_level = at(record["timestamp"]), level
        else:
            run_length += 1
        if run_length < g["DEBOUNCE"]:
            continue
        edges.append((run_start, run_level, solar_sum / solar_count if solar_count else 0.0))
        stable, run_length = run_level, 0
        solar_sum, solar_count = 0.0, 0
    return edges


def expected_measurements(edges, active_total, g):
    """What the app would have written, given the replayed transitions.

    Returns (rate written, runtime written, best solar saving or None,
    intervals, light spread across them).
    """
    rate = runtime = False
    if len(edges) >= g["MIN_EDGES"]:
        first_t, first_level, _ = edges[0]
        for k in range(1, len(edges)):
            t, level, _ = edges[k]
            # The rate from this transition stands until the next one arrives.
            until = edges[k + 1][0] if k + 1 < len(edges) else active_total
            if t - first_t < g["MIN_SPAN_SECONDS"] or max(t, g["MIN_SECONDS"]) > until:
                continue
            rate = True
            if first_level - level > 0:
                runtime = True

    intervals = [(x, (prev_level - level) * 3600.0 / (t - prev_t))
                 for (prev_t, prev_level, _), (t, level, x) in zip(edges, edges[1:])
                 if t > prev_t]
    spread = (max(x for x, _ in intervals) - min(x for x, _ in intervals)) if intervals else 0.0
    best = None
    for n in range(g["REG_MIN_INTERVALS"], len(intervals) + 1):
        xs = [x for x, _ in intervals[:n]]
        ys = [y for _, y in intervals[:n]]
        if max(xs) - min(xs) < g["REG_MIN_SPREAD"]:
            continue
        mean_x, mean_y = sum(xs) / n, sum(ys) / n
        cxx = sum((x - mean_x) ** 2 for x in xs)
        if cxx < 1e-6:
            continue
        cxy = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
        saving = -(cxy / cxx) * 100.0
        best = saving if best is None else max(best, saving)
    return rate, runtime, best, len(intervals), spread


def fine_windows(records, at):
    """The days gauge fitted the way the watch fits it: windows of FINE_WINDOW
    active seconds, each the minutes of life spent an hour against the mean
    light, from the recorded battery_days and solar_intensity. Returns
    [(mean light, minutes of life an hour)]. The watch's own windows also end
    at pauses; here a window simply spans the active clock."""
    rows = [(at(r["timestamp"]), r["solar_intensity"], r["battery_days"]) for r in records
            if r.get("battery_days") is not None and r.get("solar_intensity") is not None]
    windows = []
    start = None
    for t, light, days in rows:
        if start is None:
            start = (t, days)
            lights = []
            continue
        lights.append(light)
        span = t - start[0]
        if span >= FINE_WINDOW:
            windows.append((sum(lights) / len(lights), (start[1] - days) * 1440.0 * 3600.0 / span))
            start = (t, days)
            lights = []
    return windows


def fine_fit(windows):
    """Slope of life spent against light, as minutes of life an hour of full
    sun saves, with its standard error and t: (saving, se, t, dof, spread, sums).
    sums are the within-activity co-deviations (cxx, cxy, cyy) for pooling."""
    n = len(windows)
    if n < 3:
        return None
    mx = sum(x for x, _ in windows) / n
    my = sum(y for _, y in windows) / n
    cxx = sum((x - mx) ** 2 for x, _ in windows)
    cxy = sum((x - mx) * (y - my) for x, y in windows)
    cyy = sum((y - my) ** 2 for _, y in windows)
    if cxx < 1e-6:
        return None
    slope = cxy / cxx
    resid = max(0.0, cyy - cxy * cxy / cxx)
    dof = n - 2
    se = (resid / dof / cxx) ** 0.5 if dof > 0 else float("inf")
    saving = -slope * 100.0
    t = (saving / (se * 100.0)) if se > 0 else float("inf")
    spread = max(x for x, _ in windows) - min(x for x, _ in windows)
    return saving, se * 100.0, t, n - 1, spread, (cxx, cxy, cyy)


def gauge_report(records, at):
    """The dev branch's days gauge: does it move between the whole percent
    steps, what did it say the activity spent, and what does its fit say
    about the sun? Says nothing when the file holds no gauge. Returns the
    activity's windows for pooling across files, or None."""
    pairs = [(r.get("battery"), r["battery_days"]) for r in records if r.get("battery_days") is not None]
    if not pairs:
        return None
    heading("THE DAYS GAUGE (dev branch)")
    readings = [value for _, value in pairs]
    changes = [abs(b - a) for a, b in zip(readings, readings[1:]) if b != a]
    between = sum(1 for (la, a), (lb, b) in zip(pairs, pairs[1:]) if b != a and la == lb)
    steps = sum(1 for (la, _), (lb, _) in zip(pairs, pairs[1:]) if la != lb)
    print(f"  battery_days: {len(readings)} readings, {min(readings):.4f} to {max(readings):.4f} days, "
          f"{len(set(readings))} distinct values")
    if changes:
        print(f"    changed {len(changes)} times, smallest change {min(changes):.4f} days "
              f"({min(changes) * 1440:.1f} min of life); {between} between whole percent steps "
              f"({steps} steps in the file)")
        print(f"    life spent by the gauge: {(readings[0] - readings[-1]) * 1440:.1f} min")
    else:
        print("    never changed")
    windows = fine_windows(records, at)
    fit = fine_fit(windows)
    print(f"  fit on the gauge: {len(windows)} window(s) of {FINE_WINDOW // 60} active minutes")
    if fit is None:
        print("    too few windows, or no spread of light, to fit")
    else:
        saving, se, t, dof, spread, _ = fit
        print(f"    full sun saves {saving:+.1f} min of life an hour, se {se:.1f}, t {t:.1f}, "
              f"light spread {spread:.0f} points")
        if abs(t) >= 3 and saving > 0:
            print("    >> the gauge follows the light on this activity alone")
        else:
            print("    not clear on one activity (the watch needs t >= 3 across activities)")
    return windows


def pooled_report(per_file):
    """The fixed-effects pool the watch keeps, across every file given: each
    activity's windows measured against its own means, then summed."""
    heading(f"THE DAYS GAUGE POOLED OVER {len(per_file)} ACTIVITIES")
    cxx = cxy = cyy = 0.0
    dof = 0
    for windows in per_file:
        fit = fine_fit(windows)
        if fit is None:
            continue
        _, _, _, d, _, (a, b, c) = fit
        cxx += a
        cxy += b
        cyy += c
        dof += d
    if cxx < 1e-6 or dof < 2:
        print("  nothing to pool yet")
        return
    slope = cxy / cxx
    resid = max(0.0, cyy - cxy * cxy / cxx)
    se = (resid / (dof - 1) / cxx) ** 0.5
    saving = -slope * 100.0
    t = saving / (se * 100.0) if se > 0 else float("inf")
    print(f"  full sun saves {saving:+.1f} min of life an hour, se {se * 100:.1f}, t {t:.1f}, "
          f"{dof} degrees of freedom")
    if t >= 3 and saving > 0:
        print("  >> PASSES THE WATCH'S GATE: the gauge is a real reading and the bonus would show")
    else:
        need = (3.0 / t) ** 2 * len(per_file) if t > 0 else float("inf")
        print(f"  not yet: at this rate about {need:.0f} activities like these reach t = 3"
              if need != float("inf") else "  not yet: no benefit from the sun in these files")


def heading(title):
    print()
    print("=" * 70)
    print(title)
    print("=" * 70)


def main(path):
    fit = FitFile(path)
    fit.parse()

    app_ids, descriptions, laps, sessions, records, events = [], [], [], [], [], []
    for message in fit.messages:
        bucket = {"developer_data_id": app_ids, "field_description": descriptions,
                  "lap": laps, "session": sessions, "record": records,
                  "event": events}.get(message.name)
        if bucket is not None:
            bucket.append(values(message))

    g = gates()
    fields = expected_fields()
    display = connect_display()
    problems, not_measured = [], []

    heading("1. CONNECT IQ APPLICATION ID")
    if not app_ids:
        print("  none written - no developer data in this file at all")
        problems.append("no developer_data_id message")
    for entry in app_ids:
        raw = entry.get("application_id") or ()
        as_hex = bytes(raw).hex() if raw else ""
        print(f"  application_id: {as_hex or '(empty)'}   "
              f"application_version: {entry.get('application_version')}")
        if not raw or not any(raw):
            print("  >> ALL ZEROS. Garmin Connect keys developer fields to this id,")
            print("     so it has nothing to attach them to. A raw sideload onto")
            print("     GARMIN/APPS can leave it blank; install through the store.")
            problems.append("application_id is all zeros")
        elif as_hex == STORE_APP_ID:
            print("  the Connect IQ Store listing: this is a store install")
        elif as_hex == manifest_uuid():
            print("  matches manifest.xml: a build loaded directly onto the watch")
        else:
            print("  neither the store listing nor manifest.xml. Expected for a")
            print("  private beta, which the store gives its own id. Otherwise the")
            print("  watch is running a build this source did not produce.")

    heading("2. DECLARED DEVELOPER FIELDS (and where Garmin Connect shows them)")
    declared = {}
    for entry in descriptions:
        name = entry.get("field_name")
        field_id = entry.get("field_definition_number")
        mesg = entry.get("native_mesg_num")
        declared[name] = (field_id, mesg)
        where = "?"
        if display is not None:
            where = ", ".join(display.get(field_id, [])) or "NOT SHOWN"
        print(f"  {name:18s} id {str(field_id):>2s}  on {str(mesg):8s} "
              f"units={entry.get('units') or ''!r:7s} connect: {where}")
        if name in fields and fields[name][0] != field_id:
            problems.append(f"{name} was written with id {field_id}, but the app "
                            f"defines it as {fields[name][0]}; Connect matches by id")
        if display is not None and not display.get(field_id):
            problems.append(f"{name} (id {field_id}) has no fitContributions entry "
                            f"with a display flag, so Connect will never show it")
    for name, (field_id, mesg) in fields.items():
        if name not in declared:
            if name in EXPERIMENT_FIELDS:
                # Only a build of the experiment branch writes these.
                not_measured.append(f"{name}: recorded only by the battery gauge experiment build")
                continue
            print(f"  MISSING: {name} (id {field_id}, expected on {mesg})")
            problems.append(f"{name} was never declared")

    heading("3. LAP FIELDS - every lap must carry its own value")
    for index, lap in enumerate(laps):
        shown = "  ".join(f"{f}={lap.get(f)}" for f in LAP_FIELDS)
        if lap.get("lap_life_spent") is not None:
            shown += f"  lap_life_spent={lap['lap_life_spent']:.1f} min"
        print(f"  lap {index}: elapsed={lap.get('total_elapsed_time')}s  {shown}")
    empty = [i for i, lap in enumerate(laps) if all(lap.get(f) is None for f in LAP_FIELDS)]
    if empty:
        print(f"  >> laps with no developer values: {empty}")
        print("     A missing first lap is the signature of setting lap fields")
        print("     after the lap message has already been written.")
        problems.append(f"laps {empty} carry no developer values")

    at = active_clock(events, records)
    active_total = at(records[-1]["timestamp"]) if records else 0.0
    edges = replay_battery(records, at, g)
    rate, runtime, saving, intervals, spread = expected_measurements(edges, active_total, g)

    heading("4. SESSION SUMMARY")
    if not sessions:
        problems.append("no session message")
    for session in sessions:
        print("  written on every activity:")
        for name in ALWAYS_SESSION:
            value = session.get(name)
            print(f"    {name:16s} = {value}{'   <- MISSING' if value is None else ''}")
            if value is None:
                problems.append(f"session.{name} is missing")

        print("  written once measured:")
        levels = " -> ".join(str(level) for _, level, _ in edges) or "no change"
        print(f"    replay: {len(edges)} battery step(s) in {active_total / 60:.0f} "
              f"active minutes ({levels})")
        checks = (
            ("battery_rate", rate,
             f"{len(edges)} battery step(s); the rate needs {g['MIN_EDGES']} steps at least "
             f"{g['MIN_SPAN_SECONDS'] // 60} minutes apart, after {g['MIN_SECONDS'] // 60} "
             f"active minutes"),
            ("projected_hours", runtime,
             "needs a measured drain; the battery rate was not measured"
             if not rate else "the battery held or gained, so there was no drain to project"),
            ("solar_saving", saving is not None and saving > SAVING_MARGIN,
             f"{intervals} gap(s) between battery steps; needs {g['REG_MIN_INTERVALS']} "
             f"with average light differing by at least {g['REG_MIN_SPREAD']:.0f} points"
             if intervals < g["REG_MIN_INTERVALS"] or spread < g["REG_MIN_SPREAD"]
             else "the fit found no clear benefit from the sun on this activity"),
        )
        for name, expected, reason in checks:
            value = session.get(name)
            if value is not None:
                note = "" if expected else \
                    "   (present though the replay did not predict it; the file is coarser than the watch)"
                print(f"    {name:16s} = {value}{note}")
            elif expected:
                print(f"    {name:16s} = None   <- MISSING")
                problems.append(f"session.{name} is missing although the recorded "
                                f"battery says it was measured")
            else:
                print(f"    {name:16s} = None   (not measured: {reason})")
                not_measured.append(f"{name}: {reason}")

    heading("5. RECORDED CHANNELS")
    solar = [r["solar_intensity"] for r in records if r.get("solar_intensity") is not None]
    battery = [r["battery"] for r in records if r.get("battery") is not None]
    elevation = [r["sun_elevation"] for r in records if r.get("sun_elevation") is not None]
    catching = sum(1 for r in records if r.get("catching_percent") is not None)
    positions = sum(1 for r in records if r.get("position_lat") is not None)
    print(f"  records: {len(records)}   solar: {len(solar)}   battery: {len(battery)}   "
          f"sun elevation: {len(elevation)}   catching: {catching}   gps: {positions}")
    if solar:
        deltas = [abs(b - a) for a, b in zip(solar, solar[1:])]
        jitter = sum(deltas) / len(deltas) if deltas else 0.0
        print(f"  solar mean {sum(solar) / len(solar):.1f}%   peak {max(solar)}%   "
              f"full-sun equivalent {sum(solar) / 6000:.2f} min   jitter {jitter:.1f} points/s")
        if jitter > 6.0:
            print("  >> This is the raw sensor. In Connect it plots as a solid band")
            print("     rather than a curve; the field should record a smoothed value.")
            problems.append(f"solar channel jitter is {jitter:.1f} points/s")
    else:
        problems.append("no solar_intensity on any record")
    if not battery:
        problems.append("no battery channel on records")

    minimum = g["MIN_USEFUL_ELEVATION"]
    if elevation:
        print(f"  sun elevation {min(elevation)} to {max(elevation)} degrees")
    elif positions:
        problems.append("GPS positions were recorded but sun_elevation never was")
    else:
        not_measured.append("sun_elevation: no GPS fix on this activity")
        not_measured.append("catching_percent: needs a GPS fix")
    if elevation and not catching:
        # The recorded elevation is rounded, so a reading of 15 may have been
        # 14.5 on the watch. Only a reading a full degree clear is conclusive.
        if max(elevation) >= minimum + 1:
            problems.append(f"the sun reached {max(elevation)} degrees but "
                            f"catching_percent was never written")
        else:
            not_measured.append(f"catching_percent: the sun stayed at or below "
                                f"{max(elevation)} degrees; catching needs {minimum:.0f}")

    windows = gauge_report(records, at)

    heading("RESULT")
    if problems:
        print(f"  {len(problems)} PROBLEM(S)")
        for problem in problems:
            print(f"    - {problem}")
    else:
        print("  No recording problems found.")
    if not_measured:
        print("  Not measured on this activity (expected, not faults):")
        for item in not_measured:
            print(f"    - {item}")
    print("=" * 70)
    return (1 if problems else 0), windows


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    worst = 0
    pooled = []
    for path in sys.argv[1:]:
        if len(sys.argv) > 2:
            print()
            print("#" * 70)
            print(f"# {path}")
            print("#" * 70)
        code, windows = main(path)
        worst = max(worst, code)
        if windows:
            pooled.append(windows)
    if len(sys.argv) > 2:
        pooled_report(pooled)
    sys.exit(worst)
