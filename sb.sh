cat << 'EOF' > sb-alpine.sh && chmod +x sb-alpine.sh && sh sb-alpine.sh
#!/bin/sh
set -e

# 彻底清除输入、IP、端口变量中的空格、回车(\r)与换行(\n)
clean_str() {
  printf "%s" "$1" | tr -d ' \t\r\n'
}

echo "=================================================="
echo "  Alpine sing-box (musl) 四协议自由组合 + BBR 部署"
echo "=================================================="

if [ -z "$PROTO_CHOICE" ]; then
  echo "请选择要部署的协议（支持多选，如输入 12 或 34 或 1234）："
  echo "  1) VLESS-TCP-REALITY-Vision (TCP)"
  echo "  2) Hysteria 2               (UDP)"
  echo "  3) TUIC v5                  (UDP)"
  echo "  4) AnyTLS                   (TCP)"
  printf "请输入协议序号组合 [默认 1234 全选]: "
  read -r PROTO_CHOICE </dev/tty || true
  PROTO_CHOICE=$(clean_str "${PROTO_CHOICE:-1234}")
fi

EN_REALITY=0; EN_HY2=0; EN_TUIC=0; EN_ANYTLS=0
case "$PROTO_CHOICE" in *1*) EN_REALITY=1 ;; esac
case "$PROTO_CHOICE" in *2*) EN_HY2=1 ;; esac
case "$PROTO_CHOICE" in *3*) EN_TUIC=1 ;; esac
case "$PROTO_CHOICE" in *4*) EN_ANYTLS=1 ;; esac

if [ "$EN_REALITY" -eq 0 ] && [ "$EN_HY2" -eq 0 ] && [ "$EN_TUIC" -eq 0 ] && [ "$EN_ANYTLS" -eq 0 ]; then
  echo "未识别到有效序号，默认启用 1) REALITY + 2) Hysteria 2"
  EN_REALITY=1; EN_HY2=1
fi

# 端口与参数交互（支持 TCP 与 UDP 复用同一个 NAT 端口）
if [ "$EN_REALITY" -eq 1 ]; then
  if [ -z "$REALITY_PORT" ]; then
    R_PORT=$(awk 'BEGIN{srand(); print int(rand()*40000)+10000}')
    printf "请输入 VLESS-REALITY (TCP) 端口 [默认 %s]: " "$R_PORT"
    read -r REALITY_PORT </dev/tty || true
    REALITY_PORT=$(clean_str "${REALITY_PORT:-$R_PORT}")
  fi
  if [ -z "$SNI" ]; then
    printf "请输入 REALITY 伪装域名 SNI [默认 www.yahoo.com]: "
    read -r SNI </dev/tty || true
    SNI=$(clean_str "${SNI:-www.yahoo.com}")
  fi
fi

if [ "$EN_HY2" -eq 1 ]; then
  if [ -z "$HY2_PORT" ]; then
    H_PORT=${REALITY_PORT:-$(awk 'BEGIN{srand(); print int(rand()*40000)+10001}')}
    printf "请输入 Hysteria 2 (UDP) 端口 [默认 %s，可与 TCP 共用端口]: " "$H_PORT"
    read -r HY2_PORT </dev/tty || true
    HY2_PORT=$(clean_str "${HY2_PORT:-$H_PORT}")
  fi
fi

if [ "$EN_TUIC" -eq 1 ]; then
  if [ -z "$TUIC_PORT" ]; then
    T_PORT=$(awk 'BEGIN{srand(); print int(rand()*40000)+10002}')
    [ "$T_PORT" = "$HY2_PORT" ] && T_PORT=$((T_PORT + 1))
    printf "请输入 TUIC v5 (UDP) 端口 [默认 %s，不可与 Hy2 同端口]: " "$T_PORT"
    read -r TUIC_PORT </dev/tty || true
    TUIC_PORT=$(clean_str "${TUIC_PORT:-$T_PORT}")
  fi
fi

if [ "$EN_ANYTLS" -eq 1 ]; then
  if [ -z "$ANYTLS_PORT" ]; then
    A_PORT=$(awk 'BEGIN{srand(); print int(rand()*40000)+10003}')
    [ "$A_PORT" = "$REALITY_PORT" ] && A_PORT=$((A_PORT + 1))
    printf "请输入 AnyTLS (TCP) 端口 [默认 %s，不可与 REALITY 同端口]: " "$A_PORT"
    read -r ANYTLS_PORT </dev/tty || true
    ANYTLS_PORT=$(clean_str "${ANYTLS_PORT:-$A_PORT}")
  fi
fi

echo ""
echo "===== 1. 开启 BBR + FQ 与 UDP 缓冲区优化 ====="
modprobe tcp_bbr 2>/dev/null || true
modprobe sch_fq 2>/dev/null || true

