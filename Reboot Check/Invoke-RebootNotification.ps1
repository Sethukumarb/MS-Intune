<#
.SYNOPSIS
    Displays a WPF reboot notification dialog to the logged-on user and handles
    restart or postpone actions based on user input.

.DESCRIPTION
    This script is intended for use as an Intune Proactive Remediation script.
    It performs the following tasks:

    When running as SYSTEM (Intune default):
      1. Collects last boot time and uptime data via WMI while elevated.
      2. Writes a self-contained user-session PowerShell script to disk at
         C:\ProgramData\IT\Notifications\RebootCheckNotification.ps1.
      3. Detects the currently logged-on user via Win32_ComputerSystem.
      4. Registers a one-shot Scheduled Task under the logged-on user's session
         to launch the notification dialog in the correct desktop context.
      5. Waits 15 seconds for the WPF window to render, then removes the task.
      6. Exits cleanly if no user is logged on.

    When running directly in a user session (manual testing):
      1. Collects last boot time and uptime data directly.
      2. Renders the WPF notification dialog inline without any Scheduled Task.

    User Options in the Dialog:
      - Restart Now  : Queues a reboot via shutdown.exe and shows a live
                       countdown timer with a progress bar. Reboots when
                       the timer reaches zero.
      - Postpone     : Calls shutdown.exe to schedule a silent reboot after
                       the configured number of hours. Swaps the UI to show
                       a confirmation message and a Close button.

.NOTES
    Deploy as : Intune > Devices > Scripts > Proactive Remediations (Remediation script)
    Run as    : SYSTEM
    Architecture: 64-bit

    Paired with: Detect-DeviceReboot.ps1
    Drop path  : C:\ProgramData\IT\Notifications\RebootCheckNotification.ps1

    To cancel a pending reboot scheduled by this script, run the following
    from an elevated command prompt:
        shutdown /a

.AUTHOR
    Sethu Kumar B

.VERSION
    3.1 - Added detailed synopsis, description, inline comments, and function-level docs
          Previous changes:
          3.0 - Removed all scheduled-task logic from Postpone entirely.
                Postpone now calls shutdown /r /t directly. Zero dependencies.
          2.2 - Removed DeleteExpiredTaskAfter, added try/catch.
          2.1 - Fixed EndBoundary XML schema error on postpone task.
          2.0 - Bulletproof session-launch pattern. Writes user script to disk,
                launches via scheduled task, waits 15s, cleans up.
          1.0 - Initial release.
#>


#region ── CONFIGURATION ──────────────────────────────────────────────────────

$DAYS_THRESHOLD   = 7              # Must match the Detection script threshold
$REBOOT_COUNTDOWN = 3              # Minutes before reboot fires when Restart Now is clicked
$POSTPONE_HOURS   = 2              # Hours until auto-reboot after Postpone is clicked
$PRIMARY_COLOR    = "#0078D4"      # Hex color used for banner, buttons, and accent elements
$FOOTER_TEXT      = "For assistance, please contact your IT Support team."

#endregion ────────────────────────────────────────────────────────────────────


#==============================================================================
# !! DO NOT EDIT BELOW THIS LINE !!
#==============================================================================


#region ── SESSION DETECTION ──────────────────────────────────────────────────
#
# Determines whether this script is running as SYSTEM (launched by Intune) or
# directly in a user session (manual test run). The two execution paths diverge
# here — SYSTEM launches a Scheduled Task; user session renders the UI directly.
#
#endregion ────────────────────────────────────────────────────────────────────

$runningAsSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem)


#==============================================================================
# SYSTEM SESSION
# Runs when Intune executes this script as SYSTEM.
# Collects boot data, writes the user-session script to disk,
# and launches it in the logged-on user's desktop via a Scheduled Task.
#==============================================================================

