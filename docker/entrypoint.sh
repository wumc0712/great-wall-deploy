#!/bin/sh
# 服务容器入口。
#
# 职责：把 config/config.json.template 与容器环境变量合成为运行时配置，启动服务。
# 只依赖 /bin/sh，不引入外部解释器。
#
# 去特征化说明：脚本与镜像内所有可自定义的路径/变量都使用中性命名（APP_*）。
# 唯一保留上游名称的是 V2RAY_LOCATION_ASSET——那是二进制自身读取的接口名，
# 无法更改，因此只能显式 export（见文件末尾）。
set -eu

APP_BIN="${APP_BIN:-/usr/local/bin/relay}"
APP_TEMPLATE="${APP_TEMPLATE:-/usr/local/share/app/config.json.template}"
APP_CONFIG="${APP_CONFIG:-/run/app/config.json}"
APP_ASSET_DIR="${APP_ASSET_DIR:-/usr/local/share/app}"
APP_UUID_FILE="${APP_UUID_FILE:-/etc/app/uuid}"
log() { printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "错误：$*"; exit 1; }

# 配置模板用 %%NAME%% 作为占位符，值里出现 % 会造成占位符错配。
no_percent() {
    case "$2" in
        *%*) die "$1 不能包含百分号：$2" ;;
    esac
}

# 由 32 个十六进制字符按 RFC 4122 v4 规则组装 UUID。
# 第 7 字节高半字节固定为 4（版本），第 9 字节高半字节固定为 a（variant）。
make_uuid_from_hex() {
    hex="$1"
    [ ${#hex} -eq 32 ] || return 1
    printf '%s-%s-4%s-a%s-%s\n' \
        "$(printf '%s' "$hex" | cut -c1-8)" \
        "$(printf '%s' "$hex" | cut -c9-12)" \
        "$(printf '%s' "$hex" | cut -c14-16)" \
        "$(printf '%s' "$hex" | cut -c18-20)" \
        "$(printf '%s' "$hex" | cut -c21-32)"
}

# ---------------------------------------------------------------- UUID ------
# 未显式提供 APP_UUID 时，首次启动生成并持久化到挂载卷，避免重启后服务端
# UUID 变化导致已下发的客户端配置失效。
if [ -z "${APP_UUID:-}" ]; then
    if [ -s "$APP_UUID_FILE" ]; then
        APP_UUID="$(tr -d ' \t\r\n' < "$APP_UUID_FILE")"
        log "复用已持久化的 UUID（$APP_UUID_FILE）"
    else
        if [ -r /proc/sys/kernel/random/uuid ]; then
            APP_UUID="$(cat /proc/sys/kernel/random/uuid)"
        elif [ -r /dev/urandom ]; then
            APP_UUID="$(make_uuid_from_hex "$(od -An -N16 -tx1 < /dev/urandom | tr -d ' \n')")" \
                || die "无法生成 UUID，请显式设置 APP_UUID"
        else
            die "无法生成 UUID（/proc/sys/kernel/random/uuid 与 /dev/urandom 均不可读），请显式设置 APP_UUID"
        fi
        mkdir -p "$(dirname "$APP_UUID_FILE")"
        ( umask 077; printf '%s\n' "$APP_UUID" > "$APP_UUID_FILE" )
        log "已生成新的 UUID 并写入 $APP_UUID_FILE"
    fi
fi

APP_UUID="$(printf '%s' "$APP_UUID" | tr 'A-Z' 'a-z')"
case "$APP_UUID" in
    ????????-????-????-????-????????????) ;;
    *) die "APP_UUID 不是合法 UUID：$APP_UUID" ;;
esac
case "$APP_UUID" in
    *[!0-9a-f-]*) die "APP_UUID 含有非法字符：$APP_UUID" ;;
esac

# ------------------------------------------------------- 环境变量与校验 -----
APP_PORT="${APP_PORT:-10000}"
case "$APP_PORT" in
    ''|*[!0-9]*) die "APP_PORT 必须为数字，当前为：$APP_PORT" ;;
esac
[ "$APP_PORT" -ge 1 ] && [ "$APP_PORT" -le 65535 ] || die "APP_PORT 超出 1-65535：$APP_PORT"

