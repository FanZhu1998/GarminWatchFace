import java.awt.*;
import java.awt.font.*;
import java.awt.geom.*;
import java.awt.image.BufferedImage;
import java.io.*;
import java.util.*;
import java.util.List;
import javax.imageio.ImageIO;

/**
 * FontGen - BMFont-compatible bitmap font generator (text .fnt + RGBA .png) for Connect IQ,
 * plus an SVG path exporter for the launcher icon.
 *
 *   FontGen info    <ttf> <sizePx>
 *   FontGen bmfont  <ttf> <sizePx> <chars> <outBase> <tracking> [base,lineHeight] [tab] [s<width>]
 *   FontGen svgpath <ttf> <sizePx> <text> [tracking]
 *
 * Trailing bmfont options (any order): a "base,lineHeight" pair overrides the vertical metrics;
 * the literal "tab" forces tabular figures (every digit 0-9 gets the widest digit's advance,
 * centered) so per-second / per-minute digits do not jitter with a proportional typeface;
 * "s<width>" (e.g. s1.2) faux-bolds glyphs by stroking the outline that many pixels, for a weight
 * between the font's Regular and Bold when no intermediate weight exists.
 */
public class FontGen {
    public static void main(String[] a) throws Exception {
        System.setProperty("java.awt.headless", "true");
        switch (a[0]) {
            case "info":    info(a[1], Float.parseFloat(a[2])); break;
            case "bmfont": {
                String metrics = null; boolean tab = false; double stroke = 0;
                for (int i = 6; i < a.length; i++) {
                    if (a[i].equals("tab")) { tab = true; }
                    else if (a[i].contains(",")) { metrics = a[i]; }
                    else if (a[i].startsWith("s")) { stroke = Double.parseDouble(a[i].substring(1)); }
                    // "-" (or anything else) is ignored
                }
                bmfont(a[1], Float.parseFloat(a[2]), unescape(a[3]), a[4], Integer.parseInt(a[5]), metrics, tab, stroke);
                break;
            }
            case "svgpath": svgpath(a[1], Float.parseFloat(a[2]), unescape(a[3]), a.length > 4 ? Float.parseFloat(a[4]) : 0f); break;
            default: throw new IllegalArgumentException("mode");
        }
    }

