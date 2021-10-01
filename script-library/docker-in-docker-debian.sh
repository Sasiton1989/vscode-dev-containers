#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------
#
# Docs: https://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/docker-in-docker.md
# Maintainer: The VS Code and Codespaces Teams
#
# Syntax: ./docker-in-docker-debian.sh [enable non-root docker access flag] [non-root user] [use moby] [Engine/CLI Version]

ENABLE_NONROOT_DOCKER=${1:-"true"}
USERNAME=${2:-"automatic"}
USE_MOBY=${3:-"true"}
DOCKER_VERSION=${4:-"latest"} # The Docker/Moby Engine + CLI should match in version
DOCKER_COMPOSE_PLUGIN_VERSION=${5:-"latest"}
COMPOSE_SWITCH_VERSION=${6:-"latest"}
DOCKER_COMPOSE_V1_VERSION=${7:-"1"}

MICROSOFT_GPG_KEYS_URI="https://packages.microsoft.com/keys/microsoft.asc"

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Determine the appropriate non-root user
if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
    USERNAME=""
    POSSIBLE_USERS=("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
    for CURRENT_USER in ${POSSIBLE_USERS[@]}; do
        if id -u ${CURRENT_USER} > /dev/null 2>&1; then
            USERNAME=${CURRENT_USER}
            break
        fi
    done
    if [ "${USERNAME}" = "" ]; then
        USERNAME=root
    fi
elif [ "${USERNAME}" = "none" ] || ! id -u ${USERNAME} > /dev/null 2>&1; then
    USERNAME=root
fi

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

# Function to run apt-get if needed
apt_get_update_if_needed()
{
    if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls /var/lib/apt/lists/ | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update
    else
        echo "Skipping apt-get update."
    fi
}

# Update bash/zshrc as needed
updaterc() {
    if [ "${UPDATE_RC}" = "true" ]; then
        echo "Updating /etc/bash.bashrc and /etc/zsh/zshrc..."
        if [[ "$(cat /etc/bash.bashrc)" != *"$1"* ]]; then
            echo -e "$1" >> /etc/bash.bashrc
        fi
        if [ -f "/etc/zsh/zshrc" ] && [[ "$(cat /etc/zsh/zshrc)" != *"$1"* ]]; then
            echo -e "$1" >> /etc/zsh/zshrc
        fi
    fi
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        apt_get_update_if_needed
        apt-get -y install --no-install-recommends "$@"
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

# Ensure apt is in non-interactive to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Install dependencies
check_packages apt-transport-https curl ca-certificates lxc pigz iptables gnupg2 dirmngr
if ! type git > /dev/null 2>&1; then
    apt_get_update_if_needed
    apt-get -y install git
fi

# Swap to legacy iptables for compatibility
if type iptables-legacy > /dev/null 2>&1; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
fi

# Source /etc/os-release to get OS info
. /etc/os-release
# Fetch host/container arch.
architecture="$(dpkg --print-architecture)"
target_compose_arch="${architecture}"
case ${target_compose_arch} in
 amd64) 
    target_compose_arch="x86_64"
    ;;
 arm64) 
    target_compose_arch="aarch64"
    ;;
 *) echo "(!) Architecture ${architecture} not supported."
    exit 1
    ;;
esac

# Set up the necessary apt repos (either Microsoft's or Docker's)
if [ "${USE_MOBY}" = "true" ]; then

    # Name of open source engine/cli
    engine_package_name="moby-engine"
    cli_package_name="moby-cli"

    # Import key safely and import Microsoft apt repo
    get_common_setting MICROSOFT_GPG_KEYS_URI
    curl -sSL ${MICROSOFT_GPG_KEYS_URI} | gpg --dearmor > /usr/share/keyrings/microsoft-archive-keyring.gpg
    echo "deb [arch=${architecture} signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/microsoft-${ID}-${VERSION_CODENAME}-prod ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/microsoft.list
else
    # Name of licensed engine/cli
    engine_package_name="docker-ce"
    cli_package_name="docker-ce-cli"

    # Import key safely and import Docker apt repo
    curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor > /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=${architecture} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
fi

# Refresh apt lists
apt-get update

# Soft version matching for docker version
if [ "${DOCKER_VERSION}" = "latest" ] || [ "${DOCKER_VERSION}" = "lts" ] || [ "${DOCKER_VERSION}" = "stable" ]; then
    # Empty, meaning grab whatever "latest" is in apt repo
    engine_version_suffix=""
    cli_version_suffix=""
