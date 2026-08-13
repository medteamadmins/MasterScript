#requires -Version 5.1
<#
.SYNOPSIS
    THE MEDICAL TEAM standard computer configuration orchestrator.

.DESCRIPTION
    Deploy this script from Microsoft Intune in SYSTEM context. The Intune
    invocation installs this script under ProgramData, registers a recurring
    SYSTEM scheduled task, starts the task, and exits promptly. The scheduled
    worker performs the long-running configuration outside the Intune platform
    script time limit and publishes a machine-readable state contract under:

        HKLM\SOFTWARE\TMT\Standard  (64-bit registry view)

    The companion user-context monitor reads that state but never needs write
    access to HKLM.

.NOTES
    Script version : 2.1.1
    PowerShell     : Windows PowerShell 5.1 or later
    Deployment     : Intune, Run using logged-on credentials = No
#>

[CmdletBinding()]
param(
    [switch]$Worker,
    [switch]$Reset
)

# Capture the original invocation before entering strict mode. Intune normally
# invokes a physical .ps1 file, but some execution wrappers run the payload as
# a ScriptBlock and leave $PSCommandPath empty. Retaining the parsed ScriptBlock
# allows the persistent SYSTEM worker to be materialized in either case.
$script:InitialInvocation = $MyInvocation
$script:InitialScriptPath = $null
$script:InitialCommandPath = $null
$script:InitialScriptText = $null

try {
    $pathVariable = Get-Variable -Name PSCommandPath -ValueOnly -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace([string]$pathVariable)) {
        $script:InitialScriptPath = [string]$pathVariable
    }
}
catch {
    # The ScriptBlock fallback below remains available.
}

try {
    if ([string]::IsNullOrWhiteSpace($script:InitialScriptPath) -and
        -not [string]::IsNullOrWhiteSpace([string]$script:InitialInvocation.PSCommandPath)) {
        $script:InitialScriptPath = [string]$script:InitialInvocation.PSCommandPath
    }
}
catch {
    # Not every host exposes PSCommandPath through InvocationInfo.
}

try {
    $commandPath = [string]$script:InitialInvocation.MyCommand.Path
    if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
        $script:InitialCommandPath = $commandPath
    }
}
catch {
    # ScriptBlock-backed commands do not necessarily expose a Path property.
}

try {
    $initialScriptBlock = $script:InitialInvocation.MyCommand.ScriptBlock
    if ($null -ne $initialScriptBlock -and $null -ne $initialScriptBlock.Ast) {
        $script:InitialScriptText = [string]$initialScriptBlock.Ast.Extent.Text
    }
}
catch {
    # A physical source file can still be copied when available.
}

if ([string]::IsNullOrWhiteSpace($script:InitialScriptText)) {
    try {
        $commandDefinition = [string]$script:InitialInvocation.MyCommand.Definition
        if (-not [string]::IsNullOrWhiteSpace($commandDefinition) -and
            $commandDefinition.Contains('function Invoke-Worker')) {
            $script:InitialScriptText = $commandDefinition
        }
    }
    catch {
        # Installation reports a precise error if neither source is usable.
    }
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -----------------------------------------------------------------------------
# Configuration constants
# -----------------------------------------------------------------------------
$script:ConfigVersion = '2.1.1'
$script:SchemaVersion = 4
$script:TotalSteps = 5
$script:RegistrySubKey = 'SOFTWARE\TMT\Standard'
$script:RootDirectory = Join-Path $env:ProgramData 'TMT'
$script:LogDirectory = Join-Path $script:RootDirectory 'Logs'
$script:DownloadDirectory = Join-Path $script:RootDirectory 'Downloads'
$script:InstalledScript = Join-Path $script:RootDirectory 'Computer-StandardConfig-System.ps1'
$script:LogPath = Join-Path $script:LogDirectory 'StandardConfig.log'
$script:TaskName = 'TMT-StandardComputerConfiguration'
$script:ProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
if ([string]::IsNullOrWhiteSpace($script:ProgramFilesX86)) {
    $script:ProgramFilesX86 = $env:ProgramFiles
}
$script:MutexName = 'Global\TMT.StandardComputerConfiguration.Worker'
$script:WorkerIntervalMinutes = 5
$script:ConfigurationDeadlineHours = 24
$script:MaximumConsecutiveFailures = 3
$script:StepProgressCeiling = 95

# Packaged-app identities used for stable desktop shortcuts. These values are
# intentionally centralized so creation and verification cannot drift apart.
$script:OutlookPackageName = 'Microsoft.OutlookForWindows'
$script:OutlookAppUserModelId = 'Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookForWindows'
$script:TeamsPackageName = 'MSTeams'
$script:TeamsAppUserModelId = 'MSTeams_8wekyb3d8bbwe!MSTeams'

# The original Windows debloat wrapper only downloaded and launched this script.
# Calling the approved upstream script directly removes one unreliable wrapper
# layer. The dependency is pinned to an immutable commit and SHA256 so upstream
# changes cannot silently alter the production build.
$script:WindowsDebloatVersion = '5.5.14'
$script:WindowsDebloatCommit = '1d2eddcf4d2983b5ee0ce1a61b238f4e45f4db3f'
$script:WindowsDebloatUrl = "https://raw.githubusercontent.com/andrew-s-taylor/public/$script:WindowsDebloatCommit/De-Bloat/RemoveBloat.ps1"
$script:WindowsDebloatExpectedSha256 = '69B3B3DB1E1ED9D74ECF53D619145D4C6990641435B77BDF39C89C924A1A6E97'

# -----------------------------------------------------------------------------
# Generic helpers
# -----------------------------------------------------------------------------
function Ensure-Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScheduledTaskPowerShellPath {
    # Task Scheduler is a native service, so use the physical System32 path.
    return (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Get-NativeWindowsPowerShellPath {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return (Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe')
    }

    return (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function ConvertTo-Int32 {
    [CmdletBinding()]
    param(
        $Value,
        [int]$Default = 0
    )

    $parsed = 0
    if ($null -ne $Value -and [int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function Test-RetryUntilDeadlineException {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        try {
            if ($current.Data['TMT.RetryUntilDeadline'] -eq $true) {
                return $true
            }
        }
        catch {
            # Continue through the inner-exception chain.
        }

        $current = $current.InnerException
    }

    return $false
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f ([DateTime]::UtcNow.ToString('o')), $Level, $Message
    Write-Host $line

    try {
        Ensure-Directory -Path $script:LogDirectory
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch {
        Write-Host "Unable to write to log file '$script:LogPath': $($_.Exception.Message)"
    }
}


function Install-CurrentScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DestinationPath)

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    Ensure-Directory -Path $destinationDirectory
    $destinationFullPath = [IO.Path]::GetFullPath($DestinationPath)

    $candidatePaths = @(
        $script:InitialScriptPath,
        $script:InitialCommandPath
    ) | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    } | Select-Object -Unique

    foreach ($candidatePath in $candidatePaths) {
        try {
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                continue
            }

            $sourceFullPath = [IO.Path]::GetFullPath([string]$candidatePath)
            if ($sourceFullPath -ine $destinationFullPath) {
                Copy-Item -LiteralPath $sourceFullPath -Destination $destinationFullPath -Force
            }

            if (Test-Path -LiteralPath $destinationFullPath -PathType Leaf) {
                Write-Log -Message "Installed persistent worker script from '$sourceFullPath'."
                return
            }
        }
        catch {
            Write-Log -Level WARN -Message "Unable to install the worker from candidate path '$candidatePath': $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:InitialScriptText)) {
        $utf8WithoutBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        [IO.File]::WriteAllText(
            $destinationFullPath,
            $script:InitialScriptText,
            $utf8WithoutBom
        )

        if (-not (Test-Path -LiteralPath $destinationFullPath -PathType Leaf) -or
            (Get-Item -LiteralPath $destinationFullPath).Length -le 0) {
            throw "The worker ScriptBlock was captured, but '$destinationFullPath' was not written successfully."
        }

        Write-Log -Message 'Installed persistent worker script from the captured Intune ScriptBlock because no physical source path was available.'
        return
    }

    throw "Unable to install the persistent worker at '$destinationFullPath'. The host supplied neither a readable script path nor recoverable ScriptBlock text."
}

# -----------------------------------------------------------------------------
# Explicit 64-bit registry state contract
# -----------------------------------------------------------------------------
function Get-RegistryView {
    if ([Environment]::Is64BitOperatingSystem) {
        return [Microsoft.Win32.RegistryView]::Registry64
    }

    return [Microsoft.Win32.RegistryView]::Registry32
}

function Set-StateValues {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        (Get-RegistryView)
    )

    try {
        $stateKey = $baseKey.CreateSubKey(
            $script:RegistrySubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
        )

        if ($null -eq $stateKey) {
            throw "Unable to create or open HKLM\$script:RegistrySubKey."
        }

        try {
            foreach ($entry in $Values.GetEnumerator()) {
                $value = $entry.Value
                $kind = [Microsoft.Win32.RegistryValueKind]::String

                if ($null -eq $value) {
                    $value = ''
                }
                elseif ($value -is [bool]) {
                    $value = [int]$value
                    $kind = [Microsoft.Win32.RegistryValueKind]::DWord
                }
                elseif (
                    $value -is [byte] -or
                    $value -is [int16] -or
                    $value -is [uint16] -or
                    $value -is [int32]
                ) {
                    $value = [int]$value
                    $kind = [Microsoft.Win32.RegistryValueKind]::DWord
                }
                elseif ($value -is [int64]) {
                    $kind = [Microsoft.Win32.RegistryValueKind]::QWord
                }
                else {
                    $value = [string]$value
                }

                $stateKey.SetValue([string]$entry.Key, $value, $kind)
            }
        }
        finally {
            $stateKey.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Update-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)

    $copy = @{}
    foreach ($entry in $Values.GetEnumerator()) {
        $copy[[string]$entry.Key] = $entry.Value
    }

    $copy['LastUpdatedUtc'] = [DateTime]::UtcNow.ToString('o')
    Set-StateValues -Values $copy
}

function Get-StateValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        (Get-RegistryView)
    )

    try {
        $stateKey = $baseKey.OpenSubKey($script:RegistrySubKey, $false)
        if ($null -eq $stateKey) {
            return $Default
        }

        try {
            return $stateKey.GetValue(
                $Name,
                $Default,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
        }
        finally {
            $stateKey.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Get-StateSnapshot {
    [CmdletBinding()]
    param()

    $result = @{}
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        (Get-RegistryView)
    )

    try {
        $stateKey = $baseKey.OpenSubKey($script:RegistrySubKey, $false)
        if ($null -eq $stateKey) {
            return $result
        }

        try {
            foreach ($name in $stateKey.GetValueNames()) {
                $result[$name] = $stateKey.GetValue(
                    $name,
                    $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                )
            }
        }
        finally {
            $stateKey.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }

    return $result
}

function Remove-StateKey {
    [CmdletBinding()]
    param()

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        (Get-RegistryView)
    )

    try {
        $baseKey.DeleteSubKeyTree($script:RegistrySubKey, $false)
    }
    finally {
        $baseKey.Dispose()
    }
}

function Set-MachineRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][Microsoft.Win32.RegistryValueKind]$Kind
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        (Get-RegistryView)
    )

    try {
        $key = $baseKey.CreateSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
        )

        if ($null -eq $key) {
            throw "Unable to create or open HKLM\$SubKey."
        }

        try {
            $key.SetValue($Name, $Value, $Kind)
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Add-ConfigurationWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    $existing = [string](Get-StateValue -Name 'ConfigWarnings' -Default '')
    $items = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        foreach ($item in ($existing -split '\s*\|\s*')) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $items.Add($item.Trim()) | Out-Null
            }
        }
    }

    if (-not $items.Contains($Message)) {
        $items.Add($Message) | Out-Null
    }

    Update-State -Values @{ ConfigWarnings = ($items -join ' | ') }
}

# -----------------------------------------------------------------------------
# Scheduled worker management
# -----------------------------------------------------------------------------
function Remove-WorkerTask {
    [CmdletBinding()]
    param([switch]$StopRunning)

    try {
        $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            return
        }

        if ($StopRunning -and [string]$task.State -eq 'Running') {
            try {
                Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
                $stopDeadline = (Get-Date).AddSeconds(30)
                do {
                    Start-Sleep -Milliseconds 500
                    $task = Get-ScheduledTask `
                        -TaskName $script:TaskName `
                        -ErrorAction SilentlyContinue
                } while (
                    $null -ne $task -and
                    [string]$task.State -eq 'Running' -and
                    (Get-Date) -lt $stopDeadline
                )

                if ($null -ne $task -and [string]$task.State -eq 'Running') {
                    throw "Scheduled task '$script:TaskName' did not stop within 30 seconds."
                }
            }
            catch {
                Write-Log -Level WARN -Message "Unable to stop scheduled task '$script:TaskName': $($_.Exception.Message)"
                throw
            }
        }

        Unregister-ScheduledTask `
            -TaskName $script:TaskName `
            -Confirm:$false `
            -ErrorAction Stop
        Write-Log -Message "Removed scheduled task '$script:TaskName'."
    }
    catch {
        Write-Log -Level WARN -Message "Unable to remove scheduled task '$script:TaskName': $($_.Exception.Message)"
        if ($StopRunning) {
            throw
        }
    }
}

function Register-WorkerTask {
    [CmdletBinding()]
    param()

    $powerShellPath = Get-ScheduledTaskPowerShellPath
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script:InstalledScript`" -Worker"

    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
    $trigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Minutes $script:WorkerIntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Hours ($script:ConfigurationDeadlineHours + 1))

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4)

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'THE MEDICAL TEAM standard computer configuration worker.'

    Register-ScheduledTask `
        -TaskName $script:TaskName `
        -InputObject $task `
        -Force `
        -ErrorAction Stop | Out-Null

    try {
        Start-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
        Write-Log -Message "Registered and started scheduled task '$script:TaskName'."
    }
    catch {
        $registeredTask = Get-ScheduledTask `
            -TaskName $script:TaskName `
            -ErrorAction SilentlyContinue
        $taskState = if ($null -ne $registeredTask) {
            [string]$registeredTask.State
        }
        else {
            ''
        }

        # Starting an already-running task is benign; every other failure is not.
        if ($taskState -ne 'Running') {
            throw
        }

        Write-Log -Message "Scheduled task '$script:TaskName' is already running."
    }
}

