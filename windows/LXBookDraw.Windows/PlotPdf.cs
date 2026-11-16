using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;

namespace LXBookDrawWin;

// A line-for-line port of lxdraw_pdf.py (which mirrors the Mac app's renderer): turns a drawing into a PDF.
// It draws the same pages LX Book Draw makes on the Mac: one page per sheet, or one per scene.
// Keep the three in step: a change to how the Mac draws goes into lxdraw_pdf.py and into this file.

public readonly record struct Rgb(double R, double G, double B);

/// Small helpers for reading JSON the way the Python reads dicts: missing or wrong-typed values count as empty.
static class J
{
    public static JsonNode? G(JsonNode? n, string k) => n is JsonObject o && o.TryGetPropertyValue(k, out var v) ? v : null;

    public static bool Has(JsonNode? n, string k)
    {
        var v = G(n, k);
        if (v == null) return false;
        if (v is JsonValue jv)
        {
            if (jv.TryGetValue<bool>(out var b)) return b;
            if (jv.TryGetValue<string>(out var s)) return s.Length > 0;
            if (jv.TryGetValue<double>(out var d)) return d != 0;
        }
        if (v is JsonArray a) return a.Count > 0;
        if (v is JsonObject o) return o.Count > 0;
        return true;
    }

    public static string S(JsonNode? n, string k)
    {
        var v = G(n, k);
        return v is JsonValue jv && jv.TryGetValue<string>(out var s) ? s : "";
    }

    public static double D(JsonNode? n, string k, double def = 0)
    {
        var v = G(n, k);
        if (v is JsonValue jv)
        {
            if (jv.TryGetValue<double>(out var d)) return d;
            if (jv.TryGetValue<string>(out var s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var p)) return p;
        }
        return def;
    }

    public static bool IsTrue(JsonNode? n, string k) => G(n, k) is JsonValue jv && jv.TryGetValue<bool>(out var b) && b;
    public static bool IsFalse(JsonNode? n, string k) => G(n, k) is JsonValue jv && jv.TryGetValue<bool>(out var b) && !b;
    public static JsonArray A(JsonNode? n, string k) => G(n, k) as JsonArray ?? new JsonArray();
    public static IEnumerable<JsonObject> Objs(JsonNode? n, string k) => A(n, k).OfType<JsonObject>();

    /// Lx Book's values as text: whole numbers without ".0", booleans as nothing (Python's _txt).
    public static string Txt(JsonNode? v)
    {
        if (v is JsonValue jv)
        {
            if (jv.TryGetValue<bool>(out _)) return "";
            if (jv.TryGetValue<string>(out var s)) return s;
            if (jv.TryGetValue<double>(out var d))
                return d == Math.Round(d) ? ((long)d).ToString(CultureInfo.InvariantCulture) : d.ToString(CultureInfo.InvariantCulture);
        }
        return "";
    }

    public static string Key(JsonNode? v) => Txt(v).Trim().ToLowerInvariant();

    public static JsonObject Copy(JsonNode? n) => n is JsonObject o ? (JsonObject)o.DeepClone() : new JsonObject();
}

public static class PlotPdf
{
    public const double PtPerMM = 2.835;
    const double A3W = 1190.55, A3H = 841.89;
    const double MarginMM = 7.0, PanelMM = 76.0, NoticeMM = 0.0;

    static readonly Rgb Black = new(0, 0, 0), White = new(1, 1, 1), Red = new(0.90, 0.10, 0.10), Blue = new(0.15, 0.25, 0.90),
        Green = new(0.10, 0.65, 0.20), Grey = new(0.55, 0.55, 0.55), Purple = new(0.75, 0.35, 0.85);

    static readonly Dictionary<string, (string Name, double L, double W)> Truss = new()
    {
        ["lopro-2.5"] = ("Lopro Prerig 2.5m", 2500, 660), ["lopro-3"] = ("Lopro Prerig 3m", 3000, 660),
        ["mlt3-3"] = ("MLT Three 3m", 3000, 500), ["mlt3-1.2"] = ("MLT Three 1.2m", 1200, 500),
        ["tyler-gt-8"] = ("Tyler GT Prerig 8'", 2438, 762), ["tomcat-sp-3"] = ("Tomcat 20.5\" Spigotted 3m", 3000, 521),
        ["tomcat-bo-3"] = ("Tomcat 20.5\" Bolted 3m", 3000, 521), ["tomcat-bo-1"] = ("Tomcat 20.5\" Bolted 1m", 1000, 521),
    };
    static readonly string[] TrussOrder = { "lopro-2.5", "lopro-3", "mlt3-3", "mlt3-1.2", "tyler-gt-8", "tomcat-sp-3", "tomcat-bo-3", "tomcat-bo-1" };

    static JsonObject Col(Rgb c) => new() { ["r"] = c.R, ["g"] = c.G, ["b"] = c.B, ["a"] = 1 };

    static JsonObject Prim(string k, double a = 0, double b = 0, double c = 0, double d = 0, Rgb? fill = null, (double, double)[]? pts = null)
    {
        var p = new JsonObject { ["k"] = k, ["a"] = a, ["b"] = b, ["c"] = c, ["d"] = d, ["s"] = "" };
        var arr = new JsonArray();
        foreach (var (x, y) in pts ?? Array.Empty<(double, double)>()) arr.Add(new JsonObject { ["x"] = x, ["y"] = y });
        p["pts"] = arr;
        if (fill.HasValue) p["fill"] = Col(fill.Value);
        return p;
    }

    static JsonObject TypeDef(string id, string name, string mode, string category, double size, params JsonObject[] prims)
    {
        var arr = new JsonArray();
        foreach (var p in prims) arr.Add(p);
        return new JsonObject
        {
            ["id"] = id, ["manufacturer"] = "", ["name"] = name, ["mode"] = mode, ["channels"] = 0, ["category"] = category,
            ["width"] = size, ["depth"] = size, ["prims"] = arr
        };
    }

    static readonly List<JsonObject> BuiltIn = new()
    {
        TypeDef("generic", "Generic fixture", "", "fixture", 400, Prim("circle", 0, 0, 200, fill: White), Prim("line", -200, 0, 200, 0), Prim("line", 0, -200, 0, 200)),
        TypeDef("hoist-1000", "1000kg EXE D8+ 25m", "LX", "hoist", 320, Prim("circle", 0, 0, 160, fill: White), Prim("rect", -113, 0, 113, 113, fill: Red),
            Prim("rect", 0, -113, 113, 113, fill: Red), Prim("line", -160, 0, 160, 0), Prim("line", 0, -160, 0, 160), Prim("circle", 0, 0, 160)),
        TypeDef("hoist-500-dd", "500kg EXE D8+ DD 25m", "Subhung", "hoist", 300, Prim("poly", fill: White, pts: new[] { (-150.0, -130.0), (150.0, -130.0), (0.0, 150.0) }),
            Prim("line", 0, -130, 0, 150), Prim("rect", -40, -130, 80, 80, fill: Red)),
        TypeDef("hoist-2000", "2000kg Lodestar", "Video", "hoist", 320, Prim("rect", -160, -160, 320, 320, fill: White), Prim("rect", -160, 0, 160, 160, fill: Purple),
            Prim("rect", 0, -160, 160, 160, fill: Purple), Prim("rect", -160, -160, 320, 320)),
    };

    static readonly Dictionary<string, string[]> Tape = new()
    {
        ["white"] = new[] { "#F2F2EE" }, ["red"] = new[] { "#D32F2F" }, ["blue"] = new[] { "#1F5FD0" }, ["yellow"] = new[] { "#F7D417" },
        ["orange"] = new[] { "#F28C18" }, ["green"] = new[] { "#23984B" }, ["brown"] = new[] { "#7B4B2A" }, ["pink"] = new[] { "#F4A6C8" },
        ["purple"] = new[] { "#7A3DB8" }, ["black"] = new[] { "#1B1B1B" }, ["grey"] = new[] { "#8D939A" }, ["gray"] = new[] { "#8D939A" },
        ["flouro green"] = new[] { "#6CFF3B" }, ["fluoro green"] = new[] { "#6CFF3B" }, ["flouro pink"] = new[] { "#FF3EA5" },
        ["fluoro pink"] = new[] { "#FF3EA5" }, ["flouro orange"] = new[] { "#FF6B1A" }, ["fluoro orange"] = new[] { "#FF6B1A" },
        ["flouro yellow"] = new[] { "#E6FF2E" }, ["fluoro yellow"] = new[] { "#E6FF2E" }, ["earth"] = new[] { "#23984B", "#F7D417" },
        ["yellow/black hazard"] = new[] { "#F7D417", "#1B1B1B" }, ["white/red hazard"] = new[] { "#F2F2EE", "#D32F2F" },
        ["green/white hazard"] = new[] { "#23984B", "#F2F2EE" },
    };

