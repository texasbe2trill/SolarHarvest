import sys, pathlib
page, bg = sys.argv[1], sys.argv[2]
p = pathlib.Path('source/SolarPowerView.mc'); s = p.read_text()
trace = (pathlib.Path(__file__).parent / 'fixtures' / 'solar_trace.txt').read_text()

s = s.replace("    private var _probeTick as Number = 0;", "")
s = s.replace("    private var _manualPage as Number = 0;",
              "    private var _manualPage as Number = 0;\n    private var _pv as Number = 0;")

# replay instead of live stats, fast-forwarded so the long charts fill
old_start = s.index("    function compute(info as Activity.Info) as Void {")
old_end = s.index("    // A lap boundary, however it was triggered.")
s = s[:old_start] + '''    function compute(info as Activity.Info) as Void {
        var t0 = Time.now().value();
        _clockOverride = (t0 - (t0 % 86400)) + 68400;  // mid-afternoon, via the real seam
        _hasSolar = true;
        _model.setLearned(2.0, 5.0);  // stand-in for a converged fit
        _charging = false;
        _daysLeft = 4.2;
        var now = nowSeconds();
        // The walk's real position, so the sun geometry has something true to work
        // from in preview.
        _latRad = 0.5344677444d;
        _lonRad = -1.7081166813d;
        _hasFix = true;
        _heading = 262.0;  // facing west, so the afternoon sun sits off to the left
        var ev = SolarGeometry.sunEvents(now, _latRad, _lonRad);
        if (ev != null) {
            _sunrise = ev[0];
            _sunset = ev[1];
        }
        _uvIndex = 7.0;
        _cloudCover = 35;
        refreshElevation();
        if (!_profileValid) {
            refreshProfile();
        }
        var t = previewTrace();
        // Same per-call workload as the original (220 addSample calls - more
        // than that tripped the simulator's own watchdog, since 900 in one
        // compute() is work no real onUpdate() cycle would ever be asked to do).
        // _pv persists across calls, and the simulator calls compute() once per
        // real second, so this accumulates toward BatteryModel's confirmed-rate
        // gates (600 simulated seconds, 300 apart, 2 edges) over the capture's
        // own wait rather than in one frame.
        for (var k = 0; k < 220; k++) {
            var v = t[_pv % t.size()];
            _pv += 1;
            // A gentle, realistic drain: ~1 point per 3.5 simulated minutes.
            var lvl = (90 - (_pv / 210)).toFloat();
            if (lvl < 78.0) { lvl = 78.0; }
            _model.addSample(v, lvl, false);
        }
        // After the samples, exactly as the real compute() orders it. Run before
        // them, this cached a sky reading taken when the model still had no ticks,
        // and every page that asks "how much of the available light am I getting"
        // fell back to its no-data branch for the whole frame.
        _skyValid = false;
        refreshForecast();
    }

    function previewTrace() as Array<Number> {
        return [
''' + trace + '''
        ] as Array<Number>;
    }

''' + s[old_end:]

s = s.replace('        _pageMode = numberProperty("pageMode", 0, 0, PAGE_COUNT);',
              f'        _pageMode = {int(page)+1};')
# Drive the real theme setting rather than rewriting the palette call. The old
# version patched a line that a later refactor renamed, so it silently stopped
# forcing the background and every "dark" capture was actually light. Assert, so a
# patch that matches nothing fails loudly instead of producing a plausible lie.
if bg != "auto":
    theme = 1 if "BLACK" in bg.upper() or bg == "dark" else 2
    before = s
    s = s.replace('        _theme = numberProperty("theme", 0, 0, 2);',
                  f'        _theme = {theme};')
    assert s != before, "theme override did not apply - has loadSettings changed?"
p.write_text(s)
print(f"patched page={page} bg={bg}")
