# What is this?
A flow to configure a node for a disconnected OpenShift installation.
The target of the installation will be determined on customer site(SNO, Compact, Multi-node).
When interactive agent-based installation will become available, this flow will become agnostic to node's specifics.
Since this isn't the case yet, the flow relies on the existing agent-based installation in which the creation of
the agent.iso requires HW specific information of the target cluster's nodes.

# Boot VM machine to be used as a disconnected OpenShift node

# Factory-like node
At this version (using openshift-installer-4.12), MAC Address is hardcoded in the agent image.
We'll prepare the foundation of the appliance of SNO type.
In this example we'll use the MAC address represented by `MAC_ADDRESS` as the MAC address of the target node.
It is required to reserve IP Address for the node in the DHCP server, since the IP of the rendezvous is
also hard-coded in the agent image. Therefore, if using libvirt, a simple way can be to use the DHCP server
of the used network:
```bash
MAC_ADDRESS=52:54:00:e7:05:79
RENDEZVOUS_IP=192.168.122.118
NETWORK_NAME=default

# Add the host to the network's DHCP server, without needing to restart the network:
virsh net-update $NETWORK_NAME add-last ip-dhcp-host \
    "<host mac='${MAC_ADDRESS}' ip='${RENDEZVOUS_IP}'/>" \
    --live --config --parent-index 0

# Verify the changes:
virsh net-dumpxml --network $NETWORK_NAME
<network>
  <name>default</name>
  <uuid>7de07e73-d7d4-4672-b342-7155648c216a</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mac address='52:54:00:f3:79:5b'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.116' end='192.168.122.120'/>
      <host mac='52:54:00:e7:05:72' ip='192.168.122.116'/>
    </dhcp>
  </ip>
</network>
```

# Prepare ignition file to create partitions
The partition layout on the device should add a 5th partition with label `agentdata` to store the images needed for
agent based installation in disconnected mode, where the images are located in the `agentdata` partition.
The partition layout should be as follows:
```text
NAME     LABEL      PARTLABEL    SIZE TYPE FSTYPE
nbd0                             120G disk 
├─nbd0p1            BIOS-BOOT      1M part 
├─nbd0p2 EFI-SYSTEM EFI-SYSTEM   127M part vfat
├─nbd0p3 boot       boot         384M part ext4
├─nbd0p4 root       root       115.6G part xfs
└─nbd0p5 agentdata  agentdata    3.9G part ext4
```
In a latter step, we'll copy required images to the `agentdata` partition.
Hence, the `agentdata` partition should be large enough to hold the images and the rest of disconnect resources.

Use Butane to create the partition layout to be applied by the initial ignition file:
```bash
IGN_DIR=$(mktemp -d)
IGNITION_CONFIG=${IGN_DIR}/init.ign

# replace with your public key or generate a new one (this is optional, since this image will be wiped)
SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub)

butane --pretty --strict << EOF > $IGNITION_CONFIG 
variant: fcos
version: 1.4.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - "$SSH_PUB_KEY"
storage:
  disks:
    - device: /dev/vda
      partitions:
        - number: 5
          start_mib: -4000
          size_mib: 4000
          label: agentdata
  filesystems:
    - device: /dev/disk/by-partlabel/agentdata
      format: ext4
      label: agentdata
      wipe_filesystem: true
EOF
```

## Create a VM
There is more than one option to prepare a virtual machine to act as the node in the target cluster.
We'll capture two options here:
1. Using a ISO file cached by agent.iso creation
2. Using a qcow2 image downloaded from the internet

For both options, we should specify the destination disk image on a file system with more than 120GB of free space.
```bash
SNO_IMG=/home/libvirt/images/sno.qcow2
SNO_IMG_SIZE=120
```

### Alternative 1: Using a ISO file cached by agent.iso creation
When creating the agent.iso, coreos image is downloaded and cached into _$HOME/.cache/agent/image_cache/coreos-x86_64.iso_
This image can be used to boot the VM and install the OS. Copy the image to a location accessible by the qemu.
Alternately, other live-cd should be usable.
To ease the debug process, the serial console is enabled.
```bash
COREOS_ISO=$HOME/.cache/agent/image_cache/coreos-x86_64.iso
BOOT_COREOS_ISO=/var/lib/libvirt/images/coreos-x86_64.iso
cp $COREOS_ISO $BOOT_COREOS_ISO

# We'll use the same image for booting the OS of the target node.
# Any required changes can be applied to the image before booting the VM.
coreos-installer iso kargs modify -a "console=ttyS0,115200n8 serial" $BOOT_COREOS_ISO
```
Create a VM using the following command:
```bash
virt-install --name sno \
    --memory 16384 \
    --vcpus 8 \
    --disk path="${SNO_IMG},size=${SNO_IMG_SIZE}" \
    --cdrom ${BOOT_COREOS_ISO} \
    --network bridge=virbr0,mac=${MAC_ADDRESS} \
    --os-type linux --os-variant fedora-coreos-stable \
    --virt-type kvm \
    --boot uefi,bootmenu.enable=on,bios.useserial=on \
    --graphics none
```

