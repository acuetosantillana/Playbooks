param(
    [ValidateSet('Reservar','Liberar')][string]$Action,
    [string]$Library,
    [ValidatePattern('^TPL-[a-zA-Z0-9-]+$')][string]$VmName,
    [string]$IPAddress,
    [string[]]$CsvVolumes,
    [string]$Token
)
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
$address=[Net.IPAddress]::Parse($IPAddress)
if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'IP base invalida.' }
$libraryPath=[IO.Path]::GetFullPath($Library).TrimEnd('\')
if (-not ($CsvVolumes | Where-Object { $libraryPath.StartsWith($_.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) })) { throw 'Biblioteca fuera de los CSV autorizados.' }
Import-Module FailoverClusters
$volumes=@(Get-ClusterSharedVolume | Where-Object State -eq 'Online' | ForEach-Object { $_.SharedVolumeInfo.FriendlyVolumeName.TrimEnd('\') })
if (-not ($volumes | Where-Object { $_ -in $CsvVolumes -and $libraryPath.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase) })) { throw 'La biblioteca no esta sobre un CSV Online.' }
$locks=Join-Path $libraryPath '.locks'
$lock=Join-Path $locks $address.ToString()
$ownerFile=Join-Path $lock 'owner.json'
if ($Action -eq 'Reservar') {
    if (Test-Path -LiteralPath $lock) { throw 'La IP de instalacion ya esta reservada por otra base o por una tarea fallida. Revisar antes de continuar.' }
    if (Test-Connection -ComputerName $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue) { throw 'La IP de instalacion ya responde. No se inicia otra base con esa IP.' }
    New-Item -ItemType Directory -Path $locks -Force | Out-Null
    New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
    $tokenValue=[guid]::NewGuid().ToString()
    @{vm=$VmName;token=$tokenValue;ip=$IPAddress;created=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $ownerFile -Encoding UTF8
    $Ansible.Result=@{token=$tokenValue;ip=$IPAddress}
} else {
    $owner=Get-Content -LiteralPath $ownerFile -Raw | ConvertFrom-Json
    if ($owner.vm -ne $VmName -or $owner.token -ne $Token -or $owner.ip -ne $IPAddress) { throw 'El bloqueo pertenece a otra instalacion.' }
    # Ruta absoluta comprobada bajo .locks, nunca carpetas de VM ni imagenes.
    if ([IO.Path]::GetFullPath($lock) -ne (Join-Path $locks $address.ToString())) { throw 'Ruta de bloqueo invalida.' }
    Remove-Item -LiteralPath $ownerFile -Force
    Remove-Item -LiteralPath $lock
}
$Ansible.Changed=$true
