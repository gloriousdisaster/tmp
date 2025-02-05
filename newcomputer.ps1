<#
.SYNOPSIS
  A PowerShell script to automatically enable Hyper-V, WSL 2, and VirtualMachinePlatform,
  install Debian WSL, and install various applications via winget. If a reboot is required,
  it creates a one-time Scheduled Task to resume the script automatically after the system
  restarts.

.DESCRIPTION
  1. Ensures the script runs with Administrator privileges.
  2. Checks Windows version to ensure WSL 2 compatibility (Windows 10 19041+ or Windows 11).
  3. Enables the following Windows features if not already enabled:
     - Hyper-V
     - Windows Subsystem for Linux
     - VirtualMachinePlatform
  4. If any feature changes require a restart, creates a one-time Scheduled Task that runs
     this script automatically on system startup with SYSTEM privileges. Then reboots.
  5. After reboot, the script resumes:
     - Sets the default WSL version to 2.
     - Installs Debian WSL if not already installed.
     - Installs applications via winget (logs output to a file on the Desktop).
  6. Removes the Scheduled Task when complete so it does not run on every startup.

IMPORTANT 
  Computers with VScode Installed
  Visual Studio Code Remote Tunnels are a legitimate feature that enables remote
  access to endpoints. For threat actors - VSCode tunnels enable them to bypass 
  security protocols, facilitating lateral movement and data exfiltration.

  To prevent this on a single computer, add the following to the host file.
  # C:\Windows\System32\drivers\etc

  0.0.0.0     tunnels.api.visualstudio.com
  0.0.0.0     devtunnels.ms
  
  #END
#>

# --- Recommended additions for better script hygiene ---
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Check for Administrator Privileges ---
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: This script must be run as Administrator. Please restart PowerShell with elevated privileges." -ForegroundColor Red
    exit 1
}

# --- Optional: Check Windows version for WSL2 compatibility (Windows 10 build 19041 or later) ---
$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Major -lt 10 -or ($osVersion.Major -eq 10 -and $osVersion.Build -lt 19041)) {
    Write-Host "ERROR: WSL 2 requires Windows 10 build 19041 or later. Detected version: $osVersion" -ForegroundColor Red
    exit 1
}

# --- Helper Function to create a one-time Scheduled Task to resume script after reboot ---
function New-OneTimeScheduledTask {
    param (
        [Parameter(Mandatory)]
        [string]$TaskName,

        [Parameter(Mandatory)]
        [string]$ScriptPath
    )

    Write-Host "Creating a scheduled task '$TaskName' to run this script after reboot..."

    # 1. Create an Action: Powershell.exe with your script path
    #    - Using ExecutionPolicy Bypass to ensure it runs even if local policy is more restrictive.
    #    - Use double-quotes around the file path if it contains spaces.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

    # 2. Create a Trigger: at startup (i.e., when the system boots up).
    $trigger = New-ScheduledTaskTrigger -AtStartup

    # 3. Specify the Principal to run with the highest privileges under the SYSTEM account.
    #    This avoids UAC prompts and ensures the script has full elevation automatically.
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -RunLevel Highest

    # 4. Register the Scheduled Task with the system.
    #    - If a task with the same name exists, you can update it. Otherwise, creation will fail if it already exists.
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force

    Write-Host "Scheduled Task '$TaskName' created successfully."
}

# Identify the path to this script (so the scheduled task can run the exact same script).
$scriptPath = $MyInvocation.MyCommand.Definition

# Name for the temporary scheduled task. 
# (You can customize as needed—just make sure to match it in Unregister-ScheduledTask below.)
$taskName = "ResumeWSLSetupTask"

# --- We use a flag to check if we've resumed after a reboot.
#     This helps us know if we should remove the scheduled task at the end.
$hasResumed = $false

# We can detect if we are running in "post-reboot" scenario by checking if the task still exists.
# If it does, we assume we resumed from that scheduled task. 
# If the script is run manually again, the user might see a message but it's harmless.
try {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($existingTask) {
        Write-Host "Detected a previously created scheduled task '$taskName'. Assuming this script is resuming post-reboot..."
        $hasResumed = $true
    }
} catch {
    # No scheduled task found, so this is the first run or a normal run.
    $hasResumed = $false
}

# --- Step 1-3: Enable Hyper-V, WSL, and Virtual Machine Platform ---
$needRestart = $false

