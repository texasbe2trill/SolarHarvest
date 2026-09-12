import Toybox.FitContributor;
import Toybox.Lang;
import Toybox.WatchUi;

// catching_percent and sun_elevation exist because raw battery percent, sampled
// at the OS's own whole-point resolution, is often a single step across an
// entire activity - a walk that starts at 90% and ends at 89% has nothing left
// to chart, and no amount of axis styling fixes that. Solar intensity has no
// such problem - it already renders as a genuinely rich chart, canopy shade and
// all - so these two fields extend the same idea: always a real, honest,
// second-to-second shape, on any activity, long or short, battery moving or not.

// Everything this field contributes to the .FIT file, and so everything Garmin
// Connect can show once the activity is over.
//
// Two rules drive the design:
//
//  * Session and lap fields are refreshed on every compute(), never only at the
//    moment a lap is pressed. Garmin writes the lap message itself, and a value
//    set inside onTimerLap() lands after that message is already built - which is
//    why the first lap recorded nothing and every later lap carried the previous
//    lap's number.
//  * Every field is created in its own try/catch. A device that refuses one field
//    then still records all the others instead of silently recording nothing.
//
// This class cannot be unit tested: constructing a real Field via createField()
// outside a live activity-recording context throws a native System Error that
// bypasses Monkey C's own try/catch entirely. That is why every test that builds
// a SolarPowerView sets gSkipFitRecording first - not a style preference, a hard
// wall. What stays testable is the arithmetic that feeds this class (see
// roundedElevation below); createField()/setData() themselves only prove out
// against a real recorded activity.
class FitRecorder {

    // Developer field numbers. Stable for the life of the app: changing one
    // renames the channel for anybody comparing old activities to new ones.
    static const ID_SOLAR = 0;
    static const ID_SESSION_FULL_SUN = 1;
    static const ID_LAP_FULL_SUN = 2;
    static const ID_BATTERY = 3;
    static const ID_SESSION_AVG = 4;
    static const ID_SESSION_PEAK = 5;
    static const ID_SESSION_SUN_PCT = 6;
    static const ID_SESSION_BAT_USED = 7;
    static const ID_SESSION_FLOW = 8;
    static const ID_SESSION_SAVING = 9;
    static const ID_LAP_AVG = 10;
    static const ID_CATCHING = 11;
    static const ID_ELEVATION = 12;
    static const ID_PROJECTED_HOURS = 13;

    // Record stream: the curves worth plotting against distance and time.
    private var _solar as Field?;
    private var _battery as Field?;
    private var _catching as Field?;
    private var _elevation as Field?;

    // Session summary.
    private var _fullSun as Field?;
    private var _avg as Field?;
    private var _peak as Field?;
    private var _sunPct as Field?;
    private var _batUsed as Field?;
    private var _flow as Field?;
    private var _saving as Field?;
    private var _projectedHours as Field?;

    // Lap summary.
    private var _lapFullSun as Field?;
    private var _lapAvg as Field?;

    function initialize(field as WatchUi.DataField) {
        _solar = make(field, "solar_intensity", ID_SOLAR, FitContributor.DATA_TYPE_UINT8,
            FitContributor.MESG_TYPE_RECORD, "%");
        _battery = make(field, "battery", ID_BATTERY, FitContributor.DATA_TYPE_UINT8,
            FitContributor.MESG_TYPE_RECORD, "%");
        // The same "share of available sunlight actually caught" the on-watch
        // CATCHING page leads with - the app's most distinctive metric, and
        // until now invisible to Connect entirely. Available on any activity
        // with a fix once the sun clears 15 degrees, independent of whether the
        // battery has moved at all.
        _catching = make(field, "catching_percent", ID_CATCHING, FitContributor.DATA_TYPE_UINT8,
            FitContributor.MESG_TYPE_RECORD, "%");
        // The sun's height above the horizon, every second. Signed because it is
        // legitimately negative just after sunrise or before sunset - not an
        // error, the actual geometry. Smooth and always present once there is a
        // fix, so it gives Connect a real curve to draw even during the one
        // activity in twenty where solar intensity itself barely moves.
        _elevation = make(field, "sun_elevation", ID_ELEVATION, FitContributor.DATA_TYPE_SINT8,
            FitContributor.MESG_TYPE_RECORD, "deg");

        _fullSun = make(field, "full_sun", ID_SESSION_FULL_SUN, FitContributor.DATA_TYPE_UINT16,
            FitContributor.MESG_TYPE_SESSION, "min");
        _avg = make(field, "avg_solar", ID_SESSION_AVG, FitContributor.DATA_TYPE_UINT8,
            FitContributor.MESG_TYPE_SESSION, "%");
        _peak = make(field, "peak_solar", ID_SESSION_PEAK, FitContributor.DATA_TYPE_UINT8,
            FitContributor.MESG_TYPE_SESSION, "%");
        _sunPct = make(field, "time_in_sun", ID_SESSION_SUN_PCT, FitContributor.DATA_TYPE_UINT8,
            FitContributor.MESG_TYPE_SESSION, "%");
        _batUsed = make(field, "battery_used", ID_SESSION_BAT_USED, FitContributor.DATA_TYPE_FLOAT,
            FitContributor.MESG_TYPE_SESSION, "%");
        _flow = make(field, "battery_rate", ID_SESSION_FLOW, FitContributor.DATA_TYPE_FLOAT,
            FitContributor.MESG_TYPE_SESSION, "%/h");
        _saving = make(field, "solar_saving", ID_SESSION_SAVING, FitContributor.DATA_TYPE_FLOAT,
            FitContributor.MESG_TYPE_SESSION, "%/h");
        // Runtime left at the measured drain rate - the same figure the RATE/LEFT
        // chip already states on the watch, restated here so it survives the
        // activity as a summary stat rather than only living on a screen nobody
        // is looking at after the fact.
        _projectedHours = make(field, "projected_hours", ID_PROJECTED_HOURS,
            FitContributor.DATA_TYPE_FLOAT, FitContributor.MESG_TYPE_SESSION, "h");

        _lapFullSun = make(field, "lap_full_sun", ID_LAP_FULL_SUN, FitContributor.DATA_TYPE_UINT16,
            FitContributor.MESG_TYPE_LAP, "min");
        _lapAvg = make(field, "lap_avg_solar", ID_LAP_AVG, FitContributor.DATA_TYPE_UINT8,
            FitContributor.MESG_TYPE_LAP, "%");
    }

