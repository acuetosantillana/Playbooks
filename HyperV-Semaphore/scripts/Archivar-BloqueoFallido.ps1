param(
    [Parameter(Mandatory)][string]$Library,
    [Parameter(Mandatory)][string[]]$CsvVolumes,
    [Parameter(Mandatory)][string[]]$ClusterNodes,
    [Parameter(Mandatory)][ValidatePattern('^TPL-[a-zA-Z0-9-]+$')][string]$VmName,
    [Parameter(Mandatory)][string]$IPAddress,
    [Parameter(Mandatory)][DateTimeOffset]$ExpectedCreated,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$FailedTaskId
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
foreach ($csv in $CsvVolumes) {
    if (Test-Path -LiteralPath (Join-Path (Join-Path $csv 'SemaphoreVMs') $VmName)) { throw 'Existe una carpeta de preparacion; revisar su contenido antes de recuperar.' }
}
if (Test-Connection -ComputerName $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue) { throw 'La IP responde. Se conserva el bloqueo.' }
$history=[IO.Path]::GetFullPath((Join-Path $locks '.history'))
$destination=[IO.Path]::GetFullPath((Join-Path $history ($ip.ToString()+'-task'+$FailedTaskId+'-'+[guid]::NewGuid().ToString('N'))))
if (-not $destination.StartsWith($history+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $history.StartsWith($locks+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Destino de archivo fuera del directorio de bloqueos.' }
New-Item -ItemType Directory -Path $history -Force | Out-Null
# Conserva owner.json completo. No elimina datos y no toca VM ni discos.
Move-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
@{failed_task=$FailedTaskId;vm=$VmName;ip=$IPAddress;archived_utc=[DateTime]::UtcNow.ToString('o');reason='Preparacion fallida antes de crear VM o carpeta'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'recovery.json') -Encoding UTF8
$Ansible.Result=@{ip=$IPAddress;vm=$VmName;archived_at=$destination;ready_to_retry=$true}
$Ansible.Changed=$true
} finally { $guard.Dispose() }
