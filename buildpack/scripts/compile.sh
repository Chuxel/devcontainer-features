#!/bin/bash
set -e
root_path="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"

build_api_binary()
{
    source="$1"
    binary_name="${2:-"${source}"}"
    cd "${root_path}/${source}"
    GOARCH=amd64 GOOS=linux go build -o "${root_path}/out/bin/${binary_name}-amd64"
    GOARCH=arm64 GOOS=linux go build -o "${root_path}/out/bin/${binary_name}-arm64"
}

mkdir -p out/bin
build_api_binary src buildpackify
chmod +x "${root_path}/out/bin/"/*
