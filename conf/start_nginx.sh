#!/bin/sh
# =============================================================================
# yijiao-nginx-fdfs 容器启动脚本
# 启动前校验 Nginx 配置，之后以前台（daemon off）方式运行，
# 保证容器生命周期与 Nginx 主进程一致，收到停止信号时能正确退出
# =============================================================================

set -e

NGINX_HOME=/usr/local/nginx
NGINX_BIN="${NGINX_HOME}/sbin/nginx"

# 配置校验失败时直接退出，避免容器假启动后无进程守护
"${NGINX_BIN}" -t

exec "${NGINX_BIN}" -g 'daemon off;'
