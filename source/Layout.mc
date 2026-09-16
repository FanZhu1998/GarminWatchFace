import Toybox.Lang;

// Every coordinate is a fraction of the screen size, so the 42 mm (390), 47 mm (416)
// and 51 mm (454) epix Pro render proportionally identical faces.
//
// Vertical rhythm (top to bottom): the date is a tight eyebrow just above the time (no dead space
// under the bezel); the lower third is one crisp stats panel whose top rule doubles as the underline
// of the coach line, so there is a single strong divider instead of two faint ones.
class Layout {
    public var w as Number;
    public var h as Number;
    public var cx as Number;
    public var cy as Number;
    public var r as Number;              // intensity ring radius

    public var yDate as Number;
    public var yTime as Number;          // vertical center of the time block
    public var secGap as Number;         // gap between minutes and seconds

    public var yCoach as Number;

    public var railX0 as Number;
    public var railX1 as Number;
    public var railV0 as Number;
    public var railV1 as Number;
    public var railTop as Number;
    public var railBottom as Number;
    public var yValue as Number;
    public var yLabel as Number;
    public var xCells as Array<Number>;

    public var yFooter as Number;
    public var yBattery as Number;
    public var dotSize as Number;        // halo diameter of the phone-connected dot
    public var dotGap as Number;         // gap between the dot and the battery text

    public var railPen as Number;        // stroke width of the stats-panel rules

    function initialize(width as Number, height as Number) {
        w = width;
        h = height;
        cx = w / 2;
        cy = h / 2;
        r = cx - 4;

        // The stack is centered in the circle. Three even zones: date+time, coach+panel,
        // footer+battery. The date+time pair rides high enough that the gap below the time (into the
        // coach line) matches the gap below the panel (into the footer), so no zone feels crowded.
        yDate    = frac(h, 0.13);        // eyebrow near the top, tight above the time
        yTime    = frac(h, 0.30);        // hero, lifted to clear the coach line below it
        secGap   = frac(w, 0.028);

        yCoach   = frac(h, 0.472);       // header bridging the time and the panel, even air on both sides

        // stats panel: 0.74 W wide so a 4-glyph value fits each cell; corners stay inside the ring.
        // value and label are centered between the two rules (equal space above the number and
        // below the label), so the cells no longer look top-heavy.
        railX0 = cx - frac(w, 0.37);
        railX1 = cx + frac(w, 0.37);
        railV0 = cx - frac(w, 0.1233);
        railV1 = cx + frac(w, 0.1233);
        railTop = frac(h, 0.53);
        railBottom = frac(h, 0.76);
        yValue = frac(h, 0.618);
        yLabel = frac(h, 0.69);
        xCells = [cx - frac(w, 0.2467), cx, cx + frac(w, 0.2467)] as Array<Number>;

        yFooter = frac(h, 0.825);
        yBattery = frac(h, 0.89);        // even cadence with the footer; settles the base off the bottom edge
        dotSize = frac(w, 0.03);
        dotGap = frac(w, 0.025);

        railPen = frac(w, 0.0072);       // ~3 px at 416; scales with the screen
    }

    private function frac(base as Number, k as Float) as Number {
        return (base * k + 0.5).toNumber();
    }

    // Rail cell under a touch point: 0 = HR, 1 = BODY, 2 = STEPS, -1 = none.
    function cellAt(x as Number, y as Number) as Number {
        if (y < railTop || y > railBottom || x < railX0 || x > railX1) {
            return -1;
        }
        if (x < railV0) { return 0; }
        if (x < railV1) { return 1; }
        return 2;
    }
}
