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

# Compute terminal display width reliably across UTF-8 & C/BusyBox locales (ASCII=1, CJK=2)
display_width() {
    local LC_ALL=C
    local plain ascii_only total_bytes ascii_bytes non_ascii_bytes
    plain=$(printf '%b' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g')
    total_bytes=${#plain}
    ascii_only=$(printf '%s' "$plain" | tr -d '\200-\377')
    ascii_bytes=${#ascii_only}
    non_ascii_bytes=$(( total_bytes - ascii_bytes ))
    printf '%s' "$(( ascii_bytes + (non_ascii_bytes * 2 / 3) ))"
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

ui_box_center() {
    local content="$1"
    local inner_width=58
    local w left_pad right_pad
    w=$(display_width "$content")
    left_pad=$(( (inner_width - w) / 2 ))
    (( left_pad < 0 )) && left_pad=0
    right_pad=$(( inner_width - w - left_pad ))
    (( right_pad < 0 )) && right_pad=0
    printf "${C_CYAN}│${C_RESET}%*s%b%*s${C_CYAN}│${C_RESET}\n" "$left_pad" "" "$content" "$right_pad" ""
}

ui_box_kv_row() {
    local l_key="$1" l_val="$2" r_key="$3" r_val="$4"
    local l_val_w l_pad
    l_val_w=$(display_width "$l_val")
    l_pad=$(( 15 - l_val_w ))
    (( l_pad < 0 )) && l_pad=0
    ui_box_line "$(printf '    %s : %b%*s  %s : %b' "$l_key" "$l_val" "$l_pad" "" "$r_key" "$r_val")"
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
    local os_info arch_info kernel_ver warp_status xray_status sb_status socks_status
    os_info=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 \
        | sed -E 's/ GNU\/Linux//; s/^Alpine Linux /Alpine /; s/ \([^)]*\)$//; s/ LTS$//' || uname -s)
    [[ -z "$os_info" ]] && os_info="$(uname -s)"
    (( ${#os_info} > 15 )) && os_info="${os_info:0:15}"

    arch_info="$(uname -m 2>/dev/null || echo unknown)"
    kernel_ver="$(uname -r | cut -d'-' -f1)"
    (( ${#kernel_ver} > 15 )) && kernel_ver="$(printf '%s' "$kernel_ver" | cut -d'+' -f1)"
    (( ${#kernel_ver} > 15 )) && kernel_ver="${kernel_ver:0:15}"

    warp_status="${C_GRAY}未启用${C_RESET}"
    if ss -tlpn 2>/dev/null | grep -q '127.0.0.1:40000'; then
        warp_status="${C_GREEN}已分流 :40000${C_RESET}"
    fi
    xray_status=$(svc_status_badge "nexus-xray")
    sb_status=$(svc_status_badge "nexus-singbox")

    socks_status="${C_GRAY}未启用${C_RESET}"
    if [[ -f "${NEXUS_DIR:-/etc/nexusnode}/socks_outbound.conf" ]]; then
        local SOCKS_OUT_HOST="" SOCKS_OUT_PORT="" SOCKS_OUT_SCOPE=""
        source "${NEXUS_DIR:-/etc/nexusnode}/socks_outbound.conf" 2>/dev/null || true
        if [[ -n "$SOCKS_OUT_HOST" ]]; then
            local socks_addr="${SOCKS_OUT_HOST}:${SOCKS_OUT_PORT}"
            if (( ${#socks_addr} > 13 )); then
                socks_addr="已启用 :${SOCKS_OUT_PORT}"
            fi
            socks_status="${C_GREEN}${socks_addr}${C_RESET}"
        fi
    fi

    printf "${C_CYAN}╭──────────────────────────────────────────────────────────╮${C_RESET}\n"
    ui_box_center "${C_BOLD}NexusNode v2.0${C_RESET} ${C_CYAN}::${C_RESET} 极简零噪多内核代理部署与运维引擎"
    printf "${C_CYAN}├──────────────────────────────────────────────────────────┤${C_RESET}\n"
    ui_box_kv_row "系统环境" "${os_info}"      "系统架构" "${arch_info}"
    ui_box_kv_row "内核版本" "${kernel_ver}"   "服务管理" "${INIT_SYSTEM:-systemd}"
    ui_box_kv_row "Xray状态" "${xray_status}"  "sing-box" "${sb_status}"
    ui_box_kv_row "WARP状态" "${warp_status}"  "代理出口" "${socks_status}"
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
