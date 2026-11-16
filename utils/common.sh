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
        apt-get update -qq && apt-get install -y -qq curl openssl gawk coreutils iproute2 systemd >/dev/null
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

    if is_port_in_use 80; then
        echo -e "${RED}[Error] 80 端口已被占用，无法使用 acme.sh standalone 模式申请证书。${NC}" >&2
        return 1
    fi

    if ! command -v socat &>/dev/null; then
        echo -e "${CYAN}[Info]${NC} 正在安装证书申请依赖 socat..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq socat >/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf install -y -q socat >/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y -q socat >/dev/null || true
        fi
    fi

    local acme_bin="/root/.acme.sh/acme.sh"
    if [[ ! -x "$acme_bin" ]]; then
        echo -e "${CYAN}[Info]${NC} 正在安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="nexus@${domain}" >/dev/null || {
            echo -e "${RED}[Error] acme.sh 安装失败。${NC}" >&2
            return 1
        }
    fi

    open_firewall_port 80 "tcp"
    "$acme_bin" --set-default-ca --server letsencrypt &>/dev/null || true
    echo -e "${CYAN}[Info]${NC} 正在向 Let's Encrypt 申请 ${domain} 的正式证书..."
    if ! "$acme_bin" --issue -d "$domain" --standalone --keylength ec-256; then
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

prompt_tls_cert() {
    local cert_dir="$1"

    read -p " └─ 绑定域名 / SNI (留空自动优选并自签): " input_domain
    input_domain="$(echo "${input_domain:-}" | tr -d '[:space:]')"
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
