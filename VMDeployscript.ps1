
# ============================================================
# Ubuntu VM - Automatic Multi-VM Deployment
# VirtualBox 7.2 / Windows / Ubuntu Server
#
# Automatically creates:
#   Ubuntu-VM1 -> 192.168.56.10
#   Ubuntu-VM2 -> 192.168.56.11
#   Ubuntu-VM3 -> 192.168.56.12
#   etc.
#
# Requirements:
#   - VirtualBox 7.2
#   - Ubuntu OVA with cloud-init installed and enabled
#   - WSL with cloud-image-utils installed
# ============================================================

$ErrorActionPreference = "Stop"

# -------------------- SETTINGS --------------------

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$OVA = "C:\VMImages\Ubuntu-Server-Base.ova"
$VMBaseFolder = "C:\VMs"

$VMPrefix = "Ubuntu-VM"

$HostIP = "192.168.56.1"
$DHCPServerIP = "192.168.56.2"
$Netmask = "255.255.255.0"

# DHCP range is deliberately separate from static VM addresses.
$DHCPStartIP = "192.168.56.100"
$DHCPEndIP = "192.168.56.200"

# Static VM IP allocation.
$IPPrefix = "192.168.56."
$FirstVMIP = 10
$LastVMIP = 99

$SSHPort = 22
$SSHUser = "ubuntuvirtualbox"
$TimeoutMinutes = 10

# -------------------- VBOXMANAGE HELPER --------------------

function Invoke-VBox {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $OldPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& $VBoxManage @Arguments 2>&1)
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $OldPreference
    }

    if ($Output) {
        $Output | ForEach-Object {
            Write-Host "$_"
        }
    }

    if ($ExitCode -ne 0) {
        throw "VBoxManage failed (exit code $ExitCode): $($Arguments -join ' ')"
    }

    return $Output
}

# -------------------- UNIQUE MAC GENERATOR --------------------

function New-UniqueMAC {

    $Bytes = New-Object byte[] 3

    [System.Security.Cryptography.RandomNumberGenerator]::Fill($Bytes)

    # VirtualBox OUI followed by random bytes.
    $RandomPart = ($Bytes | ForEach-Object {
        $_.ToString("X2")
    }) -join ""

    return "080027$RandomPart"
}

# -------------------- DISCOVER HOST-ONLY ADAPTERS --------------------

function Get-HostOnlyAdapters {

    $Output = Invoke-VBox @("list", "hostonlyifs")

    $Adapters = @()
    $Current = $null

    foreach ($Line in $Output) {

        if ("$Line" -match '^\s*Name:\s*(.+?)\s*$') {

            if ($null -ne $Current) {
                $Adapters += [pscustomobject]$Current
            }

            $Current = @{
                Name = $Matches[1]
                IPAddress = ""
            }
        }
        elseif ("$Line" -match '^\s*IPAddress:\s*(.+?)\s*$') {

            if ($null -ne $Current) {
                $Current.IPAddress = $Matches[1]
            }
        }
    }

    if ($null -ne $Current) {
        $Adapters += [pscustomobject]$Current
    }

    return $Adapters
}

# -------------------- ADMINISTRATOR / PREREQUISITES --------------------

Write-Host "`nChecking prerequisites..." -ForegroundColor Cyan

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)

if (-not $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw "Run PowerShell as Administrator."
}

if (-not (Test-Path $VBoxManage -PathType Leaf)) {
    throw "VBoxManage.exe not found: $VBoxManage"
}

if (-not (Test-Path $OVA -PathType Leaf)) {
    throw "OVA image not found: $OVA"
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "Windows Subsystem for Linux (WSL) is required to generate cloud-init ISO files."
}

New-Item -ItemType Directory -Path $VMBaseFolder -Force |
    Out-Null

# Check cloud-localds inside WSL.
$CloudLocalDS = & wsl.exe -- bash -lc "command -v cloud-localds" 2>$null

if ($LASTEXITCODE -ne 0 -or -not $CloudLocalDS) {
    throw @"
cloud-localds is missing from WSL.

Install it inside your WSL Ubuntu distribution using:

sudo apt update
sudo apt install -y cloud-image-utils

Then run this deployment script again.
"@
}

Write-Host "Prerequisites passed." -ForegroundColor Green

# ============================================================
# AUTOMATIC VM NAME AND STATIC IP ALLOCATION
# ============================================================

