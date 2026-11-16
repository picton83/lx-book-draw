using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace LXBookDrawWin;

public interface ICanvasHost
{
    DrawDoc? Doc { get; }
    string ActiveLayer { get; }
    string CurrentFixtureType { get; }
    string CurrentTrussType { get; }
    string ShowName { get; }
    void Log(string text, string kind = "note");
    void SetPrompt(string text);
    void SetCoords(double x, double y);
    void SelectionChanged();
    bool AppCommand(string name);
    void MakeLayerCurrent(string name);
}

public enum Cmd { None, Line, Pline, Circle, Rect, Text, Move, Copy, Rotate, Scale, Erase, Truss, Fixture, Zoom, ZoomWindow, Layer, Scene, Label, Dist, Tag, Viewport, SheetText }

/// The drawing area: model space or a sheet, AutoCAD style. Commands prompt on the command line for points or values
/// until finished with Enter or cancelled with Esc (a port of CanvasView.swift).
public sealed class DrawCanvas : FrameworkElement
{
    readonly ICanvasHost host;
    DrawDoc? Doc => host.Doc;

    // view: screen = ((world - off) * scale), Y flipped
    public double ViewScale { get; private set; } = 0.05;
    double offX = -2000, offY = -2000;

    public HashSet<string> Selection { get; private set; } = new();
    public Cmd Command { get; private set; } = Cmd.None;
    Cmd lastCmd = Cmd.None;
    readonly List<(double X, double Y)> pts = new();
    int step;
    bool selecting;
    readonly List<string> made = new();
    SnapKind? snapOverride;
    double textHeight = 250;

    Point? mouse;
    (double X, double Y) cursor;
    SnapHit? snapHit;
    (double X, double Y)? windowStart;
    (double X, double Y) windowEnd;

    Point pressView;
    (double X, double Y) pressWorld;
    bool pressedObject, pressedEmpty, draggingWindow, panning, didMove;
    Point panLast;
    string? snapshot;
    Grip? activeGrip;
    bool gripHeld;
    public bool LabelMode { get; set; }
    (string Id, double DX, double DY)? labelDrag;
    JsonObject? pendingLocation;

    // sheets (paper space): SheetID null means the Model tab
    public string? SheetID { get; private set; }
    public string? SheetSel { get; private set; }
    (double X, double Y, double W, double H)? sheetDragStart;

    // drafting aids
    public bool Osnap { get; set; } = true;
    public bool Ortho { get; set; }
    public bool ShowGrid { get; set; } = true;
    public HashSet<SnapKind> Modes { get; } = new() { SnapKind.Endpoint, SnapKind.Midpoint, SnapKind.Center, SnapKind.Insertion, SnapKind.Quadrant, SnapKind.Intersection, SnapKind.Perpendicular };

    // the drawing as last painted, kept so moving the cursor doesn't draw it all again
    DrawingGroup? kept;
    int keptVersion = -1;
    double keptScale;
    string? keptSheet;
    int version;
    readonly DispatcherTimer redrawSoon = new() { Interval = TimeSpan.FromMilliseconds(140) };

    static readonly Brush SelBrush = Frozen(Color.FromRgb(0x1E, 0x90, 0xFF)), GripBlue = Frozen(Color.FromRgb(0x1E, 0x6F, 0xE8)),
        GripGreen = Frozen(Color.FromRgb(0x2E, 0xB8, 0x4F)), SnapGreen = Frozen(Color.FromRgb(0x10, 0xA0, 0x30)), Tip = Frozen(Color.FromRgb(0xFF, 0xF7, 0xC0)),
        WinFill = Frozen(Color.FromArgb(40, 0x1E, 0x6F, 0xE8)), CrossFill = Frozen(Color.FromArgb(40, 0x2E, 0xB8, 0x4F)), Desk = Frozen(Color.FromRgb(0x5A, 0x60, 0x68)),
        GridMinor = Frozen(Color.FromRgb(0xEE, 0xEF, 0xF1)), GridMajor = Frozen(Color.FromRgb(0xDA, 0xDD, 0xE2)), Ghost = Frozen(Color.FromRgb(0x1E, 0x6F, 0xE8));

    static SolidColorBrush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    public DrawCanvas(ICanvasHost host)
    {
        this.host = host;
        Focusable = false;
        ClipToBounds = true;
        Cursor = Cursors.Cross;
        redrawSoon.Tick += (_, _) =>
        {
            redrawSoon.Stop();
            InvalidateVisual();
        };
    }

    // ---------------------------------------------------------------- view

    Matrix ViewMatrix => new(ViewScale, 0, 0, -ViewScale, -offX * ViewScale, ActualHeight + offY * ViewScale);
    public Point ToScreen((double X, double Y) w) => new((w.X - offX) * ViewScale, ActualHeight - (w.Y - offY) * ViewScale);
    public (double X, double Y) ToWorld(Point p) => (p.X / ViewScale + offX, (ActualHeight - p.Y) / ViewScale + offY);

    /// Call after any change to the drawing.
    public void DrawingChanged()
    {
        version++;
        if (Doc != null)
        {
            var ids = M.Objects(Doc.D).Select(M.Id).ToHashSet();
            if (SheetID == null && Selection.RemoveWhere(s => !ids.Contains(s)) > 0) host.SelectionChanged();
            if (SheetID != null && Sheet() == null) ShowSheet(null);
        }
        InvalidateVisual();
    }

    public void ZoomFit()
    {
        if (Doc == null || ActualWidth < 10) return;
        if (SheetID != null && Sheet() is JsonObject sh)
        {
            FitBox(0, 0, J.D(sh, "w", 420), J.D(sh, "h", 297), 0.94);
            return;
        }
        var e = M.Extents(Doc.D);
        if (e == null || e.Value.X1 - e.Value.X0 < 1) e = (0, 0, 10000, 7000);
        FitBox(e.Value.X0, e.Value.Y0, e.Value.X1, e.Value.Y1, 0.92);
    }

    void FitBox(double x0, double y0, double x1, double y1, double margin)
    {
        double w = Math.Max(x1 - x0, 1), h = Math.Max(y1 - y0, 1);
        ViewScale = Math.Min(ActualWidth / w, ActualHeight / h) * margin;
        offX = (x0 + x1) / 2 - ActualWidth / 2 / ViewScale;
        offY = (y0 + y1) / 2 - ActualHeight / 2 / ViewScale;
        InvalidateVisual();
    }

    public void ZoomBy(double k, Point? at = null)
    {
        var p = at ?? new Point(ActualWidth / 2, ActualHeight / 2);
        var w = ToWorld(p);
        var next = Math.Clamp(ViewScale * k, 0.0005, 200);
        ViewScale = next;
        offX = w.X - p.X / ViewScale;
        offY = w.Y - (ActualHeight - p.Y) / ViewScale;
        redrawSoon.Stop();
        redrawSoon.Start();
        InvalidateVisual();
    }

    // ---------------------------------------------------------------- sheets

    public JsonObject? Sheet() => SheetID == null || Doc == null ? null : J.Objs(Doc.D, "sheets").FirstOrDefault(s => J.S(s, "id") == SheetID);

    (double X, double Y)? modelOff;
    double modelScale;

    public void ShowSheet(string? id)
    {
        if (id == SheetID) return;
        if (Command != Cmd.None) EndCommand();
        if (SheetID == null)
        {
            modelOff = (offX, offY);
            modelScale = ViewScale;
        }
        SheetID = id;
        SheetSel = null;
        Selection = new HashSet<string>();
        host.SelectionChanged();
        if (id == null && modelOff is (double, double) o)
        {
            (offX, offY) = o;
            ViewScale = modelScale;
            InvalidateVisual();
        }
        else ZoomFit();
        RefreshPrompt();
    }

    public JsonObject? SelectedSheetItem()
    {
        var sh = Sheet();
        if (sh == null || SheetSel == null) return null;
        return J.Objs(sh, "viewports").FirstOrDefault(v => J.S(v, "id") == SheetSel) ?? J.Objs(sh, "objects").FirstOrDefault(v => J.S(v, "id") == SheetSel);
    }

    void SelectSheetItem(string? id)
    {
        SheetSel = id;
        host.SelectionChanged();
        InvalidateVisual();
    }

    /// Changes the sheet showing (one undo step).
    public void EditSheet(string name, Action<JsonObject> body)
    {
        var id = SheetID;
        Doc?.Edit(name, d =>
        {
            var sh = J.Objs(d, "sheets").FirstOrDefault(s => J.S(s, "id") == id);
            if (sh != null) body(sh);
        });
    }

    // ---------------------------------------------------------------- commands

    void Log(string s, string kind = "note") => host.Log(s, kind);

