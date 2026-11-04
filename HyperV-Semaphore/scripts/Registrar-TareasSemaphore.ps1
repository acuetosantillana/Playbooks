[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BaseUrl='https://smxsemaphore.santillana.com.mx',
    [int]$ProjectId=1,
    [int]$ViewId=5,
    [Parameter(Mandatory)][int]$WindowsTemplateOrigen,
    [Parameter(Mandatory)][int]$RockyTemplateOrigen,
    [int]$EnvironmentId=0,
    [string]$Branch='codex/hyperv-semaphore-nuevas-tareas'
)
$ErrorActionPreference = 'Stop'
if (-not $env:SEMAPHORE_API_TOKEN) { throw 'Define SEMAPHORE_API_TOKEN en tu entorno local. No lo guardes en Git ni en el chat.' }
if ([uri]$BaseUrl -and ([uri]$BaseUrl).Scheme -ne 'https') { throw 'Usa HTTPS para la API.' }
$headers = @{ Authorization='Bearer ' + $env:SEMAPHORE_API_TOKEN }
$apiRoot = $BaseUrl.TrimEnd('/') + '/api/project/' + $ProjectId
$templates = @(Invoke-RestMethod -Uri ($apiRoot + '/templates') -Headers $headers)
$requests = @()
foreach ($spec in @(
    @{ Name='VM desde plantilla - Windows Server 2025'; Playbook='HyperV-Semaphore/playbooks/crear_windows_2025.yml'; Source=$WindowsTemplateOrigen; Windows=$true; Image='ws2025-base-v1' },
    @{ Name='VM desde plantilla - Rocky Linux 9'; Playbook='HyperV-Semaphore/playbooks/crear_rocky_9.yml'; Source=$RockyTemplateOrigen; Windows=$false; Image='rocky9-base-v1' }
)) {
    if ($templates | Where-Object name -eq $spec.Name) { throw "La tarea $($spec.Name) ya existe. No se modifica ni duplica." }
    $source = Invoke-RestMethod -Uri ($apiRoot + '/templates/' + $spec.Source) -Headers $headers
    $repo = Invoke-RestMethod -Uri ($apiRoot + '/repositories/' + $source.repository_id) -Headers $headers
    if ($repo.git_url -notmatch 'github.com[:/]acuetosantillana/Playbooks(?:\.git)?$') { throw 'La tarea origen no usa el repositorio Playbooks esperado.' }
    if ($repo.monorepo -and $repo.git_branch -ne $Branch) { throw 'El repositorio compartido no permite esta rama. Crear una entrada de repositorio separada antes de registrar.' }
    $survey = @()
    foreach ($field in @(
        @('vm_name','Nombre de la nueva VM','','',$true),
        @('memory_gb','Memoria GiB','int',$(if ($spec.Windows) {'8'} else {'4'}),$true),
        @('cpu','vCPU','int','4',$true),
        @('disk_gb','Disco GiB','int','100',$true),
        @('vm_ip','Direccion IPv4','','',$true),
        @('vm_mask','Prefijo CIDR','int','24',$true),
        @('vm_gateway','Gateway','','',$true),
        @('vm_dns1','DNS principal','','',$true),
        @('vm_dns2','DNS secundario (opcional)','','',$false)
    )) {
        $survey += @{ name=$field[0]; title=$field[1]; type=$field[2]; default_value=$field[3]; required=$field[4] }
    }
    $survey += @{name='hyperv_host';title='Hipervisor';type='enum';required=$true;values=@(@{name='SMXHYPVA';value='SMXHYPVA'},@{name='SMXHYPVB';value='SMXHYPVB'})}
    $survey += @{name='vm_vlan';title='VLAN ID';type='enum';required=$true;values=@(@{name='120';value='120'},@{name='96';value='96'})}
    $survey += @{name='template_id';title='Plantilla base';type='enum';required=$true;default_value=$spec.Image;values=@(@{name=$spec.Image;value=$spec.Image})}
    if ($spec.Windows) {
        $survey += @{ name='admin_password'; title='Contrasena del administrador Windows'; type='secret'; required=$true }
    } else {
        $survey += @{ name='linux_user'; title='Usuario Rocky'; type=''; default_value='adm'; required=$true }
        $survey += @{ name='root_password'; title='Contrasena root'; type='secret'; required=$true }
        $survey += @{ name='linux_password'; title='Contrasena del usuario Rocky'; type='secret'; required=$true }
    }
    $request = @{ project_id=$ProjectId; view_id=$ViewId; name=$spec.Name; playbook=$spec.Playbook; inventory_id=$source.inventory_id; repository_id=$source.repository_id; environment_id=$source.environment_id; git_branch=$Branch; app='ansible'; arguments='[]'; allow_override_args_in_task=$false; survey_vars=$survey; description='Copia de imagen VHDX ya instalada, personalizacion de primer arranque y registro HA.' }
    if ($EnvironmentId -gt 0) { $request.environment_id=$EnvironmentId }
    if ($source.vaults) { $request.vaults=$source.vaults }
    $requests += $request
}
foreach ($request in $requests) {
    if ($PSCmdlet.ShouldProcess($request.name, "Crear nueva plantilla en proyecto $ProjectId, vista $ViewId; rama $Branch")) {
        $created = Invoke-RestMethod -Method Post -Uri ($apiRoot + '/templates') -Headers $headers -ContentType 'application/json' -Body ($request | ConvertTo-Json -Depth 12)
        $verified = Invoke-RestMethod -Uri ($apiRoot + '/templates/' + $created.id) -Headers $headers
        if ($verified.playbook -ne $request.playbook -or $verified.git_branch -ne $Branch) { throw 'La tarea creada no coincide con la configuracion solicitada.' }
        [pscustomobject]@{ id=$verified.id; name=$verified.name; playbook=$verified.playbook; branch=$verified.git_branch }
    }
}
# No se llama a /tasks: registrar estas plantillas no inicia instalaciones.
