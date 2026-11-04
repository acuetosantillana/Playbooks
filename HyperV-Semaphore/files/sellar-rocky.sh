#!/bin/bash
# Solo ejecutar DENTRO de la VM base dedicada; nunca en el host/runner.
set -euo pipefail
expected_name="${1:?Se requiere el hostname esperado}"
test "$(id -u)" = 0
test "$(hostname -s)" = "$expected_name"
[[ "$expected_name" == TPL-* ]]
grep -q '^ID="\?rocky"\?$' /etc/os-release
grep -q '^VERSION_ID="9\.' /etc/os-release
test -f /etc/semaphore-provisioning-complete
command -v cloud-init >/dev/null
if realm list 2>/dev/null | grep -q .; then echo 'La base no debe estar unida a dominio' >&2; exit 1; fi
install -d -m 0755 /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-semaphore-template.cfg <<'CLOUD'
datasource_list: [NoCloud]
ssh_deletekeys: true
ssh_genkeytypes: [rsa, ecdsa, ed25519]
CLOUD
# Desactivar perfiles viejos sin bajar la conexion actual.
while IFS= read -r connection_id; do
    nmcli connection modify "$connection_id" connection.autoconnect no
done < <(nmcli -g UUID connection show)
rm -f /etc/cloud/cloud-init.disabled
cloud-init clean --logs --machine-id --seed
if [ -f /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ]; then
    rm -f /var/lib/dbus/machine-id
    ln -s /etc/machine-id /var/lib/dbus/machine-id
fi
find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*key*' -delete
# Ninguna cuenta del disco maestro conserva una contrasena compartida activa.
passwd -l root
while IFS=: read -r account _ uid _; do
    if [ "$uid" -ge 1000 ] && [ "$account" != nobody ]; then usermod -L "$account"; fi
done < /etc/passwd
rm -f /etc/semaphore-provisioning-complete /etc/semaphore-instance.json
systemctl enable cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service
# Permite devolver el resultado de Ansible antes de cerrar SSH.
systemd-run --unit=semaphore-base-poweroff --on-active=10s /usr/bin/systemctl poweroff
