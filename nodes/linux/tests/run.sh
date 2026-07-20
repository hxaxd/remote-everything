#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
node_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
exec bash "$node_root/../../internal/nodecore/testharness/run_unix.sh" "$node_root" linux
