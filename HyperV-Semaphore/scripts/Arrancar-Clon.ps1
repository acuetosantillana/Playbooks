param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
Import-Module Hyper-V
Import-Module FailoverClusters
$manifest=Get-Content -LiteralPath (Join-Path $Root 'deployment.json') -Raw | ConvertFrom-Json
$personalized=Get-Content -LiteralPath (Join-Path $Root 'Provisioning\personalized.txt') -Raw
if ($personalized -ne $manifest.instance_id) { throw 'No se completo la personalizacion del clon.' }
$vm=Get-VM -Id ([guid]$manifest.vm_id)
if ($vm.Name -ne $manifest.name -or $vm.State -ne 'Off') { throw 'Identidad/estado inesperado del clon.' }
if (Get-ClusterGroup -ErrorAction Stop | Where-Object Name -eq $manifest.name) { throw 'Ya existe el rol. Revisar antes de reintentar.' }
Add-ClusterVirtualMachineRole -VMId $vm.Id -Name $manifest.name | Out-Null
Start-ClusterGroup -Name $manifest.name | Out-Null
$deadline=[DateTime]::UtcNow.AddSeconds(120)
do {
    $group=Get-ClusterGroup -Name $manifest.name
    if ($group.State -eq 'Online') { break }
    if ($group.State -eq 'Failed') { throw 'Fallo al iniciar el clon en el cluster.' }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)
if ($group.State -ne 'Online') { throw 'Timeout al iniciar el clon.' }
$Ansible.Changed=$true
$Ansible.Result=@{name=$vm.Name;state='Online';owner=$group.OwnerNode.Name}
