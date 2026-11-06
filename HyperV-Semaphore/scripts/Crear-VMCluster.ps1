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
$arguments=@('-n','-m',"-l$label",$answers,$answersIso)
$quotedArguments=@($arguments | ForEach-Object { '"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"' })
$stdout=Join-Path $Root 'Media\oscdimg-answers.stdout.log'
$stderr=Join-Path $Root 'Media\oscdimg-answers.stderr.log'
$process=Start-Process -FilePath $OscdimgPath -ArgumentList $quotedArguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if ($process.ExitCode -ne 0) {
    $details=@(Get-Content -LiteralPath $stdout,$stderr -ErrorAction SilentlyContinue | Select-Object -Last 30) -join [Environment]::NewLine
    throw "Oscdimg fallo con codigo $($process.ExitCode). $details"
}
if (-not (Test-Path -LiteralPath $answersIso -PathType Leaf) -or (Get-Item -LiteralPath $answersIso).Length -eq 0) { throw 'Oscdimg no produjo el medio de respuestas.' }
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
$grubKeysSent = $false
if ($Sistema -eq 'Rocky') {
    # Seleccionar "Install Rocky Linux 9" en GRUB sin esperar el timeout de 60 s:
    # el host manda Arriba+Enter a la consola. Si la tecla no llega a tiempo,
    # el timeout de GRUB arranca igual la opcion por defecto (test & install).
    try {
        $ownerNode = $group.OwnerNode.Name
        $cim = New-CimSession -ComputerName $ownerNode -ErrorAction Stop
        $vmCs = Get-CimInstance -CimSession $cim -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VmName'"
        $keyboard = Get-CimAssociatedInstance -CimSession $cim -InputObject $vmCs -ResultClassName Msvm_Keyboard
        foreach ($delay in @(15, 10)) {
            Start-Sleep -Seconds $delay
            # VK_UP=38 resalta "Install"; VK_RETURN=13 arranca. Repetido por si GRUB aun no estaba.
            [void](Invoke-CimMethod -CimSession $cim -InputObject $keyboard -MethodName TypeKey -Arguments @{keyCode=[uint32]38})
            Start-Sleep -Milliseconds 500
            [void](Invoke-CimMethod -CimSession $cim -InputObject $keyboard -MethodName TypeKey -Arguments @{keyCode=[uint32]13})
        }
        Remove-CimSession -CimSession $cim
        $grubKeysSent = $true
    } catch { $grubKeysSent = $false }
}
$Ansible.Result = @{ name=$VmName; vm_id=$vm.Id.ToString(); owner=$group.OwnerNode.Name; root=$Root; state=$group.State.ToString(); grub_keys_sent=$grubKeysSent }
$Ansible.Changed = $true
