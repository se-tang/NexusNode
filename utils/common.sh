#!/usr/bin/env bash

[[ -n "${NEXUS_COMMON_LOADED:-}" ]] && return 0
NEXUS_COMMON_LOADED=1

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

SAFE_SNI_POOL=(
    "www.microsoft.com"
    "www.bing.com"
    "learn.microsoft.com"
    "azure.microsoft.com"
    "visualstudio.microsoft.com"
)

run_with_spinner() {
    local msg="$1"
    shift
    local log_file
    log_file="$(mktemp /tmp/nexus-cmd.XXXXXX)"
    "$@" >"$log_file" 2>&1 &
    local pid=$!
    local spin='|/-\'
    local i=0
    local secs=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}[Info]${NC} %s... %c (%ds)" "$msg" "${spin:i%4:1}" "$secs"
        sleep 1
        ((i++))
        ((secs++))
    done

    wait "$pid"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "\r${GREEN}[OK]${NC}   %s 完成 (%ds)        \n" "$msg" "$secs"
    else
        printf "\r${RED}[Fail]${NC} %s 失败 (%ds)        \n" "$msg" "$secs"
        tail -n 15 "$log_file" 2>/dev/null || true
    fi
    rm -f "$log_file"
    return $rc
}

check_dependencies() {
    local missing=()
    for cmd in curl openssl awk shuf ss systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    echo -e "${YELLOW}[Info] 检测到缺少基础依赖: ${missing[*]}，尝试自动安装...${NC}"
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -qq && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq curl openssl gawk coreutils iproute2 systemd >/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl openssl gawk coreutils iproute systemd >/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q curl openssl gawk coreutils iproute systemd >/dev/null
    else
        echo -e "${RED}[Error] 无法自动安装依赖 (${missing[*]})，请手动安装后重试。${NC}"
        return 1
    fi

    for cmd in curl openssl awk shuf ss systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}[Error] 依赖 $cmd 仍不可用，请检查系统环境。${NC}"
            return 1
        fi
    done
}

auto_select_best_sni() {
    local best_sni=""
    local min_time=9999.0

    for sni in "${SAFE_SNI_POOL[@]}"; do
        local result http_ver time_total
        result=$(curl -so /dev/null -w "%{http_version} %{time_total}" --tlsv1.3 --http2 --connect-timeout 2 --max-time 3 "https://$sni" 2>/dev/null || true)
        http_ver=$(echo "$result" | awk '{print $1}')
        time_total=$(echo "$result" | awk '{print $2}')

        # Reality 要求目标站点支持 TLS 1.3 + HTTP/2 (http_version == 2)
        if [[ "$http_ver" == "2" ]] && [[ -n "$time_total" ]] && awk -v t="$time_total" 'BEGIN {exit !(t > 0)}'; then
            local is_smaller
            is_smaller=$(awk -v t="$time_total" -v m="$min_time" 'BEGIN {print (t < m) ? 1 : 0}')
            if [[ "$is_smaller" -eq 1 ]]; then
                min_time="$time_total"
                best_sni="$sni"
            fi
        fi
    done

    if [[ -z "$best_sni" ]]; then
        best_sni="${SAFE_SNI_POOL[0]}"
    fi

    echo "$best_sni"
}

