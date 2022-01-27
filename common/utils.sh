# Function to run apt-get if needed
apt_get_update_if_needed()
{
    export DEBIAN_FRONTEND=noninteractive
    if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls /var/lib/apt/lists/ | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update
    else
        echo "Skipping apt-get update."
    fi
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        apt_get_update_if_needed
        apt-get -y install --no-install-recommends "$@"
    fi
}

# If in automatic mode, determine if a user already exists, if not use vscode
detect_user() {
    local user_variable_name=${1:-username}
    local user_variable_value=${!user_variable_name}
    local possible_users=${2:-("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")}
    local uid_variable_name=${3:-user_uid}
    local gid_variable_name=${4:-user_gid}
    if [ "${user_variable_value}" = "auto" ] || [ "${user_variable_value}" = "automatic" ]; then
        declare -g ${user_variable_name}=vscode
        for current_user in ${possible_users[@]}; do
            if id -u ${current_user} > /dev/null 2>&1; then
                declare -g ${user_variable_nam}e=${current_user}
                break
            fi
        done
        if [ "${user_variable_value}" = "" ]; then
            declare -g ${user_variable_name}=vscode
        fi
    elif [ "${user_variable_value}" = "none" ]; then
        declare -g ${user_variable_name}=root
        declare -g ${uid_variable_name}=0
        declare -g ${gid_variable_name}=0
    fi
}

# Figure out correct version of a three part version number is not passed
find_version_from_git_tags() {
    local variable_name=$1
    local requested_version=${!variable_name}
    if [ "${requested_version}" = "none" ]; then return; fi
    local repository=$2
    local prefix=${3:-"tags/v"}
    local separator=${4:-"."}
    local last_part_optional=${5:-"false"}    
    if [ "$(echo "${requested_version}" | grep -o "." | wc -l)" != "2" ]; then
        local escaped_separator=${separator//./\\.}
        local last_part
        if [ "${last_part_optional}" = "true" ]; then
            last_part="(${escaped_separator}[0-9]+)?"
        else
            last_part="${escaped_separator}[0-9]+"
        fi
        local regex="${prefix}\\K[0-9]+${escaped_separator}[0-9]+${last_part}$"
        local version_list="$(git ls-remote --tags ${repository} | grep -oP "${regex}" | tr -d ' ' | tr "${separator}" "." | sort -rV)"
        if [ "${requested_version}" = "latest" ] || [ "${requested_version}" = "current" ] || [ "${requested_version}" = "lts" ]; then
            declare -g ${variable_name}="$(echo "${version_list}" | head -n 1)"
        else
            set +e
            declare -g ${variable_name}="$(echo "${version_list}" | grep -E -m 1 "^${requested_version//./\\.}([\\.\\s]|$)")"
            set -e
        fi
    fi
    if [ -z "${!variable_name}" ] || ! echo "${version_list}" | grep "^${!variable_name//./\\.}$" > /dev/null 2>&1; then
        echo -e "Invalid ${variable_name} value: ${requested_version}\nValid values:\n${version_list}" >&2
        exit 1
    fi
    echo "${variable_name}=${!variable_name}"
}

# Checks if a marker file exists with the correct contents
# check_marker <marker path> [argument to be validated]...
check_marker() {
    local marker_path="$1"
    shift
    local verifier_string="$(echo "$@")"
    if [ -e "${marker_path}" ] && [ "${verifier_string}" = "$(cat ${marker_path})" ]; then
        return 1
    else 
        return 0
    fi
}

# Updates marker for future checking
# update_marker <marker path> [argument to be validated]...
update_marker() {
    local marker_path="$1"
    shift
    mkdir -p "$(dirname "${marker_path}")"
    echo "$(echo "$@")" > "${marker_path}"
}

# Checks if command exists, installs it if not
# check_command <command> <package to install>...
check_command() {
    command_to_check=$1
    shift
    if type "${command_to_check}" > /dev/null 2>&1; then
        return 0
    fi
    apt_get_update_if_needed
    apt-get -y install --no-install-recommends "$@"
}

# Converts arguments into expected format for build args and updates a variable called "__retval" with the result
get_buld_arg_env_var_name() {
    local var_name="_BUILD_ARG"
    while [ "$1" != "" ]; do
        var_name="${var_name}_$(echo "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
        shift
    done
    __retval="${var_name}"
}

# set_var_to_option_value <feature id> <option name> <variable name> <default value>
set_var_to_option_value() {
    get_buld_arg_env_var_name "$1" "$2"
    echo "$3=${!__retval:-"$4"}"
    declare -g $3="${!__retval:-"$4"}"
}

# run_if_exists <command> <command arguments>...
run_if_exists() {
    if [ -e "$1" ]; then
        "$@"
    fi
}