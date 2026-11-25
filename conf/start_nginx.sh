#!/bin/bash
# =============================================================================
# yijiao-nginx-fdfs 容器启动脚本
#
# 环境变量（与原镜像保持一致）：
#   INDEX_URL  首页跳转地址，替换 conf.d/web.conf 中的 /INDEX_URL 占位符
#   SSL_MODE   为 on 时，用 ssl.conf.sample 生成 ssl.conf 并启用 HTTPS
#   SSL_CRT    SSL 证书内容（PEM）
#   SSL_KEY    SSL 私钥内容（PEM）
# =============================================================================

set -e

NGINX_HOME=/usr/local/nginx
CONF_D="${NGINX_HOME}/conf/conf.d"
NGINX_BIN="${NGINX_HOME}/sbin/nginx"

cd "${NGINX_HOME}"

# 替换首页地址占位符（web.conf 由挂载提供时跳过）
if [ -n "${INDEX_URL}" ] && [ -f "${CONF_D}/web.conf" ]; then
    sed -i "s#/INDEX_URL#${INDEX_URL}#g" "${CONF_D}/web.conf"
fi

# 开启 SSL 时，由 ssl.conf.sample 渲染出 ssl.conf
if [ "${SSL_MODE}" = "on" ] && [ -f "${CONF_D}/ssl.conf.sample" ]; then
    envsubst '${SSL_MODE}${SSL_CRT}${SSL_KEY}${INDEX_URL}' \
        < "${CONF_D}/ssl.conf.sample" > "${CONF_D}/ssl.conf"

    # nginx 1.25 起移除了 "ssl on;" 指令，沿用 1.x 老模板会直接启动失败，
    # 这里转换为等价的 listen 443 ssl 形式
    sed -i -E \
        -e '/^[[:space:]]*ssl[[:space:]]+on[[:space:]]*;[[:space:]]*$/d' \
        -e 's/^([[:space:]]*listen[[:space:]]+443)([[:space:]]*;)/\1 ssl\2/' \
        "${CONF_D}/ssl.conf"
fi

# 配置校验失败直接退出，避免容器假启动
"${NGINX_BIN}" -t

exec "${NGINX_BIN}" -g 'daemon off;'