APP_WS_PATH="${APP_WS_PATH:-/vless-ws}"
case "$APP_WS_PATH" in
    /*) ;;
    *) die "APP_WS_PATH 必须以 / 开头：$APP_WS_PATH" ;;
esac
# 路径会原样写进 JSON，限制字符集避免引号/反斜杠破坏配置。
if ! printf '%s' "$APP_WS_PATH" | grep -Eq '^/[A-Za-z0-9._~/-]*$'; then
    die "APP_WS_PATH 只能包含字母、数字与 . _ ~ / - ：$APP_WS_PATH"
fi

APP_EMAIL="${APP_EMAIL:-app}"
if ! printf '%s' "$APP_EMAIL" | grep -Eq '^[A-Za-z0-9._@-]+$'; then
    die "APP_EMAIL 只能包含字母、数字与 . _ @ - ：$APP_EMAIL"
fi

APP_WS_HOST="${APP_WS_HOST:-}"
if [ -n "$APP_WS_HOST" ] && ! printf '%s' "$APP_WS_HOST" | grep -Eq '^[A-Za-z0-9.-]+$'; then
    die "APP_WS_HOST 含有非法字符：$APP_WS_HOST"
fi

no_percent APP_UUID "$APP_UUID"
no_percent APP_EMAIL "$APP_EMAIL"
no_percent APP_WS_PATH "$APP_WS_PATH"
no_percent APP_WS_HOST "$APP_WS_HOST"
# 这两项在下面才赋默认值，此处用安全展开，避免未设置时被 set -u 中断。
no_percent APP_LOG_ACCESS "${APP_LOG_ACCESS:-}"
no_percent APP_LOG_ERROR "${APP_LOG_ERROR:-}"

APP_LOG_LEVEL="${APP_LOG_LEVEL:-warning}"
case "$APP_LOG_LEVEL" in
    debug|info|warning|error|none) ;;
    *) die "APP_LOG_LEVEL 只能是 debug/info/warning/error/none：$APP_LOG_LEVEL" ;;
esac

APP_SNIFFING="${APP_SNIFFING:-true}"
case "$APP_SNIFFING" in
    true|false) ;;
    *) die "APP_SNIFFING 只能是 true 或 false：$APP_SNIFFING" ;;
esac

APP_DOMAIN_STRATEGY="${APP_DOMAIN_STRATEGY:-UseIP}"
case "$APP_DOMAIN_STRATEGY" in
    AsIs|UseIP|UseIPv4|UseIPv6) ;;
    *) die "APP_DOMAIN_STRATEGY 只能是 AsIs/UseIP/UseIPv4/UseIPv6：$APP_DOMAIN_STRATEGY" ;;
esac

APP_BLOCK_PRIVATE="${APP_BLOCK_PRIVATE:-true}"
case "$APP_BLOCK_PRIVATE" in
    true|false) ;;
    *) die "APP_BLOCK_PRIVATE 只能是 true 或 false：$APP_BLOCK_PRIVATE" ;;
esac

APP_LOG_ACCESS="${APP_LOG_ACCESS:-}"
APP_LOG_ERROR="${APP_LOG_ERROR:-}"
if [ -n "$APP_LOG_ACCESS" ]; then
    case "$APP_LOG_ACCESS" in
        /*) ;;
        *) die "APP_LOG_ACCESS 必须是绝对路径（或留空以输出到 stdout）：$APP_LOG_ACCESS" ;;
    esac
    mkdir -p "$(dirname "$APP_LOG_ACCESS")" || die "无法创建日志目录：$(dirname "$APP_LOG_ACCESS")"
fi
if [ -n "$APP_LOG_ERROR" ]; then
    case "$APP_LOG_ERROR" in
        /*) ;;
        *) die "APP_LOG_ERROR 必须是绝对路径（或留空以输出到 stderr）：$APP_LOG_ERROR" ;;
    esac
    mkdir -p "$(dirname "$APP_LOG_ERROR")" || die "无法创建日志目录：$(dirname "$APP_LOG_ERROR")"
fi

[ -r "$APP_TEMPLATE" ] || die "模板不存在或不可读：$APP_TEMPLATE"
[ -x "$APP_BIN" ] || die "二进制不存在或不可执行：$APP_BIN"
[ -f "$APP_ASSET_DIR/geoip.dat" ] || log "警告：$APP_ASSET_DIR/geoip.dat 缺失，geoip 相关规则将失效"

# ------------------------------------------------------------- 路由规则 -----
# 只在需要时生成规则条目。注意：绝不能生成 "ip": [] 这类空字段规则，
# 空规则会被判定为 "this rule has no effective fields" 并拒绝启动。
if [ "$APP_BLOCK_PRIVATE" = "true" ]; then
    ROUTING_RULES="      {
        \"type\": \"field\",
        \"ip\": [ \"geoip:private\" ],
        \"outboundTag\": \"drop\"
      }"
else
    ROUTING_RULES=""
fi

# --------------------------------------------------------------- 合成 -------
mkdir -p "$(dirname "$APP_CONFIG")"
tmp="${APP_CONFIG}.tmp.$$"
scalar="${APP_CONFIG}.scalar.$$"
trap 'rm -f "$tmp" "$scalar"' EXIT INT TERM

# sed 替换串里先转义反斜杠、与和 & 及分隔符 |，避免值中的特殊字符破坏替换。
escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# 占位符用 %%NAME%%，各变量在校验阶段已禁止出现 % 字符，
# 因此替换结果不会被后续占位符二次匹配（__NAME__ 形式配合自由文本值会串扰）。
#
# 第一步：标量替换。只处理单值占位符，路由规则留到第二步，因为 busybox sed
# 的替换串不支持跨行内容（会报 unmatched '|'）。
sed \
    -e "s|%%UUID%%|$(escape "$APP_UUID")|g" \
    -e "s|%%EMAIL%%|$(escape "$APP_EMAIL")|g" \
    -e "s|%%PORT%%|$(escape "$APP_PORT")|g" \
    -e "s|%%WS_PATH%%|$(escape "$APP_WS_PATH")|g" \
    -e "s|%%WS_HOST%%|$(escape "$APP_WS_HOST")|g" \
    -e "s|%%SNIFFING%%|$(escape "$APP_SNIFFING")|g" \
    -e "s|%%DOMAIN_STRATEGY%%|$(escape "$APP_DOMAIN_STRATEGY")|g" \
    -e "s|%%LOG_LEVEL%%|$(escape "$APP_LOG_LEVEL")|g" \
    -e "s|%%LOG_ACCESS%%|$(escape "$APP_LOG_ACCESS")|g" \
    -e "s|%%LOG_ERROR%%|$(escape "$APP_LOG_ERROR")|g" \
    "$APP_TEMPLATE" > "$scalar" || die "渲染配置失败（标量替换）"

# 第二步：展开路由规则占位行，替换为多行规则片段（或空）。
: > "$tmp"
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        *%%ROUTING_RULES%%*) printf '%s\n' "$ROUTING_RULES" ;;
        *)                   printf '%s\n' "$line" ;;
    esac
done < "$scalar" >> "$tmp" || die "渲染配置失败（路由规则）"
rm -f "$scalar"

chmod 0600 "$tmp"
mv "$tmp" "$APP_CONFIG"
trap - EXIT INT TERM

# ------------------------------------------------------------- 版本分支 -----
# v5 用 "run -c"，v4 用 "-c"；两个大版本的 flag 互不兼容（v5 不认 -c/-version，
# v4 不认 run 子命令，且会退回去读二进制同目录的配置）。因此分别探测：
#   v4 支持 -version，v5 只支持 version 子命令。
detect_major() {
    ver="$("$APP_BIN" -version 2>&1 | head -n 1 | awk '{print $2}')"
    case "$ver" in
        4.*|v4.*) printf '4'; return ;;
    esac
    ver="$("$APP_BIN" version 2>&1 | head -n 1 | awk '{print $2}')"
    case "$ver" in
        4.*|v4.*) printf '4'; return ;;
        5.*|v5.*) printf '5'; return ;;
    esac
    printf ''
}

MAJOR=""
case "${APP_CLI:-auto}" in
    v4|4) MAJOR="4" ;;
    v5|5) MAJOR="5" ;;
    auto) MAJOR="$(detect_major)" ;;
    *)    die "APP_CLI 只能是 auto/v4/v5：${APP_CLI:-}" ;;
esac

case "$MAJOR" in
    4) set -- -c "$APP_CONFIG" ;;
    5) set -- run -c "$APP_CONFIG" ;;
    *) log "警告：无法识别主版本，按 v5 的 CLI 启动（可用 APP_CLI=v4 强制）"
       set -- run -c "$APP_CONFIG" ;;
esac

# 记录镜像内实际部署的版本（构建时写入），便于排障。
APP_VERSION_FILE="${APP_VERSION_FILE:-/usr/local/share/app/.version}"
BUILT_VERSION="$(cat "$APP_VERSION_FILE" 2>/dev/null || echo '未知')"

# ------------------------------------------------------------ 分享链接 -----
# 启动前顺手生成一次分享链接，落盘到挂载目录，省得再进容器手动拼。
# 部署完成后仍可在容器内随时重跑（结果同样写到该文件）：
#   APP_DOMAIN=你的域名 sh /usr/local/bin/share-link.sh
SHARE_LINK_BIN="${APP_SHARE_BIN:-/usr/local/bin/share-link.sh}"
SHARE_LINK_FILE="${APP_SHARE_FILE:-$(dirname "$APP_UUID_FILE")/share-link.txt}"
# 对外域名：APP_SHARE_HOST 优先，其次 APP_DOMAIN（边缘证书用的同一个域名），
# 最后退回 APP_WS_HOST（它的语义是校验 Host 头，通常与对外域名一致）。
APP_SHARE_HOST="${APP_SHARE_HOST:-${APP_DOMAIN:-}}"
APP_SHARE_HOST="${APP_SHARE_HOST:-$APP_WS_HOST}"
APP_SHARE_PORT="${APP_SHARE_PORT:-443}"

if [ -n "$APP_SHARE_HOST" ]; then
    if ! printf '%s' "$APP_SHARE_HOST" | grep -Eq '^[A-Za-z0-9.-]+$'; then
        die "APP_DOMAIN / APP_SHARE_HOST 含有非法字符：$APP_SHARE_HOST"
    fi
else
    # 不阻断启动：域名是客户端侧的参数，服务端照样能跑起来。
    APP_SHARE_HOST="your.domain.com"
    log "警告：APP_DOMAIN / APP_SHARE_HOST / APP_WS_HOST 均未设置，链接里的域名暂用占位符 $APP_SHARE_HOST"
fi

case "$APP_SHARE_PORT" in
    ''|*[!0-9]*) die "APP_SHARE_PORT 必须为数字：$APP_SHARE_PORT" ;;
esac

if [ -x "$SHARE_LINK_BIN" ]; then
    # APP_UUID 是 shell 变量（未导出），显式传给脚本，不依赖环境继承。
    # 脚本失败绝不能拖垮 entrypoint（set -e 下命令替换失败会直接终止），
    # 因此这里用 if 兜住退出码，再按情况回显。
    SHARE_TEXT=""
    if SHARE_TEXT="$(APP_SHARE_OUT="$SHARE_LINK_FILE" \
                     APP_UUID="$APP_UUID" \
                     APP_UUID_FILE="$APP_UUID_FILE" \
                     APP_WS_PATH="$APP_WS_PATH" \
                     APP_SHARE_HOST="$APP_SHARE_HOST" \
                     APP_SHARE_PORT="$APP_SHARE_PORT" \
                     "$SHARE_LINK_BIN" 2>&1)"; then
        :
    else
        log "警告：生成分享链接时脚本返回非零码，以下为其输出"
    fi
    # 逐行套上时间戳前缀，便于容器日志里辨认。
    printf '%s\n' "$SHARE_TEXT" | while IFS= read -r SHARE_LINE; do log "$SHARE_LINE"; done
    if [ -s "$SHARE_LINK_FILE" ]; then
        log "分享链接已写入 $SHARE_LINK_FILE"
    else
        log "警告：未能写入 $SHARE_LINK_FILE，链接见上方日志"
    fi
else
    log "警告：未找到分享链接脚本 $SHARE_LINK_BIN，跳过生成"
fi

# geo 数据目录：二进制自身读取的变量名（不可更改），因此必须显式导出。
export V2RAY_LOCATION_ASSET="$APP_ASSET_DIR"

log "启动服务：version=$BUILT_VERSION uuid=$APP_UUID port=$APP_PORT path=$APP_WS_PATH host=${APP_WS_HOST:-<任意>}"
exec "$APP_BIN" "$@"
