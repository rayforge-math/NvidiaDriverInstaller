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

$GLOBAL_NVIDIA_DRIVER_DB = ".\NvidiaDriverMasterData.json"

# Vendor ID (VID)
$GLOBAL_VID_NVIDIA = "10DE"

# Global Mapping for NVIDIA Driver API osID parameter
# Matches internal IDs used by NVIDIA AjaxDriverService.php
$GLOBAL_NVIDIA_OS_IDS = @{
    # --- Windows 11 & 10 ---
    [WindowsVersionKey]::WIN11          = 135
    [WindowsVersionKey]::WIN10_64       = 57
    [WindowsVersionKey]::WIN10_32       = 56

    # --- Windows 8.1 & 8 ---
    [WindowsVersionKey]::WIN81_64       = 41
    [WindowsVersionKey]::WIN81_32       = 40
    [WindowsVersionKey]::WIN8_64        = 35
    [WindowsVersionKey]::WIN8_32        = 34

    # --- Windows 7 ---
    [WindowsVersionKey]::WIN7_64        = 19
    [WindowsVersionKey]::WIN7_32        = 18

    # --- Windows Server (Modern) ---
    [WindowsVersionKey]::SRV2025        = 141
    [WindowsVersionKey]::SRV2022        = 138
    [WindowsVersionKey]::SRV2019        = 113
    [WindowsVersionKey]::SRV2016        = 79

    # --- Windows Server (Legacy) ---
    [WindowsVersionKey]::SRV2012_R2     = 43
    [WindowsVersionKey]::SRV2012        = 37
    [WindowsVersionKey]::SRV2008_R2     = 25
    [WindowsVersionKey]::SRV2008_64     = 23
    [WindowsVersionKey]::SRV2008_32     = 22
}

enum NvidiaHardwareCategory {
    Tier
    Mobile
    Special
}

