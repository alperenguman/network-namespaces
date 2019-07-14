## Network Namespaces

Linux network namespaces are a kernel feature that let you define a virtual network environment seperate and completely isolated from the one your physical network adapters are in. 

This is especially useful for scenarios such as setting up a VPN to spoof IP and keep real public IP simultaneously. Or to assume multiple spoofed WAN addresses at once. An additional benefit is spoofed local IPs, which are detectable by technologies such as WebRTC.

Any command executed with the "ip netns exec [namespace name]" prefix can only see the virtual network configuration available within that space and nothing else. 

This helper script was written to configure multiple network namespaces. It creates all the required virtual adapters, assigns ips and configures routing to make sure the newly created namespace gets internet access. It optionally configures unique DNS and VPN per each namespace and summarizes all configurations at the end. 

It's meant for a Debian-based distro and is configured with NordVPN config files by default but can be changed to work with any service provider that supports the OpenVPN protocol.