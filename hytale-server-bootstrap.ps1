#Requires -Version 5.1
<#
.SYNOPSIS
    Hytale dedicated server bootstrap for Windows (native Java 25).

.DESCRIPTION
    Prepares a native Windows Hytale server without Docker:

      * reuses Server\, Assets.zip and start.bat when they are already present;
      * otherwise downloads the official Hytale Downloader for Windows and
        extracts the latest server archive;
      * finds Java 25 or downloads Temurin 25 into .jdk\;
      * links Server\universe, Server\backups and the auth files to data\;
      * writes jvm.options for the machine's RAM;
      * starts start.bat in a new console window.

    The world and server authorization stay portable in data\. The script is
    idempotent and does not overwrite an existing world or auth token.

.PARAMETER NoStart
    Prepare everything but do not launch the server.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\hytale-server-bootstrap.ps1

.EXAMPLE
    .\hytale-server-bootstrap.ps1 -NoStart

.NOTES
    Never commit .hytale-downloader-credentials.json or data\auth\.
#>
[CmdletBinding()]
param(
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -- Platform guard ------------------------------------------------------------
if ($env:OS -ne 'Windows_NT') {
    Write-Host '[ERR ]  This bootstrap is for Windows. On Linux/macOS use hytale-server-bootstrap.sh.' -ForegroundColor Red
    exit 1
}

$ProjectDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location -LiteralPath $ProjectDir

$DownloaderUrl      = 'https://downloader.hytale.com/hytale-downloader.zip'
$DownloaderExeName  = 'hytale-downloader-windows-amd64.exe'
$DownloaderZipName  = 'hytale-downloader.zip'
$CredentialsFile    = Join-Path $ProjectDir '.hytale-downloader-credentials.json'
$StagingDir         = Join-Path $ProjectDir '.hytale-staging'
$DataDir            = Join-Path $ProjectDir 'data'
$ServerDir          = Join-Path $ProjectDir 'Server'
$StartBat           = Join-Path $ProjectDir 'start.bat'
$JvmOptions         = Join-Path $ProjectDir 'jvm.options'
$JavaRoot           = Join-Path $ProjectDir '.jdk'
$HytalePort         = 5520
$ManagedJvmMarker   = '# Hytale server JVM options (Windows).'

# -- Helpers -------------------------------------------------------------------
function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[ OK ]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Fail       { param([string]$Message) Write-Host "[ERR ]  $Message" -ForegroundColor Red; exit 1 }
function Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor DarkCyan
    Write-Host "  $Message" -ForegroundColor DarkCyan
    Write-Host ('=' * 60) -ForegroundColor DarkCyan
    Write-Host ''
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-NormalizedPath {
    param([string]$Path)
    $value = [string]$Path
    if ($value.StartsWith('\\?\')) { $value = $value.Substring(4) }
    try { return [System.IO.Path]::GetFullPath($value).TrimEnd('\') } catch { return $value.TrimEnd('\') }
}

function Expand-ZipArchive {
    param(
        [string]$Zip,
        [string]$Destination
    )

    Ensure-Directory $Destination

    # Windows 10/11 ships bsdtar, which is faster and more tolerant of long
    # paths than Expand-Archive. Fall back when tar is unavailable or fails.
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        try {
            & $tar.Source -xf $Zip -C $Destination
            if ($LASTEXITCODE -eq 0) { return }
        } catch { }
    }

    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
}

function Get-HytalePids {
    $pids = @()
    try {
        $pids = @(Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'HytaleServer\.jar' } |
            ForEach-Object { [int]$_.ProcessId })
    } catch {
        try {
            $pids = @(Get-WmiObject Win32_Process -Filter "Name = 'java.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -and $_.CommandLine -match 'HytaleServer\.jar' } |
                ForEach-Object { [int]$_.ProcessId })
        } catch {
            $pids = @()
        }
    }
    return $pids
}

function Test-HytaleRunning {
    return ((Get-HytalePids).Count -gt 0)
}

function Add-GitIgnorePatterns {
    $gitignore = Join-Path $ProjectDir '.gitignore'
    $patterns = @(
        'hytale-downloader-windows-amd64.exe',
        '.jdk-download.zip',
        '.jdk-extract/',
        'updater/'
    )

    if (-not (Test-Path -LiteralPath $gitignore)) {
        $content = "# Hytale secrets and generated files - never commit`r`n" + ($patterns -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($gitignore, $content)
        Write-Ok '.gitignore written.'
        return
    }

    $lines = @(Get-Content -LiteralPath $gitignore)
    $missing = @($patterns | Where-Object { $lines -notcontains $_ })
    if ($missing.Count -gt 0) {
        $content = "`r`n# Windows native runtime`r`n" + ($missing -join "`r`n") + "`r`n"
        [System.IO.File]::AppendAllText($gitignore, $content)
        Write-Ok 'Added Windows runtime files to .gitignore.'
    }
}

function Test-Java25 {
    param([string]$JavaExe)
    if (-not (Test-Path -LiteralPath $JavaExe -PathType Leaf)) { return $false }
    try {
        $first = (& $JavaExe -version 2>&1 | Select-Object -First 1)
        return ([string]$first -match 'version "25[."]')
    } catch {
        return $false
    }
}

function Find-Java25 {
    $candidates = @()
    if ($env:JAVA_HOME) {
        $candidates += (Join-Path $env:JAVA_HOME 'bin\java.exe')
    }
    $candidates += (Join-Path $JavaRoot 'bin\java.exe')

    if (Test-Path -LiteralPath $JavaRoot) {
        $candidates += @(Get-ChildItem -LiteralPath $JavaRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'bin\java.exe' })
    }

    foreach ($base in @('C:\Program Files\Eclipse Adoptium', 'C:\Program Files\Java')) {
        if (Test-Path -LiteralPath $base) {
            $candidates += @(Get-ChildItem -LiteralPath $base -Directory -Filter 'jdk-25*' -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'bin\java.exe' })
        }
    }

    $command = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($command) {
        $candidates += @($command | ForEach-Object { $_.Source })
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Java25 $candidate) { return $candidate }
    }
    return $null
}

function Install-Java25 {
    $zip = Join-Path $ProjectDir '.jdk-download.zip'
    $tmp = Join-Path $ProjectDir '.jdk-extract'

    Write-Info 'Java 25 not found. Downloading Temurin 25 for Windows x64...'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    Ensure-Directory $tmp

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing `
            -Uri 'https://api.adoptium.net/v3/binary/latest/25/ga/windows/x64/jdk/hotspot/normal/eclipse' `
            -OutFile $zip
    } catch {
        Fail "Could not download Java 25: $($_.Exception.Message). Install Temurin 25 manually or put a JDK 25 under .jdk\."
    }

    try {
        Expand-ZipArchive -Zip $zip -Destination $tmp
    } catch {
        Fail "Could not extract Java 25: $($_.Exception.Message)"
    }

    $java = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'java.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\bin\\java\.exe$' } |
        Select-Object -First 1
    if (-not $java) { Fail 'Java extraction did not produce bin\java.exe.' }

    $javaHome = Split-Path -Parent (Split-Path -Parent $java.FullName)
    if (Test-Path -LiteralPath $JavaRoot) { Remove-Item -LiteralPath $JavaRoot -Recurse -Force }
    Ensure-Directory $JavaRoot

    Get-ChildItem -LiteralPath $javaHome -Force | Move-Item -Destination $JavaRoot -Force
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    $java = Join-Path $JavaRoot 'bin\java.exe'
    Unblock-File -LiteralPath $java -ErrorAction SilentlyContinue
    if (-not (Test-Java25 $java)) {
        Fail 'The downloaded Java is not Java 25. Install Temurin 25 manually.'
    }
    return $java
}

