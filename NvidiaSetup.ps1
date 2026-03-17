<#
    NVIDIA SETUP SCRIPT (Run as Administrator)
#>

param (
    [int]$ForceStep = 0,    # Force execution from a specific step
    [int]$StopAfterStep = 0 # 0 = Run to end, >0 = Stop immediately after this step index
)

$Dependencies = @("Utils.ps1", "WindowsIds.ps1", "WindowsHW.ps1", "NvidiaIds.ps1", "NvidiaHelpers.ps1", "Networking.ps1", "Logging.ps1", "Wsus.ps1")

foreach ($File in $Dependencies) {
    $FilePath = Join-Path $PSScriptRoot $File
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        Throw "Critical Error: Dependency '$File' not found at $FilePath"
    }
}

function Install-NvidiaDriverBare {
    <#
    .SYNOPSIS
        Downloads and installs a stripped-down NVIDIA driver.
        Returns $true if a new driver was actually installed, otherwise $false.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [WindowsVersionKey]$WinVer,
        [switch]$Clean = $false,
        [string]$DownloadFolder = $null
    )

    Write-Log "Nvidia Driver Setup (Bare Installation)..." -Level STEP

    # --- 1. Hardware Detection & API Check ---
    try {
        Write-Log "Checking Hardware and Requirements" -Level INFO
        $gpus = Get-HardwareByVid -Vid $GLOBAL_VID_NVIDIA

        if ($gpus.Count -eq 0) {
            Write-Log "No NVIDIA hardware detected. Skipping." -Level INFO -SubStep
            return [DriverInstallationResult]::NoInstall
        }

        $gpu = $gpus[0]
        if ($gpus.Count -gt 1) {
            Write-Log "Detected multiple NVIDIA GPUs. Using $($gpu.Caption) as primary." -Level INFO -SubStep
        }

        # Local Status & Provider Check
        $currentVersion = Format-NvidiaVersion -WmiVersion $gpu.DriverVersion
        $isNvidia = ($gpu.ProviderName -match "NVIDIA") -or 
                    ($gpu.Caption -match "NVIDIA") -or 
                    ($gpu.VideoProcessor -match "NVIDIA")

        # Remote Status Check
        $pfid = Get-NvidiaPfid -Gpu $gpu
        $osId = Get-NvidiaApiOsId -WinVer $WinVer
        $latestVersion = Get-NvidiaLatestVersion -Pfid $pfid -OsId $osId

        if ($null -eq $latestVersion) {
            Write-Log "Aborting: Could not determine latest version from API." -Level ERROR
            return [DriverInstallationResult]::NoInstall
        }

        # Logic & Decision Making
        $provider = if ($isNvidia) { "NVIDIA" } else { "Microsoft/Generic/Other" }
        Write-Log "Status: [Provider: $provider] | [Installed: $currentVersion] | [Latest: $latestVersion]" -Level INFO

        # Check if already up-to-date
        if ($isNvidia -and ($currentVersion -eq $latestVersion)) {
            Write-Log "NVIDIA Driver is already up-to-date ($currentVersion)." -Level SUCCESS
            return [DriverInstallationResult]::SameVersion
        }

        # Final Action Message
        if (!$isNvidia) {
            Write-Log "Action Required: Current driver is NOT NVIDIA software. Deployment required." -Level WARN
        } else {
            Write-Log "Action Required: Update available ($currentVersion -> $latestVersion)." -Level INFO
        }
    } 
    catch {
        Write-Log "Nvidia API/Hardware check failed: $($_.Exception.Message)" -Level ERROR
        return [DriverInstallationResult]::NoInstall
    }

    # --- 2. Download & Extraction ---
    try {
        Write-Log "Preparing Installation Environment" -Level INFO
        if ([string]::IsNullOrWhiteSpace($DownloadFolder)) {
            $DownloadFolder = Join-Path $env:TEMP "NvidiaUpdate"
        }

        if (Test-Path $DownloadFolder) {
            Write-Log "Cleaning up existing download folder: $DownloadFolder" -Level INFO -SubStep
            Get-ChildItem $DownloadFolder | Where-Object { $_.Name -ne "7zr.exe" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "Creating download directory: $DownloadFolder" -Level INFO -SubStep
            New-Item $DownloadFolder -ItemType Directory -Force | Out-Null
        }

        Write-Log "Working Directory set to: $DownloadFolder" -Level INFO -SubStep
        $extractPath = Join-Path $DownloadFolder "Extracted"
        $sevenZipExe = Join-Path $DownloadFolder "7zr.exe"

        # 7-Zip Setup
        if (!(Get-SevenZipHelper -DestinationPath $sevenZipExe)) {
            throw "Abort: Required helper tool (7-Zip) could not be acquired."
        }
    
        # Driver Download
        $dlPath = Get-NvidiaDriverFile -Version $latestVersion -DestinationFolder $DownloadFolder -WinVer $WinVer
        
        if ($null -eq $dlPath) {
            throw "Driver download failed."
        }

        # Extraction
        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force | Out-Null }
        Write-Log "Extracting to: $extractPath" -Level INFO
        $extractArgs = "x `"$dlPath`" -o`"$extractPath`" -y"
        $extProcess = Start-Process -FilePath $sevenZipExe -ArgumentList $extractArgs -Wait -WindowStyle Hidden -PassThru
        if ($extProcess.ExitCode -ne 0) { throw "Extraction failed." }

        # 3. Component Selection (The "Bare" part)
        # We manually remove folders we don't want before starting the setup
        # need to further inspect setup.cfg before precise debloat can be applied
        # until then this stays
        $bloatFolders = @("GFExperience", "NVFans", "Node.js", "NvTelemetry", "Update.Core")
        Write-Log "Stripping unnecessary components..." -Level INFO
        foreach ($folder in $bloatFolders) {
            $path = Join-Path $extractPath $folder
            if (Test-Path $path) { 
                Remove-Item $path -Recurse -Force | Out-Null
                Write-Log "Deleted $folder" -Level INFO -SubStep
            }
        }

        # --- 3. Deep Debloat (XML & Folder Stripping) ---
        #Write-Log "Deep Stripping setup.cfg (Removing App & Telemetry blocks)..." -Level INFO
        #$cfgPath = Join-Path $extractPath "setup.cfg"
        #if (Test-Path $cfgPath) {
        #    [xml]$cfg = Get-Content $cfgPath
        #
        #    $toNuke = @(
        #        "Display.NvApp", "NvContainer", "NvContainer.LocalSystem", 
        #        "NvContainer.Session", "NvContainer.User", "NvPlugin.Watchdog",
        #        "VirtualAudio.Driver", "ShadowPlay", "Display.NVWMI", 
        #        "FrameViewSdk", "Display.NvApp.MessageBus", "Display.NvApp.NvBackend", 
        #        "Display.NvApp.NvCPL", "NvDLISR", "NvTelemetry"
        #    )
        #
        #    $installNode = $cfg.setup.install
        #    foreach ($name in $toNuke) {
        #        $node = $installNode.SelectSingleNode("sub-package[@name='$name']")
        #        if ($node) { [void]$installNode.RemoveChild($node) }
        #    }
        #
        #    $cfg.setup.strings.ChildNodes | Where-Object { $_.name -match 'PrivacyPolicyFile|FunctionalConsentFile|EulaHtmlFile|CheckForUpdates' } | ForEach-Object { [void]$_.ParentNode.RemoveChild($_) }
        #
        #    $cfg.Save($cfgPath)
        #}

        #$bloatFolders = @(
        #    "GFExperience", "NvTelemetry", "Update.Core", "Display.Update", "NvApp",
        #    "NVFans", "Node.js", "NvVAD", "ShieldWirelessController", "NvAbp", "NvBackend"
        #)
        #foreach ($folder in $bloatFolders) {
        #    $p = Join-Path $extractPath $folder
        #    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        #}

        # --- 4. Installation ---
        Write-Log "Executing Setup: $extractPath\setup.exe" -Level INFO
        $installArgs = @("-passive", "-noreboot", "-noeula", "-nofinish", "-s")
        if ($Clean) { $installArgs += "-clean" }
        
        $process = Start-Process -FilePath "$extractPath\setup.exe" -ArgumentList $installArgs -Wait -PassThru
        Write-Log "NVIDIA Setup finished with ExitCode: $($process.ExitCode)" -Level INFO
        
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            throw "Installation failed (Code $($process.ExitCode))."
        }

        # --- 5. Post-Install Cleanup ---
        Write-Log "Final Telemetry Removal..." -Level INFO
        Get-ScheduledTask -TaskPath "\" -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match "NvTm|Nvidia" } | ForEach-Object {
            Write-Log "Unregistering Task: $($_.TaskName)" -Level INFO -SubStep
            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        $badServices = @("NvTelemetryContainer", "NvDbuls", "NvContainerLocalSystem")
        foreach ($s in $badServices) { 
            if (Get-Service $s -ErrorAction SilentlyContinue) { 
                Write-Log "Deleting service: $s" -Level INFO -SubStep
                Stop-Service $s -Force -ErrorAction SilentlyContinue
                sc.exe delete $s | Out-Null
            } 
        }

        Write-Log "Nvidia Bare Driver v$latestVersion installed successfully." -Level SUCCESS
        return [DriverInstallationResult]::Install
    }
    catch { 
        Write-Log "Critical Error: $($_.Exception.Message)" -Level ERROR 
        return [DriverInstallationResult]::NoInstall
    }
    finally { 
        if (Test-Path $DownloadFolder) { 
            Write-Log "Cleaning up temporary files..." -Level INFO
            Remove-Item $DownloadFolder -Recurse -Force -ErrorAction SilentlyContinue 
        } 
    }
}

