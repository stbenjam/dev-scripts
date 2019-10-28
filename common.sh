#!/bin/bash

[[ ":$PATH:" != *":/usr/local/go/bin:"* ]] && export PATH=$PATH:/usr/local/go/bin
eval "$(go env)"

# Ensure if a go program crashes we get a coredump
#
# To get the dump, use coredumpctl:
#   coredumpctl -o oc.coredump dump /usr/local/bin/oc
#
export GOTRACEBACK=crash

# Do not use pigz due to race condition in vendored docker code
# that oc uses.
# See: https://github.com/openshift/oc/issues/58,
#      https://github.com/moby/moby/issues/39859
export MOBY_DISABLE_PIGZ=true

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

#
# See https://openshift-release.svc.ci.openshift.org for release details
#
LATEST_CI_IMAGE=$(curl https://openshift-release.svc.ci.openshift.org/api/v1/releasestream/4.3.0-0.ci/latest | grep -o 'registry.svc.ci.openshift.org[^"]\+')
export OPENSHIFT_RELEASE_IMAGE="${OPENSHIFT_RELEASE_IMAGE:-$LATEST_CI_IMAGE}"
export OPENSHIFT_INSTALL_PATH="$GOPATH/src/github.com/openshift/installer"

# Switch Container Images to upstream, Installer defaults these to the openshift version
if [ "${UPSTREAM_IRONIC:-false}" != "false" ] ; then
    export IRONIC_LOCAL_IMAGE=${IRONIC_LOCAL_IMAGE:-"quay.io/metal3-io/ironic:master"}
    export IRONIC_INSPECTOR_LOCAL_IMAGE=${IRONIC_INSPECTOR_LOCAL_IMAGE:-"quay.io/metal3-io/ironic-inspector:master"}
    export IRONIC_IPA_DOWNLOADER_LOCAL_IMAGE=${IRONIC_IPA_DOWNLOADER_LOCAL_IMAGE:-"quay.io/metal3-io/ironic-ipa-downloader:master"}
    export IRONIC_STATIC_IP_MANAGER_LOCAL_IMAGE=${IRONIC_STATIC_IP_MANAGER_LOCAL_IMAGE:-"quay.io/metal3-io/static-ip-manager"}
    export BAREMETAL_OPERATOR_LOCAL_IMAGE=${BAREMETAL_OPERATOR_LOCAL_IMAGE:-"quay.io/metal3-io/baremetal-operator"}
fi

if env | grep -q "_LOCAL_IMAGE=" ; then
    # We need a custome installer (allows http image pulls for local images)
    KNI_INSTALL_FROM_GIT=true
fi

if [ -z "$KNI_INSTALL_FROM_GIT" ]; then
    export OPENSHIFT_INSTALLER=${OPENSHIFT_INSTALLER:-ocp/openshift-baremetal-install}
 else
    export OPENSHIFT_INSTALLER=${OPENSHIFT_INSTALLER:-$OPENSHIFT_INSTALL_PATH/bin/openshift-install}

    # This is an URI so we can use curl for either the file on GitHub, or locally
    export OPENSHIFT_INSTALLER_RHCOS=${OPENSHIFT_INSTALLER_RHCOS:-file:///$OPENSHIFT_INSTALL_PATH/data/data/rhcos.json}

    # The installer defaults to origin/CI releases, e.g registry.svc.ci.openshift.org/origin/release:4.3
    # Which currently don't work for us ref
    # https://github.com/openshift/ironic-inspector-image/pull/17
    # Until we can align OPENSHIFT_RELEASE_IMAGE with the installer default, we still need
    # to set OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE for openshift-install source builds
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${OPENSHIFT_RELEASE_IMAGE}"
fi

if env | grep -q "_LOCAL_IMAGE=" ; then
    # We're going to be using a locally modified release image
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="192.168.111.1:5000/localimages/local-release-image:latest" 
fi

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

# Ironic vars (Image can be use <NAME>_LOCAL_IMAGE to override)
export IRONIC_IMAGE="quay.io/metal3-io/ironic:master"
export IRONIC_IPA_DOWNLOADER_IMAGE="quay.io/metal3-io/ironic-ipa-downloader:master"
export IRONIC_DATA_DIR="$WORKING_DIR/ironic"

# VBMC and Redfish images
export VBMC_IMAGE=${VBMC_IMAGE:-"quay.io/metal3-io/vbmc"}
export SUSHY_TOOLS_IMAGE=${SUSHY_TOOLS_IMAGE:-"quay.io/metal3-io/sushy-tools"}

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
VER=$(awk -F= '/^VERSION_ID=/ { print $2 }' /etc/os-release | tr -d '"' | cut -f1 -d'.')
if [[ ${VER} -ne 7 ]] && [[ ${VER} -ne 8 ]]; then
  echo "Required CentOS 7 / RHEL 7 / RHEL 8"
  exit 1
fi

if grep -q "Red Hat Enterprise Linux release 8" /etc/redhat-release 2>/dev/null ; then
    export RHEL8="True"
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
  sudo mkdir -p "$WORKING_DIR"
  sudo chown "${USER}:${USER}" "$WORKING_DIR"
  chmod 755 "$WORKING_DIR"
fi

if [ ! -d "$IRONIC_DATA_DIR" ]; then
  echo "Creating Ironic Data Dir"
  sudo mkdir "$IRONIC_DATA_DIR"
  sudo chown "${USER}:${USER}" "$IRONIC_DATA_DIR"
  chmod 755 "$IRONIC_DATA_DIR"
fi

# Defaults the variable to enable testing a custom machine-api-operator image
export TEST_CUSTOM_MAO=${TEST_CUSTOM_MAO:-false}
