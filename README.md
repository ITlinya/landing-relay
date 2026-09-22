# landing-relay

落地服务器（出口机）一键部署脚本。用来给 VLESS-REALITY 节点加一层干净 IP 的出口。

很多线路服务器的情况是：到大陆的线路很好，但 IP 纯净度差，Google 老是要验证码、流媒体解锁不了、部分站点直接拒绝。而纯净 IP 的机器往往线路绕、延迟高，直连体验又不好。

这个脚本把两者拼起来：线路机继续负责"快"，落地机负责"干净"。

```
客户端  ──VLESS-REALITY──▶  线路机  ──Shadowsocks-2022──▶  落地机  ──▶  互联网
        （好线路，低延迟）              （纯净 IP 出口）
```

客户端配置完全不用改，还是连原来那台线路机的 reality 入口。变的只是流量最终从哪里出公网。

## 为什么用 Shadowsocks-2022 做中转

这一跳可选的方案不少（WireGuard、VLESS-TLS、Hysteria2 等），这里选 SS-2022 的理由：

- **纯 TCP**，不需要开 UDP 端口，也不用去改云服务商的安全组规则。用过 WireGuard 双跳的都知道，Oracle、GCP 这类平台漏放一条 UDP 规则就得排查半天。
- **不需要域名和证书**，落地机拿到就能用，不用等 DNS 生效或者跑 acme。
- **无内核模块依赖**，不挑内核版本，OpenVZ/LXC 小鸡也能跑。
- **CPU 开销低**，AEAD 加密对转发性能影响很小。
- **换机成本低**，落地机换了重跑一遍脚本就行。

代价是 SS-2022 的流量特征比 reality 明显。但这一跳是线路机到落地机的内部链路，不面向被审查的客户端侧，所以可以接受。**面向客户端的那一跳仍然是 reality，抗审查能力没有变化。**

## 环境要求

- Debian 12（主要测试目标），同时兼容 Debian 11+ / Ubuntu 20.04+
- systemd（Alpine 等 OpenRC 系统需另行适配）
- root 权限
- 线路机侧运行 Xray-core，配置在 `/usr/local/etc/xray/config.json`

## 快速开始

### 第一步：落地机

```bash
curl -fsSLO https://raw.githubusercontent.com/ITlinya/landing-relay/main/landing-relay.sh
bash landing-relay.sh --upstream=你的线路机IP
```

不带参数直接运行会交互式询问上游 IP：

```bash
bash landing-relay.sh
```

端口和密钥会自动随机生成。脚本跑完会把**线路机那边需要执行的完整命令**直接打印出来。

### 第二步：线路机

把上一步输出的那段命令原样复制到线路机执行。它会：

1. 备份现有 `config.json`
2. 添加一个 tag 为 `landing-out` 的 shadowsocks 出站
3. 追加一条把 tcp/udp 流量指向该出站的路由规则
4. `xray run -test` 自检，**通过才写入并重启**

### 第三步：验证

客户端连上 reality 后访问 <https://ipinfo.io/ip>，看到落地机 IP 就说明两跳通了。

## 参数

| 参数 | 说明 |
|---|---|
| `--upstream=IP` | 上游线路机 IP。多个用逗号分隔，支持 CIDR 和 IPv6 |
| `--port=N` | 中转端口。默认在 20000–49999 随机选一个未占用的 |
| `--password=KEY` | 指定 PSK。必须是 base64 编码的 16 字节 |
| `--ipv6` | 出口策略改为 `UseIP`（v4/v6 都用） |
| `--ipv6-only` | 出口策略改为 `UseIPv6` |
| `--show` | 打印当前部署参数后退出 |
| `--uninstall` | 卸载 Xray、防火墙规则和相关配置 |
| `-y`, `--yes` | 跳过卸载确认 |
| `-h`, `--help` | 显示用法 |

示例：

```bash
# 多台线路机共用一个落地机
bash landing-relay.sh --upstream=1.2.3.4,5.6.7.8

# 整段放行
bash landing-relay.sh --upstream=1.2.3.0/24

# 指定端口，复用已有密钥
bash landing-relay.sh --upstream=1.2.3.4 --port=23456 --password='xxxxxxxxxxxxxxxxxxxxxx=='
```

## 安全设计

**中转端口只对指定的上游 IP 开放，其余来源一律 DROP。**

