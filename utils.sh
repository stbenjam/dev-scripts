#!/bin/bash

set -o pipefail

function generate_assets() {
  rm -rf assets/generated && mkdir assets/generated
  for file in $(find assets/templates -type f -printf "%P\n"); do
      echo "Templating ${file} to assets/generated/${file}"
      cp assets/{templates,generated}/${file}

      for path in $(yq -r '.spec.config.storage.files[].path' assets/templates/${file} | cut -c 2-); do 
          assets/yaml_patch.py "assets/generated/${file}" "/${path}" "$(cat assets/files/${path} | base64 -w0)"
      done
  done
}

function create_cluster() {
    local assets_dir

    assets_dir="$1"

    cp ${assets_dir}/install-config.yaml{,.tmp}
    $GOPATH/src/github.com/openshift-metalkube/kni-installer/bin/kni-install --dir "${assets_dir}" --log-level=debug create manifests

    generate_assets
    mkdir -p ${assets_dir}/openshift
    cp -rf assets/generated/*.yaml ${assets_dir}/openshift

    cp ${assets_dir}/install-config.yaml{.tmp,}
    $GOPATH/src/github.com/openshift-metalkube/kni-installer/bin/kni-install --dir "${assets_dir}" --log-level=debug create cluster
}

function wait_for_json() {
    local name
    local url
    local curl_opts
    local timeout

    local start_time
    local curr_time
    local time_diff

    name="$1"
    url="$2"
    timeout="$3"
    shift 3
    curl_opts="$@"
    echo -n "Waiting for $name to respond"
    start_time=$(date +%s)
    until curl -g -X GET "$url" "${curl_opts[@]}" 2> /dev/null | jq '.' 2> /dev/null > /dev/null; do
        echo -n "."
        curr_time=$(date +%s)
        time_diff=$(($curr_time - $start_time))
        if [[ $time_diff -gt $timeout ]]; then
            echo "\nTimed out waiting for $name"
            return 1
        fi
        sleep 5
    done
    echo " Success!"
    return 0
}

function network_ip() {
    local network
    local rc

    network="$1"
    ip="$(sudo virsh net-dumpxml "$network" | "${PWD}/pyxpath" "//ip/@address" -)"
    rc=$?
    if [ $rc -ne 0 ]; then
        return $rc
    fi
    echo "$ip"
}

function master_node_val() {
    local n
    local val

    n="$1"
    val="$2"

    jq -r ".nodes[${n}].${val}" $MASTER_NODES_FILE
}

function master_node_to_installer() {
    local master_idx

    master_idx="$1"

    username=$(master_node_val ${master_idx} "driver_info.${driver_prefix}_username")
    password=$(master_node_val ${master_idx} "driver_info.${driver_prefix}_password")
    address=$(master_node_val ${master_idx} "driver_info.${driver_prefix}_address")
    port=$(master_node_val ${master_idx} "driver_info.${driver_prefix}_port // \"\"")
    driver=$(master_node_val ${master_idx} "driver")

    if [ $driver == "ipmi" ] ; then
		    if [ -n "$port" ]; then
					bmc_address="ipmi://${address}:${port}/"
				else
					bmc_address="ipmi://${address}/"
		    fi

        driver=ipmi
        driver_prefix=ipmi
        driver_interface=ipmitool
    elif [ $driver == "idrac" ] ; then
		    if [ -n "$port" ]; then
					bmc_address="idrac://${address}:${port}/"
				else
					bmc_address="idrac://${address}/"
		    fi

        driver=idrac
        driver_prefix=drac
        driver_interface=idrac
    fi

    name=$(master_node_val ${master_idx} "name")
    mac=$(master_node_val ${master_idx} "ports[0].address")
    local_gb=$(master_node_val ${master_idx} "properties.local_gb")
    cpu_arch=$(master_node_val ${master_idx} "properties.cpu_arch")


    deploy_kernel=$(master_node_val ${master_idx} "driver_info.deploy_kernel")
    deploy_ramdisk=$(master_node_val ${master_idx} "driver_info.deploy_ramdisk")

    cat <<EOF
    master_${master_idx}:
      local_gb: "${local_gb}"
      cpu_arch: "${cpu_arch}"
      root_device_name: "${ROOT_DISK}"
      port_address: "${mac}"
      pxe_enabled: "true"
      bmc_address: "${bmc_address}"
      bmc_username: "${username}"
      bmc_password: "${password}"
			deploy_kernel: "${deploy_kernel}"
			deploy_ramdisk: "${deploy_ramdisk}"
      management_interface: "${driver_interface}"
      power_interface: "${driver_interface}"
EOF
}


function collect_info_on_failure() {
    $SSH -o ConnectionAttempts=500 core@$IP sudo journalctl -b -u bootkube
    oc get clusterversion/version
    oc get clusteroperators
    oc get pods --all-namespaces | grep -v Running | grep -v Completed
}

function patch_ep_host_etcd() {
    local host_etcd_ep
    local hostnames
    local address

    declare -a etcd_hosts
    declare -r domain="$1"
    declare -r srv_record="_etcd-server-ssl._tcp.$domain"
    declare -r api_domain="api.$domain"
    host_etcd_ep=$(oc get ep -n kube-system host-etcd -o json | jq -r '{"subsets": .subsets}')
    echo -n "Looking for etcd records"
    while ! host -t SRV "$srv_record" "$api_domain" >/dev/null 2>&1; do
        echo -n "."
        sleep 1
    done
    echo " Found!"

    mapfile -t hostnames < <(dig +noall +answer -t SRV "$srv_record" "@$api_domain" | awk '{print substr($NF, 1, length($NF)-1)}')

    for hostname in "${hostnames[@]}"; do
        address=$(dig +noall +answer "$hostname" "@$api_domain" | awk '$4 == "A" {print $NF}')
        etcd_hosts+=($address\ $hostname)
    done
    patch=$(python -c "$(cat << 'EOF'
import json
import sys
import yaml

patch = json.loads(sys.argv[1])
addresses = []
for entry in sys.argv[2:]:
    ip, hostname = entry.split()

    if '.' in hostname:
        hostname = hostname.split('.')[0]
    addresses.append({'ip': ip, 'hostname': hostname})

# remove old address entries
del patch['subsets'][0]['addresses']
patch['subsets'][0]['addresses'] = addresses
print(yaml.safe_dump(patch))
EOF
    )" "$host_etcd_ep" "${etcd_hosts[@]}")
    oc -n kube-system patch ep/host-etcd --patch "$patch"
}
