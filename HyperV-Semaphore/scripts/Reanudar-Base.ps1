param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][ValidateSet('Windows','Rocky')][string]$Sistema,
    [Parameter(Mandatory)][string]$IPAddress,
    [Parameter(Mandatory)][string]$Library,
    [Parameter(Mandatory)][string]$TemplateId,
    [Parameter(Mandatory)][string[]]$CsvVolumes
)
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
Import-Module Hyper-V
Import-Module FailoverClusters
$expectedName=if ($Sistema -eq 'Windows') { 'TPL-WS2025' } else { 'TPL-ROCKY9' }
if ($VmName -ne $expectedName) { throw 'Solo se reanuda la base dedicada del sistema elegido.' }
$libraryPath=[IO.Path]::GetFullPath($Library).TrimEnd('\')
if (-not ($CsvVolumes | Where-Object { $libraryPath.StartsWith($_.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) })) { throw 'Biblioteca fuera de CSV autorizados.' }
if ($TemplateId -ne $(if ($Sistema -eq 'Windows') { 'ws2025-base-v1' } else { 'rocky9-base-v1' })) { throw 'Version de plantilla incompatible.' }
if (Test-Path -LiteralPath (Join-Path $libraryPath $TemplateId)) { throw 'La version ya existe; no se repite el sellado ni la captura.' }
$address=[Net.IPAddress]::Parse($IPAddress)
if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'IP invalida.' }
$lock=Get-Content -LiteralPath (Join-Path $libraryPath ('.locks\'+$address.ToString()+'\owner.json')) -Raw | ConvertFrom-Json
if ($lock.vm -ne $VmName -or $lock.ip -ne $IPAddress -or -not $lock.token) { throw 'La reserva no pertenece a esta base.' }
$roots=@($CsvVolumes | ForEach-Object { Join-Path (Join-Path $_ 'SemaphoreVMs') $VmName } | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'deployment.json') })
if ($roots.Count -ne 1) { throw 'Se requiere un unico manifiesto de esta base en los CSV autorizados.' }
$root=[IO.Path]::GetFullPath($roots[0]).TrimEnd('\')
$manifest=Get-Content -LiteralPath (Join-Path $root 'deployment.json') -Raw | ConvertFrom-Json
if ($manifest.name -ne $VmName -or $manifest.system -ne $Sistema -or $manifest.root.TrimEnd('\') -ne $root) { throw 'El manifiesto no coincide con la base.' }
$group=Get-ClusterGroup -Name $VmName
$vm=Get-VM -ComputerName $group.OwnerNode.Name -Id ([guid]$manifest.vm_id)
if ($vm.Name -ne $VmName -or $vm.State -ne 'Running' -or $group.State -ne 'Online') { throw 'Se requiere la base instalada encendida y su rol Online; no se enciende ni reinstala automaticamente.' }
$disks=@(Get-VMHardDiskDrive -VM $vm)
$expectedDisk=Join-Path $root ('Virtual Hard Disks\'+$VmName+'.vhdx')
if ($disks.Count -ne 1 -or [IO.Path]::GetFullPath($disks[0].Path) -ne $expectedDisk -or @(Get-VMSnapshot -VM $vm).Count -gt 0) { throw 'El disco o los checkpoints no permiten continuar esta base.' }
$Ansible.Result=@{root=$root;csv=(Split-Path -Parent (Split-Path -Parent $root));vm_id=$vm.Id.ToString();owner=$group.OwnerNode.Name;token=$lock.token}
