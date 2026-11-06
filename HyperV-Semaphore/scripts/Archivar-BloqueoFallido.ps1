param(
    [Parameter(Mandatory)][string]$Library,
    [Parameter(Mandatory)][string[]]$CsvVolumes,
    [Parameter(Mandatory)][string[]]$ClusterNodes,
    [Parameter(Mandatory)][ValidatePattern('^TPL-[a-zA-Z0-9-]+$')][string]$VmName,
    [Parameter(Mandatory)][string]$IPAddress,
    [Parameter(Mandatory)][DateTimeOffset]$ExpectedCreated,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$FailedTaskId,
    [string]$PreparationRoot=''
)
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
Import-Module Hyper-V
Import-Module FailoverClusters
$ip=[Net.IPAddress]::Parse($IPAddress)
if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'IP invalida.' }
$libraryPath=[IO.Path]::GetFullPath($Library).TrimEnd('\')
$online=@(Get-ClusterSharedVolume | Where-Object State -eq 'Online' | ForEach-Object { $_.SharedVolumeInfo.FriendlyVolumeName.TrimEnd('\') })
if (-not ($online | Where-Object { $_ -in $CsvVolumes -and $libraryPath.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase) })) { throw 'La biblioteca no esta en un CSV autorizado Online.' }
$locks=[IO.Path]::GetFullPath((Join-Path $libraryPath '.locks'))
$source=[IO.Path]::GetFullPath((Join-Path $locks $ip.ToString()))
if (-not $source.StartsWith($locks+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Bloqueo fuera de la biblioteca.' }
$guardPath=Join-Path $locks ('.recovery-'+$ip.ToString()+'.guard')
$guard=[IO.File]::Open($guardPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
$owner=Get-Content -LiteralPath (Join-Path $source 'owner.json') -Raw | ConvertFrom-Json
if ($owner.vm -ne $VmName -or $owner.ip -ne $ip.ToString() -or ([DateTimeOffset]$owner.created) -ne $ExpectedCreated) { throw 'El bloqueo ya no coincide con el intento fallido seleccionado; no se modifica.' }
foreach ($node in $ClusterNodes) {
    if (Get-VM -ComputerName $node -ErrorAction Stop | Where-Object Name -eq $VmName) { throw 'Existe una VM con ese nombre; no es seguro liberar la IP automaticamente.' }
}
if (Get-ClusterGroup -ErrorAction Stop | Where-Object Name -eq $VmName) { throw 'Existe un rol de cluster para esa base.' }
$preparationPaths=@($CsvVolumes | ForEach-Object { [IO.Path]::GetFullPath((Join-Path (Join-Path $_ 'SemaphoreVMs') $VmName)) })
$existingPaths=@($preparationPaths | Where-Object { Test-Path -LiteralPath $_ })
$archivePreparation=''
if ($PreparationRoot) {
    $archivePreparation=[IO.Path]::GetFullPath($PreparationRoot).TrimEnd('\')
    if ($archivePreparation -notin $preparationPaths -or $existingPaths.Count -ne 1 -or $existingPaths[0] -ne $archivePreparation) { throw 'La carpeta no coincide con la unica preparacion autorizada.' }
    if (Get-Process -Name oscdimg -ErrorAction SilentlyContinue) { throw 'Oscdimg sigue activo; no se mueve su preparacion.' }
    $items=@(Get-ChildItem -LiteralPath $archivePreparation -Recurse -Force)
    if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Se detecto un enlace en la preparacion.' }
    $configPath=Join-Path $archivePreparation 'Provisioning\vm.json'
    if (Test-Path -LiteralPath $configPath) {
        $config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($config.vm_name -ne $VmName -or $config.solo_base -ne $true) { throw 'La configuracion no corresponde a esta base.' }
    }
    foreach ($item in $items) {
        $relative=$item.FullName.Substring($archivePreparation.Length+1)
        # Solo el estado anterior a generar respuestas o crear discos/VM.
        if ($relative -notmatch '^(Media|Provisioning)$|^Provisioning\\windows-media(?:\\.*)?$|^Provisioning\\answers(?:\\.*)?$|^Provisioning\\(?:Configurar-Windows\.ps1|Generar-Respuestas\.ps1|Personalizar-Clon\.ps1|rocky9(?:-base)?\.ks\.tpl|rocky-auto\.iso(?:\.partial)?|vm\.json|fuentes-originales(?:\\windows-original\.xml\.j2)?)$|^Media\\(?:os\.iso|os-uefi-auto\.iso(?:\.partial)?|os-uefi-auto\.json|oscdimg-uefi\.(?:stdout|stderr)\.log)$') { throw "Hay recursos fuera de la preparacion de ISO: $relative" }
    }
    $sourceImage=Join-Path $archivePreparation 'Media\os.iso'
    if ((Get-DiskImage -ImagePath $sourceImage -ErrorAction Stop).Attached) { throw 'La ISO sigue montada; no se mueve.' }
} elseif ($existingPaths.Count -gt 0) { throw 'Existe una carpeta de preparacion; revisar su contenido antes de recuperar.' }
if (Test-Connection -ComputerName $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue) { throw 'La IP responde. Se conserva el bloqueo.' }
$history=[IO.Path]::GetFullPath((Join-Path $locks '.history'))
$destination=[IO.Path]::GetFullPath((Join-Path $history ($ip.ToString()+'-task'+$FailedTaskId+'-'+[guid]::NewGuid().ToString('N'))))
if (-not $destination.StartsWith($history+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $history.StartsWith($locks+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Destino de archivo fuera del directorio de bloqueos.' }
New-Item -ItemType Directory -Path $history -Force | Out-Null
if ($archivePreparation) {
    $archiveParent=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $archivePreparation) '.failed'))
    $archiveTarget=[IO.Path]::GetFullPath((Join-Path $archiveParent ($VmName+'-task'+$FailedTaskId+'-'+[guid]::NewGuid().ToString('N'))))
    if (-not $archiveTarget.StartsWith($archiveParent+'\',[StringComparison]::OrdinalIgnoreCase) -or $archivePreparation -notin $preparationPaths) { throw 'Ruta de archivo fuera del directorio autorizado.' }
    New-Item -ItemType Directory -Path $archiveParent -Force | Out-Null
    Move-Item -LiteralPath $archivePreparation -Destination $archiveTarget -ErrorAction Stop
}
# Conserva owner.json completo. No elimina datos y no toca VM ni discos.
Move-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
@{failed_task=$FailedTaskId;vm=$VmName;ip=$IPAddress;archived_utc=[DateTime]::UtcNow.ToString('o');preparation_archive=$archiveTarget;reason='Preparacion fallida antes de crear VM'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'recovery.json') -Encoding UTF8
$Ansible.Result=@{ip=$IPAddress;vm=$VmName;archived_at=$destination;preparation_archive=$archiveTarget;ready_to_retry=$true}
$Ansible.Changed=$true
} finally { $guard.Dispose() }
