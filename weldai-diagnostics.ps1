<#
.SYNOPSIS
    Weld AI System Check v2.0 (on-premise edition)
.DESCRIPTION
    Checks whether this Windows PC can run Weld AI, which runs entirely on
    this machine with no cloud service.

    - Makes NO changes to the system.
    - Makes NO internet connections.
    - Reads NO documents and NO file names. It records hardware, Windows and
      network settings only (the report is plain text - open it and look).

    Writes weldai-diagnostics.zip to your Desktop.
.USAGE
    Right-click > Run with PowerShell
    Email weldai-diagnostics.zip from your Desktop to hello@weldai.uk
    Subject: System check - [your business name]
#>
param(
    [switch]$NoPause,          # for unattended runs: skip Explorer and the final prompt
    [string]$OutDir = "$env:USERPROFILE\Desktop"
)

$ErrorActionPreference = 'SilentlyContinue'

# -- Output setup --------------------------------------------------------------
$timestamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$reportPath = "$env:TEMP\weldai-diagnostics_$timestamp.txt"
$zipPath    = Join-Path $OutDir 'weldai-diagnostics.zip'
$lines      = [System.Collections.Generic.List[string]]::new()

function Add  { param($t = '') $lines.Add($t); Write-Host $t }
function Sep  { Add ('-' * 60) }
function Head { param($t) Add ''; Add "=== $t ==="; Add '' }
function Ok   { param($t) Add "  [PASS]  $t" }
function Warn { param($t) Add "  [WARN]  $t" }
function Fail { param($t) Add "  [FAIL]  $t" }
function Info { param($t) Add "  [INFO]  $t" }
function Skip { param($t) Add "  [SKIP]  $t (needs Administrator - please confirm manually)" }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Add "Weld AI System Check v2.0 (on-premise edition)"
Add "Generated : $(Get-Date -Format 'dd MMM yyyy HH:mm')"
Add "Computer  : $env:COMPUTERNAME"
Add "Admin     : $isAdmin"
Add ""
Add "This report holds hardware, Windows and network settings only."
Add "No documents or file names were read. No internet connection was made."
if (-not $isAdmin) {
    Add ""
    Add "  NOTE: Run as a standard user. Checks marked [SKIP] need Administrator"
    Add "  rights. That is fine - they can be confirmed on the install call."
}
Sep

# -- 1. WINDOWS VERSION -------------------------------------------------------
Head "1. Windows"

$os      = Get-CimInstance Win32_OperatingSystem
$build   = [int]$os.BuildNumber
$cv      = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$version = $cv.DisplayVersion
$installType = $cv.InstallationType

Info "OS      : $($os.Caption)"
Info "Version : $version  (Build $build)"

if ($installType -in @('Server', 'Server Core')) {
    Warn "Windows Server detected. The standard install is for Windows 10 or 11 PCs - email hello@weldai.uk before going further."
} elseif ($build -ge 22000) {
    Ok "Windows 11 - supported"
} elseif ($build -ge 19044) {
    Ok "Windows 10 $version (build $build) - meets the 21H2 minimum"
} else {
    Fail "Windows 10 build $build is older than 21H2 (19044). Run Windows Update first."
}

# -- 2. PROCESSOR -------------------------------------------------------------
Head "2. Processor"

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs  = Get-CimInstance Win32_ComputerSystem

Info "CPU   : $($cpu.Name)"
Info "Cores : $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) logical"

if     ($cpu.NumberOfCores -ge 8) { Ok "$($cpu.NumberOfCores) cores - recommended (8+)" }
elseif ($cpu.NumberOfCores -ge 4) { Ok "$($cpu.NumberOfCores) cores - meets the minimum (4). 8+ is better on a PC without a graphics card." }
else                              { Fail "$($cpu.NumberOfCores) cores - at least 4 are needed" }

