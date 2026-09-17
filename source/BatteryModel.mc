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
    // The least light variation any activity meeting both rules above can
    // have: every interval but the two extremes sitting at the midpoint of a
    // 25 point spread. Evidence pooled across activities has to carry at least
    // this much, so it is never weaker than the weakest single activity the
    // rules already accept.
    static const REG_MIN_VARIATION = 312.5;
    // The early rule: fewer intervals when the fit itself is sure. The slope
    // has to stand at least REG_T of its own standard errors away from zero,
    // judged against the intervals' scatter about the fitted line, so a day
    // whose light varied and whose drain followed it can speak after five
    // intervals, and a day whose drain merely wandered cannot, however long.
    static const REG_EARLY_INTERVALS = 5;
    static const REG_EARLY_SPREAD = 20.0;
    static const REG_T = 3.0;
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

    // Incremental least squares of interval drain rate against mean sunlight,
    // kept as running means and co-deviations about them rather than raw sums.
    // Raw sums subtract two large, nearly equal numbers to recover the spread,
    // which a 32-bit float does badly; these hold the spread directly. They are
    // also exactly this activity's "within" sums, which is what pooling across
    // activities needs. Memory does not grow with activity length.
    private var _n as Number = 0;
    private var _meanX as Float = 0.0;
    private var _meanY as Float = 0.0;
    private var _cxx as Float = 0.0;
    private var _cxy as Float = 0.0;
    private var _cyy as Float = 0.0;
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
        _meanX = 0.0;
        _meanY = 0.0;
        _cxx = 0.0;
        _cxy = 0.0;
        _cyy = 0.0;
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
            var dx = x - _meanX;
            var dy = y - _meanY;
            _meanX += dx / _n;
            _meanY += dy / _n;
            _cxx += dx * (x - _meanX);
            _cxy += dx * (y - _meanY);
            _cyy += dy * (y - _meanY);
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
    // The same rules as pooledSavingPerHour() with no prior, written out
    // rather than delegated, and with as few locals as the arithmetic allows:
    // both are leaves under onUpdate, where the stack is shallow enough that
    // one more frame, or a fatter one, overflows it in the render tests.
    function solarSavingPerHour() as Float? {
        if (_n < 2 || _cxx < 0.000001) {
            return null;
        }
        var dof = (_n - 1).toFloat();
        var spread = _maxX - _minX;
        if (!(dof >= (REG_MIN_INTERVALS - 1) && spread >= REG_MIN_SPREAD)) {
            if (dof < (REG_EARLY_INTERVALS - 1) || spread < REG_EARLY_SPREAD) {
                return null;
            }
            // residual scatter about the fitted line, then the t test as
            // cxy^2 (dof - 1) >= T^2 residual cxx, which needs no square root
            spread = _cyy - ((_cxy * _cxy) / _cxx);
            if (spread < 0.0) {
                spread = 0.0;
            }
            if ((_cxy * _cxy) * (dof - 1.0) < (REG_T * REG_T) * spread * _cxx) {
                return null;
            }
        }
        dof = -(_cxy / _cxx) * 100.0;
        return (dof > 0.05) ? dof : null;
    }

    // Drain the watch would show with no sun at all, from the same fit.
    function baseDrainPerHour() as Float? {
        if (solarSavingPerHour() == null) {
            return null;
        }
        return _meanY - ((_cxy / _cxx) * _meanX);
    }

    // The same coefficient, fitted on this activity's intervals together with
    // everything earlier activities contributed (the prior arguments).
    //
    // Pooled as a fixed-effects fit: each activity's intervals are measured
    // against that activity's own means before they are combined. Baseline
    // drain differs between activities - GPS mode, backlight, heat - and a
    // plain pooled fit would read a sunny day that happened to use a hungrier
    // GPS mode as the sun costing battery. Only light that varied within one
    // activity can say what light is worth, so that is all this uses. The cost
    // is that an activity needs at least two intervals, three battery steps,
    // to contribute anything: one interval says nothing about the sun that is
    // not confounded with that activity's own drain.
    //
    // With no prior this is exactly solarSavingPerHour(), gates included.
    function pooledSavingPerHour(priorDof as Float, priorCxx as Float, priorCxy as Float,
                                 priorMinX as Float, priorMaxX as Float, priorCyy as Float) as Float? {
        var dof = priorDof;
        var cxx = priorCxx;
        var cxy = priorCxy;
        var cyy = priorCyy;
        var spread = priorMaxX - priorMinX;
        if (_n >= 2) {
            dof += _n - 1;
            cxx += _cxx;
            cxy += _cxy;
            cyy += _cyy;
            spread = ((_maxX > priorMaxX) ? _maxX : priorMaxX) - ((_minX < priorMinX) ? _minX : priorMinX);
        }
        if (cxx < 0.000001) {
            return null;
        }
        // Two ways in: the classic rule with the variation floor for pooled
        // evidence, or the early rule, the slope REG_T standard errors clear
        // of zero against the intervals' scatter. Written out with the fewest
        // locals: this runs under onUpdate, where the stack is shallow.
        if (!(dof >= (REG_MIN_INTERVALS - 1) && spread >= REG_MIN_SPREAD && cxx >= REG_MIN_VARIATION)) {
            if (dof < (REG_EARLY_INTERVALS - 1) || spread < REG_EARLY_SPREAD || cyy < 0.0) {
                return null;
            }
            cyy -= (cxy * cxy) / cxx;
            if (cyy < 0.0) {
                cyy = 0.0;
            }
            if ((cxy * cxy) * (dof - 1.0) < (REG_T * REG_T) * cyy * cxx) {
                return null;
            }
        }
        cxy = -(cxy / cxx) * 100.0;
        return (cxy > 0.05) ? cxy : null;
    }

    // What this activity can add to the cross-activity calibration, as
    // [dof, cxx, cxy, minLight, maxLight, drainHours, drainPercent, cyy].
    //
    // Drain is kept as the measured window's hours and net percent rather than
    // as a rate, so combining activities gives total percent over total hours,
    // weighting each by how long it was actually measured. Only a confirmed
    // drain counts, the same evidence rule the RATE figure uses.
    function calibrationContribution() as Array<Float> {
        var c = [0.0, 0.0, 0.0, 1000.0, -1000.0, 0.0, 0.0, 0.0] as Array<Float>;
        if (_n >= 2) {
            c[0] = (_n - 1).toFloat();
            c[1] = _cxx;
            c[2] = _cxy;
            c[3] = _minX;
            c[4] = _maxX;
            c[7] = _cyy;
        }
        if (drainPerHour() != null) {
            c[5] = (_lastT - _firstT) / 3600.0;
            c[6] = _firstLevel - _lastLevel;
        }
        return c;
    }
}
