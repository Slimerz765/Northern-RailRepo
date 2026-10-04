# ============================================================
# Ubuntu 26.04.1 Desktop - VirtualBox Unattended Installation
# ============================================================

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

# -----------------------------
# VM SETTINGS
# -----------------------------

$VM = "Ubuntu-VM"

$ISO = "C:\Users\paul\Downloads\ubuntu-26.04.1-desktop-amd64.iso"

$VMFolder = "C:\VMs\$VM"
$VDI = "$VMFolder\$VM.vdi"

$Username = "ubuntuvirtualbox"
$Password = "pass"

$Hostname = "ubuntu-vm.local"

$RAM = 8096
$CPUs = 4
$DiskSizeMB = 51200

# -----------------------------
# NETWORK SETTINGS
# -----------------------------

$HostOnlyAdapter = "VirtualBox Host-Only Ethernet Adapter"

$NetworkIP = "192.168.56.1"
$NetworkMask = "255.255.255.0"

# -----------------------------
# CHECKS
# -----------------------------

if (-not (Test-Path $VBoxManage)) {
    throw "VBoxManage.exe not found: $VBoxManage"
}

if (-not (Test-Path $ISO)) {
    throw "Ubuntu ISO not found: $ISO"
}

# -----------------------------
# CREATE VM DIRECTORY
# -----------------------------

if (-not (Test-Path $VMFolder)) {
    New-Item -ItemType Directory -Path $VMFolder -Force | Out-Null
}

# -----------------------------
# CONFIGURE HOST-ONLY NETWORK
# -----------------------------

Write-Host "Configuring VirtualBox host-only network..." -ForegroundColor Cyan

$HostOnlyInterfaces = & $VBoxManage list hostonlyifs 2>$null

if ($HostOnlyInterfaces -notmatch [regex]::Escape($HostOnlyAdapter)) {

    Write-Host "Host-only adapter not found. Creating it..." -ForegroundColor Yellow

    & $VBoxManage hostonlyif create 2>&1 | Out-Host

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create VirtualBox host-only adapter."
    }

    Start-Sleep -Seconds 2
}

# Configure host-only adapter IP

& $VBoxManage hostonlyif ipconfig $HostOnlyAdapter `
    --ip $NetworkIP `
    --netmask $NetworkMask

if ($LASTEXITCODE -ne 0) {
    throw "Failed to configure host-only adapter."
}

Write-Host "Host-only network: $NetworkIP/$NetworkMask" -ForegroundColor Green

# -----------------------------
# CREATE VM
# -----------------------------

Write-Host "Creating VM: $VM" -ForegroundColor Cyan

& $VBoxManage createvm `
    --name $VM `
    --ostype Ubuntu_64 `
    --basefolder "C:\VMs" `
    --register

if ($LASTEXITCODE -ne 0) {
    throw "Failed to create VM."
}

# -----------------------------
# VM HARDWARE
# -----------------------------

Write-Host "Configuring VM hardware..." -ForegroundColor Cyan

& $VBoxManage modifyvm $VM `
    --memory $RAM `
    --cpus $CPUs `
    --vram 128 `
    --boot1 dvd `
    --boot2 disk `
    --boot3 none `
    --boot4 none `
    --graphicscontroller VMSVGA `
    --firmware efi `
    --nic1 hostonly `
    --hostonlyadapter1 $HostOnlyAdapter

if ($LASTEXITCODE -ne 0) {
    throw "Failed to configure VM hardware."
}

# -----------------------------
# CREATE VIRTUAL DISK
# -----------------------------

Write-Host "Creating $DiskSizeMB MB virtual disk..." -ForegroundColor Cyan

& $VBoxManage createhd `
    --filename $VDI `
    --size $DiskSizeMB `
    --format VDI

if ($LASTEXITCODE -ne 0) {
    throw "Failed to create virtual disk."
}

# -----------------------------
# SATA CONTROLLER
# -----------------------------

& $VBoxManage storagectl $VM `
    --name "SATA Controller" `
    --add sata `
    --controller IntelAhci

if ($LASTEXITCODE -ne 0) {
    throw "Failed to create SATA controller."
}

# -----------------------------
# ATTACH VIRTUAL DISK
# -----------------------------

& $VBoxManage storageattach $VM `
    --storagectl "SATA Controller" `
    --port 0 `
    --device 0 `
    --type hdd `
    --medium $VDI

if ($LASTEXITCODE -ne 0) {
    throw "Failed to attach virtual disk."
}

# -----------------------------
# UNATTENDED INSTALLATION
# -----------------------------

Write-Host ""
Write-Host "Starting unattended Ubuntu installation..." -ForegroundColor Green
Write-Host ""
Write-Host "Username : $Username"
Write-Host "Hostname : $Hostname"
Write-Host "RAM      : $RAM MB"
Write-Host "CPUs     : $CPUs"
Write-Host "Disk     : $DiskSizeMB MB"
Write-Host "Network  : $NetworkIP/$NetworkMask"
Write-Host ""

& $VBoxManage unattended install $VM `
    --iso="$ISO" `
    --user="$Username" `
    --user-password="$Password" `
    --full-user-name="$Username" `
    --hostname="$Hostname" `
    --locale="en_GB" `
    --country="GB" `
    --time-zone="Europe/London" `
    --install-additions `
    --start-vm="gui"

if ($LASTEXITCODE -ne 0) {
    throw "Unattended installation failed."
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " Ubuntu installation started successfully!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "VM Name : $VM"
Write-Host "User    : $Username"
Write-Host "Network : $NetworkIP/$NetworkMask"
Write-Host ""
Write-Host "The VM is installing Ubuntu in the background."
Write-Host "Installation time will depend on your PC."
Write-Host ""
