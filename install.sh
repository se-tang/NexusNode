#!/usr/bin/env bash
# ==============================================================================
# NexusNode v2.0 One-Key Bootstrap Installer
# ==============================================================================
set -e

[[ $EUID -ne 0 ]] && printf "\033[38;5;196m✖\033[0m 请使用 root 权限运行此脚本 (sudo -i)\n" && exit 1

REPO_TAR_URL="https://github.com/se-tang/NexusNode/archive/refs/heads/main.tar.gz"
REPO_ATOM_URL="https://github.com/se-tang/NexusNode/commits/main.atom"
INSTALL_DIR="/opt/NexusNode"
VERSION_FILE="${INSTALL_DIR}/.version"

fetch_remote_sha() {
    local sha=""
    if command -v git >/dev/null 2>&1; then
        sha="$(git ls-remote https://github.com/se-tang/NexusNode.git refs/heads/main 2>/dev/null | awk '{print $1}' | head -n 1 || true)"
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        sha="$(curl -fsSL --connect-timeout 3 --max-time 5 "$REPO_ATOM_URL" 2>/dev/null | grep -m 1 -oE '[0-9a-f]{40}' || true)"
    fi
    if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$sha"
    fi
}

download_and_exec() {
    local sha="${1:-}"
    shift || true
    if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
        printf "\033[38;5;196m✖\033[0m 缺少 curl 或 tar，无法拉取 NexusNode。\n"
        exit 1
    fi
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    if curl -fsSL --connect-timeout 5 --max-time 30 "$REPO_TAR_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1; then
        [[ -n "$sha" ]] && echo "$sha" > "$VERSION_FILE"
        chmod +x "${INSTALL_DIR}/nexus.sh" "${INSTALL_DIR}/install.sh" 2>/dev/null || true
        ln -sf "${INSTALL_DIR}/nexus.sh" /usr/local/bin/nexus 2>/dev/null || true
        ln -sf "${INSTALL_DIR}/nexus.sh" /usr/local/bin/nx 2>/dev/null || true
        exec bash "${INSTALL_DIR}/nexus.sh" "$@"
    else
        printf "\033[38;5;196m✖\033[0m 拉取 NexusNode 失败，请检查网络连接。\n"
        exit 1
    fi
}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -z "$DIR" || ! -f "$DIR/nexus.sh" || ! -f "$DIR/lib/ui.sh" || ! -f "$DIR/core/xray.sh" || ! -f "$DIR/core/singbox.sh" ]]; then
    local_sha=""
    [[ -f "$VERSION_FILE" ]] && local_sha="$(tr -d '[:space:]' < "$VERSION_FILE")"
    remote_sha="$(fetch_remote_sha)"

    if [[ -f "$INSTALL_DIR/nexus.sh" && -f "$INSTALL_DIR/lib/ui.sh" && -f "$INSTALL_DIR/core/xray.sh" && -f "$INSTALL_DIR/core/singbox.sh" ]]; then
        if [[ -z "$remote_sha" || "$local_sha" == "$remote_sha" ]]; then
            ln -sf "${INSTALL_DIR}/nexus.sh" /usr/local/bin/nexus 2>/dev/null || true
            ln -sf "${INSTALL_DIR}/nexus.sh" /usr/local/bin/nx 2>/dev/null || true
            exec bash "${INSTALL_DIR}/nexus.sh" "$@"
        fi
        printf "\033[38;5;51m⠋\033[0m 检测到新版本，正在同步更新 NexusNode...\n"
        download_and_exec "$remote_sha" "$@"
    else
        printf "\033[38;5;51m⠋\033[0m 首次运行，正在安装 NexusNode v2.0 到 %s...\n" "$INSTALL_DIR"
        download_and_exec "$remote_sha" "$@"
    fi
fi

chmod +x "${DIR}/nexus.sh" 2>/dev/null || true
ln -sf "${DIR}/nexus.sh" /usr/local/bin/nexus 2>/dev/null || true
ln -sf "${DIR}/nexus.sh" /usr/local/bin/nx 2>/dev/null || true
exec bash "${DIR}/nexus.sh" "$@"