function Get-TotalRamGb {
    try {
        $bytes = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
        return [int][math]::Round($bytes / 1GB, 0)
    } catch {
        return 0
    }
}

function Get-JvmContent {
    param([int]$RamGb)

    if ($RamGb -le 10) {
        $xms = '1g'; $xmx = '4g'
    } elseif ($RamGb -le 16) {
        $xms = '2g'; $xmx = '6g'
    } elseif ($RamGb -le 24) {
        $xms = '3g'; $xmx = '6g'
    } else {
        $xms = '4g'; $xmx = '8g'
    }

    return @"
$ManagedJvmMarker
# Loaded automatically by start.bat - one argument per line.
# Lines starting with # are comments.
#
# Tuned for a ${RamGb} GB Windows PC. Leave memory for Windows.
# Raise -Xmx only if you have more RAM and a larger view distance.
-Xms$xms
-Xmx$xmx

# G1 is a good fit for a small heap on Windows.
-XX:+UseG1GC
"@
}

function Set-JvmOptions {
    $ramGb = Get-TotalRamGb

    if (-not (Test-Path -LiteralPath $JvmOptions)) {
        [System.IO.File]::WriteAllText($JvmOptions, (Get-JvmContent $ramGb))
        Write-Ok "jvm.options written for ${ramGb} GB RAM."
        return
    }

    try {
        $content = [System.IO.File]::ReadAllText($JvmOptions)
    } catch {
        Fail "Could not read jvm.options: $($_.Exception.Message)"
    }

    $xmx = ''
    $match = [regex]::Match($content, '(?m)^-Xmx(\S+)')
    if ($match.Success) { $xmx = $match.Groups[1].Value }

    if ($content -match [regex]::Escape($ManagedJvmMarker)) {
        if ($ramGb -gt 0 -and $ramGb -le 10 -and $xmx -match '^([6-9]|[1-9][0-9]+)g$') {
            $backup = "$JvmOptions.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item -LiteralPath $JvmOptions -Destination $backup -Force
            [System.IO.File]::WriteAllText($JvmOptions, (Get-JvmContent $ramGb))
            Write-Warn "Adjusted jvm.options for ${ramGb} GB RAM (was -Xmx$xmx; previous file: $(Split-Path -Leaf $backup))."
        } else {
            Write-Ok "jvm.options already suitable (-Xmx$($xmx))."
        }
    } else {
        Write-Warn "jvm.options exists; preserving custom settings (-Xmx$($xmx))."
        if ($ramGb -gt 0 -and $ramGb -le 10 -and $xmx -match '^([6-9]|[1-9][0-9]+)g$') {
            Write-Warn "This PC has ${ramGb} GB RAM; -Xmx$xmx may be too large."
        }
    }
}

