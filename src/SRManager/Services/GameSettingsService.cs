using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace SRManager.Services;

public sealed class GameSettingsService
{
    public string GetGameSettingsPath()
    {
        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new[]
        {
            Path.Combine(documents, "My Games", "FarmingSimulator2025", "gameSettings.xml"),
            Path.Combine(profile, "Documents", "My Games", "FarmingSimulator2025", "gameSettings.xml"),
            Path.Combine(profile, "OneDrive", "Documents", "My Games", "FarmingSimulator2025", "gameSettings.xml")
        };

        var existing = candidates.FirstOrDefault(File.Exists);
        if (existing is not null)
        {
            return existing;
        }

        foreach (var root in new[] { documents, Path.Combine(profile, "Documents"), Path.Combine(profile, "OneDrive", "Documents") })
        {
            var fs25 = Path.Combine(root, "My Games", "FarmingSimulator2025");
            if (Directory.Exists(fs25))
            {
                return Path.Combine(fs25, "gameSettings.xml");
            }
        }

        return candidates[0];
    }

    public GameSettings Read()
    {
        var path = GetGameSettingsPath();
        if (!File.Exists(path))
        {
            return new GameSettings();
        }

        try
        {
            var content = File.ReadAllText(path, Encoding.UTF8);
            return new GameSettings
            {
                IntroScene = ReadBoolean(content, "isIntroActive", true),
                DeveloperConsole = ReadBoolean(content, "developmentControls", false)
            };
        }
        catch
        {
            return new GameSettings();
        }
    }

    public bool WriteSetting(string tag, bool value) => WriteSetting(tag, value ? "true" : "false");

