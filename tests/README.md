# 测试套件

在**一台可以随意折腾的服务器**上运行。这些脚本会反复创建、删除节点，甚至完整卸载重装 mnode，不要在生产机上跑。

先把服务器公网 IP 填进去（`test_menu.sh` 和 `test_v6.sh` 里有断言用到）：

```bash
sed -i 's/YOUR_SERVER_IP/1.2.3.4/g' tests/*.sh
```

然后逐个运行：

```bash
bash tests/negative.sh        # 非法输入、回滚、删除、压测、自愈、权限   （76 项）
bash tests/test_v6.sh         # IPv6 探测逻辑，用桩函数模拟各种网络环境   （65 项）
bash tests/test_menu.sh       # 交互菜单全路径，管道喂按键               （39 项）
bash tests/test_lifecycle.sh  # 卸载 → 全新安装 → 重启存活 → kill -9 自愈（29 项）
```

`test_v6.sh` 用 `MNODE_ROOT=/tmp/v6root` + `MNODE_NO_SERVICE=1` 跑在沙箱里，不动真实配置和服务。其余三个会操作真实的 `/etc/mnode` 与 systemd 服务。

`test_lifecycle.sh` 需要 `/root/mnode.sh` 存在（脚本副本），它会用它模拟一键安装。

## 端到端流量测试

真实出网测试需要另一台机器做客户端，用 mihomo 加载 `mnode sub` 的输出，逐个协议访问 `https://api.ipify.org` 并核对出口 IP 是否为服务器 IP，同时测 HTTPS、吞吐和 UDP（SOCKS5 UDP 做 DoH 查询）。这部分依赖两台机器，没有放进脚本。
