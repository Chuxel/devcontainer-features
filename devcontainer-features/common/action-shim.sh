# This file is intended to be sourced from other scripts and assumes relative pathing.

run_action() {
    local feature_id="$1"
    local action_release_url="$2"
    local target_path="${3:-/tmp/action-shim/tool-cache}"
    local profile_d="${4:-/usr/local/etc/dev-container-features/profile.d}"

    local orig_cwd="$(pwd)"
    local orig_path="$PATH"

    export GITHUB_ACTION_PATH="/tmp/action-shim/${feature-id}"
    mkdir -p "${GITHUB_ACTION_PATH}" "${target_path}" "${profile_d}" /tmp/action-shim/node /tmp/action-shim/npm-cache /tmp/action-shim/runner-temp
    # If no node version, grab one...
    if ! type node > /dev/null 2>&1; then
        echo "Downloading dependencies..."
        local node_base_url=https://nodejs.org/dist
        local node_version="16.14.0"
        local node_architecture="$(uname -m)"
        case "${node_architecture}" in
            x86_64)
                node_architecture="x64"
                ;;
            aarch64 | armv8l)
                node_architecture="arm64"
                ;;
        esac
        local node_url="${node_base_url}/v${node_version}/node-v${node_version}-linux-${node_architecture}.tar.gz"
        curl -sSLf "${node_url}" -o /tmp/action-shim/node/node.tar.gz
        tar --strip-components 1 -xzf /tmp/action-shim/node/node.tar.gz -C /tmp/action-shim/node
        export PATH="/tmp/action-shim/node/bin:${PATH}"
    fi

    echo "Downloading action..."
    curl -sSLf "${action_release_url}" -o "${GITHUB_ACTION_PATH}/action.tar.gz"
    tar --strip-components 1 -xzf "${GITHUB_ACTION_PATH}/action.tar.gz" -C "${GITHUB_ACTION_PATH}"
    if [ -e "${GITHUB_ACTION_PATH}/action.yaml" ]; then
        mv "${GITHUB_ACTION_PATH}/action.yaml" "${GITHUB_ACTION_PATH}/action.yml"
    fi

    echo "Executing action..."
    export ACTION_SHIM_TARGET_PATH="${target_path}"
    export ACTION_SHIM_PROFILE_D="${profile_d}"
    export ACTIONS_SHIM_FEATURE_ID="${feature_id}"    
    export RUNNER_TOOL_CACHE="${target_path}"
    export RUNNER_TEMP="/tmp/action-shim/runner-temp"
    local shim_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/action-shim" && pwd)"
    cd "${shim_path}"
    npm install --cache /tmp/action-shim/npm-cache > /tmp/action-shim/npm-cache/install.log 2>&1 || (cat /tmp/action-shim/npm-cache/install.log; exit 1)
    cd "${orig_cwd}"
    node "${shim_path}/action-shim.js" | tee /tmp/action-shim/runner-temp/output.log

    # Source the profile.d script to add env vars for other steps
    echo "Sourcing profile.d script..."
    export PATH="${orig_path}"
    . "${profile_d}/action-${feature_id}-env.sh"
}