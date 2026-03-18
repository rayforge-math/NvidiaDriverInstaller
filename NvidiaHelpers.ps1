# ==============================================================================
# NVIDIA HELPERS
# ==============================================================================

$Dependencies = @("WindowsIds.ps1", "Networking.ps1")

foreach ($File in $Dependencies) {
    $FilePath = Join-Path $PSScriptRoot $File
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        Throw "Critical Error: Dependency '$File' not found at $FilePath"
    }
}

$NVIDIA_DRIVER_SUCCESS = 0
$NVIDIA_DRIVER_SUCCESS_REBOOT = 1

# contains OS mappings for the download strings
$GLOBAL_NVIDIA_OS_MAP = @{
    # --- Windows 11 & 10 ---
    [WindowsVersionKey]::WIN11          = "win10-win11"
    [WindowsVersionKey]::WIN10_64       = "win10-win11"
    [WindowsVersionKey]::WIN10_32       = "win10-32bit"

    # --- Windows 8.1, 8 & 7 ---
    [WindowsVersionKey]::WIN81_64       = "win8-win7"
    [WindowsVersionKey]::WIN81_32       = "win8-win7-32bit"
    [WindowsVersionKey]::WIN8_64        = "win8-win7"
    [WindowsVersionKey]::WIN8_32        = "win8-win7-32bit"
    [WindowsVersionKey]::WIN7_64        = "win8-win7"
    [WindowsVersionKey]::WIN7_32        = "win8-win7-32bit"

    # --- Windows Server (Modern) ---
    [WindowsVersionKey]::SRV2025        = "winserv2019-2022"
    [WindowsVersionKey]::SRV2022        = "winserv2019-2022"
    [WindowsVersionKey]::SRV2019        = "winserv2019-2022"
    [WindowsVersionKey]::SRV2016        = "winserv2016"

    # --- Windows Server (Legacy) ---
    [WindowsVersionKey]::SRV2012_R2     = "winserv2012r2"
    [WindowsVersionKey]::SRV2012        = "winserv2012"
    [WindowsVersionKey]::SRV2008_R2     = "winserv2008r2"
    [WindowsVersionKey]::SRV2008_64     = "winserv2008"
    [WindowsVersionKey]::SRV2008_32     = "winserv2008-32bit"
}

# helpers
function Get-NvidiaLatestVersion {
    <#
    .SYNOPSIS
        Queries the NVIDIA Ajax Driver API for the latest version string.
    .PARAMETER Pfid
        The NVIDIA Product Family ID.
    .PARAMETER OsId
        The NVIDIA OS ID.
    #>
    param (
        [Parameter(Mandatory=$true)][string]$Pfid,
        [Parameter(Mandatory=$true)][string]$OsId
    )

    $baseUrl = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php"
    $uri = "{0}?func=DriverManualLookup&psid=120&pfid={1}&osID={2}&languageCode=1033&isWHQL=1&dch=1&numberOfResults=1" -f $baseUrl, $Pfid, $OsId

    Write-Log "Querying NVIDIA API for latest version..." -Level INFO
    if (Wait-ForConnection -Target $uri -MaxRetries 10) {
        try {
            $payload = Invoke-RestMethod -Uri $uri -ErrorAction Stop
            
            if ($null -eq $payload.IDS -or $payload.IDS.Count -eq 0 -or $null -eq $payload.IDS[0].downloadInfo.Version) {
                Write-Log "API returned no results for PFID $Pfid on OS $OsId." -Level ERROR
                return $null
            }
            
            $version = ([string]$payload.IDS[0].downloadInfo.Version).Trim()
            Write-Log "Latest NVIDIA version found: $version" -Level SUCCESS
            return $version
        }
        catch {
            Write-Log "Failed to parse NVIDIA API response: $($_.Exception.Message)" -Level ERROR
            return $null
        }
    }
    return $null
}

function Format-NvidiaVersion {
    <#
    .SYNOPSIS
        Converts a WMI DriverVersion string to the standard NVIDIA 5xx.xx format.
    .EXAMPLE
        Format-NvidiaVersion -WmiVersion "31.0.15.5244" # Returns "552.44"
    #>
    param (
        [Parameter(Mandatory=$true)][string]$WmiVersion
    )

    try {
        $cleanVersion = $WmiVersion.Trim().Replace('.', '')
        
        if ($cleanVersion.Length -lt 5) {
            throw "Version string too short to format."
        }

        $formatted = ($cleanVersion[-5..-1] -join '').Insert(3, '.')
        return $formatted
    }
    catch {
        Write-Log "Failed to format version '$WmiVersion': $($_.Exception.Message)" -Level WARN
        return $WmiVersion.Trim() 
    }
}