# -----------------------------------------------------------------------------
# Process and download helpers
# -----------------------------------------------------------------------------
function Invoke-ProcessWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [ValidateRange(1, 240)][int]$TimeoutMinutes = 30,
        [int[]]$AcceptedExitCodes = @(0),
        [string]$Activity = 'Process'
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf) -and
        -not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        throw "Executable not found: $FilePath"
    }

    Write-Log -Message "$Activity starting: $FilePath $Arguments"
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $Arguments `
        -WindowStyle Hidden `
        -PassThru

    $started = Get-Date
    while (-not $process.HasExited) {
        Start-Sleep -Seconds 10
        $process.Refresh()

        $elapsed = (Get-Date) - $started
        Update-State -Values @{
            ConfigStepDetail = "$Activity is running ($([int]$elapsed.TotalMinutes)m elapsed)"
            WorkerHeartbeatUtc = [DateTime]::UtcNow.ToString('o')
        }

        if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
            try {
                $process.Kill()
            }
            catch {
                Write-Log -Level WARN -Message "Unable to terminate timed-out process $($process.Id): $($_.Exception.Message)"
            }

            throw "$Activity exceeded its $TimeoutMinutes minute timeout."
        }
    }

    $exitCode = $process.ExitCode
    Write-Log -Message "$Activity exited with code $exitCode."

    if ($AcceptedExitCodes -notcontains $exitCode) {
        throw "$Activity failed with exit code $exitCode."
    }

    if ($exitCode -in @(1641, 3010)) {
        Update-State -Values @{
            RestartRequired = 1
            RestartRequiredSinceUtc = [DateTime]::UtcNow.ToString('o')
        }
    }

    return $exitCode
}

function Invoke-CommandLineWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [ValidateRange(1, 120)][int]$TimeoutMinutes = 20,
        [int[]]$AcceptedExitCodes = @(0, 1605, 1614, 1641, 3010),
        [string]$Activity = 'Uninstaller'
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    $executable = ''
    $arguments = ''

    if ($expanded -match '^\s*"([^"]+)"\s*(.*)$') {
        $executable = $Matches[1]
        $arguments = $Matches[2]
    }
    elseif ($expanded -match '^\s*(.+?\.(?:exe|com|cmd|bat))(?=\s|$)\s*(.*)$') {
        # Some vendors publish an invalid, unquoted executable path containing
        # spaces. Capture through the executable extension before falling back
        # to first-token parsing.
        $executable = $Matches[1].Trim().Trim('"')
        $arguments = $Matches[2]
    }
    elseif ($expanded -match '^\s*([^\s]+)\s*(.*)$') {
        $executable = $Matches[1]
        $arguments = $Matches[2]
    }
    else {
        throw "Unable to parse command line: $CommandLine"
    }

    return Invoke-ProcessWithTimeout `
        -FilePath $executable `
        -Arguments $arguments `
        -TimeoutMinutes $TimeoutMinutes `
        -AcceptedExitCodes $AcceptedExitCodes `
        -Activity $Activity
}

function Invoke-DownloadFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [string]$ExpectedSha256 = '',
        [ValidateRange(1, 10)][int]$Attempts = 3
    )

    Ensure-Directory -Path (Split-Path -Path $Destination -Parent)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $temporaryPath = "$Destination.download"
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Write-Log -Message "Downloading $Uri (attempt $attempt of $Attempts)."
            Invoke-WebRequest `
                -Uri $Uri `
                -OutFile $temporaryPath `
                -UseBasicParsing `
                -Headers @{ 'Cache-Control' = 'no-cache' } `
                -ErrorAction Stop

            $file = Get-Item -LiteralPath $temporaryPath -ErrorAction Stop
            if ($file.Length -lt 100) {
                throw "Downloaded file is unexpectedly small ($($file.Length) bytes)."
            }

            $hash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToUpperInvariant()
            Write-Log -Message "Downloaded SHA256: $hash"

            if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and
                $hash -ne $ExpectedSha256.Trim().ToUpperInvariant()) {
                throw "SHA256 validation failed. Expected $ExpectedSha256; received $hash."
            }

            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $temporaryPath -Destination $Destination -Force
            return $hash
        }
        catch {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            Write-Log -Level WARN -Message "Download attempt $attempt failed: $($_.Exception.Message)"

            if ($attempt -eq $Attempts) {
                $downloadException = $_.Exception
                $failureMessage = $downloadException.Message
                $isPermanentFailure = $failureMessage -like 'SHA256 validation failed*'

                try {
                    if ($null -ne $downloadException.Response -and
                        $null -ne $downloadException.Response.StatusCode) {
                        $httpStatus = [int]$downloadException.Response.StatusCode
                        if ($httpStatus -in @(400, 401, 403, 404)) {
                            $isPermanentFailure = $true
                        }
                    }
                }
                catch {
                    # Not every download exception exposes an HTTP response.
                }

                if ($isPermanentFailure) {
                    throw
                }

                $retryException = [System.InvalidOperationException]::new(
                    "Download remained unavailable after $Attempts attempts: $failureMessage",
                    $downloadException
                )
                $retryException.Data['TMT.RetryUntilDeadline'] = $true
                throw $retryException
            }

            Start-Sleep -Seconds (10 * $attempt)
        }
    }
}

