#!/usr/bin/env bash
# ==============================================================================
# NexusNode Network Utilities: SNI Benchmark, Ports, Certs, CDN & Port Hopping
# ==============================================================================

SAFE_SNI_POOL=(
    "www.microsoft.com"
    "www.bing.com"
    "learn.microsoft.com"
    "azure.microsoft.com"
    "www.oracle.com"
    "www.amd.com"
    "www.nvidia.com"
    "www.intel.com"
)

is_port_in_use() {
    local port="$1"
    ss -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

random_high_port() {
    local port attempts=0
    while (( attempts < 50 )); do
        port=$(( RANDOM % 50000 + 10000 ))
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
        ((attempts++))
    done
    ui_err "无法找到可用高位端口。"
    return 1
}

get_valid_port() {
    local input_port="${1:-}"
    input_port="$(echo "$input_port" | tr -d '[:space:]')"
    if [[ -z "$input_port" ]]; then
        random_high_port
        return $?
    fi
    if [[ ! "$input_port" =~ ^[0-9]+$ ]] || (( input_port < 1 || input_port > 65535 )); then
        ui_err "端口必须是 1-65535 之间的整数。"
        return 1
    fi
    if is_port_in_use "$input_port"; then
        ui_warn "端口 ${input_port} 当前已被占用（若为覆盖重装则继续）。"
    fi
    echo "$input_port"
}

get_cf_https_port() {
    local p
    for p in 443 8443 2053 2083 2087 2096; do
        if ! is_port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "443"
}

# 0 = direct/grey cloud, 1 = CDN/orange cloud, 2 = unresolved
check_domain_direct_status() {
    local domain="$1"
    local pub_ip="$2"
    local resolved_ips
    resolved_ips="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [[ -z "$resolved_ips" ]]; then
        return 2
    fi
    if echo "$resolved_ips" | grep -qxF "$pub_ip"; then
        return 0
    fi
    return 1
}

validate_sni() {
    local sni
    sni="$(echo "${1:-}" | tr -d '[:space:]')"
    if [[ -z "$sni" || ! "$sni" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        ui_err "非法域名格式: ${sni}"
        return 1
    fi
    echo "$sni"
}

# Benchmark direct-connect enterprise SNI domains requiring TLS 1.3 + HTTP/2
benchmark_sni() {
    local __out_var="$1"
    local best_domain="www.microsoft.com"
    local best_time="9999"
    local tmp_dir="/tmp/nexus_sni_$$"
    mkdir -p "$tmp_dir"

    tput civis 2>/dev/null || true
    printf "${C_CLEAR_LINE}${C_CYAN}⠋${C_RESET} 正在并发测速筛选本机最优 TLS 1.3 + H2 伪装域名..."

    for d in "${SAFE_SNI_POOL[@]}"; do
        (
            local res http_ver ms
            res=$(curl -o /dev/null -s -w '%{http_version} %{time_connect}' --tlsv1.3 --http2 --connect-timeout 2 --max-time 3 "https://${d}" 2>/dev/null || true)
            http_ver=$(echo "$res" | awk '{print $1}')
            ms=$(echo "$res" | awk '{printf "%d", $2*1000}')
            if [[ "$http_ver" == "2" && -n "$ms" && "$ms" -gt 0 ]]; then
                echo "$ms $d" > "${tmp_dir}/${d}"
            fi
        ) &
    done
    wait

    if ls "${tmp_dir}"/* >/dev/null 2>&1; then
        local winner
        winner=$(cat "${tmp_dir}"/* | sort -n | head -n1)
        best_time=$(echo "$winner" | awk '{print $1}')
        best_domain=$(echo "$winner" | awk '{print $2}')
    fi
    rm -rf "$tmp_dir"
    tput cnorm 2>/dev/null || true

    printf "${C_CLEAR_LINE}${C_GREEN}✔${C_RESET} 最优 SNI 伪装域名: ${C_BOLD}%s${C_RESET} ${C_GRAY}(TLS1.3+H2 握手: %sms)${C_RESET}\n" "$best_domain" "$best_time"
    eval "$__out_var=\"\$best_domain\""
}

generate_self_signed_cert() {
    local cert_dir="$1"
    local domain="$2"
    local pub_ip="${3:-}"
    local san="DNS:${domain}"
    [[ -n "$pub_ip" && "$pub_ip" != *:* ]] && san="${san},IP:${pub_ip}"
    mkdir -p "$cert_dir"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -nodes -days 365 \
        -keyout "${cert_dir}/key.pem" \
        -out "${cert_dir}/cert.pem" \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=${san}" >/dev/null 2>&1
    chown -R "$NEXUS_USER":"$NEXUS_USER" "$cert_dir" 2>/dev/null || true
}

issue_acme_cert() {
    local cert_dir="$1"
    local domain="$2"

    if [[ -s "${cert_dir}/cert.pem" && -s "${cert_dir}/key.pem" ]]; then
        ui_ok "检测到 ${domain} 已有 Let's Encrypt 正式证书，直接复用。"
        return 0
    fi

    if is_port_in_use 80; then
        ui_err "80 端口已被占用，无法使用 acme.sh standalone 模式申请证书。"
        return 1
    fi

    if ! command -v socat >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apt) run_step "安装证书申请依赖 socat" "export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a && apt-get install -y -qq socat cron" ;;
            dnf|yum) run_step "安装证书申请依赖 socat" "$PKG_MGR install -y -q socat cronie" ;;
            apk) run_step "安装证书申请依赖 socat" "apk add --no-cache socat" ;;
        esac
    fi

    local acme_bin="/root/.acme.sh/acme.sh"
    if [[ ! -x "$acme_bin" ]]; then
        run_step "安装 acme.sh 证书签发客户端" "curl -fsSL --connect-timeout 10 --max-time 45 https://get.acme.sh | sh -s email=nexus@${domain}" || return 1
    fi

    open_firewall_port 80 "tcp"
    "$acme_bin" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    local acme_rc=0
    run_step "向 Let's Encrypt 申请 ${domain} 正式证书" "
        rc=0;
        ${acme_bin} --issue -d ${domain} --standalone --keylength ec-256 || rc=\$?;
        [ \$rc -eq 0 ] || [ \$rc -eq 2 ]
    " || {
        ui_err "证书申请失败！请确认域名已解析到本机 IP 且未开启 CF 小黄云（申请时需灰云）。"
        return 1
    }

    ensure_nexus_user
    mkdir -p "$cert_dir"
    run_step "安装证书并配置自动续期重载" "
        ${acme_bin} --install-cert -d ${domain} --ecc \
            --fullchain-file ${cert_dir}/cert.pem \
            --key-file ${cert_dir}/key.pem \
            --reloadcmd 'systemctl restart nexus-xray nexus-singbox 2>/dev/null || rc-service nexus-xray restart 2>/dev/null || true' &&
        chown -R ${NEXUS_USER}:${NEXUS_USER} ${cert_dir}
    "
}

prompt_required_domain() {
    local pub_ip="$1"
    local input_domain=""
    ui_ask "请输入自有域名 (如 node.example.com)" "" input_domain
    TLS_DOMAIN="$(validate_sni "$input_domain")" || return 1

    DOMAIN_IS_CF=0
    local rc=0
    check_domain_direct_status "$TLS_DOMAIN" "$pub_ip" || rc=$?
    if [[ $rc -eq 0 ]]; then
        ui_ok "域名探测: 直连本机 (灰云)，支持任意端口与自动申请正式证书。"
        DOMAIN_IS_CF=0
    elif [[ $rc -eq 1 ]]; then
        ui_warn "域名探测: 指向非本机 IP (疑似已开 CF 小黄云 CDN)，将自动匹配 CF HTTPS 端口。"
        DOMAIN_IS_CF=1
    else
        ui_warn "域名暂未解析出 IP，请确认已在 DNS 面板配置 A 记录。"
        DOMAIN_IS_CF=2
    fi
}

prompt_cert_for_domain() {
    local cert_dir="$1"
    local domain="$2"
    local is_cf="${3:-0}"
    local domain_cert_dir="${cert_dir}/${domain}"

    if [[ -s "${domain_cert_dir}/cert.pem" && -s "${domain_cert_dir}/key.pem" ]]; then
        ui_ok "检测到 ${domain} 已有正式证书，直接复用。"
        TLS_CERT_FILE="${domain_cert_dir}/cert.pem"
        TLS_KEY_FILE="${domain_cert_dir}/key.pem"
        TLS_INSECURE=0
        TLS_CERT_SHA256=""
        return 0
    fi

    if [[ "$is_cf" -eq 1 ]]; then
        local local_pub_ip
        local_pub_ip="$(get_public_ip)"
        mkdir -p "$domain_cert_dir"
        generate_self_signed_cert "$domain_cert_dir" "$domain" "$local_pub_ip" || {
            ui_err "生成自签证书失败。"
            return 1
        }
        ui_ok "CDN 模式：已自动生成回源 365 天 ECC 自签证书 (请确保 CF SSL/TLS 为 Full 模式)。"
        TLS_CERT_FILE="${domain_cert_dir}/cert.pem"
        TLS_KEY_FILE="${domain_cert_dir}/key.pem"
        TLS_INSECURE=0
        TLS_CERT_SHA256=""
    else
        issue_acme_cert "$domain_cert_dir" "$domain" || return 1
        TLS_CERT_FILE="${domain_cert_dir}/cert.pem"
        TLS_KEY_FILE="${domain_cert_dir}/key.pem"
        TLS_INSECURE=0
        TLS_CERT_SHA256=""
    fi
}

prepare_self_signed_tls() {
    local cert_dir="$1"
    local sni="${2:-}"
    local pub_ip="${3:-}"

    if [[ -z "$sni" ]]; then
        benchmark_sni sni
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            ui_ask "确认或修改伪装 SNI 域名" "$sni" sni
        fi
    fi
    TLS_DOMAIN="$(validate_sni "$sni")" || return 1

    generate_self_signed_cert "$cert_dir" "$TLS_DOMAIN" "$pub_ip" || {
        ui_err "生成 365 天 ECC 自签证书失败。"
        return 1
    }
    TLS_CERT_FILE="${cert_dir}/cert.pem"
    TLS_KEY_FILE="${cert_dir}/key.pem"
    TLS_INSECURE=1
    TLS_CERT_SHA256="$(openssl x509 -in "$TLS_CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print $2}' | tr -d ':\r\n' | tr 'A-F' 'a-f')"
    ui_ok "已生成 365 天 ECC 合规证书 (${TLS_DOMAIN})"
}

# Configure Hysteria 2 UDP Port Hopping (nftables / iptables)
setup_hy2_port_hopping() {
    local listen_port="$1"
    local hop_range="${2:-30000:40000}"
    local hop_start="${hop_range%:*}"
    local hop_end="${hop_range#*:}"

    local cmd=""
    if command -v nft >/dev/null 2>&1; then
        cmd="nft add table inet nexus_hop 2>/dev/null || true; \
             nft flush table inet nexus_hop 2>/dev/null || true; \
             nft add chain inet nexus_hop prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'; \
             nft add rule inet nexus_hop prerouting udp dport ${hop_start}-${hop_end} redirect to :${listen_port}"
    elif command -v iptables >/dev/null 2>&1; then
        cmd="iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports ${listen_port} 2>/dev/null || true; \
             iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports ${listen_port}; \
             ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports ${listen_port} 2>/dev/null || true; \
             ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports ${listen_port} 2>/dev/null || true"
    else
        ui_warn "未检测到 nftables/iptables，跳过 UDP 端口跳跃规则。"
        return 0
    fi

    run_step "配置 Hysteria 2 UDP 端口跳跃 (${hop_start}-${hop_end} -> ${listen_port})" "$cmd" || ui_warn "端口跳跃规则下发失败（可能受限容器环境），主端口仍可正常使用。"
}
