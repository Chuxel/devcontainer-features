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

# If in automatic mode, determine if a user already exists, if not use root
detect_user() {
    local user_variable_name=${1:-username}
    local possible_users=${2:-("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")}
    if [ "${!user_variable_name}" = "auto" ] || [ "${!user_variable_name}" = "automatic" ]; then
        declare -g ${user_variable_name}=""
        for current_user in ${possible_users[@]}; do
            if id -u "${current_user}" > /dev/null 2>&1; then
                declare -g ${user_variable_name}="${current_user}"
                break
            fi
        done
    fi
    if [ "${!user_variable_name}" = "" ] || [ "${!user_variable_name}" = "none" ] || ! id -u "${!user_variable_name}" > /dev/null 2>&1; then
        declare -g ${user_variable_name}=root
    fi
}

# Get central common setting
get_common_setting() {
    if [ "${common_settings_file_loaded}" != "true" ]; then
        curl -sfL "https://aka.ms/vscode-dev-containers/script-library/settings.env" 2>/dev/null -o /tmp/vsdc-settings.env || echo "Could not download settings file. Skipping."
        common_settings_file_loaded=true
    fi
    if [ -f "/tmp/vsdc-settings.env" ]; then
        local multi_line=""
        if [ "$2" = "true" ]; then multi_line="-z"; fi
        local result="$(grep ${multi_line} -oP "$1=\"?\K[^\"]+" /tmp/vsdc-settings.env | tr -d '\0')"
        if [ ! -z "${result}" ]; then declare -g $1="${result}"; fi
    fi
    echo "$1=${!1}"
}

# Import the specified key in a variable name passed in as 
receive_gpg_keys() {
    get_common_setting $1
    local keys=${!1}
    get_common_setting GPG_KEY_SERVERS true
    local keyring_args=""
    if [ ! -z "$2" ]; then
        mkdir -p "$(dirname \"$2\")"
        keyring_args="--no-default-keyring --keyring $2"
    fi

    # Use a temporary locaiton for gpg keys to avoid polluting image
    export GNUPGHOME="/tmp/tmp-gnupg"
    mkdir -p ${GNUPGHOME}
    chmod 700 ${GNUPGHOME}
    echo -e "disable-ipv6\n${GPG_KEY_SERVERS}" > ${GNUPGHOME}/dirmngr.conf
    # GPG key download sometimes fails for some reason and retrying fixes it.
    local retry_count=0
    local gpg_ok="false"
    set +e
    until [ "${gpg_ok}" = "true" ] || [ "${retry_count}" -eq "5" ]; 
    do
        echo "(*) Downloading GPG key..."
        ( echo "${keys}" | xargs -n 1 gpg -q ${keyring_args} --recv-keys) 2>&1 && gpg_ok="true"
        if [ "${gpg_ok}" != "true" ]; then
            echo "(*) Failed getting key, retring in 10s..."
            (( retry_count++ ))
            sleep 10s
        fi
    done
    set -e
    if [ "${gpg_ok}" = "false" ]; then
        echo "(!) Failed to get gpg key."
        exit 1
    fi
}

