using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace LXBookDrawWin;

// The drawing is kept as JSON exactly as the Mac app writes it (Model.swift), so a drawing passes between the two
// apps, and through Lx Book, without losing anything. Millimetres, Y up.
//
// The Mac reads drawings strictly: every field that isn't optional there must be present. Everything made here
// comes from the makers below (or passes through Normalize) so the Mac can always open it.

public static class M
{
    public static string NewId() => Guid.NewGuid().ToString().ToUpperInvariant();

    public static JsonObject Rgba(double r, double g, double b, double a = 1) => new() { ["r"] = r, ["g"] = g, ["b"] = b, ["a"] = a };
    public static JsonObject Rgba(Rgb c) => Rgba(c.R, c.G, c.B);
    public static JsonObject P(double x, double y) => new() { ["x"] = x, ["y"] = y };

    public static readonly (string Name, Rgb Color)[] Presets =
    {
        ("Black", new Rgb(0, 0, 0)), ("Red", new Rgb(0.90, 0.10, 0.10)), ("Blue", new Rgb(0.15, 0.25, 0.90)), ("Yellow", new Rgb(1.0, 0.92, 0.0)),
        ("Orange", new Rgb(1.0, 0.55, 0.0)), ("Green", new Rgb(0.10, 0.65, 0.20)), ("Grey", new Rgb(0.55, 0.55, 0.55)), ("Pink", new Rgb(1.0, 0.80, 0.82)),
        ("White", new Rgb(1, 1, 1))
    };

    public static readonly (string Name, Rgb Color)[] Tints =
    {
        ("Red", new Rgb(1.0, 0.72, 0.72)), ("Orange", new Rgb(1.0, 0.82, 0.62)), ("Yellow", new Rgb(1.0, 0.95, 0.60)), ("Green", new Rgb(0.72, 0.92, 0.72)),
        ("Blue", new Rgb(0.72, 0.82, 1.0)), ("Purple", new Rgb(0.87, 0.76, 0.96)), ("Pink", new Rgb(1.0, 0.80, 0.90)), ("Grey", new Rgb(0.85, 0.85, 0.85))
    };

    static readonly (string Key, Func<JsonNode> Make)[] ObjectFields =
    {
        ("kind", () => "line"), ("pos", () => P(0, 0)), ("rot", () => 0.0), ("w", () => 0.0), ("h", () => 0.0), ("pts", () => new JsonArray()),
        ("closed", () => false), ("stroke", () => Rgba(0, 0, 0)), ("lineWeight", () => 0.25), ("text", () => ""), ("textSize", () => 250.0),
        ("typeID", () => ""), ("unit", () => ""), ("universe", () => ""), ("address", () => ""), ("circuit", () => ""), ("position", () => ""), ("note", () => "")
    };

    public static JsonObject NewObject(string kind, string layer)
    {
        var o = new JsonObject { ["id"] = NewId(), ["layer"] = layer };
        foreach (var (k, make) in ObjectFields) o[k] = make();
        o["kind"] = kind;
        return o;
    }

    public static JsonObject NewLayer(string name) => new() { ["id"] = NewId(), ["name"] = name, ["visible"] = true, ["locked"] = false };

    public static JsonObject NewInfo() => new()
    {
        ["show"] = "", ["drawingTitle"] = "LX Plot", ["designer"] = "", ["venue"] = "", ["drawnBy"] = "", ["version"] = "V0.1", ["date"] = ""
    };

    public static JsonObject Blank() => new()
    {
        ["formatVersion"] = 1,
        ["layers"] = new JsonArray(NewLayer("Truss"), NewLayer("Lighting"), NewLayer("Rigging"), NewLayer("Stage & Notes")),
        ["objects"] = new JsonArray(), ["fixtureTypes"] = new JsonArray(), ["info"] = NewInfo(), ["gridSize"] = 100.0, ["snapGrid"] = true,
        ["showLabels"] = true, ["labelSize"] = 130.0, ["nextUnit"] = 1
    };

    static void Fill(JsonObject o, string key, Func<JsonNode> make)
    {
        if (!o.TryGetPropertyValue(key, out var v) || v == null) o[key] = make();
    }

