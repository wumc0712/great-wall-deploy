#!/bin/sh
# 构建期去品牌：对上游二进制做「等长字符串替换」。
#
# 为什么必须等长：Go 二进制的字符串常量与编译期写死的长度/索引元数据混排在一起，
# 长度一变，那些元数据全部失配——轻则输出错乱，重则启动即崩。只改字节、不改长度，
# 就能在不重新编译、不重新签名的前提下换掉品牌字样。
#
# 本脚本只在 builder 阶段运行，产物留在构建期，不进运行层镜像。
set -eu

BIN="${1:-/out/relay}"
log() { printf 'debrand: %s\n' "$*" >&2; }
die() { log "错误：$*"; exit 1; }

[ -f "$BIN" ] || die "找不到二进制：$BIN"

# ----------------------------------------------------------- 替换表 ---------
# 每行是「标记 + 原串|替换串」：
#   !  必需——二进制里找不到原串就构建失败（说明上游改了字符串，本表该更新）
#   ?  可选——存在才替换
#
# 硬性约束（脚本逐条断言，不满足就构建失败）：
#   * 原串与替换串字节数必须完全相等；
#   * 只允许 [A-Za-z0-9 ,._/:@-] ——这样 sed 模式里需要转义的只有 '.'，
#     替换串里需要转义的字符已被排除，避免踩 POSIX BRE 的未定义转义。
#
# 只匹配**读取路径上的确切文本**，不做「凡是含 V2Ray 就改」的全局替换——
# 后者会连带改掉二进制内 proto 描述符里的大写类型名（`V2Ray.Core.*`，98 处），
# 那些数据会进 protobuf 注册表，属于能不碰就不碰的部分。
#
# 第 1 行「V2Ray 」尾随的空格是模式的一部分：横幅首行与启动日志行都是
# "<名称> <版本> …" 的形态（`V2Ray 5.41.0 …`），靠这个空格同时覆盖两者。
# 它也不会误伤 `V2Ray.Core`（点号紧跟，不是空格）。
#
# 有意不改的部分（详见 README「去特征化说明」）：
#   * proto 描述符里的大写类型名 `V2Ray.Core.*`（98 处）与其实用小写包名
#     `v2ray.core.*`（569 处）：会进 protobuf 注册表，改动收益低而风险高；
#   * 裸 `v2ray` 子串（约 1.1 万处，绝大多数是 proto 包路径）；
#   * 少数编译期符号名（如 `startV2Ray`）与功能默认域名 `v2fly.org`。
table() {
    cat <<'EOF'
!V2Ray |Relay 
!V2Fly, a community-driven edition of V2Ray.|Relay, a community-driven edition of Relay.
!A unified platform for anti-censorship.|Lightweight internal services platform.
?V2Ray: |Relay: 
?github.com/v2fly/v2ray-core/v5|example.com/relay-service/core
?github.com/v2fly/v2ray-core/v4|example.com/relay-service/core
EOF
}

# ------------------------------------------------------------ 辅助 ----------
# 模式里唯一需要转义的 BRE 元字符是 '.'（其余元字符已由字符集校验排除）。
escape_pattern() { printf '%s' "$1" | sed -e 's/\./\\./g'; }

# busybox grep 默认把 NUL 当作「行」的终止符，只搜索 NUL 之前的内容，
# 用它检查二进制会漏报（已实测：匹配被 NUL 包夹时识别不到）。
# -z 把分隔符改成 NUL，行边界不再是 NUL，于是能在整个二进制里如实搜索。
contains() { grep -F -q -a -z -- "$1" "$2"; }

# 替换串不必转义：'\'、'&'、'|' 均已被字符集校验排除。
needs_escape() {
    case "$1" in
        *[!A-Za-z0-9,\ ._/:@-]*) return 0 ;;
        *) return 1 ;;
    esac
}

