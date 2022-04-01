#!/bin/bash
set -e
# The install.sh script is the installation entrypoint for any features in this repository when used directly (rather than via a Devpack). 
DEV_CONTAINER_FEATURE_SMOKE_TEST="${1:-"${DEV_CONTAINER_FEATURE_SMOKE_TEST-false}"}"
DEV_CONTAINER_CONFIG_DIR="/usr/local/etc/dev-container-features"
DEV_CONTAINER_PROFILE_D="${DEV_CONTAINER_CONFIG_DIR}/profile.d"
DEV_CONTAINER_ENTRYPOINT_D="${DEV_CONTAINER_CONFIG_DIR}/entrypoint.d"
DEV_CONTAINER_MARKERS="${DEV_CONTAINER_CONFIG_DIR}/markers"

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Move to the same directory as this script
cd "$(dirname "${BASH_SOURCE[0]}")"

# Import common utils
. ./common/utils.sh

# The tooling will parse the features.json + user devcontainer, and write 
# any build-time arguments into a feature-set scoped "devcontainer-features.env"
# The author is free to source that file and use it however they would like.
set -a
. ./devcontainer-features.env
set +a

# Detect username for acquire script
username="automatic"
detect_user username

# Syntax: conditional_install <feature_id>
# Executes feature's scripts if _BUILD_ARG_<FEATURE_ID> is set. It will
# automatically change the feature_id to upper case and swap out - for _. It
# expects that there is a folder named <feature_id> that contains the scripts.
conditional_install() {
    local feature_id="$1"
    get_buld_arg_env_var_name "${feature_id}"
    if [ -z "${!__retval}" ]; then
        return 0
    fi
    local feature_bin_dir="./features/${feature_id}/bin"

    # Always set profile.d/exec.d folder name - buildpacks will also set this to their own values
    local feature_id_safe="$(echo "${feature_id}" | tr '[:lower:]' '[:upper:]' | tr '-' '_' )"
    profile_d_build_arg_name="_BUILD_ARG_${feature_id_safe}_PROFILE_D"
    declare -x ${profile_d_build_arg_name}="${DEV_CONTAINER_PROFILE_D}"
    entrypoint_d_build_arg_name="_BUILD_ARG_${feature_id_safe}_ENTRYPOINT_D"
    declare -x ${entrypoint_d_build_arg_name}="${DEV_CONTAINER_ENTRYPOINT_D}"

    # Always set build mode to devcontainer - buildpacks will also set this to an appropriate value
    build_mode_build_arg_name="_BUILD_ARG_${feature_id_safe}_BUILD_MODE"
    declare -x ${build_mode_build_arg_name}="devcontainer"

    # Run the three stages in sequence (assuming each exists). These are:
    # 1. validate-prereqs - Can be expected to run as root and should only include things needed to do acquisition
    # 2. acquire - Core install stage. However, this stage cannot be assumed to be running as root.
    # 3. configure - Runs post-acquisition steps that require root. It's entirely optional.
    echo "(*) Enabling feature \"$1\"..."
    chmod +x "${feature_bin_dir}"/*
    run_if_exists "${feature_bin_dir}/validate-prereqs"
    run_if_exists "${feature_bin_dir}/acquire"
    run_if_exists "${feature_bin_dir}/configure"
    if [ "${DEV_CONTAINER_FEATURE_SMOKE_TEST}" = "true" ] && [ -e "${feature_bin_dir}/test" ]; then
        echo "(*) Testing feature \"$1\"..."
        ${feature_bin_dir}/test
        echo "Passed!"
    fi
    echo
}

# Inject profile.d processing script into /etc/profile.d, /etc/bash.bashrc, /etc/zsh/zshrc
# for scenarios where they are used in a feature that is not installed via the buildpack.
# This makes it compatible with the buildpack spec's support for the same idea. We could
# in concept just adopt this as the approach for dev container features in general as well.
add_env_boostrap_to_file() {
    local filename="$1"
    local check_exists="${2:-$1}"
    local snippet=". ${DEV_CONTAINER_CONFIG_DIR}/env-bootstrap.sh"
    if [ ! -e "${check_exists}" ]; then
        echo "${check_exists} does not exist. Skipping."
        return
    fi
    local existing_file="$(cat "${filename}")"
    if [[ ${existing_file} != *"${snippet}"* ]]; then
        echo "${snippet}" >> "${filename}"
    fi
}

mkdir -p "${DEV_CONTAINER_PROFILE_D}" "${DEV_CONTAINER_ENTRYPOINT_D}" "${DEV_CONTAINER_MARKERS}"
chown "${username}" "${DEV_CONTAINER_PROFILE_D}" "${DEV_CONTAINER_ENTRYPOINT_D}" "${DEV_CONTAINER_MARKERS}"
# Add profile.d script
if [ ! -e "${DEV_CONTAINER_CONFIG_DIR}/env-bootstrap.sh" ]; then
cat << EOF > "${DEV_CONTAINER_CONFIG_DIR}/env-bootstrap.sh"
if [ -z "\${DEV_CONTAINER_ENV_BOOSTRAP_DONE}" ] && [ -d "${DEV_CONTAINER_PROFILE_D}" ]; then
    for script in "${DEV_CONTAINER_PROFILE_D}"/*; do
        if [ -r "\$script" ]; then
            . \$script
        fi
        unset script
    done
    export DEV_CONTAINER_ENV_BOOSTRAP_DONE="true"
fi
EOF
fi
chmod +x "${DEV_CONTAINER_CONFIG_DIR}/env-bootstrap.sh"
symlink_if_ne "${DEV_CONTAINER_CONFIG_DIR}/env-bootstrap.sh" /etc/profile.d/9999-env-bootstrap.sh

# Add entrypoint script
if [ ! -e "${DEV_CONTAINER_CONFIG_DIR}/entrypoint-bootstrap.sh" ]; then
cat << EOF > "${DEV_CONTAINER_CONFIG_DIR}/entrypoint-bootstrap.sh"
#!/bin/bash
if [ -z "\${DEV_CONTAINER_ENTRYPOINTS_DONE}" ] && [ -d "${DEV_CONTAINER_ENTRYPOINT_D}" ] && [ -d "${DEV_CONTAINER_ENTRYPOINT_D}" ] && [ "$(ls "${DEV_CONTAINER_ENTRYPOINT_D}" | wc -l)" != "0" ]; then
    for entrypoint in "${DEV_CONTAINER_ENTRYPOINT_D}"/*; do
        if [ -r "\${entrypoint}" ]; then
            "\${entrypoint}"
        fi
    done
    export DEV_CONTAINER_ENTRYPOINTS_DONE=true
fi
exec "\$@"
EOF
fi
chmod +x "${DEV_CONTAINER_CONFIG_DIR}/entrypoint-bootstrap.sh"

add_env_boostrap_to_file /etc/bash.bashrc
add_env_boostrap_to_file /etc/zsh/zshrc /etc/zsh
add_env_boostrap_to_file /etc/zsh/zprofile /etc/zsh

# Execute actual feature installs
for feature in "$(dirname "{BASH_SOURCE[0]}")"/features/*; do
    conditional_install "$(basename "${feature}")"
done

echo "(*) Done!"