Write-Host "`nFinding next available VM number..." -ForegroundColor Cyan

$RegisteredVMs = Invoke-VBox @("list", "vms")

$VMNumber = $FirstVMIP
$VM = $null
$VMIP = $null
$VMFolder = $null

while ($VMNumber -le $LastVMIP) {

    $CandidateVM = "$VMPrefix$($VMNumber - $FirstVMIP + 1)"
    $CandidateIP = "$IPPrefix$VMNumber"
    $CandidateFolder = Join-Path $VMBaseFolder $CandidateVM

    $NameExists = $false

    foreach ($Line in $RegisteredVMs) {

        if ("$Line" -match '^"(.+)"\s+\{[0-9a-f-]+\}$') {

            if ($Matches[1] -eq $CandidateVM) {
                $NameExists = $true
                break
            }
        }
    }

    $FolderExists = Test-Path -LiteralPath $CandidateFolder

    if (-not $NameExists -and -not $FolderExists) {

        $VM = $CandidateVM
        $VMIP = $CandidateIP
        $VMFolder = $CandidateFolder

        break
    }

    $VMNumber++
}

if (-not $VM) {
    throw "No available VM names or static IP addresses remain in the configured range."
}

Write-Host "Selected VM: $VM" -ForegroundColor Green
Write-Host "Static IP: $VMIP" -ForegroundColor Green

# ============================================================
# GENERATE UNIQUE MAC ADDRESSES
# ============================================================

$NatMAC = New-UniqueMAC
$HostOnlyMAC = New-UniqueMAC

Write-Host "`nGenerated network addresses:" -ForegroundColor Cyan
Write-Host "NAT MAC: $NatMAC"
Write-Host "Host-only MAC: $HostOnlyMAC"

# ============================================================
# DISCOVER OR CREATE HOST-ONLY ADAPTER
# ============================================================

Write-Host "`nDiscovering host-only network..." -ForegroundColor Cyan

$Adapters = @(Get-HostOnlyAdapters)

$Adapter = $Adapters |
    Where-Object {
        $_.IPAddress -eq $HostIP
    } |
    Select-Object -First 1

if (-not $Adapter -and $Adapters.Count -gt 0) {
    $Adapter = $Adapters[0]
}

if (-not $Adapter) {

    Write-Host "Creating host-only adapter..." -ForegroundColor Yellow

    Invoke-VBox @("hostonlyif", "create") | Out-Null

    $Adapters = @(Get-HostOnlyAdapters)

    if ($Adapters.Count -eq 0) {
        throw "Failed to discover the newly created host-only adapter."
    }

    $Adapter = $Adapters[-1]
}

$HostOnlyAdapter = $Adapter.Name

Write-Host "Selected adapter: $HostOnlyAdapter" -ForegroundColor Green

# Configure host-only adapter.
Invoke-VBox @(
    "hostonlyif", "ipconfig", $HostOnlyAdapter,
    "--ip", $HostIP,
    "--netmask", $Netmask
) | Out-Null

# Verify Windows adapter.
$WindowsAdapter = Get-NetAdapter -IncludeHidden |
    Where-Object {
        $_.Name -eq $HostOnlyAdapter -or
        $_.InterfaceDescription -eq $HostOnlyAdapter
    } |
    Select-Object -First 1

if (-not $WindowsAdapter) {
    throw "Windows network adapter not found: $HostOnlyAdapter"
}

$AddressFound = Get-NetIPAddress `
    -InterfaceIndex $WindowsAdapter.ifIndex `
    -AddressFamily IPv4 `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -eq $HostIP
    }

if (-not $AddressFound) {
    throw "Host IP $HostIP was not found on the Windows adapter."
}

Write-Host "Host-only network ready." -ForegroundColor Green

# ============================================================
# CONFIGURE HOST-ONLY DHCP SERVER
# ============================================================

Write-Host "`nConfiguring host-only DHCP server..." -ForegroundColor Cyan

$DHCPOutput = Invoke-VBox @("list", "dhcpservers")
$DHCPText = $DHCPOutput -join "`n"

$NetworkName = "HostInterfaceNetworking-$HostOnlyAdapter"

$DHCPExists = $DHCPText -match [regex]::Escape($NetworkName)

