#!/bin/bash

### DEFAULTS ###

# names of executables used in script
required_progs=( 'dnsmasq' 'hostapd' 'iptables' 'ip' )

# dhcp
client_subnet='172.16.55.0'

# wireless
hostapd_cfg='/tmp/hostapd.conf'
ssid='share_net'
channel='11'
# generate random 8-character PSK
wpa_psk=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)

# trap for cleanup
trap cleanup SIGINT SIGTERM SIGHUP


### FUNCTIONS ###

usage() {

	cat <<EOF
${0##*/} version $version
Usage: ${0##*/} [options]

 Options:

	-i	<internet_interface>
	-s	<shared_interface>
	-d	<DHCP subnet> e.g. 10.0.0.0
	-b	enable bridged mode (instead of NAT)

  Programs required:

	${required_progs[*]}

EOF
	exit 0

}


check_root() {

	if [ $EUID -ne 0 ]; then
		printf "[!] Please sudo me!\n"
		exit 1
	fi

}


check_progs() {

	reqs=("$@")
	to_install=''

	for bin in "${reqs[@]}"; do
		hash $bin 2>/dev/null || to_install="$to_install $bin"
	done

	if [ -n "$to_install" ]; then
		printf "Programs required:\n$to_install\n"
		exit 0
	fi

}


get_ifcs() {

	[ "$check_int_ifc" = false ] || int_ifc=$(ip -o addr show | grep 'enp\|eth\|wlp\|wlan\|tun' | grep 'inet ' | tail -n 1 | awk '{print $2}' | cut -d':' -f1)
	[ "$check_shared_ifc" = false ] || shared_ifc=$(ip -o link | grep 'enp\|eth\|wlp\|wlan' | grep -v $int_ifc | tail -n 1 | awk '{print $2}' | cut -d':' -f1)
	case "$shared_ifc" in
		*wlp*|*wlan*)
			is_ap=true
	esac

}


check_vars() {

	if [ -z $int_ifc ]; then
		printf "[!] Please specify internet interface (-i)\n"
		exit 0
	elif [ -z $shared_ifc ]; then
		printf "[!] Please specify shared interface (-s)\n"
		exit 0
	fi

}


set_ifc_ip() {

	subnet_trunc=${client_subnet%.*}
	gateway="$subnet_trunc.1"
	range_start="$subnet_trunc.100"
	range_end="$subnet_trunc.200"

	old_ip=$(ip -o addr show dev $shared_ifc | grep -v inet6 | awk '{print $4}')
	ip link set down dev $shared_ifc
	ip addr flush dev $shared_ifc
	ip link set up dev $shared_ifc
	ip addr add "$gateway/24" dev $shared_ifc
	ip link set up dev $shared_ifc

}


reset_ifc_ip() {

	ip addr del dev $shared_ifc "$gateway/24"
	if [ -n "$old_ip" ]; then
		ip addr add dev $shared_ifc $old_ip
	fi

}


start_dnsmasq() {

	ifc="$1"

	dnsmasq -a $gateway -d -F $range_start,$range_end,255.255.255.0,12h --dhcp-option=3,$gateway --interface=$ifc

}


start_hostapd() {

		cat <<EOF > $hostapd_cfg
beacon_int=100
ssid=share-net
hw_mode=g
wpa=2
wpa_passphrase=$wpa_psk
interface=$shared_ifc
channel=$channel
EOF
	hostapd $hostapd_cfg &

}


iptables_on() {

	iptables -t nat -A POSTROUTING -o $int_ifc -j MASQUERADE
	iptables -A FORWARD -i $int_ifc -o $shared_ifc -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	iptables -A FORWARD -i $shared_ifc -o $int_ifc -j ACCEPT

}


iptables_off() {

	iptables -t nat -D POSTROUTING -o $int_ifc -j MASQUERADE
	iptables -D FORWARD -i $int_ifc -o $shared_ifc -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	iptables -D FORWARD -i $shared_ifc -o $int_ifc -j ACCEPT

}


bridge_on() {

	ip link delete ics_bridge type bridge 2>/dev/null

	ip link add name ics_bridge type bridge
	ip link set up ics_bridge up

	#ip link set down dev $int_ifc
	#ip link set down dev $shared_ifc

	ip link set $int_ifc master ics_bridge || cleanup
	ip link set $shared_ifc master ics_bridge || cleanup

	#ip link set up dev $int_ifc
	#ip link set up dev $shared_ifc

}


bridge_off() {

	ip link set $int_ifc nomaster
	ip link set $shared_ifc nomaster
	ip link delete ics_bridge type bridge 2>/dev/null

}


start_ics() {

	printf "\n[+] Checking root\n"
	check_root
	printf "[+] Checking interfaces\n"
	get_ifcs
	printf " |--- Internet: %s\n" "$int_ifc"
	printf " |--- Shared:   %s\n" "$shared_ifc"
	printf "[+] Checking binaries\n"
	check_progs "${required_progs[@]}"
	check_vars

	ip link set dev $shared_ifc up
	ip link set dev $int_ifc up

	if [ "$is_ap" = true ]; then
		printf "[+] Starting hostapd\n"
		start_hostapd
		printf "[+] Connection info:\n\n	SSID: %s\n	PSK:  %s\n\n" "$ssid" "$wpa_psk"
	fi

	printf "[+] Press CTRL+C to quit\n"

	if [ "$bridged_mode" = true ]; then
		printf "[+] Bridging interfaces\n\n"
		bridge_on
		sleep infinity
	else
		set_ifc_ip
		printf "[+] Starting iptables\n"
		iptables_on
		printf "[+] Enabling ip forwarding\n"
		echo 1 > /proc/sys/net/ipv4/ip_forward
	
		printf "[+] Starting dnsmasq\n\n"
		start_dnsmasq "$shared_ifc"
	fi

}


cleanup() {

	if [ "$?" -ne 0 ]; then

		printf "[+] Cleaning up\n"

		if [ "$bridged_mode" = true ]; then
			bridge_off
		else
			echo 0 > /proc/sys/net/ipv4/ip_forward
			killall dnsmasq 2>/dev/null
			killall hostapd 2>/dev/null
			rm $hostapd_cfg 2>/dev/null
			iptables_off 2>/dev/null
			reset_ifc_ip 2>/dev/null
		fi

		ip link set dev $shared_ifc down
		if [ "$is_ap" = true ]; then
			iwconfig $shared_ifc mode managed
		fi
		ip link set dev $shared_ifc up

	fi

}


### PARSE ARGUMENTS ###

check_int_ifc=true
check_shared_ifc=true
bridged_mode=false

while :; do
	case $1 in
		-i)
			shift
			int_ifc=$1
			check_int_ifc=false
			;;
		-s)
			shift
			shared_ifc=$1
			check_shared_ifc=false
			;;
		-d)
			shift
			client_subnet=$1
			;;
		-b)
			bridged_mode=true
			;;
		-h|--help)
			usage
			;;
		*)
			break
	esac
	shift
done

# start main script

start_ics