# ==============================================================================
# WINDOWS UTILS FRAMEWORK
# Centralized OS handling, logging, and execution control
# ==============================================================================

# --- OS ENUMERATION ---
enum WindowsVersionKey {
    UNKNOWN     = 0
    
    # Client Versions
    WIN11       = 1
    WIN10_64    = 2
    WIN10_32    = 3
    WIN81_64    = 4
    WIN81_32    = 5
    WIN8_64     = 6
    WIN8_32     = 7
    WIN7_64     = 8
    WIN7_32     = 9

    # Server Versions
    SRV2025     = 10
    SRV2022     = 11
    SRV2019     = 12
    SRV2016     = 13
    SRV2012_R2  = 14
    SRV2012     = 15
    SRV2008_R2  = 16
    SRV2008_64  = 17
    SRV2008_32  = 18
}

# Mapping for Human-Readable Logging
# Links [WindowsVersionKey] Enums to user-friendly strings
$GLOBAL_OS_DISPLAY_NAMES = @{
    # --- Client OS ---
    [WindowsVersionKey]::WIN11          = "Windows 11"
    [WindowsVersionKey]::WIN10_64       = "Windows 10 64-bit"
    [WindowsVersionKey]::WIN10_32       = "Windows 10 32-bit"
    [WindowsVersionKey]::WIN81_64       = "Windows 8.1 64-bit"
    [WindowsVersionKey]::WIN81_32       = "Windows 8.1 32-bit"
    [WindowsVersionKey]::WIN8_64        = "Windows 8 64-bit"
    [WindowsVersionKey]::WIN8_32        = "Windows 8 32-bit"
    [WindowsVersionKey]::WIN7_64        = "Windows 7 64-bit"
    [WindowsVersionKey]::WIN7_32        = "Windows 7 32-bit"

    # --- Server OS ---
    [WindowsVersionKey]::SRV2025        = "Windows Server 2025"
    [WindowsVersionKey]::SRV2022        = "Windows Server 2022"
    [WindowsVersionKey]::SRV2019        = "Windows Server 2019"
    [WindowsVersionKey]::SRV2016        = "Windows Server 2016"
    [WindowsVersionKey]::SRV2012_R2     = "Windows Server 2012 R2"
    [WindowsVersionKey]::SRV2012        = "Windows Server 2012"
    [WindowsVersionKey]::SRV2008_R2     = "Windows Server 2008 R2"
    [WindowsVersionKey]::SRV2008_64     = "Windows Server 2008 64-bit"
    [WindowsVersionKey]::SRV2008_32     = "Windows Server 2008 32-bit"

    # --- Fallback ---
    [WindowsVersionKey]::UNKNOWN        = "Unknown System"
}

# --- CORE HELPERS ---
function Get-CurrentWindowsVersion {
    <#
    .SYNOPSIS
        Identifies the current Windows OS and returns the internal [WindowsVersionKey] enum.
    .DESCRIPTION
        Compatible with PowerShell 5.1 and 7+. Uses WMI/CIM to analyze OS Caption 
        and Architecture.
    #>
    $OS = Get-CimInstance Win32_OperatingSystem
    $Caption = $OS.Caption
    $Is64Bit = $OS.OSArchitecture -match "64"

    # --- Client Versions ---
    if ($Caption -match "Windows 11") { return [WindowsVersionKey]::WIN11 }
    
    if ($Caption -match "Windows 10") {
        if ($Is64Bit) { return [WindowsVersionKey]::WIN10_64 } else { return [WindowsVersionKey]::WIN10_32 }
    }
    
    if ($Caption -match "Windows 8.1") {
        if ($Is64Bit) { return [WindowsVersionKey]::WIN81_64 } else { return [WindowsVersionKey]::WIN81_32 }
    }
    
    if ($Caption -match "Windows 8") {
        if ($Is64Bit) { return [WindowsVersionKey]::WIN8_64 } else { return [WindowsVersionKey]::WIN8_32 }
    }
    
    if ($Caption -match "Windows 7") {
        if ($Is64Bit) { return [WindowsVersionKey]::WIN7_64 } else { return [WindowsVersionKey]::WIN7_32 }
    }

    # --- Server Versions ---
    if ($Caption -match "Server 2025") { return [WindowsVersionKey]::SRV2025 }
    if ($Caption -match "Server 2022") { return [WindowsVersionKey]::SRV2022 }
    if ($Caption -match "Server 2019") { return [WindowsVersionKey]::SRV2019 }
    if ($Caption -match "Server 2016") { return [WindowsVersionKey]::SRV2016 }
    
    if ($Caption -match "Server 2012 R2") { return [WindowsVersionKey]::SRV2012_R2 }
    if ($Caption -match "Server 2012")    { return [WindowsVersionKey]::SRV2012 }
    
    if ($Caption -match "Server 2008 R2") { return [WindowsVersionKey]::SRV2008_R2 }
    if ($Caption -match "Server 2008") {
        if ($Is64Bit) { return [WindowsVersionKey]::SRV2008_64 } else { return [WindowsVersionKey]::SRV2008_32 }
    }
    
    Write-Log "Unknown Windows Version detected: $Caption" -Level WARN
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