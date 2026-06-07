<#
.SYNOPSIS
    Weld AI Pre-Installation Diagnostics v1.4
.DESCRIPTION
    Checks the server environment against Weld AI installation requirements.
    Produces a plain-text report zipped to the Desktop.
    Makes NO changes to the system.
.USAGE
    Right-click > Run with PowerShell
    Email weldai-diagnostics.zip from your Desktop to hello@weldai.uk
    Subject: Diagnostics - [your company name]
#>

$ErrorActionPreference = 'SilentlyContinue'

# -- Output setup --------------------------------------------------------------
$timestamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$reportPath = "$env:TEMP\weldai-diagnostics_$timestamp.txt"
$zipPath    = "$env:USERPROFILE\Desktop\weldai-diagnostics.zip"
$lines      = [System.Collections.Generic.List[string]]::new()

function Add  { param($t = '') $lines.Add($t); Write-Host $t }
function Sep  { Add ('-' * 60) }
function Head { param($t) Add ''; Add "=== $t ==="; Add '' }
function Ok   { param($t) Add "  [PASS]  $t" }
function Warn { param($t) Add "  [WARN]  $t" }
function Fail { param($t) Add "  [FAIL]  $t" }
function Info { param($t) Add "  [INFO]  $t" }
function Skip { param($t) Add "  [SKIP]  $t (requires Administrator - please confirm manually)" }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Add "Weld AI Pre-Installation Diagnostics"
Add "Generated : $(Get-Date -Format 'dd MMM yyyy HH:mm')"
Add "Hostname  : $env:COMPUTERNAME"
Add "Run as    : $env:USERDOMAIN\$env:USERNAME"
Add "Admin     : $isAdmin"
if (-not $isAdmin) {
    Add ""
    Add "  NOTE: Running as standard user. Some checks marked [SKIP] require"
    Add "  Administrator rights. Please confirm those items manually."
}
Sep

# -- 1. WINDOWS VERSION -------------------------------------------------------
Head "1. Windows Operating System"

$os      = Get-CimInstance Win32_OperatingSystem
$build   = [int]$os.BuildNumber
$version = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion

Info "OS      : $($os.Caption)"
Info "Version : $version  (Build $build)"

if     ($build -ge 22000) { Ok "Windows 11 detected - fully supported" }
elseif ($build -ge 19044) { Ok "Windows 10 $version (build $build) - meets 21H2 minimum" }
elseif ($build -ge 17763) {
    # Windows Server — check for Desktop Experience vs Core
    $installType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).InstallationType
    Info "Windows Server installation type: $installType"
    if ($installType -eq 'Server Core') {
        Fail "Windows Server Core detected - Weld AI requires Desktop Experience edition. Reinstall Windows Server with Desktop Experience."
    } elseif ($installType -eq 'Server') {
        Ok "Windows Server with Desktop Experience detected (build $build) - supported"
    } else {
        Ok "Windows Server detected (build $build) - supported"
    }
} else { Fail "Windows 10 build $build is below the 21H2 minimum (19044). OS update required." }

# -- 2. WSL2 ------------------------------------------------------------------
Head "2. WSL2"

if ($isAdmin) {
    $wslF = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -ErrorAction SilentlyContinue
    $vmpF = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform'            -ErrorAction SilentlyContinue

    if ($wslF.State -eq 'Enabled') { Ok "WSL feature enabled" }
    else                            { Fail "WSL feature NOT enabled. Run: wsl --install" }

    if ($vmpF.State -eq 'Enabled') { Ok "Virtual Machine Platform enabled" }
    else                            { Fail "Virtual Machine Platform NOT enabled. Run: wsl --install" }
} else {
    Skip "WSL feature status"
    Skip "Virtual Machine Platform status"
}

# WSL network adapter is visible to standard users and is a reliable proxy
# for WSL2 being installed and active
$wslAdapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*WSL*' }
if ($wslAdapter) {
    Ok "WSL network adapter detected - WSL2 appears to be active"
} else {
    Info "WSL network adapter not found - WSL2 may not be installed or not currently running"
}