if ! grep -q "tcp_bbr" /etc/modules 2>/dev/null; then
  echo "tcp_bbr" >> /etc/modules 2>/dev/null || true
  echo "sch_fq" >> /etc/modules 2>/dev/null || true
fi

mkdir -p /etc/sysctl.d
cat << 'SYSCTL' > /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
SYSCTL

sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
CUR_QD=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
echo "[OK] 当前拥塞控制算法: ${CUR_CC} | 队列算法: ${CUR_QD}"

echo "===== 2. 安装基础依赖与二维码工具 (Alpine apk) ====="
apk update && apk add --no-cache curl tar openssl ca-certificates
apk add --no-cache libqrencode-tools 2>/dev/null || apk add --no-cache qrencode 2>/dev/null || true

echo "===== 3. 下载 sing-box (musl 原生版) ====="
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) SB_ARCH="amd64" ;;
  aarch64) SB_ARCH="arm64" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

SB_VER=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/' | tr -d ' \r\n')
[ -z "$SB_VER" ] && SB_VER="1.14.4"

if [ ! -f /usr/local/bin/sing-box ]; then
  curl -fsSL -o /root/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}-musl.tar.gz"
  tar -xzf /root/sb.tar.gz -C /root
  mv /root/sing-box-${SB_VER}-linux-${SB_ARCH}-musl/sing-box /usr/local/bin/sing-box
  chmod +x /usr/local/bin/sing-box
  rm -rf /root/sb.tar.gz /root/sing-box-${SB_VER}-linux-${SB_ARCH}-musl
fi

echo "===== 4. 免 Python 生成密钥、证书与配置文件 ====="
mkdir -p /etc/sing-box

UUID=$(clean_str "$(cat /proc/sys/kernel/random/uuid)")
COMMON_PASS=$(clean_str "$(head -c 512 /dev/urandom | tr -dc 'a-zA-Z0-9' | cut -c 1-16)")
CERT_SNI="www.bing.com"

