#!/usr/bin/env bash
# ==============================================================================
# NexusNode v2.0 - Main CLI & TUI Entrypoint
# Supports both Non-Interactive CLI (`nexus add ...`) & Clean Dual-Layer TUI
# ==============================================================================

set -o pipefail

SOURCE_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
[[ ! -d "${SCRIPT_DIR}/lib" && -d "/opt/NexusNode/lib" ]] && SCRIPT_DIR="/opt/NexusNode"
source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/env.sh"
source "${SCRIPT_DIR}/lib/net.sh"
source "${SCRIPT_DIR}/modules/warp.sh"
source "${SCRIPT_DIR}/modules/doctor.sh"
source "${SCRIPT_DIR}/modules/migrate.sh"
source "${SCRIPT_DIR}/core/xray.sh"
source "${SCRIPT_DIR}/core/singbox.sh"

export NON_INTERACTIVE="false"

show_all_links() {
    printf "\n${C_CYAN}╭── 当前已部署节点订阅链接汇总 ────────────────────────────╮${C_RESET}\n"
    if ls "${NEXUS_DIR}/links/"*.txt >/dev/null 2>&1; then
        for f in "${NEXUS_DIR}/links/"*.txt; do
            printf "${C_GREEN}• (%s):${C_RESET}\n%s\n\n" "$(basename "$f" .txt)" "$(cat "$f")"
        done
    else
        ui_warn "当前尚未部署任何节点。"
    fi
    printf "${C_CYAN}╰──────────────────────────────────────────────────────────╯${C_RESET}\n"
}

show_service_logs() {
    printf "\n${C_CYAN}── 服务状态与最近日志 ──${C_RESET}\n"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        for svc in nexus-xray nexus-singbox nexus-warp; do
            if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
                ui_ok "${svc}: 运行中"
            else
                ui_warn "${svc}: 未运行"
            fi
        done
        echo ""
        local svc_pick
        ui_ask "查看日志的服务 (xray / singbox / warp / 回车跳过)" "" svc_pick
        case "$svc_pick" in
            xray)    journalctl -u nexus-xray -n 30 --no-pager 2>/dev/null || true ;;
            singbox) journalctl -u nexus-singbox -n 30 --no-pager 2>/dev/null || true ;;
            warp)    journalctl -u nexus-warp -n 30 --no-pager 2>/dev/null || true ;;
        esac
    else
        for svc in nexus-xray nexus-singbox nexus-warp; do
            rc-service "$svc" status 2>/dev/null || true
        done
    fi
}

uninstall_core() {
    local target="$1"
    case "$target" in
        xray)
            run_step "卸载 Xray-core 服务、配置与节点链接" "
                service_ctl stop nexus-xray;
                service_ctl disable nexus-xray;
                rm -f /etc/systemd/system/nexus-xray.service /etc/init.d/nexus-xray;
                systemctl daemon-reload 2>/dev/null || true;
                rm -rf ${NEXUS_DIR}/xray ${NEXUS_DIR}/links/xray_*.txt
            "
            ui_ok "Xray-core 已单独卸载清理。"
            ;;
        singbox)
            run_step "卸载 sing-box 服务、配置与端口跳跃规则" "
                service_ctl stop nexus-singbox;
                service_ctl disable nexus-singbox;
                rm -f /etc/systemd/system/nexus-singbox.service /etc/init.d/nexus-singbox;
                systemctl daemon-reload 2>/dev/null || true;
                nft delete table inet nexus_hop 2>/dev/null || true;
                rm -rf ${NEXUS_DIR}/sing-box ${NEXUS_DIR}/links/singbox_*.txt
            "
            ui_ok "sing-box 已单独卸载清理。"
            ;;
        *)
            ui_err "未知内核: ${target} (可选: xray | singbox)"
            return 1
            ;;
    esac
}

