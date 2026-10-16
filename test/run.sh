#!/bin/bash
# Run the kit's tests on Linux, as root — the droplet's environment (GNU coreutils).
set -euo pipefail
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD:/kit:ro" ubuntu:24.04 bash -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq bats git >/dev/null 2>&1
  cp -r /kit /tmp/kit && cd /tmp/kit && bats test/'