$wslStatus = & wsl --status 2>&1 | Out-String
if     ($wslStatus -match 'Default Version\s*:\s*2') { Ok "WSL default version is 2" }
elseif ($wslStatus -match 'Default Version\s*:\s*1') {
    Warn "WSL default version is 1. Run: wsl --set-default-version 2"
    if ($build -ge 17763 -and $build -lt 22000) {
        Warn "Windows Server detected: WSL2 setup requires Windows Update to be fully applied first."
        Warn "Run Windows Update then: wsl.exe --update  then: wsl --set-default-version 2"
        Info "See: weldai.uk/it-setup.html#windows-direct for full step-by-step instructions"
    }
} elseif ($wslStatus -match 'Usage:') {
    Fail "wsl.exe is too old to report status - Windows Update must be run to get a current wsl.exe"
    Info "See: weldai.uk/it-setup.html#windows-direct for step-by-step WSL2 setup instructions"
} else { Info "WSL version could not be determined from wsl --status" }

# -- 3. HYPER-V (Windows Server only) ----------------------------------------
Head "3. Hyper-V"

$isServer = ($build -ge 17763 -and $build -lt 22000)
if ($isServer) {
    if ($isAdmin) {
        $hvFeature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
        if ($hvFeature) {
            if ($hvFeature.InstallState -eq 'Installed') {
                Ok "Hyper-V role is installed - Ubuntu VM install type is available"
            } elseif ($hvFeature.InstallState -eq 'Available') {
                Info "Hyper-V role is available but not installed"
                Info "For the recommended Ubuntu VM install type, run: Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart"
                Info "See: weldai.uk/it-setup.html#ubuntu-vm"
            } else {
                Warn "Hyper-V status: $($hvFeature.InstallState)"
            }
        } else {
            Info "Could not determine Hyper-V status - check Server Manager"
        }

        # Check available RAM for VM headroom
        # $os.TotalVisibleMemorySize is in KB - convert to GB
        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        Info "Server RAM: $totalGB GB total"
        if ($totalGB -ge 16) { Ok "$totalGB GB RAM - sufficient for Ubuntu VM (needs 4 GB)" }
        elseif ($totalGB -ge 8) { Warn "$totalGB GB RAM - tight for Ubuntu VM. 16 GB recommended." }
        else { Fail "$totalGB GB RAM - insufficient for Ubuntu VM install type. Minimum 8 GB, recommended 16 GB." }
    } else {
        Skip "Hyper-V role status (requires Administrator)"
    }
} else {
    Info "Not a Windows Server build - Hyper-V check skipped"
}

# -- 4. CPU AND VIRTUALISATION ------------------------------------------------
Head "4. CPU and Virtualisation"

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs  = Get-CimInstance Win32_ComputerSystem
$archMap  = @{0='x86';1='MIPS';2='Alpha';3='PowerPC';5='ARM';6='ia64';9='x64/x86_64'}
$archName = if ($archMap.ContainsKey([int]$cpu.Architecture)) { $archMap[[int]$cpu.Architecture] } else { "$($cpu.Architecture)" }

Info "CPU   : $($cpu.Name)"
Info "Cores : $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) logical"
Info "Arch  : $archName"

if ($cpu.NumberOfCores -ge 4) { Ok "$($cpu.NumberOfCores) cores - meets minimum (4)" }
else                           { Warn "Only $($cpu.NumberOfCores) cores - 4 minimum recommended" }

if ($cpu.Architecture -eq 9)  { Ok "x86_64 architecture confirmed" }
else                           { Fail "Non-x64 architecture ($archName) - ARM not currently supported" }

# Virtualisation: hypervisor running is the definitive check.
# VirtualizationFirmwareEnabled is a raw BIOS flag that can read false even
# when the hypervisor is fully active (common on corporate/managed machines).
$hvPresent = $cs.HypervisorPresent
$virtFlag  = $cpu.VirtualizationFirmwareEnabled