# Define features and labels for easy iteration
$features = @(
    @{ Name = "Microsoft-Hyper-V";                 Label = "Hyper-V" },
    @{ Name = "Microsoft-Windows-Subsystem-Linux"; Label = "Windows Subsystem for Linux" },
    @{ Name = "VirtualMachinePlatform";            Label = "Virtual Machine Platform" }
)

foreach ($feature in $features) {
    $result = Get-WindowsOptionalFeature -Online -FeatureName $feature.Name
    if ($result.State -ne "Enabled") {
        Write-Host "Enabling $($feature.Label)..."
        Enable-WindowsOptionalFeature -Online -FeatureName $feature.Name -All -NoRestart
        $needRestart = $true
    }
}

# If any features were enabled, we must reboot before continuing.
# We'll create the scheduled task to resume automatically.
if ($needRestart -and -not $hasResumed) {
    Write-Host "One or more system features were just enabled. A restart is required."

    # Create scheduled task to run this script after reboot
    New-OneTimeScheduledTask -TaskName $taskName -ScriptPath $scriptPath

    Write-Host "Rebooting in 5 seconds..."
    shutdown /r /t 5
    exit 0
}
elseif ($needRestart -and $hasResumed) {
    # This is an edge case: if the user re-runs the script or something else changed in between?
    # Usually we wouldn't expect to need a second reboot. 
    # We'll just proceed, but you could handle differently if needed.
    Write-Host "We resumed from a reboot but still see that features were enabled. Proceeding..."
}

# By this point, if a reboot was needed, the script either:
# - Already set up the task + rebooted (and is now continuing).
# - Or, we are continuing in the same session if no reboot was needed.

# --- Step 4: Set WSL default version to 2 ---
Write-Host "Setting WSL default version to 2..."
wsl --set-default-version 2

# --- Step 5: Install Debian for WSL if not already installed ---
$installedDistros = wsl -l -q
if (-not ($installedDistros -match "Debian")) {
    Write-Host "Debian is not installed in WSL. Installing Debian..."
    wsl --install -d Debian
    Write-Host "Debian has been installed for WSL. If you encounter issues, a reboot may be required." -ForegroundColor Yellow
} else {
    Write-Host "Debian is already installed in WSL."
}

# --- Step 6: Install applications using winget ---
# Ensure winget is available
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: winget is not installed. Please install winget before proceeding." -ForegroundColor Red
    exit 1
}

# Define the list of apps to install
$apps = @(
    "Microsoft.PowerShell"          # PowerShell
    "Microsoft.WindowsTerminal"     # Windows Terminal
    "Google.Chrome"                 # Google Chrome
    "Mozilla.Firefox"               # Mozilla Firefox
    "7zip.7zip"                     # 7-Zip
    "Notepad++.Notepad++"           # Notepad++
    "Git.Git"                       # Git
    "Microsoft.VisualStudioCode"    # Visual Studio Code
    "VideoLAN.VLC"                  # VLC Media Player
    "Spotify.Spotify"               # Spotify
    "Docker.DockerDesktop"          # Docker Desktop
    "SimonTatham.Putty"             # PuTTY
    "OBSProject.OBSStudio"          # OBS Studio
    "obsidian.Obsidian"             # Obsidian
    "Signal.Signal"                 # Signal
    "Plex.Plexamp"                  # Plexamp
    "AnacondaInc.Anaconda3"         # Anaconda
)

# Define the log file location (on Desktop)
$logFile = "$env:USERPROFILE\Desktop\winget_install_log.txt"
New-Item -ItemType File -Path $logFile -Force | Out-Null

# Install each application via winget
foreach ($app in $apps) {
    Write-Host "Installing $app..."

    # Capture winget output and exit code
    $wingetOutput = winget install --id=$app --silent --accept-source-agreements --accept-package-agreements 2>&1 |
                    Tee-Object -FilePath $logFile -Append

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installation failed for $app with exit code: $LASTEXITCODE" -ForegroundColor Red
        # Decide whether to break or continue installing the rest:
        # break
    }
}

Write-Host "All installations have been initiated. Please check the log file at: $logFile" -ForegroundColor Green

# --- Remove the scheduled task if we're resuming after reboot ---
# This ensures the script does not run on every startup going forward.
if ($hasResumed) {
    Write-Host "Attempting to remove the scheduled task '$taskName' so it does not run again..."
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host "Scheduled task '$taskName' removed successfully."
    } catch {
        Write-Host "Warning: Unable to remove the scheduled task '$taskName'. Error: $_"
    }
}
