$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('hyperv-validation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse) {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors) { throw "Sintaxis PowerShell invalida: $($file.Name): $parseErrors" }
}
$config = @{ vm_name='TEST-WS25'; vm_image_index=2; vm_ip='192.0.2.20'; vm_mask='255.255.254.0'; vm_gateway='192.0.2.1'; vm_dns1='192.0.2.10'; vm_dns2=''; rdp_port=4502; windows_ui_language='es-ES'; windows_admin_user='Administrador'; linux_user='adm' }
$json = Join-Path $testRoot 'vm.json'
$config | ConvertTo-Json | Set-Content $json
$generator = Join-Path $root 'files\bootstrap\Generar-Respuestas.ps1'
$password = ConvertTo-SecureString 'Prueba<&>''9!SoloFicticia' -AsPlainText -Force
$windows = Join-Path $testRoot 'windows'
& $generator -Sistema Windows -Configuracion $json -Salida $windows -AdminPassword $password
[xml]$xml = Get-Content -LiteralPath (Join-Path $windows 'Autounattend.xml') -Raw
$ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
$ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
if ($xml.SelectNodes('//u:FirstLogonCommands/u:SynchronousCommand',$ns).Count -ne 1) { throw 'Secuencia Windows duplicada.' }
if ($xml.SelectSingleNode('//u:CommandLine',$ns).InnerText.Length -gt 1024) { throw 'CommandLine excede longitud admitida.' }
if ($xml.SelectSingleNode('//u:AdministratorPassword/u:Value',$ns).InnerText -ne 'Prueba<&>''9!SoloFicticia') { throw 'Escape de XML invalido.' }
if ($xml.SelectSingleNode('//u:AutoLogon/u:Username',$ns).InnerText -ne 'Administrador') { throw 'Administrador localizado incorrecto.' }
if ($xml.SelectSingleNode('//u:UILanguage',$ns).InnerText -ne 'es-ES') { throw 'Idioma no coincide.' }
$scriptText = Get-Content (Join-Path $windows 'Configurar-Windows.ps1') -Raw
$encoded = [regex]::Match($scriptText,"FromBase64String\('([^']+)'\)").Groups[1].Value
$network = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
if ($network.vm_mask -ne 23 -or $network.vm_dns2 -ne '') { throw 'Parametros de red incorrectos.' }
$hash = ConvertTo-SecureString ('$6$test$' + ('A' * 86)) -AsPlainText -Force
$rocky = Join-Path $testRoot 'rocky'
& $generator -Sistema Rocky -Configuracion $json -Salida $rocky -RootPasswordHash $hash -LinuxPasswordHash $hash
$ks = Get-Content (Join-Path $rocky 'ks.cfg') -Raw
if ($ks -match '\{\{|\{%|--plaintext' -or $ks -notmatch '--netmask=255.255.254.0' -or $ks -notmatch '/etc/semaphore-provisioning-complete') { throw 'Generacion Kickstart incorrecta.' }
$config.vm_mask='255.0.255.0'
$config | ConvertTo-Json | Set-Content $json
$rejected=$false
try { & $generator -Sistema Windows -Configuracion $json -Salida (Join-Path $testRoot 'invalid') -AdminPassword $password } catch { $rejected=$_.Exception.Message -match 'contigua' }
if (-not $rejected) { throw 'No se rechazo la mascara invalida.' }
'OK: sintaxis PowerShell, XML escapado, idioma, administrador, secuencia unica, red /23, hashes y rechazo de mascara invalida.'
