#!/usr/bin/bash

set -eux
source utils.sh

# Note This logic will likely run in a container (on the bootstrap VM)
# for the final solution, but for now we'll prototype the workflow here
instack="ocp/master_nodes.json"
export OS_TOKEN=fake-token
export OS_URL=http://ostest-api.test.metalkube.org:6385/

wait_for_json ironic \
    "${OS_URL}/v1/nodes" \
    10 \
    -H "Accept: application/json" -H "Content-Type: application/json" -H "User-Agent: wait-for-json" -H "X-Auth-Token: $OS_TOKEN"

# Clean previously env
nodes=$(openstack baremetal node list)
for node in $(jq -r .nodes[].name ${instack}); do
  if [[ $nodes =~ $node ]]; then
    openstack baremetal node undeploy $node;
    openstack baremetal node delete $node;
  fi;
done

openstack baremetal create ocp/master_nodes.json
mkdir -p configdrive/openstack/latest
cp ocp/master.ign configdrive/openstack/latest/user_data
for node in $(jq -r .nodes[].name ocp/master_nodes.json); do

  # FIXME(shardy) we should parameterize the image and checksum (or calculate the latter)
  # Change to sda if using BM
  openstack baremetal node set $node --instance-info image_source=http://172.22.0.1/images/redhat-coreos-maipo-47.284-openstack.qcow2 --instance-info image_checksum=2a38fafe0b9465937955e4d054b8db3a --instance-info root_gb=25 --property root_device='{"name": "/dev/vda"}'
  openstack baremetal node manage $node --wait
  openstack baremetal node provide $node --wait
  openstack baremetal node deploy --config-drive configdrive $node
done

# FIXME(shardy) we should wait for the node deploy to complete (or fail)