    /** Expand \\uXXXX escapes so non-ASCII glyphs survive the Windows console. */
    static String unescape(String s) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch == '\\' && i + 5 < s.length() + 0 && s.charAt(i + 1) == 'u') {
                out.append((char) Integer.parseInt(s.substring(i + 2, i + 6), 16));
                i += 5;
            } else {
                out.append(ch);
            }
        }
        return out.toString();
    }

    static final FontRenderContext FRC = new FontRenderContext(null, RenderingHints.VALUE_TEXT_ANTIALIAS_ON, RenderingHints.VALUE_FRACTIONALMETRICS_ON);

    static Font load(String ttf, float size) throws Exception {
        return Font.createFont(Font.TRUETYPE_FONT, new File(ttf)).deriveFont(size);
    }

    static void info(String ttf, float size) throws Exception {
        Font f = load(ttf, size);
        LineMetrics lm = f.getLineMetrics("0", FRC);
        System.out.printf("%s | family=%s | ps=%s%n", f.getFontName(), f.getFamily(), f.getPSName());
        System.out.printf("size=%.0f ascent=%.1f descent=%.1f leading=%.1f%n", size, lm.getAscent(), lm.getDescent(), lm.getLeading());
        for (String s : new String[]{"0", "1", "8", "H", "x", ":", ","}) {
            GlyphVector gv = f.createGlyphVector(FRC, s);
            Rectangle2D b = gv.getOutline().getBounds2D();
            System.out.printf("  [%s] bounds x=%.1f y=%.1f w=%.1f h=%.1f advance=%.1f%n", s, b.getX(), b.getY(), b.getWidth(), b.getHeight(), gv.getGlyphMetrics(0).getAdvance());
        }
    }

    static class G { int cp; Shape outline; Rectangle box; int adv; int xoffAdj; int x, y; }

    static void bmfont(String ttf, float size, String chars, String outBase, int tracking, String metricsOverride, boolean tabular, double stroke) throws Exception {
        int sp = (stroke > 0) ? (int) Math.ceil(stroke / 2.0) : 0;   // extra glyph-box padding for the stroke
        Font f = load(ttf, size);
        List<G> gs = new ArrayList<>();
        int minTop = Integer.MAX_VALUE, maxBottom = Integer.MIN_VALUE;
        LinkedHashSet<Integer> cps = new LinkedHashSet<>();
        chars.codePoints().forEach(cps::add);
        for (int cp : cps) {
            if (!f.canDisplay(cp)) { System.err.println("WARN: font lacks U+" + Integer.toHexString(cp)); continue; }
            String s = new String(Character.toChars(cp));
            GlyphVector gv = f.createGlyphVector(FRC, s);
            G g = new G();
            g.cp = cp;
            g.outline = gv.getOutline();
            Rectangle2D b = g.outline.getBounds2D();
            g.adv = Math.round(gv.getGlyphMetrics(0).getAdvance()) + tracking;
            if (b.isEmpty()) {                       // space etc.
                g.box = new Rectangle(0, 0, 1, 1);
                g.outline = null;
            } else {
                int x0 = (int) Math.floor(b.getX()) - 1 - sp, y0 = (int) Math.floor(b.getY()) - 1 - sp;
                int x1 = (int) Math.ceil(b.getMaxX()) + 1 + sp, y1 = (int) Math.ceil(b.getMaxY()) + 1 + sp;
                g.box = new Rectangle(x0, y0, x1 - x0, y1 - y0);
                minTop = Math.min(minTop, y0);
                maxBottom = Math.max(maxBottom, y1);
            }
            gs.add(g);
        }
        int base, lineHeight;
        if (metricsOverride != null) {
            String[] p = metricsOverride.split(",");
            base = Integer.parseInt(p[0]); lineHeight = Integer.parseInt(p[1]);
        } else {
            base = -minTop;                       // tight: line top = tallest glyph top
            lineHeight = base + Math.max(0, maxBottom);
        }

        // Tabular figures: give every digit the widest digit's advance, centered, so changing
        // numbers do not shift horizontally. Letters and punctuation stay proportional.
        if (tabular) {
            int maxDigitAdv = 0;
            for (G g : gs) { if (g.cp >= '0' && g.cp <= '9') { maxDigitAdv = Math.max(maxDigitAdv, g.adv); } }
            for (G g : gs) {
                if (g.cp >= '0' && g.cp <= '9') {
                    g.xoffAdj = (maxDigitAdv - g.adv) / 2;
                    g.adv = maxDigitAdv;
                }
            }
        }

        // shelf pack, tallest first
        List<G> order = new ArrayList<>(gs);
        order.sort((p, q) -> q.box.height - p.box.height);
        int texW = 0, texH = 0;
        int[] sizes = {64, 128, 256, 512, 1024, 2048};
        outer:
        for (int W : sizes) {
            for (int H : sizes) {
                if (H > W * 2) break;
                if (pack(order, W, H)) { texW = W; texH = H; break outer; }
            }
        }
        if (texW == 0) throw new RuntimeException("glyphs do not fit a 2048 texture");
        int used = 0;
        for (G g : order) used = Math.max(used, g.y + g.box.height + 1);
        int H2 = 1; while (H2 < used) H2 <<= 1; texH = Math.max(1, Math.min(texH, H2));

        BufferedImage atlas = new BufferedImage(texW, texH, BufferedImage.TYPE_INT_ARGB);
        for (G g : order) {
            if (g.outline == null) continue;
            BufferedImage cell = new BufferedImage(g.box.width, g.box.height, BufferedImage.TYPE_INT_ARGB);
            Graphics2D gr = cell.createGraphics();
            gr.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            gr.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY);
            gr.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE);
            gr.setColor(Color.WHITE);
            gr.translate(-g.box.x, -g.box.y);
            gr.fill(g.outline);
            if (stroke > 0) {                        // faux-bold: thicken strokes ~stroke/2 px each side
                gr.setStroke(new BasicStroke((float) stroke, BasicStroke.CAP_ROUND, BasicStroke.JOIN_ROUND));
                gr.draw(g.outline);
            }
            gr.dispose();
            for (int yy = 0; yy < g.box.height; yy++) for (int xx = 0; xx < g.box.width; xx++) {
                int a = (cell.getRGB(xx, yy) >>> 24) & 0xff;
                atlas.setRGB(g.x + xx, g.y + yy, (a << 24) | (a << 16) | (a << 8) | a);   // coverage in RGB and A
            }
        }
        String png = new File(outBase).getName() + ".png";
        ImageIO.write(atlas, "png", new File(outBase + ".png"));

        StringBuilder sb = new StringBuilder();
        sb.append(String.format("info face=\"%s\" size=%d bold=0 italic=0 charset=\"\" unicode=1 stretchH=100 smooth=1 aa=1 padding=0,0,0,0 spacing=1,1 outline=0\n", f.getPSName(), Math.round(size)));
        sb.append(String.format("common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0 alphaChnl=0 redChnl=4 greenChnl=4 blueChnl=4\n", lineHeight, base, texW, texH));
        sb.append(String.format("page id=0 file=\"%s\"\n", png));
        sb.append(String.format("chars count=%d\n", gs.size()));
        for (G g : gs) {
            int xoff = (g.outline == null) ? 0 : g.box.x + g.xoffAdj;
            int yoff = (g.outline == null) ? 0 : base + g.box.y;
            sb.append(String.format("char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d xadvance=%d page=0 chnl=15\n",
                g.cp, g.x, g.y, g.box.width, g.box.height, xoff, yoff, g.adv));
        }
        sb.append("kernings count=0\n");
        try (Writer w = new OutputStreamWriter(new FileOutputStream(outBase + ".fnt"), "UTF-8")) { w.write(sb.toString()); }
        long pix = 0; for (G g : gs) pix += (long) g.box.width * g.box.height;
        System.out.printf("%s: %d glyphs, texture %dx%d, base=%d lineHeight=%d, glyph px=%d (~%d KB @8bpp)%n",
            new File(outBase).getName(), gs.size(), texW, texH, base, lineHeight, pix, pix / 1024);
    }

    static boolean pack(List<G> order, int W, int H) {
        int x = 1, y = 1, rowH = 0;
        for (G g : order) {
            if (x + g.box.width + 1 > W) { x = 1; y += rowH + 1; rowH = 0; }
            if (y + g.box.height + 1 > H) return false;
            g.x = x; g.y = y;
            x += g.box.width + 1;
            rowH = Math.max(rowH, g.box.height);
        }
        return true;
    }

    static void svgpath(String ttf, float size, String text, float tracking) throws Exception {
        Font f = load(ttf, size);
        GlyphVector gv = f.createGlyphVector(FRC, text);
        for (int i = 0; i < gv.getNumGlyphs(); i++) {
            Point2D p = gv.getGlyphPosition(i);
            gv.setGlyphPosition(i, new Point2D.Float((float) p.getX() + i * tracking, (float) p.getY()));
        }
        Shape s = gv.getOutline();
        Rectangle2D b = s.getBounds2D();
        StringBuilder d = new StringBuilder();
        PathIterator it = s.getPathIterator(null);
        double[] c = new double[6];
        while (!it.isDone()) {
            int t = it.currentSegment(c);
            switch (t) {
                case PathIterator.SEG_MOVETO:  d.append(String.format(Locale.ROOT, "M%.2f %.2f", c[0], c[1])); break;
                case PathIterator.SEG_LINETO:  d.append(String.format(Locale.ROOT, "L%.2f %.2f", c[0], c[1])); break;
                case PathIterator.SEG_QUADTO:  d.append(String.format(Locale.ROOT, "Q%.2f %.2f %.2f %.2f", c[0], c[1], c[2], c[3])); break;
                case PathIterator.SEG_CUBICTO: d.append(String.format(Locale.ROOT, "C%.2f %.2f %.2f %.2f %.2f %.2f", c[0], c[1], c[2], c[3], c[4], c[5])); break;
                case PathIterator.SEG_CLOSE:   d.append("Z"); break;
            }
            it.next();
        }
        System.out.printf(Locale.ROOT, "BBOX %.2f %.2f %.2f %.2f%n", b.getX(), b.getY(), b.getWidth(), b.getHeight());
        System.out.println("PATH " + d);
    }
}
