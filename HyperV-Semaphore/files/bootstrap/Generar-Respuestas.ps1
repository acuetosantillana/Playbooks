[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Windows','Rocky')][string]$Sistema,
    [Parameter(Mandatory)][string]$Configuracion,
    [Parameter(Mandatory)][string]$Salida,
    [Security.SecureString]$AdminPassword,
    [Security.SecureString]$RootPasswordHash,
    [Security.SecureString]$LinuxPasswordHash
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath $Configuracion -Raw | ConvertFrom-Json
$values = @{}
$cfg.PSObject.Properties | ForEach-Object { $values[$_.Name] = $_.Value }
foreach ($key in 'vm_name','vm_ip','vm_mask','vm_gateway','vm_dns1') {
    if ($null -eq $values[$key] -or [string]$values[$key] -eq '') { throw "Falta $key." }
}
if (-not $values.ContainsKey('vm_dns2')) { $values.vm_dns2 = '' }
foreach ($key in 'vm_ip','vm_gateway','vm_dns1','vm_dns2') {
    if ($values[$key]) {
        $address = [Net.IPAddress]::Parse([string]$values[$key])
        if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw "$key debe ser IPv4." }
    }
}
# Acepta prefijo CIDR o mascara decimal contigua, incluso /23 y /22.
$mask = [string]$values.vm_mask
if ($mask -match '^\d{1,2}$') {
    $prefix = [int]$mask
} else {
    $octets = [Net.IPAddress]::Parse($mask).GetAddressBytes()
    if ($octets.Count -ne 4) { throw 'Mascara IPv4 invalida.' }
    $bits = ($octets | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    if ($bits -notmatch '^1*0*$') { throw 'La mascara debe ser contigua.' }
    $prefix = ($bits -replace '0', '').Length
}
if ($prefix -lt 1 -or $prefix -gt 30) { throw 'Usa un prefijo entre 1 y 30 para este laboratorio.' }
$values.vm_mask = $prefix
$binaryMask = ('1' * $prefix).PadRight(32, '0')
$values.vm_netmask = ((0..3 | ForEach-Object { [Convert]::ToInt32($binaryMask.Substring($_ * 8, 8), 2) }) -join '.')
if ($values.vm_name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$') { throw 'Hostname invalido.' }
if ($Sistema -eq 'Windows' -and ($values.vm_name.Length -gt 15 -or $values.vm_name -match '^\d+$')) { throw 'El nombre Windows admite hasta 15 caracteres y no puede ser solo numerico.' }
$outputPath = [IO.Path]::GetFullPath($Salida)
if (Test-Path -LiteralPath $outputPath) { throw 'La carpeta de salida ya existe. Usa una nueva para evitar sobrescrituras.' }

if ($Sistema -eq 'Windows') {
    if (-not $values.vm_image_index -or [int]$values.vm_image_index -lt 1) { throw 'Indica vm_image_index segun el install.wim/install.esd de TU ISO; 0 es solo un marcador.' }
    if (-not $values.rdp_port) { $values.rdp_port = 4502 }
    if ([int]$values.rdp_port -lt 1 -or [int]$values.rdp_port -gt 65535) { throw 'Puerto RDP invalido.' }
    $password = $AdminPassword
    if (-not $password) { throw 'Semaphore debe proporcionar AdminPassword como SecureString.' }
    $values.admin_password = [Net.NetworkCredential]::new('', $password).Password
    if (-not $values.admin_password) { throw 'La contrasena no puede estar vacia.' }
    $text = Get-Content (Join-Path $PSScriptRoot 'fuentes-originales\windows-original.xml.j2') -Raw
    foreach ($key in 'vm_name','vm_image_index','admin_password') {
        $text = $text.Replace('{{ ' + $key + ' }}', [Security.SecurityElement]::Escape([string]$values[$key]))
    }
    [xml]$xml = $text
    $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    if ($values.windows_ui_language -notmatch '^[a-z]{2}-[A-Z]{2}$') { throw 'Indica windows_ui_language segun la ISO (ej. es-ES o en-US).' }
    foreach ($languageNode in $xml.SelectNodes('//u:UILanguage', $ns)) { $languageNode.InnerText = $values.windows_ui_language }
    foreach ($keyboardNode in $xml.SelectNodes('//u:InputLocale', $ns)) { $keyboardNode.InnerText = '080a:0000080a' }
    if (-not $values.windows_admin_user) { throw 'Indica windows_admin_user segun el idioma de la ISO.' }
    $xml.SelectSingleNode('//u:AutoLogon/u:Username', $ns).InnerText = $values.windows_admin_user
    # Una sola secuencia evita carreras entre red, firewall y reinicio de RDP.
    $firstLogon = $xml.SelectSingleNode('//u:FirstLogonCommands', $ns)
    while ($firstLogon.HasChildNodes) { [void]$firstLogon.RemoveChild($firstLogon.FirstChild) }
    $network = @{}
    foreach ($key in 'vm_ip','vm_mask','vm_gateway','vm_dns1','vm_dns2','rdp_port') { $network[$key] = $values[$key] }
    $network64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($network | ConvertTo-Json -Compress)))
    $bootstrap = (Get-Content (Join-Path $PSScriptRoot 'Configurar-Windows.ps1') -Raw).Replace('__NETWORK_BASE64__', $network64)
    $command = $xml.CreateElement('SynchronousCommand', $xml.DocumentElement.NamespaceURI)
    $action = $xml.CreateAttribute('wcm', 'action', 'http://schemas.microsoft.com/WMIConfig/2002/State')
    $action.Value = 'add'
    [void]$command.Attributes.Append($action)
    $bootstrapCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$v = @(Get-Volume -FileSystemLabel HVCONFIG -ErrorAction Stop); if ($v.Count -ne 1 -or -not $v[0].DriveLetter) { throw ''Medio HVCONFIG no disponible'' }; & ($v[0].DriveLetter + '':\Configurar-Windows.ps1'')"'
    foreach ($pair in @(@('Order','1'), @('Description','Configure network and management'), @('CommandLine', $bootstrapCommand))) {
        $node = $xml.CreateElement($pair[0], $xml.DocumentElement.NamespaceURI)
        $node.InnerText = $pair[1]
        [void]$command.AppendChild($node)
    }
    [void]$firstLogon.AppendChild($command)
    # Estas reglas se aplican por nombre estable desde el bootstrap.
    foreach ($node in @($xml.SelectNodes('//u:component[@name="Networking-MPSSVC-Svc"]', $ns))) { [void]$node.ParentNode.RemoveChild($node) }
    $xml.SelectSingleNode('//u:UserAuthentication', $ns).InnerText = '1'
    $xml.SelectSingleNode('//u:CreatePartition[u:Type="EFI"]/u:Size', $ns).InnerText = '260'
    foreach ($node in @($xml.SelectNodes('//u:SkipUserOOBE | //u:SkipMachineOOBE', $ns))) { [void]$node.ParentNode.RemoveChild($node) }
    $rendered = $xml.OuterXml
    $fileName = 'Autounattend.xml'
} else {
    if ($values.linux_user -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw 'linux_user invalido.' }
    foreach ($key in 'root_password_hash','linux_password_hash') {
        $secureHash = $RootPasswordHash
        if ($key -eq 'linux_password_hash') { $secureHash = $LinuxPasswordHash }
        if (-not $secureHash) { throw "Semaphore debe proporcionar $key como SecureString." }
        $values[$key] = [Net.NetworkCredential]::new('', $secureHash).Password
        if ($values[$key] -notmatch '^\$6\$(?:rounds=\d+\$)?[./a-zA-Z0-9]{1,16}\$[./a-zA-Z0-9]{86}$') { throw "Hash SHA-512 crypt invalido: $key." }
    }
    $values.vm_dns_suffix = ''
    if ($values.vm_dns2) { $values.vm_dns_suffix = ',' + $values.vm_dns2 }
    $ksTemplate = 'rocky9.ks.tpl'
    if ($values.solo_base -eq $true) { $ksTemplate = 'rocky9-base.ks.tpl' }
    $rendered = Get-Content (Join-Path $PSScriptRoot $ksTemplate) -Raw
    $rendered = [regex]::Replace($rendered, '\{\{\s*(\w+)\s*\}\}', {
        param($match)
        $key = $match.Groups[1].Value
        if (-not $values.ContainsKey($key)) { throw "Variable sin valor: $key" }
        [string]$values[$key]
    })
    $fileName = 'ks.cfg'
}
if ($rendered -match '\{\{|\{%') { throw 'Quedaron variables sin resolver.' }
New-Item -ItemType Directory -Path $outputPath | Out-Null
[IO.File]::WriteAllText((Join-Path $outputPath $fileName), $rendered.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
if ($Sistema -eq 'Windows') {
    [IO.File]::WriteAllText((Join-Path $outputPath 'Configurar-Windows.ps1'), $bootstrap, [Text.UTF8Encoding]::new($false))
}
Write-Host "Generado: $(Join-Path $outputPath $fileName)"
Write-Host 'Windows incluye la contrasena de instalacion en el XML. Rocky incluye hashes. Retira el medio despues de instalar.'
