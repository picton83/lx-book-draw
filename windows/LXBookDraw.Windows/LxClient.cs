using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace LXBookDrawWin;

public sealed class LxException : Exception
{
    public bool Login { get; }
    public bool NoShow { get; }
    public LxException(string message, bool login = false, bool noShow = false) : base(message) { Login = login; NoShow = noShow; }
}

/// What is kept between runs: the Lx Book address, the key Lx Book gave this PC, and the shows. The password is never kept.
/// The file is protected with Windows' own data protection, so only this Windows user on this PC can read it.
public sealed class Account
{
    public string Server { get; set; } = "https://34-74-154-240.sslip.io/book";
    public string User { get; set; } = "";
    public string Key { get; set; } = "";
    public List<ShowRef> Shows { get; set; } = new();
    public string ShowID { get; set; } = "";

    public bool SignedIn => Key.Length > 0;
    public string ShowName => Shows.FirstOrDefault(s => s.Id == ShowID)?.Name ?? "";

    public static string Folder
    {
        get
        {
            var f = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LX Book Draw");
            Directory.CreateDirectory(f);
            return f;
        }
    }

    static string FilePath => Path.Combine(Folder, "account.dat");

    public static Account Load()
    {
        try
        {
            var raw = ProtectedData.Unprotect(File.ReadAllBytes(FilePath), null, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<Account>(raw) ?? new Account();
        }
        catch
        {
            return new Account();
        }
    }

    public void Save()
    {
        var raw = JsonSerializer.SerializeToUtf8Bytes(this);
        File.WriteAllBytes(FilePath, ProtectedData.Protect(raw, null, DataProtectionScope.CurrentUser));
    }
}

public sealed class ShowRef
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public override string ToString() => Name;
}

