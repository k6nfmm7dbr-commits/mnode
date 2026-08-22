#!/bin/bash
# 真机测试套件 D：交互菜单（用管道喂输入，模拟用户按键）
set -u
ND=/etc/mnode/nodes
P=0; F=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %-34s = %s\n' "$1" "$2"; P=$((P+1))
  else printf '  FAIL  %-34s = %s (期望 %s)\n' "$1" "$2" "$3"; F=$((F+1)); fi; }
has_txt() { if printf '%s' "$2" | grep -q "$3"; then printf '  PASS  %s\n' "$1"; P=$((P+1))
  else printf '  FAIL  %s（输出里找不到 %s）\n' "$1" "$3"; F=$((F+1)); fi; }
lsn() { ss -lntH 2>/dev/null | grep -c ":$1\b"; }

echo "===== 0. 清空 ====="
for f in "$ND"/*.node; do [ -f "$f" ] && mnode del "$(basename "$f" .node)" >/dev/null 2>&1; done
chk "节点数 0" "$(ls $ND/*.node 2>/dev/null | wc -l)" "0"

echo "===== 1. 菜单：1) 搭建 → REALITY，端口 31001，SNI www.icloud.com ====="
OUT="$(printf '1\n1\n31001\nwww.icloud.com\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "有协议选择界面" "$OUT" "VLESS-REALITY"
has_txt "创建成功提示"   "$OUT" "节点已创建"
chk "节点已落库"  "$(ls $ND/*.node 2>/dev/null | wc -l)" "1"
chk "端口正确"    "$(sed -n 's/^port=//p' $ND/vless-reality-1.node)" "31001"
chk "SNI 正确"    "$(sed -n 's/^sni=//p' $ND/vless-reality-1.node)" "www.icloud.com"
chk "31001 在监听" "$(lsn 31001)" "1"

echo "===== 2. 菜单：搭建 SS2022（端口留空 → 随机）====="
OUT="$(printf '1\n3\n\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "创建成功" "$OUT" "节点已创建"
chk "节点数 2" "$(ls $ND/*.node | wc -l)" "2"
SP="$(sed -n 's/^port=//p' $ND/ss2022-1.node)"
chk "随机端口在 20000-59999" "$([ "$SP" -ge 20000 ] && [ "$SP" -le 59999 ] && echo yes || echo no)" "yes"
chk "随机端口在监听" "$(lsn $SP)" "1"

echo "===== 3. 菜单：搭建 VLESS-WS（默认伪装域名）====="
OUT="$(printf '1\n2\n31003\n\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
chk "节点数 3" "$(ls $ND/*.node | wc -l)" "3"
chk "默认 SNI 生效" "$(sed -n 's/^sni=//p' $ND/vless-ws-1.node)" "www.tesla.com"

echo "===== 4. 菜单：3) 修改端口（选序号 2 = reality）====="
mnode list
OUT="$(printf '3\n2\n31009\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "改端口成功提示" "$OUT" "端口 31001 → 31009"
chk "端口已改"    "$(sed -n 's/^port=//p' $ND/vless-reality-1.node)" "31009"
chk "新端口在听"  "$(lsn 31009)" "1"
chk "旧端口释放"  "$(lsn 31001)" "0"

echo "===== 5. 菜单：4) 修改 SNI（只应列出 2 个可改节点）====="
OUT="$(printf '4\n1\nwww.microsoft.com\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "改 SNI 成功提示" "$OUT" "SNI"
chk "ss2022 不在候选列表" "$(printf '%s' "$OUT" | grep -c 'ss2022-1 .*ss2022')" "0"
chk "reality SNI 已改" "$(sed -n 's/^sni=//p' $ND/vless-reality-1.node)" "www.microsoft.com"

echo "===== 6. 菜单：5) 查看节点/订阅 ====="
OUT="$(printf '5\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "显示 REALITY 详情" "$OUT" "vless-reality-1"
has_txt "显示 ss2022 详情"  "$OUT" "Shadowsocks-2022"
has_txt "显示订阅段"        "$OUT" "订阅"
chk "三个节点都在" "$(printf '%s' "$OUT" | grep -cE '^(vless|ss)[0-9a-z-]*-1  ')" "3"

echo "===== 7. 菜单：2) 删除节点（输 n 应取消）====="
OUT="$(printf '2\n1\nn\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "取消提示" "$OUT" "已取消"
chk "节点数仍 3" "$(ls $ND/*.node | wc -l)" "3"

echo "===== 8. 菜单：2) 删除节点（输 y 应删除）====="
OUT="$(printf '2\n1\ny\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "删除成功" "$OUT" "已删除"
chk "节点数 2" "$(ls $ND/*.node | wc -l)" "2"

echo "===== 9. 菜单：6) 重启 / 7) 日志 / 9) 重新探测IP ====="
OUT="$(printf '6\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "重启成功"  "$OUT" "服务已重启"
OUT="$(printf '7\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "有日志输出" "$OUT" "mihomo"
OUT="$(printf '9\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "探测输出 IPv4"  "$OUT" "YOUR_SERVER_IP"
has_txt "无 v6 时有说明" "$OUT" "无公网 IPv6"

echo "===== 10. 菜单：无效选择应提示且不崩 ====="
OUT="$(printf '99\n\n0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "无效选择提示" "$OUT" "无效选择"
chk "服务未受影响" "$(systemctl is-active mnode)" "active"

echo "===== 11. 菜单头部信息 ====="
OUT="$(printf '0\n' | NO_COLOR=1 mnode menu 2>&1)"
has_txt "显示内核版本" "$OUT" "v1.19"
has_txt "显示服务状态" "$OUT" "运行中"
has_txt "显示 IPv4"    "$OUT" "YOUR_SERVER_IP"
has_txt "显示 IPv6 无" "$OUT" "IPv6 无"

echo "===== 12. qr 命令 ====="
ID="$(basename "$(ls $ND/*.node | head -1)" .node)"
OUT="$(mnode qr "$ID" 2>&1)"
chk "二维码非空" "$([ ${#OUT} -gt 100 ] && echo yes || echo no)" "yes"

echo
echo "===== 汇总: PASS=$P FAIL=$F $([ $F -eq 0 ] && echo ALL-PASS || echo HAS-FAIL) ====="
