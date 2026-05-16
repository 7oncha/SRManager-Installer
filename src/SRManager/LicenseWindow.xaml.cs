using System.Windows;
using SRManager.Models;
using SRManager.Services;

namespace SRManager;

public partial class LicenseWindow : Window
{
    private readonly LauncherConfig _config;
    private readonly LicenseService _licenseService;

    public LicenseWindow(LauncherConfig config, LicenseService licenseService, string? error)
    {
        InitializeComponent();
        _config = config;
        _licenseService = licenseService;
        txtError.Text = error ?? string.Empty;
    }

    private async void ActivateClick(object sender, RoutedEventArgs e)
    {
        var key = txtKey.Password.Trim();
        if (string.IsNullOrWhiteSpace(key))
        {
            txtError.Text = "Unesi licencni kljuc.";
            return;
        }

        await ActivateKeyAsync(key);
    }

    private async void TrialClick(object sender, RoutedEventArgs e)
    {
        txtInfo.Text = "Trazim trial licencu...";
        var trial = await _licenseService.RequestTrialAsync(_config);
        if (!trial.Ok)
        {
            txtError.Text = trial.Reason;
            txtInfo.Text = string.Empty;
            return;
        }

        if (string.IsNullOrWhiteSpace(trial.Key))
        {
            txtInfo.Text = "Trial je odobren. Provjeri Discord/admin panel za kljuc.";
            return;
        }

        txtKey.Password = trial.Key;
        await ActivateKeyAsync(trial.Key);
    }

    private void CancelClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private async Task ActivateKeyAsync(string key)
    {
        txtError.Text = string.Empty;
        txtInfo.Text = "Aktiviram licencu...";
        var result = await _licenseService.ActivateAsync(_config, key);
        if (result.Ok)
        {
            DialogResult = true;
            Close();
            return;
        }

        txtInfo.Text = string.Empty;
        txtError.Text = result.Reason;
    }
}
