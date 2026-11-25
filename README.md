# yijiao-nginx-fdfs 镜像构建说明

Nginx + fastdfs-nginx-module 镜像的构建、运行与排障注意事项。

---

## 1. 镜像信息

| 项 | 值 |
|---|---|
| 镜像名 | `nginx-dfs:V1.20.1` |
| 基础系统 | Rocky Linux 9.9（`quay.io/rockylinux/rockylinux:9`） |
| Nginx | 1.31.9（源码编译，内嵌 fastdfs-nginx-module） |
| FastDFS | 5.11（客户端库 `libfdfsclient`） |
| libfastcommon | 1.0.36 |
| fastdfs-nginx-module | v1.20.1（本仓库 `src/`） |
| 镜像体积 | 约 204 MB（多阶段构建，不含编译工具链） |
| 监听端口 | 80 |
| 健康检查 | `curl -sf http://127.0.0.1:8080/status`（独立 8080 端口的 `stub_status`，不与业务站点冲突） |
| 运行用户 | `nginx`（uid 999） |

### 相对旧版镜像（registry.zwjk.com/yilian/yijiao-nginx-fdfs:init）的变更

| 项 | 旧镜像 `:init` | 当前镜像 |
|---|---|---|
| 基础系统 | CentOS 7（已 EOL） | Rocky Linux 9.9 |
| Nginx | 1.14.0 / OpenSSL 1.0.2k | 1.31.9 / OpenSSL 3.x |
| 镜像体积 | 484 MB | 204 MB |
| 构建方式 | 单阶段 | 多阶段（builder / runtime） |
| 组件来源 | 外部站点明文 HTTP | 仓库内 tarball，可离线、可校验 |
| 健康检查 | 探测两个上游业务服务 | 自身 `stub_status`（8080），不耦合业务 |
| 运行用户 | 无 `user` 指令（worker=nobody） | `user nginx`（uid 999） |
| `conf.d` 内置业务配置 | `web.conf` / `android.conf` / `ssl.conf.sample` | 不内置，由部署方挂载 |
| `ssl on;`（nginx 1.25 已移除） | 支持 | 启动脚本自动转换为 `listen 443 ssl;` |

`mod_fastdfs.conf` 的路径、group、response_mode 等生产参数与旧镜像**保持一致**（见 4 节）。


---

## 2. 仓库文件

| 文件 | 用途 |
|---|---|
| `Dockerfile` | 镜像构建文件（多阶段） |
| `conf/nginx.conf` | Nginx 主配置；`conf.d/*.conf` 放业务 location 片段 |
| `conf/start_nginx.sh` | 容器启动脚本：先 `nginx -t` 校验，再前台运行（`daemon off`） |
| `src/` | fastdfs-nginx-module 源码（模块编译输入） |
| `src/mod_fastdfs.conf` | 模块运行参数模板，构建时复制到镜像 `/etc/fdfs/mod_fastdfs.conf` |
| `nginx-1.31.9.tar.gz` / `fastdfs-5.11.tar.gz` / `libfastcommon-1.0.36.tar.gz` | 源码包（`libfastcommon` 为编译 FastDFS 客户端库必需） |

镜像内 `/etc/fdfs/` 实际内容：
`mod_fastdfs.conf`、`http.conf`、`mime.types`、`client.conf` + FastDFS 自带的 `*.conf.sample`

---

## 3. 构建

```bash
podman build --format docker -t nginx-dfs:V1.20.1 .
```

> **必须带 `--format docker`**：podman 默认的 OCI 镜像格式**不保留 `HEALTHCHECK`**，构建时会告警
> `HEALTHCHECK is not supported for OCI image format and will be ignored`，导致健康检查失效。

**dnf 源**：Dockerfile 默认把 Rocky 源切成阿里云镜像（官方源在国内只有几十 KB/s，dnf 装包要几十分钟）。
如需改回官方源或换其他镜像：

```bash
podman build --format docker --build-arg DNF_MIRROR= -t nginx-dfs:V1.20.1 .          # 官方源
podman build --format docker --build-arg DNF_MIRROR=https://mirrors.ustc.edu.cn/rocky -t nginx-dfs:V1.20.1 .
```

增量构建策略：改 `conf/` 下文件只需重跑 runtime 层的 COPY（秒级）；改 `src/` 模块源码会触发 nginx 重新编译（数分钟）。

---

## 4. 运行

```bash
podman run -d --name nginx-dfs -p 80:80 \
  -v /path/to/mod_fastdfs.conf:/etc/fdfs/mod_fastdfs.conf:ro \
  -v /path/to/conf.d:/usr/local/nginx/conf/conf.d:ro \
  nginx-dfs:V1.20.1
```

常用配置挂载点：

