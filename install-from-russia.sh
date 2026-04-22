#!/bin/bash
#####################################################################################
# * Copyright 2024 by Sangoma Technologies
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3.0
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# @author kgupta@sangoma.com
#
# This FreePBX install script and all concepts are property of
# Sangoma Technologies.
# This install script is free to use for installing FreePBX
# along with dependent packages only but carries no guarantee on performance
# and is used at your own risk.  This script carries NO WARRANTY.
#####################################################################################
#                                               FreePBX 17                          #
#####################################################################################
set -e
SCRIPTVER="1.15"
ASTVERSION=${ASTVERSION:-22}
PHPVERSION="8.2"
LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/freepbx17-install-$(date '+%Y.%m.%d-%H.%M.%S').log"
log=$LOG_FILE
SANE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DEBIAN_MIRROR="http://mirror.yandex.ru/debian"
NPM_MIRROR=""
DEBIAN_OS_VERSION=""

if [ -f /etc/os-release ]; then
    DEBIAN_OS_VERSION=$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release)
fi

# Fallback to checking /etc/debian_version numerically
if [ -z "$DEBIAN_OS_VERSION" ] && [ -f /etc/debian_version ]; then
    case "$(cat /etc/debian_version)" in
        12*|bookworm)
            DEBIAN_OS_VERSION="bookworm"
            ;;
        13*|trixie)
            DEBIAN_OS_VERSION="trixie"
            ;;
        *)
            DEBIAN_OS_VERSION="unknown"
            ;;
    esac
fi

# Only allow Debian 12 (bookworm)
if [ "$DEBIAN_OS_VERSION" != "bookworm" ]; then
    echo "Unsupported OS version. This script supports only Debian 12 (bookworm). Detected: $DEBIAN_OS_VERSION"
    exit 1
fi


# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi


# Setup a sane PATH for script execution as root
export PATH=$SANE_PATH

while [[ $# -gt 0 ]]; do
	case $1 in
		--dev)
			dev=true
			shift # past argument
			;;
		--disable-deb-update-v13)
			disableDebUpdateToV13=true
			shift # past argument
			;;
		--testing)
			testrepo=true
			shift # past argument
			;;
		--nofreepbx)
			nofpbx=true
			shift # past argument
			;;
		--noasterisk)
			noast=true
			shift # past argument
			;;
		--opensourceonly)
			opensourceonly=true
			shift # past argument
			;;
		--noaac)
			noaac=true
			shift # past argument
			;;
		--skipversion)
			skipversion=true
			shift # past argument
			;;
		
		--nochrony)
			nochrony=true
			shift # past argument
			;;
		--debianmirror)
			DEBIAN_MIRROR=$2
			shift; shift # past argument
			;;
    --npmmirror)
      NPM_MIRROR=$2
      shift; shift # past argument
      ;;
		-*)
			echo "Unknown option $1"
			exit 1
			;;
		*)
			echo "Unknown argument \"$1\""
			exit 1
			;;
	esac
done


block_debian13_trixie_update() {
	cat >/etc/apt/preferences.d/99-block-trixie.pref <<'EOF'
# Block Debian 13 Trixie
Package: *
Pin: release n=trixie
Pin-Priority: -1

EOF
}

fix_debian12_repo() {
    # --- Fix sources.list files to use bookworm ---
    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -f "$file" ] || continue
        
        # 1. Замена "stable" на "bookworm" в основном зеркале (mirror.yandex.ru)
        if grep -qE "deb\s+$DEBIAN_MIRROR\s+stable\b" "$file"; then
            sed -i.bak -E "s|(deb\s+$DEBIAN_MIRROR\s+)stable\b|\1bookworm|g" "$file"
        fi

        # 2. Замена "stable-security" на "bookworm-security" в security-репозитории
        #    Используем зеркало Яндекса для security
        if grep -qE "deb\s+http://mirror\.yandex\.ru/debian-security\s+stable-security\b" "$file"; then
            sed -i.bak -E "s|(deb\s+http://mirror\.yandex\.ru/debian-security\s+)stable-security\b|\1bookworm-security|g" "$file"
        fi
    done
}

