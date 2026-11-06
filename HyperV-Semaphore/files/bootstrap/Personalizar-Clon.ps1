param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$RequestFile,
    [Security.SecureString]$AdminPassword,
    [Security.SecureString]$RootHash,
    [Security.SecureString]$UserHash,
    [string]$OscdimgPath,
    [switch]$RenderOnly
)
$ErrorActionPreference='Stop'
$manifest=Get-Content -LiteralPath (Join-Path $Root 'deployment.json') -Raw | ConvertFrom-Json
$cfg=Get-Content -LiteralPath $RequestFile -Raw | ConvertFrom-Json
if ($cfg.vm_name -ne $manifest.name) { throw 'La solicitud no coincide con la VM creada.' }
foreach ($key in @('vm_ip','vm_gateway','vm_dns1','vm_dns2')) {
    if ($cfg.$key) {
        if ([Net.IPAddress]::Parse($cfg.$key).AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw "$key debe ser IPv4." }
    }
}
$prefix=[int]$cfg.vm_mask
if ($prefix -lt 1 -or $prefix -gt 30) { throw 'Se requiere prefijo CIDR numerico entre 1 y 30.' }
$dns=@($cfg.vm_dns1,$cfg.vm_dns2 | Where-Object {$_})
$utf8=[Text.UTF8Encoding]::new($false)
$instance=@{instance_id=$manifest.instance_id;vm_name=$manifest.name;template=$manifest.template}
if ($manifest.system -eq 'Windows') {
    if (-not $AdminPassword) { throw 'Falta la contrasena para el clon Windows.' }
    $password=[Security.SecurityElement]::Escape([Net.NetworkCredential]::new('',$AdminPassword).Password)
    $name=[Security.SecurityElement]::Escape($cfg.vm_name)
    $network=@{vm_ip=$cfg.vm_ip;vm_mask=$prefix;vm_gateway=$cfg.vm_gateway;vm_dns1=$cfg.vm_dns1;vm_dns2=$cfg.vm_dns2;rdp_port=$cfg.rdp_port}
    $network64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($network | ConvertTo-Json -Compress)))
    $bootstrap=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Configurar-Windows.ps1') -Raw).Replace('__NETWORK_BASE64__',$network64)
    $instance64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($instance | ConvertTo-Json -Compress)))
    $bootstrap+="`n[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$instance64')) | Set-Content -LiteralPath 'C:\ProgramData\Semaphore\instance.json' -Encoding UTF8`n"
    $xml=@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ComputerName>$name</ComputerName><TimeZone>Central Standard Time (Mexico)</TimeZone></component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\Semaphore\Customize.ps1</Path></RunSynchronousCommand></RunSynchronous></component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><InputLocale>es-MX</InputLocale><SystemLocale>es-MX</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>es-MX</UserLocale></component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts><AdministratorPassword><Value>$password</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
    </component>
  </settings>
