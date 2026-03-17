<#
    NVIDIA SETUP SCRIPT (Run as Administrator)
#>

param (
    [int]$ForceStep = 0,    # Force execution from a specific step
    [int]$StopAfterStep = 0 # 0 = Run to end, >0 = Stop immediately after this step index
)

$UtilsPath = Join-Path $PSScriptRoot "Utils.ps1"
if (Test-Path $UtilsPath) { . $UtilsPath } else { Throw "Critical Error: Utils.ps1 not found!" }

# Global Mapping for NVIDIA Driver API osID parameter
# Matches internal IDs used by NVIDIA AjaxDriverService.php
$GLOBAL_NVIDIA_OS_IDS = @{
    $GLOBAL_OS_KEYS.WIN11    = 135
    $GLOBAL_OS_KEYS.WIN10_64 = 57
    $GLOBAL_OS_KEYS.WIN10_32 = 56
    $GLOBAL_OS_KEYS.SRV2022  = 138
    $GLOBAL_OS_KEYS.SRV2019  = 113
}

# Vendor ID (VID)
$GLOBAL_VID_NVIDIA = "10DE"

# This map links the Hardware Device ID (DEV_XXXX) to the specific 
# Nvidia Product Family ID (PFID) required for their Ajax Driver API.
$GLOBAL_NVIDIA_PID_MAP = @{
    # --- RTX 50 Series (Blackwell) ---
    "2D01" = "1045"; # RTX 5090
    "2D02" = "1047"; # RTX 5080
    
    # --- RTX 40 Series (Ada Lovelace) ---
    "2684" = "1005"; # RTX 4090
    "2704" = "1013"; # RTX 4080
    "2703" = "1013"; # RTX 4080 Super
    "2782" = "973";  # RTX 4070 Ti
    "2706" = "973";  # RTX 4070
    "2786" = "967";  # RTX 4070 Super
    "2811" = "957";  # RTX 4060 Ti
    "2882" = "956";  # RTX 4060
    
    # --- RTX 30 Series (Ampere) ---
    "2204" = "933";  # RTX 3090
    "2208" = "933";  # RTX 3090 Ti
    "2206" = "929";  # RTX 3080
    "2216" = "929";  # RTX 3080 Ti
    "220A" = "929";  # RTX 3080 12GB
    "2484" = "911";  # RTX 3070
    "2488" = "911";  # RTX 3070 Ti
    "2486" = "903";  # RTX 3060 Ti
    "2503" = "903";  # RTX 3060
    "2504" = "903";  # RTX 3060 (LHR)

    # --- RTX 20 Series (Turing) ---
    "1E04" = "845";  # RTX 2080 Ti
    "1E07" = "845";  # RTX 2080 Super
    "1E82" = "834";  # RTX 2080
    "1E87" = "834";  # RTX 2070 Super
    "1F02" = "834";  # RTX 2070

    # --- GTX 10 Series (Pascal) ---
    "1B80" = "815";  # GTX 1080
    "1B81" = "815";  # GTX 1070
    "1B82" = "821";  # GTX 1080 Ti
    "1B83" = "815";  # GTX 1070 Ti
    "1C02" = "816";  # GTX 1060 3GB
    "1C03" = "816";  # GTX 1060 6GB
    "1C81" = "818";  # GTX 1050
    "1C82" = "818";  # GTX 1050 Ti

    # --- GTX 900 Series (Maxwell) ---
    "17C2" = "751";  # GTX TITAN X (Maxwell)
    "17C8" = "751";  # GTX 980 Ti
    "13C0" = "744";  # GTX 980
    "13C2" = "744";  # GTX 970
    "1401" = "747";  # GTX 960
    "1402" = "747"   # GTX 950
}

