#!/usr/bin/env bash
# ==============================================================================
# NexusNode Lightweight WARP Socks5 Split-Routing Engine
# ==============================================================================

sync_warp_routing() {
    local mode="${1:-auto}" # enable | disable | auto
    local use_warp="false"
    if [[ "$mode" == "enable" ]]; then
        use_warp="true"
    elif [[ "$mode" == "disable" ]]; then
        use_warp="false"
    else
        is_warp_active && use_warp="true"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        ui_warn "未检测到 jq，跳过现有节点配置热更新。"
        return 0
    fi

    # 1. Hot-patch existing Xray config without changing inbound/UUID/keys
    local xray_cfg="${NEXUS_DIR}/xray/config.json"
    if [[ -f "$xray_cfg" ]]; then
        local xray_patch
        if [[ "$use_warp" == "true" ]]; then
            xray_patch='{
              "outbounds": [
                { "tag": "direct", "protocol": "freedom" },
                { "tag": "warp-out", "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 40000 }] } },
                { "tag": "block", "protocol": "blackhole" }
              ],
              "routing": {
                "domainStrategy": "IPIfNonMatch",
                "rules": [
                  { "type": "field", "domain": ["geosite:openai", "geosite:anthropic", "geosite:netflix", "geosite:disney", "geosite:google"], "outboundTag": "warp-out" }
                ]
              }
            }'
        else
            xray_patch='{
              "outbounds": [
                { "tag": "direct", "protocol": "freedom" },
                { "tag": "block", "protocol": "blackhole" }
              ]
            }'
        fi

        local tmp_x="${xray_cfg}.tmp"
        if [[ "$use_warp" == "true" ]]; then
            jq --argjson p "$xray_patch" '.outbounds = $p.outbounds | .routing = $p.routing' "$xray_cfg" > "$tmp_x" 2>/dev/null
        else
            jq --argjson p "$xray_patch" 'del(.routing) | .outbounds = $p.outbounds' "$xray_cfg" > "$tmp_x" 2>/dev/null
        fi
        if [[ -s "$tmp_x" ]]; then
            mv "$tmp_x" "$xray_cfg"
            chown "${NEXUS_USER}:${NEXUS_USER}" "$xray_cfg" 2>/dev/null || true
            if "${NEXUS_BIN}/xray" run -test -c "$xray_cfg" >/dev/null 2>&1; then
                service_ctl restart nexus-xray
                ui_ok "已自动热更新 Xray 节点路由（$( [[ "$use_warp" == "true" ]] && echo '已开启 WARP 分流' || echo '已还原直连' )）"
            else
                ui_warn "Xray 配置热更新校验异常，请检查 ${xray_cfg}"
            fi
        else
            rm -f "$tmp_x"
        fi
    fi

    # 2. Hot-patch existing sing-box config without changing inbound/certs/keys
    local sb_cfg="${NEXUS_DIR}/sing-box/config.json"
    if [[ -f "$sb_cfg" ]]; then
        local sb_patch
        if [[ "$use_warp" == "true" ]]; then
            sb_patch='{
              "outbounds": [
                { "type": "direct", "tag": "direct" },
                { "type": "socks", "tag": "warp-out", "server": "127.0.0.1", "server_port": 40000 }
              ],
              "route": {
                "rules": [
                  { "domain_suffix": ["openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "anthropic.com", "claude.ai", "netflix.com", "google.com"], "outbound": "warp-out" }
                ],
                "final": "direct"
              }
            }'
        else
            sb_patch='{
              "outbounds": [ { "type": "direct", "tag": "direct" } ],
              "route": { "final": "direct" }
            }'
        fi

        local tmp_s="${sb_cfg}.tmp"
        jq --argjson p "$sb_patch" '.outbounds = $p.outbounds | .route = $p.route' "$sb_cfg" > "$tmp_s" 2>/dev/null
        if [[ -s "$tmp_s" ]]; then
            mv "$tmp_s" "$sb_cfg"
            chown "${NEXUS_USER}:${NEXUS_USER}" "$sb_cfg" 2>/dev/null || true
            if "${NEXUS_BIN}/sing-box" check -c "$sb_cfg" >/dev/null 2>&1; then
                service_ctl restart nexus-singbox
                ui_ok "已自动热更新 sing-box 节点路由（$( [[ "$use_warp" == "true" ]] && echo '已开启 WARP 分流' || echo '已还原直连' )）"
            else
                ui_warn "sing-box 配置热更新校验异常，请检查 ${sb_cfg}"
            fi
        else
            rm -f "$tmp_s"
        fi
    fi
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
