param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string[]]$CsvVolumes,
    [Parameter(Mandatory)][string]$OscdimgPath,
    [string]$NoPromptBootFile='',
    [string]$AnswersPath=''
)
$ErrorActionPreference='Stop'
$Ansible.Changed=$false
$rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')
$allowedRoots=@($CsvVolumes | ForEach-Object { [IO.Path]::GetFullPath((Join-Path (Join-Path $_ 'SemaphoreVMs') $VmName)).TrimEnd('\') })
if ($rootPath -notin $allowedRoots) { throw 'La ISO solo se prepara en la carpeta CSV de esta VM nueva.' }
$sourceIso=Join-Path $rootPath 'Media\os.iso'
$outputIso=Join-Path $rootPath 'Media\os-uefi-auto.iso'
$partialIso=$outputIso+'.partial'
$work=Join-Path $rootPath 'Provisioning\windows-media'
if ($AnswersPath) {
    $expectedAnswers=Join-Path $rootPath 'Provisioning\answers'
    if ([IO.Path]::GetFullPath($AnswersPath).TrimEnd('\') -ne $expectedAnswers) { throw 'Respuestas fuera del directorio restringido de esta VM.' }
    if (-not (Test-Path -LiteralPath (Join-Path $AnswersPath 'Autounattend.xml') -PathType Leaf)) { throw 'Falta Autounattend.xml para integrar en el medio de arranque.' }
    # La ISO ahora contiene la contrasena de instalacion. Proteger el directorio
    # antes de que Oscdimg cree siquiera el archivo parcial.
    $mediaPath=Join-Path $rootPath 'Media'
    $acl=Get-Acl -LiteralPath $mediaPath
    $acl.SetAccessRuleProtection($true,$false)
    $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($identity in @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identity),'FullControl',$inherit,'None','Allow'))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-83-0'),'ReadAndExecute',$inherit,'None','Allow'))
    Set-Acl -LiteralPath $mediaPath -AclObject $acl
}
if (-not (Test-Path -LiteralPath $OscdimgPath -PathType Leaf)) { throw 'Falta oscdimg.exe de Microsoft ADK.' }
if (-not (Test-Path -LiteralPath $sourceIso -PathType Leaf)) { throw 'No se encontro la copia de ISO en el CSV.' }
foreach ($path in @($outputIso,$partialIso,$work)) { if (Test-Path -LiteralPath $path) { throw 'Ya existe una preparacion de ISO. Revisar antes de reintentar; no se sobrescribe.' } }
$mountedByThisScript=$false
try {
    $image=Get-DiskImage -ImagePath $sourceIso -ErrorAction Stop
    if (-not $image.Attached) {
        $image=Mount-DiskImage -ImagePath $sourceIso -StorageType ISO -Access ReadOnly -PassThru
        $mountedByThisScript=$true
    }
    $volumes=@($image | Get-Volume | Where-Object DriveLetter)
    if ($volumes.Count -ne 1) { throw 'La ISO montada no expuso una unica unidad de lectura.' }
    $mountedRoot=$volumes[0].DriveLetter+':\'
    if (-not (Test-Path -LiteralPath (Join-Path $mountedRoot 'sources\boot.wim')) -or -not (Test-Path -LiteralPath (Join-Path $mountedRoot 'setup.exe'))) { throw 'El medio no contiene un instalador Windows compatible.' }
    $candidates=@()
    if ($NoPromptBootFile) {
        if ([IO.Path]::GetFileName($NoPromptBootFile) -notmatch '^efisys_noprompt(?:_EX)?\.bin$') { throw 'Se requiere efisys_noprompt.bin o efisys_noprompt_EX.bin oficial.' }
        if (-not (Test-Path -LiteralPath $NoPromptBootFile -PathType Leaf)) { throw 'La ruta configurada de efisys_noprompt no existe.' }
        $candidates+= $NoPromptBootFile
    } else {
        $candidates+=Join-Path $mountedRoot 'efi\microsoft\boot\efisys_noprompt.bin'
        $candidates+=Join-Path (Split-Path -Parent $OscdimgPath) 'efisys_noprompt.bin'
        $adkRoot=${env:ProgramFiles(x86)}
        if ($adkRoot) { $candidates+=Join-Path $adkRoot 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\efisys_noprompt.bin' }
    }
    $bootFile=$candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $bootFile) { throw 'Falta efisys_noprompt.bin. Copiar el archivo oficial del ADK junto a C:\Oscdimg\oscdimg.exe o configurar efisys_noprompt_path. No se arranca una instalacion que espere una tecla.' }
    if ((Get-Item -LiteralPath $bootFile).Length -eq 0) { throw 'El archivo de arranque esta vacio.' }
    New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
    Get-ChildItem -LiteralPath $mountedRoot -Force | Copy-Item -Destination $work -Recurse -Force
    if ($AnswersPath) {
        $embeddedAnswer=Join-Path $work 'Autounattend.xml'
        if (Test-Path -LiteralPath $embeddedAnswer) { (Get-Item -LiteralPath $embeddedAnswer).IsReadOnly=$false }
        Copy-Item -LiteralPath (Join-Path $AnswersPath 'Autounattend.xml') -Destination $embeddedAnswer -Force
        if ((Get-FileHash -LiteralPath $embeddedAnswer).Hash -ne (Get-FileHash -LiteralPath (Join-Path $AnswersPath 'Autounattend.xml')).Hash) { throw 'No se verifico la integracion del archivo de respuestas.' }
    }
    # Una entrada El Torito UEFI para Hyper-V Gen2; conserva Secure Boot.
    $arguments=@('-m','-o','-u2','-udfver102','-lWS2025AUTO',('-bootdata:1#pEF,e,b'+$bootFile),$work,$partialIso)
    # Oscdimg escribe progreso en stderr incluso cuando termina correctamente.
    # Redirigir a archivos evita NativeCommandError con WinRM/error_action=stop.
    $stdout=Join-Path $rootPath 'Media\oscdimg-uefi.stdout.log'
    $stderr=Join-Path $rootPath 'Media\oscdimg-uefi.stderr.log'
    $quotedArguments=@($arguments | ForEach-Object { '"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"' })
    $process=Start-Process -FilePath $OscdimgPath -ArgumentList $quotedArguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0) {
        $details=@(Get-Content -LiteralPath $stdout,$stderr -ErrorAction SilentlyContinue | Select-Object -Last 30) -join [Environment]::NewLine
        throw "Oscdimg fallo con codigo $($process.ExitCode). $details"
    }
    if (-not (Test-Path -LiteralPath $partialIso -PathType Leaf) -or (Get-Item -LiteralPath $partialIso).Length -eq 0) { throw 'Oscdimg no produjo una ISO utilizable.' }
    Move-Item -LiteralPath $partialIso -Destination $outputIso
    $audit=@{uefi_no_prompt=$true;embedded_autounattend=[bool]$AnswersPath;source_iso=$sourceIso;boot_image=$bootFile;boot_sha256=(Get-FileHash -LiteralPath $bootFile -Algorithm SHA256).Hash;created_utc=[DateTime]::UtcNow.ToString('o')}
    $audit | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $rootPath 'Media\os-uefi-auto.json') -Encoding UTF8
} finally {
    if ($mountedByThisScript) { Dismount-DiskImage -ImagePath $sourceIso | Out-Null }
}
# Solo el arbol de trabajo verificado de esta VM; se conservan NAS e ISO fuente.
$resolvedWork=[IO.Path]::GetFullPath($work)
if ($resolvedWork -ne (Join-Path $rootPath 'Provisioning\windows-media')) { throw 'Ruta de trabajo fuera de la carpeta autorizada.' }
Remove-Item -LiteralPath $resolvedWork -Recurse -Force
$Ansible.Result=@{iso=$outputIso;uefi_no_prompt=$true;embedded_autounattend=[bool]$AnswersPath}
$Ansible.Changed=$true
