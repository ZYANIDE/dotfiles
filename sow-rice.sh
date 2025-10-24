# prompt_text [-rh] <prompt_message> [<default> <default_message>]
prompt_text() (
  while getopts 'rh' OPTKEY; do
    case "$OPTKEY" in
      r) is_required=true ;;
      h) is_hidden=true ;;
      *) printf '%s: option %s does not exist fr the internal function prompt_text\n' "$PROGRAM_NAME" "$OPTARG" && exit 1 ;;
    esac
  done
  shift "$((OPTIND -1))"; DEFAULT="$2"
  if [ -n "$3" ]; then PROMPT_HINT="$3"
  elif [ "$is_hidden" = true ]; then PROMPT_HINT='[Hidden]' && stty -echo
  elif [ -n "$DEFAULT" ]; then PROMPT_HINT="$DEFAULT"
  elif [ "$is_required" = true ]; then PROMPT_HINT='[Required]'
  else PROMPT_HINT='[Empty]'; fi
  while [ -z "${IN+x}" ] || { [ -z "$IN" ] && [ "$is_required" = true ]; } do
    printf '%s' "$1 ($PROMPT_HINT): " >> /dev/tty
    read -r IN
  done
  [ "$is_hidden" = true ] && stty echo && printf '\n' >> /dev/tty
  echo "${IN:-"$DEFAULT"}"
)

# includes <haystack> <needles>
includes() (
  for a in $1; do
    for b in $2; do
      [ "$a" = "$b" ] && echo true && return 0
    done
  done
  echo false && return 1
)

printf '\n' >> /dev/tty
printf 'Define the root password for the new linux system\n' >> /dev/tty
root_pwd_verified=false
while [ "$root_pwd_verified" = false ]; do
  root_pwd="$(prompt_text -rh 'New password')"
  if [ "$(prompt_text -rh 'Repeat password')" = "$root_pwd" ];
  then root_pwd_verified=true
  else printf 'Sorry, passwords do not match.\n\n' >> /dev/tty; fi
done

printf '\n' >> /dev/tty
user_name="$(prompt_text -r 'New user name')"

printf '\n' >> /dev/tty
user_pwd_verified=false
while [ "$user_pwd_verified" = false ]; do
  user_pwd="$(prompt_text -rh 'New password')"
  if [ "$(prompt_text -rh 'Repeat password')" = "$user_pwd" ];
  then user_pwd_verified=true
  else printf 'Sorry, passwords do not match.\n\n' >> /dev/tty; fi
done

printf '\n' >> /dev/tty
printf 'Select a disk to wipe and install linux on.\n' >> /dev/tty
printf '\n%s\n\n' "$(lsblk -o NAME,SIZE,TYPE)" >> /dev/tty

valid_disks="$(lsblk -d | awk '{print $1}')"
while [ "$(includes "$valid_disks" "$chosen_disk")" = false ]; do
  chosen_disk="$(prompt_text -r 'Choose a disk')"
done

umount $(mount | grep /mnt | awk '{print $1}' | sort -n)

printf '\n' >> /dev/tty
printf 'Partitioning disk /dev/%s...\n' "$chosen_disk" >> /dev/tty
gdisk /dev/"$chosen_disk" <<EOF > /dev/null
o       # Create a new empty GPT partition table
y       # Confirm
n       # New partition
1       # Partition number
        # Default - begin at first sector available
+512M   # 512MiB size
ef00    # EFI system partition
n       # New partition
2       # Partition number
        # Default - begin at first sector available
        # Default - size of all remaining space
8300    # Linux filesystem partition
w       # Write disk
y       # Confirm write
EOF

efi_partition="$(lsblk -ln | awk -v disk="nvme1n1" '$1 ~ ("^" disk) && $6 == "part" {print $1}' | awk 'NR==1')"
linux_fs_partition="$(lsblk -ln | awk -v disk="nvme1n1" '$1 ~ ("^" disk) && $6 == "part" {print $1}' | awk 'NR==2')"
printf 'Formatting EFI partition /dev/%s to fat32...\n' "$efi_partition" >> /dev/tty
mkfs.fat -F 32 /dev/"$efi_partition"
mount /dev/"$efi_partition" /mnt && rm -rf /mnt/* && umount /mnt
printf 'Formatting linux filesystem partition /dev/%s to btrfs...\n' "$linux_fs_partition" >> /dev/tty
mkfs.btrfs -f /dev/"$linux_fs_partition"
mount /dev/"$linux_fs_partition" /mnt && rm -rf /mnt/* && umount /mnt

read -rd '' btrfs_subvolumes <<EOF
@ /
@home /home
EOF

printf '\n' >> /dev/tty
printf 'Creating btrfs subvolumes\n' >> /dev/tty
mount /dev/"$linux_fs_partition" /mnt
while read -r subvolume; do
  name="$(echo "$subvolume" | awk '{print $1}')"
  printf 'Creating subvolume %s ...' "$name" >> /dev/tty
  btrfs subvolume create "$name" /mnt/"$name"
  printf ' done.\n' >> /dev/tty
done <<< "$btrfs_subvolumes"
umount /mnt

printf '\n' >> /dev/tty
printf 'Mounting disk /dev/%s\n' "$chosen_disk" >> /dev/tty
while read -r subvolume; do
  name="$(echo "$subvolume" | awk '{print $1}')"
  mountpoint="$(echo "$subvolume" | awk '{print $2}')"
  printf 'Mounting subvolume %s to %s ...' "$name" "/mnt${mountpoint%/}" >> /dev/tty
  mkdir -p "/mnt${mountpoint%/}"
  mount -o compress=zstd,subvol="$name" /dev/"$linux_fs_partition" "/mnt${mountpoint%/}"
  printf ' done.\n' >> /dev/tty
done <<< "$btrfs_subvolumes"
printf 'Mounting subvolume %s to /mnt/efi ...' "$name" >> /dev/tty
mkdir -p "/mnt/efi"
mount /dev/"$efi_partition" /mnt/efi
printf ' done.\n' >> /dev/tty

printf '\n' >> /dev/tty
printf 'Installing linux on disk /dev/%s\n' "$chosen_disk" >> /dev/tty
pacstrap -K /mnt base linux linux-firmware
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt /bin/bash -x <<EOF
pacman -Syu archlinux-keyring grub efibootmgr networkmanager sudo --noconfirm
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable NetworkManager.service
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers
echo "root:$root_pwd" | chpasswd
useradd -mG wheel "$user_name"
echo "$user_name:$user_pwd" | chpasswd
EOF
printf 'done.\n' >> /dev/tty

printf '\n' >> /dev/tty
printf 'Reboot, login with the non-root user and run:\n' >> /dev/tty
printf '$ pacman -S git yq\n' >> /dev/tty
printf '$ git clone https://github.com/zyanide/dotfiles && sh dotfiles/rice-cooker.sh\n' >> /dev/tty
printf '\n' >> /dev/tty
