"""Preview variant for the recording: real auto-cycling across every page, with
the walk trace replayed underneath so the charts have something true in them."""
import pathlib
p = pathlib.Path('source/SolarPowerView.mc'); s = p.read_text()
trace = (pathlib.Path(__file__).parent / 'fixtures' / 'solar_trace.txt').read_text()

s = s.replace("    private var _manualPage as Number = 0;",
              "    private var _manualPage as Number = 0;\n    private var _pv as Number = 0;")

start = s.index("    function compute(info as Activity.Info) as Void {")
end = s.index("    function onTimerStop() as Void {")
s = s[:start] + '''    function compute(info as Activity.Info) as Void {
        _hasSolar = true;
        _charging = false;
        _daysLeft = 4.2;
        var now = Time.now().value();
        _sunrise = now - 18000;
        _sunset = now + 7400;
        _latRad = 0.5344677444d;
        _lonRad = -1.7081166813d;
        _hasFix = true;
        _uvIndex = 7.0;
        _cloudCover = 35;
        var t = previewTrace();
        // Seed fast on the first tick so the charts are populated, then run at
        // roughly real speed so the recording shows genuine second-by-second life.
        var batch = (_pv < 2600) ? 220 : 2;
        for (var k = 0; k < batch; k++) {
            var v = t[_pv % t.size()];
            _pv += 1;
            _model.addSample(v, (78 - (_pv / 900)).toFloat(), false);
        }
        _elevTick = 0;
        refreshElevation();
        if (!_profileValid) {
            refreshProfile();
        }
        _skyValid = false;
        _forecastValid = false;
    }

    function previewTrace() as Array<Number> {
        return [
''' + trace + '''
        ] as Array<Number>;
    }

''' + s[end:]

# auto-cycle every 4s so a short recording covers all five pages
s = s.replace('        _pageMode = numberProperty("pageMode", 0, 0, PAGE_COUNT);', '        _pageMode = 0;')
s = s.replace('        _cycleSeconds = numberProperty("cycleSeconds", 8, 3, 60);', '        _cycleSeconds = 4;')
s = s.replace("        _palette.apply(getBackgroundColor());", "        _palette.apply(Graphics.COLOR_BLACK);")
p.write_text(s)
print("patched for recording")