if [ "$EN_HY2" -eq 1 ] || [ "$EN_TUIC" -eq 1 ] || [ "$EN_ANYTLS" -eq 1 ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/sing-box/private.key
  openssl req -new -x509 -key /etc/sing-box/private.key -out /etc/sing-box/cert.pem -days 3650 -subj "/CN=${CERT_SNI}" >/dev/null 2>&1
  CERT_FP=$(clean_str "$(openssl x509 -noout -fingerprint -sha256 -in /etc/sing-box/cert.pem | cut -d= -f2)")
fi

INBOUNDS=""
append_inbound() {
  if [ -n "$INBOUNDS" ]; then
    INBOUNDS="${INBOUNDS},
$1"
  else
    INBOUNDS="$1"
  fi
}

if [ "$EN_REALITY" -eq 1 ]; then
  KEYPAIR=$(/usr/local/bin/sing-box generate reality-keypair)
  PRIVATE_KEY=$(clean_str "$(echo "$KEYPAIR" | awk '/PrivateKey/ {print $2}')")
  PUBLIC_KEY=$(clean_str "$(echo "$KEYPAIR" | awk '/PublicKey/ {print $2}')")
  SHORT_ID=$(clean_str "$(head -c 512 /dev/urandom | tr -dc 'a-f0-9' | cut -c 1-8)")

  IB_REALITY=$(cat << EOF_R
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
EOF_R
)
  append_inbound "$IB_REALITY"
fi

if [ "$EN_HY2" -eq 1 ]; then
  IB_HY2=$(cat << EOF_H
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${COMMON_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    }
EOF_H
)
  append_inbound "$IB_HY2"
fi

if [ "$EN_TUIC" -eq 1 ]; then
  IB_TUIC=$(cat << EOF_T
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "${COMMON_PASS}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    }
EOF_T
)
  append_inbound "$IB_TUIC"
fi

if [ "$EN_ANYTLS" -eq 1 ]; then
  IB_ANYTLS=$(cat << EOF_A
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [
        {
          "name": "default",
          "password": "${COMMON_PASS}"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    }
EOF_A
)
  append_inbound "$IB_ANYTLS"
fi

cat << CONF > /etc/sing-box/config.json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
${INBOUNDS}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
CONF

echo "===== 5. 配置 Alpine OpenRC 系统服务 (含小内存限制) ====="
cat << 'INIT' > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
export GOMEMLIMIT=28MiB
export GOGC=30

depend() {
    need net
    after firewall
}
INIT

chmod +x /etc/init.d/sing-box
rc-update add sysctl default >/dev/null 2>&1 || true
rc-update add sing-box default >/dev/null 2>&1 || true
rc-service sing-box restart

echo "===== 6. 创建 sb 快捷管理面板 ====="
cat << 'SB_EOF' > /usr/local/bin/sb
#!/bin/sh
CONFIG_FILE="/etc/sing-box/config.json"
NODES_FILE="/root/nodes.txt"

# 从 config.json 获取指定 tag 的当前端口
get_port() {
    awk -v tag="\"$1\"" '
        $0 ~ tag { found=1 }
        found && /"listen_port":/ {
            gsub(/[^0-9]/, "", $0)
            print $0
            exit
        }
    ' "$CONFIG_FILE"
}

# 修改指定协议的端口（同步更新 config.json 与 /root/nodes.txt）
update_proto_port() {
    TAG="$1"
    NODE_MARK="$2"
    NEW_P="$3"

    # 1. 精准更新 config.json 中对应 tag 下的 listen_port
    awk -v tag="\"$TAG\"" -v port="$NEW_P" '
        $0 ~ tag { found=1 }
        found && /"listen_port":/ {
            sub(/:[[:space:]]*[0-9]+/, ": " port)
            found=0
        }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 2. 精准更新 /root/nodes.txt 中对应协议的端口
    if [ -f "$NODES_FILE" ]; then
        sed -i "/#${NODE_MARK}$/s/@\([^:]*\):[0-9]*?/@\1:${NEW_P}?/" "$NODES_FILE"
    fi
}

show_menu() {
    clear
    echo "=================================================="
    echo "       sing-box (Alpine) 快捷管理面板             "
    echo "=================================================="
    
    if rc-service sing-box status 2>/dev/null | grep -q "started"; then
        STATUS="\033[32m运行中 (Started)\033[0m"
    else
        STATUS="\033[31m已停止 (Stopped)\033[0m"
    fi
    
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    CUR_QD=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    
    printf " 服务状态 : %b\n" "$STATUS"
    echo " BBR 加速 : 拥塞控制 [$CUR_CC] | 队列算法 [$CUR_QD]"
    echo "--------------------------------------------------"
    echo " 1. 查看 Base64 订阅与二维码"
    echo " 2. 按协议修改监听端口 (自动同步订阅与二维码)"
    echo " 3. 查看 sing-box 运行日志"
    echo " 4. 重启 sing-box 服务"
    echo " 5. 停止 sing-box 服务"
    echo " 6. 启动 sing-box 服务"
    echo " 7. 检查 BBR 状态与网络优化"
    echo " 0. 退出"
    echo "=================================================="
    printf "请输入选项 [0-7]: "
    read -r choice
    case "$choice" in
        1) show_nodes ;;
        2) change_port ;;
        3) rc-service sing-box status; tail -n 50 /var/log/messages 2>/dev/null || true; printf "按回车键继续..."; read -r _ ; show_menu ;;
        4) rc-service sing-box restart; echo "服务已重启"; sleep 1; show_menu ;;
        5) rc-service sing-box stop; echo "服务已停止"; sleep 1; show_menu ;;
        6) rc-service sing-box start; echo "服务已启动"; sleep 1; show_menu ;;
        7) check_bbr; printf "按回车键继续..."; read -r _ ; show_menu ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1; show_menu ;;
    esac
}

show_nodes() {
    clear
    echo "========== Base64 订阅与二维码 =========="
    if [ -f "$NODES_FILE" ]; then
        B64_STR=$(base64 < "$NODES_FILE" | tr -d '\r\n')
        echo ""
        echo " [Base64 订阅串]"
        echo "$B64_STR"
        echo ""
        if command -v qrencode >/dev/null 2>&1; then
            echo " [Base64 订阅二维码 (支持客户端直接扫码导入)]"
            qrencode -t ansiutf8 -m 1 -l L "$B64_STR"
        else
            echo " [提示] 未检测到 qrencode，可执行 apk add libqrencode-tools 安装"
        fi
    else
        echo "未找到节点文件 /root/nodes.txt"
    fi
    echo "========================================="
    printf "按回车键返回主菜单..."
    read -r _
    show_menu
}

