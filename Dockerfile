# =============================================================================
# yijiao-nginx-fdfs 镜像构建文件
#
# 相对旧版镜像（registry.zwjk.com/yilian/yijiao-nginx-fdfs:init）的升级点：
#   1. 基础系统：CentOS 7（已 EOL）-> Rocky Linux 9.9
#   2. Nginx：1.14.0 -> 1.31.9（源码编译，内嵌 fastdfs-nginx-module）
#   3. 构建方式：单阶段 -> 多阶段构建（builder 编译 / runtime 纯净运行），去掉编译工具链
#   4. 组件来源：外部站点明文 HTTP 下载 -> 随仓库本地 tarball 供给（可离线、可校验）
#
# 组件版本：
#   Nginx          1.31.9
#   FastDFS        5.11（客户端库 libfdfsclient）
#   libfastcommon  1.0.36
#   fastdfs-nginx-module  v1.20（本仓库 src 目录）
#
# 构建命令：
#   podman build --format docker -t nginx-dfs:V1.20.1 .
#   说明：podman 默认的 OCI 镜像格式不保留 HEALTHCHECK，故显式指定 --format docker
# =============================================================================

# -----------------------------------------------------------------------------
# 第一阶段：编译阶段，产出 Nginx 与 FastDFS 客户端库
# -----------------------------------------------------------------------------
FROM quay.io/rockylinux/rockylinux:9 AS builder

LABEL maintainer="plz" \
      org.label-schema.name="nginx-fdfs" \
      org.label-schema.vendor="Fight" \
      org.label-schema.license="GPLv2" \
      org.label-schema.description="Nginx 1.31.9 with fastdfs-nginx-module on Rocky Linux 9"

ENV NGINX_VERSION=1.31.9 \
    FDFS_VERSION=5.11 \
    FASTCOMMON_VERSION=1.0.36 \
    FDFS_MODULE_VERSION=1.20 \
    TZ=Asia/Shanghai

# 国内镜像源加速：Rocky 官方源在国内下载仅几十 KB/s，改用阿里云镜像
# 如需使用官方源，构建时传 --build-arg DNF_MIRROR=
ARG DNF_MIRROR=https://mirrors.aliyun.com/rockylinux
RUN if [ -n "${DNF_MIRROR}" ]; then \
        sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
               -e "s|^#baseurl=http://dl.rockylinux.org/\$contentdir|baseurl=${DNF_MIRROR}|" \
               /etc/yum.repos.d/rocky*.repo; \
    fi

# 编译工具链与依赖库：perl 供 FastDFS 的 make.sh 改写 Makefile 使用，
# pcre2/zlib/openssl-devel 分别对应 Nginx 的 rewrite/压缩/SSL 模块
RUN dnf -y install \
        gcc \
        gcc-c++ \
        make \
        perl-core \
        perl-interpreter \
        tar \
        gzip \
        pcre2-devel \
        zlib-devel \
        openssl-devel \
    && dnf clean all \
    && rm -rf /var/cache/dnf

WORKDIR /usr/local/nginx

# 源码包：全部来自本地构建上下文，避免依赖外部站点
COPY libfastcommon-1.0.36.tar.gz fastdfs-5.11.tar.gz nginx-1.31.9.tar.gz /tmp/

# fastdfs-nginx-module 源码（本仓库 src 目录）
COPY src /tmp/fastdfs-nginx-module/src

# 1) 编译安装 libfastcommon：FastDFS 依赖的公共基础库
RUN cd /tmp \
    && tar zxf libfastcommon-1.0.36.tar.gz \
    && cd libfastcommon-1.0.36 \
    && ./make.sh \
    && ./make.sh install

# 2) 编译安装 FastDFS 5.11 客户端库
#    说明：旧版 Makefile 未声明目标文件依赖，make 4.x 并行编译会出现
#    "cannot find tracker_mem.o" 链接竞态，故此处顺序编译
#    mod_fastdfs.conf 中的 "#include http.conf" 是 ini 解析器的有效包含指令，
#    http.conf 又依赖同目录下的 mime.types，因此这两个文件必须随镜像提供，
#    否则模块初始化失败，Nginx worker 会持续退出
RUN cd /tmp \
    && tar zxf fastdfs-5.11.tar.gz \
    && cd fastdfs-5.11 \
    && ./make.sh \
    && ./make.sh install \
    && ln -sv /usr/include/fast* /usr/local/include/ \
    && cp -f conf/http.conf conf/mime.types conf/client.conf /etc/fdfs/

