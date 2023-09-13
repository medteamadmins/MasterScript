Add-Type -AssemblyName System.Windows.Forms

# Create a form
$form = New-Object Windows.Forms.Form
$form.Text = "Progress Bar Demo"
$form.Size = New-Object Drawing.Size(300, 100)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $False
$form.MinimizeBox = $False

# Create a progress bar
$progressBar = New-Object Windows.Forms.ProgressBar
$progressBar.Maximum = 6  # Total number of tasks
$progressBar.Value = 0
$progressBar.Location = New-Object Drawing.Point(10, 30)
$progressBar.Width = 260

# Create a label
$label = New-Object Windows.Forms.Label
$label.Text = "Progress:"
$label.Location = New-Object Drawing.Point(10, 10)

# Add controls to the form
$form.Controls.Add($label)
$form.Controls.Add($progressBar)

# Function to update the progress bar
function Update-ProgressBar {
    if ($progressBar.Value -lt $progressBar.Maximum) {
        $progressBar.Value++
    }
    else {
        $form.Close()
    }
}

New-Item -Path "C:\MasterScriptIsStarting.txt"

$MasterScriptDone = "C:\ProgramData\TMT\MasterScriptDone1.0.txt"

$a = new-object -comobject wscript.shell

# Declare expected users in the Local Admin Group
$expectedMembers = @("Administrator", "MiPCSAdmin")

# Get the members of the Administrators group
$administratorsGroup = [ADSI]"WinNT://./Administrators,group"
$members = $administratorsGroup.Invoke("Members") | ForEach-Object {
    $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)
}

# Check if the members match the expected list
$additionalMembers = $members | Where-Object { $_ -notin $expectedMembers }

# Display the appropriate notification
if (Test-Path $MasterScriptDone) {
    # There are no additional members
$b = $a.popup("The computer is ready to use",-1,"Configuration Complete",0x0)
} else {
$b = $a.popup("Please DO NOT USE this computer at this moment. We are setting up this computer. Press OK to continue",-1,"Configuration is in Progress",0x0)


$LocalAdminGroupFolder = "C:\ProgramData\TMT\LocalAdminGroup"
If (Test-Path $LocalAdminGroupFolder) {
}
Else {
    New-Item -Path "$LocalAdminGroupFolder" -ItemType Directory
}

$LocalAdminGroupFile = "C:\ProgramData\TMT\LocalAdminGroup\RemoveUsersFromLocalAdminGroup.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/LocalAdminGroup/main/RemoveUsersFromLocalAdminGroup.ps1" -OutFile "C:\ProgramData\TMT\LocalAdminGroup\RemoveUsersFromLocalAdminGroup.ps1"
Invoke-expression -Command $LocalAdminGroupFile
# $b = $a.popup("Local Admin Changes Successful. Press OK to continue",5,"Configuration is in Progress",0x0)
Update-ProgressBar

# Step 1: RE-PARTITION
$PartitionFolder = "C:\ProgramData\TMT\Partition"
If (Test-Path $PartitionFolder) {
}
Else {
    New-Item -Path "$PartitionFolder" -ItemType Directory
}

$PartitionFile = "C:\ProgramData\TMT\Partition\Repartition.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/Repartition/main/Repartition.ps1" -OutFile "C:\ProgramData\TMT\Partition\Repartition.ps1"
Invoke-expression -Command $PartitionFile
Update-ProgressBar
# $b = $a.popup("Repartition Successful. Press OK to continue",5,"Configuration is in Progress",0x0)




$FolderRedirectionFolder = "C:\ProgramData\TMT\FolderRedirection"
If (Test-Path $FolderRedirectionFolder) {
}
Else {
    New-Item -Path "$FolderRedirectionFolder" -ItemType Directory
}

$FolderRedirectionFile = "C:\ProgramData\TMT\FolderRedirection\FolderRedirectionDownload.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/FolderRedirection/main/FolderRedirectionDownload.ps1" -OutFile "C:\ProgramData\TMT\FolderRedirection\FolderRedirectionDownload.ps1"
Invoke-expression -Command $FolderRedirectionFile
Update-ProgressBar
# $b = $a.popup("Folder Redirection Changes Successful. Press OK to continue",5,"Configuration is in Progress",0x0)




$ChangeComputerNameFolder = "C:\ProgramData\TMT\ChangeComputerName"
If (Test-Path $ChangeComputerNameFolder) {
}
Else {
    New-Item -Path "$ChangeComputerNameFolder" -ItemType Directory
}


$ChangeComputerNameFile = "C:\ProgramData\TMT\ChangeComputerName\PCSChangeComputerName.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/ChangeComputerName/main/PCSChangeComputerName.ps1" -OutFile "C:\ProgramData\TMT\ChangeComputerName\PCSChangeComputerName.ps1"
Invoke-expression -Command $ChangeComputerNameFile
Update-ProgressBar
# $b = $a.popup("Change Computer Name Successful. Press OK to continue",5,"Configuration is in Progress",0x0)




$RemoveHPBloatwareFolder = "C:\ProgramData\TMT\RemoveHPBloatware"
If (Test-Path $RemoveHPBloatwareFolder) {
}
Else {
    New-Item -Path "$RemoveHPBloatwareFolder" -ItemType Directory
}


$RemoveHPBloatwareFile = "C:\ProgramData\TMT\RemoveHPBloatware\RemoveHPBloatware.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/HPBloatwareRemover/main/RemoveHPBloatware.ps1" -OutFile "C:\ProgramData\TMT\RemoveHPBloatware\RemoveHPBloatware.ps1"
Invoke-expression -Command $RemoveHPBloatwareFile
Update-ProgressBar
# $b = $a.popup("Remove HP Bloatware Successful. Press OK to continue",5,"Configuration is in Progress",0x0)



$WindowsDebloatFolder = "C:\ProgramData\TMT\WindowsDebloat"
If (Test-Path $WindowsDebloatFolder) {
}
Else {
    New-Item -Path "$WindowsDebloatFolder" -ItemType Directory
}


$WindowsDebloatFile = "C:\ProgramData\TMT\WindowsDebloat\Debloat.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/WindowsBloatware/main/Debloat.ps1" -OutFile "C:\ProgramData\TMT\WindowsDebloat\Debloat.ps1"
Invoke-expression -Command $WindowsDebloatFile
Update-ProgressBar
# $b = $a.popup("Remove Windows Bloatware Successful. Press OK to continue",5,"Configuration Status",0x0)

New-Item -Path "C:\ProgramData\TMT\MasterScriptDone1.0.txt"
New-Item -Path "C:\ProgramData\TMT\Done1.0.txt"

$b = $a.popup("The configuration is complete.  You may now use your computer after the reboot. Press OK to reboot",-1,"Configuration Status",0x0)

Start-Sleep -Seconds 30
Restart-Computer -Force
}

