using System.Security.Cryptography;
using Aes = System.Security.Cryptography.Aes;
using System.Text.Json;
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Versions;

// MTPak — Motor Town pak helper.
//   findkey                 find the pak AES key in the shipping exe and save it to aes.txt
//   extract <filter> [out]  extract every pak file whose path contains <filter>
//   tires [out.json]        decode MTTirePhysicsParams from every tire asset
//   mkmod <values.json> [out.pak]  patch tire params in place and write an override pak
//   verifymod <pak>         decode the tire params from a mod pak on its own
//   grep <text>             list .uasset files whose header/name map contains <text> (ASCII)
// Options: --game <Motor Town install dir>   (default: D:\Steam\steamapps\common\Motor Town)

var toolDir = FindToolDir();
var opts = ParseArgs(args, out var positional);
var game = opts.GetValueOrDefault("game", @"D:\Steam\steamapps\common\Motor Town");
var exePath = Path.Combine(game, @"MotorTown\Binaries\Win64\MotorTown-Win64-Shipping.exe");
var paksDir = Path.Combine(game, @"MotorTown\Content\Paks");
var keyFile = Path.Combine(toolDir, "aes.txt");

// FMTTirePhysicsParams, in reflection order (verified offsets 0x00..0x3C). Cooked assets use
// unversioned serialization: fields equal to the C++ default are omitted, so start from defaults.
string[] fields = ["PatchLengthCoefficient", "StaticMu", "SlidingMu", "SpringX", "SpringY", "DampingX", "DampingY",
    "CoolDownSpeed", "WarmUpSpeed", "WearRate", "SmokeRate", "MaxWeightKg", "BrushCount",
    "OffroadFriction", "RollingResistanceCoeff", "RollingResistanceCoeffV1"];


switch (positional.FirstOrDefault())
{
    case "findkey": FindKey(); break;
    case "extract": Extract(positional.ElementAtOrDefault(1) ?? "", positional.ElementAtOrDefault(2) ?? Path.Combine(toolDir, "extracted")); break;
    case "tires": Tires(positional.ElementAtOrDefault(1) ?? Path.Combine(toolDir, "tires.json"), Mount()); break;
    case "mkmod": MkMod(positional[1], positional.ElementAtOrDefault(2) ?? Path.Combine(toolDir, "build", "MTTireFix_P.pak")); break;
    case "verifymod": VerifyMod(positional[1]); break;
    case "grep": Grep(positional[1]); break;
    default:
        Console.WriteLine("usage: MTPak findkey | extract <filter> [outDir] | tires [out.json] | mkmod <values.json> [out.pak] | verifymod <pak>  [--game <dir>]");
        break;
}

