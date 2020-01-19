#!/bin/bash


namespace_name="ns1"
dns1="103.86.96.100"
dns2="103.86.99.100"
openvpn_config="https://downloads.nordcdn.com/configs/archives/servers/ovpn.zip"
openvpn_country="us"
n=$((200+$(sudo ip netns | wc -l)))
local_ip_range="10.$n.5"
auth_dir="/tmp/openvpn/temp_dir"

function summarize (){
	# Summarize all namespaces
	echo ""
	title="Real Network"
	echo -en " \e[1m$title\e[0m "
	echo -e "\n Local IP: $(hostname -I | awk '{print $1}')"
	echo -e " Public IP: $(sudo dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')"
	echo -e " DNS resolver: $(sudo nslookup google.com | grep Server | awk '{print $2;}')\n"

	for i in $(ip netns | awk '{print $1}' | tr '\r\n' ' ')
	do
		current_namespace="$i"
		title="$current_namespace Network Namespace"
		echo -en " \e[1m$title\e[0m "
		echo -e "\n Local IP: $(sudo ip netns exec $current_namespace hostname -I | awk '{print $1}')"
		echo -e " Public IP: $(sudo ip netns exec $current_namespace dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')"
		echo -e " DNS resolver: $(sudo ip netns exec $current_namespace nslookup -timeout=1 google.com | grep Server | awk '{print $2;}')\n"
	done
	}

function kill_openvpn (){
	for i in $(sudo ip netns pid $1)
	do
		if [ "$(ps -p $i -o comm=)" == "openvpn" ]
		then
			echo "Killing openvpn with pid: $i"
			sudo kill $i
		fi
	done 
}

if [ "$1" == "--summarize" ] || [ "$1" == "-s" ];
then
	summarize
	set -e
	exit 0
fi

if [ "$1" == "-reset" ] || [ "$1" == "-r" ];
then
	gpg -d -o $auth_dir/auth.txt $auth_dir/auth.txt.asc
	sudo /usr/bin/killall -s HUP openvpn &&
	sudo rm "$auth_dir/auth.txt"
	set -e
	exit 0
fi

# Get desired network namespace name
echo -en "\e[93m\e[1mEnter namespace name ($namespace_name): \e[0m"
read input_namespace
if [ -z "$input_namespace" ] 
then 
	echo "continuing..." 
else 
	echo "changing to $input_namespace" 
	namespace_name="$input_namespace"
fi

# Check if namespace exists
if [ -z "$(sudo ip netns | grep "$namespace_name")" ]
then
    echo "Creating $namespace_name"
else
    echo -en "\e[93m\e[1m$namespace_name already exists, would you like to delete and recreate it? (y/N): \e[0m"
    read answer
    set -e
    if [ "$answer" == "y" ]
    then
    	kill_openvpn $namespace_name && sudo ip netns del "$namespace_name" && sudo ip link delete v-eth-to-$namespace_name 
    else
    	echo "exiting..."
    	exit 1
    fi
    set +e
fi

sudo ip netns add $namespace_name

# Get desired default interface
default_interface=$(ip route | grep default | awk '{print $5;}')
echo -n "Enter default interface ($default_interface): "
read input_interface
if [ -z "$input_interface" ] 
then 
	echo "continuing..." 
else
	echo "changing to $input_interface" 
	default_interface="$input_interface"
fi


echo -e "\e[93m\e[1m"
echo -e "Current network namespaces: \n\e[0m$(sudo ip netns)\n\e[93m\e[1m"
echo "Adding loopback interface to $namespace_name..."
echo -e "\e[0m"
sudo ip netns exec $namespace_name ip link set dev lo up
sudo ip netns exec $namespace_name ping -i 0.2 -c 3 127.0.0.1
echo -e "\e[93m\e[1m"
echo "Creating veth link..."
sudo ip link add v-eth-to-$namespace_name type veth peer name v-peer1

echo "Adding peer1 to $namespace_name"
sudo ip link set v-peer1 netns $namespace_name

echo "Setting up IP address of v-eth-to-$namespace_name..."

