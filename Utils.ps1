$Dependencies = @("Networking.ps1", "Logging.ps1")

foreach ($File in $Dependencies) {
    $FilePath = Join-Path $PSScriptRoot $File
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        Throw "Critical Error: Dependency '$File' not found at $FilePath"
    }
}

# --- HELPERS ---
function Wait-ForKeyOrTimeout {
    <#
    .SYNOPSIS
        Displays an in-place countdown and returns $true if a key was pressed, 
        or $false if the timeout was reached.
    #>
    param (
        [int]$Timeout = 10,
        [string]$Message = "Time remaining"
    )

    while ([System.Console]::KeyAvailable) { [void][System.Console]::ReadKey($true) }

    for ($i = $Timeout; $i -ge 0; $i--) {
        Write-Host -NoNewline ("`r{0}: {1:D2} seconds... (Press any key to cancel)" -f $Message, $i)

        if ([System.Console]::KeyAvailable) {
            [void][System.Console]::ReadKey($true)
            Write-Host ""
            return $true
        }
        
        if ($i -gt 0) { Start-Sleep -Seconds 1 }
    }

    Write-Host ""
    return $false
}

function Test-IsAdmin {
    <#
    .SYNOPSIS
        Checks if the current PowerShell session has administrative privileges.
    .OUTPUTS
        Boolean ($true or $false)
    #>
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    <#
    .SYNOPSIS
        Ensures the script is running with administrative privileges. 
        Terminates the script if not elevated.
    #>
    if (-not (Test-IsAdmin)) {
        Write-Log "CRITICAL: This script must be run as Administrator!" -Level ERROR
        Write-Log "Please restart your terminal with elevated privileges." -Level WARN
        exit
    }
    Write-Log "Administrative privileges confirmed." -Level SUCCESS
}

function Get-SevenZipHelper {
    param (
        [Parameter(Mandatory=$true)]
        [string]$DestinationPath
    )

    Write-Log "Requirement Check: 7-Zip Portable Helper" -Level INFO

    if (Test-Path $DestinationPath) {
        Write-Log "Utility already present ($(Split-Path $DestinationPath -Leaf))" -Level SUCCESS
        return $true
    }

    Write-Log "Not found. Initializing download..." -Level WARN -SubStep
    
    $dir = Split-Path $DestinationPath
    if (!(Test-Path $dir)) { 
        Write-Log "Creating directory: $dir" -Level INFO -SubStep
        New-Item -Path $dir -ItemType Directory -Force | Out-Null 
    }

    try {
        if (Start-SmartDownload -SourceUrl "https://www.7-zip.org/a/7zr.exe" -DestinationPath $DestinationPath) {
            return $true
        }
    }
    catch {
        Write-Log "Error: Failed to acquire helper: $($_.Exception.Message)" -Level ERROR
    }

    return $false
}