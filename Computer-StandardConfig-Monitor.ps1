# =====================================================================
# Purpose : THE MEDICAL TEAM - Standard Computers — User-facing progress monitor
# Runs as : Logged-in User
# Polls   : Registry HKLM:\SOFTWARE\TMT\Standard every 5 seconds
# Timeout : 24 hours — shows failure message if config doesn't finish
# =====================================================================

$RegBase    = "HKLM:\SOFTWARE\TMT\Standard"
$TotalSteps = 5                        # MUST match the master config script
$AppsStep   = 4                        # Step number when apps are being checked
$Timeout    = 86400                    # 24 hours in seconds
$StartTime  = Get-Date

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================
# REGISTRY HELPER
# =====================================================================
function Get-Reg {
    param([string]$Name)
    try { return (Get-ItemProperty -Path $RegBase -Name $Name -ErrorAction Stop).$Name }
    catch { return $null }
}

# =====================================================================
# EARLY EXIT — Already complete (registry)
# =====================================================================
if ((Get-Reg "ConfigComplete") -eq 1) {
    Write-Host "ConfigComplete already set — exiting silently."
    return
}

# =====================================================================
# EARLY EXIT — Legacy txt flags (silent, no prompts)
# =====================================================================
$LegacyFlags = @(
    "C:\ProgramData\TMT\MasterScriptDone1.0.txt",
    "C:\ProgramData\TMT\Done1.0.txt",
    "C:\Users\$ENV:USERNAME\AppData\MasterScriptDone1.0.txt",
    "C:\Users\$ENV:USERNAME\AppData\Done1.0.txt"
)
foreach ($f in $LegacyFlags) {
    if (Test-Path $f -PathType Leaf) {
        Write-Host "Legacy flag found: $f — exiting silently."
        return
    }
}

