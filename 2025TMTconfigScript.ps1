# ----------------------------- CONFIG (tweak as you like) -----------------------------
$UI_FontTitleSize   = 12
$UI_FontBodySize    = 10
$UI_ColorAccent     = 'DodgerBlue'
$UI_ColorBody       = 'Black'
$UI_ProgressWidth   = 500
$UI_ProgressHeight  = 180
$UI_TopMost         = $true

# ----------------------------- IMPORTS -----------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ----------------------------- REUSABLE: Big Message Box ------------------------------
function Show-BigMessageBox {
    param(
        [string]$Title = "Information",
        [string]$Message = "",
        [ValidateSet("OK","OKCancel")] [string]$Buttons = "OK",
        [string]$AccentColor = $UI_ColorAccent,
        [switch]$TopMost
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $TopMost.IsPresent
    $form.Size = New-Object System.Drawing.Size(640,280)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.AutoSize = $true
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', $UI_FontTitleSize, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromName($AccentColor)
    $lblTitle.Location = New-Object System.Drawing.Point(16,16)
    $lblTitle.Text = $Title

    $lblBody = New-Object System.Windows.Forms.Label
    $lblBody.AutoSize = $false
    $lblBody.Font = New-Object System.Drawing.Font('Segoe UI', $UI_FontBodySize)
    $lblBody.ForeColor = [System.Drawing.Color]::FromName($UI_ColorBody)
    $lblBody.Location = New-Object System.Drawing.Point(18,48)
    $lblBody.Size = New-Object System.Drawing.Size(590,140)
    $lblBody.Text = $Message

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnOK.Size = New-Object System.Drawing.Size(110,32)
    $btnOK.Location = New-Object System.Drawing.Point(400,200)
    $btnOK.Add_Click({ $form.Tag = [System.Windows.Forms.DialogResult]::OK; $form.Close() })

    $form.Controls.AddRange(@($lblTitle,$lblBody,$btnOK))

    $btnCancel = $null
    if ($Buttons -eq "OKCancel") {
        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = "Cancel"
        $btnCancel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $btnCancel.Size = New-Object System.Drawing.Size(110,32)
        $btnCancel.Location = New-Object System.Drawing.Point(520,200)
        $btnCancel.Add_Click({ $form.Tag = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })
        $form.Controls.Add($btnCancel)
    }

    $form.AcceptButton = $btnOK
    if ($btnCancel) { $form.CancelButton = $btnCancel }

    [void]$form.ShowDialog()
    return $form.Tag
}

# ----------------------------- REUSABLE: Progress UI ---------------------------------
function New-ProgressUI {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Configuration in Progress"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $UI_TopMost
    $form.Size = New-Object System.Drawing.Size($UI_ProgressWidth, $UI_ProgressHeight)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.AutoSize = $true
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromName($UI_ColorAccent)
    $lblTitle.Location = New-Object System.Drawing.Point(14,12)
    $lblTitle.Text = "Please wait…"

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.AutoSize = $true
    $lblSub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lblSub.ForeColor = [System.Drawing.Color]::FromArgb(60,60,60)
    $lblSub.Location = New-Object System.Drawing.Point(16,36)
    $lblSub.Text = "Preparing configuration"

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(16,64)
    $bar.Size = New-Object System.Drawing.Size($UI_ProgressWidth - 40, 22)
    $bar.Style = 'Continuous'
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Value = 0

    $form.Controls.AddRange(@($lblTitle,$lblSub,$bar))

    return [pscustomobject]@{
        Form = $form
        Title = $lblTitle
        Sub = $lblSub
        Bar = $bar
    }
}

function Set-ProgressStep {
    param(
        [Parameter(Mandatory)] [int]$StepIndex,
        [Parameter(Mandatory)] [int]$TotalSteps,
        [Parameter(Mandatory)] [System.Windows.Forms.ProgressBar]$Bar,
        [System.Windows.Forms.Label]$SubLabel,
        [string]$StepTitle
    )
    $pct = [int]([math]::Round((($StepIndex) / $TotalSteps) * 100,0))
    $Bar.Value = [Math]::Min([Math]::Max($pct,0),100)
    if ($SubLabel -and $StepTitle) {
        $SubLabel.Text = "$StepTitle  ($pct`%)"
    }
    # keep UI snappy if running on same thread
    [System.Windows.Forms.Application]::DoEvents()
}

# ----------------------------- YOUR VARIABLES / FLAGS ---------------------------------
$MasterScriptDone = "C:\Users\$($ENV:USERNAME)\AppData\MasterScriptDone1.0.txt" # DO NOT DELETE.

# Steps you actually run (edit labels or add/remove steps as needed)
$Steps = @(
    "Step 1/6: Configure Local Admin Group",
    # "Step 2/6: Re-Partition Disk",      # currently disabled
    # "Step 3/6: Folder Redirection",     # currently disabled
    "Step 2/6: Rename Computer",
    "Step 3/6: Remove HP Bloatware",
    "Step 4/6: Remove Windows Bloatware",
    "Step 5/6: Create Shortcuts",
    "Step 6/6: Finalizing"
)
$TotalSteps = $Steps.Count

# ----------------------------- START: Pre-check / Welcome ------------------------------
if (Test-Path $MasterScriptDone) {
    # Already finished earlier → show a big, styled info dialog
    [void](Show-BigMessageBox -Title "Configuration Complete" -Message "The computer is ready to use." -Buttons OK -TopMost)
    return
}
else {
    $msg = @"
Please **DO NOT USE** this computer right now.
We are setting up this device and it may restart when complete.

Click **OK** to begin the setup.
"@
    # (The custom dialog doesn't render markdown; the bolding is achieved by title color/weight.)
    [void](Show-BigMessageBox -Title "Configuration Status" -Message $msg -Buttons OK -TopMost)
}

# ----------------------------- PROGRESS WINDOW ----------------------------------------
$ui = New-ProgressUI
$ui.Title.Text = "Configuring your computer…"
$ui.Sub.Text = "Starting…"
$ui.Form.Show()

# ----------------------------- STEP 1: Local Admin Group ------------------------------
Set-ProgressStep -StepIndex 0 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[0]

$LocalAdminGroupFolder = "C:\ProgramData\TMT\LocalAdminGroup"
if (-not (Test-Path $LocalAdminGroupFolder)) {
    New-Item -Path $LocalAdminGroupFolder -ItemType Directory | Out-Null
}
$LocalAdminGroupFile = "C:\ProgramData\TMT\LocalAdminGroup\TMTLocalAdGroup.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/LocalAdminGroup/main/TMTLocalAdGroup.ps1" -OutFile $LocalAdminGroupFile
Invoke-Expression -Command $LocalAdminGroupFile

Set-ProgressStep -StepIndex 1 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[0]

# ----------------------------- STEP 2: Rename Computer --------------------------------
Set-ProgressStep -StepIndex 1 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[1]

$ChangeComputerNameFolder = "C:\ProgramData\TMT\ChangeComputerName"
if (-not (Test-Path $ChangeComputerNameFolder)) {
    New-Item -Path $ChangeComputerNameFolder -ItemType Directory | Out-Null
}
$ChangeComputerNameFile = "C:\ProgramData\TMT\ChangeComputerName\TMTComputerName.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/ChangeComputerName/main/TMTComputerName.ps1" -OutFile $ChangeComputerNameFile
Invoke-Expression -Command $ChangeComputerNameFile

Set-ProgressStep -StepIndex 2 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[1]

# ----------------------------- STEP 3: Remove HP Bloatware ----------------------------
Set-ProgressStep -StepIndex 2 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[2]

$RemoveHPBloatwareFolder = "C:\ProgramData\TMT\RemoveHPBloatware"
if (-not (Test-Path $RemoveHPBloatwareFolder)) {
    New-Item -Path $RemoveHPBloatwareFolder -ItemType Directory | Out-Null
}
$RemoveHPBloatwareFile = "C:\ProgramData\TMT\RemoveHPBloatware\RemoveHPBloatware.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/HPBloatwareRemover/main/RemoveHPBloatware.ps1" -OutFile $RemoveHPBloatwareFile
Invoke-Expression -Command $RemoveHPBloatwareFile

Set-ProgressStep -StepIndex 3 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[2]

# ----------------------------- STEP 4: Windows Debloat --------------------------------
Set-ProgressStep -StepIndex 3 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[3]

$WindowsDebloatFolder = "C:\ProgramData\TMT\WindowsDebloat"
if (-not (Test-Path $WindowsDebloatFolder)) {
    New-Item -Path $WindowsDebloatFolder -ItemType Directory | Out-Null
}
$WindowsDebloatFile = "C:\ProgramData\TMT\WindowsDebloat\Debloat.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/WindowsBloatware/main/Debloat.ps1" -OutFile $WindowsDebloatFile
Invoke-Expression -Command $WindowsDebloatFile

Set-ProgressStep -StepIndex 4 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[3]

# ----------------------------- STEP 5: Create Shortcuts --------------------------------
Set-ProgressStep -StepIndex 4 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[4]

$PublicDesktop = "C:\Users\Public\Desktop"
Copy-Item -Path "C:\Users\$($ENV:USERNAME)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Remote Desktop.lnk" -Destination $PublicDesktop -ErrorAction SilentlyContinue
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Word.lnk"            -Destination $PublicDesktop -ErrorAction SilentlyContinue
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Excel.lnk"           -Destination $PublicDesktop -ErrorAction SilentlyContinue

Set-ProgressStep -StepIndex 5 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[4]

# ----------------------------- STEP 6: Finalizing --------------------------------------
Set-ProgressStep -StepIndex 5 -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle $Steps[5]

# Flags/files
New-Item -Path "C:\ProgramData\TMT\MasterScriptDone1.0.txt" -ItemType File -Force | Out-Null
New-Item -Path "C:\ProgramData\TMT\Done1.0.txt"             -ItemType File -Force | Out-Null
New-Item -Path "C:\Users\$($ENV:USERNAME)\AppData\MasterScriptDone1.0.txt" -ItemType File -Force | Out-Null

# Finish the bar at 100%
Set-ProgressStep -StepIndex $TotalSteps -TotalSteps $TotalSteps -Bar $ui.Bar -SubLabel $ui.Sub -StepTitle "Completed"

Start-Sleep -Seconds 1
$ui.Form.Close()

# ----------------------------- REBOOT PROMPT (BIG) ------------------------------------
$result = Show-BigMessageBox -Title "Reboot Required" -Message "The configuration is complete. Press **OK** to reboot now, or **Cancel** to reboot later." -Buttons OKCancel -TopMost

if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    Restart-Computer -Force
} else {
    # no-op
}
