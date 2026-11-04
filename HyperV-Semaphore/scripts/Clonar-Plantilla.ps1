param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$')][string]$VmName,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')][string]$TemplateId,
    [Parameter(Mandatory)][ValidateSet('Windows','Rocky')][string]$Sistema,
    [Parameter(Mandatory)][string]$Library,
    [Parameter(Mandatory)][string[]]$ClusterNodes,
    [Parameter(Mandatory)][string[]]$CsvVolumes,
    [Parameter(Mandatory)][string]$SwitchName,
    [Parameter(Mandatory)][long]$MemoryBytes,
    [Parameter(Mandatory)][long]$DiskBytes,
    [Parameter(Mandatory)][int]$CpuCount,
    [ValidateSet(120,96)][int]$VlanId,
    [long]$ReserveBytes=10737418240
)
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
Import-Module Hyper-V
Import-Module FailoverClusters
if ($env:COMPUTERNAME -notin $ClusterNodes) { throw 'Nodo ejecutor no autorizado.' }
$nodes=@(Get-ClusterNode)
$usedMac=@()
foreach ($nodeName in $ClusterNodes) {
    if (-not ($nodes | Where-Object { $_.Name -eq $nodeName -and $_.State -eq 'Up' })) { throw "Nodo no disponible: $nodeName" }
    $null=Get-VMSwitch -ComputerName $nodeName -Name $SwitchName -ErrorAction Stop
    if (Get-VM -ComputerName $nodeName -ErrorAction Stop | Where-Object Name -eq $VmName) { throw 'La VM ya existe; no se modifica.' }
    $usedMac+=@(Get-VMNetworkAdapter -ComputerName $nodeName -All | ForEach-Object MacAddress)
}
if (Get-ClusterGroup -ErrorAction Stop | Where-Object Name -eq $VmName) { throw 'El rol de cluster ya existe.' }
$sourceDirectory=Join-Path $Library $TemplateId
$metadataPath=Join-Path $sourceDirectory 'metadata.json'
if (-not (Test-Path -LiteralPath $metadataPath)) { throw "Falta crear y capturar la base $TemplateId. Ejecutar primero su tarea BASE, una sola vez." }
$metadata=Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ($metadata.ready -ne $true -or $metadata.id -ne $TemplateId -or $metadata.system -ne $Sistema -or $metadata.generation -ne 2 -or $metadata.prepared_by -ne 'semaphore-base-builder-v1') { throw 'La plantilla no es una base preparada compatible.' }
$baseDisk=Join-Path $sourceDirectory 'base.vhdx'
$vhd=Get-VHD -Path $baseDisk
if ($vhd.Attached -or $vhd.VhdType -eq 'Differencing') { throw 'El disco maestro debe estar independiente y desconectado.' }
if ($DiskBytes -lt $vhd.Size) { throw 'El disco solicitado no puede ser menor que el disco virtual de la base.' }
if ((Get-FileHash -LiteralPath $baseDisk -Algorithm SHA256).Hash -ne $metadata.sha256) { throw 'La imagen maestra no coincide con su hash publicado.' }
$candidates=@()
foreach ($csv in Get-ClusterSharedVolume | Where-Object State -eq 'Online') {
    foreach ($volume in $csv.SharedVolumeInfo) {
        $path=$volume.FriendlyVolumeName.TrimEnd('\')
        if ($path -in $CsvVolumes) {
            if (Test-Path -LiteralPath (Join-Path (Join-Path $path 'SemaphoreVMs') $VmName)) { throw 'Ya existe una carpeta de despliegue con ese nombre.' }
            if ($volume.Partition.FreeSpace -ge $DiskBytes+$ReserveBytes) { $candidates+=[pscustomobject]@{Path=$path;Free=$volume.Partition.FreeSpace} }
        }
    }
}
$selected=$candidates | Sort-Object Free -Descending | Select-Object -First 1
if (-not $selected) { throw 'No hay espacio suficiente en los CSV permitidos.' }
$root=Join-Path (Join-Path $selected.Path 'SemaphoreVMs') $VmName
$parent=Split-Path -Parent $root
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
$stage=Join-Path $root 'Provisioning'
$media=Join-Path $root 'Media'
$diskDirectory=Join-Path $root 'Virtual Hard Disks'
New-Item -ItemType Directory -Path $stage,$media,$diskDirectory | Out-Null
$acl=Get-Acl -LiteralPath $stage
$acl.SetAccessRuleProtection($true,$false)
foreach ($identity in @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identity),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $stage -AclObject $acl
$destination=Join-Path $diskDirectory ($VmName+'.vhdx')
Copy-Item -LiteralPath $baseDisk -Destination $destination
(Get-Item -LiteralPath $destination).IsReadOnly=$false
if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $metadata.sha256) { throw 'La copia del disco no paso la validacion de integridad.' }
if ($DiskBytes -gt $vhd.Size) { Resize-VHD -Path $destination -SizeBytes $DiskBytes }
$vm=New-VM -Name $VmName -Generation 2 -Path $root -VHDPath $destination -SwitchName $SwitchName -MemoryStartupBytes $MemoryBytes
Set-VMProcessor -VM $vm -Count $CpuCount
Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType ProductionOnly -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
Set-VMNetworkAdapterVlan -VM $vm -Access -VlanId $VlanId
$random=[Security.Cryptography.RandomNumberGenerator]::Create()
try {
    do {
        $bytes=New-Object byte[] 6
        $random.GetBytes($bytes)
        $bytes[0]=2
        $mac=($bytes | ForEach-Object {$_.ToString('X2')}) -join ''
    } while ($mac -in $usedMac)
} finally { $random.Dispose() }
Set-VMNetworkAdapter -VM $vm -StaticMacAddress $mac
$secureBoot='MicrosoftWindows'
if ($Sistema -eq 'Rocky') { $secureBoot='MicrosoftUEFICertificateAuthority' }
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate $secureBoot -FirstBootDevice (Get-VMHardDiskDrive -VM $vm | Select-Object -First 1)
$instanceId=[guid]::NewGuid().ToString()
@{name=$VmName;vm_id=$vm.Id.ToString();root=$root;system=$Sistema;template=$TemplateId;instance_id=$instanceId;mac=$mac;disk=$destination;created_utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'deployment.json') -Encoding UTF8
$Ansible.Result=@{root=$root;stage=$stage;csv=$selected.Path;instance_id=$instanceId;vm_id=$vm.Id.ToString();template=$TemplateId}
$Ansible.Changed=$true
