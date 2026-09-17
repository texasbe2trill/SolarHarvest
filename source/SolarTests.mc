import Toybox.Application;
import Toybox.Graphics;
import Toybox.Math;
import Toybox.System;
import Toybox.Lang;
import Toybox.Test;
import Toybox.WatchUi;

// -- solar readings --------------------------------------------------------

(:test)
function testClampsOutOfRangeSamples(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    model.addSample(-25, -1.0, false);
    Test.assertEqualMessage(model.current(), 0, "negative intensity clamps to 0");
    model.addSample(180, -1.0, false);
    Test.assertEqualMessage(model.current(), 100, "intensity above 100 clamps");
    Test.assertEqualMessage(model.peak(), 100, "peak tracks the clamped maximum");
    return true;
}

(:test)
function testAveragePeakAndTicks(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var values = [10, 20, 30, 41];
    for (var i = 0; i < values.size(); i++) {
        model.addSample(values[i], -1.0, false);
    }
    Test.assertEqualMessage(model.average(), 25, "average rounds 25.25 to 25");
    Test.assertEqualMessage(model.peak(), 41, "peak is the maximum sample");
    Test.assertEqualMessage(model.ticks(), 4, "one tick per sample");
    return true;
}

(:test)
function testBucketAveraging(logger as Logger) as Boolean {
    var model = new SolarModel(4);
    model.addSample(100, -1.0, false);
    Test.assertEqualMessage(model.count(), 1, "first sample seeds the chart");
    Test.assertEqualMessage(model.sampleAt(0), 100, "seed keeps its value");

    var bucket = [20, 40, 60, 80];
    for (var i = 0; i < bucket.size(); i++) {
        model.addSample(bucket[i], -1.0, false);
    }
    Test.assertEqualMessage(model.count(), 2, "four ticks close one bucket");
    Test.assertEqualMessage(model.sampleAt(1), 50, "bucket stores the mean of its ticks");
    return true;
}

(:test)
function testRingBufferWrapsAndKeepsOrder(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var total = SolarModel.HISTORY_SIZE + 10;
    for (var i = 0; i < total; i++) {
        model.addSample(i % 100, -1.0, false);
    }
    Test.assertEqualMessage(model.count(), SolarModel.HISTORY_SIZE, "history is capped");
    Test.assertEqualMessage(model.sampleAt(0), (total - SolarModel.HISTORY_SIZE) % 100,
        "index 0 is the oldest retained sample");
    Test.assertEqualMessage(model.sampleAt(SolarModel.HISTORY_SIZE - 1), (total - 1) % 100,
        "last index is the newest sample");
    Test.assertEqualMessage(model.sampleAt(-1), 0, "negative index is safe");
    Test.assertEqualMessage(model.sampleAt(SolarModel.HISTORY_SIZE), 0, "overflow index is safe");
    return true;
}

(:test)
function testHarvestIntegralAndProjection(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    for (var i = 0; i < 3600; i++) {
        model.addSample(50, -1.0, false);
    }
    Test.assertEqualMessage(model.harvestSeconds(), 1800, "half intensity halves the harvest clock");
    Test.assertEqualMessage(model.batteryMinutes(60), 30, "half a full-sun hour at 60min/h is 30min");
    Test.assertEqualMessage(model.projectedHarvestSeconds(600), 300,
        "projection scales the remaining window by current intensity");
    Test.assertEqualMessage(model.projectedHarvestSeconds(-10), 0, "negative window projects zero");
    return true;
}

(:test)
function testLapHarvestResets(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    for (var i = 0; i < 100; i++) {
        model.addSample(100, -1.0, false);
    }
    Test.assertEqualMessage(model.lapHarvestSeconds(), 100, "lap harvest accumulates");
    model.noteLap();
    Test.assertEqualMessage(model.lapHarvestSeconds(), 0, "lap harvest resets on lap");
    Test.assertEqualMessage(model.harvestSeconds(), 100, "session harvest survives a lap");
    return true;
}

(:test)
function testTrendDirection(logger as Logger) as Boolean {
    var rising = new SolarModel(1);
    var falling = new SolarModel(1);
    for (var i = 0; i < 20; i++) {
        rising.addSample(i * 5, -1.0, false);
        falling.addSample(100 - (i * 5), -1.0, false);
    }
    Test.assertMessage(rising.slopePerMinute() > 0, "rising series has a positive slope");
    Test.assertMessage(falling.slopePerMinute() < 0, "falling series has a negative slope");

    var flat = new SolarModel(1);
    for (var i = 0; i < 20; i++) {
        flat.addSample(42, -1.0, false);
    }
    Test.assertMessage(flat.slopePerMinute().abs() < 0.0001, "flat series has no slope");
    return true;
}

(:test)
function testSlopeCacheInvalidates(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    for (var i = 0; i < 10; i++) {
        model.addSample(10, -1.0, false);
    }
    Test.assertMessage(model.slopePerMinute().abs() < 0.0001, "flat prefix has no slope");
    for (var i = 0; i < 10; i++) {
        model.addSample(100, -1.0, false);
    }
    Test.assertMessage(model.slopePerMinute() > 0, "cached slope refreshes after new samples");
    return true;
}

(:test)
function testTrendIsSafeWithTooFewSamples(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    Test.assertEqualMessage(model.slopePerMinute(), 0.0, "empty model has no trend");
    model.addSample(30, -1.0, false);
    Test.assertEqualMessage(model.slopePerMinute(), 0.0, "single sample has no trend");
    return true;
}

(:test)
function testZoneBoundariesAndDistribution(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    Test.assertEqualMessage(model.zoneOf(0), 0, "0% is dark");
    Test.assertEqualMessage(model.zoneOf(14), 0, "14% is dark");
    Test.assertEqualMessage(model.zoneOf(15), 1, "15% enters low");
    Test.assertEqualMessage(model.zoneOf(39), 1, "39% is low");
    Test.assertEqualMessage(model.zoneOf(40), 2, "40% enters moderate");
    Test.assertEqualMessage(model.zoneOf(69), 2, "69% is moderate");
    Test.assertEqualMessage(model.zoneOf(70), 3, "70% enters high");
    Test.assertEqualMessage(model.zoneOf(100), 3, "100% is high");

    for (var i = 0; i < 4; i++) {
        model.addSample(0, -1.0, false);
    }
    for (var i = 0; i < 4; i++) {
        model.addSample(80, -1.0, false);
    }
    Test.assertMessage((model.zoneFraction(0) - 0.5).abs() < 0.0001, "half the session was dark");
    Test.assertMessage((model.sunFraction() - 0.5).abs() < 0.0001, "sun fraction excludes dark");

    var sum = 0.0;
    for (var z = 0; z < SolarModel.ZONE_COUNT; z++) {
        sum += model.zoneFraction(z);
    }
    Test.assertMessage((sum - 1.0).abs() < 0.0001, "zone fractions sum to 1");
    Test.assertEqualMessage(model.zoneFraction(-1), 0.0, "invalid zone is safe");
    Test.assertEqualMessage(model.zoneFraction(SolarModel.ZONE_COUNT), 0.0, "invalid zone is safe");
    return true;
}

// -- battery analytics -----------------------------------------------------

(:test)
function testDrainRateNeedsEnoughEvidence(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 100.0;
    for (var i = 0; i < 60; i++) {
        model.addSample(0, level, false);
        level -= 0.01;
    }
    Test.assertMessage(model.drainPerHour() == null, "a one minute window is not enough evidence");
    Test.assertMessage(model.projectedHours() == null, "no projection without a measured rate");
    return true;
}

(:test)
function testMeasuredDrainRate(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 100.0;
    // 3600 samples losing 4% total should measure as 4%/h.
    for (var i = 0; i < 3600; i++) {
        model.addSample(0, level, false);
        level -= 4.0 / 3600.0;
    }
    var drain = model.drainPerHour();
    if (drain == null) {
        Test.assertMessage(false, "an hour of drain is enough evidence");
        return false;
    }
    Test.assertMessage((drain - 4.0).abs() < 0.2, "measured drain is about 4%/h");

    var hours = model.projectedHours();
    if (hours == null) {
        Test.assertMessage(false, "projection available once a rate exists");
        return false;
    }
    Test.assertMessage((hours - 24.0).abs() < 2.0, "96% left at 4%/h is about 24h");
    return true;
}

(:test)
function testSolarOffsetIsMeasuredNotAssumed(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 100.0;
    // One hour in the dark draining 6%/h.
    for (var i = 0; i < 3600; i++) {
        model.addSample(0, level, false);
        level -= 6.0 / 3600.0;
    }
    // One hour in full sun draining 2%/h.
    for (var i = 0; i < 3600; i++) {
        model.addSample(90, level, false);
        level -= 2.0 / 3600.0;
    }
    var offset = model.solarOffsetPerHour();
    if (offset == null) {
        Test.assertMessage(false, "both buckets have enough evidence");
        return false;
    }
    Test.assertMessage((offset - 4.0).abs() < 0.5, "sun saved about 4%/h");
    return true;
}

(:test)
function testChargingIsExcludedFromDrain(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 50.0;
    for (var i = 0; i < 3600; i++) {
        model.addSample(0, level, true);
        level += 10.0 / 3600.0;
    }
    Test.assertMessage(model.drainPerHour() == null, "charging never produces a drain rate");
    Test.assertMessage(model.batteryPercent() > 50.0, "battery level still tracks while charging");
    return true;
}

(:test)
function testBatteryTraceRingBuffer(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 100.0;
    var seconds = SolarModel.BATTERY_PERIOD * (SolarModel.BATTERY_HISTORY_SIZE + 5);
    for (var i = 0; i < seconds; i++) {
        model.addSample(0, level, false);
        level -= 0.001;
    }
    Test.assertEqualMessage(model.batteryCount(), SolarModel.BATTERY_HISTORY_SIZE,
        "battery trace is capped");
    Test.assertMessage(model.batteryAt(0) > model.batteryAt(SolarModel.BATTERY_HISTORY_SIZE - 1),
        "oldest trace point is higher than the newest while draining");
    Test.assertEqualMessage(model.batteryAt(-1), 0.0, "invalid trace index is safe");
    return true;
}

(:test)
function testUnknownBatteryIsIgnored(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    for (var i = 0; i < 1200; i++) {
        model.addSample(50, -1.0, false);
    }
    Test.assertEqualMessage(model.batteryCount(), 0, "no trace without a battery reading");
    Test.assertMessage(model.drainPerHour() == null, "no rate without a battery reading");
    Test.assertEqualMessage(model.harvestSeconds(), 600, "solar stats still accumulate");
    return true;
}

(:test)
function testResetClearsEverything(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 100.0;
    for (var i = 0; i < 1200; i++) {
        model.addSample(70, level, false);
        level -= 0.002;
    }
    model.reset();
    Test.assertEqualMessage(model.count(), 0, "history cleared");
    Test.assertEqualMessage(model.ticks(), 0, "ticks cleared");
    Test.assertEqualMessage(model.peak(), 0, "peak cleared");
    Test.assertEqualMessage(model.average(), 0, "average cleared");
    Test.assertEqualMessage(model.harvestSeconds(), 0, "harvest cleared");
    Test.assertEqualMessage(model.batteryCount(), 0, "battery trace cleared");
    Test.assertMessage(model.drainPerHour() == null, "drain rate cleared");
    Test.assertEqualMessage(model.zoneFraction(3), 0.0, "zones cleared");
    return true;
}

// -- layout ----------------------------------------------------------------

(:test)
function testLayoutNeverOverlaps(logger as Logger) as Boolean {
    var planner = new LayoutPlanner(0, 100, 12, 7, true);
    for (var h = 24; h <= 300; h += 1) {
        planner.plan(4, h, 14, 7, true);
        var cursor = 4;
        if (planner.showDots) {
            Test.assertMessage(planner.dotsY >= cursor, "dots start inside the field");
            cursor = planner.dotsY + 7;
        }
        if (planner.showTitle) {
            Test.assertMessage(planner.titleY >= cursor, "title sits below the dots");
            cursor = planner.titleY + 14;
        }
        Test.assertMessage(planner.heroY >= cursor, "hero sits below the header");
        cursor = planner.heroY + planner.heroH;
        if (planner.showChart) {
            Test.assertMessage(planner.chartY >= cursor, "chart sits below the hero");
            cursor = planner.chartY + planner.chartH;
        }
        if (planner.showChips) {
            Test.assertMessage(planner.chipsY >= cursor, "chips sit below the chart");
        }
    }
    return true;
}

(:test)
function testLayoutDropsInPriorityOrder(logger as Logger) as Boolean {
    var planner = new LayoutPlanner(0, 200, 14, 7, true);
    Test.assertMessage(planner.showTitle && planner.showDots && planner.showChart
        && planner.showChips, "a tall field shows everything");

    planner.plan(0, 70, 14, 7, true);
    Test.assertMessage(!planner.showDots, "dots are sacrificed first");

    planner.plan(0, 55, 14, 7, true);
    Test.assertMessage(!planner.showChips, "chips are sacrificed second");

    planner.plan(0, 40, 14, 7, true);
    Test.assertMessage(!planner.showTitle, "title is sacrificed third");

    planner.plan(0, 20, 14, 7, true);
    Test.assertMessage(!planner.showChart, "chart is sacrificed last");
    Test.assertMessage(planner.heroH >= LayoutPlanner.MIN_HERO, "hero always survives");
    return true;
}

(:test)
function testLayoutHeroStaysCentered(logger as Logger) as Boolean {
    var planner = new LayoutPlanner(10, 200, 14, 7, false);
    var center = planner.heroCenterY();
    Test.assertMessage(center > planner.heroY, "hero centre is inside the hero band");
    Test.assertMessage(center < (planner.heroY + planner.heroH), "hero centre is inside the hero band");
    Test.assertMessage(!planner.showDots, "dots are hidden when not requested");
    return true;
}

// -- safe area -------------------------------------------------------------

// Short names for DataField.OBSCURE_*, which SafeArea reads directly.
const T_TOP = WatchUi.DataField.OBSCURE_TOP;
const T_LEFT = WatchUi.DataField.OBSCURE_LEFT;
const T_BOTTOM = WatchUi.DataField.OBSCURE_BOTTOM;
const T_RIGHT = WatchUi.DataField.OBSCURE_RIGHT;

function configureArea(area as SafeArea, round as Boolean, fieldH as Number, flags as Number) as Void {
    area.configure(round, 280, 280, 280, fieldH, flags);
}