| 容器内路径 | 用途 |
|---|---|
| `/etc/fdfs/mod_fastdfs.conf` | 模块参数：tracker 地址、group、store_path、response_mode |
| `/etc/fdfs/client.conf` | FastDFS 客户端库参数（上传下载接口用） |
| `/usr/local/nginx/conf/nginx.conf` | Nginx 主配置 |
| `/usr/local/nginx/conf/conf.d/*.conf` | 业务站点配置：**完整的 `server {}` 块**（include 在 http 层，与原镜像一致） |
| `/usr/local/nginx/conf/ca` | SSL 证书目录，`ssl.conf` 中按文件名引用 |

### 环境变量（启动脚本读取，与原镜像一致）

| 变量 | 说明 |
|---|---|
| `INDEX_URL` | 首页跳转路径（注意是**路径**，如 `/ui/index.html`，不是完整 URL）。启动时会 `sed` 替换 `conf.d/web.conf` 里的 `/INDEX_URL` 占位符 |
| `SSL_MODE` | 为 `on` 时，用 `conf.d/ssl.conf.sample` 渲染出 `ssl.conf` 并启用 443 |
| `SSL_CRT` | 证书文件名（放在 `/usr/local/nginx/conf/ca/` 下） |
| `SSL_KEY` | 私钥文件名（同上） |

> `INDEX_URL` 需要写入 `web.conf`，所以挂载 `conf.d` 时不能是 `:ro`；不需要该能力时可以不传该变量（脚本会跳过替换）。

### FastDFS 路径约定

镜像内 `mod_fastdfs.conf` 的生产值与旧镜像一致：

| 参数 | 值 |
|---|---|
| `base_path` | `/data/fastdfs_client` |
| `store_path0` | `/data/fastdfs_storage` |
| `url_have_group_name` | `true`（URL 形如 `/group1/M00/...`） |
| `tracker_server` | `tracker:22122` |
| `response_mode` | `proxy` |

镜像已创建 `/data/fastdfs_client` 与 `/data/fastdfs_storage` 两个目录。

FastDFS 接入示例（`conf.d` 中的 `server` 块里，`location` 写在内部）：

```nginx
server {
    listen       80;
    server_name  localhost;

    # url_have_group_name=true 时用这条；若 URL 不带 group 名则改为 location /M00
    location ~ /group[0-9]/M00 {
        ngx_fastdfs_module;
    }
}
```

---

## 5. 注意事项（踩坑清单）

### 5.1 模块初始化必须带 `http.conf` 与 `mime.types`（最易致命）

`mod_fastdfs.conf` 中的 `#include http.conf` **不是注释**，而是 ini 解析器的有效包含指令；
`http.conf` 又需要同目录下的 `mime.types`（`http.mime_types_filename`）。

任一文件缺失 → `fdfs_mod_init` 失败 → **nginx worker 持续退出（fatal code 2）→ 容器显示 Up 但完全不服务**。

镜像已内置这三个文件；若自行覆盖 `mod_fastdfs.conf`，必须保留 `#include http.conf` 或自行补齐 `http.*` 参数
（否则报 `param "http.mime_types_filename" not exist or is empty`）。

### 5.2 `mod_fastdfs.conf` 中的 tracker 地址

`tracker_server=tracker:22122` 是原镜像 docker-compose 的服务名，部署时须保证该名字可解析且可达；
模块初始化阶段**只解析配置、不连接 tracker**，所以 tracker 不通不会导致启动失败，但文件请求会超时。

### 5.3 FastDFS 服务端（若在同容器/同编排中自建 tracker+storage）

- `storage.conf` 必须 `buff_size >= 65546`（默认 65536 启动即 `CRIT - exit abnormally`）
- tracker 不接受 `127.0.0.1` 作为 tracker 地址，须用容器实际 IP
- `tracker.conf` 需声明 `store_group / store_group_name / store_group_port`

### 5.4 编译期已知降级项

- **FastDFS 必须顺序编译**（`./make.sh` 不带 `-j`）：旧 Makefile 未声明目标文件依赖，make 4.x 并行会报
  `cannot find tracker_mem.o` 链接竞态
- **`--with-cc-opt` 必带两项**：
  - `-I/usr/include/fastcommon`：`fdfs_define.h` 以 `""` 方式包含 fastcommon 的 `common_define.h`
  - `-Wno-error=format-truncation`：gcc 11 对 `snprintf` 截断的告警在 `-Werror` 下会中断编译
    （根治需改 `src/common.c` 的缓冲区长度，属上游代码问题，本次未改动模块源码）
- 原镜像的 `ln -sv /usr/include/fast* /usr/local/include/` 软链方案在新 gcc 下**不再有效**，不要再依赖

### 5.5 rootless podman 环境限制

