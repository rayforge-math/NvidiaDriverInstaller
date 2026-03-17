# ==============================================================================
# WINDOWS UTILS FRAMEWORK
# Centralized OS handling, logging, and execution control
# ==============================================================================

# --- OS ENUMERATION ---
enum WindowsVersionKey {
    UNKNOWN = 0
    WIN11 = 1
    WIN10_64 = 2
    WIN10_32 = 3
    SRV2022 = 4
    SRV2019 = 5
}

# Mapping for Human-Readable Logging
$GLOBAL_OS_DISPLAY_NAMES = @{
    [WindowsVersionKey]::WIN11    = "Windows 11"
    [WindowsVersionKey]::WIN10_64 = "Windows 10 64-bit"
    [WindowsVersionKey]::WIN10_32 = "Windows 10 32-bit"
    [WindowsVersionKey]::SRV2022  = "Windows Server 2022"
    [WindowsVersionKey]::SRV2019  = "Windows Server 2019"
    [WindowsVersionKey]::UNKNOWN  = "Unknown System"
}

# --- CORE HELPERS ---

function Get-CurrentWindowsVersion {
    <#
    .SYNOPSIS
        Identifies current Windows OS and returns the internal [WindowsVersionKey] enum.
    #>
    $OS = Get-CimInstance Win32_OperatingSystem
    $Caption = $OS.Caption

    if ($Caption -match "Windows 11") { return [WindowsVersionKey]::WIN11 }
    if ($Caption -match "Windows 10") {
        if ($OS.OSArchitecture -match "64") { return [WindowsVersionKey]::WIN10_64 }
        return [WindowsVersionKey]::WIN10_32
    }
    if ($Caption -match "Server 2022") { return [WindowsVersionKey]::SRV2022 }
    if ($Caption -match "Server 2019") { return [WindowsVersionKey]::SRV2019 }
    
    return [WindowsVersionKey]::UNKNOWN
}

function Get-OsDisplayName {
    <#
    .SYNOPSIS
        Resolves a WindowsVersionKey enum to its human-readable display string.
    #>
    param ([WindowsVersionKey]$WinVer)

    if ($GLOBAL_OS_DISPLAY_NAMES.ContainsKey($WinVer)) {
        return $GLOBAL_OS_DISPLAY_NAMES[$WinVer]
    }
    return "Unknown System ($($WinVer.ToString()))"
}