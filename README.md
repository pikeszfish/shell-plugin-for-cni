# shell 实现的 k8s CNI

## Why?
* 好玩!
* k8s CNI 的设计非常地通用和简单
* 不用编译, 随时 debug!

## How?
使用 Linux 下的命令行工具, 来实现官方实现下的 bridge 插件的(大部分)功能.

## requirements
### common
* bash - 执行
* ip - 大部分对网络的操作都使用了该命令
* jq - 命令行解析 json, 似乎没什么选择...
* ln - 软链接 netns 文件
* arping - 给容器 IP 发送免费的 arp

### Bridge
* brctl - 仅仅用到了 `brctl hairpin <bridge> <port> {on|off}`. `yum(apt) install bridge-utils`.

## TODO list
[x] bridge(70%)
[ ] macvlan
[ ] ipvlan
[ ] ptp
