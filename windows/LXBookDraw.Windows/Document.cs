using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Threading;

namespace LXBookDrawWin;

/// The open drawing: its JSON, undo and redo, the change log, and saving (to its file, or to the show's working copy).
public sealed class DrawDoc
{
    public JsonObject D { get; private set; }
    public string? FilePath { get; set; }
    public bool Dirty { get; private set; }
    /// Raised after every change; true while a drag is still going (nothing saved or sent yet).
    public event Action<bool>? Changed;

    readonly List<(string Name, string Json)> undo = new(), redo = new();
    readonly DispatcherTimer saveTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    public DateTime LastChange { get; private set; } = DateTime.MinValue;

    public DrawDoc(JsonObject d, string? path)
    {
        M.Normalize(d);
        D = d;
        FilePath = path;
        saveTimer.Tick += (_, _) =>
        {
            saveTimer.Stop();
            SaveNow();
        };
    }

    public static DrawDoc Open(string path)
    {
        if (JsonNode.Parse(File.ReadAllText(path)) is not JsonObject d || d["layers"] is not JsonArray)
            throw new InvalidDataException("That isn't an LX Book Draw drawing.");
        return new DrawDoc(d, path);
    }

    public bool InShow => J.IsTrue(D, "inShow");
    public string UndoName => undo.Count > 0 ? undo[^1].Name : "";
    public string RedoName => redo.Count > 0 ? redo[^1].Name : "";

    void LogChange(string what)
    {
        if (D["history"] is not JsonArray h) D["history"] = h = new JsonArray();
        h.Add(new JsonObject { ["ts"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm"), ["what"] = what });
        while (h.Count > 400) h.RemoveAt(0);
    }

    static string Body(JsonObject d)
    {
        var c = (JsonObject)d.DeepClone();
        c.Remove("history");
        return c.ToJsonString();
    }

    /// One undoable change.
    public bool Edit(string name, Action<JsonObject> body)
    {
        var before = D.ToJsonString();
        var beforeBody = Body(D);
        body(D);
        if (Body(D) == beforeBody) return false;
        LogChange(name);
        undo.Add((name, before));
        if (undo.Count > 200) undo.RemoveAt(0);
        redo.Clear();
        Fire(false);
        return true;
    }

    /// A change from Lx Book: shown and saved, but not put on the undo list.
    public void ApplyRemote(Action<JsonObject> body)
    {
        var beforeBody = Body(D);
        body(D);
        if (Body(D) == beforeBody) return;
        LogChange("Update from Lx Book");
        Fire(false);
    }

    /// Replaces the whole drawing from Lx Book (not undoable).
    public void ReplaceRemote(JsonObject d)
    {
        M.Normalize(d);
        if (D["history"] is JsonArray h && d["history"] == null) d["history"] = h.DeepClone();
        D = d;
        Fire(false);
    }

    /// While dragging: show the change without recording undo.
    public void SetLive(JsonObject d)
    {
        D = d;
        Changed?.Invoke(true);
    }

    /// The end of a drag: one undo step back to where the drag started.
    public void CommitLive(string beforeJson, string name)
    {
        var old = (JsonObject)JsonNode.Parse(beforeJson)!;
        if (Body(old) == Body(D)) { Fire(false); return; }
        LogChange(name);
        undo.Add((name, beforeJson));
        redo.Clear();
        Fire(false);
    }

    public void Undo() => Step(undo, redo, "Undo: ");
    public void Redo() => Step(redo, undo, "Redo: ");

    void Step(List<(string Name, string Json)> from, List<(string Name, string Json)> to, string label)
    {
        if (from.Count == 0) return;
        var (name, json) = from[^1];
        from.RemoveAt(from.Count - 1);
        to.Add((name, D.ToJsonString()));
        var restored = (JsonObject)JsonNode.Parse(json)!;
        restored["history"] = D["history"]?.DeepClone();
        // what Lx Book keeps for linked fixtures stays as Lx Book has it now
        D = restored;
        LogChange(label + name);
        Fire(false);
    }

    void Fire(bool live)
    {
        Dirty = true;
        LastChange = DateTime.Now;
        Changed?.Invoke(live);
        if (!live && FilePath != null)
        {
            saveTimer.Stop();
            saveTimer.Start();
        }
    }

    /// Saves to the file now (a show's drawing is saved to its working copy on this PC).
    public void SaveNow()
    {
        if (FilePath == null) return;
        var opts = new JsonSerializerOptions { WriteIndented = false };
        var tmp = FilePath + ".saving";
        File.WriteAllText(tmp, D.ToJsonString(opts));
        File.Move(tmp, FilePath, true);
        Dirty = false;
    }
}