    /// Puts in any field the Mac needs that is missing, so the drawing always opens there.
    public static void Normalize(JsonObject d)
    {
        Fill(d, "formatVersion", () => 1);
        Fill(d, "layers", () => new JsonArray());
        Fill(d, "objects", () => new JsonArray());
        Fill(d, "fixtureTypes", () => new JsonArray());
        Fill(d, "info", NewInfo);
        Fill(d, "gridSize", () => 100.0);
        Fill(d, "snapGrid", () => true);
        Fill(d, "showLabels", () => true);
        Fill(d, "labelSize", () => 130.0);
        Fill(d, "nextUnit", () => 1);
        if (d["info"] is JsonObject info) foreach (var (k, v) in NewInfo().ToList()) Fill(info, k, () => v!.DeepClone());
        if (J.A(d, "layers").Count == 0) d["layers"] = new JsonArray(NewLayer("Layer 1"));
        foreach (var l in J.Objs(d, "layers"))
        {
            Fill(l, "id", () => NewId());
            Fill(l, "name", () => "Layer");
            Fill(l, "visible", () => true);
            Fill(l, "locked", () => false);
        }
        var firstLayer = J.S(J.Objs(d, "layers").First(), "id");
        foreach (var o in J.Objs(d, "objects")) NormalizeObject(o, firstLayer);
        foreach (var t in J.Objs(d, "fixtureTypes"))
        {
            foreach (var (k, make) in new (string, Func<JsonNode>)[]
                     {
                         ("manufacturer", () => ""), ("name", () => J.S(t, "id")), ("mode", () => ""), ("channels", () => 0), ("weight", () => 0.0), ("watts", () => 0.0),
                         ("category", () => "fixture"), ("width", () => 400.0), ("depth", () => 400.0), ("prims", () => new JsonArray()), ("source", () => "gdtf"),
                         ("gdtfRID", () => 0), ("revision", () => "")
                     }) Fill(t, k, make);
            foreach (var p in J.Objs(t, "prims")) NormalizePrim(p);
        }
        foreach (var s in J.Objs(d, "scenes"))
        {
            Fill(s, "id", () => NewId());
            Fill(s, "name", () => "Scene");
            Fill(s, "visibleLayers", () => new JsonArray());
        }
        foreach (var sh in J.Objs(d, "sheets"))
        {
            Fill(sh, "id", () => NewId());
            Fill(sh, "name", () => "Sheet");
            Fill(sh, "w", () => 420.0);
            Fill(sh, "h", () => 297.0);
            Fill(sh, "viewports", () => new JsonArray());
            Fill(sh, "objects", () => new JsonArray());
            foreach (var v in J.Objs(sh, "viewports"))
                foreach (var (k, make) in new (string, Func<JsonNode>)[]
                         { ("id", () => NewId()), ("x", () => 0.0), ("y", () => 0.0), ("w", () => 100.0), ("h", () => 100.0), ("cx", () => 0.0), ("cy", () => 0.0), ("scale", () => 50.0) })
                    Fill(v, k, make);
            foreach (var o in J.Objs(sh, "objects")) NormalizeObject(o, firstLayer);
        }
        foreach (var key in new[] { "labelParts", "hoistLabelParts" })
            foreach (var p in J.Objs(d, key))
            {
                Fill(p, "field", () => "unit");
                Fill(p, "on", () => true);
                Fill(p, "size", () => J.D(d, "labelSize", 130));
            }
        foreach (var h in J.Objs(d, "history"))
        {
            Fill(h, "ts", () => "");
            Fill(h, "what", () => "");
        }
    }

    public static void NormalizeObject(JsonObject o, string layer)
    {
        Fill(o, "id", () => NewId());
        Fill(o, "layer", () => layer);
        foreach (var (k, make) in ObjectFields) Fill(o, k, make);
    }

    public static void NormalizePrim(JsonObject p)
    {
        foreach (var (k, make) in new (string, Func<JsonNode>)[]
                 { ("k", () => "line"), ("a", () => 0.0), ("b", () => 0.0), ("c", () => 0.0), ("d", () => 0.0), ("s", () => ""), ("pts", () => new JsonArray()) })
            Fill(p, k, make);
    }

    // ---------------------------------------------------------------- reading and changing objects

