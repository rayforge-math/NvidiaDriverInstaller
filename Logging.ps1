# --- LOGGING ENGINE ---
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "STEP")]
        [string]$Level = "INFO",
        [switch]$SubStep
    )

    # Corrected hashtable with single '='
    $prefixes = @{ 
        "INFO"    = "[i]"
        "SUCCESS" = "[+]"
        "WARN"    = "[!]"
        "ERROR"   = "[-]"
        "STEP"    = ">>>" 
    }

    $timestamp = Get-Date -Format "HH:mm:ss"
    $p = if ($prefixes.ContainsKey($Level)) { $prefixes[$Level] } else { $prefixes["INFO"] }
    $indent = if ($SubStep) { "   > " } else { " " }

    # Set colors based on level
    $color = switch ($Level) {
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "STEP"    { "Cyan" }
        Default   { "Gray" }
    }

    Write-Host "$timestamp $p$indent$Message" -ForegroundColor $color
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