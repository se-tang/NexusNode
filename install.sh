#!/usr/bin/env bash

[[ $EUID -ne 0 ]] && echo -e "\033[31m[Error] 请以 Root 权限运行此脚本！\033[0m" && exit 1

REPO_TAR_URL="https://github.com/se-tang/NexusNode/archive/refs/heads/main.tar.gz"
REPO_SHA_URL="https://api.github.com/repos/se-tang/NexusNode/commits/main"
INSTALL_DIR="/opt/NexusNode"
VERSION_FILE="${INSTALL_DIR}/.version"

fetch_remote_sha() {
    curl -fsSL --connect-timeout 3 --max-time 5 -H "Accept: application/vnd.github.sha" "$REPO_SHA_URL" 2>/dev/null | tr -d '[:space:]' || true
}

download_and_exec() {
    local sha="${1:-}"
    if ! command -v curl &>/dev/null || ! command -v tar &>/dev/null; then
        echo -e "\033[31m[Error] 缺少 curl 或 tar，无法自动拉取项目。\033[0m"
        exit 1
    fi
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    if curl -fsSL --connect-timeout 5 --max-time 30 "$REPO_TAR_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1; then
        [[ -n "$sha" ]] && echo "$sha" > "$VERSION_FILE"
        exec bash "$INSTALL_DIR/install.sh" "$@"
    else
        echo -e "\033[31m[Error] 拉取 NexusNode 失败，请检查网络连接。\033[0m"
        exit 1
    fi
}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -z "$DIR" || ! -f "$DIR/utils/common.sh" || ! -f "$DIR/core/xray.sh" || ! -f "$DIR/core/singbox.sh" ]]; then
    local_sha=""
    [[ -f "$VERSION_FILE" ]] && local_sha="$(tr -d '[:space:]' < "$VERSION_FILE")"
    remote_sha="$(fetch_remote_sha)"

    if [[ -f "$INSTALL_DIR/install.sh" && -f "$INSTALL_DIR/utils/common.sh" && -f "$INSTALL_DIR/core/xray.sh" && -f "$INSTALL_DIR/core/singbox.sh" ]]; then
        if [[ -z "$remote_sha" || "$local_sha" == "$remote_sha" ]]; then
            exec bash "$INSTALL_DIR/install.sh" "$@"
        fi
        echo -e "\033[36m[Info] 检测到新版本，正在同步更新 NexusNode...\033[0m"
        download_and_exec "$remote_sha" "$@"
    else
        echo -e "\033[36m[Info] 首次运行，正在拉取 NexusNode 到 ${INSTALL_DIR}...\033[0m"
        download_and_exec "$remote_sha" "$@"
    fi
fi

source "$DIR/utils/common.sh"
source "$DIR/core/xray.sh"
source "$DIR/core/singbox.sh"

check_dependencies || exit 1

install_shortcut() {
    local target="$DIR/install.sh"
    if [[ -w /usr/local/bin ]] && [[ ! -f /usr/local/bin/nx || "$(cat /usr/local/bin/nx 2>/dev/null)" != *"$target"* ]]; then
        cat <<EOF > /usr/local/bin/nx
#!/usr/bin/env bash
exec bash "$target" "\$@"
EOF
        chmod +x /usr/local/bin/nx
    fi
}

install_shortcut

manage_services() {
    echo -e "\n${CYAN}--- 服务状态与卸载管理 ---${NC}"
    echo -n " nexus-xray:    "
    if systemctl is-active --quiet nexus-xray.service 2>/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${YELLOW}未运行${NC}"
    fi

    echo -n " nexus-singbox: "
    if systemctl is-active --quiet nexus-singbox.service 2>/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${YELLOW}未运行${NC}"
    fi

    echo "------------------------------------------"
    echo " 1. 查看 nexus-xray 日志"
    echo " 2. 查看 nexus-singbox 日志"
    echo " 3. 卸载 nexus-xray 服务与配置"
    echo " 4. 卸载 nexus-singbox 服务与配置"
    echo " 0. 返回主菜单"
    read -p " 请选择 [0-4]: " svc_choice

    case "$svc_choice" in
        1)
            journalctl -u nexus-xray.service -n 30 --no-pager || true
            read -p "按回车键继续..."
            ;;
        2)
            journalctl -u nexus-singbox.service -n 30 --no-pager || true
            read -p "按回车键继续..."
            ;;
        3)
            systemctl disable --now nexus-xray.service &>/dev/null || true
            rm -f /etc/systemd/system/nexus-xray.service /usr/local/etc/xray/config.json
            systemctl daemon-reload
            echo -e "${GREEN}[OK] nexus-xray 服务与配置已清理。${NC}"
            sleep 1
            ;;
        4)
            systemctl disable --now nexus-singbox.service &>/dev/null || true
            rm -f /etc/systemd/system/nexus-singbox.service /etc/sing-box/config.json
            systemctl daemon-reload
            echo -e "${GREEN}[OK] nexus-singbox 服务与配置已清理。${NC}"
            sleep 1
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            sleep 1
            ;;
    esac
}

show_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "${CYAN}          NexusNode 智能代理部署工具         ${NC}"
        echo -e "${CYAN}==========================================${NC}"
        echo " 1. Xray-core (稳定成熟，抗封锁首选)"
        echo " 2. sing-box  (新一代多协议，支持 Reality)"
        echo " 3. 服务管理  (查看状态 / 日志 / 卸载)"
        echo " 0. 退出脚本"
        echo "------------------------------------------"
        echo -e " ${CYAN}提示:${NC} 随时在终端输入 ${GREEN}nx${NC} 可快速打开此面板"
        read -p " 请选择 [0-3]: " core_choice

        case "$core_choice" in
            1)
                configure_xray
                read -p "按回车键返回主菜单..."
                ;;
            2)
                configure_singbox
                read -p "按回车键返回主菜单..."
                ;;
            3)
                manage_services
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择${NC}"
                sleep 1
                ;;
        esac
    done
}

show_menu
