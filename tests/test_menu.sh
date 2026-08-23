#!/bin/bash
# 真机测试套件 D：交互菜单（管道喂按键）
#   菜单编号：1搭建 2删除 3改端口 4改SNI 5查看 6面板 7重启 8日志 9更新内核 10探测IP 11卸载 0退出
#   协议子菜单：1 REALITY  2 VLESS-WS  3 SS2022
# 注意：全部用 timeout 包住，防止脚本本身把会话拖死
set -u
ND=/etc/mnode/nodes
P=0; F=0
M() { timeout 120 env NO_COLOR=1 mnode menu 2>&1; }      # 统一入口，带超时
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %-34s = %s\n' "$1" "$2"; P=$((P+1))
  else printf '  FAIL  %-34s = %s (期望 %s)\n' "$1" "$2" "$3"; F=$((F+1)); fi; }
has_txt() { if printf '%s' "$2" | grep -q "$3"; then printf '  PASS  %s\n' "$1"; P=$((P+1))
  else printf '  FAIL  %s（输出里找不到 %s）\n' "$1" "$3"; F=$((F+1)); fi; }
lsn() { ss -lntH 2>/dev/null | grep -c ":$1\b"; }

echo "===== 0. 清空 ====="
for f in "$ND"/*.node; do [ -f "$f" ] && mnode del "$(basename "$f" .node)" >/dev/null 2>&1; done
chk "节点数 0" "$(ls $ND/*.node 2>/dev/null | wc -l)" "0"

echo "===== 1. 菜单退出不挂死（喂 0）====="
S=$(date +%s); OUT="$(printf '0\n' | M)"; E=$(date +%s)
chk "3 秒内退出" "$([ $((E-S)) -le 3 ] && echo yes || echo no)" "yes"
has_txt "显示菜单标题" "$OUT" "mnode · mihomo 节点管理"
has_txt "显示面板状态行" "$OUT" "面板"

echo "===== 2. stdin 耗尽也必须退出（只喂一个无效值，不喂 0）====="
S=$(date +%s); OUT="$(printf '99\n' | M)"; E=$(date +%s)
chk "不空转，5 秒内退出" "$([ $((E-S)) -le 5 ] && echo yes || echo no)" "yes"
has_txt "提示无效选择" "$OUT" "无效选择"

echo "===== 3. 搭建 REALITY（端口 31001，SNI www.icloud.com）====="
OUT="$(printf '1\n1\n31001\nwww.icloud.com\n\n0\n' | M)"
has_txt "有协议选择界面" "$OUT" "VLESS-REALITY"
has_txt "创建成功提示"   "$OUT" "节点已创建"
chk "节点已落库"   "$(ls $ND/*.node 2>/dev/null | wc -l)" "1"
chk "端口正确"     "$(sed -n 's/^port=//p' $ND/vless-reality-1.node)" "31001"
chk "SNI 正确"     "$(sed -n 's/^sni=//p' $ND/vless-reality-1.node)" "www.icloud.com"
chk "31001 在监听" "$(lsn 31001)" "1"
chk "面板节点表已同步" "$(grep -c 'vless-reality-1' /etc/mnode/panel/nodes.json)" "1"

echo "===== 4. 搭建 SS2022（端口留空 → 随机）====="
OUT="$(printf '1\n3\n\n\n0\n' | M)"
has_txt "创建成功" "$OUT" "节点已创建"
chk "节点数 2" "$(ls $ND/*.node | wc -l)" "2"
SP="$(sed -n 's/^port=//p' $ND/ss2022-1.node)"
chk "随机端口在 20000-59999" "$([ "$SP" -ge 20000 ] && [ "$SP" -le 59999 ] && echo yes || echo no)" "yes"
chk "随机端口在监听" "$(lsn $SP)" "1"

echo "===== 5. 搭建 VLESS-WS（默认伪装域名）====="
OUT="$(printf '1\n2\n31003\n\n\n0\n' | M)"
chk "节点数 3" "$(ls $ND/*.node | wc -l)" "3"
chk "默认 SNI 生效" "$(sed -n 's/^sni=//p' $ND/vless-ws-1.node)" "www.tesla.com"
chk "面板 3 个节点" "$(python3 -c 'import json;print(len(json.load(open("/etc/mnode/panel/nodes.json"))))')" "3"

echo "===== 6. 修改端口（序号 2 = reality）====="
OUT="$(printf '3\n2\n31009\n\n0\n' | M)"
has_txt "改端口成功提示" "$OUT" "端口 31001 → 31009"
chk "端口已改"   "$(sed -n 's/^port=//p' $ND/vless-reality-1.node)" "31009"
chk "新端口在听" "$(lsn 31009)" "1"
chk "旧端口释放" "$(lsn 31001)" "0"
chk "面板端口跟着改" "$(python3 -c '
import json
print([n["port"] for n in json.load(open("/etc/mnode/panel/nodes.json")) if n["name"]=="vless-reality-1"][0])')" "31009"

echo "===== 7. 修改 SNI（ss2022 不应出现在候选里）====="
OUT="$(printf '4\n1\nwww.microsoft.com\n\n0\n' | M)"
has_txt "改 SNI 成功提示" "$OUT" "SNI"
chk "ss2022 不在候选" "$(printf '%s' "$OUT" | grep -c 'ss2022-1 .*ss2022')" "0"
chk "reality SNI 已改" "$(sed -n 's/^sni=//p' $ND/vless-reality-1.node)" "www.microsoft.com"

echo "===== 8. 查看节点 / 订阅 ====="
OUT="$(printf '5\n\n0\n' | M)"
has_txt "显示 REALITY 详情" "$OUT" "vless-reality-1"
has_txt "显示 ss2022 详情"  "$OUT" "Shadowsocks-2022"
has_txt "显示订阅段"        "$OUT" "订阅"

echo "===== 9. 删除节点：输 n 取消 ====="
OUT="$(printf '2\n1\nn\n\n0\n' | M)"
has_txt "取消提示" "$OUT" "已取消"
chk "节点数仍 3" "$(ls $ND/*.node | wc -l)" "3"

echo "===== 10. 删除节点：输 y 删除 ====="
OUT="$(printf '2\n1\ny\n\n0\n' | M)"
has_txt "删除成功" "$OUT" "已删除"
chk "节点数 2" "$(ls $ND/*.node | wc -l)" "2"
chk "面板节点表 2 条" "$(python3 -c 'import json;print(len(json.load(open("/etc/mnode/panel/nodes.json"))))')" "2"

echo "===== 11. 流量面板菜单（第 6 项）====="
OUT="$(printf '6\n1\n\n0\n' | M)"
has_txt "显示面板地址"   "$OUT" "地址"
has_txt "显示后端"       "$OUT" "nftables"
has_txt "统计表头"       "$OUT" "今日"
OUT="$(printf '6\n2\n\n0\n' | M)"
has_txt "每日流量输出"   "$OUT" "日期"
OUT="$(printf '6\n7\n\n0\n' | M)"
has_txt "自检输出"       "$OUT" "自检通过"
OUT="$(printf '6\n9\n\n0\n' | M)"
has_txt "重建计数规则"   "$OUT" "计数规则已重建"

echo "===== 12. 面板改端口（菜单 6 → 3）====="
OLDP="$(mnode panel url | sed -E 's|.*:([0-9]+)/.*|\1|')"
OUT="$(printf '6\n3\n41234\n\n0\n' | M)"
has_txt "改端口成功" "$OUT" "面板端口已改为 41234"
chk "面板新端口在听" "$(lsn 41234)" "1"
chk "面板旧端口释放" "$(lsn $OLDP)" "0"
chk "配置已写入"     "$(mnode panel url | sed -E 's|.*:([0-9]+)/.*|\1|')" "41234"

echo "===== 13. 面板重置令牌（菜单 6 → 6）====="
T0="$(mnode panel url | sed -E 's|.*token=||')"
OUT="$(printf '6\n6\n\n0\n' | M)"
T1="$(mnode panel url | sed -E 's|.*token=||')"
has_txt "重置提示" "$OUT" "令牌已重置"
chk "令牌确实变了" "$([ "$T0" != "$T1" ] && echo yes || echo no)" "yes"
chk "旧令牌被拒(401)" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:41234/api/summary?token=$T0")" "401"
chk "新令牌可用(200)" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:41234/api/summary?token=$T1")" "200"

echo "===== 14. 面板 仅本机/公网 切换（菜单 6 → 5）====="
OUT="$(printf '6\n5\n\n0\n' | M)"
has_txt "切到仅本机" "$OUT" "仅本机访问"
chk "监听已变 127.0.0.1" "$(python3 -c 'import json;print(json.load(open("/etc/mnode/panel/panel.json"))["listen"])')" "127.0.0.1"
OUT="$(printf '6\n5\n\n0\n' | M)"
has_txt "切回公网" "$OUT" "允许公网访问"
chk "监听已变 0.0.0.0" "$(python3 -c 'import json;print(json.load(open("/etc/mnode/panel/panel.json"))["listen"])')" "0.0.0.0"

echo "===== 15. 重启服务 / 查看日志 / 重新探测IP ====="
OUT="$(printf '7\n\n0\n' | M)"; has_txt "重启成功"  "$OUT" "服务已重启"
OUT="$(printf '8\n\n0\n' | M)"; has_txt "有日志输出" "$OUT" "mihomo"
OUT="$(printf '10\n\n0\n' | M)"
has_txt "探测输出 IPv4"  "$OUT" "YOUR_SERVER_IP"
has_txt "无 v6 时有说明" "$OUT" "无公网 IPv6"

echo "===== 16. 结束状态 ====="
chk "节点服务 active" "$(systemctl is-active mnode)" "active"
chk "面板服务 active" "$(systemctl is-active mnode-panel)" "active"
chk "无残留菜单进程" "$(ps aux | grep -c '[m]node menu')" "0"

echo
echo "===== 汇总: PASS=$P FAIL=$F $([ $F -eq 0 ] && echo ALL-PASS || echo HAS-FAIL) ====="
