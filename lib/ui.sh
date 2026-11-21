#!/usr/bin/env bash
# ==============================================================================
# NexusNode UI & Silent Task Engine (Zero-Noise TUI)
# ==============================================================================

export NEXUS_LOG="/var/log/nexusnode/install.log"
mkdir -p "$(dirname "$NEXUS_LOG")" 2>/dev/null || export NEXUS_LOG="/tmp/nexusnode_install.log"

# Colors & ANSI Escapes
readonly C_RESET="\033[0m"
readonly C_BOLD="\033[1m"
readonly C_DIM="\033[2m"
readonly C_CYAN="\033[38;5;51m"
readonly C_GREEN="\033[38;5;46m"
readonly C_YELLOW="\033[38;5;226m"
readonly C_RED="\033[38;5;196m"
readonly C_GRAY="\033[38;5;245m"
readonly C_PURPLE="\033[38;5;141m"
readonly C_CLEAR_LINE="\r\033[K"

ui_info()  { printf "${C_CYAN}ℹ${C_RESET} %s\n" "$1"; }
ui_ok()    { printf "${C_GREEN}✔${C_RESET} %s\n" "$1"; }
ui_warn()  { printf "${C_YELLOW}⚠${C_RESET} %s\n" "$1"; }
ui_err()   { printf "${C_RED}✖${C_RESET} %s\n" "$1"; }

# Silent Task Runner with Braille Spinner
# Usage: run_step "Installing dependencies..." "apt-get update && apt-get install -y curl jq"
run_step() {
    local msg="$1"
    local cmd="$2"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local pid i=0

    echo -e "\n--- [$(date '+%F %T')] EXEC: $cmd ---" >> "$NEXUS_LOG"
    bash -c "$cmd" >> "$NEXUS_LOG" 2>&1 &
    pid=$!

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "${C_CLEAR_LINE}${C_CYAN}%s${C_RESET} %s" "${frames[i]}" "$msg"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.08
    done
    wait "$pid"
    local exit_code=$?
    tput cnorm 2>/dev/null || true

    if [[ $exit_code -eq 0 ]]; then
        printf "${C_CLEAR_LINE}${C_GREEN}✔${C_RESET} %s\n" "$msg"
        return 0
    else
        printf "${C_CLEAR_LINE}${C_RED}✖${C_RESET} %s ${C_DIM}(失败，退出码: %d)${C_RESET}\n" "$msg" "$exit_code"
        printf "${C_YELLOW}┌── 错误日志摘要 (%s) ──────────────────────────${C_RESET}\n" "$NEXUS_LOG"
        tail -n 12 "$NEXUS_LOG" | sed 's/^/│ /'
        printf "${C_YELLOW}└─────────────────────────────────────────────────────────────${C_RESET}\n"
        return $exit_code
    fi
}

# Clean Prompt Input with Default/Random Label
# Usage: ui_ask "监听端口" "443" PORT_VAR [默认|随机]
ui_ask() {
    local prompt_text="$1"
    local default_val="$2"
    local __resultvar="$3"
    local tag="${4:-默认}"
    local input_val=""

    if [[ -n "$default_val" ]]; then
        printf "${C_PURPLE}❯${C_RESET} %s ${C_GRAY}[%s: %s]${C_RESET}: " "$prompt_text" "$tag" "$default_val"
    else
        printf "${C_PURPLE}❯${C_RESET} %s: " "$prompt_text"
    fi
    read -r input_val
    if [[ -z "$input_val" ]]; then
        input_val="$default_val"
    fi
    # Move cursor up 1 line and overwrite with clean confirmed summary
    printf "\033[1A${C_CLEAR_LINE}${C_GREEN}✔${C_RESET} %s: ${C_BOLD}%s${C_RESET}\n" "$prompt_text" "$input_val"
    eval "$__resultvar=\"\$input_val\""
}

