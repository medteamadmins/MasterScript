#New-Item -Path "C:\MasterScriptIsStarting.txt"

#----------------------------------------------------------------------------

#Progress Bar
Add-Type -AssemblyName System.Windows.Forms

# Create a form
$form = New-Object Windows.Forms.Form
$form.Text = "Configuration is in Progress"
$form.Size = New-Object Drawing.Size(300, 100)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $False
$form.MinimizeBox = $False

# Create a progress bar
$progressBar = New-Object Windows.Forms.ProgressBar
$progressBar.Maximum = 8
$progressBar.Value = 0
$progressBar.Location = New-Object Drawing.Point(10, 30)
$progressBar.Width = 360

# Create a label
$label = New-Object Windows.Forms.Label
$label.Text = "Status:"
$label.Location = New-Object Drawing.Point(10, 10)

# Add controls to the form
$form.Controls.Add($label)
$form.Controls.Add($progressBar)

# Function to update the progress bar
function Update-ProgressBar {
    if ($progressBar.Value -lt $progressBar.Maximum) {
        $progressBar.Value++    }
    else {
        $timer.Stop()
        $form.Close()
    }
}

# -----------------------------SCRIPT STARTING---------------------------------------------------

$MasterScriptDone = "C:\Users\$($ENV:USERNAME)\AppData\MasterScriptDone1.0.txt" # DO NOT DELETE.

$a = new-object -comobject wscript.shell

# Declare expected users in the Local Admin Group
$expectedMembers = @("Medtrator", "S-1-12-1-1605978423-1201099401-1932580286-3281254816")

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
$b = $a.popup("Please DO NOT USE this computer at this moment. We are setting up this computer. It will require a restart when complete. Press OK to begin the setup",-1,"Configuration Status",0x0)

$form.Show()

#-------------------------------STEP BEIN--------------------------------------------------------------------------------------------------


# Step 1: Local Admin Group
$LocalAdminGroupFolder = "C:\ProgramData\TMT\LocalAdminGroup"
If (Test-Path $LocalAdminGroupFolder) {
}
Else {
    New-Item -Path "$LocalAdminGroupFolder" -ItemType Directory
}

$LocalAdminGroupFile = "C:\ProgramData\TMT\LocalAdminGroup\RemoveUsersFromLocalAdminGroup.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/LocalAdminGroup/main/RemoveUsersFromLocalAdminGroup.ps1" -OutFile "C:\ProgramData\TMT\LocalAdminGroup\RemoveUsersFromLocalAdminGroup.ps1"
Invoke-expression -Command $LocalAdminGroupFile

#Update progress Bar
Update-ProgressBar


# Step 2: RE-PARTITION
$PartitionFolder = "C:\ProgramData\TMT\Partition"
If (Test-Path $PartitionFolder) {
}
Else {
    New-Item -Path "$PartitionFolder" -ItemType Directory
}

$PartitionFile = "C:\ProgramData\TMT\Partition\Repartition.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/Repartition/main/Repartition.ps1" -OutFile "C:\ProgramData\TMT\Partition\Repartition.ps1"
Invoke-expression -Command $PartitionFile

#Update progress Bar
Update-ProgressBar


# Step 3: Folder Redirection
$FolderRedirectionFolder = "C:\ProgramData\TMT\FolderRedirection"
If (Test-Path $FolderRedirectionFolder) {
}
Else {
    New-Item -Path "$FolderRedirectionFolder" -ItemType Directory
}

$FolderRedirectionFile = "C:\ProgramData\TMT\FolderRedirection\FolderRedirectionDownload.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/FolderRedirection/main/FolderRedirectionDownload.ps1" -OutFile "C:\ProgramData\TMT\FolderRedirection\FolderRedirectionDownload.ps1"
Invoke-expression -Command $FolderRedirectionFile

#Update progress Bar
Update-ProgressBar


# Step 4: Re-Name The Computer
$ChangeComputerNameFolder = "C:\ProgramData\TMT\ChangeComputerName"
If (Test-Path $ChangeComputerNameFolder) {
}
Else {
    New-Item -Path "$ChangeComputerNameFolder" -ItemType Directory
}

$ChangeComputerNameFile = "C:\ProgramData\TMT\ChangeComputerName\PCSChangeComputerName.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/ChangeComputerName/main/PCSChangeComputerName.ps1" -OutFile "C:\ProgramData\TMT\ChangeComputerName\PCSChangeComputerName.ps1"
Invoke-expression -Command $ChangeComputerNameFile

#Update progress Bar
Update-ProgressBar


# Step 5: Remove HP Bloatware.
$RemoveHPBloatwareFolder = "C:\ProgramData\TMT\RemoveHPBloatware"
If (Test-Path $RemoveHPBloatwareFolder) {
}
Else {
    New-Item -Path "$RemoveHPBloatwareFolder" -ItemType Directory
}

$RemoveHPBloatwareFile = "C:\ProgramData\TMT\RemoveHPBloatware\RemoveHPBloatware.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/HPBloatwareRemover/main/RemoveHPBloatware.ps1" -OutFile "C:\ProgramData\TMT\RemoveHPBloatware\RemoveHPBloatware.ps1"
Invoke-expression -Command $RemoveHPBloatwareFile

#Update progress Bar
Update-ProgressBar


# Step 6: Remove Windows Debloat.
$WindowsDebloatFolder = "C:\ProgramData\TMT\WindowsDebloat"
If (Test-Path $WindowsDebloatFolder) {
}
Else {
    New-Item -Path "$WindowsDebloatFolder" -ItemType Directory
}

$WindowsDebloatFile = "C:\ProgramData\TMT\WindowsDebloat\Debloat.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/medteamadmins/WindowsBloatware/main/Debloat.ps1" -OutFile "C:\ProgramData\TMT\WindowsDebloat\Debloat.ps1"
Invoke-expression -Command $WindowsDebloatFile

#Update progress Bar
Update-ProgressBar

# Copy Remote Desktop shortcut to Desktop
cp "C:\Users\$($ENV:USERNAME)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Remote Desktop.lnk" "D:\$($ENV:USERNAME)\Desktop"

New-Item -Path "C:\Users\$($ENV:USERNAME)\AppData\MasterScriptDone1.0.txt" # DO NOT DELETE.
New-Item -Path "C:\Users\$($ENV:USERNAME)\AppData\Done1.0.txt" # DO NOT DELETE.

Start-Sleep -Seconds 2

$form.Close()

# Display a message box to ask users for a reboot.
$result = [System.Windows.Forms.MessageBox]::Show("The configuration is complete. You may now use your computer after the reboot. Press OK to reboot", "Reboot Confirmation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
# Check the user's choice
	if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
		# Reboot the computer
		Restart-Computer -Force
	} else {
    # User canceled, do nothing
	}

# -----------------------------------SCRIPT END-------------------------

}
