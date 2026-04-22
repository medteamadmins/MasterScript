# =====================================================================
# Purpose : THE MEDICAL TEAM - Standard Computers Configuration
# Runs as : SYSTEM — silent, writes all progress to registry
# Timeout : 24 hours
# =====================================================================

# Allow child .ps1 files to execute in this process only (safe; not machine-wide)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$RegBase   = "HKLM:\SOFTWARE\TMT\Standard"
$TMTDir    = "C:\ProgramData\TMT\Standard"
$PubDesk   = "C:\Users\Public\Desktop"
$Timeout   = 86400   # 24 hours in seconds
$StartTime = Get-Date

# =====================================================================
# REGISTRY HELPERS
# =====================================================================
function Ensure-RegKey {
    if (-not (Test-Path $RegBase)) {
        New-Item -Path $RegBase -Force | Out-Null
    }
}

function Set-Reg {
    param([string]$Name, $Value)
    Ensure-RegKey
    Set-ItemProperty -Path $RegBase -Name $Name -Value $Value
}

function Get-Reg {
    param([string]$Name)
    try { return (Get-ItemProperty -Path $RegBase -Name $Name -ErrorAction Stop).$Name }
    catch { return $null }
}

function Write-Step {
    param([int]$StepNum, [string]$Label, [string]$Detail = "")
    Set-Reg "ConfigStep"        $StepNum
    Set-Reg "ConfigStepLabel"   $Label
    Set-Reg "ConfigStepDetail"  $Detail
    Set-Reg "LastUpdated"       (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [Step $StepNum] $Label $(if ($Detail) { "— $Detail" })"
}

function Write-Detail {
    param([string]$Detail)
    Set-Reg "ConfigStepDetail" $Detail
    Set-Reg "LastUpdated"      (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Write-Host "    > $(Get-Date -Format 'HH:mm:ss') $Detail"
}

function Fail-Out {
    param([string]$Reason)
    Set-Reg "ConfigFailed"   1
    Set-Reg "ConfigError"    $Reason
    Set-Reg "ConfigComplete" 0
    Write-Host "FATAL: $Reason"
    exit 1
}

function Test-Timeout {
    $elapsed = (Get-Date) - $StartTime
    if ($elapsed.TotalSeconds -ge $Timeout) {
        Fail-Out "Script timed out after 24 hours. Last step: $(Get-Reg 'ConfigStepLabel')"
    }
}

function Invoke-Step {
    param(
        [string]$StepName,
        [string]$Url,
        [string]$OutFile
    )

    $dir = Split-Path $OutFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory | Out-Null
    }

    # Download — retry up to 3 times
    $downloaded = $false
    for ($i = 1; $i -le 3; $i++) {
        Test-Timeout
        try {
            Write-Detail "$StepName — Downloading (attempt $i/3)"
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            $downloaded = $true
            Write-Detail "$StepName — Download complete"
            break
        } catch {
            Write-Detail "$StepName — Download attempt $i failed: $_"
            if ($i -lt 3) { Start-Sleep -Seconds 10 }
        }
    }

    if (-not $downloaded) {
        Set-Reg "ConfigError" "$StepName download failed after 3 attempts"
        Write-Detail "$StepName — All download attempts failed, continuing to next step"
        return $false
    }

    # Execute via spawned PowerShell with ExecutionPolicy Bypass
    try {
        Write-Detail "$StepName — Executing"
        $proc = Start-Process -FilePath "powershell.exe" `
                              -ArgumentList @(
                                  "-NoProfile",
                                  "-ExecutionPolicy","Bypass",
                                  "-File", $OutFile
                              ) `
                              -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            Write-Detail "$StepName — Exited with code $($proc.ExitCode)"
        } else {
            Write-Detail "$StepName — Completed successfully"
        }
        return $true
    } catch {
        Set-Reg "ConfigError" "$StepName execution failed: $_"
        Write-Detail "$StepName — Execution failed: $_"
        return $false
    }
}

# =====================================================================
# EARLY EXIT — Already complete (registry)
# =====================================================================
if ((Get-Reg "ConfigComplete") -eq 1) {
    Write-Host "ConfigComplete already set — exiting."
    exit 0
}

# =====================================================================
# EARLY EXIT — Legacy txt flags (silent, no prompts)
# =====================================================================
$LegacyFlags = @(
    "C:\ProgramData\TMT\MasterScriptDone1.0.txt",
    "C:\ProgramData\TMT\Done1.0.txt",
    "C:\Users\$ENV:USERNAME\AppData\Done1.0.txt",
    "C:\Users\$ENV:USERNAME\AppData\MasterScriptDone1.0.txt"
)
foreach ($f in $LegacyFlags) {
    if (Test-Path $f -PathType Leaf) {
        Write-Host "Legacy flag found: $f — marking done and exiting silently."
        Ensure-RegKey
        Set-Reg "ConfigComplete" 1
        exit 0
    }
}

# =====================================================================
# INIT
# =====================================================================
if (-not (Test-Path $TMTDir)) { New-Item $TMTDir -ItemType Directory | Out-Null }
Ensure-RegKey

