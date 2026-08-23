#!/bin/bash
# 套件E：运行时韧性（不做卸载/重装，那部分已单独验证过，避免每次重下 46MB 内核）
#   stop/start 存活 · 内核 kill -9 自愈 · 面板 kill -9 自愈 · 计数规则被清后自愈 · 重复安装幂等
set -u
P=0; F=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %-36s = %s\n' "$1" "$2"; P=$((P+1))
  else printf '  FAIL  %-36s = %s (期望 %s)\n' "$1" "$2" "$3"; F=$((F+1)); fi; }
lsn() { ss -lntH 2>/dev/null | grep -c ":$1\b"; }

PP="$(mnode panel url | sed -E 's|.*:([0-9]+)/.*|\1|')"
PT="$(mnode panel url | sed -E 's|.*token=||')"
echo "面板端口 $PP"

echo "===== 0. 起点 ====="
chk "节点数 3"        "$(ls /etc/mnode/nodes/*.node 2>/dev/null | wc -l)" "3"
chk "节点服务 active" "$(systemctl is-active mnode)" "active"
chk "面板服务 active" "$(systemctl is-active mnode-panel)" "active"
chk "面板 API 200"    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PP/api/summary?token=$PT")" "200"
chk "无令牌 401"      "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PP/api/summary")" "401"
chk "错令牌 401"      "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PP/api/summary?token=bad")" "401"
chk "首页无令牌→登录页" "$(curl -s --max-time 10 "http://127.0.0.1:$PP/" | grep -c '登录 · mnode 流量面板')" "1"
chk "pid 为 1,2,3"    "$(grep -h '^pid=' /etc/mnode/nodes/*.node | sed 's/pid=//' | sort -n | tr '\n' ',')" "1,2,3,"

echo "===== 1. stop → start 存活 ====="
systemctl stop mnode mnode-panel; sleep 2
chk "停止后节点端口全无" "$(( $(lsn 8443) + $(lsn 8388) + $(lsn 8446) ))" "0"
chk "停止后面板端口无"   "$(lsn $PP)" "0"
systemctl start mnode-firewall mnode mnode-panel; sleep 8
chk "节点 active"        "$(systemctl is-active mnode)" "active"
chk "面板 active"        "$(systemctl is-active mnode-panel)" "active"
chk "端口全回"           "$(( $(lsn 8443) + $(lsn 8388) + $(lsn 8446) ))" "3"
chk "面板端口回"         "$(lsn $PP)" "1"
chk "统计仍可读"         "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PP/api/summary?token=$PT")" "200"

echo "===== 2. 内核 kill -9 自愈 ====="
K="$(systemctl show -p MainPID --value mnode)"
kill -9 "$K" 2>/dev/null; sleep 9
chk "节点服务恢复" "$(systemctl is-active mnode)" "active"
chk "PID 已变"     "$([ "$K" != "$(systemctl show -p MainPID --value mnode)" ] && echo yes || echo no)" "yes"
chk "端口恢复"     "$(( $(lsn 8443) + $(lsn 8388) + $(lsn 8446) ))" "3"

echo "===== 3. 面板 kill -9 自愈 ====="
K2="$(systemctl show -p MainPID --value mnode-panel)"
kill -9 "$K2" 2>/dev/null; sleep 9
chk "面板恢复"     "$(systemctl is-active mnode-panel)" "active"
chk "面板 PID 变"  "$([ "$K2" != "$(systemctl show -p MainPID --value mnode-panel)" ] && echo yes || echo no)" "yes"
chk "面板端口回"   "$(lsn $PP)" "1"
chk "API 可用"     "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PP/api/live?token=$PT")" "200"

echo "===== 4. 计数规则被人为清掉后自愈 ====="
B4="$(curl -s --max-time 10 "http://127.0.0.1:$PP/api/summary?token=$PT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["total"]["rx"]+d["total"]["tx"])')"
nft delete table inet sbx_traffic 2>/dev/null
chk "规则已被清"     "$(nft list tables 2>/dev/null | grep -c sbx_traffic)" "0"
sleep 40             # 采集器 30s 退避后自动 repair
chk "采集器自动重建" "$(nft list tables 2>/dev/null | grep -c sbx_traffic)" "1"
chk "面板仍健康"     "$(curl -s --max-time 10 "http://127.0.0.1:$PP/api/live?token=$PT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["healthy"])')" "True"
AF="$(curl -s --max-time 10 "http://127.0.0.1:$PP/api/summary?token=$PT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["total"]["rx"]+d["total"]["tx"])')"
chk "历史累计未被清零" "$([ "$AF" -ge "$B4" ] && echo yes || echo no)" "yes"

echo "===== 5. 面板单元被删后 mnode 能自愈 ====="
systemctl stop mnode-panel >/dev/null 2>&1
rm -f /etc/systemd/system/mnode-panel.service /etc/systemd/system/mnode-firewall.service
systemctl daemon-reload
timeout 120 mnode panel apply >/dev/null 2>&1
sleep 3
chk "面板单元已重建" "$([ -f /etc/systemd/system/mnode-panel.service ] && echo yes || echo no)" "yes"
chk "计数单元已重建" "$([ -f /etc/systemd/system/mnode-firewall.service ] && echo yes || echo no)" "yes"
chk "面板 active"    "$(systemctl is-active mnode-panel)" "active"

echo "===== 6. 重复安装幂等（用已装内核，不重下）====="
timeout 200 mnode restart >/dev/null 2>&1
chk "节点仍 3 个"     "$(ls /etc/mnode/nodes/*.node | wc -l)" "3"
chk "节点 active"     "$(systemctl is-active mnode)" "active"
chk "面板 active"     "$(systemctl is-active mnode-panel)" "active"
chk "端口仍在听"      "$(( $(lsn 8443) + $(lsn 8388) + $(lsn 8446) ))" "3"
chk "面板端口未变"    "$(mnode panel url | sed -E 's|.*:([0-9]+)/.*|\1|')" "$PP"
chk "面板节点表 3 条" "$(python3 -c 'import json;print(len(json.load(open("/etc/mnode/panel/nodes.json"))))')" "3"

echo
echo "===== 汇总: PASS=$P FAIL=$F $([ $F -eq 0 ] && echo ALL-PASS || echo HAS-FAIL) ====="