change_port() {
    clear
    echo "========== 按协议修改监听端口 =========="
    P_REALITY=$(get_port "vless-reality-in")
    P_HY2=$(get_port "hy2-in")
    P_TUIC=$(get_port "tuic-in")
    P_ANYTLS=$(get_port "anytls-in")

    echo "当前已部署协议及端口："
    [ -n "$P_REALITY" ] && echo "  1) VLESS-REALITY (TCP) : 当前端口 [$P_REALITY]"
    [ -n "$P_HY2" ]     && echo "  2) Hysteria 2    (UDP) : 当前端口 [$P_HY2]"
    [ -n "$P_TUIC" ]    && echo "  3) TUIC v5       (UDP) : 当前端口 [$P_TUIC]"
    [ -n "$P_ANYTLS" ]  && echo "  4) AnyTLS        (TCP) : 当前端口 [$P_ANYTLS]"
    echo "  0) 返回主菜单"
    echo "----------------------------------------"
    printf "请选择要修改的协议序号 [0-4]: "
    read -r p_choice

    TARGET_TAG=""
    TARGET_MARK=""
    TARGET_NAME=""

    case "$p_choice" in
        1) [ -n "$P_REALITY" ] && TARGET_TAG="vless-reality-in" && TARGET_MARK="Alpine-REALITY" && TARGET_NAME="VLESS-REALITY" ;;
        2) [ -n "$P_HY2" ]     && TARGET_TAG="hy2-in"           && TARGET_MARK="Alpine-Hy2"     && TARGET_NAME="Hysteria 2" ;;
        3) [ -n "$P_TUIC" ]    && TARGET_TAG="tuic-in"          && TARGET_MARK="Alpine-TUIC"    && TARGET_NAME="TUIC v5" ;;
        4) [ -n "$P_ANYTLS" ]  && TARGET_TAG="anytls-in"        && TARGET_MARK="Alpine-AnyTLS"  && TARGET_NAME="AnyTLS" ;;
        0|"") show_menu; return ;;
    esac

    if [ -z "$TARGET_TAG" ]; then
        echo "该协议未部署或输入序号无效！"
        sleep 1
        change_port
        return
    fi

    printf "请输入 %s 的新端口号 (1-65535，回车取消): " "$TARGET_NAME"
    read -r new_port
    new_port=$(printf "%s" "$new_port" | tr -d ' \t\r\n')

    case "$new_port" in
        ''|*[!0-9]*)
            echo "已取消或输入了非数字端口。"
            sleep 1
            show_menu
            return
            ;;
    esac

    if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo "端口超出范围 (1-65535)！"
        sleep 1
        change_port
        return
    fi

    update_proto_port "$TARGET_TAG" "$TARGET_MARK" "$new_port"
    rc-service sing-box restart
    echo ""
    echo "[OK] ${TARGET_NAME} 端口已成功更新为 ${new_port}，服务已重启！"
    echo "新的 Base64 订阅与二维码已同步更新。"
    sleep 2
    show_nodes
}

check_bbr() {
    clear
    echo "========== BBR 与内核加速状态 ======"
    echo "拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "队列排队算法: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "TCP 最大读缓存: $(sysctl -n net.core.rmem_max 2>/dev/null)"
    echo "TCP 最大写缓存: $(sysctl -n net.core.wmem_max 2>/dev/null)"
    echo "=================================="
}

show_menu
SB_EOF

chmod +x /usr/local/bin/sb

RAW_IP=$(curl -fsSL4 --max-time 5 ip.sb || curl -fsSL4 --max-time 5 ifconfig.me || echo "127.0.0.1")
SERVER_IP=$(clean_str "$RAW_IP")

# 生成节点文件供 Base64 编码使用
> /root/nodes.txt
[ "$EN_REALITY" -eq 1 ] && echo "vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Alpine-REALITY" >> /root/nodes.txt
[ "$EN_HY2" -eq 1 ]     && echo "hysteria2://${COMMON_PASS}@${SERVER_IP}:${HY2_PORT}?insecure=1&allow_insecure=1&sni=${CERT_SNI}&pinSHA256=${CERT_FP}#Alpine-Hy2" >> /root/nodes.txt
[ "$EN_TUIC" -eq 1 ]    && echo "tuic://${UUID}%3A${COMMON_PASS}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${CERT_SNI}&udp_relay_mode=native&insecure=1&allow_insecure=1#Alpine-TUIC" >> /root/nodes.txt
[ "$EN_ANYTLS" -eq 1 ]  && echo "anytls://${COMMON_PASS}@${SERVER_IP}:${ANYTLS_PORT}?sni=${CERT_SNI}&insecure=1&allow_insecure=1&fp=chrome#Alpine-AnyTLS" >> /root/nodes.txt

B64_SUB=$(base64 < /root/nodes.txt | tr -d '\r\n')

echo ""
echo "========== 部署完成 & 订阅信息 =========="
echo " [快捷管理] 终端输入 sb 即可打开管理面板"
echo " [BBR 状态] 拥塞控制: ${CUR_CC} | 队列算法: ${CUR_QD}"
echo ""
echo " [Base64 集合订阅串]"
echo "${B64_SUB}"
echo ""
if command -v qrencode >/dev/null 2>&1; then
  echo " [Base64 订阅二维码 (客户端直接扫码导入)]"
  qrencode -t ansiutf8 -m 1 -l L "${B64_SUB}"
  echo ""
fi
echo "========================================="
EOF