# =====================================================================
# WELCOME PROMPT
# =====================================================================
[System.Windows.Forms.MessageBox]::Show(
    "This computer is being configured.`n`nPlease DO NOT use it until setup is complete.`n`nClick OK to monitor the installation progress.",
    "****THE MEDICAL TEAM, INC.***",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null

# =====================================================================
# BUILD PROGRESS FORM
# =====================================================================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "**Computer Setup**THE MEDICAL TEAM, INC."
$form.Size            = New-Object System.Drawing.Size(540, 230)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.ControlBox      = $false
$form.TopMost         = $true

# Title label
$lblTitle           = New-Object System.Windows.Forms.Label
$lblTitle.AutoSize  = $true
$lblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::DodgerBlue
$lblTitle.Location  = New-Object System.Drawing.Point(14, 12)
$lblTitle.Text      = "***Please wait while we work on the magic...***"

# Step label
$lblStep           = New-Object System.Windows.Forms.Label
$lblStep.AutoSize  = $false
$lblStep.Size      = New-Object System.Drawing.Size(500, 20)
$lblStep.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblStep.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$lblStep.Location  = New-Object System.Drawing.Point(14, 42)
$lblStep.Text      = "Progress..."

# Detail label
$lblDetail           = New-Object System.Windows.Forms.Label
$lblDetail.AutoSize  = $false
$lblDetail.Size      = New-Object System.Drawing.Size(500, 20)
$lblDetail.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblDetail.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$lblDetail.Location  = New-Object System.Drawing.Point(14, 64)
$lblDetail.Text      = "Please wait — DO NOT turn off or restart this computer."

# Progress bar
$bar                       = New-Object System.Windows.Forms.ProgressBar
$bar.Location              = New-Object System.Drawing.Point(14, 92)
$bar.Size                  = New-Object System.Drawing.Size(500, 22)
$bar.Style                 = "Marquee"
$bar.MarqueeAnimationSpeed = 30
$bar.Minimum               = 0
$bar.Maximum               = 100
$bar.Value                 = 0

# Percent label
$lblPct           = New-Object System.Windows.Forms.Label
$lblPct.AutoSize  = $true
$lblPct.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblPct.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$lblPct.Location  = New-Object System.Drawing.Point(14, 122)
$lblPct.Text      = "0% complete"

# Apps label
$lblApps           = New-Object System.Windows.Forms.Label
$lblApps.AutoSize  = $false
$lblApps.Size      = New-Object System.Drawing.Size(500, 20)
$lblApps.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$lblApps.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$lblApps.Location  = New-Object System.Drawing.Point(14, 148)
$lblApps.Text      = ""

# Elapsed label
$lblElapsed           = New-Object System.Windows.Forms.Label
$lblElapsed.AutoSize  = $false
$lblElapsed.Size      = New-Object System.Drawing.Size(500, 18)
$lblElapsed.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$lblElapsed.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
$lblElapsed.Location  = New-Object System.Drawing.Point(14, 170)
$lblElapsed.Text      = "Elapsed: 0m"

$form.Controls.AddRange(@(
    $lblTitle, $lblStep, $lblDetail,
    $bar, $lblPct, $lblApps, $lblElapsed
))

# =====================================================================
# POLLING TIMER — every 5 seconds
# =====================================================================
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000

$timer.Add_Tick({

    # ---- Timeout check ----
    $elapsed = (Get-Date) - $StartTime
    if ($elapsed.TotalSeconds -ge $Timeout) {
        $timer.Stop()
        $form.Hide()
        [System.Windows.Forms.MessageBox]::Show(
            "The configuration did not complete within 24 hours.`n`nError: Timeout after 24 hours.",
            "****Configuration Failed****",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        $form.Close()
        return
    }

    # ---- Read registry ----
    $done        = Get-Reg "ConfigComplete"
    $failed      = Get-Reg "ConfigFailed"
    $step        = Get-Reg "ConfigStep"
    $stepLabel   = Get-Reg "ConfigStepLabel"
    $stepDetail  = Get-Reg "ConfigStepDetail"
    $appsReady   = Get-Reg "AppsReady"
    $appsTotal   = Get-Reg "AppsTotal"
    $appsMissing = Get-Reg "AppsMissing"
    $appsReadyL  = Get-Reg "AppsReadyList"
    $lastUpdated = Get-Reg "LastUpdated"
    $errMsg      = Get-Reg "ConfigError"

    # ---- Elapsed time ----
    $mins = [int]$elapsed.TotalMinutes
    $secs = $elapsed.Seconds
    $lblElapsed.Text = "Elapsed: ${mins}m ${secs}s$(if ($lastUpdated) { "  |  Last update: $lastUpdated" })"

    # ---- Failed state ----
    if ($failed -eq 1) {
        $timer.Stop()
        $form.Hide()
        [System.Windows.Forms.MessageBox]::Show(
            "Configuration encountered a fatal error and could not complete.`n`nError: $errMsg`n`nPlease contact your IT administrator for assistance.",
            "****Configuration Failed****",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        $form.Close()
        return
    }

    # ---- Update progress bar ----
    if ($step -is [int] -and $step -gt 0) {
        if ($bar.Style -ne 'Continuous') {
            $bar.Style                 = 'Continuous'
            $bar.MarqueeAnimationSpeed = 0
        }
        $pct         = [int][math]::Round(($step / $TotalSteps) * 100)
        $bar.Value   = [Math]::Min($pct, 100)
        $lblPct.Text = "$pct% complete"
    } else {
        if ($bar.Style -ne 'Marquee') {
            $bar.Style                 = 'Marquee'
            $bar.MarqueeAnimationSpeed = 30
        }
        $lblPct.Text = "Starting…"
    }

    # ---- Step labels ----
    if ($stepLabel)  { $lblStep.Text   = $stepLabel }
    if ($stepDetail) { $lblDetail.Text = $stepDetail }

    # ---- Apps status (show from app-check step onward) ----
    if ($step -ge $AppsStep -and $appsTotal -gt 0) {
        $lblApps.Text = "Apps: $appsReady/$appsTotal installed$(if ($appsMissing -and $appsMissing -ne 'None') { "  |  Waiting for: $appsMissing" } else { "  |  All apps ready" })"
    } else {
        $lblApps.Text = ""
    }

    [System.Windows.Forms.Application]::DoEvents()

    # ---- All done ----
    if ($done -eq 1) {
        $timer.Stop()
        $bar.Value      = 100
        $lblStep.Text   = "Configuration Complete!"
        $lblDetail.Text = "All steps finished successfully."
        $lblPct.Text    = "100% complete"
        $lblApps.Text   = ""
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 1000
        $form.Hide()

        $result = [System.Windows.Forms.MessageBox]::Show(
            "The computer setup is complete!`n`nClick YES to restart now.`nClick NO to restart automatically in 5 minutes.",
            "Finished - Reboot Required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            shutdown.exe /r /t 0 /c "Restarting now."
        } else {
            shutdown.exe /r /t 300 /c "Restarting in 5 minutes."
        }

        $form.Close()
    }
})

$form.Add_Shown({ $timer.Start() })
[void]$form.ShowDialog()
