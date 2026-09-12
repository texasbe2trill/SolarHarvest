import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// The full-screen card an alert puts in front of the user.
//
// This is read at arm's length, in motion, in sunlight, in the second or two
// before it clears itself - which rules out almost everything the pages do. No
// charts, no chips, no dial: a mark, a headline, and one line saying what to do
// about it. The mark is drawn rather than lettered so the meaning survives being
// seen rather than read.
class SolarAlertView extends WatchUi.DataFieldAlert {
    private var _kind as Number;
    private var _detail as String;
    private var _palette as Palette;

    function initialize(kind as Number, detail as String, palette as Palette) {
        DataFieldAlert.initialize();
        _kind = kind;
        _detail = detail;
        _palette = palette;
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var accent = accentColor();

        dc.setColor(_palette.bg, _palette.bg);
        dc.clear();

        // A rim rather than a full flood: on a reflective display a saturated
        // full-screen fill costs contrast everywhere it touches text, and the
        // colour only has to be seen, not stared at.
        //
        // Drawn as a ring because the screen is one. The first version banded the
        // top and bottom edges, which on a round lens is where there are almost no
        // pixels - the top band fell outside the glass entirely and only the
        // bottom one survived, so the card looked lopsided rather than framed.
        var cx = w / 2;
        var cy = h / 2;
        var band = (h * 0.045).toNumber();
        if (band < 3) {
            band = 3;
        }
        var rim = ((w < h) ? w : h) / 2;
        dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(band);
        dc.drawCircle(cx, cy, rim - (band / 2) - 1);
        dc.setPenWidth(1);
        var glyphR = (h * 0.13).toNumber();
        var glyphY = (h * 0.28).toNumber();
        drawGlyph(dc, cx, glyphY, glyphR, accent);

        var titleFont = Graphics.FONT_MEDIUM;
        var detailFont = Graphics.FONT_XTINY;
        var title = headline();
        // Step down rather than let the headline run off a 43mm screen.
        if (dc.getTextWidthInPixels(title, titleFont) > (w - 8)) {
            titleFont = Graphics.FONT_SMALL;
        }
        if (dc.getTextWidthInPixels(title, titleFont) > (w - 8)) {
            titleFont = Graphics.FONT_XTINY;
        }

        var titleY = (h * 0.50).toNumber();
        dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY, titleFont, title, Graphics.TEXT_JUSTIFY_CENTER);

        // The detail line gets the same step-down the headline does. Without it a
        // string that was written to fit a 51mm screen simply ran off both edges
        // of the glass, and the alert that most needed explaining was the one that
        // lost its explanation.
        var room = w - (4 * band);
        if (dc.getTextWidthInPixels(_detail, detailFont) > room) {
            detailFont = Graphics.FONT_GLANCE;
        }
        dc.setColor(_palette.fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY + dc.getFontHeight(titleFont), detailFont, _detail,
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Drawn, not lettered. Each mark says its own thing at a glance: a rising
    // wedge for charge coming in, a filled disc for the sun, a half-covered one
    // for shade, a sinking one for the day ending.
    private function drawGlyph(dc as Dc, cx as Number, cy as Number, r as Number,
                               accent as Number) as Void {
        dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
        if (_kind == SolarAlerts.KIND_GAIN) {
            // An upward chevron: the one direction a battery reading almost never
            // goes, which is exactly why it is worth interrupting for.
            dc.setPenWidth(6);
            dc.drawLine(cx - r, cy + (r / 2), cx, cy - (r / 2));
            dc.drawLine(cx, cy - (r / 2), cx + r, cy + (r / 2));
            dc.drawLine(cx - r, cy + r, cx, cy);
            dc.drawLine(cx, cy, cx + r, cy + r);
            dc.setPenWidth(1);
            return;
        }
        if (_kind == SolarAlerts.KIND_SHADE) {
            // A sun with a bite taken out of it, in the background colour, so the
            // obstruction reads as something in front of the sun rather than as a
            // differently shaped sun.
            dc.fillCircle(cx, cy, r);
            dc.setColor(_palette.bg, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(cx + (r / 2), cy + (r / 3), r);
            return;
        }
        // Sun, full or setting: a disc with rays, and for the setting case a
        // horizon drawn across its lower third.
        dc.fillCircle(cx, cy, (r * 2) / 3);
        dc.setPenWidth(4);
        for (var i = 0; i < 8; i++) {
            var a = (i * Math.PI) / 4.0;
            var sx = cx + (Math.cos(a) * r).toNumber();
            var sy = cy + (Math.sin(a) * r).toNumber();
            var ex = cx + (Math.cos(a) * (r * 1.35)).toNumber();
            var ey = cy + (Math.sin(a) * (r * 1.35)).toNumber();
            dc.drawLine(sx, sy, ex, ey);
        }
        if (_kind == SolarAlerts.KIND_SUNSET) {
            // The horizon is painted in the background colour and then re-drawn as
            // a line, so the sun is cut off by it rather than sitting on top.
            dc.setColor(_palette.bg, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(cx - (r * 2), cy + (r / 2), r * 4, r * 2);
            dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(cx - (r * 3 / 2), cy + (r / 2), r * 3, 4);
        }
        dc.setPenWidth(1);
    }

    private function accentColor() as Number {
        if (_kind == SolarAlerts.KIND_GAIN) {
            return _palette.gain;
        } else if (_kind == SolarAlerts.KIND_SHADE) {
            return _palette.dim;
        } else if (_kind == SolarAlerts.KIND_SUNSET) {
            return _palette.drain;
        }
        return _palette.accent;
    }

    private function headline() as String {
        if (_kind == SolarAlerts.KIND_GAIN) {
            return "BATTERY GAIN";
        } else if (_kind == SolarAlerts.KIND_SHADE) {
            return "IN SHADE";
        } else if (_kind == SolarAlerts.KIND_SUNSET) {
            return "SUN SETTING";
        }
        return "BACK IN SUN";
    }
}
