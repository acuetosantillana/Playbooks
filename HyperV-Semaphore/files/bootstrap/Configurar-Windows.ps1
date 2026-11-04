# Se ejecuta dentro del invitado desde el medio HVCONFIG, no en el host.
$ErrorActionPreference = 'Stop'
$networkJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__NETWORK_BASE64__'))
$config = $networkJson | ConvertFrom-Json
Start-Transcript -Path 'C:\netcfg.log' -Append | Out-Null
try {
    $adapters = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')
    if ($adapters.Count -ne 1) { throw 'Se requiere exactamente un adaptador conectado durante la instalacion.' }
    $index = $adapters[0].ifIndex
    Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
    Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -ne $config.vm_ip | Remove-NetIPAddress -Confirm:$false
    Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object NextHop -ne $config.vm_gateway | Remove-NetRoute -Confirm:$false
    $existing = Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -eq $config.vm_ip
    if ($existing) {
        Set-NetIPAddress -InterfaceIndex $index -IPAddress $config.vm_ip -PrefixLength $config.vm_mask
        if (-not (Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object NextHop -eq $config.vm_gateway)) {
            New-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -NextHop $config.vm_gateway | Out-Null
        }
    } else {
        New-NetIPAddress -InterfaceIndex $index -IPAddress $config.vm_ip -PrefixLength $config.vm_mask -DefaultGateway $config.vm_gateway | Out-Null
    }
    $dns = @($config.vm_dns1, $config.vm_dns2) | Where-Object { $_ }
    Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $dns
    New-NetFirewallRule -Name 'Lab-ICMPv4' -DisplayName 'Lab ICMPv4' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Any | Out-Null
    # Se conserva el puerto solicitado y se habilita NLA.
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
    $rdpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    Set-ItemProperty $rdpKey -Name UserAuthentication -Value 1
    Set-ItemProperty $rdpKey -Name PortNumber -Value $config.rdp_port
    New-NetFirewallRule -Name 'Lab-RDP' -DisplayName 'Lab RDP' -Direction Inbound -Protocol TCP -LocalPort $config.rdp_port -Action Allow -Profile Any | Out-Null
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    # WinRM con autenticacion integrada; no habilitar Basic ni AllowUnencrypted.
    Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
    # El autologon se usa una vez para la configuracion y luego se deshabilita.
    $logonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $logonKey -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty $logonKey -Name DefaultPassword -ErrorAction SilentlyContinue
    Restart-Service TermService -Force
    'CONFIGURACION_COMPLETA' | Set-Content 'C:\plantilla-lista.txt'
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