sudo ip addr add $local_ip_range.1/24 dev v-eth-to-$namespace_name
sudo ip link set v-eth-to-$namespace_name up

echo "Setting up IP address of v-peer1..."
sudo ip netns exec $namespace_name ip addr add $local_ip_range.2/24 dev v-peer1
sudo ip netns exec $namespace_name ip link set v-peer1 up

echo "Routing all traffic leaving $namespace_name through v-eth-to-$namespace_name"
sudo ip netns exec $namespace_name ip route add default via $local_ip_range.1

echo "Configuring shared internet access between host and $namespace_name"
echo "Enabling IP forwarding"
sudo bash -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'

if [ $(sudo ip netns | wc -l) -lt 2 ]
then
	echo "Flushing forward rules, policy DROP by default"
	sudo iptables -P FORWARD DROP
	sudo iptables -F FORWARD

	echo "Flushing NAT rules..."
	sudo iptables -t nat -F
fi

echo "Enabling masquerading of $local_ip_range.0"
sudo iptables -t nat -A POSTROUTING -s $local_ip_range.0/255.255.255.0 -o "$default_interface" -j MASQUERADE

echo "Allowing forwarding between $default_interface and v-eth-to-$namespace_name"
sudo iptables -A FORWARD -i "$default_interface" -o v-eth-to-$namespace_name -j ACCEPT
sudo iptables -A FORWARD -o "$default_interface" -i v-eth-to-$namespace_name -j ACCEPT

echo "Pinging external host from $namespace_name to test connectivity..."
echo -e "\e[0m"
sudo ip netns exec $namespace_name ping -i 0.2 -c 3 8.8.8.8


# Set up DNS for namespace
echo -e "\n\e[93m\e[1mSetting up DNS for $namespace_name"
echo "Creating directories.."
sudo rm -rf "/etc/netns/$namespace_name"
sudo mkdir -p "/etc/netns/$namespace_name"
sudo cp /etc/resolv.conf "/etc/netns/$namespace_name/"

# Download & set up openvpn config
echo -en "Setup Openvpn for $namespace_name? (Y/n): \e[0m"
read answer
if [ "$answer" != "n" ] && [ "$answer" != "N" ];
then
	if [ -z "$(sudo which openvpn)" ]
	then
		sudo apt-get install openvpn wget ca-certificates unzip
	fi
	sudo bash -c "echo -e 'nameserver $dns1\nnameserver $dns2' > '/etc/netns/$namespace_name/resolv.conf'"
	sudo wget -nc -P /etc/openvpn/ $openvpn_config
	sudo unzip -n $(ls /etc/openvpn/*.zip) -d /etc/openvpn/nord 
	
	if [ ! -f "$auth_dir/auth.txt.asc" ]
	then
		sudo mkdir -p "$auth_dir"
		sudo mount -t tmpfs -o size=1m tmpfs "$auth_dir"
		echo -n "Enter username: "
		read username
		pass="$(sudo /lib/cryptsetup/askpass "Enter password:")"
		sudo sh -c "echo '$username\n$pass' > $auth_dir/auth.txt"
		gpg -a -e -R $username $auth_dir/auth.txt
	else
		gpg -d -o $auth_dir/auth.txt $auth_dir/auth.txt.asc
	fi

	selected_config=$(ls /etc/openvpn/nord/ovpn_udp/$openvpn_country* | sort -R | tail -n 1)

	# TODO: Configure deamon as system service to make sure connection persists across sleep and boot

	sudo ip netns exec $namespace_name openvpn --config $selected_config --auth-user-pass "$auth_dir/auth.txt" --daemon
	echo "Connecting..."
	sleep 3
	echo -e "Public IP: $(sudo ip netns exec $namespace_name dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')\n"
	echo "Changing default route to VPN..."
	sudo ip netns exec $namespace_name ip route del default
	sudo ip netns exec $namespace_name ip route add default via $(sudo ip netns exec $namespace_name ip route | grep 0.0.0.0 | awk '{print $3}')
	sudo rm "$auth_dir/auth.txt"
fi

summarize
