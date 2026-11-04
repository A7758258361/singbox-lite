#!/bin/sh
# ==============================================================================
# sing-box-lite 极简四协议部署与管理脚本 (Alpine / Debian / Ubuntu 全兼容版)
# 集成协议: VLESS-REALITY-Vision / Hysteria 2 / TUIC v5 / AnyTLS
# 特性: 1C64M 防 OOM + 核心智能复用 + 协议独立增删 + 端口修改 + 订阅生成
# ==============================================================================

export TMPDIR="/var/tmp"
mkdir -p /var/tmp /etc/sing-box

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
META_FILE="/etc/sing-box/meta.json"
NODES_FILE="/root/nodes.txt"
SB_BIN="/usr/local/bin/sing-box"
SB_CMD="/usr/local/bin/sb"

echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}     开始部署 sing-box 极简四协议 (兼容 Alpine/Debian)    ${NC}"
echo -e "${CYAN}========================================================${NC}"

# 1. 环境识别与基础依赖安装
if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    echo -e "${YELLOW}[1/6] 检测到 Alpine Linux，正在检查基础依赖...${NC}"
    apk update >/dev/null 2>&1 || true
    apk add --no-cache curl wget tar openssl ca-certificates jq iproute2 iptables >/dev/null 2>&1 || true
else
    OS_TYPE="debian"
    echo -e "${YELLOW}[1/6] 检测到 Debian/Ubuntu 系统，正在检查基础依赖...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl wget tar openssl ca-certificates jq iproute2 iptables >/dev/null 2>&1 || true
fi

# 2. 内核网络参数优化 (修复双栈监听仅 IPv6 问题 + 开启 BBR + QUIC 缓冲区)
echo -e "${YELLOW}[2/6] 正在优化内核双栈监听与 BBR/UDP 参数...${NC}"
sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
sysctl -w net.core.rmem_max=2500000 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=2500000 >/dev/null 2>&1 || true
sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-singbox.conf << 'EOF' 2>/dev/null || true
net.ipv6.bindv6only = 0
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null 2>&1 || true

# 3. 架构识别与获取 sing-box 核心 (支持直接复用已有核心 + 防 Text file busy)
echo -e "${YELLOW}[3/6] 正在检查/获取 sing-box 核心...${NC}"

# 先停止可能正在运行的旧进程，释放内存与二进制文件锁
rc-service sing-box stop >/dev/null 2>&1 || true
systemctl stop sing-box >/dev/null 2>&1 || true
pkill -9 -x sing-box >/dev/null 2>&1 || killall -9 sing-box >/dev/null 2>&1 || true

# 如果其他路径(如 /usr/bin/sing-box)已有核心但 /usr/local/bin 没有，自动复制过来
if [ ! -x "$SB_BIN" ] && command -v sing-box >/dev/null 2>&1; then
    EXIST_BIN=$(command -v sing-box)
    cp -f "$EXIST_BIN" "$SB_BIN" 2>/dev/null || true
    chmod +x "$SB_BIN" 2>/dev/null || true
fi

NEED_DOWNLOAD=1
if [ -x "$SB_BIN" ] && "$SB_BIN" version >/dev/null 2>&1; then
    CUR_VER=$("$SB_BIN" version 2>/dev/null | awk '/sing-box version/ {print $3}' | head -n 1)
    echo -e "${GREEN}检测到本机已安装 sing-box v${CUR_VER}，直接复用现有核心！${NC}"
    NEED_DOWNLOAD=0
fi

