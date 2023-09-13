# Add-Type -AssemblyNamePresentationFramework

# CHECK COMPUTER STATUS AND SHOW A NOTIFICATION

New-Item -Path "C:\MasterScriptIsStarting.txt"

$a = new-object -comobject wscript.shell


$expectedMembers = @("Administrator", "MiPCSAdmin")

# Get the members of the Administrators group
$administratorsGroup = [ADSI]"WinNT://./Administrators,group"
$members = $administratorsGroup.Invoke("Members") | ForEach-Object {
    $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)
}

# Check if the members match the expected list
$additionalMembers = $members | Where-Object { $_ -notin $expectedMembers }

# Display the appropriate notification
if ($additionalMembers.Count -eq 0) {
    # There are no additional members
$b = $a.popup("The computer is ready to use",-1,"Configuration Complete",0)
} else {
$b = $a.popup("Please DO NOT USE this computer at this moment. We are setting up this computer. It will restart when complete",10,"Configuration is in Progress",0)
}



$LocalAdminGroupFolder = "C:\ProgramData\TMT\LocalAdminGroup"
If (Test-Path $LocalAdminGroupFolder) {
    # Write-Output "$PartitionFolder exists. Skipping."
}
Else {
    # Write-Output "The folder '$PartitionFolder' doesn't exist. This folder will be used for storing logs created after the script runs. Creating now."
    # Start-Sleep 1
    New-Item -Path "$LocalAdminGroupFolder" -ItemType Directory
    # Write-Output "The folder $PartitionFolder was successfully created."
}

$LocalAdminGroupFile = "C:\ProgramData\TMT\LocalAdminGroup\RemoveUsersFromLocalAdminGroup.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/LocalAdminGroup/main/RemoveUsersFromLocalAdminGroup.ps1" -OutFile "C:\ProgramData\TMT\LocalAdminGroup\RemoveUsersFromLocalAdminGroup.ps1"
Invoke-expression -Command $LocalAdminGroupFile
# New-Item -Path "C:\RepartitionSuccessful.txt"
# [System.Windows.MessageBox]::Show('Local Admin Changes Successful.  Press OK to continue')
$b = $a.popup("Local Admin Changes Successful. Press OK to continue",10,"Configuration is in Progress",0)


# Step 1: RE-PARTITION

$PartitionFolder = "C:\ProgramData\TMT\Partition"
If (Test-Path $PartitionFolder) {
    # Write-Output "$PartitionFolder exists. Skipping."
}
Else {
    # Write-Output "The folder '$PartitionFolder' doesn't exist. This folder will be used for storing logs created after the script runs. Creating now."
    # Start-Sleep 1
    New-Item -Path "$PartitionFolder" -ItemType Directory
    # Write-Output "The folder $PartitionFolder was successfully created."
}

$PartitionFile = "C:\ProgramData\TMT\Partition\Repartition.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/Repartition/main/Repartition.ps1" -OutFile "C:\ProgramData\TMT\Partition\Repartition.ps1"
Invoke-expression -Command $PartitionFile
# New-Item -Path "C:\RepartitionSuccessful.txt"
# [System.Windows.MessageBox]::Show('Repartition Successful.  Press OK to continue')
$b = $a.popup("Repartition Successful. Press OK to continue",10,"Configuration is in Progress",0)


# New-Item -Path "C:\Step1CompleteGoingToStep2.txt"



$FolderRedirectionFolder = "C:\ProgramData\TMT\FolderRedirection"
If (Test-Path $FolderRedirectionFolder) {
    # Write-Output "$PartitionFolder exists. Skipping."
}
Else {
    # Write-Output "The folder '$PartitionFolder' doesn't exist. This folder will be used for storing logs created after the script runs. Creating now."
    # Start-Sleep 1
    New-Item -Path "$FolderRedirectionFolder" -ItemType Directory
    # Write-Output "The folder $PartitionFolder was successfully created."
}


$FolderRedirectionFile = "C:\ProgramData\TMT\FolderRedirection\FolderRedirectionDownload.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/FolderRedirection/main/FolderRedirectionDownload.ps1" -OutFile "C:\ProgramData\TMT\FolderRedirection\FolderRedirectionDownload.ps1"
Invoke-expression -Command $FolderRedirectionFile

