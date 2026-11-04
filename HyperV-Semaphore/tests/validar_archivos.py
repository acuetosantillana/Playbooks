"""Validacion local/CI sin conexion a Hyper-V ni Semaphore."""
import json
import re
import sys
from pathlib import Path

import yaml
from jinja2 import Environment

root = Path(__file__).resolve().parents[1]


class UniqueLoader(yaml.SafeLoader):
    pass


def mapping(loader, node, deep=False):
    data = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in data:
            raise ValueError(f"Clave YAML duplicada: {key}")
        data[key] = loader.construct_object(value_node, deep=deep)
    return data


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
env = Environment()
assert yaml.safe_load((root.parent / 'collections/requirements.yml').read_text()) == yaml.safe_load((root / 'requirements.yml').read_text())


def check_jinja(value):
    if isinstance(value, dict):
        for child in value.values():
            check_jinja(child)
    elif isinstance(value, list):
        for child in value:
            check_jinja(child)
    elif isinstance(value, str):
        env.parse(value)


count = 0
for file in root.rglob("*.yml"):
    value = yaml.load(file.read_text(encoding="utf-8"), Loader=UniqueLoader)
    check_jinja(value)
    count += 1
for file in root.glob("examples/*.json"):
    json.loads(file.read_text(encoding="utf-8"))
playbook = yaml.load((root / "playbooks/desplegar.yml").read_text(), Loader=UniqueLoader)
assert len(playbook) == 3
for play in playbook:
    for task in play.get("tasks", []):
        module = task.get("ansible.windows.win_powershell", {})
        if "path" in module:
            relative = module["path"].replace("{{ playbook_dir }}/", "")
            assert (root / "playbooks" / relative).resolve().is_file(), relative

ks_text = (root / "files/bootstrap/rocky9.ks.tpl").read_text(encoding="utf-8")
values = {
    "vm_name": "test-rocky9", "vm_ip": "192.0.2.21", "vm_netmask": "255.255.254.0",
    "vm_gateway": "192.0.2.1", "vm_dns1": "192.0.2.10", "vm_dns_suffix": "",
    "linux_user": "adm", "root_password_hash": "$6$test$" + "A" * 86,
    "linux_password_hash": "$6$test$" + "B" * 86,
}
rendered = env.from_string(ks_text).render(**values)
assert not re.search(r"\{\{|\{%|--plaintext", rendered)
assert "--erroronfail" in rendered
assert "/etc/semaphore-provisioning-complete" in rendered
assert re.search(r"^reboot$", rendered, re.M)
try:
    from pykickstart.parser import KickstartParser
    from pykickstart.version import makeVersion
    parser = KickstartParser(makeVersion("RHEL9"), followIncludes=False, errorsAreFatal=True)
    parser.readKickstartFromString(rendered)
except ImportError as exc:
    raise SystemExit("Instala pykickstart para validar el KS RHEL9") from exc
print(f"OK: {count} YAML, JSON de ejemplo, sintaxis Jinja, referencias y KS RHEL9.")
