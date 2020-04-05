#!/bin/bash
# vim: tabstop=2 shiftwidth=2 softtabstop=2 expandtab:

set -euxo pipefail

# UNLOCK=none -> do not use LUKS

# QEMU?
export DISK=${DISK:-/dev/vda}
export COUNTRY=${COUNTRY:-GB}
export KEYMAP=${KEYMAP:-uk}
export FQDN=${FQDN:-arch.example.com}
export LANG=${LANG:-en_GB.UTF-8}
export TZ=${TZ:-Europe/London}
export ROOTPW=${ROOTPW:-root}
export UNLOCK=${UNLOCK:-none}
export KERNEL=${KERNEL:-linux-lts}
# size in GiB or 100% (default)
export SIZE=${SIZE:-100%}
[[ $SIZE == "100%" ]] || SIZE=$[SIZE*1024*1024*2-1]s

# you must explicitly set the UNLOCK environment variable on invocation
# value none means no encryption will be applied

if ! [ -b "$DISK" ]
then
  echo "$0: $DISK unavailable"
  exit 1
fi

HAVE_EFI=0
[[ -d /sys/firmware/efi ]] && HAVE_EFI=1
HAVE_TRIM=$(lsblk -D -l | grep ^${DISK##/dev/} | awk '{print $3}')
if [[ $HAVE_TRIM == "0B" ]]
then
  HAVE_TRIM=0
else
  HAVE_TRIM=1
fi
HAVE_HDD=0
[[ $HAVE_TRIM == 0 ]] && HAVE_HDD=$(cat /sys/block/${DISK##/dev/}/queue/rotational)
HAVE_INTEL=0
grep -q Intel /proc/cpuinfo && HAVE_INTEL=1
HAVE_WIFI=0
rfkill|grep -q wlan && HAVE_WIFI=1
HAVE_BT=0
rfkill|grep -q bluetooth && HAVE_BT=1
HAVE_CRYPT=1
[[ "$UNLOCK" == "none" ]] && HAVE_CRYPT=0
NODE=$(cut -d. -f1 <<< $FQDN)

# set up country specific source
MIRRORLIST="https://www.archlinux.org/mirrorlist/?country=${COUNTRY}&protocol=https&ip_version=4&use_mirror_status=on"
curl -s "$MIRRORLIST" | sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist

# set up required packages
pacman -Syy
PACKAGES="base base-devel $KERNEL $KERNEL-headers linux-firmware"
PACKAGES="$PACKAGES xfsprogs netctl dhcpcd man-db usbutils openssh python2 bridge-utils ethtool vim dmidecode tcpdump bc rsync net-tools parted"
[[ $HAVE_EFI == 0 ]] && PACKAGES="$PACKAGES grub"
[[ $HAVE_EFI == 1 ]] && PACKAGES="$PACKAGES efibootmgr"
[[ $HAVE_INTEL == 1 ]] && PACKAGES="$PACKAGES intel-ucode"
[[ $HAVE_INTEL == 0 ]] && PACKAGES="$PACKAGES amd-ucode"
[[ $HAVE_WIFI == 1 ]] && PACKAGES="$PACKAGES rfkill dialog wpa_supplicant crda"
[[ $HAVE_BT == 1 ]] && PACKAGES="$PACKAGES bluez bluez-utils"

# wipe off existing systems
for part in `grep ${DISK##/dev/}$ /proc/partitions|sort -r|awk '{print $4}'`
do
  echo "Wiping partition $part"
  wipefs -f -a /dev/$part
done

# partitioning
if [[ $HAVE_EFI == 1 ]]
then
  # EFI
  LABEL=rootfs
  [[ $HAVE_CRYPT == 1 ]] && LABEL=encrypted
  parted -s $DISK mklabel gpt
  parted -s $DISK mkpart ESP fat32 2048s $[1024*2*512-1]s
  parted -s $DISK mkpart $LABEL xfs $[1024*2*512]s "$SIZE"
else
  # BIOS
  parted -s $DISK mklabel msdos
  parted -s $DISK mkpart primary xfs 2048s $[1024*2*512-1]s
  parted -s $DISK mkpart primary xfs $[1024*2*512]s 100%
fi

parted -s $DISK set 1 boot on

# wait until kernel refreshes the partitions
while ! [ -b ${DISK}1 ] ; do sleep 1 ; done
while ! [ -b ${DISK}2 ] ; do sleep 1 ; done

# CREATE BOOT FILESYSTEM
if [[ $HAVE_EFI == 1 ]]
then
  # EFI
  mkfs.fat -v -F32 -n ESP ${DISK}1
else
  # BIOS
  mkfs.xfs -f -L bootfs ${DISK}1
fi

# CREATE LUKS DEVICE IF NEEDED
if [[ $HAVE_CRYPT == 1 ]]
then
  LUKS_KEY="$(mktemp)"
  echo -n "$UNLOCK" > "$LUKS_KEY"
  cryptsetup --type luks1 --batch-mode --key-file=$LUKS_KEY -c aes-xts-plain64 \
    -s 512 --hash sha512 --iter-time 5000 --use-random luksFormat ${DISK}2
  eval $(blkid -o export ${DISK}2)
  LUKS_UUID=$UUID
  if [[ $HAVE_TRIM == 1 ]]
  then
    cryptsetup --batch-mode --key-file=$LUKS_KEY --allow-discards luksOpen ${DISK}2 cryptroot
  else
    cryptsetup --batch-mode --key-file=$LUKS_KEY luksOpen ${DISK}2 cryptroot
  fi
  ROOTDEV=/dev/mapper/cryptroot
  LUKS_OPTS=""
  [[ $HAVE_TRIM == 1 ]] && LUKS_OPTS=":allow-discards"
else
  ROOTDEV=${DISK}2
fi

# CREATE ROOT FILESYSTEM
mkfs.xfs -f -L rootfs $ROOTDEV

MOUNT_OPTS="defaults"
[[ $HAVE_TRIM == 1 ]] && MOUNT_OPTS="$MOUNT_OPTS,discard"

# mount rootfs
eval $(blkid -o export $ROOTDEV)
ROOT_UUID=$UUID
mount "$ROOTDEV" /mnt -o $MOUNT_OPTS

# mount boot
mkdir -p /mnt/boot
mount ${DISK}1 /mnt/boot -o $MOUNT_OPTS

# bootstrap
pacman -Syy
pacstrap /mnt $PACKAGES

# fstab
genfstab -U -p /mnt >> /mnt/etc/fstab

# set hostname
echo "$FQDN" > /mnt/etc/hostname

# timezone
ln -sf /usr/share/zoneinfo/$TZ /mnt/etc/localtime

# locale specific
echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf
echo "$LANG UTF-8" >> /mnt/etc/locale.gen
echo "LANG=$LANG" > /mnt/etc/locale.conf

# generate locale(s)
arch-chroot /mnt locale-gen

if [[ $HAVE_CRYPT == 1 ]]
then
  # fix hooks
  cp -p /mnt/etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf.pacnew
  sed -i -e 's,^HOOKS=.*$,HOOKS="base udev autodetect modconf block keyboard keymap encrypt filesystems fsck",' \
    /mnt/etc/mkinitcpio.conf
fi

# create initrd
arch-chroot /mnt mkinitcpio -p $KERNEL

if [[ $HAVE_EFI == 1 ]]
then
  # clean-up existing efi boot vars
  efibootmgr | grep 'Linux Boot Manager$' | cut -c5-8 | xargs --no-run-if-empty -n1 efibootmgr -B -b
  # install systemd boot manager
  arch-chroot /mnt \
    bootctl install
else
  # BIOS
  arch-chroot /mnt \
    grub-install --target=i386-pc --recheck $DISK
fi

KERNEL_LUKS=""
[[ $HAVE_CRYPT == 1 ]] && KERNEL_LUKS="cryptdevice=UUID=$LUKS_UUID:cryptroot$LUKS_OPTS"

if [[ $HAVE_EFI == 1 ]]
then
  KERNEL_CMDLINE="root=UUID=$ROOT_UUID rw"
  [[ $HAVE_CRYPT == 1 ]] && KERNEL_CMDLINE="$KERNEL_CMDLINE $KERNEL_LUKS"
  MICROCODE="intel-ucode.img"
  [[ $HAVE_INTEL == 0 ]] && MICROCODE="amd-ucode.img"
  cat > /mnt/boot/loader/entries/arch.conf << EOD
title Arch Linux
linux /vmlinuz-$KERNEL
initrd /$MICROCODE
initrd /initramfs-$KERNEL.img
options $KERNEL_CMDLINE
EOD
else
  # BIOS
  cp -p /mnt/etc/default/grub /mnt/etc/default/grub.pacnew
  [[ $HAVE_CRYPT == 1 ]] && \
    sed -i -e "s,^GRUB_CMDLINE_LINUX=.*$,GRUB_CMDLINE_LINUX=\"$KERNEL_LUKS\"," \
    /mnt/etc/default/grub
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi

# 1GiB swap in a file
echo 'vm.swappiness = 10' > /mnt/etc/sysctl.d/swap.conf
dd if=/dev/zero of=/mnt/swapfile bs=1024k count=1024
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
echo  >> /mnt/etc/fstab
echo '# swap on file' >> /mnt/etc/fstab
echo '/swapfile none swap defaults 0 0' >> /mnt/etc/fstab

# auto-cleaning pacman cache
find /mnt/var/cache/pacman/pkg/ -type f -delete
curl -R -L -o /mnt/usr/share/libalpm/hooks/package-cleanup.hook \
  https://raw.githubusercontent.com/archlinux/archlinux-docker/master/rootfs/usr/share/libalpm/hooks/package-cleanup.hook

# root password
echo root:$ROOTPW | chpasswd -R /mnt

# sync file systems
sync

echo "NOTE: setup networking if needed"
