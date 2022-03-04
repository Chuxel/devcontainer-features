#!/bin/bash
set -e
test_image=${1:-"mcr.microsoft.com/vscode/devcontainers/base:ubuntu"}
interactive="${2:-"false"}"
devcontainer_features_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../devcontainer-features" && pwd)"

if [ "${interactive}" == "true" ]; then
    docker run -it --rm -u root -v "${devcontainer_features_dir}:/features" "${test_image}" bash
else 
    docker run -it --rm -u root -v "${devcontainer_features_dir}:/features" "${test_image}" bash /features/install.sh true
fi