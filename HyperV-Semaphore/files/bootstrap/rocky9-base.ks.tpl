#version=RHEL9
cdrom
lang en_US.UTF-8
keyboard --vckeymap=latam --xlayouts=latam
timezone America/Mexico_City --utc
network --bootproto=static --ip={{ vm_ip }} --netmask={{ vm_netmask }} --gateway={{ vm_gateway }} --nameserver={{ vm_dns1 }}{{ vm_dns_suffix }} --device=link --activate --onboot=yes --hostname={{ vm_name }}
rootpw --iscrypted {{ root_password_hash }}
selinux --enforcing
firewall --enabled --service=ssh
services --enabled=sshd
ignoredisk --only-use=sda
clearpart --all --initlabel --drives=sda --disklabel=gpt
zerombr
bootloader --boot-drive=sda
part /boot/efi --fstype=efi --size=512 --ondisk=sda
part /boot --fstype=xfs --size=1024 --ondisk=sda
part pv.01 --fstype=lvmpv --grow --size=1 --ondisk=sda
volgroup vg_system pv.01
logvol / --vgname=vg_system --name=lv_root --size=51200 --fstype=xfs
logvol /home --vgname=vg_system --name=lv_home --size=20480 --fstype=xfs
logvol swap --vgname=vg_system --name=lv_swap --size=4096 --fstype=swap
reboot
%packages
@core
@development
cloud-init
openssh-server
sudo
lvm2
xfsprogs
vim
curl
wget
net-tools
nginx
bash-completion
nfs-utils
git
dnf-utils
dnf-plugins-core
# Evitar conflictos con Docker Engine
-podman
-buildah
%end
%post --erroronfail --interpreter=/bin/bash --log=/root/ks-post.log
set -euo pipefail
echo "=== Inicio Post-Configuracion base: $(date) ==="
# Se activara al sellar. El primer arranque conserva la red estatica del KS.
touch /etc/cloud/cloud-init.disabled
# Acceso de aprovisionamiento solo de la base; se retira al sellar.
install -d -m 0755 /etc/ssh/sshd_config.d
printf '%s\n' 'PermitRootLogin yes' 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/00-semaphore-base.conf
chmod 0600 /etc/ssh/sshd_config.d/00-semaphore-base.conf
systemctl enable sshd
# Docker CE del repositorio oficial; la base se instala con la red del KS activa.
echo "=== Instalando Docker ==="
dnf -y install dnf-plugins-core >> /root/ks-post.log 2>&1
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >> /root/ks-post.log 2>&1
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest >> /root/ks-post.log 2>&1
systemctl enable docker.service
echo "DOCKER_STATUS=INSTALLED"
# El usuario de cada clon se crea con cloud-init y se agrega a wheel y docker alli.
printf '%s\n' '{{ vm_name }}' > /etc/semaphore-provisioning-complete
echo "=== Fin Post-Configuracion base: $(date) ==="
%end
