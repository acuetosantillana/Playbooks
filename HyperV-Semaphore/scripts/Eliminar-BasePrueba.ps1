param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string[]]$CsvVolumes,
    [Parameter(Mandatory)][string]$Library,
    [Parameter(Mandatory)][guid]$ExpectedVMId,
    [Parameter(Mandatory)][DateTimeOffset]$ExpectedLockCreated,
    [switch]$Apply
)
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
Import-Module Hyper-V
Import-Module FailoverClusters
$vmName='TPL-WS2025'
$ip='10.138.120.5'
$rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')
$allowedRoots=@($CsvVolumes | ForEach-Object { [IO.Path]::GetFullPath((Join-Path (Join-Path $_ 'SemaphoreVMs') $vmName)).TrimEnd('\') })
if ($rootPath -notin $allowedRoots) { throw 'Root fuera del despliegue de prueba autorizado.' }
$online=@(Get-ClusterSharedVolume | Where-Object State -eq 'Online' | ForEach-Object { $_.SharedVolumeInfo.FriendlyVolumeName.TrimEnd('\') })
if (-not ($online | Where-Object { $_ -in $CsvVolumes -and $rootPath.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase) })) { throw 'El despliegue no esta en un CSV autorizado Online.' }
# Rechazar enlaces tanto en los padres como en el arbol que se eliminaria.
foreach ($path in @($rootPath,(Split-Path -Parent $rootPath))) {
    if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'La ruta de despliegue contiene un enlace.' }
}
if (Get-ChildItem -LiteralPath $rootPath -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Hay enlaces dentro del despliegue.' }
$manifest=Get-Content -LiteralPath (Join-Path $rootPath 'deployment.json') -Raw | ConvertFrom-Json
if ($manifest.name -ne $vmName -or $manifest.system -ne 'Windows' -or [guid]$manifest.vm_id -ne $ExpectedVMId -or [IO.Path]::GetFullPath($manifest.root).TrimEnd('\') -ne $rootPath) { throw 'El manifiesto no coincide con la VM de prueba aprobada.' }
$libraryPath=[IO.Path]::GetFullPath($Library).TrimEnd('\')
if (-not ($online | Where-Object { $_ -in $CsvVolumes -and $libraryPath.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase) })) { throw 'Biblioteca fuera de un CSV autorizado Online.' }
if (Test-Path -LiteralPath (Join-Path $libraryPath 'ws2025-base-v1\metadata.json')) { throw 'Ya existe una plantilla publicada; no se admite esta limpieza de prueba.' }
$lockPath=[IO.Path]::GetFullPath((Join-Path (Join-Path $libraryPath '.locks') $ip))
$lockOwner=Get-Content -LiteralPath (Join-Path $lockPath 'owner.json') -Raw | ConvertFrom-Json
if ($lockOwner.vm -ne $vmName -or $lockOwner.ip -ne $ip -or [DateTimeOffset]$lockOwner.created -ne $ExpectedLockCreated) { throw 'La reserva corresponde a otro intento.' }
$group=Get-ClusterGroup -Name $vmName -ErrorAction Stop
$node=$group.OwnerNode.Name
$vm=Get-VM -ComputerName $node -Id $ExpectedVMId -ErrorAction Stop
if ($vm.Name -ne $vmName -or -not ([IO.Path]::GetFullPath($vm.ConfigurationLocation).TrimEnd('\')+'\').StartsWith($rootPath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'La VM o su configuracion no coincide con el despliegue.' }
if (Get-VMSnapshot -VM $vm -ErrorAction Stop) { throw 'La VM tiene checkpoints; no se admite limpieza automatica.' }
$disks=@(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)
$expectedDisk=Join-Path $rootPath ('Virtual Hard Disks\'+$vmName+'.vhdx')
if ($disks.Count -ne 1 -or [IO.Path]::GetFullPath($disks[0].Path) -ne $expectedDisk) { throw 'El disco conectado no es el unico disco de prueba autorizado.' }
# Comprobar tambien referencias de otras VM antes de borrar un VHDX o ISO.
foreach ($clusterNode in Get-ClusterNode) {
    foreach ($other in @(Get-VM -ComputerName $clusterNode.Name -ErrorAction Stop | Where-Object Id -ne $ExpectedVMId)) {
        $references=@(Get-VMHardDiskDrive -VM $other -ErrorAction Stop)+@(Get-VMDvdDrive -VM $other -ErrorAction Stop)
        if ($references | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($rootPath+'\',[StringComparison]::OrdinalIgnoreCase) }) { throw 'Otra VM referencia archivos de este despliegue.' }
    }
}
$Ansible.Result=@{validated=$true;vm=$vmName;vm_id=$ExpectedVMId.ToString();root=$rootPath;apply=[bool]$Apply}
if (-not $Apply) { return }
Stop-ClusterGroup -Name $vmName -Wait 120 -ErrorAction Stop | Out-Null
$vm=Get-VM -ComputerName $node -Id $ExpectedVMId -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop; $vm=Get-VM -ComputerName $node -Id $ExpectedVMId -ErrorAction Stop }
if ($vm.State -ne 'Off') { throw 'La VM no esta apagada; no se elimina.' }
Remove-ClusterGroup -Name $vmName -RemoveResources -Force -ErrorAction Stop
Remove-VM -VM $vm -Force -ErrorAction Stop
if (Get-VM -ComputerName $node -ErrorAction Stop | Where-Object Id -eq $ExpectedVMId) { throw 'La VM sigue registrada; se conservan los archivos.' }
# Target absoluto exacto validado arriba. Nunca se borra CSV, biblioteca o NAS.
if ([IO.Path]::GetFullPath($rootPath).TrimEnd('\') -notin $allowedRoots) { throw 'Ruta final de borrado invalida.' }
Remove-Item -LiteralPath $rootPath -Recurse -Force -ErrorAction Stop
$current=Get-Content -LiteralPath (Join-Path $lockPath 'owner.json') -Raw | ConvertFrom-Json
if ($current.vm -ne $lockOwner.vm -or $current.token -ne $lockOwner.token) { throw 'Cambio la reserva; no se libera.' }
$history=[IO.Path]::GetFullPath((Join-Path (Join-Path $libraryPath '.locks') '.history'))
$archive=[IO.Path]::GetFullPath((Join-Path $history ('cleanup-'+$vmName+'-'+[guid]::NewGuid().ToString('N'))))
if (-not $archive.StartsWith($history+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Archivo de reserva fuera de biblioteca.' }
New-Item -ItemType Directory -Path $history -Force | Out-Null
Move-Item -LiteralPath $lockPath -Destination $archive -ErrorAction Stop
@{vm_id=$ExpectedVMId.ToString();deleted_root=$rootPath;utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $archive 'cleanup.json') -Encoding UTF8
$Ansible.Result=@{deleted_vm=$vmName;deleted_root=$rootPath;lock_archived=$archive;ready_to_recreate=$true}
$Ansible.Changed=$true
