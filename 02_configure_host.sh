#!/usr/bin/env bash
set -xe

source logging.sh
source common.sh
source utils.sh
source ocp_install_env.sh

# Generate user ssh key
if [ ! -f $HOME/.ssh/id_rsa.pub ]; then
    ssh-keygen -f ~/.ssh/id_rsa -P ""
fi

# root needs a private key to talk to libvirt
# See vm-setup/roles/virtbmc/tasks/configure-vbmc.yml
# in https://github.com/metal3-io/metal3-dev-env.git
# FIXME(shardy) this should be in the ansible role ...
if sudo [ ! -f /root/.ssh/id_rsa_virt_power ]; then
  sudo ssh-keygen -f /root/.ssh/id_rsa_virt_power -P ""
  sudo cat /root/.ssh/id_rsa_virt_power.pub | sudo tee -a /root/.ssh/authorized_keys
fi

# This script will create some libvirt VMs do act as "dummy baremetal"
# then configure python-virtualbmc to control them - these can later
# be deployed via the install process similar to how we test TripleO
# Note we copy the playbook so the roles/modules from tripleo-quickstart
# are found without a special ansible.cfg
# FIXME(shardy) output an error message temporarily since we've broken an interface
export VM_NODES_FILE=${VM_NODES_FILE:-}
if [ ! -z "${VM_NODES_FILE}" ]; then
  echo "VM_NODES_FILE is no longer supported"
  echo "Please use NUM_MASTERS, NUM_WORKERS and VM_EXTRADISKS variables instead"
  exit 1
fi

export REPO_PATH=${WORKING_DIR}
sync_repo_and_patch metal3-dev-env https://github.com/metal3-io/metal3-dev-env.git
VM_SETUP_PATH="${REPO_PATH}/metal3-dev-env/vm-setup"

ANSIBLE_FORCE_COLOR=true ansible-playbook \
    -e @vm_setup_vars.yml \
    -e "working_dir=$WORKING_DIR" \
    -e "num_masters=$NUM_MASTERS" \
    -e "num_workers=$NUM_WORKERS" \
    -e "extradisks=$VM_EXTRADISKS" \
    -e "virthost=$HOSTNAME" \
    -e "vm_platform=$NODES_PLATFORM" \
    -e "manage_baremetal=$MANAGE_BR_BRIDGE" \
    -i ${VM_SETUP_PATH}/inventory.ini \
    -b -vvv ${VM_SETUP_PATH}/setup-playbook.yml

# Allow local non-root-user access to libvirt
# Restart libvirtd service to get the new group membership loaded
if ! id $USER | grep -q libvirt; then
  sudo usermod -a -G "libvirt" $USER
  sudo systemctl restart libvirtd
fi

# As per https://github.com/openshift/installer/blob/master/docs/dev/libvirt-howto.md#configure-default-libvirt-storage-pool
# Usually virt-manager/virt-install creates this: https://www.redhat.com/archives/libvir-list/2008-August/msg00179.html
if ! virsh pool-uuid default > /dev/null 2>&1 ; then
    virsh pool-define /dev/stdin <<EOF
<pool type='dir'>
  <name>default</name>
  <target>
    <path>/var/lib/libvirt/images</path>
  </target>
</pool>
EOF
    virsh pool-start default
    virsh pool-autostart default
fi

if [ "${RHEL8}" = "y" ] ; then
    ZONE="\nZONE=libvirt"
fi

if [ "$MANAGE_PRO_BRIDGE" == "y" ]; then
    # Adding an IP address in the libvirt definition for this network results in
    # dnsmasq being run, we don't want that as we have our own dnsmasq, so set
    # the IP address here
    if [ ! -e /etc/sysconfig/network-scripts/ifcfg-provisioning ] ; then
        echo -e "DEVICE=provisioning\nTYPE=Bridge\nONBOOT=yes\nNM_CONTROLLED=no\nBOOTPROTO=static\nIPADDR=172.22.0.1\nNETMASK=255.255.255.0${ZONE}" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-provisioning
    fi
    sudo ifdown provisioning || true
    sudo ifup provisioning

    # Need to pass the provision interface for bare metal
    if [ "$PRO_IF" ]; then
        echo -e "DEVICE=$PRO_IF\nTYPE=Ethernet\nONBOOT=yes\nNM_CONTROLLED=no\nBRIDGE=provisioning" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-$PRO_IF
        sudo ifdown $PRO_IF || true
        sudo ifup $PRO_IF
    fi
fi