if ($hvPresent) {
    Ok "Hypervisor is active - virtualisation confirmed working"
    if ($virtFlag -eq $false) {
        Info "Note: BIOS virtualisation flag reads as disabled but hypervisor is running - this is normal on some managed machines"
    }
} elseif ($virtFlag -eq $true) {
    Ok "Virtualisation enabled in BIOS firmware (hypervisor not yet active - expected before Docker is running)"
} elseif ($virtFlag -eq $false) {
    Fail "Virtualisation DISABLED in BIOS and hypervisor is not active. Enable Intel VT-x or AMD-V in server BIOS."
} else {
    Info "Virtualisation status could not be determined - check Task Manager > Performance > CPU > Virtualisation manually"
}

# -- 4. RAM -------------------------------------------------------------------
Head "5. RAM"

$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
Info "Total installed RAM: $ramGB GB"

if     ($ramGB -ge 16) { Ok "$ramGB GB - recommended (16 GB+)" }
elseif ($ramGB -ge 8)  { Ok "$ramGB GB - meets minimum (8 GB)" }
elseif ($ramGB -ge 4)  { Warn "$ramGB GB - below minimum. Upgrade to 8 GB+ before installation." }
else                   { Fail "$ramGB GB - insufficient. 8 GB minimum required." }

# -- 5. DISK SPACE ------------------------------------------------------------
Head "6. Disk Space"

$c      = Get-PSDrive C
$freeGB = [math]::Round($c.Free / 1GB, 1)
$usedGB = [math]::Round($c.Used / 1GB, 1)
Info "C: drive - Free: $freeGB GB  Used: $usedGB GB"

if     ($freeGB -ge 20) { Ok "$freeGB GB free - good headroom" }
elseif ($freeGB -ge 10) { Ok "$freeGB GB free - meets 10 GB minimum" }
else                    { Fail "$freeGB GB free - below 10 GB minimum. Free up space before installation." }

# -- 6. ALL DRIVES ------------------------------------------------------------
Head "7. All Available Drives"

$drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
foreach ($drive in $drives) {
    try {
        $label = if ($drive.Description) { $drive.Description } else { 'No label' }
        if ($drive.Root -match '^[A-Z]:\\') {
            $df = [math]::Round($drive.Free / 1GB, 1)
            $du = [math]::Round($drive.Used / 1GB, 1)
            Info "$($drive.Root)  Local   Free: $df GB  Used: $du GB  Label: $label"
        } else {
            Info "$($drive.Root)  Network/Other  Label: $label"
        }
    } catch { Info "$($drive.Root)  Not accessible" }
}

$netDrives = Get-CimInstance Win32_MappedLogicalDisk -ErrorAction SilentlyContinue
if ($netDrives) {
    Info "Mapped network drives:"
    $netDrives | ForEach-Object { Info "  $($_.DeviceID)  ->  $($_.ProviderName)" }
    Warn "Mapped network drives detected - Docker on Windows CANNOT mount network drives as document folders."
    Warn "Options: (1) copy documents to a local folder, (2) use Windows Server + Ubuntu VM install type"
    Info "See: weldai.uk/systemcheck.html for supported document locations"
} else {
    Info "No mapped network drives detected"
}
Info "NOTE: Please identify which drive/folder contains your company documents before the installation call."

# -- 7. WELDAI INSTALL FOLDER -------------------------------------------------
Head "8. Weld AI Installation Folder (C:\WeldAI)"

if (Test-Path 'C:\WeldAI') {
    $existing = Get-ChildItem 'C:\WeldAI' -ErrorAction SilentlyContinue
    Warn "C:\WeldAI already exists - $($existing.Count) file(s)/folder(s) found. Previous installation may be present."
} else {
    Ok "C:\WeldAI does not exist yet - will be created during installation"
}