The VM should boot and a console should be available to follow the installation process.
In this scenario, let's serve the ignition file using a simple web server from the hyperviosr:
```bash
cd $IGN_DIR
python3 -m http.server 9000
```
The ignition file can be served from any other web server, as long as the VM can access it.

From the booted VM, run the following to start installation:
```bash
sudo coreos-installer install /dev/vda --ignition-url http://192.168.122.1:9000/init.ign --insecure-ignition
sudo reboot
```
Where `192.168.122.1` is the IP address of the virtual network used by the VM.

### Alternative 2: Using a qcow2 image downloaded from the internet
Another option is to download qcow2 image from the internet (1.5G).
```bash
# as an installed binary:
coreos-installer download -s stable \
    -p qemu -f qcow2.xz \
    --decompress -C /var/lib/libvirt/images/
```
And start the VM using the downloaded image:
```bash
# replace the following with the correct path to the downloaded image from previous step
IMAGE=/var/lib/libvirt/images/fedora-coreos-37.20230122.3.0-qemu.x86_64.qcow2

# For x86
IGNITION_DEVICE_ARG=(--qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_CONFIG}")

# Setup the correct SELinux label to allow access to the config
chown -R qemu:qemu $IGN_DIR
    
virt-install --connect="qemu:///system" --name=sno \
    --memory 16384 \
    --vcpus 8 \
    --disk="path=${SNO_IMG},size=${SNO_IMG_SIZE},backing_store=${IMAGE}" \
    --network bridge=virbr0,mac=${MAC_ADDRESS} \
    --os-type linux --os-variant=fedora-coreos-stable \
    --virt-type kvm \
    --boot uefi,bootmenu.enable=on,bios.useserial=on \
    --import --graphics=none \
    "${IGNITION_DEVICE_ARG[@]}"
```

## Adding agent installation resources to the VM
At this stage, the VM should be booted and the OS installed. There is a dedicated partition `agentdata` that will be used
to store the agent installation resources.
We'll add the resources to the VM using by writing directly to the partition in the VM image.
The resources that will be added to the VM are:
* Boot menu entry to allow booting the VM using the agent-based installer
* The kernel, initramfs, rootfs and ignition of the agent-based installer
Other changes:
* Setting the new menu entry `SYSTEM RESET` as the non-default boot option.
* Extend boot menu timeout to 10 seconds.

First, the VM needs to be shutdown:
```bash
virsh shutdown sno
```

The rest of the process relies on a script to prepare the device and copy the resources to the VM image.
```bash
bash -x update_node0_image.sh $SNO_IMG /var/lib/libvirt/images/agent.iso nbd0
```

Boot the VM and verify that the new boot menu entry is available.
To start the agent-based installation, select the new menu entry 'SYSTEM RESET' and follow the instructions.
For SNO that meets the requirements, the installation should be completed automatically.
Note that it takes nearly 30 minutes for SNO to be installed and fully operational.

## Troubleshooting
There are several steps in which the installation can fail.
The steps to troubleshoot the installation depend on the stage of the installation.
One recommendation is to ssh to the VM and check the logs of the agent-based installer.
agent-based installer will start assisted-service pod which is a good source of information.
```bash
RENDEZVOUS_IP=192.168.122.118

# ssh to the VM
ssh core@$RENDEZVOUS_IP

# view the logs of the agent-based installer
sudo journalctl -u agent.service

# view the pods started by the agent-based installer
sudo podman ps

# view the logs of the assisted-service container
sudo podman logs service
```

If the installation fails, the assisted-service API should be used to query the failure reason.
```bash
# A single infra env is created
INFRA_ENV_ID=$(curl -s http://$RENDEZVOUS_IP:8090/api/assisted-install/v2/infra-envs/ | jq -r .[].id)

# View host status info (for SNO, there is only one host)
curl -s  http://$RENDEZVOUS_IP:8090/api/assisted-install/v2/infra-envs/${INFRA_ENV_ID}/hosts | jq -r .[].status_info

# In case of a disk problem, the disk inventory can be used to check the disk details
curl -s  http://$RENDEZVOUS_IP:8090/api/assisted-install/v2/infra-envs/${INFRA_ENV_ID}/hosts | jq -r  .[].inventory  | jq .disks

# View cluster status info
CLUSTER_ID=$(curl -s  http://$RENDEZVOUS_IP:8090/api/assisted-install/v2/clusters | jq -r  .[].id)
curl -s  http://$RENDEZVOUS_IP:8090/api/assisted-install/v2/clusters/${CLUSTER_ID} | jq -r .status_info
```

# Other scripts in this project
There are additional two scripts in this project:
* `patch_release_version.sh` - patches the release version of openshift-installer. This script should be run after openshift-installer was built
  based on the tailored images of assisted-installer-service and assisted-installer-agent.
* `create_agent_agent.sh` - creates an agent ISO image using the patched openshift-installer.