if [ "$NEED_DOWNLOAD" -eq 1 ]; then
    ARCH_RAW=$(uname -m)
    case "$ARCH_RAW" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv7*) ARCH="armv7" ;;
        *) echo -e "${RED}不支持的 CPU 架构: $ARCH_RAW${NC}"; exit 1 ;;
    esac

    SB_VER=$(curl -fsSLm 5 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    if ! echo "$SB_VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        SB_VER="1.14.4"
    fi

    echo -e "${CYAN}正在下载 sing-box v${SB_VER} (${ARCH})...${NC}"
    cd /var/tmp || exit 1
    rm -rf /var/tmp/sing-box*
    DL_OK=0

    if [ "$OS_TYPE" = "alpine" ]; then
        MUSL_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${ARCH}-musl.tar.gz"
        if curl -fsSLm 60 "$MUSL_URL" -o sing-box.tar.gz 2>/dev/null || wget -q -T 60 "$MUSL_URL" -O sing-box.tar.gz 2>/dev/null; then
            [ -s sing-box.tar.gz ] && DL_OK=1
        fi
    fi

    if [ "$DL_OK" -eq 0 ]; then
        STD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${ARCH}.tar.gz"
        if curl -fsSLm 60 "$STD_URL" -o sing-box.tar.gz 2>/dev/null || wget -q -T 60 "$STD_URL" -O sing-box.tar.gz 2>/dev/null; then
            [ -s sing-box.tar.gz ] && DL_OK=1
        fi
    fi

    if [ "$DL_OK" -eq 0 ] || ! tar -xzf sing-box.tar.gz 2>/dev/null; then
        echo -e "${RED}[错误] 下载或解压 sing-box 失败，请检查机器连接 GitHub 的网络！${NC}"
        rm -rf /var/tmp/sing-box*
        exit 1
    fi

    EXTRACTED_BIN=$(find /var/tmp -maxdepth 2 -type f -name "sing-box" | head -n 1)
    if [ -z "$EXTRACTED_BIN" ]; then
        echo -e "${RED}[错误] 解压后未找到 sing-box 二进制文件！${NC}"
        exit 1
    fi

    # 关键修复: 先 rm -f 解锁旧 inode，再移动新二进制，彻底杜绝 Text file busy
    rm -f "$SB_BIN"
    mv -f "$EXTRACTED_BIN" "$SB_BIN"
    chmod +x "$SB_BIN"
    rm -rf /var/tmp/sing-box*
    echo -e "${GREEN}已成功安装 sing-box v${SB_VER}${NC}"
fi

# 4. 生成密钥、证书与端口元数据
echo -e "${YELLOW}[4/6] 正在生成密钥、自签证书与初始配置...${NC}"
UUID=$("$SB_BIN" generate uuid 2>/dev/null)
[ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)

PASS=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
SHORT_ID=$(openssl rand -hex 4 2>/dev/null || head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
REALITY_SNI="${REALITY_SNI:-www.apple.com}"
TLS_SNI="${TLS_SNI:-www.bing.com}"

KEYPAIR=$("$SB_BIN" generate reality-keypair 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/ {print $2}' | tr -d '\r\n ')
PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/PublicKey/ {print $2}' | tr -d '\r\n ')

# 关键修复: 加上 -noout 生成纯净私钥，防止附带 EC PARAMETERS 导致 TLS 握手异常
openssl ecparam -name prime256v1 -genkey -noout -out /etc/sing-box/private.key 2>/dev/null
openssl req -new -x509 -days 3650 -key /etc/sing-box/private.key -out /etc/sing-box/cert.pem \
    -subj "/CN=${TLS_SNI}" -addext "subjectAltName=DNS:${TLS_SNI}" 2>/dev/null || \
openssl req -new -x509 -days 3650 -key /etc/sing-box/private.key -out /etc/sing-box/cert.pem \
    -subj "/CN=${TLS_SNI}" 2>/dev/null

gen_port() {
    shuf -i 20000-55000 -n 1 2>/dev/null || awk 'BEGIN{srand(); print int(20000+rand()*35000)}'
}
PORT_REALITY="${PORT_REALITY:-$(gen_port)}"
PORT_HY2="${PORT_HY2:-$((PORT_REALITY + 1))}"
PORT_TUIC="${PORT_TUIC:-$((PORT_REALITY + 2))}"
PORT_ANYTLS="${PORT_ANYTLS:-$((PORT_REALITY + 3))}"

if [ -f /proc/net/if_inet6 ] && [ -s /proc/net/if_inet6 ]; then
    LISTEN_ADDR="::"
else
    LISTEN_ADDR="0.0.0.0"
fi

jq -n \
    --arg uuid "$UUID" \
    --arg pass "$PASS" \
    --arg sni "$REALITY_SNI" \
    --arg tls_sni "$TLS_SNI" \
    --arg priv "$PRIVATE_KEY" \
    --arg pub "$PUBLIC_KEY" \
    --arg sid "$SHORT_ID" \
    --arg listen "$LISTEN_ADDR" \
    --argjson pr "$PORT_REALITY" \
    --argjson ph "$PORT_HY2" \
    --argjson pt "$PORT_TUIC" \
    --argjson pa "$PORT_ANYTLS" \
    '{
        uuid: $uuid,
        password: $pass,
        reality_sni: $sni,
        tls_sni: $tls_sni,
        private_key: $priv,
        public_key: $pub,
        short_id: $sid,
        listen: $listen,
        ports: {
            "vless-in": $pr,
            "hy2-in": $ph,
            "tuic-in": $pt,
            "anytls-in": $pa
        }
    }' > "$META_FILE"

cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${PORT_REALITY},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${PORT_HY2},
      "users": [
        {
          "password": "${PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${TLS_SNI}",
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${PORT_TUIC},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "${PASS}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "${TLS_SNI}",
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${PORT_ANYTLS},
      "users": [
        {
          "name": "default",
          "password": "${PASS}"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "${TLS_SNI}",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      }
    ],
    "final": "direct"
  }
}
EOF

# 兼容性自检: 若旧版核心不支持 route.rules.action，自动回退基础路由
if ! "$SB_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    jq 'del(.route.rules)' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi
# 若本机旧核心版本低于 1.12 不支持 anytls，自动剔除 anytls 确保剩余 3 协议正常启动
if ! "$SB_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    jq 'del(.inbounds[] | select(.tag == "anytls-in"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi

# 5. 配置系统守护服务 (OpenRC / systemd / nohup 三模自适应 + 28MiB 内存硬限)
echo -e "${YELLOW}[5/6] 正在配置后台守护服务 (GOMEMLIMIT=28MiB)...${NC}"
if [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1; then
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box service (64MB Low-RAM Optimized)"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 32768"
export GOMEMLIMIT="28MiB"
export GOGC="15"
export GOMAXPROCS="1"
start_pre() {
    export GOMEMLIMIT="28MiB"
    export GOGC="15"
    export GOMAXPROCS="1"
}
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1 || true
elif command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box service (64MB Low-RAM Optimized)
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Environment="GOMEMLIMIT=28MiB"
Environment="GOGC=15"
Environment="GOMAXPROCS=1"
Nice=10
LimitNOFILE=32768
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable sing-box >/dev/null 2>&1 || true
fi

# 6. 生成 /usr/local/bin/sb 快捷管理面板 (含删除/恢复单条协议功能)
echo -e "${YELLOW}[6/6] 正在安装 sb 快捷管理命令...${NC}"
rm -f "$SB_CMD"
cat > "$SB_CMD" << 'EOF'
#!/bin/sh
CONFIG_FILE="/etc/sing-box/config.json"
META_FILE="/etc/sing-box/meta.json"
NODES_FILE="/root/nodes.txt"
SB_BIN="/usr/local/bin/sing-box"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

restart_sb() {
    if ! "$SB_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}[错误] 配置文件校验未通过，具体原因如下：${NC}"
        "$SB_BIN" check -c "$CONFIG_FILE"
        return 1
    fi

    # 先彻底清理可能冲突的残留进程
    if [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box stop >/dev/null 2>&1 || true
        pkill -9 -x sing-box >/dev/null 2>&1 || true
        rc-service sing-box start >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl stop sing-box >/dev/null 2>&1 || true
        pkill -9 -x sing-box >/dev/null 2>&1 || true
        systemctl start sing-box >/dev/null 2>&1 || true
    else
        pkill -9 -x sing-box >/dev/null 2>&1 || true
    fi

    sleep 1
    # 如果 OpenRC/systemd 未能拉起(如特殊容器环境)，自动使用 nohup 后台兜底启动
    if ! pgrep -x "sing-box" >/dev/null 2>&1; then
        GOMEMLIMIT="28MiB" GOGC="15" GOMAXPROCS="1" nohup "$SB_BIN" run -c "$CONFIG_FILE" >/var/tmp/sing-box.log 2>&1 &
        sleep 1
    fi

    if pgrep -x "sing-box" >/dev/null 2>&1; then
        echo -e "${GREEN}[成功] sing-box 服务已启动并正常运行！${NC}"
    else
        echo -e "${RED}[失败] sing-box 未能启动，报错信息如下：${NC}"
        "$SB_BIN" run -c "$CONFIG_FILE"
    fi
}

open_port() {
    PORT=$1
    [ -z "$PORT" ] && return
    iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    ip6tables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    ip6tables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
}

get_server_ip() {
    IP4=$(curl -s4m4 https://api.ipify.org 2>/dev/null || curl -s4m4 https://ip.sb 2>/dev/null || curl -s4m4 https://ifconfig.me 2>/dev/null)
    IP4=$(echo "$IP4" | tr -d '\r\n ')
    if echo "$IP4" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "$IP4"
        return
    fi
    IP6=$(curl -s6m4 https://api64.ipify.org 2>/dev/null || curl -s6m4 https://ip.sb 2>/dev/null)
    IP6=$(echo "$IP6" | tr -d '\r\n ')
    if [ -n "$IP6" ]; then
        echo "[${IP6}]"
    else
        echo "YOUR_SERVER_IP"
    fi
}

refresh_nodes() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$META_FILE" ]; then
        echo -e "${RED}未找到配置文件！${NC}"
        return 1
    fi

    SERVER_IP=$(get_server_ip)
    RAW_IP=$(echo "$SERVER_IP" | tr -d '[]')
    HOST_TAG=$(hostname 2>/dev/null | tr -d '\r\n ')
    [ -z "$HOST_TAG" ] && HOST_TAG="Node"

    UUID=$(jq -r '.uuid' "$META_FILE")
    PASS=$(jq -r '.password' "$META_FILE")
    REALITY_SNI=$(jq -r '.reality_sni' "$META_FILE")
    TLS_SNI=$(jq -r '.tls_sni' "$META_FILE")
    PUBLIC_KEY=$(jq -r '.public_key' "$META_FILE")
    SHORT_ID=$(jq -r '.short_id' "$META_FILE")

    URI_LIST=""
    CLASH_LIST="proxies:"

    P_VLESS=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .listen_port // empty' "$CONFIG_FILE")
    if [ -n "$P_VLESS" ]; then
        open_port "$P_VLESS"
        VLESS_URI="vless://${UUID}@${SERVER_IP}:${P_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${HOST_TAG}-Reality"
        URI_LIST="${URI_LIST}${VLESS_URI}\n"
        CLASH_LIST="${CLASH_LIST}
  - name: ${HOST_TAG}-Reality
    type: vless
    server: ${RAW_IP}
    port: ${P_VLESS}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}"
    fi

    P_HY2=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .listen_port // empty' "$CONFIG_FILE")
    if [ -n "$P_HY2" ]; then
        open_port "$P_HY2"
        HY2_URI="hysteria2://${PASS}@${SERVER_IP}:${P_HY2}?insecure=1&sni=${TLS_SNI}#${HOST_TAG}-Hy2"
        URI_LIST="${URI_LIST}${HY2_URI}\n"
        CLASH_LIST="${CLASH_LIST}
  - name: ${HOST_TAG}-Hy2
    type: hysteria2
    server: ${RAW_IP}
    port: ${P_HY2}
    password: ${PASS}
    sni: ${TLS_SNI}
    skip-cert-verify: true"
    fi

    P_TUIC=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .listen_port // empty' "$CONFIG_FILE")
    if [ -n "$P_TUIC" ]; then
        open_port "$P_TUIC"
        TUIC_URI="tuic://${UUID}%3A${PASS}@${SERVER_IP}:${P_TUIC}?congestion_control=bbr&alpn=h3&sni=${TLS_SNI}&udp_relay_mode=native&allow_insecure=1&insecure=1#${HOST_TAG}-TUIC"
        URI_LIST="${URI_LIST}${TUIC_URI}\n"
        CLASH_LIST="${CLASH_LIST}
  - name: ${HOST_TAG}-TUIC
    type: tuic
    server: ${RAW_IP}
    port: ${P_TUIC}
    uuid: ${UUID}
    password: ${PASS}
    alpn: [h3]
    sni: ${TLS_SNI}
    congestion-controller: bbr
    udp-relay-mode: native
    skip-cert-verify: true"
    fi

    P_ANYTLS=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .listen_port // empty' "$CONFIG_FILE")
    if [ -n "$P_ANYTLS" ]; then
        open_port "$P_ANYTLS"
        ANYTLS_URI="anytls://${PASS}@${SERVER_IP}:${P_ANYTLS}?sni=${TLS_SNI}&insecure=1#${HOST_TAG}-AnyTLS"
        URI_LIST="${URI_LIST}${ANYTLS_URI}\n"
        CLASH_LIST="${CLASH_LIST}
  - name: ${HOST_TAG}-AnyTLS
    type: anytls
    server: ${RAW_IP}
    port: ${P_ANYTLS}
    password: ${PASS}
    sni: ${TLS_SNI}
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: true"
    fi

    PLAIN_LINKS=$(printf "%b" "$URI_LIST" | sed '/^$/d')
    B64_SUB=$(printf "%s\n" "$PLAIN_LINKS" | base64 | tr -d '\r\n ')

    cat > "$NODES_FILE" << EOC
========================================================
                当前已启用节点明文链接
========================================================
${PLAIN_LINKS}

========================================================
             Base64 聚合订阅串 (直接导入客户端)
========================================================
${B64_SUB}

========================================================
                Clash Meta (Mihomo) 配置
========================================================
${CLASH_LIST}
EOC

    cat "$NODES_FILE"
}

delete_protocol() {
    TARGET_TAG=$1
    if [ -z "$TARGET_TAG" ]; then
        echo -e "\n${CYAN}--- 当前已启用的协议列表 ---${NC}"
        jq -r '.inbounds[] | "  * \(.tag) (协议: \(.type), 端口: \(.listen_port))"' "$CONFIG_FILE"
        echo -e "${CYAN}----------------------------${NC}"
        echo "请选择要删除的协议:"
        echo "  1) 删除 VLESS-REALITY (vless-in)"
        echo "  2) 删除 Hysteria 2    (hy2-in)"
        echo "  3) 删除 TUIC v5       (tuic-in)"
        echo "  4) 删除 AnyTLS        (anytls-in)"
        echo "  0) 返回主菜单"
        printf "请输入数字 [0-4]: "
        read -r choice
        case "$choice" in
            1) TARGET_TAG="vless-in" ;;
            2) TARGET_TAG="hy2-in" ;;
            3) TARGET_TAG="tuic-in" ;;
            4) TARGET_TAG="anytls-in" ;;
            *) return ;;
        esac
    else
        case "$TARGET_TAG" in
            reality|vless|vless-in) TARGET_TAG="vless-in" ;;
            hy2|hysteria2|hy2-in) TARGET_TAG="hy2-in" ;;
            tuic|tuic-in) TARGET_TAG="tuic-in" ;;
            anytls|anytls-in) TARGET_TAG="anytls-in" ;;
            *) echo -e "${RED}未知协议名！支持参数: reality | hy2 | tuic | anytls${NC}"; return 1 ;;
        esac
    fi

    EXISTS=$(jq -r --arg tag "$TARGET_TAG" '.inbounds[] | select(.tag==$tag) | .tag' "$CONFIG_FILE")
    if [ -z "$EXISTS" ]; then
        echo -e "${YELLOW}[提示] 协议 ${TARGET_TAG} 当前不存在，无需删除。${NC}"
        return
    fi

    COUNT=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [ "$COUNT" -le 1 ]; then
        echo -e "${RED}[禁止] 当前仅剩最后 1 条协议，删除后 sing-box 将失去所有入站！${NC}"
        return 1
    fi

    jq --arg tag "$TARGET_TAG" 'del(.inbounds[] | select(.tag == $tag))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    echo -e "${GREEN}[成功] 已从配置中移除协议: ${TARGET_TAG}${NC}"
    restart_sb
    refresh_nodes
}