if ($cpu.Architecture -eq 9) { Ok "64-bit Intel/AMD processor" }
else                         { Fail "Not a 64-bit Intel/AMD processor (ARM PCs are not supported)" }

# AVX2 speeds up the AI model on the processor (PF_AVX2_INSTRUCTIONS_AVAILABLE = 40)
try {
    Add-Type -Namespace WeldAI -Name Cpu -ErrorAction Stop -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);'
    if ([WeldAI.Cpu]::IsProcessorFeaturePresent(40)) { Ok "Processor supports AVX2" }
    else { Warn "Processor does not report AVX2 - the AI model will run much slower without a graphics card" }
} catch {
    Info "Could not check for AVX2 on this PC (most processors made since 2015 have it)"
}

# Virtualisation: a running hypervisor is the definitive check. The firmware
# flag can read false on managed PCs even when the hypervisor is active.
if ($cs.HypervisorPresent) {
    Ok "Virtualisation is active"
} elseif ($cpu.VirtualizationFirmwareEnabled -eq $true) {
    Ok "Virtualisation is enabled in the BIOS"
} elseif ($cpu.VirtualizationFirmwareEnabled -eq $false) {
    Fail "Virtualisation is switched off in the BIOS. Enable Intel VT-x or AMD-V (your IT person or PC supplier can do this)."
} else {
    Info "Could not tell whether virtualisation is on - check Task Manager > Performance > CPU > Virtualisation"
}

# -- 3. MEMORY ----------------------------------------------------------------
Head "3. Memory (RAM)"

# A "16 GB" PC reports slightly under 16, so compare against 15.5 and 11.5.
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
Info "Installed RAM: $ramGB GB"

if     ($ramGB -ge 15.5) { Ok "$ramGB GB - recommended (16 GB+)" }
elseif ($ramGB -ge 11.5) { Warn "$ramGB GB - enough, with little headroom. 16 GB is recommended." }
else                     { Fail "$ramGB GB - at least 12 GB is needed (16 GB recommended)" }

# -- 4. GRAPHICS CARD ---------------------------------------------------------
Head "4. Graphics card (decides how fast answers are)"

$cards = Get-CimInstance Win32_VideoController
foreach ($card in $cards) { Info "Display adapter: $($card.Name)" }

$gpuLine = $null
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $gpuLine = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null | Select-Object -First 1
}

if ($gpuLine -and $gpuLine -match ',') {
    $parts  = $gpuLine -split ',\s*'
    $vramMB = 0
    [void][int]::TryParse(($parts[1] -replace '[^\d]', ''), [ref]$vramMB)
    $vramGB = [math]::Round($vramMB / 1024, 1)
    Info "NVIDIA card : $($parts[0])"
    Info "Card memory : $vramGB GB    Driver: $($parts[2])"

    if     ($vramMB -ge 7500) { Ok "$vramGB GB NVIDIA card - recommended. Both AI models fit on the card." }
    elseif ($vramMB -ge 5500) { Ok "$vramGB GB NVIDIA card - both AI models fit, using compact settings." }
    elseif ($vramMB -ge 3500) { Warn "$vramGB GB NVIDIA card - works. Measured on a 4 GB card: first words in about 10 seconds, summaries about 30 seconds. 8 GB+ is recommended." }
    else                      { Warn "$vramGB GB NVIDIA card - too small to hold the AI model. Expect answers at no-graphics-card speed (20-60 seconds or more)." }
} elseif ($cards | Where-Object { $_.Name -match 'NVIDIA' }) {
    Warn "An NVIDIA card is fitted but its driver tools (nvidia-smi) were not found. Install the current NVIDIA driver so the card can be used."
} else {
    Warn "No NVIDIA graphics card found. Weld AI will still work, but answers take 20-60 seconds or more. An NVIDIA card with 8 GB+ is recommended."
}

# -- 5. DISK SPACE ------------------------------------------------------------
Head "5. Disk space"

$c      = Get-PSDrive C
$freeGB = [math]::Round($c.Free / 1GB, 1)
Info "C: drive - $freeGB GB free"

