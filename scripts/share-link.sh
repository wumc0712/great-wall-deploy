#!/bin/sh
# 从 .env（或环境变量）生成 VLESS + WebSocket 分享链接。
#
# 用法：
#   ./scripts/share-link.sh .env
#   ./scripts/share-link.sh            # 直接读环境变量
#   APP_SHARE_OUT=/etc/app/share-link.txt ./scripts/share-link.sh
#
# 想拿到可直接复制的链接，建议不带注释执行：
#   set -a; . ./.env; set +a; ./scripts/share-link.sh | tail -n 1
set -eu

# ---------------------------------------------------------------- 读取 ----
ENV_FILE="${1:-}"
if [ -n "$ENV_FILE" ]; then
    [ -f "$ENV_FILE" ] || { echo "找不到配置文件：$ENV_FILE" >&2; exit 1; }
    # 只取 KEY=VALUE 行，忽略注释与空行；最后一个赋值生效。
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        # 去掉 key 两端空白
        key="$(printf '%s' "$key" | tr -d ' \t')"
        case "$key" in
            ''|*[!A-Za-z0-9_]*) continue ;;
        esac
        # 去掉值两端空白，并剥掉成对的单/双引号
        val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        export "$key=$val"
    done < "$ENV_FILE"
fi

# ---------------------------------------------------------------- 取值 ----
UUID="${APP_UUID:-}"
if [ -z "$UUID" ] && [ -s "${APP_UUID_FILE:-/etc/app/uuid}" ]; then
    UUID="$(tr -d ' \t\r\n' < "${APP_UUID_FILE:-/etc/app/uuid}")"
fi
# 本地部署时 uuid 常落在 ./data/uuid
if [ -z "$UUID" ] && [ -s "./data/uuid" ]; then
    UUID="$(tr -d ' \t\r\n' < ./data/uuid)"
fi

# 域名优先级：APP_SHARE_HOST → APP_DOMAIN（边缘证书域名）→ APP_WS_HOST。
HOST="${APP_SHARE_HOST:-}"
[ -n "$HOST" ] || HOST="${APP_DOMAIN:-}"
[ -n "$HOST" ] || HOST="${APP_WS_HOST:-}"

PORT="${APP_SHARE_PORT:-443}"
WS_PATH="${APP_WS_PATH:-/vless-ws}"
SNI="${APP_SHARE_SNI:-$HOST}"
INSECURE="${APP_SHARE_INSECURE:-false}"
LABEL="${APP_SHARE_LABEL:-relay}"

if [ -z "$UUID" ]; then
    echo "错误：拿不到 UUID。请先设置 APP_UUID，或让容器生成后读取 ./data/uuid。" >&2
    exit 1
fi
if [ -z "$HOST" ]; then
    echo "错误：拿不到域名。请设置 APP_DOMAIN（或 APP_SHARE_HOST / APP_WS_HOST）。" >&2
    exit 1
fi

# ------------------------------------------------------------ URL 编码 ----
# busybox 无现代 sed，用 od 逐字节判断，按 RFC 3986 unreserved 之外全部百分号编码。
# 转义用 POSIX 的 \NNN（八进制）：printf 的 \xHH 在 dash/bash 下不通用，容器里是 ash。
urlencode() {
    str="$1"
    out=""
    hex="$(printf '%s' "$str" | od -An -v -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')"
    while [ -n "$hex" ]; do
        byte="${hex%"${hex#??}"}"
        hex="${hex#??}"
        case "$byte" in
            2D|2E|5F|7E|3[0-9]|4[1-9A-F]|5[0-9A]|6[1-9A-F]|7[0-9A]) out="$out$(printf "\\$(printf '%03o' "0x$byte")")" ;;
            *) out="$out$(printf '%%%s' "$byte")" ;;
        esac
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------- 校验 ----
case "$UUID" in
    ????????-????-????-????-????????????) ;;
    *) echo "警告：UUID 格式看起来不标准：$UUID" >&2 ;;
esac

SECURITY_PARAM="tls"
if [ "$INSECURE" = "true" ]; then
    SECURITY_PARAM="tls&allowInsecure=1"
fi

ENC_UUID="$(urlencode "$UUID")"
ENC_PATH="$(urlencode "$WS_PATH")"
ENC_SNI="$(urlencode "$SNI")"
ENC_LABEL="$(urlencode "$LABEL")"

LINK="vless://${ENC_UUID}@${HOST}:${PORT}?encryption=none&security=${SECURITY_PARAM}&type=ws&host=${HOST}&sni=${ENC_SNI}&path=${ENC_PATH}#${ENC_LABEL}"

# ---------------------------------------------------------------- 输出 ----
OUT="$(cat <<EOF
# 生成参数（请核对与 .env 一致）
UUID     = ${UUID}
地址     = ${HOST}
端口     = ${PORT}
SNI      = ${SNI}
WS 路径  = ${WS_PATH}
标签     = ${LABEL}

# 分享链接（整行复制）
${LINK}
EOF
)"

printf '%s\n' "$OUT"

# 容器内由入口脚本设置 APP_SHARE_OUT，把结果同时落到可读文件里。
# 写文件是附加能力：失败只警告，不影响 stdout 的链接与退出码。
if [ -n "${APP_SHARE_OUT:-}" ]; then
    if ! ( umask 077; mkdir -p "$(dirname "$APP_SHARE_OUT")" && \
           printf '%s\n' "$OUT" > "$APP_SHARE_OUT" ) 2>/dev/null; then
        echo "警告：无法写入 $APP_SHARE_OUT，请直接使用上面的链接。" >&2
    fi
fi
