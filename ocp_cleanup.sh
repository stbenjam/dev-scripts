#!/bin/bash
set -x

source logging.sh
source common.sh
source network.sh
source ocp_install_env.sh
source validation.sh

early_cleanup_validation

sudo systemctl stop fix_certs.timer

if [ -d ${OCP_DIR} ]; then
    ${OCP_DIR}/openshift-install --dir ${OCP_DIR} --log-level=debug destroy bootstrap
    ${OCP_DIR}/openshift-install --dir ${OCP_DIR} --log-level=debug destroy cluster
    rm -rf ${OCP_DIR}
fi

sudo rm -rf /etc/NetworkManager/dnsmasq.d/openshift-${CLUSTER_NAME}.conf

# Cleanup ssh keys for baremetal network
if [ -f $HOME/.ssh/known_hosts ]; then
    EXT_SUB_V4=$(echo "${EXTERNAL_SUBNET_V4}" | cut -d"/" -f1 | sed "s/0$//")
    if [ -n "${EXT_SUB_V4}" ]; then
        sed -i "/^${EXT_SUB_V4}/d" $HOME/.ssh/known_hosts
    fi
    EXT_SUB_V6=$(echo "${EXTERNAL_SUBNET_V6}" | cut -d"/" -f1 | sed "s/0$//")
    if [ -n "${EXT_SUB_V6}" ]; then
        sed -i "/^${EXT_SUB_V6}/d" $HOME/.ssh/known_hosts
    fi
    PRO_SUB=$(echo "${PROVISIONING_NETWORK}" | cut -d"/" -f1 | sed "s/0$//")
    if [ -n "${PRO_SUB}" ]; then
        sed -i "/^${PRO_SUB}/d" $HOME/.ssh/known_hosts
    fi
    sed -i "/^api.${CLUSTER_DOMAIN}/d" $HOME/.ssh/known_hosts
fi

if test -f assets/templates/98_master-chronyd-redhat.yaml ; then
    rm -f assets/templates/98_master-chronyd-redhat.yaml
fi
if test -f assets/templates/98_worker-chronyd-redhat.yaml ; then
    rm -f assets/templates/98_worker-chronyd-redhat.yaml
fi

# If the installer fails before terraform completes the destroy bootstrap
# cleanup doesn't clean up the VM/volumes created..
for vm in $(sudo virsh list --all --name | grep "^${CLUSTER_NAME}.*bootstrap"); do
  sudo virsh destroy $vm
  sudo virsh undefine $vm --remove-all-storage
done

# For some reason --remove-all-storage doesn't actually remove the storage...
if [ -d /var/lib/libvirt/openshift-images ]; then
  sudo rm -fr /var/lib/libvirt/openshift-images/${CLUSTER_NAME}-*
fi

# The .ign volume isn't deleted via --remove-all-storage
VOLS="$(sudo virsh vol-list --pool default | awk '{print $1}' | grep "^${CLUSTER_NAME}.*bootstrap")"
for v in $VOLS; do
  sudo virsh vol-delete $v --pool default
done

if [ -d assets/generated ]; then
  rm -rf assets/generated
fi

# Remove squid container
sudo podman ps | grep -w "squid$" && sudo podman kill squid || true
sudo podman ps -a | grep -w "squid$" && sudo podman rm squid -f || true