if     ($freeGB -ge 40) { Ok "$freeGB GB free - recommended (40 GB+)" }
elseif ($freeGB -ge 25) { Warn "$freeGB GB free - enough to install, with little room for documents and backups. 40 GB+ is recommended." }
else                    { Fail "$freeGB GB free - at least 25 GB is needed" }

foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
    if ($drive.Root -match '^[A-Z]:\\$' -and $drive.Name -ne 'C' -and $null -ne $drive.Free) {
        Info "$($drive.Root)  $([math]::Round($drive.Free / 1GB, 1)) GB free"
    }
}

# -- 6. WHERE THE DOCUMENTS LIVE ----------------------------------------------
Head "6. Network drives"

$netDrives = Get-CimInstance Win32_MappedLogicalDisk
if ($netDrives) {
    $netDrives | ForEach-Object { Info "Mapped drive $($_.DeviceID)  ->  $($_.ProviderName)" }
    Warn "Mapped network drives found. If your documents are on one, they need a copy in a folder on this PC (I can set up an automatic nightly copy)."
} else {
    Info "No mapped network drives"
}
Info "Before the install call, decide which folder on this PC holds the documents to search."

# -- 7. WSL2 ------------------------------------------------------------------
Head "7. WSL2 (Windows feature that Docker needs)"

if ($isAdmin) {
    $wslF = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux'
    $vmpF = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform'
    if ($wslF.State -eq 'Enabled') { Ok "WSL feature enabled" }
    else                           { Warn "WSL feature not enabled yet. Run in PowerShell as Administrator: wsl --install   then restart." }
    if ($vmpF.State -eq 'Enabled') { Ok "Virtual Machine Platform enabled" }
    else                           { Warn "Virtual Machine Platform not enabled yet. 'wsl --install' turns it on." }
} else {
    Skip "WSL feature status"
}

# wsl.exe writes UTF-16; strip the null characters before matching.
$wslStatus = ((& wsl.exe --status 2>&1 | Out-String) -replace "`0", '')
if     ($wslStatus -match 'Default Version\s*:\s*2') { Ok "WSL default version is 2" }
elseif ($wslStatus -match 'Default Version\s*:\s*1') { Warn "WSL default version is 1. Run: wsl --set-default-version 2" }
else   { Info "WSL2 is not set up yet. See weldai.uk/it-setup.html (one command and a restart)." }

# -- 8. DOCKER DESKTOP --------------------------------------------------------
Head "8. Docker Desktop"

$dockerVer = & docker --version 2>&1 | Out-String
if ($dockerVer -match 'Docker version ([\d.]+)') {
    $dv = $Matches[1]
    if ([int]($dv -split '\.')[0] -ge 24) { Ok "Docker $dv installed" }
    else                                  { Warn "Docker $dv is older than version 24 - it will be updated on the install call" }

    $dockerInfo = & docker info 2>&1 | Out-String
    if ($dockerInfo -match 'Server Version') {
        Ok "Docker is running"
        if ($dockerInfo -match '(?i)nvidia') { Ok "Docker can see the NVIDIA graphics card" }
    } else {
        Info "Docker is installed but not running at the moment"
    }
} else {
    Info "Docker Desktop is not installed yet. That is expected - it is installed on the call."
}

if (Test-Path 'C:\WeldAI') {
    Warn "C:\WeldAI already exists - an earlier installation may be present. Mention this when you email the report."
}

# -- 9. PORTS -----------------------------------------------------------------
Head "9. Ports 80 and 443 (how staff reach Weld AI in a browser)"

foreach ($port in @(80, 443)) {
    $inUse = Get-NetTCPConnection -LocalPort $port -State Listen
    if ($inUse) { Warn "Port $port is already in use on this PC - another web service (e.g. IIS) may clash. Weld AI can use a different port." }
    else        { Ok "Port $port is free" }
}

