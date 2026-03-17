# ==============================================================================
# NVIDIA DATA & MAPPING CONFIGURATION
# ==============================================================================

$Dependencies = @("WindowsIds.ps1")

foreach ($File in $Dependencies) {
    $FilePath = Join-Path $PSScriptRoot $File
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        Throw "Critical Error: Dependency '$File' not found at $FilePath"
    }
}

# Vendor ID (VID)
$GLOBAL_VID_NVIDIA = "10DE"

# Global Mapping for NVIDIA Driver API osID parameter
# Matches internal IDs used by NVIDIA AjaxDriverService.php
$GLOBAL_NVIDIA_OS_IDS = @{
    [WindowsVersionKey]::WIN11    = 135
    [WindowsVersionKey]::WIN10_64 = 57
    [WindowsVersionKey]::WIN10_32 = 56
    [WindowsVersionKey]::SRV2022  = 138
    [WindowsVersionKey]::SRV2019  = 113
}

$GLOBAL_NVIDIA_OS_MAP = @{
    [WindowsVersionKey]::WIN11    = "win10-win11"
    [WindowsVersionKey]::WIN10_64 = "win10-win11"
    [WindowsVersionKey]::WIN10_32 = "win10"
    [WindowsVersionKey]::SRV2022  = "server2019-server2022"
    [WindowsVersionKey]::SRV2019  = "server2019-server2022"
    [WindowsVersionKey]::UNKNOWN  = "win10-win11"
}

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

# helpers
function Get-NvidiaApiOsId {
    <#
    .SYNOPSIS
        Resolves a WindowsVersionKey enum to an NVIDIA-specific API osID.
    .DESCRIPTION
        Maps internal enum values to the numerical IDs required by the 
        NVIDIA backend API.
    .PARAMETER WinVer
        The internal Windows version key as [WindowsVersionKey] enum.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [WindowsVersionKey]$WinVer
    )

    # 1. Direct Lookup in the Global Map using the Enum Key
    if ($GLOBAL_NVIDIA_OS_IDS.ContainsKey($WinVer)) {
        $osID = $GLOBAL_NVIDIA_OS_IDS[$WinVer]
        Write-Log "Resolved [$WinVer] to ID $osID" -Level INFO
        return $osID
    }

    # 2. Safety Fallback using the WIN10_64 Enum Key
    $FallbackKey = [WindowsVersionKey]::WIN10_64
    $FallbackId  = $GLOBAL_NVIDIA_OS_IDS[$FallbackKey]

    Write-Log "No mapping for enum value [$WinVer]. Using fallback ID $FallbackId." -Level WARN
    
    return $FallbackId
}

function Get-NvidiaPfid {
    <#
    .SYNOPSIS
        Resolves the Hardware Device ID (PID) from a GPU object to an NVIDIA Product Family ID (PFID).
    .PARAMETER Gpu
        The CIM/WMI object of the video controller.
    #>
    param (
        [Parameter(Mandatory=$true)]
        $Gpu
    )

    $fallbackPfid = "929" # Default fallback (RTX 3080/4080 family)

    # Extract the DEV_XXXX part from the PNPDeviceID
    if ($Gpu.PNPDeviceID -match "DEV_([A-F0-9]{4})") {
        $devId = $Matches[1].ToUpper()
        
        if ($GLOBAL_NVIDIA_PID_MAP.ContainsKey($devId)) {
            $pfid = $GLOBAL_NVIDIA_PID_MAP[$devId]
            Write-Log "Hardware Match: $devId -> PFID: $pfid" -Level SUCCESS
            return $pfid
        } else {
            Write-Log "Device ID [$devId] not in map. Using fallback PFID: $fallbackPfid" -Level WARN
            return $fallbackPfid
        }
    }

    Write-Log "Could not extract Device ID from PNPDeviceID. Using fallback: $fallbackPfid" -Level ERROR
    return $fallbackPfid
}