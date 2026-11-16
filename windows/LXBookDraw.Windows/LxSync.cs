using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;

namespace LXBookDrawWin;

// The live link to Lx Book, ported from the Mac app (LxBook.swift and ShowStore.swift), so both apps behave the same:
//
// - Fixtures on the plot are tied to Lx Book's fixtures by their ID. Patch, position and notes go both ways;
//   circuits come from Lx Book's power patch; the ID itself is never changed in Lx Book from here.
// - A drawing opened from Lx Book lives in the show as rows in six lists (drawmeta, drawlayers, drawscenes,
//   drawsheets, drawtypes, drawobjects), saved with the same PUT api/state the web app uses. A working copy on
//   this PC (with what Lx Book last agreed to) means work carries on with no signal and is sent when it's back.

public interface ISyncHost
{
    DrawDoc? Doc { get; }
    Window Owner { get; }
    void Log(string text, string kind = "lx");
    void SyncStatusChanged();
}

public sealed record LxFields(string Unit, string Universe, string Address, string Position, string Note);

/// The drawing as the rows Lx Book keeps (ShowRows in the Mac app). Must stay the same as the Mac and lxdraw_pdf.py.
public static class ShowRows
{
    public static readonly string[] Collections = { "drawmeta", "drawlayers", "drawscenes", "drawsheets", "drawtypes", "drawobjects" };
    static readonly string[] MetaKeys = { "info", "labelSize", "labelParts", "hoistLabelParts", "labelSpacing", "labelBackground", "autoLabels", "showLabels",
                                          "gridSize", "snapGrid", "viewerLink", "nextUnit", "formatVersion" };
    static readonly string[] Clearable = { "labelParts", "hoistLabelParts", "labelSpacing", "labelBackground", "autoLabels", "viewerLink" };
    static readonly string[] LxFieldNames = { "unit", "universe", "address", "position", "note", "circuit" };

    public static string RowID(JsonNode? row) => J.S(row, "_id");

    static JsonObject? Renamed(JsonObject item, string from, string to)
    {
        var row = (JsonObject)item.DeepClone();
        if (!row.TryGetPropertyValue(from, out var id)) return null;
        row.Remove(from);
        row[to] = id;
        return row;
    }