if ($runningAsSystem) {

    Write-Host "[SYSTEM] Running as SYSTEM - preparing user session launch..."

    #region ── Step 1: Collect boot data as SYSTEM ────────────────────────────
    #
    # Boot info is gathered here while running as SYSTEM because this context
    # has reliable, unrestricted access to WMI. The values are baked directly
    # into the generated user-session script as literals so the user-session
    # process does not need elevated access or WMI permissions.
    #
    #endregion

    $lastBoot        = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $daysSinceBoot   = [math]::Round(((Get-Date) - $lastBoot).TotalDays, 1)
    $lastBootStr     = $lastBoot.ToString("dddd, dd MMM yyyy 'at' hh:mm tt")
    $rebootSeconds   = $REBOOT_COUNTDOWN * 60
    $postponeSeconds = $POSTPONE_HOURS * 3600

    Write-Host "[SYSTEM] Last boot  : $lastBootStr"
    Write-Host "[SYSTEM] Days since : $daysSinceBoot"

    #region ── Step 2: Prepare the drop folder ────────────────────────────────
    #
    # C:\ProgramData\IT\Notifications is used as the handoff location between
    # the SYSTEM session and the user session. This path is accessible to both.
    #
    #endregion

    $dropFolder = "C:\ProgramData\IT\Notifications"
    $dropScript = "$dropFolder\RebootCheckNotification.ps1"

    if (-not (Test-Path $dropFolder)) {
        New-Item -ItemType Directory -Path $dropFolder -Force | Out-Null
        Write-Host "[SYSTEM] Created folder: $dropFolder"
    }

    #region ── Step 3: Write the user-session script to disk ──────────────────
    #
    # The here-string below contains the complete self-contained script that
    # will run inside the logged-on user's desktop session. All dynamic values
    # (boot time, countdown seconds, colors, footer) are interpolated here and
    # written as literals into the output file, so the user-session process
    # requires no elevated access, WMI, or external dependencies.
    #
    # The script builds and displays a WPF notification dialog with:
    #   - Last reboot date and days-since badge
    #   - Restart Now button with live countdown timer and progress bar
    #   - Postpone button that schedules a silent reboot via shutdown.exe
    #
    #endregion

    $userScriptContent = @"
#==============================================================================
# REBOOT NOTIFICATION - USER SESSION SCRIPT
# Auto-generated by Intune Remediation. Do not upload this file to Intune.
# Source: Invoke-RebootNotification.ps1
#==============================================================================

`$daysSinceBoot   = $daysSinceBoot
`$lastBootStr     = '$lastBootStr'
`$rebootSeconds   = $rebootSeconds
`$postponeSeconds = $postponeSeconds
`$POSTPONE_HOURS  = $POSTPONE_HOURS
`$PRIMARY_COLOR   = '$PRIMARY_COLOR'
`$FOOTER_TEXT     = '$FOOTER_TEXT'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

[xml]`$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="IT Notification"
    Width="500"
    SizeToContent="Height"
    WindowStartupLocation="Manual"
    ResizeMode="NoResize"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="True">

    <Window.Resources>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="CornerRadius" Value="10"/>
            <Setter Property="Background" Value="White"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect BlurRadius="24" ShadowDepth="5" Opacity="0.22" Color="#000000"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Height" Value="40"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="18,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="b" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="b" Property="Opacity" Value="0.72"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SecondaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#EFEFEF"/>
            <Setter Property="Foreground" Value="#333333"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Height" Value="40"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="18,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#E0E0E0"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#D0D0D0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Border Style="{StaticResource Card}">
            <StackPanel>

                <!-- TOP ACCENT BAR — colored strip at the top of the card -->
                <Border x:Name="AccentBar" CornerRadius="10,10,0,0" Height="7"/>

                <!-- HEADER — icon, title, subtitle, and close (X) button -->
                <Grid Margin="22,18,22,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Border x:Name="IconCircle" Grid.Column="0" Width="46" Height="46"
                            CornerRadius="23" Margin="0,0,14,0" VerticalAlignment="Top">
                        <TextBlock Text="🔄" FontSize="22"
                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <TextBlock Text="Restart Required"
                                   FontFamily="Segoe UI Semibold" FontSize="17" Foreground="#1A1A1A"/>
                        <TextBlock Text="Your device is overdue for a reboot"
                                   FontFamily="Segoe UI" FontSize="11.5" Foreground="#888888" Margin="0,3,0,0"/>
                    </StackPanel>
                    <Button Grid.Column="2" x:Name="CloseBtn"
                            Content="✕" Width="28" Height="28" FontSize="12"
                            Foreground="#AAAAAA" Background="Transparent"
                            BorderThickness="0" Cursor="Hand" VerticalAlignment="Top">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="cb" Background="Transparent" CornerRadius="4">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="cb" Property="Background" Value="#F0F0F0"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </Grid>

                <!-- DIVIDER -->
                <Separator Margin="22,14,22,0" Background="#EBEBEB"/>

                <!-- UPTIME INFO CARD — shows last reboot date and days-since badge -->
                <Border Margin="22,14,22,0" Background="#F0F6FF" CornerRadius="8" Padding="14,12">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" VerticalAlignment="Center">
                            <TextBlock Text="Last Reboot"
                                       FontFamily="Segoe UI" FontSize="11" Foreground="#666666"/>
                            <TextBlock x:Name="LastBootLabel"
                                       FontFamily="Segoe UI Semibold" FontSize="13"
                                       Foreground="#1A1A1A" Margin="0,4,0,0" TextWrapping="Wrap"/>
                        </StackPanel>
                        <Border x:Name="DaysBadge" Grid.Column="1" CornerRadius="8"
                                Padding="14,8" VerticalAlignment="Center" Margin="10,0,0,0">
                            <StackPanel HorizontalAlignment="Center">
                                <TextBlock x:Name="DaysLabel"
                                           FontFamily="Segoe UI Black" FontSize="26"
                                           Foreground="White" HorizontalAlignment="Center"/>
                                <TextBlock Text="days ago"
                                           FontFamily="Segoe UI" FontSize="10"
                                           Foreground="#CCE4FF" HorizontalAlignment="Center"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <!-- BODY TEXT — explains why a reboot is needed -->
                <TextBlock Margin="22,14,22,0"
                           FontFamily="Segoe UI" FontSize="13.5" Foreground="#444444"
                           TextWrapping="Wrap" LineHeight="22"
                           Text="Your device has not been restarted in a while. Regular restarts improve performance, apply security patches, and keep your device healthy and compliant.&#x0a;&#x0a;Please save your work and click Restart Now when you are ready."/>

                <!-- COUNTDOWN BANNER — hidden until Restart Now is clicked -->
                <Border x:Name="CountdownBanner" Visibility="Collapsed"
                        Margin="22,14,22,0" Background="#FFF0F0" CornerRadius="8" Padding="14,10">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="⚠  " FontSize="14" Foreground="#C42B1C" VerticalAlignment="Center"/>
                        <TextBlock x:Name="CountdownLabel"
                                   FontFamily="Segoe UI Semibold" FontSize="13"
                                   Foreground="#C42B1C" VerticalAlignment="Center" TextWrapping="Wrap"/>
                    </StackPanel>
                </Border>

                <!-- COUNTDOWN PROGRESS BAR — hidden until Restart Now is clicked -->
                <ProgressBar x:Name="CountdownProgress"
                             Margin="22,8,22,0" Height="5"
                             Minimum="0" Maximum="100" Value="100"
                             Visibility="Collapsed"
                             Foreground="#C42B1C" Background="#F5D0CE"/>

                <!-- POSTPONE CONFIRMATION BANNER — hidden until Postpone is clicked -->
                <Border x:Name="PostponeBanner" Visibility="Collapsed"
                        Margin="22,14,22,0" Background="#FFF4CE" CornerRadius="8" Padding="14,10">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="⏱  " FontSize="14" Foreground="#7A6400" VerticalAlignment="Center"/>
                        <TextBlock x:Name="PostponeLabel"
                                   FontFamily="Segoe UI Semibold" FontSize="13"
                                   Foreground="#7A6400" VerticalAlignment="Center" TextWrapping="Wrap"/>
                    </StackPanel>
                </Border>

                <!-- ACTION BUTTONS — Postpone and Restart Now (hidden after Postpone clicked) -->
                <StackPanel x:Name="ButtonPanel"
                            Orientation="Horizontal" HorizontalAlignment="Right"
                            Margin="22,20,22,0">
                    <Button x:Name="PostponeBtn"
                            Style="{StaticResource SecondaryBtn}"
                            MinWidth="175" Margin="0,0,10,0"/>
                    <Button x:Name="RestartBtn"
                            Style="{StaticResource PrimaryBtn}"
                            Content="🔄  Restart Now" MinWidth="145"/>
                </StackPanel>

                <!-- DISMISS BUTTON — only shown after Postpone is clicked -->
                <StackPanel x:Name="ClosePanel" Visibility="Collapsed"
                            Orientation="Horizontal" HorizontalAlignment="Right"
                            Margin="22,14,22,0">
                    <Button x:Name="DismissBtn"
                            Style="{StaticResource SecondaryBtn}"
                            Content="✕  Close" MinWidth="120"/>
                </StackPanel>

                <!-- FOOTER — support contact information -->
                <Border Background="#FAFAFA" CornerRadius="0,0,10,10"
                        Margin="0,18,0,0" Padding="22,10">
                    <TextBlock x:Name="FooterText"
                               FontFamily="Segoe UI" FontSize="11"
                               Foreground="#AAAAAA" TextWrapping="Wrap"/>
                </Border>

            </StackPanel>
        </Border>
    </Grid>
</Window>
'@

`$reader = New-Object System.Xml.XmlNodeReader `$xaml
`$window = [Windows.Markup.XamlReader]::Load(`$reader)

