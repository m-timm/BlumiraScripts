#–– Run this as Administrator ––
Set-ExecutionPolicy Bypass -Scope Process -Force

# Destination folder and log file
$destination = "C:\Blumira"
$logFile     = Join-Path $destination "Blumira.log"

# Ensure destination exists BEFORE first log write so nothing is silently lost
if (-not (Test-Path $destination)) {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    try {
        Add-Content -Path $logFile -Value $line -ErrorAction Stop
    } catch {
        Write-Host "  (could not write to log file: $($_.Exception.Message))"
    }
}

Write-Log "Starting Blumira DC deployment. Destination=$destination"

# 1. Force TLS 1.2/1.1 to prevent SSL errors when downloading from GitHub
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12 -bor `
        [Net.SecurityProtocolType]::Tls11
    Write-Log "TLS set to 1.2/1.1"
} catch {
    Write-Log "Failed to set SecurityProtocol: $($_.Exception.Message)" "WARN"
}

# 2. Ensure the BITS transfer module is available
try {
    Import-Module BitsTransfer -ErrorAction Stop
    Write-Log "BitsTransfer module loaded"
} catch {
    Write-Log "Could not import BitsTransfer module: $($_.Exception.Message)" "WARN"
}

# 3. Download the Blumira files (ZIP + 2 PS1s) with fallback
$downloads = @(
    @{ Url = "https://github.com/Blumira/Logmira/raw/master/GPO%20Files/Logmira.zip"; OutFile = "Logmira.zip" },
    @{ Url = "https://raw.githubusercontent.com/Blumira/Kerberoast-Detection/main/DOGEMIRA.ps1"; OutFile = "DOGEMIRA.ps1" },
    @{ Url = "https://raw.githubusercontent.com/Blumira/SYSVOL_enum_honeyxml/main/create_honeyxml.ps1"; OutFile = "create_honeyxml.ps1" }
)

foreach ($item in $downloads) {
    $url     = $item.Url
    $outPath = Join-Path $destination $item.OutFile
    Write-Log "Downloading $($item.OutFile)..."

    try {
        Invoke-WebRequest -Uri $url -OutFile $outPath -UseBasicParsing -ErrorAction Stop
        Write-Log "Downloaded via Invoke-WebRequest: $($item.OutFile)"
    } catch {
        Write-Log "Invoke-WebRequest failed for $url : $($_.Exception.Message) -- trying BITS..." "WARN"
        try {
            Start-BitsTransfer -Source $url -Destination $outPath -ErrorAction Stop
            Write-Log "Downloaded via BITS: $($item.OutFile)"
        } catch {
            Write-Log "BITS transfer also failed for $url : $($_.Exception.Message)" "ERROR"
        }
    }
}

# 4. Extract the ZIP to C:\Blumira\GPO
$zipPath   = Join-Path $destination "Logmira.zip"
$gpoBackup = Join-Path $destination "GPO"

if (Test-Path $zipPath) {
    try {
        Write-Log "Extracting $zipPath to $gpoBackup..."
        Expand-Archive -Path $zipPath -DestinationPath $gpoBackup -Force
        Write-Log "Extraction complete"
    } catch {
        Write-Log "Failed to extract ${zipPath}: $($_.Exception.Message)" "ERROR"
    }
} else {
    Write-Log "ZIP not found at $zipPath -- skipping extraction" "ERROR"
}

# 5. Execute the downloaded .ps1 scripts if they exist
$scriptPaths = @(
    Join-Path $destination "DOGEMIRA.ps1"
    Join-Path $destination "create_honeyxml.ps1"
)

foreach ($script in $scriptPaths) {
    if (Test-Path $script) {
        Write-Log "Running $script..."
        try {
            & $script
            Write-Log "Completed: $script"
        } catch {
            Write-Log "Error running ${script}: $($_.Exception.Message)" "ERROR"
        }
    } else {
        Write-Log "Script not found at $script -- skipping" "WARN"
    }
}

# 6. Import GPO and link it at domain level
try {
    Import-Module GroupPolicy -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Log "GroupPolicy and ActiveDirectory modules loaded"

    $domainDNS = (Get-ADDomain).DNSRoot
    $domainDN  = (Get-ADDomain).DistinguishedName   # e.g. DC=mora,DC=local
    Write-Log "Domain DNS root: $domainDNS"
    Write-Log "Domain DN      : $domainDN"

    # Find the {GUID} backup folder regardless of nesting depth.
    # We capture the DirectoryInfo object so we can get both the parent path
    # (required by -Path) and the GUID itself (required by -BackupId).
    #
    # Using -BackupId is more reliable than -BackupGpoName because it matches
    # on the folder name directly, not the display name stored inside
    # bkupInfo.xml which can change between Blumira ZIP releases.
    Write-Log "Scanning $gpoBackup for GPO backup {GUID} folder..."

    $guidFolder = Get-ChildItem -Path $gpoBackup -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\{[0-9A-Fa-f\-]{36}\}$' } |
        Select-Object -First 1

    if (-not $guidFolder) {
        # Dump the full tree into the log so you can see exactly what extracted
        $tree = (Get-ChildItem -Path $gpoBackup -Recurse |
            Select-Object -ExpandProperty FullName) -join "`n"
        throw "No {GUID} folder found under $gpoBackup. Extracted contents:`n$tree"
    }

    $gpoBackupPath = $guidFolder.Parent.FullName
    $backupId      = $guidFolder.Name   # e.g. {602F142B-D8BE-4807-9D7F-8F6AF943FE72}

    Write-Log "Found GUID folder    : $($guidFolder.FullName)"
    Write-Log "Import-GPO -Path     : $gpoBackupPath"
    Write-Log "Import-GPO -BackupId : $backupId"

    Import-GPO -Path $gpoBackupPath `
        -BackupId $backupId `
        -TargetName "Logmira-RV" `
        -CreateIfNeeded

    Write-Log "GPO imported successfully as 'Logmira-RV'"

    Set-GPLink -Name "Logmira-RV" `
        -Target $domainDN `
        -LinkEnabled Yes

    Write-Log "GPO linked to domain root: $domainDN"

} catch {
    Write-Log "GPO import/link failed: $($_.Exception.Message)" "ERROR"
}

Write-Log "Deployment complete. Log: $logFile"
Write-Host ""
Write-Host "Done! Check $logFile for full output."