restore_protocol() {
    echo -e "\n${CYAN}请选择要恢复/重新添加的协议:${NC}"
    echo "  1) 恢复/添加 VLESS-REALITY"
    echo "  2) 恢复/添加 Hysteria 2"
    echo "  3) 恢复/添加 TUIC v5"
    echo "  4) 恢复/添加 AnyTLS"
    echo "  0) 返回主菜单"
    printf "请输入数字 [0-4]: "
    read -r choice

    case "$choice" in
        1) TAG="vless-in" ;;
        2) TAG="hy2-in" ;;
        3) TAG="tuic-in" ;;
        4) TAG="anytls-in" ;;
        *) return ;;
    esac

    EXISTS=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tag' "$CONFIG_FILE")
    if [ -n "$EXISTS" ]; then
        echo -e "${YELLOW}[提示] 该协议当前已处于启用状态！${NC}"
        return
    fi

    UUID=$(jq -r '.uuid' "$META_FILE")
    PASS=$(jq -r '.password' "$META_FILE")
    REALITY_SNI=$(jq -r '.reality_sni' "$META_FILE")
    TLS_SNI=$(jq -r '.tls_sni' "$META_FILE")
    PRIVATE_KEY=$(jq -r '.private_key' "$META_FILE")
    SHORT_ID=$(jq -r '.short_id' "$META_FILE")
    LISTEN_ADDR=$(jq -r '.listen // "::"' "$META_FILE")
    DEF_PORT=$(jq -r --arg tag "$TAG" '.ports[$tag] // 25000' "$META_FILE")

    printf "请输入该协议监听端口 [回车默认 %s]: " "$DEF_PORT"
    read -r NEW_PORT
    [ -z "$NEW_PORT" ] && NEW_PORT="$DEF_PORT"

    case "$TAG" in
        vless-in)
            INBOUND_JSON=$(jq -n --arg l "$LISTEN_ADDR" --argjson p "$NEW_PORT" --arg u "$UUID" --arg sni "$REALITY_SNI" --arg priv "$PRIVATE_KEY" --arg sid "$SHORT_ID" \
            '{type:"vless",tag:"vless-in",listen:$l,listen_port:$p,users:[{uuid:$u,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$priv,short_id:[$sid]}}}')
            ;;
        hy2-in)
            INBOUND_JSON=$(jq -n --arg l "$LISTEN_ADDR" --argjson p "$NEW_PORT" --arg pw "$PASS" --arg sni "$TLS_SNI" \
            '{type:"hysteria2",tag:"hy2-in",listen:$l,listen_port:$p,users:[{password:$pw}],tls:{enabled:true,server_name:$sni,alpn:["h3"],certificate_path:"/etc/sing-box/cert.pem",key_path:"/etc/sing-box/private.key"}}')
            ;;
        tuic-in)
            INBOUND_JSON=$(jq -n --arg l "$LISTEN_ADDR" --argjson p "$NEW_PORT" --arg u "$UUID" --arg pw "$PASS" --arg sni "$TLS_SNI" \
            '{type:"tuic",tag:"tuic-in",listen:$l,listen_port:$p,users:[{uuid:$u,password:$pw}],congestion_control:"bbr",tls:{enabled:true,server_name:$sni,alpn:["h3"],certificate_path:"/etc/sing-box/cert.pem",key_path:"/etc/sing-box/private.key"}}')
            ;;
        anytls-in)
            INBOUND_JSON=$(jq -n --arg l "$LISTEN_ADDR" --argjson p "$NEW_PORT" --arg pw "$PASS" --arg sni "$TLS_SNI" \
            '{type:"anytls",tag:"anytls-in",listen:$l,listen_port:$p,users:[{name:"default",password:$pw}],padding_scheme:[],tls:{enabled:true,server_name:$sni,certificate_path:"/etc/sing-box/cert.pem",key_path:"/etc/sing-box/private.key"}}')
            ;;
    esac

    jq --argjson ib "$INBOUND_JSON" '.inbounds += [$ib]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    echo -e "${GREEN}[成功] 已添加协议 ${TAG} (端口: ${NEW_PORT})${NC}"
    restart_sb
    refresh_nodes
}

