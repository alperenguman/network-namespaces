#!/bin/bash


namespace_name="ns1"
dns1="103.86.96.100"
dns2="103.86.99.100"
openvpn_config="https://downloads.nordcdn.com/configs/archives/servers/ovpn.zip"
openvpn_country="us"

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
    [ "$answer" == "y" ] && sudo ip netns del "$namespace_name" || (echo "exiting..." & exit 1)
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
sudo ip netns exec $namespace_name ping -c 3 127.0.0.1
echo -e "\e[93m\e[1m"
echo "Creating veth link..."
sudo ip link add v-eth-to-$namespace_name type veth peer name v-peer1

echo "Adding peer1 to $namespace_name"
sudo ip link set v-peer1 netns $namespace_name

echo "Setting up IP address of v-eth-to-$namespace_name..."

sudo ip addr add 10.20$(sudo ip netns | wc -l).1.1/24 dev v-eth-to-$namespace_name
sudo ip link set v-eth-to-$namespace_name up

echo "Setting up IP address of v-peer1..."
sudo ip netns exec $namespace_name ip addr add 10.20$(sudo ip netns | wc -l).1.2/24 dev v-peer1
sudo ip netns exec $namespace_name ip link set v-peer1 up

echo "Routing all traffic leaving $namespace_name through v-eth-to-$namespace_name"
sudo ip netns exec $namespace_name ip route add default via 10.20$(sudo ip netns | wc -l).1.1

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

echo "Enabling masquerading of 10.20$(sudo ip netns | wc -l).1.0"
sudo iptables -t nat -A POSTROUTING -s 10.20$(sudo ip netns | wc -l).1.0/255.255.255.0 -o "$default_interface" -j MASQUERADE

echo "Allowing forwarding between $default_interface and v-eth-to-$namespace_name"
sudo iptables -A FORWARD -i "$default_interface" -o v-eth-to-$namespace_name -j ACCEPT
sudo iptables -A FORWARD -o "$default_interface" -i v-eth-to-$namespace_name -j ACCEPT

echo "Pinging external host from $namespace_name to test connectivity..."
echo -e "\e[0m"
sudo ip netns exec $namespace_name ping -c 3 8.8.8.8


# Set up DNS for namespace
echo -e "\n\e[93m\e[1mSetting up DNS for $namespace_name"
echo "Creating directories.."
sudo rm -rf "/etc/netns/$namespace_name"
sudo mkdir -p "/etc/netns/$namespace_name"
sudo cp /etc/resolv.conf "/etc/netns/$namespace_name/"

# Download & set up openvpn config
echo -en "Setup Openvpn for $namespace_name? (y/N): \e[0m"
read answer
if [ "$answer" == "y" ]
then
	if [ -z "$(sudo which openvpn)" ]
	then
		sudo apt-get install openvpn wget ca-certificates unzip
	fi
	sudo bash -c "echo -e 'nameserver $dns1\nnameserver $dns2' > '/etc/netns/$namespace_name/resolv.conf'"
	sudo wget -nc -P /etc/openvpn/ $openvpn_config
	sudo unzip -n $(ls /etc/openvpn/*.zip) -d /etc/openvpn/nord 
	selected_config=$(ls /etc/openvpn/nord/ovpn_udp/$openvpn_country* | sort -R | tail -n 1)
	sudo ip netns exec $namespace_name openvpn --config $selected_config --daemon
	echo "Connecting..."
	sleep 3
	echo -e "Public IP: $(sudo ip netns exec $namespace_name dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')\n"
fi

# Summarize all namespaces
echo ""
for i in {1..10}; do echo -n =; done
echo -n " Real Network "
for i in {1..10}; do echo -n =; done
echo -e "\n+ Local IP: $(hostname -I | awk '{print $1}')"
echo -e "+ Public IP: $(sudo dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')"
echo -e "+ DNS resolver: $(sudo nslookup google.com | grep Server | awk '{print $2;}')\n"


for i in $(ip netns | awk '{print $1}' | tr '\r\n' ' ')
do

	current_namespace="$i"
	for i in {1..10}; do echo -n =; done
	echo -n " $current_namespace Network Namespace "
	for i in {1..10}; do echo -n =; done
	echo -e "\n+ Local IP: $(sudo ip netns exec $current_namespace hostname -I | awk '{print $1}')"
	echo -e "+ Public IP: $(sudo ip netns exec $current_namespace dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')"
	echo -e "+ DNS resolver: $(sudo ip netns exec $current_namespace nslookup google.com | grep Server | awk '{print $2;}')\n"
done



