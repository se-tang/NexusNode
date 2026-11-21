#!/usr/bin/env bash
# ==============================================================================
# NexusNode Lightweight WARP Socks5 Split-Routing Engine
# ==============================================================================

sync_warp_routing() {
    local mode="${1:-auto}" # enable | disable | auto
    WARP_OVERRIDE="$mode" apply_all_routing
}

install_warp_outbound() {
    local arch
    arch=$(uname -m)
    local wp_arch="amd64"
    [[ "$arch" == "aarch64" ]] && wp_arch="arm64"

    run_step "下载 wgcf 与 wireproxy 轻量级 WARP 组件" "
        curl -fsSL https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${wp_arch} -o ${NEXUS_BIN}/wgcf &&
        chmod +x ${NEXUS_BIN}/wgcf &&
        curl -fsSL https://github.com/pufferffish/wireproxy/releases/download/v1.0.9/wireproxy_linux_${wp_arch}.tar.gz -o /tmp/wp.tar.gz &&
        tar -xzf /tmp/wp.tar.gz -C ${NEXUS_BIN} wireproxy &&
        chmod +x ${NEXUS_BIN}/wireproxy &&
        rm -f /tmp/wp.tar.gz
    " || return 1

    if [[ ! -f "${NEXUS_DIR}/warp/wgcf-profile.conf" ]]; then
        run_step "向 Cloudflare 注册免费 WARP 密钥对" "
            cd ${NEXUS_DIR}/warp &&
            rm -f wgcf-account.toml wgcf-profile.conf &&
            ${NEXUS_BIN}/wgcf register --accept-tos &&
            ${NEXUS_BIN}/wgcf generate
        " || return 1
    fi

    cat > "${NEXUS_DIR}/warp/wireproxy.conf" <<EOF
WGConfig = ${NEXUS_DIR}/warp/wgcf-profile.conf

[Socks5]
BindAddress = 127.0.0.1:40000
EOF

    chown -R "$NEXUS_USER":"$NEXUS_USER" "${NEXUS_DIR}/warp"
    create_service "nexus-warp" "${NEXUS_BIN}/wireproxy -c ${NEXUS_DIR}/warp/wireproxy.conf" "NexusNode Cloudflare WARP Local Outbound" || return 1
    sync_warp_routing "enable"
    ui_ok "WARP 本地分流出口已就绪 (127.0.0.1:40000)"
}

disable_warp_outbound() {
    service_ctl stop "nexus-warp"
    sync_warp_routing "disable"
    ui_ok "已停用 WARP 分流服务"
}

is_warp_active() {
    ss -tlpn 2>/dev/null | grep -q '127.0.0.1:40000'
}
