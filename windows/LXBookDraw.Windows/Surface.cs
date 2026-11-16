using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Media;

namespace LXBookDrawWin;

/// Something to draw on: a PDF page or the screen. The plot is drawn by the same code (PlotPdf) on both,
/// so what you see while drawing is what the PDF and Lx Book show. Y is up, as in PDF.
public abstract class Surface
{
    public abstract void Save();
    public abstract void Restore();
    public abstract void Concat(double a, double b, double c, double d, double e, double f);
    public void Translate(double x, double y) => Concat(1, 0, 0, 1, x, y);
    public void Scale(double s) => Concat(s, 0, 0, s, 0, 0);
    public void Rotate(double r) { double cs = Math.Cos(r), sn = Math.Sin(r); Concat(cs, sn, -sn, cs, 0, 0); }
    /// How many points (or screen pixels) one unit of the current coordinate system is.
    public abstract double Units();
    public abstract void StrokeColor(Rgb c);
    public abstract void FillColor(Rgb c);
    public abstract void LineWidth(double w);
    public abstract void RoundJoins();
    public abstract void ClipRect(double x, double y, double w, double h);
    public abstract void Rect(double x, double y, double w, double h, bool fill = false, bool stroke = true);
    public abstract void Path(IList<(double X, double Y)> pts, bool closed = false, bool fill = false, bool stroke = true);
    public abstract void Segments(IEnumerable<((double X, double Y) A, (double X, double Y) B)> segs);
    public abstract void Ellipse(double x, double y, double w, double h, bool fill = false, bool stroke = true);
    /// Text whose line box has its bottom-left corner at (x, y).
    public abstract void Text(double x, double y, string s, double size, char font = 'R', Rgb? color = null);
}

