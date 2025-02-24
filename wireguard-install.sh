#!/bin/bash

# Secure WireGuard server installer
# https://github.com/Admin-Hallon/wireguard

RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'
SEARCH_ZONE_1="hallon.es"
SEARCH_ZONE_2="eprensa.com"
SYSADMIN_EMAIL="sysadmin@hallon.es"
GIT_DIR=$(pwd)
POSTFIX_DIR="/etc/postfix"
HOME_DIR="/web/hallon/vpn_users_conf"


function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}

function checkVirt() {
	if [ "$(systemd-detect-virt)" == "openvz" ]; then
		echo "OpenVZ is not supported"
		exit 1
	fi

	if [ "$(systemd-detect-virt)" == "lxc" ]; then
		echo "LXC is not supported (yet)."
		echo "WireGuard can technically run in an LXC container,"
		echo "but the kernel module has to be installed on the host,"
		echo "the container has to be run with some specific parameters"
		echo "and only the tools need to be installed in the container."
		exit 1
	fi
}

function checkOS() {
	# Check OS version
	if [[ -e /etc/debian_version ]]; then
		source /etc/os-release
		OS="${ID}" # debian or ubuntu
		if [[ ${ID} == "debian" || ${ID} == "raspbian" ]]; then
			if [[ ${VERSION_ID} -lt 10 ]]; then
				echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later"
				exit 1
			fi
			OS=debian # overwrite if raspbian
		fi
	elif [[ -e /etc/fedora-release ]]; then
		source /etc/os-release
		OS="${ID}"
	elif [[ -e /etc/centos-release ]]; then
		source /etc/os-release
		OS=centos
	elif [[ -e /etc/oracle-release ]]; then
		source /etc/os-release
		OS=oracle
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	else
		echo "Looks like you aren't running this installer on a Debian, Ubuntu, Fedora, CentOS, Oracle or Arch Linux system"
		exit 1
	fi
}

function initialCheck() {
	isRoot
	checkVirt
	checkOS
}

