# mnode

用 [mihomo](https://github.com/MetaCubeX/mihomo) 内核搭建代理节点的一键脚本。

只做四件事：**搭建节点、删除节点、改端口、改 SNI**。没有分流、没有订阅转换、没有多用户面板。

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
  5) 查看节点/订阅
  6) 重启服务   7) 查看日志   8) 更新内核
  9) 重新探测IP 10) 卸载      0) 退出
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

## IPv6

安装和每次搭建节点时会自动探测公网地址：

- 服务器有公网 IPv6 → 每个节点输出两条链接，IPv6 那条标签带 `-v6` 后缀，地址按 RFC 加方括号
- 服务器没有公网 IPv6 → 只输出 IPv4，不产生连不上的无效链接
- 网卡有公网 v6 地址但 `curl -6` 探测不通，且存在 IPv6 默认路由 → 仍输出，但标注「出站未验证」
- v6 后来消失了 → 下次操作时缓存自动清除，链接回到只有 IPv4

监听地址：内核支持 IPv6 时用 `::`（同时接收 IPv4 映射连接），否则退回 `0.0.0.0`。

## 设计要点

- **改动全都带回滚**：生成配置 → `mihomo -t` 校验 → 重启 → 轮询确认端口真的在监听。任何一步失败就还原到改动前的状态，包括节点文件、防火墙规则和配置文件
- **端口冲突预检**：既查已有节点，也查系统全部监听端口（sshd、nginx 等一律拦下）
- **单一数据源**：节点参数存在 `/etc/mnode/nodes/<id>.node`，`config.yaml` 每次由它重新渲染。手动改坏配置，下次任何操作都会自动重建
- **自愈**：systemd 单元被删或内容过期，`mnode restart` 会重建；单元关掉了 systemd 的启动频率限制，频繁增删节点不会触发 `start-limit-hit`
- **权限**：`/etc/mnode` 是 700，`config.yaml` 和节点文件是 600

## 卸载

```bash
mnode uninstall
```

删除内核、所有节点、配置、systemd 单元和 `mnode` 命令本身。

## 文件位置

```
/usr/local/bin/mnode              脚本
/usr/local/bin/mihomo             内核
/etc/mnode/config.yaml            自动生成的 mihomo 配置
/etc/mnode/nodes/*.node           节点参数（唯一数据源）
/etc/systemd/system/mnode.service 服务单元
```

## 测试

已在 Debian 12 / amd64 真机完整验证：

| 套件 | 内容 | 结果 |
|---|---|---|
| 端到端流量 | 3 协议真实出网（出口 IP 核对）、HTTPS、2MB 吞吐、UDP DoH | 4/4 |
| 负面与回滚 | 25 项非法输入、失败零副作用、删除、删到 0、5 轮增删压测、配置污染自愈、单元自愈、文件权限 | 76/76 |
| IPv6 逻辑 | 地址判定、6 种 v4/v6 组合场景、链接格式、监听地址回退 | 65/65 |
| 交互菜单 | 全部菜单项、确认/取消分支、随机端口、无效输入 | 39/39 |
| 生命周期 | 卸载干净、全新安装、重启存活、`kill -9` 自动拉起、重复安装幂等 | 29/29 |

## License

MIT
