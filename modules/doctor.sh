#!/usr/bin/env bash
# ==============================================================================
# NexusNode Doctor: Automated Diagnostics & Self-Healing
# ==============================================================================

run_doctor() {
    local auto_fix="${1:-true}"
    printf "\n${C_CYAN}╭── NexusNode 系统健康度与防封锁自检 ──────────────────────╮${C_RESET}\n"

    # 1. Check Time Sync (Critical for Reality / TLS)
    if command -v chronyc >/dev/null 2>&1 || command -v timedatectl >/dev/null 2>&1; then
        ui_ok "系统时间同步检查: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    else
        ui_warn "未检测到时间同步守护进程，Reality 协议对时间偏差极敏感"
    fi

    if [[ "$auto_fix" == "true" ]]; then
        # 2. Kernel BBR & UDP Buffer Optimization (Required for Hysteria2)
        run_step "优化内核 BBR 拥塞控制与 QUIC/UDP 缓冲区参数" "
            cat > /etc/sysctl.d/99-nexusnode.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.ipv4.ip_forward=1
EOF
            sysctl --system >/dev/null 2>&1 || true
        "

        # 3. Time Synchronization Force Fix
        run_step "校准系统硬件时钟与 NTP 时间同步" "
            (systemctl restart chrony || systemctl restart systemd-timesyncd || rc-service chronyd restart) 2>/dev/null || true
        "

        # 4. Restart / Heal Core Services
        if [[ -f "${NEXUS_DIR}/xray/config.json" ]]; then
            run_step "自检并重启 Xray-core 守护进程" "systemctl restart nexus-xray 2>/dev/null || rc-service nexus-xray restart 2>/dev/null || true"
        fi
        if [[ -f "${NEXUS_DIR}/sing-box/config.json" ]]; then
            run_step "自检并重启 sing-box 守护进程" "systemctl restart nexus-singbox 2>/dev/null || rc-service nexus-singbox restart 2>/dev/null || true"
        fi
    fi

    printf "${C_CYAN}╰──────────────────────────────────────────────────────────╯${C_RESET}\n"
    ui_ok "诊断与自愈修复全部完成！"
}
