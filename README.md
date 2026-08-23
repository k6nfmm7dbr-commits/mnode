# mnode

用 [mihomo](https://github.com/MetaCubeX/mihomo) 内核搭建代理节点的一键脚本，自带内核级精确流量面板。

节点部分只做四件事：**搭建、删除、改端口、改 SNI**。没有分流、没有订阅转换、没有多用户。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/k6nfmm7dbr-commits/mnode/main/mnode.sh)
```

装完后输入 `mnode` 进菜单。

## 支持的协议

| 协议 | 说明 |
|---|---|
| `vless-reality` | VLESS + REALITY + XTLS-Vision。免证书、免域名，抗封锁最好，首选 |
| `vless-ws` | VLESS + WebSocket 明文。用来套 Cloudflare 等 CDN，SNI 填回源域名 |
| `ss2022` | Shadowsocks-2022（`2022-blake3-aes-128-gcm`），UDP 全开 |

## 菜单

```
  1) 搭建节点        2) 删除节点
  3) 修改端口        4) 修改 SNI
  5) 查看节点/订阅   6) 流量面板
  7) 重启服务   8) 查看日志   9) 更新内核
 10) 重新探测IP 11) 卸载      0) 退出
```

## 命令行

```bash
mnode add vless-reality 8443 www.tesla.com   # 搭建（端口/SNI 可省略）
mnode add ss2022                              # 端口留空 = 随机
mnode del vless-reality-1                     # 删除
mnode port vless-reality-1 23456              # 改端口
mnode sni  vless-reality-1 www.apple.com      # 改 SNI
mnode list                                    # 节点列表
mnode show vless-reality-1                    # 详情 + 分享链接
mnode sub                                     # Base64 订阅
mnode qr vless-reality-1                      # 二维码
mnode ip                                      # 重新探测公网 IPv4/IPv6
mnode restart | log | update | uninstall
```

## 流量面板

安装时自动部署，端口随机、令牌随机。取访问地址：

```bash
mnode panel url          # http://IP:端口/?token=...
mnode panel              # 地址 + 状态 + 后端 + 采集间隔
```

面板是三页导航：首页（实时速率、TCP/UDP 连接、今日/累计、单节点状态）、每日（最近 60 天）、节点（单节点每日明细）。

```bash
mnode panel show             # 终端里看统计
mnode panel daily 30         # 每日流量
mnode panel port 8080        # 改端口
mnode panel token            # 重置令牌
mnode panel local | public   # 仅本机访问 / 允许公网访问
mnode panel interval 5       # 改采集间隔（秒）
mnode panel apply            # 重建计数规则
mnode panel selftest         # 自检
mnode panel reset            # 清空统计
mnode panel log
```

### 统计口径

流量来自**内核 netfilter 计数器**（优先 nftables named counter，无 nft 时退回 iptables 自定义链），按节点端口计数，不抽样、不估算。

- `rx` = 服务器收到的字节 = 客户端上传；`tx` = 服务器发出的字节 = 客户端下载
- 计的是 IP 层字节（含 TCP/IP 包头），比客户端应用层数字高约 2%~5%，与云厂商计费口径一致
- 统计按中国时间（UTC+8）跨天
- 采集器每 2 秒读一次做单调差分累加进 SQLite；计数器归零或规则换代只进累计，不制造假速率峰值
- 改端口、增删节点会重建规则并打上新的世代标记，累计流量无缝衔接，零丢计零重复

**连接数**取自 mihomo 自己的 RESTful API（`/connections`，按 inbound 归属到节点），API 不可用时退回读 `/proc/net/{tcp,udp}[6]`。这一点和 sing-box 不同：mihomo 的连接由内部协程池管理，服务端 socket 不以常规 ESTABLISHED 形态出现在 `/proc` 里，只读 `/proc` 会恒为 0。

## IPv6

安装和每次搭建节点时自动探测公网地址：

- 有公网 IPv6 → 每个节点输出两条链接，IPv6 那条标签带 `-v6` 后缀，地址按 RFC 加方括号
- 没有 → 只输出 IPv4，不产生连不上的无效链接
- 网卡有公网 v6 地址但 `curl -6` 探测不通、且存在 IPv6 默认路由 → 仍输出，但标注「出站未验证」
- v6 后来消失了 → 下次操作时缓存自动清除

监听地址：内核支持 IPv6 时用 `::`（同时接收 IPv4 映射连接），否则退回 `0.0.0.0`。

## 设计要点

- **改动全都带回滚**：渲染配置 → `mihomo -t` 校验 → 重启 → 轮询确认端口真在监听 → 同步面板并换代计数规则。任何一步失败就还原到改动前状态，包括节点文件、防火墙规则和配置文件
- **端口冲突预检**：既查已有节点，也查系统全部监听端口（sshd、nginx 一律拦下）
- **单一数据源**：节点参数存在 `/etc/mnode/nodes/<id>.node`，`config.yaml` 和面板的 `nodes.json` 每次都由它重新渲染。手动改坏配置，下次任何操作都会自动重建
- **面板节点编号不复用**：每个节点分配一个递增的数字 `pid` 用于计数器命名，删除后不回收，历史统计不会串到新节点上
- **自愈**：systemd 单元被删或内容过期，`mnode restart` 会重建；单元关掉了启动频率限制，频繁增删不会触发 `start-limit-hit`
- **面板更新有保护**：资源先下到暂存目录并校验语法，全部通过才覆盖，更新失败保留现有可用版本
- **权限**：`/etc/mnode` 是 700，`config.yaml`、`panel.json` 和节点文件是 600

## 卸载

```bash
mnode uninstall
```

删除内核、所有节点、面板与统计数据、netfilter 计数规则、三个 systemd 单元和 `mnode` 命令本身。

## 文件位置

```
/usr/local/bin/mnode                       脚本
/usr/local/bin/mihomo                      内核
/etc/mnode/config.yaml                     自动生成的 mihomo 配置
/etc/mnode/nodes/*.node                    节点参数（唯一数据源）
/etc/mnode/panel/panel.py                  面板采集器 + HTTP 服务
/etc/mnode/panel/panel.json                面板配置（端口、令牌、采集间隔）
/etc/mnode/panel/nodes.json                面板节点表（由 mnode 同步生成）
/etc/mnode/panel/traffic.db                流量历史（SQLite）
/etc/mnode/panel/web/                      面板前端
/etc/systemd/system/mnode.service          节点服务
/etc/systemd/system/mnode-panel.service    面板服务
/etc/systemd/system/mnode-firewall.service 计数规则（oneshot）
```

## 关于面板来源

`src/panel.py` 与 `web/` 取自同作者的 [sbx](https://github.com/k6nfmm7dbr-commits/sbx) 项目。除了连接数改用 mihomo API（sing-box 与 mihomo 在这点上行为不同）和前端标题文案，逻辑未作改动。

## 测试

已在 Debian 12 / amd64 真机完整验证：

| 套件 | 内容 | 结果 |
|---|---|---|
| 端到端流量 | 3 协议真实出网（出口 IP 核对）、HTTPS、吞吐、UDP DoH | 全通过 |
| 面板计数准确性 | 每节点各下 1MB，面板逐节点核对增量 | 1.02MB×3 |
| 面板实时/连接数 | 并行下载时速率峰值、停止后回落、TCP/UDP 会话数 | 全通过 |
| UDP 计数 | 网络命名空间内经 SOCKS5 UDP 发 120 次 DNS | 上下行均计入 |
| 负面与回滚 | 非法输入、失败零副作用、删除、删到 0、增删压测、配置污染自愈、单元自愈、权限 | 76/76 |
| IPv6 逻辑 | 地址判定、6 种 v4/v6 组合场景、链接格式、监听地址回退 | 65/65 |
| 交互菜单 | 全部菜单项、确认/取消、随机端口、无效输入 | 39/39 |
| 生命周期 | 卸载干净、全新安装、重启存活、`kill -9` 自愈、重复安装幂等 | 29/29 |

测试脚本见 [tests/](tests/)。

## License

MIT