    // Helvetica and Helvetica-Bold advance widths for characters 32 to 255 (WinAnsi), in 1/1000 of the font size.
    static readonly int[] WReg = { 278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 350, 556, 350, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000, 350, 611, 350, 350, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 350, 500, 667, 278, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 556, 537, 278, 333, 333, 365, 556, 834, 834, 834, 611, 667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, 556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278, 556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556, 500, 556, 500 };
    static readonly int[] WBold = { 278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584, 350, 556, 350, 278, 556, 500, 1000, 556, 556, 333, 1000, 667, 333, 1000, 350, 611, 350, 350, 278, 278, 500, 500, 350, 556, 1000, 333, 1000, 556, 333, 944, 350, 500, 667, 278, 333, 556, 556, 556, 556, 280, 556, 333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 611, 556, 278, 333, 333, 365, 556, 834, 834, 834, 611, 722, 722, 722, 722, 722, 722, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, 556, 556, 556, 556, 556, 556, 889, 556, 556, 556, 556, 556, 278, 278, 278, 278, 611, 611, 611, 611, 611, 611, 611, 584, 611, 611, 611, 611, 611, 556, 611, 556 };

    const double LineH = 1.19, Baseline = 0.25;
    static readonly Encoding Win1252;

    static PlotPdf()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        Win1252 = Encoding.GetEncoding(1252, EncoderFallback.ReplacementFallback, DecoderFallback.ReplacementFallback);
    }

    static byte[] Enc(string s) => Win1252.GetBytes(s ?? "");

    public static double TextWidth(string s, double size, char font = 'R')
    {
        var w = font == 'B' ? WBold : WReg;
        double total = 0;
        foreach (var ch in Enc(s)) if (ch >= 32) total += w[ch - 32];
        return total * size / 1000.0;
    }

    static (double W, double H) TextSize(string s, double size, char font = 'R') => (TextWidth(string.IsNullOrEmpty(s) ? " " : s, size, font), LineH * size);

    static string FmtNum(double v) => v == Math.Round(v) ? ((long)v).ToString(CultureInfo.InvariantCulture) : v.ToString("0.0", CultureInfo.InvariantCulture);

    static Rgb ToRgb(JsonNode? c, Rgb def)
    {
        if (c is not JsonObject) return def;
        return new Rgb(J.D(c, "r"), J.D(c, "g"), J.D(c, "b"));
    }

    static Rgb HexRgb(string? h)
    {
        h = (h ?? "").Trim().TrimStart('#');
        if (h.Length != 6 || !int.TryParse(h, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return Grey;
        return new Rgb(((v >> 16) & 255) / 255.0, ((v >> 8) & 255) / 255.0, (v & 255) / 255.0);
    }

    // ---------------------------------------------------------------- PDF writing

    sealed class Canvas
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
        public void Save() { stack.Push(m); Op("q"); }
        public void Restore() { if (stack.Count > 0) m = stack.Pop(); Op("Q"); }

        public void Concat(double a, double b, double c, double d, double e, double f)
        {
            var o = m;
            m = (a * o.a + b * o.c, a * o.b + b * o.d, c * o.a + d * o.c, c * o.b + d * o.d, e * o.a + f * o.c + o.e, e * o.b + f * o.d + o.f);
            Op(string.Format(CultureInfo.InvariantCulture, "{0:F6} {1:F6} {2:F6} {3:F6} {4:F4} {5:F4} cm", a, b, c, d, e, f));
        }

        public void Translate(double x, double y) => Concat(1, 0, 0, 1, x, y);
        public void Scale(double s) => Concat(s, 0, 0, s, 0, 0);
        public void Rotate(double r) { double cs = Math.Cos(r), sn = Math.Sin(r); Concat(cs, sn, -sn, cs, 0, 0); }
        public double Units() => Math.Sqrt(m.a * m.a + m.b * m.b);
        public void StrokeColor(Rgb c) => Op($"{N(c.R)} {N(c.G)} {N(c.B)} RG");
        public void FillColor(Rgb c) => Op($"{N(c.R)} {N(c.G)} {N(c.B)} rg");
        public void LineWidth(double w) => Op($"{N(Math.Max(w, 0))} w");
        public void RoundJoins() => Op("1 j");
        public void ClipRect(double x, double y, double w, double h) => Op($"{N(x)} {N(y)} {N(w)} {N(h)} re W n");
        void Paint(bool fill, bool stroke) => Op(fill && stroke ? "B" : fill ? "f" : stroke ? "S" : "n");

        public void Rect(double x, double y, double w, double h, bool fill = false, bool stroke = true)
        {
            Op($"{N(x)} {N(y)} {N(w)} {N(h)} re");
            Paint(fill, stroke);
        }

        public void Path(IList<(double X, double Y)> pts, bool closed = false, bool fill = false, bool stroke = true)
        {
            if (pts.Count < 2) return;
            Op($"{N(pts[0].X)} {N(pts[0].Y)} m");
            for (int i = 1; i < pts.Count; i++) Op($"{N(pts[i].X)} {N(pts[i].Y)} l");
            if (closed) Op("h");
            Paint(fill, stroke);
        }

        public void Segments(IEnumerable<((double X, double Y) A, (double X, double Y) B)> segs)
        {
            foreach (var (a, b) in segs)
            {
                Op($"{N(a.X)} {N(a.Y)} m");
                Op($"{N(b.X)} {N(b.Y)} l");
            }
            Op("S");
        }

        public void Ellipse(double x, double y, double w, double h, bool fill = false, bool stroke = true)
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
        public void Text(double x, double y, string s, double size, char font = 'R', Rgb? color = null)
        {
            if (string.IsNullOrEmpty(s) || size <= 0) return;
            var sb = new StringBuilder();
            foreach (var b in Enc(s))
            {
                if (b == (byte)'\\' || b == (byte)'(' || b == (byte)')') sb.Append('\\');
                sb.Append((char)b);
            }
            FillColor(color ?? Black);
            var tag = font == 'B' ? "F2" : font == 'I' ? "F3" : "F1";
            Op($"BT /{tag} {N(size)} Tf {N(x)} {N(y + Baseline * size)} Td ({sb}) Tj ET");
        }

        public byte[] Data() => Encoding.Latin1.GetBytes(ops.ToString());
    }

    static byte[] Zlib(byte[] data)
    {
        using var ms = new MemoryStream();
        using (var z = new ZLibStream(ms, CompressionLevel.Optimal, true)) z.Write(data, 0, data.Length);
        return ms.ToArray();
    }

    static byte[] BuildPdf(List<(double W, double H, Canvas C)> pages)
    {
        var objs = new List<byte[]> { Array.Empty<byte>(), Array.Empty<byte>() };
        int Add(byte[] body) { objs.Add(body); return objs.Count; }
        byte[] A(string s) => Encoding.Latin1.GetBytes(s);
        var fonts = new[] { ("F1", "Helvetica"), ("F2", "Helvetica-Bold"), ("F3", "Helvetica-Oblique") };
        var fontIds = new List<(string, int)>();
        foreach (var (tag, name) in fonts) fontIds.Add((tag, Add(A($"<< /Type /Font /Subtype /Type1 /BaseFont /{name} /Encoding /WinAnsiEncoding >>"))));
        var resources = "<< /Font << " + string.Join(" ", fontIds.Select(f => $"/{f.Item1} {f.Item2} 0 R")) + " >> >>";
        var kids = new List<int>();
        foreach (var (w, h, c) in pages)
        {
            var stream = Zlib(c.Data());
            var body = new List<byte>();
            body.AddRange(A($"<< /Length {stream.Length} /Filter /FlateDecode >>\nstream\n"));
            body.AddRange(stream);
            body.AddRange(A("\nendstream"));
            int content = Add(body.ToArray());
            kids.Add(Add(A(string.Format(CultureInfo.InvariantCulture,
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {0:F2} {1:F2}] /Resources {2} /Contents {3} 0 R >>", w, h, resources, content))));
        }
        objs[0] = A("<< /Type /Catalog /Pages 2 0 R >>");
        objs[1] = A($"<< /Type /Pages /Count {kids.Count} /Kids [{string.Join(" ", kids.Select(k => $"{k} 0 R"))}] >>");
        var outp = new List<byte>();
        outp.AddRange(A("%PDF-1.4\n"));
        outp.AddRange(new byte[] { 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A });
        var offsets = new List<int>();
        for (int i = 0; i < objs.Count; i++)
        {
            offsets.Add(outp.Count);
            outp.AddRange(A($"{i + 1} 0 obj\n"));
            outp.AddRange(objs[i]);
            outp.AddRange(A("\nendobj\n"));
        }
        int xref = outp.Count;
        var sb = new StringBuilder();
        sb.Append($"xref\n0 {objs.Count + 1}\n0000000000 65535 f \n");
        foreach (var off in offsets) sb.Append(off.ToString("D10", CultureInfo.InvariantCulture)).Append(" 00000 n \n");
        sb.Append($"trailer\n<< /Size {objs.Count + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        outp.AddRange(A(sb.ToString()));
        return outp.ToArray();
    }

    // ---------------------------------------------------------------- the drawing

    sealed class Doc
    {
        public readonly JsonObject D;
        public readonly List<JsonObject> Layers;
        public readonly HashSet<string> Visible;
        readonly Dictionary<string, JsonObject> layerById = new();
        public readonly List<JsonObject> Objects;
        readonly Dictionary<string, JsonObject> types = new();
        public readonly List<JsonObject> TypeOrder;
        public readonly double LabelSize, LabelGap;
        public readonly bool ShowLabels;
        public readonly JsonNode? Styles;
        public Dictionary<string, double> Shift = new();

        public Doc(JsonObject drawing, IEnumerable<string>? visible = null)
        {
            D = drawing;
            Layers = J.Objs(drawing, "layers").ToList();
            Visible = visible != null ? new HashSet<string>(visible) : new HashSet<string>(Layers.Where(l => !J.IsFalse(l, "visible")).Select(l => J.S(l, "id")));
            foreach (var l in Layers) layerById[J.S(l, "id")] = l;
            Objects = J.Objs(drawing, "objects").ToList();
            foreach (var t in BuiltIn) types[J.S(t, "id")] = t;
            foreach (var t in J.Objs(drawing, "fixtureTypes")) types[J.S(t, "id")] = t;
            TypeOrder = J.Objs(drawing, "fixtureTypes").Concat(BuiltIn).ToList();
            LabelSize = J.D(drawing, "labelSize") is var ls && ls != 0 ? ls : 130;
            var on = J.Objs(drawing, "labelParts").Where(p => J.Has(p, "on")).Select(p => J.D(p, "size")).ToList();
            LabelGap = on.Count > 0 && on.Min() > 0 ? on.Min() : LabelSize;
            ShowLabels = !J.IsFalse(drawing, "showLabels");
            Styles = J.G(drawing, "typeStyles");
        }

        public Doc WithLayers(IEnumerable<string> visible) => new(D, visible);

        public Rgb? LayerColor(JsonObject o)
        {
            if (layerById.TryGetValue(J.S(o, "layer"), out var l) && J.S(l, "colorBy") == "layer" && J.Has(l, "color"))
                return ToRgb(J.G(l, "color"), Black);
            return null;
        }

        public bool IsVisible(JsonObject o)
        {
            var layer = J.S(o, "layer");
            return !layerById.ContainsKey(layer) || Visible.Contains(layer);
        }

        public JsonObject FType(string id) => types.TryGetValue(id, out var t) ? t : BuiltIn[0];

        public List<JsonObject> HoistLabelParts()
        {
            var parts = J.Objs(D, "hoistLabelParts").ToList();
            if (parts.Count > 0) return parts;
            var s = LabelSize;
            return new[] { ("unit", true), ("chain", true), ("load", true), ("position", false), ("type", false), ("note", false) }
                .Select(p => new JsonObject { ["field"] = p.Item1, ["on"] = p.Item2, ["size"] = p.Item1 == "unit" ? s : s * 0.8 }).ToList();
        }

        public List<JsonObject> LabelParts()
        {
            var parts = J.Objs(D, "labelParts").ToList();
            if (parts.Count > 0) return parts;
            var s = LabelSize;
            return new[] { ("unit", true), ("patch", true), ("circuit", true), ("position", false), ("type", false), ("note", false) }
                .Select(p => new JsonObject { ["field"] = p.Item1, ["on"] = p.Item2, ["size"] = s }).ToList();
        }
    }

    static (double a, double b, double c, double d, double e, double f) Transform(JsonObject o)
    {
        var a = J.D(o, "rot") * Math.PI / 180;
        var pos = J.G(o, "pos");
        return (Math.Cos(a), Math.Sin(a), -Math.Sin(a), Math.Cos(a), J.D(pos, "x"), J.D(pos, "y"));
    }

    static (double X, double Y) Apply((double a, double b, double c, double d, double e, double f) m, double x, double y) =>
        (m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f);

    static (double W, double H) TagSize(JsonObject o)
    {
        var s = Math.Max(J.D(o, "textSize", 1), 1);
        var (nw, nh) = TextSize(J.S(o, "text") is var t && t.Length > 0 ? t : " ", s, 'B');
        return (Math.Max(nw + s * 0.8, s * 6.6), nh + s * 1.15);
    }

    static (double X, double Y, double W, double H) LocalBox(JsonObject o)
    {
        var k = J.S(o, "kind");
        if (k == "rect" || k == "ellipse") return (0, 0, J.D(o, "w"), J.D(o, "h"));
        if (k == "truss")
        {
            var t = Truss.TryGetValue(J.S(o, "typeID"), out var tt) ? tt : Truss["lopro-2.5"];
            return (0, -t.W / 2, t.L, t.W);
        }
        if (k == "fixture")
        {
            double w = J.D(o, "w"), h = J.D(o, "h");
            return (-w / 2, -h / 2, w, h);
        }
        if (k == "text")
        {
            var (w, h) = J.Has(o, "tag") ? TagSize(o) : TextSize(J.S(o, "text") is var t && t.Length > 0 ? t : " ", Math.Max(J.D(o, "textSize", 1), 1));
            return (0, 0, w, h);
        }
        return (0, 0, 0, 0);
    }

    static List<(double X, double Y)> Quad(JsonObject o)
    {
        var (x, y, w, h) = LocalBox(o);
        var m = Transform(o);
        return new() { Apply(m, x, y), Apply(m, x + w, y), Apply(m, x + w, y + h), Apply(m, x, y + h) };
    }

    static (double, double, double, double)? WorldBounds(JsonObject o)
    {
        var k = J.S(o, "kind");
        List<(double X, double Y)> pts;
        if (k == "line" || k == "polyline")
        {
            pts = J.Objs(o, "pts").Select(p => (J.D(p, "x"), J.D(p, "y"))).ToList();
            if (pts.Count == 0) return null;
        }
        else pts = Quad(o);
        return (pts.Min(p => p.X), pts.Min(p => p.Y), pts.Max(p => p.X), pts.Max(p => p.Y));
    }

    static (double, double, double, double)? Extents(Doc doc)
    {
        (double, double, double, double)? box = null;
        foreach (var o in doc.Objects)
        {
            if (!doc.IsVisible(o)) continue;
            var bb = WorldBounds(o);
            if (bb == null) continue;
            var b = bb.Value;
            if (J.S(o, "kind") == "fixture" && doc.ShowLabels)
                b = (b.Item1 - doc.LabelSize * 2, b.Item2 - doc.LabelSize * 4, b.Item3 + doc.LabelSize * 2, b.Item4 + doc.LabelSize * 4);
            box = box == null ? b : (Math.Min(box.Value.Item1, b.Item1), Math.Min(box.Value.Item2, b.Item2), Math.Max(box.Value.Item3, b.Item3), Math.Max(box.Value.Item4, b.Item4));
        }
        return box;
    }

    // ---------------------------------------------------------------- labels

    static List<(string Text, Rgb Color, char Font, double Size)> LabelLines(JsonObject o, Doc doc)
    {
        var outp = new List<(string, Rgb, char, double)>();
        var hoist = (J.S(doc.FType(J.S(o, "typeID")), "category") is var c && c.Length > 0 ? c : "fixture") == "hoist";
        var parts = hoist ? doc.HoistLabelParts() : doc.LabelParts();
        for (int i = parts.Count - 1; i >= 0; i--)
        {
            var part = parts[i];
            if (!J.Has(part, "on")) continue;
            var size = Math.Max(J.D(part, "size", 1), 1);
            switch (J.S(part, "field"))
            {
                case "unit": outp.Add((J.S(o, "unit"), Black, 'R', size)); break;
                case "patch":
                    var u = J.S(o, "universe");
                    var a = J.S(o, "address");
                    outp.Add((u.Length > 0 && a.Length > 0 ? u + "/" + a : u + a, Red, 'I', size));
                    break;
                case "circuit": outp.Add((J.S(o, "circuit"), Blue, 'R', size)); break;
                case "position": outp.Add((J.S(o, "position"), Green, 'R', size)); break;
                case "type": outp.Add((J.S(doc.FType(J.S(o, "typeID")), "name"), Grey, 'R', size)); break;
                case "note": outp.Add((J.S(o, "note"), Grey, 'I', size)); break;
                case "chain": outp.Add((J.S(o, "chain"), Blue, 'R', size)); break;
                case "load":
                    var load = J.S(o, "load").Trim();
                    if (double.TryParse(load, NumberStyles.Float, CultureInfo.InvariantCulture, out _)) load += " kg";
                    outp.Add((load, Red, 'I', size));
                    break;
            }
        }
        return outp;
    }

    static (double W, double H) BlockSize(JsonObject o, Doc doc)
    {
        double w = 0, h = 0;
        foreach (var (text, _, font, size) in LabelLines(o, doc))
        {
            if (string.IsNullOrEmpty(text)) continue;
            var (tw, th) = TextSize(text, size, font);
            w = Math.Max(w, tw);
            h += th * 0.95;
        }
        return (w, h);
    }

    static bool IsManual(JsonObject o) => J.D(o, "labelDX") != 0 || J.D(o, "labelDY") != 0 || J.IsTrue(o, "labelLevel");

    static List<(double X, double Y)> LabelQuad(JsonObject o, (double W, double H) block, double size, double shift)
    {
        var bs = J.D(o, "h") / 2 + size * 0.35;
        var half = block.W * 0.47;
        double dx = J.D(o, "labelDX"), dy = J.D(o, "labelDY");
        var m = Transform(o);
        if (J.IsTrue(o, "labelLevel"))
        {
            var (ax, ay) = Apply(m, 0, bs);
            double x = ax + dx, y = ay + dy;
            return new() { (x - half, y), (x + half, y), (x + half, y + block.H), (x - half, y + block.H) };
        }
        var y0 = bs + shift;
        var outp = new List<(double, double)>();
        foreach (var (px, py) in new[] { (-half, y0), (half, y0), (half, y0 + block.H), (-half, y0 + block.H) })
        {
            var (wx, wy) = Apply(m, px, py);
            outp.Add((wx + dx, wy + dy));
        }
        return outp;
    }

    static bool Overlap(List<(double X, double Y)> a, List<(double X, double Y)> b)
    {
        foreach (var shape in new[] { a, b })
        {
            int n = shape.Count;
            for (int i = 0; i < n; i++)
            {
                var p = shape[i];
                var q = shape[(i + 1) % n];
                double nx = -(q.Y - p.Y), ny = q.X - p.X;
                double amin = double.MaxValue, amax = double.MinValue, bmin = double.MaxValue, bmax = double.MinValue;
                foreach (var v in a) { var t = v.X * nx + v.Y * ny; amin = Math.Min(amin, t); amax = Math.Max(amax, t); }
                foreach (var v in b) { var t = v.X * nx + v.Y * ny; bmin = Math.Min(bmin, t); bmax = Math.Max(bmax, t); }
                if (amax <= bmin || bmax <= amin) return false;
            }
        }
        return true;
    }

    static (double, double, double, double) BBox(List<(double X, double Y)> q) => (q.Min(p => p.X), q.Min(p => p.Y), q.Max(p => p.X), q.Max(p => p.Y));

    static bool Near((double, double, double, double) b1, (double, double, double, double) b2) =>
        !(b1.Item3 <= b2.Item1 || b2.Item3 <= b1.Item1 || b1.Item4 <= b2.Item2 || b2.Item4 <= b1.Item2);

    /// Moves labels out of each other's way: the same rules as the Mac app.
    static Dictionary<string, double> LayoutLabels(Doc doc)
    {
        var outp = new Dictionary<string, double>();
        if (J.IsFalse(doc.D, "autoLabels") || !doc.ShowLabels) return outp;
        var size = doc.LabelGap;
        var fixtures = doc.Objects.Where(o => J.S(o, "kind") == "fixture" && doc.IsVisible(o)).ToList();
        var symbols = fixtures.Select(o => { var q = Quad(o); return (Id: J.S(o, "id"), Q: q, B: BBox(q)); }).ToList();
        var placed = new List<(List<(double X, double Y)> Q, (double, double, double, double) B)>();
        var pending = new List<(JsonObject O, (double W, double H) Block)>();
        var room = Math.Max(J.D(doc.D, "labelSpacing"), 0);
        foreach (var o in fixtures)
        {
            var block = BlockSize(o, doc);
            if (block.W <= 0) continue;
            block = (block.W + room, block.H + room);
            if (IsManual(o))
            {
                var q = LabelQuad(o, block, size, 0);
                placed.Add((q, BBox(q)));
            }
            else pending.Add((o, block));
        }
        pending.Sort((x, y) =>
        {
            int c = J.D(J.G(x.O, "pos"), "x").CompareTo(J.D(J.G(y.O, "pos"), "x"));
            return c != 0 ? c : J.D(J.G(x.O, "pos"), "y").CompareTo(J.D(J.G(y.O, "pos"), "y"));
        });
        foreach (var (o, block) in pending)
        {
            var bs = J.D(o, "h") / 2 + size * 0.35;
            var row = block.H + size * 0.15;
            var other = -(2 * bs + block.H);
            double chosen = 0;
            var id = J.S(o, "id");
            foreach (var c in new[] { 0, row, 2 * row, other, other - row, 3 * row })
            {
                var q = LabelQuad(o, block, size, c);
                var qb = BBox(q);
                if (placed.Any(p => Near(qb, p.B) && Overlap(p.Q, q))) continue;
                if (symbols.Any(s => s.Id != id && Near(qb, s.B) && Overlap(s.Q, q))) continue;
                chosen = c;
                break;
            }
            if (chosen != 0) outp[id] = chosen;
            var fq = LabelQuad(o, block, size, chosen);
            placed.Add((fq, BBox(fq)));
        }
        return outp;
    }

    // ---------------------------------------------------------------- objects

    static void DrawPrims(Canvas cv, JsonArray prims, double lw, Rgb? tint = null, Rgb? line = null)
    {
        Rgb? FillOf(JsonObject p)
        {
            if (!J.Has(p, "fill")) return null;
            var c = ToRgb(J.G(p, "fill"), Black);
            if (tint.HasValue && Math.Min(c.R, Math.Min(c.G, c.B)) > 0.92) return tint;
            return c;
        }
        cv.LineWidth(lw);
        cv.StrokeColor(line ?? Black);
        foreach (var p in prims.OfType<JsonObject>())
        {
            var k = J.S(p, "k");
            double a = J.D(p, "a"), b = J.D(p, "b"), c = J.D(p, "c"), d = J.D(p, "d");
            var f = FillOf(p);
            switch (k)
            {
                case "circle":
                    if (f.HasValue) cv.FillColor(f.Value);
                    cv.Ellipse(a - c, b - c, c * 2, c * 2, fill: f.HasValue);
                    break;
                case "rect":
                    if (f.HasValue) cv.FillColor(f.Value);
                    cv.Rect(a, b, c, d, fill: f.HasValue);
                    break;
                case "line":
                    cv.Segments(new[] { ((a, b), (c, d)) });
                    break;
                case "poly":
                    var pts = J.Objs(p, "pts").Select(q => (J.D(q, "x"), J.D(q, "y"))).ToList();
                    if (pts.Count < 2) break;
                    if (f.HasValue)
                    {
                        cv.FillColor(f.Value);
                        cv.Path(pts, closed: true, fill: true, stroke: false);
                    }
                    if (!J.Has(p, "bare")) cv.Path(pts, closed: !J.Has(p, "open"));
                    break;
                case "text":
                    var s = J.S(p, "s");
                    var (w, h) = TextSize(s, c, 'B');
                    cv.Text(a - w / 2, b - h / 2, s, c, 'B');
                    break;
            }
        }
    }

    static void DrawFixtureSymbol(Canvas cv, JsonObject ftype, Doc doc, double lw, Rgb? layerColor = null)
    {
        var style = J.G(doc.Styles, J.S(ftype, "id"));
        Rgb? tint = J.Has(style, "color") ? ToRgb(J.G(style, "color"), Black) : null;
        Rgb line = Black;
        if (layerColor.HasValue)
        {
            var c = layerColor.Value;
            tint = new Rgb(c.R + (1 - c.R) * 0.7, c.G + (1 - c.G) * 0.7, c.B + (1 - c.B) * 0.7);
            line = c;
        }
        DrawPrims(cv, J.A(ftype, "prims"), lw, tint, line);
        var label = J.S(style, "easyID");
        if (label.Length == 0) return;
        var side = Math.Max(110.0, Math.Min(J.D(ftype, "width"), J.D(ftype, "depth")) * 0.55);
        var (tw, th) = TextSize(label, side * 0.72, 'B');
        var bw = Math.Max(side, tw + side * 0.3);
        cv.FillColor(White);
        cv.StrokeColor(Black);
        cv.LineWidth(lw);
        cv.Rect(-bw / 2, -side / 2, bw, side, fill: true);
        cv.Text(-tw / 2, -th / 2, label, side * 0.72, 'B');
    }

    static void DrawTruss(Canvas cv, JsonObject o, double lw, Rgb color)
    {
        var t = Truss.TryGetValue(J.S(o, "typeID"), out var tt) ? tt : Truss["lopro-2.5"];
        double L = t.L, W = t.W;
        cv.StrokeColor(color);
        if (J.Has(o, "fill"))
        {
            var f = ToRgb(J.G(o, "fill"), Black);
            cv.FillColor(new Rgb(1 - (1 - f.R) * 0.35, 1 - (1 - f.G) * 0.35, 1 - (1 - f.B) * 0.35));
            cv.Rect(0, -W / 2, L, W, fill: true);
        }
        else cv.Rect(0, -W / 2, L, W);
        var detailed = cv.Units() * 30 >= 2.5;
        double chord = 50, brace = 30;
        var inset = Math.Min(chord, W * 0.12);
        var bays = Math.Max(2, (int)Math.Round(L / W, MidpointRounding.ToEven));
        var step = L / bays;
        cv.LineWidth(lw * 0.7);

        void Tube((double X, double Y) a, (double X, double Y) b, double dia)
        {
            double dx = b.X - a.X, dy = b.Y - a.Y, ln = Math.Sqrt(dx * dx + dy * dy);
            if (ln < 1) return;
            double nx = -dy / ln * dia / 2, ny = dx / ln * dia / 2;
            cv.FillColor(White);
            cv.Path(new List<(double, double)> { (a.X + nx, a.Y + ny), (b.X + nx, b.Y + ny), (b.X - nx, b.Y - ny), (a.X - nx, a.Y - ny) }, closed: true, fill: true);
        }

        if (detailed)
        {
            double top = W / 2 - chord / 2, bottom = -W / 2 + chord / 2;
            for (int i = 0; i < bays; i++)
            {
                double x0 = i * step, x1 = (i + 1) * step;
                var up = i % 2 == 0;
                Tube((x0, up ? bottom : top), (x1, up ? top : bottom), brace);
                if (i > 0) Tube((x0, bottom), (x0, top), brace);
            }
            Tube((chord / 2, bottom), (chord / 2, top), chord);
            Tube((L - chord / 2, bottom), (L - chord / 2, top), chord);
            Tube((0, top), (L, top), chord);
            Tube((0, bottom), (L, bottom), chord);
        }
        else
        {
            var segs = new List<((double, double), (double, double))> { ((0, W / 2 - inset), (L, W / 2 - inset)), ((0, -W / 2 + inset), (L, -W / 2 + inset)) };
            for (int i = 0; i < bays; i++)
            {
                double x0 = i * step, x1 = (i + 1) * step;
                if (i > 0) segs.Add(((x0, -W / 2), (x0, W / 2)));
                if (i % 2 == 0) segs.Add(((x0, -W / 2 + inset), (x1, W / 2 - inset)));
                else segs.Add(((x0, W / 2 - inset), (x1, -W / 2 + inset)));
            }
            cv.Segments(segs);
        }
    }

    static void DrawTag(Canvas cv, JsonObject o, Doc doc, double lw)
    {
        var s = Math.Max(J.D(o, "textSize", 1), 1);
        var (bw, bh) = TagSize(o);
        var band = s * 0.95;
        var key = J.S(o, "text").Trim().ToLowerInvariant();
        JsonObject? location = null;
        foreach (var l in J.Objs(doc.D, "locations"))
        {
            var sh = J.S(l, "short");
            if (J.S(l, "name").ToLowerInvariant() == key || (sh.Length > 0 && sh.ToLowerInvariant() == key)) { location = l; break; }
        }
        var tapes = J.Objs(location, "tapes").ToList();
        cv.FillColor(White);
        cv.Rect(0, 0, bw, bh, fill: true, stroke: false);
        if (tapes.Count == 0)
        {
            var note = location == null ? "not in Lx Book" : "no colours set";
            var (nw, nh) = TextSize(note, s * 0.36);
            cv.Text(bw / 2 - nw / 2, (band - nh) / 2, note, s * 0.36, 'R', Grey);
        }
        else
        {
            var w = bw / tapes.Count;
            for (int i = 0; i < tapes.Count; i++)
            {
                var tape = tapes[i];
                var a = HexRgb(J.S(tape, "a"));
                cv.FillColor(a);
                cv.Rect(i * w, 0, w, band, fill: true, stroke: false);
                if (J.Has(tape, "b"))
                {
                    cv.FillColor(HexRgb(J.S(tape, "b")));
                    cv.Rect(i * w + w / 2, 0, w / 2, band, fill: true, stroke: false);
                }
                var lum = 0.299 * a.R + 0.587 * a.G + 0.114 * a.B;
                var name = J.S(tape, "name").ToUpperInvariant();
                var (lw2, lh) = TextSize(name, s * 0.34, 'B');
                if (lw2 < w * 1.6) cv.Text(i * w + w / 2 - lw2 / 2, (band - lh) / 2, name, s * 0.34, 'B', lum > 0.6 ? Black : White);
                cv.StrokeColor(Black);
                cv.LineWidth(lw * 0.6);
                cv.Rect(i * w, 0, w, band);
            }
        }
        var nm = J.S(o, "text") is var t && t.Length > 0 ? t : " ";
        var (nw2, nh2) = TextSize(nm, s, 'B');
        cv.Text(bw / 2 - nw2 / 2, band + (bh - band - nh2) / 2, nm, s, 'B');
        cv.StrokeColor(Black);
        cv.LineWidth(lw * 1.4);
        cv.Rect(0, 0, bw, bh);
    }

    static void DrawLabels(Canvas cv, JsonObject o, Doc doc)
    {
        var lines = LabelLines(o, doc);
        var backed = !J.IsFalse(doc.D, "labelBackground");
        var size = doc.LabelGap;
        double dx = J.D(o, "labelDX"), dy = J.D(o, "labelDY");
        var moved = dx != 0 || dy != 0;
        var auto = IsManual(o) ? 0 : (doc.Shift.TryGetValue(J.S(o, "id"), out var sv) ? sv : 0);
        var a = -J.D(o, "rot") * Math.PI / 180;
        var h = J.D(o, "h");
        var ax = dx * Math.Cos(a) - dy * Math.Sin(a);
        var ay = h / 2 + size * 0.35 + auto + dx * Math.Sin(a) + dy * Math.Cos(a);

        cv.Save();
        cv.Translate(ax, ay);
        if (J.IsTrue(o, "labelLevel")) cv.Rotate(a);
        double y = 0;
        foreach (var (text, color, font, lsize) in lines)
        {
            if (string.IsNullOrEmpty(text)) continue;
            var (tw, th) = TextSize(text, lsize, font);
            if (backed)
            {
                cv.FillColor(White);
                cv.Rect(-tw / 2 - lsize * 0.08, y + th * 0.04, tw + lsize * 0.16, th * 0.9, fill: true, stroke: false);
            }
            cv.Text(-tw / 2, y, text, lsize, font, color);
            y += th * 0.95;
        }
        cv.Restore();

        if (auto != 0)
        {
            var start = auto > 0 ? h / 2 : -h / 2;
            var block = BlockSize(o, doc);
            var end = auto > 0 ? ay - size * 0.1 : ay + block.H + size * 0.1;
            cv.Save();
            cv.StrokeColor(Grey);
            cv.LineWidth(size * 0.03);
            cv.Segments(new[] { ((0.0, start), (0.0, end)) });
            cv.Restore();
        }

        if (moved && J.IsTrue(o, "labelArrow"))
        {
            var ln = Math.Sqrt(ax * ax + ay * ay);
            var reach = Math.Min(J.D(o, "w"), h) / 2;
            if (ln > reach + size)
            {
                double ux = ax / ln, uy = ay / ln;
                var tip = (ux * reach, uy * reach);
                var tail = (ax - ux * size * 0.3, ay - uy * size * 0.3);
                var head = size * 0.7;
                var segs = new List<((double, double), (double, double))> { (tail, tip) };
                foreach (var side in new[] { 0.42, -0.42 })
                {
                    var hx = ux * Math.Cos(side) - uy * Math.Sin(side);
                    var hy = ux * Math.Sin(side) + uy * Math.Cos(side);
                    segs.Add((tip, (tip.Item1 + hx * head, tip.Item2 + hy * head)));
                }
                cv.StrokeColor(Black);
                cv.Segments(segs);
            }
        }
    }

    static void DrawFollowSpot(Canvas cv, JsonObject o, Doc doc)
    {
        var r = Math.Max(70.0, doc.LabelGap * 0.6);
        cv.Save();
        cv.Translate(J.D(o, "w") / 2 + r * 0.9, -J.D(o, "h") / 2 + r * 0.2);
        cv.Rotate(-J.D(o, "rot") * Math.PI / 180);
        cv.FillColor(new Rgb(0.055, 0.647, 0.914));
        cv.Ellipse(-r, -r, r * 2, r * 2, fill: true, stroke: false);
        var (tw, th) = TextSize("FS", r * 0.85, 'B');
        cv.Text(-tw / 2, -th / 2, "FS", r * 0.85, 'B', White);
        cv.Restore();
    }

    static void DrawObject(Canvas cv, JsonObject o, Doc doc, double ptPerUnit)
    {
        cv.Save();
        var lw = Math.Max(0.6, J.D(o, "lineWeight", 0.25) * PtPerMM) / ptPerUnit;
        var byLayer = doc.LayerColor(o);
        cv.LineWidth(lw);
        cv.StrokeColor(byLayer ?? ToRgb(J.G(o, "stroke"), Black));
        cv.RoundJoins();
        var k = J.S(o, "kind");
        Rgb? fill = J.Has(o, "fill") ? ToRgb(J.G(o, "fill"), Black) : null;
        if (k == "line" || k == "polyline")
        {
            var pts = J.Objs(o, "pts").Select(p => (J.D(p, "x"), J.D(p, "y"))).ToList();
            var closed = J.Has(o, "closed");
            if (closed && fill.HasValue) cv.FillColor(fill.Value);
            cv.Path(pts, closed: closed, fill: closed && fill.HasValue);
        }
        else
        {
            var t = Transform(o);
            cv.Concat(t.a, t.b, t.c, t.d, t.e, t.f);
            double w = J.D(o, "w"), h = J.D(o, "h");
            switch (k)
            {
                case "rect":
                    if (fill.HasValue) cv.FillColor(fill.Value);
                    cv.Rect(0, 0, w, h, fill: fill.HasValue);
                    break;
                case "ellipse":
                    if (fill.HasValue) cv.FillColor(fill.Value);
                    cv.Ellipse(0, 0, w, h, fill: fill.HasValue);
                    break;
                case "text":
                    if (J.Has(o, "tag")) DrawTag(cv, o, doc, lw);
                    else cv.Text(0, 0, J.S(o, "text"), Math.Max(J.D(o, "textSize", 1), 1), 'R', ToRgb(J.G(o, "stroke"), Black));
                    break;
                case "truss":
                    DrawTruss(cv, o, lw, byLayer ?? Black);
                    break;
                case "fixture":
                    DrawFixtureSymbol(cv, doc.FType(J.S(o, "typeID")), doc, lw, byLayer);
                    if (J.IsTrue(o, "fs")) DrawFollowSpot(cv, o, doc);
                    if (doc.ShowLabels) DrawLabels(cv, o, doc);
                    break;
            }
        }
        cv.Restore();
    }

    static void DrawModel(Canvas cv, Doc doc, double ptPerUnit)
    {
        doc.Shift = LayoutLabels(doc);
        foreach (var o in doc.Objects) if (doc.IsVisible(o)) DrawObject(cv, o, doc, ptPerUnit);
    }

    // ---------------------------------------------------------------- page furniture (in points)

    static List<List<(string Word, char Font)>> Wrap(List<(string Text, char Font)> runs, double width, double size)
    {
        var words = new List<(string, char)>();
        foreach (var (text, font) in runs) foreach (var w in text.Split(' ')) if (w.Length > 0) words.Add((w, font));
        var lines = new List<List<(string, char)>>();
        var cur = new List<(string, char)>();
        double curW = 0;
        foreach (var (w, font) in words)
        {
            var ww = TextWidth(w, size, font);
            var gap = cur.Count > 0 ? TextWidth(" ", size, font) : 0;
            if (cur.Count > 0 && curW + gap + ww > width)
            {
                lines.Add(cur);
                cur = new List<(string, char)>();
                curW = 0;
                gap = 0;
            }
            cur.Add((w, font));
            curW += gap + ww;
        }
        if (cur.Count > 0) lines.Add(cur);
        return lines;
    }

    static double DrawNotice(Canvas cv, JsonObject drawing, double x, double bottom, double width, string showName, string now, string? viewerLink)
    {
        const double size = 5.6;
        var linked = J.S(J.G(drawing, "lxBook"), "showName") is var sn && sn.Length > 0 ? sn : showName;
        var runs = new List<(string, char)>();
        if (linked.Length > 0)
        {
            runs.Add(($"This plot was generated automatically by LX Book Draw from the Lx Book show \"{linked}\" on {now}.", 'R'));
            runs.Add(("Fixture numbers, DMX addresses and power (circuits) come straight from Lx Book and are correct as of that time.", 'B'));
        }
        else
        {
            runs.Add(($"This plot was generated automatically by LX Book Draw on {now}.", 'R'));
            runs.Add(("This drawing is not linked to Lx Book, so check fixture numbers, DMX addresses and power (circuits) against the show paperwork.", 'B'));
        }
        runs.Add(("The physical placement of truss and fixtures is indicative only and may not match the lighting designer's plot; " +
                  "where they differ, the designer's plot is correct. Not to scale unless a scale is stated. Not for rigging, weight " +
                  "loading or structural use: rigging points, trim heights and loads must come from the approved rigging plot.", 'R'));
        var link = (string.IsNullOrEmpty(viewerLink) ? J.S(drawing, "viewerLink") : viewerLink).Trim();
        var modules = link.Length > 0 ? Qr.Modules(link) : null;
        const double side = 56;
        double tx = x, tw = width;
        if (modules != null) { tx = x + side + 6; tw = width - side - 6; }
        var lines = Wrap(runs, tw, size);
        var lineH = size * LineH;
        var height = Math.Max(lines.Count * lineH, modules != null ? side + 18 : 0);
        if (modules != null)
        {
            double bx = x, by = bottom + height - side, m = side / modules.Length;
            cv.FillColor(Black);
            for (int r = 0; r < modules.Length; r++)
                for (int c = 0; c < modules[r].Length; c++)
                    if (modules[r][c]) cv.Rect(bx + c * m, by + side - (r + 1) * m, m + 0.05, m + 0.05, fill: true, stroke: false);
            cv.Text(x, by - 8, "Scan to view this", 5.5, 'B');
            cv.Text(x, by - 15, "show in Lx Book", 5.5, 'B');
        }
        var ly = bottom + height - lineH;
        foreach (var line in lines)
        {
            var lx = tx;
            foreach (var (word, font) in line)
            {
                cv.Text(lx, ly, word, size, font);
                lx += TextWidth(word + " ", size, font);
            }
            ly -= lineH;
        }
        return height;
    }

    static void DrawPanel(Canvas cv, Doc doc, (double X, double Y, double W, double H) panel, string scaleText, string title,
                          string showName, string now, string? viewerLink)
    {
        var (px, py, pw, ph) = panel;
        double left = px + 10, right = px + pw - 10, y = py + ph - 22;
        var info = J.G(doc.D, "info");
        void Txt(string s, double x, double yy, double size, bool bold = false, Rgb? color = null) => cv.Text(x, yy, s, size, bold ? 'B' : 'R', color ?? Black);
        void TxtRight(string s, double x, double yy, double size, bool bold = false) => cv.Text(x - TextWidth(s, size, bold ? 'B' : 'R'), yy, s, size, bold ? 'B' : 'R');

        var counts = new Dictionary<string, int>();
        foreach (var o in doc.Objects)
            if (J.S(o, "kind") == "fixture" && doc.IsVisible(o)) counts[J.S(o, "typeID")] = counts.GetValueOrDefault(J.S(o, "typeID")) + 1;
        var used = doc.TypeOrder.Where(t => counts.ContainsKey(J.S(t, "id"))).ToList();
        foreach (var category in new[] { "fixture", "hoist" })
        {
            var group = used.Where(t => (J.S(t, "category") is var c && c.Length > 0 ? c : "fixture") == category).ToList();
            if (group.Count == 0) continue;
            Txt(category == "fixture" ? "FIXTURES" : "HOISTS", left, y, 10, true);
            y -= 8;
            foreach (var f in group)
            {
                y -= 34;
                cv.Save();
                cv.Translate(left + 17, y + 15);
                var k = 28.0 / Math.Max(Math.Max(J.D(f, "width"), J.D(f, "depth")), 1);
                cv.Scale(k);
                DrawFixtureSymbol(cv, f, doc, 0.6 / k);
                cv.Restore();
                var display = (J.S(f, "manufacturer").Trim() + " " + J.S(f, "name")).Trim();
                Txt(display.ToUpperInvariant(), left + 42, y + 15, 7.5, true);
                var sub = J.S(f, "mode");
                var ch = (int)J.D(f, "channels");
                if (ch > 0) sub += sub.Length == 0 ? $"{ch}ch" : $" ({ch}ch)";
                Txt(sub, left + 42, y + 5, 6.5, false, new Rgb(0.33, 0.33, 0.33));
                TxtRight(counts.GetValueOrDefault(J.S(f, "id")).ToString(CultureInfo.InvariantCulture), right, y + 10, 9, true);
            }
            y -= 16;
        }

        var tcounts = new Dictionary<string, int>();
        foreach (var o in doc.Objects)
        {
            if (J.S(o, "kind") != "truss" || !doc.IsVisible(o)) continue;
            var tid = Truss.ContainsKey(J.S(o, "typeID")) ? J.S(o, "typeID") : "lopro-2.5";
            tcounts[tid] = tcounts.GetValueOrDefault(tid) + 1;
        }
        if (tcounts.Count > 0)
        {
            Txt("TRUSS", left, y, 10, true);
            y -= 4;
            foreach (var tid in TrussOrder)
            {
                if (!tcounts.ContainsKey(tid)) continue;
                y -= 13;
                Txt(Truss[tid].Name.ToUpperInvariant(), left, y, 7.5);
                TxtRight(tcounts[tid].ToString(CultureInfo.InvariantCulture), right, y, 9, true);
            }
        }

        var rows = new[] { ("SCALE", scaleText), ("DATE", J.S(info, "date")), ("DRAWN BY", J.S(info, "drawnBy")), ("VENUE", J.S(info, "venue")),
                           ("LIGHTING DESIGNER", J.S(info, "designer")), ("SHOW", J.S(info, "show")) };
        var by = py;
        cv.StrokeColor(Black);
        cv.LineWidth(0.5);
        Txt((title ?? "").ToUpperInvariant(), left, by + 6, 9, true);
        cv.Rect(px, by, pw, 22);
        by += 22;
        cv.FillColor(Red);
        cv.Rect(px, by, pw, 34, fill: true);
        var version = J.S(info, "version");
        var (vw, vh) = TextSize(version, 22);
        cv.Text(px + pw / 2 - vw / 2, by + 17 - vh / 2, version, 22, 'R', White);
        by += 34;
        foreach (var (label, value) in rows)
        {
            cv.StrokeColor(Black);
            cv.Rect(px, by, pw, 18);
            Txt(label, left, by + 5, 6, false, new Rgb(0.33, 0.33, 0.33));
            Txt(value.ToUpperInvariant(), left + 78, by + 5, 7);
            by += 18;
        }
        var show = J.S(info, "show");
        if (show.Length > 0)
        {
            double nameSize = 16;
            while (TextWidth(show, nameSize, 'B') > pw - 16 && nameSize > 7) nameSize -= 1;
            var (sw, sh) = TextSize(show, nameSize, 'B');
            Txt(show, px + pw / 2 - sw / 2, by + 10, nameSize, true);
            by += 10 + sh + 6;
        }
        else by += 6;
        DrawNotice(cv, doc.D, px + 8, by, pw - 16, showName, now, viewerLink);
    }

    // ---------------------------------------------------------------- pages

    static (double, double, Canvas) SheetPage(JsonObject drawing, JsonObject sheet, string showName, string now, string? viewerLink)
    {
        var k = PtPerMM;
        double sw = J.D(sheet, "w", 420), sh = J.D(sheet, "h", 297);
        if (sw == 0) sw = 420;
        if (sh == 0) sh = 297;
        var cv = new Canvas();
        cv.Save();
        cv.Scale(k);
        var bse = new Doc(drawing);
        var shown = new HashSet<string>();
        var viewports = J.Objs(sheet, "viewports").ToList();
        foreach (var v in viewports)
        {
            double vx = J.D(v, "x"), vy = J.D(v, "y"), vw = J.D(v, "w"), vh = J.D(v, "h"), scale = J.D(v, "scale");
            if (vw <= 0 || vh <= 0 || scale <= 0) continue;
            var doc = J.G(v, "layers") is JsonArray la ? bse.WithLayers(la.Select(n => J.Txt(n))) : bse;
            shown.UnionWith(doc.Visible);
            var s = 1.0 / scale;
            double cx0 = Math.Max(vx, 0), cy0 = Math.Max(vy, 0), cx1 = Math.Min(vx + vw, sw), cy1 = Math.Min(vy + vh, sh);
            if (cx1 > cx0 && cy1 > cy0)
            {
                cv.Save();
                cv.ClipRect(cx0, cy0, cx1 - cx0, cy1 - cy0);
                cv.Translate(vx + vw / 2, vy + vh / 2);
                cv.Scale(s);
                cv.Translate(-J.D(v, "cx"), -J.D(v, "cy"));
                DrawModel(cv, doc, k * s);
                cv.Restore();
            }
            if (!J.IsFalse(v, "frame"))
            {
                cv.StrokeColor(Black);
                cv.LineWidth(0.5 / k);
                cv.Rect(vx, vy, vw, vh);
            }
        }
        foreach (var o in J.Objs(sheet, "objects")) DrawObject(cv, o, bse, k);
        cv.Restore();

        var m = MarginMM * k;
        double fx = m, fy = m, fw = sw * k - 2 * m, fh = sh * k - 2 * m;
        cv.StrokeColor(Black);
        cv.LineWidth(1);
        cv.Rect(fx, fy, fw, fh);
        var hasPanel = !J.IsFalse(sheet, "panel");
        var pw = hasPanel ? PanelMM * k : 0;
        if (hasPanel)
        {
            cv.FillColor(White);
            cv.StrokeColor(Black);
            cv.LineWidth(1);
            cv.Rect(fx + fw - pw, fy, pw, fh, fill: true);
            var keyDoc = viewports.Count > 0 ? bse.WithLayers(shown) : bse;
            var scales = viewports.Select(v => J.D(v, "scale")).Distinct().ToList();
            var scaleText = scales.Count == 1 ? "1:" + FmtNum(Math.Round(scales[0], MidpointRounding.ToEven)) : "As shown";
            var title = J.S(J.G(drawing, "info"), "drawingTitle");
            title = title.Length == 0 ? J.S(sheet, "name") : title + " - " + J.S(sheet, "name");
            DrawPanel(cv, keyDoc, (fx + fw - pw, fy, pw, fh), scaleText, title, showName, now, viewerLink);
        }
        return (sw * k, sh * k, cv);
    }

    static (double, double, Canvas) ClassicPage(JsonObject drawing, IEnumerable<string>? visible, string title, string showName, string now, string? viewerLink)
    {
        double w = A3W, h = A3H;
        var cv = new Canvas();
        var doc = new Doc(drawing, visible);
        double fx = 20, fy = 20, fw = w - 40, fh = h - 40, pw = 215;
        var nh = NoticeMM * PtPerMM;
        double ax = fx + 14, ay = fy + 14, aw = fw - pw - 28, ah = fh - nh - 28;
        cv.StrokeColor(Black);
        cv.LineWidth(1);
        cv.Rect(fx, fy, fw, fh);
        cv.Rect(fx + fw - pw, fy, pw, fh);
        var e = Extents(doc);
        var ext = e == null || e.Value.Item3 - e.Value.Item1 < 1 || e.Value.Item4 - e.Value.Item2 < 1 ? (0.0, 0.0, 10000.0, 7000.0) : e.Value;
        var s = Math.Min(aw / (ext.Item3 - ext.Item1), ah / (ext.Item4 - ext.Item2));
        cv.Save();
        cv.ClipRect(ax, ay, aw, ah);
        cv.Translate(ax + aw / 2, ay + ah / 2);
        cv.Scale(s);
        cv.Translate(-(ext.Item1 + ext.Item3) / 2, -(ext.Item2 + ext.Item4) / 2);
        DrawModel(cv, doc, s);
        cv.Restore();
        DrawPanel(cv, doc, (fx + fw - pw, fy, pw, fh), "Fit to page, about 1:" + ((int)Math.Round(PtPerMM / s, MidpointRounding.ToEven)).ToString(CultureInfo.InvariantCulture),
                  title, showName, now, viewerLink);
        return (w, h, cv);
    }

    /// The PDF for a drawing. With `state` (Lx Book's show), fixtures take their data from Lx Book first.
    public static byte[] Render(JsonObject source, JsonNode? state = null, string showName = "", string now = "", string? viewerLink = null)
    {
        var drawing = (JsonObject)source.DeepClone();
        if (state != null) ApplyState(drawing, state);
        var pages = new List<(double, double, Canvas)>();
        var sheets = J.Objs(drawing, "sheets").ToList();
        var kept = sheets.Where(s => !J.IsFalse(s, "lxBook")).ToList();
        if (kept.Count > 0) sheets = kept;
        var scenes = J.Objs(drawing, "scenes").ToList();
        var baseTitle = J.S(J.G(drawing, "info"), "drawingTitle");
        if (sheets.Count > 0)
            foreach (var sheet in sheets) pages.Add(SheetPage(drawing, sheet, showName, now, viewerLink));
        else if (scenes.Count > 0)
            foreach (var scene in scenes)
                pages.Add(ClassicPage(drawing, J.A(scene, "visibleLayers").Select(n => J.Txt(n)), baseTitle + " - " + J.S(scene, "name"), showName, now, viewerLink));
        else pages.Add(ClassicPage(drawing, null, baseTitle, showName, now, viewerLink));
        return BuildPdf(pages);
    }

    /// The names of the pages Render makes, in order (sheet names, or scene names).
    public static List<string> PageNames(JsonObject drawing)
    {
        var sheets = J.Objs(drawing, "sheets").ToList();
        var kept = sheets.Where(s => !J.IsFalse(s, "lxBook")).ToList();
        if (kept.Count > 0) sheets = kept;
        if (sheets.Count > 0) return sheets.Select(s => J.S(s, "name") is var n && n.Length > 0 ? n : "Sheet").ToList();
        var scenes = J.Objs(drawing, "scenes").ToList();
        if (scenes.Count > 0) return scenes.Select(s => J.S(s, "name")).ToList();
        return new List<string> { "Plot" };
    }

    // ---------------------------------------------------------------- Lx Book's data

    static (string, string) Patch(JsonObject row)
    {
        var patch = J.Txt(J.G(row, "patch")).Trim();
        var parts = new List<string>();
        var cur = "";
        foreach (var ch in patch)
        {
            if (char.IsDigit(ch)) cur += ch;
            else
            {
                if (cur.Length > 0) parts.Add(cur);
                cur = "";
            }
        }
        if (cur.Length > 0) parts.Add(cur);
        var only = patch.All(ch => char.IsDigit(ch) || "./:- ".Contains(ch));
        if (parts.Count == 2 && only)
            return (long.Parse(parts[0], CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture),
                    long.Parse(parts[1], CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture));
        return ("", patch);
    }

    /// Brings the drawing's fixtures and location tags into line with Lx Book's show state. Lx Book's values win.
    public static void ApplyState(JsonObject drawing, JsonNode state)
    {
        var rows = new Dictionary<string, JsonObject>();
        foreach (var f in J.Objs(state, "fixtures"))
        {
            var id = J.Txt(J.G(f, "_id"));
            if (id.Length > 0) rows[id] = f;
        }
        var ways = new Dictionary<string, List<string>>();
        foreach (var m in J.Objs(state, "multis"))
        {
            var name = J.Txt(J.G(m, "name"));
            var list = J.A(m, "ways");
            for (int n = 0; n < list.Count; n++)
                foreach (var u in J.A(list[n], "units"))
                {
                    var k = J.Key(u);
                    if (k.Length == 0) continue;
                    if (!ways.TryGetValue(k, out var l)) ways[k] = l = new List<string>();
                    l.Add($"{name}-{n + 1}");
                }
        }
        var custom = new Dictionary<string, JsonObject>();
        foreach (var c in J.Objs(J.G(state, "settings"), "customColours"))
        {
            string name = J.Txt(J.G(c, "name")), a = J.Txt(J.G(c, "a")), b = J.Txt(J.G(c, "b"));
            if (name.Length > 0 && a.Length > 0) custom[name.ToLowerInvariant()] = new JsonObject { ["name"] = name, ["a"] = a, ["b"] = b.Length > 0 ? b : null };
        }
        var locations = new JsonArray();
        var locList = new List<JsonObject>();
        foreach (var l in J.Objs(state, "locations"))
        {
            var tapes = new JsonArray();
            foreach (var key in new[] { "c1", "c2", "c3" })
            {
                var name = J.Txt(J.G(l, key)).Trim();
                if (name.Length == 0) continue;
                var lower = name.ToLowerInvariant();
                if (Tape.TryGetValue(lower, out var known))
                    tapes.Add(new JsonObject { ["name"] = name, ["a"] = known[0], ["b"] = known.Length > 1 ? known[1] : null });
                else if (custom.TryGetValue(lower, out var cc)) tapes.Add(cc.DeepClone());
                else tapes.Add(new JsonObject { ["name"] = name, ["a"] = "#8D939A", ["b"] = null });
            }
            var loc = new JsonObject { ["id"] = J.Txt(J.G(l, "_id")), ["name"] = J.Txt(J.G(l, "name")), ["short"] = J.Txt(J.G(l, "short")), ["tapes"] = tapes };
            locList.Add(loc);
            locations.Add(loc);
        }
        drawing["locations"] = locations;

        var objects = J.Objs(drawing, "objects").ToList();
        foreach (var o in objects)
        {
            if (J.S(o, "kind") != "text" || !J.Has(o, "tag")) continue;
            var name = J.S(o, "text").Trim().ToLowerInvariant();
            var lx = J.S(o, "lxID");
            var hit = lx.Length > 0 ? locList.FirstOrDefault(l => J.S(l, "id") == lx) : null;
            if (hit != null)
            {
                if (J.S(hit, "name").Length > 0) o["text"] = J.S(hit, "name");
            }
            else
            {
                hit = locList.FirstOrDefault(l => J.S(l, "name").ToLowerInvariant() == name || (J.S(l, "short").Length > 0 && J.S(l, "short").ToLowerInvariant() == name));
                if (hit != null) o["lxID"] = J.S(hit, "id");
            }
        }

        var motors = new Dictionary<string, JsonObject>();
        foreach (var m in J.Objs(state, "motors"))
        {
            var k = J.Key(J.G(m, "mid"));
            if (k.Length > 0 && !motors.ContainsKey(k)) motors[k] = m;
        }
        var types = new Dictionary<string, JsonObject>();
        foreach (var t in BuiltIn) types[J.S(t, "id")] = t;
        foreach (var t in J.Objs(drawing, "fixtureTypes")) types[J.S(t, "id")] = t;
        string Category(JsonObject o) => J.S(types.TryGetValue(J.S(o, "typeID"), out var t) ? t : BuiltIn[0], "category") is var c && c.Length > 0 ? c : "fixture";
        var taken = new HashSet<string>(objects.Select(o => J.S(o, "lxID")).Where(s => s.Length > 0));
        var free = new Dictionary<string, string>();
        foreach (var (id, row) in rows)
        {
            if (taken.Contains(id)) continue;
            var k = J.Key(J.G(row, "fid"));
            if (k.Length > 0) free[k] = id;
        }
        foreach (var o in objects)
        {
            if (J.S(o, "kind") != "fixture") continue;
            if (Category(o) == "hoist")
            {
                if (motors.TryGetValue(J.Key(J.G(o, "unit")), out var m))
                {
                    o["lxMotor"] = J.Txt(J.G(m, "_id"));
                    o["position"] = J.Txt(J.G(m, "location"));
                    o["note"] = J.Txt(J.G(m, "notes"));
                    var chain = J.Txt(J.G(m, "chain"));
                    var load = J.Txt(J.G(m, "weight"));
                    o["chain"] = chain.Length > 0 ? chain : null;
                    o["load"] = load.Length > 0 ? load : null;
                }
                continue;
            }
            if (J.S(o, "lxID").Length == 0)
            {
                var k = J.Key(J.G(o, "unit"));
                if (k.Length > 0 && free.TryGetValue(k, out var fid))
                {
                    o["lxID"] = fid;
                    free.Remove(k);
                }
            }
            if (!rows.TryGetValue(J.S(o, "lxID"), out var row)) continue;
            o["unit"] = J.Txt(J.G(row, "fid")).Trim();
            var (u, a) = Patch(row);
            o["universe"] = u;
            o["address"] = a;
            o["position"] = J.Txt(J.G(row, "pos"));
            o["note"] = J.Txt(J.G(row, "notes"));
            if (ways.TryGetValue(J.Key(J.G(row, "fid")), out var w)) o["circuit"] = string.Join(", ", w);
            if (J.Has(row, "fs")) o["fs"] = true;
            else o.Remove("fs");
        }
    }

    // ---------------------------------------------------------------- the drawing kept inside the show

    static readonly string[] MetaKeys = { "info", "labelSize", "labelParts", "hoistLabelParts", "labelSpacing", "labelBackground", "autoLabels",
                                          "showLabels", "gridSize", "snapGrid", "viewerLink", "nextUnit", "activeScene", "formatVersion" };
    static readonly string[] LxFields = { "unit", "universe", "address", "position", "note", "circuit" };

    /// Builds the drawing from a show's draw rows and the symbol library (Python's join_drawing).
    public static JsonObject JoinDrawing(JsonNode state, Dictionary<string, JsonObject>? symbols = null)
    {
        symbols ??= new();
        var meta = J.Objs(state, "drawmeta").FirstOrDefault() ?? new JsonObject();
        var d = new JsonObject();
        foreach (var k in MetaKeys) if (meta.TryGetPropertyValue(k, out var v)) d[k] = v?.DeepClone();
        if (!d.ContainsKey("formatVersion")) d["formatVersion"] = 1;
        var layers = new JsonArray();
        foreach (var r in J.Objs(state, "drawlayers"))
        {
            var l = J.Copy(r);
            l["id"] = l["_id"]?.DeepClone();
            l.Remove("_id");
            if (!l.ContainsKey("name")) l["name"] = "";
            if (!l.ContainsKey("visible")) l["visible"] = true;
            if (!l.ContainsKey("locked")) l["locked"] = false;
            layers.Add(l);
        }
        d["layers"] = layers;
        var scenes = new JsonArray();
        foreach (var r in J.Objs(state, "drawscenes"))
            scenes.Add(new JsonObject { ["id"] = r["_id"]?.DeepClone(), ["name"] = J.S(r, "name"), ["visibleLayers"] = J.A(r, "visibleLayers").DeepClone() });
        if (scenes.Count > 0) d["scenes"] = scenes;
        var sheets = new JsonArray();
        foreach (var r in J.Objs(state, "drawsheets"))
        {
            var sh = J.Copy(r);
            sh["id"] = sh["_id"]?.DeepClone();
            sh.Remove("_id");
            sheets.Add(sh);
        }
        if (sheets.Count > 0) d["sheets"] = sheets;
        var types = new JsonArray();
        var styles = new JsonObject();
        foreach (var r in J.Objs(state, "drawtypes"))
        {
            var st = new JsonObject();
            if (J.Has(r, "color")) st["color"] = r["color"]!.DeepClone();
            if (J.Has(r, "easyID")) st["easyID"] = r["easyID"]!.DeepClone();
            var id = J.S(r, "_id");
            if (st.Count > 0) styles[id] = st;
            if (J.Has(r, "builtIn")) continue;
            var t = J.Copy(r);
            foreach (var k in new[] { "_id", "symbol", "color", "easyID" }) t.Remove(k);
            t["id"] = id;
            var symId = J.S(r, "symbol") is var si && si.Length > 0 ? si : id;
            if (symbols.TryGetValue(symId, out var sym))
            {
                t["prims"] = J.A(sym, "prims").DeepClone();
                t["width"] = J.D(sym, "width") is var sw && sw != 0 ? sw : (J.D(t, "width") is var tw && tw != 0 ? tw : 400);
                t["depth"] = J.D(sym, "depth") is var sd && sd != 0 ? sd : (J.D(t, "depth") is var td && td != 0 ? td : 400);
            }
            else
            {
                var w = J.D(t, "width") is var tw2 && tw2 != 0 ? tw2 : 400;
                var h = J.D(t, "depth") is var td2 && td2 != 0 ? td2 : 400;
                t["prims"] = new JsonArray(Prim("rect", -w / 2, -h / 2, w, h, fill: White));
            }
            types.Add(t);
        }
        d["fixtureTypes"] = types;
        if (styles.Count > 0) d["typeStyles"] = styles;
        var objects = new JsonArray();
        foreach (var r in J.Objs(state, "drawobjects"))
        {
            var o = J.Copy(r);
            o["id"] = o["_id"]?.DeepClone();
            o.Remove("_id");
            if (J.Has(o, "fx"))
            {
                o["lxID"] = o["fx"]!.DeepClone();
                o.Remove("fx");
            }
            foreach (var k in LxFields) if (!o.ContainsKey(k)) o[k] = "";
            objects.Add(o);
        }
        d["objects"] = objects;
        return d;
    }
}
