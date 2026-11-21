#!/usr/bin/env bash
# ==============================================================================
# NexusNode Custom SOCKS5 Outbound (Landing Proxy) Engine
# ==============================================================================

SOCKS_CONF="${NEXUS_DIR}/socks_outbound.conf"

load_socks_outbound() {
    SOCKS_OUT_HOST=""
    SOCKS_OUT_PORT=""
    SOCKS_OUT_USER=""
    SOCKS_OUT_PASS=""
    SOCKS_OUT_SCOPE=""
    [[ -f "$SOCKS_CONF" ]] && source "$SOCKS_CONF" 2>/dev/null || true
}

is_socks_out_enabled_for() {
    local core="$1" # xray | singbox
    load_socks_outbound
    [[ -z "$SOCKS_OUT_HOST" || -z "$SOCKS_OUT_PORT" ]] && return 1
    [[ "$SOCKS_OUT_SCOPE" == "all" || "$SOCKS_OUT_SCOPE" == "$core" ]]
}

url_decode() {
    local s="${1//\\/\\\\}"
    s="${s//%/\\x}"
    printf '%b' "$s"
}

# Parse: socks5://, socks5h://, socks://, ip:port:user:pass, ip:port
parse_socks5_input() {
    local raw="$1"
    raw="$(echo "$raw" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    raw="${raw%%#*}"
    raw="${raw%%\?*}"

    local host="" port="" user="" pass=""
    if [[ "$raw" =~ ^socks(5h?|4a?)?:// ]]; then
        local body="${raw#*://}"
        body="${body%%/*}"
        if [[ "$body" == *@* ]]; then
            local auth="${body%@*}"
            local addr="${body##*@}"
            if [[ "$auth" == *:* ]]; then
                user="$(url_decode "${auth%%:*}")"
                pass="$(url_decode "${auth#*:}")"
            else
                user="$(url_decode "$auth")"
            fi
            body="$addr"
        fi
        if [[ "$body" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        elif [[ "$body" =~ ^([^:]+):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        fi
    elif [[ "$raw" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        # ip:port or ip:port:user:pass
        IFS=':' read -r f1 f2 f3 f4 <<< "$raw"
        if [[ -n "$f1" && "$f2" =~ ^[0-9]+$ ]]; then
            host="$f1"
            port="$f2"
            user="${f3:-}"
            pass="${f4:-}"
        fi
    fi

    if [[ -z "$host" || ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        return 1
    fi

    PARSED_SOCKS_HOST="$host"
    PARSED_SOCKS_PORT="$port"
    PARSED_SOCKS_USER="$user"
    PARSED_SOCKS_PASS="$pass"
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Unified outbound+routing builder for Xray-core (handles direct, WARP, and SOCKS5)
build_xray_routing_json() {
    local warp_on="false" socks_on="false"
    if [[ "${WARP_OVERRIDE:-}" == "enable" ]]; then
        warp_on="true"
    elif [[ "${WARP_OVERRIDE:-}" != "disable" ]]; then
        is_warp_active && warp_on="true"
    fi
    is_socks_out_enabled_for "xray" && socks_on="true"

    local default_tag="direct"
    [[ "$socks_on" == "true" ]] && default_tag="socks-out"

    local outbounds='['
    if [[ "$socks_on" == "true" ]]; then
        local h_esc u_esc p_esc
        h_esc=$(json_escape "$SOCKS_OUT_HOST")
        if [[ -n "$SOCKS_OUT_USER" ]]; then
            u_esc=$(json_escape "$SOCKS_OUT_USER")
            p_esc=$(json_escape "$SOCKS_OUT_PASS")
            outbounds+="{\"tag\":\"socks-out\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"${h_esc}\",\"port\":${SOCKS_OUT_PORT},\"users\":[{\"user\":\"${u_esc}\",\"pass\":\"${p_esc}\"}]}]}},"
        else
            outbounds+="{\"tag\":\"socks-out\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"${h_esc}\",\"port\":${SOCKS_OUT_PORT}}]}},"
        fi
    fi
    outbounds+='{"tag":"direct","protocol":"freedom"}'
    if [[ "$warp_on" == "true" ]]; then
        outbounds+=',{"tag":"warp-out","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}}'
    fi
    outbounds+=',{"tag":"block","protocol":"blackhole"}]'

    if [[ "$warp_on" == "true" ]]; then
        printf '{"outbounds":%s,"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","domain":["geosite:openai","geosite:anthropic","geosite:netflix","geosite:disney","geosite:google"],"outboundTag":"warp-out"},{"type":"field","network":"tcp,udp","outboundTag":"%s"}]}}' "$outbounds" "$default_tag"
    elif [[ "$socks_on" == "true" ]]; then
        printf '{"outbounds":%s,"routing":{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"},{"type":"field","network":"tcp,udp","outboundTag":"socks-out"}]}}' "$outbounds"
    else
        printf '{"outbounds":%s}' "$outbounds"
    fi
}

# Unified outbound+route builder for sing-box (handles direct, WARP, and SOCKS5)
build_singbox_routing_json() {
    local warp_on="false" socks_on="false"
    if [[ "${WARP_OVERRIDE:-}" == "enable" ]]; then
        warp_on="true"
    elif [[ "${WARP_OVERRIDE:-}" != "disable" ]]; then
        is_warp_active && warp_on="true"
    fi
    is_socks_out_enabled_for "singbox" && socks_on="true"

    local final_tag="direct"
    [[ "$socks_on" == "true" ]] && final_tag="socks-out"

    local outbounds='[{"type":"direct","tag":"direct"}'
    if [[ "$socks_on" == "true" ]]; then
        local h_esc u_esc p_esc
        h_esc=$(json_escape "$SOCKS_OUT_HOST")
        if [[ -n "$SOCKS_OUT_USER" ]]; then
            u_esc=$(json_escape "$SOCKS_OUT_USER")
            p_esc=$(json_escape "$SOCKS_OUT_PASS")
            outbounds+=",{\"type\":\"socks\",\"tag\":\"socks-out\",\"server\":\"${h_esc}\",\"server_port\":${SOCKS_OUT_PORT},\"username\":\"${u_esc}\",\"password\":\"${p_esc}\"}"
        else
            outbounds+=",{\"type\":\"socks\",\"tag\":\"socks-out\",\"server\":\"${h_esc}\",\"server_port\":${SOCKS_OUT_PORT}}"
        fi
    fi
    if [[ "$warp_on" == "true" ]]; then
        outbounds+=',{"type":"socks","tag":"warp-out","server":"127.0.0.1","server_port":40000}'
    fi
    outbounds+=']'

    if [[ "$warp_on" == "true" ]]; then
        printf '{"outbounds":%s,"route":{"rules":[{"domain_suffix":["openai.com","chatgpt.com","oaistatic.com","oaiusercontent.com","anthropic.com","claude.ai","netflix.com","google.com"],"outbound":"warp-out"}],"final":"%s"}}' "$outbounds" "$final_tag"
    elif [[ "$socks_on" == "true" ]]; then
        printf '{"outbounds":%s,"route":{"rules":[{"ip_is_private":true,"outbound":"direct"}],"final":"socks-out"}}' "$outbounds"
    else
        printf '{"outbounds":%s,"route":{"final":"direct"}}' "$outbounds"
    fi
}

apply_all_routing() {
    if ! command -v jq >/dev/null 2>&1; then
        ui_warn "未检测到 jq，跳过现有节点配置热更新。"
        return 0
    fi

    local xray_cfg="${NEXUS_DIR}/xray/config.json"
    if [[ -f "$xray_cfg" ]]; then
        local patch tmp_x="${xray_cfg}.tmp"
        patch=$(build_xray_routing_json)
        if echo "$patch" | jq -e '.routing' >/dev/null 2>&1; then
            jq --argjson p "$patch" '.outbounds = $p.outbounds | .routing = $p.routing' "$xray_cfg" > "$tmp_x" 2>/dev/null
        else
            jq --argjson p "$patch" 'del(.routing) | .outbounds = $p.outbounds' "$xray_cfg" > "$tmp_x" 2>/dev/null
        fi
        if [[ -s "$tmp_x" ]]; then
            mv "$tmp_x" "$xray_cfg"
            chown "${NEXUS_USER}:${NEXUS_USER}" "$xray_cfg" 2>/dev/null || true
            if "${NEXUS_BIN}/xray" run -test -c "$xray_cfg" >/dev/null 2>&1; then
                service_ctl restart nexus-xray
                ui_ok "已同步更新 Xray 节点出口路由"
            else
                ui_warn "Xray 配置热更新校验失败，请检查 ${xray_cfg}"
            fi
        else
            rm -f "$tmp_x"
        fi
    fi

    local sb_cfg="${NEXUS_DIR}/sing-box/config.json"
    if [[ -f "$sb_cfg" ]]; then
        local patch tmp_s="${sb_cfg}.tmp"
        patch=$(build_singbox_routing_json)
        jq --argjson p "$patch" '.outbounds = $p.outbounds | .route = $p.route' "$sb_cfg" > "$tmp_s" 2>/dev/null
        if [[ -s "$tmp_s" ]]; then
            mv "$tmp_s" "$sb_cfg"
            chown "${NEXUS_USER}:${NEXUS_USER}" "$sb_cfg" 2>/dev/null || true
            if "${NEXUS_BIN}/sing-box" check -c "$sb_cfg" >/dev/null 2>&1; then
                service_ctl restart nexus-singbox
                ui_ok "已同步更新 sing-box 节点出口路由"
            else
                ui_warn "sing-box 配置热更新校验失败，请检查 ${sb_cfg}"
            fi
        else
            rm -f "$tmp_s"
        fi
    fi
}

configure_socks_outbound() {
    local raw_input="${1:-}"
    local scope_arg="${2:-}"

    load_socks_outbound
    if [[ -n "$SOCKS_OUT_HOST" ]]; then
        ui_info "当前已配置 SOCKS5 出口: ${SOCKS_OUT_HOST}:${SOCKS_OUT_PORT} (范围: ${SOCKS_OUT_SCOPE})"
    fi

    if [[ -z "$raw_input" ]]; then
        ui_ask "粘贴 SOCKS5 出口 (支持 socks5://user:pass@ip:port 或 ip:port:user:pass)" "" raw_input
    fi
    if ! parse_socks5_input "$raw_input"; then
        ui_err "无法解析 SOCKS5 地址，请检查格式。"
        return 1
    fi

    local scope="$scope_arg"
    if [[ -z "$scope" ]]; then
        local files=() idx=1
        if ls "${NEXUS_DIR}/links/"*.txt >/dev/null 2>&1; then
            printf "\n  ${C_BOLD}[选择应用出口的节点]${C_RESET}\n"
            for f in "${NEXUS_DIR}/links/"*.txt; do
                files+=("$f")
                printf "  ${C_GREEN}%d.${C_RESET} %s\n" "$idx" "$(basename "$f" .txt)"
                ((idx++))
            done
        fi
        printf "  ${C_GRAY}直接回车 = 全部节点 (含以后新建节点)${C_RESET}\n"
        local pick=""
        ui_ask "选择节点编号或回车全部应用" "all" pick
        if [[ "$pick" == "all" || -z "$pick" ]]; then
            scope="all"
        elif [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#files[@]} )); then
            local bname
            bname="$(basename "${files[$((pick - 1))]}" .txt)"
            if [[ "$bname" == xray_* ]]; then
                scope="xray"
            elif [[ "$bname" == singbox_* ]]; then
                scope="singbox"
            else
                scope="all"
            fi
        else
            ui_err "无效编号。"
            return 1
        fi
    fi

    cat > "$SOCKS_CONF" <<EOF
SOCKS_OUT_HOST=$(printf '%q' "$PARSED_SOCKS_HOST")
SOCKS_OUT_PORT=$(printf '%q' "$PARSED_SOCKS_PORT")
SOCKS_OUT_USER=$(printf '%q' "$PARSED_SOCKS_USER")
SOCKS_OUT_PASS=$(printf '%q' "$PARSED_SOCKS_PASS")
SOCKS_OUT_SCOPE=$(printf '%q' "$scope")
EOF
    chmod 600 "$SOCKS_CONF"
    ui_ok "已保存 SOCKS5 出口: ${PARSED_SOCKS_HOST}:${PARSED_SOCKS_PORT} (作用范围: ${scope})"
    apply_all_routing
}

disable_socks_outbound() {
    rm -f "$SOCKS_CONF"
    ui_ok "已清除 SOCKS5 出口配置。"
    apply_all_routing
}
