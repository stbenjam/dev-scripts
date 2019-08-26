eval "$(go env)"

export OPENSHIFT_INSTALL_PATH="$GOPATH/src/github.com/openshift/installer"
export OPENSHIFT_INSTALL_DATA="$OPENSHIFT_INSTALL_PATH/data/data"
export BASE_DOMAIN=${BASE_DOMAIN:-test.metalkube.org}
export CLUSTER_NAME=${CLUSTER_NAME:-ostest}
export CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"
export SSH_PUB_KEY="${SSH_PUB_KEY:-$(cat $HOME/.ssh/id_rsa.pub)}"
export EXTERNAL_SUBNET=${EXTERNAL_SUBNET:-"192.168.111.0/24"}
export DNS_VIP=${DNS_VIP:-"192.168.111.2"}

#
# See https://origin-release.svc.ci.openshift.org/ for release details
#
export OPENSHIFT_RELEASE_IMAGE="${OPENSHIFT_RELEASE_IMAGE:-registry.svc.ci.openshift.org/ocp/release:4.2}"

function extract_installer() {
    local release_image
    local outdir

    release_image="$1"
    outdir="$2"

    extract_dir=$(mktemp -d "installer--XXXXXXXXXX")
    pullsecret_file=$(mktemp "pullsecret--XXXXXXXXXX")

    echo "${PULL_SECRET}" > "${pullsecret_file}"
    oc adm release extract --registry-config "${pullsecret_file}" "$release_image" --command=openshift-baremetal-install --to "${extract_dir}"

    mv "${extract_dir}/openshift-baremetal-install" "${outdir}"
    export OPENSHIFT_INSTALLER="${outdir}/openshift-baremetal-install"

    rm -rf "${extract_dir}"
    rm -rf "${pullsecret_file}"
}

function clone_installer() {
  # Clone repo, if not already present
  if [[ ! -d $OPENSHIFT_INSTALL_PATH ]]; then
    sync_repo_and_patch go/src/github.com/openshift/installer https://github.com/openshift/installer.git
  fi
}

function build_installer() {
  # Build installer
  pushd .
  cd $OPENSHIFT_INSTALL_PATH
  TAGS="libvirt baremetal" hack/build.sh
  popd

  export OPENSHIFT_INSTALLER="$OPENSHIFT_INSTALL_PATH/bin/openshift-install"
}

function generate_ocp_install_config() {
    local outdir

    outdir="$1"

    deploy_kernel=$(master_node_val 0 "driver_info.deploy_kernel")
    deploy_ramdisk=$(master_node_val 0 "driver_info.deploy_ramdisk")

    # Always deploy with 0 workers by default.  We do not yet support
    # automatically deploying workers at install time anyway.  We can scale up
    # the worker MachineSet after deploying the baremetal-operator
    #
    # TODO - Change worker replicas to ${NUM_WORKERS} once the machine-api-operator
    # deploys the baremetal-operator

    cat > "${outdir}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
networking:
  machineCIDR: ${EXTERNAL_SUBNET}
metadata:
  name: ${CLUSTER_NAME}
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: ${NUM_MASTERS}
  platform:
    baremetal: {}
platform:
  baremetal:
    dnsVIP: ${DNS_VIP}
    hosts:
$(master_node_map_to_install_config $NUM_MASTERS)
pullSecret: |
  $(echo $PULL_SECRET | jq -c .)
sshKey: |
  ${SSH_PUB_KEY}
EOF
}
