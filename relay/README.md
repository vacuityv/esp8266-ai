# AI-Clock 跨网中继 (relay)

当**时钟**和**桥接端 Mac** 不在同一个局域网时(例如 Mac 在 `YUGUO-R.D`、时钟在
`YUGUO-moblie`,两者不同网段),时钟无法直接访问 Mac 的本地 HTTP 服务。这个中继解决它:

```
Mac (任意网络)                     VPS (公网)                     时钟 (任意 2.4G 网络)
  RelayPusher 每 1s              relay.py 内存里                  bridgeHost 指向 VPS
  POST /ingest/<key>   ───►      只存"每个路由的最新一份"  ◄───   GET /r/<secret>/status ...
  (Authorization: Bearer)                                        (拿到的字节 == Mac 本地服务返回的)
```

**关键点**:中继只是"原样搬运字节"。时钟拉到的 `/status`、`/net`、`/music`、
`/music/cover.raw`、`/music/text.raw` 和原来 Mac 本地返回的完全一致,所以**固件一行都不用改**,
只需把 `bridgeHost` 设成 VPS 地址(见下)。`/net` 的 `seq` 增量逻辑照常工作,因为 Mac 的 JSON 被逐字转发。

## v2:反向控制通道

除了遥测,同一个中继还承载**反向的控制/查询**(让菜单栏跨段也能看设备信息、切显示模式、传 GIF):

```
读设备信息:  时钟 ─POST /r/<secret>/deviceinfo─► VPS ◄─GET /control/deviceinfo─ Mac(Bearer)
下发命令:    Mac ─POST /control/command(Bearer)─► VPS ◄─GET /r/<secret>/commands─ 时钟(取即清空)
传 GIF:      Mac ─POST /control/gif/<slot>(Bearer)► VPS ◄─GET /r/<secret>/gif/<slot>─ 时钟
```

- 时钟侧全部走 `/r/<secret>/...` 能力路径(固件只是往 `bridgeHost` 后拼路径),Mac 侧用 `Bearer <PUSH_TOKEN>`。
- 命令 JSON:`{"type":"display","mode":"claude"}`、`{"type":"reset","slot":"claude"}`、
  `{"type":"sprite","slot":"claude"}`(配合先传 GIF)、`{"type":"bridge","host":"..."}`。
- Mac 端:配了中继时 `DeviceClient` 的 `fetchInfo`/切模式/传 GIF 自动改走这些接口(见 `RelayPusher` 同款配置)。
- 固件端:每 10s 上报 `deviceinfo`、每 3s 轮询 `commands` 并本地执行。

> ⚠️ **固件的反向通道尚未在硬件上验证**(写好、审查过,但开发机无 ESP8266 工具链)。中继 + Mac 两端已用 curl 模拟设备实测通过。

## 文件

| 文件 | 作用 |
|---|---|
| `relay.py` | 中继本体,Python 3 stdlib,零第三方依赖 |
| `aiclock-relay.service` | systemd 单元,常驻 + 开机自启 |
| `aiclock-relay.env.example` | 环境变量模板(真实密钥不进 repo) |

## 一、部署到 VPS

```bash
# 1. 上传
scp relay/relay.py            <vps>:/tmp/relay.py
scp relay/aiclock-relay.service <vps>:/tmp/aiclock-relay.service
ssh <vps> 'sudo mkdir -p /opt/aiclock-relay \
  && sudo mv /tmp/relay.py /opt/aiclock-relay/relay.py \
  && sudo mv /tmp/aiclock-relay.service /etc/systemd/system/aiclock-relay.service'

# 2. 生成密钥并写 /etc/aiclock-relay.env(权限 600)
ssh <vps> 'sudo bash -c "cat > /etc/aiclock-relay.env <<EOF
RELAY_PORT=8080
PUSH_TOKEN=$(openssl rand -hex 16)
PULL_SECRET=$(openssl rand -hex 8)
EOF
chmod 600 /etc/aiclock-relay.env"'

# 3. 启动
ssh <vps> 'sudo systemctl daemon-reload && sudo systemctl enable --now aiclock-relay'
```

