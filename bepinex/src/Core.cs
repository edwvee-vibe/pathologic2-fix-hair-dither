// Core of the BepInEx variant: no BepInEx or Unity types here, so build.ps1 can self-test it from PowerShell.
// The data resource (made by build.ps1) holds, for every supported game version, the original and the patched shader
// blobs of globalgamemanagers.assets, their positions and SHA-256 hashes. The same data as in the .ps1 release.
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;

namespace Pathologic2HairDitherFix
{
    public sealed class Region
    {
        public int LenPos, BlobPos, Length, OrigLen, NewLen, Orig, New;
    }

    public sealed class GameBuild
    {
        public string Game, Skeleton, Original, Patched;
        public long Size;
        public Region[] Regions;
    }

    public static class Core
    {
        public const string ResourceName = "hairdither.data";
        static GameBuild[] builds;
        static byte[] payload;

        public static GameBuild[] Builds
        {
            get { Load(); return builds; }
        }

        // Format (gzip): int32 count; per build: string game, int64 size, string skeleton, string original, string patched,
        // int32 regions, per region 7 x int32 (LenPos, BlobPos, Length, OrigLen, NewLen, Orig, New); int32 payload length, payload
        static void Load()
        {
            if (builds != null) return;
            Stream res = typeof(Core).Assembly.GetManifestResourceStream(ResourceName);
            if (res == null) throw new InvalidDataException("resource " + ResourceName + " is missing (built without build.ps1?)");
            using (GZipStream gz = new GZipStream(res, CompressionMode.Decompress))
            using (BinaryReader r = new BinaryReader(gz))
            {
                GameBuild[] list = new GameBuild[r.ReadInt32()];
                for (int i = 0; i < list.Length; i++)
                {
                    GameBuild b = new GameBuild();
                    b.Game = r.ReadString(); b.Size = r.ReadInt64();
                    b.Skeleton = r.ReadString(); b.Original = r.ReadString(); b.Patched = r.ReadString();
                    b.Regions = new Region[r.ReadInt32()];
                    for (int k = 0; k < b.Regions.Length; k++)
                    {
                        Region g = new Region();
                        g.LenPos = r.ReadInt32(); g.BlobPos = r.ReadInt32(); g.Length = r.ReadInt32();
                        g.OrigLen = r.ReadInt32(); g.NewLen = r.ReadInt32(); g.Orig = r.ReadInt32(); g.New = r.ReadInt32();
                        b.Regions[k] = g;
                    }
                    list[i] = b;
                }
                int n = r.ReadInt32();
                payload = r.ReadBytes(n);
                if (payload.Length != n) throw new InvalidDataException("data resource is truncated");
                builds = list;
            }
        }

        public static string Sha256(byte[] data)
        {
            using (SHA256 sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
        }

        // Hash of the file with the shader data blanked out: identifies the game version whatever state the shaders are in
        static string SkeletonHash(byte[] data, GameBuild b)
        {
            byte[] copy = (byte[])data.Clone();
            foreach (Region g in b.Regions)
            {
                Array.Clear(copy, g.LenPos, 4);
                Array.Clear(copy, g.BlobPos, g.Length);
            }
            return Sha256(copy);
        }

        static string Supported()
        {
            List<string> v = new List<string>();
            foreach (GameBuild b in Builds) v.Add(b.Game);
            return string.Join(", ", v.ToArray());
        }

        // enable = true: patched shaders, false: the original file. Only a file the data knows is written, and only
        // after the result matched the expected hash. The file is opened exclusively: if the game (Unity) already has it
        // open, nothing is changed. Returns the final state: "ON", "OFF", "unknown" or "in use".
        public static string Run(string file, bool enable, Action<string> info, Action<string> warn)
        {
            FileStream fs;
            try
            {
                fs = new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            }
            catch (UnauthorizedAccessException e)
            {
                warn("no write access to " + file + " (" + e.Message + "); nothing changed");
                return "in use";
            }
            catch (IOException e)
            {
                warn("cannot open " + file + " exclusively (" + e.Message + "); nothing changed");
                return "in use";
            }
            using (fs)
            {
                byte[] bytes = new byte[fs.Length];
                int read = 0;
                while (read < bytes.Length)
                {
                    int n = fs.Read(bytes, read, bytes.Length - read);
                    if (n <= 0) throw new EndOfStreamException(file);
                    read += n;
                }

                GameBuild build = null;
                foreach (GameBuild b in Builds)
                    if (b.Size == bytes.Length && SkeletonHash(bytes, b) == b.Skeleton) { build = b; break; }
                if (build == null)
                {
                    warn("globalgamemanagers.assets is not a file this mod knows (size " + bytes.Length + "; supported game versions: " +
                         Supported() + "). Nothing changed. After a game update, look for a new version of the mod.");
                    return "unknown";
                }

                string hash = Sha256(bytes);
                string state = hash == build.Patched ? "ON" : hash == build.Original ? "OFF" : "unknown";
                string want = enable ? build.Patched : build.Original;
                if (hash == want)
                {
                    info("game " + build.Game + ", hair fix " + state + ", nothing to do");
                    return state;
                }

                foreach (Region g in build.Regions)
                {
                    BitConverter.GetBytes(enable ? g.NewLen : g.OrigLen).CopyTo(bytes, g.LenPos);
                    Array.Copy(payload, enable ? g.New : g.Orig, bytes, g.BlobPos, g.Length);
                }
                if (Sha256(bytes) != want)
                {
                    warn("internal check failed: the result does not match the expected file; nothing changed");
                    return state;
                }
                foreach (Region g in build.Regions)
                {
                    fs.Position = g.LenPos; fs.Write(bytes, g.LenPos, 4);
                    fs.Position = g.BlobPos; fs.Write(bytes, g.BlobPos, g.Length);
                }
                fs.Flush(true);
                string now = enable ? "ON" : "OFF";
                info("game " + build.Game + ", hair fix was " + state + ", now " + now + " (file written)");
                return now;
            }
        }
    }
}