else
    # Fetch a valid version from the apt-cache (eg: the Microsoft repo appends +azure, breakfix, etc...)
    docker_version_dot_escaped="${DOCKER_VERSION//./\\.}"
    docker_version_dot_plus_escaped="${docker_version_dot_escaped//+/\\+}"
    # Regex needs to handle debian package version number format: https://www.systutorials.com/docs/linux/man/5-deb-version/
    docker_version_regex="^(.+:)?${docker_version_dot_plus_escaped}([\\.\\+ ~:-]|$)"
    set +e # Don't exit if finding version fails - will handle gracefully
    cli_version_suffix="=$(apt-cache madison ${cli_package_name} | awk -F"|" '{print $2}' | sed -e 's/^[ \t]*//' | grep -E -m 1 "${docker_version_regex}")"
    engine_version_suffix="=$(apt-cache madison ${engine_package_name} | awk -F"|" '{print $2}' | sed -e 's/^[ \t]*//' | grep -E -m 1 "${docker_version_regex}")"
    set -e
    if [ -z "${engine_version_suffix}" ] || [ "${engine_version_suffix}" = "=" ] || [ -z "${cli_version_suffix}" ] || [ "${cli_version_suffix}" = "=" ] ; then
        echo "(!) No full or partial Docker / Moby version match found for \"${DOCKER_VERSION}\" on OS ${ID} ${VERSION_CODENAME} (${architecture}). Available versions:"
        apt-cache madison ${cli_package_name} | awk -F"|" '{print $2}' | grep -oP '^(.+:)?\K.+'
        exit 1
    fi
    echo "engine_version_suffix ${engine_version_suffix}"
    echo "cli_version_suffix ${cli_version_suffix}"
fi

# Install Docker / Moby CLI, buildx, and compose v2 if not already installed
if type docker > /dev/null 2>&1 && type dockerd > /dev/null 2>&1; then
    echo "Docker / Moby CLI and Engine already installed."
else
    if [ "${USE_MOBY}" = "true" ]; then
        apt-get -y install --no-install-recommends moby-cli${cli_version_suffix} moby-buildx moby-engine${engine_version_suffix}
        apt-get -y install --no-install-recommends moby-compose || echo "(*) Package moby-compose (Docker Compose v2) not available for OS ${ID} ${VERSION_CODENAME} (${architecture}). Skipping."
    else
        apt-get -y install --no-install-recommends docker-ce-cli${cli_version_suffix} docker-ce${engine_version_suffix}
    fi

    # Enable buildkit by default
    updaterc "export DOCKER_BUILDKIT=1"
fi

# Install Compose v2 plugin if missing
if [ "${DOCKER_COMPOSE_PLUGIN_VERSION}" != "none" ]; then
    if [ -e "/usr/local/lib/docker/cli-plugins/docker-compose" ] || [ -e "/usr/local/libexec/docker/cli-plugins/docker-compose" ] || [ -e "/usr/lib/docker/cli-plugins/docker-compose" ] || [ -e "/usr/libexec/docker/cli-plugins/docker-compose" ]; then
        echo "(*) Compose v2 plugin already installed. Skipping..."
    else
        find_version_from_git_tags DOCKER_COMPOSE_PLUGIN_VERSION "https://github.com/docker/compose"
        echo "(*) Installing Compose v2 plugin ${DOCKER_COMPOSE_PLUGIN_VERSION}..."
        docker_compose_v2_filename="docker-compose-linux-${target_compose_arch}"
        curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_PLUGIN_VERSION}/${docker_compose_v2_filename}" -o /tmp/${docker_compose_v2_filename}
        curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_PLUGIN_VERSION}/${docker_compose_v2_filename}.sha256" -o /tmp/${docker_compose_v2_filename}.sha256
        cd /tmp
        sha256sum -c /tmp/${docker_compose_v2_filename}.sha256
        rm -f /tmp/${docker_compose_v2_filename}.sha256
        mkdir -p /usr/local/lib/docker/cli-plugins/
        mv -f /tmp/${docker_compose_v2_filename} /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi
fi

# Install Docker Compose v1 if not already installed
if [ "${DOCKER_COMPOSE_V1_VERSION}" != "none" ]; then
    if type docker-compose > /dev/null 2>&1; then
        echo "(*) Compose v1 already installed. Skipping..."
    else
        if [ "${target_compose_arch}" != "x86_64" ]; then
            # Use pip to get a version that runns on this architecture
            echo "(*) Installing Compose v1..."
            if ! dpkg -s python3-minimal python3-pip libffi-dev python3-venv > /dev/null 2>&1; then
                apt_get_update_if_needed
                apt-get -y install python3-minimal python3-pip libffi-dev python3-venv
            fi
            export PIPX_HOME=/usr/local/pipx
            mkdir -p ${PIPX_HOME}
            export PIPX_BIN_DIR=/usr/local/bin
            export PYTHONUSERBASE=/tmp/pip-tmp
            export PIP_CACHE_DIR=/tmp/pip-tmp/cache
            pipx_bin=pipx
            if ! type pipx > /dev/null 2>&1; then
                pip3 install --disable-pip-version-check --no-warn-script-location  --no-cache-dir --user pipx
                pipx_bin=/tmp/pip-tmp/bin/pipx
            fi
            ${pipx_bin} install --system-site-packages --pip-args '--no-cache-dir --force-reinstall' docker-compose
            rm -rf /tmp/pip-tmp
        else
            find_version_from_git_tags DOCKER_COMPOSE_V1_VERSION "https://github.com/docker/compose" "tags/"
            echo "(*) Installing Compose v1 (docker-compose) ${DOCKER_COMPOSE_V1_VERSION}..."
            curl -fsSL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_V1_VERSION}/docker-compose-Linux-x86_64" -o /tmp/docker-compose-Linux-x86_64
            curl -fsSL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_V1_VERSION}/docker-compose-Linux-x86_64.sha256" -o /tmp/docker-compose-Linux-x86_64.sha256
            cd /tmp
            sha256sum -c docker-compose-Linux-x86_64.sha256
            rm -f /tmp/docker-compose-Linux-x86_64.sha256
            mv -f /tmp/docker-compose-Linux-x86_64 /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        fi
    fi
