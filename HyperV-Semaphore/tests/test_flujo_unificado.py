"""Comprobar seleccion excluyente de acciones y menu Install de Rocky."""
import importlib.util
import sys
from pathlib import Path
import yaml
import hashlib
import tempfile
from io import BytesIO

root=Path(__file__).resolve().parents[1]
sys.dont_write_bytecode=True
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
cfg=module.automatic_grub(cfg)
assert 'set default="0"' in cfg and 'set timeout=3' in cfg
try:
    module.automatic_grub(cfg.replace("menuentry 'Install Rocky", "menuentry 'Test Rocky"))
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

# ISO y FAT UEFI reales de prueba: no se usan ISO de produccion ni una VM.
import pycdlib
from pyfatfs.PyFat import PyFat
from pyfatfs.PyFatFS import PyFatFS
original='''set default="1"
set timeout=60
menuentry 'Install Rocky Linux 9.6' {
 linuxefi /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=RockyTest quiet
 initrdefi /images/pxeboot/initrd.img
}
menuentry 'Test this media & install Rocky Linux 9.6' {
 linuxefi /images/pxeboot/vmlinuz rd.live.check
 initrdefi /images/pxeboot/initrd.img
}
'''
with tempfile.TemporaryDirectory(prefix='rocky-iso-test-') as work:
    work=Path(work)
    image=work/'efiboot.img'
    image.touch()
    fs=PyFat()
    fs.mkfs(str(image),fat_type=16,size=16*1024*1024)
    fs.close()
    with PyFatFS(str(image)) as fat:
        fat.makedirs('/EFI/BOOT',recreate=True)
        fat.writetext('/EFI/BOOT/grub.cfg',original)
        fat.writebytes('/EFI/BOOT/BOOTX64.EFI',b'FAKE UEFI LOADER FOR TEST')
    source=work/'source.iso'
    iso=pycdlib.PyCdlib()
    iso.new(interchange_level=3,rock_ridge='1.09',vol_ident='RockyTest')
    iso.add_directory('/EFI',rr_name='EFI')
    iso.add_directory('/EFI/BOOT',rr_name='BOOT')
    iso.add_directory('/IMAGES',rr_name='images')
    iso.add_fp(BytesIO(original.encode()),len(original.encode()),iso_path='/EFI/BOOT/GRUB.CFG;1',rr_name='grub.cfg')
    iso.add_file(str(image),iso_path='/IMAGES/EFIBOOT.IMG;1',rr_name='efiboot.img')
    iso.add_eltorito('/IMAGES/EFIBOOT.IMG;1',bootcatfile='/BOOT.CAT;1',rr_bootcatname='boot.cat',platform_id=0xef)
    iso.write(str(source))
    iso.close()
    source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
    result=work/'auto.iso'
    module.prepare(source,result)
    assert hashlib.sha256(source.read_bytes()).hexdigest()==source_hash
    iso.open(str(result))
    final=BytesIO()
    iso.get_file_from_iso_fp(final,rr_path='/EFI/BOOT/grub.cfg')
    assert final.getvalue().decode().rstrip()==module.automatic_grub(original).rstrip()
    extracted=work/'final.img'
    iso.get_file_from_iso(local_path=str(extracted),rr_path='/images/efiboot.img')
    iso.close()
    with PyFatFS(str(extracted),read_only=True) as fat:
        assert fat.readtext('/EFI/BOOT/grub.cfg')==module.automatic_grub(original)
        assert fat.readbytes('/EFI/BOOT/BOOTX64.EFI')==b'FAKE UEFI LOADER FOR TEST'
print('OK: ISO y FAT UEFI modificadas sin root; fuente y cargador EFI conservados.')