- rootless 下容器进程**不能绑定 80 等特权端口**（`bind() to 0.0.0.0:80 failed (13: Permission denied)`）。
  这是运行环境限制，不是镜像问题；调试时改用 `listen 8080` 之类的非特权端口。
- rootless podman 转发宿主端口在本机不通时，改用 `podman exec` 在容器内 `curl 127.0.0.1` 自测。

### 5.6 nginx 1.25+ 移除了 `ssl on;` 指令

旧镜像（nginx 1.14）的 `ssl.conf.sample` 里有 `ssl ${SSL_MODE};`，在 1.31.9 下会报
`unknown directive "ssl"` 导致**启动失败**。启动脚本已自动做等价转换：

```nginx
ssl on;          →   删除该行
listen 443;      →   listen 443 ssl;
```

如果你的 `ssl.conf` 是自行维护的，请直接写成 `listen 443 ssl;`，不要再写 `ssl on;`。

### 5.7 其他

- `conf.d/*.conf` 的 include 位于 **http 层**（与原镜像一致），`conf.d` 内放**完整的 `server {}` 块**；
  若在该文件里直接写 `location` 片段会报 `location directive is not allowed here`，
  location 片段必须写在 `server {}` 块内部
- 模块只放行 GET/HEAD：POST 返回 `405`；file id 非法返回 `400`（模块自身 storage_client 校验）
- 容器时区由 `TZ=Asia/Shanghai` + `tzdata` 提供

---

## 6. 排障速查

容器起不来 / 不服务时，按顺序检查：

```bash
# 1. 容器与健康状态
podman ps -a --filter name=nginx-dfs
podman inspect --format '{{.State.Health.Status}}' nginx-dfs

# 2. 容器日志（模块的 FastDFS 日志输出在这里）
podman logs nginx-dfs | tail -50

# 3. nginx 错误日志（worker 崩溃会在这里：exited with fatal code 2）
podman exec nginx-dfs tail -50 /usr/local/nginx/logs/error.log

# 4. 配置校验 + 版本/模块确认
podman exec nginx-dfs nginx -t
podman exec nginx-dfs nginx -V

# 5. 模块配置是否完整
podman exec nginx-dfs ls -1 /etc/fdfs
```

常见错误对照：

| 现象 / 错误 | 原因 | 处理 |
|---|---|---|
| `worker process exited with fatal code 2` | 模块初始化失败 | 查 5.1，确认 `/etc/fdfs/http.conf`、`mime.types` 存在 |
| `param "http.mime_types_filename" not exist or is empty` | `mod_fastdfs.conf` 缺 `http.*` 参数 | 保留 `#include http.conf` |
| `include http.conf not exists` | 缺少 `http.conf` | 见 5.1 |
| `nginx: [emerg] server directive is not allowed here` | `conf.d` 的 include 被放在 `server` 块内 | include 必须在 **http 层**（本镜像已如此） |
| `nginx: [emerg] location directive is not allowed here` | `conf.d` 里直接写了 `location` 片段 | location 片段必须写在 `server {}` 块内部 |
| `HEALTHCHECK is not supported for OCI image format` | 构建未加 `--format docker` | 重新构建 |
| `cannot find tracker_mem.o` | FastDFS 并行编译竞态 | 去掉 `-j` |

---

## 7. 兼容性验证结论（已实测）

模块 v1.20.1 与 nginx 1.31.9 **兼容**，无需改动模块源码。

静态检查：模块引用的 77 个 nginx 符号在 1.31.9 中全部存在；`r->method`、`r->header_only`、
`r->header_hash`、`r->lowcase_index`、`r->lowcase_header` 等已被 nginx 弃用但仍在 1.31.9 中被正常维护；
CHANGES 1.14.0→1.31.9 无 upstream 扩展接口的破坏性变更。

端到端实测（容器内真实 FastDFS 5.11 tracker + storage，经 nginx 1.31.9 + 模块取文件）：

| 场景 | 结果 |
|---|---|
| GET 完整文件（100KB） | 200，md5 与原文件一致 |
| HEAD | 200，Content-Type / Content-Length / Last-Modified 正确 |
| Range `bytes=0-99` | 206，`Content-Range: bytes 0-99/102400`、`Accept-Ranges: bytes`，内容 md5 一致 |
| 多段 Range `bytes=0-9,20-29` | 206，`multipart/byteranges` |
| POST | 405（模块只放行 GET/HEAD） |
| 非法 file id | 400（模块 storage_client 校验） |
| worker 稳定性 | fatal exit 0 次，`/status` 200，容器 healthy |

---

## 8. 相关文档

- `yijiao-nginx-fdfs镜像构建历史整理与详细总结.docx` —— 旧版镜像的构建历史与问题梳理
- `HISTORY` / `INSTALL` —— fastdfs-nginx-module 官方版本历史与安装说明