(:test)
function testSafeAreaStaysInsideTheCircle(logger as Logger) as Boolean {
    var area = new SafeArea();
    configureArea(area, true, 280, T_TOP | T_BOTTOM | T_LEFT | T_RIGHT);
    for (var y = 0; y <= 280; y += 1) {
        var left = area.leftAt(y);
        var right = area.rightAt(y);
        Test.assertMessage(left >= 0, "left edge never leaves the field");
        Test.assertMessage(right <= 280, "right edge never leaves the field");
        Test.assertMessage(right >= left, "right edge is never left of the left edge");
        // Rows above or below the circle collapse to zero width, which is correct.
        if (area.halfAt(y) > 0) {
            var dy = y - 140;
            var limit = 140 - SafeArea.MARGIN;
            var dx = area.centerAt(y) - 140;
            Test.assertMessage((dx * dx) + (dy * dy) <= (limit * limit) + 1,
                "row centre stays inside the bezel circle");
        }
    }
    return true;
}

(:test)
function testSafeAreaIsWidestAtTheMiddle(logger as Logger) as Boolean {
    var area = new SafeArea();
    configureArea(area, true, 280, T_TOP | T_BOTTOM | T_LEFT | T_RIGHT);
    Test.assertMessage(area.halfAt(140) > area.halfAt(40), "the middle row is wider than the top");
    Test.assertMessage(area.halfAt(140) > area.halfAt(250), "the middle row is wider than the bottom");
    Test.assertEqualMessage(area.halfAt(-40), 0, "rows outside the circle have no width");
    return true;
}

(:test)
function testSafeAreaPlacesPartialFields(logger as Logger) as Boolean {
    var top = new SafeArea();
    configureArea(top, true, 90, T_TOP | T_LEFT | T_RIGHT);
    var middle = new SafeArea();
    configureArea(middle, true, 90, T_LEFT | T_RIGHT);
    var bottom = new SafeArea();
    configureArea(bottom, true, 90, T_BOTTOM | T_LEFT | T_RIGHT);

    Test.assertMessage(middle.halfAt(45) > top.halfAt(45),
        "a middle field is wider than a top field at the same local row");
    Test.assertMessage(middle.halfAt(45) > bottom.halfAt(45),
        "a middle field is wider than a bottom field at the same local row");
    Test.assertMessage(top.halfAt(85) > top.halfAt(5),
        "a top field widens as it approaches the screen centre");
    Test.assertMessage(bottom.halfAt(5) > bottom.halfAt(85),
        "a bottom field narrows as it approaches the screen bottom");
    return true;
}

(:test)
function testSafeAreaOnRectangularScreens(logger as Logger) as Boolean {
    var area = new SafeArea();
    configureArea(area, false, 280, T_TOP | T_BOTTOM | T_LEFT | T_RIGHT);
    Test.assertEqualMessage(area.leftAt(0), SafeArea.MARGIN, "flat screens use a plain margin");
    Test.assertEqualMessage(area.rightAt(0), 280 - SafeArea.MARGIN, "flat screens use a plain margin");
    Test.assertEqualMessage(area.leftAt(279), SafeArea.MARGIN, "margins do not vary by row");
    return true;
}

// -- sun window ------------------------------------------------------------

(:test)
function testSunWindowStates(logger as Logger) as Boolean {
    Test.assertEqualMessage(sunWindowState(1000, -1, -1), SUN_UNKNOWN, "no fix yet is unknown");
    Test.assertEqualMessage(sunWindowState(1000, 2000, 5000), SUN_DAWN, "before sunrise is dawn");
    Test.assertEqualMessage(sunWindowState(3000, 2000, 5000), SUN_DAY, "between the two is daylight");
    Test.assertEqualMessage(sunWindowState(6000, 2000, 5000), SUN_NIGHT, "after sunset is night");
    Test.assertEqualMessage(sunWindowState(5000, 2000, 5000), SUN_NIGHT, "sunset itself is night");
    return true;
}

(:test)
function testSunWindowRemaining(logger as Logger) as Boolean {
    Test.assertEqualMessage(sunWindowRemaining(1000, 2000, 5000), 1000, "dawn counts to sunrise");
    Test.assertEqualMessage(sunWindowRemaining(3000, 2000, 5000), 2000, "daylight counts to sunset");
    Test.assertEqualMessage(sunWindowRemaining(9000, 2000, 5000), 0, "night has no window left");
    Test.assertEqualMessage(sunWindowRemaining(1000, -1, -1), 0, "unknown window is zero");
    return true;
}

// -- page cycling ----------------------------------------------------------

(:test)
function testResolvePageSkipsEmptyPages(logger as Logger) as Boolean {
    var mask = (1 << 0) | (1 << 2);
    Test.assertEqualMessage(resolvePage(0, mask, 4), 0, "an available page is kept");
    Test.assertEqualMessage(resolvePage(1, mask, 4), 2, "an empty page advances to the next");
    Test.assertEqualMessage(resolvePage(3, mask, 4), 0, "the search wraps around");
    Test.assertEqualMessage(resolvePage(0, 0, 4), 0, "an empty mask falls back to page 0");
    Test.assertEqualMessage(resolvePage(9, mask, 4), 2, "index 9 wraps to slot 1 then advances to 2");
    return true;
}

(:test)
function testCountPages(logger as Logger) as Boolean {
    Test.assertEqualMessage(countPages(0, 4), 0, "no pages available");
    Test.assertEqualMessage(countPages((1 << 0) | (1 << 3), 4), 2, "two pages available");
    Test.assertEqualMessage(countPages(15, 4), 4, "all pages available");
    return true;
}

(:test)
function testProvisionalDrainAppearsEarlier(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 100.0;
    // Five minutes at a 6%/h drain: too thin for the confident gate, enough for the
    // provisional one.
    for (var i = 0; i < 300; i++) {
        model.addSample(0, level, false);
        level -= 6.0 / 3600.0;
    }
    Test.assertMessage(model.drainPerHour() == null, "confident rate still withheld");
    var provisional = model.provisionalDrainPerHour();
    if (provisional == null) {
        Test.assertMessage(false, "provisional rate is available after five minutes");
        return false;
    }
    Test.assertMessage((provisional - 6.0).abs() < 1.0, "provisional rate is about 6%/h");
    return true;
}

(:test)
function testDrainFromGarminDaysEstimate(logger as Logger) as Boolean {
    var rate = drainFromDays(5.0);
    if (rate == null) {
        Test.assertMessage(false, "five days converts to a rate");
        return false;
    }
    // 100% over 120 hours is 0.833%/h.
    Test.assertMessage((rate - 0.8333).abs() < 0.001, "five days is about 0.83%/h");

    var oneDay = drainFromDays(1.0);
    if (oneDay == null) {
        Test.assertMessage(false, "one day converts to a rate");
        return false;
    }
    Test.assertMessage((oneDay - 4.1666).abs() < 0.001, "one day is about 4.17%/h");
    Test.assertMessage(drainFromDays(0.0) == null, "zero days has no rate");
    Test.assertMessage(drainFromDays(-3.0) == null, "negative days has no rate");
    return true;
}

// -- formatting ------------------------------------------------------------


(:test)
function testFormatClock(logger as Logger) as Boolean {
    Test.assertEqualMessage(formatClock(0), "0:00", "zero renders as m:ss");
    Test.assertEqualMessage(formatClock(-5), "0:00", "negatives are floored");
    Test.assertEqualMessage(formatClock(65), "1:05", "seconds are zero padded");
    Test.assertEqualMessage(formatClock(3599), "59:59", "just under an hour stays in minutes");
    Test.assertEqualMessage(formatClock(3600), "1:00", "an hour switches to h:mm");
    Test.assertEqualMessage(formatClock(7861), "2:11", "hours and minutes render together");
    return true;
}

(:test)
function testFormatMinutes(logger as Logger) as Boolean {
    Test.assertEqualMessage(formatMinutes(0), "0m", "zero renders as minutes");
    Test.assertEqualMessage(formatMinutes(-30), "0m", "negatives are floored");
    Test.assertEqualMessage(formatMinutes(90), "1m", "seconds truncate to minutes");
    Test.assertEqualMessage(formatMinutes(3599), "59m", "just under an hour stays in minutes");
    Test.assertEqualMessage(formatMinutes(3660), "1h01", "an hour switches to h:mm");
    return true;
}

(:test)
function testFormatSigned(logger as Logger) as Boolean {
    Test.assertEqualMessage(formatSigned(3.24), "+3.2", "positive values get a plus");
    Test.assertEqualMessage(formatSigned(-3.24), "-3.2", "negative values get a minus");
    Test.assertEqualMessage(formatSigned(0.0), "0.0", "zero is unsigned");
    Test.assertEqualMessage(formatSigned(0.01), "0.0", "noise below the threshold is unsigned");
    return true;
}

// -- timer gating ------------------------------------------------------------
//
// compute() runs about once a second from the moment the field appears, which
// is before the timer starts and right through every pause, but records only
// reach the FIT while it runs. Every number below was previously accumulated in
// those gaps, so the session summary described an activity the chart beside it
// never showed.

(:test)
function testPausedSamplesStayOutOfTheSessionSummary(logger as Logger) as Boolean {
    var model = new SolarModel(5);
    // Ten minutes in the dark waiting for a GPS lock, then ten in full sun.
    for (var i = 0; i < 600; i++) {
        model.addSampleWhen(0, 80.0, false, false);
    }
    for (var i = 0; i < 600; i++) {
        model.addSampleWhen(100, 80.0, false, true);
    }
    logger.debug("after 600 paused dark + 600 running sun: avg=" + model.average().format("%d")
        + " peak=" + model.peak().format("%d") + " ticks=" + model.ticks().format("%d")
        + " sunFraction=" + model.sunFraction().format("%.2f"));
    Test.assertEqualMessage(model.ticks(), 600,
        "only the running samples may be counted");
    Test.assertEqualMessage(model.average(), 100,
        "the average must describe the recorded activity, not the wait before it");
    Test.assertMessage((model.sunFraction() - 1.0).abs() < 0.0001,
        "time in sun must be 100%, got " + model.sunFraction().format("%.3f"));
    Test.assertEqualMessage(model.harvestSeconds(), 600,
        "harvest must count only the running seconds");
    return true;
}

(:test)
function testPausedSamplesCannotSetThePeak(logger as Logger) as Boolean {
    // A watch left face-up on a cafe table reads full sun. That is not this
    // activity's peak, and before the timer gate it silently became one.
    var model = new SolarModel(5);
    for (var i = 0; i < 60; i++) {
        model.addSampleWhen(100, 80.0, false, false);
    }
    for (var i = 0; i < 60; i++) {
        model.addSampleWhen(30, 80.0, false, true);
    }
    Test.assertEqualMessage(model.peak(), 30,
        "a paused reading must not become the session peak");
    return true;
}

(:test)
function testPausedSamplesStillUpdateTheLiveReading(logger as Logger) as Boolean {
    // The other half of the deal: a paused field that freezes its live number
    // looks broken, so the display keeps tracking even though nothing counts.
    var model = new SolarModel(5);
    for (var i = 0; i < 120; i++) {
        model.addSampleWhen(80, 77.0, false, false);
    }
    logger.debug("paused-only: current=" + model.current().format("%d")
        + " smoothed=" + model.smoothed().format("%d")
        + " battery=" + model.batteryPercent().format("%.1f")
        + " ticks=" + model.ticks().format("%d"));
    Test.assertEqualMessage(model.current(), 80,
        "the live reading must follow the sensor while paused");
    Test.assertMessage(model.smoothed() > 70,
        "the smoothed reading must converge while paused, got " + model.smoothed().format("%d"));
    Test.assertMessage((model.batteryPercent() - 77.0).abs() < 0.0001,
        "the battery level must stay live while paused, got " + model.batteryPercent().format("%.1f"));
    Test.assertEqualMessage(model.ticks(), 0,
        "none of that may count as activity time");
    return true;
}

(:test)
function testPausedSecondsDoNotDiluteTheDrainRate(logger as Logger) as Boolean {
    // A measured rate is percent per hour of RUNNING time. Folding a long pause
    // into the denominator reports a drain far gentler than the one the wearer
    // is actually living with.
    var running = new SolarModel(5);
    var paused = new SolarModel(5);
    var level = 100.0;
    for (var i = 0; i < 3600; i++) {
        level -= 4.0 / 3600.0;
        running.addSampleWhen(0, level, false, true);
        paused.addSampleWhen(0, level, false, true);
        // The paused model also sits through a matching second of break time.
        paused.addSampleWhen(0, level, false, false);
    }
    var a = running.netFlowPerHour();
    var b = paused.netFlowPerHour();
    Test.assertMessage(a != null && b != null, "both models must have measured a rate");
    logger.debug("drain with no pause=" + a.format("%.2f") + "%/h, with an equal pause="
        + b.format("%.2f") + "%/h");
    Test.assertMessage((a - b).abs() < 0.01,
        "an equal amount of paused time must not change the measured rate: "
            + a.format("%.2f") + " vs " + b.format("%.2f"));
    return true;
}

// -- battery estimator -----------------------------------------------------
//
// Real hardware reports the battery level quantised to whole percent and the
// reading dithers across the boundary. These tests feed exactly that, because
// the continuous float traces above never exercise it.

// A quantised, dithering trace at a known true drain.
function feedQuantised(model as SolarModel, trueDrainPerHour as Float, seconds as Number,
                       intensity as Number) as Void {
    var level = 87.0;
    var dither = 0;
    for (var i = 0; i < seconds; i++) {
        level -= trueDrainPerHour / 3600.0;
        // A deterministic +-1% wobble on the reported value, the way a real
        // reading bounces when the true level sits near a boundary.
        dither = (i % 7 < 2) ? 1 : 0;
        model.addSample(intensity, (level.toNumber() + dither).toFloat(), false);
    }
}

(:test)
function testQuantisedDrainIsMeasuredNotInflated(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    feedQuantised(model, 4.0, 7200, 0);
    var drain = model.drainPerHour();
    if (drain == null) {
        Test.assertMessage(false, "two hours of quantised drain is enough evidence");
        return false;
    }
    logger.debug("measured " + drain.format("%.2f") + "%/h for a true 4.0%/h");
    // Counting every downward tick instead would report hundreds of percent an
    // hour here, which is the bug this replaces.
    Test.assertMessage((drain - 4.0).abs() < 0.6,
        "dithering readings still measure about 4%/h, not a multiple of it");
    return true;
}

(:test)
function testDitherAloneNeverInventsDrain(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    // The true level never moves; only the reported value wobbles.
    for (var i = 0; i < 3600; i++) {
        model.addSample(50, (i % 7 < 2) ? 71.0 : 70.0, false);
    }
    var flow = model.netFlowPerHour();
    if (flow != null) {
        Test.assertMessage(flow.abs() < 0.5, "a flat battery reads as no meaningful flow");
    }
    Test.assertMessage(model.drainPerHour() == null || model.drainPerHour() < 0.5,
        "pure dither does not become a drain rate");
    return true;
}

