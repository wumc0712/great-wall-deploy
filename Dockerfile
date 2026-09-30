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
    # 冒烟测试：确认二进制可执行且确实是本方案期望的程序。v4 认 -version，
    # v5 只有 version 子命令。横幅首行是 "<名称> <版本>"，故按去品牌开关断言
    # 对应名称——DEBRAND=false 时二进制保留上游名，不能用中性名去匹配。
    # 断言的是命令输出（纯文本），不是二进制本身。输出只进构建日志，不进镜像。
    if [ "${DEBRAND}" = "true" ]; then smoke_name='Relay'; else smoke_name='V2Ray'; fi; \
    ( "${APP_BIN}" -version || "${APP_BIN}" version ) 2>&1 | grep -q "${smoke_name}"

EXPOSE 10000/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
