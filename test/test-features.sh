#!/bin/bash
set -e
test_image=${1:-"mcr.microsoft.com/vscode/devcontainers/base:ubuntu"}
devcontainer_features_dir="$(dirname "${BASH_SOURCE[0]}")/../devcontainer-features"

docker run -it --rm -u root -v "${devcontainer_features_dir}:/features" "${test_image}" bash /features/install.sh true