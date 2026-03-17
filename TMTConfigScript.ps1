# =====================================================================
# 2025TMTconfigScript.ps1
# Runs as: SYSTEM | Silent — communicates progress via registry
# =====================================================================

# ----- Paths & Registry -----
$RegBase  = "HKLM:\SOFTWARE\TMT"
$TMTDir   = "C:\ProgramData\TMT"
$PubDesk  = "C:\Users\Public\Desktop"

# ----- Registry Helpers -----
function Get-Reg([string]$Name) {
    try { return (Get-ItemProperty -Path $RegBase -Name $Name -ErrorAction Stop).$Name }
    catch { return $null }
}

function Set-Reg([string]$Name, $Value) {
    if (-not (Test-Path $RegBase)) { New-Item -Path $RegBase -Force | Out-Null }
    Set-ItemProperty -Path $RegBase -Name $Name -Value $Value
}

function Write-Step([int]$n, [string]$label) {
    Set-Reg "ConfigStep"       $n
    Set-Reg "ConfigStepLabel"  $label
    Write-Host "[Step $n] $label"
}

# =====================================================================
# EARLY EXIT — New registry flag
# =====================================================================
if ((Get-Reg "ConfigComplete") -eq 1) {
    Write-Host "ConfigComplete already set in registry. Exiting."
    exit 0
}

# =====================================================================
# EARLY EXIT — Old txt flags (production compat — silent, no prompts)
# =====================================================================
$OldFlags = @(
    "$TMTDir\MasterScriptDone1.0.txt",
    "$TMTDir\Done1.0.txt"
)
foreach ($f in $OldFlags) {
    if (Test-Path $f -PathType Leaf) {
        Write-Host "Legacy flag found: $f — marking registry and exiting silently."
        Set-Reg "ConfigComplete" 1
        exit 0
    }
}

# =====================================================================
# INIT
# =====================================================================
if (-not (Test-Path $TMTDir))  { New-Item $TMTDir -ItemType Directory | Out-Null }
if (-not (Test-Path $RegBase)) { New-Item $RegBase -Force | Out-Null }

Set-Reg "ConfigComplete"  0
Set-Reg "AppsInstalled"   0
Set-Reg "ConfigStep"      0
Set-Reg "ConfigStepLabel" "Starting"

$TotalSteps = 5

# =====================================================================
# STEP 1: Rename Computer
# =====================================================================
Write-Step 1 "Step 1/$TotalSteps Rename Computer"

$dir  = "$TMTDir\ChangeComputerName"
$file = "$dir\TMTComputerName.ps1"
if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory | Out-Null }
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/ChangeComputerName/main/TMTComputerName.ps1" -OutFile $file
& $file

# =====================================================================
# STEP 2: Remove HP Bloatware
# =====================================================================
Write-Step 2 "Step 2/$TotalSteps Remove HP Bloatware"

$dir  = "$TMTDir\RemoveHPBloatware"
$file = "$dir\RemoveHPBloatware.ps1"
if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory | Out-Null }
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/HPBloatwareRemover/main/RemoveHPBloatware.ps1" -OutFile $file
& $file

# =====================================================================
# STEP 3: Remove Windows Bloatware
# =====================================================================
Write-Step 3 "Step 3/$TotalSteps Remove Windows Bloatware"

$dir  = "$TMTDir\WindowsDebloat"
$file = "$dir\Debloat.ps1"
if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory | Out-Null }
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/WindowsBloatware/main/Debloat.ps1" -OutFile $file
& $file

# =====================================================================
# STEP 4: Wait for All Applications
# =====================================================================
Write-Step 4 "Step 4/$TotalSteps Waiting for Applications"

function Test-AllApps {
    $chrome  = Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe"

    $adobe   = (Test-Path "C:\Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe") -or
               (Test-Path "C:\Program Files (x86)\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe")

    $outlook = $null -ne (Get-AppxPackage -AllUsers -Name "Microsoft.OutlookForWindows" -ErrorAction SilentlyContinue)

    $teams   = $null -ne (Get-AppxPackage -AllUsers -Name "MSTeams" -ErrorAction SilentlyContinue)

    $winApp  = $null -ne (Get-AppxPackage -AllUsers -Name "MicrosoftCorporationII.Windows365" -ErrorAction SilentlyContinue)

    $word    = (Test-Path "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE") -or
               (Test-Path "C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE")

    $excel   = (Test-Path "C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE") -or
               (Test-Path "C:\Program Files (x86)\Microsoft Office\root\Office16\EXCEL.EXE")

    return ($chrome -and $adobe -and $outlook -and $teams -and $winApp -and $word -and $excel)
}

# Poll every 60 seconds until all apps are confirmed
while (-not (Test-AllApps)) {
    Write-Host "$(Get-Date -Format 'HH:mm:ss') — Apps not ready yet. Checking again in 60s…"
    Start-Sleep -Seconds 60
}

Set-Reg "AppsInstalled" 1
Write-Host "All applications confirmed installed."

# =====================================================================
# STEP 5: Create Desktop Shortcuts
# =====================================================================
Write-Step 5 "Step 5/$TotalSteps Creating Shortcuts"

$WS = New-Object -ComObject WScript.Shell

# Word — copy from Start Menu
Copy-Item "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Word.lnk"  $PubDesk -ErrorAction SilentlyContinue

# Excel — copy from Start Menu
Copy-Item "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Excel.lnk" $PubDesk -ErrorAction SilentlyContinue

# New Outlook (UWP)
$sc = $WS.CreateShortcut("$PubDesk\Outlook.lnk")
$sc.TargetPath = "shell:AppsFolder\Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookForWindows"
$sc.Save()

# Microsoft Teams (UWP)
$sc = $WS.CreateShortcut("$PubDesk\MS Teams.lnk")
$sc.TargetPath = "shell:AppsFolder\MSTeams_8wekyb3d8bbwe!MSTeams"
$sc.Save()

# TMT Workspace / Windows App (UWP)
$sc = $WS.CreateShortcut("$PubDesk\TMT Workspace.lnk")
$sc.TargetPath = "shell:AppsFolder\MicrosoftCorporationII.Windows365_8wekyb3d8bbwe!Windows365"
$sc.Save()

# =====================================================================
# FINALIZE
# =====================================================================
Write-Step $TotalSteps "Completed"
Set-Reg "ConfigComplete" 1
Write-Host "TMT configuration complete."
exit 0