if [ "$MANAGE_INT_BRIDGE" == "y" ]; then
    # Create the baremetal bridge
    if [ ! -e /etc/sysconfig/network-scripts/ifcfg-baremetal ] ; then
        echo -e "DEVICE=baremetal\nTYPE=Bridge\nONBOOT=yes\nNM_CONTROLLED=no${ZONE}" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-baremetal
    fi
    sudo ifdown baremetal || true
    sudo ifup baremetal

    # Add the internal interface to it if requests, this may also be the interface providing
    # external access so we need to make sure we maintain dhcp config if its available
    if [ "$INT_IF" ]; then
        echo -e "DEVICE=$INT_IF\nTYPE=Ethernet\nONBOOT=yes\nNM_CONTROLLED=no\nBRIDGE=baremetal" | sudo dd of=/etc/sysconfig/network-scripts/ifcfg-$INT_IF
        if sudo nmap --script broadcast-dhcp-discover -e $INT_IF | grep "IP Offered" ; then
            echo -e "\nBOOTPROTO=dhcp\n" | sudo tee -a /etc/sysconfig/network-scripts/ifcfg-baremetal
            sudo systemctl restart network
        else
           sudo systemctl restart network
        fi
    fi
fi

# restart the libvirt network so it applies an ip to the bridge
if [ "$MANAGE_BR_BRIDGE" == "y" ] ; then
    sudo virsh net-destroy baremetal
    sudo virsh net-start baremetal
    if [ "$INT_IF" ]; then #Need to bring UP the NIC after destroying the libvirt network
        sudo ifup $INT_IF
    fi
fi

# Add firewall rules to ensure the IPA ramdisk can reach httpd, Ironic and the Inspector API on the host
for port in 80 5050 6385 ; do
    if [ "${RHEL8}" = "y" ] ; then
        sudo firewall-cmd --zone=libvirt --add-port=${port}/tcp
        sudo firewall-cmd --zone=libvirt --add-port=${port}/tcp --permanent
    else
        if ! sudo iptables -C INPUT -i provisioning -p tcp -m tcp --dport $port -j ACCEPT > /dev/null 2>&1; then
            sudo iptables -I INPUT -i provisioning -p tcp -m tcp --dport $port -j ACCEPT
        fi
    fi
done

# Allow ipmi to the virtual bmc processes that we just started
if [ "${RHEL8}" = "y" ] ; then
    sudo firewall-cmd --zone=libvirt --add-port=6230-6235/udp
    sudo firewall-cmd --zone=libvirt --add-port=6230-6235/udp --permanent
else
    if ! sudo iptables -C INPUT -i baremetal -p udp -m udp --dport 6230:6235 -j ACCEPT 2>/dev/null ; then
        sudo iptables -I INPUT -i baremetal -p udp -m udp --dport 6230:6235 -j ACCEPT
    fi
fi

#Allow access to dhcp and tftp server for pxeboot
for port in 67 69 ; do
    if [ "${RHEL8}" = "y" ] ; then
        sudo firewall-cmd --zone=libvirt --add-port=${port}/udp
        sudo firewall-cmd --zone=libvirt --add-port=${port}/udp --permanent
    else
        if ! sudo iptables -C INPUT -i provisioning -p udp --dport $port -j ACCEPT 2>/dev/null ; then
            sudo iptables -I INPUT -i provisioning -p udp --dport $port -j ACCEPT
        fi
    fi
done

# mDNS
if [ "${RHEL8}" = "y" ] ; then
    sudo firewall-cmd --zone=libvirt --add-port=5353/udp
    sudo firewall-cmd --zone=libvirt --add-port=5353/udp --permanent
fi

# Need to route traffic from the provisioning host.
if [ "$EXT_IF" ]; then
  sudo iptables -t nat -A POSTROUTING --out-interface $EXT_IF -j MASQUERADE
  sudo iptables -A FORWARD --in-interface baremetal -j ACCEPT
fi

# Add access to backend Facet server from remote locations
if ! sudo iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null ; then
  sudo iptables -I INPUT -p tcp --dport 8080 -j ACCEPT
fi

# Add access to Yarn development server from remote locations
if ! sudo iptables -C INPUT -p tcp --dport 3000 -j ACCEPT 2>/dev/null ; then
  sudo iptables -I INPUT -p tcp --dport 3000 -j ACCEPT
fi

# Switch NetworkManager to internal DNS
if [ "$MANAGE_BR_BRIDGE" == "y" ] ; then
  sudo mkdir -p /etc/NetworkManager/conf.d/
  sudo $(which crudini) --set /etc/NetworkManager/conf.d/dnsmasq.conf main dns dnsmasq
  if [ "$ADDN_DNS" ] ; then
    echo "server=$ADDN_DNS" | sudo tee /etc/NetworkManager/dnsmasq.d/upstream.conf
  fi
  if systemctl is-active --quiet NetworkManager; then
    sudo systemctl reload NetworkManager
  else
    sudo systemctl restart NetworkManager
  fi
fi