# -- 8. DOCKER DESKTOP --------------------------------------------------------
Head "9. Docker Desktop"

$dockerVer = & docker --version 2>&1
if ($dockerVer -match 'Docker version ([\d.]+)') {
    $dv = $Matches[1]
    Info "Docker version: $dv"
    if ([int]($dv -split '\.')[0] -ge 20) { Ok "Docker version $dv meets minimum (v20.0)" }
    else                                   { Fail "Docker version $dv is below minimum v20.0. Update Docker Desktop." }
} else {
    Fail "Docker not installed or not in PATH. Install from docker.com/products/docker-desktop"
}

# -- 9. DOCKER WINDOWS SERVICE ------------------------------------------------
Head "10. Docker Windows Service"

if ($isAdmin) {
    $svc = Get-Service 'com.docker.service' -ErrorAction SilentlyContinue
    if ($svc) {
        Info "Status       : $($svc.Status)"
        Info "Startup type : $($svc.StartType)"

        if ($svc.StartType -in @('Automatic','AutomaticDelayedStart')) { Ok "Docker service startup type is $($svc.StartType)" }
        else { Fail "Docker service startup type is '$($svc.StartType)'. Run: Set-Service -Name 'com.docker.service' -StartupType Automatic" }

        # Service stopped is only a problem if the Docker engine is also not responding
        if ($svc.Status -ne 'Running') {
            $engineTest = & docker info 2>&1 | Out-String
            if ($engineTest -match 'Server Version') {
                Info "Docker service shows Stopped but engine is responding - Docker Desktop manages the engine directly on this machine (normal)"
            } else {
                Warn "Docker service is not running. Start Docker Desktop or run: Start-Service 'com.docker.service'"
            }
        } else {
            Ok "Docker service is running"
        }
    } else {
        Warn "Service 'com.docker.service' not found - Docker Desktop may not be installed yet"
        $any = Get-Service | Where-Object { $_.Name -like '*docker*' -or $_.DisplayName -like '*docker*' }
        if ($any) { $any | ForEach-Object { Info "  Found: $($_.Name) [$($_.Status)] StartType: $($_.StartType)" } }
    }
} else {
    $svc = Get-Service 'com.docker.service' -ErrorAction SilentlyContinue
    if ($svc) {
        Info "Service found: $($svc.DisplayName) - Status: $($svc.Status)"
        if ($svc.Status -ne 'Running') {
            # Check if engine is actually responding before warning
            $engineTest = & docker info 2>&1 | Out-String
            if ($engineTest -match 'Server Version') {
                Info "Docker service shows Stopped but engine is responding - Docker Desktop manages the engine directly (normal)"
            } else {
                Warn "Docker service is not running. Start Docker Desktop before the installation call."
            }
        } else {
            Ok "Docker service is running"
        }
        Skip "Docker service startup type"
    } else {
        Warn "Service 'com.docker.service' not found - Docker Desktop may not be installed yet"
    }
}

# -- 10. DOCKER ENGINE AND PULL TEST ------------------------------------------
Head "11. Docker Engine and Image Pull Test"

$dockerInfo = & docker info 2>&1 | Out-String
if ($dockerInfo -match 'Server Version') {
    Ok "Docker engine is running and responsive"
    if ($dockerInfo -match 'Server Version: ([\S]+)') { Info "Engine version: $($Matches[1])" }

    Info "Testing Docker Hub pull (may take 10-30 seconds)..."
    $pull = & docker pull hello-world 2>&1 | Out-String
    if ($pull -match 'Pull complete|Already exists|Status: Downloaded|Status: Image is up to date') {
        Ok "Docker Hub pull succeeded - internet access confirmed"
    } else {
        Fail "Docker Hub pull failed. IT may need to whitelist hub.docker.com and registry-1.docker.io"
        Info "Output: $($pull.Trim() -replace '\r?\n',' | ')"
    }
} else {
    Warn "Docker engine not responding - Docker Desktop may not be running. Start it and re-run for a full report."
}

