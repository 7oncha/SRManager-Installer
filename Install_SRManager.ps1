# ============================================================
#  SR Manager - GUI Installer v2
#  Skida pojedinacne fajlove (bez ZIP-a) - AV friendly
# ============================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:InstallDir = Join-Path $env:USERPROFILE "SR Manager"
$script:BotUrl     = "https://server-bot-production-a3a0.up.railway.app"
$script:BaseUrl    = "https://raw.githubusercontent.com/7oncha/SRManager-Installer/master"
$script:Files = @(
    @{ name = "SlavonskaRavnica.ps1"; url = "$($script:BotUrl)/launcher/script"; fallback = "$($script:BaseUrl)/SlavonskaRavnica.ps1" },
    @{ name = "sr_shared_config.json"; url = "$($script:BotUrl)/launcher/config"; fallback = "$($script:BaseUrl)/sr_shared_config.json" },
    @{ name = "Pokreni SR Manager.bat"; url = "$($script:BaseUrl)/package/Pokreni%20SR%20Manager.bat" },
    @{ name = "SR Manager.vbs";      url = "$($script:BaseUrl)/SR%20Manager.vbs" },
    @{ name = "sr_logo.ico";         url = "$($script:BaseUrl)/sr_logo.ico" },
    @{ name = "sr_logo.png";         url = "$($script:BaseUrl)/sr_logo.png" }
)

