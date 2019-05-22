#!/bin/bash

set -o pipefail

function generate_assets() {
  rm -rf assets/generated && mkdir assets/generated
  for file in $(find assets/templates/ -iname '*.yaml' -type f -printf "%P\n"); do
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

    # Enable terraform debug logging
    export TF_LOG=DEBUG

    cp ${assets_dir}/install-config.yaml{,.tmp}
    $OPENSHIFT_INSTALLER --dir "${assets_dir}" --log-level=debug create manifests

    # TODO - consider adding NTP server config to install-config.yaml instead
    if host clock.redhat.com ; then
        cp assets/templates/99_worker-chronyd-redhat.yaml.optional assets/templates/99_worker-chronyd-redhat.yaml
        cp assets/templates/99_master-chronyd-redhat.yaml.optional assets/templates/99_master-chronyd-redhat.yaml
    fi
    generate_assets
    mkdir -p ${assets_dir}/openshift
    cp -rf assets/generated/*.yaml ${assets_dir}/openshift

    cp ${assets_dir}/install-config.yaml{.tmp,}
    $OPENSHIFT_INSTALLER --dir "${assets_dir}" --log-level=debug create cluster
}

function wait_for_cvo_finish() {
    local assets_dir

    assets_dir="$1"
    $OPENSHIFT_INSTALLER --dir "${assets_dir}" --log-level=debug wait-for install-complete
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

function master_node_map_to_install_config() {
    local num_masters
    num_masters="$1"

    cat <<EOF
      master_nodes:
EOF

    for ((master_idx=0;master_idx<$1;master_idx++)); do
      driver=$(master_node_val ${master_idx} "driver")
      if [ $driver == "ipmi" ] ; then
          driver=ipmi
          driver_prefix=ipmi
          driver_interface=ipmitool
      elif [ $driver == "idrac" ] ; then
          driver=idrac
          driver_prefix=drac
          driver_interface=idrac
      fi

      name=$(master_node_val ${master_idx} "name")
      mac=$(master_node_val ${master_idx} "ports[0].address")
      cat <<EOF
        openshift-master-$master_idx:
          name: $name
          port_address: "${mac}"
          driver: "${driver}"
          management_interface: "${driver_interface}"
          power_interface: "${driver_interface}"
          vendor_interface: "no-vendor"
EOF

    done

    cat <<EOF
      properties:
EOF

    for ((master_idx=0;master_idx<$1;master_idx++)); do
      local_gb=$(master_node_val ${master_idx} "properties.local_gb")
      cpu_arch=$(master_node_val ${master_idx} "properties.cpu_arch")

      cat <<EOF
        openshift-master-$master_idx:
          local_gb: "${local_gb}"
          cpu_arch: "${cpu_arch}"
EOF

    done

    cat <<EOF
      root_devices:
EOF

    [ -n "$ROOT_DISK" ] && ROOT_DISK_NAME="$ROOT_DISK"
    for _hint in ${!ROOT_DISK_*}; do
        [ -z "${!_hint}" ] && continue
        hint_name=${_hint/#ROOT_DISK_/}
        hint_name=${hint_name,,}
        hint_value=${!_hint}
    done

    for ((master_idx=0;master_idx<$1;master_idx++)); do
      cat <<EOF
        openshift-master-$master_idx:
          $hint_name: "${hint_value}"
EOF
    done

    cat <<EOF
      driver_infos:
EOF

    for ((master_idx=0;master_idx<$1;master_idx++)); do
      port=$(master_node_val ${master_idx} "driver_info.${driver_prefix}_port // \"\"")
      username=$(master_node_val ${master_idx} "driver_info.${driver_prefix}_username")
      password=$(master_node_val ${master_idx} "driver_info.${driver_prefix}_password")
      address=$(master_node_val ${master_idx} "driver_info.${driver_prefix}_address")

      deploy_kernel=$(master_node_val ${master_idx} "driver_info.deploy_kernel")
      deploy_ramdisk=$(master_node_val ${master_idx} "driver_info.deploy_ramdisk")

      cat <<EOF
        openshift-master-$master_idx:
EOF

      if [ -n "$port" ]; then
          cat <<EOF
          ${driver_prefix}_port: "${port}"
EOF
      fi

      cat <<EOF
          ${driver_prefix}_username: "${username}"
          ${driver_prefix}_password: "${password}"
          ${driver_prefix}_address: "${address}"
          deploy_kernel:  "${deploy_kernel}"
          deploy_ramdisk: "${deploy_ramdisk}"
EOF

    done
}

function patch_ep_host_etcd() {
    local host_etcd_ep
    local hostnames
    local address

    declare -a etcd_hosts
    declare -r domain="$1"
    declare -r srv_record="_etcd-server-ssl._tcp.$domain"
    declare -r api_domain="api.$domain"
    host_etcd_ep=$(oc get ep -n openshift-etcd host-etcd -o json | jq -r '{"subsets": .subsets}')
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
    oc -n openshift-etcd patch ep/host-etcd --patch "$patch"
}

function sync_repo_and_patch {
    REPO_PATH=${REPO_PATH:-$HOME}
    DEST="${REPO_PATH}/$1"
    figlet "Syncing $1" | lolcat

    if [ ! -d $DEST ]; then
        mkdir -p $DEST
        git clone $2 $DEST
    fi

    pushd $DEST

    git am --abort || true
    git checkout master
    git fetch origin
    git rebase origin/master
    if test "$#" -gt "2" ; then
        git branch -D metalkube || true
        git checkout -b metalkube

        shift; shift;
        for arg in "$@"; do
            curl -L $arg | git am
        done
    fi
    popd
}