    public static string Id(JsonNode? o) => J.S(o, "id");
    public static string Kind(JsonNode? o) => J.S(o, "kind");
    public static (double X, double Y) Pos(JsonNode? o) => (J.D(J.G(o, "pos"), "x"), J.D(J.G(o, "pos"), "y"));
    public static void SetPos(JsonObject o, double x, double y) => o["pos"] = P(x, y);
    public static List<(double X, double Y)> Pts(JsonNode? o) => J.Objs(o, "pts").Select(p => (J.D(p, "x"), J.D(p, "y"))).ToList();

    public static void SetPts(JsonObject o, IEnumerable<(double X, double Y)> pts)
    {
        var a = new JsonArray();
        foreach (var (x, y) in pts) a.Add(P(x, y));
        o["pts"] = a;
    }

    public static bool UsesPoints(JsonNode? o) => Kind(o) is "line" or "polyline";

    public static void Translate(JsonObject o, double dx, double dy)
    {
        var (x, y) = Pos(o);
        SetPos(o, x + dx, y + dy);
        SetPts(o, Pts(o).Select(p => (p.X + dx, p.Y + dy)));
    }

    public static void Rotate(JsonObject o, double cx, double cy, double degrees)
    {
        var a = degrees * Math.PI / 180;
        double cs = Math.Cos(a), sn = Math.Sin(a);
        (double, double) Turn((double X, double Y) p) => (cx + (p.X - cx) * cs - (p.Y - cy) * sn, cy + (p.X - cx) * sn + (p.Y - cy) * cs);
        var np = Turn(Pos(o));
        SetPos(o, np.Item1, np.Item2);
        SetPts(o, Pts(o).Select(Turn));
        o["rot"] = J.D(o, "rot") + degrees;
    }

    /// Drawn shapes and text change size; truss and fixtures keep their real size and only move.
    public static void Scale(JsonObject o, double cx, double cy, double f)
    {
        (double, double) Grow((double X, double Y) p) => (cx + (p.X - cx) * f, cy + (p.Y - cy) * f);
        var np = Grow(Pos(o));
        SetPos(o, np.Item1, np.Item2);
        SetPts(o, Pts(o).Select(Grow));
        switch (Kind(o))
        {
            case "rect":
            case "ellipse":
                o["w"] = J.D(o, "w") * f;
                o["h"] = J.D(o, "h") * f;
                break;
            case "text":
                o["textSize"] = J.D(o, "textSize") * f;
                break;
        }
    }

    public static (double X, double Y) ToWorld(JsonObject o, double x, double y) => PlotPdf.Apply(PlotPdf.Transform(o), x, y);

    public static (double X, double Y) ToLocal(JsonObject o, double x, double y)
    {
        var (px, py) = Pos(o);
        var a = -J.D(o, "rot") * Math.PI / 180;
        double dx = x - px, dy = y - py;
        return (dx * Math.Cos(a) - dy * Math.Sin(a), dx * Math.Sin(a) + dy * Math.Cos(a));
    }

    public static (double X0, double Y0, double X1, double Y1)? Bounds(JsonObject o)
    {
        var b = PlotPdf.WorldBounds(o);
        return b;
    }

    public static double DistToSegment((double X, double Y) p, (double X, double Y) a, (double X, double Y) b)
    {
        double dx = b.X - a.X, dy = b.Y - a.Y, len2 = dx * dx + dy * dy;
        if (len2 == 0) return Dist(p, a);
        var t = Math.Clamp(((p.X - a.X) * dx + (p.Y - a.Y) * dy) / len2, 0, 1);
        return Dist(p, (a.X + t * dx, a.Y + t * dy));
    }

