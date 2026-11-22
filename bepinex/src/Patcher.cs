// BepInEx 5 preloader patcher. Runs at every game start before Unity loads globalgamemanagers.assets and puts the hair
// fix into that file (or the original back, with Enabled = false). Patches no assemblies: TargetDLLs is empty.
using System;
using System.Collections.Generic;
using System.IO;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using Mono.Cecil;

namespace Pathologic2HairDitherFix
{
    public static class Patcher
    {
        static readonly string Version = typeof(Patcher).Assembly.GetName().Version.ToString(3);

        public static IEnumerable<string> TargetDLLs
        {
            get { return new string[0]; }
        }

        public static void Patch(AssemblyDefinition assembly) { }

        public static void Initialize()
        {
            ManualLogSource log = Logger.CreateLogSource("HairDitherFix");
            try
            {
                ConfigFile cfg = new ConfigFile(Path.Combine(Paths.ConfigPath, "pathologic2.hairdither.cfg"), true);
                ConfigEntry<bool> enabled = cfg.Bind("General", "Enabled", true,
                    "true: the hair fix is put into Pathologic_Data\\globalgamemanagers.assets at game start (again after a game update).\n" +
                    "false: the original file is written back at the next game start. Do this before removing the mod.");
                string file = Path.Combine(Path.GetDirectoryName(Paths.ManagedPath), "globalgamemanagers.assets");
                string state = Core.Run(file, enabled.Value, s => log.LogInfo(s), s => log.LogWarning(s));
                log.LogMessage("Pathologic 2 Hair Dither Fix " + Version + ": Enabled=" + enabled.Value + ", state " + state);
            }
            catch (Exception e)
            {
                log.LogError("Pathologic 2 Hair Dither Fix " + Version + " failed, nothing changed: " + e);
            }
            finally
            {
                Logger.Sources.Remove(log);
            }
        }
    }
}
