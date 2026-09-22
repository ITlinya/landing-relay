#!/usr/bin/env bash
# landing-relay.sh — 落地服务器(出口)一键部署脚本
#
# 作用：在落地机上装 Xray，开一个 Shadowsocks-2022 入口，只允许你指定的
#       上游线路服务器 IP 连接；所有进来的流量从落地机本地网卡出公网。
#
# 拓扑：客户端 --VLESS-REALITY--> 线路机 --SS-2022--> 落地机 --> 互联网
#
# 适用：Debian 12 (bookworm) 为主，同时兼容 Debian 11+ / Ubuntu 20.04+。
# 幂等：可重复执行。重跑会重新生成配置和防火墙规则。
#
# 用法：
#   bash landing-relay.sh                                  # 交互式
#   bash landing-relay.sh --upstream=1.2.3.4                # 指定线路机IP
#   bash landing-relay.sh --upstream=1.2.3.4,5.6.7.8 --port=23456
#   bash landing-relay.sh --upstream=1.2.3.4 --password='已有的base64密钥'
#   bash landing-relay.sh --show                            # 只打印当前参数
#   bash landing-relay.sh --uninstall                       # 卸载

set -euo pipefail

# ---------------------------------------------------------------- 常量
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
readonly STATE_FILE="/usr/local/etc/xray/landing-relay.env"
readonly FW_SCRIPT="/usr/local/bin/landing-relay-fw.sh"
readonly FW_UNIT="/etc/systemd/system/landing-relay-fw.service"
readonly FW_CHAIN="LANDING_RELAY"
readonly SS_METHOD="2022-blake3-aes-128-gcm"   # PSK = base64(16 字节)
readonly SYSCTL_FILE="/etc/sysctl.d/99-landing-relay.conf"

# ---------------------------------------------------------------- 输出
if [[ -t 1 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
info()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()   { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 参数
UPSTREAM=""
SS_PORT=""
SS_PASSWORD=""
OUT_STRATEGY="UseIPv4"     # UseIPv4 | UseIP | UseIPv6
ACTION="install"
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --upstream=*)  UPSTREAM="${arg#*=}" ;;
        --port=*)      SS_PORT="${arg#*=}" ;;
        --password=*)  SS_PASSWORD="${arg#*=}" ;;
        --ipv6)        OUT_STRATEGY="UseIP" ;;
        --ipv6-only)   OUT_STRATEGY="UseIPv6" ;;
        --show)        ACTION="show" ;;
        --uninstall)   ACTION="uninstall" ;;
        -y|--yes)      ASSUME_YES=1 ;;
        -h|--help)
            sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "未知参数: $arg (用 --help 查看用法)" ;;
    esac
done

# ---------------------------------------------------------------- 前置检查
[[ $EUID -eq 0 ]] || die "请用 root 运行 (sudo -i 后再执行)。"

command -v systemctl >/dev/null 2>&1 || die "本脚本需要 systemd。Alpine 等系统请另行适配。"

OS_ID=""; OS_VER=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
fi
case "$OS_ID" in
    debian|ubuntu) : ;;
    *) warn "检测到 ${OS_ID:-未知} ${OS_VER}，脚本主要针对 Debian 12 测试，继续执行但可能需要手动调整。" ;;
esac

# ---------------------------------------------------------------- 工具函数
validate_ip() {
    # 支持 IPv4 / IPv4 CIDR / IPv6 / IPv6 CIDR
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] && return 0
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ || "$ip" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] && [[ "$ip" == *:* ]] && return 0
    return 1
}

is_ipv6() { [[ "$1" == *:* ]]; }

free_port() {
    local p
    for _ in $(seq 1 50); do
        p=$(( (RANDOM % 30000) + 20000 ))
        if ! ss -Hltn "sport = :$p" 2>/dev/null | grep -q .; then
            printf '%s' "$p"; return 0
        fi
    done
    printf '%s' 23456
}

public_ip() {
    local ip=""
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -fsS4 --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]') || true
        [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    done
    printf '%s' "YOUR_LANDING_IP"
}

# ---------------------------------------------------------------- show
if [[ "$ACTION" == "show" ]]; then
    [[ -r "$STATE_FILE" ]] || die "没有找到 $STATE_FILE，说明还没部署过。"
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    LANDING_IP=$(public_ip)
    printf '\n落地机 IP : %s\n端口      : %s\n加密      : %s\n密钥      : %s\n允许上游  : %s\n\n' \
        "$LANDING_IP" "${SS_PORT:-}" "$SS_METHOD" "${SS_PASSWORD:-}" "${UPSTREAM:-}"
    exit 0
fi