function Get-Downloader {
    $exe = Join-Path $ProjectDir $DownloaderExeName
    if (Test-Path -LiteralPath $exe) {
        Write-Ok 'Hytale Downloader already present.'
        return $exe
    }

    Write-Info 'Fetching the Hytale Downloader from the official source...'
    Ensure-Directory $StagingDir
    $tmp = Join-Path $StagingDir 'downloader'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    Ensure-Directory $tmp

    $zip = Join-Path $ProjectDir $DownloaderZipName
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $DownloaderUrl -OutFile $zip
        Expand-ZipArchive -Zip $zip -Destination $tmp
    } catch {
        Fail "Could not download the Hytale Downloader: $($_.Exception.Message)"
    }

    $found = Get-ChildItem -LiteralPath $tmp -Recurse -Filter $DownloaderExeName -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $found) { Fail "The downloader archive did not contain $DownloaderExeName." }

    Copy-Item -LiteralPath $found.FullName -Destination $exe -Force
    Unblock-File -LiteralPath $exe -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok 'Hytale Downloader ready.'
    return $exe
}

function Install-ServerFiles {
    $downloader = Get-Downloader

    if (Test-Path -LiteralPath $StagingDir) { Remove-Item -LiteralPath $StagingDir -Recurse -Force }
    Ensure-Directory $StagingDir
    $log = Join-Path $StagingDir 'download.log'

    Write-Info 'Downloading the latest Hytale server (this can take a while)...'
    $output = @()
    $rc = 1
    Push-Location -LiteralPath $StagingDir
    try {
        $output = @(& $downloader -credentials-path $CredentialsFile 2>&1)
        $rc = $LASTEXITCODE
        $output | Tee-Object -FilePath $log | Out-Host
    } finally {
        Pop-Location
    }

    $text = ($output | Out-String)
    if ($rc -ne 0 -and $text -match 'invalid_grant|refresh token expired|authorization grant') {
        Write-Warn 'Saved Hytale downloader credentials expired. Starting a fresh login...'
        if (Test-Path -LiteralPath $CredentialsFile) {
            $expired = "$CredentialsFile.expired.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $CredentialsFile -Destination $expired -Force
        }
        Get-ChildItem -LiteralPath $StagingDir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Push-Location -LiteralPath $StagingDir
        try {
            $output = @(& $downloader -credentials-path $CredentialsFile 2>&1)
            $rc = $LASTEXITCODE
            $output | Tee-Object -FilePath $log -Append | Out-Host
        } finally {
            Pop-Location
        }
        $text = ($output | Out-String)
    }

    if ($rc -ne 0) {
        Fail 'The Hytale Downloader failed. Check the output above and your account access.'
    }

    $zip = Get-ChildItem -LiteralPath $StagingDir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $zip) {
        $zip = Get-ChildItem -LiteralPath $StagingDir -Filter '*.zip' -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $zip) { Fail 'No server archive was downloaded.' }

    Write-Info "Extracting $($zip.Name)..."
    $extract = Join-Path $StagingDir 'extracted'
    if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
    try {
        Expand-ZipArchive -Zip $zip.FullName -Destination $extract
    } catch {
        Fail "Could not extract the server archive: $($_.Exception.Message)"
    }

    $root = $extract
    if (-not (Test-Path -LiteralPath (Join-Path $root 'Server'))) {
        $candidate = Get-ChildItem -LiteralPath $extract -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Server') } |
            Select-Object -First 1
        if ($candidate) { $root = $candidate.FullName }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $root 'Server')) -or
        -not (Test-Path -LiteralPath (Join-Path $root 'Assets.zip'))) {
        Fail 'The downloaded archive is missing Server\ or Assets.zip.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'start.bat'))) {
        Fail 'The downloaded archive is missing start.bat. Copy it from the Hytale launcher and re-run.'
    }

    Copy-Item -LiteralPath (Join-Path $root 'Server') -Destination $ServerDir -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'Assets.zip') -Destination (Join-Path $ProjectDir 'Assets.zip') -Force
    Copy-Item -LiteralPath (Join-Path $root 'start.bat') -Destination $StartBat -Force

    $startSh = Join-Path $root 'start.sh'
    if (Test-Path -LiteralPath $startSh) {
        Copy-Item -LiteralPath $startSh -Destination (Join-Path $ProjectDir 'start.sh') -Force
    }

    Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok 'Server files installed.'
}

