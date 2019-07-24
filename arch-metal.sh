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

# you must explicitly set the UNLOCK environment variable on invocation
# this fails if UNLOCK is unset
# special value none means no encryption

LUKS_PHRASE="$UNLOCK"

if ! [ -b "$DISK" ]
then
  echo "$0: $DISK unavailable"
  exit 1
fi

export ROTATIONAL=$(cat /sys/block/${DISK##/dev/}/queue/rotational)

# set up country specific source
MIRRORLIST="https://www.archlinux.org/mirrorlist/?country=${COUNTRY}&protocol=https&ip_version=4&use_mirror_status=on"
curl -s "$MIRRORLIST" | sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist

# wipe off existing systems
for part in `grep ${DISK##/dev/}$ /proc/partitions|sort -r|awk '{print $4}'`
do
  echo "Wiping partition $part"
  wipefs -f -a /dev/$part
done

# ready to go
if [ -d /sys/firmware/efi ]
then
  # EFI
  parted -s $DISK mklabel gpt
  parted -s $DISK mkpart ESP fat32 2048s $[1024*2*512-1]s
  if [ "$UNLOCK" = "none" ]; then
    parted -s $DISK mkpart rootfs xfs $[1024*2*512]s 100%
  else
    parted -s $DISK mkpart encrypted xfs $[1024*2*512]s 100%
  fi
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

if [ -d /sys/firmware/efi ]
then
  # EFI
  mkfs.fat -F32 -n ESP ${DISK}1
else
  # BIOS
  mkfs.xfs -L boot ${DISK}1
fi

if [ "$UNLOCK" = "none" ]
then
  ROOT_PARTITION="${DISK}2"
  # don't encrypt root partition
  mkfs.xfs -f -L rootfs "$ROOT_PARTITION"
  # get the UUID
  eval $(blkid "$ROOT_PARTITION" | cut -d' ' -f3)
  ROOT_UUID=$UUID
else
  # setup LUKS key
  LUKS_KEY="$(mktemp)"
  echo -n "$LUKS_PHRASE" > "$LUKS_KEY"
  
  # create LUKS
  cryptsetup --batch-mode --key-file=$LUKS_KEY -c aes-xts-plain64 \
    -s 512 luksFormat ${DISK}2
  
  # get LUKS UUID
  eval $(blkid ${DISK}2 | cut -d' ' -f2)
  LUKS_UUID=$UUID
  echo "LUKS_UUID = $LUKS_UUID"
  
  # open LUKS
  cryptsetup --batch-mode --key-file=$LUKS_KEY luksOpen ${DISK}2 cryptroot
  
  # create xfs root file system
  mkfs.xfs -f -L cryptroot /dev/mapper/cryptroot
  ROOT_PARTITION="/dev/mapper/cryptroot"
fi

# mount rootfs
if [[ $ROTATIONAL == 1 ]] 
then
  mount "$ROOT_PARTITION" /mnt
else
  mount "$ROOT_PARTITION" /mnt -o discard
fi

# mount boot
mkdir /mnt/boot
if [ $ROTATIONAL = 0 -a ! -d /sys/firmware/efi ]
then
  mount ${DISK}1 /mnt/boot -o discard
else
  mount ${DISK}1 /mnt/boot
fi

# bootstrap
pacman -Syy
pacstrap /mnt $(pacman -Sqg base | sed 's/^linux$/&-lts/') base-devel

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

if ! [ "$UNLOCK" = "none" ]
then
  # fix hooks
  cp -p /mnt/etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf.pacnew
  sed -i -e 's,^HOOKS=.*$,HOOKS="base udev autodetect modconf block keyboard keymap encrypt filesystems fsck",' \
    /mnt/etc/mkinitcpio.conf

  # LUKS on SSD?
  export LUKS_OPTS=""
  [ $ROTATIONAL = 0 ] && LUKS_OPTS=":allow-discards"
fi

# root password
echo root:$ROOTPW | chpasswd -R /mnt

# set up dhcp if on wired networking
NETIF="$(gawk '/^en/{if ($2==00000000) { print $1 }}' /proc/net/route)"

if [ -n "$NETIF" ]
then
  cat > /mnt/etc/netctl/wired <<EOD
Description='Bridged Wired Ethernet'
Interface=br0
BindsToInterfaces=('$NETIF')
Connection=bridge
IP=dhcp
SkipForwardingDelay=yes
EOD
fi

# post setup
cat > /mnt/root/post.sh << EOD
#!/bin/bash
set -euxo pipefail

# generate locale(s)
locale-gen

# some extra stuff needed for ansible
pacman --noconfirm -Syy
pacman --noconfirm -S intel-ucode openssh python2 bridge-utils
# systemctl enable sshd

# check for wired ethernet
# if [ -s /etc/netctl/wired ]
# then
#   netctl enable wired
# fi

# create initrd
mkinitcpio -p linux-lts

if [ -d /sys/firmware/efi ]
then
  # EFI -- setting entries from outside the chroot 
  pacman --noconfirm -S efibootmgr
  bootctl --path=/boot install || \
    efibootmgr -c -d $DISK -p1 -D -l /EFI/systemd/systemd-bootx64.efi \
    -L 'Linux Boot Manager' 
else
  # BIOS
  pacman --noconfirm -S grub
  grub-install --target=i386-pc --recheck $DISK
fi
EOD
chmod +x /mnt/root/post.sh
arch-chroot /mnt /root/post.sh

if [ -d /sys/firmware/efi ]
then

  # EFI
  cat > /mnt/boot/loader/entries/arch.conf << EOD
title Arch Linux
linux /vmlinuz-linux-lts
initrd /intel-ucode.img
initrd /initramfs-linux-lts.img
EOD

  if [ "$UNLOCK" = "none" ]
  then
    echo "options root=UUID=$ROOT_UUID rw"
  else
    echo "options cryptdevice=UUID=$LUKS_UUID:cryptroot$LUKS_OPTS root=/dev/mapper/cryptroot net.ifnames=0 rw"
  fi >> /mnt/boot/loader/entries/arch.conf

else
  if ! [ "$UNLOCK" = "none" ]
  then
    cp -p /mnt/etc/default/grub /mnt/etc/default/grub.pacnew
    sed -i -e "s,^GRUB_CMDLINE_LINUX=.*$,GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$LUKS_UUID:cryptroot${LUKS_OPTS} net.ifnames=0\"," /mnt/etc/default/grub
  fi
  # generate fresh grub config
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi

# swap
if [ $ROTATIONAL = 0 ]
then
  echo 'vm.swappiness = 0' > /mnt/etc/sysctl.d/swap-off.conf
else
  dd if=/dev/zero of=/mnt/swapfile bs=1024k count=1024
  chmod 600 /mnt/swapfile
  mkswap /mnt/swapfile
  echo '# swap' >> /mnt/etc/fstab
  echo '/swapfile none swap defaults 0 0' >> /mnt/etc/fstab
fi

# sync file systems
sync

echo "NOTE: check for network setup and enable"
