# Bridge
## Why?
* 好玩
* k8s bridge CNI 的设计非常地通用和简单
* 不用编译, 随时 debug!

## How?
使用 Linux 下的命令行工具, 来实现官方实现下的 bridge 插件的(大部分)功能.

* bash - 执行
* ln - 软链接 netns 文件
* ip - 大部分对网络的操作都使用了该命令
* brctl - 仅仅用到了 `brctl hairpin <bridge> <port> {on|off}`, 可以替换部分 ip. 但我更喜欢 ip 命令
* arping - 给容器 IP 发送免费的 arp
* jq - Linux 下解析 json, 似乎没什么选择...

## requirements
* 有 ip 命令的发行版
* bridge-utils
* jq

## Start
脚本实现和 golang 实现差不多, 主要分为 `command_add` / `command_del` / `command_version`. 下面主要仅仅介绍 `command_add` 的实现过程.

### Env and stdin
```bash
# CNI.spec 规定的环境变量
CNI_COMMAND=${CNI_COMMAND:-"VERSION"}
CNI_CONTAINERID=${CNI_CONTAINERID:-""}
CNI_NETNS=${CNI_NETNS:-""}
CNI_IFNAME=${CNI_IFNAME:-""}
CNI_ARGS=${CNI_ARGS:-""}
CNI_PATH=${CNI_PATH:-""}

# 从 stdin 获取配置. 参考
# https://github.com/containernetworking/plugins/blob/master/plugins/main/bridge/README.md
INPUT=`cat -`
BRIDGE_NAME=`echo $INPUT | jq -r '.bridge'`
IS_GATEWAY=`echo $INPUT | jq -r '.isGateway'`
IS_DEFAULT_GATEWAY=`echo $INPUT | jq -r '.isDefaultGateway'`
FORCE_ADDRESS=`echo $INPUT | jq -r '.forceAddress'`
IP_MASQ=`echo $INPUT | jq -r '.ipMasq'`
HAIRPIN_MODE=`echo $INPUT | jq -r '.hairpinMode'`
PROMISC_MODE=`echo $INPUT | jq -r '.promiscMode'`
MTU=`echo $INPUT | jq -r '.mtu'`
IPAM_TYPE=`echo $INPUT | jq -r '.ipam.type'`
```

### check_config/检查 stdin 的配置
```bash
# 主要是 混杂模式和发卡弯模式不能同时开启
check_config() {
    if [ "${PROMISC_MODE}" == "true" ] && [ "${HAIRPIN_MODE}" == "true" ]; then
        Fatal "cannot set hairpin mode and promiscous mode at the same time."
    fi
}
```

### setup_bridge/创建并设置网桥
```bash
# env: ${BRIDGE_NAME} ${MTU} ${PROMISC_MODE}
setup_bridge() {
    # test exist
    ip_link=`ip link show ${BRIDGE_NAME}`
    if [ $? -ne 0 ]; then 
        ip link add ${BRIDGE_NAME} mtu ${MTU} txqueuelen -1 type bridge
    fi

    # 根据配置是否打开混杂模式
    if [ "${PROMISC_MODE}" == "true" ]; then
        ip link set dev ${BRIDGE_NAME} promisc on
    else
        ip link set dev ${BRIDGE_NAME} promisc off
    fi
}
```

### setup_netns/设置netns
```bash
# 主要是因为 ip 读取的 netns 是位于 /var/run/netns 下.
# 这里创建了以 ${CNI_CONTAINERID} 为名的 netns
setup_netns() {
    mkdir -p /var/run/netns/
    ln -sfT ${CNI_NETNS} /var/run/netns/${CNI_CONTAINERID}
}

cleanup_netns() {
    rm -rf /var/run/netns/${CNI_CONTAINERID}
}
```

### generate_veth_peer_name/随机 veth name
```bash
generate_veth_peer_name() {
    echo "${VETH_PREFIX}`cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8`"
}
```

### setup_veth/创建并设置 veth peer
```bash
# env: ${CNI_IFNAME}
# arg: $host_veth_name
setup_veth() {
    host_veth_name=${1}

    # 在 ${CNI_CONTAINERID} 的 netns 下创建 veth. 因为容器内的 veth name 都是 eth0, 所以不能都在 host netns 下创建.
    ip netns exec ${CNI_CONTAINERID} \
        ip link add \
            dev ${host_veth_name} up \
            mtu ${MTU} \
            type veth \
            peer name ${CNI_IFNAME}

    # 将 ${host_veth_name} 移到 host 一侧的 netns
    ip netns exec ${CNI_CONTAINERID} \
        ip link set dev ${host_veth_name} netns 1

    # 启动 host 侧的 veth
    ip link set ${host_veth_name} up

    # 将 host 侧的 veth 连接到 br0 网桥
    ip link set ${host_veth_name} master ${BRIDGE_NAME}

    # 选择是否配置发卡弯模式
    if [ "${HAIRPIN_MODE}" == "true" ]; then
        brctl hairpin ${BRIDGE_NAME} ${host_veth_name} on
    fi
}
```

### exec_ipam/执行 ipam 的二进制文件, 获取 IP
```bash
exec_ipam() {
    for p in `echo ${CNI_PATH} | sed "s/:/ /g"`; do
        if [ -f "${p}/${IPAM_TYPE}" ]; then
            IPAM_RESULT=`echo -e ${INPUT} | ${p}/${IPAM_TYPE}`
            return
        fi
    done
}
```

### config_container_veth/根据 IPAM 的结果配置容器内的 veth
```bash
# env: ${CNI_IFNAME} ${IPAM_RESULT}
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
```

### config_gateway/配置到 br0 的默认路由
```bash
config_gateway() {
    echo "TODO"
}
```

### config_ip_masq/配置 iptables NAT 表
```bash
config_ip_masq() {
    echo "TODO"
}
```

### command_add/实现 CNI 规范中环境变量 CNI_COMMAND=ADD 时候的逻辑
```bash
command_add() {
    if [ "${IS_DEFAULT_GATEWAY}" == "true" ]; then
        IS_GATEWAY="true"
    fi

    # 检查配置, 主要是混杂模式和发卡弯模式不能同时开启
    check_config

    # 如果没有 br0, 则创建
    setup_bridge

    # 将类似 /proc/49875/ns/net 建立软链接
    setup_netns

    # 随机的 veth 名称
    host_veth_name="${VETH_PREFIX}`cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8`"

    # 在容器 netns 中创建 veth(因为容器一侧的永远叫 eth0, 不能在主机的 netns 中创建)
    setup_veth ${host_veth_name}

    # 根据 IPAM 获取 IP, 结果放在 IPAM_RESULT 中
    exec_ipam

    # TODO, 检查结果是否格式正确
    check_ipam_result

    # 给容器内的 eth0 配置 IP/route, 并发送免费 arp
    config_container_veth

    # TODO
    if [ "${IS_GATEWAY}" == "true" ]; then
        config_gateway
    fi

    # TODO IP MASQ
    if [ "${IP_MASQ}" == "true" ]; then
        config_ip_masq
    fi

    # 输到 stderr 的可以在 kubelet 日志中看到
    echo -e ${IPAM_RESULT} >&2

    # 输出结果到 stdin
    echo -e ${IPAM_RESULT}
}
```