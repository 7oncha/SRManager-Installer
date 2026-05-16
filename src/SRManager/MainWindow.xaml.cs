using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Windows;
using SRManager.Models;
using SRManager.Services;
using Forms = System.Windows.Forms;
using WpfMessageBox = System.Windows.MessageBox;
using WpfOpenFileDialog = Microsoft.Win32.OpenFileDialog;

namespace SRManager;

public partial class MainWindow : Window
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private readonly ConfigService _configService;
    private readonly GameSettingsService _gameSettingsService;
    private readonly ServerStatusService _serverStatusService;
    private readonly ModService _modService;
    private readonly LicenseService _licenseService;
    private readonly GameLauncherService _gameLauncherService;
    private readonly UpdateService _updateService;
    private readonly ObservableCollection<ModListItem> _modItems = [];

    private LauncherConfig? _config;
    private LatestVersion? _latest;
    private bool _loading;

    public MainWindow()
    {
        InitializeComponent();

        _configService = new ConfigService(_http);
        _gameSettingsService = new GameSettingsService();
        _serverStatusService = new ServerStatusService(_http);
        _modService = new ModService(_http, _configService);
        _licenseService = new LicenseService(_http, _configService, _gameSettingsService);
        _gameLauncherService = new GameLauncherService(_gameSettingsService, _serverStatusService, _modService, _licenseService);
        _updateService = new UpdateService(_http, _configService);
        dgMods.ItemsSource = _modItems;

        Loaded += MainWindowLoaded;
    }

    private async void MainWindowLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _loading = true;
            Log("Ucitavam C# launcher...");
            _config = await _configService.LoadAsync();
            await _configService.SyncSharedConfigAsync(_config);
            DetectMissingPaths();
            ApplyConfigToUi();
            _loading = false;

            var license = await _licenseService.EnsureValidAsync(_config);
            if (!license.Ok)
            {
                var licenseWindow = new LicenseWindow(_config, _licenseService, license.Reason) { Owner = this };
                if (licenseWindow.ShowDialog() != true)
                {
                    WpfMessageBox.Show(this, "Licenca nije aktivirana. Launcher se gasi.", "SR Manager", MessageBoxButton.OK, MessageBoxImage.Warning);
                    Close();
                    return;
                }
            }

            await RefreshStatusAsync();
            await RefreshModsAsync();
            await CheckUpdateAsync();
            _config.LastLaunchAt = DateTimeOffset.UtcNow.ToString("O");
            await _configService.SaveAsync(_config);
            Log("Launcher spreman.");
        }
        catch (Exception ex)
        {
            _loading = false;
            Log($"GRESKA init: {ex.Message}");
            WpfMessageBox.Show(this, ex.Message, "SR Manager", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void ServerSelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_loading || _config is null || cmbServer.SelectedIndex < 0)
        {
            return;
        }

        _config.ActiveServer = cmbServer.SelectedIndex;
        await _configService.SaveAsync(_config);
        await RefreshStatusAsync();
        await RefreshModsAsync();
    }

    private async void RefreshStatusClick(object sender, RoutedEventArgs e) => await RefreshStatusAsync();
    private async void RefreshModsClick(object sender, RoutedEventArgs e) => await RefreshModsAsync();
    private async void DownloadModsClick(object sender, RoutedEventArgs e) => await DownloadModsAsync();
    private async void JoinClick(object sender, RoutedEventArgs e) => await JoinAsync();
    private async void UpdateClick(object sender, RoutedEventArgs e) => await InstallUpdateAsync();

    private void OpenWebClick(object sender, RoutedEventArgs e) => OpenUrl(_configService.WebUrl);
    private void OpenDiscordClick(object sender, RoutedEventArgs e) => OpenUrl(_configService.DiscordUrl);
    private void ClearLogClick(object sender, RoutedEventArgs e) => txtLog.Clear();

    private void BrowseGameClick(object sender, RoutedEventArgs e)
    {
        var dialog = new WpfOpenFileDialog
        {
            Filter = "FarmingSimulator2025.exe|FarmingSimulator2025.exe|EXE files|*.exe",
            Title = "Odaberi FarmingSimulator2025.exe"
        };
        if (dialog.ShowDialog(this) == true)
        {
            txtGamePath.Text = dialog.FileName;
        }
    }

    private void BrowseModsClick(object sender, RoutedEventArgs e)
    {
        using var dialog = new Forms.FolderBrowserDialog
        {
            Description = "Odaberi FS25 mods folder",
            UseDescriptionForTitle = true
        };
        if (dialog.ShowDialog() == Forms.DialogResult.OK)
        {
            txtModsPath.Text = dialog.SelectedPath;
        }
    }

    private async void SaveSettingsClick(object sender, RoutedEventArgs e)
    {
        if (_config is null)
        {
            return;
        }

        _config.GamePath = txtGamePath.Text.Trim();
        _config.ModsPath = txtModsPath.Text.Trim();
        _config.IntroScene = chkIntro.IsChecked == true;
        _config.DeveloperConsole = chkDev.IsChecked == true;
        _gameSettingsService.WriteSetting("isIntroActive", _config.IntroScene);
        _gameSettingsService.WriteSetting("developmentControls", _config.DeveloperConsole);
        if (!string.IsNullOrWhiteSpace(_config.ModsPath))
        {
            _gameSettingsService.UpdateModsDirectoryOverride(_config.ModsPath);
        }

        await _configService.SaveAsync(_config);
        Log("Postavke spremljene.");
    }

    private async void DetectPathsClick(object sender, RoutedEventArgs e)
    {
        if (_config is null)
        {
            return;
        }

        DetectMissingPaths(force: true);
        ApplyConfigToUi();
        await _configService.SaveAsync(_config);
        Log("Auto-detekcija putanja zavrsena.");
    }

    private void OpenModsFolderClick(object sender, RoutedEventArgs e)
    {
        if (_config is null || string.IsNullOrWhiteSpace(_config.ModsPath))
        {
            WpfMessageBox.Show(this, "Mods folder nije postavljen.", "SR Manager", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        Directory.CreateDirectory(_config.ModsPath);
        Process.Start(new ProcessStartInfo { FileName = _config.ModsPath, UseShellExecute = true });
    }

    private async Task RefreshStatusAsync()
    {
        if (_config is null)
        {
            return;
        }

        var server = _configService.GetActiveServer(_config);
        txtStatusBar.Text = "Osvjezavam status...";
        var status = await _serverStatusService.GetStatusAsync(server);
        txtStatus.Text = status.Online ? "ONLINE" : "OFFLINE";
        txtMap.Text = status.Online ? status.Map : "-";
        txtPlayers.Text = status.Online ? $"{status.PlayersOnline}/{status.PlayersMax}" : "-/-";
        lstPlayers.ItemsSource = status.Players.Select(p => p.IsAdmin ? $"{p.Name} (admin) - {p.UptimeText}" : $"{p.Name} - {p.UptimeText}");
        txtStatusBar.Text = status.Online ? $"{status.Name} online" : $"{server.Name} offline";
        Log(status.Online
            ? $"Server ONLINE: {status.Name} ({status.PlayersOnline}/{status.PlayersMax})"
            : $"Server OFFLINE: {server.Name}");
    }

    private async Task RefreshModsAsync()
    {
        if (_config is null)
        {
            return;
        }

        var server = _configService.GetActiveServer(_config);
        txtStatusBar.Text = "Provjeravam modove...";
        txtProgress.Text = "Dohvacam listu modova...";
        _modItems.Clear();
        var items = await _modService.CompareAsync(_config, server);
        foreach (var item in items)
        {
            _modItems.Add(item);
        }

        var missing = _modItems.Count(i => i.Status is "FALI" or "ZASTARIO");
        txtModSummary.Text = $"{_modItems.Count} / fali {missing}";
        txtFooterHint.Text = _config.LastSync;
        txtProgress.Text = missing == 0 ? "Svi modovi su OK." : $"Fali ili je zastarjelo {missing} mod(ova).";
        txtStatusBar.Text = "Modovi provjereni";
        await _configService.SaveAsync(_config);
        Log($"Pregled modova: ukupno={_modItems.Count}, fali/zastarjelo={missing}");
    }

    private async Task DownloadModsAsync()
    {
        if (_config is null)
        {
            return;
        }

        try
        {
            var server = _configService.GetActiveServer(_config);
            var downloaded = await _modService.DownloadMissingAsync(_config, server, _modItems, SetProgress);
            Log($"Download modova zavrsen: {downloaded} skinuto.");
            await RefreshModsAsync();
        }
        catch (Exception ex)
        {
            WpfMessageBox.Show(this, ex.Message, "SR Manager", MessageBoxButton.OK, MessageBoxImage.Warning);
            Log($"GRESKA download modova: {ex.Message}");
        }
    }

    private async Task JoinAsync()
    {
        if (_config is null)
        {
            return;
        }

        try
        {
            if (_modItems.Count == 0)
            {
                await RefreshModsAsync();
            }

            var server = _configService.GetActiveServer(_config);
            var result = await _gameLauncherService.LaunchAsync(_config, server, _modItems, ConfirmAsync, SetProgress);
            if (!result.Ok)
            {
                Log(result.Message);
                txtProgress.Text = result.Message;
                return;
            }

            Log("Igra pokrenuta.");
            txtProgress.Text = "Igra pokrenuta. Launcher se zatvara za 5 sekundi.";
            await Task.Delay(TimeSpan.FromSeconds(5));
            Close();
        }
        catch (Exception ex)
        {
            Log($"GRESKA launch: {ex.Message}");
            WpfMessageBox.Show(this, ex.Message, "SR Manager", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async Task CheckUpdateAsync()
    {
        if (_config is null)
        {
            return;
        }

        _latest = await _updateService.CheckAsync(_config);
        if (_latest is not null)
        {
            btnUpdate.Visibility = Visibility.Visible;
            Log($"Dostupna nova verzija: v{_latest.Version}");
        }
    }

    private async Task InstallUpdateAsync()
    {
        if (_latest is null)
        {
            return;
        }

        var confirm = WpfMessageBox.Show(this, $"Dostupna je nova verzija v{_latest.Version}.\nSkinuti i instalirati sada?", "Update", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (confirm != MessageBoxResult.Yes)
        {
            return;
        }

        await _updateService.InstallAsync(_latest, SetProgress);
        Close();
    }

    private Task<bool> ConfirmAsync(string message)
    {
        var result = WpfMessageBox.Show(this, message, "SR Manager", MessageBoxButton.YesNo, MessageBoxImage.Question);
        return Task.FromResult(result == MessageBoxResult.Yes);
    }

    private void DetectMissingPaths(bool force = false)
    {
        if (_config is null)
        {
            return;
        }

        if (force || string.IsNullOrWhiteSpace(_config.GamePath))
        {
            var detected = _gameLauncherService.FindGamePath();
            if (!string.IsNullOrWhiteSpace(detected))
            {
                _config.GamePath = detected;
            }
        }

        if (force || string.IsNullOrWhiteSpace(_config.ModsPath))
        {
            var detected = _gameLauncherService.FindModsPath();
            if (!string.IsNullOrWhiteSpace(detected))
            {
                _config.ModsPath = detected;
            }
        }
    }

    private void ApplyConfigToUi()
    {
        if (_config is null)
        {
            return;
        }

        cmbServer.ItemsSource = null;
        cmbServer.ItemsSource = _config.Servers;
        cmbServer.SelectedIndex = _config.ActiveServer;
        txtGamePath.Text = _config.GamePath;
        txtModsPath.Text = _config.ModsPath;
        var settings = _gameSettingsService.Read();
        chkIntro.IsChecked = settings.IntroScene;
        chkDev.IsChecked = settings.DeveloperConsole;
    }

    private void SetProgress(string message)
    {
        Dispatcher.Invoke(() =>
        {
            txtProgress.Text = message;
            txtStatusBar.Text = message;
        });
    }

    private void Log(string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}";
        txtLog.AppendText(line);
        txtLog.ScrollToEnd();
    }

    private static void OpenUrl(string url)
    {
        if (!string.IsNullOrWhiteSpace(url))
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
        }
    }
}