$DHCPArgs = @(
    "--interface=$HostOnlyAdapter",
    "--server-ip=$DHCPServerIP",
    "--netmask=$Netmask",
    "--lower-ip=$DHCPStartIP",
    "--upper-ip=$DHCPEndIP",
    "--enable"
)

if ($DHCPExists) {

    Write-Host "Updating existing DHCP server..." -ForegroundColor Yellow

    $ModifyArgs = @("dhcpserver", "modify") + $DHCPArgs

    Invoke-VBox -Arguments $ModifyArgs | Out-Null
}
else {

    Write-Host "Creating DHCP server..." -ForegroundColor Yellow

    $AddArgs = @("dhcpserver", "add") + $DHCPArgs

    Invoke-VBox -Arguments $AddArgs | Out-Null
}

Write-Host "DHCP server configured." -ForegroundColor Green

# ============================================================
# IMPORT BASE IMAGE
# ============================================================

Write-Host "`nImporting Ubuntu baseline image..." -ForegroundColor Cyan

$OldPreference = $ErrorActionPreference

try {

    $ErrorActionPreference = "Continue"

    & $VBoxManage import $OVA `
        --vsys 0 `
        --vmname $VM `
        --basefolder $VMBaseFolder

    $ImportExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $OldPreference
}

if ($ImportExitCode -ne 0) {
    throw "OVA import failed. Exit code: $ImportExitCode"
}

# Verify VM registration.
$RegisteredVMs = Invoke-VBox @("list", "vms")

$VMRegistered = $false

foreach ($Line in $RegisteredVMs) {

    if ("$Line" -match '^"(.+)"\s+\{[0-9a-f-]+\}$') {

        if ($Matches[1] -eq $VM) {
            $VMRegistered = $true
            break
        }
    }
}

if (-not $VMRegistered) {
    throw "Imported VM is not registered."
}

Write-Host "VM imported successfully." -ForegroundColor Green

# ============================================================
# CREATE CLOUD-INIT CONFIGURATION
# ============================================================

Write-Host "`nCreating VM-specific cloud-init configuration..." -ForegroundColor Cyan

$SeedFolder = Join-Path $env:TEMP "CloudInit-$VM"

New-Item -ItemType Directory -Path $SeedFolder -Force |
    Out-Null

$UserDataFile = Join-Path $SeedFolder "user-data"
$MetaDataFile = Join-Path $SeedFolder "meta-data"
$NetworkFile = Join-Path $SeedFolder "network-config"

$SeedISO = Join-Path $VMFolder "$VM-cloud-init.iso"

$NatMACFormatted = ($NatMAC -replace '(.{2})(?!$)', '$1:').ToLower()
$HostMACFormatted = ($HostOnlyMAC -replace '(.{2})(?!$)', '$1:').ToLower()

# Unique cloud-init instance ID for each deployment.
$InstanceID = [guid]::NewGuid().ToString()

$UserData = @"
#cloud-config
hostname: $VM
preserve_hostname: false
"@

$MetaData = @"
instance-id: $InstanceID
local-hostname: $VM
"@

# Adapter 1: NAT with DHCP for internet access.
# Adapter 2: genuinely static host-only IP.
$NetworkConfig = @"
version: 2
ethernets:
  nat:
    match:
      macaddress: '$NatMACFormatted'
    dhcp4: true
    dhcp6: false
  hostonly:
    match:
      macaddress: '$HostMACFormatted'
    dhcp4: false
    dhcp6: false
    addresses:
      - $VMIP/24
"@

Set-Content -LiteralPath $UserDataFile -Value $UserData -Encoding ASCII
Set-Content -LiteralPath $MetaDataFile -Value $MetaData -Encoding ASCII
Set-Content -LiteralPath $NetworkFile -Value $NetworkConfig -Encoding ASCII

# Convert Windows paths to WSL paths.
$WslUserData = (& wsl.exe wslpath -a $UserDataFile).Trim()
$WslMetaData = (& wsl.exe wslpath -a $MetaDataFile).Trim()
$WslNetwork = (& wsl.exe wslpath -a $NetworkFile).Trim()
$WslISO = (& wsl.exe wslpath -a $SeedISO).Trim()

if ($LASTEXITCODE -ne 0) {
    throw "Failed to convert cloud-init paths for WSL."
}

# Generate NoCloud seed ISO.
$OldPreference = $ErrorActionPreference

try {

    $ErrorActionPreference = "Continue"

    & wsl.exe -- cloud-localds `
        "--network-config=$WslNetwork" `
        $WslISO `
        $WslUserData `
        $WslMetaData

    $ISOExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $OldPreference
}

if ($ISOExitCode -ne 0 -or -not (Test-Path $SeedISO)) {
    throw "Failed to generate cloud-init ISO."
}

Write-Host "Cloud-init ISO generated." -ForegroundColor Green

# ============================================================
# CONFIGURE VM NETWORK ADAPTERS
# ============================================================

Write-Host "`nConfiguring VM network adapters..." -ForegroundColor Cyan

Invoke-VBox @(
    "modifyvm", $VM,
    "--nic1", "nat",
    "--macaddress1", $NatMAC,
    "--nic2", "hostonly",
    "--hostonlyadapter2", $HostOnlyAdapter,
    "--macaddress2", $HostOnlyMAC
) | Out-Null

# ============================================================
# ATTACH CLOUD-INIT ISO
# ============================================================

Write-Host "`nAttaching cloud-init configuration..." -ForegroundColor Cyan

Invoke-VBox @(
    "storagectl", $VM,
    "--name", "CloudInit",
    "--add", "ide"
) | Out-Null

Invoke-VBox @(
    "storageattach", $VM,
    "--storagectl", "CloudInit",
    "--port", "0",
    "--device", "0",
    "--type", "dvddrive",
    "--medium", $SeedISO
) | Out-Null

# Ensure the VM boots from its existing disk.
Invoke-VBox @(
    "modifyvm", $VM,
    "--boot1", "disk",
    "--boot2", "dvd"
) | Out-Null

# ============================================================
# CHECK VM STATE
# ============================================================

$VMInfo = Invoke-VBox @("showvminfo", $VM, "--machinereadable")

if ($VMInfo -match '(?m)^VMState="saved"$') {
    throw "VM is in a saved state. Manual inspection required."
}

# ============================================================
# START VM
# ============================================================

Write-Host "`nStarting $VM..." -ForegroundColor Cyan

Invoke-VBox @("startvm", $VM, "--type", "gui") | Out-Null

# ============================================================
# WAIT FOR SSH
# ============================================================

Write-Host "`nWaiting for SSH at ${VMIP}:$SSHPort ..." -ForegroundColor Cyan

$Deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$SSHReady = $false

while ((Get-Date) -lt $Deadline) {

    Start-Sleep -Seconds 5

    $VMInfo = & $VBoxManage showvminfo $VM --machinereadable 2>$null

    if ($LASTEXITCODE -eq 0 -and
        $VMInfo -match '(?m)^VMState="aborted"$') {

        throw "VM aborted. Inspect the VirtualBox console."
    }

    $SSHReady = Test-NetConnection `
        -ComputerName $VMIP `
        -Port $SSHPort `
        -InformationLevel Quiet `
        -WarningAction SilentlyContinue `
        -ErrorAction SilentlyContinue

    if ($SSHReady) {
        break
    }
}

if (-not $SSHReady) {

    throw @"
SSH did not become reachable within $TimeoutMinutes minutes.

VM: $VM
Expected static IP: $VMIP

Check:
1. Ubuntu booted successfully.
2. Cloud-init is installed and enabled in the OVA.
3. The NoCloud datasource was detected.
4. The host-only interface received $VMIP.
5. openssh-server is installed and running.

The VM has been left running for inspection.
"@
}

# ============================================================
# CLEAN UP TEMPORARY CONFIGURATION
# ============================================================

# The seed ISO is retained in the VM folder for troubleshooting.
# Temporary source files are no longer needed.

Remove-Item -LiteralPath $SeedFolder -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================
# FINISHED
# ============================================================

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " VM DEPLOYED - SSH PORT REACHABLE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

Write-Host "VM: $VM"
Write-Host "Host-only adapter: $HostOnlyAdapter"
Write-Host "Host IP: $HostIP"
Write-Host "Guest static IP: $VMIP"
Write-Host "NAT MAC: $NatMAC"
Write-Host "Host-only MAC: $HostOnlyMAC"
Write-Host "Internet: NAT"
Write-Host ""
Write-Host "Connect using:"
Write-Host "ssh ${SSHUser}@${VMIP}"
Write-Host ""
Write-Host "Note: TCP port reachability does not verify SSH authentication."
