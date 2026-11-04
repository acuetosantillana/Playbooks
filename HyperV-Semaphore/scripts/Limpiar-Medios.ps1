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
foreach ($dvd in @(Get-VMDvdDrive -ComputerName $ownerNode -VMName $VmName)) {
    if ($dvd.Path) {
        Set-VMDvdDrive -ComputerName $ownerNode -VMName $VmName -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $null
        $Ansible.Changed = $true
    }
}
if (Get-VMDvdDrive -ComputerName $ownerNode -VMName $VmName | Where-Object Path) { throw 'Quedan medios montados. Se conserva el material de instalacion.' }
# Solo estas rutas del despliegue; nunca se borran discos ni configuracion de VM.
foreach ($relative in @('Provisioning','Media\answers.iso','Media\os.iso')) {
    $targetPath = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $relative))
    if (-not $targetPath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Ruta de limpieza fuera del despliegue.' }
    if (Test-Path -LiteralPath $targetPath) {
        Remove-Item -LiteralPath $targetPath -Recurse -Force
        $Ansible.Changed = $true
    }
}
$Ansible.Result = @{ name=$VmName; owner=$ownerNode; state='Online'; media_removed=$true }
