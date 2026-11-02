
# ============================================================
# Ubuntu VM - Automatic Multi-VM Deployment
# VirtualBox 7.2 / Windows / Ubuntu Server
#
# Automatic naming:
#   Ubuntu-VM1, Ubuntu-VM2, Ubuntu-VM3...
#
# Static IP allocation:
#   Ubuntu-VM1 = 192.168.56.10
#   Ubuntu-VM2 = 192.168.56.11
#   Ubuntu-VM3 = 192.168.56.12
#
# ============================================================

$ErrorActionPreference = "Stop"

# -------------------- SETTINGS --------------------

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$OVA = "C:\VMImages\Ubuntu-Server-Base.ova"
$VMPrefix = "Ubuntu-VM"
$VMBaseFolder = "C:\VMs"

$HostIP = "192.168.56.1"
$DHCPServerIP = "192.168.56.2"
$Netmask = "255.255.255.0"

$DHCPStartIP = "192.168.56.100"
$DHCPEndIP = "192.168.56.200"

# Static IP allocation.
$IPPrefix = "192.168.56."
$FirstVMNumber = 1
$LastVMNumber = 90
$FirstVMIP = 10

$SSHPort = 22
$TimeoutMinutes = 10

# -------------------- VBOXMANAGE HELPER --------------------

