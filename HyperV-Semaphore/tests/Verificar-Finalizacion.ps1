$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('hyperv-finalize-test-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $testRoot 'SemaphoreVMs\TPL-WS2025'
New-Item -ItemType Directory -Path (Join-Path $root 'Media'),(Join-Path $root 'Provisioning'),(Join-Path $root 'Virtual Hard Disks') -Force | Out-Null
$vmId=[guid]::NewGuid()
@{name='TPL-WS2025';root=$root;system='Windows';vm_id=$vmId.ToString()} | ConvertTo-Json | Set-Content (Join-Path $root 'deployment.json')
$global:finalizeTest=@{Dvds=@();Removed=@();Stale=0;Refuse=$false;Id=$vmId;Root=$root;Disk=(Join-Path $root 'Virtual Hard Disks\TPL-WS2025.vhdx')}
function Import-Module { param($Name) }
function Get-ClusterGroup { param($Name) [pscustomobject]@{State='Online';OwnerNode=[pscustomobject]@{Name='TEST'}} }
function Get-VM { param($ComputerName,$Id) if ($Id -ne $global:finalizeTest.Id) { throw 'UUID incorrecto' }; [pscustomobject]@{Name='TPL-WS2025';Id=$Id;State='Running'} }
function Get-VMHardDiskDrive { param($VM) [pscustomobject]@{Path=$global:finalizeTest.Disk} }
function Get-VMSnapshot { param($VM) @() }
function Get-VMDvdDrive { param($VM) if ($global:finalizeTest.Stale -gt 0 -and $global:finalizeTest.Removed.Count -gt 0) { $global:finalizeTest.Stale--; $global:finalizeTest.Original } else { $global:finalizeTest.Dvds } }
function Remove-VMDvdDrive { param($VMDvdDrive,$ErrorAction) $global:finalizeTest.Removed+=@($VMDvdDrive); if (-not $global:finalizeTest.Refuse) { $global:finalizeTest.Dvds=@($global:finalizeTest.Dvds | Where-Object Id -ne $VMDvdDrive.Id) } }
function Start-Sleep { param($Seconds) }
$clean=Join-Path $projectRoot 'scripts\Limpiar-Medios.ps1'
foreach ($relative in @('Media\answers.iso','Media\os-uefi-auto.iso','Provisioning\params.json','Virtual Hard Disks\TPL-WS2025.vhdx')) { Set-Content (Join-Path $root $relative) 'fixture' }
$global:finalizeTest.Dvds=@([pscustomobject]@{Id=1;ControllerNumber=0;ControllerLocation=1;Path=(Join-Path $root 'Media\answers.iso')},[pscustomobject]@{Id=2;ControllerNumber=0;ControllerLocation=2;Path=(Join-Path $root 'Media\os-uefi-auto.iso')})
$global:finalizeTest.Original=$global:finalizeTest.Dvds
$global:finalizeTest.Stale=2
$Ansible=[pscustomobject]@{Changed=$false;Result=$null}
& $clean -VmName TPL-WS2025 -Root $root -CsvVolumes @($testRoot)
if ($global:finalizeTest.Removed.Count -ne 2 -or -not $Ansible.Result.media_removed -or (Test-Path (Join-Path $root 'Provisioning')) -or -not (Test-Path $global:finalizeTest.Disk)) { throw 'No se retiro cada DVD conservando el disco.' }
# Idempotente sin DVD ni medios: no vuelve a tocar el disco.
& $clean -VmName TPL-WS2025 -Root $root -CsvVolumes @($testRoot)
New-Item -ItemType Directory -Path (Join-Path $root 'Provisioning') | Out-Null
Set-Content (Join-Path $root 'Provisioning\keep.txt') 'preservar'
$global:finalizeTest.Dvds=@([pscustomobject]@{Id=3;ControllerNumber=0;ControllerLocation=1;Path=(Join-Path $root 'Media\answers.iso')})
$global:finalizeTest.Refuse=$true
$blocked=$false
try { & $clean -VmName TPL-WS2025 -Root $root -CsvVolumes @($testRoot) } catch { $blocked=$_.Exception.Message -match 'Quedan DVD temporales' }
if (-not $blocked -or -not (Test-Path (Join-Path $root 'Provisioning\keep.txt'))) { throw 'Se borro material antes de confirmar retirada.' }
$global:finalizeTest.Dvds=@([pscustomobject]@{Id=4;Path=(Join-Path $testRoot 'foreign.iso')})
$before=$global:finalizeTest.Removed.Count
$blocked=$false
try { & $clean -VmName TPL-WS2025 -Root $root -CsvVolumes @($testRoot) } catch { $blocked=$_.Exception.Message -match 'DVD ajeno' }
if (-not $blocked -or $global:finalizeTest.Removed.Count -ne $before) { throw 'Se modifico un DVD ajeno.' }
$library=Join-Path $testRoot 'VMTemplates'
$lock=Join-Path $library '.locks\192.0.2.5'
New-Item -ItemType Directory -Path $lock -Force | Out-Null
@{vm='TPL-WS2025';ip='192.0.2.5';token='fixture-token'} | ConvertTo-Json | Set-Content (Join-Path $lock 'owner.json')
$resume=Join-Path $projectRoot 'scripts\Reanudar-Base.ps1'
& $resume -VmName TPL-WS2025 -Sistema Windows -IPAddress 192.0.2.5 -Library $library -TemplateId ws2025-base-v1 -CsvVolumes @($testRoot)
if ($Ansible.Result.root -ne $root -or $Ansible.Result.token -ne 'fixture-token' -or $Ansible.Changed) { throw 'No se recupero la base sin modificarla.' }
$global:finalizeTest.Disk=Join-Path $testRoot 'other.vhdx'
$blocked=$false
try { & $resume -VmName TPL-WS2025 -Sistema Windows -IPAddress 192.0.2.5 -Library $library -TemplateId ws2025-base-v1 -CsvVolumes @($testRoot) } catch { $blocked=$_.Exception.Message -match 'disco o los checkpoints' }
if (-not $blocked) { throw 'Se permitio reanudar un disco distinto.' }
'OK: DVD exactos, espera de confirmacion, fallos conservan archivos; reanudar valida identidad y disco sin reinstalar.'
