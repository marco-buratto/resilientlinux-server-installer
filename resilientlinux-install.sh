#!/bin/bash

set -e

function System()
{
    base=$FUNCNAME
    this=$1

    # Declare methods.
    for method in $(compgen -A function)
    do
        export ${method/#$base\_/$this\_}="${method} ${this}"
    done

    # Properties list.
    DEVICE="$DEVICE"
}

# ##################################################################################################################################################
# Public 
# ##################################################################################################################################################

#
# Void System_run().
#
function System_run()
{
    if [ -n "$DEVICE" ]; then
	printf "\n* Installing the system, please have a cup of coffee...\n"
	System_install "$DEVICE"

	echo "Installation accomplished. Please remove your installation media and reboot to Resilient Server Linux."
    else
        exit 1
    fi
}

# ##################################################################################################################################################
# Private static
# ##################################################################################################################################################

function System_install()
{
	# Find out where this live system is mounted to.
	liveSystemMountpoint=$(mount | grep iso9660 | grep live | awk '{print $3}')

	# Create an ISO file from the files.
	xorrisofs -v -J -r -V RESILIENT_LINUX -o /tmp/resilientlinux.iso $liveSystemMountpoint	

	isoFile="/tmp/resilientlinux.iso"
	isoFileSize=$(du -sm "$isoFile" | awk '{print $1}') # MiB.

	# Initially wipe the $DEVICE with wipefs.
	wipefs -af $DEVICE && sleep 2

	# Re-create a blank GPT with a protective MBR.
	printf "o\nY\nw\nY\n" | gdisk $DEVICE && sync && sleep 6

	# Create the first system partition for writing kernel+initrd+filesystem.squashfs files into.
	printf "n\n\n\n${isoFileSize}M\n8300\nw\nY\n" | gdisk $DEVICE && sync && sleep 2

	# Write content from the hybrid-ISO (no MBR; only kernel, initrd, filesystem.squashfs) with xorriso into the host partition.
	xorriso -abort_on FAILURE -return_with SORRY 0 -indev "$isoFile" -boot_image any discard -overwrite on -volid 'SK-SYSTEM1' -rm_r .disk boot efi efi.img isolinux md5sum.txt live/filesystem.packages* live/filesystem.size live/initrd.img-* live/vmlinuz-* -- -outdev stdio:${DEVICE}1 -blank as_needed

	# Create the second system partition (256MiB) and write the kernel+initrd files into.
	printf "n\n\n\n+256M\n8300\nw\nY\n" | gdisk $DEVICE && sync && sleep 2
	xorriso -abort_on FAILURE -return_with SORRY 0 -indev "$isoFile" -boot_image any discard -overwrite on -volid 'SK-SYSTEM2' -rm_r .disk boot efi efi.img isolinux md5sum.txt live/filesystem.* live/filesystem.size live/initrd.img-* live/vmlinuz-* -- -outdev stdio:${DEVICE}2 -blank as_needed

	# Find out ISO partitions' UUIDs.
	isoUuidSystemPartition=$(blkid -s UUID ${DEVICE}1 | grep -oP '(?<=UUID=").*(?=")')
	isoUuidSecondSystemPartition=$(blkid -s UUID ${DEVICE}2 | grep -oP '(?<=UUID=").*(?=")')

	# Create UEFI structures; pass isoUuid* to grub.cfg:
	# GRUB will load kernel and initrd from the second system partition (which will be rewritten via xorrisofs after the kernel update by the system itself),
	# and will instruct the live-build-patched initrd to load the filesystem.squashfs from the first (complete) system partition.
	# A fallback boot is also available, with ye olde settings (i.e.: kernel/initrd loader from first system partition);
	# this boot option will also pass a special boot parameter, so the system can re-build the second system partition (xorrisofs).

	# Create UEFI structures (must be FAT) of 32MiB. Flag the UEFI partition so that it is recognized as such by the OSs and not mounted.
	printf "n\n\n\n+32M\nef00\nw\nY\n" | gdisk $DEVICE && sync && sleep 2 
	mkfs.vfat -n "UEFI Boot" ${DEVICE}3 && sleep 2

	mount ${DEVICE}3 /mnt

	cp -R /usr/share/resilient-linux/grub-uefi /mnt/efi
	sed -i -e "s/SYSTEM_ISO_UUID1/$isoUuidSystemPartition/g" /mnt/efi/boot/grub.cfg
	sed -i -e "s/SYSTEM_ISO_UUID2/$isoUuidSecondSystemPartition/g" /mnt/efi/boot/grub.cfg

	cp -R /usr/share/resilient-linux/grub-bios /mnt/boot
	sed -i -e "s/SYSTEM_ISO_UUID1/$isoUuidSystemPartition/g" /mnt/boot/grub/grub.cfg
	sed -i -e "s/SYSTEM_ISO_UUID2/$isoUuidSecondSystemPartition/g" /mnt/boot/grub/grub.cfg
	grub-install --root-directory=/mnt $DEVICE --force 2>/dev/null

	umount /mnt

	# Create the persistence partition as the last partition (with all the remaining space left) with the persistence.conf file inside.  
	printf "n\n\n\n\n\nw\nY\n" | gdisk $DEVICE && sync && sleep 2
	mkfs.ext4 -F ${DEVICE}4 && sleep 2
	e2label ${DEVICE}4 "persistence"

	mount ${DEVICE}4 /mnt
	echo "/ union" > /mnt/persistence.conf
	umount /mnt 

	# Finally fix partitions' flags.

	printf "x\na\n1\n62\n\nw\nY\n" | gdisk $DEVICE && sync && sleep 2
	printf "x\na\n2\n62\n\nw\nY\n" | gdisk $DEVICE && sync && sleep 2
}

# ##################################################################################################################################################
# Main
# ##################################################################################################################################################

DEVICE=""

# Must be run as root (sudo).
ID=$(id -u)
if [ $ID -ne 0 ]; then
    echo "This script needs super cow powers."
    exit 1
fi

# Parse user input.
while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        --device)
            DEVICE="$2"
            shift
            shift
            ;;

        *)
            shift
            ;;
    esac
done

if [ -z "$DEVICE" ]; then
    echo "Missing parameters. Use $0 --device <device> for installation, for example $0 --device /dev/sda."
else
    System "system"
    $system_run
fi

exit 0