manage_nodes_menu() {
    while true; do
        ui_header
        printf "  ${C_BOLD}[已部署节点链接与卸载管理]${C_RESET}\n\n"
        local files=()
        if ls "${NEXUS_DIR}/links/"*.txt >/dev/null 2>&1; then
            local idx=1
            for f in "${NEXUS_DIR}/links/"*.txt; do
                files+=("$f")
                printf "  ${C_GREEN}%d.${C_RESET} ${C_BOLD}%s${C_RESET}\n     ${C_CYAN}%s${C_RESET}\n\n" "$idx" "$(basename "$f" .txt)" "$(cat "$f")"
                ((idx++))
            done
        else
            ui_warn "当前尚未部署任何节点。"
            echo ""
        fi

        printf "  ${C_GRAY}────────────────────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_CYAN}d.${C_RESET} 删除指定编号的协议节点    ${C_CYAN}x.${C_RESET} 单独卸载 Xray-core\n"
        printf "  ${C_CYAN}s.${C_RESET} 单独卸载 sing-box         ${C_CYAN}0.${C_RESET} 返回主菜单\n\n"

        local act
        ui_ask "请选择操作" "0" act
        case "$act" in
            d|D)
                if [[ ${#files[@]} -eq 0 ]]; then
                    ui_warn "没有可删除的节点。"
                    sleep 1
                    continue
                fi
                local del_idx
                ui_ask "输入要删除的节点编号 [1-${#files[@]}]" "1" del_idx
                if [[ "$del_idx" =~ ^[0-9]+$ ]] && (( del_idx >= 1 && del_idx <= ${#files[@]} )); then
                    local target_file="${files[$((del_idx - 1))]}"
                    local base_name
                    base_name="$(basename "$target_file" .txt)"
                    if [[ "$base_name" == xray_* ]]; then
                        uninstall_core "xray"
                    elif [[ "$base_name" == singbox_* ]]; then
                        uninstall_core "singbox"
                    else
                        rm -f "$target_file"
                        ui_ok "已删除 ${base_name}"
                    fi
                else
                    ui_warn "编号无效。"
                fi
                sleep 1
                ;;
            x|X)
                uninstall_core "xray"
                sleep 1
                ;;
            s|S)
                uninstall_core "singbox"
                sleep 1
                ;;
            0)
                return
                ;;
            *)
                ui_warn "无效选项"
                sleep 1
                ;;
        esac
    done
}

uninstall_all() {
    run_step "停止并清理所有 NexusNode 守护服务与配置" "
        service_ctl stop nexus-xray;
        service_ctl stop nexus-singbox;
        service_ctl stop nexus-warp;
        rm -f /etc/systemd/system/nexus-*.service /etc/init.d/nexus-*;
        systemctl daemon-reload 2>/dev/null || true;
        nft delete table inet nexus_hop 2>/dev/null || true;
        rm -rf ${NEXUS_DIR} ${NEXUS_BIN}/xray ${NEXUS_BIN}/sing-box ${NEXUS_BIN}/wgcf ${NEXUS_BIN}/wireproxy /usr/local/bin/nexus /usr/local/bin/nx
    "
    ui_ok "NexusNode 已彻底卸载干净。"
}

print_cli_help() {
    cat <<EOF
NexusNode v2.0 - 极简零噪多内核代理部署与运维工具

用法:
  nexus / nx                         进入清爽交互式双层 TUI 菜单
  nexus add xray [模式]              部署 Xray (vision | xhttp | tcp-tls | ws-tls | grpc-tls | trojan)
  nexus add singbox [模式]           部署 sing-box (reality | hy2 | tuic | anytls | ss2022 | mixed)
  nexus add hy2                      快捷部署 sing-box Hysteria 2 (支持端口跳跃)
  nexus warp [enable|disable]        一键开启或关闭 Cloudflare WARP AI/流媒体自动分流
  nexus doctor [--fix]               一键诊断时间同步、BBR、UDP缓冲区与服务自愈
  nexus migrate [export|import|push] 节点配置与私钥无缝备份/恢复/SSH跨机推送
  nexus links                        输出当前所有节点分享链接
  nexus rm [xray|singbox]            单独卸载指定内核的服务与配置
  nexus uninstall                    彻底卸载 NexusNode

可选参数 (配合 nexus add 使用):
  --port <端口>                      指定监听端口 (默认自动生成或匹配 CF HTTPS 端口)
  --sni <域名>                       指定伪装 SNI 或自有域名
  --hop <起始:结束>                  指定 Hysteria 2 UDP 端口跳跃范围 (如 30000:40000)
EOF
}

# Parse Non-Interactive CLI Subcommands
handle_cli_args() {
    local subcmd="$1"
    shift || true

    case "$subcmd" in
        add)
            export NON_INTERACTIVE="true"
            local core="${1:-}"
            shift || true
            local mode="" port="" sni="" hop=""

            if [[ "$core" == "xray" ]]; then
                mode="vision"
                if [[ "${1:-}" =~ ^(vision|xhttp|tcp-tls|ws-tls|grpc-tls|trojan)$ ]]; then
                    mode="$1"
                    shift || true
                fi
            elif [[ "$core" == "singbox" ]]; then
                mode="hy2"
                if [[ "${1:-}" =~ ^(reality|hy2|tuic|anytls|ss2022|mixed)$ ]]; then
                    mode="$1"
                    shift || true
                fi
            elif [[ "$core" == "hy2" || "$core" == "hysteria2" ]]; then
                core="singbox"
                mode="hy2"
                hop="30000:40000"
            else
                ui_err "未知核心或协议: ${core} (可选: xray | singbox | hy2)"
                exit 1
            fi

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port) port="${2:-}"; shift 2 ;;
                    --sni)  sni="${2:-}"; shift 2 ;;
                    --hop)  hop="${2:-}"; shift 2 ;;
                    *) shift ;;
                esac
            done

            install_base_deps
            if [[ "$core" == "xray" ]]; then
                deploy_xray_node "$mode" "$port" "$sni"
            else
                deploy_singbox_node "$mode" "$port" "$hop" "$sni"
            fi
            ;;
        warp)
            install_base_deps
            if [[ "${1:-}" == "disable" ]]; then
                disable_warp_outbound
            else
                install_warp_outbound
            fi
            ;;
        doctor)
            run_doctor "true"
            ;;
        migrate)
            local action="${1:-export}"
            shift || true
            case "$action" in
                export) migrate_export "${1:-}" ;;
                import) migrate_import "${1:-}" ;;
                push)   migrate_push "${1:-}" "${2:-}" ;;
            esac
            ;;
        links)
            show_all_links
            ;;
        rm)
            uninstall_core "${1:-}"
            ;;
        uninstall)
            uninstall_all
            ;;
        help|--help|-h)
            print_cli_help
            ;;
        *)
            ui_err "未知子命令: $subcmd"
            print_cli_help
            exit 1
            ;;
    esac
}

