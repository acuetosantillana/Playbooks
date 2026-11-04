param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][ValidateSet('Windows','Rocky')][string]$Sistema,
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$SwitchName,
    [Parameter(Mandatory)][string]$OscdimgPath,
    [Parameter(Mandatory)][long]$MemoryBytes,
    [Parameter(Mandatory)][long]$DiskBytes,
    [Parameter(Mandatory)][int]$CpuCount,
    [string]$OsIsoPath='',
    [ValidateRange(0,4094)][int]$VlanId=0
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module Hyper-V
Import-Module FailoverClusters
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { throw 'La VM ya existe; no se modifica.' }
if (Get-ClusterGroup -Name $VmName -ErrorAction SilentlyContinue) { throw 'El rol ya existe; no se modifica.' }
$stage = Join-Path $Root 'Provisioning'
$answers = Join-Path $stage 'answers'
$osIso = Join-Path $Root 'Media\os.iso'
if ($OsIsoPath) {
    $allowedIsoPaths=@($osIso,(Join-Path $Root 'Media\os-uefi-auto.iso'))
    if ([IO.Path]::GetFullPath($OsIsoPath) -notin $allowedIsoPaths) { throw 'ISO fuera del directorio de medios de esta VM.' }
    $osIso=[IO.Path]::GetFullPath($OsIsoPath)
}
$answersIso = Join-Path $Root 'Media\answers.iso'
$label = 'OEMDRV'
$file = 'ks.cfg'
$secureBoot = 'MicrosoftUEFICertificateAuthority'
if ($Sistema -eq 'Windows') { $label='HVCONFIG'; $file='Autounattend.xml'; $secureBoot='MicrosoftWindows' }
if (-not (Test-Path -LiteralPath (Join-Path $answers $file))) { throw 'No se generaron las respuestas de instalacion.' }
if (-not (Test-Path -LiteralPath $osIso)) { throw 'No se encontro la ISO de instalacion en CSV.' }
if (Test-Path -LiteralPath $answersIso) { throw 'El medio de respuestas ya existe. No se sobrescribe.' }
& $OscdimgPath '-n' '-m' "-l$label" $answers $answersIso | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Oscdimg fallo con codigo $LASTEXITCODE." }
# Proteger el medio con credenciales manteniendo lectura para los procesos VM.
$acl = Get-Acl -LiteralPath $answersIso
$acl.SetAccessRuleProtection($true,$false)
foreach ($identity in @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identity),'FullControl','Allow'))
}
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-83-0'),'ReadAndExecute','Allow'))
Set-Acl -LiteralPath $answersIso -AclObject $acl
$vhdDirectory = Join-Path $Root 'Virtual Hard Disks'
New-Item -ItemType Directory -Path $vhdDirectory -ErrorAction Stop | Out-Null
$vhdPath = Join-Path $vhdDirectory ($VmName + '.vhdx')
New-VHD -Path $vhdPath -Dynamic -SizeBytes $DiskBytes | Out-Null
$vm = New-VM -Name $VmName -Generation 2 -Path $Root -MemoryStartupBytes $MemoryBytes -SwitchName $SwitchName -VHDPath $vhdPath
Set-VMProcessor -VM $vm -Count $CpuCount
Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType ProductionOnly -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
if ($VlanId -gt 0) { Set-VMNetworkAdapterVlan -VM $vm -Access -VlanId $VlanId } else { Set-VMNetworkAdapterVlan -VM $vm -Untagged }
$dvd = Add-VMDvdDrive -VM $vm -Path $osIso -Passthru
Add-VMDvdDrive -VM $vm -Path $answersIso | Out-Null
$disk = Get-VMHardDiskDrive -VM $vm | Select-Object -First 1
# Disco vacio: pasa al DVD. Tras instalar: inicia desde el disco y evita reinstalar.
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate $secureBoot -BootOrder @($disk,$dvd)
Add-ClusterVirtualMachineRole -VMId $vm.Id -Name $VmName | Out-Null
$manifest = @{ name=$VmName; vm_id=$vm.Id.ToString(); root=$Root; system=$Sistema; created_utc=[DateTime]::UtcNow.ToString('o') }
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'deployment.json') -Encoding UTF8
Start-ClusterGroup -Name $VmName | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds(120)
do {
    $group = Get-ClusterGroup -Name $VmName
    if ($group.State -eq 'Failed') { throw 'El recurso de cluster fallo al iniciar.' }
    if ($group.State -eq 'Online') { break }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)
if ($group.State -ne 'Online') { throw 'Timeout al iniciar el recurso de cluster.' }
$Ansible.Result = @{ name=$VmName; vm_id=$vm.Id.ToString(); owner=$group.OwnerNode.Name; root=$Root; state=$group.State.ToString() }
$Ansible.Changed = $true
