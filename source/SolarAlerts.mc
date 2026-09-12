import Toybox.Lang;

// When the field should speak up.
//
// Everything else here is passive: six pages a user has to choose to look at.
// An alert is the opposite - it interrupts, and it spends the user's attention
// whether or not they wanted it spent. So the bar for firing one is high, and
// the engine is built around refusing far more often than it fires.
//
// Three rules hold the whole design together:
//
//   1. Say only what the user could act on, or what they would be glad to know.
//      "The sun is out" is neither; "you have half an hour of daylight left" is
//      the first and "the sun is now outrunning your battery drain" is the second.
//
//   2. Never fire on a transient. Every condition has to hold for minutes, not
//      seconds, or a data field turns into a stream of interruptions the moment a
//      user walks under a row of trees.
//
//   3. Never repeat inside a refractory window. A condition that stays true is
//      not new information.
module SolarAlerts {
    const KIND_NONE = 0;
    const KIND_GAIN = 1;     // solar is now outrunning drain
    const KIND_SHADE = 2;    // well below what this sun height allows, sustained
    const KIND_SUN = 3;      // back out in it, after a shade alert
    const KIND_SUNSET = 4;   // the daylight window is closing
    const KIND_COUNT = 5;

    // The sun has to be properly up before "you are in shade" means anything. At
    // low elevation a dim reading is the geometry, not an obstruction, and
    // telling a user to move at dusk is telling them to chase a sun that has
    // already gone.
    const SHADE_MIN_ELEVATION = 20.0;
    const SHADE_MAX_SKY = 30;        // percent of available light actually landing
    const SUN_MIN_SKY = 65;          // recovery has to be convincing, not marginal
    const SHADE_HOLD = 300;          // five minutes under cover before saying so
    const SUN_HOLD = 120;            // but only two back in it before the all-clear
    const SUNSET_LEAD = 1800;        // half an hour of warning

    // Long enough that a condition flickering on and off cannot produce a stream.
    const REFRACTORY = 1800;
    const GAIN_HOLD = 120;
}

class AlertEngine {
    private var _firedAt as Array<Number>;
    private var _shadeFor as Number = 0;
    private var _sunFor as Number = 0;
    private var _gainFor as Number = 0;
    private var _inShade as Boolean = false;

    function initialize() {
        // A literal rather than new [KIND_COUNT], which types as Array<Null>.
        // One slot per kind, indexed by it; -1 means never fired.
        _firedAt = [-1, -1, -1, -1, -1] as Array<Number>;
        reset();
    }

    function reset() as Void {
        for (var i = 0; i < SolarAlerts.KIND_COUNT; i++) {
            _firedAt[i] = -1;
        }
        _shadeFor = 0;
        _sunFor = 0;
        _gainFor = 0;
        _inShade = false;
    }

    // Returns the alert to raise this second, or KIND_NONE.
    //
    // `sky` is the share of the light the sun's height allows that is actually
    // landing, or null when there is no fix to judge it against. `flow` is the
    // measured battery flow in points per hour, negative when gaining, or null
    // while it is still being measured - an alert is never raised on a guess.
    function evaluate(ticks as Number, elevation as Float, sky as Number?,
                      flow as Float?, secondsToSunset as Number) as Number {
        // Timers advance first, so a condition that has only just become true has
        // a hold of one second rather than of zero.
        advance(sky, elevation, flow);

        // Ordered by how much the user would want each one if two came due at the
        // same second. Only one alert is ever raised per second: a pair of
        // full-screen interruptions arriving together is worse than either alone,
        // and the loser stays eligible for the next second anyway.
        if (_gainFor >= SolarAlerts.GAIN_HOLD && ready(SolarAlerts.KIND_GAIN, ticks)) {
            return fire(SolarAlerts.KIND_GAIN, ticks);
        }
        if (secondsToSunset > 0 && secondsToSunset <= SolarAlerts.SUNSET_LEAD
            && ready(SolarAlerts.KIND_SUNSET, ticks)) {
            return fire(SolarAlerts.KIND_SUNSET, ticks);
        }
        if (!_inShade && _shadeFor >= SolarAlerts.SHADE_HOLD
            && ready(SolarAlerts.KIND_SHADE, ticks)) {
            _inShade = true;
            return fire(SolarAlerts.KIND_SHADE, ticks);
        }
        // The all-clear is only worth having if the warning was given. Announcing
        // sunshine to someone who was never told they had lost it is noise.
        if (_inShade && _sunFor >= SolarAlerts.SUN_HOLD
            && ready(SolarAlerts.KIND_SUN, ticks)) {
            _inShade = false;
            return fire(SolarAlerts.KIND_SUN, ticks);
        }
        return SolarAlerts.KIND_NONE;
    }

    private function advance(sky as Number?, elevation as Float, flow as Float?) as Void {
        // Gaining charge: measured only. A provisional rate is not evidence.
        if (flow != null && flow < -0.05) {
            _gainFor += 1;
        } else {
            _gainFor = 0;
        }

        if (sky == null || elevation < SolarAlerts.SHADE_MIN_ELEVATION) {
            // Nothing to judge against. Hold the counters rather than resetting
            // them, so a momentary loss of the reading does not throw away four
            // minutes of accumulated evidence.
            return;
        }
        if (sky <= SolarAlerts.SHADE_MAX_SKY) {
            _shadeFor += 1;
            _sunFor = 0;
        } else if (sky >= SolarAlerts.SUN_MIN_SKY) {
            _sunFor += 1;
            _shadeFor = 0;
        }
        // Between the two thresholds neither timer moves. The gap is deliberate:
        // a single threshold would let a reading hovering on the line alternate
        // between states forever.
    }

    private function ready(kind as Number, ticks as Number) as Boolean {
        var last = _firedAt[kind];
        return (last < 0) || ((ticks - last) >= SolarAlerts.REFRACTORY);
    }

    private function fire(kind as Number, ticks as Number) as Number {
        _firedAt[kind] = ticks;
        return kind;
    }

    // Test seams.
    function shadeSecondsForTest() as Number { return _shadeFor; }
    function inShadeForTest() as Boolean { return _inShade; }
}