function Clear-WindowsUpdateCache {
    <#
    .SYNOPSIS
        Purges the Windows Update cache using Robocopy to bypass MAX_PATH (260 character) limitations.
    #>
    Write-Log "Purging Windows Update Cache..." -Level STEP

    $Services = @("wuauserv", "bits", "dosvc")
    $cachePath = "C:\Windows\SoftwareDistribution\Download"
    $emptyDir = Join-Path $env:TEMP "EmptyDirForPurge"

    try {
        # 1. Stop Services
        foreach ($Service in $Services) {
            if ((Get-Service -Name $Service -ErrorAction SilentlyContinue).Status -eq 'Running') {
                Write-Log "Stopping $Service..." -Level INFO
                Stop-Service -Name $Service -Force -ErrorAction SilentlyContinue
            }
        }

        # 2. Use Robocopy to purge the folder (The "Nuclear Option" for long paths)
        if (Test-Path $cachePath) {
            Write-Log "Executing Robocopy purge on $cachePath..." -Level INFO
            
            # Create a temporary empty directory
            if (!(Test-Path $emptyDir)) { New-Item $emptyDir -ItemType Directory -Force | Out-Null }
            
            # /PURGE deletes everything in the destination that isn't in the source (empty)
            # /NJH /NJS /NDL /NC /NS hides the spammy robocopy logs
            robocopy $emptyDir $cachePath /PURGE /NJH /NJS /NDL /NC /NS /MT:16 | Out-Null
            
            # Cleanup the empty helper dir
            Remove-Item $emptyDir -Force -Recurse -ErrorAction SilentlyContinue
            
            Write-Log "Update cache cleared successfully." -Level SUCCESS
        }
    } catch {
        Write-Log "Failed to clear Update Cache: $($_.Exception.Message)" -Level ERROR
    }finally {
        # 3. Restart Services
        Write-Log "Restarting update services..." -Level INFO
        foreach ($Service in $Services) {
            Set-Service -Name $Service -StartupType Manual -ErrorAction SilentlyContinue
            Start-Service -Name $Service -ErrorAction SilentlyContinue
        }

        if (Test-Path $emptyDir) { Remove-Item $emptyDir -Force -Recurse -ErrorAction SilentlyContinue }
        Write-Log "Update services are back online." -Level SUCCESS
    }
}

function Disable-AutomaticDriverInstallation {
    <#
    .SYNOPSIS
        Prevents Windows Update from automatically downloading and installing hardware drivers.
        Includes Registry, Policy, and Metadata settings.
    #>
    
    # Check for Admin rights
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Please run this script as Administrator!" -Level ERROR
        return
    }

    Write-Log "Configuring Driver Update Policy..." -Level STEP

    try {
        # 1. Disable Driver Searching (corresponds to sysdm.cpl "No" setting)
        $dsPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"
        if (!(Test-Path $dsPath)) { New-Item -Path $dsPath -Force | Out-Null }
        Set-ItemProperty -Path $dsPath -Name "SearchOrderConfig" -Value 0 -Type DWord -ErrorAction Stop
        Write-Log "Set SearchOrderConfig to 0 (Manual / sysdm.cpl equivalent)." -Level INFO

        # 2. Prevent drivers in Quality Updates (Registry & Group Policy equivalent)
        $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
        if (!(Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
        Set-ItemProperty -Path $policyPath -Name "ExcludeWUDriversInQualityUpdate" -Value 1 -Type DWord -ErrorAction Stop
        Write-Log "Set ExcludeWUDriversInQualityUpdate to 1 (Registry/GPEDit equivalent)." -Level INFO

        # 3. Disable Device Metadata (Prevents icons/manufacturer info downloads)
        $metadataPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"
        if (!(Test-Path $metadataPath)) { New-Item -Path $metadataPath -Force | Out-Null }
        Set-ItemProperty -Path $metadataPath -Name "PreventDeviceMetadataFromNetwork" -Value 1 -Type DWord -ErrorAction Stop
        Write-Log "Set PreventDeviceMetadataFromNetwork to 1 (Metadata disabled)." -Level INFO

        Write-Log "Success: Automatic driver installations are now disabled." -Level SUCCESS
    }
    catch {
        Write-Log "Failed to update driver registry keys: $($_.Exception.Message)" -Level ERROR
    }
}

function Get-NvidiaApiOsId {
    <#
    .SYNOPSIS
        Resolves a given Windows version key to an NVIDIA-specific osID.
    .PARAMETER WinVer
        The internal Windows version key (e.g. from $GLOBAL_OS_KEYS).
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$WinVer
    )

    # 1. Check if we have a specific mapping for the provided version key
    if ($GLOBAL_NVIDIA_OS_IDS.ContainsKey($WinVer)) {
        $osID = $GLOBAL_NVIDIA_OS_IDS[$WinVer]
        Write-Log "NVIDIA API: Resolved [$WinVer] to ID $osID" -Level INFO
        return $osID
    }

    # 2. Fallback logic using the central Map if the key is unknown
    $FallbackKey = $GLOBAL_OS_KEYS.WIN10_64
    $FallbackId  = $GLOBAL_NVIDIA_OS_IDS[$FallbackKey]

    Write-Log "NVIDIA API: No mapping for [$WinVer]. Falling back to [$FallbackKey] (ID $FallbackId)." -Level WARN
    
    return $FallbackId
}