    public bool Run(string name)
    {
        var n = name.ToLowerInvariant();
        if (SheetID != null && SheetRun(n) is bool handled) return handled;
        Cmd? next = n switch
        {
            "l" or "line" => Cmd.Line,
            "pl" or "pline" or "polyline" => Cmd.Pline,
            "c" or "circle" => Cmd.Circle,
            "rec" or "rectang" or "rectangle" => Cmd.Rect,
            "t" or "dt" or "mt" or "text" or "mtext" => Cmd.Text,
            "m" or "move" => Cmd.Move,
            "co" or "cp" or "copy" => Cmd.Copy,
            "ro" or "rotate" => Cmd.Rotate,
            "di" or "dist" or "mea" or "measure" or "measuregeom" => Cmd.Dist,
            "sc" or "scale" => Cmd.Scale,
            "e" or "erase" or "del" or "delete" => Cmd.Erase,
            "tr" or "truss" => Cmd.Truss,
            "fx" or "f" or "fixture" or "ld" or "hoist" => Cmd.Fixture,
            "z" or "zoom" => Cmd.Zoom,
            "la" or "layer" => Cmd.Layer,
            "sn" or "scene" or "view" => Cmd.Scene,
            "lb" or "label" or "labels" => Cmd.Label,
            _ => null
        };
        if (next is Cmd c)
        {
            if (SheetID != null)
            {
                Log("That command draws on the model. Click the Model tab first. On a sheet: MV makes a viewport, T adds text, E erases.");
                return true;
            }
            Start(c);
            return true;
        }
        switch (n)
        {
            case "ml": case "movelabels": case "labelmode":
                LabelMode = !LabelMode;
                Log(LabelMode ? "Move Labels mode on: drag any label to move it. ML again turns it off." : "Move Labels mode off.");
                RefreshPrompt();
                break;
            case "ze": ZoomFit(); break;
            case "g": case "group": GroupSelection(); break;
            case "ug": case "ungroup": UngroupSelection(); break;
            case "u": case "undo": Doc?.Undo(); break;
            case "redo": Doc?.Redo(); break;
            case "os": case "osnap":
                Osnap = !Osnap;
                Log("Object snap " + (Osnap ? "on" : "off"));
                break;
            case "ortho":
                Ortho = !Ortho;
                Log("Ortho " + (Ortho ? "on" : "off"));
                break;
            case "grid": ShowGrid = !ShowGrid; break;
            case "help": case "?": Log(HelpText); break;
            default: return false;
        }
        InvalidateVisual();
        return true;
    }

    public const string HelpText =
        "Commands: L line, PL polyline, C circle, REC rectangle, T text, M move, CO copy, RO rotate, SC scale, E erase, " +
        "TR truss, FX fixture, LB label (R reset, A arrow, L level), ML move labels mode, LOC location label, LC / MLC label config, DI measure, " +
        "Z zoom (W window), ZE zoom extents, LA layer, SN scene, G group, UG ungroup, U undo, REDO, OS osnap, ORTHO, GRID, " +
        "PDF export, SAVE, NOTE, NOTES, LOG change log. On a sheet: MV viewport, T text, E erase, FIT. " +
        "Points: click, or type x,y  @dx,dy  @dist<angle, or a distance in the cursor's direction. Snap overrides: END MID CEN INS QUA INT PER NEA.";

    public void Start(Cmd c)
    {
        if (Command != Cmd.None) EndCommand();
        Command = c;
        lastCmd = c;
        pts.Clear();
        step = 0;
        made.Clear();
        snapOverride = null;
        windowStart = null;
        selecting = false;
        switch (c)
        {
            case Cmd.Move: case Cmd.Copy: case Cmd.Rotate: case Cmd.Scale:
                selecting = Selection.Count == 0;
                break;
            case Cmd.Label:
                selecting = SelectedFixtures().Count == 0;
                break;
            case Cmd.Erase:
                if (Selection.Count == 0) selecting = true;
                else
                {
                    EraseSelection();
                    EndCommand();
                    return;
                }
                break;
        }
        RefreshPrompt();
    }

    void EndCommand()
    {
        Command = Cmd.None;
        pts.Clear();
        step = 0;
        made.Clear();
        selecting = false;
        snapOverride = null;
        snapHit = null;
        windowStart = null;
        RefreshPrompt();
        InvalidateVisual();
    }

    /// True while the command line wants words, so Space types a space instead of acting as Enter.
    public bool WantsFreeText => (Command == Cmd.Text && step == 2) || Command == Cmd.Layer || Command == Cmd.Scene || (Command == Cmd.SheetText && step == 1);

    bool WantsPoint => !selecting && Command switch
    {
        Cmd.Line or Cmd.Pline or Cmd.Circle or Cmd.Rect or Cmd.Truss or Cmd.Fixture or Cmd.ZoomWindow or Cmd.Dist or Cmd.Tag or Cmd.Viewport => true,
        Cmd.Text or Cmd.SheetText => step == 0,
        Cmd.Move or Cmd.Copy or Cmd.Rotate or Cmd.Scale or Cmd.Label => true,
        _ => false
    };

    public void RefreshPrompt()
    {
        string p;
        if (selecting) p = Command == Cmd.Label ? "Select fixtures, then Enter:" : "Select objects, then Enter:";
        else
            p = Command switch
            {
                Cmd.None => SheetID != null ? "Sheet: click a viewport to select it, drag to move it. MV viewport, T text, E erase. Command:" : (LabelMode ? "Move Labels mode (ML to stop). Command:" : "Command:"),
                Cmd.Line => pts.Count == 0 ? "LINE Specify first point:" : "LINE Specify next point or [Close Undo]:",
                Cmd.Pline => pts.Count == 0 ? "PLINE Specify start point:" : "PLINE Specify next point or [Close Undo], Enter to finish:",
                Cmd.Circle => pts.Count == 0 ? "CIRCLE Specify center point:" : "CIRCLE Specify radius:",
                Cmd.Rect => pts.Count == 0 ? "RECTANG Specify first corner:" : "RECTANG Specify other corner:",
                Cmd.Text => step == 0 ? "TEXT Specify start point:" : step == 1 ? $"TEXT Specify height <{M.Num(textHeight)}>:" : "TEXT Enter text:",
                Cmd.Move => pts.Count == 0 ? "MOVE Specify base point:" : "MOVE Specify second point:",
                Cmd.Copy => pts.Count == 0 ? "COPY Specify base point:" : "COPY Specify second point, Enter to finish:",
                Cmd.Rotate => pts.Count == 0 ? "ROTATE Specify base point:" : "ROTATE Specify rotation angle:",
                Cmd.Scale => pts.Count == 0 ? "SCALE Specify base point:" : "SCALE Specify scale factor:",
                Cmd.Truss => pts.Count == 0 ? $"TRUSS ({M.TrussType(host.CurrentTrussType).Name}) Specify start point:" : "TRUSS Specify end point (Enter to finish):",
                Cmd.Fixture => $"FIXTURE ({J.S(M.FixtureType(Doc?.D ?? M.Blank(), host.CurrentFixtureType), "name")}) Click to place, Enter to finish:",
                Cmd.Zoom => "ZOOM [Window / Extents] <Extents>:",
                Cmd.ZoomWindow => pts.Count == 0 ? "ZOOM Specify first corner:" : "ZOOM Specify opposite corner:",
                Cmd.Layer => "LAYER Type a layer name to make it current:",
                Cmd.Scene => "SCENE Type a scene name to show it:",
                Cmd.Label => "LABEL Click where the label goes, or [Reset Arrow Level]:",
                Cmd.Dist => pts.Count == 0 ? "DIST Specify first point:" : "DIST Specify second point:",
                Cmd.Tag => "LOCATION Click to place the location label:",
                Cmd.Viewport => pts.Count == 0 ? "MVIEW Specify first corner of the viewport:" : "MVIEW Specify opposite corner:",
                Cmd.SheetText => step == 0 ? "TEXT Specify start point on the sheet:" : "TEXT Enter text:",
                _ => "Command:"
            };
        host.SetPrompt(p);
    }

    /// Esc: cancel the command, or the selection window, or clear the selection.
    public void Escape()
    {
        if (gripHeld && snapshot != null && Doc != null)
        {
            Doc.SetLive((JsonObject)JsonNode.Parse(snapshot)!);
            gripHeld = false;
            activeGrip = null;
            snapshot = null;
            Log("*Cancel*");
            InvalidateVisual();
            return;
        }
        pressedObject = pressedEmpty = false;
        snapshot = null;
        if (Command != Cmd.None)
        {
            Log("*Cancel*");
            EndCommand();
        }
        else if (windowStart != null)
        {
            windowStart = null;
            RefreshPrompt();
        }
        else if (SheetID != null) SelectSheetItem(null);
        else SetSelection(new HashSet<string>());
        InvalidateVisual();
    }

    public void SetSelection(HashSet<string> s)
    {
        Selection = s;
        host.SelectionChanged();
        InvalidateVisual();
    }