SED_SCRIPT="${TMPDIR:-/tmp}/debrand.$$.sed"
trap 'rm -f "$SED_SCRIPT"' EXIT INT TERM
: > "$SED_SCRIPT"

# ------------------------------------------------------ 校验并生成脚本 ------
# while 在管道子 shell 中，die 只能终止子 shell；故用管道整体退出码在末尾兜底。
table | while IFS='|' read -r lhs rep; do
    [ -n "$lhs" ] || continue
    case "$lhs" in
        '!'*) required=1; pat="${lhs#!}" ;;
        '?'*) required=0; pat="${lhs#?}" ;;
        *)    die "替换表行缺少 !/? 标记：$lhs" ;;
    esac
    [ -n "$pat" ] || die "替换表里原串为空"
    [ -n "$rep" ] || die "替换表里替换串为空（原串：[$pat]）"
    # 这里必须用 if：`needs_escape ... && die ...` 在不需要转义时会以非零码结束整条
    # 语句，set -e 会把脚本直接终止。
    if needs_escape "$pat"; then die "原串含不支持的字符：[$pat]"; fi
    if needs_escape "$rep"; then die "替换串含不支持的字符：[$rep]"; fi
    if [ "${#pat}" -ne "${#rep}" ]; then
        die "原串与替换串长度不等（${#pat} vs ${#rep}）：[$pat] => [$rep]"
    fi
    if [ "$required" -eq 1 ] && ! contains "$pat" "$BIN"; then
        die "必需项在二进制里找不到（上游字符串已变？）：[$pat]"
    fi
    printf 's|%s|%s|g\n' "$(escape_pattern "$pat")" "$rep" >> "$SED_SCRIPT"
done || die "替换表校验未通过，详见上方输出"

[ -s "$SED_SCRIPT" ] || die "替换表为空"

# -------------------------------------------------------------- 替换 --------
ORIG_SIZE="$(wc -c < "$BIN")"
TMP="${BIN}.debrand.$$"
rm -f "$TMP"
if ! sed -f "$SED_SCRIPT" "$BIN" > "$TMP"; then
    rm -f "$TMP"; die "sed 处理失败"
fi
NEW_SIZE="$(wc -c < "$TMP")"
if [ "$ORIG_SIZE" != "$NEW_SIZE" ]; then
    rm -f "$TMP"
    die "替换改变了文件大小（$ORIG_SIZE -> $NEW_SIZE），存在不等长的替换串"
fi

# -------------------------------------------------------------- 复核 --------
table | while IFS='|' read -r lhs rep; do
    [ -n "$lhs" ] || continue
    pat="${lhs#?}"
    if contains "$pat" "$TMP"; then
        die "替换后仍能匹配到原串：[$pat]"
    fi
done || { rm -f "$TMP"; die "残留检查未通过，详见上方输出"; }

# 替换后仍须是可运行程序：v5 认 version 子命令，v4 只认 -version。
chmod 0755 "$TMP"
VER_OUT=""
if VER_OUT="$("$TMP" version 2>&1)"; then
    :
elif VER_OUT="$("$TMP" -version 2>&1)"; then
    :
else
    rm -f "$TMP"; die "替换后二进制无法执行，已放弃（请检查替换表）"
fi
case "$VER_OUT" in
    *V2Ray*) rm -f "$TMP"; die "版本输出仍含品牌字样：$VER_OUT" ;;
    *Relay*) log "版本输出已中性化：$(printf '%s' "$VER_OUT" | head -n 1)" ;;
    *)       log "警告：版本输出未见预期的中性名，请人工确认：$VER_OUT" ;;
esac

# 写回原路径（用重定向而非 mv，保留 inode 与权限位）。
if ! cat "$TMP" > "$BIN"; then
    rm -f "$TMP"; die "写回失败：$BIN"
fi
rm -f "$TMP"
log "完成：$BIN（$ORIG_SIZE 字节，长度未变）"