function Test-PowerShellSyntax {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "Downloaded PowerShell script failed syntax validation: $messages"
    }
}

function Invoke-RemotePowerShellScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$LocalPath,
        [string]$ExpectedSha256 = '',
        [ValidateRange(1, 180)][int]$TimeoutMinutes = 75
    )

    $hash = Invoke-DownloadFile `
        -Uri $Uri `
        -Destination $LocalPath `
        -ExpectedSha256 $ExpectedSha256

    Test-PowerShellSyntax -Path $LocalPath

    $powerShellPath = Get-NativeWindowsPowerShellPath
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$LocalPath`""

    $exitCode = Invoke-ProcessWithTimeout `
        -FilePath $powerShellPath `
        -Arguments $arguments `
        -TimeoutMinutes $TimeoutMinutes `
        -AcceptedExitCodes @(0, 1641, 3010) `
        -Activity $Name

    return [pscustomobject]@{
        ExitCode = $exitCode
        Sha256 = $hash
    }
}

# -----------------------------------------------------------------------------
# Application and uninstall inventory
# -----------------------------------------------------------------------------
function Get-UninstallEntries {
    [CmdletBinding()]
    param()

    $entries = New-Object System.Collections.Generic.List[object]
    $views = @([Microsoft.Win32.RegistryView]::Registry32)
    if ([Environment]::Is64BitOperatingSystem) {
        $views = @(
            [Microsoft.Win32.RegistryView]::Registry64,
            [Microsoft.Win32.RegistryView]::Registry32
        )
    }

    foreach ($view in $views) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $view
        )

        try {
            $root = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', $false)
            if ($null -eq $root) {
                continue
            }

            try {
                foreach ($subKeyName in $root.GetSubKeyNames()) {
                    $subKey = $root.OpenSubKey($subKeyName, $false)
                    if ($null -eq $subKey) {
                        continue
                    }

                    try {
                        $displayName = [string]$subKey.GetValue('DisplayName', '')
                        if ([string]::IsNullOrWhiteSpace($displayName)) {
                            continue
                        }

                        $uninstallString = [string]$subKey.GetValue('UninstallString', '')
                        $quietUninstallString = [string]$subKey.GetValue('QuietUninstallString', '')
                        $windowsInstaller = ConvertTo-Int32 -Value $subKey.GetValue('WindowsInstaller', 0)
                        $productCode = ''

                        if ($subKeyName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                            $productCode = $subKeyName
                        }
                        elseif ($uninstallString -match '\{[0-9A-Fa-f-]{36}\}') {
                            $productCode = $Matches[0]
                        }

                        $entries.Add([pscustomobject]@{
                            DisplayName = $displayName
                            DisplayVersion = [string]$subKey.GetValue('DisplayVersion', '')
                            InstallLocation = [string]$subKey.GetValue('InstallLocation', '')
                            DisplayIcon = [string]$subKey.GetValue('DisplayIcon', '')
                            UninstallString = $uninstallString
                            QuietUninstallString = $quietUninstallString
                            WindowsInstaller = $windowsInstaller
                            ProductCode = $productCode
                            KeyName = $subKeyName
                            RegistryView = [string]$view
                        }) | Out-Null
                    }
                    finally {
                        $subKey.Dispose()
                    }
                }
            }
            finally {
                $root.Dispose()
            }
        }
        finally {
            $baseKey.Dispose()
        }
    }

    return $entries.ToArray()
}

function Find-InstalledExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$KnownPaths,
        [string[]]$SearchRoots = @(),
        [string[]]$FileNames = @()
    )

    foreach ($path in $KnownPaths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and
            (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $path
        }
    }

    foreach ($root in $SearchRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($fileName in $FileNames) {
            $match = Get-ChildItem `
                -LiteralPath $root `
                -Filter $fileName `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue | Select-Object -First 1

            if ($null -ne $match) {
                return $match.FullName
            }
        }
    }

    return $null
}

function Resolve-ChromeExecutable {
    return Find-InstalledExecutable -KnownPaths @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $script:ProgramFilesX86 'Google\Chrome\Application\chrome.exe')
    )
}

function Resolve-AdobeExecutable {
    return Find-InstalledExecutable `
        -KnownPaths @(
            (Join-Path $env:ProgramFiles 'Adobe\Acrobat DC\Acrobat\Acrobat.exe'),
            (Join-Path $env:ProgramFiles 'Adobe\Acrobat Reader DC\Reader\AcroRd32.exe'),
            (Join-Path $script:ProgramFilesX86 'Adobe\Acrobat DC\Acrobat\Acrobat.exe'),
            (Join-Path $script:ProgramFilesX86 'Adobe\Acrobat Reader DC\Reader\AcroRd32.exe')
        ) `
        -SearchRoots @(
            (Join-Path $env:ProgramFiles 'Adobe'),
            (Join-Path $script:ProgramFilesX86 'Adobe')
        ) `
        -FileNames @('Acrobat.exe', 'AcroRd32.exe')
}

function Get-PackagedAppStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$AppUserModelId,
        [string[]]$FallbackExecutableNames = @()
    )

    $package = $null
    try {
        $package = @(
            Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction SilentlyContinue |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
                Sort-Object Version -Descending
        ) | Select-Object -First 1
    }
    catch {
        Write-Log -Level WARN -Message "Unable to query package '$PackageName': $($_.Exception.Message)"
    }

    if ($null -eq $package) {
        return [pscustomobject]@{
            Ready = $false
            Executable = ''
            PackageFullName = ''
            Evidence = "Package '$PackageName' is not registered for any user"
        }
    }

    $installLocation = [string]$package.InstallLocation
    $applicationId = ''
    if ($AppUserModelId -match '!(.+)$') {
        $applicationId = $Matches[1]
    }

    $executablePath = $null
    $manifestPath = Join-Path $installLocation 'AppxManifest.xml'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
            $applications = @($manifest.Package.Applications.Application)
            $application = $applications | Where-Object {
                [string]$_.Id -eq $applicationId
            } | Select-Object -First 1

            if ($null -ne $application -and
                -not [string]::IsNullOrWhiteSpace([string]$application.Executable)) {
                $candidate = Join-Path $installLocation ([string]$application.Executable)
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $executablePath = $candidate
                }
            }
        }
        catch {
            Write-Log -Level WARN -Message "Unable to parse '$manifestPath': $($_.Exception.Message)"
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$executablePath)) {
        foreach ($fileName in $FallbackExecutableNames) {
            $match = Get-ChildItem `
                -LiteralPath $installLocation `
                -Filter $fileName `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $match) {
                $executablePath = $match.FullName
                break
            }
        }
    }

    $ready = -not [string]::IsNullOrWhiteSpace([string]$executablePath)
    return [pscustomobject]@{
        Ready = $ready
        Executable = [string]$executablePath
        PackageFullName = [string]$package.PackageFullName
        Evidence = if ($ready) {
            "Package '$($package.PackageFullName)' with executable '$executablePath'"
        }
        else {
            "Package '$($package.PackageFullName)' is installed, but its application executable could not be resolved"
        }
    }
}

function Get-RequiredApplicationStatus {
    [CmdletBinding()]
    param()

    $chromePath = Resolve-ChromeExecutable
    $adobePath = Resolve-AdobeExecutable
    $outlook = Get-PackagedAppStatus `
        -PackageName $script:OutlookPackageName `
        -AppUserModelId $script:OutlookAppUserModelId `
        -FallbackExecutableNames @('olk.exe')
    $teams = Get-PackagedAppStatus `
        -PackageName $script:TeamsPackageName `
        -AppUserModelId $script:TeamsAppUserModelId `
        -FallbackExecutableNames @('ms-teams.exe', 'msteams.exe')

    return [ordered]@{
        'Google Chrome' = [pscustomobject]@{
            Ready = -not [string]::IsNullOrWhiteSpace([string]$chromePath)
            Executable = [string]$chromePath
        }
        'Adobe Acrobat' = [pscustomobject]@{
            Ready = -not [string]::IsNullOrWhiteSpace([string]$adobePath)
            Executable = [string]$adobePath
        }
        'Microsoft Outlook' = [pscustomobject]@{
            Ready = [bool]$outlook.Ready
            Executable = [string]$outlook.Executable
        }
        'Microsoft Teams' = [pscustomobject]@{
            Ready = [bool]$teams.Ready
            Executable = [string]$teams.Executable
        }
    }
}

function Resolve-PendingRestartState {
    [CmdletBinding()]
    param()

    if ((ConvertTo-Int32 -Value (Get-StateValue -Name 'RestartRequired' -Default 0)) -ne 1) {
        return
    }

    $requiredSinceValue = [string](Get-StateValue -Name 'RestartRequiredSinceUtc' -Default '')
    $requiredSince = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($requiredSinceValue, [ref]$requiredSince)) {
        return
    }

    try {
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $bootTimeUtc = ([DateTime]$operatingSystem.LastBootUpTime).ToUniversalTime()
        if ($bootTimeUtc -gt $requiredSince.UtcDateTime.AddSeconds(30)) {
            Update-State -Values @{
                RestartRequired = 0
                RestartRequiredSinceUtc = ''
                RestartSatisfiedUtc = [DateTime]::UtcNow.ToString('o')
            }
            Write-Log -Message 'A restart occurred after the pending restart requirement; the restart state was cleared.'
        }
    }
    catch {
        Write-Log -Level WARN -Message "Unable to reconcile restart state: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# Configuration steps
# -----------------------------------------------------------------------------
function Get-StepStatusName {
    param([Parameter(Mandatory)][int]$Number)
    return ('Step{0:D2}Status' -f $Number)
}

function Get-StepProgressPercent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 99)][int]$Number,
        [switch]$Completed
    )

    $position = if ($Completed) { $Number } else { $Number - 1 }
    return [int][Math]::Floor(
        (([double]$position / [double]$script:TotalSteps) * $script:StepProgressCeiling)
    )
}

