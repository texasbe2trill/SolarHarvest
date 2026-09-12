import Toybox.Lang;

// Rolling solar + battery analytics for one activity.
// Pure data (no Dc, no API calls) so every number here is unit tested.
class SolarModel {

    static const HISTORY_SIZE = 48;
    static const BATTERY_HISTORY_SIZE = 40;
    static const ZONE_COUNT = 4;

    // Zone lower bounds in percent: dark, low, moderate, high.
    static const ZONE_DARK = 15;
    static const ZONE_MODERATE = 40;
    static const ZONE_HIGH = 70;

    // Battery trace resolution.
    static const BATTERY_PERIOD = 60;

    // The raw sensor swings ~13 percentage points a second on a real wrist, so a
    // displayed number taken straight from it is unreadable. Smoothing at
    // 1/SMOOTH_DIVISOR per second (about a 10s time constant) removes ~84% of
    // that flicker while staying responsive. Energy totals stay on the raw
    // signal, so smoothing never changes the harvest integral.
    static const SMOOTH_DIVISOR = 10;

    private var _samplePeriod as Number = 5;
    private var _smooth as Float = 0.0;

    private var _history as Array<Number>;
    private var _head as Number = 0;
    private var _count as Number = 0;
    private var _bucketSum as Number = 0;
    private var _bucketTicks as Number = 0;

    private var _current as Number = 0;
    private var _peak as Number = 0;
    private var _sessionSum as Float = 0.0;
    private var _ticks as Number = 0;
    private var _harvestSeconds as Float = 0.0;
    private var _lapHarvestSeconds as Float = 0.0;
    private var _lapSum as Float = 0.0;
    private var _lapTicks as Number = 0;
    private var _zoneTicks as Array<Number>;

    private var _slope as Float = 0.0;
    private var _slopeStale as Boolean = true;

    private var _batHistory as Array<Number>;
    private var _batHead as Number = 0;
    private var _batCount as Number = 0;
    private var _batBucket as Number = 0;
    private var _battery as BatteryModel;

    // What previous activities taught this watch about itself. The solar benefit
    // needs hours of varied sunlight to fit, so on any normal ride it is still
    // converging when the activity ends and the wearer never sees it. Carrying
    // the fitted values forward means the number is available from the first
    // minute of the next one - still measured on this watch, just not today.
    private var _learnedSaving as Float = -1.0;
    private var _learnedDrain as Float = -1.0;

    function initialize(samplePeriod as Number) {
        _samplePeriod = (samplePeriod < 1) ? 1 : samplePeriod;
        _history = new [HISTORY_SIZE] as Array<Number>;
        _batHistory = new [BATTERY_HISTORY_SIZE] as Array<Number>;
        _zoneTicks = new [ZONE_COUNT] as Array<Number>;
        _battery = new BatteryModel();
        reset();
    }

    function reset() as Void {
        for (var i = 0; i < HISTORY_SIZE; i++) {
            _history[i] = 0;
        }
        for (var i = 0; i < BATTERY_HISTORY_SIZE; i++) {
            _batHistory[i] = 0;
        }
        for (var z = 0; z < ZONE_COUNT; z++) {
            _zoneTicks[z] = 0;
        }
        _head = 0;
        _count = 0;
        _bucketSum = 0;
        _bucketTicks = 0;
        _current = 0;
        _peak = 0;
        _sessionSum = 0.0;
        _ticks = 0;
        _harvestSeconds = 0.0;
        _lapHarvestSeconds = 0.0;
        _lapSum = 0.0;
        _lapTicks = 0;
        _slope = 0.0;
        _slopeStale = true;
        _smooth = 0.0;
        _batHead = 0;
        _batCount = 0;
        _batBucket = 0;
        _battery.reset();
    }

    // One reading per second. Pass battery < 0 when the level is unknown.
    function addSample(intensity as Number, battery as Float, charging as Boolean) as Void {
        var v = clamp(intensity);
        _current = v;
        if (_ticks <= 0) {
            _smooth = v.toFloat();
        } else {
            _smooth += (v - _smooth) / SMOOTH_DIVISOR;
        }
        _ticks += 1;
        if (v > _peak) {
            _peak = v;
        }
        _sessionSum += v;
        _harvestSeconds += v / 100.0;
        _lapHarvestSeconds += v / 100.0;
        _lapSum += v;
        _lapTicks += 1;
        _zoneTicks[zoneOf(v)] += 1;

        _bucketSum += v;
        _bucketTicks += 1;
        if (_bucketTicks >= _samplePeriod || _count == 0) {
            push(_bucketSum / _bucketTicks);
            _bucketSum = 0;
            _bucketTicks = 0;
        }

        updateBattery(v, battery, charging);
    }

    function noteLap() as Void {
        _lapHarvestSeconds = 0.0;
        _lapSum = 0.0;
        _lapTicks = 0;
    }

    // -- solar readings ---------------------------------------------------

    function current() as Number { return _current; }

    // The stable reading meant for the screen and for FIT. Raw stays available
    // for peaks and for the energy integral.
    function smoothed() as Number { return (_smooth + 0.5).toNumber(); }