function New-SRManagerDesktopShortcut {
    param([string]$InstallDir)
    $ws = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcut = $ws.CreateShortcut((Join-Path $desktop 'SR Manager.lnk'))
    $bat = Join-Path $InstallDir 'Pokreni SR Manager.bat'
    if (-not (Test-Path $bat)) { $bat = Join-Path $InstallDir 'SR Manager.bat' }
    if (-not (Test-Path $bat)) {
        $bat = Join-Path $InstallDir 'SR Manager.vbs'
    }
    $shortcut.TargetPath = $bat
    $shortcut.Arguments = ''
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.Description = 'Slavonska Ravnica - SR Manager'
    $logo = Join-Path $InstallDir 'sr_logo.ico'
    if (Test-Path $logo) { $shortcut.IconLocation = "$logo,0" }
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SR Manager - Instalacija" Width="500" Height="380"
        WindowStartupLocation="CenterScreen" Background="#0d0d0d"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize">
    <Border CornerRadius="12" BorderBrush="#333" BorderThickness="1" Background="#0d0d0d">
        <Grid Margin="30">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Title bar -->
            <DockPanel Grid.Row="0" Margin="0,0,0,20">
                <Button x:Name="btnClose" DockPanel.Dock="Right" Content="&#xE711;" FontFamily="Segoe MDL2 Assets"
                        FontSize="14" Background="Transparent" Foreground="#888" BorderThickness="0"
                        Cursor="Hand" Padding="6,4" VerticalAlignment="Top"/>
                <TextBlock Text="SR MANAGER" Foreground="#F5C518" FontSize="22" FontWeight="Bold"
                           FontFamily="Segoe UI" VerticalAlignment="Center"/>
            </DockPanel>

            <!-- Description -->
            <TextBlock x:Name="txtDesc" Grid.Row="1" Text="Instalacija SR Manager aplikacije za Slavonska Ravnica zajednicu."
                       Foreground="#aaa" FontSize="13" FontFamily="Segoe UI" TextWrapping="Wrap" Margin="0,0,0,16"/>

            <!-- Install path -->
            <StackPanel x:Name="panelPath" Grid.Row="2" Margin="0,0,0,16">
                <TextBlock Text="Folder:" Foreground="#888" FontSize="11" FontFamily="Segoe UI" Margin="0,0,0,4"/>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Background="#1a1a1a" CornerRadius="6" Padding="12,8">
                        <TextBlock x:Name="txtPath" Foreground="#ccc" FontSize="12" FontFamily="Segoe UI Semibold" TextTrimming="CharacterEllipsis"/>
                    </Border>
                    <Button x:Name="btnBrowse" Grid.Column="1" Content="..." Margin="6,0,0,0" Padding="14,6" Cursor="Hand"
                            FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="13"
                            Background="#1a1a1a" Foreground="#F5C518" BorderThickness="1" BorderBrush="#333"
                            ToolTip="Promijeni folder">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="bbd" Background="{TemplateBinding Background}"
                                        BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                                        CornerRadius="6" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="bbd" Property="Background" Value="#2a2a2a"/>
                                        <Setter TargetName="bbd" Property="BorderBrush" Value="#F5C518"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </Grid>
            </StackPanel>

            <!-- Progress area -->
            <StackPanel x:Name="panelProgress" Grid.Row="3" VerticalAlignment="Center" Visibility="Collapsed">
                <TextBlock x:Name="txtStep" Text="" Foreground="#ccc" FontSize="13" FontFamily="Segoe UI"
                           HorizontalAlignment="Center" Margin="0,0,0,12"/>
                <Border Background="#1a1a1a" CornerRadius="4" Height="8" Margin="0,0,0,8">
                    <Border x:Name="progressBar" Background="#F5C518" CornerRadius="4" Height="8"
                            HorizontalAlignment="Left" Width="0"/>
                </Border>
                <TextBlock x:Name="txtPercent" Text="0%" Foreground="#888" FontSize="11" FontFamily="Segoe UI"
                           HorizontalAlignment="Center"/>
            </StackPanel>

            <!-- Success message -->
            <StackPanel x:Name="panelDone" Grid.Row="3" VerticalAlignment="Center" Visibility="Collapsed"
                        HorizontalAlignment="Center">
                <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="40" Foreground="#30A46C"
                           HorizontalAlignment="Center" Margin="0,0,0,10"/>
                <TextBlock Text="Instalacija zavrsena!" Foreground="#30A46C" FontSize="16" FontWeight="SemiBold"
                           FontFamily="Segoe UI" HorizontalAlignment="Center"/>
                <TextBlock Text="Pokreni SR Manager sa Desktopa." Foreground="#888" FontSize="12"
                           FontFamily="Segoe UI" HorizontalAlignment="Center" Margin="0,6,0,0"/>
            </StackPanel>

            <!-- Error message -->
            <StackPanel x:Name="panelError" Grid.Row="3" VerticalAlignment="Center" Visibility="Collapsed">
                <TextBlock Text="&#xE783;" FontFamily="Segoe MDL2 Assets" FontSize="36" Foreground="#E5484D"
                           HorizontalAlignment="Center" Margin="0,0,0,8"/>
                <TextBlock x:Name="txtError" Text="" Foreground="#E5484D" FontSize="12" FontFamily="Segoe UI"
                           TextWrapping="Wrap" HorizontalAlignment="Center" TextAlignment="Center"/>
            </StackPanel>

            <!-- Buttons -->
            <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,16,0,0">
                <Button x:Name="btnInstall" Content="Instaliraj" Padding="30,10" Cursor="Hand"
                        FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="14"
                        Background="#F5C518" Foreground="#111" BorderThickness="0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="bd" Background="{TemplateBinding Background}"
                                    CornerRadius="8" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="bd" Property="Background" Value="#FFD84D"/>
                                </Trigger>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="bd" Property="Background" Value="#555"/>
                                    <Setter Property="Foreground" Value="#999"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="btnCancel" Content="Odustani" Padding="20,10" Cursor="Hand" Margin="12,0,0,0"
                        FontFamily="Segoe UI" FontSize="13" Background="Transparent" Foreground="#888"
                        BorderBrush="#555" BorderThickness="1">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="bd" Background="Transparent" CornerRadius="8"
                                    Padding="{TemplateBinding Padding}" BorderBrush="#555" BorderThickness="1">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="bd" Property="BorderBrush" Value="#888"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Find controls
$btnClose     = $window.FindName('btnClose')
$btnInstall   = $window.FindName('btnInstall')
$btnCancel    = $window.FindName('btnCancel')
$btnBrowse    = $window.FindName('btnBrowse')
$txtPath      = $window.FindName('txtPath')
$txtDesc      = $window.FindName('txtDesc')
$panelPath    = $window.FindName('panelPath')
$panelProgress = $window.FindName('panelProgress')
$panelDone    = $window.FindName('panelDone')
$panelError   = $window.FindName('panelError')
$txtStep      = $window.FindName('txtStep')
$txtPercent   = $window.FindName('txtPercent')
$progressBar  = $window.FindName('progressBar')
$txtError     = $window.FindName('txtError')

$txtPath.Text = $script:InstallDir
$script:InstallDone = $false

# Drag window
$window.Add_MouseLeftButtonDown({ $window.DragMove() })

$btnClose.Add_Click({ $window.Close() })
$btnCancel.Add_Click({ $window.Close() })

$btnBrowse.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Odaberi folder za instalaciju SR Manager-a"
    $dlg.ShowNewFolderButton = $true
    if (Test-Path $script:InstallDir) {
        $dlg.SelectedPath = $script:InstallDir
    } elseif (Test-Path (Split-Path $script:InstallDir -Parent)) {
        $dlg.SelectedPath = (Split-Path $script:InstallDir -Parent)
    }
    $result = $dlg.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) {
        # Append "SR Manager" if user picked a generic parent folder
        $picked = $dlg.SelectedPath
        $leaf = Split-Path $picked -Leaf
        if ($leaf -ne "SR Manager") {
            $picked = Join-Path $picked "SR Manager"
        }
        $script:InstallDir = $picked
        $txtPath.Text = $script:InstallDir
    }
})

