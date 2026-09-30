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

# ------------------------------------------------------------ 入口层 ---------
# 托管平台（Railway 等）只有一个对外端口，跑不了 compose 里的 edge 容器，
# 于是静态站点伪装会整个丢失——探测者直连后端会看到 400/404。这里在**同一容器内**
# 起一个 Caddy 做入口层：对外提供静态站点，只把「路径 + WS 升级头」转发给后端。
#
# 开关：auto（默认）——检测到平台注入的端口就启用；true/false 可强制。
# 端口：APP_EDGE_PORT 显式指定，否则用平台注入的 PORT。两个端口必须不同。
APP_EDGE="${APP_EDGE:-auto}"
case "$APP_EDGE" in
    auto)
        if [ -n "${APP_EDGE_PORT:-}" ] || [ -n "${PORT:-}" ]; then APP_EDGE_ON=true; else APP_EDGE_ON=false; fi
        ;;
    true|false) APP_EDGE_ON="$APP_EDGE" ;;
    *) die "APP_EDGE 只能是 auto/true/false：$APP_EDGE" ;;
esac

APP_EDGE_PORT="${APP_EDGE_PORT:-${PORT:-}}"
if [ "$APP_EDGE_ON" = "true" ]; then
    if [ -z "$APP_EDGE_PORT" ]; then
        # 明确要求启用却拿不到对外端口：与其静默降级（正是要修的 bug），不如直接报错。
        die "APP_EDGE=true 但拿不到对外端口：请设置 APP_EDGE_PORT（或让平台注入 PORT）"
    fi
    case "$APP_EDGE_PORT" in
        ''|*[!0-9]*) die "APP_EDGE_PORT 必须为数字：$APP_EDGE_PORT" ;;
    esac
    [ "$APP_EDGE_PORT" -ge 1 ] && [ "$APP_EDGE_PORT" -le 65535 ] \
        || die "APP_EDGE_PORT 超出 1-65535：$APP_EDGE_PORT"
    if [ "$APP_EDGE_PORT" = "$APP_PORT" ]; then
        die "端口冲突：APP_PORT 与 APP_EDGE_PORT 同为 $APP_PORT。入口层与后端必须用不同端口，请显式设置其中一个"
    fi
fi

# 入口层开启时后端只绑回环：公网扫不到明文 WS，平台也只能看到入口层那一个端口。
if [ "$APP_EDGE_ON" = "true" ]; then
    APP_LISTEN_ADDR="${APP_LISTEN_ADDR:-127.0.0.1}"
else
    APP_LISTEN_ADDR="${APP_LISTEN_ADDR:-0.0.0.0}"
fi
# 入口层反代目标固定走回环，不依赖 APP_LISTEN_ADDR（它可能有别的用途）。
APP_UPSTREAM="${APP_UPSTREAM:-127.0.0.1:${APP_PORT}}"
APP_EDGE_BIN="${APP_EDGE_BIN:-/usr/sbin/caddy}"
APP_EDGE_CONF="${APP_EDGE_CONF:-/usr/local/share/app/Caddyfile.platform}"
APP_WWW="${APP_WWW:-/srv/www}"

no_percent APP_LISTEN_ADDR "$APP_LISTEN_ADDR"
no_percent APP_UPSTREAM "$APP_UPSTREAM"

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
    -e "s|%%LISTEN_ADDR%%|$(escape "$APP_LISTEN_ADDR")|g" \
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
# 分享链接里的域名不是服务端运行的必要条件，因此**任何情况下都不该阻断启动**：
# 用户显式配错了就报错退出（早失败早发现），平台注入的值不可控，非法时只警告忽略。
APP_SHARE_PORT="${APP_SHARE_PORT:-443}"