(:test)
function testSolarSurplusReadsAsGain(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    // Sun puts more in than the activity takes out: the level climbs 1%/h.
    feedQuantised(model, -1.0, 10800, 95);
    var flow = model.netFlowPerHour();
    if (flow == null) {
        Test.assertMessage(false, "three hours is enough evidence for a flow rate");
        return false;
    }
    logger.debug("net flow " + flow.format("%.2f") + "%/h for a true -1.0%/h");
    Test.assertMessage(flow < 0.0, "a rising battery reports as a gain, not a drain");
    Test.assertMessage((flow + 1.0).abs() < 0.6, "the gain is about 1%/h");
    Test.assertMessage(model.drainPerHour() == null, "a gaining watch has no drain rate");
    Test.assertMessage(model.projectedHours() == null, "and no runtime countdown");
    return true;
}

(:test)
function testEdgeToEdgeIgnoresPartialSteps(logger as Logger) as Boolean {
    // Whole-percent steps exactly 900s apart is 4%/h. Starting and stopping
    // part way through a step must not bias the answer.
    var model = new SolarModel(1);
    var level = 80.0;
    for (var i = 0; i < 5000; i++) {
        if (i > 0 && i % 900 == 0) {
            level -= 1.0;
        }
        model.addSample(0, level, false);
    }
    var drain = model.drainPerHour();
    if (drain == null) {
        Test.assertMessage(false, "five whole steps is ample evidence");
        return false;
    }
    logger.debug("edge to edge measured " + drain.format("%.3f") + "%/h");
    Test.assertMessage((drain - 4.0).abs() < 0.15, "four percent per hour, measured exactly");
    return true;
}

(:test)
function testSolarSavingNeedsRealEvidence(logger as Logger) as Boolean {
    // Drain that genuinely depends on sunlight: 6%/h dark, 3%/h at full sun.
    var model = new SolarModel(1);
    var level = 95.0;
    for (var i = 0; i < 18000; i++) {
        // Alternate half-hour blocks of deep shade and bright sun.
        var sun = ((i / 1800) % 2 == 0) ? 0 : 100;
        level -= (6.0 - (3.0 * sun / 100.0)) / 3600.0;
        model.addSample(sun, level, false);
    }
    var saving = model.solarOffsetPerHour();
    if (saving == null) {
        Test.assertMessage(false, "five hours across both extremes should fit");
        return false;
    }
    logger.debug("fitted saving " + saving.format("%.2f") + "%/h for a true 3.0%/h");
    Test.assertMessage((saving - 3.0).abs() < 1.0, "the fit recovers about 3%/h saved at full sun");

    var base = model.baseDrainPerHour();
    if (base != null) {
        Test.assertMessage((base - 6.0).abs() < 1.0, "and about 6%/h with no sun at all");
    }
    return true;
}

// The early rule: a day whose drain plainly followed its light earns a
// saving well before twelve intervals. Whole-percent levels as a watch
// reports them, shade and sun in quarter hour blocks, 6%/h dark and 3%/h in
// full sun: a handful of battery steps is enough.
(:test)
function testSolarSavingArrivesEarlyWhenTheContrastIsStrong(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 90.5;
    var seenAt = -1;
    var t = 0;
    while (t < 36000 && model.batteryRegressionSamples() < BatteryModel.REG_MIN_INTERVALS) {
        var sun = ((t / 900) % 2 == 0) ? 0 : 100;
        level -= (6.0 - (3.0 * sun / 100.0)) / 3600.0;
        model.addSample(sun, level.toNumber().toFloat(), false);
        if (seenAt < 0 && model.solarOffsetPerHour() != null) {
            seenAt = model.batteryRegressionSamples();
        }
        t += 1;
    }
    var saving = model.solarOffsetPerHour();
    if (saving == null || seenAt < 0) {
        Test.assertMessage(false, "a strong contrast should fit before the classic count");
        return false;
    }
    logger.debug("early saving " + saving.format("%.2f") + "%/h after " + seenAt.format("%d") + " intervals");
    Test.assertMessage(seenAt < BatteryModel.REG_MIN_INTERVALS, "the fit arrived before twelve intervals");
    Test.assertMessage(seenAt >= BatteryModel.REG_EARLY_INTERVALS, "but never before the early floor");
    Test.assertMessage((saving - 3.0).abs() < 1.0, "and it is the true 3%/h, not a guess");
    return true;
}

// The other half of the rule: light that varies while the drain merely
// wanders (a jittery 4%/h with no sun effect) never passes the early gate,
// so the saving stays withheld until the classic evidence would have it.
(:test)
function testSolarSavingWaitsWhenTheDrainIgnoresTheLight(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 90.5;
    var seed = 12345l;
    var t = 0;
    while (t < 36000 && model.batteryRegressionSamples() < BatteryModel.REG_MIN_INTERVALS - 2) {
        var sun = ((t / 900) % 2 == 0) ? 0 : 100;
        // Park and Miller on Longs, so the product does not wrap; a new
        // draw every minute, so the jitter is per interval, not per second.
        if (t % 60 == 0) {
            seed = (seed * 16807l) % 2147483647l;
        }
        var jitter = ((seed % 100l).toNumber()) / 50.0;          // 0 to 2%/h
        level -= (3.0 + jitter) / 3600.0;
        model.addSample(sun, level.toNumber().toFloat(), false);
        Test.assertMessage(model.solarOffsetPerHour() == null,
            "drain that ignores the light earns no early saving at " + model.batteryRegressionSamples().format("%d") + " intervals");
        t += 1;
    }
    return true;
}

(:test)
function testSolarSavingWithheldWithoutSpread(logger as Logger) as Boolean {
    // Constant sunlight carries no information about what sun is worth.
    var model = new SolarModel(1);
    var level = 95.0;
    for (var i = 0; i < 18000; i++) {
        level -= 4.0 / 3600.0;
        model.addSample(60, level, false);
    }
    Test.assertMessage(model.solarOffsetPerHour() == null,
        "no variation in sunlight means no claim about its benefit");
    Test.assertMessage(model.baseDrainPerHour() == null, "and no fitted baseline either");
    return true;
}

(:test)
function testBatteryUsedIsNetNotGross(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 60.0;
    for (var i = 0; i < 1800; i++) {
        level -= 2.0 / 3600.0;
        model.addSample(0, level, false);
    }
    for (var i = 0; i < 1800; i++) {
        level += 1.0 / 3600.0;
        model.addSample(100, level, false);
    }
    // Down 1% then back up 0.5%: net consumption is 0.5%, not 1.5%.
    var used = model.batteryUsedPercent();
    logger.debug("net used " + used.format("%.3f") + "%");
    Test.assertMessage((used - 0.5).abs() < 0.05, "recharge counts against consumption");
    return true;
}

// -- signal smoothing ------------------------------------------------------

// 120 consecutive real readings from a fenix 9 Pro Solar walking activity.
// The raw sensor moves an average of 14 percentage points every single second.
function realSolarTrace() as Array<Number> {
    return [
        100, 100, 32, 26, 30, 23, 27, 27, 21, 30, 36, 40,
        100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100,
        100, 100, 100, 100, 17, 29, 30, 32, 100, 100, 100, 100,
        100, 100, 100, 65, 75, 100, 100, 100, 100, 100, 100, 32,
        36, 100, 100, 100, 24, 22, 54, 100, 31, 35, 100, 100,
        100, 100, 100, 65, 100, 100, 91, 68, 71, 100, 100, 100,
        100, 100, 100, 100, 100, 100, 95, 100, 100, 67, 65, 100,
        100, 100, 68, 69, 100, 100, 100, 78, 66, 100, 100, 100,
        71, 67, 99, 100, 75, 49, 40, 100, 100, 87, 47, 33,
        61, 61, 89, 46, 48, 97, 100, 100, 64, 47, 100, 100
    ] as Array<Number>;
}

(:test)
function testSmoothingCalmsTheRealSensor(logger as Logger) as Boolean {
    var trace = realSolarTrace();
    var model = new SolarModel(1);
    var rawJitter = 0;
    var smoothJitter = 0;
    var prevRaw = trace[0];
    var prevSmooth = trace[0];
    for (var i = 0; i < trace.size(); i++) {
        model.addSample(trace[i], -1.0, false);
        rawJitter += (trace[i] - prevRaw).abs();
        smoothJitter += (model.smoothed() - prevSmooth).abs();
        prevRaw = trace[i];
        prevSmooth = model.smoothed();
    }
    logger.debug("raw jitter " + rawJitter.format("%d") + " vs smoothed " + smoothJitter.format("%d"));
    Test.assertMessage(rawJitter > 1000, "the real trace really is this noisy");
    Test.assertMessage(smoothJitter * 4 < rawJitter,
        "smoothing removes most of the second-to-second flicker");

    // Smoothing is for the eye only: the energy total stays on the raw signal.
    var total = 0;
    for (var i = 0; i < trace.size(); i++) {
        total += trace[i];
    }
    Test.assertEqualMessage(model.harvestSeconds(), total / 100,
        "harvest still integrates the raw readings");
    Test.assertMessage(model.smoothed() >= 0 && model.smoothed() <= 100,
        "the smoothed value stays a percentage");
    return true;
}

(:test)
function testSmoothedTracksASteadySignal(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    model.addSample(80, -1.0, false);
    Test.assertEqualMessage(model.smoothed(), 80, "the first reading seeds the smoother exactly");
    for (var i = 0; i < 200; i++) {
        model.addSample(80, -1.0, false);
    }
    Test.assertEqualMessage(model.smoothed(), 80, "a steady signal converges to itself");
    for (var i = 0; i < 200; i++) {
        model.addSample(0, -1.0, false);
    }
    Test.assertEqualMessage(model.smoothed(), 0, "and follows a sustained change all the way");
    return true;
}

// -- lap summaries ---------------------------------------------------------

(:test)
function testLapAverageResetsWithTheLap(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    Test.assertEqualMessage(model.lapAverage(), 0, "no lap samples yet");
    for (var i = 0; i < 100; i++) {
        model.addSample(40, -1.0, false);
    }
    Test.assertEqualMessage(model.lapAverage(), 40, "lap average over the first lap");
    model.noteLap();
    Test.assertEqualMessage(model.lapAverage(), 0, "a new lap starts empty");
    for (var i = 0; i < 50; i++) {
        model.addSample(90, -1.0, false);
    }
    Test.assertEqualMessage(model.lapAverage(), 90, "lap average reflects only the new lap");
    Test.assertEqualMessage(model.average(), 57, "session average still spans both laps");
    return true;
}

// -- formatting ------------------------------------------------------------

(:test)
function testFormatFlow(logger as Logger) as Boolean {
    // The model counts drain as positive; the screen shows a falling battery
    // with a minus and a solar surplus with a plus.
    Test.assertEqualMessage(formatFlow(4.25), "-4.2", "draining reads as a minus");
    Test.assertEqualMessage(formatFlow(-0.8), "+0.8", "gaining reads as a plus");
    Test.assertEqualMessage(formatFlow(0.0), "0.0", "break-even is unsigned");
    Test.assertEqualMessage(formatFlow(0.01), "0.0", "noise below the threshold is unsigned");
    return true;
}

// -- rendering -------------------------------------------------------------
//
// These drive onUpdate() against a real off-screen graphics context, which is
// the only way to prove the drawing layer cannot throw. Charts do integer
// arithmetic on widths and heights that shrink with the field size, so a
// division or an array index going wrong only ever shows up at a specific size.

// An off-screen bitmap on every tier. createBufferedBitmap arrived in Connect IQ
// 4.0 and hands back a reference; the fenix 6 generation only has the
// constructor.
function offscreenBitmap(width as Number, height as Number) {
    var options = { :width => width, :height => height };
    if (Graphics has :createBufferedBitmap) {
        var buffer = Graphics.createBufferedBitmap(options);
        if (buffer != null && buffer has :get) {
            buffer = buffer.get();
        }
        return buffer;
    }
    return new Graphics.BufferedBitmap(options);
}

function renderAt(view as SolarPowerView, width as Number, height as Number) as Boolean {
    var buffer = offscreenBitmap(width, height);
    if (buffer == null) {
        return false;
    }
    view.onUpdate(buffer.getDc());
    return true;
}

(:test)
function testRendersEveryPageAtManySizes(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    var trace = realSolarTrace();
    var rendered = 0;

    // Empty model first: every chart has to cope with having no data at all.
    for (var page = 0; page < 7; page++) {
        view.setPageForTest(page);
        if (renderAt(view, 280, 280)) {
            rendered += 1;
        }
    }

    // Then with real readings and a falling battery behind them, and a position
    // fix. Without the fix the sun geometry short-circuits and the daylight arc
    // is never drawn - which is how a stack overflow in it survived this test.
    var level = 74.0;
    for (var i = 0; i < trace.size(); i++) {
        level -= 0.01;
        view.addSampleForTest(trace[i], level);
    }
    view.setClockForTest(SOLAR_NOON_UTC);
    view.setFixForTest(TEST_LAT_RAD, TEST_LON_RAD);
    // Sizes from a full screen down to a one-line sliver, plus awkward widths.
    var sizes = [280, 260, 210, 163, 120, 94, 61, 37, 24];
    for (var s = 0; s < sizes.size(); s++) {
        for (var page = 0; page < 7; page++) {
            view.setPageForTest(page);
            if (renderAt(view, sizes[s], sizes[s])) {
                rendered += 1;
            }
            if (renderAt(view, 280, sizes[s])) {
                rendered += 1;
            }
        }
    }

    // Then the same pages across the day. Every sun-facing page draws something
    // different depending on where the sun is, and until the clock was pinned
    // this test only ever saw whichever one happened to apply when it ran: at
    // dusk the daylight arc's future half is a few pixels tall and its hatching
    // barely executes, before dawn the catching page falls back to sun height and
    // takes an entirely separate set of branches for its title, chip and dial.
    // Two sizes each, because this sweep is about the geometry rather than the
    // layout - the sweep above already covers the sizes.
    var dayShapes = [280, 120];
    var clocks = renderClocks();
    for (var c = 0; c < clocks.size(); c++) {
        view.setClockForTest(clocks[c]);
        // Alternate between a watch that has a compass reading and one that does
        // not, so the heads-up and north-up paths are both walked at every hour.
        view.setHeadingForTest(((c % 2) == 0) ? (c * 47.0) : -1.0);
        for (var s = 0; s < dayShapes.size(); s++) {
            for (var page = 0; page < 7; page++) {
                view.setPageForTest(page);
                if (renderAt(view, dayShapes[s], dayShapes[s])) {
                    rendered += 1;
                }
            }
        }
    }

    // Above the arctic circle in midsummer there is no sunrise and no sunset at
    // all, so the geometry hands back nothing and every daylight feature has to
    // degrade instead of dividing by a day length it does not have.
    view.setClockForTest(SOLAR_NOON_UTC);
    view.setFixForTest(POLAR_LAT_RAD, TEST_LON_RAD);
    for (var page = 0; page < 7; page++) {
        view.setPageForTest(page);
        if (renderAt(view, 280, 280)) {
            rendered += 1;
        }
    }

    view.setClockForTest(0);
    logger.debug("rendered " + rendered.format("%d") + " page/size/time combinations");
    Test.assertMessage(rendered > 0, "the off-screen buffer must be available to prove this");
    return true;
}

