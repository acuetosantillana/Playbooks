$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('hyperv-lock-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$global:hvRecoveryTest=@{Root=$testRoot;HasVM=$false}
function Import-Module { param($Name) }
function Get-ClusterSharedVolume { [pscustomobject]@{State='Online';SharedVolumeInfo=[pscustomobject]@{FriendlyVolumeName=$global:hvRecoveryTest.Root}} }
function Get-VM { param($ComputerName) if ($global:hvRecoveryTest.HasVM) { [pscustomobject]@{Name='TPL-TEST'} } }
function Get-ClusterGroup { @() }
function Test-Connection { param($ComputerName,$Count,[switch]$Quiet,$ErrorAction) $false }
function Get-Process { param($Name,$ErrorAction) @() }
function Get-DiskImage { param($ImagePath,$ErrorAction) [pscustomobject]@{Attached=$false} }
$recovery=Join-Path $projectRoot 'scripts\Archivar-BloqueoFallido.ps1'
$timestamp='2026-11-04T01:26:25.8453407Z'
function New-LockFixture {
    param($Name)
    $library=Join-Path $testRoot $Name
    $lock=Join-Path $library '.locks\192.0.2.5'
    New-Item -ItemType Directory -Path $lock -Force | Out-Null
    @{vm='TPL-TEST';ip='192.0.2.5';created=$timestamp;token='test-only-token'} | ConvertTo-Json | Set-Content (Join-Path $lock 'owner.json')
    $library
}
$library=New-LockFixture 'valid'
$Ansible=[pscustomobject]@{Changed=$false;Result=$null}
& $recovery -Library $library -CsvVolumes @($testRoot) -ClusterNodes @('TEST') -VmName TPL-TEST -IPAddress 192.0.2.5 -ExpectedCreated $timestamp -FailedTaskId 1
if (-not $Ansible.Result.ready_to_retry -or -not (Test-Path (Join-Path $Ansible.Result.archived_at 'owner.json')) -or (Test-Path (Join-Path $library '.locks\192.0.2.5'))) { throw 'No se archivo el bloqueo conservando owner.json.' }
$library=New-LockFixture 'active'
$global:hvRecoveryTest.HasVM=$true
$blocked=$false
try { & $recovery -Library $library -CsvVolumes @($testRoot) -ClusterNodes @('TEST') -VmName TPL-TEST -IPAddress 192.0.2.5 -ExpectedCreated $timestamp -FailedTaskId 1 } catch { $blocked=$_.Exception.Message -match 'Existe una VM' }
if (-not $blocked -or -not (Test-Path (Join-Path $library '.locks\192.0.2.5\owner.json'))) { throw 'No se protegio el bloqueo de una VM existente.' }
$global:hvRecoveryTest.HasVM=$false
$library=New-LockFixture 'mismatch'
$blocked=$false
try { & $recovery -Library $library -CsvVolumes @($testRoot) -ClusterNodes @('TEST') -VmName TPL-TEST -IPAddress 192.0.2.5 -ExpectedCreated '2026-11-03T00:00:00Z' -FailedTaskId 1 } catch { $blocked=$_.Exception.Message -match 'ya no coincide' }
if (-not $blocked -or -not (Test-Path (Join-Path $library '.locks\192.0.2.5\owner.json'))) { throw 'Se modifico un bloqueo distinto al seleccionado.' }
$library=New-LockFixture 'media'
$preparation=Join-Path $testRoot 'SemaphoreVMs\TPL-TEST'
New-Item -ItemType Directory -Path (Join-Path $preparation 'Media'),(Join-Path $preparation 'Provisioning\windows-media\sources') -Force | Out-Null
Set-Content (Join-Path $preparation 'Media\os.iso') 'test original ISO'
Set-Content (Join-Path $preparation 'Provisioning\windows-media\sources\boot.wim') 'test copied content'
New-Item -ItemType Directory -Path (Join-Path $preparation 'Virtual Hard Disks') | Out-Null
$blocked=$false
try { & $recovery -Library $library -CsvVolumes @($testRoot) -ClusterNodes @('TEST') -VmName TPL-TEST -IPAddress 192.0.2.5 -ExpectedCreated $timestamp -FailedTaskId 2 -PreparationRoot $preparation } catch { $blocked=$_.Exception.Message -match 'recursos fuera' }
if (-not $blocked -or -not (Test-Path $preparation)) { throw 'Se admitio archivar una carpeta posterior a crear discos.' }
# Solo se retira la carpeta vacia creada por esta prueba, sin recursion.
Remove-Item -LiteralPath (Join-Path $preparation 'Virtual Hard Disks')
& $recovery -Library $library -CsvVolumes @($testRoot) -ClusterNodes @('TEST') -VmName TPL-TEST -IPAddress 192.0.2.5 -ExpectedCreated $timestamp -FailedTaskId 2 -PreparationRoot $preparation
if ((Test-Path $preparation) -or (Get-Content (Join-Path $Ansible.Result.preparation_archive 'Media\os.iso')) -ne 'test original ISO') { throw 'No se conservo la preparacion archivada.' }
'OK: archivado recuperable de bloqueo y medios; VM, discos y fecha distinta protegidos.'
