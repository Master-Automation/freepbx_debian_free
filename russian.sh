#!/bin/bash
#####################################################################################
# Адаптированный скрипт установки FreePBX 17 на Debian 12
# Исправлены проблемы: libasteriskssl.so.1, systemd, коммерческие модули
#####################################################################################
set -e
SCRIPTVER="1.16"
ASTVERSION=${ASTVERSION:-22}
PHPVERSION="8.2"
LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/freepbx17-install-$(date '+%Y.%m.%d-%H.%M.%S').log"
log=$LOG_FILE
SANE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DEBIAN_MIRROR="https://mirror.yandex.ru/debian/"
NPM_MIRROR=""
DEBIAN_OS_VERSION=""

if [ -f /etc/os-release ]; then
    DEBIAN_OS_VERSION=$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release)
fi

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

if [ "$DEBIAN_OS_VERSION" != "bookworm" ]; then
    echo "Unsupported OS version. This script supports only Debian 12 (bookworm). Detected: $DEBIAN_OS_VERSION"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

export PATH=$SANE_PATH

while [[ $# -gt 0 ]]; do
	case $1 in
		--skipversion) skipversion=true; shift ;;
		--opensourceonly) opensourceonly=true; shift ;;
		--nochrony) nochrony=true; shift ;;
		--debianmirror) DEBIAN_MIRROR=$2; shift; shift ;;
		*) shift ;;
	esac
done

block_debian13_trixie_update() {
	cat >/etc/apt/preferences.d/99-block-trixie.pref <<'EOF'
Package: *
Pin: release n=trixie
Pin-Priority: -1
EOF
}

fix_debian12_repo() {
	for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
		[ -f "$file" ] || continue
		if grep -qE "deb\s+$DEBIAN_MIRROR\s+stable\b" "$file"; then
			sed -i.bak -E "s|(deb\s+$DEBIAN_MIRROR\s+)stable\b|\1bookworm|g" "$file"
		fi
	    if grep -qE "deb\s+http://security\.debian\.org/debian-security\s+stable-security\b" "$file"; then
		    sed -i.bak -E "s|(deb\s+http://security\.debian\.org/debian-security\s+)stable-security\b|\1bookworm-security|g" "$file"
	    fi
    done
}

mkdir -p "${LOG_FOLDER}"
touch "${LOG_FILE}"
exec 2>>"${LOG_FILE}"

compare_version() {
        if dpkg --compare-versions "$1" "gt" "$2"; then result=0
        elif dpkg --compare-versions "$1" "lt" "$2"; then result=1
        else result=2
        fi
}

check_version() { return 0; }

echo_ts() { echo "$(date +"%Y-%m-%d %T") - $*"; }
log() { echo_ts "$*" >> "$LOG_FILE"; }
message() { echo_ts "$*" | tee -a "$LOG_FILE"; }
setCurrentStep () { currentStep="$1"; message "${currentStep}"; }

terminate() {
	if [ $? -ne 0 ]; then
		echo_ts "Displaying last 10 lines from the log file"
		tail -n 10 "$LOG_FILE"
	fi
	rm -f "$pidfile"
	message "Exiting script"
}
errorHandler() {
	log "****** INSTALLATION FAILED *****"
	echo_ts "Installation failed at step ${currentStep}. Please check log ${LOG_FILE} for details."
	log "Error at line: $1 exiting with code $2 (last command was: $3)"
	exit "$2"
}

isinstalled() {
	PKG_OK=$(dpkg-query -W --showformat='${Status}\n' "$@" 2>/dev/null|grep "install ok installed")
	if [ "" = "$PKG_OK" ]; then false; else true; fi
}

