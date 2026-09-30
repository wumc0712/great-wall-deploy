#!/bin/sh
# 在 builder 阶段（官方 v2fly/v2fly-core 镜像内）定位并抽取运行时需要的文件。
#
# 不写死路径：不同大版本的官方镜像内部布局可能不同，这里按候选路径 + 全局查找
# 定位，找不到就明确失败，避免构建出一个缺文件的镜像。
set -eu

OUT="${1:-/out}"
mkdir -p "$OUT"

# ---- 二进制 ---------------------------------------------------------------
# 上游镜像内文件名固定为 v2ray（构建期内部路径，不进运行时镜像）。
BIN=""
for candidate in /usr/local/bin/v2ray /usr/bin/v2ray /opt/v2ray/v2ray; do
    if [ -x "$candidate" ]; then
        BIN="$candidate"
        break
    fi
done
if [ -z "$BIN" ]; then
    BIN="$(find / -xdev -type f -name 'v2ray' -perm -u+x 2>/dev/null | head -n 1 || true)"
fi
[ -n "$BIN" ] || { echo "extract: 在 builder 镜像中找不到上游二进制" >&2; exit 1; }
echo "extract: binary = $BIN"

# ---- geo 数据 --------------------------------------------------------------
find_data() {
    name="$1"
    for dir in "${V2RAY_LOCATION_ASSET:-}" /usr/local/share/v2ray /usr/share/v2ray /etc/v2ray; do
        [ -n "$dir" ] || continue
        if [ -f "$dir/$name" ]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done
    find / -xdev -type f -name "$name" 2>/dev/null | head -n 1
}

GEOIP="$(find_data geoip.dat)"
[ -n "$GEOIP" ] || { echo "extract: 找不到 geoip.dat" >&2; exit 1; }
echo "extract: geoip.dat   = $GEOIP"

GEOSITE="$(find_data geosite.dat)"
[ -n "$GEOSITE" ] || { echo "extract: 找不到 geosite.dat" >&2; exit 1; }
echo "extract: geosite.dat = $GEOSITE"

# ---- 落盘 ------------------------------------------------------------------
# 输出文件名用中性名，Dockerfile 侧再按 APP_BIN_NAME 落到最终路径。
cp "$BIN" "$OUT/relay"
cp "$GEOIP" "$OUT/geoip.dat"
cp "$GEOSITE" "$OUT/geosite.dat"
chmod 0755 "$OUT/relay"

# v4 需要 v2ctl 辅助生成 geo 数据；有就一并带上，没有也不影响服务端运行。
for candidate in /usr/local/bin/v2ctl /usr/bin/v2ctl; do
    if [ -x "$candidate" ]; then
        cp "$candidate" "$OUT/v2ctl"
        chmod 0755 "$OUT/v2ctl"
        echo "extract: v2ctl        = $candidate"
        break
    fi
done

ls -l "$OUT"