# 从形如 "https://host:port/path" 的值里取出主机名。平台注入的变量格式不完全可控，
# 先做规整再校验。注意顺序：先去 scheme，再去路径，最后去端口（IPv6 的 [..] 保留）。
sanitize_host() {
    h="$1"
    case "$h" in
        *://*) h="${h#*://}" ;;
    esac
    case "$h" in
        */*) h="${h%%/*}" ;;
    esac
    case "$h" in
        *@*) h="${h#*@}" ;;
    esac
    case "$h" in
        \[*\]*) ;;                    # [v6]:port —— 保留方括号内的内容
        *:*)    h="${h%%:*}" ;;
    esac
    printf '%s' "$h"
}

is_valid_host() {
    # 用 case 而不是 `grep -E '^[A-Za-z0-9.-]+$'`：grep 是逐行匹配的，
    # 形如 "evil\ndomain.com" 的多行值只要有一行合法就会通过校验，
    # 而 case 是对整个字符串做匹配，换行同样会被下面这条模式拒绝。
    [ -n "$1" ] || return 1
    # 长度上限：DNS 名最长 253 字符，挡掉明显异常的超长值。
    [ "${#1}" -le 253 ] || return 1
    case "$1" in
        *[!A-Za-z0-9.-]*) return 1 ;;
    esac
    return 0
}

# 优先级：APP_SHARE_HOST → APP_DOMAIN（边缘证书用的域名）→ 平台注入的
# RAILWAY_PUBLIC_DOMAIN → APP_WS_HOST（语义是校验 Host 头，通常与对外域名一致）。
APP_SHARE_HOST="${APP_SHARE_HOST:-${APP_DOMAIN:-}}"
if [ -n "$APP_SHARE_HOST" ]; then
    # 用户显式配置：非法就退出，避免带着坏配置继续跑。
    if ! is_valid_host "$APP_SHARE_HOST"; then
        die "APP_DOMAIN / APP_SHARE_HOST 含有非法字符：$APP_SHARE_HOST"
    fi
else
    # 平台注入：属于便利功能，用户改不了这个值，因此非法时只警告并忽略，
    # 绝不能因此让容器启动失败。
    if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
        APP_SHARE_HOST="$(sanitize_host "$RAILWAY_PUBLIC_DOMAIN")"
        if is_valid_host "$APP_SHARE_HOST"; then
            log "采用平台注入的域名（RAILWAY_PUBLIC_DOMAIN）：$APP_SHARE_HOST"
        else
            log "警告：RAILWAY_PUBLIC_DOMAIN 不是合法主机名，已忽略：$RAILWAY_PUBLIC_DOMAIN"
            APP_SHARE_HOST=""
        fi
    fi
    # 最后的兜底：APP_WS_HOST（前面已单独校验过字符集）。
    [ -n "$APP_SHARE_HOST" ] || APP_SHARE_HOST="${APP_WS_HOST:-}"
fi

if [ -z "$APP_SHARE_HOST" ]; then
    # 不阻断启动：域名是客户端侧的参数，服务端照样能跑起来。
    APP_SHARE_HOST="your.domain.com"
    log "警告：APP_DOMAIN / APP_SHARE_HOST / RAILWAY_PUBLIC_DOMAIN / APP_WS_HOST 均未设置，链接里的域名暂用占位符 $APP_SHARE_HOST"
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

# ------------------------------------------------------------ 启动服务 -----
# 未启用入口层：保持原有行为，直接 exec 后端（PID 1 就是服务本身）。
if [ "$APP_EDGE_ON" != "true" ]; then
    log "启动服务：version=$BUILT_VERSION uuid=$APP_UUID port=$APP_PORT path=$APP_WS_PATH host=${APP_WS_HOST:-<任意>}"
    exec "$APP_BIN" "$@"
fi

# -------------------------------------------------------- 入口层 + 后端 ----
# 两个进程同处一个容器：Caddy 对外，后端只监听回环。任一退出即整体退出
# （避免"一个死了另一个还在"的半死状态），收到 TERM/INT 时转发给两者。
[ -x "$APP_EDGE_BIN" ] || die "入口层已启用但找不到可执行文件：$APP_EDGE_BIN"
[ -r "$APP_EDGE_CONF" ] || die "入口层配置不存在或不可读：$APP_EDGE_CONF"
[ -d "$APP_WWW" ] || log "警告：静态站点目录不存在：$APP_WWW（探测者将看到 404）"

# Caddy 用 {$VAR} 读环境变量，因此必须导出。
export APP_EDGE_PORT APP_WS_PATH APP_UPSTREAM APP_WWW

APP_EDGE_LOG="${APP_EDGE_LOG:-}"
if [ -n "$APP_EDGE_LOG" ]; then
    case "$APP_EDGE_LOG" in
        /*) ;;
        *) die "APP_EDGE_LOG 必须是绝对路径（或留空以输出到 stdout）：$APP_EDGE_LOG" ;;
    esac
    mkdir -p "$(dirname "$APP_EDGE_LOG")" || die "无法创建入口层日志目录：$(dirname "$APP_EDGE_LOG")"
fi

log "启动入口层：caddy 监听 :$APP_EDGE_PORT，静态站点=$APP_WWW，WS 路径=$APP_WS_PATH"
log "启动服务：version=$BUILT_VERSION uuid=$APP_UUID port=$APP_PORT（仅 $APP_LISTEN_ADDR）path=$APP_WS_PATH host=${APP_WS_HOST:-<任意>}"

PIDS=""
start() {
    if [ -n "$APP_EDGE_LOG" ]; then
        "$@" >> "$APP_EDGE_LOG" 2>&1 &
    else
        "$@" &
    fi
    PIDS="$PIDS $!"
}

shutdown() {
    # 先摘掉 trap，避免清理过程中再次触发。
    trap - TERM INT EXIT
    log "收到终止信号，正在停止..."
    # shellcheck disable=SC2086
    for p in $PIDS; do kill -TERM "$p" 2>/dev/null || true; done
    for p in $PIDS; do wait "$p" 2>/dev/null || true; done
    log "已停止"
    exit 0
}
trap shutdown TERM INT

start "$APP_EDGE_BIN" run --config "$APP_EDGE_CONF" --adapter caddyfile
start "$APP_BIN" "$@"

# 轮询等待任一进程退出（不用 wait -n：busybox ash 下拿不到是哪个进程、也取不到退出码）。
while :; do
    for p in $PIDS; do
        if ! kill -0 "$p" 2>/dev/null; then
            wait "$p" 2>/dev/null
            rc=$?
            log "进程 $p 退出（退出码 $rc），停止容器"
            shutdown
        fi
    done
    sleep 1
done