# ── Wire up named controls from the XAML tree ─────────────────────────────────
`$AccentBar         = `$window.FindName("AccentBar")
`$IconCircle        = `$window.FindName("IconCircle")
`$DaysBadge         = `$window.FindName("DaysBadge")
`$DaysLabel         = `$window.FindName("DaysLabel")
`$LastBootLabel     = `$window.FindName("LastBootLabel")
`$FooterText        = `$window.FindName("FooterText")
`$RestartBtn        = `$window.FindName("RestartBtn")
`$PostponeBtn       = `$window.FindName("PostponeBtn")
`$CloseBtn          = `$window.FindName("CloseBtn")
`$DismissBtn        = `$window.FindName("DismissBtn")
`$CountdownBanner   = `$window.FindName("CountdownBanner")
`$CountdownLabel    = `$window.FindName("CountdownLabel")
`$CountdownProgress = `$window.FindName("CountdownProgress")
`$PostponeBanner    = `$window.FindName("PostponeBanner")
`$PostponeLabel     = `$window.FindName("PostponeLabel")
`$ButtonPanel       = `$window.FindName("ButtonPanel")
`$ClosePanel        = `$window.FindName("ClosePanel")

# ── Apply dynamic values baked in from the SYSTEM session ─────────────────────
# Primary color brush is applied to accent bar, icon circle, days badge, and primary button
`$brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString(`$PRIMARY_COLOR)
`$AccentBar.Background  = `$brush
`$IconCircle.Background = `$brush
`$DaysBadge.Background  = `$brush
`$RestartBtn.Background = `$brush

