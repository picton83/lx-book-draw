using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;

namespace LXBookDrawWin;

/// Sheets (paper space) and their viewports, as the Mac's Sheet and Viewport.
public static class Sheets
{
    public static readonly double[] Scales = { 5, 10, 20, 25, 40, 50, 75, 100, 125, 150, 200, 250, 300, 400, 500, 750, 1000 };

    /// The space inside the border that is free for viewports.
    public static (double X, double Y, double W, double H) DrawArea(JsonObject sheet)
    {
        var right = J.IsFalse(sheet, "panel") ? 0 : PlotPdf.PanelMM;
        double w = J.D(sheet, "w", 420), h = J.D(sheet, "h", 297), m = PlotPdf.MarginMM;
        return (m + 4, m + 4, Math.Max(20, w - 2 * m - right - 8), Math.Max(20, h - 2 * m - 8));
    }

    /// The drawing as a viewport shows it: only its layers visible.
    public static JsonObject View(JsonObject v, JsonObject d)
    {
        var c = (JsonObject)d.DeepClone();
        if (v["layers"] is JsonArray ls)
        {
            var shown = ls.Select(n => J.Txt(n)).ToHashSet();
            foreach (var l in J.Objs(c, "layers")) l["visible"] = shown.Contains(J.S(l, "id"));
        }
        return c;
    }

    /// Centres the drawing in the viewport at the biggest standard scale that fits.
    public static void Fit(JsonObject v, JsonObject d)
    {
        var ext = M.Extents(View(v, d));
        double w = J.D(v, "w"), h = J.D(v, "h");
        if (ext == null || w <= 0 || h <= 0) return;
        var (x0, y0, x1, y1) = ext.Value;
        if (x1 - x0 < 1 || y1 - y0 < 1) return;
        var need = Math.Max((x1 - x0) / w, (y1 - y0) / h) * 1.04;
        v["scale"] = Scales.Cast<double?>().FirstOrDefault(s => s >= need) ?? Math.Ceiling(need);
        v["cx"] = (x0 + x1) / 2;
        v["cy"] = (y0 + y1) / 2;
    }

    public static JsonObject NewViewport(JsonObject d, double x, double y, double w, double h, IEnumerable<string>? layers)
    {
        var v = new JsonObject { ["id"] = M.NewId(), ["x"] = x, ["y"] = y, ["w"] = w, ["h"] = h, ["cx"] = 0.0, ["cy"] = 0.0, ["scale"] = 50.0 };
        var ls = layers ?? J.Objs(d, "layers").Where(l => !J.IsFalse(l, "visible")).Select(l => J.S(l, "id"));
        v["layers"] = new JsonArray(ls.Select(id => (JsonNode)id!).ToArray());
        Fit(v, d);
        return v;
    }

    public static JsonObject NewSheet(JsonObject d, string name, IEnumerable<string>? layers = null)
    {
        var s = new JsonObject { ["id"] = M.NewId(), ["name"] = name, ["w"] = 420.0, ["h"] = 297.0, ["viewports"] = new JsonArray(), ["objects"] = new JsonArray() };
        var (x, y, w, h) = DrawArea(s);
        ((JsonArray)s["viewports"]!).Add(NewViewport(d, x, y, w, h, layers));
        return s;
    }

    /// Replaces the sheet's viewports with a grid of them; each takes the next scene in turn, else what the model shows.
    public static void SetGrid(JsonObject sheet, int columns, int rows, JsonObject d)
    {
        var (ax, ay, aw, ah) = DrawArea(sheet);
        const double gap = 4;
        int cols = Math.Max(1, columns), rws = Math.Max(1, rows);
        var cellW = (aw - gap * (cols - 1)) / cols;
        var cellH = (ah - gap * (rws - 1)) / rws;
        var scenes = J.Objs(d, "scenes").ToList();
        var showing = J.Objs(d, "layers").Where(l => !J.IsFalse(l, "visible")).Select(l => J.S(l, "id")).ToList();
        var made = new JsonArray();
        for (int r = 0; r < rws; r++)
            for (int c = 0; c < cols; c++)
            {
                var x = ax + c * (cellW + gap);
                var y = ay + ah - cellH - r * (cellH + gap);
                var n = made.Count;
                IEnumerable<string> layers = n < scenes.Count ? J.A(scenes[n], "visibleLayers").Select(z => J.Txt(z)).ToList() : showing;
                made.Add(NewViewport(d, x, y, cellW, cellH, layers));
            }
        sheet["viewports"] = made;
    }
}