function Set-DirectoryJunction {
    param(
        [string]$Link,
        [string]$Target
    )

    Ensure-Directory $Target

    if (Test-Path -LiteralPath $Link) {
        $item = Get-Item -LiteralPath $Link -Force
        if ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink') {
            $actual = @($item.Target) | Select-Object -First 1
            if ($actual -and ((Get-NormalizedPath $actual) -ieq (Get-NormalizedPath $Target))) {
                Write-Ok "$Link -> $Target"
                return $true
            }
            Write-Warn "Replacing $Link (was -> $($item.Target))."
            Remove-Item -LiteralPath $Link -Force
        } elseif ($item.PSIsContainer) {
            $children = @(Get-ChildItem -LiteralPath $Link -Force -ErrorAction SilentlyContinue)
            if ($children.Count -eq 0) {
                Remove-Item -LiteralPath $Link -Force
            } else {
                Write-Warn "$Link exists and is not a junction; leaving it untouched."
                Write-Warn "Move its contents into $Target if you want data\ to be authoritative."
                return $false
            }
        } else {
            Write-Warn "$Link exists and is not a directory; leaving it untouched."
            return $false
        }
    }

    try {
        New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null
    } catch {
        Write-Warn "Could not create junction $Link -> ${Target}: $($_.Exception.Message)"
        return $false
    }
    Write-Ok "$Link -> $Target"
    return $true
}