`$DaysLabel.Text      = "`$daysSinceBoot"
`$LastBootLabel.Text  = `$lastBootStr
`$FooterText.Text     = `$FOOTER_TEXT
`$PostponeBtn.Content = "⏱  Postpone (`$POSTPONE_HOURS hrs)"

# ── Center the window on the primary screen's working area ────────────────────
`$window.Add_Loaded({
    `$screen      = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    `$window.Left = (`$screen.Width  - `$window.ActualWidth)  / 2 + `$screen.Left
    `$window.Top  = (`$screen.Height - `$window.ActualHeight) / 2 + `$screen.Top
})

# ── Allow the user to drag the window by clicking anywhere on it ──────────────
`$window.Add_MouseLeftButtonDown({ `$window.DragMove() })

# ── CLOSE (X) button — dismisses the dialog without any action ───────────────
`$CloseBtn.Add_Click({ `$window.Close() })

# ── DISMISS button — shown after Postpone; closes the dialog ─────────────────
`$DismissBtn.Add_Click({ `$window.Close() })

# ── POSTPONE button ───────────────────────────────────────────────────────────
# Schedules a silent reboot via shutdown.exe after POSTPONE_HOURS hours.
# Swaps the action button panel for a confirmation banner and a Close button.
# Disables the X button so the user must use the explicit Close button to exit.
`$PostponeBtn.Add_Click({

    # Queue a silent reboot — shutdown.exe handles the timer natively, no task needed
    Start-Process -FilePath "shutdown.exe" ``
        -ArgumentList "/r /t `$postponeSeconds /c ``"Your IT team has scheduled a restart in `$POSTPONE_HOURS hours. Please save your work before then.``"" ``
        -WindowStyle Hidden

    # Swap UI state: hide action buttons, reveal confirmation banner and Close button
    `$ButtonPanel.Visibility    = [System.Windows.Visibility]::Collapsed
    `$PostponeBanner.Visibility = [System.Windows.Visibility]::Visible
    `$ClosePanel.Visibility     = [System.Windows.Visibility]::Visible
    `$PostponeLabel.Text        = "Noted! Your device will automatically restart in `$POSTPONE_HOURS hours. `nPlease save your work before then."

    # Disable X so the user must acknowledge via the Close button
    `$CloseBtn.IsEnabled = `$false
})

