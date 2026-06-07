# linuxshell 防火墙默认配置;所有值可经环境变量覆盖。

# 配置文件与安装路径
FW_RULES_FILE="${FW_RULES_FILE:-/etc/linuxshell-fw/rules.conf}"
FW_RULES_DIR="${FW_RULES_DIR:-/etc/linuxshell-fw}"
FW_LIB_DIR="${FW_LIB_DIR:-/usr/local/lib/linuxshell-fw}"
FW_BIN="${FW_BIN:-/usr/local/bin/fw}"
FW_SERVICE_FILE="${FW_SERVICE_FILE:-/etc/systemd/system/linuxshell-fw.service}"

# SSH 兜底端口(探测不到时用)
FW_SSH_PORT="${FW_SSH_PORT:-22}"

# IPv6:auto 由预检根据内核探测设定 FW_HAVE_IPV6
FW_IPV6="${FW_IPV6:-auto}"

# k3s 端口组与网络(k3s+flannel 默认值)
FW_K3S_TCP_PORTS="${FW_K3S_TCP_PORTS:-6443,10250,2379,2380}"
FW_K3S_UDP_PORTS="${FW_K3S_UDP_PORTS:-8472}"
FW_K3S_POD_CIDR="${FW_K3S_POD_CIDR:-10.42.0.0/16}"
FW_K3S_CNI_IFACES="${FW_K3S_CNI_IFACES:-cni0 flannel.1}"

# 自建链名
FW_INPUT_CHAIN="${FW_INPUT_CHAIN:-FW-INPUT}"
FW_DOCKER_CHAIN="${FW_DOCKER_CHAIN:-FW-DOCKER}"