# New-Item -Path "C:\RepartitionSuccessful.txt"
# [System.Windows.MessageBox]::Show('Folder Redirection Changes Successful.  Press OK to continue')
$b = $a.popup("Folder Redirection Changes Successful. Press OK to continue",10,"Configuration is in Progress",0)




$ChangeComputerNameFolder = "C:\ProgramData\TMT\ChangeComputerName"
If (Test-Path $ChangeComputerNameFolder) {
    # Write-Output "$PartitionFolder exists. Skipping."
}
Else {
    # Write-Output "The folder '$PartitionFolder' doesn't exist. This folder will be used for storing logs created after the script runs. Creating now."
    # Start-Sleep 1
    New-Item -Path "$ChangeComputerNameFolder" -ItemType Directory
    # Write-Output "The folder $PartitionFolder was successfully created."
}


$ChangeComputerNameFile = "C:\ProgramData\TMT\ChangeComputerName\PCSChangeComputerName.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/ChangeComputerName/main/PCSChangeComputerName.ps1" -OutFile "C:\ProgramData\TMT\ChangeComputerName\PCSChangeComputerName.ps1"
Invoke-expression -Command $ChangeComputerNameFile

# New-Item -Path "C:\RepartitionSuccessful.txt"
# [System.Windows.MessageBox]::Show('Change Computer Name Successful.  Press OK to continue')
$b = $a.popup("Change Computer Name Successful. Press OK to continue",10,"Configuration is in Progress",0)








$RemoveHPBloatwareFolder = "C:\ProgramData\TMT\RemoveHPBloatware"
If (Test-Path $RemoveHPBloatwareFolder) {
    # Write-Output "$PartitionFolder exists. Skipping."
}
Else {
    # Write-Output "The folder '$PartitionFolder' doesn't exist. This folder will be used for storing logs created after the script runs. Creating now."
    # Start-Sleep 1
    New-Item -Path "$RemoveHPBloatwareFolder" -ItemType Directory
    # Write-Output "The folder $PartitionFolder was successfully created."
}


$RemoveHPBloatwareFile = "C:\ProgramData\TMT\RemoveHPBloatware\RemoveHPBloatware.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/HPBloatwareRemover/main/RemoveHPBloatware.ps1" -OutFile "C:\ProgramData\TMT\RemoveHPBloatware\RemoveHPBloatware.ps1"
Invoke-expression -Command $RemoveHPBloatwareFile

# New-Item -Path "C:\RepartitionSuccessful.txt"
# [System.Windows.MessageBox]::Show('Remove HP Bloatware Successful.  Press OK to continue')
$b = $a.popup("Remove HP Bloatware Successfu. Press OK to continue",10,"Configuration is in Progress",0)










$WindowsDebloatFolder = "C:\ProgramData\TMT\WindowsDebloat"
If (Test-Path $WindowsDebloatFolder) {
    # Write-Output "$PartitionFolder exists. Skipping."
}
Else {
    # Write-Output "The folder '$PartitionFolder' doesn't exist. This folder will be used for storing logs created after the script runs. Creating now."
    # Start-Sleep 1
    New-Item -Path "$WindowsDebloatFolder" -ItemType Directory
    # Write-Output "The folder $PartitionFolder was successfully created."
}


$WindowsDebloatFile = "C:\ProgramData\TMT\WindowsDebloat\Debloat.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/WindowsBloatware/main/Debloat.ps1" -OutFile "C:\ProgramData\TMT\WindowsDebloat\Debloat.ps1"
Invoke-expression -Command $WindowsDebloatFile

# New-Item -Path "C:\RepartitionSuccessful.txt"
# [System.Windows.MessageBox]::Show('Remove Windows Bloatware Successful.  Press OK to continue')
$b = $a.popup("Remove Windows Bloatware Successful. Press OK to continue",10,"Configuration is in Progress",0)


$registryPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$registryName = "RunTMTScript"

# Check if the registry key exists
if (Test-Path -Path $registryPath) {
    # Remove the registry key
    Remove-ItemProperty -Path $registryPath -Name $registryName
    Write-Host "Registry key $registryName has been removed."
} else {
    Write-Host "Registry key $registryName does not exist."
}


$b = $a.popup("Windows Setup Complete.  Rebooting in 30 seconds",30,"Configuration is in Progress",0)

New-Item -Path "C:\ProgramData\TMT\Done1.0.txt"

Start-Sleep -Seconds 30
Restart-Computer -Force
