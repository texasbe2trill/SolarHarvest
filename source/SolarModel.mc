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
    // Whether _smooth holds a real reading yet. Separate from _ticks, which
    // only counts samples taken while the timer was actually running.
    private var _primed as Boolean = false;

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

    // What earlier activities taught this watch about itself, as
    // [dof, cxx, cxy, minLight, maxLight, drainHours, drainPercent, cyy] - see
    // BatteryModel.calibrationContribution(). The solar benefit needs a lot of
    // varied sunlight to fit, far more than one ordinary activity holds, so the
    // evidence is carried forward and added to. reset() leaves this alone: it
    // belongs to the watch, not to any one activity.
    static const CAL_SIZE = 8;
    // Records written before cyy was kept have seven values; their scatter is
    // taken as that of an average fit (half the drain's variation explained
    // by the light), which lets the early rule weigh them without trusting
    // them more than they earned.
    static const CAL_LEGACY_SIZE = 7;
    // Older evidence is scaled back once this many degrees of freedom have
    // accumulated, roughly the last 120 battery-step gaps, so the coefficient
    // follows the watch as its battery ages instead of being anchored to its
    // first weeks.
    static const CAL_MAX_DOF = 120.0;
    // The learned drain follows the most recent measured hours the same way.
    static const CAL_MAX_DRAIN_HOURS = 20.0;
    // A learned drain from less measured time than this is one quantised step
    // of evidence, too coarse to turn saved charge into minutes.
    static const CAL_MIN_DRAIN_HOURS = 1.0;

    private var _calDof as Float = 0.0;
    private var _calCxx as Float = 0.0;
    private var _calCxy as Float = 0.0;
    private var _calMinX as Float = 1000.0;
    private var _calMaxX as Float = -1000.0;
    private var _calDrainHours as Float = 0.0;
    private var _calDrainPercent as Float = 0.0;
    private var _calCyy as Float = 0.0;

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
        _primed = false;
        _batHead = 0;
        _batCount = 0;
        _batBucket = 0;
        _battery.reset();
    }

    // One reading per second. Pass battery < 0 when the level is unknown.
    function addSample(intensity as Number, battery as Float, charging as Boolean) as Void {
        addSampleWhen(intensity, battery, charging, true);
    }

    // `recording` is false before the timer starts and while it is paused.
    //
    // compute() runs about once a second the whole time the field is on screen,
    // which includes the wait for a GPS lock and every pause, but the FIT only
    // gets records while the timer runs. Accumulating in those gaps put samples
    // into the session summary that the chart beside it could never show: a
    // "time in sun" that counted a minute spent indoors before the start, and an
    // average pulled toward whatever the watch happened to see while it sat on a
    // cafe table. The live reading still updates, because a paused field showing
    // a frozen number looks broken.
    function addSampleWhen(intensity as Number, battery as Float, charging as Boolean,
                           recording as Boolean) as Void {
        var v = clamp(intensity);
        _current = v;
        if (!_primed) {
            _smooth = v.toFloat();
            _primed = true;
        } else {
            _smooth += (v - _smooth) / SMOOTH_DIVISOR;
        }
        if (!recording) {
            // Still let the battery see it, so the level on the page is the
            // watch's real level rather than the last one before the pause.
            updateBattery(v, battery, charging, false);
            return;
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

        updateBattery(v, battery, charging, true);
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

    // -- calibration carried between activities ---------------------------

    static function emptyCalibration() as Array<Float> {
        return [0.0, 0.0, 0.0, 1000.0, -1000.0, 0.0, 0.0, 0.0] as Array<Float>;
    }

    // The scatter a record carries, or the average-fit assumption for one
    // written before it was kept.
    static function cyyOf(c as Array<Float>) as Float {
        if (c.size() > CAL_LEGACY_SIZE) {
            return c[7];
        }
        return (c[1] > 0.000001) ? (2.0 * c[2] * c[2]) / c[1] : 0.0;
    }

    function setCalibration(c as Array<Float>) as Void {
        _calDof = c[0];
        _calCxx = c[1];
        _calCxy = c[2];
        _calMinX = c[3];
        _calMaxX = c[4];
        _calDrainHours = c[5];
        _calDrainPercent = c[6];
        _calCyy = cyyOf(c);
    }

    function calibration() as Array<Float> {
        return [_calDof, _calCxx, _calCxy, _calMinX, _calMaxX,
                _calDrainHours, _calDrainPercent, _calCyy] as Array<Float>;
    }

    // What this activity would add if it ended now.
    function activityCalibration() as Array<Float> {
        return _battery.calibrationContribution();
    }

    // Folds one activity's contribution into the carried calibration.
    //
    // Sums add, which is what makes the pooled fit exact rather than an average
    // of per-activity fits. Past the caps the older evidence is scaled back
    // first, so a new activity always counts in full; scaling co-deviations and
    // degrees of freedom together leaves the older evidence's own slope intact.
    static function mergeCalibration(prior as Array<Float>, add as Array<Float>) as Array<Float> {
        var out = emptyCalibration();
        var keep = 1.0;
        if (prior[0] > 0.0 && (prior[0] + add[0]) > CAL_MAX_DOF) {
            keep = (CAL_MAX_DOF - add[0]) / prior[0];
            if (keep < 0.0) {
                keep = 0.0;
            }
        }
        out[0] = (prior[0] * keep) + add[0];
        out[1] = (prior[1] * keep) + add[1];
        out[2] = (prior[2] * keep) + add[2];
        out[7] = (cyyOf(prior) * keep) + cyyOf(add);
        if (keep > 0.0) {
            out[3] = (prior[3] < add[3]) ? prior[3] : add[3];
            out[4] = (prior[4] > add[4]) ? prior[4] : add[4];
        } else {
            out[3] = add[3];
            out[4] = add[4];
        }

        var keepDrain = 1.0;
        if (prior[5] > 0.0 && (prior[5] + add[5]) > CAL_MAX_DRAIN_HOURS) {
            keepDrain = (CAL_MAX_DRAIN_HOURS - add[5]) / prior[5];
            if (keepDrain < 0.0) {
                keepDrain = 0.0;
            }
        }
        out[5] = (prior[5] * keepDrain) + add[5];
        out[6] = (prior[6] * keepDrain) + add[6];
        return out;
    }

    // A stored calibration read back, or null if it is not one. Storage is the
    // only way anything outside this activity reaches the model, so it is
    // checked as untrusted input rather than assumed well formed.
    static function calibrationFrom(values as Array, offset as Number) as Array<Float>? {
        var size = (values.size() >= offset + CAL_SIZE) ? CAL_SIZE : CAL_LEGACY_SIZE;
        if (values.size() < offset + size) {
            return null;
        }
        var c = emptyCalibration();
        for (var i = 0; i < size; i++) {
            var v = values[offset + i];
            if (!(v instanceof Lang.Float || v instanceof Lang.Number || v instanceof Lang.Double)) {
                return null;
            }
            c[i] = (v as Numeric).toFloat();
        }
        if (c[0] < 0.0 || c[1] < 0.0 || c[5] < 0.0 || c[7] < 0.0) {
            return null;
        }
        if (size == CAL_LEGACY_SIZE) {
            c[7] = (c[1] > 0.000001) ? (2.0 * c[2] * c[2]) / c[1] : 0.0;
        }
        return c;
    }

    // A Sun Bonus saved by the first release, which kept only the fitted saving.
    //
    // That release only ever saved one from an activity that passed the
    // single-activity rules, so the least evidence that could have produced it
    // is known exactly: eleven degrees of freedom and the minimum light
    // variation. Carried forward at that weight it keeps the number the user
    // already had, and anything measured afterwards outweighs it rather than
    // being outweighed. The light range was not kept; any 25 point span passes
    // the one gate the range is used for, just as the original did. Its drain
    // is not carried at all, because the hours behind it were never recorded.
    static function calibrationFromLegacy(saving as Float) as Array<Float>? {
        if (!(saving > 0.05)) {
            return null;
        }
        var c = emptyCalibration();
        c[0] = (BatteryModel.REG_MIN_INTERVALS - 1).toFloat();
        c[1] = BatteryModel.REG_MIN_VARIATION;
        c[2] = -(saving / 100.0) * BatteryModel.REG_MIN_VARIATION;
        c[3] = 0.0;
        c[4] = BatteryModel.REG_MIN_SPREAD;
        c[7] = (2.0 * c[2] * c[2]) / c[1];
        return c;
    }

    // The saving at full sun that the page quotes: this activity's own fit if
    // it has one, otherwise the fit across this activity and the earlier ones.
    function effectiveSaving() as Float? {
        var fresh = solarOffsetPerHour();
        if (fresh != null) {
            return fresh;
        }
        return pooledSavingPerHour();
    }

    function pooledSavingPerHour() as Float? {
        return _battery.pooledSavingPerHour(_calDof, _calCxx, _calCxy, _calMinX, _calMaxX, _calCyy);
    }

    function effectiveDrain() as Float? {
        var fresh = drainPerHour();
        if (fresh != null) {
            return fresh;
        }
        return learnedDrainPerHour();
    }

    // Total net percent over total measured hours across earlier activities.
    function learnedDrainPerHour() as Float? {
        if (_calDrainHours < CAL_MIN_DRAIN_HOURS) {
            return null;
        }
        var drain = _calDrainPercent / _calDrainHours;
        return (drain > 0.0) ? drain : null;
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
    function batteryRegressionSamples() as Number { return _battery.regressionSamples(); }

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

    private function updateBattery(intensity as Number, battery as Float, charging as Boolean,
                                   recording as Boolean) as Void {
        if (battery < 0.0) {
            return;
        }
        // Seed on the first sample that reaches the trace, not the first the
        // watch reports: the level is read before the timer starts, so
        // hasLevel() is already true by the time recording begins.
        var seeding = (_batCount == 0);
        _battery.addSampleWhen(intensity, battery, charging, recording);
        if (!recording) {
            // The level is live for the page to read; the trace behind it is
            // this activity's own history and stays where the timer left it.
            return;
        }
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