# 3) 编译安装 Nginx 1.31.9，并内嵌 fastdfs-nginx-module
#    --with-cc-opt 说明：
#      -I/usr/include/fastcommon  fastdfs_define.h 以 "" 方式包含 fastcommon 的
#                                  common_define.h，需要显式指定其头文件目录
#      -Wno-error=format-truncation  gcc 11 对 snprintf 截断的告警在 Nginx 的
#                                  -Werror 策略下会中断编译，仅降级该类告警
RUN cd /tmp \
    && tar zxf nginx-1.31.9.tar.gz \
    && cd nginx-1.31.9 \
    && ./configure --prefix=/usr/local/nginx \
        --with-http_stub_status_module \
        --with-http_ssl_module \
        --with-file-aio \
        --with-http_realip_module \
        --with-cc-opt="-I/usr/include/fastcommon -Wno-error=format-truncation" \
        --add-module=/tmp/fastdfs-nginx-module/src \
    && make -j"$(nproc)" \
    && make install \
    && mkdir -p /usr/local/nginx/conf/conf.d

# -----------------------------------------------------------------------------
# 第二阶段：运行阶段，只保留运行时必需的产物
# -----------------------------------------------------------------------------
FROM quay.io/rockylinux/rockylinux:9

LABEL maintainer="plz" \
      org.label-schema.name="nginx-fdfs" \
      org.label-schema.vendor="Yilian" \
      org.label-schema.license="GPLv2" \
      org.label-schema.description="Nginx 1.31.9 with fastdfs-nginx-module on Rocky Linux 9"

ENV NGINX_VERSION=1.31.9 \
    FDFS_VERSION=5.11 \
    FASTCOMMON_VERSION=1.0.36 \
    FDFS_MODULE_VERSION=1.20 \
    TZ=Asia/Shanghai

# 国内镜像源加速（同 builder 阶段）
ARG DNF_MIRROR=https://mirrors.aliyun.com/rockylinux
RUN if [ -n "${DNF_MIRROR}" ]; then \
        sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
               -e "s|^#baseurl=http://dl.rockylinux.org/\$contentdir|baseurl=${DNF_MIRROR}|" \
               /etc/yum.repos.d/rocky*.repo; \
    fi

# 运行时依赖：pcre2/zlib/openssl-libs 供 Nginx 动态库，curl-minimal 供健康检查，
# gettext 提供 envsubst（启动脚本渲染 ssl.conf 用），tzdata 供时区
RUN dnf -y install \
        pcre2 \
        zlib \
        openssl-libs \
        curl-minimal \
        gettext \
        tzdata \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone \
    && useradd -r -s /sbin/nologin nginx

# Nginx 可执行文件与静态资源
COPY --from=builder /usr/local/nginx /usr/local/nginx

# FastDFS 客户端库及其依赖的公共库
COPY --from=builder /usr/lib64/libfdfsclient.so /usr/lib64/libfdfsclient.so
COPY --from=builder /usr/lib64/libfastcommon.so /usr/lib64/libfastcommon.so

# FastDFS 客户端配置目录（client.conf 等）
COPY --from=builder /etc/fdfs /etc/fdfs

# fastdfs-nginx-module 的运行参数配置
COPY src/mod_fastdfs.conf /etc/fdfs/mod_fastdfs.conf

# Nginx 主配置与容器启动脚本
COPY conf/nginx.conf /usr/local/nginx/conf/nginx.conf
COPY conf/start_nginx.sh /usr/local/nginx/conf/start_nginx.sh

RUN chmod +x /usr/local/nginx/conf/start_nginx.sh \
    && ldconfig \
    && mkdir -p /data/fastdfs_client /data/fastdfs_storage

WORKDIR /usr/local/nginx

EXPOSE 80

# 健康检查：探测 Nginx 自身的 stub_status（独立 8080 端口，不与业务站点配置冲突）
HEALTHCHECK --interval=30s --timeout=3s --retries=2 \
    CMD curl -sf -o /dev/null http://127.0.0.1:8080/status || exit 1

CMD ["./conf/start_nginx.sh"]
