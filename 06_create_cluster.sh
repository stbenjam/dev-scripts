#!/usr/bin/env bash
set -x
set -e

source ocp_install_env.sh
source common.sh
source utils.sh

if [ ! -d ocp ]; then
    mkdir -p ocp
    generate_ocp_install_config ocp
fi

# NOTE: This is equivalent to the external API DNS record pointing the API to the API VIP
export API_VIP=$(dig +noall +answer "api.${CLUSTER_DOMAIN}" @$(network_ip baremetal) | awk '{print $NF}')
echo "address=/api.${CLUSTER_DOMAIN}/${API_VIP}" | sudo tee /etc/NetworkManager/dnsmasq.d/openshift.conf
sudo systemctl reload NetworkManager

# Make sure Ironic is up
export OS_TOKEN=fake-token
export OS_URL=http://localhost:6385/

trap collect_info_on_failure TERM

wait_for_json ironic \
    "${OS_URL}/v1/nodes" \
    10 \
    -H "Accept: application/json" -H "Content-Type: application/json" -H "User-Agent: wait-for-json" -H "X-Auth-Token: $OS_TOKEN"

if [ $(sudo podman ps | grep -w -e "ironic$" -e "ironic-inspector$" -e "dnsmasq" -e "httpd" | wc -l) != 4 ]; then
    echo "Can't find required containers"
    exit 1
fi

# Call kni-installer to deploy the bootstrap node and masters
create_cluster ocp
sleep 10

echo "Master nodes up, you can ssh to the following IPs with core@<IP>"
sudo virsh net-dhcp-leases baremetal

# disable NoSchedule taints for masters until we have workers deployed
for num in 0 1 2; do
  oc adm taint nodes master-${num} node-role.kubernetes.io/master:NoSchedule-
  oc label node master-${num} node-role.kubernetes.io/worker=''
done

echo "Cluster up, you can interact with it via oc --config ocp/auth/kubeconfig <command>"