// Times of day for the render sweep, at the test longitude (97.87 W, so solar
// noon lands near 18:31 UTC on this date). Deep night, before dawn, mid-morning
// on the way up, solar noon, mid-afternoon on the way down, and dusk.
//
// Built by a function rather than held in a module-level const: the other
// fixtures in this suite are locals for the same reason, and a data field has
// 128K for everything.
const RENDER_DAY = 1781913600;  // 2026-06-20 00:00 UTC, near the solstice
const SOLAR_NOON_UTC = 1781913600 + (18 * 3600) + 1860;
// The real crossing, where the hour angle is actually zero: 18:32:38 UTC.
const TRUE_SOLAR_NOON_UTC = 1781913600 + (18 * 3600) + 1958;

// Tromso in midsummer: the sun never sets, so the geometry reports no events.
const POLAR_LAT_RAD = 1.2159d;  // 69.66 N

function renderClocks() as Array<Number> {
    return [
        RENDER_DAY + (8 * 3600),          // 03:00 local, dark
        RENDER_DAY + (11 * 3600),         // 06:00 local, first light
        RENDER_DAY + (15 * 3600),         // 10:00 local, climbing
        SOLAR_NOON_UTC,                   // solar noon
        RENDER_DAY + (22 * 3600),         // 17:00 local, dropping
        RENDER_DAY + (25 * 3600) + 1800,  // 20:30 local, dusk
    ] as Array<Number>;
}

(:test)
function testSunBonusPageAgreesWithItself(logger as Logger) as Boolean {
    // The bonus page quotes the same arithmetic in three places - the ring, the
    // bar and the two chips - and they are computed from one split so they cannot
    // drift apart. Learned coefficients stand in for a fit that has not converged,
    // which is exactly the state the page has to cope with on a short activity.
    var model = new SolarModel(5);
    for (var i = 0; i < 600; i++) {
        model.addSample(50, 80.0, false);
    }
    model.setCalibration(calibrationWith(2.0, 5.0));

    var saving = model.effectiveSaving();
    var drain = model.effectiveDrain();
    Test.assertMessage(saving != null, "learned saving must stand in for an unconverged fit");
    Test.assertMessage(drain != null, "learned drain must stand in for an unconverged fit");

    // Half-lit, so the sun covers 2.0 * 0.5 = 1.0 of a 6.0 point hour: one sixth.
    var lit = saving * (model.average() / 100.0);
    Test.assertMessage((lit - 1.0).abs() < 0.01,
        "half-lit hour must halve the full-sun saving, got " + lit.format("%.3f"));
    var share = (lit / (lit + drain)) * 100.0;
    Test.assertMessage((share - 16.667).abs() < 0.5,
        "the sun must read as one sixth of what the hour would have cost, got "
            + share.format("%.2f"));

    // And the headline has to be the same figure expressed as runtime.
    var bonus = model.solarBonusMinutes();
    Test.assertMessage(bonus != null, "a learned saving and drain must produce a bonus");
    logger.debug("bonus " + bonus.format("%d") + "m, sun covers " + share.format("%.1f") + "%");
    Test.assertMessage(bonus > 0, "a measured bonus must be positive");
    return true;
}

(:test)
function testSunAzimuthTracksTheSunAcrossTheSky(logger as Logger) as Boolean {
    // True solar noon on the solstice: the sun bears due south from 30.6 N,
    // because the latitude is north of the 23.4 N declination.
    //
    // This wants the real crossing rather than the longitude estimate the render
    // sweep uses, which is 98 seconds early. That sounds like nothing and is
    // worth 3 degrees of bearing here: the sun reaches 82.8 degrees at this
    // latitude on this date, and a nearly overhead sun sweeps azimuth extremely
    // fast. It is the same reason the compass page stops quoting a bearing when
    // the sun climbs near the zenith - there, the number is real but useless.
    var noon = SolarGeometry.azimuthDegrees(TRUE_SOLAR_NOON_UTC, TEST_LAT_RAD, TEST_LON_RAD);
    Test.assertMessage((noon - 180.0).abs() < 0.5,
        "at true solar noon the sun must bear due south, got " + noon.format("%.1f"));

    // Four hours earlier it is in the east, four hours later in the west, and the
    // bearing has to increase monotonically through the day.
    var morning = SolarGeometry.azimuthDegrees(TRUE_SOLAR_NOON_UTC - 14400, TEST_LAT_RAD, TEST_LON_RAD);
    var evening = SolarGeometry.azimuthDegrees(TRUE_SOLAR_NOON_UTC + 14400, TEST_LAT_RAD, TEST_LON_RAD);
    logger.debug("azimuth 08:00 " + morning.format("%.0f") + ", noon " + noon.format("%.0f")
        + ", 16:00 " + evening.format("%.0f"));
    Test.assertMessage(morning > 60.0 && morning < 130.0,
        "mid-morning sun must be in the east, got " + morning.format("%.1f"));
    Test.assertMessage(evening > 230.0 && evening < 300.0,
        "mid-afternoon sun must be in the west, got " + evening.format("%.1f"));
    Test.assertMessage(morning < noon && noon < evening,
        "the bearing must sweep east to west through the day");

    // And it must stay a legal bearing at every hour, including through midnight,
    // where a sign slip would show up as a negative or an out-of-range value.
    for (var h = 0; h < 24; h++) {
        var b = SolarGeometry.azimuthDegrees(RENDER_DAY + (h * 3600), TEST_LAT_RAD, TEST_LON_RAD);
        Test.assertMessage(b >= 0.0 && b < 360.0,
            "hour " + h.format("%d") + " gave an illegal bearing " + b.format("%.1f"));
    }
    return true;
}

(:test)
function testThisDeviceCanActuallyRaiseAlerts(logger as Logger) as Boolean {
    // The alert path is guarded by a `has` check, which fails silently: if the
    // check were wrong, every alert would simply never appear and nothing would
    // say so. This makes the capability an explicit, logged fact per device.
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    var canAlert = (view has :showAlert);
    var hasAlertView = (Toybox.WatchUi has :DataFieldAlert);
    logger.debug("showAlert=" + canAlert.toString() + " DataFieldAlert=" + hasAlertView.toString());
    Test.assertMessage(hasAlertView,
        "this build targets devices with DataFieldAlert; if this fails the permission is pointless");
    Test.assertMessage(canAlert,
        "a DataField subclass must expose showAlert, or no alert can ever be raised");
    return true;
}

// Five laps with a different amount of sun in each, to check that every lap
// reports its own figure rather than the running total.
//
// The two tests below differ only in which callback delivers the lap boundary,
// but they cannot share that step: onTimerLap2 is compiled out on the fenix 7
// tier, and Monkey C resolves symbols at build time, so a shared helper naming
// it fails to compile there even down a branch that never runs.
function lapSunSeconds() as Array<Number> {
    return [90, 30, 60, 0, 45] as Array<Number>;
}

// One lap's worth of samples; returns what that lap accumulated.
function runLapSamples(view as SolarPowerView, sunny as Number) as Number {
    for (var t = 0; t < 120; t++) {
        view.addSampleForTest((t < sunny) ? 100 : 0, 80.0);
    }
    return view.lapHarvestSecondsForTest();
}

function assertPerLap(logger as Logger, view as SolarPowerView, seen as Array<Number>,
                      via as String) as Boolean {
    var perLap = lapSunSeconds();
    var total = 0;
    for (var i = 0; i < perLap.size(); i++) {
        total += perLap[i];
        Test.assertMessage(seen[i] == perLap[i],
            via + ": lap " + i.format("%d") + " must report its own "
                + perLap[i].format("%d") + "s, got " + seen[i].format("%d") + "s");
    }
    logger.debug(via + " per-lap seconds " + seen.toString()
        + ", session " + total.format("%d") + "s");
    Test.assertMessage(view.harvestSecondsForTest() == total,
        via + ": session must hold every lap's sun, expected " + total.format("%d")
            + "s got " + view.harvestSecondsForTest().format("%d") + "s");
    return true;
}

(:lap2, :test)
function testAutoLapsThroughLap2EachRecordTheirOwnMinutes(logger as Logger) as Boolean {
    // The bug this exists for: the lap reset hung off onTimerLap() alone, so on
    // firmware that raises onTimerLap2 instead, laps the watch triggered itself
    // never reset the accumulator and every lap recorded the running total.
    // Two laps cannot catch that - a cumulative series and a per-lap one are
    // identical over one boundary - so this walks five.
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    var seen = [] as Array<Number>;
    var perLap = lapSunSeconds();
    for (var lap = 0; lap < perLap.size(); lap++) {
        seen.add(runLapSamples(view, perLap[lap]));
        view.onTimerLap2({ :lapTrigger => DataField.LAP_TRIGGER_TIME });
    }
    return assertPerLap(logger, view, seen, "onTimerLap2");
}

(:test)
function testManualLapsEachRecordTheirOwnMinutes(logger as Logger) as Boolean {
    // The same guarantee through the older callback, which is the only one the
    // fenix 7 generation raises.
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    var seen = [] as Array<Number>;
    var perLap = lapSunSeconds();
    for (var lap = 0; lap < perLap.size(); lap++) {
        seen.add(runLapSamples(view, perLap[lap]));
        view.onTimerLap();
    }
    return assertPerLap(logger, view, seen, "onTimerLap");
}

// lapPaging must flip the page on a button press but not on a lap the watch
// raised itself - the whole reason to check the trigger at all is that a
// structured workout's auto-laps would otherwise flip the page every mile,
// motion nobody asked for from a setting meant to be a convenience.
(:lap2, :test)
function testLapPagingOnlyRespondsToTheButtonNotAutoLaps(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    view.setLapPagingForTest(true);

    view.onTimerLap2({ :lapTrigger => DataField.LAP_TRIGGER_DISTANCE });
    Test.assertMessage(view.manualPageForTest() == 0,
        "an auto-lap by distance must not flip the page, got page "
            + view.manualPageForTest().format("%d"));

    view.onTimerLap2({ :lapTrigger => DataField.LAP_TRIGGER_TIME });
    Test.assertMessage(view.manualPageForTest() == 0,
        "an auto-lap by time must not flip the page, got page "
            + view.manualPageForTest().format("%d"));

    view.onTimerLap2({ :lapTrigger => DataField.LAP_TRIGGER_MANUAL });
    Test.assertMessage(view.manualPageForTest() == 1,
        "a manually pressed lap must flip the page, got page "
            + view.manualPageForTest().format("%d"));
    return true;
}

// The fenix 7 tier has no LapInfoType at all, so onTimerLap() cannot tell a
// button press from an auto-lap - it always treats the lap as manual, which is
// the same behaviour this app had everywhere before the distinction existed.
(:test)
function testLapPagingTreatsEveryLapAsManualWithoutLapInfoType(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    view.setLapPagingForTest(true);

    view.onTimerLap();
    Test.assertMessage(view.manualPageForTest() == 1,
        "onTimerLap() has no trigger info and must still flip the page, got page "
            + view.manualPageForTest().format("%d"));
    return true;
}

// With lapPaging off - the default - no lap of any kind should touch the page.
(:lap2, :test)
function testLapPagingOffLeavesThePageAlone(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    var view = new SolarPowerView();

    view.onTimerLap2({ :lapTrigger => DataField.LAP_TRIGGER_MANUAL });
    view.onTimerLap();
    Test.assertMessage(view.manualPageForTest() == 0,
        "lapPaging defaults to off, so no lap should move the page, got page "
            + view.manualPageForTest().format("%d"));
    return true;
}

// The end of a structured workout: the last step closes on a TIME trigger, the
// watch shows Workout Complete, and the wearer stops a couple of seconds later.
// The session-end lap is written from whatever the lap fields hold at that
// moment. They used to still hold the finished step's totals, so a three
// second final lap reported the previous step's three minutes of sun.
(:lap2, :test)
function testLap2LeavesTheNewEmptyLapInTheFields(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    for (var t = 0; t < 230; t++) {
        view.addSampleForTest(100, 84.0);
    }
    Test.assertEqualMessage(view.lapHarvestSecondsForTest(), 230,
        "the final step accumulated 230 seconds of full sun");

    view.onTimerLap2({ :lapTrigger => DataField.LAP_TRIGGER_TIME });
    logger.debug("after the step closed, lap fields hold " + view.lapFieldSecondsForTest().format("%d") + "s");
    Test.assertEqualMessage(view.lapFieldSecondsForTest(), 0,
        "the fields must hold the new empty lap, not the finished step's 230 seconds");

    // No compute() between the two closures: the stop lands first.
    view.onTimerLap2({ :lapTrigger => DataField.LAP_TRIGGER_SESSION_END });
    Test.assertEqualMessage(view.lapFieldSecondsForTest(), 0,
        "the session-end lap must not inherit anything from the step before it");
    return true;
}

// Every trigger takes the same path. The record is written before the callback
// whatever closed the lap, so none of them may leave the finished lap behind.
(:lap2, :test)
function testLap2ClearsTheFieldsForEveryTrigger(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    var triggers = [DataField.LAP_TRIGGER_MANUAL, DataField.LAP_TRIGGER_DISTANCE,
                    DataField.LAP_TRIGGER_TIME, DataField.LAP_TRIGGER_POSITION_LAP,
                    DataField.LAP_TRIGGER_SESSION_END];
    for (var i = 0; i < triggers.size(); i++) {
        for (var t = 0; t < 90; t++) {
            view.addSampleForTest(100, 84.0);
        }
        view.onTimerLap2({ :lapTrigger => triggers[i] });
        Test.assertEqualMessage(view.lapFieldSecondsForTest(), 0,
            "trigger index " + i.format("%d") + " left the finished lap in the fields");
    }
    return true;
}

// The legacy callback makes no promise about when the record is written, so it
// must still push the finished lap before resetting, for firmware that reads
// the fields only after the callback returns. The per-lap tests above already
// prove the accumulator resets on this path.
(:test)
function testLegacyLapKeepsTheFinishedLapInTheFields(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    for (var t = 0; t < 120; t++) {
        view.addSampleForTest(100, 84.0);
    }
    view.onTimerLap();
    Test.assertEqualMessage(view.lapFieldSecondsForTest(), 120,
        "the finished lap's 120 seconds must be in the fields when the callback returns");
    Test.assertEqualMessage(view.lapHarvestSecondsForTest(), 0,
        "and the accumulator must still start the next lap from zero");
    return true;
}

