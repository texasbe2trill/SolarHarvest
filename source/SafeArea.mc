import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

// Maps the data field rectangle onto the physical screen so text is never drawn
// under the bezel, in any field layout - not just full screen.
// The field's position is derived from the obscurity flags the system reports.
class SafeArea {

    static const MARGIN = 5;

    // Extra inset, so content can be kept clear of a bezel ring drawn over the
    // same rows. Zero unless a caller asks for it, and only applied above the row
    // where that ring ends - the dial sweeps over the top and leaves the bottom
    // of the screen open, so insetting there would strip width from the chips for
    // no reason.
    private var _inset as Number = 0;
    private var _insetAbove as Number = 0;

    private var _round as Boolean = false;
    private var _fieldW as Number = 100;
    private var _fieldX as Number = 0;
    private var _fieldY as Number = 0;    private var _screenCx as Number = 50;
    private var _screenCy as Number = 50;
    private var _radius as Number = 50;

    function initialize() {
    }

    // The obscurity bits are read from DataField rather than passed in: they are
    // constants, and Connect IQ 3.4 (the fenix 6 generation) rejects any method
    // with more than nine parameters.
    function configure(round as Boolean, screenW as Number, screenH as Number,
                       fieldW as Number, fieldH as Number, flags as Number) as Void {
        var obscureTop = WatchUi.DataField.OBSCURE_TOP;
        var obscureBottom = WatchUi.DataField.OBSCURE_BOTTOM;
        var obscureLeft = WatchUi.DataField.OBSCURE_LEFT;
        var obscureRight = WatchUi.DataField.OBSCURE_RIGHT;
        _round = round;
        _fieldW = fieldW;
        _screenCx = screenW / 2;
        _screenCy = screenH / 2;
        _radius = ((screenW < screenH) ? screenW : screenH) / 2;

        if ((flags & obscureTop) != 0) {
            _fieldY = 0;
        } else if ((flags & obscureBottom) != 0) {
            _fieldY = screenH - fieldH;
        } else {
            _fieldY = (screenH - fieldH) / 2;
        }

        var left = (flags & obscureLeft) != 0;
        var right = (flags & obscureRight) != 0;
        if (left && !right) {
            _fieldX = 0;
        } else if (right && !left) {
            _fieldX = screenW - fieldW;
        } else {
            _fieldX = (screenW - fieldW) / 2;
        }
    }

    // Pull rows above `above` in by this many pixels. The intensity dial is drawn
    // just inside the glass, and without this the page title runs straight
    // through it.
    function setInset(inset as Number, above as Number) as Void {
        _inset = (inset < 0) ? 0 : inset;
        _insetAbove = above;
    }

    function leftAt(localY as Number) as Number {
        if (!_round) {
            return MARGIN;
        }
        var half = chordHalfWidth(localY);
        var edge = (_screenCx - half) - _fieldX;
        return (edge < 0) ? 0 : edge;
    }

    function rightAt(localY as Number) as Number {
        if (!_round) {
            return _fieldW - MARGIN;
        }
        var half = chordHalfWidth(localY);
        var edge = (_screenCx + half) - _fieldX;
        return (edge > _fieldW) ? _fieldW : edge;
    }

    function centerAt(localY as Number) as Number {
        return (leftAt(localY) + rightAt(localY)) / 2;
    }

    function halfAt(localY as Number) as Number {
        var span = (rightAt(localY) - leftAt(localY)) / 2;
        return (span < 0) ? 0 : span;
    }

    // The narrowest half-width across a band, for content that occupies rows
    // rather than a single line.
    //
    // Measuring at one edge is what let the widest hero on the field run into the
    // ring at both ends: a box sitting above centre is widest at its bottom, and
    // sizing the text to that gives it room the row it is actually drawn on does
    // not have. Chord width falls away monotonically from the middle, so the
    // narrower of the two ends is the whole answer.
    function halfAcross(topY as Number, bottomY as Number) as Number {
        var a = halfAt(topY);
        var b = halfAt(bottomY);
        return (a < b) ? a : b;
    }

    // Screen centre expressed in field coordinates, so a bezel ring is concentric
    // with the watch face rather than with the data field rectangle.
    function ringCenterX() as Number { return _screenCx - _fieldX; }
    function ringCenterY() as Number { return _screenCy - _fieldY; }
    function ringRadius() as Number { return _radius; }

    private function chordHalfWidth(localY as Number) as Number {
        var r = _radius - MARGIN - ((localY < _insetAbove) ? _inset : 0);
        var dy = (_fieldY + localY) - _screenCy;
        var squared = (r * r) - (dy * dy);
        if (squared <= 0) {
            return 0;
        }
        return Math.sqrt(squared.toFloat()).toNumber();
    }
}