Set-Reg "ConfigComplete"    0
Set-Reg "ConfigFailed"      0
Set-Reg "ConfigError"       ""
Set-Reg "AppsInstalled"     0
Set-Reg "AppsReady"         0
Set-Reg "AppsTotal"         0
Set-Reg "AppsMissing"       ""
Set-Reg "AppsReadyList"     ""
Set-Reg "ConfigStep"        0
Set-Reg "ConfigStepLabel"   "Initializing"
Set-Reg "ConfigStepDetail"  "Starting configuration"
Set-Reg "ScriptStartTime"   (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Set-Reg "LastUpdated"       (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

$TotalSteps = 5

Write-Host "Config Script started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# =====================================================================
# STEP 1: Rename Computer
# =====================================================================
Write-Step 1 "Step 1/$TotalSteps Rename Computer" "Preparing"

Invoke-Step `
    -StepName "Rename Computer" `
    -Url      "https://raw.githubusercontent.com/medteamadmins/ChangeComputerName/refs/heads/main/TMTComputerName.ps1" `
    -OutFile  "$TMTDir\ChangeComputerName\TMTComputerName.ps1"


# =====================================================================
# STEP 2: Remove HP Bloatware
# =====================================================================
Write-Step 2 "Step 2/$TotalSteps Remove HP Bloatware" "Preparing"

Invoke-Step `
    -StepName "HP Bloatware Removal" `
    -Url      "https://raw.githubusercontent.com/medteamadmins/HPBloatwareRemover/main/RemoveHPBloatware.ps1" `
    -OutFile  "$TMTDir\RemoveHPBloatware\RemoveHPBloatware.ps1"


# =====================================================================
# STEP 3: Remove Windows Bloatware
# =====================================================================
Write-Step 3 "Step 3/$TotalSteps Remove Windows Bloatware" "Preparing"

Invoke-Step `
    -StepName "Windows Debloat" `
    -Url      "https://raw.githubusercontent.com/medteamadmins/WindowsBloatware/main/Debloat.ps1" `
    -OutFile  "$TMTDir\WindowsDebloat\Debloat.ps1"


# =====================================================================
# STEP 4: Wait for All Applications
# =====================================================================
Write-Step 4 "Step 4/$TotalSteps Waiting for Applications" "Checking installed apps"

function Test-App {
    param([string[]]$Paths, [string]$AppxName = "")
    foreach ($p in $Paths) {
        if ($p -and (Test-Path $p)) { return $true }
    }
    if ($AppxName) {
        $pkg = Get-AppxPackage -AllUsers -Name $AppxName -ErrorAction SilentlyContinue
        if ($null -ne $pkg) { return $true }
    }
    return $false
}

function Get-AppStatus {
    return [ordered]@{
        "Google Chrome" = Test-App -Paths @(
                              "C:\Users\Public\Desktop\Google Chrome.lnk"
                          )
        "Adobe Acrobat" = Test-App -Paths @(
                              "C:\Users\Public\Desktop\Adobe Acrobat.lnk"
                          )
    }
}

$checkInterval = 60   # seconds between app checks

while ($true) {
    Test-Timeout

    $status      = Get-AppStatus
    $readyCount  = ($status.Values | Where-Object { $_ -eq $true }).Count
    $totalApps   = $status.Count
    $missingList = ($status.GetEnumerator() | Where-Object { $_.Value -eq $false }).Name -join ", "
    $readyList   = ($status.GetEnumerator() | Where-Object { $_.Value -eq $true  }).Name -join ", "

    Set-Reg "AppsTotal"     $totalApps
    Set-Reg "AppsReady"     $readyCount
    Set-Reg "AppsMissing"   $(if ($missingList) { $missingList } else { "None" })
    Set-Reg "AppsReadyList" $(if ($readyList)   { $readyList   } else { "None" })
    Set-Reg "LastUpdated"   (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

    Write-Detail "$readyCount/$totalApps apps ready — Missing: $(if ($missingList) { $missingList } else { 'None' })"

    if ($readyCount -eq $totalApps) {
        Set-Reg "AppsInstalled" 1
        Write-Detail "All $totalApps applications confirmed installed — proceeding to shortcuts"
        break
    }

    # Wait in small increments so timeout check stays responsive
    $waited = 0
    while ($waited -lt $checkInterval) {
        Start-Sleep -Seconds 10
        $waited += 10
        Test-Timeout
    }
}

# =====================================================================
# STEP 5: Create Desktop Shortcuts
# =====================================================================
Write-Step 5 "Step 5/$TotalSteps Creating Desktop Shortcuts" "Building .lnk files on Public Desktop"

$PublicDesktop = "C:\Users\Public\Desktop"

# Office click-to-run shortcuts (already produced by Office installer)
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Word.lnk"  -Destination $PublicDesktop -ErrorAction SilentlyContinue
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Excel.lnk" -Destination $PublicDesktop -ErrorAction SilentlyContinue

# AppsFolder (UWP / packaged app) shortcuts — must target explorer.exe
$WScriptShell = New-Object -ComObject WScript.Shell

function New-AppsFolderShortcut {
    param(
        [string]$Name,
        [string]$AppLink
    )
    try {
        $sc = $WScriptShell.CreateShortcut("$PublicDesktop\$Name.lnk")
        $sc.TargetPath = "C:\Windows\explorer.exe"
        $sc.Arguments  = "shell:AppsFolder\$AppLink"
        $sc.Save()
        Write-Detail "Shortcut created: $Name"
    } catch {
        Write-Detail "Shortcut FAILED for $Name : $_"
    }
}

New-AppsFolderShortcut -Name "Outlook"       -AppLink "Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookForWindows"
New-AppsFolderShortcut -Name "MS Teams"      -AppLink "MSTeams_8wekyb3d8bbwe!MSTeams"
New-AppsFolderShortcut -Name "TMT Workspace" -AppLink "MicrosoftCorporationII.Windows365_8wekyb3d8bbwe!Windows365"

# =====================================================================
# FINALIZE
# =====================================================================
Set-Reg "ConfigStep"       $TotalSteps
Set-Reg "ConfigStepLabel"  "Completed"
Set-Reg "ConfigStepDetail" "Computer set up finished successfully"
Set-Reg "ConfigComplete"   1
Set-Reg "LastUpdated"      (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Write-Host "TMT Master Script completed successfully at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
exit 0