(:test)
function testSunPathArcIsADomeNotAStub(logger as Logger) as Boolean {
    // The sky view plots elevation against bearing. That only reads as a sun
    // path if the elevation profile actually arcs and the bearings sweep - so
    // this pins both, and would have caught the arc rendering flat against the
    // horizon far faster than looking at pixels did.
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    view.setClockForTest(SOLAR_NOON_UTC);
    view.setFixForTest(TEST_LAT_RAD, TEST_LON_RAD);

    var elev = view.profileForTest();
    var az = view.azProfileForTest();
    var peak = 0;
    var minA = 400;
    var maxA = -1;
    var lit = 0;
    for (var i = 0; i < elev.size(); i++) {
        if (elev[i] > peak) { peak = elev[i]; }
        if (elev[i] > 0) { lit += 1; }
        if (az[i] >= 0) {
            if (az[i] < minA) { minA = az[i]; }
            if (az[i] > maxA) { maxA = az[i]; }
        }
    }
    logger.debug("peak elev " + peak.format("%d") + ", lit points " + lit.format("%d")
        + ", bearing " + minA.format("%d") + " to " + maxA.format("%d"));

    Test.assertMessage(peak > 40,
        "midsummer at 30N must put the sun high, got peak " + peak.format("%d"));
    Test.assertMessage(lit >= 28,
        "almost every sample between sunrise and sunset must be above the horizon, got "
            + lit.format("%d"));
    Test.assertMessage(maxA - minA > 120,
        "the bearing must sweep across the sky, got " + (maxA - minA).format("%d")
            + " degrees");
    // And the arc has to rise and fall rather than sit flat: the middle sample
    // must clear both ends by a wide margin.
    var mid = elev[elev.size() / 2];
    Test.assertMessage(mid > (elev[2] + 20) && mid > (elev[elev.size() - 3] + 20),
        "the path must arc, mid " + mid.format("%d") + " vs ends "
            + elev[2].format("%d") + "/" + elev[elev.size() - 3].format("%d"));

    // The projection, not just the data. The arc rendered as a stub along the
    // horizon while every assertion above still passed, because the fault was in
    // folding the bearings rather than in measuring them: a day sweeps about 190
    // degrees, and folding each one to within 180 of a single reference sent the
    // whole afternoon a turn backwards. The walked series has to come out
    // strictly increasing across every lit sample.
    var walk = view.azWalkForTest();
    var prev = -9999;
    var lo2 = 9999;
    var hi2 = -9999;
    for (var i = 0; i < walk.size(); i++) {
        if (az[i] < 0 || elev[i] <= 0) { continue; }
        Test.assertMessage(walk[i] > prev,
            "walked bearings must increase: sample " + i.format("%d") + " gave "
                + walk[i].format("%d") + " after " + prev.format("%d"));
        prev = walk[i];
        if (walk[i] < lo2) { lo2 = walk[i]; }
        if (walk[i] > hi2) { hi2 = walk[i]; }
    }
    logger.debug("walked span " + (hi2 - lo2).format("%d") + " degrees");
    Test.assertMessage((hi2 - lo2) > 150,
        "the walked span must cover the day's sweep, got " + (hi2 - lo2).format("%d"));
    return true;
}

// testProjectedLevelExtrapolatesAndClamps removed along with projectedLevel()
// and the dotted-projection chart it belonged to. Replaced by the animated
// battery icon, which needs no forward extrapolation: direction is shown live,
// from the same measured rate the RATE chip already displays.

(:test, :codeOutsideHeap)
function testMemoryHeadroomIsHealthy(logger as Logger) as Boolean {
    // The number that actually matters for "will this fit on every device it
    // ships to": live heap usage against this device's own declared datafield
    // limit (131072 bytes on the 6.0 API tier, 262144 on the 5.2 tier this
    // build also now targets), with every page constructed and rendered at
    // least once so nothing lazily allocated later is missing from the count.
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    view.setFixForTest(TEST_LAT_RAD, TEST_LON_RAD);
    var buffer = offscreenBitmap(280, 280);
    if (buffer != null) {
        var dc = buffer.getDc();
        for (var page = 0; page < 7; page++) {
            view.setPageForTest(page);
            view.onUpdate(dc);
        }
    }
    var used = System.getSystemStats().usedMemory;
    // NOT usedMemory/totalMemory: totalMemory is the whole device's system RAM
    // (multiple megabytes), not the sandboxed limit Connect IQ actually
    // enforces for this app type - dividing by it produced a "1% used" reading
    // that was true and told a reader nothing, since the real ceiling is three
    // orders of magnitude smaller. The datafield limit is 131072 bytes on the
    // 6.0 API tier this build's newer targets use and 262144 on the 5.2 tier
    // its fenix 7 generation targets use (both read from each device's own
    // compiler.json, not guessed). Measured against the smaller of the two -
    // this test runs once per build, not once per device, so it reports the
    // more conservative figure rather than whichever happens to be under test.
    var limit = 131072;
    var pct = ((used * 100) / limit);
    logger.debug("memory: " + used.format("%d") + " bytes, " + pct.format("%d")
        + "% of the 131072-byte 6.0-tier limit");
    Test.assertMessage(used < limit,
        "used memory must stay under the smallest limit this build targets, got "
            + used.format("%d") + " of " + limit.format("%d"));
    return true;
}

(:test, :codeInHeap)
function testFieldDataFitsBesideItsCodeOnTheFenix6(logger as Logger) as Boolean {
    // On the fenix 6 generation the heap reading includes the loaded code, and
    // a unit-test build carries every test as well, so the check above reads
    // far past the 131072-byte limit whatever the field does. What a test can
    // still see here is the field's own data: everything it holds once built,
    // fed six hours of activity and drawn on every page at every size. That
    // measured under 4 KB when written, beside a release build that idles at
    // 59.8 of 124.4 kB there, so the budget below allows four times the growth
    // before it fails. The production build as a whole is measured in the
    // simulator instead.
    gSkipFitRecording = true;
    var before = System.getSystemStats().usedMemory;
    var view = new SolarPowerView();
    view.setClockForTest(SOLAR_NOON_UTC);
    view.setFixForTest(TEST_LAT_RAD, TEST_LON_RAD);
    feedViewActivity(view, 0, 21600);
    for (var page = 0; page < 7; page++) {
        view.setPageForTest(page);
        renderAt(view, 280, 280);
        renderAt(view, 260, 260);
        renderAt(view, 240, 240);
    }
    var held = System.getSystemStats().usedMemory - before;
    logger.debug("field data: " + held.format("%d") + " bytes");
    Test.assertMessage(held < 16384, "field data must stay small, got " + held.format("%d"));
    return true;
}

// -- FIT recording -----------------------------------------------------------
//
// FitRecorder itself cannot be unit tested - constructing a real
// FitContributor.Field outside a live activity throws a native error that
// bypasses Monkey C's exception handling entirely, uncatchable even by a
// try/catch wrapped directly around the call. What is left is the pure
// arithmetic that feeds the class.

(:test)
function testRoundedElevationRoundsAwayFromZero(logger as Logger) as Boolean {
    // Static specifically so this is callable with no FitRecorder instance at
    // all - building one is the operation this whole class cannot survive here.
    Test.assertMessage(FitRecorder.roundedElevation(2.7) == 3,
        "2.7 must round up to 3, got " + FitRecorder.roundedElevation(2.7).format("%d"));
    Test.assertMessage(FitRecorder.roundedElevation(2.3) == 2,
        "2.3 must round down to 2, got " + FitRecorder.roundedElevation(2.3).format("%d"));

    // The case a plain "+0.5, then truncate" gets backwards: toNumber() cuts
    // toward zero, so -2.7 + 0.5 = -2.2 truncates to -2 - one degree short of
    // the -3 that -2.7 actually rounds to.
    Test.assertMessage(FitRecorder.roundedElevation(-2.7) == -3,
        "-2.7 must round away from zero to -3, got "
            + FitRecorder.roundedElevation(-2.7).format("%d"));
    Test.assertMessage(FitRecorder.roundedElevation(-2.3) == -2,
        "-2.3 must round to -2, got " + FitRecorder.roundedElevation(-2.3).format("%d"));

    Test.assertMessage(FitRecorder.roundedElevation(0.0) == 0, "zero must round to zero");
    // The exact geometry a real activity produced: elevation legitimately
    // negative just after sunrise, and the value this field has to be able to
    // carry without clipping - SINT8 covers -128..127, and the sun never gets
    // anywhere near that, but a fencepost here would be silent until charted.
    Test.assertMessage(FitRecorder.roundedElevation(-89.6) == -90,
        "must round a near-horizon negative correctly, got "
            + FitRecorder.roundedElevation(-89.6).format("%d"));
    return true;
}

// -- stress and efficiency --------------------------------------------------
//
// Pre-launch checks, distinct from the correctness tests above: not "is this
// number right" but "does this survive being hammered with inputs an ordinary
// activity would never produce, for far longer than one ever would."

(:test)
function testCompassAndSkyAcrossADenseSweepOfTimes(logger as Logger) as Boolean {
    // The compass ring's dotted sweep and the sky view's useful-sun threshold
    // line are both geometry that is easy to get subtly wrong - a sweep
    // computed in the wrong space, an arc direction reversed, a threshold line
    // with no floor on how thin the sky band could be. Six
    // fixed times of day already exercise the render sweep; this walks 48,
    // evenly spaced across a full rotation, specifically hunting for a time
    // that lands on a boundary those six happened to miss - a sweep that is
    // exactly zero, a peak that is exactly at the threshold, a moment where
    // "now" sits on the last profile sample.
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    view.setFixForTest(TEST_LAT_RAD, TEST_LON_RAD);
    var rendered = 0;
    var slices = 48;
    for (var i = 0; i < slices; i++) {
        var at = RENDER_DAY + ((86400 * i) / slices);
        view.setClockForTest(at);
        view.setHeadingForTest(((i * 61) % 360).toFloat());
        view.setPageForTest(6);  // PAGE_COMPASS - private to SolarPowerView, not visible here
        if (renderAt(view, 280, 280)) {
            rendered += 1;
        }
    }
    logger.debug("compass/sky rendered cleanly at " + rendered.format("%d") + " of "
        + slices.format("%d") + " times of day");
    Test.assertMessage(rendered == slices,
        "every time of day must render without throwing, got " + rendered.format("%d"));
    return true;
}

// The compass ring's dotted future-sweep is built from small per-dash arcs,
// each one wrapping its own start and end angle into drawing space
// independently. The render test above proves every heading renders without
// throwing, but a degenerate arc (start and end landing on the same wrapped
// degree, which draws as a full circle instead of a sliver) throws nothing -
// it just draws the wrong thing, invisible to a "did this crash" check. This
// shipped, and a full circle appeared on a real watch during a real activity.
(:test)
function testRingArcEndNeverCollapsesToItsOwnStart(logger as Logger) as Boolean {
    for (var start = 0; start < 360; start += 1) {
        for (var span = 0; span <= 3; span += 1) {
            var end = SolarPowerView.ringArcEnd(start, span);
            Test.assertMessage(end != start,
                "start=" + start.format("%d") + " span=" + span.format("%d")
                    + " must not collapse to its own start (draws a full circle instead of a sliver)");
        }
    }
    return true;
}

(:test)
function testBatteryIconAcrossExtremeLevelsAndFlows(logger as Logger) as Boolean {
    // Every combination the icon's drawing code branches on: empty, full, and a
    // mid-range level; a flow with no evidence yet, a flow sitting exactly on
    // the +/-0.05 dead band that decides whether it animates at all, and flows
    // an order of magnitude past anything a real activity would measure in
    // either direction.
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    var levels = [0.0, 1.0, 50.0, 99.0, 100.0] as Array<Float>;
    var rendered = 0;
    var attempts = 0;
    for (var li = 0; li < levels.size(); li++) {
        // Seed the model at this exact level, then let addSampleForTest hold it
        // there - the view has no direct level setter, and it should not need
        // one just for a test.
        for (var t = 0; t < 3; t++) {
            view.addSampleForTest(50, levels[li]);
        }
        view.setPageForTest(2);  // PAGE_BATTERY - private to SolarPowerView, not visible here
        attempts += 1;
        if (renderAt(view, 280, 280)) {
            rendered += 1;
        }
        // Odd sizes too - the icon's geometry (nub width, fill inset) is derived
        // from the band height, and a render sweep already proved that kind of
        // derived geometry is exactly where a small size divides badly.
        attempts += 1;
        if (renderAt(view, 61, 37)) {
            rendered += 1;
        }
    }
    logger.debug("battery icon rendered cleanly " + rendered.format("%d") + " of "
        + attempts.format("%d") + " level/size combinations");
    Test.assertMessage(rendered == attempts,
        "every level and size must render without throwing, got " + rendered.format("%d")
            + " of " + attempts.format("%d"));
    return true;
}

(:test)
function testAlertEngineSurvivesThreeAdversarialDays(logger as Logger) as Boolean {
    // Three full days, oscillating every input the engine reads through its
    // full legal range every few minutes rather than holding any of them
    // steady - elevation swinging in and out of "properly up," sky flickering
    // across both shade thresholds, flow flipping between a strong drain and a
    // strong gain, and the countdown to sunset ticking through zero and past it
    // into negative. An ordinary activity holds these far steadier than this;
    // if a boundary condition anywhere in the engine can throw or runs away
    // producing an alert every second, adversarial input is what finds it.
    var engine = new AlertEngine();
    var seconds = 3 * 86400;
    var fired = 0;
    for (var t = 0; t < seconds; t += 1) {
        var elevation = 40.0 * Math.sin(t / 1200.0);
        var sky = ((t / 37) % 100);
        var flow = (((t / 53) % 20) - 10).toFloat();
        var toSunset = 1800 - (t % 5000);
        var kind = engine.evaluate(t, elevation, sky, flow, toSunset);
        if (kind != SolarAlerts.KIND_NONE) {
            fired += 1;
        }
    }
    // Three days times four alert kinds, each gated by a 30-minute refractory,
    // bounds the count generously without pinning it to today's exact
    // thresholds - the point is "did not run away," not "fired exactly N times."
    var ceiling = (seconds / SolarAlerts.REFRACTORY) * 2;
    logger.debug("three adversarial days produced " + fired.format("%d")
        + " alerts, ceiling " + ceiling.format("%d"));
    Test.assertMessage(fired <= ceiling,
        "adversarial input must not make the engine fire far more than its own "
            + "refractory budget allows, got " + fired.format("%d") + " against a ceiling of "
            + ceiling.format("%d"));
    return true;
}

