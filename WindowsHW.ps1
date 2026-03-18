# ==============================================================================
# WINDOWS HARDWARE HELPERS
# ==============================================================================

function Get-HardwareByVid {
    <#
    .SYNOPSIS
        Retrieves all video controllers matching a specific Vendor ID (VID) 
        and parses them into structured objects.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$Vid
    )

    try {
        # 1. Raw WMI Query
        $devices = Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match "VEN_$Vid" }
        
        if ($null -eq $devices) { return @() }

        # 2. Transformation into Custom Objects
        $structuredDevices = foreach ($dev in @($devices)) {
            # Regex to extract VID, PID (DEV) and SUBSYS from PNPDeviceID
            # Example: PCI\VEN_10DE&DEV_2684&SUBSYS_889E1043...
            $pnp = $dev.PNPDeviceID
            $vidMatch = ""
            $pidMatch = ""
            $subsysMatch = ""

            if ($pnp -match "VEN_(?<vid>[A-F0-9]{4})") { $vidMatch = $Matches['vid'] }
            if ($pnp -match "DEV_(?<pid>[A-F0-9]{4})") { $pidMatch = $Matches['pid'] }
            if ($pnp -match "SUBSYS_(?<subsys>[A-F0-9]{8})") { $subsysMatch = $Matches['subsys'] }

            [PSCustomObject]@{
                # Extracted Hardware IDs
                VendorId      = $vidMatch.ToUpper()
                DeviceId      = $pidMatch.ToUpper()
                SubsystemId   = $subsysMatch.ToUpper()
                
                # Original WMI Metadata
                Caption       = $dev.Caption
                DriverVersion = $dev.DriverVersion
                ProviderName  = $dev.ProviderName
                PNPDeviceID   = $pnp
                VideoProcessor = $dev.VideoProcessor
                
                # Raw Object (Optional, if you need other WMI fields later)
                _RawWmiObject = $dev
            }
        }

        return @($structuredDevices)
    }
    catch {
        Write-Log "Error during hardware detection for VID $Vid : $($_.Exception.Message)" -Level ERROR
        return @()
    }
}