#!/bin/bash

eval "$(go env)"

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
USER=`whoami`

# Get variables from the config file
if [ -z "${CONFIG:-}" ]; then
    # See if there's a config_$USER.sh in the SCRIPTDIR
    if [ -f ${SCRIPTDIR}/config_${USER}.sh ]; then
        echo "Using CONFIG ${SCRIPTDIR}/config_${USER}.sh"
        CONFIG="${SCRIPTDIR}/config_${USER}.sh"
    else
        echo "Please run with a configuration environment set."
        echo "eg CONFIG=config_example.sh ./01_all_in_one.sh"
        exit 1
    fi
fi
source $CONFIG

# Set variables
# Additional DNS
ADDN_DNS=${ADDN_DNS:-}
# External interface for routing traffic through the host
EXT_IF=${EXT_IF:-}
# Provisioning interface
PRO_IF=${PRO_IF:-}
# Does libvirt manage the baremetal bridge (including DNS and DHCP)
MANAGE_BR_BRIDGE=${MANAGE_BR_BRIDGE:-y}
# Only manage bridges if is set
MANAGE_PRO_BRIDGE=${MANAGE_PRO_BRIDGE:-y}
MANAGE_INT_BRIDGE=${MANAGE_INT_BRIDGE:-y}
# Internal interface, to bridge virbr0
INT_IF=${INT_IF:-}
#Root disk to deploy coreOS - use /dev/sda on BM
ROOT_DISK_NAME=${ROOT_DISK_NAME-"/dev/sda"}

FILESYSTEM=${FILESYSTEM:="/"}

WORKING_DIR=${WORKING_DIR:-"/opt/dev-scripts"}
NODES_FILE=${NODES_FILE:-"${WORKING_DIR}/ironic_nodes.json"}
NODES_PLATFORM=${NODES_PLATFORM:-"libvirt"}
MASTER_NODES_FILE=${MASTER_NODES_FILE:-"ocp/master_nodes.json"}

export NUM_MASTERS=${NUM_MASTERS:-"3"}
export NUM_WORKERS=${NUM_WORKERS:-"1"}
export VM_EXTRADISKS=${VM_EXTRADISKS:-"false"}

export RHCOS_INSTALLER_IMAGE_URL="https://releases-art-rhcos.svc.ci.openshift.org/art/storage/releases/ootpa/410.8.20190508.1/"
export RHCOS_IMAGE_URL=${RHCOS_IMAGE_URL:-${RHCOS_INSTALLER_IMAGE_URL}}

export RHCOS_IMAGE_FILENAME_OPENSTACK_GZ="$(curl ${RHCOS_IMAGE_URL}/meta.json | jq -r '.images.openstack.path')"
export RHCOS_IMAGE_NAME=$(echo $RHCOS_IMAGE_FILENAME_OPENSTACK_GZ | sed -e 's/-openstack.*//')
# FIXME(shardy) - we need to download the -openstack as its needed
# for the baremetal nodes so we get config drive support,
# or perhaps a completely new image?
export RHCOS_IMAGE_FILENAME_OPENSTACK="${RHCOS_IMAGE_NAME}-openstack.qcow2"
export RHCOS_IMAGE_FILENAME_COMPRESSED="${RHCOS_IMAGE_NAME}-compressed.qcow2"
export RHCOS_IMAGE_FILENAME_LATEST="rhcos-ootpa-latest.qcow2"

# Ironic vars
export IRONIC_IMAGE=${IRONIC_IMAGE:-"quay.io/metal3-io/ironic"}
export IRONIC_INSPECTOR_IMAGE=${IRONIC_INSPECTOR_IMAGE:-"quay.io/metal3-io/ironic-inspector"}
export IRONIC_DATA_DIR="$WORKING_DIR/ironic"

export KUBECONFIG="${SCRIPTDIR}/ocp/auth/kubeconfig"

# Use a cloudy ssh that doesn't do Host Key checking
export SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

# Verify requisites/permissions
# Connect to system libvirt
export LIBVIRT_DEFAULT_URI=qemu:///system
if [ "$USER" != "root" -a "${XDG_RUNTIME_DIR:-}" == "/run/user/0" ] ; then
    echo "Please use a non-root user, WITH a login shell (e.g. su - USER)"
    exit 1
fi

# Check if sudo privileges without password
if ! sudo -n uptime &> /dev/null ; then
  echo "sudo without password is required"
  exit 1
fi

# Check OS
if [[ ! $(awk -F= '/^ID=/ { print $2 }' /etc/os-release | tr -d '"') =~ ^(centos|rhel)$ ]]; then
  echo "Unsupported OS"
  exit 1
fi

# Check CentOS version
if [[ $(awk -F= '/^VERSION_ID=/ { print $2 }' /etc/os-release | tr -d '"' | cut -f1 -d'.') -ne 7 ]]; then
  echo "Required CentOS 7 or RHEL 7"
  exit 1
fi

# Check d_type support
FSTYPE=$(df ${FILESYSTEM} --output=fstype | grep -v Type)

case ${FSTYPE} in
  'ext4'|'btrfs')
  ;;
  'xfs')
    if [[ $(xfs_info ${FILESYSTEM} | grep -q "ftype=1") ]]; then
      echo "Filesystem not supported"
      exit 1
    fi
  ;;
  *)
    echo "Filesystem not supported"
    exit 1
  ;;
esac

# avoid "-z $PULL_SECRET" to ensure the secret is not logged
if [ ${#PULL_SECRET} = 0 ]; then
  echo "No valid PULL_SECRET set in ${CONFIG}"
  echo "Get a valid pull secret (json string) from https://cloud.openshift.com/clusters/install#pull-secret"
  exit 1
fi

if [ ! -d "$WORKING_DIR" ]; then
  echo "Creating Working Dir"
  sudo mkdir "$WORKING_DIR"
fi
sudo chown "${USER}:${USER}" "$WORKING_DIR"
chmod 755 "$WORKING_DIR"