if [ -n "$disableDebUpdateToV13" ]; then
	    # Fix current debian repo to point to bookworm
	    fix_debian12_repo
	    # Block Debian 13/Trixie update because currently FreePBX only supports Debian 12/Bookworm 
	    block_debian13_trixie_update
	    echo "Debian repositories have been updated to use the Bookworm (Debian 12) sources."
	    echo "The script is exiting now because the '--disable-deb-update-v13' option was used."
	    echo "This option is intended only for updating the APT sources without proceeding with a full installation."
	    echo "To run the full installation, please re-run the script **without** the '--disable-deb-update-v13' option."
	    exit 1
fi


# Create the log file
mkdir -p "${LOG_FOLDER}"
touch "${LOG_FILE}"


# Redirect stderr to the log file
exec 2>>"${LOG_FILE}"

#Comparing version
compare_version() {
        if dpkg --compare-versions "$1" "gt" "$2"; then
                result=0
        elif dpkg --compare-versions "$1" "lt" "$2"; then
                result=1
        else
                result=2
        fi
}


# Functions to log messages
echo_ts() {
	echo "$(date +"%Y-%m-%d %T") - $*"
}

log() {
	echo_ts "$*" >> "$LOG_FILE"
}

message() {
	echo_ts "$*" | tee -a "$LOG_FILE"
}

#Function to record and display the current step
setCurrentStep () {
	currentStep="$1"
	message "${currentStep}"
}

# Function to cleanup installation
terminate() {
	# display last 10 lines of the log file on abnormal exits
	if [ $? -ne 0 ]; then
		echo_ts "Displaying last 10 lines from the log file"
		tail -n 10 "$LOG_FILE"
	fi
	# removing pid file
	rm -f "$pidfile"
	message "Exiting script"
}

#Function to log error and location
errorHandler() {
	log "****** INSTALLATION FAILED *****"
	echo_ts "Installation failed at step ${currentStep}. Please check log ${LOG_FILE} for details."
	log "Error at line: $1 exiting with code $2 (last command was: $3)"
	exit "$2"
}

# Checking if the package is already installed or not
isinstalled() {
	PKG_OK=$(dpkg-query -W --showformat='${Status}\n' "$@" 2>/dev/null|grep "install ok installed")
	if [ "" = "$PKG_OK" ]; then
		false
	else
		true
	fi
}

# Function to install the package
pkg_install() {
    log "############################### "
    PKG=("$@")  # Assign arguments as an array
    if isinstalled "${PKG[@]}"; then
        log "${PKG[*]} already present ...."   # Use * to join the array into a string
    else
        message "Installing ${PKG[*]} ...."
        apt-get -y --ignore-missing -o DPkg::Options::="--force-confnew" -o Dpkg::Options::="--force-overwrite" install "${PKG[@]}" >> "$log"
        if isinstalled "${PKG[@]}"; then
            message "${PKG[*]} installed successfully...."
        else
            message "${PKG[*]} failed to install ...."
            message "Exiting the installation process as dependent ${PKG[*]} failed to install ...."
            terminate
        fi
    fi
    log "############################### "
}

# Function to install the asterisk and dependent packages
install_asterisk() {
	astver=$1
	ASTPKGS=("addons"
		"addons-core"
		"addons-mysql"
		"core"
		"curl"
		"odbc"
		"ogg"
		"flite"
		"g729"
		"resample"
		"snmp"
		"speex"
		"sqlite3"
		"voicemail"
	)

	# creating directories
	mkdir -p /var/lib/asterisk/moh
	pkg_install asterisk"$astver"

	for i in "${!ASTPKGS[@]}"; do
		pkg_install asterisk"$astver"-"${ASTPKGS[$i]}"
	done

	pkg_install asterisk"$astver".0-freepbx-asterisk-modules
	pkg_install asterisk-version-switch
	pkg_install asterisk-sounds-*
}