这条不是可选项。Shadowsocks 入口如果对全网开放，等于把你辛苦找来的纯净 IP 做成了公开代理，扫描器很快会发现并滥用，IP 纯净度反而先毁在这上面。

实现方式是独立的 `LANDING_RELAY` iptables 链，由 systemd unit `landing-relay-fw.service` 在开机时应用。用独立链而不是往 INPUT 里塞规则，是为了不干扰你已有的防火墙配置，卸载时也能干净移除。IPv4 和 IPv6 分别用 `iptables` 和 `ip6tables` 处理。

查看规则命中情况：

```bash
iptables -L LANDING_RELAY -n -v
```

其他几点：

- 状态文件 `/usr/local/etc/xray/landing-relay.env` 含密钥，权限 600
- 路由规则屏蔽 `geoip:private`，防止有人通过中转探测落地机内网
- 屏蔽 BitTorrent 协议，降低落地机被投诉的概率
- 每次写配置前自动备份为 `config.json.bak.<时间戳>`

## 幂等性

脚本可以反复执行。重跑时会从状态文件读取上次的端口和密钥并沿用，所以：

```bash
# 线路机 IP 变了，只更新放行列表
bash landing-relay.sh --upstream=新IP
```

**端口和密钥不变，线路机侧不需要任何改动。**

线路机侧的 jq 变换同样是幂等的：先按 tag 过滤掉旧的 `landing-out` 出站和相关路由规则再追加，重复执行不会堆积重复项。

## 两个容易踩的坑

如果你打算手写配置而不用这个脚本，这两点值得注意。它们都是我读 nokey 脚本源码时发现的。

**一、nokey 生成的 config.json 含 JSON 注释**

配置模板里有一段被 `/* */` 包起来的路由规则示例。Xray 自己能解析，但 `jq` 会直接报 parse error。所以用 jq 改配置之前必须先剥掉注释：

```bash
perl -0pe 's{/\*.*?\*/}{}gs' "$CFG" > /tmp/xray.clean.json
```

脚本生成的线路机命令里已经包含这一步。

**二、freedom 出站的 domainStrategy 不在 settings 里**

它现在归 `streamSettings.sockopt` 管：

```json
{
  "tag": "direct",
  "protocol": "freedom",
  "settings": {},
  "streamSettings": {
    "sockopt": { "domainStrategy": "UseIPv4" }
  }
}
```

写在 `settings` 下面不会报错，只会被静默忽略，出口可能意外走 IPv6。默认用 `UseIPv4` 而不是 `ForceIPv4`，因为 `Use*` 在解析失败时会退回 `AsIs`，而 `Force*` 会直接断连——对出口机来说，退化比中断更可接受。

## 内核调优

脚本会写入 `/etc/sysctl.d/99-landing-relay.conf`，启用 BBR + fq，放大 TCP 缓冲区，并把 Xray 的 `LimitNOFILE` 提到 1048576。老内核不支持 BBR 时会给出警告但不影响转发功能。

## 排错

```bash
systemctl status xray
journalctl -u xray -f
journalctl -u landing-relay-fw
ss -ltnp | grep xray
iptables -L LANDING_RELAY -n -v
bash landing-relay.sh --show
```

常见情况：

- **客户端能连但 IP 还是线路机的** — 线路机的路由规则没生效，检查 `landing-out` 出站是否存在，以及是否有优先级更高的规则先匹配了
- **完全连不上** — 大概率是放行列表里的 IP 不对。确认线路机的**公网出口 IP**（`curl ipinfo.io/ip`）和你填的一致，有些机器出口 IP 与面板显示的入口 IP 不同
- **落地机 Xray 起不来** — 看 `journalctl -u xray`，脚本在启动前已做 `xray run -test`，配置错误会中止而不会留下坏配置

## 卸载

```bash
bash landing-relay.sh --uninstall
```

移除防火墙规则、systemd unit、sysctl 配置和状态文件，并调用 Xray 官方脚本卸载 Xray 本体。

## 验证状态

已验证：IP 校验（IPv4 / CIDR / IPv6 / 非法输入）、PSK 长度校验、防火墙规则生成顺序（用 mock iptables 做 dry-run）、渲染出的落地机配置与线路机 patch 命令均为合法 JSON、jq 变换的幂等性。

未验证：脚本在真实 Debian 12 + Xray 环境下的端到端运行，包括 systemd 服务启停和两跳链路实际连通性。首次部署建议留意输出，有报错欢迎提 issue 附上日志。
