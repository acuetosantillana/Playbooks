param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$AdminUser,
    [Parameter(Mandatory)][Security.SecureString]$AdminPassword,
    [int]$TimeoutMinutes=20
)
# Configura la red del clon Windows desde el host por PowerShell Direct.
# No depende de la red del invitado ni de que el script de specialize termine.
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
Import-Module Hyper-V
Import-Module FailoverClusters
$manifest=Get-Content -LiteralPath (Join-Path $Root 'deployment.json') -Raw | ConvertFrom-Json
$cfg=Get-Content -LiteralPath (Join-Path $Root 'Provisioning\vm.json') -Raw | ConvertFrom-Json
if ($cfg.vm_name -ne $manifest.name) { throw 'La solicitud no coincide con la VM creada.' }
$group=Get-ClusterGroup -Name $manifest.name -ErrorAction Stop
if ($group.OwnerNode.Name -ne $env:COMPUTERNAME) { throw ('La VM pertenece al nodo {0}; ejecutar la tarea en ese nodo.' -f $group.OwnerNode.Name) }
$vm=Get-VM -Id ([guid]$manifest.vm_id)
if ($vm.State -ne 'Running') { throw 'La VM no esta encendida.' }
$instanceJson=(@{instance_id=$manifest.instance_id;vm_name=$manifest.name;template=$manifest.template} | ConvertTo-Json -Compress)
$cred=[pscredential]::new($AdminUser,$AdminPassword)
$deadline=[DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$session=$null
$lastError=''
# El invitado acepta PowerShell Direct cuando specialize/oobe terminaron y la
# contrasena del unattend quedo aplicada; esperar a que este listo.
while (-not $session) {
    try { $session=New-PSSession -VMId $vm.Id -Credential $cred -ErrorAction Stop }
    catch {
        $lastError=$_.Exception.Message
        if ([DateTime]::UtcNow -ge $deadline) { throw ('El invitado no acepto PowerShell Direct en {0} min. Ultimo error: {1}' -f $TimeoutMinutes,$lastError) }
        Start-Sleep -Seconds 15
    }
}
try {
    $result=Invoke-Command -Session $session -ScriptBlock {
        param($ip,$prefix,$gateway,$dns,$rdpPort,$instanceJson)
        $ErrorActionPreference='Stop'
        $log=@()
        $adapters=@(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')
        if ($adapters.Count -eq 0) { $adapters=@(Get-NetAdapter -Physical) }
        if ($adapters.Count -ne 1) { throw ('Se requiere exactamente un adaptador; detectados: {0}.' -f $adapters.Count) }
        $index=$adapters[0].ifIndex
        Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
        Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne $ip -and $_.PrefixOrigin -ne 'WellKnown' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object NextHop -ne $gateway | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        $existing=Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $ip
        if ($existing) {
            if ($existing.PrefixLength -ne $prefix) { Set-NetIPAddress -InterfaceIndex $index -IPAddress $ip -PrefixLength $prefix }
            if (-not (Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object NextHop -eq $gateway)) {
                New-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -NextHop $gateway | Out-Null
            }
            $log+='La IP ya estaba presente; se verifico prefijo y gateway.'
        } else {
            New-NetIPAddress -InterfaceIndex $index -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gateway | Out-Null
            $log+='IP asignada.'
        }
        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $dns
        # Esperar la deteccion de direcciones duplicadas antes de dar por buena la IP.
        $state=$null
        for ($i=0; $i -lt 15; $i++) {
            $state=Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 | Where-Object IPAddress -eq $ip
            if ($state -and $state.AddressState -eq 'Preferred') { break }
            Start-Sleep -Seconds 2
        }
        if (-not $state) { throw 'La IP no quedo registrada en el adaptador.' }
        if ($state.AddressState -eq 'Duplicate') { throw ('La IP {0} esta duplicada: otro equipo de la red ya la usa.' -f $ip) }
        if ($state.AddressState -ne 'Preferred') { throw ('La IP quedo en estado {0}; revisar la red.' -f $state.AddressState) }
        if (Get-NetFirewallRule -Name 'Lab-ICMPv4' -ErrorAction SilentlyContinue) {
            Set-NetFirewallRule -Name 'Lab-ICMPv4' -Enabled True -Action Allow -Profile Any
        } else {
            New-NetFirewallRule -Name 'Lab-ICMPv4' -DisplayName 'Lab ICMPv4' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Any | Out-Null
        }
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        $rdpKey='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        Set-ItemProperty $rdpKey -Name UserAuthentication -Value 1
        if ($rdpPort) { Set-ItemProperty $rdpKey -Name PortNumber -Value $rdpPort }
        if (Get-NetFirewallRule -Name 'Lab-RDP' -ErrorAction SilentlyContinue) {
            Set-NetFirewallRule -Name 'Lab-RDP' -Enabled True -Action Allow -Profile Any
            if ($rdpPort) { Get-NetFirewallRule -Name 'Lab-RDP' | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -LocalPort $rdpPort }
        } elseif ($rdpPort) {
            New-NetFirewallRule -Name 'Lab-RDP' -DisplayName 'Lab RDP' -Direction Inbound -Protocol TCP -LocalPort $rdpPort -Action Allow -Profile Any | Out-Null
        }
        Enable-PSRemoting -Force -SkipNetworkProfileCheck
        Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false
        Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
        # Permitir WinRM desde fuera de la subred local aunque el perfil sea publico.
        Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue |
            Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress Any
        Restart-Service TermService -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path 'C:\ProgramData\Semaphore' -Force | Out-Null
        if (-not (Test-Path -LiteralPath 'C:\ProgramData\Semaphore\instance.json')) {
            $instanceJson | Set-Content -LiteralPath 'C:\ProgramData\Semaphore\instance.json' -Encoding UTF8
            $log+='instance.json escrito.'
        }
        @{log=$log;computer=$env:COMPUTERNAME;ip=$state.IPAddress;prefix=$state.PrefixLength;address_state=[string]$state.AddressState}
    } -ArgumentList $cfg.vm_ip,[int]$cfg.vm_mask,$cfg.vm_gateway,@(@($cfg.vm_dns1,$cfg.vm_dns2) | Where-Object {$_}),$cfg.rdp_port,$instanceJson
} finally { Remove-PSSession -Session $session }
$Ansible.Changed=$true
$Ansible.Result=@{name=$manifest.name;ip=$result.ip;prefix=$result.prefix;address_state=$result.address_state;guest=$result.computer;log=@($result.log)}
