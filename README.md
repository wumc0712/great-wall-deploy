# great-wall-deploy

[v2ray-core](https://github.com/v2fly/v2ray-core) 的服务端 Docker 方案，协议为 **VLESS + WebSocket**，带一层**静态站点伪装**与**去特征化命名**。

## 架构

两个容器，**TLS 在容器内终止**（不再依赖 CDN）：

```
客户端 ──443/TLS──> edge (Caddy)  ──明文 WS──> app (服务)
                      │
                      └─ 其余请求一律返回静态站点
```

| 容器 | 作用 |
| --- | --- |
| `edge` | Caddy。自动申请/续期 Let's Encrypt 证书，终止 TLS；只有「路径 + WS 升级头」同时匹配的请求才转发给后端，其余一律返回 `web/` 里的静态站点 |
| `app` | 实际服务。只在内网监听明文 WS，**不映射端口到公网** |

这样做的两个好处：

1. **主动探测拿到的是一个正常小站**，而不是 `404` + 无 `Server` 头这种典型指纹；
2. **明文 WS 端口不暴露**，公网无法直接扫描到它。

## 文件结构

```
.
├── Dockerfile                  多阶段构建：官方镜像取二进制 → alpine 运行时
├── docker-compose.yml          edge + app 两个服务
├── .env.example                变量说明，复制为 .env 使用
├── caddy/
│   └── Caddyfile               终止 TLS + 按路径/升级头分流 + 静态页回调
├── web/                        伪装用的静态站点（自行替换成你的内容）
│   ├── index.html
│   ├── 404.html
│   ├── assets/style.css
│   └── ...
├── config/
│   └── config.json.template    配置模板，占位符由入口脚本替换
├── docker/
│   ├── entrypoint.sh           渲染配置 + 校验环境变量 + 启动前生成分享链接
│   ├── extract-artifacts.sh    在 builder 阶段定位并抽出发行产物
│   └── debrand.sh              构建期对二进制做等长品牌字符串替换
└── scripts/
    └── share-link.sh           生成 VLESS 分享链接；也会装进镜像供容器内调用
```

## 去特征化说明

运行时镜像内不出现上游名称，具体做法与**做不到的部分**：

| 项目 | 处理 |
| --- | --- |
| 二进制文件名 | 改由 `APP_BIN_NAME` 决定（默认 `relay`），进程名与文件名随之改变 |
| 安装路径 | `/usr/local/bin/<APP_BIN_NAME>`、`/usr/local/share/app/`、`/etc/app/` |
| 镜像 LABEL | `org.opencontainers.image.*` 全部中性化 |
| 容器名/镜像名 | `APP_CONTAINER_NAME`、`APP_IMAGE`、`EDGE_CONTAINER_NAME` |
| 配置 `tag` | `ws-in` / `direct` / `drop`，不再有上游命名 |
| 变量前缀 | 全部 `APP_*` |
| **进程环境变量** | **`V2RAY_LOCATION_ASSET` 无法去掉**——它由二进制自身读取，用来定位 `geoip.dat`/`geosite.dat`，只能显式 export |
| **二进制内的品牌字符串** | 由 `docker/debrand.sh` 在构建期做**等长替换**（见下节） |

### 二进制内的品牌字符串替换

上游二进制会自己打印品牌名（启动横幅、"… started" 日志行、`help` 输出），
这些不受配置控制，只能改二进制。`docker/debrand.sh` 在 builder 阶段对它做替换，
替换规则有两类：

- **纯品牌字面量**：启动横幅 `V2Ray <版本>`、社区版说明、一行标语、`help` 里的
  `V2Ray: ` 字段，以及编译进来的模块路径 `github.com/v2fly/v2ray-core/v5`；
- **必须等长**：Go 的字符串常量与编译期写死的长度/索引元数据混排在一起，长度一变
  那些元数据即失配（轻则输出错乱，重则启动即崩）。脚本对替换表逐条断言长度相等，
  并在替换后复核文件字节数没变，否则构建失败。

脚本只匹配**读取路径上的确切文本**，不做"凡含 `V2Ray` 就改"的全局替换，因此二进制里
仍会保留一些上游标识：

- proto 描述符里的大写类型名 `V2Ray.Core.*`（98 处）与小写包名 `v2ray.core.*`（569 处）：
  会进 protobuf 注册表，改动收益低、风险高；
- 裸 `v2ray` 子串（约 1.1 万处，绝大多数是 proto 包路径与编译期符号名）；
- 少数编译期符号名（如 `startV2Ray`）；
- 功能默认域名 `v2fly.org`（如 `udp:v2fly.org:6666`）——改动收益低，且不属于品牌输出。

也就是说：**运行时可观察到的品牌输出已中性化，但静态扫描二进制仍能看到上游包名**，
只靠 `strings` 扫描并不能做到"零命中"。

脚本还会在替换后做自检：替换表里标记 `!` 的条目必须在二进制里找到（上游改了字符串
就让构建失败，而不是静默漏掉）；替换后必须仍能执行 `version` 且输出里不再有品牌字样。
构建期设 `--build-arg DEBRAND=false` 可整体跳过。

> 如需更彻底的处理（字符串混淆、UPX 等），请在 `Dockerfile` 的 builder 阶段
> 追加步骤，并保证替换后仍能通过 `version` 自检。

## 构建方式

镜像来源为 Docker Hub 官方仓库 `v2fly/v2fly-core`（由 [v2fly/docker](https://github.com/v2fly/docker) 构建），内含 `v2ray` 二进制与 `geoip.dat` / `geosite.dat`。

`Dockerfile` 做**多阶段资源抽取**：builder 阶段用官方镜像，只 COPY 出二进制与两份 geo 数据，再放进干净的 `alpine` 运行时层，并在此期间改名。好处是运行层不含编译期冗余，也不需要构建时访问 GitHub Release。

> 注意：`ghcr.io/v2fly/...` 的匿名拉取会被拒绝，因此这里只用 Docker Hub 的官方镜像。
> 上游镜像名只出现在**构建期**，运行层内不含上游标识。

## 快速开始

前提：

- 一台**允许此类用途**的 VPS（先看它的 AUP/ToS，不是所有服务商都允许）；
- 一个域名，A/AAAA 记录指向该 VPS；
- VPS 上放行 80 与 443（80 用于 ACME HTTP-01 挑战）。

```bash
cp .env.example .env
# 编辑 .env：至少填 APP_DOMAIN（你的域名）；APP_WS_PATH 建议改成强随机值
docker compose up -d --build

# 看日志（首次启动会申请证书，需要几十秒）
docker compose logs -f front      # edge：证书申请情况
docker compose logs -f relay      # app：服务日志

# 未设置 APP_UUID 时，查看自动生成并持久化的 UUID
cat data/uuid

# 分享链接（启动时自动生成）
cat data/share-link.txt
```

仅用 Docker 不借助 compose（注意：**这样会丢掉静态页伪装**，只建议本机验证时使用）：

```bash
docker build -t relay:v5.41.0 .

docker run -d --name relay \
  -p 10000:10000 \
  -e APP_PORT=10000 \
  -e APP_WS_PATH=/vless-ws \
  -e APP_DOMAIN=your.domain.com \
  -v "$PWD/data:/etc/app" \
  relay:v5.41.0
```

## 服务端配置

容器启动时由 `docker/entrypoint.sh` 把 `config/config.json.template` 渲染成 `/run/app/config.json`，渲染结果可在容器内直接查看：

```bash
docker compose exec app cat /run/app/config.json
```

关键字段：

| 字段 | 值 | 说明 |
| --- | --- | --- |
| `inbounds[0].protocol` | `vless` | |
| `inbounds[0].settings.decryption` | `none` | VLESS 服务端固定为 `none` |
| `inbounds[0].settings.clients[].flow` | `""` | **必须为空**，`xtls-rprx-vision` 仅用于 TLS 直连，与 WS 不兼容 |
| `inbounds[0].streamSettings.network` | `ws` | |
| `inbounds[0].streamSettings.security` | `none` | TLS 在 edge 层终止 |
| `inbounds[0].streamSettings.wsSettings.path` | 由 `APP_WS_PATH` 指定 | 需与客户端及 Caddyfile 一致 |
| `outbounds[0]` | `direct` / `freedom` | **出站列表第一项即默认出站**，不要把 `drop` 放前面 |

### 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SRC_VERSION` | `v5.41.0` | 构建参数，指定上游官方镜像 tag |
| `APP_BIN_NAME` | `relay` | 构建参数，容器内二进制名（即进程名） |
| `DEBRAND` | `true` | 构建参数，是否对二进制内品牌字符串做等长替换（`false` 时保留上游品牌字样，仅供排查构建问题） |
| `APP_IMAGE` / `APP_CONTAINER_NAME` / `EDGE_CONTAINER_NAME` | `relay` / `relay` / `front` | 镜像与容器命名 |
| `APP_DOMAIN` | 空 | **必填**，对外域名；用于申请证书与生成链接。留空退化为只监听 80（无证书） |
| `ACME_EMAIL` | 空 | Let's Encrypt 通知邮箱，可留空 |
| `APP_PORT` | `10000` | 容器内明文 WS 监听端口，**不映射到公网** |
| `APP_WS_PATH` | `/vless-ws` | WS 路径，**建议改成不易猜测的长随机值** |
| `APP_UUID` | 空 | 留空则首次启动生成并持久化到 `./data/uuid` |
| `APP_EMAIL` | `app` | 日志中标识该客户端 |
| `APP_WS_HOST` | 空 | 限定 `Host` 头，留空不校验；设为 `APP_DOMAIN` 可收紧 |
| `APP_SHARE_HOST` | 空 | 分享链接里的域名，留空取 `APP_DOMAIN` |
| `APP_SHARE_PORT` | `443` | 分享链接里的端口 |
| `APP_LOG_LEVEL` | `warning` | `debug`/`info`/`warning`/`error`/`none` |
| `APP_LOG_ACCESS` / `APP_LOG_ERROR` | 空 | 留空输出到容器 stdout/stderr |
| `APP_SNIFFING` | `true` | 流量嗅探，用于按域名分流 |
| `APP_DOMAIN_STRATEGY` | `UseIP` | 出站解析策略 |
| `APP_BLOCK_PRIVATE` | `true` | 丢弃目标为私网地址的出站流量，避免被当作内网跳板 |
| `APP_CLI` | `auto` | 主版本探测；仅在自动识别异常时才需强制 `v4`/`v5` |

脚本会对 `APP_PORT`、`APP_WS_PATH`、`APP_UUID`、`APP_EMAIL`、`APP_LOG_LEVEL`、`APP_SNIFFING`、`APP_DOMAIN_STRATEGY`、`APP_BLOCK_PRIVATE`、`APP_WS_HOST`、`APP_CLI` 做校验，非法值会让容器直接以非零码退出并打印原因，而不是带着坏配置启动。其中 `APP_WS_PATH`、`APP_EMAIL`、`APP_WS_HOST` 只允许安全字符集，避免破坏生成的 JSON。

> **从旧版本升级**：变量前缀已从 `V2RAY_*` 改为 `APP_*`，容器内路径也从 `/etc/v2ray` 改为 `/etc/app`。请按 `.env.example` 重命名你的 `.env`，并注意 UUID 文件位置变化——否则服务端会生成新 UUID，已下发的客户端配置全部失效。

## v4 / v5 差异

两个大版本的命令行参数**互不兼容**，入口脚本会自动探测并分支：

| | v4（如 `v4.45.2`） | v5（如 `v5.41.0`） |
| --- | --- | --- |
| 启动参数 | `<bin> -c <config>` | `<bin> run -c <config>` |
| 版本输出 | `<bin> -version` | `<bin> version` |
| 配置校验 | `<bin> -test -config <config>` | `<bin> test -c <config>` |

切换版本只需改 `SRC_VERSION`。实测两个版本的服务端配置模板通用（`v4.45.2` 与 `v5.53.0` 均已通过校验并完成 VLESS+WS 连通）。

## 伪装与探测行为

- 根路径与任何不匹配的请求 → 静态站点（返回 200，正常 HTML）。
- 路径匹配但**没有 WS 升级头**的 GET 请求 → 同样落到静态页（这是与"裸后端"最大的区别：裸后端会返回 `404`）。
- 路径与升级头都匹配 → 转发到后端，返回 `101 Switching Protocols`。
- 响应头去掉 `Server`，补 `Referrer-Policy`、`X-Content-Type-Options`。

自测：

```bash
# 应看到一个正常的静态站点
curl -sI https://your.domain.com/ | head -n 5
curl -s  https://your.domain.com/ | head -n 3

# 应看到 404 静态页，而不是后端错误
curl -s -o /dev/null -w '%{http_code}\n' https://your.domain.com/nope
```

> `web/` 里是占位内容。请替换成你自己的站点——**千篇一律的伪装页本身就是一种指纹**。

## 安全注意事项

- 明文 WS 端口只在容器内网暴露，**不要**在 compose 里给它加 `ports`。
- WS 路径用强随机值，降低被主动探测识别的概率。
- `edge` 需要绑定 80/443 与读写 `/data`，故保留了 `NET_BIND_SERVICE`；两个容器都以 `read_only` + `cap_drop: [ALL]` + `no-new-privileges` 运行。
- 证书数据存在 `caddy_data` 卷里，**不要删**：删除后重启会重新申请，可能触发 Let's Encrypt 速率限制。
- 若设置了 `APP_LOG_ACCESS` / `APP_LOG_ERROR` 为文件路径，在 `read_only: true` 下需额外挂载可写卷，否则容器启动即失败。
- 域名与证书是明文可查的公开信息；本方案解决的是**主动探测**，不隐藏"这台机器在跑什么"。

## 已验证的行为

以下在本机用真实 v2ray 二进制（`v4.45.2`、`v5.53.0`）配合 busybox（容器内同一套 shell/sed 实现）实测确认：

- 渲染出的配置在 v4 与 v5 下均通过 `test` 校验，并能完成 VLESS + WS 端到端代理。
- 明文 WS 端口对未升级 HTTP 请求返回 `404`，对错误路径返回 `404`，仅在路径匹配且携带 WS 升级头时返回 `101`。
- `APP_BLOCK_PRIVATE=true` 时，私网目标被丢弃，公网目标走 `direct`。
- 所有环境变量校验分支均按预期拒绝非法输入并以非零码退出。

去品牌替换（`docker/debrand.sh`）已用真实 `v5.41.0` 二进制实测（用 busybox 工具集模拟
容器内的工具实现）：

- 替换前后文件字节数完全一致（35 639 444 字节），对全量做逐字节比对后，**所有差异段
  长度相等**，且没有任何差异段跨越 `NUL`；
- `version` / `help` / `test` 三条路径的输出与退出码和原始二进制一致，横幅与标语已中性化；
- 用替换后的二进制同时作服务端与客户端，VLESS + WS 端到端代理连通，日志里
  `… started` 行显示为 `Relay <版本>`（原始二进制为 `V2Ray <版本>`）；
- 必需项缺失、替换串长度不等、文件不存在三种情况均以非零码退出并给出原因；
- 对已去品牌的二进制重复执行会明确报错（而不是静默通过）。

改造为「Caddy 伪装层 + 去特征化命名」后，以下已用 dash 与 busybox `sh` 模拟容器环境回归通过：

- 入口脚本语法、占位符全量替换、UUID 生成与复用；
- 渲染结果不含上游命名（`tag` 已中性化）；
- 分享链接的域名优先级 `APP_SHARE_HOST` → `APP_DOMAIN` → `APP_WS_HOST`；
- 非法输入被拒绝，域名缺失时只警告不阻断启动。

尚未实测（本机无 Docker）：`docker build` 全流程（含 builder 阶段去品牌与 `grep` 冒烟测试）、Caddy 证书申请、以及真实的反代分流行为。