if ($isAdmin) {
    foreach ($port in @(80, 443)) {
        $rules = Get-NetFirewallRule -Direction Inbound -Enabled True |
                 Where-Object { $_ | Get-NetFirewallPortFilter |
                                Where-Object { $_.LocalPort -eq $port -and $_.Protocol -eq 'TCP' } }
        if ($rules) { Ok   "Firewall allows inbound port $port ('$($rules[0].DisplayName)')" }
        else        { Info "No inbound firewall rule for port $port yet - only needed if staff use Weld AI from other PCs" }
    }
} else {
    Skip "Windows Firewall rules for ports 80 and 443"
}

# -- 10. NETWORK ADDRESS ------------------------------------------------------
Head "10. Network address"

$skipPatterns = @('Loopback','vEthernet','Default Switch','WSL','Bluetooth','Teredo','ISATAP','6to4')
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $iface = $_.InterfaceAlias
        $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' -and
        -not ($skipPatterns | Where-Object { $iface -like "*$_*" })
    } |
    ForEach-Object {
        Info "$($_.InterfaceAlias): $($_.IPAddress) ($($_.PrefixOrigin))"
        if     ($_.PrefixOrigin -eq 'Manual') { Ok   "Fixed address on $($_.InterfaceAlias)" }
        elseif ($_.PrefixOrigin -eq 'Dhcp')   { Info "Automatic (DHCP) address. If other PCs will use Weld AI, ask for a fixed address or DHCP reservation for this PC." }
    }
Info "Weld AI needs NO outbound internet access to run. Internet is used on install day only."

# -- SUMMARY ------------------------------------------------------------------
Head "SUMMARY"

$passCount = @($lines | Where-Object { $_ -match '^\s*\[PASS\]' }).Count
$failCount = @($lines | Where-Object { $_ -match '^\s*\[FAIL\]' }).Count
$warnCount = @($lines | Where-Object { $_ -match '^\s*\[WARN\]' }).Count
$skipCount = @($lines | Where-Object { $_ -match '^\s*\[SKIP\]' }).Count

Add "PASS : $passCount"
Add "WARN : $warnCount   (worth a look - none of these stop an install)"
Add "FAIL : $failCount   (must be fixed before installing)"
if ($skipCount -gt 0) { Add "SKIP : $skipCount   (needs Administrator; can be confirmed on the call)" }
Add ""

if     ($failCount -gt 0) { Add "ACTION NEEDED: $failCount item(s) must be fixed. See the [FAIL] lines above." }
elseif ($warnCount -gt 0) { Add "This PC can run Weld AI. Please read the [WARN] lines above." }
else                      { Add "This PC looks ready for Weld AI." }

Sep
Add "Weld AI - weldai.uk - hello@weldai.uk"

# -- WRITE AND ZIP ------------------------------------------------------------
$lines | Out-File -FilePath $reportPath -Encoding UTF8
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path $reportPath -DestinationPath $zipPath -Force

# -- CONSOLE SUMMARY ----------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Weld AI System Check complete"              -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  PASS : $passCount"                          -ForegroundColor Green
if ($warnCount -gt 0) { Write-Host "  WARN : $warnCount" -ForegroundColor Yellow }
if ($failCount -gt 0) { Write-Host "  FAIL : $failCount" -ForegroundColor Red }
if ($skipCount -gt 0) { Write-Host "  SKIP : $skipCount" -ForegroundColor DarkGray }
Write-Host ""
Write-Host "  Report saved to:"                           -ForegroundColor White
Write-Host "  $zipPath"                                   -ForegroundColor White
Write-Host ""
Write-Host "  Please email the zip to hello@weldai.uk"    -ForegroundColor White
Write-Host "  Subject: System check - [your business]"    -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if (-not $NoPause) {
    Start-Process explorer.exe -ArgumentList "/select,`"$zipPath`""
    Read-Host "Press Enter to close"
}
