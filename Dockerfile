# syntax=docker/dockerfile:1

# 从官方 v2fly/v2fly-core 镜像（由 v2fly/docker 构建）中抽取二进制与 geo 数据，
# 再放进干净的 alpine 运行时层。
#
# 去特征化：上游镜像名只出现在构建期（无法避免），运行时镜像内不再有上游标识——
# 二进制名、安装路径、LABEL、配置 tag、环境变量前缀均已中性化。

ARG SRC_VERSION=v5.41.0

# --------------------------------------------------------------- builder ----
FROM v2fly/v2fly-core:${SRC_VERSION} AS builder

COPY docker/extract-artifacts.sh /tmp/extract-artifacts.sh
RUN sh /tmp/extract-artifacts.sh /out

# --------------------------------------------------------------- runtime ----
FROM alpine:3.21

ARG SRC_VERSION
# 运行时二进制名。改它就是改进程名与文件名——去特征化的第一步。
ARG APP_BIN_NAME=relay

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
    APP_UUID_FILE="/etc/app/uuid"

RUN set -eux; \
    apk add --no-cache ca-certificates; \
    mkdir -p "${APP_ASSET_DIR}" /run/app /etc/app

COPY --from=builder /out/relay       /usr/local/bin/${APP_BIN_NAME}
COPY --from=builder /out/geoip.dat   /usr/local/share/app/geoip.dat
COPY --from=builder /out/geosite.dat /usr/local/share/app/geosite.dat

COPY config/config.json.template /usr/local/share/app/config.json.template
COPY docker/entrypoint.sh        /usr/local/bin/entrypoint.sh
COPY scripts/share-link.sh       /usr/local/bin/share-link.sh

RUN set -eux; \
    chmod 0755 "${APP_BIN}" "${APP_ENTRYPOINT}" "${APP_SHARE_BIN}"; \
    printf '%s\n' "${SRC_VERSION}" > "${APP_VERSION_FILE}"; \
    # 冒烟测试：确认二进制可执行且是预期程序。v4 认 -version，v5 只有 version 子命令。
    # 输出只在构建日志里，不进镜像。
    ( "${APP_BIN}" -version || "${APP_BIN}" version ) 2>&1 | grep -q 'V2Ray'

EXPOSE 10000/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
