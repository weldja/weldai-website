# ============================================================
# Weld AI — System Check Script v1.1
# ============================================================
# How to run:
#   1. Right-click this file
#   2. Select "Run with PowerShell"
#   3. The script runs automatically - no input needed
#   4. WeldAI_SystemCheck.txt saved to your Desktop
#   5. Email that file to hello@weldai.uk
# ============================================================

$RunDate = Get-Date -Format "yyyy-MM-dd_HHmmss"
$OutputFile = "$env:USERPROFILE\Desktop\WeldAI_SystemCheck_$RunDate.txt"
$lines = @()

function Add($text = "") {
    Write-Host $text
    $script:lines += $text
}

Add "============================================================"
Add "  Weld AI System Check"
Add "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add "  Computer:  $env:COMPUTERNAME"
Add "  User:      $env:USERNAME"
Add "============================================================"
Add ""

# 1. Windows version
Add "[ 1 ] Windows Version"
$os = Get-CimInstance Win32_OperatingSystem
Add "  Caption:  $($os.Caption)"
Add "  Version:  $($os.Version)"
Add "  Build:    $($os.BuildNumber)"
Add ""

# 2. RAM
Add "[ 2 ] RAM"
$ram = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
Add "  Total RAM: $ram GB"
Add ""

# 3. CPU
Add "[ 3 ] CPU"
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Add "  Name:   $($cpu.Name)"
Add "  Cores:  $($cpu.NumberOfCores)"
$archMap = @{0="x86"; 1="MIPS"; 2="Alpha"; 3="PowerPC"; 5="ARM"; 6="ia64"; 9="x64/x86_64"}
$archName = if ($archMap.ContainsKey([int]$cpu.Architecture)) { $archMap[[int]$cpu.Architecture] } else { $cpu.Architecture }
Add "  Arch:   $archName"
$virt = $cpu.VirtualizationFirmwareEnabled
Add "  Virtualisation enabled: $virt"
Add ""

# 4. Disk space
Add "[ 4 ] Disk Space (C:)"
$disk = Get-PSDrive C
$freeGB = [math]::Round($disk.Free / 1GB, 1)
$usedGB = [math]::Round($disk.Used / 1GB, 1)
Add "  Free:  $freeGB GB"
Add "  Used:  $usedGB GB"
Add ""

# 5. Docker
Add "[ 5 ] Docker"
try {
    $dv = docker --version 2>&1
    Add "  $dv"
    $di = docker info 2>&1 | Select-String "Server Version|Operating System|Total Memory|Kernel Version"
    $di | ForEach-Object { Add "  $_" }
} catch {
    Add "  Docker not installed or not running"
}
Add ""

# 6. Internet connectivity
Add "[ 6 ] Internet Connectivity"
$sites = @("api.anthropic.com:443", "hub.docker.com:443", "registry-1.docker.io:443")
foreach ($s in $sites) {
    $parts = $s.Split(":")
    try {
        $result = Test-NetConnection -ComputerName $parts[0] -Port $parts[1] -WarningAction SilentlyContinue
        $status = if ($result.TcpTestSucceeded) { "OK" } else { "FAILED" }
        Add "  $($parts[0]) : $status"
    } catch {
        Add "  $($parts[0]) : ERROR"
    }
}
Add ""

# 7. Network IP
Add "[ 7 ] Network IP Addresses"
Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*"
} | ForEach-Object {
    Add "  Interface: $($_.InterfaceAlias)  IP: $($_.IPAddress)"
}
Add ""

# 8. Ports in use
Add "[ 8 ] Ports 80 and 443"
$port80  = Get-NetTCPConnection -LocalPort 80  -ErrorAction SilentlyContinue
$port443 = Get-NetTCPConnection -LocalPort 443 -ErrorAction SilentlyContinue
Add "  Port 80  in use: $(if ($port80)  { 'YES - may conflict with Weld AI' } else { 'No' })"
Add "  Port 443 in use: $(if ($port443) { 'YES - may conflict with Weld AI' } else { 'No' })"
Add ""

# 9. C:\WeldAI installation folder check
Add "[ 9 ] Installation Folder (C:\WeldAI)"
$installPath = "C:\WeldAI"
if (Test-Path $installPath) {
    Add "  C:\WeldAI already exists"
    $existing = Get-ChildItem $installPath -ErrorAction SilentlyContinue
    Add "  Existing files: $($existing.Count)"
} else {
    Add "  C:\WeldAI does not exist yet — will be created during installation"
}
# Check free space on C: (read only)
$cDrive = Get-PSDrive C -ErrorAction SilentlyContinue
if ($cDrive) {
    $freeGB = [math]::Round($cDrive.Free / 1GB, 1)
    $status = if ($freeGB -ge 10) { "OK ($freeGB GB free)" } else { "WARNING: Only $freeGB GB free — minimum 10 GB required" }
    Add "  C: free space: $status"
}
# Check current user is Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add "  Running as Administrator: $isAdmin"
Add ""

# 10. Available drives
Add "[ 10 ] Available Drives"
$drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
foreach ($drive in $drives) {
    try {
        $label = if ($drive.Description) { $drive.Description } else { "No label" }
        if ($drive.Root -match "^[A-Z]:\\") {
            # Local drive
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            $usedGB = [math]::Round($drive.Used / 1GB, 1)
            Add "  $($drive.Root)  Local  Free: $freeGB GB  Used: $usedGB GB  Label: $label"
        } else {
            # Network or other
            Add "  $($drive.Root)  Network/Other  Label: $label"
        }
    } catch {
        Add "  $($drive.Root)  Not accessible"
    }
}
# Also check for mapped network drives via WMI
$netDrives = Get-CimInstance Win32_MappedLogicalDisk -ErrorAction SilentlyContinue
if ($netDrives) {
    Add "  Mapped network drives:"
    $netDrives | ForEach-Object {
        Add "    $($_.DeviceID)  -> $($_.ProviderName)"
    }
}
Add "  NOTE: Please identify which drive/folder contains your company documents."
Add ""

Add "============================================================"
Add "  Check complete."
Add "  Please email WeldAI_SystemCheck.txt from your Desktop"
Add "  to hello@weldai.uk"
Add "============================================================"

# Save to file
$lines | Out-File -FilePath $OutputFile -Encoding ASCII
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  DONE! File saved to your Desktop:" -ForegroundColor Green
Write-Host "  WeldAI_SystemCheck.txt" -ForegroundColor Green
Write-Host "  Please email it to hello@weldai.uk" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

Read-Host "Press Enter to close"