# -- 11. PORT CONFLICTS -------------------------------------------------------
Head "12. Port Conflicts (80, 443)"

# Ports 80/443 used by Weld AI - only flag if something else is using them
$weldaiRunning = $dockerInfo -match 'Server Version'

foreach ($port in @(80, 443)) {
    $inUse = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($inUse) {
        if ($weldaiRunning) {
            Info "Port $port in use - likely Weld AI or its reverse proxy (nginx)"
        } else {
            Warn "Port $port in use - another service (e.g. IIS) may conflict with Weld AI"
        }
    } else {
        Ok "Port $port is free"
    }
}

# -- 12. FIREWALL RULES -------------------------------------------------------
Head "13. Windows Firewall - Inbound Rules"

if ($isAdmin) {
    foreach ($port in @(80, 443)) {
        $rules = Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue |
                 Where-Object { $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
                                Where-Object { $_.LocalPort -eq $port -and $_.Protocol -eq 'TCP' } }
        if ($rules) { Ok  "Inbound TCP $port - rule found: '$($rules[0].DisplayName)'" }
        else        { Warn "No inbound TCP $port firewall rule found - may need adding if staff access Weld AI from other PCs" }
    }
} else {
    Skip "Firewall rule check for port 80"
    Skip "Firewall rule check for port 443"
}

# -- 13. NETWORK CONFIGURATION ------------------------------------------------
Head "14. Network Configuration"

# Filter out virtual/internal adapters - only show physical and VPN adapters
$skipPatterns = @('Loopback','vEthernet','Default Switch','WSL','Bluetooth','Teredo','ISATAP','6to4')

Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $ip = $_.IPAddress
        $iface = $_.InterfaceAlias
        $ip -notlike '127.*' -and
        $ip -notlike '169.*' -and
        -not ($skipPatterns | Where-Object { $iface -like "*$_*" })
    } |
    ForEach-Object {
        Info "Interface: $($_.InterfaceAlias)   IP: $($_.IPAddress)   Origin: $($_.PrefixOrigin)"
        if     ($_.PrefixOrigin -eq 'Manual') { Ok  "Static IP on $($_.InterfaceAlias)" }
        elseif ($_.PrefixOrigin -eq 'Dhcp')   { Warn "DHCP address on '$($_.InterfaceAlias)' ($($_.IPAddress)) - request a static IP or DHCP reservation from IT to prevent address changing after reboot" }
    }

# -- 14. OUTBOUND CONNECTIVITY ------------------------------------------------
Head "15. Outbound Internet Connectivity"

$targets = @(
    @{ Host='api.anthropic.com';                          Port=443; Label='Anthropic Claude API' },
    @{ Host='hub.docker.com';                             Port=443; Label='Docker Hub' },
    @{ Host='registry-1.docker.io';                       Port=443; Label='Docker Registry' },
    @{ Host='wslstorestorage.blob.core.windows.net';      Port=443; Label='WSL Kernel Update (Windows Server)' },
    @{ Host='windowsupdate.microsoft.com';                Port=443; Label='Windows Update' }
)

foreach ($t in $targets) {
    $result = Test-NetConnection -ComputerName $t.Host -Port $t.Port -WarningAction SilentlyContinue -InformationLevel Quiet
    if ($result) { Ok  "$($t.Label) ($($t.Host):$($t.Port)) - reachable" }
    else         { Fail "$($t.Label) ($($t.Host):$($t.Port)) - UNREACHABLE. Check outbound firewall/proxy." }
}

# -- SUMMARY ------------------------------------------------------------------
Head "SUMMARY"

$passCount = ($lines | Where-Object { $_ -match '^\s*\[PASS\]' }).Count
$failCount = ($lines | Where-Object { $_ -match '^\s*\[FAIL\]' }).Count
$warnCount = ($lines | Where-Object { $_ -match '^\s*\[WARN\]' }).Count
$skipCount = ($lines | Where-Object { $_ -match '^\s*\[SKIP\]' }).Count

