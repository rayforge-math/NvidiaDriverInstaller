# ==============================================================================
# WINDOWS HARDWARE HELPERS
# ==============================================================================

function Get-HardwareByVid {
    <#
    .SYNOPSIS
        Retrieves all video controllers matching a specific Vendor ID (VID).
    .EXAMPLE
        $gpus = Get-HardwareByVid -Vid "10DE"
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$Vid
    )

    try {
        # Search for controllers matching the Vendor ID in PNPDeviceID
        $devices = Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match "VEN_$Vid" }
        
        # Ensure we return an array even if only one device is found
        if ($null -eq $devices) { return @() }
        return @($devices)
    }
    catch {
        Write-Log "Error during hardware detection for VID $Vid : $($_.Exception.Message)" -Level ERROR
        return @()
    }
}