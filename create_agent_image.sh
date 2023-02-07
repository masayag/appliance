#!/bin/bash

# Verify 3 parameters provided to this script: working directory, pull secret, and SSH pub-key
if [ $# -ne 3 ]; then
    echo "Usage: $0 <working directory> <pull-secret-file> <ssh-pub-key-file>"
    exit 1
fi

# Verify working directory exists
if [ ! -d $1 ]; then
    echo "Working directory $1 does not exist"
    exit 1
fi

# Verify pull secret file exists
if [ ! -f $2 ]; then
    echo "Pull secret file $2 does not exist"
    exit 1
fi

# Verify pull secret is a valid json file
if ! jq empty $2 > /dev/null 2>&1; then
    echo "Pull secret file $2 is not a valid json file"
    exit 1
fi

# Verify SSH pub-key file exists
if [ ! -f $3 ]; then
    echo "SSH pub-key file $3 does not exist"
    exit 1
fi

# Verify openshift-install binary exists
if [ ! -f /home/$USER/work/installer/bin/openshift-install ]; then
    echo "openshift-install binary does not exist"
    exit 1
fi

# read value from file into env var for pull-secret
export PULL_SECRET=$(cat $2)

# read value from file into env var for SSH pub-key
export SSH_PUB_KEY=$(cat $3)

read -r -d '' installconfig << EOL
apiVersion: v1
baseDomain: appliance.com
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: 0
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 1
metadata:
  name: appliance
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 192.168.122.0/24
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_PUB_KEY}'
EOL

read -r -d '' agentconfig << EOL
apiVersion: v1alpha1
metadata:
  name: appliance
rendezvousIP: 192.168.122.116
hosts:
  - hostname: sno
    installerArgs: '["--save-partlabel", "agent*", "--save-partlabel", "rhcos-*"]'
    interfaces:
     - name: enp1s0
       macAddress: 52:54:00:e7:05:72
    networkConfig:
      interfaces:
        - name: enp1s0
          type: ethernet
          state: up
          mac-address: 52:54:00:e7:05:72
          ipv4:
            enabled: true
            dhcp: true
EOL

workdir=$1
echo "${installconfig}" >$workdir/install-config.yaml
echo "${agentconfig}" >$workdir/agent-config.yaml
/home/$USER/work/installer/bin/openshift-install agent create image --log-level debug --dir $workdir

# recreate install-config.yaml and agent-config.yaml that were removed by openshift-install
echo "${installconfig}" >$workdir/install-config.yaml
echo "${agentconfig}" >$workdir/agent-config.yaml

