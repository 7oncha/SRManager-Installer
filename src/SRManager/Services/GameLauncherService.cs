using System.Diagnostics;
using System.IO;
using Microsoft.Win32;
using SRManager.Models;

namespace SRManager.Services;

public sealed class GameLauncherService
{
    private readonly GameSettingsService _gameSettingsService;
    private readonly ServerStatusService _serverStatusService;
    private readonly ModService _modService;
    private readonly LicenseService _licenseService;

    public GameLauncherService(
        GameSettingsService gameSettingsService,
        ServerStatusService serverStatusService,
        ModService modService,
        LicenseService licenseService)
    {
        _gameSettingsService = gameSettingsService;
        _serverStatusService = serverStatusService;
        _modService = modService;
        _licenseService = licenseService;
    }

    public string FindGamePath()
    {
        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var candidates = new[]
        {
            Path.Combine(programFilesX86, "Farming Simulator 2025", "FarmingSimulator2025.exe"),
            Path.Combine(programFiles, "Farming Simulator 2025", "FarmingSimulator2025.exe"),
            @"D:\Farming Simulator 2025\FarmingSimulator2025.exe",
            @"D:\Games\Farming Simulator 2025\FarmingSimulator2025.exe",
            @"E:\Farming Simulator 2025\FarmingSimulator2025.exe",
            Path.Combine(programFilesX86, "Steam", "steamapps", "common", "Farming Simulator 25", "FarmingSimulator2025.exe"),
            Path.Combine(programFiles, "Steam", "steamapps", "common", "Farming Simulator 25", "FarmingSimulator2025.exe"),
            @"D:\SteamLibrary\steamapps\common\Farming Simulator 25\FarmingSimulator2025.exe"
        };

        var path = candidates.FirstOrDefault(File.Exists);
        if (path is not null)
        {
            return path;
        }

        try
        {
            using var uninstall = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall");
            if (uninstall is null)
            {
                return string.Empty;
            }

            foreach (var name in uninstall.GetSubKeyNames())
            {
                using var key = uninstall.OpenSubKey(name);
                var displayName = key?.GetValue("DisplayName")?.ToString() ?? string.Empty;
                if (!displayName.Contains("Farming Simulator 2025", StringComparison.OrdinalIgnoreCase) &&
                    !displayName.Contains("Farming Simulator 25", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var installLocation = key?.GetValue("InstallLocation")?.ToString();
                if (string.IsNullOrWhiteSpace(installLocation))
                {
                    continue;
                }

                var exe = Path.Combine(installLocation, "FarmingSimulator2025.exe");
                if (File.Exists(exe))
                {
                    return exe;
                }
            }
        }
        catch
        {
        }

        return string.Empty;
    }

    public string FindModsPath()
    {
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            "My Games",
            "FarmingSimulator2025",
            "mods");
        if (Directory.Exists(path))
        {
            return path;
        }

        var parent = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(parent) && Directory.Exists(parent))
        {
            Directory.CreateDirectory(path);
            return path;
        }

        return string.Empty;
    }

    public async Task<LaunchResult> LaunchAsync(
        LauncherConfig config,
        ServerConfig server,
        IReadOnlyCollection<ModListItem> modItems,
        Func<string, Task<bool>> confirmAsync,
        Action<string>? progress,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(config.GamePath) || !File.Exists(config.GamePath))
        {
            return LaunchResult.Fail("FS25 exe nije pronaden. Postavi putanju u Postavkama.");
        }

        _gameSettingsService.WriteServerPassword(server.Password);
        if (!string.IsNullOrWhiteSpace(config.ModsPath))
        {
            _gameSettingsService.UpdateModsDirectoryOverride(config.ModsPath);
        }

        var status = await _serverStatusService.GetStatusAsync(server, cancellationToken);
        if (status.Online && !string.IsNullOrWhiteSpace(status.GameVersion))
        {
            var localVersion = GameSettingsService.ReadExecutableVersion(config.GamePath, _gameSettingsService);
            if (!string.IsNullOrWhiteSpace(localVersion) && !localVersion.Equals(status.GameVersion, StringComparison.OrdinalIgnoreCase))
            {
                var proceed = await confirmAsync($"Verzija igre se ne podudara.\n\nServer: {status.GameVersion}\nTvoja:  {localVersion}\n\nPokrenuti svejedno?");
                if (!proceed)
                {
                    return LaunchResult.Fail("Pokretanje otkazano zbog verzije igre.");
                }
            }
        }

        var missing = modItems.Count(i => i.Status is "FALI" or "ZASTARIO");
        if (missing > 0)
        {
            var download = await confirmAsync($"Fali ti / zastarjelo je {missing} mod(ova).\n\nSkinuti sve i pokrenuti igru?");
            if (!download)
            {
                return LaunchResult.Fail("Pokretanje otkazano jer fale modovi.");
            }

            progress?.Invoke("Skidam modove...");
            await _modService.DownloadMissingAsync(config, server, modItems, progress, cancellationToken);
        }

        var args = new List<string>();
        var settings = _gameSettingsService.Read();
        if (!settings.IntroScene && !IsGiantsLauncherInstall(config.GamePath))
        {
            args.Add("-skipStartVideos");
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = config.GamePath,
            Arguments = string.Join(" ", args),
            UseShellExecute = true
        });

        try
        {
            await _licenseService.SendHeartbeatAsync(config, cancellationToken);
            _licenseService.StartDetachedSessionWatcher(config);
        }
        catch
        {
        }

        return LaunchResult.Success();
    }

    private static bool IsGiantsLauncherInstall(string exePath)
    {
        try
        {
            var parent = Path.GetDirectoryName(exePath);
            if (string.IsNullOrWhiteSpace(parent))
            {
                return false;
            }

            if (File.Exists(Path.Combine(parent, "steam_api64.dll")))
            {
                return false;
            }

            return File.Exists(Path.Combine(parent, "GiantsLauncher.exe")) ||
                   File.Exists(Path.Combine(Directory.GetParent(parent)?.FullName ?? parent, "GiantsLauncher.exe"));
        }
        catch
        {
            return false;
        }
    }
}

public sealed class LaunchResult
{
    public bool Ok { get; private init; }
    public string Message { get; private init; } = string.Empty;

    public static LaunchResult Success() => new() { Ok = true };
    public static LaunchResult Fail(string message) => new() { Ok = false, Message = message };
}