    public static double Dist((double X, double Y) a, (double X, double Y) b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    public static bool Hit(JsonObject o, (double X, double Y) p, double tol)
    {
        if (UsesPoints(o))
        {
            var ps = Pts(o);
            if (J.Has(o, "closed") && ps.Count > 0) ps.Add(ps[0]);
            for (int i = 0; i + 1 < ps.Count; i++) if (DistToSegment(p, ps[i], ps[i + 1]) <= tol) return true;
            return false;
        }
        var (lx, ly) = ToLocal(o, p.X, p.Y);
        var (bx, by, bw, bh) = PlotPdf.LocalBox(o);
        return lx >= bx - tol && lx <= bx + bw + tol && ly >= by - tol && ly <= by + bh + tol;
    }

    // ---------------------------------------------------------------- the drawing

    public static IEnumerable<JsonObject> Objects(JsonObject d) => J.Objs(d, "objects");
    public static JsonArray ObjectArray(JsonObject d) => d["objects"] as JsonArray ?? (JsonArray)(d["objects"] = new JsonArray());
    public static JsonObject? Find(JsonObject d, string id) => Objects(d).FirstOrDefault(o => Id(o) == id);
    public static JsonObject? Layer(JsonObject d, string id) => J.Objs(d, "layers").FirstOrDefault(l => J.S(l, "id") == id);

    public static bool IsVisible(JsonObject d, JsonObject o)
    {
        var l = Layer(d, J.S(o, "layer"));
        return l == null || !J.IsFalse(l, "visible");
    }

    public static bool IsLocked(JsonObject d, JsonObject o) => J.IsTrue(Layer(d, J.S(o, "layer")), "locked");

    public static string? TopObject(JsonObject d, (double X, double Y) p, double tol)
    {
        foreach (var o in Objects(d).Reverse())
        {
            if (!IsVisible(d, o) || IsLocked(d, o)) continue;
            if (Hit(o, p, tol)) return Id(o);
        }
        return null;
    }

    public static (double X0, double Y0, double X1, double Y1)? Extents(JsonObject d, IEnumerable<JsonObject>? only = null)
    {
        (double, double, double, double)? box = null;
        var labels = !J.IsFalse(d, "showLabels");
        var ls = J.D(d, "labelSize", 130);
        foreach (var o in only ?? Objects(d).Where(o => IsVisible(d, o)))
        {
            var bb = Bounds(o);
            if (bb == null) continue;
            var b = bb.Value;
            if (Kind(o) == "fixture" && labels) b = (b.Item1 - ls * 2, b.Item2 - ls * 4, b.Item3 + ls * 2, b.Item4 + ls * 4);
            box = box == null ? b : (Math.Min(box.Value.Item1, b.Item1), Math.Min(box.Value.Item2, b.Item2), Math.Max(box.Value.Item3, b.Item3), Math.Max(box.Value.Item4, b.Item4));
        }
        return box;
    }

    /// Fixtures hung on any of these objects.
    public static HashSet<string> AttachedFixtures(JsonObject d, ICollection<string> ids)
    {
        var outp = new HashSet<string>();
        foreach (var o in Objects(d))
            if (Kind(o) == "fixture" && J.S(o, "attachedTo") is var a && a.Length > 0 && ids.Contains(a)) outp.Add(Id(o));
        return outp;
    }

    /// The given objects plus every other member of the groups they belong to.
    public static HashSet<string> WithGroups(JsonObject d, ICollection<string> ids)
    {
        var groups = Objects(d).Where(o => ids.Contains(Id(o))).Select(o => J.S(o, "group")).Where(g => g.Length > 0).ToHashSet();
        var outp = new HashSet<string>(ids);
        if (groups.Count == 0) return outp;
        foreach (var o in Objects(d)) if (groups.Contains(J.S(o, "group"))) outp.Add(Id(o));
        return outp;
    }

    public static JsonObject FixtureType(JsonObject d, string id) =>
        J.Objs(d, "fixtureTypes").FirstOrDefault(t => J.S(t, "id") == id) ?? PlotPdf.BuiltIn.FirstOrDefault(t => J.S(t, "id") == id) ?? PlotPdf.BuiltIn[0];

    public static IEnumerable<JsonObject> AllFixtureTypes(JsonObject d) => J.Objs(d, "fixtureTypes").Concat(PlotPdf.BuiltIn);

    public static string Category(JsonObject d, JsonObject o) => J.S(FixtureType(d, J.S(o, "typeID")), "category") is var c && c.Length > 0 ? c : "fixture";

    public static (string Name, double Length, double Width) TrussType(string id) =>
        PlotPdf.Truss.TryGetValue(id, out var t) ? (t.Name, t.L, t.W) : (PlotPdf.Truss["lopro-2.5"].Name, PlotPdf.Truss["lopro-2.5"].L, PlotPdf.Truss["lopro-2.5"].W);

    /// Hangs a fixture on the nearest truss centreline within maxDist, taking its rotation and position name.
    public static void Attach(JsonObject o, JsonObject d, double maxDist)
    {
        var bestDist = double.MaxValue;
        JsonObject? best = null;
        double bestX = 0;
        var (px, py) = Pos(o);
        foreach (var t in Objects(d))
        {
            if (Kind(t) != "truss" || !IsVisible(d, t)) continue;
            var (_, len, _) = TrussType(J.S(t, "typeID"));
            var (lx, ly) = ToLocal(t, px, py);
            if (lx < -150 || lx > len + 150 || Math.Abs(ly) > maxDist) continue;
            if (Math.Abs(ly) < bestDist)
            {
                bestDist = Math.Abs(ly);
                best = t;
                bestX = Math.Clamp(lx, 0, len);
            }
        }
        if (best != null)
        {
            var (wx, wy) = ToWorld(best, bestX, 0);
            SetPos(o, wx, wy);
            o["rot"] = J.D(best, "rot");
            o["attachedTo"] = Id(best);
            if (J.S(best, "position").Length > 0) o["position"] = J.S(best, "position");
        }
        else o.Remove("attachedTo");
    }

    public static void ApplyScene(JsonObject d, string id)
    {
        var scene = J.Objs(d, "scenes").FirstOrDefault(s => J.S(s, "id") == id);
        if (scene == null) return;
        var shown = J.A(scene, "visibleLayers").Select(n => J.Txt(n)).ToHashSet();
        foreach (var l in J.Objs(d, "layers")) l["visible"] = shown.Contains(J.S(l, "id"));
        d["activeScene"] = id;
    }

    public static List<JsonObject> EffectiveLabelParts(JsonObject d, bool hoist)
    {
        var parts = J.Objs(d, hoist ? "hoistLabelParts" : "labelParts").ToList();
        if (parts.Count > 0) return parts.Select(p => (JsonObject)p.DeepClone()).ToList();
        var s = J.D(d, "labelSize", 130);
        var fields = hoist
            ? new[] { ("unit", true, s), ("chain", true, s * 0.8), ("load", true, s * 0.8), ("position", false, s * 0.8), ("type", false, s * 0.8), ("note", false, s * 0.8) }
            : new[] { ("unit", true, s), ("patch", true, s), ("circuit", true, s), ("position", false, s), ("type", false, s), ("note", false, s) };
        return fields.Select(f => new JsonObject { ["field"] = f.Item1, ["on"] = f.Item2, ["size"] = f.Item3 }).ToList();
    }

    /// Where a fixture's label sits when it hasn't been moved (the Mac's Renderer.defaultLabelAnchor).
    public static (double X, double Y) DefaultLabelAnchor(JsonObject o, JsonObject d)
    {
        var on = J.Objs(d, "labelParts").Where(p => J.Has(p, "on")).Select(p => J.D(p, "size")).ToList();
        var gap = on.Count > 0 && on.Min() > 0 ? on.Min() : J.D(d, "labelSize", 130);
        return ToWorld(o, 0, J.D(o, "h") / 2 + gap * 0.35);
    }

    public static string Num(double v) => v == Math.Round(v) ? ((long)v).ToString(CultureInfo.InvariantCulture) : v.ToString("0.##", CultureInfo.InvariantCulture);

    public static double? ParseNum(string s) =>
        double.TryParse(s.Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;

    /// The same text for the same content whatever order the keys are in (for comparing rows).
    public static string Canon(JsonNode? n)
    {
        var sb = new StringBuilder();
        void W(JsonNode? x)
        {
            switch (x)
            {
                case null: sb.Append("null"); break;
                case JsonObject o:
                    sb.Append('{');
                    var first = true;
                    foreach (var kv in o.OrderBy(k => k.Key, StringComparer.Ordinal))
                    {
                        if (!first) sb.Append(',');
                        first = false;
                        sb.Append(JsonSerializer.Serialize(kv.Key)).Append(':');
                        W(kv.Value);
                    }
                    sb.Append('}');
                    break;
                case JsonArray a:
                    sb.Append('[');
                    for (int i = 0; i < a.Count; i++)
                    {
                        if (i > 0) sb.Append(',');
                        W(a[i]);
                    }
                    sb.Append(']');
                    break;
                case JsonValue v:
                    if (J.Num(v) is double dbl) sb.Append(dbl.ToString("R", CultureInfo.InvariantCulture));
                    else sb.Append(v.ToJsonString());
                    break;
            }
        }
        W(n);
        return sb.ToString();
    }
}