# Interactive Dual-Layer TUI Menus
tui_xray_menu() {
    ui_header
    printf "  ${C_BOLD}[Xray-core 协议部署]${C_RESET}\n\n"
    printf "  ${C_CYAN}1.${C_RESET} VLESS - XTLS-Reality   ${C_GRAY}(免域名首选，借壳大厂防探测)${C_RESET}\n"
    printf "  ${C_CYAN}2.${C_RESET} VLESS - XHTTP+Reality  ${C_GRAY}(新一代抗 DPI，免域名直连)${C_RESET}\n"
    printf "  ${C_CYAN}3.${C_RESET} VLESS - TCP+TLS+Vision ${C_GRAY}(需自有域名，灰云直连最强)${C_RESET}\n"
    printf "  ${C_CYAN}4.${C_RESET} VLESS - WS + TLS       ${C_GRAY}(需自有域名，支持 CF 小黄云/优选 IP)${C_RESET}\n"
    printf "  ${C_CYAN}5.${C_RESET} VLESS - gRPC + TLS     ${C_GRAY}(需自有域名，支持 CF 小黄云)${C_RESET}\n"
    printf "  ${C_CYAN}6.${C_RESET} Trojan - gRPC / TLS    ${C_GRAY}(需自有域名，gRPC 支持 CDN)${C_RESET}\n"
    printf "  ${C_CYAN}0.${C_RESET} 返回主菜单\n\n"
    local choice
    ui_ask "请选择协议" "1" choice
    case "$choice" in
        1) install_base_deps && deploy_xray_node "vision" ;;
        2) install_base_deps && deploy_xray_node "xhttp" ;;
        3) install_base_deps && deploy_xray_node "tcp-tls" ;;
        4) install_base_deps && deploy_xray_node "ws-tls" ;;
        5) install_base_deps && deploy_xray_node "grpc-tls" ;;
        6) install_base_deps && deploy_xray_node "trojan" ;;
        0) return ;;
        *) ui_warn "无效选项" ;;
    esac
    read -rp "按回车键返回主菜单..." _
}