setup_repositories() {
	apt-key del "9641 7C6E 0423 6E0A 986B  69EF DE82 7447 3C8D 0E52" >> "$log"

	wget -O - http://deb.freepbx.org/gpg/aptly-pubkey.asc | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/freepbx.gpg  >> "$log"

	if [ "$testrepo" ]; then
		REPO_URL="http://deb.freepbx.org/freepbx17-dev"
	else
		REPO_URL="http://deb.freepbx.org/freepbx17-prod"
	fi

	REPO_LINE="deb [arch=amd64] $REPO_URL bookworm main"
	REPO_FILE="/etc/apt/sources.list"

	# Only add the line if it's not already present
	if ! grep -qsF "$REPO_LINE" "$REPO_FILE" 2>/dev/null; then
		echo "$REPO_LINE" | tee -a "$REPO_FILE" >> "$log"
		echo "Added FreePBX repo: $REPO_LINE" >> "$log"
	else
		echo "FreePBX repo already exists: $REPO_LINE" >> "$log"
	fi

	if [ -z "$noaac" ]; then
	     # Add main Bookworm repo if missing
	     REPO_LINE="deb $DEBIAN_MIRROR bookworm main non-free non-free-firmware"

	     # Only add if the line doesn't already exist
	     if ! grep -qsF "$REPO_LINE" "$REPO_FILE"; then
		     echo "$REPO_LINE" | tee -a "$REPO_FILE" >> "$log"
		     echo "Added Bookworm main repo: $REPO_LINE" >> "$log"
	     else
		     echo "Bookworm main repo already exists: $REPO_LINE" >> "$log"
	     fi			

	    # Fix current debian repo to point to bookworm
	    fix_debian12_repo
	    # Block Debian 13/Trixie update because currently FreePBX only supports Debian 12/Bookworm 
	    block_debian13_trixie_update
	fi

	apt-get update >> "$log"

	setCurrentStep "Setting up Sangoma repository"
    local aptpref="/etc/apt/preferences.d/99sangoma-fpbx-repository"
    cat <<EOF> $aptpref
Package: *
Pin: origin deb.freepbx.org
Pin-Priority: ${MIRROR_PRIO}
EOF
    if [ "$noaac" ]; then
    cat <<EOF>> $aptpref

Package: ffmpeg
Pin: origin deb.freepbx.org
Pin-Priority: 1
EOF
    fi
}



check_services() {
    services=("fail2ban" "iptables")
    for service in "${services[@]}"; do
        service_status=$(systemctl is-active "$service")
        if [[ "$service_status" != "active" ]]; then
            message "Service $service is not active. Please ensure it is running."
        fi
    done

    apache2_status=$(systemctl is-active apache2)
    if [[ "$apache2_status" == "active" ]]; then
        apache_process=$(netstat -anp | awk '$4 ~ /:80$/ {sub(/.*\//,"",$7); print $7}')
        if [ "$apache_process" == "apache2" ]; then
            message "Apache2 service is running on port 80."
        else
            message "Apache2 is not running in port 80."
        fi
    else
        message "The Apache2 service is not active. Please activate the service"
    fi
}

check_php_version() {
    php_version=$(php -v | grep built: | awk '{print $2}')
    if [[ "${php_version:0:3}" == "8.2" ]]; then
        message "Installed PHP version $php_version is compatible with FreePBX."
    else
        message "Installed PHP version  $php_version is not compatible with FreePBX. Please install PHP version '8.2.x'"
    fi

    # Checking whether enabled PHP modules are of PHP 8.2 version
    php_module_version=$(a2query -m | grep php | awk '{print $1}')

    if [[ "$php_module_version" == "php8.2" ]]; then
       log "The PHP module version $php_module_version is compatible with FreePBX. Proceeding with the script."
    else
       log "The installed PHP module version $php_module_version is not compatible with FreePBX. Please install PHP version '8.2'."
       exit 1
    fi
}

verify_module_status() {
    modules_list=$(fwconsole ma list | grep -Ewv "Enabled|----|Module|No repos")
    if [ -z "$modules_list" ]; then
        message "All Modules are Enabled."
    else
        message "List of modules which are not Enabled:"
        message "$modules_list"
    fi
}