pkg_install() {
    log "############################### "
    PKG=("$@")
    if isinstalled "${PKG[@]}"; then
        log "${PKG[*]} already present ...."
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

install_asterisk() {
    astver=$1
    message "Building Asterisk ${astver} from source (standard for Debian 12). This may take 20-40 minutes."
    mkdir -p /usr/src
    cd /usr/src
    if [ -d "asterisk-${astver}" ]; then
        message "Removing old Asterisk source directory..."
        rm -rf asterisk-${astver}
    fi
    git clone -b ${astver} https://github.com/asterisk/asterisk.git asterisk-${astver}
    cd asterisk-${astver}
    ./contrib/scripts/install_prereq install
    ./configure --libdir=/usr/lib64 --with-pjproject-bundled
    make menuselect.makeopts
    menuselect/menuselect --enable chan_pjsip --enable res_srtp --enable res_http_websocket --enable codec_opus --enable codec_g729a --enable format_mp3
    make -j2
    make install
    make config
    ldconfig
    # Fix library path
    cp /usr/src/asterisk-${astver}/main/libasteriskssl.so.1 /usr/lib64/
    echo "/usr/lib64" > /etc/ld.so.conf.d/asterisk.conf
    ldconfig
    message "Asterisk ${astver} installed successfully from source."
}

setup_repositories() {
    # Use Russian mirror for FreePBX
    REPO_URL="http://git.freepbx.asterisk.ru/freepbx17-prod"
    REPO_LINE="deb [arch=amd64] $REPO_URL bookworm main"
    if ! grep -qsF "$REPO_LINE" /etc/apt/sources.list; then
        echo "$REPO_LINE" | tee -a /etc/apt/sources.list >> "$log"
        message "Added FreePBX repo: $REPO_LINE"
    fi
    wget -O - http://git.freepbx.asterisk.ru/gpg/aptly-pubkey.asc | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/freepbx.gpg >> "$log"
    # Debian main repo
    if ! grep -qsF "deb $DEBIAN_MIRROR bookworm main" /etc/apt/sources.list; then
        echo "deb $DEBIAN_MIRROR bookworm main non-free non-free-firmware" | tee -a /etc/apt/sources.list >> "$log"
    fi
    fix_debian12_repo
    block_debian13_trixie_update
    apt-get update >> "$log"
}

setCurrentStep "Starting installation."
trap 'errorHandler "$LINENO" "$?" "$BASH_COMMAND"' ERR
trap "terminate" EXIT

start=$(date +%s)
message "  Starting FreePBX 17 installation process for $(hostname) $(uname -a)"
message "  Please refer to the $log to know the process..."

setCurrentStep "Making sure installation is sane"
apt-get -y --fix-broken install >> "$log"
apt-get autoremove -y >> "$log"

setCurrentStep "Setting up default configuration"
debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
echo "postfix postfix/mailname string $(hostname -f)" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections

pkg_install gnupg

setCurrentStep "Setting up repositories"
setup_repositories

setCurrentStep "Updating repository"
apt-get update >> "$log"

setCurrentStep "Installing required packages"
DEPPRODPKGS=(
    "redis-server" "ghostscript" "libtiff-tools" "iptables-persistent" "net-tools"
    "rsyslog" "libavahi-client3" "nmap" "apache2" "zip" "incron" "wget" "vim"
    "openssh-server" "rsync" "mariadb-server" "mariadb-client" "bison" "flex"
    "flite" "php${PHPVERSION}" "php${PHPVERSION}-curl" "php${PHPVERSION}-zip"
    "php${PHPVERSION}-redis" "php${PHPVERSION}-cli" "php${PHPVERSION}-common"
    "php${PHPVERSION}-mysql" "php${PHPVERSION}-gd" "php${PHPVERSION}-mbstring"
    "php${PHPVERSION}-intl" "php${PHPVERSION}-xml" "php${PHPVERSION}-bz2"
    "php${PHPVERSION}-ldap" "php${PHPVERSION}-sqlite3" "php${PHPVERSION}-bcmath"
    "php${PHPVERSION}-soap" "php${PHPVERSION}-ssh2" "php-pear" "curl" "sox"
    "mpg123" "sqlite3" "git" "uuid" "odbc-mariadb" "sudo" "subversion" "unixodbc"
    "nodejs" "npm" "ipset" "iptables" "fail2ban" "htop" "postfix" "tcpdump"
    "sngrep" "tftpd-hpa" "xinetd" "lame" "haproxy" "screen" "easy-rsa" "openvpn"
    "sysstat" "apt-transport-https" "lsb-release" "ca-certificates" "cron"
    "python3-mysqldb" "at" "avahi-daemon" "avahi-utils" "libnss-mdns" "mailutils"
    "liburiparser1" "libavdevice59" "python3-mysqldb" "python-is-python3"
    "pkgconf" "libicu-dev" "libsrtp2-1" "libspandsp2" "libncurses5" "autoconf"
    "libical3" "libneon27" "libsnmp40" "libbluetooth3" "libunbound8" "libsybdb5"
    "libspeexdsp1" "libiksemel3" "libresample1" "libgmime-3.0-0" "libc-client2007e"
    "imagemagick"
)
for i in "${!DEPPRODPKGS[@]}"; do
    pkg_install "${DEPPRODPKGS[$i]}"
done

if [ "$nochrony" != true ]; then
    pkg_install chrony
fi

setCurrentStep "Removing unnecessary packages"
apt-get autoremove -y >> "$log"
execution_time="$(($(date +%s) - start))"
message "Execution time to install all the dependent packages : $execution_time s"

setCurrentStep "Setting up folders and asterisk config"
groupadd -r asterisk 2>/dev/null || true
useradd -r -g asterisk -d /home/asterisk -M -s /bin/bash asterisk 2>/dev/null || true
mkdir -p /tftpboot
chown -R asterisk:asterisk /tftpboot
sed -i -e "s|^TFTP_DIRECTORY=\"/srv\/tftp\"$|TFTP_DIRECTORY=\"/tftpboot\"|" /etc/default/tftpd-hpa
systemctl unmask tftpd-hpa.service
systemctl start tftpd-hpa.service

mkdir -p /var/lib/asterisk/sounds
chown -R asterisk:asterisk /var/lib/asterisk

# Install Asterisk
if [ "$noast" ]; then
    message "Skipping Asterisk installation due to noasterisk option"
else
    setCurrentStep "Installing Asterisk packages."
    install_asterisk $ASTVERSION
fi

# Install FreePBX packages
setCurrentStep "Installing FreePBX packages"
pkg_install sysadmin17 sangoma-pbx17 ffmpeg

setCurrentStep "Enabling modules"
phpenmod freepbx
mkdir -p /var/lib/php/session

setCurrentStep "Installing FreePBX 17"
pkg_install ioncube-loader-82
pkg_install freepbx17

if [ "$opensourceonly" ]; then
    setCurrentStep "Removing commercial modules"
    fwconsole ma list | awk '/Commercial/ {print $2}' | xargs -t -I {} fwconsole ma -f remove {} >> "$log" || true
    fwconsole ma -f remove firewall >> "$log" || true
    apt-get purge -y sysadmin17 ioncube-loader-82 >> "$log" || true
fi

setCurrentStep "Reloading and restarting FreePBX"
fwconsole reload >> "$log"
fwconsole restart >> "$log"

setCurrentStep "Wrapping up the installation process"
systemctl daemon-reload
systemctl enable freepbx
a2enmod ssl expires rewrite
a2ensite freepbx.conf
a2ensite default-ssl

# Fix Apache startup order
systemctl edit --full freepbx.service <<EOF || true
[Unit]
After=mariadb.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/fwconsole start
ExecStop=/usr/sbin/fwconsole stop
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable asterisk
systemctl start asterisk
systemctl restart apache2

setCurrentStep "Holding packages"
apt-mark hold sangoma-pbx17 nodejs node-* freepbx17 >> "$log"

setCurrentStep "FreePBX 17 Installation finished successfully."
execution_time="$(($(date +%s) - start))"
message "Total script Execution Time: $execution_time"
message "Finished FreePBX 17 installation process. You can now access the web interface at http://$(hostname -I | awk '{print $1}')"

if [ ! "$nofpbx" ] ; then
  fwconsole motd
fi