function Get-NvidiaDriverPackage {
    param (
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$DestinationFolder,
        [Parameter(Mandatory=$true)][WindowsVersionKey]$WinVer
    )

    Write-Log "Acquiring NVIDIA Driver Package (v$Version)" -Level INFO

    # --- DIAGNOSTIC: Check Input ---
    if ($null -eq $WinVer) {
        Write-Log "Critical: WinVer parameter is null!" -Level ERROR
        return $null
    }

    # --- 1. OS Mapping ---
    $osString = "win10-win11" # Default
    try {
        if ($GLOBAL_NVIDIA_OS_MAP.ContainsKey($WinVer)) { 
            $osString = $GLOBAL_NVIDIA_OS_MAP[$WinVer]
            Write-Log "OS Mapping: '$WinVer' -> '$osString'" -Level INFO -SubStep
        }
    } catch {
        Write-Log "Error accessing OS Map: $($_.Exception.Message)" -Level ERROR
    }
    
    # --- 2. Architecture Detection (Mögliche Fehlerquelle!) ---
    $arch = "64bit"
    try {
        $winVerString = Get-OsDisplayName -WinVer $WinVer
        if ($null -ne $winVerString) {
            if ($winVerString -like "*_32") { $arch = "32bit" }
            Write-Log "Architecture: Detected as $arch (based on $winVerString)" -Level INFO -SubStep
        } else {
            Write-Log "Warning: OS Display Name Resolution returned null. Defaulting to 64bit." -Level WARN -SubStep
        }
    } catch {
        Write-Log "Error in Architecture Detection: $($_.Exception.Message)" -Level ERROR
    }

    # --- 3. DCH vs Standard Logic ---
    $versionFloat = 0.0
    $isModern = $true
    if ([float]::TryParse($Version, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$versionFloat)) {
        $isModern = $versionFloat -ge 400.0
        $typeDescription = if ($isModern) { 'DCH (Modern)' } else { 'Standard (Legacy)' }
        Write-Log "Driver Type: $typeDescription" -Level INFO -SubStep
    }
    
    $typeSuffix = if ($isModern) { "-international-dch-whql.exe" } else { "-international-whql.exe" }

    # --- 4. Path Construction ---
    # Hier könnte Split-Path/Join-Path knallen, wenn DestinationFolder null ist
    if ([string]::IsNullOrWhiteSpace($DestinationFolder)) {
        Write-Log "Critical: DestinationFolder is null or empty!" -Level ERROR
        return $null
    }
    
    $fileName = "$Version-desktop-$osString-$arch$typeSuffix"
    $url = "https://international.download.nvidia.com/Windows/$Version/$fileName"
    $fullPath = Join-Path $DestinationFolder $fileName

    # --- 5. Cache Check ---
    if (Test-Path $fullPath) {
        Write-Log "Local Cache: Found '$fileName'" -Level SUCCESS -SubStep
        return $fullPath
    }

    # --- 6. Execution ---
    Write-Log "Target URL: $url" -Level INFO -SubStep

    try {
        if (Start-SmartDownload -SourceUrl $url -DestinationPath $fullPath) {
            if (Test-Path $fullPath) {
                Write-Log "Driver successfully acquired." -Level SUCCESS
                return $fullPath
            }
        }
    }
    catch {
        Write-Log "Download Exception: $($_.Exception.Message)" -Level ERROR -SubStep
    }

    return $null
}

function Expand-NvidiaDriverPackage {
    <#
    .SYNOPSIS
        Pure extraction of the NVIDIA driver package using a temporary 7-Zip helper.
    .DESCRIPTION
        Acquires 7zr.exe, extracts the driver to the destination, and ensures 
        the helper tool is removed immediately after completion.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$PackagePath,
        [Parameter(Mandatory=$true)]
        [string]$DestinationPath
    )

    # Place the helper in the same directory as the package
    $workingDir = Split-Path $PackagePath
    $helperExe = Join-Path $workingDir "7zr.exe"
    
    try {
        Write-Log "Initializing extraction of: $(Split-Path $PackagePath -Leaf)" -Level INFO
        
        # 1. Acquire 7-Zip Helper (7zr.exe)
        if (!(Get-SevenZipHelper -DestinationPath $helperExe)) {
            throw "Failed to acquire temporary 7-Zip helper tool."
        }

        # 2. Prepare Destination
        if (Test-Path $DestinationPath) { 
            Remove-Item $DestinationPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null 
        }
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

        # 3. Execute Extraction
        Write-Log "Extracting files to: $DestinationPath" -Level INFO -SubStep
        $extractArgs = "x `"$PackagePath`" -o`"$DestinationPath`" -y"
        $process = Start-Process -FilePath $helperExe -ArgumentList $extractArgs -Wait -WindowStyle Hidden -PassThru
        
        if ($process.ExitCode -ne 0) { 
            throw "Extraction failed with exit code $($process.ExitCode)." 
        }

        Write-Log "Extraction completed successfully." -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Extraction Error: $($_.Exception.Message)" -Level ERROR
        return $false
    }
    finally {
        # 4. Immediate cleanup of the helper tool to keep the environment clean
        if (Test-Path $helperExe) { 
            Remove-Item $helperExe -Force -ErrorAction SilentlyContinue 
        }
    }
}

