#!/bin/bash
set -e

if [[ $EUID -ne 0 ]]; then
    echo "You must be root to run this script"
    exit 1
fi

ip -all netns delete

FIREWALL_NAMESPACE="firewall"

SERVER_NAMESPACE="server"
FIREWALL_to_SERVER_VETH="veth1"
SERVER_to_FIREWALL_VETH="veth2"

CLIENT_one_NAMESPACE="client1"
FIREWALL_to_CLIENT_one_VETH="veth2"
CLIENT_one_to_FIREWALL_VETH="veth3"

CLIENT_two_NAMESPACE="client2"
FIREWALL_to_CLIENT_two_VETH="veth3"
CLIENT_two_to_FIREWALL_VETH="veth4"

#Create Namespaces
ip netns add $SERVER_NAMESPACE
ip netns add $CLIENT_one_NAMESPACE
ip netns add $CLIENT_two_NAMESPACE
ip netns add $FIREWALL_NAMESPACE

#Enable forwarding in firewall
ip netns exec $FIREWALL_NAMESPACE sysctl -w net.ipv4.ip_forward=1

#Connect spaces

## Server
ip link add $FIREWALL_to_SERVER_VETH type veth peer name $SERVER_to_FIREWALL_VETH
ip link set $SERVER_to_FIREWALL_VETH netns $SERVER_NAMESPACE
ip link set $FIREWALL_to_SERVER_VETH netns $FIREWALL_NAMESPACE

##client1
ip link add $CLIENT_one_to_FIREWALL_VETH type veth peer name $FIREWALL_to_CLIENT_one_VETH
ip link set $CLIENT_one_to_FIREWALL_VETH netns $CLIENT_one_NAMESPACE
ip link set $FIREWALL_to_CLIENT_one_VETH netns $FIREWALL_NAMESPACE

#client2
ip link add $CLIENT_two_to_FIREWALL_VETH type veth peer name $FIREWALL_to_CLIENT_two_VETH
ip link set $CLIENT_two_to_FIREWALL_VETH netns $CLIENT_two_NAMESPACE
ip link set $FIREWALL_to_CLIENT_two_VETH netns $FIREWALL_NAMESPACE 

#ip assignment
ip netns exec $SERVER_NAMESPACE ip addr add 192.0.2.130/26 dev $SERVER_to_FIREWALL_VETH #server
ip netns exec $FIREWALL_NAMESPACE ip addr add 192.0.2.129/26 dev $FIREWALL_to_SERVER_VETH

ip netns exec $CLIENT_one_NAMESPACE ip add add 192.0.2.2/26 dev $CLIENT_one_to_FIREWALL_VETH #cli1
ip netns exec $FIREWALL_NAMESPACE ip add add 192.0.2.1/26 dev $FIREWALL_to_CLIENT_one_VETH

ip netns exec $CLIENT_two_NAMESPACE ip add add 192.0.2.66/26 dev $CLIENT_two_to_FIREWALL_VETH #cli2
ip netns exec $FIREWALL_NAMESPACE ip add add 192.0.2.65/26 dev $FIREWALL_to_CLIENT_two_VETH

# up lo
ip netns exec $FIREWALL_NAMESPACE ip link set dev lo up
ip netns exec $SERVER_NAMESPACE ip link set dev lo up
ip netns exec $CLIENT_one_NAMESPACE ip link set dev lo up
ip netns exec $CLIENT_two_NAMESPACE ip link set dev lo up

# Up Firewall interface
ip netns exec $FIREWALL_NAMESPACE ip link set dev $FIREWALL_to_SERVER_VETH up
ip netns exec $FIREWALL_NAMESPACE ip link set dev $FIREWALL_to_CLIENT_one_VETH up
ip netns exec $FIREWALL_NAMESPACE ip link set dev $FIREWALL_to_CLIENT_two_VETH up

# Up endpoints
ip netns exec $SERVER_NAMESPACE ip link set dev $SERVER_to_FIREWALL_VETH up

ip netns exec $CLIENT_one_NAMESPACE ip link set dev $CLIENT_one_to_FIREWALL_VETH up

ip netns exec $CLIENT_two_NAMESPACE ip link set dev $CLIENT_two_to_FIREWALL_VETH up


# Set Routing
ip netns exec $CLIENT_one_NAMESPACE ip route add 192.0.2.64/26 via 192.0.2.1
ip netns exec $CLIENT_one_NAMESPACE ip route add 192.0.2.128/26 via 192.0.2.1 

