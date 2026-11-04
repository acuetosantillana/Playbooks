param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')][string]$TemplateId,
    [Parameter(Mandatory)][ValidateSet('Windows','Rocky')][string]$Sistema,
    [Parameter(Mandatory)][string]$Library,
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string[]]$CsvVolumes,
    [int]$TimeoutSeconds=1800
)
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
Import-Module Hyper-V
Import-Module FailoverClusters
if ($VmName -notmatch '^TPL-') { throw 'La fuente debe ser una base dedicada TPL-.' }
$root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$allowedRoots = @($CsvVolumes | ForEach-Object { [IO.Path]::GetFullPath((Join-Path (Join-Path $_ 'SemaphoreVMs') $VmName)).TrimEnd('\') })
if ($root -notin $allowedRoots) { throw 'La fuente no coincide con una VM creada por este proceso.' }
$sourceManifest = Get-Content -LiteralPath (Join-Path $root 'deployment.json') -Raw | ConvertFrom-Json
if ($sourceManifest.name -ne $VmName -or $sourceManifest.system -ne $Sistema) { throw 'Manifiesto de la fuente incompatible.' }
$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    $group=Get-ClusterGroup -Name $VmName
    $vm=Get-VM -ComputerName $group.OwnerNode.Name -Id ([guid]$sourceManifest.vm_id)
    if ($vm.State -eq 'Off') { break }
    Start-Sleep -Seconds 5
} while ([DateTime]::UtcNow -lt $deadline)
if ($vm.State -ne 'Off') { throw 'La base no se apago despues del sellado. Revisar Sysprep/cloud-init; no se publica una imagen.' }
if (@(Get-VMSnapshot -VM $vm).Count -gt 0) { throw 'Consolidar checkpoints antes de capturar.' }
$disks=@(Get-VMHardDiskDrive -VM $vm)
if ($disks.Count -ne 1) { throw 'La base debe tener un solo disco.' }
$disk=Get-VHD -Path $disks[0].Path
if ($disk.VhdType -eq 'Differencing' -or $disk.Attached -or $disk.Path -notlike '*.vhdx') { throw 'Se requiere un VHDX independiente y desconectado.' }
$libraryPath=[IO.Path]::GetFullPath($Library).TrimEnd('\')
$csv = @(Get-ClusterSharedVolume | Where-Object State -eq 'Online' | ForEach-Object { $_.SharedVolumeInfo } | Where-Object { $libraryPath.StartsWith($_.FriendlyVolumeName.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase) -and $_.FriendlyVolumeName -in $CsvVolumes })
if ($csv.Count -ne 1) { throw 'La biblioteca debe estar en un CSV autorizado y Online.' }
if ($csv[0].Partition.FreeSpace -lt $disk.FileSize + 10GB) { throw 'Espacio insuficiente para publicar la plantilla.' }
$folder=Join-Path $libraryPath $TemplateId
if (Test-Path -LiteralPath $folder) { throw 'Esta version ya existe. Publicar otra version; nunca sobrescribir una base.' }
New-Item -ItemType Directory -Path $libraryPath -Force | Out-Null
New-Item -ItemType Directory -Path $folder -ErrorAction Stop | Out-Null
$destination=Join-Path $folder 'base.vhdx'
Copy-Item -LiteralPath $disk.Path -Destination $destination
$hash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
$metadata=@{ id=$TemplateId; system=$Sistema; generation=2; source_vm=$VmName; source_vm_id=$vm.Id.ToString(); virtual_size=[long]$disk.Size; sha256=$hash; prepared_by='semaphore-base-builder-v1'; captured_utc=[DateTime]::UtcNow.ToString('o'); ready=$true }
(Get-Item -LiteralPath $destination).IsReadOnly=$true
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'metadata.json') -Encoding UTF8
$Ansible.Result=@{ template=$TemplateId; image=$destination; sha256=$hash; system=$Sistema; source_state='Off' }
$Ansible.Changed=$true
