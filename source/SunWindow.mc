import Toybox.Lang;

// Daylight window states derived from real sunrise/sunset moments.
const SUN_UNKNOWN = 0;
const SUN_DAWN = 1;
const SUN_DAY = 2;
const SUN_NIGHT = 3;

// Epoch seconds in, state out. Zero or negative means "not known yet".
function sunWindowState(now as Number, sunrise as Number, sunset as Number) as Number {
    if (sunrise <= 0 && sunset <= 0) {
        return SUN_UNKNOWN;
    }
    if (sunrise > 0 && now < sunrise) {
        return SUN_DAWN;
    }
    if (sunset > 0) {
        return (now < sunset) ? SUN_DAY : SUN_NIGHT;
    }
    return SUN_UNKNOWN;
}

function sunWindowRemaining(now as Number, sunrise as Number, sunset as Number) as Number {
    var state = sunWindowState(now, sunrise, sunset);
    var remaining = 0;
    if (state == SUN_DAWN) {
        remaining = sunrise - now;
    } else if (state == SUN_DAY) {
        remaining = sunset - now;
    }
    return (remaining < 0) ? 0 : remaining;
}

// Auto-cycle skips pages that have nothing to show, so a page is never blank.
// `mask` is a bitmask of available pages; returns the next available index.
function resolvePage(index as Number, mask as Number, count as Number) as Number {
    if (mask == 0 || count <= 0) {
        return 0;
    }
    var start = index % count;
    if (start < 0) {
        start += count;
    }
    for (var i = 0; i < count; i++) {
        var candidate = (start + i) % count;
        if ((mask & (1 << candidate)) != 0) {
            return candidate;
        }
    }
    return 0;
}

// Number of available pages, used to keep the dot indicator honest.
function countPages(mask as Number, count as Number) as Number {
    var total = 0;
    for (var i = 0; i < count; i++) {
        if ((mask & (1 << i)) != 0) {
            total += 1;
        }
    }
    return total;
}
