#!/usr/bin/env bash
# Wrapper is a hack that sources common.sh before running `make all` to ensure
# that derived variables are calculated and exported once. This is important
# for calls that hit an external API. Instead of hitting the API in each script
# as part of the install, it'll only happen here once.
set -ex

source logging.sh
source common.sh

# Stop logging after we've source common.sh, so the rest of the files are
# logged individually
exec &>$(tty)

make all
