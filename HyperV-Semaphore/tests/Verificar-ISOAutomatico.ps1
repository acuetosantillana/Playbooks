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
    param([string]$Case,[bool]$AlreadyMounted=$false,[int]$ExitCode=0,[string]$Boot=$bootFile)
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
    & $builder -Root $caseRoot -VmName ('TPL-'+$Case) -CsvVolumes @($testRoot) -OscdimgPath $fakeOscdimg -NoPromptBootFile $Boot
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
$missingRejected=$false
try { Invoke-FixtureBuild -Case Missing -Boot (Join-Path $testRoot 'missing\efisys_noprompt.bin') } catch { $missingRejected=$_.Exception.Message -match 'no existe' }
if (-not $missingRejected -or $global:hvAutoTestState.DismountCount -ne 1) { throw 'Archivo ausente no produce error con liberacion de montaje.' }
$failureRejected=$false
try { Invoke-FixtureBuild -Case Failure -ExitCode 5 } catch { $failureRejected=$_.Exception.Message -match 'codigo 5' }
if (-not $failureRejected -or $global:hvAutoTestState.DismountCount -ne 1) { throw 'Oscdimg fallido no interrumpe de forma correcta.' }
'OK: ISO UEFI sin tecla, ruta con espacios, fuente conservada, montajes propios/ajenos y fallos de dependencia/Oscdimg.'
