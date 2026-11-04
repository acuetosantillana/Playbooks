param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string[]]$CsvVolumes
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module Hyper-V
Import-Module FailoverClusters
$resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$expectedRoots = @($CsvVolumes | ForEach-Object { [IO.Path]::GetFullPath((Join-Path (Join-Path $_ 'SemaphoreVMs') $VmName)).TrimEnd('\') })
if ($resolvedRoot -notin $expectedRoots) { throw 'Root no coincide con una carpeta de despliegue autorizada.' }
$manifest = Get-Content -LiteralPath (Join-Path $resolvedRoot 'deployment.json') -Raw | ConvertFrom-Json
if ($manifest.name -ne $VmName -or $manifest.root.TrimEnd('\') -ne $resolvedRoot) { throw 'Manifiesto de despliegue invalido.' }
$group = Get-ClusterGroup -Name $VmName
$ownerNode = $group.OwnerNode.Name
$vm = Get-VM -ComputerName $ownerNode -Id ([guid]$manifest.vm_id)
if ($vm.Name -ne $VmName -or $group.State -ne 'Online') { throw 'La VM validada no esta disponible.' }
$dvds = @(Get-VMDvdDrive -VM $vm)
# Comprobar TODOS los medios antes de modificar dispositivos. Solo son temporales
# los DVD de esta instalacion; un medio ajeno requiere revision.
foreach ($dvd in $dvds) {
    if ($dvd.Path -and [IO.Path]::GetFullPath($dvd.Path) -notin @(
        (Join-Path $resolvedRoot 'Media\answers.iso'),
        (Join-Path $resolvedRoot 'Media\os.iso'),
        (Join-Path $resolvedRoot 'Media\os-uefi-auto.iso')
    )) { throw 'DVD ajeno al despliegue. Se conserva el material de instalacion.' }
}
foreach ($dvd in $dvds) {
    # Retirar el dispositivo temporal por su objeto exacto evita conservar una
    # referencia a la ISO al vaciar Path por direccion de controlador.
    Remove-VMDvdDrive -VMDvdDrive $dvd -ErrorAction Stop
    $Ansible.Changed = $true
}
$remaining = @()
for ($attempt = 0; $attempt -lt 10; $attempt++) {
    $group = Get-ClusterGroup -Name $VmName
    $ownerNode = $group.OwnerNode.Name
    $vm = Get-VM -ComputerName $ownerNode -Id ([guid]$manifest.vm_id)
    $remaining = @(Get-VMDvdDrive -VM $vm)
    if ($remaining.Count -eq 0) { break }
    Start-Sleep -Seconds 2
}
if ($remaining.Count -gt 0) {
    throw ('Quedan DVD temporales en {0}: {1}. Se conserva el material de instalacion.' -f $ownerNode, (($remaining | ForEach-Object { '{0}:{1} {2}' -f $_.ControllerNumber,$_.ControllerLocation,$_.Path }) -join '; '))
}
# Solo estas rutas del despliegue; nunca se borran discos ni configuracion de VM.
foreach ($relative in @('Provisioning','Media\answers.iso','Media\os.iso','Media\os-uefi-auto.iso')) {
    $targetPath = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $relative))
    if (-not $targetPath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Ruta de limpieza fuera del despliegue.' }
    if (Test-Path -LiteralPath $targetPath) {
        Remove-Item -LiteralPath $targetPath -Recurse -Force
        $Ansible.Changed = $true
    }
}
$Ansible.Result = @{ name=$VmName; owner=$ownerNode; state='Online'; media_removed=$true }
