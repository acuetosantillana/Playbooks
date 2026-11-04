param(
    [string]$VmName='TPL-WS2025',
    [string[]]$ClusterNodes,
    [string[]]$CsvVolumes,
    [string]$SwitchName,
    [string]$IsoPath,
    [string]$OscdimgPath,
    [string]$Library,
    [string]$BaseIP,
    [PSCredential]$NasCredential
)
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
$checks=New-Object 'System.Collections.Generic.List[object]'
function Add-Probe {
    param([string]$Name,[scriptblock]$Probe)
    try { $data=@(& $Probe); $checks.Add(@{check=$Name;ok=$true;data=$data}) }
    catch { $checks.Add(@{check=$Name;ok=$false;message=$_.Exception.Message;type=$_.Exception.GetType().FullName;error_id=$_.FullyQualifiedErrorId}) }
}
Add-Probe 'modulo_HyperV' { Import-Module Hyper-V; 'Disponible' }
Add-Probe 'modulo_FailoverClusters' { Import-Module FailoverClusters; 'Disponible' }
Add-Probe 'oscdimg' { if (-not (Test-Path -LiteralPath $OscdimgPath -PathType Leaf)) { throw "No existe $OscdimgPath" }; $OscdimgPath }
Add-Probe 'cluster_nodos' { Get-ClusterNode | Select-Object Name,State }
foreach ($node in $ClusterNodes) {
    Add-Probe ('switches_'+$node) { Get-VMSwitch -ComputerName $node -ErrorAction Stop | Select-Object Name,SwitchType }
    Add-Probe ('switch_solicitado_'+$node) { Get-VMSwitch -ComputerName $node -Name $SwitchName -ErrorAction Stop | Select-Object Name }
    Add-Probe ('vm_existente_'+$node) { Get-VM -ComputerName $node -ErrorAction Stop | Where-Object Name -eq $VmName | Select-Object Name,State,Id }
}
Add-Probe 'CSV_online_y_espacio' {
    Get-ClusterSharedVolume | ForEach-Object { foreach ($volume in $_.SharedVolumeInfo) {
        [pscustomobject]@{state=$_.State.ToString();path=$volume.FriendlyVolumeName;free_gib=[math]::Round($volume.Partition.FreeSpace/1GB,2);allowed=($volume.FriendlyVolumeName.TrimEnd('\') -in $CsvVolumes)}
    } }
}
Add-Probe 'ISO_con_acceso_configurado' {
    $drive=$null
    try {
        $sourcePath=$IsoPath
        if ($NasCredential) {
            if ($IsoPath -notmatch '^\\\\([^\\]+)\\([^\\]+)\\(.+)$') { throw 'iso_path debe ser una ruta UNC completa.' }
            $shareRoot='\\'+$Matches[1]+'\'+$Matches[2]
            $relativePath=$Matches[3]
            $driveName='DIAG'+[guid]::NewGuid().ToString('N').Substring(0,8)
            $drive=New-PSDrive -Name $driveName -PSProvider FileSystem -Root $shareRoot -Credential $NasCredential -Scope Script
            $sourcePath=$driveName+':\'+$relativePath
        }
        $file=Get-Item -LiteralPath $sourcePath -ErrorAction Stop
        [pscustomobject]@{path=$IsoPath;bytes=$file.Length;protected_credential_used=($null -ne $NasCredential)}
    } finally { if ($drive) { Remove-PSDrive -Name $drive.Name -Force } }
}
Add-Probe 'archivo_arranque_automatico_en_host' {
    $paths=@((Join-Path (Split-Path -Parent $OscdimgPath) 'efisys_noprompt.bin'))
    if (${env:ProgramFiles(x86)}) { $paths+=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\efisys_noprompt.bin' }
    foreach ($path in $paths) { [pscustomobject]@{path=$path;exists=(Test-Path -LiteralPath $path -PathType Leaf)} }
}
Add-Probe 'bloqueo_IP_base' {
    $owner=Join-Path (Join-Path (Join-Path $Library '.locks') $BaseIP) 'owner.json'
    if (Test-Path -LiteralPath $owner) { Get-Content -LiteralPath $owner -Raw | ConvertFrom-Json | Select-Object vm,ip,created } else { 'Sin bloqueo' }
}
Add-Probe 'carpetas_de_preparacion_existentes' {
    foreach ($csv in $CsvVolumes) {
        $root=Join-Path (Join-Path $csv 'SemaphoreVMs') $VmName
        if (Test-Path -LiteralPath $root) {
            [pscustomobject]@{path=$root;has_manifest=(Test-Path -LiteralPath (Join-Path $root 'deployment.json'));files=@(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction Stop | Select-Object -First 15 FullName,Length)}
        }
    }
}
$Ansible.Result=@{executor=$env:COMPUTERNAME;identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name;switch_requested=$SwitchName;vm=$VmName;checks=$checks.ToArray();read_only=$true}
