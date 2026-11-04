param([string]$VmName, [PSCredential]$GuestCredential)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module Hyper-V
$vm = Get-VM -Name $VmName
if ($vm.State -ne 'Running' -or $VmName -notmatch '^TPL-') { throw 'Solo se sella una VM base TPL- encendida, recien creada por el proceso.' }
Invoke-Command -VMId $vm.Id -Credential $GuestCredential -ArgumentList $VmName -ScriptBlock {
    param($ExpectedName)
    $ErrorActionPreference = 'Stop'
    if ($env:COMPUTERNAME -ne $ExpectedName) { throw 'La identidad del invitado no coincide.' }
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { throw 'No se sella una base unida al dominio.' }
    if ((Get-CimInstance Win32_OperatingSystem).Caption -notmatch 'Windows Server 2025') { throw 'La base debe ser Windows Server 2025.' }
    if (-not (Test-Path 'C:\plantilla-lista.txt')) { throw 'La instalacion inicial no esta verificada.' }
    $interfaces = @(Get-NetAdapter -Physical)
    if ($interfaces.Count -ne 1) { throw 'Se requiere una sola NIC en la base.' }
    # PowerShell Direct no depende de esta red. El clon no heredara la IP fija.
    $interfaceIndex = $interfaces[0].ifIndex
    Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
    Get-NetRoute -InterfaceIndex $interfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
    Set-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -Dhcp Enabled
    Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ResetServerAddresses
    foreach ($file in @('C:\Windows\Panther\Unattend.xml','C:\Windows\Panther\unattend-original.xml','C:\Windows\Panther\Unattend\Unattend.xml','C:\Windows\System32\Sysprep\Unattend.xml')) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
    }
    Remove-Item -LiteralPath 'C:\plantilla-lista.txt' -ErrorAction SilentlyContinue
    # El host esperara el apagado; un Sysprep fallido deja la VM encendida.
    $process = Start-Process 'C:\Windows\System32\Sysprep\Sysprep.exe' -ArgumentList '/generalize /oobe /shutdown /mode:vm' -WindowStyle Hidden -PassThru
    $process.Id
} | Out-Null
$Ansible.Changed = $true