function Set-WindowsGPUTweaks {
    <#
    .SYNOPSIS
        Applies OS-level GPU optimizations.
        Includes HAGS and the universal MPO disable for stability.
    #>
    Write-Log "Applying Universal Windows GPU Tweaks..." -Level STEP

    try {
        # 1. Disable Multi-Plane Overlay (MPO)
        # Universal DWM tweak. Prevents flickering/stuttering in browsers & apps.
        Write-Log "Disabling MPO (Multi-Plane Overlay)..." -Level INFO -SubStep
        $dwmPath = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
        if (!(Test-Path $dwmPath)) { New-Item $dwmPath -Force | Out-Null }
        Set-ItemProperty -Path $dwmPath -Name "OverlayTestMode" -Value 5 -Type Dword

        # 2. Enable Hardware Accelerated GPU Scheduling (HAGS)
        Write-Log "Enabling HAGS..." -Level INFO -SubStep
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Force

        # 3. Disable Transparency & Game DVR
        #Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -Force
        Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Force
        
        Write-Log "Success: Universal GPU optimizations applied." -Level SUCCESS
    }
    catch {
        Write-Log "Failed to apply Windows GPU tweaks: $($_.Exception.Message)" -Level WARN
    }
}

function Set-NvidiaRegistryTweaks {
    <#
    .SYNOPSIS
        Applies NVIDIA-specific hardware tweaks.
    #>
    Write-Log "Applying NVIDIA-specific Hardware Tweaks..." -Level STEP

    # 1. Force Full RGB Range (0-255)
    $gpuClassPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    $instances = Get-ChildItem -Path $gpuClassPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^\d{4}$" }

    foreach ($instance in $instances) {
        Write-Log "Setting Full RGB for Instance: $($instance.PSChildName)" -Level INFO -SubStep
        Set-ItemProperty -Path $instance.PSPath -Name "VPrG_OutputRange" -Value 1 -ErrorAction SilentlyContinue
    }

    # 2. Disable NVIDIA Telemetry (If exists)
    $telemetryPath = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry"
    if (Test-Path $telemetryPath) {
        Write-Log "Disabling Telemetry in Registry Hive..." -Level INFO -SubStep
        Set-ItemProperty -Path $telemetryPath -Name "FeatureControl" -Value 0 -Type Dword -ErrorAction SilentlyContinue
    }

    Write-Log "Success: NVIDIA-only tweaks applied." -Level SUCCESS
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

Enum DriverInstallationResult {
    NoInstall
    Install
    SameVersion
}

Write-Log "Starting System-Level Setup" -Level STEP

Assert-Admin

# --- IMPORTANT PRE-FLIGHT NOTICE ---
Write-Host "`n"
Write-Host "****************************************************************" -ForegroundColor Yellow
Write-Host "  ATTENTION: CLEAN INSTALL RECOMMENDED" -ForegroundColor Yellow
Write-Host "  1. Uninstall old drivers (ideally using DDU)." -ForegroundColor White
Write-Host "  2. Restart your system." -ForegroundColor White
Write-Host "  3. Run this script immediately after reboot." -ForegroundColor White
Write-Host "****************************************************************" -ForegroundColor Yellow
Write-Host "`n"

if ($ForceStep -gt 0) { 
    Write-Log "Manual Override: Starting at Step $ForceStep" -Level WARN 
}

$installResult = [DriverInstallationResult]::NoInstall

# 1. Prepare Windows
if (Confirm-StepExecution "Prepare Windows" 1 $StopAfterStep) {
    Disable-AutomaticDriverInstallation
    Clear-WindowsUpdateCache
}

# 2. Hardware & Driver Setup
if (Confirm-StepExecution "Hardware & Driver Setup" 2 $StopAfterStep) {
    $winVer = Get-CurrentWindowsVersion
    $installResult = Install-NvidiaDriverBare -WinVer $winVer -Clean $Clean
    #Install-NvidiaProfileInspector
    #Install-MultiMonitorTool 
}

# 3. Final System Optimization & Performance
if (Confirm-StepExecution "Final System Optimization" 3 $StopAfterStep) {
    if ($installResult -ne [DriverInstallationResult]::NoInstall) {
        Set-WindowsGPUTweaks
        Set-NvidiaRegistryTweaks
        #Set-NvidiaProfileSettings
        #Set-MonitorLayout 
    } 
    else {
        Write-Log "Skipping Optimization: No successful driver installation detected." -Level WARN
    }
}

Remove-ProgressFile

$shouldReboot = $installResult -eq [DriverInstallationResult]::Install

if ($shouldReboot) {
    $cancelled = Wait-ForKeyOrTimeout -Timeout 30 -Message "Changes require a restart. Rebooting in"

    if ($cancelled) {
        Write-Log "Reboot cancelled by user. Please restart manually to apply all tweaks." -Level WARN
    } else {
        Write-Log "Initiating system restart..." -Level INFO
        Restart-Computer -Force
    }
} 
else {
    if ($installResult -eq [DriverInstallationResult]::SameVersion) {
        Write-Log "Execution finished: Everything up to date. No reboot needed." -Level SUCCESS
    } else {
        Write-Log "Execution finished: No changes were made." -Level INFO
    }
}