fi

# Install docker-compose switch if not already installed
if [ "${COMPOSE_SWITCH_VERSION}" != "none" ] && [ ! -e "/usr/local/bin/compose-switch" ]; then
    if type docker-compose > /dev/null 2>&1; then
        # Setup v1 CLI as alternative
        current_v1_compose_path="$(which docker-compose)"
        target_v1_compose_path="$(dirname "${current_v1_compose_path}")/docker-compose-v1"
        mv "${current_v1_compose_path}" "${target_v1_compose_path}"
        update-alternatives --install /usr/local/bin/docker-compose docker-compose "${target_v1_compose_path}" 1
    fi
    find_version_from_git_tags COMPOSE_SWITCH_VERSION "https://github.com/docker/compose-switch"
    echo "(*) Installing compose-switch ${COMPOSE_SWITCH_VERSION}..."
    curl -fsSL "https://github.com/docker/compose-switch/releases/download/v${COMPOSE_SWITCH_VERSION}/docker-compose-linux-${architecture}" -o /usr/local/bin/compose-switch
    # TODO: Verify checksum once available: https://github.com/docker/compose-switch/issues/11
    chmod +x /usr/local/bin/compose-switch
    update-alternatives --install /usr/local/bin/docker-compose docker-compose /usr/local/bin/compose-switch 99
fi

# If init file already exists, exit
if [ -f "/usr/local/share/docker-init.sh" ]; then
    echo "/usr/local/share/docker-init.sh already exists, so exiting."
    exit 0
fi
echo "(*) docker-init doesnt exist, adding..."

# Add user to the docker group
if [ "${ENABLE_NONROOT_DOCKER}" = "true" ]; then
    if ! getent group docker > /dev/null 2>&1; then
        groupadd docker
    fi

    usermod -aG docker ${USERNAME}
fi

tee /usr/local/share/docker-init.sh > /dev/null \
<< 'EOF'
#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------

sudoIf()
{
    if [ "$(id -u)" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

# explicitly remove dockerd and containerd PID file to ensure that it can start properly if it was stopped uncleanly
# ie: docker kill <ID>
sudoIf find /run /var/run -iname 'docker*.pid' -delete || :
sudoIf find /run /var/run -iname 'container*.pid' -delete || :

set -e

## Dind wrapper script from docker team
# Maintained: https://github.com/moby/moby/blob/master/hack/dind

export container=docker

if [ -d /sys/kernel/security ] && ! sudoIf mountpoint -q /sys/kernel/security; then
	sudoIf mount -t securityfs none /sys/kernel/security || {
		echo >&2 'Could not mount /sys/kernel/security.'
		echo >&2 'AppArmor detection and --privileged mode might break.'
	}
fi

# Mount /tmp (conditionally)
if ! sudoIf mountpoint -q /tmp; then
	sudoIf mount -t tmpfs none /tmp
fi

# cgroup v2: enable nesting
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
	# move the init process (PID 1) from the root group to the /init group,
	# otherwise writing subtree_control fails with EBUSY.
	sudoIf mkdir -p /sys/fs/cgroup/init
	sudoIf echo 1 > /sys/fs/cgroup/init/cgroup.procs
	# enable controllers
	sudoIf sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers \
		> /sys/fs/cgroup/cgroup.subtree_control
fi
## Dind wrapper over.

# Handle DNS
set +e
cat /etc/resolv.conf | grep -i 'internal.cloudapp.net'
if [ $? -eq 0 ]
then
  echo "Setting dockerd Azure DNS."
  CUSTOMDNS="--dns 168.63.129.16"
else
  echo "Not setting dockerd DNS manually."
  CUSTOMDNS=""
fi
set -e

# Start docker/moby engine
( sudoIf dockerd $CUSTOMDNS > /tmp/dockerd.log 2>&1 ) &

set +e

# Execute whatever commands were passed in (if any). This allows us
# to set this script to ENTRYPOINT while still executing the default CMD.
exec "$@"
EOF

chmod +x /usr/local/share/docker-init.sh
chown ${USERNAME}:root /usr/local/share/docker-init.sh
