using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Rust Server Control Center")]
[assembly: AssemblyDescription("Installateur et lanceur autonome de Rust Server Control Center")]
[assembly: AssemblyCompany("Rust Server Control Center")]
[assembly: AssemblyProduct("Rust Server Control Center")]
[assembly: AssemblyCopyright("Projet communautaire")]
[assembly: AssemblyVersion("__ASSEMBLY_VERSION__")]
[assembly: AssemblyFileVersion("__ASSEMBLY_VERSION__")]

namespace RustServerControlCenter
{
    internal static class Program
    {
        private const string ProductVersion = "__PRODUCT_VERSION__";
        private const string PortableResourceName = "RustServerControlCenter.Portable.zip";
        private const string PortableSha256 = "__ZIP_SHA256__";
        private const bool InstallerMode = __INSTALLER_MODE__;

        [STAThread]
        private static int Main(string[] args)
        {
            bool verifyOnly = false;
            bool noLaunch = false;
            string requestedInstallRoot = null;

            try
            {
                for (int index = 0; index < args.Length; index++)
                {
                    string argument = args[index] ?? string.Empty;
                    if (string.Equals(argument, "--verify", StringComparison.OrdinalIgnoreCase))
                    {
                        verifyOnly = true;
                    }
                    else if (string.Equals(argument, "--no-launch", StringComparison.OrdinalIgnoreCase))
                    {
                        noLaunch = true;
                    }
                    else if (string.Equals(argument, "--install-root", StringComparison.OrdinalIgnoreCase))
                    {
                        if (index + 1 >= args.Length) throw new InvalidOperationException("--install-root attend un chemin.");
                        requestedInstallRoot = args[++index];
                    }
                    else
                    {
                        throw new InvalidOperationException("Argument inconnu : " + argument);
                    }
                }

                byte[] portableBytes = ReadAndVerifyPortablePackage();
                if (verifyOnly) return 0;

                string installRoot = ResolveInstallRoot(requestedInstallRoot);
                if (InstallerMode || !IsCurrentInstallationReady(installRoot))
                {
                    InstallPortablePackage(portableBytes, installRoot);
                }

                if (!noLaunch)
                {
                    LaunchControlCenter(installRoot);
                }
                return 0;
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    "Rust Server Control Center n'a pas pu démarrer.\r\n\r\n" + exception.Message,
                    "Rust Server Control Center",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
        }

        private static byte[] ReadAndVerifyPortablePackage()
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream resource = assembly.GetManifestResourceStream(PortableResourceName))
            {
                if (resource == null) throw new InvalidOperationException("Le package portable intégré est absent.");
                using (MemoryStream memory = new MemoryStream())
                {
                    resource.CopyTo(memory);
                    byte[] bytes = memory.ToArray();
                    string actualHash;
                    using (SHA256 sha = SHA256.Create())
                    {
                        actualHash = ToHex(sha.ComputeHash(bytes));
                    }
                    if (!string.Equals(actualHash, PortableSha256, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException("L'intégrité SHA-256 du package intégré est invalide.");
                    }
                    ValidateZipEntries(bytes);
                    return bytes;
                }
            }
        }

        private static string ToHex(byte[] bytes)
        {
            StringBuilder builder = new StringBuilder(bytes.Length * 2);
            for (int index = 0; index < bytes.Length; index++) builder.Append(bytes[index].ToString("x2"));
            return builder.ToString();
        }

        private static void ValidateZipEntries(byte[] bytes)
        {
            string probeRoot = Path.Combine(Path.GetTempPath(), "RustServerControlCenter-ZipProbe");
            string safePrefix = Path.GetFullPath(probeRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            using (MemoryStream memory = new MemoryStream(bytes, false))
            using (ZipArchive archive = new ZipArchive(memory, ZipArchiveMode.Read, false))
            {
                if (archive.Entries.Count == 0) throw new InvalidDataException("Le package intégré est vide.");
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                    string target = Path.GetFullPath(Path.Combine(probeRoot, relative));
                    if (!target.StartsWith(safePrefix, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException("Chemin ZIP refusé : " + entry.FullName);
                    }
                }
            }
        }

        private static string ResolveInstallRoot(string requestedInstallRoot)
        {
            if (!string.IsNullOrWhiteSpace(requestedInstallRoot)) return Path.GetFullPath(requestedInstallRoot);

            string userProfileInstall = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "RustRPGServer");
            if (File.Exists(Path.Combine(userProfileInstall, "LANCER-CONTROL-CENTER.vbs"))) return userProfileInstall;

            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "RustServerControlCenter");
        }

