# ==============================================================================
# NETWORKING HELPERS
# ==============================================================================

$Dependencies = @("Logging.ps1")

foreach ($File in $Dependencies) {
    $FilePath = Join-Path $PSScriptRoot $File
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        Throw "Critical Error: Dependency '$File' not found at $FilePath"
    }
}

function Start-SmartDownload {
    <#
    .SYNOPSIS
        Speed-optimized download waterfall with filename-focused success messages.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$SourceUrl,
        [Parameter(Mandatory=$true)]
        [string]$DestinationPath
    )

    $fileName = Split-Path $DestinationPath -Leaf
    $dir = Split-Path $DestinationPath
    
    Write-Log "Starting Download Process" -Level INFO
    Write-Log "Source: $SourceUrl" -Level INFO -SubStep
    Write-Log "Target: $DestinationPath" -Level INFO -SubStep

    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }

    Wait-ForConnection -Target $SourceUrl

    # --- STAGE 1: CURL ---
    if (Get-Command "curl.exe" -ErrorAction SilentlyContinue) {
        try {
            Write-Log "Requesting via curl.exe..." -Level INFO -SubStep
            curl.exe -L -f --progress-bar -o "$DestinationPath" "$SourceUrl"
            if (Test-Path $DestinationPath) {
                Write-Log "Success: '$fileName' received." -Level SUCCESS
                return $true
            }
        } catch {
            Write-Log "Curl failed." -Level WARN
        }
    }

    # --- STAGE 2: .NET WebClient ---
    try {
        Write-Log "Requesting via .NET WebClient..." -Level INFO -SubStep
        $client = New-Object System.Net.WebClient
        $client.DownloadFile($SourceUrl, $DestinationPath)
        if (Test-Path $DestinationPath) {
            Write-Log "Success: '$fileName' received." -Level SUCCESS
            return $true
        }
    } catch {
        Write-Log "WebClient failed." -Level WARN
    }

    # --- STAGE 3: BITS ---
    try {
        Write-Log "Requesting via BITS..." -Level INFO -SubStep
        Start-BitsTransfer -Source $SourceUrl -Destination $DestinationPath -Priority High -ErrorAction Stop
        if (Test-Path $DestinationPath) {
            Write-Log "Success: '$fileName' received." -Level SUCCESS
            return $true
        }
    } catch {
        Write-Log "BITS failed." -Level WARN
    }

    # --- STAGE 4: Invoke-WebRequest ---
    try {
        Write-Log "Final Fallback: Invoke-WebRequest..." -Level INFO -SubStep
        Invoke-WebRequest -Uri $SourceUrl -OutFile $DestinationPath -ErrorAction Stop
        if (Test-Path $DestinationPath) {
            Write-Log "Success: '$fileName' received." -Level SUCCESS
            return $true
        }
    } catch {
        Write-Log "CRITICAL: All download stages failed for '$fileName'." -Level ERROR
        return $false
    }
}

function Wait-ForConnection {
    <#
    .SYNOPSIS
        Waits for a network connection. Automatically extracts the Hostname 
        from any string (URL, IP, or Hostname).
    #>
    param (
        [string]$Target = "1.1.1.1",
        [int]$MaxRetries = 0
    )

    # --- Robust Hostname Extraction ---
    $cleanTarget = $Target
    
    if ($Target -match "://|/") {
        try {
            # Use .NET URI class to parse the string safely
            # We add a dummy scheme if it's missing so the parser doesn't fail
            $uriString = if ($Target -notmatch "://") { "http://$Target" } else { $Target }
            $uri = [System.Uri]$uriString
            $cleanTarget = $uri.Host
        }
        catch {
            # Fallback to a simple regex if URI parsing fails
            if ($Target -match "([^/?#:]+)") { $cleanTarget = $Matches[1] }
        }
    }

    # Final cleanup (removing any accidental leading/trailing dots or spaces)
    $cleanTarget = $cleanTarget.Trim('.')

    Write-Host -NoNewline "Checking Connectivity to [$cleanTarget]" -ForegroundColor Cyan
    
    $connected = $false
    $attempts = 0

    while (-not $connected) {
        try {
            # Count 1 is enough to see if the server/gateway is up
            if (Test-Connection -ComputerName $cleanTarget -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                $connected = $true
            } else {
                Write-Host -NoNewline "." -ForegroundColor Gray
                Start-Sleep -Seconds 1
            }
        }
        catch {
            Write-Host -NoNewline "!" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }

        $attempts++
        if ($MaxRetries -gt 0 -and $attempts -ge $MaxRetries) {
            Write-Host " [Failed]" -ForegroundColor Red
            return $false
        }
    }

    Write-Host " [Connected]" -ForegroundColor Green
    return $true
}