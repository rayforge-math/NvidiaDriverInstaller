# Central OS Identifier Map to avoid string duplication
$GLOBAL_OS_KEYS = @{
    WIN11       = "Windows 11"
    WIN10_64    = "Windows 10 64-bit"
    WIN10_32    = "Windows 10 32-bit"
    SRV2022     = "Windows Server 2022"
    SRV2019     = "Windows Server 2019"
    UNKNOWN     = "Unknown"
}

# --- LOGGING ENGINE ---
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    # Corrected hashtable with single '='
    $prefix = @{ 
        "INFO"    = "[i]"
        "SUCCESS" = "[+]"
        "WARN"    = "[!]"
        "ERROR"   = "[-]"
        "STEP"    = ">>>" 
    }

    $timestamp = Get-Date -Format "HH:mm:ss"
    
    # Check if Level exists in prefix, otherwise default to INFO
    $p = if ($prefix.ContainsKey($Level)) { $prefix[$Level] } else { $prefix["INFO"] }

    # Set colors based on level
    $color = switch ($Level) {
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "STEP"    { "Cyan" }
        Default   { "Gray" }
    }

    Write-Host "$timestamp $p $Message" -ForegroundColor $color
}

# --- SHARED ENGINE ---

function Start-Step {
    <#
    .SYNOPSIS
        Evaluates if a step should run based on a progress file or forced overrides.
    #>
    param(
        [string]$Name,
        [int]$ID,
        [string]$ProgressFile # Passed from Confirm-StepExecution
    )
    
    # Priority 1: Manual Force Parameter (Global variable override)
    if ($global:ForceStep -gt 0) {
        if ($ID -lt $global:ForceStep) {
            Write-Log "SKIPPING Step ${ID}: $Name (Forced start at $global:ForceStep)" -Level INFO
            return $false
        }
    }
    # Priority 2: Progress File (Persistence check)
    else {
        $LastID = 0
        if (Test-Path $ProgressFile) { 
            $content = Get-Content $ProgressFile -ErrorAction SilentlyContinue
            if ($content -as [int]) { $LastID = [int]$content }
        }

        if ($ID -lt $LastID) {
            Write-Log "SKIPPING Step ${ID}: $Name (Already completed according to progress file)" -Level INFO
            return $false
        }
    }

    # Visual Output for the current Step
    Write-Host ""
    Write-Log "STEP ${ID}: $Name" -Level STEP
    Write-Host ("-" * ($Name.Length + 14)) -ForegroundColor Cyan
    
    # Save the current Step ID to the progress file
    $ID | Set-Content $ProgressFile -Force
    return $true
}

function Confirm-StepExecution {
    <#
    .SYNOPSIS
        Main entry point for step control. Determines the calling script's identity 
        and checks stop constraints before calling the execution logic.
    #>
    param (
        [string]$StepName,
        [int]$StepIndex,
        [int]$StopAfter
    )

    # 1. Identify the caller to define the specific progress file
    # Index [1] refers to the main script (e.g., SetupUser.ps1) calling this function
    $CallingScriptPath = (Get-PSCallStack)[1].ScriptName
    $ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($CallingScriptPath)
    $ProgressFile = Join-Path (Split-Path $CallingScriptPath) "$($ScriptName)_Progress.txt"

    # 2. Check if the Stop-Threshold has been reached
    if ($StopAfter -gt 0 -and $StepIndex -gt $StopAfter) {
        Write-Log "Stop threshold reached ($StopAfter). Skipping further execution: '$StepName'." -Level WARN
        return $false
    }

    # 3. Hand over to the Start-Step logic with the determined progress file
    return Start-Step -Name $StepName -ID $StepIndex -ProgressFile $ProgressFile
}

function Remove-ProgressFile {
    <#
    .SYNOPSIS
        Deletes the progress file associated with the calling script.
        Call this at the very end of your main script.
    #>
    $CallingScriptPath = (Get-PSCallStack)[1].ScriptName
    $ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($CallingScriptPath)
    $ProgressFile = Join-Path (Split-Path $CallingScriptPath) "$($ScriptName)_Progress.txt"

    if (Test-Path $ProgressFile) {
        Write-Log "Cleaning up progress file: $(Split-Path $ProgressFile -Leaf)" -Level INFO
        Remove-Item $ProgressFile -Force -ErrorAction SilentlyContinue
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

function Get-CurrentWindowsVersion {
    <#
    .SYNOPSIS
        Identifies the current Windows OS version using central keys.
    #>
    $OS = Get-CimInstance Win32_OperatingSystem
    $Caption = $OS.Caption

    if ($Caption -match "Windows 11") { return $GLOBAL_OS_KEYS.WIN11 }
    if ($Caption -match "Windows 10") {
        if ($OS.OSArchitecture -match "64") { return $GLOBAL_OS_KEYS.WIN10_64 }
        return $GLOBAL_OS_KEYS.WIN10_32
    }
    if ($Caption -match "Server 2022") { return $GLOBAL_OS_KEYS.SRV2022 }
    if ($Caption -match "Server 2019") { return $GLOBAL_OS_KEYS.SRV2019 }
    
    return $GLOBAL_OS_KEYS.UNKNOWN
}