# ── RESTART NOW button ────────────────────────────────────────────────────────
# Queues an immediate reboot via shutdown.exe, then runs a per-second
# DispatcherTimer that counts down in the UI and closes the window at zero.
# Guards against double-click with the countdownRunning flag.
`$script:secondsLeft      = `$rebootSeconds
`$script:countdownRunning = `$false

`$RestartBtn.Add_Click({

    # Prevent re-entry if countdown is already running
    if (`$script:countdownRunning) { return }
    `$script:countdownRunning = `$true
    `$script:secondsLeft      = `$rebootSeconds

    # Lock all interactive controls while countdown is active
    `$RestartBtn.IsEnabled         = `$false
    `$PostponeBtn.IsEnabled        = `$false
    `$CloseBtn.IsEnabled           = `$false
    `$CountdownBanner.Visibility   = [System.Windows.Visibility]::Visible
    `$CountdownProgress.Visibility = [System.Windows.Visibility]::Visible

    # Queue the reboot — Windows executes shutdown after rebootSeconds elapses
    Start-Process -FilePath "shutdown.exe" ``
        -ArgumentList "/r /t `$rebootSeconds /c ``"Your IT team has scheduled a restart. Please save your work immediately.``"" ``
        -WindowStyle Hidden

    # Per-second DispatcherTimer — updates countdown label and progress bar each tick
    `$countTimer          = New-Object System.Windows.Threading.DispatcherTimer
    `$countTimer.Interval = [TimeSpan]::FromSeconds(1)
    `$countTimer.Add_Tick({

        `$script:secondsLeft--

        `$mins    = [math]::Floor(`$script:secondsLeft / 60)
        `$secs    = `$script:secondsLeft % 60
        `$timeStr = "{0}:{1:D2}" -f `$mins, `$secs

        `$CountdownLabel.Text     = "Your device will restart in `$timeStr. Save your work now!"
        `$CountdownProgress.Value = (`$script:secondsLeft / `$rebootSeconds) * 100

        # When timer reaches zero, stop ticking and close the window
        if (`$script:secondsLeft -le 0) {
            `$countTimer.Stop()
            `$CountdownLabel.Text     = "Restarting now. Goodbye!"
            `$CountdownProgress.Value = 0
            Start-Sleep -Seconds 2
            `$window.Close()
        }
    })
    `$countTimer.Start()
})

# ── Display the dialog — blocks until the window is closed ────────────────────
[void]`$window.ShowDialog()
"@

    # Write the fully interpolated user-session script to the handoff location
    $userScriptContent | Out-File -FilePath $dropScript -Encoding UTF8 -Force
    Write-Host "[SYSTEM] User script written to: $dropScript"

    #region ── Step 4: Detect the logged-on user ──────────────────────────────
    #
    # Win32_ComputerSystem.UserName returns DOMAIN\username of the interactive
    # user. If no user is logged on (e.g. device is at lock screen with no
    # active session), the property is null or empty and we exit cleanly.
    #
    #endregion

    $loggedOnUser = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName

    if (-not $loggedOnUser) {
        Write-Host "[SYSTEM] No user logged on. Exiting cleanly."
        Exit 0
    }

    Write-Host "[SYSTEM] Logged-on user: $loggedOnUser"

    #region ── Step 5: Register a one-shot Scheduled Task in the user session ──
    #
    # The task runs powershell.exe under the logged-on user's Interactive logon,
    # which places it in the correct desktop session so the WPF window is visible.
    # A random suffix is appended to the task name to avoid collisions if the
    # script runs more than once before the previous task is cleaned up.
    #
    #endregion

    $taskName = "IT_RebootCheckNotification_$(Get-Random -Minimum 1000 -Maximum 9999)"

    $action    = New-ScheduledTaskAction `
                    -Execute "powershell.exe" `
                    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dropScript`""

    $principal = New-ScheduledTaskPrincipal `
                    -UserId $loggedOnUser `
                    -LogonType Interactive `
                    -RunLevel Limited

    $settings  = New-ScheduledTaskSettingsSet `
                    -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    Register-ScheduledTask `
        -TaskName  $taskName `
        -Action    $action `
        -Principal $principal `
        -Settings  $settings `
        -Force | Out-Null

    Write-Host "[SYSTEM] Launch task registered: $taskName"

    # Trigger the task immediately
    Start-ScheduledTask -TaskName $taskName
    Write-Host "[SYSTEM] Launch task started."

    #region ── Step 6: Wait then clean up the launch task ─────────────────────
    #
    # 15 seconds is sufficient for powershell.exe to start and for the WPF
    # window to render and become visible. Once the window is open it runs
    # independently — removing the task does not affect the running dialog.
    #
    #endregion

    Start-Sleep -Seconds 15
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[SYSTEM] Launch task removed: $taskName"
    Write-Host "[SYSTEM] Done."
    Exit 0
}


