import Toybox.Lang;

// Battery behaviour measured from the watch's own reported level.
//
// The reported level is quantised (typically whole percent) and it dithers
// across the quantisation boundary. Accumulating every downward tick therefore
// reports the *gross* downward movement, not the net drain, and on a solar watch
// - where the level genuinely rises in the sun - it can overstate the rate by
// two orders of magnitude.
//
// Instead this measures edge to edge. A reported change only counts once it has
// held for DEBOUNCE seconds (which rejects boundary dither), and the rate is the
// net level change between the first and last accepted transition. Both ends of
// that window sit exactly on a quantisation boundary, so no partial step is
// counted at either end and the measurement is unbiased.
//
// Everything here is pure arithmetic so it can be unit tested off-device.
class BatteryModel {

    // Evidence a candidate level needs before it counts as a real transition.
    // The counter rises while the reading sits at least one step away from the
    // settled level and falls back when it returns, so a reading that merely
    // flickers across the boundary never accumulates enough to be accepted,
    // while a genuine move survives being interrupted by that flicker.
    static const DEBOUNCE = 10;
    // Two accepted transitions bound exactly one whole step of decline.
    static const MIN_EDGES = 2;
    static const CONFIDENT_EDGES = 4;
    // Time gates, so a rate is never quoted from a sliver of activity.
    static const MIN_SECONDS = 600;
    static const PROVISIONAL_SECONDS = 240;
    // The two bounding transitions must also be far enough apart, otherwise a
    // single step spanning a few seconds would extrapolate to a wild rate.
    static const MIN_SPAN_SECONDS = 300;
    // Below this the "has not dropped yet" ceiling is too loose to be worth
    // showing - at 60s it only proves the drain is under 60%/h.
    static const CEILING_MIN_SECONDS = 300;
    // Solar regression needs enough intervals and enough spread in sunlight
    // before the fitted coefficient means anything.
    static const REG_MIN_INTERVALS = 12;
    static const REG_MIN_SPREAD = 25.0;
    // Fallback quantum before the reporting resolution has been observed.
    static const DEFAULT_QUANTUM = 0.05;

    // Confidence in the reported rate.
    static const CONF_NONE = 0;
    static const CONF_PROVISIONAL = 1;
    static const CONF_MEASURED = 2;
    static const CONF_CONFIDENT = 3;

    private var _level as Float = -1.0;
    private var _start as Float = -1.0;
    private var _prev as Float = -1.0;
    private var _quantum as Float = -1.0;
    private var _activeSeconds as Number = 0;
    private var _charging as Boolean = false;

    // Debounce run state.
    private var _stable as Float = -1.0;
    private var _runStartT as Number = 0;
    private var _runStartLevel as Float = 0.0;
    private var _runDir as Number = 0;
    private var _runLength as Number = 0;

    // Accepted transitions.
    private var _firstT as Number = -1;
    private var _firstLevel as Float = 0.0;
    private var _lastT as Number = -1;
    private var _lastLevel as Float = 0.0;
    private var _edges as Number = 0;
    private var _prevEdgeT as Number = -1;
    private var _prevEdgeLevel as Float = 0.0;

    // Incremental least squares of interval drain rate against mean sunlight.
    // Only running sums are kept, so memory does not grow with activity length.
    private var _n as Number = 0;
    private var _sumX as Float = 0.0;
    private var _sumY as Float = 0.0;
    private var _sumXY as Float = 0.0;
    private var _sumXX as Float = 0.0;
    private var _minX as Float = 0.0;
    private var _maxX as Float = 0.0;
    private var _solSum as Float = 0.0;
    private var _solTicks as Number = 0;

    function initialize() {
        reset();
    }

    function reset() as Void {
        _level = -1.0;
        _start = -1.0;
        _prev = -1.0;
        _quantum = -1.0;
        _activeSeconds = 0;
        _charging = false;
        _stable = -1.0;
        _runStartT = 0;
        _runStartLevel = 0.0;
        _runDir = 0;
        _runLength = 0;
        _firstT = -1;
        _firstLevel = 0.0;
        _lastT = -1;
        _lastLevel = 0.0;
        _edges = 0;
        _prevEdgeT = -1;
        _prevEdgeLevel = 0.0;
        _n = 0;
        _sumX = 0.0;
        _sumY = 0.0;
        _sumXY = 0.0;
        _sumXX = 0.0;
        _minX = 0.0;
        _maxX = 0.0;
        _solSum = 0.0;
        _solTicks = 0;
    }

