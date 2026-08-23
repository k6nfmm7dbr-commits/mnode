# 测试套件

在**一台可以随意折腾的服务器**上运行。这些脚本会反复创建删除节点、kill 服务进程、清空 netfilter 规则，甚至完整卸载重装 mnode，不要在生产机上跑。

先把服务器公网 IP 填进去（部分断言用到）：

```bash
sed -i 's/YOUR_SERVER_IP/1.2.3.4/g' tests/*.sh
```

## 运行

脚本里有 `sleep`（等采集器落库、等自愈重试），单个套件最长约 3 分钟。建议后台跑再看日志，避免 SSH 会话被长时间占用：

```bash
nohup bash tests/negative.sh         > b.log 2>&1 &   # 非法输入·回滚·删除·压测·自愈·权限  76 项
nohup bash tests/test_v6.sh          > c.log 2>&1 &   # IPv6 探测逻辑（桩函数模拟网络环境）  65 项
nohup bash tests/test_menu.sh        > d.log 2>&1 &   # 交互菜单全路径（含面板菜单）        61 项
nohup bash tests/test_lifecycle.sh   > e.log 2>&1 &   # 运行时韧性：kill -9·规则被清·幂等   35 项
nohup bash tests/test_panel_sync.sh  > f.log 2>&1 &   # 面板与节点联动：换代·pid 不复用     32 项
tail -f b.log
```

`test_v6.sh` 用 `MNODE_PANEL_DIR=/tmp/v6root` + `MNODE_NO_SERVICE=1` 跑在沙箱里，不动真实配置和服务。其余四个会操作真实的 `/etc/mnode` 与 systemd 服务。

`test_menu.sh` 用管道喂按键模拟用户操作（`printf '1\n1\n8443\n...' | mnode menu`），每次调用都用 `timeout` 包住。

## 各套件覆盖

| 脚本 | 覆盖内容 |
|---|---|
| `negative.sh` | 22 项非法输入必须被拒绝、失败后状态零副作用、幂等改值、改端口/SNI 落到配置与内核、删除、删到 0 服务停止、5 轮增删压 systemd 启动频率限制、配置被污染自愈、单元被删自愈、文件权限 |
| `test_v6.sh` | `ip4_public`/`ip6_public` 地址判定、`url_host` 方括号、6 种 v4/v6 组合场景（无 v6 / 有 v6 / 网卡有但探测不通 / 无默认路由 / v6 消失 / v4 全失败）、监听地址回退 |
| `test_menu.sh` | 菜单退出不挂死、stdin 耗尽不空转、三协议搭建、随机端口、改端口/SNI、查看订阅、删除确认与取消、面板菜单（统计/每日/自检/重建规则/改端口/重置令牌/公网切换）、日志、探测 IP |
| `test_lifecycle.sh` | 令牌鉴权（200/401/登录页）、stop→start 存活、内核 `kill -9` 自愈、面板 `kill -9` 自愈、netfilter 规则被人为删掉后采集器自动重建且历史不清零、面板单元被删后自愈、重复操作幂等 |
| `test_panel_sync.sh` | 改端口后计数规则换代且累计不丢、删除节点后规则移除而其它节点累计保留、新建节点 pid 不复用（历史不串号）、改 SNI 不影响端口与计数 |

## 端到端流量测试

真实出网与面板计数准确性需要另一台机器做客户端：用 mihomo 加载 `mnode sub` 的输出，逐协议访问 `https://api.ipify.org` 核对出口 IP，再各下载 1MB 后比对面板逐节点累计增量（应为 1.02MB 左右，比应用层高 2%~5% 是 IP 层包头开销）。UDP 计数验证要在网络命名空间里经 veth 走 SOCKS5 UDP 发 DNS —— 走 `lo` 不行，面板的 nft 规则对 `lo` 有 return。这部分依赖两台机器，没有放进脚本。
