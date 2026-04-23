# ================================
# Logmira Local GPO Deployment (Server 2016+, SYSTEM-safe, repeatable)
# Working directory: C:\Logmira
# ================================

# --- Variables ---
$BaseDir   = "C:\Logmira"
$RunId     = Get-Date -Format "yyyyMMdd-HHmmss"
$WorkDir   = Join-Path $BaseDir "run-$RunId"
$LogFile   = Join-Path $BaseDir "logmira-deploy.log"

$LogmiraZip = Join-Path $WorkDir "Logmira.zip"
$LGPOZip    = Join-Path $WorkDir "LGPO.zip"

$LogmiraUrl = "https://github.com/Blumira/Logmira/raw/master/GPO%20Files/Logmira.zip"
$LGPOUrl    = "https://download.microsoft.com/download/8/5/c/85c25433-a1b0-4ffa-9429-7e023e7da8d8/LGPO.zip"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

# --- Ensure base working dir exists ---
if (-not (Test-Path $BaseDir)) {
    New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

Write-Log "Starting Logmira deploy. BaseDir=$BaseDir WorkDir=$WorkDir"

# --- Force TLS 1.2 (helps on Server 2016) ---
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "Set TLS to 1.2"
} catch {
    Write-Log "Could not set TLS 1.2: $($_.Exception.Message)" "WARN"
}

function Download-File {
    param([Parameter(Mandatory=$true)][string]$Url,
          [Parameter(Mandatory=$true)][string]$OutFile)

    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
        Write-Log "Downloaded via Invoke-WebRequest: $Url"
    } catch {
        Write-Log "Invoke-WebRequest failed ($Url): $($_.Exception.Message). Trying BITS..." "WARN"
        Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
        Write-Log "Downloaded via BITS: $Url"
    }

    if (-not (Test-Path $OutFile)) { throw "Download failed, file missing: $OutFile" }
    $len = (Get-Item $OutFile).Length
    if ($len -lt 1024) { throw "Download looks too small ($len bytes): $OutFile" }
}

function Find-GpoRoot {
    param([Parameter(Mandatory=$true)][string]$SearchRoot)

    $candidates = Get-ChildItem -Path $SearchRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path (Join-Path $_.FullName "Machine")) -or
            (Test-Path (Join-Path $_.FullName "User"))
        } | Select-Object -ExpandProperty FullName

    if (-not $candidates) { return $null }

    # Choose shallowest path (closest to root)
    return ($candidates | Sort-Object { ($_ -split '\\').Count } | Select-Object -First 1)
}

# --- Download ZIPs ---
try {
    Write-Log "Downloading Logmira.zip..."
    Download-File -Url $LogmiraUrl -OutFile $LogmiraZip

    Write-Log "Downloading LGPO.zip..."
    Download-File -Url $LGPOUrl -OutFile $LGPOZip
} catch {
    Write-Log "Download stage failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

# --- Extract ZIPs ---
try {
    Write-Log "Extracting Logmira.zip..."
    Expand-Archive -Path $LogmiraZip -DestinationPath $WorkDir -Force

    Write-Log "Extracting LGPO.zip..."
    Expand-Archive -Path $LGPOZip -DestinationPath $WorkDir -Force
} catch {
    Write-Log "Extract stage failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

# --- Find LGPO.exe ---
$LGPOExe = Get-ChildItem -Path $WorkDir -Recurse -Filter "LGPO.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $LGPOExe) {
    Write-Log "LGPO.exe not found after extraction." "ERROR"
    exit 1
}
Write-Log "Found LGPO.exe at: $($LGPOExe.FullName)"

# --- Find Logmira GPO root ---
$LogmiraGpoPath = Find-GpoRoot -SearchRoot $WorkDir
if ($null -eq $LogmiraGpoPath) {
    Write-Log "Logmira GPO root not found under: $WorkDir" "ERROR"
    Write-Log "Top-level extracted folders:" "INFO"
    Get-ChildItem -Path $WorkDir -Directory | ForEach-Object { Write-Log " - $($_.FullName)" "INFO" }
    exit 1
}
Write-Log "Detected Logmira GPO root at: $LogmiraGpoPath"

# --- Apply Logmira GPO ---
try {
    Write-Log "Applying Logmira Local GPO..."
    & $LGPOExe.FullName /g $LogmiraGpoPath /v
    Write-Log "LGPO apply completed."
} catch {
    Write-Log "LGPO apply failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

# --- Force Policy Refresh ---
try {
    Write-Log "Running gpupdate /force..."
    gpupdate /force | Out-Null
    Write-Log "gpupdate completed."
} catch {
    Write-Log "gpupdate failed: $($_.Exception.Message)" "WARN"
}

# --- Proof HTML (optional; safe under SYSTEM, just won't open interactively) ---
try {
    $ProofPath = Join-Path $WorkDir "proof.html"
    Write-Log "Generating gpresult proof: $ProofPath"
    gpresult /h $ProofPath /f | Out-Null
    Write-Log "gpresult proof generated."
} catch {
    Write-Log "gpresult failed: $($_.Exception.Message)" "WARN"
}

Write-Log "✅ Completed successfully."
exit 0