    function peak() as Number { return _peak; }
    function count() as Number { return _count; }
    function ticks() as Number { return _ticks; }
    function harvestSeconds() as Number { return _harvestSeconds.toNumber(); }
    function lapHarvestSeconds() as Number { return _lapHarvestSeconds.toNumber(); }

    function lapAverage() as Number {
        if (_lapTicks <= 0) {
            return 0;
        }
        return ((_lapSum / _lapTicks) + 0.5).toNumber();
    }

    function average() as Number {
        if (_ticks <= 0) {
            return 0;
        }
        return ((_sessionSum / _ticks) + 0.5).toNumber();
    }

    // index 0 is the oldest retained sample.
    function sampleAt(index as Number) as Number {
        if (index < 0 || index >= _count) {
            return 0;
        }
        var start = ((_head - _count) + HISTORY_SIZE) % HISTORY_SIZE;
        return _history[(start + index) % HISTORY_SIZE];
    }

    // Least-squares slope in percentage points per minute, cached per bucket.
    function slopePerMinute() as Float {
        if (_slopeStale) {
            _slope = computeSlope() * (60.0 / _samplePeriod);
            _slopeStale = false;
        }
        return _slope;
    }

    function zoneOf(intensity as Number) as Number {
        var v = clamp(intensity);
        if (v >= ZONE_HIGH) {
            return 3;
        } else if (v >= ZONE_MODERATE) {
            return 2;
        } else if (v >= ZONE_DARK) {
            return 1;
        }
        return 0;
    }

    function zoneFraction(zone as Number) as Float {
        if (_ticks <= 0 || zone < 0 || zone >= ZONE_COUNT) {
            return 0.0;
        }
        return _zoneTicks[zone].toFloat() / _ticks;
    }

    function sunFraction() as Float {
        return 1.0 - zoneFraction(0);
    }

    // Full-sun-equivalent seconds still to come if the current intensity holds.
    // Projected from the smoothed reading: a single raw sample is far too noisy
    // to extrapolate over the rest of the daylight window.
    function projectedHarvestSeconds(secondsRemaining as Number) as Number {
        if (secondsRemaining <= 0) {
            return 0;
        }
        return ((secondsRemaining * smoothed()) / 100.0).toNumber();
    }

    // Marketing-independent estimate: user supplies minutes of runtime per full-sun hour.
    function batteryMinutes(minutesPerFullSunHour as Number) as Number {
        return ((_harvestSeconds / 3600.0) * minutesPerFullSunHour).toNumber();
    }

    // Seed the fitted values measured on previous activities.
    function setLearned(savingPerHour as Float, drainPerHour as Float) as Void {
        _learnedSaving = savingPerHour;
        _learnedDrain = drainPerHour;
    }

    // The benefit coefficient in use, and whether it came from this activity.
    function effectiveSaving() as Float? {
        var fresh = solarOffsetPerHour();
        if (fresh != null) {
            return fresh;
        }
        return (_learnedSaving > 0.0) ? _learnedSaving : null;
    }

    function effectiveDrain() as Float? {
        var fresh = drainPerHour();
        if (fresh != null) {
            return fresh;
        }
        return (_learnedDrain > 0.0) ? _learnedDrain : null;
    }

    // True when the bonus rests on values carried over rather than measured here.
    function bonusIsLearned() as Boolean {
        return solarOffsetPerHour() == null || drainPerHour() == null;
    }

    // Runtime the sun has actually bought, in minutes.
    //
    // This is the number a solar watch owner wants, and every stock version of it
    // is a marketing constant multiplied by daylight. This one is measured: the
    // fitted saving at full sun, scaled by the sunlight this activity really got,
    // divided by this watch's own measured drain. Null unless both the fit and
    // the drain rate have earned the right to be quoted, which on a short or
    // uniformly lit activity means it simply does not appear.
    function solarBonusMinutes() as Number? {
        var saving = effectiveSaving();
        var drain = effectiveDrain();
        if (saving == null || drain == null || drain <= 0.0 || _ticks <= 0) {
            return null;
        }
        // Percent of charge the sun put back over the activity so far.
        var hours = _ticks / 3600.0;
        var savedPercent = saving * (average() / 100.0) * hours;
        var minutes = ((savedPercent / drain) * 60.0).toNumber();
        return (minutes > 0) ? minutes : null;
    }

    // -- battery ----------------------------------------------------------

    function batteryPercent() as Float { return _battery.level(); }
    function batteryCount() as Number { return _batCount; }
    function batteryUsedPercent() as Float { return _battery.usedPercent(); }
    function batteryConfidence() as Number { return _battery.confidence(); }
    function batteryEdges() as Number { return _battery.edges(); }

    // Signed: positive is draining, negative is gaining charge in the sun.
    function netFlowPerHour() as Float? { return _battery.netFlowPerHour(); }

    // Same number, available sooner and shown with a "~" prefix.
    function provisionalNetFlowPerHour() as Float? {
        return _battery.provisionalNetFlowPerHour();
    }

