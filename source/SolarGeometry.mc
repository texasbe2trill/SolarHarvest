import Toybox.Lang;
import Toybox.Math;
import Toybox.Time;
import Toybox.Time.Gregorian;

// Where the sun actually is, from the NOAA solar position equations.
//
// This is what separates a solar field from a solar gauge. The raw sensor cannot
// tell you whether a low reading means evening, cloud, tree cover or a sleeve
// over the watch - the sun being low is not the same failure as the sun being
// blocked. Elevation is pure astronomy and is exact, so measured intensity can be
// compared against what the sun's current height actually allows.
//
// Verified against the closed form for solar noon (elevation = 90 - |latitude -
// declination|) at the solstices and at the test activity's own date, and against
// that activity's real sunrise and sunset.
module SolarGeometry {

    // Below this the model stops meaning much: air mass climbs steeply, the
    // horizon and terrain dominate, and the panel is edge-on to the sun. Set
    // deliberately conservatively - a number that is sometimes wrong is worse
    // than one that is sometimes absent.
    const MIN_USEFUL_ELEVATION = 15.0;

    const DAYS_BEFORE_MONTH = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334] as Array<Number>;

    // Sun elevation in degrees above the horizon. Negative means below it.
    // Latitude and longitude in radians, as Position.Location.toRadians() gives.
    function elevationDegrees(epochSeconds as Number, latRad as Double, lonRad as Double) as Float {
        var info = Gregorian.utcInfo(new Time.Moment(epochSeconds), Time.FORMAT_SHORT);
        var doy = dayOfYear(info.year, info.month, info.day);
        var hour = info.hour + (info.min / 60.0) + (info.sec / 3600.0);

        // Fractional year, in radians.
        var g = ((2.0 * Math.PI) / 365.0) * (doy - 1 + ((hour - 12.0) / 24.0));
        var cosG = Math.cos(g);
        var sinG = Math.sin(g);
        var cos2G = Math.cos(2 * g);
        var sin2G = Math.sin(2 * g);
        var cos3G = Math.cos(3 * g);
        var sin3G = Math.sin(3 * g);

        // Equation of time, in minutes.
        var eqTime = 229.18 * (0.000075 + (0.001868 * cosG) - (0.032077 * sinG)
            - (0.014615 * cos2G) - (0.040849 * sin2G));

        // Solar declination, in radians.
        var decl = 0.006918 - (0.399912 * cosG) + (0.070257 * sinG)
            - (0.006758 * cos2G) + (0.000907 * sin2G)
            - (0.002697 * cos3G) + (0.00148 * sin3G);

        var lonDeg = lonRad * (180.0 / Math.PI);
        var trueSolarMinutes = (hour * 60.0) + eqTime + (4.0 * lonDeg);
        var hourAngle = ((trueSolarMinutes / 4.0) - 180.0) * (Math.PI / 180.0);

        var cosZenith = (Math.sin(latRad) * Math.sin(decl))
            + (Math.cos(latRad) * Math.cos(decl) * Math.cos(hourAngle));
        if (cosZenith > 1.0) {
            cosZenith = 1.0;
        } else if (cosZenith < -1.0) {
            cosZenith = -1.0;
        }
        return (90.0 - (Math.acos(cosZenith) * (180.0 / Math.PI))).toFloat();
    }

    // Where on the horizon the sun is, as a compass bearing from true north.
    //
    // The declination and hour-angle block below is the same one elevationDegrees
    // uses, and is deliberately repeated rather than factored out. Returning both
    // angles from a shared helper means allocating a pair on every call, and
    // elevationDegrees is called thirty-two times in a row to build the daylight
    // profile - that allocation in that loop is a cost this device does not need
    // to pay so that this function, called once a second, can save twenty lines.
    function azimuthDegrees(epochSeconds as Number, latRad as Double, lonRad as Double) as Float {
        var info = Gregorian.utcInfo(new Time.Moment(epochSeconds), Time.FORMAT_SHORT);
        var doy = dayOfYear(info.year, info.month, info.day);
        var hour = info.hour + (info.min / 60.0) + (info.sec / 3600.0);

        var g = ((2.0 * Math.PI) / 365.0) * (doy - 1 + ((hour - 12.0) / 24.0));
        var cosG = Math.cos(g);
        var sinG = Math.sin(g);
        var cos2G = Math.cos(2 * g);
        var sin2G = Math.sin(2 * g);
        var cos3G = Math.cos(3 * g);
        var sin3G = Math.sin(3 * g);

        var eqTime = 229.18 * (0.000075 + (0.001868 * cosG) - (0.032077 * sinG)
            - (0.014615 * cos2G) - (0.040849 * sin2G));
        var decl = 0.006918 - (0.399912 * cosG) + (0.070257 * sinG)
            - (0.006758 * cos2G) + (0.000907 * sin2G)
            - (0.002697 * cos3G) + (0.00148 * sin3G);

        var lonDeg = lonRad * (180.0 / Math.PI);
        var trueSolarMinutes = (hour * 60.0) + eqTime + (4.0 * lonDeg);
        var hourAngle = ((trueSolarMinutes / 4.0) - 180.0) * (Math.PI / 180.0);

        // atan2 rather than acos: the arccosine form loses the east-west sign and
        // needs it patched back on from the hour angle, which is exactly the sort
        // of correction that is wrong for half the day and nobody notices.
        // Measured from due south, positive toward west.
        var fromSouth = Math.atan2(Math.sin(hourAngle),
            (Math.cos(hourAngle) * Math.sin(latRad)) - (Math.tan(decl) * Math.cos(latRad)));
        var bearing = (fromSouth * (180.0 / Math.PI)) + 180.0;
        while (bearing < 0.0) {
            bearing += 360.0;
        }
        while (bearing >= 360.0) {
            bearing -= 360.0;
        }
        return bearing.toFloat();
    }

    // The share of full-sun charging the sun's current height can support, 0-1.
    // A flat panel receives light in proportion to the sine of the elevation, so
    // this is the ceiling that measured intensity should be judged against.
    function availableFraction(elevationDeg as Float) as Float {
        if (elevationDeg <= 0.0) {
            return 0.0;
        }
        var v = Math.sin(elevationDeg * (Math.PI / 180.0));
        if (v < 0.0) {
            return 0.0;
        } else if (v > 1.0) {
            return 1.0;
        }
        return v.toFloat();
    }

    // How much of the available sun is actually reaching the panel, as a percent.
    //
    // 100 means the watch is collecting everything the sun's height allows;
    // a low number with the sun high means cloud, canopy, or a sleeve over it.
    // Null when the sun is too low for the comparison to mean anything.
    function clearSkyPercent(intensity as Number, elevationDeg as Float) as Number? {
        if (elevationDeg < MIN_USEFUL_ELEVATION) {
            return null;
        }
        var available = availableFraction(elevationDeg);
        if (available <= 0.0) {
            return null;
        }
        var pct = ((intensity / available) + 0.5).toNumber();
        if (pct < 0) {
            return 0;
        } else if (pct > 100) {
            return 100;
        }
        return pct;
    }

    // Sunrise and sunset for the day `epochSeconds` falls in, as [rise, set]
    // epoch seconds. Null when the sun neither rises nor sets there.
    //
    // This exists because Weather.getSunset() reads *cached* weather: a watch that
    // has not synced with its phone returns null, and the whole daylight page
    // silently degrades. Sunrise is geometry, not weather - it needs only a
    // position and a date, both of which the watch always has.
    //
    // Zenith of 90.833 degrees rather than 90 accounts for atmospheric refraction
    // and the sun's own radius, which is the convention every published table uses.
    function sunEvents(epochSeconds as Number, latRad as Double, lonRad as Double) as Array<Number>? {
        var info = Gregorian.utcInfo(new Time.Moment(epochSeconds), Time.FORMAT_SHORT);
        var midnight = epochSeconds - ((info.hour * 3600) + (info.min * 60) + info.sec);
        var doy = dayOfYear(info.year, info.month, info.day);

        // Evaluated near the middle of the day rather than at midnight.
        var g = ((2.0 * Math.PI) / 365.0) * (doy - 1 + 0.5);
        var cosG = Math.cos(g);
        var sinG = Math.sin(g);
        var cos2G = Math.cos(2 * g);
        var sin2G = Math.sin(2 * g);
        var eqTime = 229.18 * (0.000075 + (0.001868 * cosG) - (0.032077 * sinG)
            - (0.014615 * cos2G) - (0.040849 * sin2G));
        var decl = 0.006918 - (0.399912 * cosG) + (0.070257 * sinG)
            - (0.006758 * cos2G) + (0.000907 * sin2G)
            - (0.002697 * Math.cos(3 * g)) + (0.00148 * Math.sin(3 * g));

        var cosLat = Math.cos(latRad);
        var cosDecl = Math.cos(decl);
        if (cosLat == 0.0 || cosDecl == 0.0) {
            return null;
        }
        var cosHA = (Math.cos(90.833 * (Math.PI / 180.0)) / (cosLat * cosDecl))
            - (Math.tan(latRad) * Math.tan(decl));
        if (cosHA > 1.0 || cosHA < -1.0) {
            // Polar night or midnight sun: there is no crossing to report.
            return null;
        }
        var hourAngle = Math.acos(cosHA) * (180.0 / Math.PI);

        var lonDeg = lonRad * (180.0 / Math.PI);
        var noonMinutes = 720.0 - (4.0 * lonDeg) - eqTime;
        var rise = midnight + ((noonMinutes - (4.0 * hourAngle)) * 60).toNumber();
        var set = midnight + ((noonMinutes + (4.0 * hourAngle)) * 60).toNumber();
        if (set < rise) {
            // Western longitudes put the day's sunset past UTC midnight.
            set += 86400;
        }
        return [rise, set] as Array<Number>;
    }

    function dayOfYear(year as Number, month as Number, day as Number) as Number {
        var m = month;
        if (m < 1) {
            m = 1;
        } else if (m > 12) {
            m = 12;
        }
        var doy = DAYS_BEFORE_MONTH[m - 1] + day;
        if (m > 2 && isLeapYear(year)) {
            doy += 1;
        }
        return doy;
    }

    function isLeapYear(year as Number) as Boolean {
        if ((year % 4) != 0) {
            return false;
        }
        if ((year % 100) != 0) {
            return true;
        }
        return (year % 400) == 0;
    }
}