    public static Dictionary<string, List<JsonObject>> Split(JsonObject d)
    {
        var rows = Collections.ToDictionary(c => c, _ => new List<JsonObject>());
        var meta = new JsonObject { ["_id"] = "meta" };
        foreach (var k in MetaKeys) if (d.TryGetPropertyValue(k, out var v) && v != null) meta[k] = v.DeepClone();
        rows["drawmeta"].Add(meta);
        foreach (var (key, name) in new[] { ("layers", "drawlayers"), ("scenes", "drawscenes"), ("sheets", "drawsheets") })
            foreach (var item in J.Objs(d, key))
                if (Renamed(item, "id", "_id") is JsonObject row) rows[name].Add(row);
        var styles = J.G(d, "typeStyles") as JsonObject ?? new JsonObject();
        var known = new HashSet<string>();
        foreach (var t in J.Objs(d, "fixtureTypes"))
        {
            var id = J.S(t, "id");
            if (id.Length == 0) continue;
            var row = (JsonObject)t.DeepClone();
            row.Remove("prims");
            row.Remove("id");
            row["_id"] = id;
            row["symbol"] = id;
            if (styles[id] is JsonObject st)
            {
                if (st["color"] != null) row["color"] = st["color"]!.DeepClone();
                if (st["easyID"] != null) row["easyID"] = st["easyID"]!.DeepClone();
            }
            rows["drawtypes"].Add(row);
            known.Add(id);
        }
        foreach (var id in styles.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal))
        {
            if (known.Contains(id) || styles[id] is not JsonObject st || (st["color"] == null && st["easyID"] == null)) continue;
            var row = new JsonObject { ["_id"] = id, ["builtIn"] = true };
            if (st["color"] != null) row["color"] = st["color"]!.DeepClone();
            if (st["easyID"] != null) row["easyID"] = st["easyID"]!.DeepClone();
            rows["drawtypes"].Add(row);
        }
        foreach (var item in J.Objs(d, "objects"))
        {
            if (Renamed(item, "id", "_id") is not JsonObject row) continue;
            if (J.S(row, "kind") == "fixture" && J.S(row, "lxID") is var fx && fx.Length > 0)
            {
                row["fx"] = fx;
                row.Remove("lxID");
                foreach (var k in LxFieldNames) row.Remove(k);
            }
            rows["drawobjects"].Add(row);
        }
        return rows;
    }

    public static Dictionary<string, JsonObject> Symbols(JsonObject d)
    {
        var outp = new Dictionary<string, JsonObject>();
        foreach (var t in J.Objs(d, "fixtureTypes"))
        {
            var id = J.S(t, "id");
            if (id.Length == 0) continue;
            outp[id] = new JsonObject
            {
                ["id"] = id, ["prims"] = J.A(t, "prims").DeepClone(), ["name"] = (J.S(t, "manufacturer") + " " + J.S(t, "name")).Trim(),
                ["width"] = J.D(t, "width", 400), ["depth"] = J.D(t, "depth", 400)
            };
        }
        return outp;
    }

    /// Builds the drawing from rows; what the rows don't carry is kept from `old`.
    public static JsonObject Join(Dictionary<string, List<JsonObject>> rows, Dictionary<string, JsonObject> symbols, JsonObject old)
    {
        var d = (JsonObject)old.DeepClone();
        if (rows.TryGetValue("drawmeta", out var metas) && metas.Count > 0)
        {
            var meta = metas[0];
            foreach (var k in MetaKeys)
            {
                if (meta.TryGetPropertyValue(k, out var v) && v != null) d[k] = v.DeepClone();
                else if (Clearable.Contains(k)) d.Remove(k);
            }
        }
        JsonArray List(string name)
        {
            var a = new JsonArray();
            foreach (var row in rows.GetValueOrDefault(name) ?? new List<JsonObject>())
                if (Renamed(row, "_id", "id") is JsonObject item) a.Add(item);
            return a;
        }
        var layers = List("drawlayers");
        if (layers.Count > 0) d["layers"] = layers;
        var scenes = List("drawscenes");
        if (scenes.Count == 0) d.Remove("scenes"); else d["scenes"] = scenes;
        var sheets = List("drawsheets");
        if (sheets.Count == 0) d.Remove("sheets"); else d["sheets"] = sheets;

        var types = new JsonArray();
        var styles = new JsonObject();
        foreach (var row in rows.GetValueOrDefault("drawtypes") ?? new List<JsonObject>())
        {
            var id = RowID(row);
            if (id.Length == 0) continue;
            var st = new JsonObject();
            if (row["color"] != null) st["color"] = row["color"]!.DeepClone();
            if (row["easyID"] != null) st["easyID"] = row["easyID"]!.DeepClone();
            if (st.Count > 0) styles[id] = st;
            if (J.IsTrue(row, "builtIn")) continue;
            var t = (JsonObject)row.DeepClone();
            foreach (var k in new[] { "_id", "symbol", "color", "easyID", "builtIn" }) t.Remove(k);
            t["id"] = id;
            var symbolID = J.S(row, "symbol") is var s && s.Length > 0 ? s : id;
            if (symbols.TryGetValue(symbolID, out var sym) && sym["prims"] is JsonArray prims)
            {
                t["prims"] = prims.DeepClone();
                if (J.D(sym, "width") > 0) t["width"] = J.D(sym, "width");
                if (J.D(sym, "depth") > 0) t["depth"] = J.D(sym, "depth");
            }
            else
            {
                double w = J.D(t, "width", 400), h = J.D(t, "depth", 400);
                if (w <= 0) w = 400;
                if (h <= 0) h = 400;
                t["prims"] = new JsonArray(PlotPdf.Prim("rect", -w / 2, -h / 2, w, h, fill: new Rgb(1, 1, 1)));
            }
            types.Add(t);
        }
        d["fixtureTypes"] = types;
        if (styles.Count == 0) d.Remove("typeStyles"); else d["typeStyles"] = styles;

        var oldObjects = J.Objs(d, "objects").ToDictionary(o => J.S(o, "id"), o => o);
        var objects = new JsonArray();
        foreach (var row in rows.GetValueOrDefault("drawobjects") ?? new List<JsonObject>())
        {
            if (Renamed(row, "_id", "id") is not JsonObject o) continue;
            var id = J.S(o, "id");
            if (o["fx"] != null)
            {
                o["lxID"] = o["fx"]!.DeepClone();
                o.Remove("fx");
            }
            oldObjects.TryGetValue(id, out var was);
            foreach (var k in LxFieldNames)
                if (o[k] == null) o[k] = J.S(was, k);
            objects.Add(o);
        }
        d["objects"] = objects;
        M.Normalize(d);
        return d;
    }

    static bool SameList(List<string> a, List<string> b) => a.Count == b.Count && a.SequenceEqual(b);

    /// The changes that turn `acked` into `local`, as items for PUT api/state.
    public static JsonArray Diff(Dictionary<string, List<JsonObject>> acked, Dictionary<string, List<JsonObject>> local)
    {
        var items = new JsonArray();
        foreach (var c in Collections)
        {
            var a = acked.GetValueOrDefault(c) ?? new List<JsonObject>();
            var l = local.GetValueOrDefault(c) ?? new List<JsonObject>();
            var aBy = new Dictionary<string, JsonObject>();
            foreach (var row in a) aBy[RowID(row)] = row;
            var lIDs = l.Select(RowID).ToHashSet();
            foreach (var row in a)
                if (!lIDs.Contains(RowID(row))) items.Add(new JsonObject { ["c"] = c, ["id"] = RowID(row), ["before"] = row.DeepClone(), ["after"] = null });
            for (int i = 0; i < l.Count; i++)
            {
                var row = l[i];
                var id = RowID(row);
                if (id.Length == 0) continue;
                if (aBy.TryGetValue(id, out var before))
                {
                    if (M.Canon(before) != M.Canon(row)) items.Add(new JsonObject { ["c"] = c, ["id"] = id, ["before"] = before.DeepClone(), ["after"] = row.DeepClone() });
                }
                else items.Add(new JsonObject { ["c"] = c, ["id"] = id, ["after"] = row.DeepClone(), ["apos"] = i });
            }
            var aOrder = a.Select(RowID).ToList();
            var lOrder = l.Select(RowID).ToList();
            if (!SameList(aOrder, lOrder) && lOrder.Count > 0)
                items.Add(new JsonObject { ["c"] = c, ["order"] = true, ["after"] = new JsonArray(lOrder.Select(x => (JsonNode)x!).ToArray()) });
        }
        return items;
    }

    public static string CanonSet(Dictionary<string, List<JsonObject>> rows)
    {
        var o = new JsonObject();
        foreach (var c in Collections) o[c] = new JsonArray((rows.GetValueOrDefault(c) ?? new List<JsonObject>()).Select(r => (JsonNode)r.DeepClone()).ToArray());
        return M.Canon(o);
    }

    public static Dictionary<string, List<JsonObject>> FromJson(JsonNode? j)
    {
        var rows = Collections.ToDictionary(c => c, _ => new List<JsonObject>());
        foreach (var c in Collections) rows[c] = J.Objs(j, c).Select(r => (JsonObject)r.DeepClone()).ToList();
        return rows;
    }

    public static JsonObject ToJson(Dictionary<string, List<JsonObject>> rows)
    {
        var o = new JsonObject();
        foreach (var c in Collections) o[c] = new JsonArray((rows.GetValueOrDefault(c) ?? new List<JsonObject>()).Select(r => (JsonNode)r.DeepClone()).ToArray());
        return o;
    }
}