# Compute terminal display width (strips ANSI escapes, counts CJK as 2 cols)
display_width() {
    local plain
    plain=$(printf '%b' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g')
    if command -v wc >/dev/null 2>&1 && wc -L </dev/null >/dev/null 2>&1; then
        printf '%s' "$plain" | wc -L
    else
        printf '%s' "${#plain}"
    fi
}

ui_box_line() {
    local content="$1"
    local inner_width=58
    local w pad
    w=$(display_width "$content")
    pad=$(( inner_width - w ))
    (( pad < 0 )) && pad=0
    printf "${C_CYAN}│${C_RESET}%b%*s${C_CYAN}│${C_RESET}\n" "$content" "$pad" ""
}

svc_status_badge() {
    local svc="$1"
    if (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "${svc}.service" 2>/dev/null) || \
       (command -v rc-service >/dev/null 2>&1 && rc-service "$svc" status >/dev/null 2>&1); then
        printf "${C_GREEN}运行中${C_RESET}"
    else
        printf "${C_GRAY}未启用${C_RESET}"
    fi
}

# Header Banner
ui_header() {
    clear
    local os_info kernel_ver warp_status="未启用" xray_status sb_status
    os_info=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -s)
    os_info="${os_info:0:44}"
    kernel_ver=$(uname -r | cut -d'-' -f1)
    if ss -tlpn 2>/dev/null | grep -q '127.0.0.1:40000'; then
        warp_status="${C_GREEN}已分流 (127.0.0.1:40000)${C_RESET}"
    fi
    xray_status=$(svc_status_badge "nexus-xray")
    sb_status=$(svc_status_badge "nexus-singbox")
    local socks_status="${C_GRAY}未启用${C_RESET}"
    if [[ -f "${NEXUS_DIR:-/etc/nexusnode}/socks_outbound.conf" ]]; then
        local SOCKS_OUT_HOST="" SOCKS_OUT_PORT="" SOCKS_OUT_SCOPE=""
        source "${NEXUS_DIR:-/etc/nexusnode}/socks_outbound.conf" 2>/dev/null || true
        [[ -n "$SOCKS_OUT_HOST" ]] && socks_status="${C_GREEN}${SOCKS_OUT_HOST}:${SOCKS_OUT_PORT} (${SOCKS_OUT_SCOPE:-all})${C_RESET}"
    fi

    printf "${C_CYAN}╭──────────────────────────────────────────────────────────╮${C_RESET}\n"
    ui_box_line "  ${C_BOLD}NexusNode v2.0${C_RESET}  · 极简零噪多内核代理部署与运维引擎"
    printf "${C_CYAN}├──────────────────────────────────────────────────────────┤${C_RESET}\n"
    ui_box_line "  系统环境 : ${os_info}"
    ui_box_line "  内核版本 : $(printf '%-18s' "$kernel_ver") 服务管理 : ${INIT_SYSTEM:-systemd}"
    ui_box_line "  Xray状态 : ${xray_status}             sing-box : ${sb_status}"
    ui_box_line "  WARP状态 : ${warp_status}"
    ui_box_line "  SOCKS出口: ${socks_status}"
    printf "${C_CYAN}╰──────────────────────────────────────────────────────────╯${C_RESET}\n"
}

# Print Node Card
ui_node_card() {
    local title="$1"
    local addr="$2"
    local port="$3"
    local extra="$4"
    local link="$5"

    printf "\n${C_GREEN}╭── 节点部署完成: %-40s ╮${C_RESET}\n" "$title"
    printf "${C_GREEN}│${C_RESET} 服务器地址 : ${C_BOLD}%s${C_RESET}\n" "$addr"
    printf "${C_GREEN}│${C_RESET} 监听端口   : ${C_BOLD}%s${C_RESET}\n" "$port"
    [[ -n "$extra" ]] && printf "${C_GREEN}│${C_RESET} 附加信息   : %s\n" "$extra"
    printf "${C_GREEN}├──────────────────────────────────────────────────────────┤${C_RESET}\n"
    printf "${C_CYAN}%s${C_RESET}\n" "$link"
    printf "${C_GREEN}╰──────────────────────────────────────────────────────────╯${C_RESET}\n\n"
}
