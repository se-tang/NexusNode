#!/usr/bin/env bash
# ==============================================================================
# NexusNode Environment & Service Abstraction (systemd + Alpine OpenRC)
# ==============================================================================

export NEXUS_DIR="/etc/nexusnode"
export NEXUS_BIN="/usr/local/bin"
export NEXUS_USER="nexus"
export INIT_SYSTEM="systemd"
export PKG_MGR="apt"
export BASE_DEPS_DONE="false"

detect_environment() {
    if [[ $EUID -ne 0 ]]; then
        ui_err "请使用 root 权限运行此脚本 (sudo -i)"
        exit 1
    fi

    if [[ -f /etc/alpine-release ]]; then
        export PKG_MGR="apk"
        export INIT_SYSTEM="openrc"
    elif command -v apt-get >/dev/null 2>&1; then
        export PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        export PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        export PKG_MGR="yum"
    fi

    if ! command -v systemctl >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        export INIT_SYSTEM="openrc"
    fi

    mkdir -p "$NEXUS_DIR"/{xray/certs,sing-box/certs,warp,backup,links}
}

install_base_deps() {
    [[ "$BASE_DEPS_DONE" == "true" ]] && return 0

    local missing=0
    for cmd in curl jq unzip openssl ss; do
        command -v "$cmd" >/dev/null 2>&1 || { missing=1; break; }
    done
    if [[ $missing -eq 0 ]]; then
        export BASE_DEPS_DONE="true"
        return 0
    fi

    local cmd=""
    case "$PKG_MGR" in
        apt)
            cmd="export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a && apt-get update -qq && apt-get install -y -qq curl wget jq tar unzip openssl ca-certificates iproute2 iptables chrony"
            ;;
        dnf|yum)
            cmd="$PKG_MGR install -y -q curl wget jq tar unzip openssl ca-certificates iproute iptables chrony"
            ;;
        apk)
            cmd="apk update -q && apk add --no-cache curl wget jq tar unzip openssl ca-certificates iproute2 iptables chrony bash tzdata"
            ;;
    esac
    run_step "同步系统基础组件与安全依赖库" "$cmd" && export BASE_DEPS_DONE="true"
}

ensure_nexus_user() {
    if ! id "$NEXUS_USER" >/dev/null 2>&1; then
        if [[ "$PKG_MGR" == "apk" ]]; then
            adduser -S -D -H -s /sbin/nologin "$NEXUS_USER" 2>/dev/null || true
        else
            useradd -r -M -s /usr/sbin/nologin "$NEXUS_USER" 2>/dev/null || true
        fi
    fi
    chown -R "$NEXUS_USER":"$NEXUS_USER" "$NEXUS_DIR" 2>/dev/null || true
}

open_firewall_port() {
    local port="$1"
    local proto="${2:-tcp}"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# Create Hardened Service (systemd or OpenRC)
create_service() {
    local svc_name="$1"
    local exec_cmd="$2"
    local desc="$3"

    ensure_nexus_user

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > "/etc/systemd/system/${svc_name}.service" <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${NEXUS_USER}
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=${exec_cmd}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        run_step "注册并启动 ${svc_name} 沙盒守护进程" "systemctl daemon-reload && systemctl enable ${svc_name} && systemctl restart ${svc_name} && sleep 1 && systemctl is-active --quiet ${svc_name}"
    else
        cat > "/etc/init.d/${svc_name}" <<EOF
#!/sbin/openrc-run
name="${desc}"
command="${exec_cmd%% *}"
command_args="${exec_cmd#* }"
command_user="${NEXUS_USER}"
command_background=true
pidfile="/run/${svc_name}.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x "/etc/init.d/${svc_name}"
        run_step "注册并启动 ${svc_name} (OpenRC) 服务" "rc-update add ${svc_name} default && rc-service ${svc_name} restart"
    fi
}

service_ctl() {
    local action="$1"
    local svc_name="$2"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl "$action" "$svc_name" 2>/dev/null || true
    else
        rc-service "$svc_name" "$action" 2>/dev/null || true
    fi
}

get_public_ip() {
    local ip=""
    ip=$(curl -fsSL4 -m 3 https://ipv4.ip.sb 2>/dev/null \
        || curl -fsSL4 -m 3 https://api.ipify.org 2>/dev/null \
        || curl -fsSL4 -m 3 https://icanhazip.com 2>/dev/null \
        || true)
    if [[ -z "$ip" ]]; then
        ip=$(curl -fsSL6 -m 3 https://ipv6.ip.sb 2>/dev/null \
            || curl -fsSL6 -m 3 https://api64.ipify.org 2>/dev/null \
            || true)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    echo "$ip"
}

format_ip_for_url() {
    local ip="$1"
    if [[ "$ip" == *:* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

base64_encode_oneline() {
    printf '%s' "$1" | base64 | tr -d '\r\n'
}