(:test)
function testLongActivityAccumulatorsStayLegal(logger as Logger) as Boolean {
    // Eight hours at one sample a second - four times longer than the HISTORY
    // ring buffers hold, long enough for the harvest integral, the battery
    // model's running sums and the smoothing filter to have wrapped, reset and
    // re-accumulated many times over. Every reading taken along the way has to
    // stay inside the range that value can legally hold, the whole way through
    // - not just at the end.
    var model = new SolarModel(5);
    var hours = 8;
    var seconds = hours * 3600;
    var battery = 95.0;
    for (var t = 0; t < seconds; t += 1) {
        var intensity = (50 + (40 * Math.sin(t / 313.0))).toNumber();
        if ((t % 4000) == 0 && battery > 5.0) {
            battery -= 1.0;
        }
        model.addSample(intensity, battery, false);

        var smoothed = model.smoothed();
        Test.assertMessage(smoothed >= 0 && smoothed <= 100,
            "smoothed intensity left its legal range at t=" + t.format("%d")
                + ": " + smoothed.format("%d"));
        var avg = model.average();
        Test.assertMessage(avg >= 0 && avg <= 100,
            "average left its legal range at t=" + t.format("%d") + ": " + avg.format("%d"));
        var peak = model.peak();
        Test.assertMessage(peak >= 0 && peak <= 100,
            "peak left its legal range at t=" + t.format("%d") + ": " + peak.format("%d"));
        Test.assertMessage(model.harvestSeconds() >= 0,
            "harvest integral must never go negative, did at t=" + t.format("%d"));
    }
    logger.debug("8 simulated hours: final peak " + model.peak().format("%d")
        + "%, harvest " + model.harvestSeconds().format("%d") + "s, ticks " + model.ticks().format("%d"));
    Test.assertMessage(model.ticks() == seconds,
        "every tick must be counted, expected " + seconds.format("%d") + " got "
            + model.ticks().format("%d"));
    return true;
}

// -- alerts ----------------------------------------------------------------
//
// An alert spends the user's attention whether or not they wanted it spent, so
// these tests are mostly about the engine REFUSING to fire.

// Runs the engine for n seconds under constant conditions, returning every alert
// it raised. `from` lets a test continue an activity rather than restart it.
function runAlerts(engine as AlertEngine, from as Number, seconds as Number,
                   elevation as Float, sky as Number?, flow as Float?,
                   toSunset as Number) as Array<Number> {
    var fired = [] as Array<Number>;
    for (var t = from; t < (from + seconds); t++) {
        var kind = engine.evaluate(t, elevation, sky, flow, toSunset);
        if (kind != SolarAlerts.KIND_NONE) {
            fired.add(kind);
        }
    }
    return fired;
}

(:test)
function testShadeAlertNeedsSustainedShade(logger as Logger) as Boolean {
    var engine = new AlertEngine();
    // Four minutes under cover is a row of trees, not a problem worth a
    // full-screen interruption.
    var early = runAlerts(engine, 0, 240, 50.0, 10, null, 0);
    Test.assertMessage(early.size() == 0,
        "four minutes of shade must not raise anything, got " + early.size().format("%d"));

    // Crossing five minutes is a different matter, and it must say so exactly once.
    var later = runAlerts(engine, 240, 600, 50.0, 10, null, 0);
    Test.assertMessage(later.size() == 1,
        "sustained shade must alert exactly once, got " + later.size().format("%d"));
    Test.assertMessage(later[0] == SolarAlerts.KIND_SHADE, "and it must be the shade alert");
    return true;
}

(:test)
function testShadeIsNotReportedWhenTheSunIsSimplyLow(logger as Logger) as Boolean {
    var engine = new AlertEngine();
    // A dim reading at ten degrees is the geometry, not an obstruction. Telling a
    // user to move at dusk is telling them to chase a sun that has already gone.
    var fired = runAlerts(engine, 0, 3600, 10.0, 5, null, 0);
    Test.assertMessage(fired.size() == 0,
        "low sun must never be reported as shade, got " + fired.size().format("%d"));
    return true;
}

(:test)
function testAllClearOnlyFollowsAWarning(logger as Logger) as Boolean {
    var engine = new AlertEngine();
    // Full sun from the first second: there was never a warning, so there is
    // nothing to stand down from.
    var bright = runAlerts(engine, 0, 3600, 50.0, 95, null, 0);
    Test.assertMessage(bright.size() == 0,
        "sunshine alone must not be announced, got " + bright.size().format("%d"));

    // Now earn a warning, then come back out into it.
    var dark = runAlerts(engine, 3600, 400, 50.0, 10, null, 0);
    Test.assertMessage(dark.size() == 1 && dark[0] == SolarAlerts.KIND_SHADE,
        "shade must be reported once the hold is met");
    var back = runAlerts(engine, 4000, 400, 50.0, 95, null, 0);
    Test.assertMessage(back.size() == 1 && back[0] == SolarAlerts.KIND_SUN,
        "and the all-clear must follow it");
    return true;
}

(:test)
function testGainNeedsAMeasuredRateNotAGuess(logger as Logger) as Boolean {
    var engine = new AlertEngine();
    // Null is what the model reports while the rate is still being measured. An
    // alert is never raised on a guess.
    var unknown = runAlerts(engine, 0, 1200, 50.0, 80, null, 0);
    Test.assertMessage(unknown.size() == 0,
        "an unmeasured flow must never alert, got " + unknown.size().format("%d"));

    // Draining is the normal case and is not news either.
    var draining = runAlerts(engine, 1200, 1200, 50.0, 80, 4.0, 0);
    Test.assertMessage(draining.size() == 0, "ordinary drain must not alert");

    // Actually gaining is the moment worth interrupting for.
    var gaining = runAlerts(engine, 2400, 600, 50.0, 80, -1.2, 0);
    Test.assertMessage(gaining.size() == 1 && gaining[0] == SolarAlerts.KIND_GAIN,
        "a measured gain must alert once, got " + gaining.size().format("%d"));
    return true;
}

(:test)
function testNothingRepeatsInsideTheRefractoryWindow(logger as Logger) as Boolean {
    var engine = new AlertEngine();
    // Two hours of unbroken shade is one piece of information, not seven thousand.
    var fired = runAlerts(engine, 0, 7200, 50.0, 5, null, 0);
    Test.assertMessage(fired.size() <= 4,
        "two hours of shade must stay within the refractory budget, got "
            + fired.size().format("%d"));
    for (var i = 0; i < fired.size(); i++) {
        Test.assertMessage(fired[i] == SolarAlerts.KIND_SHADE,
            "and must never turn into a different alert");
    }
    logger.debug("two hours of unbroken shade produced " + fired.size().format("%d") + " alerts");
    return true;
}

(:test)
function testSunsetWarningFiresOnceInsideTheLead(logger as Logger) as Boolean {
    var engine = new AlertEngine();
    // An hour out is too early to be useful.
    var early = runAlerts(engine, 0, 300, 30.0, 80, null, 3600);
    Test.assertMessage(early.size() == 0, "an hour of daylight left is not a warning");

    var due = runAlerts(engine, 300, 300, 30.0, 80, null, 1500);
    Test.assertMessage(due.size() == 1 && due[0] == SolarAlerts.KIND_SUNSET,
        "half an hour out must warn exactly once, got " + due.size().format("%d"));

    // And after dark there is nothing left to warn about.
    var after = runAlerts(engine, 600, 600, -5.0, null, null, 0);
    Test.assertMessage(after.size() == 0, "a set sun must not keep warning");
    return true;
}

// -- solar geometry --------------------------------------------------------
//
// Fixtures come from the test activity: a walk near 30.62N 97.87W on
// 2026-09-09, cross-checked against the NOAA equations and against the closed
// form for solar noon, elevation = 90 - |latitude - declination|.

const TEST_LAT_RAD = 0.5344677444d;   // 30.6227 N
const TEST_LON_RAD = -1.7081166813d;  // 97.8679 W
const ACTIVITY_START = 1788976270;    // 2026-09-09 17:51:10 UTC
const ACTIVITY_END = 1788978710;      // 2026-09-09 18:31:50 UTC

(:test)
function testSunElevationMatchesTheRealActivity(logger as Logger) as Boolean {
    var start = SolarGeometry.elevationDegrees(ACTIVITY_START, TEST_LAT_RAD, TEST_LON_RAD);
    var end = SolarGeometry.elevationDegrees(ACTIVITY_END, TEST_LAT_RAD, TEST_LON_RAD);
    logger.debug("elevation " + start.format("%.2f") + " -> " + end.format("%.2f") + " degrees");
    Test.assertMessage((start - 63.4).abs() < 0.5, "sun was 63.4 degrees up at the start");
    Test.assertMessage((end - 64.9).abs() < 0.5, "and 64.9 degrees up forty minutes later");
    Test.assertMessage(end > start, "the walk was still climbing towards solar noon");
    return true;
}

(:test)
function testSolarNoonMatchesTheClosedForm(logger as Logger) as Boolean {
    // At solar noon the elevation is exactly 90 - |latitude - declination|, and
    // declination at the June solstice is +23.44 degrees.
    var best = -99.0;
    for (var s = 0; s < 86400; s += 60) {
        var e = SolarGeometry.elevationDegrees(1782043200 - 43200 + s, TEST_LAT_RAD, TEST_LON_RAD);
        if (e > best) {
            best = e;
        }
    }
    var expected = 90.0 - (30.6227 - 23.44).abs();
    logger.debug("solstice noon " + best.format("%.2f") + " vs closed form " + expected.format("%.2f"));
    Test.assertMessage((best - expected).abs() < 0.5, "solstice noon elevation matches the closed form");
    return true;
}

(:test)
function testSunIsBelowTheHorizonAtNight(logger as Logger) as Boolean {
    // 06:00 UTC is just after 01:00 local at this longitude.
    var night = SolarGeometry.elevationDegrees(1788933600, TEST_LAT_RAD, TEST_LON_RAD);
    logger.debug("night elevation " + night.format("%.2f"));
    Test.assertMessage(night < 0.0, "the sun is below the horizon in the middle of the night");
    Test.assertEqualMessage(SolarGeometry.availableFraction(night), 0.0,
        "nothing is available below the horizon");
    Test.assertMessage(SolarGeometry.clearSkyPercent(50, night) == null,
        "and no sky index is offered");
    return true;
}

(:test)
function testAvailableFractionTracksHeight(logger as Logger) as Boolean {
    Test.assertEqualMessage(SolarGeometry.availableFraction(0.0), 0.0, "nothing at the horizon");
    Test.assertMessage((SolarGeometry.availableFraction(30.0) - 0.5).abs() < 0.01,
        "half at thirty degrees");
    Test.assertMessage((SolarGeometry.availableFraction(90.0) - 1.0).abs() < 0.001,
        "everything with the sun overhead");
    Test.assertMessage(SolarGeometry.availableFraction(60.0) > SolarGeometry.availableFraction(45.0),
        "a higher sun always offers more");
    return true;
}

(:test)
function testSkyIndexSeparatesLowSunFromBlockedSun(logger as Logger) as Boolean {
    // Sun overhead: measured intensity is the whole story.
    Test.assertEqualMessage(SolarGeometry.clearSkyPercent(80, 90.0), 80,
        "with the sun overhead the index is the reading itself");

    // Sun at 30 degrees only allows half, so half a reading is a clear sky.
    var half = SolarGeometry.clearSkyPercent(50, 30.0);
    if (half == null) {
        Test.assertMessage(false, "thirty degrees is high enough to judge");
        return false;
    }
    logger.debug("50% measured at 30 degrees is a sky index of " + half.format("%d"));
    Test.assertMessage((half - 100).abs() <= 1, "50% at 30 degrees is everything on offer");

    // The same reading with the sun high means something is in the way.
    var blocked = SolarGeometry.clearSkyPercent(50, 90.0);
    Test.assertMessage(blocked != null && blocked < 60,
        "the same reading under a high sun means the panel is blocked");

    Test.assertMessage(SolarGeometry.clearSkyPercent(50, 5.0) == null,
        "too low a sun is withheld rather than guessed at");
    Test.assertEqualMessage(SolarGeometry.clearSkyPercent(100, 20.0), 100,
        "the index never exceeds a full sky");
    return true;
}

(:test)
function testDayOfYearAndLeapYears(logger as Logger) as Boolean {
    Test.assertEqualMessage(SolarGeometry.dayOfYear(2026, 1, 1), 1, "first of January");
    Test.assertEqualMessage(SolarGeometry.dayOfYear(2026, 12, 31), 365, "last of a common year");
    Test.assertEqualMessage(SolarGeometry.dayOfYear(2024, 12, 31), 366, "last of a leap year");
    Test.assertEqualMessage(SolarGeometry.dayOfYear(2024, 3, 1), 61, "leap day shifts March");
    Test.assertEqualMessage(SolarGeometry.dayOfYear(2026, 3, 1), 60, "but not in a common year");
    Test.assertEqualMessage(SolarGeometry.dayOfYear(2026, 9, 9), 252, "the test activity's date");

    Test.assertMessage(SolarGeometry.isLeapYear(2024), "2024 is a leap year");
    Test.assertMessage(!SolarGeometry.isLeapYear(2026), "2026 is not");
    Test.assertMessage(!SolarGeometry.isLeapYear(1900), "1900 is not, being a century");
    Test.assertMessage(SolarGeometry.isLeapYear(2000), "2000 is, being a four hundredth");
    return true;
}

// -- cost ------------------------------------------------------------------
//
// A data field redraws about once a second for the whole activity, so work in
// onUpdate() is paid for out of the battery it is reporting on. This measures
// the real cost per frame rather than guessing at it.

(:test)
function testFrameCostIsReasonable(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    var view = new SolarPowerView();
    var trace = realSolarTrace();
    var level = 74.0;
    for (var i = 0; i < trace.size(); i++) {
        level -= 0.01;
        view.addSampleForTest(trace[i], level);
    }
    var buffer = offscreenBitmap(280, 280);
    if (buffer == null) {
        logger.debug("no off-screen buffer available; cost not measured");
        return true;
    }
    var dc = buffer.getDc();

    // A real fix at solar noon, so the sun geometry and the forecast are actually
    // exercised. Pinned, because at night the daylight arc gives up and falls
    // back to the zone bar, and the benchmark then times the cheap path and
    // reports a frame cost the field never actually pays in daylight.
    view.setClockForTest(SOLAR_NOON_UTC);
    view.setFixForTest(TEST_LAT_RAD, TEST_LON_RAD);

    var rounds = 40;
    var worst = 0.0;
    for (var page = 0; page < 7; page++) {
        view.setPageForTest(page);
        view.onUpdate(dc);
        var start = System.getTimer();
        for (var i = 0; i < rounds; i++) {
            // One cache generation per frame, exactly as compute() produces.
            view.tickCachesForTest();
            view.onUpdate(dc);
        }
        var each = (System.getTimer() - start).toFloat() / rounds;
        if (each > worst) {
            worst = each;
        }
        logger.debug("page " + page.format("%d") + ": " + each.format("%.2f") + " ms/frame");
        Test.assertMessage(each < 60.0,
            "a frame must stay far inside the one second between redraws");
    }
    logger.debug("worst page " + worst.format("%.2f") + " ms/frame");
    return true;
}

