#!/bin/bash
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
arch=$(uname -m)

case $arch in
    x86_64)
        arch=amd64
        ;;
    armv8l | aarch64)
        arch=arm64
        ;;
    *)
        echo "Unsupported architecture: $arch"
        exit 1
        ;;
esac

if [ -e "${script_dir}/devpacker-linux-${arch}" ]; then
    "${script_dir}/devpacker-linux-${arch}" _internal detect "$@"
    exit $?
fi

echo "Unable to find devpacker binary for ${arch}!"