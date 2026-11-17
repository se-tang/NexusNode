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

# Clean Prompt Input with Default Value
# Usage: ui_ask "监听端口" "443" PORT_VAR
ui_ask() {
    local prompt_text="$1"
    local default_val="$2"
    local __resultvar="$3"
    local input_val=""

    printf "${C_PURPLE}❯${C_RESET} %s ${C_GRAY}[默认: %s]${C_RESET}: " "$prompt_text" "$default_val"
    read -r input_val
    if [[ -z "$input_val" ]]; then
        input_val="$default_val"
    fi
    # Move cursor up 1 line and overwrite with clean confirmed summary
    printf "\033[1A${C_CLEAR_LINE}${C_GREEN}✔${C_RESET} %s: ${C_BOLD}%s${C_RESET}\n" "$prompt_text" "$input_val"
    eval "$__resultvar=\"\$input_val\""
}

# Header Banner
ui_header() {
    clear
    local os_info kernel_ver warp_status="未启用"
    os_info=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -s)
    kernel_ver=$(uname -r | cut -d'-' -f1)
    if ss -tlpn 2>/dev/null | grep -q '127.0.0.1:40000'; then
        warp_status="${C_GREEN}已分流 (127.0.0.1:40000)${C_RESET}"
    fi

    printf "${C_CYAN}╭──────────────────────────────────────────────────────────╮${C_RESET}\n"
    printf "${C_CYAN}│${C_RESET}  ${C_BOLD}NexusNode v2.0${C_RESET}  · 极简零噪多内核代理部署与运维引擎      ${C_CYAN}│${C_RESET}\n"
    printf "${C_CYAN}├──────────────────────────────────────────────────────────┤${C_RESET}\n"
    printf "${C_CYAN}│${C_RESET}  系统环境 : %-43s ${C_CYAN}│${C_RESET}\n" "${os_info:0:42}"
    printf "${C_CYAN}│${C_RESET}  内核版本 : %-18s 服务管理 : %-14s ${C_CYAN}│${C_RESET}\n" "$kernel_ver" "${INIT_SYSTEM:-systemd}"
    printf "${C_CYAN}│${C_RESET}  WARP状态 : %-53b ${C_CYAN}│${C_RESET}\n" "$warp_status"
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