#==============================================================================
# USER SESSION
# Runs when the script is executed directly (e.g. manual testing).
# Collects boot data inline and renders the WPF dialog without any
# Scheduled Task or SYSTEM-session handoff.
#==============================================================================

Write-Host "[USER] Running directly in user session."

# Collect boot data directly — user session has sufficient WMI access
$lastBoot        = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
$daysSinceBoot   = [math]::Round(((Get-Date) - $lastBoot).TotalDays, 1)
$lastBootStr     = $lastBoot.ToString("dddd, dd MMM yyyy 'at' hh:mm tt")
$rebootSeconds   = $REBOOT_COUNTDOWN * 60
$postponeSeconds = $POSTPONE_HOURS * 3600

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="IT Notification"
    Width="500"
    SizeToContent="Height"
    WindowStartupLocation="Manual"
    ResizeMode="NoResize"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="True">

    <Window.Resources>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="CornerRadius" Value="10"/>
            <Setter Property="Background" Value="White"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect BlurRadius="24" ShadowDepth="5" Opacity="0.22" Color="#000000"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Background" Value="$PRIMARY_COLOR"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Height" Value="40"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="18,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="b" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="b" Property="Opacity" Value="0.72"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SecondaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#EFEFEF"/>
            <Setter Property="Foreground" Value="#333333"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Height" Value="40"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="18,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#E0E0E0"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#D0D0D0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Border Style="{StaticResource Card}">
            <StackPanel>
                <!-- TOP ACCENT BAR -->
                <Border CornerRadius="10,10,0,0" Height="7" Background="$PRIMARY_COLOR"/>

                <!-- HEADER -->
                <Grid Margin="22,18,22,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Width="46" Height="46" CornerRadius="23"
                            Background="$PRIMARY_COLOR" Margin="0,0,14,0" VerticalAlignment="Top">
                        <TextBlock Text="🔄" FontSize="22"
                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <TextBlock Text="Restart Required"
                                   FontFamily="Segoe UI Semibold" FontSize="17" Foreground="#1A1A1A"/>
                        <TextBlock Text="Your device is overdue for a reboot"
                                   FontFamily="Segoe UI" FontSize="11.5" Foreground="#888888" Margin="0,3,0,0"/>
                    </StackPanel>
                    <Button Grid.Column="2" x:Name="CloseBtn"
                            Content="✕" Width="28" Height="28" FontSize="12"
                            Foreground="#AAAAAA" Background="Transparent"
                            BorderThickness="0" Cursor="Hand" VerticalAlignment="Top">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="cb" Background="Transparent" CornerRadius="4">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="cb" Property="Background" Value="#F0F0F0"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </Grid>

                <!-- DIVIDER -->
                <Separator Margin="22,14,22,0" Background="#EBEBEB"/>

                <!-- UPTIME INFO CARD -->
                <Border Margin="22,14,22,0" Background="#F0F6FF" CornerRadius="8" Padding="14,12">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" VerticalAlignment="Center">
                            <TextBlock Text="Last Reboot" FontFamily="Segoe UI" FontSize="11" Foreground="#666666"/>
                            <TextBlock x:Name="LastBootLabel"
                                       FontFamily="Segoe UI Semibold" FontSize="13"
                                       Foreground="#1A1A1A" Margin="0,4,0,0" TextWrapping="Wrap"/>
                        </StackPanel>
                        <Border Grid.Column="1" Background="$PRIMARY_COLOR" CornerRadius="8"
                                Padding="14,8" VerticalAlignment="Center" Margin="10,0,0,0">
                            <StackPanel HorizontalAlignment="Center">
                                <TextBlock x:Name="DaysLabel"
                                           FontFamily="Segoe UI Black" FontSize="26"
                                           Foreground="White" HorizontalAlignment="Center"/>
                                <TextBlock Text="days ago" FontFamily="Segoe UI" FontSize="10"
                                           Foreground="#CCE4FF" HorizontalAlignment="Center"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <!-- BODY TEXT -->
                <TextBlock Margin="22,14,22,0"
                           FontFamily="Segoe UI" FontSize="13.5" Foreground="#444444"
                           TextWrapping="Wrap" LineHeight="22"
                           Text="Your device has not been restarted in a while. Regular restarts improve performance, apply security patches, and keep your device healthy and compliant.&#x0a;&#x0a;Please save your work and click Restart Now when you are ready."/>

                <!-- COUNTDOWN BANNER — hidden until Restart Now clicked -->
                <Border x:Name="CountdownBanner" Visibility="Collapsed"
                        Margin="22,14,22,0" Background="#FFF0F0" CornerRadius="8" Padding="14,10">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="⚠  " FontSize="14" Foreground="#C42B1C" VerticalAlignment="Center"/>
                        <TextBlock x:Name="CountdownLabel"
                                   FontFamily="Segoe UI Semibold" FontSize="13"
                                   Foreground="#C42B1C" VerticalAlignment="Center" TextWrapping="Wrap"/>
                    </StackPanel>
                </Border>

                <!-- COUNTDOWN PROGRESS BAR — hidden until Restart Now clicked -->
                <ProgressBar x:Name="CountdownProgress"
                             Margin="22,8,22,0" Height="5"
                             Minimum="0" Maximum="100" Value="100"
                             Visibility="Collapsed"
                             Foreground="#C42B1C" Background="#F5D0CE"/>

                <!-- POSTPONE CONFIRMATION BANNER — hidden until Postpone clicked -->
                <Border x:Name="PostponeBanner" Visibility="Collapsed"
                        Margin="22,14,22,0" Background="#FFF4CE" CornerRadius="8" Padding="14,10">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="⏱  " FontSize="14" Foreground="#7A6400" VerticalAlignment="Center"/>
                        <TextBlock x:Name="PostponeLabel"
                                   FontFamily="Segoe UI Semibold" FontSize="13"
                                   Foreground="#7A6400" VerticalAlignment="Center" TextWrapping="Wrap"/>
                    </StackPanel>
                </Border>

                <!-- ACTION BUTTONS -->
                <StackPanel x:Name="ButtonPanel" Orientation="Horizontal"
                            HorizontalAlignment="Right" Margin="22,20,22,0">
                    <Button x:Name="PostponeBtn" Style="{StaticResource SecondaryBtn}"
                            Content="⏱  Postpone ($POSTPONE_HOURS hrs)"
                            MinWidth="175" Margin="0,0,10,0"/>
                    <Button x:Name="RestartBtn" Style="{StaticResource PrimaryBtn}"
                            Content="🔄  Restart Now" MinWidth="145"/>
                </StackPanel>

                <!-- DISMISS BUTTON — shown after Postpone clicked -->
                <StackPanel x:Name="ClosePanel" Visibility="Collapsed"
                            Orientation="Horizontal" HorizontalAlignment="Right"
                            Margin="22,14,22,0">
                    <Button x:Name="DismissBtn" Style="{StaticResource SecondaryBtn}"
                            Content="✕  Close" MinWidth="120"/>
                </StackPanel>

                <!-- FOOTER -->
                <Border Background="#FAFAFA" CornerRadius="0,0,10,10" Margin="0,18,0,0" Padding="22,10">
                    <TextBlock Text="$FOOTER_TEXT"
                               FontFamily="Segoe UI" FontSize="11" Foreground="#AAAAAA" TextWrapping="Wrap"/>
                </Border>
            </StackPanel>
        </Border>
    </Grid>
