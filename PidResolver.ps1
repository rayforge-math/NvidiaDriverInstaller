# ==============================================================================
# PID RESOLVER
# ==============================================================================

$Dependencies = @("Logging.ps1", "Networking.ps1")

foreach ($File in $Dependencies) {
    $FilePath = Join-Path $PSScriptRoot $File
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        Throw "Critical Error: Dependency '$File' not found at $FilePath"
    }
}

$Dependencies = @("Logging.ps1", "Networking.ps1")

# global db cache
$GLOBAL:PciDatabase = $null

$GLOBAL_PCI_ID_DB = "pci.ids"

foreach ($File in $Dependencies) {
    $FilePath = Join-Path $PSScriptRoot $File
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        Throw "Critical Error: Dependency '$File' not found at $FilePath"
    }
}

function Initialize-PciDatabase {
    <#
    .SYNOPSIS
        Parses the pci.ids file into a high-performance nested hashtable.
    .DESCRIPTION
        Uses a state-machine approach with regex to differentiate between 
        Vendors, Devices, and Subsystems based on indentation levels.
    #>
    param (
        [string]$DbPath = (Join-Path $PSScriptRoot $GLOBAL_PCI_ID_DB)
    )

    if ($null -ne $GLOBAL:PciDatabase) { return } # Already initialized

    Write-Log "Initializing PCI database from $DbPath..." -Level INFO
    if (!(Test-Path $DbPath)) {
        Write-Log "Critical Error: PCI database file missing!" -Level ERROR
        return
    }

    $Database = @{}
    $CurrentVendor = $null
    $CurrentDevice = $null

    try {
        # Using [System.IO.File] for significantly better performance on large text files
        foreach ($Line in [System.IO.File]::ReadLines($DbPath)) {
            # Skip comments and empty lines
            if ($Line.StartsWith("#") -or [string]::IsNullOrWhiteSpace($Line)) { continue }

            # 1. VENDOR (No indentation, 4-digit hex)
            if ($Line -match "^(?<id>[0-9a-f]{4})\s+(?<name>.+)$") {
                $CurrentVendor = $Matches.id.ToLower()
                $Database[$CurrentVendor] = @{ 
                    Name    = $Matches.name.Trim()
                    Devices = @{} 
                }
                $CurrentDevice = $null # Reset device context
            }
            # 2. DEVICE (Exactly 1 Tab indentation, 4-digit hex)
            elseif ($Line -match "^\t(?<id>[0-9a-f]{4})\s+(?<name>.+)$") {
                if ($null -ne $CurrentVendor) {
                    $CurrentDevice = $Matches.id.ToLower()
                    $Database[$CurrentVendor].Devices[$CurrentDevice] = @{
                        Name       = $Matches.name.Trim()
                        Subsystems = @{}
                    }
                }
            }
            # 3. SUBSYSTEM (Exactly 2 Tab indentation, two 4-digit hex)
            elseif ($Line -match "^\t\t(?<svid>[0-9a-f]{4})\s+(?<sdid>[0-9a-f]{4})\s+(?<name>.+)$") {
                if ($null -ne $CurrentVendor -and $null -ne $CurrentDevice) {
                    $SubKey = "$($Matches.svid.ToLower()) $($Matches.sdid.ToLower())"
                    $Database[$CurrentVendor].Devices[$CurrentDevice].Subsystems[$SubKey] = $Matches.name.Trim()
                }
            }
        }
        $GLOBAL:PciDatabase = $Database
        Write-Log "PCI database successfully indexed." -Level SUCCESS
    }
    catch {
        Write-Log "Failed to parse PCI database: $($_.Exception.Message)" -Level ERROR
    }
}

function Get-PciRepoDeviceDetails {
    <#
    .SYNOPSIS
        Look up device details in the pre-indexed global database.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$DeviceId,
        [Parameter(Mandatory=$true)]
        [string]$VendorId
    )

    # Ensure database is loaded
    if ($null -eq $GLOBAL:PciDatabase) { Initialize-PciDatabase }

    $Vid = $VendorId.ToLower()
    $Did = $DeviceId.ToLower()

    Write-Log "Resolving hardware: VEN_$Vid DEV_$Did" -Level INFO

    if ($GLOBAL:PciDatabase.ContainsKey($Vid)) {
        $Vendor = $GLOBAL:PciDatabase[$Vid]
        
        if ($Vendor.Devices.ContainsKey($Did)) {
            $Device = $Vendor.Devices[$Did]
            
            $Result = [PSCustomObject]@{
                VendorId    = $VendorId.ToUpper()
                DeviceId    = $DeviceId.ToUpper()
                VendorName  = $Vendor.Name
                PrimaryName = $Device.Name
                Subsystems  = $Device.Subsystems.Values
                Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }

            Write-Log "Result: Detected $($Result.PrimaryName)" -Level SUCCESS
            return $Result
        }
    }

    Write-Log "Result: Hardware not found in local database." -Level WARN
    return $null
}