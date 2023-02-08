#!/bin/bash

#Verify 3 arguments are provided: IMG_FILE, AGENT_ISO, DEVICE
if [ $# -ne 3 ]; then
    echo "Usage: $0 <IMG_FILE> <AGENT_ISO> <DEVICE>"
    echo "Example: $0 /var/lib/libvirt/images/fedora-coreos-testing.qcow2 /var/lib/libvirt/images/agent.iso nbd1"
    exit 1
fi

IMG_FILE=$1
AGENT_ISO=$2
DEVICE=/dev/$3

if [ ! -f $IMG_FILE ]; then
    echo "Image $IMG_FILE does not exist"
    exit 1
fi

# verify agent.iso exists
if [ ! -f $AGENT_ISO ]; then
    echo "Agent ISO $AGENT_ISO does not exist"
    exit 1
fi

# verify device exist
if [ ! -b $DEVICE ]; then
    echo "Device DEVICE does not exist"
    exit 1
fi

# verify device is not mounted
if [ -n "$(lsblk $DEVICE)" ]; then
    echo "Device $DEVICE is mounted"
    exit 1
fi

# expand image by 20G to accommodate 2 new partitions: precached agent.iso and data
qemu-img resize $IMG_FILE +20G

# map image to device
qemu-nbd -c $DEVICE $IMG_FILE

# trap to unmount and disconnect device on exit
trap "qemu-nbd -d $DEVICE" EXIT

# add 2 partitions size 2G and 18G respectively
last_sector_used=$(fdisk -l $DEVICE | tail -1 | awk '{ print $3 }')
# add 1 to last sector used to get the first sector of the new partition
first_sector_new=$(($last_sector_used + 1))
# add 2G to first sector of the new partition to get the last sector of the new partition
last_sector_new=$(($first_sector_new + 2 * 1024 * 1024 * 1024 / 512 - 1))

mkdir -p /mnt/iso
mount -ro,loop $AGENT_ISO /mnt/iso
rhcos_ver=$(cat /mnt/iso/coreos/kargs.json | awk '/default/ {print $0}' | awk -F "coreos.liveiso=" '{print $2}' | awk '{print $1}')
umount /mnt/iso

# add rhcos partition
# FIXME: align sectors to 2048
parted -s $DEVICE mkpart $rhcos_ver ext4 ${first_sector_new}s ${last_sector_new}s

# add 2 partitions size 2G and 18G respectively
last_sector_used=$(fdisk -l $DEVICE | tail -1 | awk '{ print $3 }')
# add 1 to last sector used to get the first sector of the new partition
first_sector_new=$(($last_sector_used + 1))

# add agentdata partition
# FIXME: align sectors to 2048
parted -s $DEVICE -- mkpart agentdata ext4 ${first_sector_new}s -50s

rhcos_part=$(sfdisk --dump -J $DEVICE  | jq -r '.partitiontable.partitions[] | select(.name) | select(.name | startswith("rhcos")) | .node')
agentdata_part_uuid=$(sfdisk --dump -J $DEVICE  | jq -r '.partitiontable.partitions[] | select(.name) | select(.name | startswith("agentdata")) | .uuid')
agentdata_part=$(sfdisk --dump -J $DEVICE  | jq -r '.partitiontable.partitions[] | select(.name) | select(.name | startswith("agentdata")) | .node')

# copy agent.iso to the new partition labels rhcos-*
dd if=$AGENT_ISO of=$rhcos_part

# format the new partition labels agentdata (TBD: ext4 or xfs)
mkfs.ext4 -L agentdata $agentdata_part

# list partitions of the device
lsblk -o NAME,LABEL,PARTLABEL,SIZE,TYPE,FSTYPE,UUID,PARTUUID $DEVICE

# mount the boot partition
boot_part=$(sfdisk --dump -J $DEVICE  | jq -r '.partitiontable.partitions[] | select(.name) | select(.name == "boot") | .node')
boot_part_uuid=$(sfdisk --dump -J $DEVICE  | jq -r '.partitiontable.partitions[] | select(.name) | select(.name == "boot") | .uuid')
root_part_uuid=$(sfdisk --dump -J $DEVICE  | jq -r '.partitiontable.partitions[] | select(.name) | select(.name == "root") | .uuid')
boot_mnt=/mnt/${boot_part##*/}
mkdir -p $boot_mnt
mount -o rw $boot_part $boot_mnt

# mount the partition with agent image
rhcos_mnt=/mnt/${rhcos_part##*/}
mkdir -p $rhcos_mnt
mount -t iso9660 -o ro,loop $rhcos_part $rhcos_mnt

# Add boot option from agent image to boot menu
mkdir -p $boot_mnt/boot/agentiso/
cp $rhcos_mnt/images/ignition.img $boot_mnt/boot/agentiso/
cp $rhcos_mnt/images/pxeboot/vmlinuz $boot_mnt/boot/agentiso/
cp $rhcos_mnt/images/pxeboot/initrd.img $boot_mnt/boot/agentiso/

cat <<EOF > $boot_mnt/boot/loader/entries/agent.conf
title SYSTEM RESET
version 1
options random.trust_cpu=on console=tty0 console=ttyS0,115200n8 coreos.liveiso=$rhcos_ver ignition.firstboot ignition.platform.id=metal root=PARTUUID=$root_part_uuid ro boot=PARTUUID=$boot_part_uuid
linux /agentiso/vmlinuz
initrd /agentiso/initrd.img /agentiso/ignition.img
EOF

# Give a chance to hit the boot menu
sed -i 's/set timeout=1/set timeout=5/' $boot_mnt/boot/grub2/grub.cfg

umount $boot_mnt
umount $rhcos_mnt

qemu-nbd -d $DEVICE