change_port() {
    echo -e "\n${CYAN}--- 当前已启用的协议端口 ---${NC}"
    jq -r '.inbounds[] | "  * \(.tag) (当前端口: \(.listen_port))"' "$CONFIG_FILE"
    echo -e "${CYAN}----------------------------${NC}"
    echo "  1) 修改 VLESS-REALITY 端口"
    echo "  2) 修改 Hysteria 2    端口"
    echo "  3) 修改 TUIC v5       端口"
    echo "  4) 修改 AnyTLS        端口"
    echo "  0) 返回主菜单"
    printf "请选择 [0-4]: "
    read -r p_choice
    case "$p_choice" in
        1) TAG="vless-in" ;;
        2) TAG="hy2-in" ;;
        3) TAG="tuic-in" ;;
        4) TAG="anytls-in" ;;
        *) return ;;
    esac

    EXISTS=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tag' "$CONFIG_FILE")
    if [ -z "$EXISTS" ]; then
        echo -e "${RED}[错误] 协议 ${TAG} 已被删除，请先通过菜单 [4] 恢复该协议！${NC}"
        return
    fi

    printf "请输入新的端口号 (1-65535): "
    read -r NEW_PORT
    if ! echo "$NEW_PORT" | grep -Eq '^[0-9]+$' || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}端口号无效！${NC}"
        return
    fi

    jq --arg tag "$TAG" --argjson port "$NEW_PORT" \
        '(.inbounds[] | select(.tag == $tag) | .listen_port) = $port' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    jq --arg tag "$TAG" --argjson port "$NEW_PORT" \
        '.ports[$tag] = $port' "$META_FILE" > "${META_FILE}.tmp" \
        && mv "${META_FILE}.tmp" "$META_FILE"

    open_port "$NEW_PORT"
    restart_sb
    refresh_nodes
}