function Test-StepSucceeded {
    param([Parameter(Mandatory)][int]$Number)

    $status = [string](Get-StateValue -Name (Get-StepStatusName -Number $Number) -Default '')
    return $status -in @('Succeeded', 'SucceededWithWarnings')
}

function Invoke-ManagedStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 99)][int]$Number,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    if (Test-StepSucceeded -Number $Number) {
        Write-Log -Message "Step $Number already succeeded; skipping '$Name'."
        return
    }

    $statusName = Get-StepStatusName -Number $Number
    $messageName = ('Step{0:D2}Message' -f $Number)
    $startPercent = Get-StepProgressPercent -Number $Number
    $completePercent = Get-StepProgressPercent -Number $Number -Completed

    $startingState = @{
        ConfigState = 'Running'
        ConfigStep = $Number
        ConfigStepLabel = "Step $Number/$script:TotalSteps - $Name"
        ConfigStepDetail = 'Starting'
        ProgressPercent = $startPercent
        ConfigError = ''
    }
    $startingState[$statusName] = 'Running'
    $startingState[$messageName] = 'Starting'
    Update-State -Values $startingState

    Write-Log -Message "Step $Number/$script:TotalSteps starting: $Name"

    try {
        $result = & $Action
        if ($result -is [System.Array] -and $result.Count -gt 0) {
            $result = $result[$result.Count - 1]
        }

        $warning = ''
        if ($null -ne $result -and
            $result.PSObject.Properties.Name -contains 'Warning') {
            $warning = [string]$result.Warning
        }

        $stepStatus = 'Succeeded'
        $detail = 'Completed successfully'
        if (-not [string]::IsNullOrWhiteSpace($warning)) {
            $stepStatus = 'SucceededWithWarnings'
            $detail = "Completed with warning: $warning"
            Add-ConfigurationWarning -Message "Step $Number ($Name): $warning"
        }

        $completedState = @{
            ConfigState = 'Running'
            ConfigStep = $Number
            ConfigStepLabel = "Step $Number/$script:TotalSteps - $Name"
            ConfigStepDetail = $detail
            ProgressPercent = $completePercent
            ConsecutiveFailures = 0
        }
        $completedState[$statusName] = $stepStatus
        $completedState[$messageName] = $detail
        Update-State -Values $completedState

        Write-Log -Message "Step $Number completed with status $stepStatus."
    }
    catch {
        $message = $_.Exception.Message
        $failedState = @{
            ConfigStep = $Number
            ConfigStepLabel = "Step $Number/$script:TotalSteps - $Name"
            ConfigStepDetail = "Failed: $message"
            ConfigError = "Step $Number ($Name): $message"
        }
        $failedState[$statusName] = 'Failed'
        $failedState[$messageName] = $message
        Update-State -Values $failedState

        Write-Log -Level ERROR -Message "Step $Number failed: $message"
        throw
    }
}

function Set-StandardComputerName {
    [CmdletBinding()]
    param()

    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop

    $serial = ([string]$bios.SerialNumber).Trim().ToUpperInvariant() -replace '[^A-Z0-9]', ''
    if ([string]::IsNullOrWhiteSpace($serial)) {
        throw 'The BIOS serial number is empty after removing invalid computer-name characters.'
    }

    $invalidSerials = @(
        'DEFAULTSTRING',
        'NONE',
        'NOTAPPLICABLE',
        'SYSTEMSERIALNUMBER',
        'TOBEFILLEDBYOEM',
        'UNKNOWN'
    )
    if ($serial -in $invalidSerials) {
        throw "The BIOS serial number '$($bios.SerialNumber)' is a vendor placeholder and cannot be used as a unique computer name."
    }

    $portableChassisTypes = @(8, 9, 10, 11, 14, 30, 31, 32)
    $isPortable = $false
    foreach ($chassisType in @($enclosure.ChassisTypes)) {
        if ($portableChassisTypes -contains [int]$chassisType) {
            $isPortable = $true
            break
        }
    }

    $suffix = if ($isPortable) { 'LP' } else { 'DP' }
    $maximumSerialLength = 12
    if ($serial.Length -gt $maximumSerialLength) {
        $serial = $serial.Substring(0, $maximumSerialLength)
    }

    $desiredName = "$serial-$suffix"
    $currentName = $env:COMPUTERNAME
    $pendingName = [string](Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
        -Name 'ComputerName' `
        -ErrorAction SilentlyContinue)

    Update-State -Values @{
        OriginalComputerName = $currentName
        DesiredComputerName = $desiredName
    }

    if ($currentName -ieq $desiredName) {
        Write-Log -Message "Computer name is already '$desiredName'."
        return [pscustomobject]@{ Warning = '' }
    }

    if ($pendingName -ieq $desiredName) {
        Write-Log -Message "Computer rename to '$desiredName' is already pending a restart."
        Update-State -Values @{
            RestartRequired = 1
            RestartRequiredSinceUtc = [DateTime]::UtcNow.ToString('o')
        }
        return [pscustomobject]@{ Warning = '' }
    }

    Write-Log -Message "Renaming computer from '$currentName' to '$desiredName'."
    Rename-Computer -NewName $desiredName -Force -ErrorAction Stop

    $pendingName = [string](Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
        -Name 'ComputerName' `
        -ErrorAction Stop)

    if ($pendingName -ine $desiredName) {
        throw "Rename-Computer returned without error, but the pending name is '$pendingName' instead of '$desiredName'."
    }

    Update-State -Values @{
        RestartRequired = 1
        RestartRequiredSinceUtc = [DateTime]::UtcNow.ToString('o')
    }
    return [pscustomobject]@{ Warning = '' }
}

function Remove-HpBloatware {
    [CmdletBinding()]
    param()

    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $manufacturer = [string]$computerSystem.Manufacturer
    if ($manufacturer -notmatch 'HP|Hewlett-Packard') {
        Update-State -Values @{
            ComputerManufacturer = $manufacturer
            HpCleanupApplicable = 0
            HpTargetsFound = 0
            HpTargetsRemaining = 'None'
        }
        Write-Log -Message "Manufacturer is '$manufacturer'; HP cleanup is not applicable."
        return [pscustomobject]@{ Warning = '' }
    }

    $targets = @(
        'HP Wolf Security',
        'HP Wolf Security - Console',
        'HP Security Update Service',
        'HP Client Security Manager',
        'HP Connection Optimizer',
        'HP Documentation',
        'HP Notifications',
        'HP System Default Settings',
        'HP Wolf Security Application Support for Sure Sense',
        'HP Wolf Security Application Support for Windows'
    )

    $allEntries = @(Get-UninstallEntries)
    $matches = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($entry in $allEntries) {
        foreach ($target in $targets) {
            if ($entry.DisplayName -like "*$target*") {
                $identity = if (-not [string]::IsNullOrWhiteSpace($entry.ProductCode)) {
                    $entry.ProductCode.ToUpperInvariant()
                }
                else {
                    "$($entry.RegistryView)|$($entry.KeyName)"
                }

                if (-not $seen.ContainsKey($identity)) {
                    $seen[$identity] = $true
                    $matches.Add($entry) | Out-Null
                }
                break
            }
        }
    }

    if ($matches.Count -eq 0) {
        Write-Log -Message 'No targeted HP applications were found.'
    }

    $warnings = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $matches) {
        try {
            Write-Log -Message "Removing '$($entry.DisplayName)' version '$($entry.DisplayVersion)'."

            if (-not [string]::IsNullOrWhiteSpace($entry.ProductCode) -or
                $entry.WindowsInstaller -eq 1) {
                if ([string]::IsNullOrWhiteSpace($entry.ProductCode)) {
                    throw 'Windows Installer product code was not available.'
                }

                Invoke-ProcessWithTimeout `
                    -FilePath 'msiexec.exe' `
                    -Arguments "/x $($entry.ProductCode) /qn /norestart" `
                    -TimeoutMinutes 20 `
                    -AcceptedExitCodes @(0, 1605, 1614, 1641, 3010) `
                    -Activity "Uninstall $($entry.DisplayName)" | Out-Null
            }
            elseif (-not [string]::IsNullOrWhiteSpace($entry.QuietUninstallString)) {
                Invoke-CommandLineWithTimeout `
                    -CommandLine $entry.QuietUninstallString `
                    -TimeoutMinutes 20 `
                    -Activity "Uninstall $($entry.DisplayName)" | Out-Null
            }
            else {
                $warnings.Add("No silent uninstall command was available for $($entry.DisplayName)") | Out-Null
            }
        }
        catch {
            $warnings.Add("$($entry.DisplayName): $($_.Exception.Message)") | Out-Null
            Write-Log -Level WARN -Message "Unable to remove '$($entry.DisplayName)': $($_.Exception.Message)"
        }
    }

    foreach ($path in @(
        'C:\Program Files (x86)\Online Services\Amazon',
        'C:\Program Files (x86)\Online Services\Adobe',
        'C:\ProgramData\HP\TCO'
    )) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 3
    $remaining = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-UninstallEntries)) {
        foreach ($target in $targets) {
            if ($entry.DisplayName -like "*$target*") {
                if (-not $remaining.Contains($entry.DisplayName)) {
                    $remaining.Add($entry.DisplayName) | Out-Null
                }
                break
            }
        }
    }

    if ($remaining.Count -gt 0) {
        $warnings.Add("Targeted HP entries still detected: $($remaining -join ', ')") | Out-Null
    }

    Update-State -Values @{
        ComputerManufacturer = $manufacturer
        HpCleanupApplicable = 1
        HpTargetsFound = $matches.Count
        HpTargetsRemaining = if ($remaining.Count -gt 0) { $remaining -join ', ' } else { 'None' }
    }

    return [pscustomobject]@{
        Warning = ($warnings -join '; ')
    }
}