</unattend>
"@
    $null=[xml]$xml
    if ($RenderOnly) {
        $preview=Join-Path $Root 'Provisioning\preview'
        New-Item -ItemType Directory -Path $preview -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllText((Join-Path $preview 'Unattend.xml'),$xml,$utf8)
        [IO.File]::WriteAllText((Join-Path $preview 'Customize.ps1'),$bootstrap,$utf8)
        return
    }
    Import-Module Hyper-V
    $mounted=$false
    try {
        $mountedDisk=Mount-VHD -Path $manifest.disk -Passthru
        $mounted=$true
        $candidates=@(Get-Disk -Number $mountedDisk.DiskNumber | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path -LiteralPath ($_.DriveLetter+':\Windows\System32\config\SYSTEM')) })
        if ($candidates.Count -ne 1) { throw 'No se encontro un unico volumen Windows en la copia.' }
        $drive=$candidates[0].DriveLetter+':\'
        $guestFolder=Join-Path $drive 'ProgramData\Semaphore'
        New-Item -ItemType Directory -Path $guestFolder -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $guestFolder 'Customize.ps1'),$bootstrap,$utf8)
        # La identidad se escribe offline: la verificacion no depende de que Customize.ps1 termine sin errores.
        [IO.File]::WriteAllText((Join-Path $guestFolder 'instance.json'),($instance | ConvertTo-Json -Compress),$utf8)
        # Panther es cache de Setup y el primer arranque tras sysprep puede ignorarlo.
        # Limpiar cualquier cache y escribir en las ubicaciones que Setup si consulta.
        $panther=Join-Path $drive 'Windows\Panther'
        Remove-Item -LiteralPath (Join-Path $panther 'Unattend.xml') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $panther 'Unattend') -Recurse -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText((Join-Path $drive 'Windows\System32\Sysprep\Unattend.xml'),$xml,$utf8)
        [IO.File]::WriteAllText((Join-Path $drive 'Unattend.xml'),$xml,$utf8)
    } finally { if ($mounted) { Dismount-VHD -Path $manifest.disk } }
} else {
    if (-not $RootHash -or -not $UserHash) { throw 'Faltan hashes de contrasena para Rocky.' }
    if ($cfg.linux_user -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw 'Usuario Rocky invalido.' }
    $seed=Join-Path (Join-Path $Root 'Provisioning') 'seed'
    New-Item -ItemType Directory -Path $seed -ErrorAction Stop | Out-Null
    $rootPassword=[Net.NetworkCredential]::new('',$RootHash).Password
    $userPassword=[Net.NetworkCredential]::new('',$UserHash).Password
    foreach ($hash in @($rootPassword,$userPassword)) { if ($hash -notmatch '^\$6\$') { throw 'Se requieren hashes SHA512 crypt.' } }
    $cloud=@{
        hostname=$cfg.vm_name; manage_etc_hosts=$true; ssh_pwauth=$true; disable_root=$true;
        users=@(@{name=$cfg.linux_user;groups='wheel';sudo='ALL=(ALL) ALL';lock_passwd=$false;hashed_passwd=$userPassword;shell='/bin/bash'});
        # Respaldo de red: en Hyper-V la NIC sintetica puede registrarse despues de
        # init-local y cloud-init deja la interfaz sin configurar; al final del
        # arranque la NIC ya existe y nmcli aplica la IP si sigue ausente.
        runcmd=@(
            ,@('sh','-c',('getent group docker >/dev/null 2>&1 && usermod -aG docker '+$cfg.linux_user+' || true'))
            ,@('sh','-c',('ip -4 addr show dev eth0 2>/dev/null | grep -qw '+$cfg.vm_ip+' || (nmcli connection add type ethernet ifname eth0 con-name semaphore-net ipv4.method manual ipv4.addresses '+$cfg.vm_ip+'/'+$prefix+' ipv4.gateway '+$cfg.vm_gateway+' ipv4.dns "'+(($dns) -join ' ')+'" connection.autoconnect yes && nmcli connection up semaphore-net)'))
        );
        chpasswd=@{expire=$false;users=@(@{name='root';password=$rootPassword;type='hash'})};
        write_files=@(@{path='/etc/semaphore-instance.json';permissions='0644';content=($instance | ConvertTo-Json -Compress)});
        final_message='Semaphore clone initialization finished'
    }
    $mac=([regex]::Matches($manifest.mac,'..') | ForEach-Object Value) -join ':'
    $network=@{version=1;config=@(@{type='physical';name='eth0';mac_address=$mac;subnets=@(@{type='static';address=($cfg.vm_ip+'/'+$prefix);gateway=$cfg.vm_gateway;dns_nameservers=$dns})})}
    [IO.File]::WriteAllText((Join-Path $seed 'meta-data'),(@{'instance-id'=$manifest.instance_id;'local-hostname'=$cfg.vm_name} | ConvertTo-Json),$utf8)
    [IO.File]::WriteAllText((Join-Path $seed 'user-data'),("#cloud-config`n"+($cloud | ConvertTo-Json -Depth 10)),$utf8)
    [IO.File]::WriteAllText((Join-Path $seed 'network-config'),($network | ConvertTo-Json -Depth 10),$utf8)
    if ($RenderOnly) { return }
    $seedIso=Join-Path $Root 'Media\answers.iso'
    # Oscdimg escribe progreso en stderr incluso al terminar bien; redirigir a
    # archivos evita NativeCommandError con WinRM/error_action=stop.
    $stdout=Join-Path $Root 'Media\oscdimg-seed.stdout.log'
    $stderr=Join-Path $Root 'Media\oscdimg-seed.stderr.log'
    $arguments=@('-n','-m','-lCIDATA',('"'+$seed+'"'),('"'+$seedIso+'"'))
    $process=Start-Process -FilePath $OscdimgPath -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0) {
        $details=@(Get-Content -LiteralPath $stdout,$stderr -ErrorAction SilentlyContinue | Select-Object -Last 20) -join [Environment]::NewLine
        throw "Oscdimg fallo con codigo $($process.ExitCode) al crear el medio cloud-init. $details"
    }
    if (-not (Test-Path -LiteralPath $seedIso -PathType Leaf) -or (Get-Item -LiteralPath $seedIso).Length -eq 0) { throw 'No se pudo crear el medio cloud-init.' }
    $acl=Get-Acl -LiteralPath $seedIso
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow')) }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-83-0'),'ReadAndExecute','Allow'))
    Set-Acl -LiteralPath $seedIso -AclObject $acl
    Import-Module Hyper-V
    Add-VMDvdDrive -VMName $manifest.name -Path $seedIso | Out-Null
}
# Arranque solo permitido despues de terminar esta personalizacion.
[IO.File]::WriteAllText((Join-Path $Root 'Provisioning\personalized.txt'),$manifest.instance_id,$utf8)
