#!/usr/bin/env bash
#
# 
# Credits: This script is heavily inspired by this post https://disconnected.systems/blog/archlinux-installer
# Extended under the influence of the NSA's Guide to the Secure Configuration of RHEL5
# As well as Red Hat's own security suggestions.
# Designed to be used on devices with flash storage. Intended to be good enough to be secure without being paranoid,
# using FDE, but not sacrificing on a usable experience...
#
# This one is identical to the other Arch Install Script in my gists with the exception being that this one is
# customized to my own desired default install
set -uo pipefail

trap 's=$?; echo "$0: Error happened in script at line $LINENO: $BASH_COMMAND"; exit $s' ERR

KEYMAP=${KEYMAP:-fr-latin9}
LOCALE=${LOCALE:-fr_FR}

loadkeys "$KEYMAP"

reflector --threads 4 --fastest 10 -c "United States" -c Canada > /etc/pacman.d/mirrorlist

pacman -Sy --noconfirm dialog

hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"The hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter username for the admin user" 0 0) || exit 1
clear
: ${user:?"The username cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter password for the user" 0 0) || exit 1
clear
: ${password:?"The password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Repeat password for the user" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || (echo "Password did not match"; exit 1;)

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk. IMPORTANT: Data will be lost and the disk will be encrypted with luks." 0 0 0 ${devicelist}) || exit 1

echo "Randomizing our installation disk to aid our encryption...this may a take a while..."
dd if=/dev/urandom of=${device} bs=1M

### Log stdout and stderr to files to make them easier to navigate
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

timedatectl set-ntp true


## System partitions
parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib 1GiB \
  set 1 boot on \
  mkpart primary 1GiB 100%

efi_part="$(ls ${device}* | grep -E "^${device}p?1$")"
encrypted_part="$(ls ${device}* | grep -E "^${device}p?2$")"

wipefs "${efi_part}"
wipefs "${encrypted_part}"

### Filesystems
mkfs.vfat -F32 "${efi_part}"

cryptsetup luksFormat "${encrypted_part}" --type luks2
cryptsetup open --type luks2 --persistent "${encrypted_part}" lvm

pvcreate --dataalignment 1m /dev/mapper/lvm
vgcreate arch /dev/mapper/lvm

lvcreate -l 30%VG arch -n root
lvcreate -l 8%VG arch -n swap
lvcreate -l 2%VG arch -n tmp
lvcreate -l 2%VG arch -n var
lvcreate -l 2%VG arch -n var_tmp
lvcreate -l 2%VG arch -n var_log
lvcreate -l 1%VG arch -n var_log_audit
lvcreate -l 100%FREE arch -n home

mkfs.f2fs /dev/arch/root
mkfs.f2fs /dev/arch/home
mkfs.f2fs /dev/arch/tmp
mkfs.f2fs /dev/arch/var
mkfs.f2fs /dev/arch/var_tmp
mkfs.f2fs /dev/arch/var_log
mkfs.f2fs /dev/arch/var_log_audit
mkswap /dev/arch/swap


## Install system
mount /dev/arch/root /mnt
mkdir /mnt/home
mount /dev/arch/home /mnt/home
mkdir /mnt/boot
mount "${efi_part}" /mnt/boot
mkdir -p /mnt/var/log/audit
mkdir /mnt/var/tmp
mount /dev/arch/var /mnt/var
mount /dev/arch/var_log /mnt/var/log
mount /dev/arch/var_log_audit /mnt/var/log/audit
mount /dev/arch/var_tmp /mnt/var/tmp

# Will want to switch to doas over sudo likely at some point...
pacstrap /mnt base base-devel linux-hardened linux-lts f2fs-tools linux-firmware sudo nushell lvm2 neovim iwd git waybar network-manager-applet midori alacritty fuzzel wine-stable


## Configure
genfstab -t PARTUUID /mnt >> /mnt/etc/fstab
less /mnt/etc/fstab
echo "${hostname}" > /mnt/etc/hostname

sed -i "/${LOCALE}.UTF-8/s/^#//g" /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=${LOCALE}.UTF-8" > /mnt/etc/locale.conf
echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf

#echo "An editor will open with the mkinitcpio configuration."
#echo "In this file you have to ensure that the hooks needed for luks and lvm are present".
#echo "Example: HOOKS=(base udev autodetect keyboard keymap modconf block encrypt lvm2 filesystems fsck)"
#echo "Press enter to continue:"
#read
sed -i -e 's/HOOKS=(.*)/HOOKS=(base udev autodetect keyboard keymap modconf block encrypt lvm2 filesystems fsck)/' /mnt/etc/mkinitcpio.conf
#vim /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux-hardened
arch-chroot /mnt mkinitcpio -p linux-lts

arch-chroot /mnt useradd -mU -s /usr/bin/nushell -G wheel "${user}"
echo "${user}:${password}" | chpasswd --root /mnt
echo "root:${password}" | chpasswd --root /mnt

arch-chroot /mnt visudo
arch-chroot /mnt echo "127.0.0.1 localhost" >> /etc/hosts

arch-chroot /mnt systemctl enable NetWorkManager

arch-chroot -u ${user} /mnt git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si && cd .. && rm -rf paru
arch-chroot -u ${user} /mnt paru -S hyprland-git
arch-chroot -u ${user} /mnt git clone https://github.com/ToCodeABluejay/dotfiles.git && cp -r dotfiles/.[^.]* ~ && rm -rf dotfiles

## Install bootloader
mkdir /mnt/etc/pacman.d/hooks
cat <<EOF > /mnt/etc/pacman.d/hooks/100-systemd-boot.hook
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Updating systemd-boot
When = PostTransaction
Exec = /usr/bin/bootctl update
EOF

arch-chroot /mnt bootctl install

cat <<EOF > /mnt/boot/loader/loader.conf
default arch
EOF

cat <<EOF > /mnt/boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options cryptdevice=PARTUUID=$(blkid -s PARTUUID -o value "${encrypted_part}"):lvm root=/dev/volgroup0/lv_root rw
EOF