function Invoke-WindowsDebloat {
    [CmdletBinding()]
    param()

    $localScript = Join-Path $script:DownloadDirectory 'RemoveBloat.ps1'
    $debloatLog = 'C:\ProgramData\Debloat\Debloat.log'
    $debloatStartedUtc = [DateTime]::UtcNow

    $result = Invoke-RemotePowerShellScript `
        -Name 'Windows debloat' `
        -Uri $script:WindowsDebloatUrl `
        -LocalPath $localScript `
        -ExpectedSha256 $script:WindowsDebloatExpectedSha256 `
        -TimeoutMinutes 75

    Update-State -Values @{
        WindowsDebloatVersion = $script:WindowsDebloatVersion
        WindowsDebloatCommit = $script:WindowsDebloatCommit
        WindowsDebloatSourceUrl = $script:WindowsDebloatUrl
        WindowsDebloatSha256 = $result.Sha256
        WindowsDebloatLog = $debloatLog
    }

    if (-not (Test-Path -LiteralPath $debloatLog -PathType Leaf)) {
        throw "Windows debloat returned success but did not create its expected log: $debloatLog"
    }

    $debloatLogItem = Get-Item -LiteralPath $debloatLog -ErrorAction Stop
    if ($debloatLogItem.LastWriteTimeUtc -lt $debloatStartedUtc.AddMinutes(-1)) {
        throw "Windows debloat returned success but its log was not updated during this run: $debloatLog"
    }

    $completionLine = Get-Content `
        -LiteralPath $debloatLog `
        -Tail 200 `
        -ErrorAction Stop | Where-Object { $_ -match '^\s*Completed\s*$' } | Select-Object -Last 1
    if ($null -eq $completionLine) {
        throw "Windows debloat log does not contain its terminal completion marker: $debloatLog"
    }

    foreach ($path in @(
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Amazon.com.lnk',
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Adobe offers.lnk',
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\TCO Certified.lnk',
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk',
        'C:\Users\Public\Desktop\Microsoft Edge.lnk',
        'C:\Program Files (x86)\Online Services\Amazon',
        'C:\Program Files (x86)\Online Services\Adobe',
        'C:\ProgramData\HP\TCO'
    )) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }

    Set-MachineRegistryValue `
        -SubKey 'SOFTWARE\Policies\Microsoft\Windows\Windows Chat' `
        -Name 'ChatIcon' `
        -Value 3 `
        -Kind ([Microsoft.Win32.RegistryValueKind]::DWord)

    return [pscustomobject]@{ Warning = '' }
}

function Test-RequiredApplications {
    [CmdletBinding()]
    param()

    $status = Get-RequiredApplicationStatus
    $readyNames = New-Object System.Collections.Generic.List[string]
    $missingNames = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $status.GetEnumerator()) {
        if ($entry.Value.Ready) {
            $readyNames.Add([string]$entry.Key) | Out-Null
        }
        else {
            $missingNames.Add([string]$entry.Key) | Out-Null
        }
    }

    Update-State -Values @{
        AppsTotal = $status.Count
        AppsReady = $readyNames.Count
        AppsInstalled = [int]($missingNames.Count -eq 0)
        AppsReadyList = if ($readyNames.Count -gt 0) { $readyNames -join ', ' } else { 'None' }
        AppsMissing = if ($missingNames.Count -gt 0) { $missingNames -join ', ' } else { 'None' }
        ChromeExecutable = [string]$status['Google Chrome'].Executable
        AdobeExecutable = [string]$status['Adobe Acrobat'].Executable
        OutlookExecutable = [string]$status['Microsoft Outlook'].Executable
        TeamsExecutable = [string]$status['Microsoft Teams'].Executable
    }

    if ($missingNames.Count -gt 0) {
        Update-State -Values @{
            ConfigState = 'WaitingForApps'
            ConfigStep = 4
            ConfigStepLabel = "Step 4/$script:TotalSteps - Waiting for required applications"
            ConfigStepDetail = "Waiting for: $($missingNames -join ', ')"
            ProgressPercent = (Get-StepProgressPercent -Number 4)
            Step04Status = 'Waiting'
            Step04Message = "Waiting for: $($missingNames -join ', ')"
            ConfigError = ''
            ConsecutiveFailures = 0
        }

        Write-Log -Message "Required applications are not ready: $($missingNames -join ', ')."
        return $false
    }

    Update-State -Values @{
        ConfigState = 'Running'
        ConfigStep = 4
        ConfigStepLabel = "Step 4/$script:TotalSteps - Required applications"
        ConfigStepDetail = 'All required applications are installed'
        ProgressPercent = (Get-StepProgressPercent -Number 4 -Completed)
        Step04Status = 'Succeeded'
        Step04Message = 'All required applications are installed'
    }

    Write-Log -Message 'All required applications are ready.'
    return $true
}

function New-ExecutableShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$Arguments = '',
        [string]$Description = ''
    )

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        throw "Shortcut target not found: $TargetPath"
    }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $null
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        try {
            $shortcut.TargetPath = $TargetPath
            $shortcut.Arguments = $Arguments
            $shortcut.WorkingDirectory = Split-Path -Path $TargetPath -Parent
            $shortcut.IconLocation = "$TargetPath,0"
            $shortcut.Description = $Description
            $shortcut.Save()
        }
        finally {
            if ($null -ne $shortcut) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
            }
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        throw "Shortcut was not created: $ShortcutPath"
    }
}

function New-PackagedAppShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$AppUserModelId,
        [Parameter(Mandatory)][string]$IconSourcePath,
        [string]$Description = ''
    )

    if ([string]::IsNullOrWhiteSpace($AppUserModelId)) {
        throw 'An AppUserModelId is required for a packaged-app shortcut.'
    }
    if ([string]::IsNullOrWhiteSpace($IconSourcePath) -or
        -not (Test-Path -LiteralPath $IconSourcePath -PathType Leaf)) {
        throw "Packaged-app icon source was not found: '$IconSourcePath'"
    }

    $explorerPath = Join-Path $env:SystemRoot 'explorer.exe'
    $shellTarget = "shell:AppsFolder\$AppUserModelId"

    # WScript.Shell cannot persist shell:AppsFolder as a TargetPath. When that
    # is attempted, TargetPath is read back as an empty string and the link is
    # not launchable. Use Explorer as the supported Shell launcher and assign
    # the packaged application's executable as IconLocation so the desktop
    # displays the application icon instead of the Explorer icon.
    Remove-Item -LiteralPath $ShortcutPath -Force -ErrorAction SilentlyContinue

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $null
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        try {
            $shortcut.TargetPath = $explorerPath
            $shortcut.Arguments = $shellTarget
            $shortcut.IconLocation = "$IconSourcePath,0"
            $shortcut.Description = $Description
            $shortcut.Save()
        }
        finally {
            if ($null -ne $shortcut) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
            }
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        throw "Shortcut was not created: $ShortcutPath"
    }
}