# Function to check assigned ports for services
inspect_network_ports() {
    # Array of port and service pairs
    local ports_services=(
        82 restapps
        83 restapi
        81 ucp
        80 acp
        84 hpro
        "" leport
        "" sslrestapps
        "" sslrestapi
        "" sslucp
        "" sslacp
        "" sslhpro
        "" sslsngphone
    )

    for (( i=0; i<${#ports_services[@]}; i+=2 )); do
        port="${ports_services[i]}"
        service="${ports_services[i+1]}"
        port_set=$(fwconsole sa ports | grep "$service" | cut -d'|' -f 2 | tr -d '[:space:]')

        if [ "$port_set" == "$port" ]; then
            message "$service module is assigned to its default port."
        else
            message "$service module is expected to have port $port assigned instead of $port_set"
        fi
    done
}

inspect_running_processes() {
    processes=$(fwconsole pm2 --list |  grep -Ewv "online|----|Process")
    if [ -z "$processes" ]; then
        message "No Offline Processes found."
    else
        message "List of Offline processes:"
        message "$processes"
    fi
}

check_freepbx() {
     # Check if FreePBX is installed
    if ! dpkg -l | grep -q 'freepbx'; then
        message "FreePBX is not installed. Please install FreePBX to proceed."
    else
        verify_module_status
	if [ ! "$opensourceonly" ] ; then
        	inspect_network_ports
	fi
        inspect_running_processes
        inspect_job_status=$(fwconsole job --list)
        message "Job list : $inspect_job_status"
    fi
}



hold_packages() {
    # List of package names to hold
    local packages=("sangoma-pbx17" "nodejs" "node-*")
    if [ ! "$nofpbx" ] ; then
        packages+=("freepbx17")
    fi

    # Loop through each package and hold it
    for pkg in "${packages[@]}"; do
        apt-mark hold "$pkg" >> "$log"
    done
}

################################################################################################################
MIRROR_PRIO=600
kernel=$(uname -a)
host=$(hostname)
fqdn="$(hostname -f)" || true

# Install wget which is required for version check
pkg_install wget


# Check if running in a Container
if systemd-detect-virt --container &> /dev/null; then
	message "Running in a Container. Skipping Chrony installation."
	nochrony=true
fi

# Check if we are running on a 64-bit system
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" != "amd64" ]; then
    message "FreePBX 17 installation can only be made on a 64-bit (amd64) system!"
    message "Current System's Architecture: $ARCH"
    exit 1
fi

# Check if hostname command succeeded and FQDN is not empty
if [ -z "$fqdn" ]; then
    echo "Fully qualified domain name (FQDN) is not set correctly."
    echo "Please set the FQDN for this system and re-run the script."
    echo "To set the FQDN, update the /etc/hostname and /etc/hosts files."
    exit 1
fi

#Ensure the script is not running
pidfile='/var/run/freepbx17_installer.pid'

if [ -f "$pidfile" ]; then
	old_pid=$(cat "$pidfile")
	if ps -p "$old_pid" > /dev/null; then
		message "FreePBX 17 installation process is already going on (PID=$old_pid), hence not starting new process"
		exit 1
	else
		log "Removing stale PID file"
		rm -f "${pidfile}"
	fi
fi
echo "$$" > "$pidfile"

setCurrentStep "Starting installation."
trap 'errorHandler "$LINENO" "$?" "$BASH_COMMAND"' ERR
trap "terminate" EXIT

start=$(date +%s)
message "  Starting FreePBX 17 installation process for $host $kernel"
message "  Please refer to the $log to know the process..."
log "  Executing script v$SCRIPTVER ..."

setCurrentStep "Making sure installation is sane"
# Fixing broken install
apt-get -y --fix-broken install >> "$log"
apt-get autoremove -y >> "$log"

# Check if the CD-ROM repository is present in the sources.list file
if grep -q "^deb cdrom" /etc/apt/sources.list; then
  # Comment out the CD-ROM repository line in the sources.list file
  sed -i '/^deb cdrom/s/^/#/' /etc/apt/sources.list
  message "Commented out CD-ROM repository in sources.list"
fi

apt-get update >> "$log"

# Adding iptables and postfix  inputs so "iptables-persistent" and postfix will not ask for the input
setCurrentStep "Setting up default configuration"
debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
echo "postfix postfix/mailname string ${fqdn}" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections

pkg_install gnupg

setCurrentStep "Setting up repositories"
setup_repositories


setCurrentStep "Updating repository"
apt-get update >> "$log"

# log the apt-cache policy
apt-cache policy  >> "$log"

# Don't start the tftp & chrony daemons automatically, as we need to change their configuration
systemctl mask tftpd-hpa.service
if [ "$nochrony" != true ]; then
	systemctl mask chrony.service
fi

# Install dependent packages
setCurrentStep "Installing required packages"
DEPPRODPKGS=(
	"redis-server"
	"iptables-persistent"
	"net-tools"
	"rsyslog"
	"apache2"
	"zip"
	"wget"
	"vim"
	"openssh-server"
	"rsync"
	"mariadb-server"
	"mariadb-client"
	"bison"
	"flex"
	"flite"
	"php${PHPVERSION}"
	"php${PHPVERSION}-curl"
	"php${PHPVERSION}-zip"
	"php${PHPVERSION}-redis"
	"php${PHPVERSION}-cli"
	"php${PHPVERSION}-common"
	"php${PHPVERSION}-mysql"
	"php${PHPVERSION}-gd"
	"php${PHPVERSION}-mbstring"
	"php${PHPVERSION}-intl"
	"php${PHPVERSION}-xml"
	"php${PHPVERSION}-bz2"
	"php${PHPVERSION}-ldap"
	"php${PHPVERSION}-sqlite3"
	"php${PHPVERSION}-bcmath"
	"php${PHPVERSION}-soap"
	"php${PHPVERSION}-ssh2"
	"php-pear"
	"curl"
	"sox"
	"mpg123"
	"sqlite3"
	"git"
	"uuid"
	"odbc-mariadb"
	"sudo"
	"unixodbc"
	"nodejs"
	"npm"
	"ipset"
	"iptables"
	"fail2ban"
	"htop"
	"postfix"
	"tcpdump"
	"sngrep"
	"tftpd-hpa"
	"xinetd"
	"lame"
	"screen"
	"sysstat"
	"apt-transport-https"
	"lsb-release"
	"ca-certificates"
 	"cron"
 	"at"
  	"mailutils"
	# Asterisk package
	"liburiparser1"
	# ffmpeg package
	"libavdevice59"
	# System Admin module
	"python3-mysqldb"
	"python-is-python3"
	# User Control Panel module
	"pkgconf"
	"libicu-dev"
	"libsrtp2-1"
	"libspandsp2"
	"libncurses5"
	"autoconf"
	"libical3"
	"libneon27"
	"libsnmp40"
	"libbluetooth3"
	"libunbound8"
	"libsybdb5"
	"libspeexdsp1"
	"libiksemel3"
	"libresample1"
	"libgmime-3.0-0"
	"libc-client2007e"
	)
DEPDEVPKGS=(
	"libsnmp-dev"
	"libpq-dev"
	"liblua5.2-dev"
	"libpri-dev"
	"libbluetooth-dev"
	"libunbound-dev"
	"libspeexdsp-dev"
	"libiksemel-dev"
	"libresample1-dev"
	"libgmime-3.0-dev"
	"libc-client2007e-dev"
	"libncurses-dev"
	"libssl-dev"
	"libxml2-dev"
	"libnewt-dev"
	"libsqlite3-dev"
	"unixodbc-dev"
	"uuid-dev"
	"libasound2-dev"
	"libogg-dev"
	"libvorbis-dev"
	"libcurl4-openssl-dev"
	"libical-dev"
	"libneon27-dev"
	"libsrtp2-dev"
	"libspandsp-dev"
	"libjansson-dev"
	"liburiparser-dev"
	"libavdevice-dev"
	"python-dev-is-python3"
	"default-libmysqlclient-dev"
	"dpkg-dev"
	"build-essential"
	"automake"
	"autoconf"
	"libtool-bin"
	"bison"
	"flex"
)
if [ $dev ]; then
	DEPPKGS=("${DEPPRODPKGS[@]}" "${DEPDEVPKGS[@]}")
else
	DEPPKGS=("${DEPPRODPKGS[@]}")
fi
if [ "$nochrony" != true ]; then
	DEPPKGS+=("chrony")
fi
for i in "${!DEPPKGS[@]}"; do
	pkg_install "${DEPPKGS[$i]}"
done

if  dpkg -l | grep -q 'postfix'; then
    warning_message="# WARNING: Changing the inet_interfaces to an IP other than 127.0.0.1 may expose Postfix to external network connections.\n# Only modify this setting if you understand the implications and have specific network requirements."

    if ! grep -q "WARNING: Changing the inet_interfaces" /etc/postfix/main.cf; then
        # Add the warning message above the inet_interfaces configuration
        sed -i "/^inet_interfaces\s*=/i $warning_message" /etc/postfix/main.cf
    fi

    sed -i "s/^inet_interfaces\s*=.*/inet_interfaces = 127.0.0.1/" /etc/postfix/main.cf

    systemctl restart postfix
fi

# OpenVPN EasyRSA configuration
if [ ! -d "/etc/openvpn/easyrsa3" ]; then
	make-cadir /etc/openvpn/easyrsa3
fi
#Remove below files which will be generated by sysadmin later
rm -f /etc/openvpn/easyrsa3/pki/vars || true
rm -f /etc/openvpn/easyrsa3/vars


# Install libfdk-aac2
if [ "$noaac" ] ; then
	message "Skipping libfdk-aac2 installation due to noaac option"
else
	pkg_install libfdk-aac2
fi

setCurrentStep "Removing unnecessary packages"
apt-get autoremove -y >> "$log"

execution_time="$(($(date +%s) - start))"
message "Execution time to install all the dependent packages : $execution_time s"




setCurrentStep "Setting up folders and asterisk config"
groupExists="$(getent group asterisk || echo '')"
if [ "${groupExists}" = "" ]; then
	groupadd -r asterisk
fi

userExists="$(getent passwd asterisk || echo '')"
if [ "${userExists}" = "" ]; then
	useradd -r -g asterisk -d /home/asterisk -M -s /bin/bash asterisk
fi

# Adding asterisk to the sudoers list
#echo "%asterisk ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# Creating /tftpboot directory
mkdir -p /tftpboot
chown -R asterisk:asterisk /tftpboot
# Changing the tftp process path to tftpboot
sed -i -e "s|^TFTP_DIRECTORY=\"/srv\/tftp\"$|TFTP_DIRECTORY=\"/tftpboot\"|" /etc/default/tftpd-hpa
# Change the tftp & chrony options when IPv6 is not available, to allow successful execution
if [ ! -f /proc/net/if_inet6 ]; then
	sed -i -e "s|^TFTP_OPTIONS=\"--secure\"$|TFTP_OPTIONS=\"--secure --ipv4\"|" /etc/default/tftpd-hpa
	if [ "$nochrony" != true ]; then
		sed -i -e "s|^DAEMON_OPTS=\"-F 1\"$|DAEMON_OPTS=\"-F 1 -4\"|" /etc/default/chrony
	fi
fi
# Start the tftp & chrony daemons
systemctl unmask tftpd-hpa.service
systemctl start tftpd-hpa.service
if [ "$nochrony" != true ]; then
	systemctl unmask chrony.service
	systemctl start chrony.service
fi

# Creating asterisk sound directory
mkdir -p /var/lib/asterisk/sounds
chown -R asterisk:asterisk /var/lib/asterisk

# Changing openssl to make it compatible with the katana
sed -i -e 's/^openssl_conf = openssl_init$/openssl_conf = default_conf/' /etc/ssl/openssl.cnf

isSSLConfigAdapted=$(grep "FreePBX 17 changes" /etc/ssl/openssl.cnf |wc -l)
if [ "0" = "${isSSLConfigAdapted}" ]; then
	cat <<EOF >> /etc/ssl/openssl.cnf
# FreePBX 17 changes - begin
[ default_conf ]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
MinProtocol = TLSv1.2
CipherString = DEFAULT:@SECLEVEL=1
# FreePBX 17 changes - end
EOF
fi

#Setting higher precedence value to IPv4
sed -i 's/^#\s*precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf

# Setting screen configuration
isScreenRcAdapted=$(grep "FreePBX 17 changes" /root/.screenrc |wc -l)
if [ "0" = "${isScreenRcAdapted}" ]; then
	cat <<EOF >> /root/.screenrc
# FreePBX 17 changes - begin
hardstatus alwayslastline
hardstatus string '%{= kG}[ %{G}%H %{g}][%= %{=kw}%?%-Lw%?%{r}(%{W}%n*%f%t%?(%u)%?%{r})%{w}%?%+Lw%?%?%= %{g}][%{B}%Y-%m-%d %{W}%c %{g}]'
# FreePBX 17 changes - end
EOF
fi


# Setting VIM configuration for mouse copy paste
isVimRcAdapted=$(grep "FreePBX 17 changes" /etc/vim/vimrc.local |wc -l)
if [ "0" = "${isVimRcAdapted}" ]; then
	cat <<EOF >> /etc/vim/vimrc.local
" FreePBX 17 changes - begin
" This file loads the default vim options at the beginning and prevents
" that they are being loaded again later. All other options that will be set,
" are added, or overwrite the default settings. Add as many options as you
" whish at the end of this file.

" Load the defaults
source \$VIMRUNTIME/defaults.vim

" Prevent the defaults from being loaded again later, if the user doesn't
" have a local vimrc (~/.vimrc)
let skip_defaults_vim = 1


" Set more options (overwrites settings from /usr/share/vim/vim80/defaults.vim)
" Add as many options as you whish

" Set the mouse mode to 'r'
if has('mouse')
  set mouse=r
endif
" FreePBX 17 changes - end
EOF
fi


# Setting apt configuration to always DO NOT overwrite existing configurations
aptNoOverwrite=$(grep "DPkg::options { \"--force-confdef\"; \"--force-confold\"; }" /etc/apt/apt.conf.d/00freepbx |wc -l)
if [ "0" = "${aptNoOverwrite}" ]; then
        cat <<EOF >> /etc/apt/apt.conf.d/00freepbx
DPkg::options { "--force-confdef"; "--force-confold"; }
EOF
fi


#chown -R asterisk:asterisk /etc/ssl

# Install Asterisk
if [ "$noast" ] ; then
	message "Skipping Asterisk installation due to noasterisk option"
else
	# TODO Need to check if asterisk installed already then remove that and install new ones.
	# Install Asterisk
	setCurrentStep "Installing Asterisk packages."
	install_asterisk $ASTVERSION
fi

# Install PBX dependent packages
setCurrentStep "Installing FreePBX packages"

FPBXPKGS=("sysadmin17"
	   "sangoma-pbx17"
	   "ffmpeg"
   )
for i in "${!FPBXPKGS[@]}"; do
	pkg_install "${FPBXPKGS[$i]}"
done


#Enabling freepbx.ini file
setCurrentStep "Enabling modules."
phpenmod freepbx
mkdir -p /var/lib/php/session

#Creating default config files
mkdir -p /etc/asterisk
touch /etc/asterisk/extconfig_custom.conf
touch /etc/asterisk/extensions_override_freepbx.conf
touch /etc/asterisk/extensions_additional.conf
touch /etc/asterisk/extensions_custom.conf
chown -R asterisk:asterisk /etc/asterisk

setCurrentStep "Restarting fail2ban"
systemctl restart fail2ban  >> "$log"


if [ "$nofpbx" ] ; then
  message "Skipping FreePBX 17 installation due to nofreepbx option"
else
  setCurrentStep "Installing FreePBX 17"
  pkg_install ioncube-loader-82
  pkg_install freepbx17

  if [ -n "$NPM_MIRROR" ] ; then
    setCurrentStep "Setting environment variable npm_config_registry=$NPM_MIRROR"
    export npm_config_registry="$NPM_MIRROR"
  fi

  # Check if only opensource required then remove the commercial modules
  if [ "$opensourceonly" ]; then
    setCurrentStep "Removing commercial modules"
    fwconsole ma list | awk '/Commercial/ {print $2}' | xargs -t -I {} fwconsole ma -f remove {} >> "$log"
    # Remove firewall module also because it depends on commercial sysadmin module
    fwconsole ma -f remove firewall >> "$log" || true
  fi

 

  setCurrentStep "Installing all local modules"
  fwconsole ma installlocal >> "$log"

  setCurrentStep "Upgrading FreePBX 17 modules"
  fwconsole ma upgradeall >> "$log"

  setCurrentStep "Reloading and restarting FreePBX 17"
  fwconsole reload >> "$log"
  fwconsole restart >> "$log"

  if [ "$opensourceonly" ]; then
    # Uninstall the sysadmin helper package for the sysadmin commercial module
    message "Uninstalling sysadmin17"
    apt-get purge -y sysadmin17 >> "$log"
    # Uninstall ionCube loader required for commercial modules and to install the freepbx17 package
    message "Uninstalling ioncube-loader-82"
    apt-get purge -y ioncube-loader-82 >> "$log"
  fi
fi

setCurrentStep "Wrapping up the installation process"
systemctl daemon-reload >> "$log"
if [ ! "$nofpbx" ] ; then
  systemctl enable freepbx >> "$log"
fi

#delete apache2 index.html as we do not need that file
rm -f /var/www/html/index.html

#enable apache mod ssl
a2enmod ssl  >> "$log"

#enable apache mod expires
a2enmod expires  >> "$log"

#enable apache
a2enmod rewrite >> "$log"

#Enabling freepbx apache configuration
if [ ! "$nofpbx" ] ; then 
  a2ensite freepbx.conf >> "$log"
  a2ensite default-ssl >> "$log"
fi

#Setting postfix size to 100MB
postconf -e message_size_limit=102400000

# Disable expose_php for provide less information to attacker
sed -i 's/\(^expose_php = \).*/\1Off/' /etc/php/${PHPVERSION}/apache2/php.ini

# Setting  max_input_vars to 2000
sed -i 's/;max_input_vars = 1000/max_input_vars = 2000/' /etc/php/${PHPVERSION}/apache2/php.ini

# Disable ServerTokens and ServerSignature for provide less information to attacker
sed -i 's/\(^ServerTokens \).*/\1Prod/' /etc/apache2/conf-available/security.conf
sed -i 's/\(^ServerSignature \).*/\1Off/' /etc/apache2/conf-available/security.conf

# Setting pcre.jit to 0
sed -i 's/;pcre.jit=1/pcre.jit=0/' /etc/php/${PHPVERSION}/apache2/php.ini

# Restart apache2
systemctl restart apache2 >> "$log"

setCurrentStep "Holding Packages"

hold_packages

# Update logrotate configuration
if grep -q '^#dateext' /etc/logrotate.conf; then
   message "Setting up logrotate.conf"
   sed -i 's/^#dateext/dateext/' /etc/logrotate.conf
fi

#setting permisions
chown -R asterisk:asterisk /var/www/html/

setCurrentStep "FreePBX 17 Installation finished successfully."


############ POST INSTALL VALIDATION ############################################
# Commands for post-installation validation
# Disable automatic script termination upon encountering non-zero exit code to prevent premature termination.
set +e
setCurrentStep "Post-installation validation"

check_services

check_php_version

if [ ! "$nofpbx" ] ; then
 check_freepbx
fi

check_asterisk

execution_time="$(($(date +%s) - start))"
message "Total script Execution Time: $execution_time"
message "Finished FreePBX 17 installation process for $host $kernel"
message "Join us on the FreePBX Community Forum: https://community.freepbx.org/ ";

if [ ! "$nofpbx" ] ; then
  fwconsole motd
fi