/// Draws into a WPF DrawingContext. Coordinates are whatever the caller set up (millimetres, Y up, for the model).
public sealed class ScreenSurface : Surface
{
    readonly DrawingContext dc;
    (double a, double b, double c, double d, double e, double f) m;
    readonly Stack<((double, double, double, double, double, double) M, int Pushes)> stack = new();
    int pushes;
    Brush stroke = Brushes.Black, fill = Brushes.Black;
    double width = 1;
    static readonly Dictionary<(double, double, double), SolidColorBrush> brushes = new();
    static readonly Typeface Regular = new(new FontFamily("Arial"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    static readonly Typeface Bold = new(new FontFamily("Arial"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
    static readonly Typeface Italic = new(new FontFamily("Arial"), FontStyles.Italic, FontWeights.Normal, FontStretches.Normal);

    /// `scale` is how many screen pixels one unit is at the start (for the truss detail and line weights).
    public ScreenSurface(DrawingContext dc, double scale)
    {
        this.dc = dc;
        m = (scale, 0, 0, scale, 0, 0);
    }

    /// A tint drawn over everything: used for previews and locked layers.
    public Rgb? Override { get; set; }

    public static SolidColorBrush BrushOf(Rgb c)
    {
        var key = (Math.Round(c.R, 3), Math.Round(c.G, 3), Math.Round(c.B, 3));
        if (brushes.TryGetValue(key, out var b)) return b;
        b = new SolidColorBrush(Color.FromRgb((byte)Math.Clamp(c.R * 255, 0, 255), (byte)Math.Clamp(c.G * 255, 0, 255), (byte)Math.Clamp(c.B * 255, 0, 255)));
        b.Freeze();
        brushes[key] = b;
        return b;
    }

    public override void Save() { stack.Push((m, pushes)); pushes = 0; }

    public override void Restore()
    {
        for (int i = 0; i < pushes; i++) dc.Pop();
        if (stack.Count > 0) (m, pushes) = stack.Pop(); else pushes = 0;
    }

    /// Pops anything still pushed (call once at the end).
    public void Finish()
    {
        while (stack.Count > 0) Restore();
        for (int i = 0; i < pushes; i++) dc.Pop();
        pushes = 0;
    }

    public override void Concat(double a, double b, double c, double d, double e, double f)
    {
        var o = m;
        m = (a * o.a + b * o.c, a * o.b + b * o.d, c * o.a + d * o.c, c * o.b + d * o.d, e * o.a + f * o.c + o.e, e * o.b + f * o.d + o.f);
        dc.PushTransform(new MatrixTransform(a, b, c, d, e, f));
        pushes++;
    }

    public override double Units() => Math.Sqrt(m.a * m.a + m.b * m.b);
    public override void StrokeColor(Rgb c) => stroke = Override.HasValue ? BrushOf(Override.Value) : BrushOf(c);
    public override void FillColor(Rgb c) => fill = Override.HasValue && !(c.R > 0.97 && c.G > 0.97 && c.B > 0.97) ? BrushOf(Mix(c, Override.Value)) : BrushOf(c);
    static Rgb Mix(Rgb a, Rgb b) => new((a.R + b.R * 2) / 3, (a.G + b.G * 2) / 3, (a.B + b.B * 2) / 3);
    public override void LineWidth(double w) => width = Math.Max(w, 0);
    public override void RoundJoins() { }

    Pen PenNow()
    {
        var p = new Pen(stroke, width) { LineJoin = PenLineJoin.Round, StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        p.Freeze();
        return p;
    }

    public override void ClipRect(double x, double y, double w, double h)
    {
        dc.PushClip(new RectangleGeometry(Norm(x, y, w, h)));
        pushes++;
    }

    static Rect Norm(double x, double y, double w, double h)
    {
        if (w < 0) { x += w; w = -w; }
        if (h < 0) { y += h; h = -h; }
        return new Rect(x, y, w, h);
    }

    public override void Rect(double x, double y, double w, double h, bool fill = false, bool stroke = true) =>
        dc.DrawRectangle(fill ? this.fill : null, stroke ? PenNow() : null, Norm(x, y, w, h));

    public override void Path(IList<(double X, double Y)> pts, bool closed = false, bool fill = false, bool stroke = true)
    {
        if (pts.Count < 2) return;
        var g = new StreamGeometry();
        using (var c = g.Open())
        {
            c.BeginFigure(new Point(pts[0].X, pts[0].Y), fill, closed);
            for (int i = 1; i < pts.Count; i++) c.LineTo(new Point(pts[i].X, pts[i].Y), true, true);
        }
        g.Freeze();
        dc.DrawGeometry(fill ? this.fill : null, stroke ? PenNow() : null, g);
    }

    public override void Segments(IEnumerable<((double X, double Y) A, (double X, double Y) B)> segs)
    {
        var g = new StreamGeometry();
        using (var c = g.Open())
            foreach (var (a, b) in segs)
            {
                c.BeginFigure(new Point(a.X, a.Y), false, false);
                c.LineTo(new Point(b.X, b.Y), true, false);
            }
        g.Freeze();
        dc.DrawGeometry(null, PenNow(), g);
    }

    public override void Ellipse(double x, double y, double w, double h, bool fill = false, bool stroke = true) =>
        dc.DrawEllipse(fill ? this.fill : null, stroke ? PenNow() : null, new Point(x + w / 2, y + h / 2), Math.Abs(w / 2), Math.Abs(h / 2));

    public override void Text(double x, double y, string s, double size, char font = 'R', Rgb? color = null)
    {
        if (string.IsNullOrEmpty(s) || size <= 0) return;
        var face = font == 'B' ? Bold : font == 'I' ? Italic : Regular;
        var brush = BrushOf(Override ?? color ?? PlotPdf.Black);
        var ft = new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, face, size, brush, 1.0);
        // flip so the text reads upright in a Y-up frame; the PDF's baseline sits 0.94 of the size below the top of the line
        var top = y + PlotPdf.LineH * size;
        var shift = 0.94 * size - ft.Baseline;
        dc.PushTransform(new MatrixTransform(1, 0, 0, -1, x, top - shift));
        dc.DrawText(ft, new Point(0, 0));
        dc.Pop();
    }
}

public sealed class PdfSurface : Surface
{
    readonly StringBuilder ops = new();
    (double a, double b, double c, double d, double e, double f) m = (1, 0, 0, 1, 0, 0);
    readonly Stack<(double, double, double, double, double, double)> stack = new();

    static string N(double v)
    {
        var s = v.ToString("0.###", CultureInfo.InvariantCulture);
        return s == "-0" ? "0" : s;
    }

    void Op(string s) => ops.Append(s).Append('\n');
    public override void Save() { stack.Push(m); Op("q"); }
    public override void Restore() { if (stack.Count > 0) m = stack.Pop(); Op("Q"); }

    public override void Concat(double a, double b, double c, double d, double e, double f)
    {
        var o = m;
        m = (a * o.a + b * o.c, a * o.b + b * o.d, c * o.a + d * o.c, c * o.b + d * o.d, e * o.a + f * o.c + o.e, e * o.b + f * o.d + o.f);
        Op(string.Format(CultureInfo.InvariantCulture, "{0:F6} {1:F6} {2:F6} {3:F6} {4:F4} {5:F4} cm", a, b, c, d, e, f));
    }

    public override double Units() => Math.Sqrt(m.a * m.a + m.b * m.b);
    public override void StrokeColor(Rgb c) => Op($"{N(c.R)} {N(c.G)} {N(c.B)} RG");
    public override void FillColor(Rgb c) => Op($"{N(c.R)} {N(c.G)} {N(c.B)} rg");
    public override void LineWidth(double w) => Op($"{N(Math.Max(w, 0))} w");
    public override void RoundJoins() => Op("1 j");
    public override void ClipRect(double x, double y, double w, double h) => Op($"{N(x)} {N(y)} {N(w)} {N(h)} re W n");
    void Paint(bool fill, bool stroke) => Op(fill && stroke ? "B" : fill ? "f" : stroke ? "S" : "n");

    public override void Rect(double x, double y, double w, double h, bool fill = false, bool stroke = true)
    {
        Op($"{N(x)} {N(y)} {N(w)} {N(h)} re");
        Paint(fill, stroke);
    }

    public override void Path(IList<(double X, double Y)> pts, bool closed = false, bool fill = false, bool stroke = true)
    {
        if (pts.Count < 2) return;
        Op($"{N(pts[0].X)} {N(pts[0].Y)} m");
        for (int i = 1; i < pts.Count; i++) Op($"{N(pts[i].X)} {N(pts[i].Y)} l");
        if (closed) Op("h");
        Paint(fill, stroke);
    }

    public override void Segments(IEnumerable<((double X, double Y) A, (double X, double Y) B)> segs)
    {
        foreach (var (a, b) in segs)
        {
            Op($"{N(a.X)} {N(a.Y)} m");
            Op($"{N(b.X)} {N(b.Y)} l");
        }
        Op("S");
    }

    public override void Ellipse(double x, double y, double w, double h, bool fill = false, bool stroke = true)
    {
        const double k = 0.5522847498;
        double rx = w / 2, ry = h / 2, cx = x + rx, cy = y + ry;
        Op($"{N(cx + rx)} {N(cy)} m");
        Op($"{N(cx + rx)} {N(cy + k * ry)} {N(cx + k * rx)} {N(cy + ry)} {N(cx)} {N(cy + ry)} c");
        Op($"{N(cx - k * rx)} {N(cy + ry)} {N(cx - rx)} {N(cy + k * ry)} {N(cx - rx)} {N(cy)} c");
        Op($"{N(cx - rx)} {N(cy - k * ry)} {N(cx - k * rx)} {N(cy - ry)} {N(cx)} {N(cy - ry)} c");
        Op($"{N(cx + k * rx)} {N(cy - ry)} {N(cx + rx)} {N(cy - k * ry)} {N(cx + rx)} {N(cy)} c");
        Op("h");
        Paint(fill, stroke);
    }

    /// Text whose line box has its bottom-left corner at (x, y), as the Mac's draw(at:) does.
    public override void Text(double x, double y, string s, double size, char font = 'R', Rgb? color = null)
    {
        if (string.IsNullOrEmpty(s) || size <= 0) return;
        var sb = new StringBuilder();
        foreach (var b in PlotPdf.Enc(s))
        {
            if (b == (byte)'\\' || b == (byte)'(' || b == (byte)')') sb.Append('\\');
            sb.Append((char)b);
        }
        FillColor(color ?? PlotPdf.Black);
        var tag = font == 'B' ? "F2" : font == 'I' ? "F3" : "F1";
        Op($"BT /{tag} {N(size)} Tf {N(x)} {N(y + PlotPdf.Baseline * size)} Td ({sb}) Tj ET");
    }

    public byte[] Data() => Encoding.Latin1.GetBytes(ops.ToString());
}