function Invoke-VBox {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $OldPreference = $ErrorActionPreference

    try {
        # Native VBoxManage commands can emit progress/errors on stderr.
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

    $Generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $Generator.GetBytes($Bytes)
    }
    finally {
        $Generator.Dispose()
    }

    # VirtualBox-compatible MAC:
    # 08:00:27 followed by three random bytes.

    $RandomPart = ($Bytes | ForEach-Object {
        $_.ToString("X2")
    }) -join ""

    return "080027$RandomPart"
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

New-Item -ItemType Directory -Path $VMBaseFolder -Force |
    Out-Null

# ============================================================
# AUTOMATIC VM NAME AND IP ALLOCATION
# ============================================================

Write-Host "`nFinding next available VM..." -ForegroundColor Cyan

$RegisteredVMs = Invoke-VBox @("list", "vms")

$ExistingNames = @()

foreach ($Line in $RegisteredVMs) {

    if ("$Line" -match '^"(.+)"\s+\{[0-9a-f-]+\}$') {
        $ExistingNames += $Matches[1]
    }
}

$VM = $null
$VMIP = $null
$VMNumber = $null
$VMFolder = $null

for ($Number = $FirstVMNumber; $Number -le $LastVMNumber; $Number++) {

    $CandidateVM = "$VMPrefix$Number"

    # VM1 gets .10, VM2 gets .11, etc.
    $CandidateIPNumber = $FirstVMIP + $Number - $FirstVMNumber

    $CandidateIP = "$IPPrefix$CandidateIPNumber"

    $CandidateFolder = Join-Path $VMBaseFolder $CandidateVM

    $NameExists = $ExistingNames -contains $CandidateVM

    $FolderExists = Test-Path -LiteralPath $CandidateFolder

    if (-not $NameExists -and -not $FolderExists) {

        $VM = $CandidateVM
        $VMIP = $CandidateIP
        $VMNumber = $Number
        $VMFolder = $CandidateFolder

        break
    }
}

if (-not $VM) {
    throw "No available VM numbers remain. Maximum configured VM number: $LastVMNumber"
}

Write-Host "Selected VM: $VM" -ForegroundColor Green
Write-Host "Assigned static IP: $VMIP" -ForegroundColor Green

# ============================================================
# GENERATE UNIQUE MAC ADDRESSES
# ============================================================

Write-Host "`nGenerating unique MAC addresses..." -ForegroundColor Cyan

$NatMAC = New-UniqueMAC
$HostOnlyMAC = New-UniqueMAC

Write-Host "NAT MAC: $NatMAC"
Write-Host "Host-only MAC: $HostOnlyMAC"

# ============================================================
# DISCOVER OR CREATE HOST-ONLY ADAPTER
# ============================================================

Write-Host "`nDiscovering host-only network..." -ForegroundColor Cyan

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

# Prefer an adapter already configured with the required host IP.
$Adapter = $Adapters |
    Where-Object {
        $_.IPAddress -eq $HostIP
    } |
    Select-Object -First 1

# Otherwise reuse an existing adapter.
if (-not $Adapter -and $Adapters.Count -gt 0) {
    $Adapter = $Adapters[0]
}

# Create an adapter if none exists.
if (-not $Adapter) {

    Write-Host "No host-only adapter found. Creating one..." `
        -ForegroundColor Yellow

    $OldPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"
        & $VBoxManage hostonlyif create
        $CreateExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $OldPreference
    }

    if ($CreateExitCode -ne 0) {
        throw "Failed to create host-only adapter. Exit code: $CreateExitCode"
    }

    # Rediscover adapters after creation.
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

    if ($Adapters.Count -eq 0) {
        throw "No host-only adapter found after creation."
    }

    $Adapter = $Adapters[-1]
}

$HostOnlyAdapter = $Adapter.Name

Write-Host "Selected adapter: $HostOnlyAdapter" -ForegroundColor Green

# Configure the selected adapter.
Invoke-VBox @(
    "hostonlyif", "ipconfig", $HostOnlyAdapter,
    "--ip", $HostIP,
    "--netmask", $Netmask
) | Out-Null

# Verify the corresponding Windows adapter.
$WindowsAdapter = Get-NetAdapter -IncludeHidden |
    Where-Object {
        $_.Name -eq $HostOnlyAdapter -or
        $_.InterfaceDescription -eq $HostOnlyAdapter
    } |
    Select-Object -First 1

if (-not $WindowsAdapter) {
    throw "Windows network adapter not found for '$HostOnlyAdapter'."
}

$AddressFound = Get-NetIPAddress `
    -InterfaceIndex $WindowsAdapter.ifIndex `
    -AddressFamily IPv4 `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -eq $HostIP
    }

if (-not $AddressFound) {
    throw "Host IP $HostIP not found on Windows adapter '$($WindowsAdapter.Name)'."
}

Write-Host "Host-only network ready: $HostIP/24" -ForegroundColor Green

# ============================================================
# CONFIGURE OR CREATE HOST-ONLY DHCP SERVER
# ============================================================

Write-Host "`nConfiguring host-only DHCP server..." -ForegroundColor Cyan

$DHCPOutput = Invoke-VBox @("list", "dhcpservers")
$DHCPText = $DHCPOutput -join "`n"

$NetworkName = "HostInterfaceNetworking-$HostOnlyAdapter"

$DHCPExists = $false

$Blocks = [regex]::Split(
    $DHCPText,
    '(?m)(?=^\s*NetworkName:)'
)

foreach ($Block in $Blocks) {

    if ($Block -match [regex]::Escape($NetworkName)) {
        $DHCPExists = $true
        break
    }
}

$DHCPArgs = @(
    "--interface=$HostOnlyAdapter",
    "--server-ip=$DHCPServerIP",
    "--netmask=$Netmask",
    "--lower-ip=$DHCPStartIP",
    "--upper-ip=$DHCPEndIP",
    "--enable"
)

if ($DHCPExists) {

    Write-Host "Existing DHCP server found. Updating..." `
        -ForegroundColor Yellow

    $ModifyArgs = @("dhcpserver", "modify") + $DHCPArgs

    Invoke-VBox -Arguments $ModifyArgs | Out-Null
}
else {

    Write-Host "No DHCP server found. Creating one..." `
        -ForegroundColor Yellow

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

# Verify registration before configuring hardware.
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
    throw "Import finished, but '$VM' is not registered."
}

Write-Host "VM imported successfully." -ForegroundColor Green

# ============================================================
# CONFIGURE VM NETWORK ADAPTERS
# ============================================================

Write-Host "`nConfiguring VM network adapters..." -ForegroundColor Cyan

# Adapter 1: NAT for outbound Internet access.
# Adapter 2: host-only for the private host/guest network.

Invoke-VBox @(
    "modifyvm", $VM,
    "--nic1", "nat",
    "--macaddress1", $NatMAC,
    "--nic2", "hostonly",
    "--hostonlyadapter2", $HostOnlyAdapter,
    "--macaddress2", $HostOnlyMAC
) | Out-Null

# ============================================================
# VERIFY VM STATE
# ============================================================

$VMInfo = Invoke-VBox @("showvminfo", $VM, "--machinereadable")

if ($VMInfo -match '(?m)^VMState="saved"$') {
    throw "VM is in a saved state. Discard the saved state manually and retry."
}

# ============================================================
# START VM
# ============================================================

Write-Host "`nStarting $VM..." -ForegroundColor Cyan

Invoke-VBox @("startvm", $VM, "--type", "gui") | Out-Null

# ============================================================
# WAIT FOR SSH
# ============================================================

Write-Host "`nWaiting for SSH at ${VMIP}:$SSHPort ..." `
    -ForegroundColor Cyan

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
2. The guest host-only interface is configured.
3. Ubuntu has static IP $VMIP.
4. openssh-server is installed and running.

The VM has been left running for inspection.
"@
}

# ============================================================
# FINISHED
# ============================================================

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " VM DEPLOYED - SSH PORT REACHABLE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

Write-Host "VM: $VM"
Write-Host "VM number: $VMNumber"
Write-Host "VM folder: $VMFolder"
Write-Host "Host-only adapter: $HostOnlyAdapter"
Write-Host "Host IP: $HostIP"
Write-Host "Guest static IP: $VMIP"
Write-Host "NAT MAC: $NatMAC"
Write-Host "Host-only MAC: $HostOnlyMAC"
Write-Host "Internet: NAT"
Write-Host ""
Write-Host "Connect using:"
Write-Host "ssh ubuntuvirtualbox@$VMIP"
Write-Host ""
Write-Host "Note: TCP port reachability does not verify SSH authentication."
