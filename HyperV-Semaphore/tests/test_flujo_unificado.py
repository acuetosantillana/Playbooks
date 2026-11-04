"""Comprobar seleccion excluyente de acciones y menu Install de Rocky."""
import importlib.util
from pathlib import Path
import yaml

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('rocky_iso',root/'scripts/preparar_rocky_iso.py')
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
cfg='''set default="1"
set timeout=60
menuentry 'Install Rocky Linux 9.6' {
linuxefi /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Rocky
}
menuentry 'Test this media & install Rocky Linux 9.6' {
}
'''
for old,new in module.boot_replacements(cfg):
    cfg=cfg.replace(old,new)
assert 'set default="0"' in cfg and 'set timeout=3' in cfg
try:
    module.boot_replacements(cfg.replace("menuentry 'Install Rocky", "menuentry 'Test Rocky"))
except ValueError:
    pass
else:
    raise AssertionError('No se rechazo un menu cuya primera entrada es distinta de Install.')
plays=yaml.safe_load((root/'playbooks/hyperv.yml').read_text(encoding='utf-8'))
assert not any('ansible.builtin.import_playbook' in p or 'import_playbook' in p for p in plays)
actions=set()
for p in plays[1:]:
    for phase in ('pre_tasks','tasks','post_tasks'):
        for block in p.get(phase,[]):
            assert block['when'].startswith('accion == '), p['name']
            actions.add(block['when'].split("'")[1])
assert actions=={'crear_base','clonar','diagnosticar','recuperar_reserva','limpiar'}
preflight=plays[0]['tasks']
assert any('Comprobar herramientas de Rocky antes' in t['name'] for t in preflight)
print('OK: un archivo, acciones excluyentes y GRUB con Install + timeout 3 segundos.')