function Get-ShortcutDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ShortcutPath)

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        return $null
    }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $null
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        try {
            return [pscustomobject]@{
                TargetPath = [Environment]::ExpandEnvironmentVariables([string]$shortcut.TargetPath)
                Arguments = [string]$shortcut.Arguments
                WorkingDirectory = [Environment]::ExpandEnvironmentVariables([string]$shortcut.WorkingDirectory)
                IconLocation = [Environment]::ExpandEnvironmentVariables([string]$shortcut.IconLocation)
            }
        }
        finally {
            if ($null -ne $shortcut) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
            }
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Test-EquivalentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or
        [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    try {
        $leftPath = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($Left.Trim().Trim('"'))
        ).TrimEnd('\')
        $rightPath = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($Right.Trim().Trim('"'))
        ).TrimEnd('\')
        return $leftPath -ieq $rightPath
    }
    catch {
        $leftFallback = $Left.Trim().Trim('"').TrimEnd('\')
        $rightFallback = $Right.Trim().Trim('"').TrimEnd('\')
        return ($leftFallback -ieq $rightFallback)
    }
}

function Copy-StartMenuShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Destination
    )

    $startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    foreach ($name in $Names) {
        $match = Get-ChildItem `
            -LiteralPath $startMenu `
            -Filter $name `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($null -ne $match) {
            Copy-Item -LiteralPath $match.FullName -Destination $Destination -Force
            return $true
        }
    }

    return $false
}

function Resolve-OfficeExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('WINWORD.EXE', 'EXCEL.EXE')][string]$FileName)

    return Find-InstalledExecutable `
        -KnownPaths @(
            (Join-Path $env:ProgramFiles "Microsoft Office\root\Office16\$FileName"),
            (Join-Path $script:ProgramFilesX86 "Microsoft Office\root\Office16\$FileName")
        ) `
        -SearchRoots @(
            (Join-Path $env:ProgramFiles 'Microsoft Office'),
            (Join-Path $script:ProgramFilesX86 'Microsoft Office')
        ) `
        -FileNames @($FileName)
}

function New-StandardDesktopShortcuts {
    [CmdletBinding()]
    param()

    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if ([string]::IsNullOrWhiteSpace($publicDesktop)) {
        $publicDesktop = 'C:\Users\Public\Desktop'
    }
    Ensure-Directory -Path $publicDesktop

    $warnings = New-Object System.Collections.Generic.List[string]
    $applicationStatus = Get-RequiredApplicationStatus
    $chromePath = [string]$applicationStatus['Google Chrome'].Executable
    $adobePath = [string]$applicationStatus['Adobe Acrobat'].Executable
    $outlookIcon = [string]$applicationStatus['Microsoft Outlook'].Executable
    $teamsIcon = [string]$applicationStatus['Microsoft Teams'].Executable

    # Chrome and Adobe remain executable-based shortcuts.
    New-ExecutableShortcut `
        -ShortcutPath (Join-Path $publicDesktop 'Google Chrome.lnk') `
        -TargetPath $chromePath `
        -Description 'Google Chrome'

    New-ExecutableShortcut `
        -ShortcutPath (Join-Path $publicDesktop 'Adobe Acrobat.lnk') `
        -TargetPath $adobePath `
        -Description 'Adobe Acrobat'

    # Word and Excel remain optional. Prefer Microsoft's Start Menu links and
    # fall back to their installed executables.
    $wordShortcut = Join-Path $publicDesktop 'Word.lnk'
    if (-not (Copy-StartMenuShortcut -Names @('Word.lnk', 'Microsoft Word.lnk') -Destination $wordShortcut)) {
        $wordPath = Resolve-OfficeExecutable -FileName 'WINWORD.EXE'
        if ($wordPath) {
            New-ExecutableShortcut -ShortcutPath $wordShortcut -TargetPath $wordPath -Description 'Microsoft Word'
        }
        else {
            $warnings.Add('Microsoft Word was not available for shortcut creation') | Out-Null
        }
    }

    $excelShortcut = Join-Path $publicDesktop 'Excel.lnk'
    if (-not (Copy-StartMenuShortcut -Names @('Excel.lnk', 'Microsoft Excel.lnk') -Destination $excelShortcut)) {
        $excelPath = Resolve-OfficeExecutable -FileName 'EXCEL.EXE'
        if ($excelPath) {
            New-ExecutableShortcut -ShortcutPath $excelShortcut -TargetPath $excelPath -Description 'Microsoft Excel'
        }
        else {
            $warnings.Add('Microsoft Excel was not available for shortcut creation') | Out-Null
        }
    }

    # New Outlook and new Teams are packaged apps. Explorer launches the AUMID
    # reliably, while IconLocation points to the package executable so the .lnk
    # shows the native application icon instead of the Explorer icon.
    New-PackagedAppShortcut `
        -ShortcutPath (Join-Path $publicDesktop 'Outlook.lnk') `
        -AppUserModelId $script:OutlookAppUserModelId `
        -IconSourcePath $outlookIcon `
        -Description 'Microsoft Outlook'

    New-PackagedAppShortcut `
        -ShortcutPath (Join-Path $publicDesktop 'MS Teams.lnk') `
        -AppUserModelId $script:TeamsAppUserModelId `
        -IconSourcePath $teamsIcon `
        -Description 'Microsoft Teams'

    return [pscustomobject]@{
        Warning = ($warnings -join '; ')
    }
}

function Assert-FinalConfiguration {
    [CmdletBinding()]
    param()

    $issues = New-Object System.Collections.Generic.List[string]
    $allowedStepStatuses = @('Succeeded', 'SucceededWithWarnings')
    $retryStep1 = $false
    $retryStep3 = $false
    $retryStep5 = $false

    for ($number = 1; $number -le $script:TotalSteps; $number++) {
        $statusName = Get-StepStatusName -Number $number
        $status = [string](Get-StateValue -Name $statusName -Default '')
        if ($status -notin $allowedStepStatuses) {
            $issues.Add("$statusName is '$status'") | Out-Null
        }
    }

    $applicationStatus = Get-RequiredApplicationStatus
    $readyNames = New-Object System.Collections.Generic.List[string]
    $missingNames = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $applicationStatus.GetEnumerator()) {
        if ($entry.Value.Ready) {
            $readyNames.Add([string]$entry.Key) | Out-Null
        }
        else {
            $missingNames.Add([string]$entry.Key) | Out-Null
        }
    }

    Update-State -Values @{
        AppsTotal = $applicationStatus.Count
        AppsReady = $readyNames.Count
        AppsInstalled = [int]($missingNames.Count -eq 0)
        AppsReadyList = if ($readyNames.Count -gt 0) { $readyNames -join ', ' } else { 'None' }
        AppsMissing = if ($missingNames.Count -gt 0) { $missingNames -join ', ' } else { 'None' }
        ChromeExecutable = [string]$applicationStatus['Google Chrome'].Executable
        AdobeExecutable = [string]$applicationStatus['Adobe Acrobat'].Executable
        OutlookExecutable = [string]$applicationStatus['Microsoft Outlook'].Executable
        TeamsExecutable = [string]$applicationStatus['Microsoft Teams'].Executable
    }

    if ($missingNames.Count -gt 0) {
        $issues.Add("Required applications are missing: $($missingNames -join ', ')") | Out-Null
    }

    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if ([string]::IsNullOrWhiteSpace($publicDesktop)) {
        $publicDesktop = 'C:\Users\Public\Desktop'
    }

    $explorerTarget = Join-Path $env:SystemRoot 'explorer.exe'
    $outlookArguments = "shell:AppsFolder\$script:OutlookAppUserModelId"
    $teamsArguments = "shell:AppsFolder\$script:TeamsAppUserModelId"

    $shortcutDefinitions = @(
        [pscustomobject]@{
            Name = 'Google Chrome'
            FileName = 'Google Chrome.lnk'
            TargetPath = [string]$applicationStatus['Google Chrome'].Executable
            Arguments = ''
            IconPath = ''
        },
        [pscustomobject]@{
            Name = 'Adobe Acrobat'
            FileName = 'Adobe Acrobat.lnk'
            TargetPath = [string]$applicationStatus['Adobe Acrobat'].Executable
            Arguments = ''
            IconPath = ''
        },
        [pscustomobject]@{
            Name = 'Outlook'
            FileName = 'Outlook.lnk'
            TargetPath = $explorerTarget
            Arguments = $outlookArguments
            IconPath = [string]$applicationStatus['Microsoft Outlook'].Executable
        },
        [pscustomobject]@{
            Name = 'MS Teams'
            FileName = 'MS Teams.lnk'
            TargetPath = $explorerTarget
            Arguments = $teamsArguments
            IconPath = [string]$applicationStatus['Microsoft Teams'].Executable
        }
    )

    foreach ($definition in $shortcutDefinitions) {
        $shortcutPath = Join-Path $publicDesktop $definition.FileName
        if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
            $issues.Add("Required shortcut is missing: $shortcutPath") | Out-Null
            $retryStep5 = $true
            continue
        }

        try {
            $actualShortcut = Get-ShortcutDefinition -ShortcutPath $shortcutPath
            if ($null -eq $actualShortcut) {
                throw 'The shortcut could not be read.'
            }

            if (-not (Test-EquivalentPath `
                -Left ([string]$actualShortcut.TargetPath) `
                -Right ([string]$definition.TargetPath))) {
                $issues.Add(
                    "Shortcut target mismatch for $($definition.Name): '$($actualShortcut.TargetPath)'"
                ) | Out-Null
                $retryStep5 = $true
            }

            $actualArguments = ([string]$actualShortcut.Arguments).Trim()
            $expectedArguments = ([string]$definition.Arguments).Trim()
            if ($actualArguments -cne $expectedArguments) {
                $issues.Add(
                    "Shortcut arguments mismatch for $($definition.Name): '$($actualShortcut.Arguments)'"
                ) | Out-Null
                $retryStep5 = $true
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$definition.IconPath)) {
                $actualIconLocation = [string]$actualShortcut.IconLocation
                $actualIconPath = ($actualIconLocation -replace ',\s*-?\d+\s*$', '').Trim().Trim('"')
                if (-not (Test-EquivalentPath `
                    -Left $actualIconPath `
                    -Right ([string]$definition.IconPath))) {
                    $issues.Add(
                        "Shortcut icon mismatch for $($definition.Name): '$actualIconLocation'"
                    ) | Out-Null
                    $retryStep5 = $true
                }
            }
        }
        catch {
            $issues.Add("Unable to verify shortcut '$shortcutPath': $($_.Exception.Message)") | Out-Null
            $retryStep5 = $true
        }
    }

    $desiredName = [string](Get-StateValue -Name 'DesiredComputerName' -Default '')
    $currentName = [string]$env:COMPUTERNAME
    $pendingName = [string](Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
        -Name 'ComputerName' `
        -ErrorAction SilentlyContinue)

    if ([string]::IsNullOrWhiteSpace($desiredName)) {
        $issues.Add('DesiredComputerName was not published by Step 1') | Out-Null
        $retryStep1 = $true
    }
    elseif ($currentName -ine $desiredName -and $pendingName -ine $desiredName) {
        $issues.Add("Computer name is neither applied nor pending. Current='$currentName'; Pending='$pendingName'; Expected='$desiredName'") | Out-Null
        $retryStep1 = $true
    }

    $debloatLog = [string](Get-StateValue `
        -Name 'WindowsDebloatLog' `
        -Default 'C:\ProgramData\Debloat\Debloat.log')
    $debloatHash = [string](Get-StateValue -Name 'WindowsDebloatSha256' -Default '')
    $debloatCommit = [string](Get-StateValue -Name 'WindowsDebloatCommit' -Default '')
    $debloatVersion = [string](Get-StateValue -Name 'WindowsDebloatVersion' -Default '')
    $debloatSourceUrl = [string](Get-StateValue -Name 'WindowsDebloatSourceUrl' -Default '')
    $debloatScriptPath = Join-Path $script:DownloadDirectory 'RemoveBloat.ps1'

    if ($debloatHash -ine $script:WindowsDebloatExpectedSha256) {
        $issues.Add("Windows debloat SHA256 state is '$debloatHash'; expected '$script:WindowsDebloatExpectedSha256'") | Out-Null
        $retryStep3 = $true
    }
    $debloatIdentityMatches = (
        $debloatCommit -eq $script:WindowsDebloatCommit -and
        $debloatVersion -eq $script:WindowsDebloatVersion
    )
    if (-not $debloatIdentityMatches) {
        $issues.Add("Windows debloat dependency identity is version '$debloatVersion', commit '$debloatCommit'") | Out-Null
        $retryStep3 = $true
    }
    if ($debloatSourceUrl -ne $script:WindowsDebloatUrl) {
        $issues.Add("Windows debloat source URL state is '$debloatSourceUrl'") | Out-Null
        $retryStep3 = $true
    }

    if (-not (Test-Path -LiteralPath $debloatScriptPath -PathType Leaf)) {
        $issues.Add("Pinned Windows debloat script is missing: $debloatScriptPath") | Out-Null
        $retryStep3 = $true
    }
    else {
        try {
            $actualDebloatHash = (Get-FileHash `
                -LiteralPath $debloatScriptPath `
                -Algorithm SHA256 `
                -ErrorAction Stop).Hash.ToUpperInvariant()
            if ($actualDebloatHash -ne $script:WindowsDebloatExpectedSha256) {
                $issues.Add("Pinned Windows debloat script SHA256 is '$actualDebloatHash'; expected '$script:WindowsDebloatExpectedSha256'") | Out-Null
                $retryStep3 = $true
            }
        }
        catch {
            $issues.Add("Unable to hash the pinned Windows debloat script '$debloatScriptPath': $($_.Exception.Message)") | Out-Null
            $retryStep3 = $true
        }
    }

    if (-not (Test-Path -LiteralPath $debloatLog -PathType Leaf)) {
        $issues.Add("Windows debloat log is missing: $debloatLog") | Out-Null
        $retryStep3 = $true
    }
    else {
        try {
            $completionLine = Get-Content `
                -LiteralPath $debloatLog `
                -Tail 200 `
                -ErrorAction Stop | Where-Object { $_ -match '^\s*Completed\s*$' } | Select-Object -Last 1
            if ($null -eq $completionLine) {
                $issues.Add("Windows debloat log lacks the terminal completion marker: $debloatLog") | Out-Null
                $retryStep3 = $true
            }
        }
        catch {
            $issues.Add("Unable to verify Windows debloat log '$debloatLog': $($_.Exception.Message)") | Out-Null
            $retryStep3 = $true
        }
    }

    if ($issues.Count -gt 0) {
        $message = $issues -join '; '
        $failureState = @{
            FinalVerificationResult = 'Failed'
            FinalVerificationMessage = $message
            FinalVerificationUtc = [DateTime]::UtcNow.ToString('o')
        }

        if ($missingNames.Count -gt 0) {
            $failureState['Step04Status'] = 'Waiting'
            $failureState['Step04Message'] = "Waiting for: $($missingNames -join ', ')"
        }
        if ($retryStep1) {
            $failureState['Step01Status'] = 'Failed'
            $failureState['Step01Message'] = 'Final verification requires Step 1 to run again'
        }
        if ($retryStep3) {
            $failureState['Step03Status'] = 'Failed'
            $failureState['Step03Message'] = 'Final verification requires Step 3 to run again'
        }
        if ($retryStep5) {
            $failureState['Step05Status'] = 'Failed'
            $failureState['Step05Message'] = 'Final verification requires Step 5 to run again'
        }

        Update-State -Values $failureState
        throw "Final configuration verification failed: $message"
    }

    Update-State -Values @{
        FinalVerificationResult = 'Passed'
        FinalVerificationMessage = 'All required postconditions passed'
        FinalVerificationUtc = [DateTime]::UtcNow.ToString('o')
    }

    Write-Log -Message 'Final configuration verification passed.'
}


# -----------------------------------------------------------------------------
# Worker state machine
# -----------------------------------------------------------------------------
function Get-ConfigurationAgeHours {
    $startValue = [string](Get-StateValue -Name 'ScriptStartTimeUtc' -Default '')
    $start = [DateTimeOffset]::MinValue

    if (-not [DateTimeOffset]::TryParse($startValue, [ref]$start)) {
        return 0.0
    }

    return ([DateTimeOffset]::UtcNow - $start.ToUniversalTime()).TotalHours
}

function Complete-Configuration {
    [CmdletBinding()]
    param()

    $verificationResult = [string](Get-StateValue -Name 'FinalVerificationResult' -Default '')
    if ($verificationResult -ne 'Passed') {
        throw "Configuration completion was blocked because FinalVerificationResult is '$verificationResult'."
    }

    $warnings = [string](Get-StateValue -Name 'ConfigWarnings' -Default '')
    $detail = if ([string]::IsNullOrWhiteSpace($warnings)) {
        'Computer setup finished successfully'
    }
    else {
        'Computer setup finished with non-blocking warnings'
    }

    $completedTimeUtc = [DateTime]::UtcNow.ToString('o')
    $bootTimeAtCompletionUtc = ''
    try {
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $bootTimeAtCompletionUtc = ([DateTime]$operatingSystem.LastBootUpTime).ToUniversalTime().ToString('o')
    }
    catch {
        Write-Log -Level WARN -Message "Unable to record the operating-system boot time: $($_.Exception.Message)"
    }

    # Publish all final data first. ConfigComplete is the commit marker and is
    # intentionally written in a separate final registry operation.
    Update-State -Values @{
        ConfigState = 'Finalizing'
        ConfigComplete = 0
        ConfigFailed = 0
        ConfigError = ''
        ConfigStep = $script:TotalSteps
        TotalSteps = $script:TotalSteps
        ConfigStepLabel = 'Configuration completed'
        ConfigStepDetail = $detail
        ProgressPercent = 100
        CompletedTimeUtc = $completedTimeUtc
        BootTimeAtCompletionUtc = $bootTimeAtCompletionUtc
        ConsecutiveFailures = 0
        WorkerLastResult = 'Completed'
    }
    Update-State -Values @{ ConfigState = 'Completed' }
    Update-State -Values @{ ConfigComplete = 1 }

    Write-Log -Message $detail
    Start-Sleep -Seconds 2
    Remove-WorkerTask
}

function Set-WorkerFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$RetryUntilDeadline
    )

    $failureCount = (ConvertTo-Int32 -Value (Get-StateValue -Name 'ConsecutiveFailures' -Default 0)) + 1
    $configurationAgeHours = Get-ConfigurationAgeHours
    $isTerminal = if ($RetryUntilDeadline) {
        $configurationAgeHours -ge $script:ConfigurationDeadlineHours
    }
    else {
        $failureCount -ge $script:MaximumConsecutiveFailures
    }

    if ($isTerminal) {
        # ConfigFailed is the terminal commit marker and is written last so the
        # user monitor never consumes a partially published failure record.
        Update-State -Values @{
            ConfigState = 'FailureFinalizing'
            ConfigComplete = 0
            ConfigFailed = 0
            ConfigError = $Message
            ConfigStepLabel = 'Configuration failed'
            ConfigStepDetail = $Message
            ConsecutiveFailures = $failureCount
            WorkerLastResult = 'Failed'
            FailedTimeUtc = [DateTime]::UtcNow.ToString('o')
        }
        Update-State -Values @{ ConfigState = 'Failed' }
        Update-State -Values @{ ConfigFailed = 1 }
        Write-Log -Level ERROR -Message "Configuration failed after $failureCount consecutive worker failures: $Message"
        Remove-WorkerTask
    }
    else {
        $retryDetail = if ($RetryUntilDeadline) {
            "A transient dependency is unavailable; the SYSTEM worker will retry until the configuration deadline: $Message"
        }
        else {
            "Attempt failed; the SYSTEM worker will retry: $Message"
        }

        Update-State -Values @{
            ConfigState = 'RetryPending'
            ConfigComplete = 0
            ConfigFailed = 0
            ConfigError = $Message
            ConfigStepDetail = $retryDetail
            ConsecutiveFailures = $failureCount
            WorkerLastResult = 'RetryPending'
        }

        if ($RetryUntilDeadline) {
            Write-Log -Level WARN -Message "Transient worker failure; retrying until the $script:ConfigurationDeadlineHours hour deadline (attempt $failureCount): $Message"
        }
        else {
            Write-Log -Level WARN -Message "Worker attempt failed ($failureCount/$script:MaximumConsecutiveFailures): $Message"
        }
    }
}

function Invoke-WorkerCore {
    [CmdletBinding()]
    param()

    if (-not (Test-IsElevated)) {
        throw 'The configuration worker must run elevated as SYSTEM or a local administrator.'
    }

    $snapshot = Get-StateSnapshot
    if (([string]$snapshot['ConfigVersion']) -ne $script:ConfigVersion) {
        throw "State version mismatch. Expected $script:ConfigVersion; found '$($snapshot['ConfigVersion'])'."
    }

    Resolve-PendingRestartState

    if ((ConvertTo-Int32 -Value $snapshot['ConfigComplete']) -eq 1) {
        Write-Log -Message 'Configuration is already complete.'
        Remove-WorkerTask
        return
    }

    if ((Get-ConfigurationAgeHours) -ge $script:ConfigurationDeadlineHours) {
        $deadlineException = [System.TimeoutException]::new(
            "Configuration exceeded the $script:ConfigurationDeadlineHours hour deadline."
        )
        $deadlineException.Data['TMT.RetryUntilDeadline'] = $true
        throw $deadlineException
    }

    $attempt = (ConvertTo-Int32 -Value $snapshot['WorkerAttempt']) + 1
    Update-State -Values @{
        ConfigState = 'Running'
        WorkerAttempt = $attempt
        WorkerLastStartUtc = [DateTime]::UtcNow.ToString('o')
        WorkerHeartbeatUtc = [DateTime]::UtcNow.ToString('o')
        WorkerLastResult = 'Running'
        ConfigFailed = 0
    }

    Write-Log -Message "SYSTEM worker attempt $attempt started."

    # Step 1 command: Set-StandardComputerName
    # Reads BIOS/chassis data, calculates the standard device name, and stages
    # Rename-Computer only when the current name differs.
    Invoke-ManagedStep -Number 1 -Name 'Computer name' -Action {
        Set-StandardComputerName
    }

    # Step 2 command: Remove-HpBloatware
    # Inventories HP uninstall entries in both registry views and removes only
    # the approved HP targets without using Win32_Product.
    Invoke-ManagedStep -Number 2 -Name 'HP bloatware removal' -Action {
        Remove-HpBloatware
    }

    # Step 3 command: Invoke-WindowsDebloat
    # Downloads the pinned RemoveBloat.ps1 into C:\ProgramData\TMT\Downloads,
    # validates its hash/syntax, executes it, and validates its completion log.
    Invoke-ManagedStep -Number 3 -Name 'Windows bloatware removal' -Action {
        Invoke-WindowsDebloat
    }

    # Step 4 command: Test-RequiredApplications
    # Waits for Chrome, Adobe Acrobat, new Outlook, and new Teams. For Outlook
    # and Teams it also resolves the packaged-app executable used as the icon
    # source. Missing applications are a normal waiting state and retry later.
    if (-not (Test-RequiredApplications)) {
        Write-Log -Message 'Worker completed normally and will check required applications again later.'
        return
    }

    # Step 5 command: New-StandardDesktopShortcuts
    # Creates Chrome, Adobe, Word, Excel, Outlook, and Teams shortcuts. New
    # Outlook and Teams launch through Explorer + their AUMIDs and use their
    # package executables as icon sources.
    Invoke-ManagedStep -Number 5 -Name 'Standard desktop shortcuts' -Action {
        New-StandardDesktopShortcuts
    }


    Update-State -Values @{
        ConfigState = 'Finalizing'
        ConfigStepLabel = 'Final verification'
        ConfigStepDetail = 'Validating required postconditions'
        ProgressPercent = 98
    }
    Assert-FinalConfiguration
    Complete-Configuration
}

function Invoke-Worker {
    [CmdletBinding()]
    param()

    $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    $lockTaken = $false

    try {
        try {
            $lockTaken = $mutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }

        if (-not $lockTaken) {
            Write-Log -Message 'Another configuration worker instance is already active; exiting.'
            return 0
        }

        try {
            Invoke-WorkerCore
            Update-State -Values @{ ConsecutiveFailures = 0 }
            return 0
        }
        catch {
            $message = $_.Exception.Message
            $retryUntilDeadline = Test-RetryUntilDeadlineException -Exception $_.Exception
            Set-WorkerFailure `
                -Message $message `
                -RetryUntilDeadline:$retryUntilDeadline
            return 1
        }
    }
    finally {
        if ($lockTaken) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
                Write-Log -Level WARN -Message "Unable to release worker mutex: $($_.Exception.Message)"
            }
        }
        $mutex.Dispose()
    }
}

# -----------------------------------------------------------------------------
# Intune bootstrapper
# -----------------------------------------------------------------------------
function Initialize-NewRunState {
    [CmdletBinding()]
    param()

    $now = [DateTime]::UtcNow.ToString('o')
    $runId = [Guid]::NewGuid().ToString()

    # Clear old terminal markers before replacing the rest of the state.
    Set-StateValues -Values ([ordered]@{
        ConfigComplete = 0
        ConfigFailed = 0
        ConfigState = 'Initializing'
        LastUpdatedUtc = $now
    })

    Set-StateValues -Values @{
        SchemaVersion = $script:SchemaVersion
        ConfigVersion = $script:ConfigVersion
        RunId = $runId
        ConfigState = 'Queued'
        ConfigComplete = 0
        ConfigFailed = 0
        ConfigError = ''
        ConfigWarnings = ''
        FailedTimeUtc = ''
        FinalVerificationResult = 'Pending'
        FinalVerificationMessage = ''
        FinalVerificationUtc = ''
        CompletedTimeUtc = ''
        BootTimeAtCompletionUtc = ''
        ConfigStep = 0
        TotalSteps = $script:TotalSteps
        ConfigStepLabel = 'Configuration queued'
        ConfigStepDetail = 'Waiting for the SYSTEM worker to start'
        ProgressPercent = 0
        ScriptStartTimeUtc = $now
        LastUpdatedUtc = $now
        WorkerHeartbeatUtc = $now
        WorkerLastStartUtc = ''
        WorkerLastResult = 'Queued'
        WorkerAttempt = 0
        ConsecutiveFailures = 0
        RestartRequired = 0
        RestartRequiredSinceUtc = ''
        RestartSatisfiedUtc = ''
        AppsInstalled = 0
        AppsReady = 0
        AppsTotal = 4
        AppsMissing = 'Google Chrome, Adobe Acrobat, Microsoft Outlook, Microsoft Teams'
        AppsReadyList = 'None'
        ChromeExecutable = ''
        AdobeExecutable = ''
        OutlookExecutable = ''
        TeamsExecutable = ''
        OriginalComputerName = ''
        DesiredComputerName = ''
        ComputerManufacturer = ''
        HpCleanupApplicable = 0
        HpTargetsFound = 0
        HpTargetsRemaining = 'Unknown'
        WindowsDebloatVersion = ''
        WindowsDebloatCommit = ''
        WindowsDebloatSourceUrl = ''
        WindowsDebloatSha256 = ''
        WindowsDebloatLog = 'C:\ProgramData\Debloat\Debloat.log'
        Step01Status = 'Pending'
        Step01Message = ''
        Step02Status = 'Pending'
        Step02Message = ''
        Step03Status = 'Pending'
        Step03Message = ''
        Step04Status = 'Pending'
        Step04Message = ''
        Step05Status = 'Pending'
        Step05Message = ''
    }

    Write-Log -Message "Initialized configuration run $runId, version $script:ConfigVersion."
}

function Invoke-Bootstrap {
    [CmdletBinding()]
    param()

    if (-not (Test-IsElevated)) {
        throw 'This script must be deployed in SYSTEM context or run from an elevated PowerShell session.'
    }

    Ensure-Directory -Path $script:RootDirectory
    Ensure-Directory -Path $script:LogDirectory
    Ensure-Directory -Path $script:DownloadDirectory

    if ($Reset) {
        Write-Log -Level WARN -Message 'Reset requested. Removing prior task and registry state.'
        Remove-WorkerTask -StopRunning
        Remove-StateKey
    }

    Install-CurrentScript -DestinationPath $script:InstalledScript
    Test-PowerShellSyntax -Path $script:InstalledScript

    $snapshot = Get-StateSnapshot
    $sameVersion = ([string]$snapshot['ConfigVersion']) -eq $script:ConfigVersion
    $alreadyComplete = $sameVersion -and (ConvertTo-Int32 -Value $snapshot['ConfigComplete']) -eq 1

    if (-not $sameVersion -and $snapshot.Count -gt 0) {
        Write-Log -Message "Replacing configuration state from version '$($snapshot['ConfigVersion'])' with version '$script:ConfigVersion'."
        Remove-WorkerTask -StopRunning
    }

    if ($alreadyComplete -and -not $Reset) {
        Write-Log -Message "Configuration version $script:ConfigVersion is already complete."
        Remove-WorkerTask
        return
    }

    $inProgressStates = @('Queued', 'Running', 'WaitingForApps', 'RetryPending', 'Finalizing')
    $resumeExistingRun = $sameVersion -and (([string]$snapshot['ConfigState']) -in $inProgressStates)

    if (-not $resumeExistingRun) {
        Initialize-NewRunState
    }
    else {
        Update-State -Values @{
            ConfigStepDetail = 'Intune bootstrap refreshed the SYSTEM worker task'
            ConfigFailed = 0
        }
        Write-Log -Message "Resuming existing configuration run '$($snapshot['RunId'])'."
    }

    Register-WorkerTask
    Write-Log -Message 'Bootstrap completed successfully. Long-running work continues in the SYSTEM scheduled task.'
}

try {
    if ($Worker) {
        exit (Invoke-Worker)
    }

    Invoke-Bootstrap
    exit 0
}
catch {
    $message = $_.Exception.Message
    $failureContext = if ($Worker) { 'Worker host' } else { 'Bootstrap' }
    Write-Log -Level ERROR -Message "$failureContext failed: $message"

    if ($Worker) {
        try {
            Set-WorkerFailure -Message "$failureContext $message"
        }
        catch {
            Write-Host "Unable to publish worker-host failure to registry: $($_.Exception.Message)"
        }
    }
    else {
        Remove-WorkerTask
        try {
            Update-State -Values @{
                ConfigState = 'FailureFinalizing'
                ConfigComplete = 0
                ConfigFailed = 0
                ConfigError = "$failureContext $message"
                ConfigStepLabel = "$failureContext failed"
                ConfigStepDetail = $message
                FailedTimeUtc = [DateTime]::UtcNow.ToString('o')
            }
            Update-State -Values @{ ConfigState = 'Failed' }
            Update-State -Values @{ ConfigFailed = 1 }
        }
        catch {
            Write-Host "Unable to publish bootstrap failure to registry: $($_.Exception.Message)"
        }
    }

    exit 1
}
