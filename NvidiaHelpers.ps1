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

function Get-NvidiaDriverFile {
    <#
    .SYNOPSIS
        Acquires the correct NVIDIA driver package using a global OS mapping table.
    .DESCRIPTION
        Uses $GLOBAL_NVIDIA_OS_MAP to translate internal OS keys into NVIDIA's 
        URL naming scheme. Supports modern DCH and legacy architectures.
    .PARAMETER Version
        The driver version string (e.g., "595.79").
    .PARAMETER DestinationFolder
        The directory for storing the downloaded installer.
    .PARAMETER WinVer
        The key from $GLOBAL_OS_KEYS (e.g., "WIN11").
    #>
    param (
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$DestinationFolder,
        [Parameter(Mandatory=$true)][WindowsVersionKey]$WinVer
    )

    Write-Log "Acquiring NVIDIA Driver Package" -Level INFO

    # 1. Look up the URL segment from your global map
    # Fallback to 'win10-win11' if the key is missing from the map
    $osString = if ($GLOBAL_NVIDIA_OS_MAP.ContainsKey($WinVer)) { 
        $GLOBAL_NVIDIA_OS_MAP[$WinVer] 
    } else { 
        Write-Log "Warning: OS Key '$WinVer' not found in Map. Using fallback." -Level WARN -SubStep
        "win10-win11" 
    }
    
    # 2. Determine architecture based on the WinVer naming convention
    $winVerString = Get-OsDisplayName -WinVer $WinVer
    $arch = if ($winVerString -like "*_32") { "32bit" } else { "64bit" }

    # 3. Handle DCH vs Standard (NVIDIA introduced DCH roughly around version 400)
    $isModern = [float]$Version -ge 400
    $typeSuffix = if ($isModern) { "-international-dch-whql.exe" } else { "-international-whql.exe" }

    # 4. Construct final filename and URL
    $fileName = "$Version-desktop-$osString-$arch$typeSuffix"
    $url = "https://international.download.nvidia.com/Windows/$Version/$fileName"
    $fullPath = Join-Path $DestinationFolder $fileName

    Write-Log "OS Identifier: $WinVer mapped to URL segment '$osString'" -Level INFO -SubStep

    # Local Cache Check
    if (Test-Path $fullPath) {
        Write-Log "Local copy found. Skipping download." -Level SUCCESS -SubStep
        return $fullPath
    }

    Write-Log "Requesting $fileName" -Level INFO -SubStep
    Write-Log "Source: $url" -Level INFO -SubStep

    try {
        if (Start-SmartDownload -SourceUrl $url -DestinationPath $fullPath) {
            Write-Log "Driver successfully acquired." -Level SUCCESS
            return $fullPath
        }
    }
    catch {
        Write-Log "Exception: $($_.Exception.Message)" -Level ERROR -SubStep
    }

    return $null
}