# Centralized mapping of Categories to their respective Flags
$GLOBAL_NVIDIA_HW_FEATURES = [ordered]@{
    [NvidiaHardwareCategory]::Tier    = @("Ti", "Super", "Ultra", "LE", "SE", "RTX", "GTX", "GT", "GTS")
    [NvidiaHardwareCategory]::Mobile  = @("Mobile", "Laptop", "Max-Q", "Max-P")
    [NvidiaHardwareCategory]::Special = @("Workstation", "Quadro", "NVS", "Tesla", "Grid")
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

function Get-NvidiaDriverRequestMeta {
    <#
    .SYNOPSIS
        Matches identified hardware name against the local Nvidia driver database.
    .DESCRIPTION
        Uses tokenized keyword matching (Intersection) to find the best driver profile.
        Includes categorical parity checks for strict matching.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$VendorId,
        [Parameter(Mandatory=$true)]
        [string]$PrimaryName
    )

    Write-Log "Starting metadata lookup for: $PrimaryName" -Level INFO

    # --- STAGE 1: Vendor Validation ---
    if ($VendorId -ne $GLOBAL_VID_NVIDIA) {
        Write-Log "Result: Skipping lookup. Vendor ID [$VendorId] does not match NVIDIA ($GLOBAL_VID_NVIDIA)." -Level WARN
        return $null
    }

    # --- STAGE 2: Database Check ---
    $JsonPath = Join-Path $PSScriptRoot "$GLOBAL_NVIDIA_DRIVER_DB"
    if (!(Test-Path $JsonPath)) {
        Write-Log "Result: Aborted. Driver Database file not found at: $JsonPath" -Level ERROR
        return $null
    }

    # Helper function to extract relevant tokens
    $ExtractTokens = {
        param($String)
        $Clean = $String -replace "[^a-zA-Z0-9]", " "
        $Parts = $Clean.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
        return $Parts | Where-Object { 
            $_.Length -gt 1 -and 
            $_ -notmatch "^(NVIDIA|Corporation|GeForce|Graphics|Driver|Series|Product|Video|Controller|Adapter)$" 
        } | ForEach-Object { $_.ToLower().Trim() }
    }

    # Helper: Check for a flag with word boundaries
    $HasFlag = {
        param($InputString, $Flag)
        if ($Flag -eq "M") { return $InputString -match "M$" }
        return $InputString -match "\b$Flag\b"
    }

    try {
        $MasterData = Get-Content $JsonPath -Raw | ConvertFrom-Json
        
        # --- STAGE 3: Categorized Feature Detection (Input) ---
        $InputFeatureMap = @{}
        foreach ($Category in [NvidiaHardwareCategory]::GetValues([NvidiaHardwareCategory])) {
            foreach ($Flag in $GLOBAL_NVIDIA_HW_FEATURES[$Category]) {
                if (&$HasFlag -InputString $PrimaryName -Flag $Flag) {
                    $InputFeatureMap[$Flag] = $true
                }
            }
        }
        
        $IsMobileIn = ($InputFeatureMap.Keys | Where-Object { $GLOBAL_NVIDIA_HW_FEATURES[[NvidiaHardwareCategory]::Mobile] -contains $_ }) -ne $null -or ($PrimaryName -match "M$")
        $SourceTokens = &$ExtractTokens -String $PrimaryName
        
        Write-Log "Input Features: [$($InputFeatureMap.Keys -join ', ')] (Mobile: $IsMobileIn)" -Level INFO -SubStep
        Write-Log "Search Tokens: [$($SourceTokens -join ', ')]" -Level INFO -SubStep

        $BestMatch = $null
        $MaxScore = 0

        # --- STAGE 4: Strict Filtering Loop ---
        foreach ($Entry in $MasterData) {
            $EntryName = $Entry.name
            $Mismatch = $false

            # MANDATORY CATEGORICAL PARITY CHECK
            foreach ($Category in [NvidiaHardwareCategory]::GetValues([NvidiaHardwareCategory])) {
                foreach ($Flag in $GLOBAL_NVIDIA_HW_FEATURES[$Category]) {
                    $InHasFlag    = $InputFeatureMap.ContainsKey($Flag)
                    $EntryHasFlag = &$HasFlag -InputString $EntryName -Flag $Flag

                    if ($InHasFlag -ne $EntryHasFlag) {
                        $Mismatch = $true
                        break
                    }
                }
                if ($Mismatch) { break }
            }

            # Additional legacy M check
            if (!$Mismatch -and ($PrimaryName -match "M$") -ne ($EntryName -match "M$")) { $Mismatch = $true }

            if ($Mismatch) { continue }

            # --- STAGE 5: Scoring ---
            $TargetTokens = &$ExtractTokens -String $EntryName
            $Common = $SourceTokens | Where-Object { $TargetTokens -contains $_ }
            
            $Score = ($Common | Measure-Object).Count
            foreach ($Token in $Common) {
                if ($Token -match "\d{3,4}") { $Score += 5 }
                if ($Token -match "\d+gb")    { $Score += 3 }
            }

            # --- STAGE 6: Selection & Tie-Breaking ---
            if ($Score -gt $MaxScore) {
                $MaxScore = $Score
                $BestMatch = $Entry
            }
            elseif ($Score -eq $MaxScore -and $null -ne $BestMatch) {
                $CurrentBestTokens = &$ExtractTokens -String $BestMatch.name
                if ($TargetTokens.Count -lt $CurrentBestTokens.Count) {
                    $BestMatch = $Entry
                }
            }
        }

        # --- STAGE 7: Final Validation ---
        if ($BestMatch -and $MaxScore -ge 5) {
            $Result = $BestMatch | Select-Object *
            $Result | Add-Member -MemberType NoteProperty -Name "IsMobile" -Value ([bool]$IsMobileIn) -Force
            $Result | Add-Member -MemberType NoteProperty -Name "MatchScore" -Value $MaxScore -Force

            Write-Log "Result: Successfully matched to '$($Result.name)'" -Level SUCCESS
            return $Result
        } else {
            Write-Log "Result: No specific match found for [$PrimaryName] with required features." -Level WARN
        }

    } catch {
        Write-Log "Result: Error in pattern matching - $($_.Exception.Message)" -Level ERROR
    }

    return $null
}