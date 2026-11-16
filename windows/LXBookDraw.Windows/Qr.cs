using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace LXBookDrawWin;

/// QR codes (byte mode, error correction M, versions 1 to 10), as lxdraw_pdf.py makes them.
static class Qr
{
    static readonly Dictionary<int, (int Ec, (int Count, int N)[] Groups)> Blocks = new()
    {
        [1] = (10, new[] { (1, 16) }), [2] = (16, new[] { (1, 28) }), [3] = (26, new[] { (1, 44) }), [4] = (18, new[] { (2, 32) }),
        [5] = (24, new[] { (2, 43) }), [6] = (16, new[] { (4, 27) }), [7] = (18, new[] { (4, 31) }), [8] = (22, new[] { (2, 38), (2, 39) }),
        [9] = (22, new[] { (3, 36), (2, 37) }), [10] = (26, new[] { (4, 43), (1, 44) }),
    };
    static readonly Dictionary<int, int[]> Align = new()
    {
        [1] = Array.Empty<int>(), [2] = new[] { 6, 18 }, [3] = new[] { 6, 22 }, [4] = new[] { 6, 26 }, [5] = new[] { 6, 30 },
        [6] = new[] { 6, 34 }, [7] = new[] { 6, 22, 38 }, [8] = new[] { 6, 24, 42 }, [9] = new[] { 6, 26, 46 }, [10] = new[] { 6, 28, 50 },
    };
    static readonly int[] Exp = new int[512];
    static readonly int[] Log = new int[256];

    static Qr()
    {
        int x = 1;
        for (int i = 0; i < 255; i++)
        {
            Exp[i] = x;
            Log[x] = i;
            x <<= 1;
            if ((x & 0x100) != 0) x ^= 0x11D;
        }
        for (int i = 255; i < 512; i++) Exp[i] = Exp[i - 255];
    }

    static int[] Rs(List<int> data, int n)
    {
        var gen = new List<int> { 1 };
        for (int i = 0; i < n; i++)
        {
            var nxt = new int[gen.Count + 1];
            for (int j = 0; j < gen.Count; j++)
            {
                var g = gen[j];
                nxt[j] ^= g;
                nxt[j + 1] ^= g != 0 ? Exp[(Log[g] + i) % 255] : 0;
            }
            gen = nxt.ToList();
        }
        var rem = new int[n];
        foreach (var b in data)
        {
            var factor = b ^ rem[0];
            Array.Copy(rem, 1, rem, 0, n - 1);
            rem[n - 1] = 0;
            if (factor == 0) continue;
            for (int j = 0; j < n; j++)
                if (gen[j + 1] != 0) rem[j] ^= Exp[(Log[gen[j + 1]] + Log[factor]) % 255];
        }
        return rem;
    }

    static readonly Dictionary<string, bool[][]?> cache = new();

    /// The squares of a QR code for `text`, top row first, true for dark, with a 2-square quiet border. Null if too long.
    public static bool[][]? Modules(string text)
    {
        if (cache.TryGetValue(text, out var hit)) return hit;
        var made = Make(text);
        cache[text] = made;
        return made;
    }

