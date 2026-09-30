# syntax=docker/dockerfile:1

# 从官方 v2fly/v2fly-core 镜像（由 v2fly/docker 构建）中抽取二进制与 geo 数据，
# 再放进干净的 alpine 运行时层，并在此期间改名、去品牌。
#
# 去特征化：上游镜像名只出现在构建期（无法避免），运行时镜像内不再有上游标识——
# 二进制名、安装路径、LABEL、配置 tag、环境变量前缀均已中性化，二进制内的品牌
# 字符串也在构建期做等长替换（见 docker/debrand.sh）。

ARG SRC_VERSION=v5.41.0

# --------------------------------------------------------------- builder ----
FROM v2fly/v2fly-core:${SRC_VERSION} AS builder

# 设为 false 可跳过二进制去品牌替换（排查构建问题时用）。
ARG DEBRAND=true

# 去品牌脚本要求 GNU sed：alpine 自带的 busybox sed（1.37）在 35 MB 二进制上
# 会静默漏替换且文件大小不变（实测，见 docker/debrand.sh 顶部注释），
# 因此这里显式安装 GNU sed。只在 builder 层，运行层镜像不含它。
RUN set -eux; \
    if [ "${DEBRAND}" = "true" ]; then apk add --no-cache sed; fi

COPY docker/extract-artifacts.sh docker/debrand.sh /tmp/

# 先抽取资源，再对二进制做等长替换。两步都在 builder 层，产物只有 /out/relay
# 与两份 geo 数据会进运行层，本阶段的中间文件不留在最终镜像里。
RUN set -eux; \
    sh /tmp/extract-artifacts.sh /out; \
    if [ "${DEBRAND}" = "true" ]; then sh /tmp/debrand.sh /out/relay; fi

# --------------------------------------------------------------- runtime ----
FROM alpine:3.21

ARG SRC_VERSION
# 运行时二进制名。改它就是改进程名与文件名——去特征化的第一步。
ARG APP_BIN_NAME=relay
# 与 builder 阶段同名参数联动：决定冒烟测试断言哪个名字。
ARG DEBRAND=true

LABEL org.opencontainers.image.title="relay" \
      org.opencontainers.image.description="Lightweight internal service" \
      org.opencontainers.image.version="${SRC_VERSION}"

ENV APP_BIN="/usr/local/bin/${APP_BIN_NAME}" \
    APP_ENTRYPOINT="/usr/local/bin/entrypoint.sh" \
    APP_SHARE_BIN="/usr/local/bin/share-link.sh" \
    APP_ASSET_DIR="/usr/local/share/app" \
    APP_TEMPLATE="/usr/local/share/app/config.json.template" \
    APP_VERSION_FILE="/usr/local/share/app/.version" \
    APP_CONFIG="/run/app/config.json" \
    APP_UUID_FILE="/etc/app/uuid" \
    APP_EDGE_BIN="/usr/sbin/caddy" \
    APP_EDGE_CONF="/usr/local/share/app/Caddyfile.platform" \
    APP_WWW="/srv/www"

# caddy 用作可选的入口层（托管平台上补回静态站点伪装与端口适配）。
# 只在运行时镜像装，builder 阶段不需要。
RUN set -eux; \
    apk add --no-cache ca-certificates caddy; \
    mkdir -p "${APP_ASSET_DIR}" /run/app /etc/app "${APP_WWW}"

COPY --from=builder /out/relay       /usr/local/bin/${APP_BIN_NAME}
COPY --from=builder /out/geoip.dat   /usr/local/share/app/geoip.dat
COPY --from=builder /out/geosite.dat /usr/local/share/app/geosite.dat

COPY config/config.json.template     /usr/local/share/app/config.json.template
COPY docker/Caddyfile.platform       /usr/local/share/app/Caddyfile.platform
COPY docker/entrypoint.sh            /usr/local/bin/entrypoint.sh
COPY scripts/share-link.sh           /usr/local/bin/share-link.sh
# 静态站点直接打进镜像：托管平台上没有 compose 那样的宿主机挂载，
# 若不打包进去，入口层就没有内容可服务（此前正是这个原因导致探测者看到 404）。
COPY web/                            /srv/www/

RUN set -eux; \
    chmod 0755 "${APP_BIN}" "${APP_ENTRYPOINT}" "${APP_SHARE_BIN}"; \
    printf '%s\n' "${SRC_VERSION}" > "${APP_VERSION_FILE}"; \
    # 冒烟测试：确认二进制可执行且确实是本方案期望的程序。v4 认 -version，
    # v5 只有 version 子命令。横幅首行是 "<名称> <版本>"，故按去品牌开关断言
    # 对应名称——DEBRAND=false 时二进制保留上游名，不能用中性名去匹配。
    # 断言的是命令输出（纯文本），不是二进制本身。输出只进构建日志，不进镜像。
    if [ "${DEBRAND}" = "true" ]; then smoke_name='Relay'; else smoke_name='V2Ray'; fi; \
    ( "${APP_BIN}" -version || "${APP_BIN}" version ) 2>&1 | grep -q "${smoke_name}"; \
    # 入口层冒烟测试：Caddyfile 必须在构建期就通过校验，避免部署后才发现写错。
    # 用的是占位变量的一次性取值，与运行期注入无关。
    APP_EDGE_PORT=8080 APP_WS_PATH=/vless-ws APP_UPSTREAM=127.0.0.1:10000 APP_WWW="${APP_WWW}" \
        "${APP_EDGE_BIN}" validate --config "${APP_EDGE_CONF}" --adapter caddyfile; \
    # 静态站点必须真的进了镜像。
    test -s "${APP_WWW}/index.html"

# 未启用入口层时后端直接监听这个端口；启用时它由入口层接管。
EXPOSE 10000/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
