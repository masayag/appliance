#!/bin/bash

set -e

#Verify 3 arguments are provided: IMG_FILE, AGENT_ISO, DEVICE
if [ $# -ne 3 ]; then
    echo "Usage: $0 <IMG_FILE> <AGENT_ISO> <DEVICE>"
    echo "Example: $0 /var/lib/libvirt/images/fedora-coreos-testing.qcow2 /var/lib/libvirt/images/agent.iso nbd0"
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

# trap to unmount and disconnect device on exit
trap "qemu-nbd -d $DEVICE" EXIT

#####################################################
# Add 'agentdata' partition to the image:
# First, it extends the image
# Next, it adds a new partition labelled 'agentdata'
# Finally, it formats the new partition as ext4
# If the partition already exists, it does nothing
#####################################################
function add_agentdata_partition {
qemu-nbd -c $DEVICE $IMG_FILE
  agentdata_part=$(sfdisk --dump -J $DEVICE  | jq -r '.partitiontable.partitions[] | select(.name) | select(.name | startswith("agentdata")) | .node')
  #check if agentdata partition exists
  if [ "$agentdata_part" ]; then
      echo "agentdata partition already exists"
      return
  fi

  # disconnect device before resize
  qemu-nbd -d $DEVICE $IMG_FILE

  # expand image by 5G to accommodate new partition for precached data
  # in this case, the vmlinuz, initrd.img and rootfs.img will be placed in the new partition
  qemu-img resize $IMG_FILE +5G

  # map image to device
  qemu-nbd -c $DEVICE $IMG_FILE

  # rewrite partition table at the end of resized disk
  sgdisk --move-second-header /dev/nbd0

  # add 2 partitions size 2G and 18G respectively
  last_sector_used=$(fdisk -l $DEVICE | tail -1 | awk '{ print $3 }')
  # add 1 to last sector used to get the first sector of the new partition
  first_sector_new=$(($last_sector_used + 1))

  # add agentdata partition
  # FIXME: align sectors to 2048
  parted -s $DEVICE -- mkpart agentdata ext4 ${first_sector_new}s -50s

  # format the new partition labels agentdata (TBD: ext4 or xfs)
  mkfs.ext4 -L agentdata $agentdata_part
}

#####################################################
# Add agent image resources to the agentdata partition
# First, it mounts the agentdata partition
# Next, it mounts the agent image
# Finally, it copies the ignition.img, kernel/initrd.img
# and rootfs.img to the agentdata partition
#####################################################
function add_agent_iso_resources_to_agentdata_partition {
  agentdata_part=$(sfdisk --dump -J $DEVICE  | jq -r '.partitiontable.partitions[] | select(.name) | select(.name | startswith("agentdata")) | .node')
  agentdata_mnt=/mnt/${agentdata_part##*/}
  mkdir -p $agentdata_mnt
  mount -o rw $agentdata_part $agentdata_mnt

  # copy ignition.img, kernel/initrd.img and rootfs.img to agentdata partition
  mkdir -p $agentdata_mnt/agentboot/
  cp $tmp_ignition_dir/ignition.img $agentdata_mnt/agentboot/
  cp $agent_iso_mnt/images/pxeboot/vmlinuz $agentdata_mnt/agentboot/
  cp $agent_iso_mnt/images/pxeboot/initrd.img $agentdata_mnt/agentboot/
  cp $agent_iso_mnt/images/pxeboot/rootfs.img $agentdata_mnt/agentboot/

  # mount the boot partition
  boot_part=$(sfdisk --dump -J $DEVICE  | jq -r '.partitiontable.partitions[] | select(.name) | select(.name == "boot") | .node')
  boot_mnt=/mnt/${boot_part##*/}
  mkdir -p $boot_mnt
  mount -o rw $boot_part $boot_mnt

  # add boot option to boot menu
  echo "$resetconfig" > $boot_mnt/boot/grub2/user.cfg
}

#####################################################
# Mount agent ISO
#####################################################
function mount_agent_iso {
  agent_iso_mnt=/mnt/agentiso
  mkdir -p $agent_iso_mnt
  mount -t iso9660 -o ro,loop $AGENT_ISO $agent_iso_mnt
}

#####################################################
# Update ignition config to add boot option for reset
#####################################################
function update_ignition_config {
  # Add boot option from agent image to boot menu, and set it as not default (this menu entry will be used for reset, and should not be the default)
  # The default value is 1, which is the second menu entry (counting starts from 0)
  read -r -d '' resetconfig << EOF
set timeout=10
set default=1
menuentry 'SYSTEM RESET' {
  search --set=root --label agentdata
  load_video
  set gfx_payload=keep
  insmod gzio
  linux /agentboot/vmlinuz random.trust_cpu=on console=tty0 console=ttyS0,115200n8 ignition.firstboot ignition.platform.id=metal ro
  initrd /agentboot/initrd.img /agentboot/ignition.img /agentboot/rootfs.img
}
EOF

content=$(echo "$resetconfig" | base64 -w 0)
tmp_dir=$(mktemp -d /tmp/ignition.XXXXXX)
cat <<EOF > $tmp_dir/reset_ignition.json
{
  "storage": {
    "files": [{
      "group": {},
      "overwrite": true,
      "user": {
        "name": "root"
      },
      "path": "/boot/grub2/user.cfg",
      "mode": 420,
      "contents": { "source": "data:text/plain;charset=utf-8;base64,${content}" }
    }]
  }
}
EOF

  tmp_ignition_dir=$(mktemp -d)
  cp /mnt/iso/images/ignition.img $tmp_ignition_dir
  pushd $tmp_ignition_dir
  zcat ignition.img | cpio -idmnv
  rm ignition.img

  cat <<'EOF' > $tmp_dir/merge.jq
reduce ($b | paths(scalars)) as $p (.;
  ($b|getpath($p)) as $v
  | if $v != null then setpath($p; $v) else . end)
EOF

  jq -f $tmp_dir/merge.jq --argfile b $tmp_dir/reset_ignition.json $tmp_ignition_dir/config.ign > $tmp_dir/merged_ignition.ign
  mv $tmp_dir/merged_ignition.ign $tmp_ignition_dir/config.ign
  find . | cpio -H newc -o | gzip -9 > $tmp_ignition_dir/ignition.img
  popd
}

add_agentdata_partition
mount_agent_iso
update_ignition_from_agent_iso
add_agent_iso_resources_to_agentdata_partition

umount $boot_mnt
umount $rhcos_mnt
umount $agentdata_mnt
umount $agent_iso_mnt

# for info purpose: list partitions of the device
lsblk -o NAME,LABEL,PARTLABEL,SIZE,TYPE,FSTYPE,UUID,PARTUUID $DEVICE

qemu-nbd -d $DEVICE