function Set-Progress {
    param([string]$Step, [int]$Pct)
    $window.Dispatcher.Invoke([Action]{
        $txtStep.Text = $Step
        $txtPercent.Text = "$Pct%"
        $maxW = $progressBar.Parent.ActualWidth
        if ($maxW -le 0) { $maxW = 400 }
        $progressBar.Width = [Math]::Max(0, $maxW * $Pct / 100)
    })
}

$btnInstall.Add_Click({
    # If install is done, launch app
    if ($script:InstallDone) {
        $vbs = Join-Path $script:InstallDir "SR Manager.vbs"
        if (Test-Path $vbs) { Start-Process "wscript.exe" -ArgumentList "`"$vbs`"" -WorkingDirectory $script:InstallDir }
        $window.Close()
        return
    }

    # Reset UI
    $panelError.Visibility = 'Collapsed'
    $panelDone.Visibility  = 'Collapsed'
    $btnInstall.IsEnabled  = $false
    $btnCancel.Visibility  = 'Collapsed'
    $txtDesc.Visibility    = 'Collapsed'
    $panelPath.Visibility  = 'Collapsed'
    $panelProgress.Visibility = 'Visible'

    # Run install in background
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('window', $window)
    $runspace.SessionStateProxy.SetVariable('installDir', $script:InstallDir)
    $runspace.SessionStateProxy.SetVariable('files', $script:Files)
    $runspace.SessionStateProxy.SetVariable('txtStep', $txtStep)
    $runspace.SessionStateProxy.SetVariable('txtPercent', $txtPercent)
    $runspace.SessionStateProxy.SetVariable('progressBar', $progressBar)
    $runspace.SessionStateProxy.SetVariable('panelProgress', $panelProgress)
    $runspace.SessionStateProxy.SetVariable('panelDone', $panelDone)
    $runspace.SessionStateProxy.SetVariable('panelError', $panelError)
    $runspace.SessionStateProxy.SetVariable('txtError', $txtError)
    $runspace.SessionStateProxy.SetVariable('btnInstall', $btnInstall)
    $runspace.SessionStateProxy.SetVariable('btnCancel', $btnCancel)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript({
        function Update-UI {
            param([string]$Step, [int]$Pct)
            $window.Dispatcher.Invoke([Action]{
                $txtStep.Text = $Step
                $txtPercent.Text = "$Pct%"
                $maxW = $progressBar.Parent.ActualWidth
                if ($maxW -le 0) { $maxW = 400 }
                $progressBar.Width = [Math]::Max(0, $maxW * $Pct / 100)
            })
        }

        try {
            # Step 1: Create folder
            Update-UI "Kreiram folder..." 5
            if (-not (Test-Path $installDir)) {
                New-Item -Path $installDir -ItemType Directory -Force | Out-Null
            }
            Start-Sleep -Milliseconds 200

            # Step 2: Download files individually
            $total = $files.Count
            for ($i = 0; $i -lt $total; $i++) {
                $f = $files[$i]
                $pct = 10 + [int](70 * ($i / $total))
                Update-UI "Skidam $($f.name)..." $pct

                $dest = Join-Path $installDir $f.name
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("User-Agent", "SRManager-Installer")
                try {
                    $wc.DownloadFile($f.url, $dest)
                } catch {
                    # Ako primarni URL ne radi, pokusaj fallback
                    if ($f.fallback) {
                        $wc.DownloadFile($f.fallback, $dest)
                    } else { throw }
                }
                $wc.Dispose()
            }

            Update-UI "Download zavrsen..." 85

            # Step 3: Desktop shortcut -> Pokreni SR Manager.bat (WorkingDirectory = install folder)
            Update-UI "Kreiram shortcut..." 90
            New-SRManagerDesktopShortcut -InstallDir $installDir

            Update-UI "Gotovo!" 100
            Start-Sleep -Milliseconds 400

            # Show success
            $window.Dispatcher.Invoke([Action]{
                $panelProgress.Visibility = 'Collapsed'
                $panelDone.Visibility = 'Visible'
                $btnInstall.Content = "Pokreni SR Manager"
                $btnInstall.IsEnabled = $true
                $btnCancel.Content = "Zatvori"
                $btnCancel.Visibility = 'Visible'
            })

        } catch {
            $msg = $_.Exception.Message
            $window.Dispatcher.Invoke([Action]{
                $panelProgress.Visibility = 'Collapsed'
                $panelError.Visibility = 'Visible'
                $txtError.Text = $msg
                $btnInstall.Content = "Pokusaj ponovo"
                $btnInstall.IsEnabled = $true
                $btnCancel.Visibility = 'Visible'
            })
        }
    }) | Out-Null

    $ps.BeginInvoke() | Out-Null
})

# Track install completion via Content change
$btnInstall.Add_Loaded({
    $btnInstall.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            if ($btnInstall.Content -eq "Pokreni SR Manager") {
                $script:InstallDone = $true
            }
        }
    )
})

$window.ShowDialog() | Out-Null
