.PHONY: default all requirements configure ironic ocp_run register_hosts clean ocp_cleanup ironic_cleanup host_cleanup bell csr_hack
default: wrapper
all: requirements configure build_installer ironic ocp_run register_hosts csr_hack bell

# Wrapper is an enhancement that sources common.sh, and calls `make all`. This ensures
# variables that require external access or derivation are only done once. A small optimization
# that prevents us from hitting the openshift API multiple times, for example.
wrapper:
	./wrapper.sh

redeploy: ocp_cleanup ironic_cleanup build_installer ironic ocp_run register_hosts csr_hack bell

requirements:
	./01_install_requirements.sh

configure:
	./02_configure_host.sh

build_installer:
	./03_build_installer.sh

ironic:
	./04_setup_ironic.sh

ocp_run:
	./06_create_cluster.sh

register_hosts:
	./11_register_hosts.sh

csr_hack:
	./12_csr_hack.sh

clean: ocp_cleanup ironic_cleanup host_cleanup

ocp_cleanup:
	./ocp_cleanup.sh

ironic_cleanup:
	./ironic_cleanup.sh

host_cleanup:
	./host_cleanup.sh

bell:
	@echo "Done!" $$'\a'