        private static bool IsCurrentInstallationReady(string installRoot)
        {
            string versionPath = Path.Combine(installRoot, "VERSION");
            if (!File.Exists(versionPath)) return false;
            string installedVersion = File.ReadAllText(versionPath).Trim();
            if (!string.Equals(installedVersion, ProductVersion, StringComparison.OrdinalIgnoreCase)) return false;
            return File.Exists(Path.Combine(installRoot, "LANCER-CONTROL-CENTER.vbs"))
                && File.Exists(Path.Combine(installRoot, "release-manifest.json"))
                && File.Exists(Path.Combine(installRoot, "tool", "RustRPG-Manager.ps1"))
                && File.Exists(Path.Combine(installRoot, "tool", "RustRPG-Manager.xaml"));
        }

        private static void InstallPortablePackage(byte[] portableBytes, string installRoot)
        {
            string stagingRoot = Path.Combine(
                Path.GetTempPath(),
                "RustServerControlCenter-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(stagingRoot);
            try
            {
                ExtractPortablePackage(portableBytes, stagingRoot);
                string installer = Path.Combine(stagingRoot, "Install-ControlCenter.ps1");
                if (!File.Exists(installer)) throw new FileNotFoundException("Le script d'installation intégré est absent.", installer);

                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe");
                if (!File.Exists(powershell)) throw new FileNotFoundException("Windows PowerShell 5.1 est introuvable.", powershell);

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = powershell;
                startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "
                    + Quote(installer) + " -InstallRoot " + Quote(installRoot)
                    + (InstallerMode ? " -NoLaunch" : " -NoShortcuts -NoLaunch");
                startInfo.WorkingDirectory = stagingRoot;
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                startInfo.WindowStyle = ProcessWindowStyle.Hidden;
                startInfo.RedirectStandardOutput = true;
                startInfo.RedirectStandardError = true;

                using (Process process = Process.Start(startInfo))
                {
                    string standardOutput = process.StandardOutput.ReadToEnd();
                    string standardError = process.StandardError.ReadToEnd();
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        string detail = string.IsNullOrWhiteSpace(standardError) ? standardOutput : standardError;
                        if (detail.Length > 1800) detail = detail.Substring(detail.Length - 1800);
                        throw new InvalidOperationException("L'installation silencieuse a échoué.\r\n" + detail.Trim());
                    }
                }
            }
            finally
            {
                try { if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, true); }
                catch { }
            }
        }

        private static void ExtractPortablePackage(byte[] portableBytes, string stagingRoot)
        {
            string safePrefix = Path.GetFullPath(stagingRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            using (MemoryStream memory = new MemoryStream(portableBytes, false))
            using (ZipArchive archive = new ZipArchive(memory, ZipArchiveMode.Read, false))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                    string target = Path.GetFullPath(Path.Combine(stagingRoot, relative));
                    if (!target.StartsWith(safePrefix, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException("Chemin ZIP refusé : " + entry.FullName);
                    }
                    if (string.IsNullOrEmpty(entry.Name))
                    {
                        Directory.CreateDirectory(target);
                        continue;
                    }
                    string parent = Path.GetDirectoryName(target);
                    if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
                    using (Stream input = entry.Open())
                    using (FileStream output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        input.CopyTo(output);
                    }
                }
            }
        }

        private static void LaunchControlCenter(string installRoot)
        {
            string launcher = Path.Combine(installRoot, "LANCER-CONTROL-CENTER.vbs");
            if (!File.Exists(launcher)) throw new FileNotFoundException("Le lanceur installé est absent.", launcher);
            string wscript = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wscript.exe");
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = wscript;
            startInfo.Arguments = Quote(launcher);
            startInfo.WorkingDirectory = installRoot;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(startInfo);
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}