    static bool[][]? Make(string text)
    {
        var data = Encoding.UTF8.GetBytes(text);
        int version = 0;
        for (int v = 1; v <= 10; v++)
        {
            var cap = Blocks[v].Groups.Sum(g => g.Count * g.N);
            if (data.Length + (v < 10 ? 2 : 3) <= cap) { version = v; break; }
        }
        if (version == 0) return null;
        var (ec, groups) = Blocks[version];
        var capacity = groups.Sum(g => g.Count * g.N);
        var bits = new List<int> { 0, 1, 0, 0 };
        var countBits = version < 10 ? 8 : 16;
        for (int i = countBits - 1; i >= 0; i--) bits.Add((data.Length >> i) & 1);
        foreach (var b in data) for (int i = 7; i >= 0; i--) bits.Add((b >> i) & 1);
        for (int i = 0; i < Math.Min(4, capacity * 8 - bits.Count); i++) bits.Add(0);
        while (bits.Count % 8 != 0) bits.Add(0);
        var words = new List<int>();
        for (int i = 0; i < bits.Count; i += 8)
        {
            int w = 0;
            for (int j = 0; j < 8; j++) w = (w << 1) | bits[i + j];
            words.Add(w);
        }
        int[] pad = { 0xEC, 0x11 };
        for (int i = 0; words.Count < capacity; i++) words.Add(pad[i % 2]);
        var blocks = new List<List<int>>();
        int pos = 0;
        foreach (var (count, n) in groups)
            for (int c = 0; c < count; c++) { blocks.Add(words.GetRange(pos, n)); pos += n; }
        var ecs = blocks.Select(b => Rs(b, ec)).ToList();
        var stream = new List<int>();
        for (int i = 0; i < blocks.Max(b => b.Count); i++)
            foreach (var b in blocks) if (i < b.Count) stream.Add(b[i]);
        for (int i = 0; i < ec; i++) foreach (var e in ecs) stream.Add(e[i]);
        var sbits = new List<int>();
        foreach (var b in stream) for (int i = 7; i >= 0; i--) sbits.Add((b >> i) & 1);

        int size = 17 + 4 * version;
        var grid = new bool?[size, size];
        void Put(int r, int c, bool v) { if (r >= 0 && r < size && c >= 0 && c < size) grid[r, c] = v; }
        void Finder(int r0, int c0)
        {
            for (int r = -1; r < 8; r++)
                for (int c = -1; c < 8; c++)
                {
                    var inside = r >= 0 && r <= 6 && c >= 0 && c <= 6;
                    var dark = inside && (r == 0 || r == 6 || c == 0 || c == 6 || (r >= 2 && r <= 4 && c >= 2 && c <= 4));
                    Put(r0 + r, c0 + c, dark);
                }
        }
        Finder(0, 0);
        Finder(0, size - 7);
        Finder(size - 7, 0);
        foreach (var r in Align[version])
            foreach (var c in Align[version])
            {
                if (grid[r, c] != null) continue;
                for (int dr = -2; dr <= 2; dr++)
                    for (int dc = -2; dc <= 2; dc++)
                        grid[r + dr, c + dc] = Math.Max(Math.Abs(dr), Math.Abs(dc)) != 1;
            }
        for (int i = 8; i < size - 8; i++)
        {
            if (grid[6, i] == null) grid[6, i] = i % 2 == 0;
            if (grid[i, 6] == null) grid[i, 6] = i % 2 == 0;
        }
        grid[size - 8, 8] = true;
        var reserved = new List<(int, int)>();
        for (int i = 0; i < 9; i++) { reserved.Add((8, i)); reserved.Add((i, 8)); }
        for (int i = 0; i < 8; i++) { reserved.Add((8, size - 1 - i)); reserved.Add((size - 1 - i, 8)); }
        foreach (var (r, c) in reserved) if (grid[r, c] == null) grid[r, c] = false;
        if (version >= 7)
        {
            int rem = version;
            for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
            int vbits = (version << 12) | rem;
            for (int i = 0; i < 18; i++)
            {
                var bit = ((vbits >> i) & 1) != 0;
                int a = size - 11 + i % 3, b = i / 3;
                grid[a, b] = bit;
                grid[b, a] = bit;
            }
        }
        var isData = new bool[size, size];
        for (int r = 0; r < size; r++) for (int c = 0; c < size; c++) isData[r, c] = grid[r, c] == null;
        int k = 0, col = size - 1;
        bool up = true;
        while (col > 0)
        {
            if (col == 6) col--;
            for (int step = 0; step < size; step++)
            {
                int r = up ? size - 1 - step : step;
                foreach (var cc in new[] { col, col - 1 })
                {
                    if (!isData[r, cc]) continue;
                    grid[r, cc] = k < sbits.Count && sbits[k] != 0;
                    k++;
                }
            }
            up = !up;
            col -= 2;
        }

        Func<int, int, bool>[] masks =
        {
            (r, c) => (r + c) % 2 == 0, (r, c) => r % 2 == 0, (r, c) => c % 3 == 0, (r, c) => (r + c) % 3 == 0,
            (r, c) => (r / 2 + c / 3) % 2 == 0, (r, c) => (r * c) % 2 + (r * c) % 3 == 0,
            (r, c) => ((r * c) % 2 + (r * c) % 3) % 2 == 0, (r, c) => ((r + c) % 2 + (r * c) % 3) % 2 == 0,
        };

        bool[,] WithMask(int mi)
        {
            var g = new bool[size, size];
            for (int r = 0; r < size; r++)
                for (int c = 0; c < size; c++)
                {
                    var v = grid[r, c] ?? false;
                    if (isData[r, c] && masks[mi](r, c)) v = !v;
                    g[r, c] = v;
                }
            int fmt = mi;
            int rem = fmt;
            for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
            int fbits = ((fmt << 10) | rem) ^ 0x5412;
            bool Bit(int i) => ((fbits >> i) & 1) != 0;
            for (int i = 0; i < 6; i++) g[i, 8] = Bit(i);
            g[7, 8] = Bit(6);
            g[8, 8] = Bit(7);
            g[8, 7] = Bit(8);
            for (int i = 9; i < 15; i++) g[8, 14 - i] = Bit(i);
            for (int i = 0; i < 8; i++) g[8, size - 1 - i] = Bit(i);
            for (int i = 8; i < 15; i++) g[size - 15 + i, 8] = Bit(i);
            g[size - 8, 8] = true;
            return g;
        }

        int Penalty(bool[,] g)
        {
            int score = 0;
            for (int pass = 0; pass < 2; pass++)
                for (int a = 0; a < size; a++)
                {
                    bool At(int i) => pass == 0 ? g[a, i] : g[i, a];
                    int run = 1;
                    for (int i = 1; i < size; i++)
                    {
                        if (At(i) == At(i - 1)) run++;
                        else
                        {
                            if (run >= 5) score += run - 2;
                            run = 1;
                        }
                    }
                    if (run >= 5) score += run - 2;
                    var sb = new StringBuilder();
                    for (int i = 0; i < size; i++) sb.Append(At(i) ? '1' : '0');
                    var s = sb.ToString();
                    score += 40 * (Count(s, "10111010000") + Count(s, "00001011101"));
                }
            for (int r = 0; r < size - 1; r++)
                for (int c = 0; c < size - 1; c++)
                    if (g[r, c] == g[r, c + 1] && g[r, c] == g[r + 1, c] && g[r, c] == g[r + 1, c + 1]) score += 3;
            int dark = 0;
            foreach (var v in g) if (v) dark++;
            score += 10 * (Math.Abs(dark * 20 - size * size * 10) / (size * size));
            return score;
        }

        bool[,]? best = null;
        int bestScore = int.MaxValue;
        for (int mi = 0; mi < 8; mi++)
        {
            var g = WithMask(mi);
            var p = Penalty(g);
            if (p < bestScore) { bestScore = p; best = g; }
        }
        const int quiet = 2;
        var outp = new bool[size + 2 * quiet][];
        for (int r = 0; r < outp.Length; r++)
        {
            outp[r] = new bool[size + 2 * quiet];
            if (r < quiet || r >= size + quiet) continue;
            for (int c = 0; c < size; c++) outp[r][c + quiet] = best![r - quiet, c];
        }
        return outp;
    }

    // Python's str.count: non-overlapping occurrences
    static int Count(string s, string sub)
    {
        int n = 0, i = 0;
        while ((i = s.IndexOf(sub, i, StringComparison.Ordinal)) >= 0) { n++; i += sub.Length; }
        return n;
    }
}
