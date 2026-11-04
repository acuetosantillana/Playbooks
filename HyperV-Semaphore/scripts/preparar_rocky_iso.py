"""Crear ISO Rocky UEFI que arranca Install y aplica su Kickstart sin teclado."""
import argparse
from io import BytesIO
import re
import shutil
import tempfile
from pathlib import Path


def automatic_grub(config):
    first = re.search(r"(?ms)^menuentry\s+['\"]([^'\"]+)['\"][^\n]*\{\s*\n.*?^\}", config)
    if not first or not re.match(r"install\s+rocky", first.group(1), re.I):
        raise ValueError("La primera entrada UEFI no es Install Rocky; revisar esta ISO.")
    defaults = re.findall(r"(?m)^\s*set\s+default\s*=.*$", config)
    timeouts = re.findall(r"(?m)^\s*set\s+timeout\s*=.*$", config)
    if not defaults or not timeouts:
        raise ValueError("No se reconocen default y timeout en el GRUB de la ISO.")
    text=config[:first.start()]+first.group(0)+'\n'
    text=re.sub(r'(?m)^\s*set\s+default\s*=.*$', 'set default="0"', text)
    text=re.sub(r'(?m)^\s*set\s+timeout\s*=.*$', 'set timeout=3', text)
    text=re.sub(r'(?m)^(\s*linux(?:efi)?\s+.*)$', lambda m: re.sub(r'\s+(?:rd.live.check|inst.ks=\S+)', '', m.group(1))+' inst.ks=hd:LABEL=OEMDRV:/ks.cfg', text)
    if 'inst.ks=' not in text:
        raise ValueError('No se encontro la linea linux/linuxefi de Install.')
    return text


def prepare(source, output):
    import pycdlib
    from pyfatfs.PyFatFS import PyFatFS
    shutil.copyfile(source, output)
    iso=pycdlib.PyCdlib()
    with open(output,'r+b') as stream, tempfile.TemporaryDirectory(prefix='rocky-efi-') as work:
        iso.open_fp(stream)
        patches=[]
        try:
            cfg=BytesIO()
            iso.get_file_from_iso_fp(cfg,rr_path='/EFI/BOOT/grub.cfg')
            new_cfg=automatic_grub(cfg.getvalue().decode()).encode()
            # Preservar extents, catalogo El Torito y cargadores firmados.
            if len(new_cfg)>len(cfg.getvalue()):
                raise ValueError('La configuracion automatica supera el espacio original.')
            image=Path(work)/'efiboot.img'
            iso.get_file_from_iso(local_path=str(image),rr_path='/images/efiboot.img')
            image_size=image.stat().st_size
            with PyFatFS(str(image),read_only=False) as fat:
                if not fat.exists('/EFI/BOOT/grub.cfg'):
                    raise ValueError('Falta el GRUB UEFI interno; revisar esta ISO.')
                fat.writetext('/EFI/BOOT/grub.cfg',new_cfg.decode())
            if image.stat().st_size!=image_size:
                raise ValueError('Cambio el tamano del arranque UEFI.')
            for path,data in [('/EFI/BOOT/grub.cfg',new_cfg),('/images/efiboot.img',image.read_bytes())]:
                record=iso.get_record(rr_path=path)
                offset=record.extent_location()*2048
                length=record.data_length
                if len(data)>length or offset<0 or offset+length>output.stat().st_size:
                    raise ValueError('El cambio no cabe en el archivo original de la ISO.')
                patches.append((offset,length,data.ljust(length,b'\n')))
        finally:
            iso.close()
        patches.sort()
        if patches[0][0]+patches[0][1]>patches[1][0]:
            raise ValueError('Los archivos de arranque se solapan.')
        # Sustituir solo los bytes originales, sin recalcular ni mover el
        # catalogo El Torito, tablas de particiones, paquetes o metadatos ISO.
        for offset,length,data in patches:
            stream.seek(offset)
            stream.write(data)
        stream.flush()
    output.chmod(0o600)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.source.resolve() == args.output.resolve():
        raise SystemExit("No se sobrescribe la fuente ni una ISO ya existente.")
    prepare(args.source,args.output)
    print("ISO Rocky: Install por defecto, espera 3 segundos, Kickstart en OEMDRV y UEFI actualizado.")


if __name__ == "__main__":
    main()