    public bool WriteSetting(string tag, string value)
    {
        var path = GetGameSettingsPath();
        if (!File.Exists(path))
        {
            return false;
        }

        try
        {
            var content = File.ReadAllText(path, Encoding.UTF8);
            var escapedTag = Regex.Escape(tag);
            var textPattern = $@"<{escapedTag}>([^<]*)</{escapedTag}>";
            var attrPattern = $@"<{escapedTag}\s+value=""[^""]*""";

            if (Regex.IsMatch(content, textPattern, RegexOptions.IgnoreCase))
            {
                content = Regex.Replace(content, textPattern, $"<{tag}>{value}</{tag}>", RegexOptions.IgnoreCase);
            }
            else if (Regex.IsMatch(content, attrPattern, RegexOptions.IgnoreCase))
            {
                content = Regex.Replace(content, attrPattern, $"<{tag} value=\"{value}\"", RegexOptions.IgnoreCase);
            }
            else if (content.Contains("</gameSettings>", StringComparison.OrdinalIgnoreCase))
            {
                content = Regex.Replace(content, "</gameSettings>", $"    <{tag}>{value}</{tag}>{Environment.NewLine}</gameSettings>", RegexOptions.IgnoreCase);
            }
            else
            {
                return false;
            }

            File.WriteAllText(path, content, Encoding.UTF8);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public bool UpdateModsDirectoryOverride(string modsPath)
    {
        var path = GetGameSettingsPath();
        if (!File.Exists(path))
        {
            return false;
        }

        try
        {
            var content = File.ReadAllText(path, Encoding.UTF8);
            var escapedDirectory = System.Security.SecurityElement.Escape(modsPath) ?? modsPath;
            if (Regex.IsMatch(content, @"<modsDirectoryOverride\s+active=""[^""]*""\s+directory=""[^""]*""", RegexOptions.IgnoreCase))
            {
                content = Regex.Replace(
                    content,
                    @"<modsDirectoryOverride\s+active=""[^""]*""\s+directory=""[^""]*""",
                    _ => $"<modsDirectoryOverride active=\"true\" directory=\"{escapedDirectory}\"",
                    RegexOptions.IgnoreCase);
            }
            else if (Regex.IsMatch(content, @"<modsDirectoryOverride[^/]*/>", RegexOptions.IgnoreCase))
            {
                content = Regex.Replace(
                    content,
                    @"<modsDirectoryOverride[^/]*/>",
                    _ => $"<modsDirectoryOverride active=\"true\" directory=\"{escapedDirectory}\"/>",
                    RegexOptions.IgnoreCase);
            }
            else if (content.Contains("</gameSettings>", StringComparison.OrdinalIgnoreCase))
            {
                content = Regex.Replace(
                    content,
                    "</gameSettings>",
                    $"    <modsDirectoryOverride active=\"true\" directory=\"{escapedDirectory}\"/>{Environment.NewLine}</gameSettings>",
                    RegexOptions.IgnoreCase);
            }
            else
            {
                return false;
            }

            File.WriteAllText(path, content, Encoding.UTF8);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public string? TryReadPlayerName()
    {
        var path = GetGameSettingsPath();
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            var content = File.ReadAllText(path, Encoding.UTF8);
            var attr = Regex.Match(content, @"<player[^>]*name=""([^""]+)""", RegexOptions.IgnoreCase);
            if (attr.Success)
            {
                return attr.Groups[1].Value;
            }

            var element = Regex.Match(content, @"<player>\s*<name>([^<]+)</name>", RegexOptions.IgnoreCase);
            return element.Success ? element.Groups[1].Value : null;
        }
        catch
        {
            return null;
        }
    }

    public string TryReadGameVersion()
    {
        var path = GetGameSettingsPath();
        if (!File.Exists(path))
        {
            return string.Empty;
        }

        try
        {
            var content = File.ReadAllText(path, Encoding.UTF8);
            var element = Regex.Match(content, @"<version>([^<]+)</version>", RegexOptions.IgnoreCase);
            if (element.Success)
            {
                return element.Groups[1].Value.Trim();
            }

            var attr = Regex.Match(content, @"<version\s+value=""([^""]+)""", RegexOptions.IgnoreCase);
            return attr.Success ? attr.Groups[1].Value.Trim() : string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    public void WriteServerPassword(string password)
    {
        var path = GetGameSettingsPath();
        if (!File.Exists(path) || string.IsNullOrWhiteSpace(password))
        {
            return;
        }

        try
        {
            var content = File.ReadAllText(path, Encoding.UTF8);
            if (!Regex.IsMatch(content, @"serverPassword=""[^""]*""", RegexOptions.IgnoreCase))
            {
                return;
            }

            content = Regex.Replace(
                content,
                @"serverPassword=""[^""]*""",
                _ => $"serverPassword=\"{System.Security.SecurityElement.Escape(password)}\"",
                RegexOptions.IgnoreCase);
            File.WriteAllText(path, content, Encoding.UTF8);
        }
        catch
        {
        }
    }

    public static string ReadExecutableVersion(string exePath, GameSettingsService gameSettingsService)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(exePath);
            var version = !string.IsNullOrWhiteSpace(info.ProductVersion) && info.ProductVersion != "0.0.0.0"
                ? info.ProductVersion
                : info.FileVersion;
            if (!string.IsNullOrWhiteSpace(version) && !version.StartsWith("10.", StringComparison.Ordinal))
            {
                return version.Trim();
            }
        }
        catch
        {
        }

        return gameSettingsService.TryReadGameVersion();
    }

    private static bool ReadBoolean(string content, string tag, bool defaultValue)
    {
        var escapedTag = Regex.Escape(tag);
        var element = Regex.Match(content, $@"<{escapedTag}>([^<]*)</{escapedTag}>", RegexOptions.IgnoreCase);
        if (element.Success)
        {
            return element.Groups[1].Value.Trim().Equals("true", StringComparison.OrdinalIgnoreCase);
        }

        var attr = Regex.Match(content, $@"<{escapedTag}\s+value=""([^""]*)""", RegexOptions.IgnoreCase);
        return attr.Success
            ? attr.Groups[1].Value.Trim().Equals("true", StringComparison.OrdinalIgnoreCase)
            : defaultValue;
    }
}

public sealed class GameSettings
{
    public bool IntroScene { get; set; } = true;
    public bool DeveloperConsole { get; set; }
}
