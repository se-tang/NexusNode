#!/usr/bin/env bash
# ==============================================================================
# NexusNode sing-box Engine (Reality, Hysteria2, TUIC v5, AnyTLS, SS-2022, Mixed)
# ==============================================================================

ensure_singbox_binary() {
    if [[ -x "${NEXUS_BIN}/sing-box" ]]; then
        return 0
    fi
    local arch sb_arch="amd64"
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64) sb_arch="arm64" ;;
        x86_64|amd64)  sb_arch="amd64" ;;
    esac

    local ver
    ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --connect-timeout 5 --max-time 10 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | awk -F'/v' '{print $NF}' || true)
    [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ver="1.12.12"

    run_step "下载官方 sing-box v${ver} 高性能内核" "
        curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${sb_arch}.tar.gz -o /tmp/sb.tar.gz &&
        tar -xzf /tmp/sb.tar.gz -C /tmp &&
        mv /tmp/sing-box-${ver}-linux-${sb_arch}/sing-box ${NEXUS_BIN}/sing-box &&
        chmod +x ${NEXUS_BIN}/sing-box &&
        rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
    "
}

build_singbox_routing() {
    if is_warp_active; then
        cat <<'EOF'
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "socks", "tag": "warp-out", "server": "127.0.0.1", "server_port": 40000 }
  ],
  "route": {
    "rules": [
      {
        "domain_suffix": ["openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "anthropic.com", "claude.ai", "netflix.com", "google.com"],
        "outbound": "warp-out"
      }
    ],
    "final": "direct"
  }
EOF
    else
        cat <<'EOF'
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
EOF
    fi
}

deploy_singbox_service() {
    local port="$1"
    shift
    local protos=("$@")
    [[ ${#protos[@]} -eq 0 ]] && protos=("tcp")

    if ! "${NEXUS_BIN}/sing-box" check -c "${NEXUS_DIR}/sing-box/config.json" >/dev/null 2>&1; then
        ui_err "sing-box 配置文件校验失败："
        "${NEXUS_BIN}/sing-box" check -c "${NEXUS_DIR}/sing-box/config.json" || true
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet sing-box.service 2>/dev/null; then
        systemctl disable --now sing-box.service >/dev/null 2>&1 || true
    fi
    for p in "${protos[@]}"; do
        open_firewall_port "$port" "$p"
    done
    create_service "nexus-singbox" "${NEXUS_BIN}/sing-box run -c ${NEXUS_DIR}/sing-box/config.json" "NexusNode sing-box Service"
}

# Usage: deploy_singbox_node [reality|hy2|tuic|anytls|ss2022|mixed] [port] [hop_range] [sni]
deploy_singbox_node() {
    local mode="${1:-hy2}"
    local port="${2:-}"
    local hop_range="${3:-}"
    local sni="${4:-}"

    ensure_singbox_binary || return 1

    local pub_ip url_ip routing_block
    pub_ip=$(get_public_ip)
    if [[ -z "$pub_ip" ]]; then
        ui_err "无法获取服务器公网 IP。"
        return 1
    fi
    url_ip=$(format_ip_for_url "$pub_ip")
    routing_block=$(build_singbox_routing)
    mkdir -p "${NEXUS_DIR}/sing-box/certs"

    if [[ -z "$port" ]]; then
        local def_port
        def_port=$(random_high_port) || return 1
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            port="$def_port"
        else
            ui_ask "请输入监听端口" "$def_port" port
            port="$(get_valid_port "$port")" || return 1
        fi
    else
        port="$(get_valid_port "$port")" || return 1
    fi

    local share_link title extra=""
    case "$mode" in
        reality)
            if [[ -z "$sni" ]]; then
                benchmark_sni sni
                [[ "$NON_INTERACTIVE" != "true" ]] && ui_ask "确认或修改伪装 SNI 域名" "$sni" sni
            fi
            sni="$(validate_sni "$sni")" || return 1

            local uuid short_id key_pair priv_key pub_key
            uuid=$(cat /proc/sys/kernel/random/uuid)
            short_id=$(openssl rand -hex 4)
            key_pair=$("${NEXUS_BIN}/sing-box" generate reality-keypair 2>/dev/null) || {
                ui_err "生成 sing-box Reality 密钥对失败。"
                return 1
            }
            priv_key=$(echo "$key_pair" | awk -F': ' '/PrivateKey/ {print $2}' | tr -d ' "\r\n')
            pub_key=$(echo "$key_pair" | awk -F': ' '/PublicKey/ {print $2}' | tr -d ' "\r\n')
            if [[ -z "$priv_key" || -z "$pub_key" ]]; then
                ui_err "解析 sing-box Reality 密钥失败。"
                return 1
            fi

            cat > "${NEXUS_DIR}/sing-box/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        { "name": "nexus", "uuid": "${uuid}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${sni}", "server_port": 443 },
          "private_key": "${priv_key}",
          "short_id": [ "${short_id}" ]
        }
      }
    }
  ],
