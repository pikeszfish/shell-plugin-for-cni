#!/bin/bash

#set -e
#set -x

VETH_PREFIX="testcni"

CNI_COMMAND=${CNI_COMMAND:-"VERSION"}
CNI_CONTAINERID=${CNI_CONTAINERID:-""}
CNI_NETNS=${CNI_NETNS:-""}
CNI_IFNAME=${CNI_IFNAME:-""}
CNI_ARGS=${CNI_ARGS:-""}
CNI_PATH=${CNI_PATH:-""}

Info `env`

INPUT=`cat -`
Info $INPUT

BRIDGE_NAME=`echo $INPUT | jq -r '.bridge'`
IS_GATEWAY=`echo $INPUT | jq -r '.isGateway'`
IS_DEFAULT_GATEWAY=`echo $INPUT | jq -r '.isDefaultGateway'`
FORCE_ADDRESS=`echo $INPUT | jq -r '.forceAddress'`
IP_MASQ=`echo $INPUT | jq -r '.ipMasq'`
HAIRPIN_MODE=`echo $INPUT | jq -r '.hairpinMode'`
PROMISC_MODE=`echo $INPUT | jq -r '.promiscMode'`
MTU=`echo $INPUT | jq -r '.mtu'`
IPAM_TYPE=`echo $INPUT | jq -r '.ipam.type'`

[ "${BRIDGE_NAME}" == "null" ] && BRIDGE_NAME="br0"
[ "${IS_GATEWAY}" == "null" ] && IS_GATEWAY="false"
[ "${IS_DEFAULT_GATEWAY}" == "null" ] && IS_DEFAULT_GATEWAY="false"
[ "${FORCE_ADDRESS}" == "null" ] && FORCE_ADDRESS="false"
[ "${IP_MASQ}" == "null" ] && IP_MASQ="false"
[ "${HAIRPIN_MODE}" == "null" ] && HAIRPIN_MODE="false"
[ "${PROMISC_MODE}" == "null" ] && PROMISC_MODE="false"
[ "${MTU}" == "null" ] && MTU="1500"

IPAM_RESULT=""

check_config() {
    if [ "${PROMISC_MODE}" == "true" ] && [ "${HAIRPIN_MODE}" == "true" ]; then
        Fatal "cannot set hairpin mode and promiscous mode at the same time."
    fi
}

# env: ${BRIDGE_NAME} ${MTU} ${PROMISC_MODE}
setup_bridge() {
    ip_link=`ip link show ${BRIDGE_NAME}`
    if [ $? -ne 0 ]; then 
        ip link add ${BRIDGE_NAME} mtu ${MTU} txqueuelen -1 type bridge 1>&2
    fi

    if [ "${PROMISC_MODE}" == "true" ]; then
        ip link set dev ${BRIDGE_NAME} promisc on 1>&2
    else
        ip link set dev ${BRIDGE_NAME} promisc off 1>&2
    fi
}

# env: ${CNI_NETNS} ${CNI_CONTAINERID}
setup_netns() {
    mkdir -p /var/run/netns/
    ln -sfT ${CNI_NETNS} /var/run/netns/${CNI_CONTAINERID}
}

# env: ${CNI_CONTAINERID
cleanup_netns() {
    rm -rf /var/run/netns/${CNI_CONTAINERID}
}

# env: ${CNI_CONTAINERID} ${CNI_IFNAME} ${BRIDGE_NAME} ${HAIRPIN_MODE}
# arg: $host_veth_name
setup_veth() {
    host_veth_name=${1}

    # create veth in container netns
    ip netns exec ${CNI_CONTAINERID} \
        ip link add \
            dev ${host_veth_name} up \
            mtu ${MTU} \
            type veth \
            peer name ${CNI_IFNAME} 1>&2

    # move host veth to host netns
    ip netns exec ${CNI_CONTAINERID} \
        ip link set dev ${host_veth_name} netns 1 1>&2

    # set host veth up
    ip link set ${host_veth_name} up 1>&2

    # connect host veth to bridge
    ip link set ${host_veth_name} master ${BRIDGE_NAME} 1>&2

    # config hairmode
    if [ "${HAIRPIN_MODE}" == "true" ]; then
        brctl hairpin ${BRIDGE_NAME} ${host_veth_name} on 1>&2
    fi
}

