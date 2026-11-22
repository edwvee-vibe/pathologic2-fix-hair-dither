// Core of the hair dither patch (C# 5, compiled by Add-Type in Windows PowerShell 5.1).
// LZ4 (block format), DXBC checksum, finding and replacing the cb1[0].<c> operand in pixel shaders,
// verification via D3DDisassemble (d3dcompiler_47.dll).
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace HairDitherFix
{
    public static class Lz4
    {
        public static byte[] Decompress(byte[] src, int off, int len, int outLen)
        {
            byte[] dst = new byte[outLen];
            int ip = off, end = off + len, op = 0;
            while (ip < end)
            {
                int token = src[ip++];
                int lit = token >> 4;
                if (lit == 15) { int b; do { b = src[ip++]; lit += b; } while (b == 255); }
                if (op + lit > outLen || ip + lit > end) throw new InvalidDataException("LZ4: literals out of bounds");
                Buffer.BlockCopy(src, ip, dst, op, lit);
                ip += lit; op += lit;
                if (ip >= end) break;
                int offset = src[ip] | (src[ip + 1] << 8);
                ip += 2;
                int ml = token & 15;
                if (ml == 15) { int b; do { b = src[ip++]; ml += b; } while (b == 255); }
                ml += 4;
                int m = op - offset;
                if (offset == 0 || m < 0 || op + ml > outLen) throw new InvalidDataException("LZ4: invalid match reference");
                for (int i = 0; i < ml; i++) dst[op++] = dst[m++];
            }
            if (op != outLen) throw new InvalidDataException("LZ4: decompressed size " + op + ", expected " + outLen);
            return dst;
        }

        // Optimal parsing: for each position, the longest match (hash chains), then
        // dynamic programming on the cost in bytes (literal ~ 1 byte, match = token + 2 offset bytes
        // + length bytes), as in LZ4HC level 12.
        public static byte[] CompressOptimal(byte[] data, int maxAttempts)
        {
            const int MaxDist = 65535, LastLiterals = 5, MfLimit = 12, HashBits = 17, NearLen = 64;
            int n = data.Length;
            int matchLimit = n - LastLiterals;
            int lastMatchStart = n - MfLimit;
            int[] head = new int[1 << HashBits];
            for (int i = 0; i < head.Length; i++) head[i] = -1;
            int[] chain = new int[n];
            int[] mlen = new int[n + 1];
            int[] moff = new int[n + 1];

            for (int p = 0; p + 4 <= n; p++)
            {
                uint v = (uint)(data[p] | (data[p + 1] << 8) | (data[p + 2] << 16) | (data[p + 3] << 24));
                int h = (int)((v * 2654435761u) >> (32 - HashBits));
                if (p <= lastMatchStart)
                {
                    int maxLen = matchLimit - p;
                    if (p > 0 && mlen[p - 1] > NearLen)
                    {
                        // inside a long match: same offset, 1 byte shorter
                        mlen[p] = Math.Min(mlen[p - 1] - 1, maxLen);
                        moff[p] = moff[p - 1];
                    }
                    else
                    {
                        int bestLen = 0, bestOff = 0, attempts = maxAttempts;
                        int c = head[h];
                        while (c >= 0 && attempts-- > 0)
                        {
                            int dist = p - c;
                            if (dist > MaxDist) break;
                            if (data[c + bestLen] == data[p + bestLen])
                            {
                                int l = 0;
                                while (l < maxLen && data[c + l] == data[p + l]) l++;
                                if (l > bestLen) { bestLen = l; bestOff = dist; if (l >= maxLen) break; }
                            }
                            c = chain[c];
                        }
                        if (bestLen >= 4) { mlen[p] = bestLen; moff[p] = bestOff; }
                    }
                }
                chain[p] = head[h];
                head[h] = p;
            }

            int[] price = new int[n + 1];
            int[] lit = new int[n + 1];
            int[] fromLen = new int[n + 1];
            int[] fromOff = new int[n + 1];
            for (int i = 1; i <= n; i++) price[i] = int.MaxValue;
            for (int i = 0; i < n; i++)
            {
                if (price[i] == int.MaxValue) continue;
                int r = lit[i] + 1;
                int cl = price[i] + 1 + (r == 15 ? 1 : 0) + (r > 15 && (r - 15) % 255 == 0 ? 1 : 0);
                if (cl < price[i + 1]) { price[i + 1] = cl; lit[i + 1] = r; fromLen[i + 1] = 0; }
                int L = mlen[i];
                if (L < 4) continue;
                int top = Math.Min(L, NearLen);
                for (int l = 4; l <= L; l++)
                {
                    if (l > top && l != L) { l = L - 1; continue; }
                    int ml = l - 4;
                    int cm = price[i] + 3 + (ml >= 15 ? 1 + (ml - 15) / 255 : 0);
                    if (cm < price[i + l]) { price[i + l] = cm; lit[i + l] = 0; fromLen[i + l] = l; fromOff[i + l] = moff[i]; }
                }
            }

            // backward pass: sequence of matches
            List<int[]> seq = new List<int[]>(); // {position, length, offset}
            int pos = n;
            while (pos > 0)
            {
                int l = fromLen[pos];
                if (l == 0) { pos--; continue; }
                pos -= l;
                seq.Add(new int[] { pos, l, fromOff[pos + l] });
            }
            seq.Reverse();
            MemoryStream outp = new MemoryStream(n / 8 + 16);
            int anchor = 0;
            foreach (int[] s in seq)
            {
                EmitSequence(outp, data, anchor, s[0] - anchor, s[2], s[1]);
                anchor = s[0] + s[1];
            }
            EmitSequence(outp, data, anchor, n - anchor, 0, 0);
            return outp.ToArray();
        }

        private static void EmitSequence(MemoryStream o, byte[] data, int litStart, int litLen, int offset, int matchLen)
        {
            int tokLit = Math.Min(litLen, 15);
            int tokMatch = matchLen == 0 ? 0 : Math.Min(matchLen - 4, 15);
            o.WriteByte((byte)((tokLit << 4) | tokMatch));
            if (litLen >= 15) WriteLen(o, litLen - 15);
            o.Write(data, litStart, litLen);
            if (matchLen == 0) return;
            o.WriteByte((byte)(offset & 0xFF));
            o.WriteByte((byte)(offset >> 8));
            if (matchLen - 4 >= 15) WriteLen(o, matchLen - 4 - 15);
        }

        private static void WriteLen(MemoryStream o, int rest)
        {
            while (rest >= 255) { o.WriteByte(255); rest -= 255; }
            o.WriteByte((byte)rest);
        }
    }

    public static class Dxbc
    {
        static readonly int[] S = {
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21 };
        static readonly uint[] K = MakeK();
        static uint[] MakeK()
        {
            uint[] k = new uint[64];
            for (int i = 0; i < 64; i++) k[i] = (uint)(long)Math.Floor(Math.Abs(Math.Sin(i + 1)) * 4294967296.0);
            return k;
        }

        static void Rounds(uint[] st, uint[] x)
        {
            uint a = st[0], b = st[1], c = st[2], d = st[3];
            for (int i = 0; i < 64; i++)
            {
                uint f; int g;
                if (i < 16) { f = (b & c) | (~b & d); g = i; }
                else if (i < 32) { f = (d & b) | (~d & c); g = (5 * i + 1) % 16; }
                else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) % 16; }
                else { f = c ^ (b | ~d); g = (7 * i) % 16; }
                f = f + a + K[i] + x[g];
                a = d; d = c; c = b;
                b = b + ((f << S[i]) | (f >> (32 - S[i])));
            }
            st[0] += a; st[1] += b; st[2] += c; st[3] += d;
        }

        // DXBC container checksum (MD5 variant, like ComputeHashRetail in DirectXShaderCompiler)
        public static byte[] Checksum(byte[] buf, int start, int size)
        {
            int dataStart = start + 20;
            int n = size - 20;
            int left = n & 63;
            bool twoRows = left >= 56;
            int pad = twoRows ? 120 - left : 56 - left;
            byte[] padding = new byte[128];
            padding[0] = 0x80;
            int nblocks = (n + pad + 8) >> 6;
            uint[] st = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476 };
            int nextEnd = twoRows ? nblocks - 2 : nblocks - 1;
            byte[] blk = new byte[64];
            uint[] x = new uint[16];
            for (int i = 0; i < nblocks; i++)
            {
                int off = i * 64;
                Array.Clear(blk, 0, 64);
                if (i == nextEnd)
                {
                    if (!twoRows && i == nblocks - 1)
                    {
                        int rem = n - off;
                        WriteU32(blk, 0, (uint)n << 3);
                        Buffer.BlockCopy(buf, dataStart + off, blk, 4, rem);
                        Buffer.BlockCopy(padding, 0, blk, 4 + rem, pad);
                        WriteU32(blk, 60, 1u | ((uint)n << 1));
                    }
                    else if (twoRows && i == nblocks - 2)
                    {
                        int rem = n - off;
                        Buffer.BlockCopy(buf, dataStart + off, blk, 0, rem);
                        Buffer.BlockCopy(padding, 0, blk, rem, pad - 56);
                        nextEnd = nblocks - 1;
                    }
                    else
                    {
                        WriteU32(blk, 0, (uint)n << 3);
                        Buffer.BlockCopy(padding, pad - 56, blk, 4, 56);
                        WriteU32(blk, 60, 1u | ((uint)n << 1));
                    }
                }
                else Buffer.BlockCopy(buf, dataStart + off, blk, 0, 64);
                for (int j = 0; j < 16; j++) x[j] = BitConverter.ToUInt32(blk, j * 4);
                Rounds(st, x);
            }
            byte[] r = new byte[16];
            for (int j = 0; j < 4; j++) WriteU32(r, j * 4, st[j]);
            return r;
        }

        static void WriteU32(byte[] b, int o, uint v)
        {
            b[o] = (byte)v; b[o + 1] = (byte)(v >> 8); b[o + 2] = (byte)(v >> 16); b[o + 3] = (byte)(v >> 24);
        }

        public static bool ChecksumOk(byte[] buf, int start, int size)
        {
            byte[] c = Checksum(buf, start, size);
            for (int i = 0; i < 16; i++) if (buf[start + 4 + i] != c[i]) return false;
            return true;
        }

        // All DXBC containers in the decompressed blob: (start, size) pairs
        public static List<int[]> FindContainers(byte[] blob)
        {
            List<int[]> r = new List<int[]>();
            int pos = 0;
            while (true)
            {
                int i = IndexOf(blob, pos);
                if (i < 0) break;
                if (i + 32 <= blob.Length)
                {
                    int size = BitConverter.ToInt32(blob, i + 24);
                    int one = BitConverter.ToInt32(blob, i + 20);
                    if (one == 1 && size >= 32 && size <= blob.Length - i) { r.Add(new int[] { i, size }); pos = i + size; continue; }
                }
                pos = i + 4;
            }
            return r;
        }

        static int IndexOf(byte[] b, int from)
        {
            for (int i = from; i + 4 <= b.Length; i++)
                if (b[i] == 0x44 && b[i + 1] == 0x58 && b[i + 2] == 0x42 && b[i + 3] == 0x43) return i;
            return -1;
        }

        // Offset of the SHDR/SHEX body inside the container, or -1
        static int ShaderChunk(byte[] b, int start)
        {
            int count = BitConverter.ToInt32(b, start + 28);
            for (int k = 0; k < count; k++)
            {
                int off = start + BitConverter.ToInt32(b, start + 32 + 4 * k);
                string cc = Encoding.ASCII.GetString(b, off, 4);
                if (cc == "SHDR" || cc == "SHEX") return off + 8;
            }
            return -1;
        }

        // For a pixel shader: absolute offsets of cb1[0] operand tokens (single component) in ADD instructions.
        // null if not a pixel shader. comps receives the current components (0..3).
        public static List<int> FindTimeAdds(byte[] b, int start, List<int> comps)
        {
            int body = ShaderChunk(b, start);
            if (body < 0) return null;
            uint ver = BitConverter.ToUInt32(b, body);
            if ((ver >> 16) != 0) return null; // 0 = pixel
            int total = BitConverter.ToInt32(b, body + 4);
            int p = body + 8, end = body + 4 * total;
            List<int> hits = new List<int>();
            while (p < end)
            {
                uint tok = BitConverter.ToUInt32(b, p);
                int op = (int)(tok & 0x7FF);
                if (op == 0x35) { p += 4 * BitConverter.ToInt32(b, p + 4); continue; } // customdata
                int len = (int)((tok >> 24) & 0x7F);
                if (len == 0) throw new InvalidDataException("DXBC: zero instruction length");
                if (op == 0x00) // ADD
                {
                    int q = p + 4;
                    if ((tok & 0x80000000u) != 0) q += 4;
                    for (int k = 0; k < 3; k++)
                    {
                        int opStart = q;
                        uint ot = BitConverter.ToUInt32(b, q); q += 4;
                        uint ext = ot & 0x80000000u;
                        while (ext != 0) { uint e = BitConverter.ToUInt32(b, q); q += 4; ext = e & 0x80000000u; }
                        int otype = (int)((ot >> 12) & 0xFF);
                        int dim = (int)((ot >> 20) & 3);
                        int[] idx = new int[dim];
                        bool immIdx = true;
                        for (int d = 0; d < dim; d++)
                        {
                            int rep = (int)((ot >> (22 + 3 * d)) & 7);
                            if (rep == 0) { idx[d] = BitConverter.ToInt32(b, q); q += 4; }
                            else { immIdx = false; q += 8; }
                        }
                        if (otype == 4) q += 4 * ((ot & 3) == 2 ? 4 : 1); // immediate32
                        if (k == 0 || otype != 8 || dim != 2 || !immIdx || idx[0] != 1 || idx[1] != 0) continue;
                        int mode = (int)((ot >> 2) & 3);
                        if (mode == 1)
                        {
                            int sw = (int)((ot >> 4) & 0xFF);
                            int c0 = sw & 3;
                            if (sw == c0 * 0x55) { hits.Add(opStart); comps.Add(c0); }
                        }
                        else if (mode == 2) { hits.Add(opStart); comps.Add((int)((ot >> 4) & 3)); }
                    }
                }
                p += 4 * len;
            }
            return hits;
        }

        public static void SetComponent(byte[] b, int opStart, int comp)
        {
            uint ot = BitConverter.ToUInt32(b, opStart);
            int mode = (int)((ot >> 2) & 3);
            if (mode == 1) ot = (ot & ~(0xFFu << 4)) | ((uint)(comp * 0x55) << 4);
            else ot = (ot & ~(3u << 4)) | ((uint)comp << 4);
            WriteU32(b, opStart, ot);
        }

        public static void FixChecksum(byte[] b, int start, int size)
        {
            byte[] c = Checksum(b, start, size);
            Buffer.BlockCopy(c, 0, b, start + 4, 16);
        }
    }

    [ComImport, Guid("8BA5FB08-5195-40e2-AC58-0D989C3A0102"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ID3DBlob
    {
        [PreserveSig] IntPtr GetBufferPointer();
        [PreserveSig] UIntPtr GetBufferSize();
    }

    public static class D3D
    {
        [DllImport("d3dcompiler_47.dll")]
        static extern int D3DDisassemble(byte[] src, UIntPtr size, uint flags, [MarshalAs(UnmanagedType.LPStr)] string comments, out ID3DBlob blob);

        public static string Disassemble(byte[] buf, int start, int size)
        {
            byte[] c = new byte[size];
            Buffer.BlockCopy(buf, start, c, 0, size);
            ID3DBlob blob;
            int hr = D3DDisassemble(c, (UIntPtr)size, 0, null, out blob);
            if (hr != 0) throw new InvalidOperationException("D3DDisassemble hr=0x" + hr.ToString("X8"));
            try
            {
                int n = (int)blob.GetBufferSize().ToUInt64();
                byte[] t = new byte[n];
                Marshal.Copy(blob.GetBufferPointer(), t, 0, n);
                return Encoding.ASCII.GetString(t).Replace("\0", "");
            }
            finally { Marshal.ReleaseComObject(blob); }
        }

        // Disassembly before and after must differ in exactly one line: ", cb1[0].<old>" -> ", cb1[0].<new>"
        public static string CheckOneLineDiff(string before, string after, char oldC, char newC)
        {
            string[] a = before.Split((char)10), b = after.Split((char)10);
            if (a.Length != b.Length) return "line count differs";
            int diffs = 0; string la = null, lb = null;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) { diffs++; la = a[i].Trim(); lb = b[i].Trim(); }
            if (diffs != 1) return "lines differing: " + diffs;
            string oldEnd = "cb1[0]." + oldC, newEnd = "cb1[0]." + newC;
            if (!la.EndsWith(oldEnd) || lb != la.Substring(0, la.Length - oldEnd.Length) + newEnd || !la.StartsWith("add "))
                return "unexpected line: '" + la + "' -> '" + lb + "'";
            return null;
        }
    }

    public class ShaderLoc
    {
        public string Name;
        public int NamePos;
        public int HeaderPos;    // start of platforms[] (12 int32 before the blob bytes)
        public int CompressedLen; // compressedLengths[0][0]
        public int DecompressedLen;
        public int VectorLen;     // length of the compressedBlob vector (unchanged)
        public int BlobPos;
    }

    public static class Assets
    {
        // Finds a shader by name (Unity string: int32 length + bytes) and the blob header that follows it:
        // platforms=[4], offsets=[[0]], compressedLengths=[[C]], decompressedLengths=[[D]], compressedBlob (length L >= C)
        static byte[] UnityString(string s)
        {
            byte[] nb = Encoding.UTF8.GetBytes(s);
            int padded = (nb.Length + 3) & ~3;
            byte[] pat = new byte[4 + padded];
            BitConverter.GetBytes(nb.Length).CopyTo(pat, 0);
            nb.CopyTo(pat, 4);
            return pat;
        }

        // The shader name (m_ParsedForm.m_Name) sits right before m_CustomEditorName in the file; the same name without an editor
        // after it is a Fallback reference from another shader.
        public static ShaderLoc Find(byte[] file, string name, string editor)
        {
            byte[] pat = UnityString(name);
            byte[] ed = UnityString(editor);
            byte[] all = new byte[pat.Length + ed.Length];
            pat.CopyTo(all, 0); ed.CopyTo(all, pat.Length);
            List<int> found = new List<int>();
            for (int i = 0; i + all.Length <= file.Length; i += 4)
            {
                bool ok = true;
                for (int j = 0; j < all.Length; j++) if (file[i + j] != all[j]) { ok = false; break; }
                if (ok) found.Add(i);
            }
            if (found.Count != 1) throw new InvalidDataException("shader '" + name + "' (editor " + editor + ") found " + found.Count + " time(s), expected 1");
            int np = found[0];
            for (int p = np + all.Length; p < np + 65536 && p + 48 <= file.Length; p++)
            {
                if ((p & 3) != 0) continue;
                int[] v = new int[12];
                for (int k = 0; k < 12; k++) v[k] = BitConverter.ToInt32(file, p + 4 * k);
                if (v[0] == 1 && v[1] == 4 && v[2] == 1 && v[3] == 1 && v[4] == 0 && v[5] == 1 && v[6] == 1 &&
                    v[8] == 1 && v[9] == 1 && v[7] > 0 && v[7] <= v[11] && v[10] > v[7] && p + 48 + v[11] <= file.Length)
                {
                    ShaderLoc s = new ShaderLoc();
                    s.Name = name; s.NamePos = np; s.HeaderPos = p;
                    s.CompressedLen = v[7]; s.DecompressedLen = v[10]; s.VectorLen = v[11]; s.BlobPos = p + 48;
                    return s;
                }
            }
            throw new InvalidDataException("blob header not found after name '" + name + "'");
        }
    }
}
