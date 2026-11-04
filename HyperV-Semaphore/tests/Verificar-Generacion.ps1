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
$config.vm_mask=24
$config.solo_base=$true
$config.Remove('linux_user')
$config | ConvertTo-Json | Set-Content $json
$baseOutput=Join-Path $testRoot 'rocky-base'
& $generator -Sistema Rocky -Configuracion $json -Salida $baseOutput -RootPasswordHash $hash
$baseKS=Get-Content (Join-Path $baseOutput 'ks.cfg') -Raw
if ($baseKS -match 'docker|nginx|@development' -or $baseKS -notmatch '(?m)^cloud-init$') { throw 'La base Rocky no es minima.' }
if ($baseKS -match '(?m)^user\s' -or $baseKS -match 'linux_password_hash|linux_user') { throw 'La base no debe crear usuarios adicionales.' }
$config.linux_user='adm'
$config | ConvertTo-Json | Set-Content $json
$personalizer=Join-Path $root 'files\bootstrap\Personalizar-Clon.ps1'
foreach ($system in @('Windows','Rocky')) {
    $cloneRoot=Join-Path $testRoot ('clone-'+$system)
    New-Item -ItemType Directory -Path (Join-Path $cloneRoot 'Provisioning') | Out-Null
    $identity=[guid]::NewGuid().ToString()
    @{name=$config.vm_name;system=$system;instance_id=$identity;template='test-base-v1';mac='020102030405';disk='NO-SE-MONTA.vhdx'} | ConvertTo-Json | Set-Content (Join-Path $cloneRoot 'deployment.json')
    & $personalizer -Root $cloneRoot -RequestFile $json -AdminPassword $password -RootHash $hash -UserHash $hash -RenderOnly
    if (Test-Path (Join-Path $cloneRoot 'Provisioning\personalized.txt')) { throw 'Una vista previa no debe habilitar el arranque.' }
    if ($system -eq 'Windows') {
        [xml]$cloneXML=Get-Content (Join-Path $cloneRoot 'Provisioning\preview\Unattend.xml') -Raw
        $cloneNs=[Xml.XmlNamespaceManager]::new($cloneXML.NameTable)
        $cloneNs.AddNamespace('u','urn:schemas-microsoft-com:unattend')
        if ($cloneXML.SelectSingleNode('//u:ComputerName',$cloneNs).InnerText -ne $config.vm_name) { throw 'Hostname Windows del clon incorrecto.' }
        if ($cloneXML.SelectSingleNode('//u:AdministratorPassword/u:Value',$cloneNs).InnerText -ne 'Prueba<&>''9!SoloFicticia') { throw 'Contrasena XML del clon mal escapada.' }
        if ($cloneXML.SelectNodes('//u:settings[@pass="windowsPE"]',$cloneNs).Count -ne 0) { throw 'El clon no debe ejecutar Windows Setup desde ISO.' }
    } else {
        $seedRoot=Join-Path $cloneRoot 'Provisioning\seed'
        $metadata=Get-Content (Join-Path $seedRoot 'meta-data') -Raw | ConvertFrom-Json
        $userData=((Get-Content (Join-Path $seedRoot 'user-data') -Raw) -replace '^#cloud-config\s*','') | ConvertFrom-Json
        $network=Get-Content (Join-Path $seedRoot 'network-config') -Raw | ConvertFrom-Json
        if ($metadata.'instance-id' -ne $identity -or $network.config[0].mac_address -ne '02:01:02:03:04:05' -or $network.config[0].subnets[0].address -ne '192.0.2.20/24') { throw 'Identidad/red de cloud-init incorrectas.' }
        if ($userData.users[0].hashed_passwd -notlike '$6$*' -or $userData.users[0].PSObject.Properties.Name -contains 'passwd' -or $userData.users[0].name -ne 'adm') { throw 'Se requiere hashed_passwd para reemplazar la contrasena del usuario preexistente.' }
    }
}
'OK: sintaxis PowerShell, XML escapado, idioma, administrador, secuencia unica, red /23, hashes y rechazo de mascara invalida.'
'OK: base minima y personalizacion de clones Windows/Rocky sin arrancar ni montar discos.'