    // One reading per second. Pass battery < 0 when the level is unknown.
    function addSample(intensity as Number, battery as Float, charging as Boolean) as Void {
        addSampleWhen(intensity, battery, charging, true);
    }

    // `recording` is false before the timer starts and while it is paused.
    //
    // The level itself still tracks the watch in that state, so the battery page
    // reads correctly the moment the field is on screen. Nothing that measures
    // this activity does: a rate fitted across a twenty minute cafe stop is not
    // this activity's drain rate, and the seconds spent waiting for a GPS lock
    // are not seconds this activity spent in the sun.
    function addSampleWhen(intensity as Number, battery as Float, charging as Boolean,
                           recording as Boolean) as Void {
        if (battery < 0.0) {
            return;
        }
        _charging = charging;
        _level = battery;
        if (!recording) {
            return;
        }

        if (_start < 0.0) {
            _start = battery;
            _prev = battery;
            _stable = battery;
            return;
        }

        // The smallest change ever reported is the device's reporting resolution.
        var step = (battery - _prev).abs();
        if (step > 0.0 && (_quantum < 0.0 || step < _quantum)) {
            _quantum = step;
        }
        _prev = battery;

        if (charging) {
            // Charging is a different regime; abandon any run in progress rather
            // than letting it straddle the boundary.
            _runLength = 0;
            _stable = battery;
            return;
        }

        _activeSeconds += 1;
        _solSum += intensity;
        _solTicks += 1;

        var quantum = (_quantum > 0.0) ? _quantum : DEFAULT_QUANTUM;
        var diff = battery - _stable;
        if (diff.abs() < quantum) {
            if (_runLength > 0) {
                _runLength -= 1;
            }
            return;
        }

        var dir = (diff > 0.0) ? 1 : -1;
        if (_runLength == 0 || dir != _runDir) {
            _runDir = dir;
            _runLength = 1;
            _runStartT = _activeSeconds;
            _runStartLevel = battery;
        } else {
            _runLength += 1;
        }
        if (_runLength < DEBOUNCE) {
            return;
        }

        acceptEdge(_runStartT, _runStartLevel);
    }

    // A transition is dated to when the new level was first seen, not when the
    // debounce completed, so the measured interval is not stretched.
    private function acceptEdge(t as Number, level as Float) as Void {
        _stable = level;
        _runLength = 0;

        if (_firstT < 0) {
            _firstT = t;
            _firstLevel = level;
        } else if (t > _prevEdgeT) {
            var duration = t - _prevEdgeT;
            var y = ((_prevEdgeLevel - level) * 3600.0) / duration;
            var x = (_solTicks > 0) ? (_solSum / _solTicks) : 0.0;
            if (_n == 0) {
                _minX = x;
                _maxX = x;
            } else if (x < _minX) {
                _minX = x;
            } else if (x > _maxX) {
                _maxX = x;
            }
            _n += 1;
            _sumX += x;
            _sumY += y;
            _sumXY += x * y;
            _sumXX += x * x;
        }

        _lastT = t;
        _lastLevel = level;
        _edges += 1;
        _prevEdgeT = t;
        _prevEdgeLevel = level;
        _solSum = 0.0;
        _solTicks = 0;
    }

    // -- readings ---------------------------------------------------------

    function level() as Float { return _level; }
    function hasLevel() as Boolean { return _level >= 0.0; }
    function charging() as Boolean { return _charging; }
    function edges() as Number { return _edges; }
    function activeSeconds() as Number { return _activeSeconds; }
    function regressionSamples() as Number { return _n; }

    // Net percent consumed since the field started. Negative means the watch
    // finished the activity with more charge than it began with.
    function usedPercent() as Float {
        if (_start < 0.0 || _level < 0.0) {
            return 0.0;
        }
        return _start - _level;
    }