// ---------------------------------------------------------------- findkey
void FindKey()
{
    var exe = File.ReadAllBytes(exePath);
    var block = ReadEncryptedIndexBlock(Directory.GetFiles(paksDir, "*.pak").First());
    if (block == null) { Console.WriteLine("Pak index is not encrypted; no key needed."); return; }

    bool Test(byte[] key)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        var d = aes.DecryptEcb(block, PaddingMode.None);
        int len = BitConverter.ToInt32(d, 0); // index starts with the mount point FString, e.g. "../../../"
        return len > 0 && len < 1024 && d[4] == '.' && d[5] == '.' && d[6] == '/';
    }

    // UE's UE_REGISTER_ENCRYPTION_KEY callback builds the 32-byte key on the stack with eight
    // "mov dword [base+disp], imm32" instructions. The compiler interleaves other instructions,
    // so collect those stores inside a sliding window instead of requiring them to be contiguous.
    var stores = new List<(int pos, int reg, int disp, uint imm)>();
    for (int i = 0; i < exe.Length - 12; i++)
    {
        int q = i;
        if (exe[q] >= 0x40 && exe[q] <= 0x4F && exe[q + 1] == 0xC7) q++;
        if (exe[q] != 0xC7) continue;
        byte modrm = exe[q + 1];
        int mod = modrm >> 6, rm = modrm & 7;
        if (((modrm >> 3) & 7) != 0 || mod == 3 || (mod == 0 && rm == 5)) continue;
        int p = q + 2, reg = rm;
        if (rm == 4) { reg = 0x10 | (exe[p] & 7); p++; } // SIB (rsp-based)
        int disp = mod == 1 ? (sbyte)exe[p] : mod == 2 ? BitConverter.ToInt32(exe, p) : 0;
        p += mod == 1 ? 1 : mod == 2 ? 4 : 0;
        stores.Add((i, reg, disp, BitConverter.ToUInt32(exe, p)));
    }
    var seen = new HashSet<string>();
    for (int a = 0; a < stores.Count; a++)
    {
        var map = new Dictionary<int, uint>();
        for (int b = a; b < stores.Count && stores[b].pos - stores[a].pos < 160; b++)
            if (stores[b].reg == stores[a].reg) map[stores[b].disp] = stores[b].imm;
        if (map.Count < 8) continue;
        foreach (var start in map.Keys)
        {
            var key = new byte[32]; bool ok = true;
            for (int k = 0; k < 8 && ok; k++)
                if (map.TryGetValue(start + 4 * k, out var v)) BitConverter.GetBytes(v).CopyTo(key, 4 * k); else ok = false;
            if (!ok || !seen.Add(Convert.ToHexString(key))) continue;
            if (Test(key)) { Save(key, $"stack-built key near exe offset 0x{stores[a].pos:X}"); return; }
        }
    }
    // Fallback: a 32-byte constant stored as-is somewhere in the image.
    var bits = new bool[256]; var tmp = new byte[32];
    for (int i = 0; i + 32 <= exe.Length; i++)
    {
        Array.Clear(bits); int distinct = 0;
        for (int k = 0; k < 32; k++) if (!bits[exe[i + k]]) { bits[exe[i + k]] = true; distinct++; }
        if (distinct < 24) continue;
        Buffer.BlockCopy(exe, i, tmp, 0, 32);
        if (Test(tmp)) { Save(tmp, $"raw constant at exe offset 0x{i:X}"); return; }
    }
    Console.WriteLine($"No key found ({seen.Count} candidates tried). See README for the manual route.");

    void Save(byte[] key, string where)
    {
        var hex = "0x" + Convert.ToHexString(key);
        File.WriteAllText(keyFile, hex);
        Console.WriteLine($"FOUND {hex}\n  ({where}); saved to {keyFile}");
    }
}

static byte[]? ReadEncryptedIndexBlock(string pak)
{
    using var fs = File.OpenRead(pak);
    fs.Seek(-221, SeekOrigin.End); // pak v11 footer
    var f = new byte[221]; fs.ReadExactly(f);
    if (BitConverter.ToUInt32(f, 17) != 0x5A6F12E1) throw new InvalidDataException("Unexpected pak footer (not v11?)");
    if (f[16] == 0) return null;
    fs.Seek(BitConverter.ToInt64(f, 25), SeekOrigin.Begin);
    var block = new byte[16]; fs.ReadExactly(block);
    return block;
}

// ---------------------------------------------------------------- extract / tires
DefaultFileProvider Mount()
{
    if (!File.Exists(keyFile)) throw new FileNotFoundException("Run 'MTPak findkey' first.", keyFile);
    var oodle = Path.Combine(toolDir, OodleHelper.OODLE_NAME_CURRENT);
    if (!File.Exists(oodle)) throw new FileNotFoundException($"Oodle DLL missing; place {OodleHelper.OODLE_NAME_CURRENT} in {toolDir}", oodle);
    OodleHelper.Initialize(oodle);
    var provider = new DefaultFileProvider(paksDir, SearchOption.TopDirectoryOnly, new VersionContainer(EGame.GAME_UE5_5));
    provider.Initialize();
    provider.SubmitKey(new FGuid(), new FAesKey(File.ReadAllText(keyFile).Trim()));
    Console.WriteLine($"Mounted {provider.Files.Count} files");
    return provider;
}

