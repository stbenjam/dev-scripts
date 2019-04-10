#!/usr/bin/env bash
set -xe

source common.sh

# Get the build name that kni-installer is using
eval "$(go env)"
export INSTALLER_PATH=$GOPATH/src/github.com/openshift-metalkube/kni-installer
eval $(grep "RHCOS_BUILD_NAME=" $INSTALLER_PATH/hack/build.sh)

export RHCOS_IMAGE_URL=${RHCOS_IMAGE_URL:-"https://releases-rhcos.svc.ci.openshift.org/storage/releases/ootpa/"}
export RHCOS_IMAGE_FILENAME_OPENSTACK_GZ="$(curl ${RHCOS_IMAGE_URL}/${RHCOS_BUILD_NAME}/meta.json | jq -r '.images.openstack.path')"
export RHCOS_IMAGE_NAME=$(echo $RHCOS_IMAGE_FILENAME_OPENSTACK_GZ | sed -e 's/-openstack.*//')
# FIXME(shardy) - we need to download the -openstack as its needed
# for the baremetal nodes so we get config drive support,
# or perhaps a completely new image?
export RHCOS_IMAGE_FILENAME_OPENSTACK="${RHCOS_IMAGE_NAME}-openstack.qcow2"
export RHCOS_IMAGE_FILENAME_COMPRESSED="${RHCOS_IMAGE_NAME}-compressed.qcow2"
export RHCOS_IMAGE_FILENAME="rhcos-ootpa-${RHCOS_BUILD_NAME}.qcow2"

function download_images() {
  mkdir -p "$IRONIC_DATA_DIR/html/images"
  pushd "$IRONIC_DATA_DIR/html/images"
  if [ ! -f "${RHCOS_IMAGE_FILENAME_OPENSTACK}" ]; then
      curl --insecure --compressed -L -o "${RHCOS_IMAGE_FILENAME_OPENSTACK}" "${RHCOS_IMAGE_URL}/${RHCOS_IMAGE_VERSION}/${RHCOS_IMAGE_FILENAME_OPENSTACK}"
  fi

  if [ ! -f ironic-python-agent.initramfs ]; then
      curl --insecure --compressed -L https://images.rdoproject.org/master/rdo_trunk/current-tripleo-rdo/ironic-python-agent.tar | tar -xf -
  fi

  popd
}
