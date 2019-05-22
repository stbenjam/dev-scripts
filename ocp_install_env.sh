eval "$(go env)"

export OPENSHIFT_INSTALL_PATH="$GOPATH/src/github.com/openshift-metalkube/kni-installer"
export OPENSHIFT_INSTALL_DATA="$OPENSHIFT_INSTALL_PATH/data/data"
export BASE_DOMAIN=${BASE_DOMAIN:-test.metalkube.org}
export CLUSTER_NAME=${CLUSTER_NAME:-ostest}
export CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"
export SSH_PUB_KEY="${SSH_PUB_KEY:-$(cat $HOME/.ssh/id_rsa.pub)}"
export EXTERNAL_SUBNET="192.168.111.0/24"

#
# See https://origin-release.svc.ci.openshift.org/ for release details
#
# The release we default to here is pinned and known to work with our current
# version of kni-installer.
#
export OPENSHIFT_RELEASE_IMAGE="registry.svc.ci.openshift.org/kni/release:4.1.0-rc.5-kni.1"

function extract_installer() {
    local release_image
    local outdir

    release_image="$1"
    outdir="$2"

    extract_dir=$(mktemp -d "installer--XXXXXXXXXX")


    echo "${PULL_SECRET}" > "${extract_dir}/pullsecret"
    oc adm release extract --registry-config "${extract_dir}/pullsecret" --command=openshift-install --to "${extract_dir}" "${release_image}"
    mv "${extract_dir}/openshift-install" "${outdir}"
    export OPENSHIFT_INSTALLER="${outdir}/openshift-install"

    rm -rf "${extract_dir}"
}

function clone_installer() {
  # Clone repo, if not already present
  if [[ ! -d $OPENSHIFT_INSTALL_PATH ]]; then
    sync_repo_and_patch github.com/openshift-metalkube/kni-installer https://github.com/openshift-metalkube/kni-installer.git
  fi
}

function build_installer() {
  # Build installer
  pushd .
  cd $OPENSHIFT_INSTALL_PATH
  RELEASE_IMAGE="$OPENSHIFT_RELEASE_IMAGE" TAGS="libvirt ironic" hack/build.sh
  popd

  export OPENSHIFT_INSTALLER="$OPENSHIFT_INSTALL_PATH/bin/kni-install"
}

function generate_ocp_install_config() {
    local outdir

    outdir="$1"

    cat > "${outdir}/install-config.yaml" << EOF
apiVersion: v1beta4
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- name: worker
  replicas: ${NUM_WORKERS}
controlPlane:
  name: master
  replicas: ${NUM_MASTERS}
platform:
  baremetal:
    nodes:
$(master_node_map_to_install_config $NUM_MASTERS)
    master_configuration:
      image_source: "http://172.22.0.1/images/$RHCOS_IMAGE_FILENAME_LATEST"
      image_checksum: $(curl http://172.22.0.1/images/$RHCOS_IMAGE_FILENAME_LATEST.md5sum)
      root_gb: 25
pullSecret: |
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
}