tui_singbox_menu() {
    ui_header
    printf "  ${C_BOLD}[sing-box 协议部署]${C_RESET}\n\n"
    printf "  ${C_CYAN}1.${C_RESET} VLESS - XTLS-Reality   ${C_GRAY}(高性能 Reality 主力)${C_RESET}\n"
    printf "  ${C_CYAN}2.${C_RESET} Hysteria 2 (Hy2)       ${C_GRAY}(晚高峰加速 + 端口跳跃 + pinSHA256)${C_RESET}\n"
    printf "  ${C_CYAN}3.${C_RESET} TUIC v5                ${C_GRAY}(极致低时延 QUIC 协议)${C_RESET}\n"
    printf "  ${C_CYAN}4.${C_RESET} AnyTLS                 ${C_GRAY}(新一代抗 TLS-in-TLS 指纹)${C_RESET}\n"
    printf "  ${C_CYAN}5.${C_RESET} Shadowsocks-2022       ${C_GRAY}(弱协议，低 CPU 开销转发)${C_RESET}\n"
    printf "  ${C_CYAN}6.${C_RESET} SOCKS5 / HTTP          ${C_GRAY}(单端口双协议账号代理)${C_RESET}\n"
    printf "  ${C_CYAN}0.${C_RESET} 返回主菜单\n\n"
    local choice
    ui_ask "请选择协议" "2" choice
    case "$choice" in
        1) install_base_deps && deploy_singbox_node "reality" ;;
        2) install_base_deps && deploy_singbox_node "hy2" ;;
        3) install_base_deps && deploy_singbox_node "tuic" ;;
        4) install_base_deps && deploy_singbox_node "anytls" ;;
        5) install_base_deps && deploy_singbox_node "ss2022" ;;
        6) install_base_deps && deploy_singbox_node "mixed" ;;
        0) return ;;
        *) ui_warn "无效选项" ;;
    esac
    read -rp "按回车键返回主菜单..." _
}

tui_ops_menu() {
    ui_header
    printf "  ${C_BOLD}[进阶分流、自愈诊断与无缝迁移]${C_RESET}\n\n"
    printf "  ${C_CYAN}1.${C_RESET} 开启 Cloudflare WARP 分流  ${C_GRAY}(自动解锁 ChatGPT / Claude / Netflix)${C_RESET}\n"
    printf "  ${C_CYAN}2.${C_RESET} 关闭 Cloudflare WARP 分流\n"
    printf "  ${C_CYAN}3.${C_RESET} 运行 Doctor 一键诊断自愈   ${C_GRAY}(校准时间同步 / 开启BBR / 调优UDP缓冲)${C_RESET}\n"
    printf "  ${C_CYAN}4.${C_RESET} 查看服务状态与运行日志\n"
    printf "  ${C_CYAN}5.${C_RESET} 导出节点备份包 (Migrate Export)\n"
    printf "  ${C_CYAN}6.${C_RESET} 通过 SSH 一键推送节点至新机 (Migrate Push)\n"
    printf "  ${C_CYAN}0.${C_RESET} 返回主菜单\n\n"
    local choice
    ui_ask "请选择操作" "3" choice
    case "$choice" in
        1) install_base_deps && install_warp_outbound ;;
        2) disable_warp_outbound ;;
        3) run_doctor "true" ;;
        4) show_service_logs ;;
        5) migrate_export ;;
        6) migrate_push ;;
        0) return ;;
        *) ui_warn "无效选项" ;;
    esac
    read -rp "按回车键返回主菜单..." _
}

main_tui() {
    while true; do
        ui_header
        printf "  ${C_CYAN}1.${C_RESET} 部署 ${C_BOLD}Xray-core${C_RESET} 节点       ${C_GRAY}(Reality / XHTTP / TCP-Vision / WS / gRPC / Trojan)${C_RESET}\n"
        printf "  ${C_CYAN}2.${C_RESET} 部署 ${C_BOLD}sing-box${C_RESET} 节点        ${C_GRAY}(Reality / Hy2+跳跃 / TUIC / AnyTLS / SS2022 / Mixed)${C_RESET}\n"
        printf "  ${C_CYAN}3.${C_RESET} 进阶工具箱                ${C_GRAY}(WARP 分流 / Doctor 自愈 / 日志 / 无缝迁移)${C_RESET}\n"
        printf "  ${C_CYAN}4.${C_RESET} 查看与删除节点 / 单内核卸载\n"
        printf "  ${C_CYAN}9.${C_RESET} 彻底卸载 NexusNode\n"
        printf "  ${C_CYAN}0.${C_RESET} 退出脚本\n\n"

        local choice
        ui_ask "请输入编号" "1" choice
        case "$choice" in
            1) tui_xray_menu ;;
            2) tui_singbox_menu ;;
            3) tui_ops_menu ;;
            4) manage_nodes_menu ;;
            9) uninstall_all; exit 0 ;;
            0) exit 0 ;;
            *) ui_warn "无效选项" ; sleep 1 ;;
        esac
    done
}

# Bootstrap shortcut commands `nexus` & `nx`
ln -sf "${SCRIPT_DIR}/nexus.sh" /usr/local/bin/nexus 2>/dev/null || true
ln -sf "${SCRIPT_DIR}/nexus.sh" /usr/local/bin/nx 2>/dev/null || true

detect_environment
if [[ $# -gt 0 ]]; then
    handle_cli_args "$@"
else
    main_tui
fi
