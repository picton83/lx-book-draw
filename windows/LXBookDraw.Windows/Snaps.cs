using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;

namespace LXBookDrawWin;

public enum SnapKind { Endpoint, Midpoint, Center, Insertion, Quadrant, Intersection, Perpendicular, Nearest }

public readonly record struct SnapHit((double X, double Y) Point, SnapKind Kind);

/// Object snaps, as AutoCAD's running osnaps (a port of Snaps.swift).
public static class Snapper
{
    public static string Label(SnapKind k) => k.ToString();

    public static string Abbreviation(SnapKind k) => k switch
    {
        SnapKind.Endpoint => "end", SnapKind.Midpoint => "mid", SnapKind.Center => "cen", SnapKind.Insertion => "ins",
        SnapKind.Quadrant => "qua", SnapKind.Intersection => "int", SnapKind.Perpendicular => "per", _ => "nea"
    };

    public static List<((double X, double Y) A, (double X, double Y) B)> Segments(JsonObject o)
    {
        var outp = new List<((double, double), (double, double))>();
        switch (M.Kind(o))
        {
            case "line":
            case "polyline":
                var ps = M.Pts(o);
                for (int i = 0; i + 1 < ps.Count; i++) outp.Add((ps[i], ps[i + 1]));
                if (J.Has(o, "closed") && ps.Count > 2) outp.Add((ps[^1], ps[0]));
                break;
            case "rect":
            case "truss":
                var (bx, by, bw, bh) = PlotPdf.LocalBox(o);
                var c = new[] { (bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh) }.Select(p => M.ToWorld(o, p.Item1, p.Item2)).ToArray();
                for (int i = 0; i < 4; i++) outp.Add((c[i], c[(i + 1) % 4]));
                if (M.Kind(o) == "truss") outp.Add((M.ToWorld(o, bx, 0), M.ToWorld(o, bx + bw, 0)));
                break;
        }
        return outp;
    }

    static (double X, double Y) Closest(((double X, double Y) A, (double X, double Y) B) seg, (double X, double Y) p)
    {
        double dx = seg.B.X - seg.A.X, dy = seg.B.Y - seg.A.Y, len2 = dx * dx + dy * dy;
        if (len2 == 0) return seg.A;
        var t = Math.Clamp(((p.X - seg.A.X) * dx + (p.Y - seg.A.Y) * dy) / len2, 0, 1);
        return (seg.A.X + t * dx, seg.A.Y + t * dy);
    }

    static (double X, double Y)? Intersection(((double X, double Y) A, (double X, double Y) B) a, ((double X, double Y) A, (double X, double Y) B) b)
    {
        double rx = a.B.X - a.A.X, ry = a.B.Y - a.A.Y, sx = b.B.X - b.A.X, sy = b.B.Y - b.A.Y;
        var denom = rx * sy - ry * sx;
        if (Math.Abs(denom) < 1e-9) return null;
        double qx = b.A.X - a.A.X, qy = b.A.Y - a.A.Y;
        var t = (qx * sy - qy * sx) / denom;
        var u = (qx * ry - qy * rx) / denom;
        if (t < -1e-6 || t > 1 + 1e-6 || u < -1e-6 || u > 1 + 1e-6) return null;
        return (a.A.X + t * rx, a.A.Y + t * ry);
    }

    /// The best snap point within `aperture` (drawing units) of the cursor, or null.
    public static SnapHit? Find((double X, double Y) p, JsonObject d, double aperture, ISet<SnapKind> modes, (double X, double Y)? from,
                                ICollection<string>? skip = null, IEnumerable<JsonObject>? objects = null)
    {
        if (modes.Count == 0) return null;
        SnapHit? best = null;
        var bestScore = double.MaxValue;

        void Offer((double X, double Y) point, SnapKind kind, bool hovering = false)
        {
            if (!modes.Contains(kind)) return;
            var dist = M.Dist(point, p);
            if (hovering) dist = Math.Min(dist, aperture * 0.8);
            if (dist > aperture) return;
            var score = dist + (kind == SnapKind.Nearest ? aperture : 0);
            if (score < bestScore)
            {
                bestScore = score;
                best = new SnapHit(point, kind);
            }
        }

        var nearby = new List<((double X, double Y) A, (double X, double Y) B)>();
        foreach (var o in objects ?? M.Objects(d))
        {
            if (!M.IsVisible(d, o) || (skip != null && skip.Contains(M.Id(o)))) continue;
            var bb = M.Bounds(o);
            if (bb == null) continue;
            var b = bb.Value;
            if (p.X < b.Item1 - aperture || p.X > b.Item3 + aperture || p.Y < b.Item2 - aperture || p.Y > b.Item4 + aperture) continue;
            switch (M.Kind(o))
            {
                case "fixture":
                case "text":
                    Offer(M.Pos(o), SnapKind.Insertion, M.Hit(o, p, 0));
                    break;
                case "ellipse":
                    double w = J.D(o, "w"), h = J.D(o, "h");
                    Offer(M.ToWorld(o, w / 2, h / 2), SnapKind.Center, M.Hit(o, p, 0));
                    foreach (var (qx, qy) in new[] { (w, h / 2), (w / 2, h), (0, h / 2), (w / 2, 0) }) Offer(M.ToWorld(o, qx, qy), SnapKind.Quadrant);
                    break;
            }
            foreach (var seg in Segments(o))
            {
                Offer(seg.A, SnapKind.Endpoint);
                Offer(seg.B, SnapKind.Endpoint);
                Offer(((seg.A.X + seg.B.X) / 2, (seg.A.Y + seg.B.Y) / 2), SnapKind.Midpoint);
                var near = Closest(seg, p);
                if (M.Dist(near, p) > aperture) continue;
                nearby.Add(seg);
                Offer(near, SnapKind.Nearest);
                if (from is (double, double) r)
                {
                    var foot = Closest(seg, r);
                    if (M.Dist(foot, seg.A) > 1 && M.Dist(foot, seg.B) > 1) Offer(foot, SnapKind.Perpendicular);
                }
            }
        }
        if (modes.Contains(SnapKind.Intersection) && nearby.Count >= 2 && nearby.Count <= 40)
            for (int i = 0; i < nearby.Count - 1; i++)
                for (int j = i + 1; j < nearby.Count; j++)
                    if (Intersection(nearby[i], nearby[j]) is (double, double) x) Offer(x, SnapKind.Intersection);
        return best;
    }
}