void Extract(string filter, string outDir)
{
    var provider = Mount(); int n = 0;
    foreach (var (path, file) in provider.Files)
    {
        if (!path.Contains(filter, StringComparison.OrdinalIgnoreCase)) continue;
        var dest = Path.Combine(outDir, path);
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        File.WriteAllBytes(dest, file.Read()); n++;
    }
    Console.WriteLine($"Extracted {n} files to {outDir}");
}

void MkMod(string valuesJson, string outPak)
{
    // Only fields the asset already stores can be patched in place (same size, .uasset unchanged).
    var values = JsonSerializer.Deserialize<Dictionary<string, Dictionary<string, double>>>(File.ReadAllText(valuesJson))!;
    var provider = Mount();
    var files = new Dictionary<string, byte[]>();
    foreach (var (path, file) in provider.Files)
    {
        if (!path.Contains("Cars/Parts/Tire/", StringComparison.OrdinalIgnoreCase) || !path.EndsWith(".uexp")) continue;
        var name = Path.GetFileNameWithoutExtension(path);
        if (!values.TryGetValue(name, out var want)) continue;
        var b = file.Read(); int p = 0;
        ReadHeader(b, ref p);
        var props = ReadHeader(b, ref p);
        var done = new HashSet<string>();
        foreach (var (idx, zero) in props)
        {
            if (zero) continue;
            var f = idx < fields.Length ? fields[idx] : "";
            if (f != "BrushCount" && want.TryGetValue(f, out var v))
            {
                Console.WriteLine($"{name,-30} {f,-10} {BitConverter.ToSingle(b, p),10} -> {v}");
                BitConverter.GetBytes((float)v).CopyTo(b, p);
                done.Add(f);
            }
            p += 4;
        }
        var missing = want.Keys.Except(done).ToList();
        if (missing.Count > 0) throw new InvalidOperationException($"{name}: not stored in asset, can't patch in place: {string.Join(", ", missing)}");
        files[path] = b;
        var uasset = path[..^5] + ".uasset";
        files[uasset] = provider.Files[uasset].Read();
    }
    Directory.CreateDirectory(Path.GetDirectoryName(outPak)!);
    PakWriter.Write(outPak, files);
    Console.WriteLine($"Wrote {outPak} ({files.Count} files, {new FileInfo(outPak).Length} bytes)");
}

void Grep(string text)
{
    var provider = Mount(); int n = 0;
    var needle = System.Text.Encoding.ASCII.GetBytes(text);
    foreach (var (path, file) in provider.Files)
    {
        if (!path.EndsWith(".uasset")) continue;
        if (file.Read().AsSpan().IndexOf(needle) >= 0) { Console.WriteLine(path); n++; }
    }
    Console.WriteLine($"{n} matches");
}

void VerifyMod(string pak)
{
    var provider = new DefaultFileProvider(Path.GetDirectoryName(Path.GetFullPath(pak))!, SearchOption.TopDirectoryOnly, new VersionContainer(EGame.GAME_UE5_5));
    provider.Initialize();
    Console.WriteLine($"unloaded={provider.UnloadedVfs.Count} mounted={provider.MountedVfs.Count}");
    try
    {
        var r = new CUE4Parse.UE4.Pak.PakFileReader(Path.GetFullPath(pak), provider.Versions);
        Console.WriteLine($"reader: version={r.Info.Version} encrypted={r.IsEncrypted} indexEnc={r.Info.EncryptedIndex}");
        r.Mount(StringComparer.OrdinalIgnoreCase);
        Console.WriteLine($"reader files: {r.Files.Count}; mount={r.MountPoint}");
        foreach (var k in r.Files.Keys.Take(4)) Console.WriteLine("  " + k);
    }
    catch (Exception ex) { Console.WriteLine("reader error: " + ex); }
    provider.Mount();
    Console.WriteLine($"Mod pak mounted, {provider.Files.Count} files");
    Tires(Path.ChangeExtension(pak, ".json"), provider);
}