ip netns exec $CLIENT_two_NAMESPACE ip route add 192.0.2.0/26 via 192.0.2.65
ip netns exec $CLIENT_two_NAMESPACE ip route add 192.0.2.128/26 via 192.0.2.65

ip netns exec $SERVER_NAMESPACE ip route add 192.0.2.0/26 via 192.0.2.129
ip netns exec $SERVER_NAMESPACE ip route add 192.0.2.64/26 via 192.0.2.129

#iptables 
ip netns exec $CLIENT_one_NAMESPACE iptables --policy FORWARD ACCEPT
ip netns exec $CLIENT_two_NAMESPACE iptables  --policy FORWARD ACCEPT
ip netns exec $SERVER_NAMESPACE iptables --policy FORWARD ACCEPT

#Disable all traffic on firewall
ip netns exec $FIREWALL_NAMESPACE iptables -t filter -P INPUT DROP
ip netns exec $FIREWALL_NAMESPACE iptables -t filter -P FORWARD DROP


#client2 subnet can ping to firewall
ip netns exec $FIREWALL_NAMESPACE iptables -A INPUT -s 192.0.2.64/26 -p icmp -j ACCEPT
#client2 can ping to server
ip netns exec $FIREWALL_NAMESPACE iptables -t filter -A FORWARD -i $FIREWALL_to_CLIENT_two_VETH -j ACCEPT
ip netns exec $FIREWALL_NAMESPACE iptables -t filter -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

#client 1 can ping to server
ip netns exec $FIREWALL_NAMESPACE iptables -t filter -A FORWARD -i $FIREWALL_to_CLIENT_one_VETH -j ACCEPT

#client 1 can not ping to firewall
ip netns exec $FIREWALL_NAMESPACE iptables -A INPUT -s 192.0.1.2 -p icmp -j DROP

#client 1 can access to server
ip netns exec $FIREWALL_NAMESPACE iptables -t nat -A PREROUTING -p tcp -i $FIREWALL_to_CLIENT_one_VETH --destination-port 8888 -j DNAT  --to-destination 192.0.2.130:8888
ip netns exec $FIREWALL_NAMESPACE iptables -t filter -A FORWARD -p tcp -i $FIREWALL_to_CLIENT_one_VETH --destination-port 8888 -d 192.0.2.130 -j ACCEPT

#client 2 can access to server
ip netns exec $FIREWALL_NAMESPACE iptables -t nat -A PREROUTING -p tcp -i $FIREWALL_to_CLIENT_two_VETH --destination-port 8888 -j DNAT  --to-destination 192.0.2.130:8888
ip netns exec $FIREWALL_NAMESPACE iptables -t filter -A FORWARD -p tcp -i $FIREWALL_to_CLIENT_two_VETH --destination-port 8888 -d 192.0.2.130 -j ACCEPT


# tests
echo "--------------------------------------------"
echo " "

echo "test $CLIENT_one_NAMESPACE ping to server"

if ip netns exec $CLIENT_one_NAMESPACE  ping -c 1 192.0.2.130 &> /dev/null
then
	echo "OK"
else
	echo "FAIL"
fi
echo "--------------------------------------------"

echo "test $CLIENT_one_NAMESPACE ping to firewall"

if ip netns exec $CLIENT_one_NAMESPACE  ping -c 1 192.0.2.1 &> /dev/null
then
        echo "OK"
else
        echo "FAIL"
fi

echo "--------------------------------------------"

echo "test $CLIENT_two_NAMESPACE ping to server"
if ip netns exec $CLIENT_two_NAMESPACE  ping -c 1 192.0.2.130 &> /dev/null
then
    	echo "OK"
else
    	echo "FAIL"
fi

echo "--------------------------------------------"

echo "test $CLIENT_two_NAMESPACE ping to firewall"

if ip netns exec $CLIENT_two_NAMESPACE  ping -c 1 192.0.2.65 &> /dev/null
then
    	echo "OK"
else
    	echo "FAIL"
fi

echo "--------------------------------------------"

echo " "

echo "Creating a http server on $SERVER_NAMESPACE"
echo "Creating http Server ..."

echo "To test http service from $CLIENT_one_NAMESPACE enter this cmd to the shell: "
echo "ip netns exec $CLIENT_one_NAMESPACE curl http://192.0.2.130:8888"

echo "To test http service from $CLIENT_two_NAMESPACE enter this cmd to the shell:" 
echo "ip netns exec $CLIENT_two_NAMESPACE curl http://192.0.2.130:8888"

echo "HTTP server is running. try to connect."

chmod 755 $(pwd)/http_server.sh
ip netns exec $SERVER_NAMESPACE $(pwd)/http_server.sh  

