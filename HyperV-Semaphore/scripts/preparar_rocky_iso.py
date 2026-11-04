"""Crear ISO Rocky UEFI que arranca Install y aplica su Kickstart sin teclado."""
import argparse
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


def boot_replacements(config):
    entries = re.findall(r"(?m)^\s*menuentry\s+['\"]([^'\"]+)", config)
    if not entries or not re.match(r"install\s+rocky", entries[0], re.I):
        raise ValueError("La primera entrada UEFI no es Install Rocky; revisar esta ISO.")
    defaults = re.findall(r"(?m)^\s*set\s+default\s*=.*$", config)
    timeouts = re.findall(r"(?m)^\s*set\s+timeout\s*=.*$", config)
    if not defaults or not timeouts:
        raise ValueError("No se reconocen default y timeout en el GRUB de la ISO.")
    return [(line, 'set default="0"') for line in defaults] + [(line, "set timeout=3") for line in timeouts]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--kickstart", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.source.resolve() == args.output.resolve():
        raise SystemExit("No se sobrescribe la fuente ni una ISO ya existente.")
    if os.geteuid() != 0 or not all(shutil.which(tool) for tool in ("mkksiso", "xorriso")):
        raise SystemExit("El runner Linux requiere mkksiso, xorriso y root para actualizar el arranque UEFI.")
    with tempfile.TemporaryDirectory(prefix="rocky-grub-") as work:
        grub = Path(work) / "grub.cfg"
        subprocess.run(["xorriso", "-osirrox", "on", "-indev", str(args.source), "-extract", "/EFI/BOOT/grub.cfg", str(grub)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        command = ["mkksiso", "--ks", str(args.kickstart), "--rm-args", "rd.live.check"]
        for old, new in boot_replacements(grub.read_text()):
            command.extend(["--replace", old, new])
        command.extend([str(args.source), str(args.output)])
        # No imprimir KS ni permitir salida del programa con datos de respuestas.
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(args.output, 0o600)
        verified = Path(work) / "verified.cfg"
        subprocess.run(["xorriso", "-osirrox", "on", "-indev", str(args.output), "-extract", "/EFI/BOOT/grub.cfg", str(verified)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        text = verified.read_text()
        if not re.search(r'(?m)^\s*set default="?0"?\s*$', text) or "inst.ks=" not in text or "rd.live.check" in text:
            raise SystemExit("La ISO creada no acredita Install por defecto y Kickstart.")
    print("ISO Rocky: Install por defecto, espera 3 segundos, Kickstart integrado y UEFI actualizado.")


if __name__ == "__main__":
    main()