function installQuestions() {
	echo "Welcome to the WireGuard installer!"
	echo "The git repository is available at: https://github.com/Admin-Hallon/wireguard"
	echo ""
	echo "I need to ask you a few questions before starting the setup."
	echo "You can leave the default options and just press enter if you are ok with them."
	echo ""

	# Detect public IPv4 or IPv6 address and pre-fill for the user
	SERVER_PUB_IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	if [[ -z ${SERVER_PUB_IP} ]]; then
		# Detect public IPv6 address
		SERVER_PUB_IP=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	fi
	read -rp "IPv4 or IPv6 public address: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP
	read -rp "Public hostname(DNS): " -e -i vpn.hallon.es SERVER_PUB_NAME

	# Detect public interface and pre-fill for the user
	SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
	until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
		read -rp "Public interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
	done

	until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
		read -rp "WireGuard interface name: " -e -i wg0 SERVER_WG_NIC
	done

	until [[ ${SERVER_WG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
		read -rp "Server's WireGuard IPv4: " -e -i 10.66.66.1 SERVER_WG_IPV4
	done

	until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
		read -rp "Server's WireGuard IPv6: " -e -i fd42:42:42::1 SERVER_WG_IPV6
	done

	# Generate random number within private ports range
	RANDOM_PORT=$(shuf -i49152-65535 -n1)
	until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
		read -rp "Server's WireGuard port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
	done

	# Adguard DNS by default
	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "First DNS resolver to use for the users: " -e -i 192.168.34.174 CLIENT_DNS_1
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "Second DNS resolver to use for the users (optional): " -e -i 192.168.35.94 CLIENT_DNS_2
		if [[ ${CLIENT_DNS_2} == "" ]]; then
			CLIENT_DNS_2="${CLIENT_DNS_1}"
		fi
	done

	echo ""
	echo "Okay, that was all I needed. We are ready to setup your WireGuard server now."
	echo "You will be able to generate a user at the end of the installation."
	read -n1 -r -p "Press any key to continue..."
}

function installWireGuard() {
	# Run setup questions first
	installQuestions

	# Install WireGuard tools and module
	if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' && ${VERSION_ID} -gt 10 ]]; then
		apt-get update
		apt-get install -y wireguard iptables resolvconf qrencode sendemail
		DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
	elif [[ ${OS} == 'debian' ]]; then
		if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
			echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
			apt-get update
		fi
		apt update
		apt-get install -y iptables resolvconf qrencode
		apt-get install -y -t buster-backports wireguard postfix
	elif [[ ${OS} == 'fedora' ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			dnf install -y dnf-plugins-core
			dnf copr enable -y jdoss/wireguard
			dnf install -y wireguard-dkms
		fi
		dnf install -y wireguard-tools iptables qrencode postfix
	elif [[ ${OS} == 'centos' ]]; then
		yum -y install epel-release elrepo-release
		if [[ ${VERSION_ID} -eq 7 ]]; then
			yum -y install yum-plugin-elrepo
		fi
		yum -y install kmod-wireguard wireguard-tools iptables qrencode
	elif [[ ${OS} == 'oracle' ]]; then
		dnf install -y oraclelinux-developer-release-el8
		dnf config-manager --disable -y ol8_developer
		dnf config-manager --enable -y ol8_developer_UEKR6
		dnf config-manager --save -y --setopt=ol8_developer_UEKR6.includepkgs='wireguard-tools*'
		dnf install -y wireguard-tools qrencode iptables
	elif [[ ${OS} == 'arch' ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode
	fi

	# Make sure the directory exists (this does not seem the be the case on fedora)
	mkdir /etc/wireguard >/dev/null 2>&1

	chmod 600 -R /etc/wireguard/

	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	# Save WireGuard settings
	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NAME=${SERVER_PUB_NAME}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}" >/etc/wireguard/params

	# Add server interface
	echo "[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}" >"/etc/wireguard/${SERVER_WG_NIC}.conf"

	if pgrep firewalld; then
		FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_WG_IPV4}" | cut -d"." -f1-3)".0"
		FIREWALLD_IPV6_ADDRESS=$(echo "${SERVER_WG_IPV6}" | sed 's/:[^:]*$/:0/')
		echo "PostUp = firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --add-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --remove-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	else
		#Route ALL traffic first
		echo "PostUp = iptables -A FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT; iptables -A FORWARD -i ${SERVER_WG_NIC} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE; ip6tables -A FORWARD -i ${SERVER_WG_NIC} -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT; iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE; ip6tables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
		
		# Set DNS servers to Google DNS
		echo "DNS = 8.8.8.8, 8.8.4.4" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	fi

	# Enable routing on the server
	echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/wg.conf

	sysctl --system

	systemctl start "wg-quick@${SERVER_WG_NIC}"
	systemctl enable "wg-quick@${SERVER_WG_NIC}"

	# Setting up Postfix config
	cat ${GIT_DIR}/resources/postfix_files/main.cf > ${POSTFIX_DIR}/main.cf && cat ${GIT_DIR}/resources/postfix_files/generic > ${POSTFIX_DIR}/generic
	postmap ${POSTFIX_DIR}/generic
	ln -s /usr/sbin/sendmail /usr/bin/sendmail
	systemctl restart postfix

	# Checking VPN Users directory
	if [ ! -d $HOME_DIR ] 
	then
		echo "VPN Users directory is not created... Creating..."
		mkdir -p $HOME_DIR
	else
		echo "VPN Users directory already exists, cleaning old files..."
		rm -f $HOME_DIR/* > /dev/null 2>&1
	fi

	while true
        do
            read -p 'Do you want to create your first user? (yes/no): ' RESPONSE
            case "${RESPONSE}" in
                [yY]|[yY][eE][sS]) echo "Creating your first user..." && newClient && break ;;
                [nN]|[nN][oO]) echo "Skipping,..." && break ;;
            esac
        done
	
	echo "If you want to add more users, you simply need to run this script another time!"

	# Check if WireGuard is running
	systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
	WG_RUNNING=$?

	# WireGuard might not work if we updated the kernel. Tell the user to reboot
	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}WARNING: WireGuard does not seem to be running.${NC}"
		echo -e "${ORANGE}You can check if WireGuard is running with: systemctl status wg-quick@${SERVER_WG_NIC}${NC}"
		echo -e "${ORANGE}If you get something like \"Cannot find device ${SERVER_WG_NIC}\", please reboot!${NC}"
	fi
}

function newClient() {
	ENDPOINT="${SERVER_PUB_NAME}:${SERVER_PORT}"
	echo ""
	echo "Tell me a name for the user."
	echo "The name must consist of alphanumeric character. It may also include an underscore or a dash and can't exceed 15 chars."

	until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
		read -rp "User name: " -e CLIENT_NAME
		CLIENT_EXISTS=$(grep -c -E "^### User ${CLIENT_NAME}\$" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${CLIENT_EXISTS} == '1' ]]; then
			echo ""
			echo "A user with the specified name was already created, please choose another name."
			echo ""
		fi
	done

	for DOT_IP in {2..254}; do
		DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "/etc/wireguard/${SERVER_WG_NIC}.conf")
		if [[ ${DOT_EXISTS} == '0' ]]; then
			break
		fi
	done

	if [[ ${DOT_EXISTS} == '1' ]]; then
		echo ""
		echo "The subnet configured supports only 253 users."
		exit 1
	fi

	BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	until [[ ${IPV4_EXISTS} == '0' ]]; do
		read -rp "User WireGuard IPv4: ${BASE_IP}." -e -i "${DOT_IP}" DOT_IP
		CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"
		IPV4_EXISTS=$(grep -c "$CLIENT_WG_IPV4/24" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${IPV4_EXISTS} == '1' ]]; then
			echo ""
			echo "A user with the specified IPv4 was already created, please choose another IPv4."
			echo ""
		fi
	done

	BASE_IP=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
	until [[ ${IPV6_EXISTS} == '0' ]]; do
		read -rp "User WireGuard IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" DOT_IP
		CLIENT_WG_IPV6="${BASE_IP}::${DOT_IP}"
		IPV6_EXISTS=$(grep -c "${CLIENT_WG_IPV6}/64" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${IPV6_EXISTS} == '1' ]]; then
			echo ""
			echo "A user with the specified IPv6 was already created, please choose another IPv6."
			echo ""
		fi
	done

	# Generate key pair for the client
	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	# Home directory of the user, where the client configuration will be written
	#if [ -e "/home/${CLIENT_NAME}" ]; then
	#	# if $1 is a user name
	#	HOME_DIR="/web/hallon/vpn_users_conf"
	#elif [ "${SUDO_USER}" ]; then
	#	# if not, use SUDO_USER
	#	if [ "${SUDO_USER}" == "root" ]; then
	#		# If running sudo as root
	#		HOME_DIR="/web/hallon/vpn_users_conf"
	#	else
	#		HOME_DIR="/web/hallon/vpn_users_conf"
	#	fi
	#else
	#	# if not SUDO_USER, use /root
	#	HOME_DIR="/web/hallon/vpn_users_conf"
	#fi

	# Create client file and add the server as a peer
	echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128

DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0,::/0" >>"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	# Add the client as a peer to the server
	echo -e "\n### User ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

	echo -e "\nHere is your user config file as a QR Code:"

    #We generate the qr as png and we save and send it to user.
	#qrencode -t ansiutf8 -l L <"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	echo "It is also available in ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	echo "We are sending an email with wireguard .conf file and QR file..."

	while true
		do
		    read -p "Insert the user email to send wireguard VPN conf (If you left blank I will send to ${SYSADMIN_EMAIL}): " CLIENT_EMAIL
		    echo
			if [[ $CLIENT_EMAIL == "" ]]; then
				echo "Generating QR easy access..."
				qrencode -s 6 -l H -o "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-QR.png" < "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
				echo "Sending to default email, ${SYSADMIN_EMAIL}."
				cat "${GIT_DIR}/resources/mail-body.html" | sendemail -t "${SYSADMIN_EMAIL}" -u "Tu configuracion VPN" -a "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf" "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-QR.png" "${GIT_DIR}/resources/wireguard-docu.docx" -f "Hallon-VPN <no-reply@hallon.es>" -S
				break
		    elif [[ "$CLIENT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; then
				echo "Generating QR easy access..."
				qrencode -s 6 -l H -o "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-QR.png" < "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
				echo "Sending to user email, ${CLIENT_EMAIL}."
				cat "${GIT_DIR}/resources/mail-body.html" | sendemail -t "${CLIENT_EMAIL}" -u "Tu configuracion VPN" -a "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf" "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-QR.png" "${GIT_DIR}/resources/wireguard-docu.docx" -f "Hallon-VPN <no-reply@hallon.es>" -S
				break
		    else
		        echo "Email address ${CLIENT_EMAIL} is invalid. Please insert a valid address like foo@bar.com or leave it blank."
		    fi
		done
	
}

function revokeClient() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### User" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
		echo ""
		echo "You have no existing users!"
		exit 1
	fi

	echo ""
	echo "Select the existing user you want to revoke"
	grep -E "^### User" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
		if [[ ${CLIENT_NUMBER} == '1' ]]; then
			read -rp "Select one user [1]: " CLIENT_NUMBER
		else
			read -rp "Select one user [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
		fi
	done

	# match the selected number to a client name
	CLIENT_NAME=$(grep -E "^### User" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

	# remove [Peer] block matching $CLIENT_NAME
	sed -i "/^### User ${CLIENT_NAME}\$/,/^$/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"

	# Home directory of the user, where the client configuration will be removed
	#if [ -e "/home/${CLIENT_NAME}" ]; then
	#	# if $1 is a user name
	#	HOME_DIR="/web/hallon/vpn_users_conf"
	#elif [ "${SUDO_USER}" ]; then
	#	# if not, use SUDO_USER
	#	if [ "${SUDO_USER}" == "root" ]; then
	#		# If running sudo as root
	#		HOME_DIR="/web/hallon/vpn_users_conf"
	#	else
	#		HOME_DIR="/web/hallon/vpn_users_conf"
	#	fi
	#else
	#	# if not SUDO_USER, use /root
	#	HOME_DIR="/web/hallon/vpn_users_conf"
	#fi

	# remove generated client file
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-QR.png"

	# restart wireguard to apply changes
	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")
}

function uninstallWg() {
	echo ""
	read -rp "Do you really want to remove WireGuard? [y/n]: " -e -i n REMOVE
	if [[ $REMOVE == 'y' ]]; then
		checkOS

		systemctl stop "wg-quick@${SERVER_WG_NIC}"
		systemctl disable "wg-quick@${SERVER_WG_NIC}"

		if [[ ${OS} == 'ubuntu' ]]; then
			apt-get autoremove --purge -y wireguard qrencode
		elif [[ ${OS} == 'debian' ]]; then
			apt-get autoremove --purge -y wireguard qrencode
		elif [[ ${OS} == 'fedora' ]]; then
			dnf remove -y wireguard-tools qrencode
			if [[ ${VERSION_ID} -lt 32 ]]; then
				dnf remove -y wireguard-dkms
				dnf copr disable -y jdoss/wireguard
			fi
			dnf autoremove -y
		elif [[ ${OS} == 'centos' ]]; then
			yum -y remove kmod-wireguard wireguard-tools qrencode
			yum -y autoremove
		elif [[ ${OS} == 'oracle' ]]; then
			yum -y remove wireguard-tools qrencode
			yum -y autoremove
		elif [[ ${OS} == 'arch' ]]; then
			pacman -Rs --noconfirm wireguard-tools qrencode
		fi

		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/wg.conf

		# Reload sysctl
		sysctl --system

		# Check if WireGuard is running
		systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
		WG_RUNNING=$?

		if [[ ${WG_RUNNING} -eq 0 ]]; then
			echo "WireGuard failed to uninstall properly."
			exit 1
		else
			echo "WireGuard uninstalled successfully."
			exit 0
		fi
	else
		echo ""
		echo "Removal aborted!"
	fi
}

function resendEmail() {
	HOME_DIR="/web/hallon/vpn_users_conf"
	NUMBER_OF_CLIENTS=$(grep -c -E "^### User" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
		echo ""
		echo "You have no existing users!"
		exit 1
	fi

	echo ""
	echo "Select the existing user config you want to resend the email:"
	grep -E "^### User" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
		if [[ ${CLIENT_NUMBER} == '1' ]]; then
			read -rp "Select one user [1]: " CLIENT_NUMBER
		else
			read -rp "Select one user [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
		fi
	done

	# match the selected number to a client name
	CLIENT_NAME=$(grep -E "^### User" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

	while true
		do
		    read -p "Insert the user email to resend wireguard VPN conf (If you left blank I will send to ${SYSADMIN_EMAIL}): " CLIENT_EMAIL
		    echo
			if [[ $CLIENT_EMAIL == "" ]]; then
				echo "Generating QR easy access..."
				qrencode -s 6 -l H -o "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-QR.png" < "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
				echo "Resending to default email, ${SYSADMIN_EMAIL}."
				cat "${GIT_DIR}/resources/mail-body.html" | sendemail -t "${SYSADMIN_EMAIL}" -u "Tu configuracion VPN" -a "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf" "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-QR.png" "${GIT_DIR}/resources/wireguard-docu.docx" -f "Hallon-VPN <no-reply@hallon.es>" -S
				break
		    elif [[ "$CLIENT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; then
				echo "Generating QR easy access..."
				qrencode -s 6 -l H -o "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-QR.png" < "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
				echo "Resending to user email, ${CLIENT_EMAIL}."
				cat "${GIT_DIR}/resources/mail-body.html" | sendemail -t "${CLIENT_EMAIL}" -u "Tu configuracion VPN" -a "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf" "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}-QR.png" "${GIT_DIR}/resources/wireguard-docu.docx" -f "Hallon-VPN <no-reply@hallon.es>" -S
				break
		    else
		        echo "Email address ${CLIENT_EMAIL} is invalid. Please insert a valid address like foo@bar.com or leave it blank."
		    fi
		done
}

function manageMenu() {
	echo "Welcome to WireGuard-install!"
	echo "The git repository is available at: https://github.com/Admin-Hallon/wireguard"
	echo ""
	echo "It looks like WireGuard is already installed."
	echo ""
	echo "What do you want to do?"
	echo "   1) Add a new user"
	echo "   2) Revoke existing user"
	echo "   3) Resend email with wireguard config files"
	echo "   4) Uninstall WireGuard"
	echo "   5) Exit"
	until [[ ${MENU_OPTION} =~ ^[1-5]$ ]]; do
		read -rp "Select an option [1-5]: " MENU_OPTION
	done
	case "${MENU_OPTION}" in
	1)
		newClient
		;;
	2)
		revokeClient
		;;
	3)
		resendEmail
		;;
	4)
		uninstallWg
		;;
	5)
		exit 0
		;;
	esac
}

# Check for root, virt, OS...
initialCheck

# Check if WireGuard is already installed and load params
if [[ -e /etc/wireguard/params ]]; then
	source /etc/wireguard/params
	manageMenu
else
	installWireGuard
fi