${routing_block}
}
EOF
            deploy_singbox_service "$port" "tcp" || return 1
            title="sing-box VLESS-Reality"
            extra="SNI: ${sni} | ShortID: ${short_id}"
            share_link="vless://${uuid}@${url_ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#Nexus-SB-Reality-${pub_ip}"
            ;;
        hy2)
            prepare_self_signed_tls "${NEXUS_DIR}/sing-box/certs" "$sni" "$pub_ip" || return 1

            local use_obfs="N" obfs_block="" obfs_query="" obfs_info="关闭"
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                ui_ask "是否开启 Salamander 混淆 (仅在 UDP 被限速时开启, y/N)" "N" use_obfs
                ui_ask "UDP 端口跳跃范围 (留空或输入如 30000:40000)" "30000:40000" hop_range
            fi

            local password
            password=$(openssl rand -hex 12)
            if [[ "$use_obfs" =~ ^[Yy]$ ]]; then
                local obfs_pass
                obfs_pass=$(openssl rand -hex 8)
                obfs_block="      \"obfs\": { \"type\": \"salamander\", \"password\": \"${obfs_pass}\" },"
                obfs_query="&obfs=salamander&obfs-password=${obfs_pass}"
                obfs_info="salamander"
            fi

            cat > "${NEXUS_DIR}/sing-box/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [ { "name": "nexus", "password": "${password}" } ],
${obfs_block}
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "${TLS_CERT_FILE}",
        "key_path": "${TLS_KEY_FILE}"
      }
    }
  ],
${routing_block}
}
EOF
            local mport_query="" mport_extra=""
            if [[ -n "$hop_range" && "$hop_range" =~ ^[0-9]+:[0-9]+$ ]]; then
                setup_hy2_port_hopping "$port" "$hop_range"
                local mport_str="${hop_range/:/-}"
                mport_query="&mport=${mport_str}"
                mport_extra=" | 跳跃: ${mport_str}"
            fi

            deploy_singbox_service "$port" "udp" || return 1
            title="sing-box Hysteria 2"
            extra="SNI: ${TLS_DOMAIN} | 混淆: ${obfs_info}${mport_extra}"
            share_link="hysteria2://${password}@${url_ip}:${port}/?sni=${TLS_DOMAIN}&insecure=1&pinSHA256=${TLS_CERT_SHA256}${obfs_query}${mport_query}#Nexus-Hy2-${pub_ip}"
            ;;
        tuic)
            prepare_self_signed_tls "${NEXUS_DIR}/sing-box/certs" "$sni" "$pub_ip" || return 1
            local uuid password
            uuid=$(cat /proc/sys/kernel/random/uuid)
            password=$(openssl rand -hex 12)

            cat > "${NEXUS_DIR}/sing-box/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [ { "name": "nexus", "uuid": "${uuid}", "password": "${password}" } ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "${TLS_CERT_FILE}",
        "key_path": "${TLS_KEY_FILE}"
      }
    }
  ],
${routing_block}
}
EOF
            deploy_singbox_service "$port" "udp" || return 1
            title="sing-box TUIC v5"
            extra="SNI: ${TLS_DOMAIN} | CC: bbr"
            share_link="tuic://${uuid}:${password}@${url_ip}:${port}?congestion_control=bbr&alpn=h3&sni=${TLS_DOMAIN}&allow_insecure=1#Nexus-TUIC-${pub_ip}"
            ;;
        anytls)
            prepare_self_signed_tls "${NEXUS_DIR}/sing-box/certs" "$sni" "$pub_ip" || return 1
            local password
            password=$(openssl rand -hex 12)

            cat > "${NEXUS_DIR}/sing-box/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [ { "name": "nexus", "password": "${password}" } ],
      "tls": {
        "enabled": true,
        "certificate_path": "${TLS_CERT_FILE}",
        "key_path": "${TLS_KEY_FILE}"
      }
    }
  ],
${routing_block}
}
EOF
            deploy_singbox_service "$port" "tcp" || return 1
            title="sing-box AnyTLS"
            extra="SNI: ${TLS_DOMAIN}"
            share_link="anytls://${password}@${url_ip}:${port}/?sni=${TLS_DOMAIN}&insecure=1#Nexus-AnyTLS-${pub_ip}"
            ;;
        ss2022)
            local method="2022-blake3-aes-128-gcm" password creds_b64
            password=$(openssl rand -base64 16)

            cat > "${NEXUS_DIR}/sing-box/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${port},
      "method": "${method}",
      "password": "${password}"
    }
  ],
${routing_block}
}
EOF
            deploy_singbox_service "$port" "tcp" "udp" || return 1
            creds_b64=$(base64_encode_oneline "${method}:${password}")
            title="sing-box Shadowsocks-2022"
            extra="加密: ${method}"
            share_link="ss://${creds_b64}@${url_ip}:${port}#Nexus-SS2022-${pub_ip}"
            ;;
        mixed)
            local username password
            username="nexus_$(openssl rand -hex 3)"
            password=$(openssl rand -hex 8)
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                ui_ask "请输入 SOCKS5/HTTP 用户名" "$username" username
                ui_ask "请输入 SOCKS5/HTTP 密码" "$password" password
            fi

            cat > "${NEXUS_DIR}/sing-box/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [ { "username": "${username}", "password": "${password}" } ]
    }
  ],
${routing_block}
}
EOF
            deploy_singbox_service "$port" "tcp" || return 1
            title="sing-box SOCKS5 / HTTP"
            extra="账号: ${username} | 密码: ${password}"
            share_link="socks://${username}:${password}@${url_ip}:${port}#Nexus-Mixed-${pub_ip}"
            ;;
        *)
            ui_err "未知 sing-box 协议模式: ${mode}"
            return 1
            ;;
    esac

    echo "$share_link" > "${NEXUS_DIR}/links/singbox_${mode}.txt"
    ui_node_card "$title" "$pub_ip" "$port" "$extra" "$share_link"
}