exec_ipam() {
    for p in `echo ${CNI_PATH} | sed "s/:/ /g"`; do
        if [ -f "${p}/${IPAM_TYPE}" ]; then
            IPAM_RESULT=`echo -e ${INPUT} | ${p}/${IPAM_TYPE}`
            return
        fi
    done
}

check_ipam_result() {
    echo "TODO" 1>&2
}

# env: ${CNI_CONTAINERID} ${CNI_IFNAME} ${IPAM_RESULT}
config_container_veth() {
    # set up
    ip netns exec ${CNI_CONTAINERID} \
        ip link set ${CNI_IFNAME} up

    # ip: {"version":"4","address":"192.168.88.59/16","gateway":"192.168.1.1"}
    for ip in `echo -e ${IPAM_RESULT} | jq -r --indent 0 '.ips[]'`; do
        version=`echo ${ip} | jq -r '.version'`
        if [ "${version}" != "4" ]; then
            continue
        fi

        address=`echo ${ip} | jq -r '.address'`
        gateway=`echo ${ip} | jq -r '.gateway'`

        # add ip address
        ip netns exec ${CNI_CONTAINERID} \
            ip addr add ${address} dev ${CNI_IFNAME} 1>&2
    done

    # route: {"gw":"192.168.1.1","dst":"0.0.0.0/0"}
    for route in `echo -e ${IPAM_RESULT} | jq -r --indent 0 '.routes[]'`; do
        gw=`echo ${route} | jq -r '.gw'`
        dst=`echo ${route} | jq -r '.dst'`

        # add route
        ip netns exec ${CNI_CONTAINERID} \
            ip route add ${dst} via ${gw} 1>&2
    done

    # arp
    for ip in `echo -e ${IPAM_RESULT} | jq -r --indent 0 '.ips[]'`; do
        version=`echo ${ip} | jq -r '.version'`
        if [ "${version}" != "4" ]; then
            continue
        fi

        address=`echo ${ip} | jq -r '.address'`

        # sends an gratuitous arp. ${address%/*} for 192.168.1.100/16 -> 192.168.1.100
        ip netns exec ${CNI_CONTAINERID} \
            arping -c 4 -A -I ${CNI_IFNAME} ${address%/*} 1>&2
    done
}

# TODO
config_gateway() {
    echo "TODO" 1>&2
}

# TODO
config_ip_masq() {
    echo "TODO" 1>&2
}

cleanup_ip_masq() {
    echo "TODO" 1>&2
}

command_add() {
    if [ "${IS_DEFAULT_GATEWAY}" == "true" ]; then
        IS_GATEWAY="true"
    fi

    check_config

    setup_bridge
    setup_netns

    host_veth_name="${VETH_PREFIX}`cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8`"

    setup_veth ${host_veth_name}

    exec_ipam

    # TODO
    # check_ipam_result
    config_container_veth

    # TODO
    if [ "${IS_GATEWAY}" == "true" ]; then
        config_gateway
    fi

    # TODO
    if [ "${IP_MASQ}" == "true" ]; then
        config_ip_masq
    fi

    echo -e ${IPAM_RESULT} >&2
    echo -e ${IPAM_RESULT}
}

command_del() {
    # 1. get all ips
    # TODO

    # 2. delete veth in the container
    # TODO

    exec_ipam

    if [ "${IP_MASQ}" == "true" ]; then
        cleanup_ip_masq
    fi

    echo -e ${IPAM_RESULT} >&2
    echo -e ${IPAM_RESULT}
}

command_version() {
    echo "0.0.1"
}


if [ "${CNI_COMMAND}" == "ADD" ]; then
    command_add
elif [ "${CNI_COMMAND}" == "DEL" ]; then
    command_del
else
    command_version
fi
