$Dependencies = @("Logging.ps1")

foreach ($File in $Dependencies) {
    $FilePath = Join-Path $PSScriptRoot $File
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        Throw "Critical Error: Dependency '$File' not found at $FilePath"
    }
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
                Write-Log "Stopping $Service..." -Level INFO -SubStep
                Stop-Service -Name $Service -Force -ErrorAction SilentlyContinue
            }
        }

        # 2. Use Robocopy to purge the folder (The "Nuclear Option" for long paths)
        if (Test-Path $cachePath) {
            Write-Log "Executing Robocopy purge on $cachePath..." -Level INFO -SubStep
            
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
        Write-Log "Set SearchOrderConfig to 0 (Manual / sysdm.cpl equivalent)." -Level INFO -SubStep

        # 2. Prevent drivers in Quality Updates (Registry & Group Policy equivalent)
        $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
        if (!(Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
        Set-ItemProperty -Path $policyPath -Name "ExcludeWUDriversInQualityUpdate" -Value 1 -Type DWord -ErrorAction Stop
        Write-Log "Set ExcludeWUDriversInQualityUpdate to 1 (Registry/GPEDit equivalent)." -Level INFO -SubStep

        # 3. Disable Device Metadata (Prevents icons/manufacturer info downloads)
        $metadataPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"
        if (!(Test-Path $metadataPath)) { New-Item -Path $metadataPath -Force | Out-Null }
        Set-ItemProperty -Path $metadataPath -Name "PreventDeviceMetadataFromNetwork" -Value 1 -Type DWord -ErrorAction Stop
        Write-Log "Set PreventDeviceMetadataFromNetwork to 1 (Metadata disabled)." -Level INFO -SubStep

        Write-Log "Success: Automatic driver installations are now disabled." -Level SUCCESS
    }
    catch {
        Write-Log "Failed to update driver registry keys: $($_.Exception.Message)" -Level ERROR
    }
}