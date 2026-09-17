import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Weather;
import Toybox.WatchUi;

const DEGREE = "\u00B0";

// Test seam. With no activity attached, createField() fails as a system error
// rather than a catchable exception, so a unit test cannot construct a view that
// records FIT data. The render tests set this to exercise the drawing layer; it is
// never touched in normal operation.
var gSkipFitRecording as Boolean = false;

// Solar Harvest: live intensity, harvest integral, measured battery behaviour and
// the real daylight window. Every optional API is feature-detected so the field
// degrades gracefully instead of crashing an activity.
class SolarPowerView extends WatchUi.DataField {

    static const CAL_KEY = "calibration";
    static const CAL_PENDING_KEY = "calibrationPending";
    static const CAL_VERSION = 1;
    // Where the first release kept what it had learned.
    static const LEGACY_SAVING_KEY = "learnedSaving";
    static const LEGACY_DRAIN_KEY = "learnedDrain";

    private const PAGE_NOW = 0;
    private const PAGE_HARVEST = 1;
    private const PAGE_BATTERY = 2;
    private const PAGE_WINDOW = 3;
    private const PAGE_SKY = 4;
    private const PAGE_BONUS = 5;
    private const PAGE_COMPASS = 6;
    private const PAGE_COUNT = 7;

    // Above this the sun is close enough to overhead that its bearing, while
    // perfectly real, is useless: it sweeps degrees per second and points at
    // nothing a walker could act on. The page says OVERHEAD instead.
    private const ZENITH_DEGREES = 80.0;

    private const SAMPLE_PERIOD = 5;
    private const LABEL_GAP = 4;  // between a chip's name and its number
    private const CHIP_GAP = 6; // clear separation without stealing room from either chip
    private const SUNSET_REFRESH = 120;    // seconds between sun lookups
    private const ELEVATION_REFRESH = 30;  // the sun moves a quarter degree a minute
    private const PROFILE_POINTS = 32;  // samples across the daylight arc

    private var _model as SolarModel;
    private var _palette as Palette;
    private var _layout as LayoutPlanner;
    private var _safe as SafeArea;
    private var _valueFonts as Array<FontDefinition>;

    private var _hasSolar as Boolean = true;
    private var _round as Boolean = false;
    private var _fullScreen as Boolean = false;
    private var _flags as Number = -1;
    private var _screenW as Number = 0;
    private var _screenH as Number = 0;

    private var _sunrise as Number = -1;
    private var _sunset as Number = -1;
    private var _sunTick as Number = 0;
    private var _charging as Boolean = false;
    // Whether the activity timer was running at the last compute().
    private var _recording as Boolean = true;
    private var _daysLeft as Float = -1.0;

    // Sun geometry and weather. Both are refreshed on the slow tick: the sun
    // moves a quarter of a degree a minute and cached weather changes far slower
    // than that, so recomputing either every second would be wasted work.
    private var _latRad as Double = 0.0d;
    private var _lonRad as Double = 0.0d;
    private var _hasFix as Boolean = false;
    private var _elevation as Float = -99.0;
    private var _rising as Boolean = false;
    private var _azimuth as Float = -1.0;
    private var _heading as Float = -1.0;  // degrees from north, -1 when unknown
    private var _clockOverride as Number = 0;
    private var _alerts as AlertEngine;
    private var _alertsOn as Boolean = true;
    private var _uvIndex as Float = -1.0;
    private var _cloudCover as Number = -1;
    // Elevation profile across the daylight window, cached for the chart.
    private var _profile as Array<Number>;
    private var _azProfile as Array<Number>;  // the sun's bearing at each profile point
    // The same bearings walked sequentially so the series is continuous: a day
    // sweeps roughly 190 degrees, which no single fold to within +/-180 of one
    // reference can represent - folding sent every afternoon bearing a whole turn
    // backwards and collapsed half the arc off the left of the chart.
    private var _azWalk as Array<Number>;
    private var _profileValid as Boolean = false;

    // Derived values that cost trigonometry. onUpdate() asks for the sky index
    // five times a frame and for the forecast once, and the forecast alone walks
    // the elevation profile; recomputing either per frame is work paid for out of
    // the battery this field exists to report on. Both are settled once per
    // second in compute() and read from here while drawing.
    private var _skyCache as Number? = null;
    private var _skyValid as Boolean = false;
    private var _forecastCache as Number = 0;
    private var _forecastValid as Boolean = false;
    private var _elevTick as Number = 0;

    // Last hero font that fitted, and the box it was measured against.
    private var _heroFontIndex as Number = -1;
    private var _heroFontW as Number = -1;
    private var _heroFontH as Number = -1;

    // 0 follow the watch, 1 force dark, 2 force light.
    private var _theme as Number = 0;
    private var _pageMode as Number = 0;
    private var _cycleSeconds as Number = 8;
    private var _lapPaging as Boolean = false;
    // Lap harvest seconds the lap callback last wrote into the FIT fields. Only
    // FitRecorder reads the fields themselves, and it cannot run in a unit test.
    private var _lapFieldSeconds as Number = 0;
    private var _manualPage as Number = 0;
    // Zone-label height, measured once per layout.
    private var _zoneLabelH as Number = 0;

    private var _fit as FitRecorder? = null;

    // Persisted calibration, and a throttle so storage is not written every tick.
    private var _saveTick as Number = 0;
    // Start time of the activity whose snapshot this instance writes, or -1
    // until the timer has started and the activity has one.
    private var _activityTag as Number = -1;

    function initialize() {
        DataField.initialize();
        _model = new SolarModel(SAMPLE_PERIOD);
        _alerts = new AlertEngine();
        _palette = new Palette();
        _layout = new LayoutPlanner(0, 100, 12, 7, false);
        _safe = new SafeArea();
        _profile = new [PROFILE_POINTS] as Array<Number>;
        _azProfile = new [PROFILE_POINTS] as Array<Number>;
        _azWalk = new [PROFILE_POINTS] as Array<Number>;
        for (var i = 0; i < PROFILE_POINTS; i++) {
            _azProfile[i] = -1;
            _azWalk[i] = 0;
            _profile[i] = 0;
        }
        _valueFonts = [
            Graphics.FONT_NUMBER_HOT,
            Graphics.FONT_NUMBER_MEDIUM,
            Graphics.FONT_NUMBER_MILD,
            Graphics.FONT_LARGE,
            Graphics.FONT_MEDIUM,
            Graphics.FONT_SMALL,
            Graphics.FONT_TINY,
            Graphics.FONT_XTINY
        ] as Array<FontDefinition>;
        loadSettings();
        loadCalibration();
        if (!gSkipFitRecording) {
            _fit = new FitRecorder(self);
        }
    }

    // Test seams. A data field gets its samples from compute() and its page from
    // the clock, neither of which a unit test can drive, so the render tests need
    // a way in. These are deliberately not annotated (:test): that annotation
    // registers a method as a test case in its own right.
    function addSampleForTest(intensity as Number, battery as Float) as Void {
        _model.addSample(intensity, battery, false);
    }

    // A sample taken while the timer was stopped or paused, which is what
    // compute() delivers before the wearer presses start and during every break.
    function addPausedSampleForTest(intensity as Number, battery as Float) as Void {
        _model.addSampleWhen(intensity, battery, false, false);
    }

    function setPageForTest(page as Number) as Void {
        _pageMode = page + 1;
    }

    function setLapPagingForTest(on as Boolean) as Void {
        _lapPaging = on;
    }

    function manualPageForTest() as Number {
        return _manualPage;
    }

    // What the lap callback left in the FIT lap fields, which is what the next
    // lap record captures if it closes before compute() refreshes them.
    function lapFieldSecondsForTest() as Number {
        return _lapFieldSeconds;
    }

    // What compute() does the first time an activity has a start time.
    function beginActivityForTest(startTime as Number) as Void {
        _activityTag = startTime;
        absorbStalePending();
    }

    function calibrationForTest() as Array<Float> {
        return _model.calibration();
    }

    function effectiveSavingForTest() as Float? {
        return _model.effectiveSaving();
    }

    // Without a fix the sun geometry short-circuits, so a benchmark that never
    // sets one measures none of the work that actually costs anything.
    function setFixForTest(latRad as Double, lonRad as Double) as Void {
        _latRad = latRad;
        _lonRad = lonRad;
        _hasFix = true;
        primeSunForTest();
    }

    function profileForTest() as Array<Number> {
        return _profile;
    }

    function azProfileForTest() as Array<Number> {
        return _azProfile;
    }

    function azWalkForTest() as Array<Number> {
        return _azWalk;
    }

    function lapHarvestSecondsForTest() as Number {
        return _model.lapHarvestSeconds();
    }

    function harvestSecondsForTest() as Number {
        return _model.harvestSeconds();
    }

    // A heading, or -1 for a watch that has no compass reading to give. Both
    // paths have to render: the compass page falls back to north-up and an
    // absolute bearing when there is nothing to be relative to.
    function setHeadingForTest(degrees as Float) as Void {
        _heading = degrees;
    }

    // Pins the clock, so a test can put the sun where it needs it.
    //
    // Every sun-facing page reads the time from the system, which left the render
    // test exercising only whatever geometry happened to hold when the suite ran:
    // at dusk the daylight arc has almost no future half and most of its drawing
    // never executes at all. Nothing outside a test ever sets this, and zero means
    // the real clock.
    function setClockForTest(at as Number) as Void {
        _clockOverride = at;
        if (_hasFix) {
            primeSunForTest();
        }
    }

    // Sunrise and sunset from the geometry - the same path a watch takes when it
    // has a fix but no weather synced from its phone.
    //
    // The seam used to invent a window of "five hours ago to two hours from now",
    // which no real day matches, so the profile it built was never the arc the
    // field actually draws: it came out as a monotonic slide with its whole
    // morning half missing.
    private function primeSunForTest() as Void {
        var events = SolarGeometry.sunEvents(nowSeconds(), _latRad, _lonRad);
        if (events != null) {
            _sunrise = events[0];
            _sunset = events[1];
        } else {
            // Polar day or night returns nothing, and the field has to cope with
            // that rather than assume every latitude has a sunrise.
            _sunrise = -1;
            _sunset = -1;
        }
        _profileValid = false;
        refreshElevation();
        refreshProfile();
        _skyValid = false;
        refreshForecast();
    }

    // Mirrors what compute() does to the per-second caches, so a benchmark can
    // measure a real frame rather than a permanently warm one.
    function tickCachesForTest() as Void {
        _skyValid = false;
    }

    function loadSettings() as Void {
        _theme = numberProperty("theme", 0, 0, 2);
        _pageMode = numberProperty("pageMode", 0, 0, PAGE_COUNT);
        _cycleSeconds = numberProperty("cycleSeconds", 8, 3, 60);
        _lapPaging = booleanProperty("lapPaging", false);
        _alertsOn = booleanProperty("alerts", true);
    }

    function onLayout(dc as Dc) as Void {
        var settings = System.getDeviceSettings();
        _screenW = settings.screenWidth;
        _screenH = settings.screenHeight;
        _round = (settings.screenShape == System.SCREEN_SHAPE_ROUND);
        _flags = -1;
    }

    // -- activity lifecycle -----------------------------------------------

    // Whether the activity timer is actually running.
    //
    // compute() is called about once a second from the moment the field is on
    // screen, which is well before the wearer presses start and right through
    // every pause, but the FIT only receives records while the timer runs.
    // Anything that accumulates into this activity's own numbers has to agree
    // with that or the summary describes a longer, different activity than the
    // chart beside it does.
    //
    // Feature-detected: timerState is old enough to be on every supported
    // device, but a field that stops measuring because an optional property
    // came back null would be a far worse failure than one that measures a
    // little too eagerly, so an unreadable state is treated as running.
    private function isRecording(info as Activity.Info) as Boolean {
        if (!(info has :timerState) || info.timerState == null) {
            return true;
        }
        return info.timerState == Activity.TIMER_STATE_ON;
    }

