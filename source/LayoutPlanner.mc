import Toybox.Lang;

// Vertical layout solver. Elements are dropped by priority until everything
// fits, so rows can never overlap regardless of field size or font metrics.
class LayoutPlanner {

    static const GAP = 5;
    static const MIN_HERO = 20;
    static const MIN_CHART = 12;
    static const MAX_CHART = 104;

    public var titleY as Number = 0;
    public var dotsY as Number = 0;
    public var heroY as Number = 0;
    public var heroH as Number = 0;
    public var chartY as Number = 0;
    public var chartH as Number = 0;
    public var chipsY as Number = 0;
    public var showTitle as Boolean = false;
    public var showDots as Boolean = false;
    public var showChart as Boolean = false;
    public var showChips as Boolean = false;

    function initialize(top as Number, available as Number, lineH as Number,
                        dotsH as Number, wantDots as Boolean) {
        plan(top, available, lineH, dotsH, wantDots);
    }

    function plan(top as Number, available as Number, lineH as Number,
                  dotsH as Number, wantDots as Boolean) as Void {
        showTitle = true;
        showDots = wantDots && (dotsH > 0);
        showChart = true;
        showChips = true;

        // The chart earns a little over two fifths of the field.
        //
        // At a third it was a strip: the ring and the hero took the screen and the
        // actual visualisation was a sliver pinned between them, which is exactly
        // what made the pages read as a number with a decoration rather than as a
        // chart with a headline. This is the largest share the hero can give up
        // before its font has to step down.
        var chartWant = (available * 0.42).toNumber();
        if (chartWant < MIN_CHART) {
            chartWant = MIN_CHART;
        } else if (chartWant > MAX_CHART) {
            chartWant = MAX_CHART;
        }

        // Sacrifice order: page dots, then chips, then title, then the chart.
        while (required(lineH, dotsH, chartWant) > available) {
            if (showDots) {
                showDots = false;
            } else if (showChips) {
                showChips = false;
            } else if (showTitle) {
                showTitle = false;
            } else if (showChart) {
                showChart = false;
            } else {
                break;
            }
        }

        // Dots first, then the title immediately above the hero it names.
        //
        // The title used to sit at the very top, which is exactly where the
        // intensity dial sweeps: two elements competing for the same band, and no
        // amount of margin fixes that on a round screen. Down here the chord is
        // wider, the dial never reaches, and the label finally sits next to the
        // number it belongs to instead of being separated from it by the dots.
        var y = top;
        if (showDots) {
            dotsY = y;
            y += dotsH + GAP;
        }
        if (showTitle) {
            titleY = y;
            y += lineH + GAP;
        }

        var floorY = top + available;
        if (showChips) {
            chipsY = floorY - lineH;
            floorY = chipsY - GAP;
        }
        if (showChart) {
            chartH = chartWant;
            chartY = floorY - chartH;
            floorY = chartY - GAP;
        } else {
            chartH = 0;
        }

        heroY = y;
        heroH = floorY - y;
        if (heroH < MIN_HERO) {
            heroH = MIN_HERO;
        }
    }

    function heroCenterY() as Number {
        return heroY + (heroH / 2);
    }

    private function required(lineH as Number, dotsH as Number, chartH as Number) as Number {
        var total = MIN_HERO;
        if (showTitle) {
            total += lineH + GAP;
        }
        if (showDots) {
            total += dotsH + GAP;
        }
        if (showChart) {
            total += chartH + GAP;
        }
        if (showChips) {
            total += lineH + GAP;
        }
        return total;
    }
}
