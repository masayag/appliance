# appliance
A tool to configure a node for a disconnected OpenShift installation

# boot VM machine to be used as a disconnected OpenShift node

# Factory-like node
```bash
virt-install --name rhcos-vm --memory 16384 \
    --vcpus 8 \
    --disk path=/home/libvirt/images/rhcos-vm.qcow2,size=120 \
    --cdrom /var/lib/libvirt/images/coreos-x86_64.iso \
    --network bridge=virbr0,mac=52:54:00:e7:05:72 \
    --os-type linux --os-variant fedora-coreos-testing \
    --virt-type kvm --boot uefi,bootmenu.enable=on,bios.useserial=on \
    --graphics spice --video virtio \
    --console pty,target.type=virtio --serial pty
```

# Prepare ignition file to create partitions
The partition layout on the device should add a 5th partition with label `agentdata` to store the images needed for
agent based installation.
In a latter step, we'll use the `agentdata` partition to store the images needed for agent based installation in disconnected mode.

Create Butane to create the partition layout:
```yaml
variant: fcos
version: 1.4.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - "ssh-rsa ..."
storage:
  disks:
    - device: /dev/vda
      wipe_table: false
      partitions:
        - number: 4
          label: root
          size_mib: 15000
          resize: true
        - size_mib: 0
          label: agentdata
#  filesystems:
#    - path: /agentdata
#      device: /dev/disk/by-partlabel/agentdata
#      format: ext4
#      wipe_filesystem: true
#      label: agentdata
#      with_mount_unit: true
```

Convert the Butane file to an ignition file:
```bash
butane --pretty --strict start.bu > start.ign
```

Serve the file using a web server:
```bash
python3 -m http.server 9000
```

From the booted VM, run the following to start installation:
```bash
sudo coreos-installer install /dev/vda --ignition-url http://192.168.122.1:9000:/start.ign --insecrure-ignition
sudo reboot
```