    function compute(info as Activity.Info) as Void {
        var stats = System.getSystemStats();
        var intensity = readIntensity(stats);
        if (intensity == null) {
            _hasSolar = false;
            return;
        }
        _hasSolar = true;
        _charging = stats.charging;
        _daysLeft = readDaysLeft(stats);
        _recording = isRecording(info);
        _model.addSampleWhen(intensity, stats.battery, _charging, _recording);
        if (_activityTag < 0 && (info has :startTime) && info.startTime != null) {
            _activityTag = (info.startTime as Time.Moment).value();
            absorbStalePending();
        }

        var fit = _fit;
        if (fit != null) {
            fit.update(_model, _elevation, _hasFix);
        }
        updateSunTimes(info);
        readHeading(info);

        // The sun moves 0.25 degrees a minute, so recomputing its position every
        // second buys nothing a reader could see.
        _elevTick += 1;
        if (_elevTick >= ELEVATION_REFRESH || _elevation < -90.0) {
            _elevTick = 0;
            refreshElevation();
        }
        if (!_profileValid) {
            // Built here, never from onUpdate(). Thirty-two solar positions is
            // far too much work to do inside a draw call, and doing it there
            // overflowed the stack on a device that actually had a fix.
            refreshProfile();
        }
        _skyValid = false;
        // Same rule, same reason: the forecast walks all thirty-one slices of the
        // day and evaluates the available light at each end of every one. That is
        // the profile's workload again, and it was being done from the draw path
        // on every single frame - which overflowed the stack at midday and blew
        // the frame budget the rest of the time. It follows the sun's own refresh
        // cadence because a forecast in minutes cannot change second to second.
        if (_elevTick == 0 || !_forecastValid) {
            refreshForecast();
        }

        maybeAlert();

        _saveTick += 1;
        if (_saveTick >= 300) {
            _saveTick = 0;
            writePending();
        }
    }

    function onTimerStop() as Void {
        writePending();
    }

    // Raise at most one alert per second, and only while the timer is running.
    //
    // The timer check is the point of the second condition: without it an alert
    // can fire while the wearer is still standing at the trailhead waiting for
    // a GPS lock, about an activity that has not started.
    //
    // Wrapped in its own try/catch: showAlert is not on every device this builds
    // for, and an alert is a courtesy - it must never be the reason a data field
    // stops drawing.
    private function maybeAlert() as Void {
        if (!_alertsOn || gSkipFitRecording || !_recording) {
            return;
        }
        var toSunset = 0;
        if (_sunset > 0) {
            toSunset = _sunset - nowSeconds();
            if (toSunset < 0) {
                toSunset = 0;
            }
        }
        var kind = _alerts.evaluate(_model.ticks(), _elevation, skyPercent(),
            _model.netFlowPerHour(), toSunset);
        if (kind == SolarAlerts.KIND_NONE) {
            return;
        }
        try {
            if (self has :showAlert) {
                showAlert(new SolarAlertView(kind, alertDetail(kind), _palette));
            }
        } catch (ex) {
            // A device that cannot show alerts still shows every page.
        }
    }

    // One line under the headline, carrying the number that makes it actionable.
    private function alertDetail(kind as Number) as String {
        if (kind == SolarAlerts.KIND_GAIN) {
            var flow = _model.netFlowPerHour();
            return (flow == null) ? "SUN IS WINNING"
                : "+" + (-flow).format("%.1f") + "%/h FROM THE SUN";
        } else if (kind == SolarAlerts.KIND_SHADE) {
            return "5 MIN OF POOR LIGHT";
        } else if (kind == SolarAlerts.KIND_SUNSET) {
            return formatMinutes(_sunset - nowSeconds()) + " OF DAYLIGHT LEFT";
        }
        var sky = skyPercent();
        return (sky == null) ? "CATCHING AGAIN"
            : "CATCHING " + sky.format("%d") + "% AGAIN";
    }

    // A lap boundary, however it was triggered.
    //
    // Two callbacks, because newer firmware offers onTimerLap2 and calls plain
    // onTimerLap only when onTimerLap2 returns false. Implementing just the old
    // one looked correct and was not: a lap the watch raised itself never reset
    // the accumulator, so every lap after the first recorded the running total
    // instead of its own share. Two laps cannot catch this - a cumulative series
    // and a per-lap one are identical over a single boundary.
    //
    // onTimerLap2 fires after the lap record has already been written, which is
    // exactly why the lap fields are refreshed every second in compute(): by the
    // time the firmware writes the record the field already holds this lap's
    // number, and all that is left to do here is start the next one.
    // Annotated so it can be compiled out for the fenix 7 tier, which runs
    // Connect IQ 5.2.0 - two patch levels below the 5.2.2 that introduced
    // onTimerLap2 and its LapInfoType. Those devices raise plain onTimerLap and
    // are served correctly by it; excluding the symbol is what lets the manifest
    // floor drop far enough to reach them at all.
    //
    // The lap button always records a lap when pressed - a data field has no
    // way to stop that, with or without this app installed. LapInfoType carries
    // which KIND of lap this was, though, and that is what lapPaging actually
    // needs: a page flip is a response to the user pressing the button, not to
    // an auto-lap firing by distance, time, or a workout step. Without this
    // check, a structured workout with auto-laps every mile would silently
    // flip the page every mile - motion nobody asked for, on the one setting
    // that is supposed to be a convenience.
    (:lap2)
    function onTimerLap2(trigger as DataField.LapInfoType) as Boolean {
        handleLap(trigger[:lapTrigger] == DataField.LAP_TRIGGER_MANUAL, true);
        return true;
    }

    // No LapInfoType on this path (pre-5.2.2 firmware), so there is no way to
    // tell a button press from an auto-lap here. Treating every lap as manual
    // is the same behaviour this app always had before the distinction existed
    // above, not a regression - just the best available answer on older devices.
    //
    // Nor does this callback promise when the lap record is written, so it keeps
    // pushing the finished lap before the reset, in case firmware reads the
    // fields only after it returns.
    function onTimerLap() as Void {
        handleLap(true, false);
    }

    // `recordWritten` is true when the firmware has already written the lap
    // record, which onTimerLap2 guarantees.
    //
    // In that case the finished lap is already on disk, and pushing its totals
    // back into the live fields does nothing for it but leave them there until
    // the next compute(). Anything that closes before that refresh inherits
    // them: a structured workout's last step ending moments before the stop
    // gave a three second final lap the previous step's three minutes. So the
    // fields are pushed after the reset instead, and hold the new, empty lap
    // from the moment the callback returns.
    private function handleLap(manual as Boolean, recordWritten as Boolean) as Void {
        if (!recordWritten) {
            pushLapFields();
        }
        _model.noteLap();
        if (recordWritten) {
            pushLapFields();
        }
        if (_lapPaging && manual) {
            _manualPage = (_manualPage + 1) % PAGE_COUNT;
        }
    }

    private function pushLapFields() as Void {
        _lapFieldSeconds = _model.lapHarvestSeconds();
        var fit = _fit;
        if (fit != null) {
            fit.updateLap(_model);
        }
    }

    function onTimerReset() as Void {
        commitActivity();
        _model.reset();
        _sunrise = -1;
        _sunset = -1;
        _sunTick = 0;
        _manualPage = 0;
        _elevation = -99.0;
        _profileValid = false;
        _skyValid = false;
        _forecastValid = false;
        _elevTick = 0;
    }

    // -- rendering --------------------------------------------------------