# ---------------------------------------------------------------- uninstall
if [[ "$ACTION" == "uninstall" ]]; then
    if [[ $ASSUME_YES -ne 1 ]]; then
        read -r -p "确认卸载 Xray、防火墙规则和相关配置？[y/N] " a
        [[ "$a" =~ ^[Yy]$ ]] || die "已取消。"
    fi
    systemctl disable --now landing-relay-fw.service >/dev/null 2>&1 || true
    [[ -x "$FW_SCRIPT" ]] && "$FW_SCRIPT" flush || true
    rm -f "$FW_UNIT" "$FW_SCRIPT" "$SYSCTL_FILE" "$STATE_FILE"
    systemctl daemon-reload || true
    if [[ -f /usr/local/bin/xray ]]; then
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge \
            || warn "Xray 官方卸载脚本执行失败，可手动删除 /usr/local/bin/xray 与 $XRAY_CONFIG_DIR"
    fi
    ok "已卸载。"
    exit 0
fi

# ---------------------------------------------------------------- 读取已有状态
if [[ -r "$STATE_FILE" ]]; then
    OLD_UPSTREAM=""; OLD_PORT=""; OLD_PASSWORD=""
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    OLD_UPSTREAM="${UPSTREAM_SAVED:-}"; OLD_PORT="${SS_PORT_SAVED:-}"; OLD_PASSWORD="${SS_PASSWORD_SAVED:-}"
    [[ -z "$UPSTREAM"    && -n "$OLD_UPSTREAM" ]] && UPSTREAM="$OLD_UPSTREAM"
    [[ -z "$SS_PORT"     && -n "$OLD_PORT"     ]] && SS_PORT="$OLD_PORT"
    [[ -z "$SS_PASSWORD" && -n "$OLD_PASSWORD" ]] && SS_PASSWORD="$OLD_PASSWORD"
    info "检测到已有部署，缺省参数将沿用上次的值（重跑不会改变密钥/端口）。"
fi

# ---------------------------------------------------------------- 交互输入
if [[ -z "$UPSTREAM" ]]; then
    echo
    echo "请输入上游【线路服务器】的公网 IP（就是客户端用 reality 连的那台）。"
    echo "多台用英文逗号分隔，例如: 1.2.3.4,5.6.7.8"
    echo "整段放行可以用 CIDR，例如: 1.2.3.0/24"
    while :; do
        read -r -p "上游线路机 IP: " UPSTREAM
        UPSTREAM="${UPSTREAM//[[:space:]]/}"
        [[ -n "$UPSTREAM" ]] || { warn "不能为空。"; continue; }
        break
    done
fi

# 校验并归一化上游列表
IFS=',' read -r -a UP_ARR <<< "$UPSTREAM"
UP_V4=(); UP_V6=()
for u in "${UP_ARR[@]}"; do
    u="${u//[[:space:]]/}"
    [[ -n "$u" ]] || continue
    validate_ip "$u" || die "上游地址不合法: $u"
    if is_ipv6 "$u"; then UP_V6+=("$u"); else UP_V4+=("$u"); fi