/// Talks to Lx Book the same way the Mac app does (LxBook.swift's request).
public sealed class LxClient
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(120) };
    readonly Account account;
    public Account Account => account;

    public LxClient(Account account) { this.account = account; }

    public async Task<JsonObject> Call(string method, string path, JsonNode? body = null, bool withShow = true, string? show = null, byte[]? raw = null)
    {
        var server = account.Server.TrimEnd('/');
        using var req = new HttpRequestMessage(new HttpMethod(method), server + "/" + path);
        if (account.Key.Length > 0) req.Headers.Add("X-LxBook-Key", account.Key);
        var showID = show ?? account.ShowID;
        if (withShow && showID.Length > 0) req.Headers.Add("X-LxBook-Show", showID);
        req.Headers.TryAddWithoutValidation("User-Agent", "LXBookDraw/" + AppInfo.Version + " (Windows)");
        req.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true };
        if (raw != null)
        {
            req.Content = new ByteArrayContent(raw);
            req.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream");
        }
        else if (body != null) req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        HttpResponseMessage res;
        try
        {
            res = await http.SendAsync(req);
        }
        catch (Exception e)
        {
            throw new LxException("Can't reach Lx Book (" + e.Message + ")");
        }
        var text = await res.Content.ReadAsStringAsync();
        JsonObject? json = null;
        try { json = JsonNode.Parse(text) as JsonObject; } catch { }
        var code = (int)res.StatusCode;
        var error = J.S(json, "error");
        if (code == 401 && J.IsTrue(json, "login")) throw new LxException("Lx Book no longer accepts this PC's sign-in. Sign in again.", login: true);
        if (code == 401 && account.Key.Length == 0) throw new LxException(error.Length > 0 ? error : "Wrong username or password.");
        if (code == 401) throw new LxException(error.Length > 0 ? error : "Lx Book didn't accept the key.", login: true);
        if (code == 404 && J.IsTrue(json, "noShow")) throw new LxException(error.Length > 0 ? error : "That show isn't in Lx Book any more.", noShow: true);
        if (code >= 400) throw new LxException(error.Length > 0 ? error : $"Lx Book answered {code}.");
        return json ?? throw new LxException("That address didn't answer like Lx Book.");
    }

    /// Signs in. The password is sent once and not kept; Lx Book's key is.
    public async Task SignIn(string server, string user, string password)
    {
        account.Server = server.Trim().TrimEnd('/');
        account.Key = "";
        var body = new JsonObject
        {
            ["username"] = user, ["password"] = password, ["app"] = "LX Book Draw",
            ["device"] = Environment.MachineName + " (Windows)"
        };
        var j = await Call("POST", "api/apps/login", body, withShow: false);
        var key = J.S(j, "key");
        if (key.Length == 0) throw new LxException("Lx Book didn't give a key. Is it up to date?");
        account.Key = key;
        var who = J.G(j, "user");
        var name = who is JsonObject ? J.S(who, "name") : J.Txt(who);
        account.User = name.Length > 0 ? name : user;
        account.Shows = J.Objs(j, "shows").Select(s => new ShowRef { Id = J.Txt(J.G(s, "id")), Name = J.S(s, "name") }).Where(s => s.Id.Length > 0).ToList();
        var open = J.Txt(J.G(j, "open"));
        if (account.Shows.All(s => s.Id != account.ShowID))
            account.ShowID = account.Shows.Any(s => s.Id == open) ? open : (account.Shows.FirstOrDefault()?.Id ?? "");
        account.Save();
    }

    /// Asks Lx Book for the shows this account can open now (api/apps/shows), with the key: no signing in again.
    /// Returns false if Lx Book couldn't say (offline, or an Lx Book from before api/apps/shows); the last list is kept.
    public async Task<bool> RefreshShows()
    {
        if (account.Key.Length == 0) return false;
        try
        {
            var j = await Call("GET", "api/apps/shows", withShow: false);
            var shows = J.Objs(j, "shows").Select(s => new ShowRef { Id = J.Txt(J.G(s, "id")), Name = J.S(s, "name") }).Where(s => s.Id.Length > 0).ToList();
            if (j["shows"] is not JsonArray) return false;
            account.Shows = shows;
            account.Save();
            return true;
        }
        catch (LxException)
        {
            return false;
        }
    }

    public async Task SignOut()
    {
        try { await Call("POST", "api/apps/logout", new JsonObject(), withShow: false); } catch { }
        account.Key = "";
        account.Save();
    }

    public Task<JsonObject> Health() => Call("GET", "api/health");

    /// Everything needed to draw the show's plot: its drawing (with symbols) and the show's own data.
    public async Task<(JsonObject? Drawing, JsonObject State, string ViewerLink)> LoadShow()
    {
        var draw = await Call("GET", "api/draw/state");
        var state = await Call("GET", "api/state");
        var link = J.S(draw, "viewerLink");
        if (!link.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) link = "";
        bool any = J.A(draw, "drawobjects").Count > 0 || J.A(draw, "drawsheets").Count > 0 || J.A(draw, "drawmeta").Count > 0;
        if (!any) return (null, state, link);
        var symbols = await Symbols(draw);
        return (PlotPdf.JoinDrawing(draw, symbols), state, link);
    }

    static string SymbolFolder
    {
        get
        {
            var f = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LX Book Draw", "symbols");
            Directory.CreateDirectory(f);
            return f;
        }
    }

    public static string SymbolFile(string id)
    {
        var safe = new string(id.Select(c => char.IsLetterOrDigit(c) || c == '-' || c == '_' ? c : '_').ToArray());
        return Path.Combine(SymbolFolder, safe + ".json");
    }

    /// The symbols the show's fixture types need: from this PC's copy of the library, then from Lx Book.
    async Task<Dictionary<string, JsonObject>> Symbols(JsonObject draw)
    {
        var have = new Dictionary<string, JsonObject>();
        var missing = new List<string>();
        foreach (var row in J.Objs(draw, "drawtypes"))
        {
            if (J.Has(row, "builtIn")) continue;
            var id = J.S(row, "symbol") is var s && s.Length > 0 ? s : J.Txt(J.G(row, "_id"));
            if (id.Length == 0 || have.ContainsKey(id) || missing.Contains(id)) continue;
            try
            {
                if (JsonNode.Parse(File.ReadAllText(SymbolFile(id))) is JsonObject cached) { have[id] = cached; continue; }
            }
            catch { }
            missing.Add(id);
        }
        if (missing.Count > 0)
        {
            try
            {
                var j = await Call("GET", "api/draw/symbols?ids=" + string.Join(",", missing.Select(Uri.EscapeDataString)));
                if (J.G(j, "symbols") is JsonObject found)
                    foreach (var (id, value) in found)
                    {
                        if (value is not JsonObject sym) continue;
                        have[id] = sym;
                        try { File.WriteAllText(SymbolFile(id), sym.ToJsonString()); } catch { }
                    }
            }
            catch (LxException) { }   // a missing symbol is drawn as a plain box
        }
        return have;
    }
}