    (double X, double Y)? ParsePoint(string text)
    {
        var s = text.Replace(" ", "");
        var relative = false;
        if (s.StartsWith('@'))
        {
            relative = true;
            s = s[1..];
        }
        var r = pts.Count > 0 ? pts[^1] : (0, 0);
        if (s.Contains('<'))
        {
            var parts = s.Split('<');
            if (parts.Length != 2 || M.ParseNum(parts[0]) is not double dist || M.ParseNum(parts[1]) is not double ang) return null;
            var a = ang * Math.PI / 180;
            return (r.X + Math.Cos(a) * dist, r.Y + Math.Sin(a) * dist);
        }
        var xy = s.Split(',');
        if (xy.Length != 2 || !double.TryParse(xy[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var x) ||
            !double.TryParse(xy[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) return null;
        return relative ? (r.X + x, r.Y + y) : (x, y);
    }

    /// Enter on the command line (also Space and right-click), with whatever was typed.
    public void Enter(string raw)
    {
        var doc = Doc;
        if (doc == null) return;
        var t = raw.Trim().ToLowerInvariant();
        if (Command == Cmd.Text && step == 2)
        {
            var content = raw.Trim();
            if (content.Length > 0 && pts.Count > 0)
            {
                var o = M.NewObject("text", host.ActiveLayer);
                M.SetPos(o, pts[0].X, pts[0].Y);
                o["text"] = content;
                o["textSize"] = textHeight;
                doc.Edit("Text", d => M.ObjectArray(d).Add(o));
            }
            EndCommand();
            return;
        }
        if (Command == Cmd.SheetText && step == 1)
        {
            var content = raw.Trim();
            if (content.Length > 0 && pts.Count > 0)
            {
                var o = M.NewObject("text", J.S(J.Objs(doc.D, "layers").FirstOrDefault(), "id"));
                M.SetPos(o, pts[0].X, pts[0].Y);
                o["text"] = content;
                o["textSize"] = 4.0;
                EditSheet("Sheet Text", sh => (sh["objects"] as JsonArray ?? (JsonArray)(sh["objects"] = new JsonArray())).Add(o));
            }
            EndCommand();
            return;
        }
        if (Command == Cmd.Layer)
        {
            if (raw.Trim().Length > 0) host.MakeLayerCurrent(raw.Trim());
            EndCommand();
            return;
        }
        if (Command == Cmd.Scene)
        {
            var scene = J.Objs(doc.D, "scenes").FirstOrDefault(s => J.S(s, "name").ToLowerInvariant() == t);
            if (scene != null)
            {
                SetSelection(new HashSet<string>());
                doc.Edit("Show Scene", d => M.ApplyScene(d, J.S(scene, "id")));
                ZoomFit();
            }
            else if (t.Length > 0) Log($"No scene called \"{raw.Trim()}\".");
            EndCommand();
            return;
        }

        if (t.Length == 0)
        {
            if (windowStart != null)
            {
                windowStart = null;
                RefreshPrompt();
                return;
            }
            if (selecting)
            {
                if (Selection.Count == 0) EndCommand();
                else if (Command == Cmd.Erase)
                {
                    EraseSelection();
                    EndCommand();
                }
                else
                {
                    selecting = false;
                    RefreshPrompt();
                }
                return;
            }
            switch (Command)
            {
                case Cmd.None:
                    if (lastCmd != Cmd.None && lastCmd != Cmd.Tag && lastCmd != Cmd.Viewport && lastCmd != Cmd.SheetText) Start(lastCmd);
                    break;
                case Cmd.Pline: FinishPolyline(false); break;
                case Cmd.Text:
                    if (step == 1)
                    {
                        step = 2;
                        RefreshPrompt();
                    }
                    else EndCommand();
                    break;
                case Cmd.Zoom:
                    ZoomFit();
                    EndCommand();
                    break;
                default: EndCommand(); break;
            }
            return;
        }

        if (Command == Cmd.None)
        {
            if (!Run(t) && !host.AppCommand(t)) Log($"Unknown command \"{raw.Trim()}\". Type HELP for the list.", "problem");
            return;
        }

        if (WantsPoint && Enum.GetValues<SnapKind>().FirstOrDefault(k => Snapper.Abbreviation(k) == t || k.ToString().ToLowerInvariant() == t) is var kind &&
            (Snapper.Abbreviation(kind) == t || kind.ToString().ToLowerInvariant() == t))
        {
            snapOverride = kind;
            Log(kind + " of");
            return;
        }

        switch (Command)
        {
            case Cmd.Line:
                if (t is "c" or "close")
                {
                    if (pts.Count >= 3) AddLine(pts[^1], pts[0]);
                    EndCommand();
                    return;
                }
                if (t is "u" or "undo")
                {
                    if (made.Count > 0)
                    {
                        var id = made[^1];
                        made.RemoveAt(made.Count - 1);
                        doc.Edit("Undo Segment", d => RemoveObjects(d, new HashSet<string> { id }));
                        if (pts.Count > 1) pts.RemoveAt(pts.Count - 1);
                    }
                    RefreshPrompt();
                    return;
                }
                break;
            case Cmd.Pline:
                if (t is "c" or "close")
                {
                    FinishPolyline(true);
                    return;
                }
                if (t is "u" or "undo")
                {
                    if (pts.Count > 1) pts.RemoveAt(pts.Count - 1);
                    RefreshPrompt();
                    return;
                }
                break;
            case Cmd.Label:
                if (t is "r" or "reset")
                {
                    ChangeLabels("Reset Label", o => { o.Remove("labelDX"); o.Remove("labelDY"); o.Remove("labelArrow"); o.Remove("labelLevel"); });
                    EndCommand();
                    return;
                }
                if (t is "a" or "arrow")
                {
                    var on = !J.IsTrue(SelectedFixtures().FirstOrDefault(), "labelArrow");
                    ChangeLabels("Label Arrow", o => { if (on) o["labelArrow"] = true; else o.Remove("labelArrow"); });
                    Log("Leader arrow " + (on ? "on" : "off") + " (it shows once the label is moved away from the fixture)");
                    return;
                }
                if (t is "l" or "level")
                {
                    var on = !J.IsTrue(SelectedFixtures().FirstOrDefault(), "labelLevel");
                    ChangeLabels("Level Label", o => { if (on) o["labelLevel"] = true; else o.Remove("labelLevel"); });
                    Log("Level label " + (on ? "on" : "off"));
                    return;
                }
                break;
            case Cmd.Zoom:
                if (t is "w" or "window")
                {
                    Command = Cmd.ZoomWindow;
                    pts.Clear();
                    RefreshPrompt();
                }
                else
                {
                    ZoomFit();
                    EndCommand();
                }
                return;
        }

        if (WantsPoint && ParsePoint(t) is (double, double) p)
        {
            Point(p);
            return;
        }
        if (M.ParseNum(t) is double v)
        {
            if (Command == Cmd.Text && step == 1)
            {
                if (v > 0) textHeight = v;
                step = 2;
                RefreshPrompt();
                return;
            }
            if (Command == Cmd.Circle && pts.Count > 0)
            {
                AddCircle(pts[0], Math.Abs(v));
                EndCommand();
                return;
            }
            if (Command == Cmd.Rotate && pts.Count > 0)
            {
                RotateSelection(pts[0], v);
                EndCommand();
                return;
            }
            if (Command == Cmd.Scale && pts.Count > 0)
            {
                if (v > 0) ScaleSelection(pts[0], v);
                EndCommand();
                return;
            }
            if (WantsPoint && pts.Count > 0)
            {
                var r = pts[^1];
                double dx = cursor.X - r.X, dy = cursor.Y - r.Y, len = Math.Sqrt(dx * dx + dy * dy);
                if (len > 0)
                {
                    Point((r.X + dx / len * v, r.Y + dy / len * v));
                    return;
                }
            }
        }
        Log("Invalid input.", "problem");
    }

    /// A point for the running command, from a click or typed coordinates.
    void Point((double X, double Y) p)
    {
        var doc = Doc;
        if (doc == null) return;
        snapOverride = null;
        switch (Command)
        {
            case Cmd.Line:
                if (pts.Count > 0) AddLine(pts[^1], p);
                pts.Add(p);
                break;
            case Cmd.Pline:
                pts.Add(p);
                break;
            case Cmd.Circle:
                if (pts.Count > 0)
                {
                    AddCircle(pts[0], M.Dist(pts[0], p));
                    EndCommand();
                    return;
                }
                pts.Add(p);
                break;
            case Cmd.Tag:
                if (pendingLocation is JsonObject l)
                {
                    var o = M.NewObject("text", host.ActiveLayer);
                    M.SetPos(o, p.X, p.Y);
                    o["text"] = J.S(l, "name");
                    o["tag"] = true;
                    o["lxID"] = J.S(l, "id");
                    o["textSize"] = Math.Max(80, J.D(doc.D, "labelSize", 130) * 2);
                    doc.Edit("Location Label", d => M.ObjectArray(d).Add(o));
                    Log("Location label " + J.S(l, "name") + " placed. Its tape colours follow Lx Book.");
                }
                pendingLocation = null;
                EndCommand();
                return;
            case Cmd.Dist:
                if (pts.Count > 0)
                {
                    Log(MeasureText(pts[0], p), "measure");
                    EndCommand();
                    return;
                }
                pts.Add(p);
                break;
            case Cmd.Rect:
                if (pts.Count > 0)
                {
                    double x0 = Math.Min(pts[0].X, p.X), y0 = Math.Min(pts[0].Y, p.Y), w = Math.Abs(p.X - pts[0].X), h = Math.Abs(p.Y - pts[0].Y);
                    if (w > 0 && h > 0)
                    {
                        var o = M.NewObject("rect", host.ActiveLayer);
                        M.SetPos(o, x0, y0);
                        o["w"] = w;
                        o["h"] = h;
                        doc.Edit("Rectangle", d => M.ObjectArray(d).Add(o));
                    }
                    EndCommand();
                    return;
                }
                pts.Add(p);
                break;
            case Cmd.Text:
                pts.Clear();
                pts.Add(p);
                step = 1;
                break;
            case Cmd.SheetText:
                pts.Clear();
                pts.Add(p);
                step = 1;
                break;
            case Cmd.Move:
                if (pts.Count > 0)
                {
                    double dx = p.X - pts[0].X, dy = p.Y - pts[0].Y;
                    var ids = MovingIDs(doc.D);
                    doc.Edit("Move", d => { foreach (var o in M.Objects(d).Where(o => ids.Contains(M.Id(o)))) M.Translate(o, dx, dy); });
                    EndCommand();
                    return;
                }
                pts.Add(p);
                break;
            case Cmd.Copy:
                if (pts.Count > 0)
                {
                    var ids = MovingIDs(doc.D);
                    InsertCopies(M.Objects(doc.D).Where(o => ids.Contains(M.Id(o))).ToList(), p.X - pts[0].X, p.Y - pts[0].Y, "Copy", false);
                }
                else pts.Add(p);
                break;
            case Cmd.Rotate:
                if (pts.Count > 0)
                {
                    RotateSelection(pts[0], Math.Atan2(p.Y - pts[0].Y, p.X - pts[0].X) * 180 / Math.PI);
                    EndCommand();
                    return;
                }
                pts.Add(p);
                break;
            case Cmd.Scale:
                if (pts.Count > 0)
                {
                    var r = ScaleReference(pts[0]);
                    if (r > 0) ScaleSelection(pts[0], Math.Max(0.01, M.Dist(pts[0], p) / r));
                    EndCommand();
                    return;
                }
                pts.Add(p);
                break;
            case Cmd.Truss:
                if (pts.Count > 0)
                {
                    var a = pts[0];
                    var run = TrussRun(a, p);
                    var rad = run.Angle * Math.PI / 180;
                    var sections = new List<JsonObject>();
                    for (int i = 0; i < run.Count; i++)
                    {
                        var o = M.NewObject("truss", host.ActiveLayer);
                        o["typeID"] = host.CurrentTrussType;
                        o["rot"] = run.Angle;
                        M.SetPos(o, a.X + Math.Cos(rad) * run.Length * i, a.Y + Math.Sin(rad) * run.Length * i);
                        sections.Add(o);
                    }
                    doc.Edit("Truss", d => { foreach (var o in sections) M.ObjectArray(d).Add(o); });
                    pts.Clear();
                }
                else pts.Add(p);
                break;
            case Cmd.Fixture:
                PlaceFixture(p);
                break;
            case Cmd.Label:
                if (SelectedFixtures().FirstOrDefault() is JsonObject first)
                {
                    var home = M.DefaultLabelAnchor(first, doc.D);
                    double dx = p.X - home.X, dy = p.Y - home.Y;
                    ChangeLabels("Move Label", o => { o["labelDX"] = dx; o["labelDY"] = dy; });
                }
                EndCommand();
                return;
            case Cmd.ZoomWindow:
                if (pts.Count > 0)
                {
                    FitBox(Math.Min(pts[0].X, p.X), Math.Min(pts[0].Y, p.Y), Math.Max(pts[0].X, p.X), Math.Max(pts[0].Y, p.Y), 1);
                    EndCommand();
                    return;
                }
                pts.Add(p);
                break;
            case Cmd.Viewport:
                if (pts.Count > 0)
                {
                    double x0 = Math.Min(pts[0].X, p.X), y0 = Math.Min(pts[0].Y, p.Y), w = Math.Abs(p.X - pts[0].X), h = Math.Abs(p.Y - pts[0].Y);
                    if (w > 5 && h > 5)
                    {
                        var v = Sheets.NewViewport(doc.D, x0, y0, w, h, null);
                        EditSheet("New Viewport", sh => (sh["viewports"] as JsonArray ?? (JsonArray)(sh["viewports"] = new JsonArray())).Add(v));
                        SelectSheetItem(J.S(v, "id"));
                    }
                    EndCommand();
                    return;
                }
                pts.Add(p);
                break;
        }
        RefreshPrompt();
        InvalidateVisual();
    }

    public static string MeasureText((double X, double Y) a, (double X, double Y) b)
    {
        double dx = b.X - a.X, dy = b.Y - a.Y, d = Math.Sqrt(dx * dx + dy * dy);
        var inches = d / 25.4;
        var feet = Math.Floor(inches / 12);
        var rest = inches - feet * 12;
        var ang = Math.Atan2(dy, dx) * 180 / Math.PI;
        return $"Distance = {d:0} mm ({d / 1000:0.000} m, {feet:0}' {rest:0.0}\"), angle {ang:0.#}°, across {dx:0}, up {dy:0}";
    }

    // ---------------------------------------------------------------- making and changing

    static void RemoveObjects(JsonObject d, ICollection<string> ids)
    {
        var a = M.ObjectArray(d);
        for (int i = a.Count - 1; i >= 0; i--) if (ids.Contains(J.S(a[i], "id"))) a.RemoveAt(i);
    }

    void AddLine((double X, double Y) a, (double X, double Y) b)
    {
        if (Doc == null || M.Dist(a, b) < 0.01) return;
        var o = M.NewObject("line", host.ActiveLayer);
        M.SetPts(o, new[] { a, b });
        Doc.Edit("Line", d => M.ObjectArray(d).Add(o));
        made.Add(M.Id(o));
    }

    void AddCircle((double X, double Y) c, double r)
    {
        if (Doc == null || r <= 0) return;
        var o = M.NewObject("ellipse", host.ActiveLayer);
        M.SetPos(o, c.X - r, c.Y - r);
        o["w"] = r * 2;
        o["h"] = r * 2;
        Doc.Edit("Circle", d => M.ObjectArray(d).Add(o));
    }

    void FinishPolyline(bool closed)
    {
        if (Doc != null && pts.Count >= 2)
        {
            var o = M.NewObject("polyline", host.ActiveLayer);
            M.SetPts(o, pts);
            o["closed"] = closed;
            Doc.Edit("Polyline", d => M.ObjectArray(d).Add(o));
        }
        EndCommand();
    }

    (double Angle, int Count, double Length) TrussRun((double X, double Y) a, (double X, double Y) b)
    {
        var t = M.TrussType(host.CurrentTrussType);
        var angle = Math.Atan2(b.Y - a.Y, b.X - a.X) * 180 / Math.PI;
        var count = Math.Max(1, (int)Math.Round(M.Dist(a, b) / t.Length));
        return (angle, count, t.Length);
    }

    JsonObject? FixtureGhost((double X, double Y) p)
    {
        if (Doc == null) return null;
        var type = M.FixtureType(Doc.D, host.CurrentFixtureType);
        var o = M.NewObject("fixture", host.ActiveLayer);
        o["typeID"] = J.S(type, "id");
        o["w"] = J.D(type, "width", 400);
        o["h"] = J.D(type, "depth", 400);
        M.SetPos(o, p.X, p.Y);
        M.Attach(o, Doc.D, 600);
        return o;
    }

    void PlaceFixture((double X, double Y) p)
    {
        if (Doc == null || FixtureGhost(p) is not JsonObject o) return;
        var type = M.FixtureType(Doc.D, J.S(o, "typeID"));
        var numbered = J.S(type, "category") != "hoist";
        if (numbered) o["unit"] = ((int)J.D(Doc.D, "nextUnit", 1)).ToString(CultureInfo.InvariantCulture);
        Doc.Edit("Place " + J.S(type, "name"), d =>
        {
            M.ObjectArray(d).Add(o);
            if (numbered) d["nextUnit"] = (int)J.D(d, "nextUnit", 1) + 1;
        });
    }

    HashSet<string> MovingIDs(JsonObject d)
    {
        var ids = new HashSet<string>(Selection);
        ids.UnionWith(M.AttachedFixtures(d, Selection));
        return ids;
    }

    void RotateSelection((double X, double Y) b, double deg)
    {
        if (Doc == null) return;
        var ids = MovingIDs(Doc.D);
        Doc.Edit("Rotate", d => { foreach (var o in M.Objects(d).Where(o => ids.Contains(M.Id(o)))) M.Rotate(o, b.X, b.Y, deg); });
    }

    void ScaleSelection((double X, double Y) b, double f)
    {
        if (Doc == null) return;
        var ids = MovingIDs(Doc.D);
        Doc.Edit("Scale", d => { foreach (var o in M.Objects(d).Where(o => ids.Contains(M.Id(o)))) M.Scale(o, b.X, b.Y, f); });
        Log("Scaled by " + M.Num(f) + ". Truss and fixtures keep their real size.");
    }

    double ScaleReference((double X, double Y) b)
    {
        if (Doc == null) return 0;
        double far = 0;
        foreach (var o in M.Objects(Doc.D).Where(o => Selection.Contains(M.Id(o))))
        {
            var bb = M.Bounds(o);
            if (bb == null) continue;
            var (x0, y0, x1, y1) = bb.Value;
            foreach (var c in new[] { (x0, y0), (x1, y0), (x1, y1), (x0, y1) }) far = Math.Max(far, M.Dist(b, c));
        }
        return far;
    }

    /// Insert Location Label: the next click places the tag.
    public void PlaceLocation(JsonObject location)
    {
        if (SheetID != null) ShowSheet(null);
        pendingLocation = location;
        Start(Cmd.Tag);
    }

    List<JsonObject> SelectedFixtures() => Doc == null ? new() : M.Objects(Doc.D).Where(o => Selection.Contains(M.Id(o)) && M.Kind(o) == "fixture").ToList();

    void ChangeLabels(string name, Action<JsonObject> change)
    {
        var ids = Selection;
        Doc?.Edit(name, d => { foreach (var o in M.Objects(d).Where(o => ids.Contains(M.Id(o)) && M.Kind(o) == "fixture")) change(o); });
    }

    public void GroupSelection()
    {
        if (Doc == null) return;
        if (Selection.Count < 2)
        {
            Log("Select two or more objects, then GROUP.");
            return;
        }
        var ids = Selection;
        var g = M.NewId();
        Doc.Edit("Group", d => { foreach (var o in M.Objects(d).Where(o => ids.Contains(M.Id(o)))) o["group"] = g; });
        Log($"Grouped {ids.Count} objects.");
    }

    public void UngroupSelection()
    {
        if (Doc == null || Selection.Count == 0) return;
        var ids = M.WithGroups(Doc.D, Selection);
        Doc.Edit("Ungroup", d => { foreach (var o in M.Objects(d).Where(o => ids.Contains(M.Id(o)))) o.Remove("group"); });
        Log("Ungrouped.");
    }

    public void EraseSelection()
    {
        if (Doc == null) return;
        if (SheetID != null)
        {
            if (SheetSel == null) return;
            var id = SheetSel;
            EditSheet("Erase", sh =>
            {
                foreach (var key in new[] { "viewports", "objects" })
                    if (sh[key] is JsonArray a)
                        for (int i = a.Count - 1; i >= 0; i--) if (J.S(a[i], "id") == id) a.RemoveAt(i);
            });
            SelectSheetItem(null);
            return;
        }
        if (Selection.Count == 0) return;
        var ids = Selection;
        var lockedOut = M.Objects(Doc.D).Where(o => ids.Contains(M.Id(o)) && M.IsLocked(Doc.D, o)).Select(M.Id).ToHashSet();
        var gone = ids.Where(i => !lockedOut.Contains(i)).ToHashSet();
        Doc.Edit("Erase", d =>
        {
            RemoveObjects(d, gone);
            foreach (var o in M.Objects(d)) if (gone.Contains(J.S(o, "attachedTo"))) o.Remove("attachedTo");
        });
        SetSelection(new HashSet<string>());
    }

    /// Copies of objects moved by (dx, dy), with new IDs; copied fixtures get new numbers and aren't linked to Lx Book.
    public void InsertCopies(List<JsonObject> source, double dx, double dy, string name, bool select)
    {
        if (Doc == null || source.Count == 0) return;
        var idMap = source.ToDictionary(M.Id, _ => M.NewId());
        var groupMap = new Dictionary<string, string>();
        var copies = new List<JsonObject>();
        foreach (var s in source)
        {
            var o = (JsonObject)s.DeepClone();
            o["id"] = idMap[M.Id(s)];
            if (J.S(o, "group") is var g && g.Length > 0)
            {
                if (!groupMap.TryGetValue(g, out var ng)) groupMap[g] = ng = M.NewId();
                o["group"] = ng;
            }
            if (J.S(o, "attachedTo") is var at && at.Length > 0)
            {
                if (idMap.TryGetValue(at, out var nat)) o["attachedTo"] = nat; else o.Remove("attachedTo");
            }
            o.Remove("lxID");
            o.Remove("lxMotor");
            if (Doc.D["layers"] is JsonArray && M.Layer(Doc.D, J.S(o, "layer")) == null) o["layer"] = host.ActiveLayer;
            M.NormalizeObject(o, host.ActiveLayer);
            M.Translate(o, dx, dy);
            copies.Add(o);
        }
        Doc.Edit(name, d =>
        {
            var next = (int)J.D(d, "nextUnit", 1);
            foreach (var o in copies)
            {
                if (M.Kind(o) == "fixture" && M.Category(d, o) != "hoist" && J.S(o, "unit").Length > 0)
                {
                    o["unit"] = next.ToString(CultureInfo.InvariantCulture);
                    next++;
                }
                if (M.Kind(o) == "fixture")
                {
                    o["universe"] = "";
                    o["address"] = "";
                    o["circuit"] = "";
                }
                M.ObjectArray(d).Add(o);
            }
            d["nextUnit"] = next;
        });
        if (select) SetSelection(copies.Select(M.Id).ToHashSet());
    }

    // ---------------------------------------------------------------- grips

    public sealed record Grip(string Id, string Kind, int N, (double X, double Y) At);

    List<Grip> Grips(JsonObject d)
    {
        var outp = new List<Grip>();
        if (Command != Cmd.None || Selection.Count == 0 || Selection.Count > 40 || SheetID != null) return outp;
        foreach (var o in M.Objects(d).Where(o => Selection.Contains(M.Id(o))))
        {
            if (M.IsLocked(d, o)) continue;
            var id = M.Id(o);
            if (M.UsesPoints(o))
            {
                var ps = M.Pts(o);
                for (int i = 0; i < ps.Count; i++) outp.Add(new Grip(id, "vertex", i, ps[i]));
                continue;
            }
            var (bx, by, bw, bh) = PlotPdf.LocalBox(o);
            switch (M.Kind(o))
            {
                case "rect":
                case "ellipse":
                    var corners = new[] { (bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh) };
                    for (int i = 0; i < 4; i++) outp.Add(new Grip(id, "corner", i, M.ToWorld(o, corners[i].Item1, corners[i].Item2)));
                    outp.Add(new Grip(id, "move", 0, M.ToWorld(o, bx + bw / 2, by + bh / 2)));
                    break;
                case "text":
                    outp.Add(new Grip(id, "move", 0, M.Pos(o)));
                    if (!J.IsTrue(o, "tag")) outp.Add(new Grip(id, "size", 0, M.ToWorld(o, bx + bw, by + bh)));
                    break;
                case "truss":
                    outp.Add(new Grip(id, "move", 0, M.Pos(o)));
                    outp.Add(new Grip(id, "rotate", 0, M.ToWorld(o, bx + bw, 0)));
                    continue;
                default:
                    outp.Add(new Grip(id, "move", 0, M.Pos(o)));
                    break;
            }
            outp.Add(new Grip(id, "rotate", 0, M.ToWorld(o, bx + bw / 2, by + bh + 26 / ViewScale)));
        }
        return outp;
    }

    Grip? GripAt(Point p)
    {
        if (Doc == null) return null;
        foreach (var g in Grips(Doc.D))
        {
            var s = ToScreen(g.At);
            if (Math.Abs(s.X - p.X) <= 6 && Math.Abs(s.Y - p.Y) <= 6) return g;
        }
        return null;
    }

    (double X, double Y) GripPoint((double X, double Y) raw, JsonObject snap, Grip g)
    {
        if (Osnap && Snapper.Find(raw, snap, 11 / ViewScale, Modes, null, new HashSet<string> { g.Id }) is SnapHit hit) return hit.Point;
        if (J.Has(snap, "snapGrid") && J.D(snap, "gridSize") > 0)
        {
            var s = J.D(snap, "gridSize");
            return (Math.Round(raw.X / s) * s, Math.Round(raw.Y / s) * s);
        }
        return raw;
    }

    JsonObject ApplyGrip(Grip g, JsonObject snap, (double X, double Y) p, (double X, double Y) raw, bool shift)
    {
        var d = (JsonObject)snap.DeepClone();
        var o = M.Find(d, g.Id);
        if (o == null) return d;
        var (bx, by, bw, bh) = PlotPdf.LocalBox(o);
        var ids = new HashSet<string> { g.Id };
        ids.UnionWith(M.AttachedFixtures(d, ids));
        switch (g.Kind)
        {
            case "vertex":
                var ps = M.Pts(o);
                if (g.N < ps.Count) ps[g.N] = p;
                M.SetPts(o, ps);
                break;
            case "move":
                double dx = p.X - g.At.X, dy = p.Y - g.At.Y;
                foreach (var x in M.Objects(d).Where(x => ids.Contains(M.Id(x)))) M.Translate(x, dx, dy);
                if (M.Kind(o) == "fixture") M.Attach(o, d, 600);
                break;
            case "rotate":
                var pivot = M.Kind(o) is "truss" or "fixture" ? M.Pos(o) : M.ToWorld(o, bx + bw / 2, by + bh / 2);
                var from = Math.Atan2(g.At.Y - pivot.Y, g.At.X - pivot.X);
                var to = Math.Atan2(raw.Y - pivot.Y, raw.X - pivot.X);
                var a = (to - from) * 180 / Math.PI;
                if (shift) a = Math.Round(a / 15) * 15;
                foreach (var x in M.Objects(d).Where(x => ids.Contains(M.Id(x)))) M.Rotate(x, pivot.X, pivot.Y, a);
                break;
            case "corner":
                var corners = new[] { (bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh) };
                var fixedC = corners[(g.N + 2) % 4];
                var local = M.ToLocal(o, p.X, p.Y);
                double nw = Math.Abs(local.X - fixedC.Item1), nh = Math.Abs(local.Y - fixedC.Item2);
                if (shift && bw > 0 && bh > 0)
                {
                    var f = Math.Max(nw / bw, nh / bh);
                    nw = bw * f;
                    nh = bh * f;
                }
                if (nw < 1 || nh < 1) return d;
                var minX = local.X < fixedC.Item1 ? fixedC.Item1 - nw : fixedC.Item1;
                var minY = local.Y < fixedC.Item2 ? fixedC.Item2 - nh : fixedC.Item2;
                var origin = M.ToWorld(o, minX, minY);
                M.SetPos(o, origin.X, origin.Y);
                o["w"] = nw;
                o["h"] = nh;
                break;
            case "size":
                var refd = M.Dist(g.At, M.Pos(o));
                if (refd > 0)
                {
                    var f = M.Dist(raw, M.Pos(o)) / refd;
                    if (f > 0.05) o["textSize"] = J.D(o, "textSize") * f;
                }
                break;
        }
        return d;
    }

    // ---------------------------------------------------------------- the cursor and snapping

    (double X, double Y) Snapped(Point screen, bool forPoint)
    {
        var raw = ToWorld(screen);
        snapHit = null;
        if (Doc == null || !forPoint) return raw;
        var reference = pts.Count > 0 ? pts[^1] : ((double, double)?)null;
        if (SheetID == null && (Osnap || snapOverride != null))
        {
            var modes = snapOverride is SnapKind k ? new HashSet<SnapKind> { k } : Modes;
            var skip = Command is Cmd.Move or Cmd.Copy or Cmd.Rotate or Cmd.Scale && pts.Count > 0 ? (ICollection<string>)Selection : null;
            if (Snapper.Find(raw, Doc.D, 11 / ViewScale, modes, reference, skip) is SnapHit hit)
            {
                snapHit = hit;
                return hit.Point;
            }
        }
        var p = raw;
        if (Ortho && reference is (double, double) r)
        {
            if (Math.Abs(p.X - r.X) >= Math.Abs(p.Y - r.Y)) p = (p.X, r.Y); else p = (r.X, p.Y);
        }
        if (SheetID == null && J.Has(Doc.D, "snapGrid") && J.D(Doc.D, "gridSize") > 0)
        {
            var s = J.D(Doc.D, "gridSize");
            p = Ortho && reference is (double, double) r2
                ? (Math.Abs(p.X - r2.X) >= Math.Abs(p.Y - r2.Y) ? (Math.Round(p.X / s) * s, r2.Y) : (r2.X, Math.Round(p.Y / s) * s))
                : (Math.Round(p.X / s) * s, Math.Round(p.Y / s) * s);
        }
        return p;
    }

    // ---------------------------------------------------------------- mouse

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        ZoomBy(e.Delta > 0 ? 1.2 : 1 / 1.2, e.GetPosition(this));
        e.Handled = true;
    }

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        var p = e.GetPosition(this);
        if (e.ChangedButton == MouseButton.Middle)
        {
            if (e.ClickCount == 2)
            {
                ZoomFit();
                return;
            }
            panning = true;
            panLast = p;
            CaptureMouse();
            Cursor = Cursors.SizeAll;
            return;
        }
        if (e.ChangedButton == MouseButton.Right)
        {
            Enter("");
            return;
        }
        if (e.ChangedButton != MouseButton.Left || Doc == null) return;
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        pressView = p;
        pressWorld = ToWorld(p);
        didMove = false;
        CaptureMouse();

        if (gripHeld && activeGrip != null)
        {
            // second click puts a held grip down
            FinishGrip(p, shift);
            return;
        }
        if (WantsPoint && !selecting)
        {
            Point(Snapped(p, true));
            ReleaseMouseCapture();
            return;
        }
        if (SheetID != null)
        {
            SheetPress(p);
            return;
        }
        if (Command == Cmd.None && GripAt(p) is Grip g)
        {
            activeGrip = g;
            snapshot = Doc.D.ToJsonString();
            return;
        }
        if (LabelMode && Command == Cmd.None && LabelAt(pressWorld) is JsonObject fx)
        {
            labelDrag = (M.Id(fx), J.D(fx, "labelDX"), J.D(fx, "labelDY"));
            snapshot = Doc.D.ToJsonString();
            return;
        }
        if (windowStart != null)
        {
            FinishWindow(pressWorld);
            ReleaseMouseCapture();
            return;
        }
        var hit = M.TopObject(Doc.D, pressWorld, 5 / ViewScale);
        if (hit != null)
        {
            var picked = Keyboard.Modifiers.HasFlag(ModifierKeys.Alt) ? new HashSet<string> { hit } : M.WithGroups(Doc.D, new[] { hit });
            var s = new HashSet<string>(Selection);
            if (shift) { if (s.Contains(hit)) s.ExceptWith(picked); else s.UnionWith(picked); }
            else if (selecting) s.UnionWith(picked);
            else if (!s.Contains(hit)) s = picked;
            SetSelection(s);
            pressedObject = !shift && Command == Cmd.None;
            return;
        }
        pressedEmpty = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var p = e.GetPosition(this);
        mouse = p;
        if (panning)
        {
            offX -= (p.X - panLast.X) / ViewScale;
            offY += (p.Y - panLast.Y) / ViewScale;
            panLast = p;
            InvalidateVisual();
            return;
        }
        cursor = Snapped(p, WantsPoint || activeGrip != null);
        host.SetCoords(cursor.X, cursor.Y);
        var doc = Doc;
        if (doc != null && e.LeftButton == MouseButtonState.Pressed && (Math.Abs(p.X - pressView.X) > 3 || Math.Abs(p.Y - pressView.Y) > 3)) didMove = true;
        if (doc != null && activeGrip != null && (didMove || gripHeld) && snapshot != null)
        {
            var snap = (JsonObject)JsonNode.Parse(snapshot)!;
            var raw = ToWorld(p);
            doc.SetLive(ApplyGrip(activeGrip, snap, GripPoint(raw, snap, activeGrip), raw, Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)));
        }
        else if (doc != null && labelDrag is (var id, var ldx, var ldy) && didMove && snapshot != null)
        {
            var snap = (JsonObject)JsonNode.Parse(snapshot)!;
            var w = ToWorld(p);
            if (M.Find(snap, id) is JsonObject o)
            {
                o["labelDX"] = ldx + (w.X - pressWorld.X);
                o["labelDY"] = ldy + (w.Y - pressWorld.Y);
            }
            doc.SetLive(snap);
        }
        else if (SheetID != null && sheetDragStart != null && didMove) SheetDrag(p);
        else if (pressedEmpty && didMove) draggingWindow = true;
        if (pressedEmpty || windowStart != null) windowEnd = ToWorld(p);
        InvalidateVisual();
    }

    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        var p = e.GetPosition(this);
        if (e.ChangedButton == MouseButton.Middle && panning)
        {
            panning = false;
            ReleaseMouseCapture();
            Cursor = Cursors.Cross;
            InvalidateVisual();
            return;
        }
        if (e.ChangedButton != MouseButton.Left || Doc == null) return;
        ReleaseMouseCapture();
        if (activeGrip != null && !gripHeld)
        {
            if (didMove) FinishGrip(p, Keyboard.Modifiers.HasFlag(ModifierKeys.Shift));
            else
            {
                gripHeld = true;   // picked up with a click: it follows the cursor until the next click
                Log("Grip picked up: move, then click to put it down (Esc puts it back).");
            }
            return;
        }
        if (labelDrag != null)
        {
            if (didMove && snapshot != null) Doc.CommitLive(snapshot, "Move Label");
            labelDrag = null;
            snapshot = null;
            return;
        }
        if (SheetID != null)
        {
            SheetRelease();
            return;
        }
        if (pressedObject && didMove)
        {
            var w = ToWorld(p);
            double dx = w.X - pressWorld.X, dy = w.Y - pressWorld.Y;
            if (J.Has(Doc.D, "snapGrid") && J.D(Doc.D, "gridSize") > 0)
            {
                var s = J.D(Doc.D, "gridSize");
                dx = Math.Round(dx / s) * s;
                dy = Math.Round(dy / s) * s;
            }
            var ids = MovingIDs(Doc.D);
            var locked = M.Objects(Doc.D).Where(o => ids.Contains(M.Id(o)) && M.IsLocked(Doc.D, o)).Select(M.Id).ToHashSet();
            Doc.Edit("Move", d =>
            {
                foreach (var o in M.Objects(d).Where(o => ids.Contains(M.Id(o)) && !locked.Contains(M.Id(o))))
                {
                    M.Translate(o, dx, dy);
                    if (M.Kind(o) == "fixture" && !ids.Contains(J.S(o, "attachedTo"))) M.Attach(o, d, 600);
                }
            });
        }
        else if (pressedEmpty)
        {
            if (draggingWindow) FinishWindow(ToWorld(p), ToWorld(pressView));
            else
            {
                windowStart = pressWorld;
                windowEnd = pressWorld;
                if (!selecting && Command == Cmd.None && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) && Selection.Count > 0) SetSelection(new HashSet<string>());
            }
        }
        pressedObject = pressedEmpty = draggingWindow = false;
        InvalidateVisual();
    }

    void FinishGrip(Point p, bool shift)
    {
        if (Doc == null || activeGrip == null || snapshot == null) return;
        var snap = (JsonObject)JsonNode.Parse(snapshot)!;
        var raw = ToWorld(p);
        Doc.SetLive(ApplyGrip(activeGrip, snap, GripPoint(raw, snap, activeGrip), raw, shift));
        Doc.CommitLive(snapshot, activeGrip.Kind switch { "move" => "Move", "rotate" => "Rotate", "vertex" => "Stretch", _ => "Resize" });
        activeGrip = null;
        gripHeld = false;
        snapshot = null;
        ReleaseMouseCapture();
    }

    /// Ends a selection window: left to right picks what is wholly inside, right to left also what it touches.
    void FinishWindow((double X, double Y) end, (double X, double Y)? start = null)
    {
        if (Doc == null) return;
        var a = start ?? windowStart ?? end;
        windowStart = null;
        double x0 = Math.Min(a.X, end.X), x1 = Math.Max(a.X, end.X), y0 = Math.Min(a.Y, end.Y), y1 = Math.Max(a.Y, end.Y);
        var crossing = end.X < a.X;
        var found = new HashSet<string>();
        foreach (var o in M.Objects(Doc.D))
        {
            if (!M.IsVisible(Doc.D, o) || M.IsLocked(Doc.D, o)) continue;
            var bb = M.Bounds(o);
            if (bb == null) continue;
            var b = bb.Value;
            var inside = b.X0 >= x0 && b.X1 <= x1 && b.Y0 >= y0 && b.Y1 <= y1;
            var touches = !(b.X1 < x0 || b.X0 > x1 || b.Y1 < y0 || b.Y0 > y1);
            if (inside || (crossing && touches)) found.Add(M.Id(o));
        }
        found = M.WithGroups(Doc.D, found);
        var s = new HashSet<string>(Selection);
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) s.ExceptWith(found); else s.UnionWith(found);
        SetSelection(s);
        RefreshPrompt();
    }

    /// The fixture whose label is under the point (for Move Labels mode).
    JsonObject? LabelAt((double X, double Y) w)
    {
        if (Doc == null || J.IsFalse(Doc.D, "showLabels")) return null;
        var doc = new PlotPdf.Doc(Doc.D);
        foreach (var o in M.Objects(Doc.D).Reverse())
        {
            if (M.Kind(o) != "fixture" || !M.IsVisible(Doc.D, o) || M.IsLocked(Doc.D, o)) continue;
            var (bw, bh) = PlotPdf.BlockSize(o, doc);
            if (bw <= 0) continue;
            var (ax, ay) = M.DefaultLabelAnchor(o, Doc.D);
            ax += J.D(o, "labelDX");
            ay += J.D(o, "labelDY");
            if (Math.Abs(w.X - ax) <= bw / 2 && w.Y >= ay - bh * 0.1 && w.Y <= ay + bh) return o;
        }
        return null;
    }

    // ---------------------------------------------------------------- sheets: commands and mouse

    bool? SheetRun(string n)
    {
        switch (n)
        {
            case "mv": case "mview": case "viewport":
                Start(Cmd.Viewport);
                return true;
            case "t": case "text": case "dt": case "mt":
                Start(Cmd.SheetText);
                return true;
            case "e": case "erase": case "del": case "delete":
                EraseSelection();
                return true;
            case "fit":
                if (SelectedSheetItem() is JsonObject v && v["scale"] != null && Doc != null)
                {
                    var vid = J.S(v, "id");
                    EditSheet("Fit Viewport", sh => { if (J.Objs(sh, "viewports").FirstOrDefault(x => J.S(x, "id") == vid) is JsonObject vp) Sheets.Fit(vp, Doc.D); });
                }
                else Log("Select a viewport, then FIT.");
                return true;
            case "ze":
                ZoomFit();
                return true;
            case "u": case "undo": Doc?.Undo(); return true;
            case "redo": Doc?.Redo(); return true;
        }
        return null;
    }

    void SheetPress(Point p)
    {
        var sh = Sheet();
        if (sh == null) return;
        var w = ToWorld(p);
        foreach (var o in J.Objs(sh, "objects").Reverse())
            if (M.Hit(o, w, 3 / ViewScale))
            {
                SelectSheetItem(M.Id(o));
                var (x, y) = M.Pos(o);
                sheetDragStart = (x, y, 0, 0);
                snapshot = Doc!.D.ToJsonString();
                return;
            }
        foreach (var v in J.Objs(sh, "viewports").Reverse())
        {
            double x = J.D(v, "x"), y = J.D(v, "y"), vw = J.D(v, "w"), vh = J.D(v, "h");
            if (w.X >= x && w.X <= x + vw && w.Y >= y && w.Y <= y + vh)
            {
                SelectSheetItem(J.S(v, "id"));
                if (!J.IsTrue(v, "locked"))
                {
                    sheetDragStart = (x, y, vw, vh);
                    snapshot = Doc!.D.ToJsonString();
                }
                return;
            }
        }
        SelectSheetItem(null);
    }

    void SheetDrag(Point p)
    {
        if (Doc == null || snapshot == null || sheetDragStart is not (var x, var y, _, _) || SheetSel == null) return;
        var w = ToWorld(p);
        var snap = (JsonObject)JsonNode.Parse(snapshot)!;
        var sh = J.Objs(snap, "sheets").FirstOrDefault(s => J.S(s, "id") == SheetID);
        var item = J.Objs(sh, "viewports").Concat(J.Objs(sh, "objects")).FirstOrDefault(i => J.S(i, "id") == SheetSel);
        if (item == null) return;
        double nx = Math.Round(x + w.X - pressWorld.X), ny = Math.Round(y + w.Y - pressWorld.Y);
        if (item["scale"] != null)
        {
            item["x"] = nx;
            item["y"] = ny;
        }
        else M.SetPos(item, nx, ny);
        Doc.SetLive(snap);
    }

    void SheetRelease()
    {
        if (Doc != null && snapshot != null && didMove) Doc.CommitLive(snapshot, "Move on Sheet");
        snapshot = null;
        sheetDragStart = null;
    }

    // ---------------------------------------------------------------- painting

    protected override void OnRender(DrawingContext dc)
    {
        var doc = Doc;
        var size = new Rect(0, 0, ActualWidth, ActualHeight);
        if (doc == null)
        {
            dc.DrawRectangle(Desk, null, size);
            return;
        }
        if (SheetID != null)
        {
            RenderSheet(dc, doc, size);
            return;
        }
        dc.DrawRectangle(Brushes.White, null, size);
        if (ShowGrid) DrawGrid(dc, doc.D);

        // the drawing, kept as a picture until it or the zoom changes
        var stale = kept == null || keptVersion != version || keptSheet != null || (Math.Abs(keptScale - ViewScale) / ViewScale > 0.02 && !redrawSoon.IsEnabled);
        if (stale)
        {
            var g = new DrawingGroup();
            using (var gc = g.Open())
            {
                var surface = new ScreenSurface(gc, ViewScale);
                PlotPdf.DrawModelOn(surface, doc.D, ViewScale * 0.9);
                surface.Finish();
            }
            g.Freeze();
            kept = g;
            keptVersion = version;
            keptScale = ViewScale;
            keptSheet = null;
        }
        dc.PushTransform(new MatrixTransform(ViewMatrix));
        dc.DrawDrawing(kept);
        dc.Pop();

        DrawSelection(dc, doc.D);
        DrawGhosts(dc, doc.D);
        DrawOverlay(dc, doc.D);
    }

    void DrawGrid(DrawingContext dc, JsonObject d)
    {
        var gs = J.D(d, "gridSize", 100);
        if (gs <= 0) return;
        var step = gs;
        while (step * ViewScale < 8) step *= 10;
        var (x0, y0) = ToWorld(new Point(0, ActualHeight));
        var (x1, y1) = ToWorld(new Point(ActualWidth, 0));
        var minor = new Pen(GridMinor, 1);
        var major = new Pen(GridMajor, 1);
        minor.Freeze();
        major.Freeze();
        for (var x = Math.Floor(x0 / step) * step; x <= x1; x += step)
        {
            var sx = Math.Round(ToScreen((x, 0)).X) + 0.5;
            dc.DrawLine(Math.Abs(Math.Round(x / step) % 10) == 0 ? major : minor, new Point(sx, 0), new Point(sx, ActualHeight));
        }
        for (var y = Math.Floor(y0 / step) * step; y <= y1; y += step)
        {
            var sy = Math.Round(ToScreen((0, y)).Y) + 0.5;
            dc.DrawLine(Math.Abs(Math.Round(y / step) % 10) == 0 ? major : minor, new Point(0, sy), new Point(ActualWidth, sy));
        }
    }

    void DrawSelection(DrawingContext dc, JsonObject d)
    {
        if (Selection.Count == 0) return;
        var pen = new Pen(SelBrush, 1.5) { DashStyle = new DashStyle(new double[] { 4, 3 }, 0) };
        pen.Freeze();
        foreach (var o in M.Objects(d).Where(o => Selection.Contains(M.Id(o))))
        {
            List<(double X, double Y)> outline;
            var closed = true;
            if (M.UsesPoints(o))
            {
                outline = M.Pts(o);
                closed = J.Has(o, "closed");
            }
            else outline = PlotPdf.Quad(o);
            if (outline.Count < 2) continue;
            var g = new StreamGeometry();
            using (var c = g.Open())
            {
                c.BeginFigure(ToScreen(outline[0]), false, closed);
                foreach (var q in outline.Skip(1)) c.LineTo(ToScreen(q), true, false);
            }
            g.Freeze();
            dc.DrawGeometry(null, pen, g);
        }
        var white = new Pen(Brushes.White, 1);
        white.Freeze();
        foreach (var gr in Grips(d))
        {
            var s = ToScreen(gr.At);
            if (gr.Kind == "rotate") dc.DrawEllipse(GripGreen, white, s, 4.5, 4.5);
            else dc.DrawRectangle(GripBlue, white, new Rect(s.X - 4.5, s.Y - 4.5, 9, 9));
        }
    }

    /// The selected objects as they would be if the running Move, Copy, Rotate or Scale (or a drag) finished now.
    void DrawGhosts(DrawingContext dc, JsonObject d)
    {
        List<JsonObject>? ghosts = null;
        var ids = MovingIDs(d);
        if (pressedObject && didMove && mouse is Point mp)
        {
            var w = ToWorld(mp);
            ghosts = M.Objects(d).Where(o => ids.Contains(M.Id(o))).Take(400).Select(o =>
            {
                var c = (JsonObject)o.DeepClone();
                M.Translate(c, w.X - pressWorld.X, w.Y - pressWorld.Y);
                return c;
            }).ToList();
        }
        else if (pts.Count > 0 && Command is Cmd.Move or Cmd.Copy or Cmd.Rotate or Cmd.Scale)
        {
            var b = pts[0];
            var r = Command == Cmd.Scale ? ScaleReference(b) : 0;
            ghosts = M.Objects(d).Where(o => ids.Contains(M.Id(o))).Take(400).Select(o =>
            {
                var c = (JsonObject)o.DeepClone();
                switch (Command)
                {
                    case Cmd.Move: case Cmd.Copy: M.Translate(c, cursor.X - b.X, cursor.Y - b.Y); break;
                    case Cmd.Rotate: M.Rotate(c, b.X, b.Y, Math.Atan2(cursor.Y - b.Y, cursor.X - b.X) * 180 / Math.PI); break;
                    case Cmd.Scale: if (r > 0) M.Scale(c, b.X, b.Y, Math.Max(0.01, M.Dist(b, cursor) / r)); break;
                }
                return c;
            }).ToList();
        }
        else if (Command == Cmd.Fixture && mouse != null && FixtureGhost(cursor) is JsonObject f) ghosts = new List<JsonObject> { f };
        else if (Command == Cmd.Truss && mouse != null)
        {
            var a = pts.Count > 0 ? pts[0] : cursor;
            var run = pts.Count > 0 ? TrussRun(a, cursor) : (0, 1, M.TrussType(host.CurrentTrussType).Length);
            var rad = run.Item1 * Math.PI / 180;
            ghosts = new List<JsonObject>();
            for (int i = 0; i < run.Item2; i++)
            {
                var o = M.NewObject("truss", host.ActiveLayer);
                o["typeID"] = host.CurrentTrussType;
                o["rot"] = run.Item1;
                M.SetPos(o, a.X + Math.Cos(rad) * run.Item3 * i, a.Y + Math.Sin(rad) * run.Item3 * i);
                ghosts.Add(o);
            }
        }
        if (ghosts == null || ghosts.Count == 0) return;
        dc.PushTransform(new MatrixTransform(ViewMatrix));
        dc.PushOpacity(0.55);
        var surface = new ScreenSurface(dc, ViewScale) { Override = new Rgb(0.12, 0.43, 0.91) };
        PlotPdf.DrawModelOn(surface, d, ViewScale * 0.9, ghosts, labels: false);
        surface.Finish();
        dc.Pop();
        dc.Pop();
    }

    void DrawOverlay(DrawingContext dc, JsonObject d)
    {
        var pen = new Pen(Ghost, 1);
        pen.Freeze();
        // rubber band for the running command
        if (pts.Count > 0 && mouse != null && Command is Cmd.Line or Cmd.Pline or Cmd.Dist or Cmd.Move or Cmd.Copy or Cmd.Rotate or Cmd.Scale or Cmd.Truss)
        {
            if (Command == Cmd.Pline)
                for (int i = 0; i + 1 < pts.Count; i++) dc.DrawLine(pen, ToScreen(pts[i]), ToScreen(pts[i + 1]));
            dc.DrawLine(pen, ToScreen(pts[^1]), ToScreen(cursor));
            if (Command == Cmd.Dist) DrawTip(dc, ToScreen(cursor), M.Num(Math.Round(M.Dist(pts[^1], cursor))) + " mm");
        }
        if (pts.Count > 0 && mouse != null && Command is Cmd.Rect or Cmd.ZoomWindow or Cmd.Viewport)
            dc.DrawRectangle(null, pen, new Rect(ToScreen(pts[0]), ToScreen(cursor)));
        if (pts.Count > 0 && mouse != null && Command == Cmd.Circle)
        {
            var r = M.Dist(pts[0], cursor) * ViewScale;
            dc.DrawEllipse(null, pen, ToScreen(pts[0]), r, r);
        }
        // selection window
        if (windowStart != null || (pressedEmpty && draggingWindow))
        {
            var a = windowStart ?? pressWorld;
            var crossing = windowEnd.X < a.X;
            var wpen = new Pen(crossing ? GripGreen : GripBlue, 1) { DashStyle = crossing ? DashStyles.Dash : DashStyles.Solid };
            dc.DrawRectangle(crossing ? CrossFill : WinFill, wpen, new Rect(ToScreen(a), ToScreen(windowEnd)));
        }
        // snap marker
        if (snapHit is SnapHit hit && (WantsPoint || activeGrip != null))
        {
            var c = ToScreen(hit.Point);
            var sp = new Pen(SnapGreen, 2);
            const double s = 6;
            switch (hit.Kind)
            {
                case SnapKind.Endpoint: dc.DrawRectangle(null, sp, new Rect(c.X - s, c.Y - s, s * 2, s * 2)); break;
                case SnapKind.Center: dc.DrawEllipse(null, sp, c, s, s); break;
                case SnapKind.Midpoint:
                    dc.DrawLine(sp, new Point(c.X - s, c.Y + s), new Point(c.X + s, c.Y + s));
                    dc.DrawLine(sp, new Point(c.X + s, c.Y + s), new Point(c.X, c.Y - s));
                    dc.DrawLine(sp, new Point(c.X, c.Y - s), new Point(c.X - s, c.Y + s));
                    break;
                case SnapKind.Intersection:
                    dc.DrawLine(sp, new Point(c.X - s, c.Y - s), new Point(c.X + s, c.Y + s));
                    dc.DrawLine(sp, new Point(c.X - s, c.Y + s), new Point(c.X + s, c.Y - s));
                    break;
                default: dc.DrawRectangle(null, sp, new Rect(c.X - s * 0.8, c.Y - s * 0.8, s * 1.6, s * 1.6)); break;
            }
            DrawTip(dc, new Point(c.X + 10, c.Y + 10), hit.Kind.ToString());
        }
        // crosshair
        if (mouse is Point m && !panning)
        {
            var ch = new Pen(new SolidColorBrush(Color.FromArgb(150, 0x30, 0x30, 0x30)), 1);
            var at = snapHit is SnapHit h2 && WantsPoint ? ToScreen(h2.Point) : (WantsPoint ? ToScreen(cursor) : m);
            const double arm = 22;
            dc.DrawLine(ch, new Point(at.X - arm, at.Y + 0.5), new Point(at.X + arm, at.Y + 0.5));
            dc.DrawLine(ch, new Point(at.X + 0.5, at.Y - arm), new Point(at.X + 0.5, at.Y + arm));
            if (!WantsPoint) dc.DrawRectangle(null, ch, new Rect(at.X - 4, at.Y - 4, 8, 8));
        }
    }

    static void DrawTip(DrawingContext dc, Point at, string text)
    {
        var ft = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 11, Brushes.Black, 1.0);
        dc.DrawRectangle(Tip, null, new Rect(at.X - 2, at.Y - 1, ft.Width + 4, ft.Height + 2));
        dc.DrawText(ft, at);
    }

    void RenderSheet(DrawingContext dc, DrawDoc doc, Rect size)
    {
        dc.DrawRectangle(Desk, null, size);
        var sh = Sheet();
        if (sh == null) return;
        double sw = J.D(sh, "w", 420), shh = J.D(sh, "h", 297);
        var paper = new Rect(ToScreen((0, shh)), ToScreen((sw, 0)));
        dc.DrawRectangle(Brushes.White, null, paper);
        var stale = kept == null || keptVersion != version || keptSheet != SheetID || (Math.Abs(keptScale - ViewScale) / ViewScale > 0.02 && !redrawSoon.IsEnabled);
        if (stale)
        {
            var g = new DrawingGroup();
            using (var gc = g.Open())
            {
                // the sheet is drawn in points; one paper millimetre is 2.835 points
                gc.PushTransform(new ScaleTransform(1 / PlotPdf.PtPerMM, 1 / PlotPdf.PtPerMM));
                var surface = new ScreenSurface(gc, ViewScale / PlotPdf.PtPerMM);
                PlotPdf.DrawSheet(surface, doc.D, sh, host.ShowName, DateTime.Now.ToString("d MMM yyyy HH:mm"), null);
                surface.Finish();
                gc.Pop();
            }
            g.Freeze();
            kept = g;
            keptVersion = version;
            keptScale = ViewScale;
            keptSheet = SheetID;
        }
        dc.PushClip(new RectangleGeometry(paper));
        dc.PushTransform(new MatrixTransform(ViewMatrix));
        dc.DrawDrawing(kept);
        dc.Pop();
        dc.Pop();
        if (SelectedSheetItem() is JsonObject item)
        {
            var pen = new Pen(SelBrush, 2) { DashStyle = DashStyles.Dash };
            if (item["scale"] != null)
            {
                double x = J.D(item, "x"), y = J.D(item, "y");
                dc.DrawRectangle(null, pen, new Rect(ToScreen((x, y + J.D(item, "h"))), ToScreen((x + J.D(item, "w"), y))));
            }
            else
            {
                var q = PlotPdf.Quad(item);
                dc.DrawRectangle(null, pen, new Rect(ToScreen(q[0]), ToScreen(q[2])));
            }
        }
        if (pts.Count > 0 && mouse != null && Command == Cmd.Viewport)
        {
            var pen = new Pen(Ghost, 1);
            dc.DrawRectangle(null, pen, new Rect(ToScreen(pts[0]), ToScreen(cursor)));
        }
        if (mouse is Point m)
        {
            var ch = new Pen(new SolidColorBrush(Color.FromArgb(170, 0x20, 0x20, 0x20)), 1);
            dc.DrawLine(ch, new Point(m.X - 22, m.Y + 0.5), new Point(m.X + 22, m.Y + 0.5));
            dc.DrawLine(ch, new Point(m.X + 0.5, m.Y - 22), new Point(m.X + 0.5, m.Y + 22));
        }
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        mouse = null;
        InvalidateVisual();
    }
}
