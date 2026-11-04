# Prueba de integracion con montaje y Oscdimg simulados; no monta ISO reales.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('hyperv-autoboot-'+[guid]::NewGuid().ToString('N'))
$fixture=Join-Path $testRoot 'fixture'
$global:hvAutoTestState=@{MockDriveRoot=[IO.Path]::GetPathRoot($testRoot);Fixture=$fixture;AlreadyMounted=$false;MountCount=0;DismountCount=0;FakeExitCode=0}
New-Item -ItemType Directory -Path (Join-Path $fixture 'sources'),(Join-Path $testRoot 'ADK with spaces') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $fixture 'setup.exe') -Value 'TEST FIXTURE, NO EJECUTAR'
Set-Content -LiteralPath (Join-Path $fixture 'sources\boot.wim') -Value 'TEST FIXTURE'
$bootFile=Join-Path $testRoot 'ADK with spaces\efisys_noprompt.bin'
Set-Content -LiteralPath $bootFile -Value 'TEST BOOT IMAGE'
$fakeOscdimg=Join-Path $testRoot 'fake-oscdimg.ps1'
@'
$args | ConvertTo-Json | Set-Content -LiteralPath ($args[-1]+'.args.json')
Set-Content -LiteralPath $args[-1] -Value 'TEST GENERATED ISO'
$global:LASTEXITCODE=$global:hvAutoTestState.FakeExitCode
'@ | Set-Content -LiteralPath $fakeOscdimg
function Get-DiskImage { param($ImagePath) [pscustomobject]@{Attached=$global:hvAutoTestState.AlreadyMounted;ImagePath=$ImagePath} }
function Mount-DiskImage { param($ImagePath,$StorageType,$Access,[switch]$PassThru) $global:hvAutoTestState.MountCount++; [pscustomobject]@{Attached=$true;ImagePath=$ImagePath} }
function Dismount-DiskImage { param($ImagePath) $global:hvAutoTestState.DismountCount++ }
function Get-Volume { param([Parameter(ValueFromPipeline)]$InputObject) process { [pscustomobject]@{DriveLetter=$global:hvAutoTestState.MockDriveRoot.Substring(0,1)} } }
function Start-Process {
    param($FilePath,$ArgumentList,[switch]$NoNewWindow,[switch]$Wait,[switch]$PassThru,$RedirectStandardOutput,$RedirectStandardError)
    if (-not $Wait -or -not $PassThru -or -not $RedirectStandardOutput -or -not $RedirectStandardError) { throw 'Falta esperar el proceso y aislar sus dos salidas.' }
    $decoded=@($ArgumentList | ForEach-Object { $_.Substring(1,$_.Length-2) })
    $embedded=Join-Path $decoded[-2] 'Autounattend.xml'
    $global:hvAutoTestState.EmbeddedAnswer=if (Test-Path -LiteralPath $embedded) { Get-Content -LiteralPath $embedded -Raw } else { '' }
    $decoded | ConvertTo-Json | Set-Content -LiteralPath ($decoded[-1]+'.args.json')
    Set-Content -LiteralPath $decoded[-1] -Value 'TEST GENERATED ISO'
    Set-Content -LiteralPath $RedirectStandardOutput -Value 'TEST STDOUT'
    Set-Content -LiteralPath $RedirectStandardError -Value 'TEST STDERR PROGRESS'
    [pscustomobject]@{ExitCode=$global:hvAutoTestState.FakeExitCode}
}
function Test-Path {
    [CmdletBinding()]param([string]$LiteralPath,[string]$Path,[string]$PathType)
    if ($LiteralPath -in @(($global:hvAutoTestState.MockDriveRoot+'sources\boot.wim'),($global:hvAutoTestState.MockDriveRoot+'setup.exe'))) { return $true }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-ChildItem {
    [CmdletBinding()]param([string]$LiteralPath,[switch]$Force)
    if ($LiteralPath -eq $global:hvAutoTestState.MockDriveRoot) { return Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $global:hvAutoTestState.Fixture -Force }
    Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
}
$builder=Join-Path $projectRoot 'scripts\Crear-ISOWindowsSinTecla.ps1'
function Invoke-FixtureBuild {
    param([string]$Case,[bool]$AlreadyMounted=$false,[int]$ExitCode=0,[string]$Boot=$bootFile,[switch]$WithAnswers)
    $global:hvAutoTestState.AlreadyMounted=$AlreadyMounted
    $global:hvAutoTestState.MountCount=0
    $global:hvAutoTestState.DismountCount=0
    $global:hvAutoTestState.FakeExitCode=$ExitCode
    $script:Ansible=[pscustomobject]@{Changed=$false;Result=$null}
    $caseRoot=Join-Path (Join-Path $testRoot 'SemaphoreVMs') ('TPL-'+$Case)
    New-Item -ItemType Directory -Path (Join-Path $caseRoot 'Media'),(Join-Path $caseRoot 'Provisioning') -Force | Out-Null
    $original=Join-Path $caseRoot 'Media\os.iso'
    Set-Content -LiteralPath $original -Value 'ORIGINAL ISO FIXTURE'
    $originalHash=(Get-FileHash -LiteralPath $original).Hash
    $extra=@{}
    if ($WithAnswers) {
        $answerDir=Join-Path $caseRoot 'Provisioning\answers'
        New-Item -ItemType Directory -Path $answerDir | Out-Null
        Set-Content -LiteralPath (Join-Path $answerDir 'Autounattend.xml') -Value '<unattend>TEST ONLY</unattend>'
        $extra.AnswersPath=$answerDir
    }
    & $builder -Root $caseRoot -VmName ('TPL-'+$Case) -CsvVolumes @($testRoot) -OscdimgPath $fakeOscdimg -NoPromptBootFile $Boot @extra
    if ($WithAnswers) {
        if ($global:hvAutoTestState.EmbeddedAnswer.Trim() -ne '<unattend>TEST ONLY</unattend>' -or -not $script:Ansible.Result.embedded_autounattend) { throw 'El medio de arranque no recibio Autounattend.xml en su raiz.' }
        if (-not (Get-Acl -LiteralPath (Join-Path $caseRoot 'Media')).AreAccessRulesProtected) { throw 'La ISO con respuestas hereda permisos generales.' }
    }
    $recorded=Get-Content -LiteralPath (Join-Path $caseRoot 'Media\os-uefi-auto.iso.partial.args.json') -Raw | ConvertFrom-Json
    if (('-bootdata:1#pEF,e,b'+$Boot) -notin $recorded -or '-u2' -notin $recorded) { throw 'No se selecciono la imagen UEFI sin prompt.' }
    if ((Get-FileHash -LiteralPath $original).Hash -ne $originalHash) { throw 'Se modifico la ISO original.' }
    if (-not $script:Ansible.Result.uefi_no_prompt -or -not (Test-Path -LiteralPath $script:Ansible.Result.iso)) { throw 'Falta resultado de reconstruccion.' }
    if (Test-Path -LiteralPath (Join-Path $caseRoot 'Provisioning\windows-media')) { throw 'Quedo el arbol temporal tras un resultado correcto.' }
}
Invoke-FixtureBuild -Case Normal
if ($global:hvAutoTestState.MountCount -ne 1 -or $global:hvAutoTestState.DismountCount -ne 1) { throw 'No se libero el montaje propio.' }
Invoke-FixtureBuild -Case PreMounted -AlreadyMounted $true
if ($global:hvAutoTestState.MountCount -ne 0 -or $global:hvAutoTestState.DismountCount -ne 0) { throw 'Se altero un montaje ajeno.' }
Invoke-FixtureBuild -Case Embedded -WithAnswers
$missingRejected=$false
try { Invoke-FixtureBuild -Case Missing -Boot (Join-Path $testRoot 'missing\efisys_noprompt.bin') } catch { $missingRejected=$_.Exception.Message -match 'no existe' }
if (-not $missingRejected -or $global:hvAutoTestState.DismountCount -ne 1) { throw 'Archivo ausente no produce error con liberacion de montaje.' }
$failureRejected=$false
try { Invoke-FixtureBuild -Case Failure -ExitCode 5 } catch { $failureRejected=$_.Exception.Message -match 'codigo 5' -and $_.Exception.Message -match 'TEST STDERR PROGRESS' }
if (-not $failureRejected -or $global:hvAutoTestState.DismountCount -ne 1) { throw 'Oscdimg fallido no interrumpe de forma correcta.' }
# El codigo 5 anterior es un fallo simulado que ya fue comprobado. GitHub propaga
# LASTEXITCODE aunque PowerShell haya capturado correctamente la excepcion.
$global:LASTEXITCODE=0
# Regresion con proceso nativo real: stderr no debe terminar PowerShell, pero
# un codigo no cero debe seguir siendo visible bajo ErrorActionPreference Stop.
$nativeFixture=Join-Path $testRoot 'native-stderr.ps1'
@'
param([int]$Code)
[Console]::Error.WriteLine('native progress on stderr')
exit $Code
'@ | Set-Content -LiteralPath $nativeFixture
$nativeShell=Join-Path $PSHOME 'powershell.exe'
if (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $nativeShell)) { $nativeShell=Join-Path $PSHOME 'pwsh.exe' }
foreach ($code in @(0,5)) {
    $nativeOut=Join-Path $testRoot "native-$code.out"
    $nativeErr=Join-Path $testRoot "native-$code.err"
    $nativeProcess=Microsoft.PowerShell.Management\Start-Process -FilePath $nativeShell -ArgumentList @('-NoProfile','-File',('"'+$nativeFixture+'"'),'-Code',"$code") -NoNewWindow -Wait -PassThru -RedirectStandardOutput $nativeOut -RedirectStandardError $nativeErr
    if ($nativeProcess.ExitCode -ne $code -or (Get-Content -LiteralPath $nativeErr -Raw) -notmatch 'native progress') { throw 'La captura nativa no conservo stderr y codigo de salida.' }
}
'OK: ISO UEFI sin tecla, ruta con espacios, fuente conservada, montajes propios/ajenos y fallos de dependencia/Oscdimg.'
