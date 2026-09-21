#!/usr/bin/env python3
"""Films the field for the animated store art: a replayed walk, the seven pages in turn, one
simulator capture after another. tools/build_gifs.py turns the captures into the GIFs.

    python3 tools/film.py hero  fenix9prosolar51mm 16
    python3 tools/film.py cover fenix7s 8

    NAME       the captures go to $SOLAR_WORK/film_NAME
    DEVICE     a Connect IQ device id
    PER_PAGE   steps of the film each page stays up (two minutes of the walk to a step)
    THEME      dark (the default) or light

Requires:
    CIQ_SDK_BIN         path to your Connect IQ SDK's bin/ directory
    CIQ_DEVELOPER_KEY   path to your signing key. It is read where it is and never copied
    SOLAR_WORK          scratch directory (defaults to /tmp/solar-harvest-work)
    macOS + pyobjc (`pip install pyobjc-framework-Quartz`) for window capture.

The project itself is never touched: the film build is made from a copy in $SOLAR_WORK, with
compute() replaced by a replay of tools/fixtures/solar_trace.txt (the same walk the previews
use). What the copy changes, and why:

  - Light comes from the trace, 120 seconds of it to a step. Ten larger batches run first, so
    the charts are full when the film starts.
  - The battery is a sample one that behaves like a solar watch: it drains 5 percent an hour in
    the dark and 3 in full sun, reported in steps of a tenth of a percent. The field is not told
    that. Its own fit has to find the saving, which is what the SUN BONUS page then shows.
  - The clock starts late in the morning and moves with the film, so the sun, the time to
    sunset and the compass all move too.
  - The page follows the film: PER_PAGE steps each, in the field's own order.
  - Every compute() prints the step it is on, and every capture is named for the step the field
    had reached (f_NNNN_sNNNN.png), so the builder can take the last shot of each step.
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOLD = 2          # computes to a step of the film, so a capture a second cannot miss one
PAGES = 7


def need(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit('Set %s (see the top of tools/film.py)' % name)
    return value


def project(work, per_page, theme):
    d = work / 'film_project'
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    for name in ('source', 'resources', 'manifest.xml', 'monkey.jungle'):
        src = ROOT / name
        (shutil.copytree if src.is_dir() else shutil.copy)(src, d / name)
    for extra in ROOT.glob('resources-*'):
        shutil.copytree(extra, d / extra.name)
    p = d / 'source' / 'SolarPowerView.mc'
    s = p.read_text(encoding='utf-8')
    trace = (ROOT / 'tools' / 'fixtures' / 'solar_trace.txt').read_text()
    s = s.replace("    private var _probeTick as Number = 0;", "")
    anchor = "    private var _manualPage as Number = 0;"
    assert s.count(anchor) == 1, 'the page field moved: update tools/film.py'
    s = s.replace(anchor, anchor + "\n    private var _pv as Number = 0;\n    private var _tick as Number = 0;"
                  "\n    private var _film as Number = 0;\n    private var _cell as Float = 88.0;")
    start = s.index("    function compute(info as Activity.Info) as Void {")
    end = s.index("    // A lap boundary, however it was triggered.")
    s = s[:start] + '''    function compute(info as Activity.Info) as Void {
        _tick += 1;
        var warm = _tick <= 10;                     // the charts fill before the film starts
        if (!warm && (_tick %% %(hold)d) == 0) {
            _film += 1;
        }
        var t0 = Time.now().value();
        // From late morning on, two minutes of the walk to a step of the film.
        _clockOverride = (t0 - (t0 %% 86400)) + 61200 + (_film * 120);
        _hasSolar = true;
        _charging = false;
        _daysLeft = 4.2;
        var now = nowSeconds();
        _latRad = 0.5344677444d;
        _lonRad = -1.7081166813d;
        _hasFix = true;
        _heading = 262.0;
        var ev = SolarGeometry.sunEvents(now, _latRad, _lonRad);
        if (ev != null) {
            _sunrise = ev[0];
            _sunset = ev[1];
            refreshSunTexts();
        }
        _uvIndex = 7.0;
        _cloudCover = 35;
        refreshElevation();
        if (!_profileValid) {
            refreshProfile();
        }
        var t = previewTrace();
        var batch = warm ? 220 : (((_tick %% %(hold)d) == 0) ? 120 : 0);
        for (var k = 0; k < batch; k++) {
            var v = t[_pv %% t.size()];
            _pv += 1;
            // A sample battery that behaves like a solar watch: 5 percent an hour in the dark,
            // 3 in full sun, reported in tenths. The field has to find that saving itself.
            _cell -= (5.0 - (2.0 * v / 100.0)) / 3600.0;
            if (_cell < 20.0) { _cell = 20.0; }
            var lvl = Math.floor(_cell * 10.0) / 10.0;
            _model.addSample(v, lvl.toFloat(), false);
        }
        _skyValid = false;
        refreshForecast();
        System.println("FILM " + _film.format("%%d"));
    }

    function previewTrace() as Array<Number> {
        return [
''' % {'hold': HOLD} + trace + '''
        ] as Array<Number>;
    }

''' + s[end:]
    old = "    private function currentPage(mask as Number) as Number {\n"
    assert s.count(old) == 1, 'currentPage moved: update tools/film.py'
    s = s.replace(old, old + "        if (true) { return resolvePage((_film / %d) %% PAGE_COUNT, mask, PAGE_COUNT); }\n" % per_page)
    old = '        _theme = numberProperty("theme", 0, 0, 2);'
    assert s.count(old) == 1, 'the theme setting moved: update tools/film.py'
    s = s.replace(old, '        _theme = %d;' % (2 if theme == 'light' else 1))
    p.write_text(s, encoding='utf-8')
    return d


def window():
    import Quartz
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements, Quartz.kCGNullWindowID):
        if 'Connect IQ Device Sim' in w.get('kCGWindowOwnerName', ''):
            return w.get('kCGWindowNumber')
    return None


def stop():
    subprocess.run(['pkill', '-f', '[m]onkeydo'])
    subprocess.run(['pkill', '-f', 'ConnectIQ.app/Contents/MacOS/[s]imulator'])


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    sdk = pathlib.Path(need('CIQ_SDK_BIN'))
    key = need('CIQ_DEVELOPER_KEY')
    work = pathlib.Path(os.environ.get('SOLAR_WORK', '/tmp/solar-harvest-work'))
    name, dev, per_page = sys.argv[1], sys.argv[2], int(sys.argv[3])
    theme = sys.argv[4] if len(sys.argv) > 4 else 'dark'
    work.mkdir(parents=True, exist_ok=True)
    d = project(work, per_page, theme)
    prg = work / ('film-%s.prg' % dev)
    r = subprocess.run([str(sdk / 'monkeyc'), '-f', str(d / 'monkey.jungle'), '-o', str(prg), '-y', key, '-d', dev, '-w'],
                       capture_output=True, text=True)
    errors = [line for line in (r.stdout + r.stderr).splitlines() if line.startswith('ERROR')]
    if errors or not prg.exists():
        raise SystemExit('\n'.join(errors[:6]) or 'the film build failed')
    out = work / ('film_' + name)
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob('f_*.png'):
        old.unlink()
    stop()
    time.sleep(3)
    subprocess.Popen([str(sdk / 'connectiq')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(8)
    logpath = out / 'film.log'
    log = open(logpath, 'w')
    subprocess.Popen([str(sdk / 'monkeydo'), str(prg), dev], stdout=log, stderr=log)
    time.sleep(16)
    wid = window()
    if wid is None:
        stop()
        raise SystemExit('the simulator window was not found')
    steps = per_page * PAGES
    t0, n = time.time(), 0
    while True:
        seen = re.findall(r'FILM (\d+)', logpath.read_text(errors='replace'))
        step = int(seen[-1]) if seen else 0
        if step >= steps + 2 or time.time() - t0 > steps * HOLD * 1.6 + 30:
            break
        subprocess.run(['screencapture', '-x', '-o', '-l%d' % wid, str(out / ('f_%04d_s%04d.png' % (n, step)))])
        n += 1
        time.sleep(0.35)
    log.close()
    stop()
    text = logpath.read_text(errors='replace')
    bad = [line for line in text.splitlines() if re.search('error|exception', line, re.I)]
    print('%s: %d shots, %d steps of the film, %d error lines %s' % (out, n, len(set(re.findall(r'FILM (\d+)', text))), len(bad), bad[:2]))
    if bad:
        sys.exit(1)


if __name__ == '__main__':
    main()