void Tires(string outJson, DefaultFileProvider provider)
{
    var defaults = new Dictionary<string, double> {
        ["PatchLengthCoefficient"] = 20000, ["StaticMu"] = 1.0, ["SlidingMu"] = 0.8, ["SpringX"] = 30000, ["SpringY"] = 8000,
        ["DampingX"] = 100, ["DampingY"] = 20, ["CoolDownSpeed"] = 0.5, ["WarmUpSpeed"] = 100, ["WearRate"] = 1.0,
        ["SmokeRate"] = 1.0, ["MaxWeightKg"] = 1000, ["BrushCount"] = 180 };

    var result = new SortedDictionary<string, Dictionary<string, object>>();
    foreach (var (path, file) in provider.Files)
    {
        if (!path.Contains("Cars/Parts/Tire/", StringComparison.OrdinalIgnoreCase) || !path.EndsWith(".uexp")) continue;
        var b = file.Read(); int p = 0;
        var top = ReadHeader(b, ref p);
        if (top.Count == 0 || top[0].index != 0) { Console.WriteLine($"skip {path}: unexpected layout"); continue; }
        var props = ReadHeader(b, ref p);
        var vals = defaults.ToDictionary(kv => kv.Key, kv => (object)kv.Value);
        var overridden = new List<string>();
        foreach (var (idx, zero) in props)
        {
            var name = idx < fields.Length ? fields[idx] : $"idx{idx}";
            overridden.Add(name);
            if (zero) { vals[name] = 0.0; continue; }
            vals[name] = name == "BrushCount" ? BitConverter.ToInt32(b, p) : Math.Round(BitConverter.ToSingle(b, p), 6);
            p += 4;
        }
        vals["_overridden"] = overridden;
        result[Path.GetFileNameWithoutExtension(path)] = vals;
    }
    File.WriteAllText(outJson, JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
    foreach (var (n, v) in result)
        Console.WriteLine($"{n,-30} SpringX={v["SpringX"],9} SpringY={v["SpringY"],8} DampingY={v["DampingY"],6} StaticMu={v["StaticMu"]} SlidingMu={v["SlidingMu"]}");
    Console.WriteLine($"Wrote {outJson}");
}

// UE5 unversioned property header: uint16 fragments (skip:7, hasZero:1, isLast:1, valueCount:7) + zero mask.
static List<(int index, bool zero)> ReadHeader(byte[] b, ref int p)
{
    var frags = new List<(int skip, bool z, int n)>();
    while (true)
    {
        ushort v = BitConverter.ToUInt16(b, p); p += 2;
        frags.Add((v & 0x7F, (v & 0x80) != 0, v >> 9));
        if ((v & 0x100) != 0) break;
    }
    int zeroCount = frags.Where(f => f.z).Sum(f => f.n);
    ulong mask = 0;
    if (zeroCount > 0)
    {
        int bytes = zeroCount <= 8 ? 1 : zeroCount <= 16 ? 2 : (zeroCount + 31) / 32 * 4;
        for (int i = 0; i < Math.Min(bytes, 8); i++) mask |= (ulong)b[p + i] << (8 * i);
        p += bytes;
    }
    var list = new List<(int, bool)>(); int idx = 0, zi = 0;
    foreach (var (skip, z, n) in frags)
    {
        idx += skip;
        for (int i = 0; i < n; i++, idx++) list.Add((idx, z && ((mask >> zi++) & 1) != 0));
    }
    return list;
}

static string FindToolDir()
{
    var d = new DirectoryInfo(AppContext.BaseDirectory);
    while (d != null && !File.Exists(Path.Combine(d.FullName, "README.md"))) d = d.Parent;
    return d?.FullName ?? AppContext.BaseDirectory;
}

static Dictionary<string, string> ParseArgs(string[] a, out List<string> positional)
{
    var o = new Dictionary<string, string>(); positional = [];
    for (int i = 0; i < a.Length; i++)
        if (a[i].StartsWith("--") && i + 1 < a.Length) o[a[i][2..]] = a[++i]; else positional.Add(a[i]);
    return o;
}
