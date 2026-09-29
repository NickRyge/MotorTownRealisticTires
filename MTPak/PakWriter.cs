using System.Security.Cryptography;
using System.Text;

// Minimal Unreal pak v11 writer: uncompressed, unencrypted entries, encoded entry index
// plus both lookup indexes UnrealPak writes: the path-hash index and the full directory index.
static class PakWriter
{
    const uint Magic = 0x5A6F12E1;
    const int Version = 11; // PakFile_Version_Fnv64BugFix

    public static void Write(string outPath, IReadOnlyDictionary<string, byte[]> files, string mountPoint = "../../../")
    {
        using var fs = File.Create(outPath);
        using var w = new BinaryWriter(fs);

        // Data section: per file, an inline entry header (offset written as 0) followed by the bytes.
        var entries = new List<(string path, long offset, byte[] data, byte[] sha)>();
        foreach (var (path, data) in files.OrderBy(f => f.Key, StringComparer.Ordinal))
        {
            long offset = fs.Position;
            var sha = SHA1.HashData(data);
            WriteEntryHeader(w, 0, data.Length, sha);
            w.Write(data);
            entries.Add((path, offset, data, sha));
        }

        // Encoded entries: flags + offset + uncompressed size (uncompressed files need no size/blocks).
        var enc = new MemoryStream();
        var ew = new BinaryWriter(enc);
        var locations = new Dictionary<string, int>();
        foreach (var e in entries)
        {
            locations[e.path] = (int)enc.Position;
            bool off32 = e.offset <= uint.MaxValue, size32 = e.data.Length <= uint.MaxValue;
            uint flags = (off32 ? 1u << 31 : 0) | (size32 ? 1u << 30 : 0) | (size32 ? 1u << 29 : 0);
            // compression method 0, not encrypted, 0 blocks, block size 0
            ew.Write(flags);
            if (off32) ew.Write((uint)e.offset); else ew.Write(e.offset);
            if (size32) ew.Write((uint)e.data.Length); else ew.Write((long)e.data.Length);
        }

        // Full directory index: every directory (with parents) -> { filename -> encoded offset }.
        var dirs = new SortedDictionary<string, SortedDictionary<string, int>>(StringComparer.Ordinal);
        void AddDir(string d) { if (!dirs.ContainsKey(d)) dirs[d] = new(StringComparer.Ordinal); }
        AddDir("/");
        foreach (var e in entries)
        {
            var slash = e.path.LastIndexOf('/');
            var dir = e.path[..(slash + 1)];
            for (int i = dir.IndexOf('/'); i >= 0; i = dir.IndexOf('/', i + 1)) AddDir(dir[..(i + 1)]);
            dirs[dir][e.path[(slash + 1)..]] = locations[e.path];
        }
        var dirStream = new MemoryStream();
        var dw = new BinaryWriter(dirStream);
        dw.Write(dirs.Count);
        foreach (var (dir, filesInDir) in dirs)
        {
            WriteFString(dw, dir);
            dw.Write(filesInDir.Count);
            foreach (var (name, loc) in filesInDir) { WriteFString(dw, name); dw.Write(loc); }
        }
        var dirBytes = dirStream.ToArray();

        // Path-hash index: FNV-64 of the lowercased UTF-16LE path -> encoded offset, then an empty pruned directory index.
        const ulong seed = 0;
        var phStream = new MemoryStream();
        var hw = new BinaryWriter(phStream);
        hw.Write(entries.Count);
        foreach (var e in entries) { hw.Write(Fnv64Path(e.path, seed)); hw.Write(locations[e.path]); }
        hw.Write(0);
        var phBytes = phStream.ToArray();

        // Primary index. Its size doesn't depend on the directory-index offset, so build it twice.
        byte[] BuildPrimary(long phOffset, long dirOffset)
        {
            var ms = new MemoryStream();
            var pw = new BinaryWriter(ms);
            WriteFString(pw, mountPoint);
            pw.Write(entries.Count);
            pw.Write(seed);                // PathHashSeed
            pw.Write(1);                   // bReaderHasPathHashIndex
            pw.Write(phOffset);
            pw.Write((long)phBytes.Length);
            pw.Write(SHA1.HashData(phBytes));
            pw.Write(1);                   // bReaderHasFullDirectoryIndex
            pw.Write(dirOffset);
            pw.Write((long)dirBytes.Length);
            pw.Write(SHA1.HashData(dirBytes));
            pw.Write((int)enc.Length);
            pw.Write(enc.ToArray());
            pw.Write(0);                   // no non-encodable entries
            return ms.ToArray();
        }
        long indexOffset = fs.Position;
        var primary = BuildPrimary(0, 0);
        long phOffset = indexOffset + primary.Length;
        primary = BuildPrimary(phOffset, phOffset + phBytes.Length);
        w.Write(primary);
        w.Write(phBytes);
        w.Write(dirBytes);

        // Footer (221 bytes).
        w.Write(new byte[16]);           // encryption key guid
        w.Write((byte)0);                // index not encrypted
        w.Write(Magic);
        w.Write(Version);
        w.Write(indexOffset);
        w.Write((long)primary.Length);
        w.Write(SHA1.HashData(primary));
        w.Write(new byte[5 * 32]);       // compression method names (none)
    }

    static ulong Fnv64Path(string path, ulong seed)
    {
        ulong hash = 0xcbf29ce484222325UL + seed;
        foreach (var b in Encoding.Unicode.GetBytes(path.ToLowerInvariant())) { hash ^= b; hash *= 0x100000001b3UL; }
        return hash;
    }

    static void WriteEntryHeader(BinaryWriter w, long offset, long size, byte[] sha)
    {
        w.Write(offset);
        w.Write(size);                   // compressed size
        w.Write(size);                   // uncompressed size
        w.Write(0u);                     // compression method index (none)
        w.Write(sha);
        w.Write((byte)0);                // flags
        w.Write(0u);                     // compression block size
    }

    static void WriteFString(BinaryWriter w, string s)
    {
        var bytes = Encoding.ASCII.GetBytes(s + "\0");
        w.Write(bytes.Length);
        w.Write(bytes);
    }
}
