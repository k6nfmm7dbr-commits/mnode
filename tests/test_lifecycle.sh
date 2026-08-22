#!/bin/bash
# 真机测试套件 E：完整卸载 → 全新一键安装 → 建节点 → 复核（模拟真实用户首次使用）
set -u
P=0; F=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %-36s = %s\n' "$1" "$2"; P=$((P+1))
  else printf '  FAIL  %-36s = %s (期望 %s)\n' "$1" "$2" "$3"; F=$((F+1)); fi; }
t() { local d="$1" e="$2" c="$3" o r; o="$(eval "$c" 2>&1)"; r=$?
  if [ "$r" = "$e" ]; then printf '  PASS  %s\n' "$d"; P=$((P+1))
  else printf '  FAIL  %s (rc=%s 期望=%s)\n    %s\n' "$d" "$r" "$e" "$(echo "$o"|tail -2)"; F=$((F+1)); fi; }
lsn() { ss -lntH 2>/dev/null | grep -c ":$1\b"; }

echo "===== 1. 卸载（菜单 10 → y）====="
printf '10\ny\n' | NO_COLOR=1 mnode menu >/dev/null 2>&1
chk "/etc/mnode 已删除"        "$([ -e /etc/mnode ] && echo yes || echo no)" "no"
chk "mihomo 二进制已删除"      "$([ -e /usr/local/bin/mihomo ] && echo yes || echo no)" "no"
chk "mnode 命令已删除"         "$([ -e /usr/local/bin/mnode ] && echo yes || echo no)" "no"
chk "systemd 单元已删除"       "$([ -e /etc/systemd/system/mnode.service ] && echo yes || echo no)" "no"
chk "服务已不存在"             "$(systemctl is-active mnode 2>/dev/null | head -1)" "inactive"

echo "===== 2. 全新一键安装（等价于 bash <(curl ... mnode.sh)）====="
t "首次运行安装内核+命令" 0 "bash /root/mnode.sh ip"
chk "内核已装"       "$([ -x /usr/local/bin/mihomo ] && echo yes || echo no)" "yes"
chk "mnode 命令已装" "$([ -x /usr/local/bin/mnode ] && echo yes || echo no)" "yes"
chk "单元已装"       "$([ -f /etc/systemd/system/mnode.service ] && echo yes || echo no)" "yes"
chk "开机自启"       "$(systemctl is-enabled mnode)" "enabled"
chk "工作目录 700"   "$(stat -c %a /etc/mnode)" "700"
chk "无节点时未运行" "$(systemctl is-active mnode)" "inactive"

echo "===== 3. 新装环境直接建节点 ====="
t "建 REALITY"  0 "mnode add vless-reality 8443 www.tesla.com"
t "建 SS2022"   0 "mnode add ss2022 8388"
t "建 VLESS-WS" 0 "mnode add vless-ws 8446 cdn.example.com"
chk "节点数 3"   "$(ls /etc/mnode/nodes/*.node | wc -l)" "3"
chk "服务 active" "$(systemctl is-active mnode)" "active"
chk "三端口在听"  "$(( $(lsn 8443) + $(lsn 8388) + $(lsn 8446) ))" "3"
chk "订阅 3 条"   "$(mnode sub | openssl base64 -d -A | grep -c .)" "3"

echo "===== 4. 服务器重启存活模拟（stop → start）====="
systemctl stop mnode; sleep 2
chk "停止后端口全无" "$(( $(lsn 8443) + $(lsn 8388) + $(lsn 8446) ))" "0"
systemctl start mnode; sleep 6
chk "启动后 active"   "$(systemctl is-active mnode)" "active"
chk "启动后端口全回"  "$(( $(lsn 8443) + $(lsn 8388) + $(lsn 8446) ))" "3"

echo "===== 5. 内核崩溃自动拉起（Restart=always）====="
PID="$(systemctl show -p MainPID --value mnode)"
kill -9 "$PID" 2>/dev/null
sleep 8
NEWPID="$(systemctl show -p MainPID --value mnode)"
chk "服务自动恢复"     "$(systemctl is-active mnode)" "active"
chk "PID 已变化(重启过)" "$([ "$PID" != "$NEWPID" ] && echo yes || echo no)" "yes"
chk "端口全部恢复"     "$(( $(lsn 8443) + $(lsn 8388) + $(lsn 8446) ))" "3"

echo "===== 6. 重复安装应幂等（不破坏已有节点）====="
t "再跑一次安装脚本" 0 "bash /root/mnode.sh ip"
chk "节点仍是 3 个"  "$(ls /etc/mnode/nodes/*.node | wc -l)" "3"
chk "服务仍 active"  "$(systemctl is-active mnode)" "active"
chk "端口仍在听"     "$(( $(lsn 8443) + $(lsn 8388) + $(lsn 8446) ))" "3"

echo
echo "===== 汇总: PASS=$P FAIL=$F $([ $F -eq 0 ] && echo ALL-PASS || echo HAS-FAIL) ====="
