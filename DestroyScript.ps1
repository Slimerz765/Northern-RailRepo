$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$VMBasePath = "C:\VMs"

$VMs = & $VBoxManage list vms

foreach ($Line in $VMs) {
    if ($Line -match '^"(.+)"\s+\{[0-9a-f-]+\}$') {

        $VMName = $Matches[1]
        $VMFolder = Join-Path $VMBasePath $VMName

        Write-Host "Deleting VM: $VMName" -ForegroundColor Yellow

        & $VBoxManage unregistervm $VMName --delete

        if ($LASTEXITCODE -eq 0) {

            Write-Host "Deleted from VirtualBox: $VMName" -ForegroundColor Green

            # Remove any leftover deployment files
            if (Test-Path $VMFolder) {
                Write-Host "Removing leftover files: $VMFolder" -ForegroundColor Yellow

                Remove-Item $VMFolder -Recurse -Force

                if (-not (Test-Path $VMFolder)) {
                    Write-Host "Removed: $VMFolder" -ForegroundColor Green
                }
                else {
                    Write-Host "Warning: Could not completely remove $VMFolder" -ForegroundColor Red
                }
            }
        }
        else {
            Write-Host "Failed to delete: $VMName" -ForegroundColor Red
        }
    }
}