</Window>
"@

# Load the XAML and get a reference to the WPF window object
$reader            = New-Object System.Xml.XmlNodeReader $xaml
$window            = [Windows.Markup.XamlReader]::Load($reader)

# Wire up named controls from the XAML tree
$RestartBtn        = $window.FindName("RestartBtn")
$PostponeBtn       = $window.FindName("PostponeBtn")
$CloseBtn          = $window.FindName("CloseBtn")
$DismissBtn        = $window.FindName("DismissBtn")
$CountdownBanner   = $window.FindName("CountdownBanner")
$CountdownLabel    = $window.FindName("CountdownLabel")
$CountdownProgress = $window.FindName("CountdownProgress")
$PostponeBanner    = $window.FindName("PostponeBanner")
$PostponeLabel     = $window.FindName("PostponeLabel")
$ButtonPanel       = $window.FindName("ButtonPanel")
$ClosePanel        = $window.FindName("ClosePanel")
$LastBootLabel     = $window.FindName("LastBootLabel")
$DaysLabel         = $window.FindName("DaysLabel")

# Populate dynamic fields with live boot data
$DaysLabel.Text     = "$daysSinceBoot"
$LastBootLabel.Text = $lastBootStr

# Center the window on the primary screen's working area once it has rendered
$window.Add_Loaded({
    $screen      = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $window.Left = ($screen.Width  - $window.ActualWidth)  / 2 + $screen.Left
    $window.Top  = ($screen.Height - $window.ActualHeight) / 2 + $screen.Top
})