    // Upper bound on drain while the level has not moved at all. Not a
    // measurement - see BatteryModel.drainCeilingPerHour.
    function drainCeilingPerHour() as Float? {
        return _battery.drainCeilingPerHour();
    }

    function secondsAtBatteryLevel() as Number {
        return _battery.secondsAtCurrentLevel();
    }

    function batteryAt(index as Number) as Float {
        if (index < 0 || index >= _batCount) {
            return 0.0;
        }
        var start = ((_batHead - _batCount) + BATTERY_HISTORY_SIZE) % BATTERY_HISTORY_SIZE;
        return _batHistory[(start + index) % BATTERY_HISTORY_SIZE] / 10.0;
    }

    // Measured drain in percent per hour, or null while the sample is too thin to
    // trust. Never reports drain while the watch is actually gaining charge.
    function drainPerHour() as Float? {
        return _battery.drainPerHour();
    }

    // Early, lower-confidence read of the same number.
    function provisionalDrainPerHour() as Float? {
        var flow = _battery.provisionalNetFlowPerHour();
        if (flow == null || flow <= 0.0) {
            return null;
        }
        return flow;
    }

    // Percentage points per hour of drain avoided at full sun, fitted across the
    // activity rather than differenced between two noisy buckets. Null unless the
    // fit rests on enough intervals spanning enough sunlight.
    function solarOffsetPerHour() as Float? {
        return _battery.solarSavingPerHour();
    }

    // Drain this watch would show with no sun at all, from the same fit.
    function baseDrainPerHour() as Float? {
        return _battery.baseDrainPerHour();
    }

    // Hours of runtime left at the measured drain rate.
    function projectedHours() as Float? {
        return _battery.projectedHours();
    }

    // -- internals --------------------------------------------------------

    private function updateBattery(intensity as Number, battery as Float, charging as Boolean) as Void {
        if (battery < 0.0) {
            return;
        }
        var seeding = !_battery.hasLevel();
        _battery.addSample(intensity, battery, charging);
        if (seeding) {
            pushBattery(battery);
            return;
        }
        _batBucket += 1;
        if (_batBucket >= BATTERY_PERIOD) {
            pushBattery(battery);
            _batBucket = 0;
        }
    }

    private function pushBattery(battery as Float) as Void {
        _batHistory[_batHead] = (battery * 10).toNumber();
        _batHead = (_batHead + 1) % BATTERY_HISTORY_SIZE;
        if (_batCount < BATTERY_HISTORY_SIZE) {
            _batCount += 1;
        }
    }

    private function computeSlope() as Float {
        var n = _count;
        if (n < 3) {
            return 0.0;
        }
        var sumX = 0.0;
        var sumY = 0.0;
        var sumXY = 0.0;
        var sumXX = 0.0;
        for (var i = 0; i < n; i++) {
            var y = sampleAt(i).toFloat();
            sumX += i;
            sumY += y;
            sumXY += i * y;
            sumXX += i * i;
        }
        var denom = (n * sumXX) - (sumX * sumX);
        if (denom == 0.0) {
            return 0.0;
        }
        return ((n * sumXY) - (sumX * sumY)) / denom;
    }

    private function push(value as Number) as Void {
        _history[_head] = value;
        _head = (_head + 1) % HISTORY_SIZE;
        if (_count < HISTORY_SIZE) {
            _count += 1;
        }
        _slopeStale = true;
    }

    private function clamp(value as Number) as Number {
        if (value < 0) {
            return 0;
        } else if (value > 100) {
            return 100;
        }
        return value;
    }
}

// m:ss under an hour, h:mm above it.
function formatClock(seconds as Number) as String {    var total = (seconds < 0) ? 0 : seconds;
    var hours = total / 3600;
    var minutes = (total % 3600) / 60;
    if (hours > 0) {
        return hours.format("%d") + ":" + minutes.format("%02d");
    }
    return minutes.format("%d") + ":" + (total % 60).format("%02d");
}

function formatMinutes(seconds as Number) as String {
    var total = (seconds < 0) ? 0 : seconds;
    if (total >= 3600) {
        return (total / 3600).format("%d") + "h" + ((total % 3600) / 60).format("%02d");
    }
    return (total / 60).format("%d") + "m";
}

function formatSigned(value as Float) as String {
    var text = value.abs().format("%.1f");
    if (value > 0.05) {
        return "+" + text;
    } else if (value < -0.05) {
        return "-" + text;
    }
    return "0.0";
}

// Battery flow for the screen. The model counts drain as positive, but a user
// reads a falling battery as a minus and a solar surplus as a plus, so the sign
// is flipped here rather than anywhere a calculation could pick it up.
function formatFlow(flowPerHour as Float) as String {
    var text = flowPerHour.abs().format("%.1f");
    if (flowPerHour > 0.05) {
        return "-" + text;
    } else if (flowPerHour < -0.05) {
        return "+" + text;
    }
    return "0.0";
}

// Garmin's own runtime estimate converted to percent per hour.
function drainFromDays(days as Float) as Float? {
    if (days <= 0.0) {
        return null;
    }
    return 100.0 / (days * 24.0);
}