(:test)
function testSolarBonusIsMeasuredNotAssumed(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    // Five hours alternating deep shade and full sun, draining 6%/h in the dark
    // and 3%/h in the sun, so the sun is worth 3%/h at full strength.
    var level = 95.0;
    for (var i = 0; i < 18000; i++) {
        var sun = ((i / 1800) % 2 == 0) ? 0 : 100;
        level -= (6.0 - (3.0 * sun / 100.0)) / 3600.0;
        model.addSample(sun, level, false);
    }
    var bonus = model.solarBonusMinutes();
    if (bonus == null) {
        Test.assertMessage(false, "five hours across both extremes is enough evidence");
        return false;
    }
    // Half the time in full sun over five hours saves about 3 * 0.5 * 5 = 7.5%,
    // and at roughly 4.5%/h drain that is about 100 minutes of runtime.
    logger.debug("sun gave +" + bonus.format("%d") + " minutes");
    Test.assertMessage(bonus > 40 && bonus < 200, "the bonus is in the right region");
    return true;
}

(:test)
function testSolarBonusIsWithheldWithoutEvidence(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 90.0;
    // Constant light: nothing to fit a solar benefit against.
    for (var i = 0; i < 7200; i++) {
        level -= 4.0 / 3600.0;
        model.addSample(55, level, false);
    }
    Test.assertMessage(model.solarBonusMinutes() == null,
        "no claim about what the sun gave without evidence that it gave anything");

    var empty = new SolarModel(1);
    Test.assertMessage(empty.solarBonusMinutes() == null, "and none from an empty activity");
    return true;
}


(:test)
function testSunEventsWithoutWeatherData(logger as Logger) as Boolean {
    // The real activity's position and date. Expected values come from an
    // independent scan of the elevation curve for the same day.
    var events = SolarGeometry.sunEvents(ACTIVITY_START, TEST_LAT_RAD, TEST_LON_RAD);
    if (events == null) {
        Test.assertMessage(false, "the sun both rises and sets in Texas in September");
        return false;
    }
    var rise = events[0];
    var set = events[1];
    logger.debug("computed rise=" + rise.format("%d") + " set=" + set.format("%d"));

    // 2026-09-09 12:16 UTC and 2026-09-10 00:44 UTC, to within a few minutes.
    Test.assertMessage((rise - 1788956160).abs() < 420, "sunrise lands within 7 minutes");
    Test.assertMessage((set - 1789001040).abs() < 420, "sunset lands within 7 minutes");
    Test.assertMessage(set > rise, "the day's sunset follows its sunrise even west of Greenwich");

    var hours = (set - rise) / 3600.0;
    Test.assertMessage(hours > 12.0 && hours < 13.0, "about twelve and a half hours of daylight");

    // The activity ran inside that window.
    Test.assertEqualMessage(sunWindowState(ACTIVITY_START, rise, set), SUN_DAY,
        "the walk happened in daylight");
    return true;
}

(:test)
function testSunEventsHandlePolarLatitudes(logger as Logger) as Boolean {
    // Tromso, well inside the Arctic circle: no sunrise or sunset at either
    // solstice, and the field must report that rather than inventing a time.
    var lat = 1.2156d;   // 69.65 N
    var lon = 0.3309d;   // 18.96 E
    Test.assertMessage(SolarGeometry.sunEvents(1782043200, lat, lon) == null,
        "midnight sun has no sunset to report");
    Test.assertMessage(SolarGeometry.sunEvents(1797940800, lat, lon) == null,
        "polar night has no sunrise to report");

    // And somewhere ordinary it still works.
    var london = SolarGeometry.sunEvents(1788976270, 0.8988d, -0.0022d);
    Test.assertMessage(london != null, "London has a sunrise in September");
    return true;
}

(:test)
function testLearnedCalibrationMakesTheBonusAvailableEarly(logger as Logger) as Boolean {
    // A short activity cannot fit the solar benefit, so on its own it has no
    // bonus to show.
    var fresh = new SolarModel(1);
    var level = 88.0;
    for (var i = 0; i < 1800; i++) {
        level -= 4.0 / 3600.0;
        fresh.addSample(70, level, false);
    }
    Test.assertMessage(fresh.solarBonusMinutes() == null,
        "half an hour cannot fit a solar benefit on its own");

    // Same activity on a watch that measured itself on an earlier one.
    var seeded = new SolarModel(1);
    seeded.setCalibration(calibrationWith(3.0, 4.5));
    level = 88.0;
    for (var i = 0; i < 1800; i++) {
        level -= 4.0 / 3600.0;
        seeded.addSample(70, level, false);
    }
    var bonus = seeded.solarBonusMinutes();
    if (bonus == null) {
        Test.assertMessage(false, "carried-over calibration should produce a bonus");
        return false;
    }
    logger.debug("seeded bonus +" + bonus.format("%d") + " minutes");
    // 3%/h at 70% sun for half an hour is about 1.05%, worth ~14 min at 4.5%/h.
    Test.assertMessage(bonus > 5 && bonus < 30, "and it lands in the right region");
    Test.assertMessage(seeded.bonusIsLearned(),
        "and is marked as carried over rather than measured here");
    return true;
}

(:test)
function testMeasuredBonusOverridesLearned(logger as Logger) as Boolean {
    // Five hours across both extremes: this activity can fit its own benefit,
    // and that must win over whatever was carried in.
    var model = new SolarModel(1);
    model.setCalibration(calibrationWith(99.0, 99.0));   // deliberately absurd
    var level = 95.0;
    for (var i = 0; i < 18000; i++) {
        var sun = ((i / 1800) % 2 == 0) ? 0 : 100;
        level -= (6.0 - (3.0 * sun / 100.0)) / 3600.0;
        model.addSample(sun, level, false);
    }
    Test.assertMessage(!model.bonusIsLearned(),
        "an activity that fitted its own benefit does not report a carried-over one");
    var saving = model.effectiveSaving();
    if (saving == null) {
        Test.assertMessage(false, "the fit should have converged");
        return false;
    }
    Test.assertMessage((saving - 3.0).abs() < 1.0,
        "the measured coefficient wins over the seeded one");
    return true;
}

// -- calibration carried between activities ----------------------------------
//
// Sun Bonus needs far more varied light than one ordinary activity holds, so
// its evidence is pooled across activities as a fixed-effects fit: each
// activity's intervals are centred on that activity's own means before they
// are combined, so differences in baseline drain between activities (GPS mode,
// backlight, heat) can never be mistaken for the effect of the sun.

// A calibration equivalent to one earlier activity that only just met every
// rule the pooled fit applies, at the given saving, plus ten measured hours at
// the given drain.
function calibrationWith(savingPerHour as Float, drainPerHour as Float) as Array<Float> {
    var cxx = BatteryModel.REG_MIN_VARIATION;
    return [(BatteryModel.REG_MIN_INTERVALS - 1).toFloat(), cxx, -(savingPerHour / 100.0) * cxx,
            0.0, 100.0, 10.0, drainPerHour * 10.0] as Array<Float>;
}

// One activity on a watch that reports whole percent: `benefit` percent per
// hour saved at full sun on top of `darkDrain`, alternating shade and sun.
function feedWholePercent(model as SolarModel, darkDrain as Float, benefit as Float,
                          shadeMinutes as Number, sunMinutes as Number, seconds as Number) as Void {
    feedWholePercentBetween(model, darkDrain, benefit, shadeMinutes, sunMinutes, seconds, 0, 100);
}

// The same, with the shade and the sun at chosen intensities.
function feedWholePercentBetween(model as SolarModel, darkDrain as Float, benefit as Float,
                                 shadeMinutes as Number, sunMinutes as Number, seconds as Number,
                                 shade as Number, sun as Number) as Void {
    var level = 90.5;
    var cycle = (shadeMinutes + sunMinutes) * 60;
    for (var t = 0; t < seconds; t++) {
        var light = ((t % cycle) < (shadeMinutes * 60)) ? shade : sun;
        level -= (darkDrain - (benefit * light / 100.0)) / 3600.0;
        model.addSample(light, level.toNumber().toFloat(), false);
    }
}

(:test)
function testPooledFitIgnoresEachActivitysOwnBaseline(logger as Logger) as Boolean {
    // The confound fixed effects exist for. A: a frugal activity, mostly in
    // shade. B: a hungry one, mostly in sun. Both gain the same 3%/h at full
    // sun, but a plain pooled fit sees low drain in the dark and high drain in
    // the sun and concludes sunlight costs battery.
    // Each activity's own light varies by less than the early rule's 20
    // points, so neither can fit alone under either rule; between them the
    // light spans 60 points.
    var a = new SolarModel(1);
    feedWholePercentBetween(a, 4.0, 3.0, 45, 15, 10200, 0, 15);
    var b = new SolarModel(1);
    feedWholePercentBetween(b, 12.0, 3.0, 15, 45, 3900, 45, 60);

    var ca = a.activityCalibration();
    var cb = b.activityCalibration();
    logger.debug("A dof=" + ca[0].format("%.0f") + " B dof=" + cb[0].format("%.0f"));
    Test.assertMessage(a.solarOffsetPerHour() == null && b.solarOffsetPerHour() == null,
        "each activity alone must be too thin to fit");
    Test.assertMessage(ca[0] + cb[0] >= (BatteryModel.REG_MIN_INTERVALS - 1).toFloat(),
        "together they must carry enough evidence for the test to mean anything");

    b.setCalibration(SolarModel.mergeCalibration(SolarModel.emptyCalibration(), ca));
    var pooled = b.effectiveSaving();
    if (pooled == null) {
        Test.assertMessage(false, "two activities with varied light must pool into a fit");
        return false;
    }
    logger.debug("pooled saving " + pooled.format("%.3f") + "%/h for a true 3.000");
    Test.assertMessage((pooled - 3.0).abs() < 0.5,
        "the pooled fit must recover the true 3%/h despite the baselines, got " + pooled.format("%.3f"));
    Test.assertMessage(b.bonusIsLearned(),
        "a coefficient resting on an earlier activity must be marked as carried over");
    return true;
}

(:test)
function testLightThatOnlyVariesBetweenActivitiesIsNotEvidence(logger as Logger) as Boolean {
    // All shade on one day, all sun on another, different baselines. The two
    // days differ in light and in drain, but nothing separates the sun from
    // everything else that differed, so no coefficient may be claimed.
    var dark = new SolarModel(1);
    feedWholePercent(dark, 4.0, 3.0, 1000, 0, 30000);
    var sunny = new SolarModel(1);
    feedWholePercent(sunny, 7.0, 3.0, 0, 1000, 30000);
    var cd = dark.activityCalibration();
    Test.assertMessage(cd[0] >= 11.0, "enough intervals that only the light rule can refuse it");
    sunny.setCalibration(SolarModel.mergeCalibration(SolarModel.emptyCalibration(), cd));
    Test.assertMessage(sunny.effectiveSaving() == null,
        "light that differs only between activities must not produce a coefficient");
    return true;
}

(:test)
function testPooledFitWithNoHistoryIsTheActivitysOwnFit(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    var level = 95.0;
    for (var i = 0; i < 18000; i++) {
        var sun = ((i / 1800) % 2 == 0) ? 0 : 100;
        level -= (6.0 - (3.0 * sun / 100.0)) / 3600.0;
        model.addSample(sun, level, false);
    }
    var own = model.solarOffsetPerHour();
    var pooled = model.pooledSavingPerHour();
    Test.assertMessage(own != null && pooled != null, "a long varied activity fits both ways");
    Test.assertMessage(own == pooled, "with nothing carried over, pooling must change nothing");
    return true;
}

(:test)
function testAnActivityNeedsThreeStepsToContribute(logger as Logger) as Boolean {
    // Two steps bound one interval, and one interval cannot separate the sun
    // from that activity's own drain. The first step starts the count, so a
    // third is needed before anything is added.
    var model = new SolarModel(1);
    feedWholePercent(model, 6.0, 0.0, 1, 0, 1500);     // steps at ~5 and ~15 minutes
    Test.assertMessage(model.batteryEdges() == 2, "setup: two steps, got " + model.batteryEdges().format("%d"));
    var c = model.activityCalibration();
    Test.assertMessage(c[0] == 0.0 && c[1] == 0.0, "two steps must contribute no evidence");

    var more = new SolarModel(1);
    feedWholePercent(more, 6.0, 0.0, 1, 0, 2100);      // a third step at ~25 minutes
    Test.assertMessage(more.batteryEdges() == 3, "setup: three steps, got " + more.batteryEdges().format("%d"));
    Test.assertMessage(more.activityCalibration()[0] == 1.0, "three steps contribute one degree of freedom");
    return true;
}

(:test)
function testMergeScalesBackOnlyTheOldestEvidence(logger as Logger) as Boolean {
    var prior = [120.0, 1200.0, -24.0, 0.0, 100.0, 18.0, 36.0] as Array<Float>;   // 2.0%/h, 2.0%/h drain
    var add = [20.0, 400.0, -16.0, 10.0, 90.0, 5.0, 15.0] as Array<Float>;        // 4.0%/h, 3.0%/h drain
    var m = SolarModel.mergeCalibration(prior, add);
    Test.assertMessage((m[0] - 120.0).abs() < 0.001, "degrees of freedom are capped at 120, got " + m[0].format("%.3f"));
    var saving = -(m[2] / m[1]) * 100.0;
    Test.assertMessage((saving - 2.5714).abs() < 0.001,
        "the new activity counts in full against scaled-back history, got " + saving.format("%.4f"));
    Test.assertMessage((m[5] - 20.0).abs() < 0.001, "drain hours are capped at 20");
    Test.assertMessage(((m[6] / m[5]) - 2.25).abs() < 0.001, "drain is total percent over total hours");
    Test.assertMessage(m[3] == 0.0 && m[4] == 100.0, "light range is the union while history remains");

    var small = SolarModel.mergeCalibration([10.0, 100.0, -2.0, 20.0, 60.0, 2.0, 4.0] as Array<Float>, add);
    Test.assertMessage(small[0] == 30.0 && small[1] == 500.0 && small[2] == -18.0,
        "under the cap, merging is exact addition");
    return true;
}