function Test-HardLinkToTarget {
    param(
        [string]$Link,
        [string]$Target
    )
    try {
        $out = @(& fsutil.exe hardlink list $Link 2>$null)
        if ($LASTEXITCODE -ne 0) { return $false }
        $needle = Get-NormalizedPath $Target
        foreach ($line in $out) {
            if ($line -and ([string]$line).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    } catch {
        return $false
    }
    return $false
}

function Set-AuthHardLink {
    param([string]$Name)

    $authDir = Join-Path $DataDir 'auth'
    $link = Join-Path $ServerDir $Name
    $target = Join-Path $authDir $Name
    Ensure-Directory $authDir
    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType File -Path $target -Force | Out-Null
    }
    $targetItem = Get-Item -LiteralPath $target -Force

    if ((Test-Path -LiteralPath $link) -and $targetItem.Length -eq 0) {
        $linkItem = Get-Item -LiteralPath $link -Force
        if (-not $linkItem.PSIsContainer -and $linkItem.Length -gt 0) {
            Copy-Item -LiteralPath $link -Destination $target -Force
            $targetItem = Get-Item -LiteralPath $target -Force
            Write-Ok "Moved Server\$Name into data\auth\."
        }
    }

    if (Test-Path -LiteralPath $link) {
        $linkItem = Get-Item -LiteralPath $link -Force
        if ($linkItem.LinkType -eq 'SymbolicLink') {
            $actual = @($linkItem.Target) | Select-Object -First 1
            if ($actual -and ((Get-NormalizedPath $actual) -ieq (Get-NormalizedPath $target))) {
                Write-Ok "Server\$Name -> data\auth\$Name"
                return
            }
        } elseif ($linkItem.LinkType -eq 'HardLink') {
            if ($linkItem.Length -eq $targetItem.Length -or (Test-HardLinkToTarget $link $target)) {
                Write-Ok "Server\$Name -> data\auth\$Name"
                return
            }
        } elseif (-not $linkItem.PSIsContainer) {
            $backup = "$link.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $link -Destination $backup -Force
            Write-Warn "Server\$Name existed and data\auth\$Name is authoritative; previous file saved as $(Split-Path -Leaf $backup)."
        } else {
            Write-Warn "Server\$Name is a directory; leaving it untouched."
            return
        }
    }

    try {
        New-Item -ItemType HardLink -Path $link -Target $target -ErrorAction Stop | Out-Null
        Write-Ok "Server\$Name -> data\auth\$Name (hardlink)"
        return
    } catch {
        Write-Warn "Could not create a hardlink for Server\$($Name): $($_.Exception.Message)"
    }

    try {
        New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
        Write-Ok "Server\$Name -> data\auth\$Name (symlink)"
        return
    } catch {
        Write-Warn "Could not create a symlink for Server\$($Name): $($_.Exception.Message)"
    }

    Copy-Item -LiteralPath $target -Destination $link -Force
    Write-Warn "Copied data\auth\$Name to Server\$Name. Auth refreshes will not automatically update data\auth\."
}

function Get-LanIp {
    try {
        $config = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
            Select-Object -First 1
        if ($config -and $config.IPv4Address) {
            return @($config.IPv4Address)[0].IPAddress
        }
    } catch { }

    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'Loopback' } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    } catch { }

    return '<your-lan-ip>'
}

function Start-HytaleServer {
    param([string]$JavaExe)

    $javaHome = Split-Path -Parent (Split-Path -Parent $JavaExe)
    $env:JAVA_HOME = $javaHome
    $env:Path = "$javaHome\bin;$env:Path"

    Write-Info 'Opening a new console window for the Hytale server...'
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', 'start.bat' -WorkingDirectory $ProjectDir | Out-Null
    } catch {
        Fail "Could not start start.bat: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 8
    $pids = Get-HytalePids
    if ($pids.Count -gt 0) {
        Write-Ok "Server process started (PID: $($pids -join ', '))."
    } else {
        Write-Warn 'The server process was not detected yet. Check the new console window for errors.'
    }
}

# -- Banner --------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Blue
Write-Host '  Hytale Server Bootstrap - Windows native edition' -ForegroundColor Blue
Write-Host ('=' * 60) -ForegroundColor Blue
Write-Host ''

$running = Get-HytalePids
if ($running.Count -gt 0) {
    Write-Ok "Hytale server is already running (PID: $($running -join ', '))."
    Write-Host '  Use /stop in its console window to stop it.' -ForegroundColor Gray
    exit 0
}

Step 'Windows native mode'
Add-GitIgnorePatterns
Ensure-Directory $DataDir

$needsServerFiles = (-not (Test-Path -LiteralPath (Join-Path $ServerDir 'HytaleServer.jar'))) -or
    (-not (Test-Path -LiteralPath (Join-Path $ProjectDir 'Assets.zip'))) -or
    (-not (Test-Path -LiteralPath $StartBat))