get_target_sni() {
    local input_sni="${1:-}"
    input_sni="$(echo "$input_sni" | tr -d '[:space:]')"

    if [[ -z "$input_sni" ]]; then
        echo -e "${CYAN}[Info]${NC} 正在后台进行多节点 TLS 1.3 + H2 延迟优选..." >&2
        auto_select_best_sni
        return 0
    fi

    if [[ ! "$input_sni" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo -e "${RED}[Error] 非法域名格式: $input_sni${NC}" >&2
        return 1
    fi

    echo "$input_sni"
}

is_port_in_use() {
    local port="$1"
    ss -tuln 2>/dev/null | grep -qE "[:.]$port[[:space:]]"
}

get_random_port() {
    local port
    local attempts=0
    while (( attempts < 50 )); do
        port=$(shuf -i 10000-65535 -n 1)
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
        ((attempts++))
    done
    echo -e "${RED}[Error] 无法找到可用高位端口。${NC}" >&2
    return 1
}

get_cf_https_port() {
    local p
    for p in 8443 2053 2083 2087 2096 443; do
        if ! is_port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "8443"
}

# 返回 0=直连本机(灰云), 1=疑似CDN代理(小黄云/其他IP), 2=未解析
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

get_valid_port() {
    local input_port="${1:-}"
    input_port="$(echo "$input_port" | tr -d '[:space:]')"

    if [[ -z "$input_port" ]]; then
        get_random_port
        return $?
    fi

    if [[ ! "$input_port" =~ ^[0-9]+$ ]] || (( input_port < 1 || input_port > 65535 )); then
        echo -e "${RED}[Error] 端口必须是 1-65535 之间的整数。${NC}" >&2
        return 1
    fi

    if is_port_in_use "$input_port"; then
        echo -e "${YELLOW}[Warn] 端口 $input_port 当前已被占用，如果是覆盖重装则将继续。${NC}" >&2
    fi

    echo "$input_port"
}

get_public_ip() {
    local ip=""
    ip=$(curl -fsS -4 --max-time 3 ipv4.ip.sb 2>/dev/null \
        || curl -fsS -4 --max-time 3 api.ipify.org 2>/dev/null \
        || curl -fsS -4 --max-time 3 ifconfig.me 2>/dev/null \
        || true)

    if [[ -z "$ip" ]]; then
        ip=$(curl -fsS -6 --max-time 3 ipv6.ip.sb 2>/dev/null \
            || curl -fsS -6 --max-time 3 api64.ipify.org 2>/dev/null \
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

open_firewall_port() {
    local port="$1"
    local proto="${2:-tcp}"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port/$proto" &>/dev/null || true
    fi

    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$port/$proto" &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    fi
}

restart_and_verify_service() {
    local svc="$1"
    systemctl daemon-reload
    systemctl enable "$svc" &>/dev/null
    systemctl restart "$svc"
    sleep 1

    if ! systemctl is-active --quiet "$svc"; then
        echo -e "${RED}[Error] 服务 $svc 启动失败，最近日志如下:${NC}"
        journalctl -u "$svc" -n 20 --no-pager 2>/dev/null || true
        return 1
    fi
    return 0
}

base64_encode_oneline() {
    printf '%s' "$1" | base64 | tr -d '\r\n'
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
        -keyout "$cert_dir/key.pem" \
        -out "$cert_dir/cert.pem" \
        -subj "/CN=$domain" \
        -addext "subjectAltName=${san}" &>/dev/null
}

issue_acme_cert() {
    local cert_dir="$1"
    local domain="$2"

    if [[ -s "$cert_dir/cert.pem" && -s "$cert_dir/key.pem" ]]; then
        echo -e "${GREEN}[OK]${NC} 检测到 ${domain} 已有正式证书，直接复用。"
        return 0
    fi

    if is_port_in_use 80; then
        echo -e "${RED}[Error] 80 端口已被占用，无法使用 acme.sh standalone 模式申请证书。${NC}" >&2
        return 1
    fi

    if ! command -v socat &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            run_with_spinner "正在安装证书申请依赖 socat/cron (请勿中断)" \
                env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq socat cron || true
        elif command -v dnf &>/dev/null; then
            run_with_spinner "正在安装证书申请依赖 socat/cronie" \
                dnf install -y -q socat cronie || true
        elif command -v yum &>/dev/null; then
            run_with_spinner "正在安装证书申请依赖 socat/cronie" \
                yum install -y -q socat cronie || true
        fi
    fi

    local acme_bin="/root/.acme.sh/acme.sh"
    if [[ ! -x "$acme_bin" ]]; then
        echo -e "${CYAN}[Info]${NC} 正在安装 acme.sh..."
        curl -fsSL --connect-timeout 10 --max-time 45 https://get.acme.sh | sh -s email="nexus@${domain}" || {
            echo -e "${RED}[Error] acme.sh 安装失败，请检查网络到 get.acme.sh 的连通性。${NC}" >&2
            return 1
        }
    fi

    open_firewall_port 80 "tcp"
    "$acme_bin" --set-default-ca --server letsencrypt &>/dev/null || true
    echo -e "${CYAN}[Info]${NC} 正在向 Let's Encrypt 申请 ${domain} 的正式证书..."
    local acme_rc=0
    "$acme_bin" --issue -d "$domain" --standalone --keylength ec-256 || acme_rc=$?
    # acme.sh 返回 2 表示证书仍在有效期内无需重复签发
    if [[ $acme_rc -ne 0 && $acme_rc -ne 2 ]]; then
        echo -e "${RED}[Error] 证书申请失败！请确认域名已解析到本机 IP 且未开启 CF 小黄云（申请时需灰云）。${NC}" >&2
        return 1
    fi

    mkdir -p "$cert_dir"
    if ! "$acme_bin" --install-cert -d "$domain" --ecc \
        --fullchain-file "$cert_dir/cert.pem" \
        --key-file "$cert_dir/key.pem" \
        --reloadcmd "systemctl restart nexus-xray 2>/dev/null || true; systemctl restart nexus-singbox 2>/dev/null || true"; then
        echo -e "${RED}[Error] 安装证书文件失败。${NC}" >&2
        return 1
    fi
}

prompt_required_domain() {
    local pub_ip="$1"
    read -p " └─ 绑定自有域名 (例如 node.example.com): " input_domain
    input_domain="$(echo "${input_domain:-}" | tr -d '[:space:]')"
    if [[ -z "$input_domain" ]]; then
        echo -e "${RED}[Error] 该协议必须绑定自有域名。${NC}" >&2
        return 1
    fi
    TLS_DOMAIN="$(get_target_sni "$input_domain")" || return 1

    DOMAIN_IS_CF=0
    local rc=0
    check_domain_direct_status "$TLS_DOMAIN" "$pub_ip" || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo -e "${GREEN}[Info]${NC} 域名检测: ${GREEN}直连本机 (灰云)${NC}，支持任意端口与自动申请 Let's Encrypt 证书。"
        DOMAIN_IS_CF=0
    elif [[ $rc -eq 1 ]]; then
        echo -e "${YELLOW}[Info]${NC} 域名检测: ${YELLOW}指向非本机 IP (疑似已开 CF 小黄云 CDN)${NC}，将自动匹配 CF HTTPS 端口。"
        DOMAIN_IS_CF=1
    else
        echo -e "${YELLOW}[Warn]${NC} 域名暂未解析出 IP，请确认已在 DNS 面板配置 A 记录。"
        DOMAIN_IS_CF=2
    fi
}

prompt_cert_for_domain() {
    local cert_dir="$1"
    local domain="$2"
    local is_cf="${3:-0}"
    local domain_cert_dir="${cert_dir}/${domain}"

    if [[ -s "${domain_cert_dir}/cert.pem" && -s "${domain_cert_dir}/key.pem" ]]; then
        echo -e "${GREEN}[OK]${NC} 检测到 ${domain} 已有 Let's Encrypt 正式证书，直接复用。"
        TLS_CERT_FILE="${domain_cert_dir}/cert.pem"
        TLS_KEY_FILE="${domain_cert_dir}/key.pem"
        TLS_INSECURE=0
        TLS_CERT_SHA256=""
        return 0
    fi

    if [[ "$is_cf" -eq 1 ]]; then
        echo -e "${CYAN}[Info]${NC} CDN 模式：正在自动生成回源 ECC 自签证书 (请确保 CF SSL/TLS 为 Full 模式)..."
        local local_pub_ip
        local_pub_ip="$(get_public_ip)"
        if ! generate_self_signed_cert "$domain_cert_dir" "$domain" "$local_pub_ip"; then
            echo -e "${RED}[Error] 生成自签证书失败。${NC}" >&2
            return 1
        fi
        TLS_CERT_FILE="${domain_cert_dir}/cert.pem"
        TLS_KEY_FILE="${domain_cert_dir}/key.pem"
        # 客户端连接 CF 边缘节点使用 CF 公共证书，无需 allowInsecure
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

prompt_tls_cert() {
    local cert_dir="$1"
    local mode="${2:-optional}"

    if [[ "$mode" == "required" ]]; then
        read -p " └─ 绑定自有域名 (例如 node.example.com): " input_domain
        input_domain="$(echo "${input_domain:-}" | tr -d '[:space:]')"
        if [[ -z "$input_domain" ]]; then
            echo -e "${RED}[Error] 该协议必须绑定已解析到本机的自有域名。${NC}" >&2
            return 1
        fi
    else
        read -p " └─ 绑定域名 / SNI (留空自动优选并自签): " input_domain
        input_domain="$(echo "${input_domain:-}" | tr -d '[:space:]')"
    fi

    if [[ -z "$input_domain" ]]; then
        TLS_DOMAIN="$(get_target_sni "")" || return 1
        echo -e "${CYAN}[Info]${NC} 正在生成 ECC 自签证书 ($TLS_DOMAIN)..."
        local local_pub_ip
        local_pub_ip="$(get_public_ip)"
        if ! generate_self_signed_cert "$cert_dir" "$TLS_DOMAIN" "$local_pub_ip"; then
            echo -e "${RED}[Error] 生成自签证书失败。${NC}" >&2
            return 1
        fi
        TLS_CERT_FILE="$cert_dir/cert.pem"
        TLS_KEY_FILE="$cert_dir/key.pem"
        TLS_INSECURE=1
        TLS_CERT_SHA256="$(openssl x509 -in "$TLS_CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print $2}' | tr -d ':\r\n' | tr 'A-F' 'a-f')"
        return 0
    fi

    TLS_DOMAIN="$(get_target_sni "$input_domain")" || return 1
    echo "    证书获取方式:"
    echo "      1. 自动申请 Let's Encrypt 正式证书 (推荐，需已解析到本机且暂时灰云)"
    echo "      2. 自动生成自签证书 (适合已开 CF 小黄云且 SSL 为 Full 模式)"
    echo "      3. 手动输入已有证书路径"
    read -p " └─ 请选择 [1-3] (默认 1): " cert_mode
    cert_mode="${cert_mode:-1}"

    case "$cert_mode" in
        1)
            local domain_cert_dir="${cert_dir}/${TLS_DOMAIN}"
            issue_acme_cert "$domain_cert_dir" "$TLS_DOMAIN" || return 1
            TLS_CERT_FILE="${domain_cert_dir}/cert.pem"
            TLS_KEY_FILE="${domain_cert_dir}/key.pem"
            TLS_INSECURE=0
            TLS_CERT_SHA256=""
            ;;
        2)
            echo -e "${CYAN}[Info]${NC} 正在生成 ECC 自签证书 ($TLS_DOMAIN)..."
            local local_pub_ip
            local_pub_ip="$(get_public_ip)"
            if ! generate_self_signed_cert "$cert_dir" "$TLS_DOMAIN" "$local_pub_ip"; then
                echo -e "${RED}[Error] 生成自签证书失败。${NC}" >&2
                return 1
            fi
            TLS_CERT_FILE="$cert_dir/cert.pem"
            TLS_KEY_FILE="$cert_dir/key.pem"
            TLS_INSECURE=1
            TLS_CERT_SHA256="$(openssl x509 -in "$TLS_CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print $2}' | tr -d ':\r\n' | tr 'A-F' 'a-f')"
            ;;
        3)
            read -p " └─ TLS 公钥证书路径: " input_cert
            read -p " └─ TLS 私钥路径: " input_key
            input_cert="$(echo "${input_cert:-}" | tr -d '[:space:]')"
            input_key="$(echo "${input_key:-}" | tr -d '[:space:]')"
            if [[ ! -f "$input_cert" || ! -f "$input_key" ]]; then
                echo -e "${RED}[Error] 证书或私钥文件不存在。${NC}" >&2
                return 1
            fi
            TLS_CERT_FILE="$input_cert"
            TLS_KEY_FILE="$input_key"
            TLS_INSECURE=0
            TLS_CERT_SHA256=""
            ;;
        *)
            echo -e "${RED}[Error] 无效选项。${NC}" >&2
            return 1
            ;;
    esac
}