# Allow the user to drag the borderless window by clicking anywhere on it
$window.Add_MouseLeftButtonDown({ $window.DragMove() })

# ── CLOSE (X) button — dismisses the dialog without any action ───────────────
$CloseBtn.Add_Click({ $window.Close() })

# ── DISMISS button — shown after Postpone; closes the dialog ─────────────────
$DismissBtn.Add_Click({ $window.Close() })

# ── POSTPONE button ───────────────────────────────────────────────────────────
# Schedules a silent reboot via shutdown.exe after POSTPONE_HOURS hours.
# Swaps the action button panel for a confirmation banner and a Close button.
# Disables the X button so the user must use the explicit Close button to exit.
$PostponeBtn.Add_Click({

    # Queue a silent reboot — shutdown.exe handles the timer natively, no task needed
    Start-Process -FilePath "shutdown.exe" `
        -ArgumentList "/r /t $postponeSeconds /c `"Your IT team has scheduled a restart in $POSTPONE_HOURS hours. Please save your work before then.`"" `
        -WindowStyle Hidden

    # Swap UI state: hide action buttons, reveal confirmation banner and Close button
    $ButtonPanel.Visibility    = [System.Windows.Visibility]::Collapsed
    $PostponeBanner.Visibility = [System.Windows.Visibility]::Visible
    $ClosePanel.Visibility     = [System.Windows.Visibility]::Visible
    $PostponeLabel.Text        = "Noted! Your device will automatically restart in $POSTPONE_HOURS hours. `nPlease save your work before then."

    # Disable X so the user must acknowledge via the Close button
    $CloseBtn.IsEnabled = $false
})

# ── RESTART NOW button ────────────────────────────────────────────────────────
# Queues an immediate reboot via shutdown.exe, then runs a per-second
# DispatcherTimer that counts down in the UI and closes the window at zero.
# Guards against double-click with the countdownRunning flag.
$script:secondsLeft      = $rebootSeconds
$script:countdownRunning = $false

$RestartBtn.Add_Click({

    # Prevent re-entry if countdown is already running
    if ($script:countdownRunning) { return }
    $script:countdownRunning = $true
    $script:secondsLeft      = $rebootSeconds

    # Lock all interactive controls while countdown is active
    $RestartBtn.IsEnabled         = $false
    $PostponeBtn.IsEnabled        = $false
    $CloseBtn.IsEnabled           = $false
    $CountdownBanner.Visibility   = [System.Windows.Visibility]::Visible
    $CountdownProgress.Visibility = [System.Windows.Visibility]::Visible

    # Queue the reboot — Windows executes shutdown after rebootSeconds elapses
    Start-Process -FilePath "shutdown.exe" `
        -ArgumentList "/r /t $rebootSeconds /c `"Your IT team has scheduled a restart. Please save your work immediately.`"" `
        -WindowStyle Hidden

    # Per-second DispatcherTimer — updates countdown label and progress bar each tick
    $countTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $countTimer.Interval = [TimeSpan]::FromSeconds(1)
    $countTimer.Add_Tick({

        $script:secondsLeft--

        $mins    = [math]::Floor($script:secondsLeft / 60)
        $secs    = $script:secondsLeft % 60
        $timeStr = "{0}:{1:D2}" -f $mins, $secs

        $CountdownLabel.Text     = "Your device will restart in $timeStr. Save your work now!"
        $CountdownProgress.Value = ($script:secondsLeft / $rebootSeconds) * 100

        # When timer reaches zero, stop ticking and close the window
        if ($script:secondsLeft -le 0) {
            $countTimer.Stop()
            $CountdownLabel.Text     = "Restarting now. Goodbye!"
            $CountdownProgress.Value = 0
            Start-Sleep -Seconds 2
            $window.Close()
        }
    })
    $countTimer.Start()
})

# Display the dialog — blocks until the window is closed
[void]$window.ShowDialog()
Exit 0