if ($needsServerFiles) {
    if (Test-Path -LiteralPath $ServerDir) {
        Fail 'Server\ exists but is incomplete. Restore/copy Server\, Assets.zip and start.bat, or move Server\ aside and re-run.'
    }
    Install-ServerFiles
} else {
    Write-Ok 'Existing Server\, Assets.zip and start.bat found; skipping the download.'
}

if (-not (Test-Path -LiteralPath (Join-Path $ServerDir 'HytaleServer.jar'))) {
    Fail 'Server\HytaleServer.jar is missing.'
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectDir 'Assets.zip'))) {
    Fail 'Assets.zip is missing.'
}
if (-not (Test-Path -LiteralPath $StartBat)) {
    Fail 'start.bat is missing. Copy it from the Hytale launcher and re-run.'
}

$java = Find-Java25
if ($java) {
    Write-Ok "Java 25 found: $java"
} else {
    $java = Install-Java25
    Write-Ok 'Java 25 installed under .jdk\.'
}

Step 'Preparing persistent data'
Ensure-Directory (Join-Path $DataDir 'universe')
Ensure-Directory (Join-Path $DataDir 'backups')
Ensure-Directory (Join-Path $DataDir 'auth')

$universeOk = Set-DirectoryJunction -Link (Join-Path $ServerDir 'universe') -Target (Join-Path $DataDir 'universe')
if (-not $universeOk) {
    Fail 'Server\universe is a real directory. Merge it into data\universe, remove Server\universe, then re-run.'
}
$backupsOk = Set-DirectoryJunction -Link (Join-Path $ServerDir 'backups') -Target (Join-Path $DataDir 'backups')
if (-not $backupsOk) {
    Write-Warn 'Using the existing Server\backups; data\backups is not linked.'
}

Set-AuthHardLink 'auth.key'
Set-AuthHardLink 'auth.enc'

Write-Host "  World:      $DataDir\universe"
Write-Host "  Backups:    $DataDir\backups"
Write-Host "  Auth files: $DataDir\auth  <- never commit this folder"
Write-Host ''

Set-JvmOptions

if (-not $NoStart) {
    Step 'Starting Hytale Server'
    Start-HytaleServer $java
} else {
    Write-Ok 'Preparation complete; server not started (-NoStart).'
    Write-Host '  Start it with: .\start.bat' -ForegroundColor Gray
}

$lanIp = Get-LanIp
Step 'Hytale Server - Windows'
Write-Host '  ONE-TIME SERVER AUTHORIZATION' -ForegroundColor Yellow
Write-Host ''
Write-Host '  In the server console window, type:'
Write-Host ''
Write-Host '    /auth login device' -ForegroundColor Green
Write-Host ''
Write-Host '  Open the URL, approve the code, and keep the console window open.'
Write-Host '  The token is saved in data\auth\.'
Write-Host ''
Write-Host '  CONNECT' -ForegroundColor Yellow
Write-Host "    LAN:          ${lanIp}:${HytalePort}" -ForegroundColor Green
Write-Host "    This machine: 127.0.0.1:${HytalePort}" -ForegroundColor Green
Write-Host ''
Write-Host '  COMMON COMMANDS' -ForegroundColor Yellow
Write-Host '    Start:            .\hytale-server-bootstrap.ps1'
Write-Host '    Prepare only:     .\hytale-server-bootstrap.ps1 -NoStart'
Write-Host '    Stop (console):   /stop'
Write-Host '    Auth (console):   /auth login device'
Write-Host '    Update (console): /update check'
Write-Host '                      /update download'
Write-Host '                      /update apply --confirm'
Write-Host ''
Write-Host '  WINDOWS NOTES' -ForegroundColor Yellow
Write-Host '    The server console is a separate window; closing it stops the server.'
Write-Host '    Use /stop first so the world is saved.'
Write-Host '    Allow incoming UDP 5520 in Windows Defender Firewall.'
Write-Host '    Run this in an elevated PowerShell once if needed:'
Write-Host '      New-NetFirewallRule -DisplayName "Hytale Server" -Direction Inbound -Protocol UDP -LocalPort 5520 -Action Allow'
Write-Host ''
Write-Host '  SECURITY' -ForegroundColor Yellow
Write-Host '    Never commit .hytale-downloader-credentials.json or data\auth\.'
Write-Host '    Both are already listed in .gitignore.'
Write-Host ''