(:test)
function testLearnedDrainNeedsAnHourOfMeasurement(logger as Logger) as Boolean {
    var thin = new SolarModel(1);
    thin.setCalibration([0.0, 0.0, 0.0, 1000.0, -1000.0, 0.5, 1.0] as Array<Float>);
    Test.assertMessage(thin.effectiveDrain() == null, "half an hour of measured drain is one quantised step");
    var enough = new SolarModel(1);
    enough.setCalibration([0.0, 0.0, 0.0, 1000.0, -1000.0, 2.0, 4.0] as Array<Float>);
    var d = enough.effectiveDrain();
    Test.assertMessage(d != null && (d - 2.0).abs() < 0.0001, "two measured hours at 4% is 2%/h");
    return true;
}

(:test)
function testStoredCalibrationIsValidatedNotTrusted(logger as Logger) as Boolean {
    Test.assertMessage(SolarModel.calibrationFrom([1, 2.0, 3.0] as Array, 1) == null, "too short");
    Test.assertMessage(SolarModel.calibrationFrom([1, 11, 312.5, -6.25, 0, 100, "x", 40.0] as Array, 1) == null,
        "a non-number anywhere");
    Test.assertMessage(SolarModel.calibrationFrom([1, -1.0, 312.5, -6.25, 0.0, 100.0, 10.0, 40.0] as Array, 1) == null,
        "negative degrees of freedom");
    var c = SolarModel.calibrationFrom([1, 11, 312.5, -6.25, 0, 100, 10, 40] as Array, 1);
    Test.assertMessage(c != null && c[0] == 11.0 && c[6] == 40.0, "whole numbers read back as floats");
    return true;
}

// -- calibration lifecycle through real storage -------------------------------

function clearCalibrationStorage() as Void {
    Application.Storage.deleteValue(SolarPowerView.CAL_KEY);
    Application.Storage.deleteValue(SolarPowerView.CAL_PENDING_KEY);
    Application.Storage.deleteValue(SolarPowerView.LEGACY_SAVING_KEY);
    Application.Storage.deleteValue(SolarPowerView.LEGACY_DRAIN_KEY);
}

// One continuous activity alternating twenty minutes of shade and sun at whole
// percent, fed from `fromSecond` to `toSecond`, so a stop and resume can be
// simulated without the battery jumping back to where it started.
function feedViewActivity(view as SolarPowerView, fromSecond as Number, toSecond as Number) as Void {
    var level = 90.5;
    for (var t = 0; t < toSecond; t++) {
        var sun = ((t / 1200) % 2 == 0) ? 0 : 100;
        level -= (8.0 - (4.0 * sun / 100.0)) / 3600.0;
        if (t >= fromSecond) {
            view.addSampleForTest(sun, level.toNumber().toFloat());
        }
    }
}

(:test)
function testAnActivityIsCommittedExactlyOnceThroughStopsAndResumes(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    clearCalibrationStorage();
    var view = new SolarPowerView();
    view.beginActivityForTest(1000);
    feedViewActivity(view, 0, 3600);
    view.onTimerStop();                 // snapshot written
    feedViewActivity(view, 3600, 7200); // resumed
    view.onTimerStop();                 // snapshot written over itself
    var expected = view.calibrationForTest();
    Test.assertMessage(expected[0] == 0.0, "nothing is committed while the activity runs");
    view.onTimerReset();                // activity ends
    var committed = view.calibrationForTest();
    logger.debug("committed dof " + committed[0].format("%.0f") + ", drain hours " + committed[5].format("%.2f"));
    Test.assertMessage(committed[0] > 0.0, "the activity must contribute");

    var next = new SolarPowerView();
    var loaded = next.calibrationForTest();
    Test.assertMessage(loaded[0] == committed[0] && loaded[1] == committed[1] && loaded[5] == committed[5],
        "the next activity must load exactly what was committed, not a double count");
    Test.assertMessage(Application.Storage.getValue(SolarPowerView.CAL_PENDING_KEY) == null,
        "no snapshot may survive its own activity's end");
    next.onTimerReset();                // an empty activity changes nothing
    Test.assertMessage(next.calibrationForTest()[0] == committed[0], "an empty activity adds nothing");
    clearCalibrationStorage();
    return true;
}

(:test)
function testACrashedActivityIsFoldedInByTheNextOne(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    clearCalibrationStorage();
    var crashed = new SolarPowerView();
    crashed.beginActivityForTest(1000);
    feedViewActivity(crashed, 0, 7200);
    crashed.onTimerStop();              // snapshot written, then no onTimerReset ever arrives
    var snapshotDof = (Application.Storage.getValue(SolarPowerView.CAL_PENDING_KEY) as Array)[2];

    var next = new SolarPowerView();
    Test.assertMessage(next.calibrationForTest()[0] == 0.0, "nothing committed before the next activity starts");
    next.beginActivityForTest(2000);
    Test.assertMessage(next.calibrationForTest()[0] == (snapshotDof as Numeric).toFloat(),
        "the crashed activity's snapshot must be folded in once the next activity starts");
    Test.assertMessage(Application.Storage.getValue(SolarPowerView.CAL_PENDING_KEY) == null,
        "and removed so it cannot be folded in again");
    next.onTimerReset();
    var again = new SolarPowerView();
    Test.assertMessage(again.calibrationForTest()[0] == (snapshotDof as Numeric).toFloat(),
        "still counted exactly once after that activity ends");
    clearCalibrationStorage();
    return true;
}

(:test)
function testARestartedFieldDoesNotRecountItsOwnActivity(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    clearCalibrationStorage();
    var first = new SolarPowerView();
    first.beginActivityForTest(1000);
    feedViewActivity(first, 0, 7200);
    first.onTimerStop();

    // The same activity, the field reloaded mid-way.
    var reloaded = new SolarPowerView();
    reloaded.beginActivityForTest(1000);
    Test.assertMessage(reloaded.calibrationForTest()[0] == 0.0,
        "an activity's own snapshot must never be folded into itself");
    Test.assertMessage(Application.Storage.getValue(SolarPowerView.CAL_PENDING_KEY) != null,
        "and must be left in place");
    clearCalibrationStorage();
    return true;
}

(:test)
function testTheFirstReleasesSunBonusIsCarriedForwardOnce(logger as Logger) as Boolean {
    // Exactly what the first release wrote: two floats under their own keys.
    gSkipFitRecording = true;
    clearCalibrationStorage();
    Application.Storage.setValue(SolarPowerView.LEGACY_SAVING_KEY, 3.0);
    Application.Storage.setValue(SolarPowerView.LEGACY_DRAIN_KEY, 5.0);
    var view = new SolarPowerView();
    var c = view.calibrationForTest();
    Test.assertMessage(c[0] == 11.0 && c[1] == BatteryModel.REG_MIN_VARIATION,
        "carried at the least evidence that release could have saved it from");
    Test.assertMessage(c[5] == 0.0 && c[6] == 0.0,
        "its drain is not carried: the hours behind it were never recorded");
    var saving = view.effectiveSavingForTest();
    Test.assertMessage(saving != null && (saving - 3.0).abs() < 0.001,
        "the saving the user already had must survive the update");
    Test.assertMessage(Application.Storage.getValue(SolarPowerView.LEGACY_SAVING_KEY) == null
        && Application.Storage.getValue(SolarPowerView.LEGACY_DRAIN_KEY) == null,
        "the old keys must be removed once carried");

    var again = new SolarPowerView();
    var reloaded = again.calibrationForTest();
    Test.assertMessage(reloaded[0] == 11.0 && reloaded[2] == c[2], "carried exactly once");
    clearCalibrationStorage();
    return true;
}

(:test)
function testALegacySaveNeverOverridesOrJoinsNewerCalibration(logger as Logger) as Boolean {
    gSkipFitRecording = true;
    clearCalibrationStorage();
    // Interrupted between writing the carried calibration and removing the old
    // keys: the committed one is kept and the old value is not added again.
    var c = calibrationWith(2.5, 4.0);
    Application.Storage.setValue(SolarPowerView.CAL_KEY,
        [SolarPowerView.CAL_VERSION, c[0], c[1], c[2], c[3], c[4], c[5], c[6]] as Array<Numeric>);
    Application.Storage.setValue(SolarPowerView.LEGACY_SAVING_KEY, 9.0);
    Application.Storage.setValue(SolarPowerView.LEGACY_DRAIN_KEY, 5.0);
    var view = new SolarPowerView();
    var loaded = view.calibrationForTest();
    var saving = view.effectiveSavingForTest();
    Test.assertMessage(loaded[0] == 11.0 && saving != null && (saving - 2.5).abs() < 0.001,
        "newer calibration must win untouched");
    Test.assertMessage(Application.Storage.getValue(SolarPowerView.LEGACY_SAVING_KEY) == null,
        "and the old keys still removed");

    // Anything that is not a saving the first release could have written.
    clearCalibrationStorage();
    Application.Storage.setValue(SolarPowerView.LEGACY_SAVING_KEY, "3.0");
    var junk = new SolarPowerView();
    Test.assertMessage(junk.calibrationForTest()[0] == 0.0
        && Application.Storage.getValue(SolarPowerView.CAL_KEY) == null, "a non-number is ignored");
    Test.assertMessage(Application.Storage.getValue(SolarPowerView.LEGACY_SAVING_KEY) == null, "and removed");
    Test.assertMessage(SolarModel.calibrationFromLegacy(0.0) == null
        && SolarModel.calibrationFromLegacy(-2.0) == null, "no saving is no evidence");
    clearCalibrationStorage();
    return true;
}

(:test)
function testSunBonusPageRendersFromCarriedCalibration(logger as Logger) as Boolean {
    // The pooled path adds calls under the bonus page's draw, which is where
    // this field has overflowed its stack before. Render it for real.
    gSkipFitRecording = true;
    clearCalibrationStorage();
    var c = calibrationWith(2.5, 4.0);
    Application.Storage.setValue(SolarPowerView.CAL_KEY,
        [SolarPowerView.CAL_VERSION, c[0], c[1], c[2], c[3], c[4], c[5], c[6]] as Array<Numeric>);
    var view = new SolarPowerView();
    view.setFixForTest(TEST_LAT_RAD, TEST_LON_RAD);
    for (var i = 0; i < 1200; i++) {
        view.addSampleForTest(70, 80.0);
    }
    var saving = view.effectiveSavingForTest();
    Test.assertMessage(saving != null && (saving - 2.5).abs() < 0.01,
        "the loaded calibration must drive the page");
    view.setPageForTest(5);
    var ok = renderAt(view, 280, 280) && renderAt(view, 260, 260) && renderAt(view, 240, 240);
    Test.assertMessage(ok, "the bonus page must render at every supported size");
    clearCalibrationStorage();
    return true;
}


// -- drain ceiling ---------------------------------------------------------
//
// Reproduces the real recording that prompted this: 22 minutes at a steady 80%,
// with the reported level never moving once. No rate can be measured from that,
// and inventing one is the whole failure mode this project started by removing -
// but "it has not dropped in 22 minutes" is real information and bounds the
// answer, so the field says that instead of a dash.

(:test)
function testCeilingBoundsDrainWhenTheLevelNeverMoves(logger as Logger) as Boolean {
    var model = new SolarModel(1);
    // Twenty-two minutes at a flat 80%, exactly as the watch reported it.
    for (var i = 0; i < 1314; i++) {
        model.addSample(45, 80.0, false);
    }
    Test.assertMessage(model.netFlowPerHour() == null,
        "a level that never moved yields no measured rate");
    Test.assertMessage(model.drainPerHour() == null, "and no drain");

    var ceiling = model.drainCeilingPerHour();
    if (ceiling == null) {
        Test.assertMessage(false, "twenty-two steady minutes is long enough to bound it");
        return false;
    }
    logger.debug("22 min steady at 80% bounds drain under " + ceiling.format("%.2f") + "%/h");
    // One whole percent has not been lost in 1314s, so drain is under
    // 1 * 3600 / 1314 = 2.74 %/h.
    Test.assertMessage((ceiling - 2.74).abs() < 0.1, "the bound is one step over the time held");
    Test.assertMessage(model.secondsAtBatteryLevel() >= 1300, "and it has been held that long");
    return true;
}

(:test)
function testCeilingTightensAndIsWithheldWhenUseless(logger as Logger) as Boolean {
    // One minute only proves drain is under 60%/h, which is worth nothing.
    var brief = new SolarModel(1);
    for (var i = 0; i < 60; i++) {
        brief.addSample(50, 90.0, false);
    }
    Test.assertMessage(brief.drainCeilingPerHour() == null,
        "a bound too loose to mean anything is withheld rather than shown");

    // The longer nothing happens, the tighter the true statement becomes.
    var short = new SolarModel(1);
    for (var i = 0; i < 600; i++) {
        short.addSample(50, 90.0, false);
    }
    var longer = new SolarModel(1);
    for (var i = 0; i < 3600; i++) {
        longer.addSample(50, 90.0, false);
    }
    var a = short.drainCeilingPerHour();
    var b = longer.drainCeilingPerHour();
    if (a == null || b == null) {
        Test.assertMessage(false, "both windows are long enough to bound");
        return false;
    }
    logger.debug("10 min bounds <" + a.format("%.2f") + ", 60 min bounds <" + b.format("%.2f"));
    Test.assertMessage(b < a, "an hour of no movement is a tighter ceiling than ten minutes");
    Test.assertMessage((b - 1.0).abs() < 0.05, "an hour without a single step is under 1%/h");
    return true;
}

(:test)
function testMeasuredRateAlwaysBeatsTheCeiling(logger as Logger) as Boolean {
    // Once the level actually moves enough to measure, the measurement is the
    // answer and the bound must not be what the wearer sees.
    var model = new SolarModel(1);
    var level = 87.0;
    for (var i = 0; i < 5000; i++) {
        if (i > 0 && i % 900 == 0) {
            level -= 1.0;
        }
        model.addSample(0, level, false);
    }
    var measured = model.drainPerHour();
    if (measured == null) {
        Test.assertMessage(false, "five whole steps is a measurement");
        return false;
    }
    logger.debug("measured " + measured.format("%.2f") + "%/h");
    Test.assertMessage((measured - 4.0).abs() < 0.15, "four percent an hour, measured");

    // The ceiling only describes the stretch since the last step, so it is a
    // looser statement than the measurement and must never displace it.
    Test.assertMessage(model.secondsAtBatteryLevel() < 1000,
        "the held-at-level window resets each time the level steps");
    return true;
}

(:test)
function testChargingHasNoCeiling(logger as Logger) as Boolean {
    // A level that is not dropping because the watch is on a charger says
    // nothing about drain, so no bound is claimed from it.
    var model = new SolarModel(1);
    for (var i = 0; i < 1200; i++) {
        model.addSample(0, 50.0, true);
    }
    Test.assertMessage(model.drainCeilingPerHour() == null,
        "a charging watch holding its level bounds nothing");
    return true;
}
