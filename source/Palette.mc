import Toybox.Graphics;
import Toybox.Lang;

// Color for a reflective MIP display.
//
// MIP is lit by ambient light rather than by the panel, so it has far less
// contrast than AMOLED and washes out in exactly the conditions this field is
// used in - bright sun. Three rules follow, and every choice here obeys them:
//
//  * Every color sits on the 0x00/0x55/0xAA/0xFF channel grid, which is Garmin's
//    64-color device palette. Off-grid values get dithered into a stipple that
//    looks like dirt on a 280px screen.
//  * Fully saturated hues only. Pastels and tints collapse toward gray.
//  * Structure comes from weight, not from subtle shade: tracks and baselines are
//    drawn thick in a mid tone rather than thin in a dark one, because a 1px
//    0x555555 line on black is invisible outdoors.
class Palette {

    public var bg as Number = Graphics.COLOR_BLACK;
    public var fg as Number = Graphics.COLOR_WHITE;
    public var dim as Number = 0xAAAAAA;
    public var muted as Number = 0x555555;
    public var accent as Number = 0xFFAA00;
    public var gain as Number = 0x00FF00;
    public var drain as Number = 0xFF5500;
    // A dimmed accent for area fills, so a filled chart still reads as one
    // object with its stroke rather than as gray furniture.
    public var accentFill as Number = 0xAA5500;
    private var _light as Boolean = false;

    function initialize() {
    }

    function apply(background as Number) as Void {
        bg = background;
        _light = (background != Graphics.COLOR_BLACK);
        if (_light) {
            fg = Graphics.COLOR_BLACK;
            dim = 0x555555;
            muted = 0xAAAAAA;
            accent = 0xAA5500;
            accentFill = 0xFFAA00;
            gain = 0x00AA00;
            drain = 0xAA0000;
        } else {
            fg = Graphics.COLOR_WHITE;
            dim = 0xAAAAAA;
            muted = 0x555555;
            accent = 0xFFAA00;
            accentFill = 0xAA5500;
            gain = 0x00FF00;
            drain = 0xFF5500;
        }
    }

    // Sequential heat ramp for a quantity that is ordered: more light.
    //
    // The first pass ran blue - green - amber - red, which is a categorical
    // rainbow. Rainbows have no inherent order, so a reader cannot tell which end
    // is "more" without a legend, and the green band grabs attention it has not
    // earned. These ramps instead climb monotonically in luminance, so the scale
    // is readable even where MIP washes the hue out, and still land on Garmin's
    // 64-color grid:
    //
    //   dark ground:  magenta -> red -> orange -> amber -> yellow
    //   light ground: indigo -> bronze -> orange -> red -> deep red
    //
    // The light ramp used to run the other way, from a bright amber at the bottom
    // to a near-black maroon at the top. That is defensible as a luminance ramp
    // and wrong as a solar one: it made weak light look sunny and full sun look
    // dead, so a reading of 80% arrived as an alarm color. Both ramps now run
    // cool-and-weak to hot-and-strong, which is the direction the metaphor
    // already sets. Everything stays on the 64-color grid and dark enough to
    // read on white.
    function intensity(value as Number) as Number {
        if (value >= 90) {
            return _light ? 0xAA0000 : 0xFFFF00;
        } else if (value >= SolarModel.ZONE_HIGH) {
            return _light ? 0xFF0000 : 0xFFAA00;
        } else if (value >= SolarModel.ZONE_MODERATE) {
            return _light ? 0xFF5500 : 0xFF5500;
        } else if (value >= SolarModel.ZONE_DARK) {
            return _light ? 0xAA5500 : 0xFF0000;
        } else if (value > 0) {
            return _light ? 0x5555AA : 0xAA00AA;
        }
        return muted;
    }

    // Which way the light is moving - a direction, not a level.
    //
    // This used to color the caret off the intensity ramp, which made magenta
    // mean "nearly dark" on every chart and "getting dimmer" on the caret at the
    // same time. A sequential ramp encodes how much of something there is; it
    // cannot also encode which way it is going without teaching the reader two
    // conflicting meanings for one color. Direction gets the same two tokens
    // the battery flow already uses, so up and down look the same everywhere.
    function trend(slope as Float) as Number {
        if (slope > 0.05) {
            return gain;
        } else if (slope < -0.05) {
            return drain;
        }
        return fg;
    }

    // Battery flow, where the model counts drain as positive.
    function flow(perHour as Float) as Number {
        if (perHour < -0.05) {
            return gain;
        } else if (perHour > 0.05) {
            return drain;
        }
        return fg;
    }
}