done
UP_ALL=( ${UP_V4[@]+"${UP_V4[@]}"} ${UP_V6[@]+"${UP_V6[@]}"} )
(( ${#UP_ALL[@]} > 0 )) || die "没有有效的上游 IP。"
UPSTREAM="$(IFS=','; printf '%s' "${UP_ALL[*]}")"

[[ -n "$SS_PORT" ]] || SS_PORT="$(free_port)"
[[ "$SS_PORT" =~ ^[0-9]+$ ]] && (( SS_PORT > 0 && SS_PORT < 65536 )) || die "端口不合法: $SS_PORT"

if [[ -z "$SS_PASSWORD" ]]; then
    SS_PASSWORD="$(head -c 16 /dev/urandom | base64 | tr -d '\n')"
fi
# SS-2022 的 PSK 必须是 base64 编码的 16 字节
if ! printf '%s' "$SS_PASSWORD" | base64 -d 2>/dev/null | wc -c | grep -qx 16; then
    die "密钥格式不对。2022-blake3-aes-128-gcm 需要 base64 编码的 16 字节，可用: head -c 16 /dev/urandom | base64"
fi

# ---------------------------------------------------------------- 依赖
info "安装依赖 ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 有警告，继续。"
apt-get install -y -qq curl ca-certificates jq iptables iproute2 >/dev/null 2>&1 \
    || die "依赖安装失败，请检查网络和 apt 源。"
ok "依赖就绪。"

# ---------------------------------------------------------------- 安装 Xray
if command -v xray >/dev/null 2>&1; then
    info "已安装 Xray ($(xray version 2>/dev/null | head -1))，跳过安装。"
else
    info "安装 Xray-core（官方脚本）..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
        >/dev/null 2>&1 || die "Xray 安装失败。"
    ok "Xray 安装完成: $(xray version 2>/dev/null | head -1)"
fi

# ---------------------------------------------------------------- 生成配置
info "写入 $XRAY_CONFIG ..."
mkdir -p "$XRAY_CONFIG_DIR"
[[ -f "$XRAY_CONFIG" ]] && cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "relay-in",
      "listen": "0.0.0.0",
      "port": ${SS_PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${SS_METHOD}",
        "password": "${SS_PASSWORD}",
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "${OUT_STRATEGY}",
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8", "localhost"],
    "queryStrategy": "UseIP"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

jq empty "$XRAY_CONFIG" >/dev/null 2>&1 || die "生成的配置不是合法 JSON。"
xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || {
    xray run -test -config "$XRAY_CONFIG" || true
    die "Xray 配置自检失败，未启动服务。"
}
ok "配置校验通过。"

# ---------------------------------------------------------------- 防火墙
info "配置防火墙：仅放行上游 IP 访问 ${SS_PORT}/tcp,udp ..."

{
    echo '#!/usr/bin/env bash'
    echo '# 由 landing-relay.sh 生成。用法: landing-relay-fw.sh apply|flush'
    echo 'set -u'
    echo "PORT=${SS_PORT}"
    echo "CHAIN=${FW_CHAIN}"
    printf 'V4_LIST="%s"\n' "${UP_V4[*]:-}"
    printf 'V6_LIST="%s"\n' "${UP_V6[*]:-}"
    cat <<'FWEOF'

has() { command -v "$1" >/dev/null 2>&1; }

flush_one() {
    local cmd="$1"
    has "$cmd" || return 0
    "$cmd" -D INPUT -j "$CHAIN" 2>/dev/null || true
    while "$cmd" -D INPUT -j "$CHAIN" 2>/dev/null; do :; done
    "$cmd" -F "$CHAIN" 2>/dev/null || true
    "$cmd" -X "$CHAIN" 2>/dev/null || true
}

apply_one() {
    local cmd="$1"; shift
    local allow=("$@")
    has "$cmd" || return 0
    flush_one "$cmd"
    "$cmd" -N "$CHAIN" 2>/dev/null || return 0
    local proto ip
    for proto in tcp udp; do
        for ip in ${allow[@]+"${allow[@]}"}; do
            [ -n "$ip" ] || continue
            "$cmd" -A "$CHAIN" -p "$proto" --dport "$PORT" -s "$ip" -j ACCEPT
        done
        # 其余来源一律丢弃，避免落地机变成公开的开放代理
        "$cmd" -A "$CHAIN" -p "$proto" --dport "$PORT" -j DROP
    done
    "$cmd" -I INPUT 1 -j "$CHAIN"
}

case "${1:-apply}" in
    apply)
        apply_one iptables  $V4_LIST
        apply_one ip6tables $V6_LIST
        ;;
    flush)
        flush_one iptables
        flush_one ip6tables
        ;;
    *)
        echo "用法: $0 apply|flush" >&2
        exit 1
        ;;
esac
FWEOF
} > "$FW_SCRIPT"
chmod 700 "$FW_SCRIPT"

cat > "$FW_UNIT" <<EOF
[Unit]
Description=landing-relay firewall rules (restrict relay port to upstream IPs)
After=network-pre.target
Before=xray.service
DefaultDependencies=no
Requires=sysinit.target
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${FW_SCRIPT} apply
ExecStop=${FW_SCRIPT} flush

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now landing-relay-fw.service >/dev/null 2>&1 \
    || die "防火墙服务启用失败，请查看 journalctl -u landing-relay-fw"
ok "防火墙规则已生效并已设置开机自启。"

# ---------------------------------------------------------------- 内核调优
info "写入网络内核参数（BBR + 队列/缓冲）..."
cat > "$SYSCTL_FILE" <<'EOF'
# landing-relay: 中转出口调优
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
fs.file-max = 1048576
EOF
sysctl --system >/dev/null 2>&1 || warn "部分 sysctl 参数未生效（老内核可能不支持 BBR）。"
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
    ok "BBR 已启用。"
else
    warn "BBR 未启用，内核可能不支持。不影响转发功能。"
fi

# 提高 xray 的文件描述符上限
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
systemctl daemon-reload

# ---------------------------------------------------------------- 启动
info "启动 Xray ..."
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 30 --no-pager || true
    die "Xray 启动失败，日志见上。"
fi
ss -Hltn "sport = :${SS_PORT}" 2>/dev/null | grep -q . \
    || warn "未检测到 ${SS_PORT} 端口监听，请执行 ss -ltnp | grep xray 检查。"
ok "Xray 正在运行，监听 ${SS_PORT}。"

# ---------------------------------------------------------------- 保存状态
umask 077
cat > "$STATE_FILE" <<EOF
# landing-relay.sh 状态文件（含密钥，权限 600，勿外传）
UPSTREAM_SAVED='${UPSTREAM}'
SS_PORT_SAVED='${SS_PORT}'
SS_PASSWORD_SAVED='${SS_PASSWORD}'
SS_METHOD_SAVED='${SS_METHOD}'
EOF
chmod 600 "$STATE_FILE"

# ---------------------------------------------------------------- 输出线路机配置
LANDING_IP=$(public_ip)

OUTBOUND_JSON=$(jq -n \
    --arg addr "$LANDING_IP" \
    --argjson port "$SS_PORT" \
    --arg method "$SS_METHOD" \
    --arg pass "$SS_PASSWORD" \
    '{
        tag: "landing-out",
        protocol: "shadowsocks",
        settings: {
            servers: [{
                address: $addr,
                port: $port,
                method: $method,
                password: $pass,
                level: 0
            }]
        },
        streamSettings: {
            network: "tcp",
            sockopt: { tcpFastOpen: true, tcpKeepAliveIdle: 100 }
        }
    }')

OUTBOUND_COMPACT=$(printf '%s' "$OUTBOUND_JSON" | jq -c .)

# 注意：nokey 生成的 config.json 内含 /* */ 注释块，Xray 能读但 jq 不能，
# 所以必须先用 perl 去掉注释再交给 jq。
# 这里用 quoted heredoc 保证内容原样输出，仅把 @@OUTBOUND@@ 占位符替换掉。
PATCH_TEMPLATE=$(cat <<'PEOF'
command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq perl; }

CFG=/usr/local/etc/xray/config.json
cp -a "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)"

# nokey 的配置带 /* */ 注释，先剥掉
perl -0pe 's{/\*.*?\*/}{}gs' "$CFG" > /tmp/xray.clean.json
jq empty /tmp/xray.clean.json || { echo "去注释后仍不是合法 JSON，已中止"; exit 1; }

jq --argjson ob '@@OUTBOUND@@' '
  .outbounds = ((.outbounds // []) | map(select(.tag != "landing-out")) + [$ob])
  | .routing.rules = (((.routing.rules // []) | map(select(.outboundTag != "landing-out")))
      + [{type:"field", network:"tcp,udp", outboundTag:"landing-out"}])
' /tmp/xray.clean.json > /tmp/xray.new.json \
 && xray run -test -config /tmp/xray.new.json \
 && mv /tmp/xray.new.json "$CFG" \
 && systemctl restart xray \
 && sleep 2 && systemctl is-active --quiet xray \
 && echo "OK: 线路机已切换为经落地机出口"
PEOF
)
PATCH_CMD="${PATCH_TEMPLATE//@@OUTBOUND@@/$OUTBOUND_COMPACT}"

cat <<EOF

${C_G}==================== 落地机部署完成 ====================${C_0}

  落地机公网 IP : ${LANDING_IP}
  中转端口      : ${SS_PORT} (tcp+udp)
  加密方式      : ${SS_METHOD}
  密钥(PSK)     : ${SS_PASSWORD}
  仅放行上游    : ${UPSTREAM}
  出口策略      : ${OUT_STRATEGY}

  状态文件      : ${STATE_FILE}  (含密钥，权限 600)

${C_B}------- 第二步：在【线路服务器】上执行下面这一段 -------${C_0}

${PATCH_CMD}

${C_B}------------------ 验证 ------------------${C_0}

1) 线路机上直接测隧道（应回显落地机 IP ${LANDING_IP}）：
   xray version >/dev/null && curl -s https://ipinfo.io/ip --resolve x:0:0 >/dev/null 2>&1 || true
   # 更直接的办法：在线路机上临时开一个走 landing-out 的 socks，或直接用客户端测

2) 客户端连上 reality 后访问 https://ipinfo.io/ip ，
   看到 ${LANDING_IP} 就说明两跳链路已经通了。

3) 落地机排错：
   systemctl status xray
   journalctl -u xray -f
   iptables -L ${FW_CHAIN} -n -v      # 看放行/丢弃计数

${C_Y}注意${C_0}
 - 线路机 IP 变了要重跑本脚本更新放行列表：
     bash landing-relay.sh --upstream=新IP
   （端口和密钥会自动沿用，线路机那边不用改）
 - 端口默认只对上游 IP 开放，其余来源直接 DROP，不会变成公开开放代理。
 - 重跑脚本查看参数：bash landing-relay.sh --show

EOF