show_status() {
    echo -e "\n${CYAN}--- sing-box 运行状态与监听端口 ---${NC}"
    ps aux | grep "[s]ing-box" || echo -e "${RED}未检测到运行中的 sing-box 进程${NC}"
    echo ""
    ss -tulnp | grep "sing-box" 2>/dev/null || netstat -tulnp | grep "sing-box" 2>/dev/null || true
    echo -e "${CYAN}-----------------------------------${NC}"
}

case "$1" in
    list|nodes) refresh_nodes; exit 0 ;;
    del|delete) delete_protocol "$2"; exit 0 ;;
    add|restore) restore_protocol; exit 0 ;;
    restart) restart_sb; exit 0 ;;
    status) show_status; exit 0 ;;
esac

while true; do
    echo -e "\n${CYAN}================================================${NC}"
    echo -e "${CYAN}       sing-box 极简管理面板 (快捷命令: sb)      ${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 查看节点链接 / Base64订阅 / Clash配置"
    echo -e "  ${GREEN}2.${NC} 修改指定协议端口"
    echo -e "  ${YELLOW}3.${NC} 删除指定协议 (释放端口与内存)"
    echo -e "  ${YELLOW}4.${NC} 恢复/添加已删除的协议"
    echo -e "  ${GREEN}5.${NC} 查看进程与端口监听状态"
    echo -e "  ${GREEN}6.${NC} 重启 sing-box 服务"
    echo -e "  ${RED}7.${NC} 卸载 sing-box"
    echo -e "  ${GREEN}0.${NC} 退出面板"
    echo -e "${CYAN}================================================${NC}"
    printf "请输入选项 [0-7]: "
    read -r opt
    case "$opt" in
        1) refresh_nodes ;;
        2) change_port ;;
        3) delete_protocol ;;
        4) restore_protocol ;;
        5) show_status ;;
        6) restart_sb ;;
        7)
            printf "确认彻底卸载 sing-box 吗？[y/N]: "
            read -r confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                rc-service sing-box stop 2>/dev/null || true
                rc-update del sing-box default 2>/dev/null || true
                rm -f /etc/init.d/sing-box
                systemctl stop sing-box 2>/dev/null || true
                systemctl disable sing-box 2>/dev/null || true
                rm -f /etc/systemd/system/sing-box.service
                systemctl daemon-reload 2>/dev/null || true
                pkill -9 -x sing-box 2>/dev/null || true
                rm -rf /etc/sing-box "$SB_BIN" "$SB_CMD" "$NODES_FILE"
                echo -e "${GREEN}sing-box 已彻底卸载！${NC}"
                exit 0
            fi
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${NC}" ;;
    esac
done
EOF

chmod +x "$SB_CMD"

# 启动服务并输出所有节点信息
"$SB_CMD" restart
"$SB_CMD" list