- `PUSH_TOKEN` — Mac 推送时的 Bearer token(私密)。
- `PULL_SECRET` — 时钟拉取路径里的密钥,`/r/<PULL_SECRET>/...`(半公开:会出现在设备配置里)。

**⚠️ 云防火墙**:必须在 **腾讯云/云厂商安全组** 放行 **TCP `RELAY_PORT`(默认 8080)**,
来源 `0.0.0.0/0`(或收窄到时钟出口 IP)。VPS 上的 ufw 若启用也要一并放行。

## 二、配置 Mac(桥接端)

`RelayPusher` 是 opt-in 的。配置来源优先级:环境变量 > `~/.config/aiclock/relay.env`。
因为 `.app` 用 `open` 启动**不继承 shell 环境变量**,推荐用配置文件:

```bash
mkdir -p ~/.config/aiclock
cat > ~/.config/aiclock/relay.env <<EOF
RELAY_BASE=http://<vps-ip>:8080
RELAY_TOKEN=<PUSH_TOKEN 的值>
# 可选:纯中继场景关掉本地 :8765 服务(见下)
# LOCAL_HTTP=off
EOF
chmod 600 ~/.config/aiclock/relay.env
```

不配置这个文件(也不给 env)时,relay 功能休眠,app 行为和以前完全一样(只跑本地服务)。

### 可选:`LOCAL_HTTP` —— 关掉本地 :8765 服务

app 默认在 `0.0.0.0:8765` 开本地 HTTP 服务,供**同网时钟**轮询。走中继(时钟和 Mac 不同网)
时这个本地服务用不上,可以关掉:在上面的配置文件里(或用环境变量)加

```
LOCAL_HTTP=off      # on/1/true 开(默认);off/0/false 关
```

**⚠️ 注意**:`:8765` 上同时挂着 `POST /event`,是 Claude Code / Codex 的 **hook 实时事件**入口
(hook 往 `127.0.0.1:8765/event` 推)。`LOCAL_HTTP=off` 会**一并关掉这个 hook 入口**。

- 不用 hook 实时事件(只靠日志扫描 + 配额)→ 可放心关,少开一个 LAN 端口。
- 在用 hook → 保持默认开(`LOCAL_HTTP` 不设或设 on)。

关闭后 app 只做一件事:把数据推到中继。

## 三、配置时钟

配网门户里把 **Bridge 地址**填成(注意带上密钥路径):

```
<vps-ip>:8080/r/<PULL_SECRET>
```

固件是 `"http://" + bridgeHost + "/status"` 纯拼接,所以上面这串会被拼成
`http://<vps-ip>:8080/r/<PULL_SECRET>/status`,正好命中中继的拉取路由。

## 四、自测

```bash
# 健康页(无需密钥,只显示各路由的大小/新鲜度)
curl http://<vps-ip>:8080/health

# 冒充 Mac 推一条,再冒充时钟拉回来
curl -X POST -H "Authorization: Bearer <PUSH_TOKEN>" --data '{"t":1}' \
     http://<vps-ip>:8080/ingest/status
curl http://<vps-ip>:8080/r/<PULL_SECRET>/status     # 应回 {"t":1}
curl -o /dev/null -w '%{http_code}\n' http://<vps-ip>:8080/r/wrong/status   # 应 403
```

## 运维

```bash
systemctl status aiclock-relay
journalctl -u aiclock-relay -f
sudo systemctl restart aiclock-relay   # 改了 /etc/aiclock-relay.env 后
```

## 安全说明

- 时钟只能走 **HTTP**(ESP8266 上 HTTPS 太重),所以拉取靠"密钥藏在路径里"的能力 URL 防路人,
  不是强加密。想更严可把安全组来源收窄到时钟出口 IP。
- 推送侧有 `PUSH_TOKEN` Bearer 校验,`/health` 不暴露任何 payload,只报大小和时间。
- 密钥只存在于 VPS 的 `/etc/aiclock-relay.env`(600)和 Mac 的 `~/.config/aiclock/relay.env`(600),
  **不进 git**。