    function onUpdate(dc as Dc) as Void {
        if (dc has :setAntiAlias) {
            dc.setAntiAlias(true);
        }
        _palette.apply(backgroundColor());
        dc.setColor(_palette.bg, _palette.bg);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        refreshSafeArea(w, h);

        if (!_hasSolar) {
            dc.setColor(_palette.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2, Graphics.FONT_XTINY, "NO SOLAR",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var mask = availableMask();
        var page = currentPage(mask);
        var lineH = dc.getFontHeight(Graphics.FONT_XTINY);
        _zoneLabelH = lineH;
        var edge = (_round && _fullScreen) ? (h * 0.10).toNumber() : 2;
        // On a round screen the last rows are the narrowest part of the chord, so
        // the chips get pushed up out of them. At 260px this is the difference
        // between showing both chips and dropping one for want of a few pixels.
        var bottom = edge + ((_round && _fullScreen) ? (h * 0.065).toNumber() : 0);
        // The dial is drawn just inside the glass, so every row has to be pulled
        // in by its thickness or the page title runs straight through the arc.
        // The dial sweeps from 7 o'clock over the top to 5 o'clock, so its lowest
        // point is half a radius below centre; rows under that are already clear.
        // The gauge sweeps from 7 o'clock over the top to 5 o'clock, so its lowest
        // point is half a radius below centre and rows under that are already
        // clear of it. The compass ring is a full circle and clears nothing, so
        // on that page the inset has to hold for every row on the screen -
        // without this its arc and chips ran out under the ring.
        var ringFloor = (page == PAGE_COMPASS)
            ? h
            : (_safe.ringCenterY() + (_safe.ringRadius() / 2));
        var inset = (page == PAGE_COMPASS) ? (compassWidth() + 12) : gaugeInset();
        _safe.setInset((_round && _fullScreen) ? inset : 0, ringFloor);
        var wantDots = (_pageMode == 0) && (w >= 110) && (countPages(mask, PAGE_COUNT) > 1);

        if (_round && _fullScreen) {
            if (page == PAGE_COMPASS) {
                drawCompassRing(dc);
            } else {
                drawGauge(dc, page);
            }
        }

        _layout.plan(edge, h - edge - bottom, lineH, 7, wantDots);

        if (_layout.showTitle) {
            drawTitle(dc, page, _layout.titleY, lineH);
        }
        if (_layout.showDots) {
            drawPageDots(dc, _safe.centerAt(_layout.dotsY), _layout.dotsY, page, mask);
        }

        var heroCy = _layout.heroCenterY();
        var heroTop = heroCy - (_layout.heroH / 2);
        var heroEdge = heroCy + (_layout.heroH / 2);
        drawHero(dc, _safe.centerAt(heroCy), heroCy, page,
            2 * _safe.halfAcross(heroTop, heroEdge), _layout.heroH);

        if (_layout.showChart) {
            var chartBase = _layout.chartY + _layout.chartH;
            var chartHalf = _safe.halfAt(chartBase);
            if (chartHalf > 12) {
                drawChart(dc, page, _safe.centerAt(chartBase) - chartHalf,
                    _layout.chartY, 2 * chartHalf, _layout.chartH);
            }
        }
        if (_layout.showChips) {
            drawChips(dc, page, _layout.chipsY, lineH);
        }
    }

    private function drawTitle(dc as Dc, page as Number, y as Number, lineH as Number) as Void {
        var text = pageTitle(page);
        var cx = _safe.centerAt(y + lineH);
        dc.setColor(_palette.dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_XTINY, text, Graphics.TEXT_JUSTIFY_CENTER);

        if (page != PAGE_NOW || _model.count() < 3) {
            return;
        }
        var slope = _model.slopePerMinute();
        if (slope.abs() < 0.05) {
            return;
        }
        // Trend caret next to the title, sized from the title metrics.
        var textW = dc.getTextWidthInPixels(text, Graphics.FONT_XTINY);
        var size = lineH / 4;
        // A full caret-width of air between the title and the caret. Three pixels
        // left them touching at the sizes this actually renders at.
        var ax = cx + (textW / 2) + (2 * size);
        var ay = y + (lineH / 2);
        if ((ax + size) > _safe.rightAt(y + lineH)) {
            return;
        }
        dc.setColor(_palette.trend(slope), Graphics.COLOR_TRANSPARENT);
        if (slope > 0) {
            dc.fillPolygon([[ax - size, ay + size], [ax + size, ay + size], [ax, ay - size]]);
        } else {
            dc.fillPolygon([[ax - size, ay - size], [ax + size, ay - size], [ax, ay + size]]);
        }
    }

    private function drawHero(dc as Dc, cx as Number, cy as Number, page as Number,
                              maxW as Number, maxH as Number) as Void {
        var text = heroText(page);
        dc.setColor(heroColor(page), Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, heroFont(dc, text, maxW, maxH), text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Largest font the hero still fits in.
    //
    // Searching eight fonts costs up to sixteen text-metric calls, every second,
    // on every page. The hero text changes constantly but its shape almost never
    // does, so the last answer is reused whenever it still fits - and it is
    // re-measured against the real string rather than trusted, so a wider glyph
    // can never silently overflow the box.
    private function heroFont(dc as Dc, text as String, maxW as Number,
                              maxH as Number) as FontDefinition {
        if (_heroFontIndex >= 0 && maxW == _heroFontW && maxH == _heroFontH) {
            var cached = _valueFonts[_heroFontIndex];
            if (dc.getTextWidthInPixels(text, cached) <= maxW) {
                return cached;
            }
        }
        var index = _valueFonts.size() - 1;
        for (var i = 0; i < _valueFonts.size(); i++) {
            var candidate = _valueFonts[i];
            if (dc.getTextWidthInPixels(text, candidate) <= maxW
                && dc.getFontHeight(candidate) <= maxH) {
                index = i;
                break;
            }
        }
        _heroFontIndex = index;
        _heroFontW = maxW;
        _heroFontH = maxH;
        return _valueFonts[index];
    }

    // Chips are measured first and dropped rather than allowed to collide.
    private function drawChips(dc as Dc, page as Number, y as Number, lineH as Number) as Void {
        var left = chipLeft(page);
        var right = chipRight(page);
        var leftLabel = chipLeftLabel(page);
        var rightLabel = chipRightLabel(page);
        var baseline = y + lineH;
        var x0 = _safe.leftAt(baseline);
        var x1 = _safe.rightAt(baseline);
        var room = x1 - x0;
        var leftW = pairWidth(dc, leftLabel, left);
        var rightW = pairWidth(dc, rightLabel, right);

        if (right.length() > 0 && (leftW + rightW + CHIP_GAP) <= room) {
            drawChip(dc, x0, y, leftLabel, left, chipLeftColor(page), false);
            drawChip(dc, x1, y, rightLabel, right, _palette.fg, true);
        } else if (leftW <= room) {
            drawChip(dc, ((x0 + x1) / 2) - (leftW / 2), y, leftLabel, left,
                chipLeftColor(page), false);
        } else if (dc.getTextWidthInPixels(left, Graphics.FONT_XTINY) <= room) {
            // Out of room for the name, but never for the number: the label is
            // the part a reader can infer from the page they are already on.
            dc.setColor(chipLeftColor(page), Graphics.COLOR_TRANSPARENT);
            dc.drawText((x0 + x1) / 2, y, Graphics.FONT_XTINY, left,
                Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    private function pairWidth(dc as Dc, label as String, value as String) as Number {
        var w = dc.getTextWidthInPixels(value, Graphics.FONT_XTINY);
        if (label.length() > 0) {
            w += dc.getTextWidthInPixels(label, Graphics.FONT_XTINY) + LABEL_GAP;
        }
        return w;
    }

    // Label then value, left to right, whichever edge the chip is anchored to.
    // The label always precedes its number - reversing it on the right-hand chip
    // would read as a different sentence rather than as a mirrored one.
    private function drawChip(dc as Dc, anchor as Number, y as Number, label as String,
                              value as String, valueColor as Number,
                              rightAligned as Boolean) as Void {
        var x = anchor;
        if (rightAligned) {
            x = anchor - pairWidth(dc, label, value);
        }
        if (label.length() > 0) {
            dc.setColor(_palette.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_LEFT);
            x += dc.getTextWidthInPixels(label, Graphics.FONT_XTINY) + LABEL_GAP;
        }
        dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_XTINY, value, Graphics.TEXT_JUSTIFY_LEFT);
    }

    private function drawChart(dc as Dc, page as Number, x as Number, y as Number,
                               w as Number, h as Number) as Void {
        if (page == PAGE_HARVEST) {
            drawCumulative(dc, x, y, w, h);
        } else if (page == PAGE_BATTERY) {
            drawBatteryTrace(dc, x, y, w, h);
        } else if (page == PAGE_WINDOW) {
            if (profilePeak() <= 0) {
                drawZones(dc, x, y, w, h);
            } else {
                drawDaylightArc(dc, x, y, w, h);
            }
        } else if (page == PAGE_SKY) {
            drawZones(dc, x, y, w, h);
        } else if (page == PAGE_COMPASS) {
            drawSkyView(dc, x, y, w, h);
        } else if (page == PAGE_BONUS) {
            // The fallback is chosen here rather than inside drawBonusBars, and
            // the daylight arc's is chosen the same way below. A chart renderer
            // that calls another chart renderer adds a frame to the deepest path
            // in the field, and this one overflowed the stack the moment the
            // chart band grew: onUpdate -> drawChart -> drawBonusBars ->
            // drawCumulative was one call too many. Sibling calls, never nested.
            if (bonusSplit() == null) {
                drawCumulative(dc, x, y, w, h);
            } else {
                drawBonusBars(dc, x, y, w, h);
            }
        } else if (page == PAGE_NOW) {
            drawSparkline(dc, x, y, w, h);
        }
    }

    // The hour split into what the sun covered and what the battery still paid,
    // in percentage points per hour: [saved, paid].
    //
    // Derived from the same effective figures the hero uses - measured where the
    // fit has converged, learned where it has not - so the ring, the bar and the
    // headline can never quote different arithmetic. Reading the baseline off the
    // fit alone meant the chart fell back to "measuring" while the hero was
    // already quoting a bonus from learned values.
    private function bonusSplit() as Array<Float>? {
        var saving = _model.effectiveSaving();
        var paid = _model.effectiveDrain();
        if (saving == null || paid == null || paid <= 0.0) {
            return null;
        }
        var lit = saving * (_model.average() / 100.0);
        if (lit < 0.0) {
            lit = 0.0;
        }
        return [lit, paid] as Array<Float>;
    }

    // How much of the hour the sun cancelled, as a percentage of what it would
    // otherwise have cost.
    private function offsetSharePercent() as Number {
        var split = bonusSplit();
        if (split == null) {
            return 0;
        }
        var total = split[0] + split[1];
        if (total <= 0.0) {
            return 0;
        }
        return percentOf((split[0] * 100).toNumber(), (total * 100).toNumber());
    }

    // -- page selection ---------------------------------------------------

    // A page is only offered when it actually has something to say.
    private function availableMask() as Number {
        var mask = 1 << PAGE_NOW;
        if (_model.harvestSeconds() > 0 || _model.ticks() > 0) {
            mask = mask | (1 << PAGE_HARVEST);
        }
        if (_model.batteryPercent() >= 0.0) {
            mask = mask | (1 << PAGE_BATTERY);
        }
        if (sunState() != SUN_UNKNOWN || _model.ticks() > 0) {
            mask = mask | (1 << PAGE_WINDOW);
        }
        // Offered as soon as there is a fix. Gating it on the index as well meant
        // the page vanished whenever the sun was low, and a user cannot tell an
        // absent feature from a broken one.
        if (_hasFix) {
            mask = mask | (1 << PAGE_SKY);
        }
        // Offered from the first reading rather than gated on the fit landing.
        // This is the number a solar watch is bought for, and a page that only
        // materialises once some hidden threshold is crossed reads as broken; it
        // says what it knows, and says so plainly while it is still measuring.
        if (_hasSolar && _model.ticks() > 0) {
            mask = mask | (1 << PAGE_BONUS);
        }
        // Only while there is a sun above the horizon to point at. A compass
        // aimed at a sun that has set is a page of confident nonsense.
        if (sunIsUp()) {
            mask = mask | (1 << PAGE_COMPASS);
        }
        return mask;
    }

    private function currentPage(mask as Number) as Number {
        if (_pageMode > 0) {
            return (_pageMode - 1) % PAGE_COUNT;
        }
        if (_lapPaging) {
            return resolvePage(_manualPage, mask, PAGE_COUNT);
        }
        return resolvePage(((System.getTimer() / 1000) / _cycleSeconds) % PAGE_COUNT, mask, PAGE_COUNT);
    }

    private function pageTitle(page as Number) as String {
        if (page == PAGE_HARVEST) {
            return "FULL SUN";
        } else if (page == PAGE_BATTERY) {
            if (_charging) {
                return "BATTERY CHG";
            }
            var flow = _model.netFlowPerHour();
            return (flow != null && flow < -0.05) ? "BATTERY GAIN" : "BATTERY";
        } else if (page == PAGE_WINDOW) {
            // The clock time lives in the title because the title row is wider
            // than the chip row on a round screen. That frees the chips to carry
            // two values instead of dropping one for want of a few pixels.
            var state = sunState();
            if (state == SUN_DAWN) {
                return (_sunrise > 0) ? "SUNRISE " + clockText(_sunrise) : "TO SUNRISE";
            } else if (state == SUN_DAY) {
                return (_sunset > 0) ? "SUNSET " + clockText(_sunset) : "TO SUNSET";
            } else if (state == SUN_NIGHT) {
                return "AFTER DARK";
            }
            return "TIME IN SUN";
        } else if (page == PAGE_SKY) {
            // Names the measurement: the share of the sun that is actually
            // reaching the panel. "SKY" named neither the thing nor its units.
            //
            // Below the useful elevation there is no catching figure to give, and
            // the hero falls back to the sun's height. The title has to follow it
            // there, or the page promises a number it is not showing.
            return (skyPercent() == null) ? "SUN HEIGHT" : "CATCHING";
        } else if (page == PAGE_COMPASS) {
            // One word, not a sentence. "WHERE'S THE SUN" was the widest title in
            // the app and the only one that ran into its own page's artwork - it
            // crossed the compass ring on every device this ships to. The page
            // already answers the question in its hero and chips; the title only
            // has to name it.
            return "COMPASS";
        } else if (page == PAGE_BONUS) {
            // The tilde is the app's existing mark for a figure resting on what
            // earlier activities taught this watch rather than on this one.
            return _model.bonusIsLearned() ? "~SUN BONUS" : "SUN BONUS";
        }
        return "SOLAR NOW";
    }

    private function heroText(page as Number) as String {
        if (page == PAGE_HARVEST) {
            return formatClock(_model.harvestSeconds());
        } else if (page == PAGE_BATTERY) {
            var level = _model.batteryPercent();
            return (level < 0.0) ? "--" : level.format("%d") + "%";
        } else if (page == PAGE_WINDOW) {
            var state = sunState();
            if (state == SUN_DAWN || state == SUN_DAY) {
                return formatClock(sunWindowRemaining(nowSeconds(), _sunrise, _sunset));
            } else if (state == SUN_NIGHT) {
                return "0:00";
            }
            return percentText(_model.sunFraction());
        }
        if (page == PAGE_COMPASS) {
            if (_elevation >= ZENITH_DEGREES) {
                return "OVERHEAD";
            }
            var rel = relativeBearing();
            // Clock position, because that is how people actually give each other
            // a direction while moving. A bearing in degrees is precise and has to
            // be translated by the reader before it means anything.
            if (rel == null) {
                return compassPoint(_azimuth);
            }
            var oclock = (((rel + 15.0) / 30.0).toNumber()) % 12;
            if (oclock == 0) {
                oclock = 12;
            }
            return oclock.format("%d") + " O'CLOCK";
        }
        if (page == PAGE_BONUS) {
            var bonus = _model.solarBonusMinutes();
            return (bonus == null) ? "--" : "+" + bonus.format("%d") + "m";
        }
        if (page == PAGE_SKY) {
            var sky = skyPercent();
            if (sky != null) {
                return sky.format("%d") + "%";
            }
            // Too low to judge what is reaching the panel, so report the thing
            // that is still exactly known: how high the sun is.
            if (_hasFix && _elevation > -90.0) {
                return _elevation.format("%.0f") + DEGREE;
            }
            return "--";
        }
        if (_model.ticks() <= 0) {
            return "--";
        }
        return _model.smoothed().format("%d") + "%";
    }

    private function heroColor(page as Number) as Number {
        if (page == PAGE_BATTERY) {
            var level = _model.batteryPercent();
            if (level < 0.0) {
                return _palette.dim;
            }
            if (level <= 15.0) {
                return _palette.drain;
            }
            var flow = _model.netFlowPerHour();
            if (flow != null && flow < -0.05) {
                return _palette.gain;
            }
            return _palette.fg;
        } else if (page == PAGE_HARVEST) {
            return _palette.accent;
        } else if (page == PAGE_WINDOW) {
            return (sunState() == SUN_NIGHT) ? _palette.dim : _palette.fg;
        } else if (page == PAGE_SKY) {
            var sky = skyPercent();
            return (sky == null) ? _palette.dim : _palette.intensity(sky);
        } else if (page == PAGE_BONUS) {
            return (_model.solarBonusMinutes() == null) ? _palette.dim : _palette.gain;
        } else if (page == PAGE_COMPASS) {
            return _palette.accent;
        }
        return (_model.ticks() <= 0) ? _palette.dim : _palette.intensity(_model.smoothed());
    }

    // The quiet half of a chip: what the number is, never the number itself.
    //
    // Splitting the two is what turns a row of same-weight text into something
    // scannable. "AVG 54%" set in one colour makes the reader parse a sentence;
    // a dim "AVG" beside a bright "54%" lets the eye take the value first and the
    // name only if it needs it. Empty when the value speaks for itself.
    private function chipLeftLabel(page as Number) as String {
        if (page == PAGE_HARVEST) {
            if (_model.solarBonusMinutes() != null) {
                return _model.bonusIsLearned() ? "~BONUS" : "BONUS";
            }
            return "IN SUN";
        } else if (page == PAGE_BATTERY) {
            return "RATE";
        } else if (page == PAGE_WINDOW) {
            // "AHEAD" alone answers nothing - ahead of what? The value is a
            // forecast of full-sun minutes still to come before sunset, so the
            // label says that much directly instead of naming the concept
            // implicitly.
            return (sunState() == SUN_DAY) ? "MORE SUN" : "PEAK";
        } else if (page == PAGE_SKY) {
            // No label on the states that are already a whole sentence.
            if (!_hasFix || skyPercent() == null) {
                return "";
            }
            return "SUN";
        } else if (page == PAGE_COMPASS) {
            return "SUN";
        } else if (page == PAGE_BONUS) {
            return (bonusSplit() == null) ? "" : "WAS";
        }
        return "AVG";
    }

    private function chipRightLabel(page as Number) as String {
        if (page == PAGE_HARVEST) {
            return "AVG";
        } else if (page == PAGE_BATTERY) {
            return runtimeLabel();
        } else if (page == PAGE_WINDOW) {
            return "SUN";
        } else if (page == PAGE_SKY) {
            if (!_hasFix) {
                return "";
            }
            if (_cloudCover >= 0) {
                return "CLOUD";
            }
            return (_uvIndex >= 0.0) ? "UV" : "";
        } else if (page == PAGE_BONUS) {
            return "SUN";
        } else if (page == PAGE_COMPASS) {
            return (_heading < 0.0) ? "" : "YOU";
        }
        return "PK";
    }

    private function chipLeft(page as Number) as String {
        if (page == PAGE_HARVEST) {
            // Runtime gained reads far better than a rate, so it wins when the
            // measurement supports it; the rate is the fallback, and the plain
            // sun share is what is left when neither has enough evidence.
            // Three tiers, all true. The bonus measured here; the same figure
            // from what earlier activities taught this watch, marked with "~";
            // and failing both, the harvest itself, which is exact from the very
            // first second. The chip is never empty and never invented.
            var bonus = _model.solarBonusMinutes();
            if (bonus != null) {
                return "+" + bonus.format("%d") + "m";
            }
            return formatMinutes(_model.harvestSeconds());
        } else if (page == PAGE_BATTERY) {
            return drainText();
        } else if (page == PAGE_WINDOW) {
            var state = sunState();
            if (state == SUN_DAY) {
                return formatMinutes(forecastHarvestSeconds());
            }
            return _model.peak().format("%d") + "%";
        } else if (page == PAGE_SKY) {
            // Pinned from settings this page can be reached with no fix at all,
            // and a bare "--" gives the user nothing to act on.
            if (!_hasFix) {
                return "NEEDS GPS";
            }
            // When there is no catching figure the hero is already showing the
            // sun's height, and repeating it here spends one of the page's four
            // slots saying nothing new. The useful thing to add is the direction
            // of travel: whether waiting will help.
            if (skyPercent() == null) {
                return (_elevation < -90.0) ? "SUN --" : (_rising ? "CLIMBING" : "DROPPING");
            }
            return sunHeightText();
        } else if (page == PAGE_COMPASS) {
            return compassPoint(_azimuth);
        } else if (page == PAGE_BONUS) {
            // The bar already direct-labels both halves of the hour and the ring
            // already gives the share, so quoting the saving here a third time
            // spent the row that carried the comparison - and cost it entirely,
            // because the pair no longer fitted and the second chip was dropped.
            // This is the counterfactual: what the hour would have cost unlit.
            var split = bonusSplit();
            if (split == null) {
                return "MEASURING";
            }
            return "-" + (split[0] + split[1]).format("%.1f") + "%/h";
        }
        return _model.average().format("%d") + "%";
    }

    // How high the sun actually is, above the horizon. This is the number that
    // explains a low reading that is nobody's fault.
    //
    // Labelled "UP" rather than as an elevation or altitude: on a watch both of
    // those words already mean terrain height, and a bare "SUN 47" reads as a
    // temperature or a bearing.
    private function sunHeightText() as String {
        if (_elevation < -90.0) {
            return "--";
        }
        return _elevation.format("%.0f") + DEGREE + " UP";
    }

    // The battery flow reads in the same colour as the trace above it; every
    // other chip stays quiet so the hero keeps the page's attention.
    // The colour of a chip's number. Plain white unless the value carries a
    // direction worth seeing - never dim, which is the label's weight: a value
    // set at label weight is the split undone.
    private function chipLeftColor(page as Number) as Number {
        if (page != PAGE_BATTERY) {
            return _palette.fg;
        }
        var flow = _model.netFlowPerHour();
        if (flow == null) {
            flow = _model.provisionalNetFlowPerHour();
        }
        if (flow == null) {
            return _palette.fg;
        }
        return _palette.flow(flow);
    }

    private function chipRight(page as Number) as String {
        if (page == PAGE_HARVEST) {
            return _model.average().format("%d") + "%";
        } else if (page == PAGE_BATTERY) {
            return runtimeText();
        } else if (page == PAGE_WINDOW) {
            return percentText(_model.sunFraction());
        } else if (page == PAGE_SKY) {
            if (!_hasFix) {
                return "";
            }
            if (_cloudCover >= 0) {
                return _cloudCover.format("%d") + "%";
            }
            if (_uvIndex >= 0.0) {
                return _uvIndex.format("%.0f");
            }
            return "";
        } else if (page == PAGE_BONUS) {
            // What the watch would have been spending with no sun on it. This is
            // the comparison the bonus is against, so it belongs next to it.
            return formatMinutes(_model.harvestSeconds());
        } else if (page == PAGE_COMPASS) {
            // The other half of the subtraction. Without it a relative bearing is
            // a number the user cannot check against anything they can see.
            return (_heading < 0.0) ? "NO COMPASS" : compassPoint(_heading);
        }
        return _model.peak().format("%d") + "%";
    }

    // Measured first, then a provisional read, then Garmin's own runtime estimate.
    // A leading "~" marks anything that is not yet a confident measurement.
    private function drainText() as String {
        var measured = _model.netFlowPerHour();
        if (measured != null) {
            return formatFlow(measured) + "%/h";
        }
        var provisional = _model.provisionalNetFlowPerHour();
        if (provisional != null) {
            return "~" + formatFlow(provisional) + "%/h";
        }
        // Nothing measurable yet, but the level not having moved is itself worth
        // saying, and it bounds the answer. "<2.7%/h" after twenty steady
        // minutes is true, useful, and a great deal better than a dash.
        var ceiling = _model.drainCeilingPerHour();
        if (ceiling != null) {
            return "<" + ceiling.format("%.1f") + "%/h";
        }
        // Garmin's own batteryInDays is a smartwatch-mode figure, several times
        // lower than the drain of a GPS activity. Quoting it here as though it
        // were this activity's rate is exactly the misleading part, so it only
        // appears in the runtime chip, explicitly labelled.
        return "DRAIN --";
    }

    // Runtime left. The measured activity rate wins the moment it exists - it is
    // this activity's own drain, which beats any estimate. Below that, Garmin's
    // own runtime estimate outranks the locally-derived "held" ceiling: both are
    // just placeholders for a real measurement, but the system's is stated in
    // the same units the user actually wants (time until empty), while "held"
    // only says how long nothing has happened yet. Refreshed every second
    // (see compute()), so a stale read is never shown for longer than that.
    private function runtimeLabel() as String {
        if (_model.projectedHours() != null) {
            return "LEFT";
        }
        var flow = _model.netFlowPerHour();
        if (flow != null && flow <= 0.0) {
            return "";
        }
        if (_daysLeft >= 0.0) {
            return "IDLE";
        }
        return (_model.drainCeilingPerHour() != null) ? "HELD" : "";
    }

    private function runtimeText() as String {
        var hours = _model.projectedHours();
        if (hours != null) {
            return (hours >= 10.0) ? hours.format("%.0f") + "h" : hours.format("%.1f") + "h";
        }
        var flow = _model.netFlowPerHour();
        if (flow != null && flow <= 0.0) {
            return "SURPLUS";
        }
        if (_daysLeft >= 0.0) {
            return _daysLeft.format("%.1f") + "d";
        }
        // On a solar watch, holding a level for a long stretch is the headline,
        // not a missing number. Last resort: reached only on a device that does
        // not report batteryInDays at all.
        if (_model.drainCeilingPerHour() != null) {
            return formatMinutes(_model.secondsAtBatteryLevel());
        }
        return "";
    }

    // -- chrome and charts ------------------------------------------------

    // Intensity dial, concentric with the watch bezel rather than with the field
    // rectangle, sweeping from 7 o'clock over the top to 5 o'clock.
    //
    // A dial shows one number, so the filled arc is a single hue - the colour of
    // the value it is reporting. Colouring each segment by its own position on the
    // scale turns the dial into a rainbow that reads as three unrelated things
    // rather than one measurement.
    // Thickness of the dial plus the clearance content needs from it.
    private function gaugeWidth() as Number {
        return (_safe.ringRadius() >= 130) ? 9 : 7;
    }

    private function compassWidth() as Number {
        return (gaugeWidth() * 2) / 3;
    }

    private function gaugeInset() as Number {
        return gaugeWidth() + 12;
    }

    private function drawGauge(dc as Dc, page as Number) as Void {
        var cx = _safe.ringCenterX();
        var cy = _safe.ringCenterY();
        var width = gaugeWidth();
        // Held well inside the glass: an arc drawn against the radius is clipped
        // by the rounded edge and disappears under the bezel at the top.
        var r = _safe.ringRadius() - (width + 8);
        if (r < 20) {
            return;
        }
        var start = 210;
        var sweep = 240;
        var pct = gaugeValue(page);

        dc.setPenWidth(width);
        dc.setColor(_palette.muted, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, start, (start - sweep + 360) % 360);

        if (pct > 0 && _model.ticks() > 0) {
            var end = start - ((sweep * pct) / 100);
            if (end > start - 2) {
                end = start - 2;
            }
            dc.setColor(gaugeColor(page), Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, start, (end + 360) % 360);
        }

        // A graduated scale, cut out of the track in the background colour rather
        // than added as more ink. A gauge with no scale on it is decoration;
        // these are what let the arc be read as a value instead of just "more"
        // or "less".
        //
        // Two depths, the way a real instrument is engraved: a fine tick every
        // ten percent for reading against, and a deeper notch at each quarter for
        // finding your place without counting. The pen has to be at least as
        // thick as the track or a notch only cuts the middle of the band and
        // reads as a smudge; the fineness comes from the sweep, not the pen.
        dc.setColor(_palette.bg, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(width + 2);
        for (var t = 1; t < 10; t++) {
            var at = ((start - ((sweep * t) / 10)) + 360) % 360;
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, (at + 1) % 360, at);
        }
        for (var q = 1; q < 4; q++) {
            var qat = ((start - ((sweep * q) / 4)) + 360) % 360;
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, (qat + 3) % 360, qat);
        }

        // A cap on the live end of the value arc. Without it the arc simply stops,
        // and on a track of the same weight the eye has to hunt for exactly where
        // - the cap is what makes the reading a position rather than a length.
        if (pct > 0 && _model.ticks() > 0) {
            var capAt = ((start - ((sweep * pct) / 100)) + 360) % 360;
            dc.setPenWidth(width + 5);
            dc.setColor(gaugeColor(page), Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, (capAt + 3) % 360, capAt);
        }

        // One reference mark, not two, and only where it means something: peak
        // intensity is only a useful comparison against live intensity.
        var peak = (page == PAGE_NOW) ? _model.peak() : 0;
        if (peak > 0 && peak > pct) {
            var mark = ((start - ((sweep * peak) / 100)) + 360) % 360;
            dc.setPenWidth(width + 4);
            dc.setColor(_palette.fg, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, (mark + 2) % 360, mark);
        }
        dc.setPenWidth(1);
    }

    // The ring as a compass rather than as a gauge.
    //
    // The screen already has a full circle drawn round its edge, and a compass is
    // a full circle: giving the sun a position on the ring the user is already
    // looking at beats drawing a second, smaller circle inside it. Held heads-up,
    // the way every handheld compass and car navigation screen is held - the top
    // of the watch is the way you are facing, so "the sun is up and to the right"
    // is read off the glass without any mental rotation.
    private function drawCompassRing(dc as Dc) as Void {
        var cx = _safe.ringCenterX();
        var cy = _safe.ringCenterY();
        var width = compassWidth();
        var r = _safe.ringRadius() - (gaugeWidth() + 8);
        if (r < 20) {
            return;
        }
        var rel = relativeBearing();
        var headsUp = (rel != null);
        var offset = headsUp ? _heading : 0.0;

        dc.setPenWidth(width);
        dc.setColor(_palette.muted, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, 0, 360);

        // Eight points, not four. Cutting only N/E/S/W in the background colour
        // made them all but invisible against a black face - a gap the same
        // shade as the screen behind it reads as nothing at all, which is why
        // this looked like a bare ring with two stray marks rather than a
        // compass. Ticks are now drawn IN the dim tone instead of cut out, at
        // eight points, so the ring reads as a compass rose on its own, with no
        // need to already know where north is to recognise it as one.
        dc.setColor(_palette.dim, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth((width + 2) / 2);
        for (var q = 0; q < 8; q++) {
            var at = ringAngle((q * 45.0) - offset);
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, (at + 2) % 360, at);
        }

        // North, drawn bold enough to stand apart from the seven dimmer ticks.
        var northAt = ringAngle(-offset);
        dc.setColor(_palette.fg, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(width);
        dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, (northAt + 4) % 360, northAt);

        // The sweep still ahead of the sun today, dotted exactly as the daylight
        // arc marks its own future half - one convention, so a reader who has
        // seen either page already knows what dotted means on the other. This is
        // what turns the ring from a snapshot into part of the same story the
        // chart below tells: not just where the sun is, but which way and how
        // far it still has to swing before dark.
        //
        // Interpolated in compass degrees, using the walked series that is
        // already proven monotonic across the whole day (testSunPathArcIsADome-
        // NotAStub asserts exactly that), and converted to a drawing angle once
        // PER STEP rather than interpolating between two already-converted
        // drawing angles. ringAngle is a reflection (90 - bearing), not a shift,
        // so a straight line between two reflected points does not trace the
        // same sweep as the reflection of a straight line between the two
        // original bearings - interpolating on the wrong side of that reflection
        // is what turned a narrow dotted sweep into what looked like one long
        // solid arc.
        if (_azimuth >= 0.0 && _sunset > 0 && nowSeconds() < _sunset) {
            var nowIdx = nowProfileIndex();
            if (nowIdx < PROFILE_POINTS && _azProfile[nowIdx] >= 0) {
                var fromCompass = _azWalk[nowIdx].toFloat();
                var toCompass = _azWalk[PROFILE_POINTS - 1].toFloat();
                var sweep = toCompass - fromCompass;
                if (sweep > 1.0) {
                    // Its own thin track a few pixels inside the compass ring,
                    // not drawn at the ring's own width and radius. At full ring
                    // weight this covered most of the circumference solidly for
                    // anything but a late-afternoon sweep, fusing with the base
                    // track and erasing the tick marks it was meant to sit
                    // alongside. Thin and inset, it reads as an annotation next
                    // to the compass rather than a second, competing ring.
                    var sr = r - width - 4;
                    dc.setColor(_palette.dim, Graphics.COLOR_TRANSPARENT);
                    dc.setPenWidth(2);
                    var dashes = 24;
                    for (var i = 0; i < dashes; i++) {
                        if ((i % 3) != 0) {
                            continue;
                        }
                        var c0 = fromCompass + ((sweep * i) / dashes);
                        var c1 = fromCompass + ((sweep * (i + 0.6)) / dashes);
                        var d0 = ringAngle(c0 - offset);
                        // The end angle is derived from d0 and the real span
                        // between c0 and c1, never from wrapping c1 on its own.
                        // ringAngle's reflection has its own wrap point (where
                        // compassDeg - offset crosses 90), and offset is a live
                        // heading that can put that point anywhere - when it
                        // lands inside one dash's own tiny span, wrapping c0 and
                        // c1 independently can send them to opposite sides of
                        // 0/360 and round to the same degree, and a drawArc
                        // whose start equals its end draws a full circle instead
                        // of a sliver. Deriving the end from d0 by a fixed span
                        // can never collide with itself this way.
                        dc.drawArc(cx, cy, sr, Graphics.ARC_CLOCKWISE, d0,
                            ringArcEnd(d0, (c1 - c0).toNumber()));
                    }
                }
            }
        }

        // The sun itself. A fixed warm colour rather than the brightness ramp:
        // that ramp runs red at its dark end, and a red mark sitting alone on a
        // compass with nothing beside it to say "this means dim" reads as a
        // warning, not as a weak sun. The arc below still colours its own sun by
        // intensity - it sits on a dome that gives that reading context; this
        // one does not, so it stays legible instead.
        if (_azimuth >= 0.0) {
            var sunAt = ringAngle(_azimuth - offset);
            dc.setColor(_palette.accent, Graphics.COLOR_TRANSPARENT);
            // Flush with the ring, not proud of it. On a gauge a marker stands
            // out from the track because it annotates it; here the sun is not an
            // annotation, it IS what the ring is showing - and anything thicker
            // than the band reaches inside the inset the layout reserves and
            // lands on the hero. It earns its prominence from colour and from
            // being the widest thing on the ring instead.
            dc.setPenWidth(width);
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, (sunAt + 11) % 360, (sunAt - 11 + 360) % 360);
        }
        dc.setPenWidth(1);
    }

    // Compass degrees (clockwise from the top) to the drawing system's degrees
    // (counter-clockwise from three o'clock).
    private function ringAngle(compassDeg as Float) as Number {
        var a = 90.0 - compassDeg;
        while (a < 0.0) {
            a += 360.0;
        }
        while (a >= 360.0) {
            a -= 360.0;
        }
        return a.toNumber();
    }

    // ARC_CLOCKWISE's end angle, `spanDeg` around from `start`. Static so a
    // test can sweep it directly without rendering a whole compass frame - the
    // one thing that actually matters here, the result never equalling
    // `start`, is exactly what a render test that only checks "did this throw"
    // cannot catch: a degenerate arc and a correct tiny one look identical to it.
    static function ringArcEnd(start as Number, spanDeg as Number) as Number {
        var span = spanDeg;
        if (span < 1) {
            span = 1;
        }
        var end = start - span;
        while (end < 0) {
            end += 360;
        }
        return end;
    }

    // What the dial reports on each page. Showing live solar on all four made
    // every page look the same and put a bright irrelevant arc around the battery
    // and daylight readings; here the ring is the macro view of whatever the hero
    // is reporting.
    private function gaugeValue(page as Number) as Number {
        if (page == PAGE_HARVEST) {
            // Harvest so far as a share of time elapsed.
            var ticks = _model.ticks();
            if (ticks <= 0) {
                return 0;
            }
            return percentOf(_model.harvestSeconds(), ticks);
        } else if (page == PAGE_BATTERY) {
            var level = _model.batteryPercent();
            return (level < 0.0) ? 0 : (level + 0.5).toNumber();
        } else if (page == PAGE_WINDOW) {
            // Daylight still to come, which is what the hero is counting down.
            if (_sunrise > 0 && _sunset > _sunrise) {
                return percentOf(sunWindowRemaining(nowSeconds(), _sunrise, _sunset),
                    _sunset - _sunrise);
            }
            return ((_model.sunFraction() * 100) + 0.5).toNumber();
        } else if (page == PAGE_BONUS) {
            var share = offsetSharePercent();
            if (share > 0) {
                return share;
            }
            // Still measuring: follow the cumulative harvest the chart falls back
            // to, rather than sitting at zero as though the sun gave nothing.
            var ticks = _model.ticks();
            return (ticks <= 0) ? 0 : percentOf(_model.harvestSeconds(), ticks);
        } else if (page == PAGE_SKY) {
            var sky = skyPercent();
            if (sky != null) {
                return sky;
            }
            // An empty ring reads as a broken one. With no catching figure the
            // dial tracks the hero instead: the sun's height as a share of how
            // high it gets today.
            var peak = profilePeak();
            if (peak <= 0 || _elevation <= 0.0) {
                return 0;
            }
            return percentOf((_elevation + 0.5).toNumber(), peak);
        }
        return _model.smoothed();
    }

    private function gaugeColor(page as Number) as Number {
        if (page == PAGE_HARVEST) {
            return _palette.accent;
        } else if (page == PAGE_BATTERY) {
            var level = _model.batteryPercent();
            if (level >= 0.0 && level <= 15.0) {
                return _palette.drain;
            }
            var flow = _model.netFlowPerHour();
            return (flow != null && flow < -0.05) ? _palette.gain : _palette.fg;
        } else if (page == PAGE_WINDOW) {
            return (sunState() == SUN_NIGHT) ? _palette.muted : _palette.accent;
        } else if (page == PAGE_BONUS) {
            return (offsetSharePercent() > 0) ? _palette.gain : _palette.accent;
        } else if (page == PAGE_SKY) {
            var sky = skyPercent();
            // Deliberately off the intensity ramp in the fallback: the ring is
            // reporting a height, not a brightness, and colouring it like light
            // would invite it to be read as one.
            return (sky == null) ? _palette.fg : _palette.intensity(sky);
        }
        return _palette.intensity(_model.smoothed());
    }

    private function percentOf(part as Number, whole as Number) as Number {
        if (whole <= 0) {
            return 0;
        }
        var v = ((part * 100) + (whole / 2)) / whole;
        if (v < 0) {
            return 0;
        } else if (v > 100) {
            return 100;
        }
        return v;
    }

    private function drawPageDots(dc as Dc, cx as Number, y as Number, page as Number,
                                  mask as Number) as Void {
        var visible = countPages(mask, PAGE_COUNT);
        var spacing = 10;
        var x = cx - (((visible - 1) * spacing) / 2);
        var slot = 0;
        for (var i = 0; i < PAGE_COUNT; i++) {
            if ((mask & (1 << i)) == 0) {
                continue;
            }
            var here = (i == page);
            dc.setColor(here ? _palette.accent : _palette.muted, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x + (slot * spacing), y + 3, here ? 4 : 2);
            slot += 1;
        }
    }

    // Recent history as a continuous heat ribbon. Contiguous columns rather than
    // separated bars: at this size the gaps carry no information and cost the
    // shape its continuity.
    private function drawSparkline(dc as Dc, x as Number, y as Number, w as Number, h as Number) as Void {
        var n = _model.count();
        if (n < 1) {
            drawBaseline(dc, x, y, w, h);
            return;
        }
        var barW = w / SolarModel.HISTORY_SIZE;
        if (barW < 2) {
            barW = 2;
        }
        var startX = x + w - (n * barW);
        if (startX < x) {
            startX = x;
        }
        var lastColour = -1;
        for (var i = 0; i < n; i++) {
            var v = _model.sampleAt(i);
            var barH = (h * v) / 100;
            if (barH < 2 && v > 0) {
                barH = 2;
            }
            if (barH > 0) {
                // Neighbouring columns usually land in the same heat band, so
                // only touch the graphics state when the colour really changes.
                var colour = _palette.intensity(v);
                if (colour != lastColour) {
                    dc.setColor(colour, Graphics.COLOR_TRANSPARENT);
                    lastColour = colour;
                }
                dc.fillRectangle(startX + (i * barW), y + h - barH, barW, barH);
            }
        }
        drawBaseline(dc, x, y, w, h);

        // The session average, as a datum across the trace. Without it the
        // reader sees that the light varied but has nothing to judge any of it
        // against; with it, every column reads as above or below par at a
        // glance. The AVG chip underneath names the line.
        var avg = _model.average();
        if (avg > 0 && _model.ticks() > 30) {
            var avgY = y + h - ((h * avg) / 100);
            dc.setPenWidth(1);
            dc.setColor(_palette.dim, Graphics.COLOR_TRANSPARENT);
            // Dashed, so it reads as a reference rather than as data.
            for (var dx = 0; dx < w; dx += 6) {
                dc.drawLine(x + dx, avgY, x + dx + 3, avgY);
            }
        }

        // No "now" marker. The series is right-aligned and the newest column is
        // the right edge, so a full-height rule there marked something the axis
        // already said - while reading as a data spike and crowding the dial's
        // end cap.
    }

    // Cumulative harvest: filled area under a bright stroke. The fill is a dimmed
    // accent rather than grey, so the band and its edge read as one object.
    private function drawCumulative(dc as Dc, x as Number, y as Number, w as Number, h as Number) as Void {
        var n = _model.count();
        if (n < 2) {
            drawBaseline(dc, x, y, w, h);
            return;
        }
        var total = 0;
        for (var i = 0; i < n; i++) {
            total += _model.sampleAt(i);
        }
        if (total <= 0) {
            drawBaseline(dc, x, y, w, h);
            return;
        }
        // Two passes, each setting its colour once. Setting colour and pen width
        // per sample costs more than the drawing does at this size.
        var stepX = w.toFloat() / (n - 1);
        var running = 0;
        var prevX = x;
        var prevY = y + h;
        dc.setColor(_palette.accentFill, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < n; i++) {
            running += _model.sampleAt(i);
            var px = x + (i * stepX).toNumber();
            var py = y + h - ((h * running) / total);
            if (i > 0) {
                dc.fillRectangle(prevX, py, (px - prevX) + 1, (y + h) - py);
            }
            prevX = px;
            prevY = py;
        }
        // Even-pace reference: the straight line the curve would follow if the
        // sun had delivered at a constant rate for the whole activity. Normalising
        // by the total means this curve ALWAYS ends in the top right corner, so
        // without a reference its shape says nothing - you cannot tell a bowed
        // curve from a straight one by eye. Against the diagonal it becomes a
        // reading: bulging above it means the harvest came early, sagging below
        // it means most of it arrived late.
        dc.setPenWidth(1);
        dc.setColor(_palette.dim, Graphics.COLOR_TRANSPARENT);
        for (var dx = 0; dx < w; dx += 7) {
            var ex = (dx + 4 > w) ? w : dx + 4;
            dc.drawLine(x + dx, y + h - ((h * dx) / w),
                x + ex, y + h - ((h * ex) / w));
        }

        running = 0;
        prevX = x;
        prevY = y + h;
        dc.setPenWidth(3);
        dc.setColor(_palette.accent, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < n; i++) {
            running += _model.sampleAt(i);
            var px = x + (i * stepX).toNumber();
            var py = y + h - ((h * running) / total);
            if (i > 0) {
                dc.drawLine(prevX, prevY, px, py);
            }
            prevX = px;
            prevY = py;
        }
        dc.setPenWidth(1);
        drawBaseline(dc, x, y, w, h);
    }

    // A battery icon, not a chart: the shape everyone already reads at a glance,
    // filled green to the live level, animated to show which way it is moving.
    //
    // A step-trace needs history to say anything - sparse on a short activity,
    // and fighting for scale-label space the rest of the time. This needs none:
    // the level and the current flow direction are both known from the first
    // valid reading, so the page looks exactly as complete one second in as it
    // does an hour in.
    //
    // Kept as one function with everything inlined, no helpers, minimal named
    // locals. That is not a style choice: this call chain
    // (onUpdate -> drawChart -> drawBatteryTrace) sits at its stack ceiling at
    // this depth on the smallest supported devices - one more call frame
    // overflows it regardless of how little that call does, and so does reusing
    // a couple of extra named locals across two statements. Both are avoided
    // here on purpose.
    private function drawBatteryTrace(dc as Dc, x as Number, y as Number, w as Number, h as Number) as Void {
        var level = _model.batteryPercent();
        if (level < 0.0) {
            drawBaseline(dc, x, y, w, h);
            return;
        }

        // A classic horizontal cell: body plus a small terminal nub, sized to
        // use the whole band rather than sitting small in the middle of it.
        var pad = 4;
        var nubW = (h - (2 * pad)) / 3;
        var bodyW = w - nubW - 6;
        var bodyH = h - (2 * pad);
        var bodyY = y + pad;
        var radius = 4;

        dc.setColor(_palette.fg, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRoundedRectangle(x, bodyY, bodyW, bodyH, radius);
        dc.fillRoundedRectangle(x + bodyW + 3, bodyY + (bodyH / 4), nubW, bodyH / 2, 2);
        dc.setPenWidth(1);

        var fillW = (((bodyW - 8) * level) / 100).toNumber();
        if (fillW > 0) {
            dc.setColor(_palette.gain, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x + 4, bodyY + 4, fillW, bodyH - 8);
        }

        // Which way it is moving, from the same measured or provisional rate
        // the RATE chip already shows - the animation and the number it sits
        // beside can never disagree, because they read the same call.
        var flow = _model.netFlowPerHour();
        if (flow == null) {
            flow = _model.provisionalNetFlowPerHour();
        }
        if (flow == null || fillW < 10) {
            return;
        }

        // Two bright bands sliding through the fill - up through it for a
        // gain, down through it for a drain - built from System.getTimer() so
        // they visibly move from one onUpdate() to the next during a real
        // activity, the one place on this page motion can carry information a
        // static fill cannot: which way the level is headed right now, not
        // only what it has already done.
        //
        // Two explicit bands rather than a loop over several, and their
        // position computed inline rather than held in a named local - the
        // pattern the projection line on this exact page needed to stop
        // overflowing the stack, applied here before it has the chance to.
        var cycle = bodyH - 8;
        if (cycle < 6) {
            return;
        }
        var phase = (System.getTimer() / 90) % cycle;
        dc.setColor(_palette.fg, Graphics.COLOR_TRANSPARENT);
        if (flow < -0.05) {
            dc.fillRectangle(x + 4, (bodyY + bodyH - 4) - phase, fillW, 2);
            dc.fillRectangle(x + 4, (bodyY + bodyH - 4) - ((phase + (cycle / 2)) % cycle), fillW, 2);
        } else if (flow > 0.05) {
            dc.fillRectangle(x + 4, bodyY + 4 + phase, fillW, 2);
            dc.fillRectangle(x + 4, bodyY + 4 + ((phase + (cycle / 2)) % cycle), fillW, 2);
        }
    }

    // Where to actually look for the sun: across for left and right, up for how
    // high. The ring above gives the bearing; this gives the thing the ring
    // cannot, which is that the sun is also somewhere between the horizon and
    // straight up. Together they place it in the sky rather than on a dial.
    //
    // The horizontal span is the 180 degrees in front of the user, so a sun that
    // is behind them pins to whichever edge it is nearer and stops there - being
    // told to turn round is the useful answer, and there is no sensible place on
    // a forward view to draw something that is not in front of you.
    private function drawSkyView(dc as Dc, x as Number, y as Number, w as Number, h as Number) as Void {
        var horizonY = y + h - 2;
        dc.setPenWidth(2);
        dc.setColor(_palette.dim, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x, horizonY, x + w, horizonY);

        // The sun's whole path across today's sky: bearing across, height up.
        //
        // The ring above already answers "which way is the sun". This answers the
        // question the ring cannot - where it has come from and where it is going
        // - which is what anyone choosing a side of a trail, or deciding whether
        // to wait ten minutes, is actually asking. Plotted against the day's own
        // bearing range rather than the 180 degrees in front of the user, because
        // framing it forward-only left most of the arc off the chart and turned a
        // sun path into a stub.
        //
        // Solid behind, dotted ahead, exactly as the daylight arc marks spent
        // against remaining: one visual language for one idea, on both pages.
        var peak = profilePeak();
        var lo = unwrappedAzimuths();
        if (lo == null || peak <= 0) {
            dc.setPenWidth(1);
            return;
        }
        // All three come from unwrappedAzimuths so that every bearing below is
        // unwrapped against the SAME reference the range was measured against.
        // Unwrapping against minA instead looks equivalent and is not: a day
        // sweeps about 190 degrees at this latitude, so every afternoon bearing
        // sits more than 180 from the morning minimum and gets folded back a
        // whole turn - which collapsed the afternoon half of the arc onto
        // negative x and left a stub lying along the horizon.
        var minA = lo[0];
        var maxA = lo[1];
        var spanA = maxA - minA;
        if (spanA < 1.0) {
            dc.setPenWidth(1);
            return;
        }

        var nowIndex = nowProfileIndex();
        var sky = horizonY - y;
        var prevPx = -1;
        var prevPy = -1;
        for (var i = 0; i < PROFILE_POINTS; i++) {
            if (_azProfile[i] < 0 || _profile[i] <= 0) {
                prevPx = -1;
                continue;
            }
            var px = x + ((w * (_azWalk[i] - minA)) / spanA).toNumber();
            var py = horizonY - ((sky * _profile[i]) / peak);
            if (prevPx >= 0) {
                var behind = (i <= nowIndex);
                dc.setPenWidth(behind ? 3 : 2);
                dc.setColor(behind ? _palette.accent : _palette.dim,
                    Graphics.COLOR_TRANSPARENT);
                if (behind) {
                    dc.drawLine(prevPx, prevPy, px, py);
                } else {
                    for (var k = 0; k < 3; k++) {
                        var t0 = k / 3.0;
                        var t1 = t0 + 0.2;
                        dc.drawLine(prevPx + ((px - prevPx) * t0).toNumber(),
                                    prevPy + ((py - prevPy) * t0).toNumber(),
                                    prevPx + ((px - prevPx) * t1).toNumber(),
                                    prevPy + ((py - prevPy) * t1).toNumber());
                    }
                }
            }
            prevPx = px;
            prevPy = py;
        }

        // Where the user is pointed, against that arc. Only drawn when the
        // heading actually falls inside the day's bearing range - a marker
        // clamped to an edge would claim a direction the sun never takes.
        if (_heading >= 0.0) {
            var hu = unwrap(_heading, (minA + maxA) / 2.0);
            if (hu >= minA && hu <= maxA) {
                var hx = x + ((w * (hu - minA)) / spanA).toNumber();
                dc.setPenWidth(1);
                dc.setColor(_palette.fg, Graphics.COLOR_TRANSPARENT);
                for (var dy = y; dy < horizonY; dy += 6) {
                    dc.drawLine(hx, dy, hx, dy + 3);
                }
                dc.fillPolygon([[hx - 4, horizonY], [hx + 4, horizonY], [hx, horizonY - 6]]);
            }
        }

        if (_elevation <= 0.0 || _azimuth < 0.0) {
            dc.setPenWidth(1);
            return;
        }

        // The useful-sun threshold, dashed across the band at the elevation this
        // app already treats as the floor for a worthwhile reading everywhere
        // else (the same MIN_USEFUL_ELEVATION the CATCHING page's percentage is
        // computed against). Marking it here makes an already-load-bearing model
        // parameter visible instead of implicit: the reader can see, directly on
        // the shape of the day, how much of what is left is actually worth
        // anything - not merely that the sun is technically still up.
        //
        // Skipped on a day too weak to clear it at all: a threshold sitting at or
        // above the dome's own peak would draw across empty sky and explain
        // nothing.
        if (SolarGeometry.MIN_USEFUL_ELEVATION < peak) {
            var usefulY = horizonY - ((sky * SolarGeometry.MIN_USEFUL_ELEVATION) / peak);
            dc.setPenWidth(1);
            dc.setColor(_palette.dim, Graphics.COLOR_TRANSPARENT);
            // Stepped by 10px rather than 6: this page turned out to be the most
            // expensive to render once its stress-test numbers were actually
            // checked, almost entirely from dash counts like this one. Wider
            // spacing cuts the draw calls by nearly half for a gap difference
            // nobody reading a dashed reference line at a glance will notice.
            for (var ux = x; ux < (x + w); ux += 10) {
                dc.drawLine(ux, usefulY, ux + 4, usefulY);
            }
        }

        // The sun itself, on its own path.
        var sunX = x + ((w * (unwrap(_azimuth, (minA + maxA) / 2.0) - minA)) / spanA).toNumber();
        var sunY = horizonY - ((sky * (_elevation + 0.5).toNumber()) / peak);
        // Capped, not just floored. Tied to band height alone the disc grew with
        // the chart and started dominating the arc it is supposed to sit on.
        var rad = (h / 7);
        if (rad < 4) {
            rad = 4;
        } else if (rad > 9) {
            rad = 9;
        }
        // Clamped by the ray length, not the disc radius: the rays reach 1.9r, so
        // keeping only the disc inside the band still let them cross into the
        // hero above and the chips below.
        var reach = (rad * 19) / 10;
        if (sunY < (y + reach)) {
            sunY = y + reach;
        } else if (sunY > (horizonY - 1)) {
            sunY = horizonY - 1;
        }
        if (sunX < (x + reach)) {
            sunX = x + reach;
        } else if (sunX > (x + w - reach)) {
            sunX = x + w - reach;
        }
        var hue = _palette.intensity(_model.smoothed());
        dc.setColor(hue, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(sunX, sunY, rad);
        dc.setPenWidth(2);
        for (var i = 0; i < 4; i++) {
            var a = (i * Math.PI) / 4.0;
            var dxr = (Math.cos(a) * rad * 1.9).toNumber();
            var dyr = (Math.sin(a) * rad * 1.9).toNumber();
            dc.drawLine(sunX - dxr, sunY - dyr, sunX + dxr, sunY + dyr);
        }
        // Cut back to a ring so the rays read as rays rather than as a blob.
        dc.setColor(_palette.bg, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(sunX, sunY, rad - 1);
        dc.setColor(hue, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(sunX, sunY, rad - 2);
        dc.setPenWidth(1);
    }

    // The day's bearing range, read off the walked series. Returns [min, max],
    // or null when there is no usable path.
    private function unwrappedAzimuths() as Array<Float>? {
        var seen = false;
        var minA = 0;
        var maxA = 0;
        for (var i = 0; i < PROFILE_POINTS; i++) {
            if (_azProfile[i] < 0 || _profile[i] <= 0) {
                continue;
            }
            var v = _azWalk[i];
            if (!seen) {
                minA = v;
                maxA = v;
                seen = true;
            } else if (v < minA) {
                minA = v;
            } else if (v > maxA) {
                maxA = v;
            }
        }
        return seen ? ([minA.toFloat(), maxA.toFloat()] as Array<Float>) : null;
    }

    // A bearing expressed on the same turn as `near`, so subtraction is stable
    // across the 0/360 seam.
    private function unwrap(bearing as Float, near as Float) as Float {
        var b = bearing;
        while ((b - near) > 180.0) {
            b -= 360.0;
        }
        while ((near - b) > 180.0) {
            b += 360.0;
        }
        return b;
    }

    // Which profile sample "now" falls on, so the path can be split at it.
    private function nowProfileIndex() as Number {
        if (_sunrise <= 0 || _sunset <= _sunrise) {
            return PROFILE_POINTS;
        }
        var through = (nowSeconds() - _sunrise).toFloat() / (_sunset - _sunrise);
        if (through < 0.0) {
            return 0;
        } else if (through > 1.0) {
            return PROFILE_POINTS;
        }
        return (through * (PROFILE_POINTS - 1)).toNumber();
    }

    // What the sun paid for, as a part-to-whole of what the hour would otherwise
    // have cost: of the drain this watch would show with no sun on it, the green
    // share is what the sun covered and the orange is what the battery still paid.
    //
    // A part-to-whole says this far better than two bars side by side, because the
    // bonus IS a share of the larger figure rather than a separate quantity, and
    // the reader should not have to subtract one bar from another to see it.
    private function drawBonusBars(dc as Dc, x as Number, y as Number, w as Number, h as Number) as Void {
        // Caller guarantees a split; the no-data case draws the cumulative
        // harvest as a sibling call instead.
        var split = bonusSplit();
        if (split == null) {
            return;
        }
        var lit = split[0];
        var paid = split[1];
        var base = lit + paid;
        if (base <= 0.0) {
            return;
        }

        var labelH = _zoneLabelH;
        var barH = h - labelH;
        if (barH < 8) {
            barH = h;
            labelH = 0;
        }
        var savedW = (w * (lit / base)).toNumber();
        if (savedW > w) {
            savedW = w;
        }

        dc.setColor(_palette.gain, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y, savedW, barH);
        dc.setColor(_palette.drain, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x + savedW, y, w - savedW, barH);

        if (labelH > 0) {
            // Direct labels, measured per segment exactly as the zone bar does, so
            // a thin share is named when it fits and dropped when it cannot be.
            var left = "+" + lit.format("%.1f");
            var right = "-" + paid.format("%.1f");
            if (savedW >= (dc.getTextWidthInPixels(left, Graphics.FONT_XTINY) + 2)) {
                dc.setColor(_palette.gain, Graphics.COLOR_TRANSPARENT);
                dc.drawText(x + (savedW / 2), y + barH, Graphics.FONT_XTINY, left,
                    Graphics.TEXT_JUSTIFY_CENTER);
            }
            if ((w - savedW) >= (dc.getTextWidthInPixels(right, Graphics.FONT_XTINY) + 2)) {
                dc.setColor(_palette.drain, Graphics.COLOR_TRANSPARENT);
                dc.drawText(x + savedW + ((w - savedW) / 2), y + barH, Graphics.FONT_XTINY,
                    right, Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
    }

    // Light zones as a single stacked bar. This is a part-to-whole breakdown, and
    // a stacked bar states that directly: four separate columns force the reader
    // to add them up to see that they are shares of one activity.
    private function drawZones(dc as Dc, x as Number, y as Number, w as Number, h as Number) as Void {
        var marks = [0, SolarModel.ZONE_DARK, SolarModel.ZONE_MODERATE, SolarModel.ZONE_HIGH];
        var barH = h - _zoneLabelH;
        if (barH < 8) {
            barH = h;
        }
        var top = y + ((h - barH) / 2);
        if (_zoneLabelH > 0 && barH < h) {
            top = y;
        }

        dc.setColor(_palette.muted, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, top, w, barH);

        var cursor = x;
        for (var z = 0; z < SolarModel.ZONE_COUNT; z++) {
            var fraction = _model.zoneFraction(z);
            var segW = (w * fraction).toNumber();
            if (segW <= 0) {
                continue;
            }
            if ((cursor + segW) > (x + w)) {
                segW = (x + w) - cursor;
            }
            dc.setColor(_palette.intensity(marks[z] + 5), Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(cursor, top, segW, barH);
            // A hairline of background between shares. Without it the bar is one
            // block of shifting colour and a share too narrow to label simply
            // vanishes, which leaves the labelled ones looking like they should
            // add up to a hundred and failing to.
            if (cursor > x) {
                dc.setColor(_palette.bg, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(cursor, top, 1, barH);
            }
            cursor += segW;
        }

        // Direct labelling under each share, which the field has no room for a
        // legend to do.
        if (_zoneLabelH > 0 && barH < h) {
            cursor = x;
            for (var z = 0; z < SolarModel.ZONE_COUNT; z++) {
                var fraction = _model.zoneFraction(z);
                var segW = (w * fraction).toNumber();
                var label = ((fraction * 100) + 0.5).toNumber().format("%d") + "%";
                // Measured per label, not against the widest possible one, so a
                // narrow share still gets named instead of silently dropping out.
                if (segW >= (dc.getTextWidthInPixels(label, Graphics.FONT_XTINY) + 2)) {
                    dc.setColor(_palette.intensity(marks[z] + 5), Graphics.COLOR_TRANSPARENT);
                    dc.drawText(cursor + (segW / 2), top + barH, Graphics.FONT_XTINY,
                        label, Graphics.TEXT_JUSTIFY_CENTER);
                }
                cursor += segW;
            }
        }
    }

    // The day's sun arc: elevation from sunrise to sunset, with the part already
    // walked through filled in and a marker on now.
    //
    // This is the chart that answers "is it worth waiting?" - it shows at a glance
    // whether the sun is still climbing or already on its way down, which a
    // countdown to sunset cannot say on its own.
    private function drawDaylightArc(dc as Dc, x as Number, y as Number, w as Number, h as Number) as Void {
        var peak = 0;
        for (var i = 0; i < PROFILE_POINTS; i++) {
            if (_profile[i] > peak) {
                peak = _profile[i];
            }
        }
        if (peak <= 0) {
            // Caller draws the light mix instead when there is no profile.
            return;
        }

        var now = nowSeconds();
        var span = _sunset - _sunrise;
        var progress = 0.0;
        if (span > 0) {
            progress = (now - _sunrise).toFloat() / span;
            if (progress < 0.0) {
                progress = 0.0;
            } else if (progress > 1.0) {
                progress = 1.0;
            }
        }
        var nowX = x + (w * progress).toNumber();

        var stepX = w.toFloat() / (PROFILE_POINTS - 1);
        var prevX = x;
        var prevY = y + h;
        dc.setPenWidth(2);
        for (var i = 0; i < PROFILE_POINTS; i++) {
            var px = x + (i * stepX).toNumber();
            var py = y + h - ((h * _profile[i]) / peak);
            if (i > 0) {
                var band = (px - prevX) + 1;
                // Behind: the sun already spent. Ahead: what is still to come.
                //
                // Both halves get the same hue and the same silhouette; only the
                // fill texture separates them - solid behind, hatched ahead. The
                // obvious encoding is to dim the future, and that is what this
                // used to do, but it put the one half of the chart the user can
                // still act on at the lowest contrast on the page: on a reflective
                // display a grey fill on black is all but gone in sunlight.
                // Emphasis should follow what is actionable, not what is past.
                var behind = (px <= nowX);
                dc.setColor(_palette.accentFill, Graphics.COLOR_TRANSPARENT);
                if (behind) {
                    dc.fillRectangle(prevX, py, band, (y + h) - py);
                } else {
                    // Hatched by pixel column rather than by sample, so the
                    // texture stays the same weight however few samples are left.
                    for (var hx = prevX; hx < (prevX + band); hx += 3) {
                        dc.drawLine(hx, py, hx, y + h);
                    }
                }
                dc.setColor(_palette.accent, Graphics.COLOR_TRANSPARENT);
                dc.drawLine(prevX, prevY, px, py);
            }
            prevX = px;
            prevY = py;
        }

        dc.setColor(_palette.fg, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(nowX, y, nowX, y + h);
        dc.setPenWidth(1);
        drawBaseline(dc, x, y, w, h);
    }

    private function drawBaseline(dc as Dc, x as Number, y as Number, w as Number, h as Number) as Void {
        dc.setPenWidth(2);
        dc.setColor(_palette.muted, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x, y + h + 1, x + w, y + h + 1);
        dc.setPenWidth(1);
    }

    // -- helpers ----------------------------------------------------------

    private function refreshSafeArea(w as Number, h as Number) as Void {
        var flags = getObscurityFlags();
        if (flags == _flags) {
            return;
        }
        _flags = flags;
        var all = DataField.OBSCURE_TOP | DataField.OBSCURE_BOTTOM
            | DataField.OBSCURE_LEFT | DataField.OBSCURE_RIGHT;
        _fullScreen = ((flags & all) == all);
        _safe.configure(_round, _screenW, _screenH, w, h, flags);
    }

    // Local clock time, in the user's own 12 or 24 hour preference.
    private function clockText(epochSeconds as Number) as String {
        try {
            var info = Gregorian.info(new Time.Moment(epochSeconds), Time.FORMAT_SHORT);
            var hour = info.hour;
            if (!System.getDeviceSettings().is24Hour) {
                hour = hour % 12;
                if (hour == 0) {
                    hour = 12;
                }
            }
            return hour.format("%d") + ":" + info.min.format("%02d");
        } catch (ex) {
            return "--:--";
        }
    }

    // The activity profile decides the data screen's background, so a field that
    // only ever follows it gives the user no way to ask for the other one.
    private function backgroundColor() as Number {
        if (_theme == 1) {
            return Graphics.COLOR_BLACK;
        } else if (_theme == 2) {
            return Graphics.COLOR_WHITE;
        }
        return getBackgroundColor();
    }

    // -- calibration carried between activities ---------------------------
    //
    // Storage holds the committed calibration and, separately, a snapshot of
    // the activity in progress tagged with that activity's start time. The
    // snapshot is what survives a crash or firmware that never delivers
    // onTimerReset; the tag is what stops one activity being counted twice.
    // The rule that keeps the total exact: the committed calibration never
    // includes an activity whose snapshot is still pending, and a snapshot is
    // only folded in by a different activity or by its own activity's end.
    //
    // Wherever the two writes could be interrupted, the snapshot is removed
    // before the merged total is written. An interruption then loses one
    // activity's evidence instead of counting it twice. All of it is best
    // effort: a device that refuses storage measures each activity from
    // scratch, as this field always did.

    private function loadCalibration() as Void {
        try {
            var stored = Application.Storage.getValue(CAL_KEY);
            if (stored instanceof Lang.Array && stored.size() > 0 && stored[0] == CAL_VERSION) {
                var c = SolarModel.calibrationFrom(stored, 1);
                if (c != null) {
                    _model.setCalibration(c);
                }
            }
            migrateLegacy(stored == null);
        } catch (ex) {
            // Nothing carried over; the model measures from scratch.
        }
    }

    // Carries the first release's saving forward once (see
    // SolarModel.calibrationFromLegacy), and only onto a watch with nothing
    // newer committed, then removes the old keys. An interruption between the
    // two leaves a committed calibration behind, which stops it happening twice.
    private function migrateLegacy(nothingCommitted as Boolean) as Void {
        var saving = Application.Storage.getValue(LEGACY_SAVING_KEY);
        if (saving == null && Application.Storage.getValue(LEGACY_DRAIN_KEY) == null) {
            return;
        }
        if (nothingCommitted
            && (saving instanceof Lang.Float || saving instanceof Lang.Number || saving instanceof Lang.Double)) {
            var seed = SolarModel.calibrationFromLegacy((saving as Numeric).toFloat());
            if (seed != null) {
                storeCalibration(seed);
            }
        }
        Application.Storage.deleteValue(LEGACY_SAVING_KEY);
        Application.Storage.deleteValue(LEGACY_DRAIN_KEY);
    }

    // A snapshot left by any other activity joins the committed calibration
    // before this activity can write its own over it. One this activity wrote
    // itself is left where it is.
    private function absorbStalePending() as Void {
        try {
            var pending = Application.Storage.getValue(CAL_PENDING_KEY);
            if (!(pending instanceof Lang.Array)) {
                return;
            }
            var add = null;
            if (pending.size() > 1 && pending[0] == CAL_VERSION
                && (pending[1] instanceof Lang.Number || pending[1] instanceof Lang.Long)) {
                if ((pending[1] as Numeric).toNumber() == _activityTag) {
                    return;
                }
                add = SolarModel.calibrationFrom(pending, 2);
            }
            Application.Storage.deleteValue(CAL_PENDING_KEY);
            if (add != null) {
                storeCalibration(SolarModel.mergeCalibration(_model.calibration(), add));
            }
        } catch (ex) {
            // Left for the next activity to try again.
        }
    }

    // This activity's contribution so far. Written over itself, so saving it
    // every few minutes and again at every stop never adds anything twice.
    private function writePending() as Void {
        if (_activityTag < 0) {
            return;
        }
        var a = _model.activityCalibration();
        if (a[0] <= 0.0 && a[5] <= 0.0) {
            return;
        }
        try {
            Application.Storage.setValue(CAL_PENDING_KEY,
                [CAL_VERSION, _activityTag, a[0], a[1], a[2], a[3], a[4], a[5], a[6]]
                    as Array<Numeric>);
        } catch (ex) {
            // Not being able to remember is not a reason to fail the activity.
        }
    }

    // The activity is over: what it measured joins the committed calibration.
    private function commitActivity() as Void {
        try {
            absorbStalePending();
            var a = _model.activityCalibration();
            Application.Storage.deleteValue(CAL_PENDING_KEY);
            if (a[0] > 0.0 || a[5] > 0.0) {
                storeCalibration(SolarModel.mergeCalibration(_model.calibration(), a));
            }
        } catch (ex) {
            // The snapshot, if written, is folded in by the next activity.
        }
        _activityTag = -1;
    }

    private function storeCalibration(c as Array<Float>) as Void {
        _model.setCalibration(c);
        Application.Storage.setValue(CAL_KEY,
            [CAL_VERSION, c[0], c[1], c[2], c[3], c[4], c[5], c[6], SolarModel.cyyOf(c)] as Array<Numeric>);
    }

    private function percentText(fraction as Float) as String {
        return ((fraction * 100) + 0.5).toNumber().format("%d") + "%";
    }

    private function nowSeconds() as Number {
        return (_clockOverride > 0) ? _clockOverride : Time.now().value();
    }

    private function sunState() as Number {
        return sunWindowState(nowSeconds(), _sunrise, _sunset);
    }

    private function readIntensity(stats as System.Stats) as Number? {
        if (!(stats has :solarIntensity)) {
            return null;
        }
        var value = stats.solarIntensity;
        if (value == null) {
            return null;
        }
        var intensity = value.toNumber();
        if (intensity < 0) {
            return 0;
        } else if (intensity > 100) {
            return 100;
        }
        return intensity;
    }

    private function readDaysLeft(stats as System.Stats) as Float {
        var days = -1.0;
        if (stats has :batteryInDays) {
            var value = stats.batteryInDays;
            if (value instanceof Lang.Float) {
                days = value;
            }
        }
        return days;
    }

    // Sun times need a fix and are expensive, so they are refreshed sparingly.
    // Which way the user is facing, in degrees from north.
    //
    // The compass first and the GPS course second: the magnetometer still reads
    // while standing still, and course over ground does not - it goes null the
    // moment you stop, which is exactly when someone would look at a compass.
    // Neither needs a permission beyond the Positioning one already held.
    private function readHeading(info as Activity.Info) as Void {
        var radians = null;
        if (info has :currentHeading && info.currentHeading != null) {
            radians = info.currentHeading;
        } else if (info has :track && info.track != null) {
            radians = info.track;
        }
        if (radians == null) {
            _heading = -1.0;
            return;
        }
        var deg = radians * (180.0 / Math.PI);
        while (deg < 0.0) {
            deg += 360.0;
        }
        while (deg >= 360.0) {
            deg -= 360.0;
        }
        _heading = deg.toFloat();
    }

    // Where the sun sits relative to straight ahead: 0 is dead ahead, 90 is to
    // the right, 180 behind. Null when there is nothing to measure against.
    private function relativeBearing() as Float? {
        if (_azimuth < 0.0 || _heading < 0.0) {
            return null;
        }
        var rel = _azimuth - _heading;
        while (rel < 0.0) {
            rel += 360.0;
        }
        while (rel >= 360.0) {
            rel -= 360.0;
        }
        return rel;
    }

    // A bearing as a compass point. Sixteen points rather than eight, because a
    // sun quoted as "W" when it is actually WNW sends someone the wrong way down
    // a trail, and rather than degrees because nobody faces 247.
    private function compassPoint(bearing as Float) as String {
        if (bearing < 0.0) {
            return "--";
        }
        var points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"];
        var index = (((bearing + 11.25) / 22.5).toNumber()) % 16;
        return points[index];
    }

    private function sunIsUp() as Boolean {
        return _hasFix && _elevation > 0.0 && _azimuth >= 0.0;
    }

    private function updateSunTimes(info as Activity.Info) as Void {
        _sunTick += 1;
        if (_sunset > 0 && _sunTick < SUNSET_REFRESH) {
            return;
        }
        _sunTick = 0;
        if (!(info has :currentLocation) || !(Weather has :getSunset)) {
            return;
        }
        var location = info.currentLocation;
        if (location == null) {
            return;
        }
        try {
            var now = Time.now();
            var sunset = Weather.getSunset(location, now);
            if (sunset != null) {
                _sunset = sunset.value();
            }
            var sunrise = Weather.getSunrise(location, now);
            if (sunrise != null) {
                _sunrise = sunrise.value();
            }
            var radians = location.toRadians();
            _latRad = radians[0];
            _lonRad = radians[1];
            _hasFix = true;
            _profileValid = false;

            // Weather.getSunset() reads cached weather, so a watch that has not
            // synced with its phone returns null and every daylight feature
            // quietly disappears. Sunrise is geometry: fall back to computing it,
            // which needs nothing but the fix we already have.
            if (_sunset <= 0 || _sunrise <= 0) {
                var events = SolarGeometry.sunEvents(now.value(), _latRad, _lonRad);
                if (events != null) {
                    _sunrise = events[0];
                    _sunset = events[1];
                }
            }
        } catch (ex) {
            _sunrise = -1;
            _sunset = -1;
            _hasFix = false;
        }
        updateWeather();
    }

    // Cached conditions. Both readings corroborate the sky index: a low index
    // under a high UV with clear sky means the panel itself is covered.
    private function updateWeather() as Void {
        if (!(Weather has :getCurrentConditions)) {
            return;
        }
        try {
            var conditions = Weather.getCurrentConditions();
            if (conditions == null) {
                return;
            }
            if (conditions has :uvIndex) {
                var uv = conditions.uvIndex;
                _uvIndex = (uv == null) ? -1.0 : uv.toFloat();
            }
            if (conditions has :cloudCover) {
                var cloud = conditions.cloudCover;
                _cloudCover = (cloud == null) ? -1 : cloud.toNumber();
            }
        } catch (ex) {
            _uvIndex = -1.0;
            _cloudCover = -1;
        }
    }

    // Sun elevation now, recomputed on the slow tick rather than per frame.
    private function refreshElevation() as Void {
        if (!_hasFix) {
            _elevation = -99.0;
            return;
        }
        try {
            var at = nowSeconds();
            _elevation = SolarGeometry.elevationDegrees(at, _latRad, _lonRad);
            // Whether the sun is still on its way up. Fifteen minutes is long
            // enough to clear the noise in the closed form and short enough that
            // the answer is about now rather than about this afternoon.
            _rising = SolarGeometry.elevationDegrees(at + 900, _latRad, _lonRad) > _elevation;
            _azimuth = SolarGeometry.azimuthDegrees(at, _latRad, _lonRad);
        } catch (ex) {
            _elevation = -99.0;
            _azimuth = -1.0;
        }
    }

    // The sun's highest point today, from the profile already built for the
    // daylight arc. Used to scale the sun-height dial, so the ring reads as
    // "how far up its own arc the sun has got" rather than against a flat 90.
    private function profilePeak() as Number {
        var peak = 0;
        for (var i = 0; i < PROFILE_POINTS; i++) {
            if (_profile[i] > peak) {
                peak = _profile[i];
            }
        }
        return peak;
    }

    // Elevation across the whole daylight window, sampled once per sun refresh
    // so the arc chart is not recomputing trigonometry every frame.
    private function refreshProfile() as Void {
        _profileValid = true;
        for (var i = 0; i < PROFILE_POINTS; i++) {
            _profile[i] = 0;
        }
        if (!_hasFix || _sunrise <= 0 || _sunset <= _sunrise) {
            return;
        }
        var span = _sunset - _sunrise;
        for (var i = 0; i < PROFILE_POINTS; i++) {
            var at = _sunrise + ((span * i) / (PROFILE_POINTS - 1));
            var e = 0.0;
            var a = -1.0;
            try {
                e = SolarGeometry.elevationDegrees(at, _latRad, _lonRad);
                // The bearing at each point too, so the sky view can draw the
                // path the sun actually takes rather than only where it is now.
                // Both sit behind the same _profileValid gate and are built here
                // rather than in a draw call, for the reason above.
                a = SolarGeometry.azimuthDegrees(at, _latRad, _lonRad);
            } catch (ex) {
                e = 0.0;
                a = -1.0;
            }
            _profile[i] = (e < 0.0) ? 0 : (e + 0.5).toNumber();
            _azProfile[i] = (a < 0.0) ? -1 : (a + 0.5).toNumber();
        }

        // Walk the bearings into a continuous series, stepping by the shortest
        // turn between neighbours. Consecutive samples are only a few degrees
        // apart, so the step is never ambiguous, and the running total stays
        // monotonic across a sweep of any width and across the 0/360 seam.
        var acc = 0;
        var prev = -1;
        for (var i = 0; i < PROFILE_POINTS; i++) {
            if (_azProfile[i] < 0) {
                _azWalk[i] = acc;
                continue;
            }
            if (prev < 0) {
                acc = _azProfile[i];
            } else {
                var d = _azProfile[i] - prev;
                if (d > 180) {
                    d -= 360;
                } else if (d < -180) {
                    d += 360;
                }
                acc += d;
            }
            prev = _azProfile[i];
            _azWalk[i] = acc;
        }
    }

    // Full-sun-equivalent seconds still to be had before sunset.
    //
    // The naive version multiplies the time left by the current reading, which
    // assumes the sun stays where it is until it abruptly sets. This instead
    // integrates the sun's own elevation profile over the rest of the day and
    // scales it by how much of the available light is actually reaching the panel,
    // so an hour before sunset forecasts far less than an hour at noon.
    // Read only. Nothing is computed from the draw path.
    private function forecastHarvestSeconds() as Number {
        return _forecastCache;
    }

    private function refreshForecast() as Void {
        _forecastValid = true;
        _forecastCache = computeForecastSeconds();
    }

    private function computeForecastSeconds() as Number {
        var remaining = sunWindowRemaining(nowSeconds(), _sunrise, _sunset);
        if (remaining <= 0) {
            return 0;
        }
        var sky = skyPercent();
        if (!_hasFix || !_profileValid || sky == null || _sunset <= _sunrise) {
            // No geometry to work from: fall back to holding the current reading.
            return _model.projectedHarvestSeconds(remaining);
        }
        var span = _sunset - _sunrise;
        var slice = span / (PROFILE_POINTS - 1);
        var now = nowSeconds();
        var total = 0.0;
        for (var i = 0; i < PROFILE_POINTS - 1; i++) {
            var at = _sunrise + (slice * i);
            if ((at + slice) <= now) {
                continue;
            }
            var seconds = slice;
            if (at < now) {
                seconds = (at + slice) - now;
            }
            // Mean available light across the slice, times what actually lands.
            var available = (SolarGeometry.availableFraction(_profile[i].toFloat())
                + SolarGeometry.availableFraction(_profile[i + 1].toFloat())) / 2.0;
            total += seconds * available * (sky / 100.0);
        }
        return total.toNumber();
    }

    private function skyPercent() as Number? {
        if (!_skyValid) {
            _skyValid = true;
            _skyCache = (_model.ticks() <= 0)
                ? null
                : SolarGeometry.clearSkyPercent(_model.smoothed(), _elevation);
        }
        return _skyCache;
    }

    private function booleanProperty(key as String, fallback as Boolean) as Boolean {
        var value = null;
        try {
            value = Application.Properties.getValue(key);
        } catch (ex) {
            value = null;
        }
        if (value instanceof Lang.Boolean) {
            return value;
        }
        return fallback;
    }

    private function numberProperty(key as String, fallback as Number, min as Number, max as Number) as Number {        var value = null;
        try {
            value = Application.Properties.getValue(key);
        } catch (ex) {
            value = null;
        }
        if (!(value instanceof Lang.Number)) {
            return fallback;
        }
        if (value < min) {
            return min;
        } else if (value > max) {
            return max;
        }
        return value;
    }
}
