#!/bin/bash
# vim: tabstop=2 shiftwidth=2 softtabstop=2 expandtab:

set -euo pipefail

# directory for chroot environment
BUILDROOT="${BUILDROOT:-/srv/build}"

# use UK mirror
COUNTRY=${COUNTRY:-GB}
MIRRORLIST="https://www.archlinux.org/mirrorlist/?country=${COUNTRY}&protocol=https&ip_version=4&use_mirror_status=on"

# use tokland's archbootstrap
ARCHBOOTSTRAP="https://raw.githubusercontent.com/tokland/arch-bootstrap/master/arch-bootstrap.sh"

MIRROR_PC="http://www.mirrorservice.org/sites/ftp.archlinux.org"
MIRROR_ARM="http://nl.mirror.archlinuxarm.org"

# guard
if ! which arch-chroot 2> /dev/null; then
  echo "ERROR: arch-chroot not installed"
  exit 2
fi

rm -rvf "$BUILDROOT"
mkdir -p "$BUILDROOT"

if ! [[ -s "./arch-bootstrap.sh" ]]; then
  curl -R -L -O "$ARCHBOOTSTRAP"
  chmod +x ./arch-bootstrap.sh
fi

ARCH="$(uname -m)"

# arm fixes
if [[ "$ARCH" == armv6* ]]; then
  ARCH=armv6h
elif [[ "$ARCH" == armv7* ]]; then
  ARCH=armv7h
fi


if [[ "$ARCH" == armv* || "$ARCH" == aarch64 ]]; then
  ./arch-bootstrap.sh -a "$ARCH" \
    -r "$MIRROR_ARM" "$BUILDROOT"
  # Use the customized mirrorlist from host
  cp -p /etc/pacman.d/mirrorlist \
    "${BUILDROOT}/etc/pacman.d/mirrorlist"
elif [[ "$ARCH" == x86_64 ]]; then
  ./arch-bootstrap.sh -a "$ARCH" \
    -r "$MIRROR_PC" "$BUILDROOT"
  # generate country specific mirrorlist
  curl -s "$MIRRORLIST" |  sed 's/^#Server/Server/' \
    > "${BUILDROOT}/etc/pacman.d/mirrorlist"
else
  echo "Unsupported architecture"
  exit 2
fi

echo MAKEFLAGS=\"-j$(nproc)\" >> "${BUILDROOT}/etc/makepkg.conf"
cp -p /etc/resolv.conf "${BUILDROOT}/etc/resolv.conf"

cat > "$BUILDROOT/root/bootstrap.sh" <<EOD
#!/bin/bash

pacman -Syy
pacman --noconfirm --needed -S base base-devel vim linux-headers
echo en_GB.UTF-8 UTF-8 >> /etc/locale.gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
locale-gen
useradd -m -c 'Dr Jenkins' jenkins
echo jenkins:jenkins | chpasswd
gpasswd -a jenkins wheel
echo 'Cmnd_Alias BUILD = /usr/bin/pacman' > /etc/sudoers.d/jenkins
echo '%wheel ALL=(ALL) NOPASSWD: BUILD' >> /etc/sudoers.d/jenkins
chmod 0400 /etc/sudoers.d/jenkins
echo 'kill -9 -1' >> /home/jenkins/.bash_logout
echo -e "y\ny" | pacman -Scc
rm -f /.{BUILDINFO,INSTALL,MTREE,PKGINFO}
rm -f /root/bootstrap.sh
EOD
chmod +x "$BUILDROOT/root/bootstrap.sh"

arch-chroot "$BUILDROOT" /root/bootstrap.sh