Add "PASS : $passCount"
Add "WARN : $warnCount   (review before installation call)"
Add "FAIL : $failCount   (must be resolved before installation)"
if ($skipCount -gt 0) {
    Add "SKIP : $skipCount   (re-run as Administrator for complete results)"
}
Add ""

if     ($failCount -eq 0 -and $warnCount -eq 0 -and $skipCount -eq 0) { Add "All checks passed. Server appears ready for Weld AI installation." }
elseif ($failCount -eq 0 -and $skipCount -gt 0)                        { Add "No failures found. $skipCount check(s) skipped - re-run as Administrator for a complete report." }
elseif ($failCount -eq 0)                                              { Add "No failures. Please review warnings above before the installation call." }
else                                                                   { Add "ACTION REQUIRED: $failCount item(s) must be resolved. See [FAIL] items above." }

# Install type recommendation
Add ""
Add "--- RECOMMENDED INSTALL TYPE ---"
Add ""
$isServer = ($build -ge 17763 -and $build -lt 22000)
$isWin11  = ($build -ge 22000)
$isWin10  = ($build -ge 19044 -and $build -lt 22000)

if ($isServer) {
    $hvInstalled = $false
    if ($isAdmin) {
        $hvF = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
        $hvInstalled = ($hvF -and $hvF.InstallState -eq 'Installed')
    }
    if ($hvInstalled) {
        Add "  Windows Server with Hyper-V detected."
        Add "  RECOMMENDED: Windows Server + Ubuntu VM install type."
        Add "  Your IT team creates a Ubuntu 22.04 VM via Hyper-V, then we install Weld AI inside it."
        Add "  This supports network shares and avoids WSL2 complexity."
        Add "  See: weldai.uk/it-setup.html#ubuntu-vm"
    } else {
        Add "  Windows Server without Hyper-V (or could not confirm)."
        Add "  Options:"
        Add "    (1) Enable Hyper-V and use Ubuntu VM install type (recommended)"
        Add "    (2) Windows Server Direct install (requires manual WSL2 setup)"
        Add "  See: weldai.uk/it-setup.html"
    }
} elseif ($isWin10 -or $isWin11) {
    Add "  Windows 10/11 PC detected."
    Add "  RECOMMENDED: Standard Windows PC install type."
    Add "  We handle Docker and WSL2 setup during the installation call."
    Add "  See: weldai.uk/systemcheck.html"
} else {
    Add "  Could not determine recommended install type. Contact hello@weldai.uk for advice."
}

Sep
Add "Weld AI - weldai.uk - hello@weldai.uk"

# -- WRITE AND ZIP ------------------------------------------------------------
$lines | Out-File -FilePath $reportPath -Encoding UTF8
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path $reportPath -DestinationPath $zipPath -Force

# -- CONSOLE SUMMARY ----------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Weld AI Diagnostics Complete"              -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  PASS : $passCount"                         -ForegroundColor Green
if ($warnCount -gt 0) { Write-Host "  WARN : $warnCount" -ForegroundColor Yellow }
if ($failCount -gt 0) { Write-Host "  FAIL : $failCount" -ForegroundColor Red }
if ($skipCount -gt 0) { Write-Host "  SKIP : $skipCount  (re-run as Administrator for full results)" -ForegroundColor DarkGray }
Write-Host ""
Write-Host "  Report saved to your Desktop:"            -ForegroundColor White
Write-Host "  weldai-diagnostics.zip"                   -ForegroundColor White
Write-Host ""
Write-Host "  Please email the zip to:"                 -ForegroundColor White
Write-Host "  hello@weldai.uk"                          -ForegroundColor White
Write-Host "  Subject: Diagnostics - [your company]"   -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Start-Process explorer.exe -ArgumentList "/select,`"$zipPath`""

Read-Host "Press Enter to close"