    // Signed rate in percent per hour: positive is draining, negative is gaining.
    // Null until there is enough evidence to be worth showing.
    function netFlowPerHour() as Float? {
        if (_edges < MIN_EDGES || _activeSeconds < MIN_SECONDS
            || (_lastT - _firstT) < MIN_SPAN_SECONDS) {
            return null;
        }
        return ((_firstLevel - _lastLevel) * 3600.0) / (_lastT - _firstT);
    }

    // Earlier, lower confidence read of the same number.
    function provisionalNetFlowPerHour() as Float? {
        if (_activeSeconds < PROVISIONAL_SECONDS || _start < 0.0) {
            return null;
        }
        if (_edges >= MIN_EDGES && (_lastT - _firstT) >= MIN_SPAN_SECONDS) {
            return ((_firstLevel - _lastLevel) * 3600.0) / (_lastT - _firstT);
        }
        var net = _start - _level;
        if (net.abs() < 0.0001) {
            return null;
        }
        return (net * 3600.0) / _activeSeconds;
    }

    function confidence() as Number {
        if (netFlowPerHour() != null) {
            return (_edges >= CONFIDENT_EDGES) ? CONF_CONFIDENT : CONF_MEASURED;
        }
        return (provisionalNetFlowPerHour() != null) ? CONF_PROVISIONAL : CONF_NONE;
    }

    // The tightest drain figure that can be stated when the level has not moved
    // at all, as an upper bound rather than a measurement.
    //
    // A 20 minute activity on a big battery can easily pass without the reported
    // level ticking down even once, and the edge-to-edge measurement correctly
    // refuses to invent a rate from that. But "it has not dropped" is itself
    // information, and it bounds the answer: if the reported level has held for
    // T seconds, the true level has stayed inside that one step the whole time,
    // so the decline is under one quantum and the drain is under
    // quantum * 3600 / T. That is a real, defensible ceiling, it is available
    // long before a measurement is, and it tightens the longer nothing happens.
    //
    // Null until the window is long enough for the ceiling to say anything: at
    // one minute it only proves drain is under 60%/h, which is worthless.
    function drainCeilingPerHour() as Float? {
        if (_level < 0.0 || _charging) {
            return null;
        }
        var heldFor = secondsAtCurrentLevel();
        if (heldFor < CEILING_MIN_SECONDS) {
            return null;
        }
        // Whole percent unless the device has shown finer resolution.
        var quantum = (_quantum > 0.0) ? _quantum : 1.0;
        return (quantum * 3600.0) / heldFor;
    }

    // How long the reported level has sat where it is: since the last accepted
    // transition, or since the start if there has never been one.
    function secondsAtCurrentLevel() as Number {
        if (_edges > 0 && _lastT >= 0) {
            return _activeSeconds - _lastT;
        }
        return _activeSeconds;
    }

    // Drain only: null while gaining, unknown, or still short of evidence.
    function drainPerHour() as Float? {
        var flow = netFlowPerHour();
        if (flow == null || flow <= 0.0) {
            return null;
        }
        return flow;
    }

    // Hours of runtime left at the measured drain.
    function projectedHours() as Float? {
        var drain = drainPerHour();
        if (drain == null || _level < 0.0) {
            return null;
        }
        return _level / drain;
    }

    // Percentage points per hour of drain avoided at full sun, fitted across the
    // measured intervals rather than differenced between two noisy buckets.
    // Null unless the fit rests on enough intervals spanning enough sunlight.
    function solarSavingPerHour() as Float? {
        if (_n < REG_MIN_INTERVALS || (_maxX - _minX) < REG_MIN_SPREAD) {
            return null;
        }
        var denom = (_n * _sumXX) - (_sumX * _sumX);
        if (denom.abs() < 0.000001) {
            return null;
        }
        var slope = ((_n * _sumXY) - (_sumX * _sumY)) / denom;
        var saving = -slope * 100.0;
        return (saving > 0.05) ? saving : null;
    }

    // Drain the watch would show with no sun at all, from the same fit.
    function baseDrainPerHour() as Float? {
        if (solarSavingPerHour() == null) {
            return null;
        }
        var denom = (_n * _sumXX) - (_sumX * _sumX);
        var slope = ((_n * _sumXY) - (_sumX * _sumY)) / denom;
        return (_sumY - (slope * _sumX)) / _n;
    }
}
