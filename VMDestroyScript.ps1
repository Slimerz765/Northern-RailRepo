# ============================================================
# VirtualBox - Destroy VMs and Remove Leftover Files
# ============================================================

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$VMBasePath = "C:\VMs"

if (-not (Test-Path $VBoxManage)) {
    throw "VBoxManage.exe not found: $VBoxManage"
}

if (-not (Test-Path $VMBasePath)) {
    Write-Host "VM directory does not exist: $VMBasePath" -ForegroundColor Yellow
    exit
}

# ============================================================
# DELETE REGISTERED VMs
# ============================================================

$VMs = & $VBoxManage list vms

if ($LASTEXITCODE -ne 0) {
    throw "Failed to retrieve registered VirtualBox VMs."
}

foreach ($Line in $VMs) {
    if ($Line -match '^"(.+)"\s+\{[0-9a-f-]+\}$') {

        $VMName = $Matches[1]
        $VMFolder = Join-Path $VMBasePath $VMName

        Write-Host "Deleting VM: $VMName" -ForegroundColor Yellow

        & $VBoxManage unregistervm $VMName --delete

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Deleted from VirtualBox: $VMName" -ForegroundColor Green
        }
        else {
            Write-Host "Failed to delete: $VMName" -ForegroundColor Red
        }
    }
}

# ============================================================
# REMOVE ALL LEFTOVER VM DIRECTORIES
# ============================================================

Write-Host "`nChecking for leftover VM directories..." -ForegroundColor Cyan

Get-ChildItem -LiteralPath $VMBasePath -Directory -Force |
    ForEach-Object {

        $VMFolder = $_.FullName

        Write-Host "Removing leftover files: $VMFolder" -ForegroundColor Yellow

        try {
            Remove-Item -LiteralPath $VMFolder -Recurse -Force -ErrorAction Stop

            if (-not (Test-Path -LiteralPath $VMFolder)) {
                Write-Host "Removed: $VMFolder" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "Failed to remove: $VMFolder" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor DarkRed
        }
    }

# ============================================================
# REMOVE VIRTUALBOX HOST-ONLY ADAPTERS
# ============================================================

Write-Host "`nChecking host-only adapters..." -ForegroundColor Cyan

$Adapters = & $VBoxManage list hostonlyifs

if ($LASTEXITCODE -ne 0) {
    Write-Host "Could not list host-only adapters." -ForegroundColor Red
}
else {
    $AdapterNames = @(
        [regex]::Matches(
            ($Adapters -join "`n"),
            '(?m)^Name:\s*(.+?)\s*$'
        ) | ForEach-Object {
            $_.Groups[1].Value.Trim()
        }
    )

    foreach ($AdapterName in $AdapterNames) {
        Write-Host "Removing adapter: $AdapterName" -ForegroundColor Yellow

        & $VBoxManage hostonlyif remove $AdapterName

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Removed adapter: $AdapterName" -ForegroundColor Green
        }
        else {
            Write-Host "Failed to remove adapter: $AdapterName" -ForegroundColor Red
        }
    }
}

Write-Host "`nCleanup complete." -ForegroundColor Green