# Figure out correct version of a three part version number is not passed
find_version_from_git_tags() {
    local variable_name=$1
    local requested_version=${!variable_name}
    if [ "${requested_version}" = "none" ]; then return; fi
    local repository=$2
    # Normally a "v" is used before the version number, but support alternate cases
    local prefix=${3:-"tags/v"}
    # Some repositories use "_" instead of "." for version number part separation, support that
    local separator=${4:-"."}
    # Some tools release versions that omit the last digit (e.g. go)
    local last_part_optional=${5:-"false"}
    # Some repositories may have tags that include a suffix (e.g. actions/node-versions)
    local version_suffix_regex=$6

    local escaped_separator=${separator//./\\.}
    local break_fix_digit_regex
    if [ "${last_part_optional}" = "true" ]; then
        break_fix_digit_regex="(${escaped_separator}[0-9]+)?"
    else
        break_fix_digit_regex="${escaped_separator}[0-9]+"
    fi    
    local version_regex="[0-9]+${escaped_separator}[0-9]+${break_fix_digit_regex}${version_suffix_regex//./\\.}"
    # If we're passed a matching version number, just return it, otherwise look for a version
    if ! echo "${requested_version}" | grep -E "^${versionMatchRegex}$" > /dev/null 2>&1; then
        local version_list="$(git ls-remote --tags ${repository} | grep -oP "${prefix}\\K${version_regex}$" | tr -d ' ' | tr "${separator}" "." | sort -rV)"
        if [ "${requested_version}" = "latest" ] || [ "${requested_version}" = "current" ] || [ "${requested_version}" = "lts" ]; then
            declare -g ${variable_name}="$(echo "${version_list}" | head -n 1)"
        else
            set +e
            declare -g ${variable_name}="$(echo "${version_list}" | grep -E -m 1 "^${requested_version//./\\.}([\\.\\s]|${version_suffix_regex//./\\.}|$)")"
            set -e
        fi
        if [ -z "${!variable_name}" ] || ! echo "${version_list}" | grep "^${!variable_name//./\\.}$" > /dev/null 2>&1; then
            echo -e "Invalid ${variable_name} value: ${requested_version}\nValid values:\n${version_list}" >&2
            exit 1
        fi
    fi
    echo "Adjusted ${variable_name}=${!variable_name}"
}

# Soft version matching that resolves a version for a given package in the *current apt-cache*
# Return value is stored in first argument (the unprocessed version)
apt_cache_version_soft_match() {
    
    # Version
    local variable_name="$1"
    local requested_version=${!variable_name}
    # Package Name
    local package_name="$2"
    # Exit on no match?
    local exit_on_no_match="${3:-true}"

    # Ensure we've exported useful variables
    . /etc/os-release
    local architecture="$(dpkg --print-architecture)"
    
    dot_escaped="${requested_version//./\\.}"
    dot_plus_escaped="${dot_escaped//+/\\+}"
    # Regex needs to handle debian package version number format: https://www.systutorials.com/docs/linux/man/5-deb-version/
    version_regex="^(.+:)?${dot_plus_escaped}([\\.\\+ ~:-]|$)"
    set +e # Don't exit if finding version fails - handle gracefully
        fuzzy_version="$(apt-cache madison ${package_name} | awk -F"|" '{print $2}' | sed -e 's/^[ \t]*//' | grep -E -m 1 "${version_regex}")"
    set -e
    if [ -z "${fuzzy_version}" ]; then
        echo "(!) No full or partial for package \"${package_name}\" match found in apt-cache for \"${requested_version}\" on OS ${ID} ${VERSION_CODENAME} (${architecture})."

        if $exit_on_no_match; then
            echo "Available versions:"
            apt-cache madison ${package_name} | awk -F"|" '{print $2}' | grep -oP '^(.+:)?\K.+'
            exit 1 # Fail entire script
        else
            echo "Continuing to fallback method (if available)"
            return 1;
        fi
    fi

    # Globally assign fuzzy_version to this value
    # Use this value as the return value of this function
    declare -g ${variable_name}="=${fuzzy_version}"
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

# Checks if a marker file exists with the correct contents
# check_automatic_marker <feature id> <target path>
check_automatic_marker() {
    local feature_id="$1"
    local target_path="${2:-/usr/local}"
    local marker_path="${target_path}/etc/dev-container-features/${feature_id}.marker"
    get_automatic_marker_contents "$@"
    local verifier_string="${__retval}"
    unset __retval
    if [ -e "${marker_path}" ] && [ "${verifier_string}" = "$(cat ${marker_path})" ]; then
        return 1
    else 
        return 0
    fi
}


# Updates marker for future checking using automatic logic
# update_marker <feature id> <target path> [optional additional verifiers...]
update_automatic_marker() {
    local feature_id="$1"
    local target_path="${2:-/usr/local}"
    local marker_path="${target_path}/etc/dev-container-features/${feature_id}.marker"
    mkdir -p "${target_path}/etc/dev-container-features"
    get_automatic_marker_contents "$@" 
    echo "${__retval}" > "${marker_path}"
    unset __retval
}

# Marker generator
# get_marker_text <feature id> [optional additional verifiers...]
get_automatic_marker_contents() {
    get_buld_arg_env_var_name "$1"
    local marker_text="$@\n$(declare -x | grep -E "^declare -x ${__retval}_")"
    __retval="$(echo "${marker_text}" | sha256sum | cut -d ' ' -f 1)"
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

# set_option_value <feature id> <option name> <value>
set_option_value() {
    get_buld_arg_env_var_name "$1" "$2"
    echo "${__retval}=$3"
    declare -g -x ${__retval}="$3"
}

# copy_option_value <feature id> <option name> <option name> <default value>
copy_option_value() {
    get_buld_arg_env_var_name "$1" "$2"
    in_option_value="${!__retval:-"$4"}"
    get_buld_arg_env_var_name "$1" "$3"
    out_option_var_name="${__retval}"
    echo "${out_option_var_name}=${in_option_value}"
    declare -g -x ${out_option_var_name}="${in_option_value}"
}

# run_if_exists <command> <command arguments>...
run_if_exists() {
    if [ -e "$1" ]; then
        "$@"
    fi
}

# run_as_user_if_exists <username> <command> <command arguments>...
run_as_user_if_exists() {
    local username=$1
    shift
    if [ -e "$1" ]; then
        local command_string="$@"
        su "${username}" -c "${command_string//"/\\"}"
    fi
}

# symlink_if_ne <source> <target>
symlink_if_ne() {
    if [ ! -e "$2" ]; then
        ln -s "$1" "$2"
    fi
}
