#!/usr/bin/env bash
set -x
set -e

source logging.sh
source utils.sh
source common.sh
source ocp_install_env.sh

if [[ $EXTRACT_BINARIES == "True" ]];
then
  # Extract an updated client tools from the release image
  extract_oc "${OPENSHIFT_RELEASE_IMAGE}"
fi

mkdir -p $OCP_DIR

if [ -z "$KNI_INSTALL_FROM_GIT" ]; then
  if [[ $EXTRACT_BINARIES == "True" ]];
  then
    # Extract openshift-install from the release image
    extract_installer "${OPENSHIFT_RELEASE_IMAGE}" $OCP_DIR
  fi
else
  # Clone and build the installer from source
  clone_installer
  build_installer
fi