    private function make(field as WatchUi.DataField, name as String, id as Number,
                          type as FitContributor.DataType, mesg as FitContributor.MessageType,
                          units as String) as Field? {
        try {
            return field.createField(name, id, type, { :mesgType => mesg, :units => units });
        } catch (ex) {
            return null;
        }
    }

    // Called once per second from compute(). Session and lap values are kept
    // current here so whatever Garmin writes, whenever it writes it, is right.
    //
    // elevation/hasFix are passed in rather than read off the model: the sun's
    // height is geometry the view already tracks for its own pages, not
    // something this class should be recomputing a second way.
    function update(model as SolarModel, elevation as Float, hasFix as Boolean) as Void {
        set(_solar, model.smoothed());

        var level = model.batteryPercent();
        if (level >= 0.0) {
            set(_battery, (level + 0.5).toNumber());
        }

        set(_fullSun, model.harvestSeconds() / 60);
        set(_avg, model.average());
        set(_peak, model.peak());
        set(_sunPct, percent(model.sunFraction()));

        if (level >= 0.0) {
            set(_batUsed, model.batteryUsedPercent());
        }
        var flow = model.netFlowPerHour();
        if (flow != null) {
            set(_flow, flow);
        }
        var saving = model.solarOffsetPerHour();
        if (saving != null) {
            set(_saving, saving);
        }
        var hours = model.projectedHours();
        if (hours != null) {
            set(_projectedHours, hours);
        }

        if (hasFix) {
            set(_elevation, roundedElevation(elevation));
            var catching = SolarGeometry.clearSkyPercent(model.smoothed(), elevation);
            if (catching != null) {
                set(_catching, catching);
            }
        }

        updateLap(model);
    }

    // Firmware writes the lap message around the onTimerLap() callback and the
    // exact side varies, so the lap fields are refreshed both every second and
    // once more before the accumulators are cleared. Either ordering then lands
    // the finished lap's own numbers on the finished lap.
    function updateLap(model as SolarModel) as Void {
        set(_lapFullSun, model.lapHarvestSeconds() / 60);
        set(_lapAvg, model.lapAverage());
    }

    private function set(field as Field?, value as Numeric) as Void {
        if (field != null) {
            try {
                field.setData(value);
            } catch (ex) {
                // A single rejected value must never end the activity.
            }
        }
    }

    // Round-half-away-from-zero for a signed field. Monkey C's toNumber()
    // truncates toward zero, so a plain "+0.5" rounds a negative elevation the
    // wrong way: -2.7 + 0.5 = -2.2, truncating to -2, when -2.7 rounds to -3.
    // static, not private: constructing a FitRecorder at all is the operation
    // that cannot run in a unit test (see the class comment above), so this has
    // to be callable without an instance for a test to reach it.
    static function roundedElevation(elevation as Float) as Number {
        return (elevation + (elevation < 0.0 ? -0.5 : 0.5)).toNumber();
    }

    private function percent(fraction as Float) as Number {
        var v = ((fraction * 100) + 0.5).toNumber();
        if (v < 0) {
            return 0;
        } else if (v > 100) {
            return 100;
        }
        return v;
    }
}
