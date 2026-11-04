param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$')][string]$VmName,
    [Parameter(Mandatory)][string[]]$ClusterNodes,
    [Parameter(Mandatory)][string[]]$CsvVolumes,
    [Parameter(Mandatory)][string]$SwitchName,
    [Parameter(Mandatory)][string]$IsoPath,
    [Parameter(Mandatory)][long]$DiskBytes,
    [Parameter(Mandatory)][string]$OscdimgPath,
    [long]$ReserveBytes = 10737418240,
    [ValidateRange(1,3)][int]$IsoCopies = 1,
    [PSCredential]$NasCredential
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module Hyper-V
Import-Module FailoverClusters
Write-Host 'Preparacion: comprobar Oscdimg y acceso al cluster.'
if (-not (Test-Path -LiteralPath $OscdimgPath -PathType Leaf)) { throw 'Falta oscdimg.exe en el nodo ejecutor.' }
$cluster = Get-Cluster
$nodes = @(Get-ClusterNode)
if ($env:COMPUTERNAME -notin $ClusterNodes) { throw 'El ejecutor no pertenece a los nodos autorizados.' }
foreach ($nodeName in $ClusterNodes) {
    Write-Host "Preparacion: comprobar nodo $nodeName, switch $SwitchName y VM existentes."
    $node = $nodes | Where-Object Name -eq $nodeName
    if (-not $node -or $node.State -ne 'Up') { throw "El nodo $nodeName debe estar disponible durante el despliegue." }
    $null = Get-VMSwitch -ComputerName $nodeName -Name $SwitchName -ErrorAction Stop
    if (Get-VM -ComputerName $nodeName -ErrorAction Stop | Where-Object Name -eq $VmName) { throw "La VM $VmName ya existe. Se conserva sin modificaciones." }
}
if (Get-ClusterGroup -ErrorAction Stop | Where-Object Name -eq $VmName) { throw 'Ya existe un rol de cluster con ese nombre.' }
$drive = $null
try {
    $sourcePath = $IsoPath
    if ($NasCredential) {
        Write-Host 'Preparacion: abrir acceso al NAS con la credencial protegida recibida.'
        if ($IsoPath -notmatch '^\\\\([^\\]+)\\([^\\]+)\\(.+)$') { throw 'Con credencial NAS se requiere una ruta UNC completa.' }
        $shareRoot = '\\' + $Matches[1] + '\' + $Matches[2]
        $relativePath = $Matches[3]
        $driveName = 'HV' + [guid]::NewGuid().ToString('N').Substring(0,8)
        $drive = New-PSDrive -Name $driveName -PSProvider FileSystem -Root $shareRoot -Credential $NasCredential -Scope Script
        $sourcePath = $driveName + ':\' + $relativePath
    }
    Write-Host 'Preparacion: comprobar acceso y existencia de la ISO de origen.'
    $iso = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
    if ($iso.PSIsContainer -or $iso.Extension -ne '.iso') { throw 'IsoPath debe ser un archivo ISO.' }
    $candidates = @()
    foreach ($csv in Get-ClusterSharedVolume | Where-Object State -eq 'Online') {
        foreach ($volume in $csv.SharedVolumeInfo) {
            $path = $volume.FriendlyVolumeName.TrimEnd('\')
            if ($path -in $CsvVolumes) {
                $root = Join-Path (Join-Path $path 'SemaphoreVMs') $VmName
                if (Test-Path -LiteralPath $root) { throw "Ya existe un despliegue con ese nombre: $root. Revisar manualmente." }
                $candidates += [pscustomobject]@{ Path=$path; Free=[long]$volume.Partition.FreeSpace }
            }
        }
    }
    $required = $DiskBytes + ($iso.Length * $IsoCopies) + $ReserveBytes
    Write-Host 'Preparacion: seleccionar un CSV autorizado con espacio suficiente.'
    $best = $candidates | Where-Object Free -ge $required | Sort-Object Free -Descending | Select-Object -First 1
    if (-not $best) { throw 'Ningun CSV autorizado tiene espacio suficiente para disco, ISO y reserva.' }
    $root = Join-Path (Join-Path $best.Path 'SemaphoreVMs') $VmName
    $parentPath = Split-Path -Parent $root
    if (-not (Test-Path -LiteralPath $parentPath)) { New-Item -ItemType Directory -Path $parentPath -Force | Out-Null }
    # Sin Force: reservar un nombre existente falla, incluso entre trabajos concurrentes.
    New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
    Write-Host 'Preparacion: crear carpetas y proteger el directorio temporal.'
    $stage = Join-Path $root 'Provisioning'
    $media = Join-Path $root 'Media'
    New-Item -ItemType Directory -Path $stage,$media | Out-Null
    # Evita que el XML con contrasena herede acceso para usuarios generales.
    $acl = Get-Acl -LiteralPath $stage
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($identity in @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
        $sid = [Security.Principal.SecurityIdentifier]::new($identity)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl',$inherit,'None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $stage -AclObject $acl
    $osIso = Join-Path $media 'os.iso'
    Write-Host 'Preparacion: copiar la ISO al CSV.'
    Copy-Item -LiteralPath $sourcePath -Destination ($osIso + '.partial') -ErrorAction Stop
    if ((Get-Item -LiteralPath ($osIso + '.partial')).Length -ne $iso.Length) { throw 'La copia de ISO quedo incompleta.' }
    Move-Item -LiteralPath ($osIso + '.partial') -Destination $osIso
    $Ansible.Result = @{ root=$root; stage=$stage; media=$media; os_iso=$osIso; csv=$best.Path; cluster=$cluster.Name }
    $Ansible.Changed = $true
} finally {
    if ($drive) { Remove-PSDrive -Name $drive.Name -Force }
}