public sealed class LxSync
{
    readonly LxClient client;
    readonly ISyncHost host;
    public string Server { get; }
    public string ShowID { get; }
    public string ShowName { get; }
    public string Status { get; private set; } = "Connecting…";
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(3) };
    bool busy;
    JsonNode? rev;
    Dictionary<string, JsonObject> rows = new();
    Dictionary<string, JsonObject> motorRows = new();
    Dictionary<string, LxFields> known = new();
    Dictionary<string, List<string>> ways = new();
    JsonArray locations = new();
    DateTime pushAfter = DateTime.MinValue;

    // the drawing kept in the show
    Dictionary<string, List<JsonObject>> acked = new();
    bool hasAcked, pendingImport, blocked, loaded, showBusy, askedEmpty;
    string? drawRev;
    HashSet<string>? libraryIDs;
    string? checkedBody;
    public string Note { get; private set; } = "";

    public LxSync(LxClient client, ISyncHost host, string server, string showID, string showName)
    {
        this.client = client;
        this.host = host;
        Server = server;
        ShowID = showID;
        ShowName = showName;
        timer.Tick += async (_, _) => await Tick();
        try
        {
            if (JsonNode.Parse(File.ReadAllText(Sidecar(showID))) is JsonObject j)
            {
                if (j["acked"] is JsonObject a)
                {
                    acked = ShowRows.FromJson(a);
                    hasAcked = true;
                }
                pendingImport = J.IsTrue(j, "pendingImport");
            }
        }
        catch { }
    }

    bool InShow => host.Doc?.InShow == true;

    // ---------------------------------------------------------------- where the working copies are

    public static string Folder(string name)
    {
        var f = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LX Book Draw", name);
        Directory.CreateDirectory(f);
        return f;
    }

    static string Safe(string id) => new(id.Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray());
    public static string WorkingCopy(string showID) => Path.Combine(Folder("shows"), Safe(showID) + ".lxdraw");
    public static string Sidecar(string showID) => Path.Combine(Folder("shows"), Safe(showID) + ".sync.json");

    public static void ResetSidecar(string showID, bool pendingImport) =>
        File.WriteAllText(Sidecar(showID), new JsonObject { ["pendingImport"] = pendingImport }.ToJsonString());

    void SaveSidecar()
    {
        var j = new JsonObject { ["pendingImport"] = pendingImport };
        if (hasAcked) j["acked"] = ShowRows.ToJson(acked);
        try { File.WriteAllText(Sidecar(ShowID), j.ToJsonString()); } catch { }
    }

    static string Stamp() => DateTime.Now.ToString("HH:mm");

    public void Start()
    {
        timer.Start();
        _ = Tick();
    }

    public void Stop() => timer.Stop();

    void SetStatus(string s)
    {
        if (s == Status) return;
        Status = s;
        host.SyncStatusChanged();
    }

    async Task<JsonObject?> Call(string method, string path, JsonNode? body = null, byte[]? raw = null, Action<LxException>? failed = null)
    {
        try
        {
            return await client.Call(method, path, body, true, ShowID, raw);
        }
        catch (LxException e)
        {
            if (e.Login)
            {
                client.Account.Key = "";
                client.Account.Save();
                Stop();
                SetStatus("Lx Book: signed out. Sign in again, then open the show again.");
            }
            else if (e.NoShow)
            {
                Stop();
                SetStatus("Lx Book: " + e.Message);
            }
            failed?.Invoke(e);
            return null;
        }
    }

    /// Called after every change to the drawing: sends what changed, a moment later.
    public void DrawingChanged()
    {
        pushAfter = DateTime.Now.AddSeconds(1.2);
        checkedBody = null;
    }

    /// Sends anything waiting now (Ctrl-S, closing).
    public async Task Flush()
    {
        pushAfter = DateTime.MinValue;
        checkedBody = null;
        if (!busy) await PushFixtures();
        await PushRows();
    }

    // ---------------------------------------------------------------- the loop

    async Task Tick()
    {
        if (busy) return;
        busy = true;
        try
        {
            string err = "";
            var j = await Call("GET", "api/health", failed: e => err = e.Message);
            if (j == null)
            {
                SetStatus("Lx Book: " + err);
                return;
            }
            var show = J.Txt(J.G(j, "show"));
            if (show.Length > 0 && show != ShowID)
            {
                SetStatus($"Lx Book has \"{J.Txt(J.G(j, "showName"))}\" open, not \"{ShowName}\".");
                return;
            }
            if (rev != null && J.Txt(J.G(j, "rev")) == J.Txt(rev))
            {
                if (InShow) await ShowTick(j);
                SetStatus($"Lx Book: synced with \"{ShowName}\"" + Note);
                await PushFixtures();
                return;
            }
            var state = await Call("GET", "api/state", failed: e => err = e.Message);
            if (state == null)
            {
                SetStatus("Lx Book: " + err);
                return;
            }
            Take(state);
            SetStatus($"Lx Book: synced with \"{ShowName}\"" + Note);
            await PushFixtures();
        }
        finally
        {
            busy = false;
        }
    }

    void Take(JsonObject state)
    {
        rev = state["_rev"]?.DeepClone();
        var newRows = new Dictionary<string, JsonObject>();
        foreach (var f in J.Objs(state, "fixtures"))
        {
            var id = J.Txt(J.G(f, "_id"));
            if (id.Length > 0) newRows[id] = (JsonObject)f.DeepClone();
        }
        var newWays = new Dictionary<string, List<string>>();
        foreach (var m in J.Objs(state, "multis"))
        {
            var name = J.Txt(J.G(m, "name"));
            var list = J.A(m, "ways");
            for (int i = 0; i < list.Count; i++)
                foreach (var u in J.A(list[i], "units"))
                {
                    var k = J.Key(u);
                    if (k.Length == 0) continue;
                    if (!newWays.TryGetValue(k, out var l)) newWays[k] = l = new List<string>();
                    l.Add($"{name}-{i + 1}");
                }
        }
        rows = newRows;
        ways = newWays;
        motorRows = J.Objs(state, "motors").Where(m => J.Txt(J.G(m, "_id")).Length > 0).ToDictionary(m => J.Txt(J.G(m, "_id")), m => (JsonObject)m.DeepClone());
        // locations and their tapes, the same way the PDF does
        var probe = new JsonObject();
        PlotPdf.ApplyState(probe, state);
        locations = probe["locations"] as JsonArray ?? new JsonArray();
        ApplyToDrawing();
    }

    /// Fills Lx Book's values in again (after the drawing is rebuilt from the show).
    public void Reapply() => ApplyToDrawing();

    static LxFields Fields(JsonObject row)
    {
        var (u, a) = PlotPdf.Patch(row);
        return new LxFields(J.Txt(J.G(row, "fid")).Trim(), u, a, J.Txt(J.G(row, "pos")), J.Txt(J.G(row, "notes")));
    }

    void ApplyToDrawing()
    {
        var doc = host.Doc;
        if (doc == null) return;
        var agreed = new Dictionary<string, LxFields>(known);
        var motorByID = new Dictionary<string, (string Id, JsonObject Row)>();
        foreach (var (id, row) in motorRows)
        {
            var k = J.Key(J.G(row, "mid"));
            if (k.Length > 0 && !motorByID.ContainsKey(k)) motorByID[k] = (id, row);
        }
        doc.ApplyRemote(d =>
        {
            var objs = M.Objects(d).ToList();
            foreach (var o in objs.Where(o => M.Kind(o) == "fixture" && M.Category(d, o) == "hoist"))
            {
                if (!motorByID.TryGetValue(J.Key(J.G(o, "unit")), out var hit))
                {
                    o.Remove("lxMotor");
                    continue;
                }
                o["lxMotor"] = hit.Id;
                o["position"] = J.Txt(J.G(hit.Row, "location"));
                o["note"] = J.Txt(J.G(hit.Row, "notes"));
                var chain = J.Txt(J.G(hit.Row, "chain"));
                var load = J.Txt(J.G(hit.Row, "weight"));
                if (chain.Length > 0) o["chain"] = chain; else o.Remove("chain");
                if (load.Length > 0) o["load"] = load; else o.Remove("load");
            }
            d["locations"] = locations.DeepClone();
            var locs = locations.OfType<JsonObject>().ToList();
            foreach (var o in objs.Where(o => M.Kind(o) == "text" && J.IsTrue(o, "tag")))
            {
                var name = J.S(o, "text").Trim().ToLowerInvariant();
                var lx = J.S(o, "lxID");
                var l = lx.Length > 0 ? locs.FirstOrDefault(x => J.S(x, "id") == lx) : null;
                if (l != null)
                {
                    if (J.S(l, "name").Length > 0) o["text"] = J.S(l, "name");
                }
                else if (locs.FirstOrDefault(x => J.S(x, "name").ToLowerInvariant() == name || (J.S(x, "short").Length > 0 && J.S(x, "short").ToLowerInvariant() == name)) is JsonObject hit)
                    o["lxID"] = J.S(hit, "id");
            }
            var taken = objs.Select(o => J.S(o, "lxID")).Where(s => s.Length > 0).ToHashSet();
            var free = new Dictionary<string, string>();
            foreach (var (id, row) in rows)
                if (!taken.Contains(id) && J.Key(J.G(row, "fid")) is var k && k.Length > 0) free[k] = id;
            foreach (var o in objs.Where(o => M.Kind(o) == "fixture"))
            {
                if (J.S(o, "lxID").Length == 0)
                {
                    var k = J.Key(J.G(o, "unit"));
                    if (M.Category(d, o) != "hoist" && k.Length > 0 && free.TryGetValue(k, out var fid))
                    {
                        o["lxID"] = fid;
                        free.Remove(k);
                    }
                }
                var lxID = J.S(o, "lxID");
                if (lxID.Length == 0 || !rows.TryGetValue(lxID, out var row)) continue;
                var remote = Fields(row);
                if (agreed.ContainsKey(lxID))
                {
                    o["unit"] = remote.Unit;
                    o["universe"] = remote.Universe;
                    o["address"] = remote.Address;
                    o["position"] = remote.Position;
                    o["note"] = remote.Note;
                }
                else
                {
                    // first meeting: Lx Book wins where it has a value; the drawing fills in the blanks (sent next)
                    if (remote.Unit.Length > 0) o["unit"] = remote.Unit;
                    if (remote.Universe.Length > 0 || remote.Address.Length > 0)
                    {
                        o["universe"] = remote.Universe;
                        o["address"] = remote.Address;
                    }
                    if (remote.Position.Length > 0) o["position"] = remote.Position;
                    if (remote.Note.Length > 0) o["note"] = remote.Note;
                }
                agreed[lxID] = remote;
                if (ways.TryGetValue(J.Key(J.G(row, "fid")), out var w) && w.Count > 0) o["circuit"] = string.Join(", ", w);
                if (J.Has(row, "fs")) o["fs"] = true; else o.Remove("fs");
            }
        });
        known = agreed;
    }

    /// The fixture ID is the link. Typing a new ID on a linked fixture makes it Lx Book's fixture with that ID;
    /// if Lx Book has no such fixture free, the plot fixture keeps the typed ID and stops being linked.
    void RelinkChangedIDs()
    {
        var doc = host.Doc;
        if (doc == null) return;
        var changed = M.Objects(doc.D).Where(o => M.Kind(o) == "fixture" && J.S(o, "lxID") is var id && id.Length > 0 && known.TryGetValue(id, out var was)
                                                   && J.Key(J.G(o, "unit")) != was.Unit.Trim().ToLowerInvariant()).Select(M.Id).ToList();
        if (changed.Count == 0) return;
        var messages = new List<string>();
        var linked = new List<string>();
        var dropped = new List<string>();
        doc.ApplyRemote(d =>
        {
            var taken = M.Objects(d).Where(o => M.Kind(o) == "fixture").Select(o => J.S(o, "lxID")).Where(s => s.Length > 0).ToHashSet();
            foreach (var cid in changed)
            {
                var o = M.Find(d, cid);
                var old = J.S(o, "lxID");
                if (o == null || old.Length == 0) continue;
                var unit = J.S(o, "unit").Trim();
                var key = unit.ToLowerInvariant();
                if (key.Length == 0)
                {
                    var back = known.TryGetValue(old, out var f) ? f.Unit : "";
                    o["unit"] = back;
                    messages.Add($"A linked fixture needs its ID, so it was put back to {back}. Lx Book was not changed.");
                    continue;
                }
                taken.Remove(old);
                dropped.Add(old);
                var hit = rows.FirstOrDefault(r => J.Key(J.G(r.Value, "fid")) == key && !taken.Contains(r.Key));
                if (hit.Key != null)
                {
                    o["lxID"] = hit.Key;
                    taken.Add(hit.Key);
                    linked.Add(hit.Key);
                    messages.Add($"This fixture is now Lx Book's fixture {unit}, with its patch, position and notes. Lx Book was not changed.");
                }
                else
                {
                    o.Remove("lxID");
                    messages.Add($"Lx Book has no free fixture {unit}, so this one is no longer linked. Lx Book was not changed.");
                }
            }
        });
        foreach (var id in dropped) known.Remove(id);
        foreach (var id in linked) if (rows.TryGetValue(id, out var row)) known[id] = Fields(row);
        ApplyToDrawing();
        foreach (var m in messages) host.Log(m);
    }

    static string PatchText(string universe, string address, string like)
    {
        if (universe.Length == 0 || address.Length == 0) return universe + address;
        if (like.Contains('.') && int.TryParse(address, out var a)) return universe + "." + a.ToString("000");
        var sep = like.Trim().FirstOrDefault(c => !char.IsDigit(c));
        return universe + (sep == default(char) ? "/" : sep.ToString()) + address;
    }

    async Task PushFixtures()
    {
        var doc = host.Doc;
        if (rev == null || doc == null) return;
        RelinkChangedIDs();
        var items = new JsonArray();
        var sent = new Dictionary<string, (JsonObject Row, LxFields Fields)>();
        var details = new List<string>();
        foreach (var o in M.Objects(doc.D).Where(o => M.Kind(o) == "fixture"))
        {
            var id = J.S(o, "lxID");
            if (id.Length == 0 || !rows.TryGetValue(id, out var before) || !known.TryGetValue(id, out var was) || sent.ContainsKey(id)) continue;
            var now = new LxFields(was.Unit, J.S(o, "universe"), J.S(o, "address"), J.S(o, "position"), J.S(o, "note"));
            if (now == was) continue;
            var after = (JsonObject)before.DeepClone();
            if (now.Universe != was.Universe || now.Address != was.Address) after["patch"] = PatchText(now.Universe, now.Address, J.Txt(J.G(before, "patch")));
            if (now.Position != was.Position) after["pos"] = now.Position;
            if (now.Note != was.Note) after["notes"] = now.Note;
            items.Add(new JsonObject { ["c"] = "fixtures", ["id"] = id, ["before"] = before.DeepClone(), ["after"] = after });
            sent[id] = (after, now);
            details.Add($"Fixture {now.Unit}: changed in LX Book Draw");
        }
        if (items.Count == 0) return;
        SetStatus("Lx Book: saving…");
        var summary = items.Count == 1 ? details[0] : $"{items.Count} fixtures changed in LX Book Draw";
        var body = new JsonObject
        {
            ["show"] = ShowID, ["items"] = items.DeepClone(),
            ["change"] = new JsonObject
            {
                ["kind"] = "edit", ["summary"] = summary, ["details"] = new JsonArray(details.Take(80).Select(x => (JsonNode)x!).ToArray()),
                ["items"] = items.DeepClone(), ["tz"] = TimeZoneInfo.Local.Id
            }
        };
        if (rev != null) body["baseRev"] = rev.DeepClone();
        string err = "";
        var j = await Call("PUT", "api/state", body, failed: e => err = e.Message);
        if (j == null)
        {
            SetStatus("Lx Book: not saved. " + err);
            return;
        }
        foreach (var (id, s) in sent)
        {
            rows[id] = s.Row;
            known[id] = s.Fields;
        }
        if (j["rev"] != null) rev = j["rev"]!.DeepClone();
        if (j["state"] is JsonObject merged)
        {
            var m = (JsonObject)merged.DeepClone();
            if (m["_rev"] == null) m["_rev"] = j["rev"]?.DeepClone();
            Take(m);
        }
        SetStatus($"Lx Book: synced with \"{ShowName}\"");
    }

    // ---------------------------------------------------------------- the drawing kept in the show

    async Task ShowTick(JsonObject health)
    {
        if (showBusy || blocked) return;
        if ((int)J.D(health, "draw") < 2)
        {
            Note = " · this Lx Book can't keep drawings yet (it needs its update). Your changes are safe on this PC.";
            return;
        }
        var r = J.Txt(J.G(health, "drawRev"));
        if (!loaded || r != drawRev) await Fetch(r);
        else await PushRows();
    }

    async Task Fetch(string r)
    {
        var doc = host.Doc;
        if (doc == null) return;
        showBusy = true;
        try
        {
            string err = "";
            var j = await Call("GET", "api/draw/state", failed: e => err = e.Message);
            if (j == null)
            {
                Note = " · plot not read from Lx Book: " + err;
                return;
            }
            var remote = ShowRows.FromJson(j);
            if (J.S(j, "viewerLink") is var link && link.StartsWith("https://", StringComparison.OrdinalIgnoreCase) && J.S(doc.D, "viewerLink").Length == 0)
                doc.ApplyRemote(d => d["viewerLink"] = link);
            await FetchSymbols(remote);
            var result = await Merge(remote);
            if (result == "settled")
            {
                drawRev = r;
                loaded = true;
                showBusy = false;
                await PushRows();
            }
        }
        finally
        {
            showBusy = false;
        }
    }

    Dictionary<string, JsonObject> SymbolsFor(Dictionary<string, List<JsonObject>> set, JsonObject drawing)
    {
        var outp = ShowRows.Symbols(drawing);
        foreach (var row in set.GetValueOrDefault("drawtypes") ?? new List<JsonObject>())
        {
            var id = J.S(row, "symbol") is var s && s.Length > 0 ? s : ShowRows.RowID(row);
            if (outp.ContainsKey(id)) continue;
            try
            {
                if (JsonNode.Parse(File.ReadAllText(LxClient.SymbolFile(id))) is JsonObject sym) outp[id] = sym;
            }
            catch { }
        }
        return outp;
    }

    async Task FetchSymbols(Dictionary<string, List<JsonObject>> remote)
    {
        var doc = host.Doc;
        if (doc == null) return;
        var have = SymbolsFor(remote, doc.D);
        var missing = new List<string>();
        foreach (var row in remote["drawtypes"].Where(r => !J.IsTrue(r, "builtIn")))
        {
            var id = J.S(row, "symbol") is var s && s.Length > 0 ? s : ShowRows.RowID(row);
            if (id.Length > 0 && !have.ContainsKey(id) && !missing.Contains(id)) missing.Add(id);
        }
        if (missing.Count == 0) return;
        var j = await Call("GET", "api/draw/symbols?ids=" + string.Join(",", missing.Select(Uri.EscapeDataString)));
        if (J.G(j, "symbols") is JsonObject found)
            foreach (var (id, value) in found)
                if (value is JsonObject sym)
                    try { File.WriteAllText(LxClient.SymbolFile(id), sym.ToJsonString()); } catch { }
    }

    /// Brings what Lx Book has together with what is here. A row changed here and not yet sent stays as it is here;
    /// everything else follows Lx Book. Returns "settled", "stopped" or "waiting".
    async Task<string> Merge(Dictionary<string, List<JsonObject>> remote)
    {
        var doc = host.Doc;
        if (doc == null) return "stopped";
        var local = ShowRows.Split(doc.D);
        var remoteEmpty = remote["drawobjects"].Count == 0 && remote["drawlayers"].Count == 0;
        Dictionary<string, List<JsonObject>> merged;
        if (!hasAcked)
        {
            if (pendingImport && !remoteEmpty)
            {
                var answer = MessageBox.Show(host.Owner,
                    $"\"{ShowName}\" already has a drawing in Lx Book.\n\nYes: open the drawing in Lx Book (your file stays as it is).\nNo: replace it with this file (Undo in Lx Book brings the old one back).\nCancel: send nothing.",
                    "The show already has a drawing", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
                if (answer == MessageBoxResult.No)
                {
                    await BringIn(Encoding.UTF8.GetBytes(doc.D.ToJsonString()), true);
                    return "waiting";
                }
                if (answer != MessageBoxResult.Yes)
                {
                    blocked = true;
                    Note = " · nothing was sent: the show already has a drawing.";
                    return "stopped";
                }
                host.Log("Opening the drawing kept in Lx Book. Your drawing file was not changed.");
            }
            pendingImport = false;
            if (remoteEmpty && !askedEmpty && M.Objects(doc.D).Count() == 0)
            {
                askedEmpty = true;
                var answer = MessageBox.Show(host.Owner, $"\"{ShowName}\" has no drawing yet.\n\nYes: bring in a drawing file you already have.\nNo: start a new drawing in the show.",
                    "No drawing yet", MessageBoxButton.YesNo, MessageBoxImage.Question);
                if (answer == MessageBoxResult.Yes)
                {
                    var dlg = new OpenFileDialog { Filter = "LX Book Draw drawing (*.lxdraw)|*.lxdraw", Title = "Choose the drawing to bring into the show" };
                    if (dlg.ShowDialog(host.Owner) == true)
                    {
                        try
                        {
                            var data = File.ReadAllBytes(dlg.FileName);
                            if (JsonNode.Parse(data) is JsonObject)
                            {
                                await BringIn(data, false);
                                return "waiting";
                            }
                        }
                        catch (Exception e) { host.Log("That file couldn't be read: " + e.Message, "problem"); }
                    }
                }
            }
            hasAcked = true;
            acked = ShowRows.FromJson(null);
            if (remoteEmpty)
            {
                SaveSidecar();
                return "settled";
            }
            merged = remote;
        }
        else
        {
            merged = new Dictionary<string, List<JsonObject>>();
            foreach (var c in ShowRows.Collections)
            {
                var l = local[c];
                var r = remote[c];
                var lBy = new Dictionary<string, JsonObject>();
                foreach (var row in l) lBy[ShowRows.RowID(row)] = row;
                var aCanon = new Dictionary<string, string>();
                foreach (var row in acked.GetValueOrDefault(c) ?? new List<JsonObject>()) aCanon[ShowRows.RowID(row)] = M.Canon(row);
                var rIDs = new HashSet<string>();
                var outp = new List<JsonObject>();
                foreach (var row in r)
                {
                    var id = ShowRows.RowID(row);
                    rIDs.Add(id);
                    if (lBy.TryGetValue(id, out var mine)) outp.Add(aCanon.TryGetValue(id, out var ac) && M.Canon(mine) == ac ? row : mine);
                    else if (!aCanon.ContainsKey(id)) outp.Add(row);
                }
                foreach (var row in l)
                {
                    var id = ShowRows.RowID(row);
                    if (!rIDs.Contains(id) && !aCanon.ContainsKey(id)) outp.Add(row);
                }
                merged[c] = outp;
            }
        }
        var syms = SymbolsFor(merged, doc.D);
        try
        {
            acked = ShowRows.Split(ShowRows.Join(remote, syms, doc.D));
        }
        catch
        {
            acked = remote;
        }
        SaveSidecar();
        JsonObject next;
        try
        {
            next = ShowRows.Join(merged, syms, doc.D);
        }
        catch
        {
            Note = " · the plot from Lx Book couldn't be read. Nothing here was changed.";
            return "settled";
        }
        if (ShowRows.CanonSet(ShowRows.Split(next)) == ShowRows.CanonSet(local)) return "settled";
        doc.ReplaceRemote(next);
        ApplyToDrawing();
        return "settled";
    }

    /// Sends a whole drawing file to Lx Book (api/draw/import), which writes it into the show as one change.
    async Task BringIn(byte[] data, bool replace)
    {
        showBusy = true;
        Note = " · bringing the drawing into the show…";
        string err = "";
        var j = await Call("POST", "api/draw/import" + (replace ? "?replace=1" : ""), raw: data, failed: e => err = e.Message);
        showBusy = false;
        if (j == null)
        {
            blocked = true;
            Note = " · the drawing wasn't brought in: " + err + " Nothing in Lx Book was changed.";
            return;
        }
        pendingImport = false;
        hasAcked = false;
        acked = ShowRows.FromJson(null);
        SaveSidecar();
        loaded = false;
        drawRev = null;
        askedEmpty = true;
        Note = " · drawing brought into the show " + Stamp();
        host.Log(replace ? "The show's drawing was replaced with this file. Undo in Lx Book brings the old one back." : "The drawing file was brought into the show.");
    }

    async Task PushRows()
    {
        var doc = host.Doc;
        if (doc == null || !InShow || !loaded || !hasAcked || blocked || showBusy) return;
        if (DateTime.Now < pushAfter) return;
        var body = doc.D.ToJsonString();
        if (checkedBody == body) return;
        var local = ShowRows.Split(doc.D);
        showBusy = true;
        try
        {
            if (libraryIDs == null)
            {
                var ids = new HashSet<string>();
                var j = await Call("GET", "api/draw/symbols/list");
                if (j != null)
                {
                    if (j["symbols"] is JsonArray list) foreach (var s in list) ids.Add(J.S(s, "id"));
                    else if (j["symbols"] is JsonObject map) foreach (var kv in map) ids.Add(kv.Key);
                    foreach (var x in J.A(j, "ids")) ids.Add(J.Txt(x));
                    libraryIDs = ids;
                }
                return;
            }
            var mine = ShowRows.Symbols(doc.D);
            var missing = mine.Keys.OrderBy(k => k, StringComparer.Ordinal).FirstOrDefault(k => !libraryIDs.Contains(k));
            if (missing != null)
            {
                string err = "";
                var ok = await Call("PUT", "api/draw/symbols/" + Uri.EscapeDataString(missing), mine[missing], failed: e => err = e.Message);
                if (ok != null)
                {
                    libraryIDs.Add(missing);
                    try { File.WriteAllText(LxClient.SymbolFile(missing), mine[missing].ToJsonString()); } catch { }
                }
                else
                {
                    Note = " · a symbol couldn't be saved to the library yet: " + err;
                    pushAfter = DateTime.Now.AddSeconds(20);
                }
                return;
            }
            var items = ShowRows.Diff(acked, local);
            if (items.Count == 0)
            {
                checkedBody = body;
                if (Note.Contains("waiting") || Note.Contains("not saved")) Note = " · plot saved to Lx Book " + Stamp();
                return;
            }
            var what = J.Objs(doc.D, "history").LastOrDefault() is JsonObject last ? J.S(last, "what") : "changed";
            var rowCount = items.Count(i => !J.IsTrue(i, "order"));
            var summary = "Plot: " + what + (rowCount > 1 ? $" ({rowCount} items)" : "");
            var req = new JsonObject
            {
                ["show"] = ShowID, ["items"] = items.DeepClone(),
                ["change"] = new JsonObject
                {
                    ["kind"] = "edit", ["summary"] = summary, ["details"] = new JsonArray("Changed in LX Book Draw (Windows)"), ["items"] = items.DeepClone(),
                    ["tz"] = TimeZoneInfo.Local.Id
                }
            };
            if (rev != null) req["baseRev"] = rev.DeepClone();
            string err2 = "";
            var res = await Call("PUT", "api/state", req, failed: e => err2 = e.Message);
            if (res == null)
            {
                Note = $" · plot not saved yet, {rowCount} changes waiting: " + err2;
                pushAfter = DateTime.Now.AddSeconds(8);
                return;
            }
            acked = local;
            SaveSidecar();
            if (res["rev"] != null) rev = res["rev"]!.DeepClone();
            drawRev = null;
            loaded = true;
            Note = " · plot saved to Lx Book " + Stamp();
        }
        finally
        {
            showBusy = false;
        }
    }
}