function Install-NvidiaDriverBare {
    param (
        [Parameter(Mandatory=$true)]
        [string]$WinVer,
        [switch]$Clean = $false,
        [string]$DownloadFolder = "$env:temp\NvidiaUpdate"
    )

    Write-Log "Nvidia Driver Setup (Bare Installation)..." -Level STEP

    # --- 1. Hardware Detection & API Check ---
    try {
        $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match "VEN_${GLOBAL_VID_NVIDIA}" } | Select-Object -First 1
        if (!$gpu) { 
            Write-Log "No Nvidia Hardware (VEN_${GLOBAL_VID_NVIDIA}) detected. Skipping." -Level INFO
            return 
        }

        # Dynamic PID Detection Logic
        $pfid = "929" # Static Fallback: RTX 3080
        if ($gpu.PNPDeviceID -match "DEV_([A-F0-9]{4})") {
            $devId = $Matches[1].ToUpper()

            if ($GLOBAL_NVIDIA_PID_MAP.ContainsKey($devId)) {
                $pfid = $GLOBAL_NVIDIA_PID_MAP[$devId]
                Write-Log "Hardware recognized (PID: $devId). Using dynamic PFID: $pfid" -Level INFO
            }
        }

        # Query latest Driver Version
        $osID = Get-NvidiaApiOsId -WinVer $WinVer
        $uri = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=120&pfid=$pfid&osID=$osID&languageCode=1033&isWHQL=1&dch=1&numberOfResults=1"
        $payload = Invoke-RestMethod -Uri $uri
        $latestVersion = $payload.IDS[0].downloadInfo.Version
        
        $currentVersion = ($gpu.DriverVersion.Replace('.', '')[-5..-1] -join '').Insert(3, '.')
        Write-Log "Installed: $currentVersion | Latest: $latestVersion" -Level INFO

        if (!$Clean -and ($currentVersion -eq $latestVersion)) {
            Write-Log "Nvidia Driver is already up to date." -Level SUCCESS
            return
        }
    } 
    catch {
        Write-Log "Nvidia API/Hardware check failed: $($_.Exception.Message)" -Level ERROR
        return
    }

    # --- 2. Download & Extraction ---
    try {
        if (!(Test-Path $DownloadFolder)) { New-Item $DownloadFolder -ItemType Directory -Force | Out-Null }
        $fileName = "$latestVersion-desktop-win10-win11-64bit-international-dch-whql.exe"
        $dlPath = Join-Path $DownloadFolder $fileName
        $extractPath = Join-Path $DownloadFolder "Extracted"
        $sevenZipExe = Join-Path $DownloadFolder "7zr.exe"

        if (!(Test-Path $sevenZipExe)) {
            Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $sevenZipExe
        }
    
        $DownloadUrl = "https://international.download.nvidia.com/Windows/$latestVersion/$fileName"
        Write-Log "Downloading Driver v$latestVersion..." -Level INFO
        Start-BitsTransfer -Source $DownloadUrl -Destination $dlPath -Priority High

        Write-Log "Extracting full package..." -Level INFO
        $extractArgs = "x `"$dlPath`" -o`"$extractPath`" -y"
        Start-Process -FilePath $sevenZipExe -ArgumentList $extractArgs -Wait -WindowStyle Hidden

        # 3. Component Selection (The "Bare" part)
        # We manually remove folders we don't want before starting the setup
        # need to further inspect setup.cfg before precise debloat can be applied
        # until then this stays
        $bloatFolders = @("GFExperience", "NVFans", "Node.js", "NvTelemetry", "Update.Core")
        foreach ($folder in $bloatFolders) {
            $path = Join-Path $extractPath $folder
            if (Test-Path $path) { 
                Remove-Item $path -Recurse -Force | Out-Null
                Write-Log "Removed Bloat: $folder" -Level INFO
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
        Write-Log "Starting Installation..." -Level INFO
        $installArgs = @("-passive", "-noreboot", "-noeula", "-nofinish", "-s")
        if ($Clean) { $installArgs += "-clean" }
        
        $process = Start-Process -FilePath "$extractPath\setup.exe" -ArgumentList $installArgs -Wait -PassThru
        
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            throw "Installation failed with ExitCode $($process.ExitCode)."
        }

        # --- 5. Post-Install Cleanup ---
        Write-Log "Cleaning up remaining Telemetry Tasks & Services..." -Level INFO
        Get-ScheduledTask -TaskPath "\" -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match "NvTm|Nvidia" } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        $badServices = @("NvTelemetryContainer", "NvDbuls", "NvContainerLocalSystem")
        foreach ($s in $badServices) { 
            if (Get-Service $s -ErrorAction SilentlyContinue) { 
                Stop-Service $s -Force -ErrorAction SilentlyContinue
                sc.exe delete $s 
            } 
        }

        Write-Log "Nvidia Bare Driver v$latestVersion installed successfully." -Level SUCCESS
    }
    catch { Write-Log "Setup failed: $($_.Exception.Message)" -Level ERROR }
    finally { 
        if (Test-Path $DownloadFolder) { Remove-Item $DownloadFolder -Recurse -Force -ErrorAction SilentlyContinue } 
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
        Write-Log "  > Disabling MPO (Multi-Plane Overlay)..." -Level INFO
        $dwmPath = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
        if (!(Test-Path $dwmPath)) { New-Item $dwmPath -Force | Out-Null }
        Set-ItemProperty -Path $dwmPath -Name "OverlayTestMode" -Value 5 -Type Dword

        # 2. Enable Hardware Accelerated GPU Scheduling (HAGS)
        Write-Log "  > Enabling HAGS..." -Level INFO
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Force

        # 3. Disable Transparency & Game DVR
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -Force
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
        Write-Log "  > Setting Full RGB for Instance: $($instance.PSChildName)" -Level INFO
        Set-ItemProperty -Path $instance.PSPath -Name "VPrG_OutputRange" -Value 1 -ErrorAction SilentlyContinue
    }

    # 2. Disable NVIDIA Telemetry (If exists)
    $telemetryPath = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry"
    if (Test-Path $telemetryPath) {
        Set-ItemProperty -Path $telemetryPath -Name "FeatureControl" -Value 0 -Type Dword -ErrorAction SilentlyContinue
    }

    Write-Log "Success: NVIDIA-only tweaks applied." -Level SUCCESS
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

Write-Log "Starting System-Level Setup" -Level STEP

Assert-Admin

# --- IMPORTANT PRE-FLIGHT NOTICE ---
Write-Host "`n" # Spacer
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

# 1. Prepare Windows
if (Confirm-StepExecution "Prepare Windows" 1 $StopAfterStep) {
    Disable-AutomaticDriverInstallation
    Clear-WindowsUpdateCache
}

# 2. Hardware & Driver Setup
if (Confirm-StepExecution "Hardware & Driver Setup" 2 $StopAfterStep) {
    $winVer = Get-CurrentWindowsVersion
    Install-NvidiaDriverBare -WinVer $winVer
    #Install-NvidiaProfileInspector
    #Install-MultiMonitorTool
}

# 3. Final System Optimization & Performance
if (Confirm-StepExecution "Final System Optimization" 3 $StopAfterStep) {
    Set-WindowsGPUTweaks
    Set-NvidiaRegistryTweaks
    #Set-NvidiaProfileSettings
    #Set-MonitorLayout
}

Remove-ProgressFile

$cancelled = Wait-ForKeyOrTimeout -Timeout 30 -Message "Rebooting in"

if ($cancelled) {
    Write-Log "Reboot cancelled by user. Review logs above." -Level ERROR
} else {
    Write-Log "Initiating system restart..." -Level INFO
    Restart-Computer -Force
}