function Debloat-NvidiaDriverPackage {
    <#
    .SYNOPSIS
        Removes unnecessary components from the extracted NVIDIA driver package.
    .DESCRIPTION
        Deletes specific bloat folders (GFExperience, Telemetry, etc.) to ensure 
        a "Bare" driver installation.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$ExtractPath
    )

    if (!(Test-Path $ExtractPath)) {
        Write-Log "Debloat Error: Extract path not found: $ExtractPath" -Level ERROR
        return $false
    }

    # Centralized list of components to remove
    $bloatFolders = @(
        "GFExperience", 
        "NVFans", 
        "Node.js", 
        "NvTelemetry", 
        "Update.Core"
        #"Display.Update",
        #"NvApp",
        #"NvVAD",
        #"ShieldWirelessController"
    )

    Write-Log "Stripping unnecessary components..." -Level INFO
    
    foreach ($folder in $bloatFolders) {
        $path = Join-Path $ExtractPath $folder
        if (Test-Path $path) { 
            try {
                Remove-Item $path -Recurse -Force -ErrorAction Stop | Out-Null
                Write-Log "Deleted component: $folder" -Level INFO -SubStep
            } catch {
                Write-Log "Warning: Could not remove $folder - $($_.Exception.Message)" -Level WARN -SubStep
            }
        }
    }

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

    return $true
}

function Install-NvidiaDriverPackage {
    <#
    .SYNOPSIS
        Executes the NVIDIA setup from an extracted directory with specific flags.
    .DESCRIPTION
        Runs the installer in passive/silent mode. Supports clean installation 
        and handles standard NVIDIA exit codes.
    .PARAMETER ExtractPath
        The directory where the driver was expanded (contains setup.exe).
    .PARAMETER Clean
        If true, adds the '-clean' flag to the installer.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$ExtractPath,
        [Parameter()]
        [bool]$Clean = $false
    )

    $setupExe = Join-Path $ExtractPath "setup.exe"

    # --- Validation ---
    if (!(Test-Path $setupExe)) {
        Write-Log "Installation Error: setup.exe not found at $setupExe" -Level ERROR
        return 9999 # Custom error code for missing installer
    }

    # --- Argument Construction ---
    # -passive: Progress bar only, no interaction
    # -s: Silent mode
    # -noreboot: Don't force a restart immediately
    # -noeula: Skip EULA prompt
    # -nofinish: Skip the final 'Installation Finished' screen
    $installArgs = @("-passive", "-noreboot", "-noeula", "-nofinish", "-s")
    if ($Clean) { 
        $installArgs += "-clean" 
        Write-Log "Clean installation flag enabled." -Level INFO -SubStep
    }

    Write-Log "Executing NVIDIA Setup: $setupExe" -Level INFO
    
    try {
        $process = Start-Process -FilePath $setupExe -ArgumentList $installArgs -Wait -PassThru
        $exitCode = $process.ExitCode
        
        Write-Log "NVIDIA Setup finished with ExitCode: $exitCode" -Level INFO

        # Check for success (0) or Pending Reboot (1)
        if ($exitCode -eq $NVIDIA_DRIVER_SUCCESS -or $exitCode -eq $NVIDIA_DRIVER_SUCCESS_REBOOT) {
            $status = if ($exitCode -eq $NVIDIA_DRIVER_SUCCESS_REBOOT) { "SUCCESS (Reboot Pending)" } else { "SUCCESS" }
            Write-Log "Installation Status: $status" -Level SUCCESS
        } else {
            Write-Log "Installation failed with ExitCode: $exitCode" -Level ERROR
        }

        return $exitCode
    }
    catch {
        Write-Log "Critical Error during Setup execution: $($_.Exception.Message)" -Level ERROR
        return 9999
    }
}

function Cleanup-NvidiaServices {
    <#
    .SYNOPSIS
        Removes NVIDIA telemetry tasks and services from the Windows system.
    .DESCRIPTION
        This should be called AFTER the installation to clean up any leftovers 
        that the installer might have created despite the debloated package.
    #>
    
    Write-Log "Final Telemetry Removal (System Cleanup)..." -Level INFO

    # 1. Scheduled Tasks Cleanup
    $tasks = Get-ScheduledTask -TaskPath "\" -ErrorAction SilentlyContinue | 
             Where-Object { $_.TaskName -match "NvTm|Nvidia" }

    if ($tasks) {
        foreach ($task in $tasks) {
            Write-Log "Unregistering Task: $($task.TaskName)" -Level INFO -SubStep
            Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    # 2. Services Cleanup
    # Expanded list to be more thorough
    $badServices = @(
        "NvTelemetryContainer", 
        "NvDbuls", 
        "NvContainerLocalSystem", 
        "NVDisplay.ContainerLocalSystem" # Often remains even in bare installs
    )

    foreach ($s in $badServices) { 
        if (Get-Service $s -ErrorAction SilentlyContinue) { 
            try {
                Write-Log "Stopping and deleting service: $s" -Level INFO -SubStep
                Stop-Service $s -Force -ErrorAction SilentlyContinue
                # Use sc.exe for absolute deletion of the service entry
                $null = sc.exe delete $s
            }
            catch {
                Write-Log "Warning: Could not fully delete service $s" -Level WARN -SubStep
            }
        } 
    }
}