#!/usr/bin/env bash
# ==============================================================================
# NexusNode Seamless Node Migration (Preserve UUID / Reality PrivateKey / Ports)
# ==============================================================================

migrate_export() {
    local out_file="${1:-/root/nexusnode-migration-backup.tar.gz}"
    run_step "打包当前节点配置与密钥对至 ${out_file}" "
        tar -czf ${out_file} -C / etc/nexusnode
    "
    ui_ok "备份包已生成: ${out_file}"
    ui_info "在新服务器安装 NexusNode 后执行: nexus migrate import ${out_file}"
}

migrate_import() {
    local in_file="$1"
    if [[ ! -f "$in_file" ]]; then
        ui_err "找不到备份文件: $in_file"
        return 1
    fi
    run_step "恢复节点密钥、UUID 与端口配置" "
        tar -xzf ${in_file} -C / && chown -R ${NEXUS_USER}:${NEXUS_USER} ${NEXUS_DIR}
    "
    run_doctor "true"
    ui_ok "节点配置已无缝恢复！客户端仅需将服务器 IP 修改为新机器 IP 即可直接连接。"
}

migrate_push() {
    local target_ssh="$1"
    local ssh_port="${2:-22}"
    if [[ -z "$target_ssh" ]]; then
        ui_ask "目标服务器 SSH 地址 (如 root@1.2.3.4)" "" target_ssh
        ui_ask "目标服务器 SSH 端口" "22" ssh_port
    fi
    local tmp_tar="/tmp/nexus_migrate_$$.tar.gz"
    migrate_export "$tmp_tar"

    ui_info "正在通过 SSH 推送配置并自动在新服务器拉起服务 (请根据提示输入目标机器密码)..."
    scp -P "$ssh_port" "$tmp_tar" "${target_ssh}:/tmp/nexus_migrate.tar.gz" && \
    ssh -p "$ssh_port" "$target_ssh" "mkdir -p /etc/nexusnode && tar -xzf /tmp/nexus_migrate.tar.gz -C / && rm -f /tmp/nexus_migrate.tar.gz"
    rm -f "$tmp_tar"
    ui_ok "已成功推送至 ${target_ssh}！"
}
