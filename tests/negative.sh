#!/bin/bash
# 真机测试套件 B：负面输入 / 删除 / 回滚 / 重启存活 / 自愈
# 端口全部动态取自节点文件，不写死
set -u
ND=/etc/mnode/nodes
P=0; F=0
t() { local d="$1" exp="$2" cmd="$3" out rc
  out="$(eval "$cmd" 2>&1)"; rc=$?
  if [ "$rc" = "$exp" ]; then printf '  PASS  %s\n' "$d"; P=$((P+1))
  else printf '  FAIL  %s (rc=%s 期望=%s)\n    %s\n' "$d" "$rc" "$exp" "$(echo "$out"|tail -2)"; F=$((F+1)); fi; }
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s = %s\n' "$1" "$2"; P=$((P+1))
  else printf '  FAIL  %s = %s (期望 %s)\n' "$1" "$2" "$3"; F=$((F+1)); fi; }
pt()  { sed -n 's/^port=//p' "$ND/$1.node" 2>/dev/null; }
lsn() { ss -lntH 2>/dev/null | grep -c ":$1\b"; }

echo "===== 0. 基线：重建 3 个节点 ====="
for f in "$ND"/*.node; do [ -f "$f" ] && mnode del "$(basename "$f" .node)" >/dev/null 2>&1; done
mnode add vless-reality 8443 www.tesla.com   >/dev/null 2>&1 || echo "  基线1失败"
mnode add ss2022        8388                 >/dev/null 2>&1 || echo "  基线2失败"
mnode add vless-ws      8445 cdn.example.com >/dev/null 2>&1 || echo "  基线3失败"
chk "基线节点数" "$(ls $ND/*.node 2>/dev/null | wc -l)" "3"
R=$(pt vless-reality-1); S=$(pt ss2022-1); W=$(pt vless-ws-1)
echo "  端口: reality=$R ss=$S ws=$W"

echo "===== A. 非法输入必须被拒绝 ====="
t "未知协议 vmess"        1 "mnode add vmess 30001"
t "已移除的 ws-tls"       1 "mnode add vless-ws-tls 30001 a.com"
t "端口 0"                1 "mnode add ss2022 0"
t "端口 65536"            1 "mnode add ss2022 65536"
t "端口带字母"            1 "mnode add ss2022 80ab"
t "端口负数"              1 "mnode add ss2022 -80"
t "占用端口 22(sshd)"      1 "mnode add ss2022 22"
t "占用端口 80(nginx)"     1 "mnode add ss2022 80"
t "占用自己节点端口"       1 "mnode add ss2022 $R"
t "SNI 带空格"            1 "mnode add vless-reality 30001 'bad domain'"
t "SNI 无点"              1 "mnode add vless-reality 30001 localhost"
t "SNI 带斜杠"            1 "mnode add vless-reality 30001 'a.com/x'"
t "SNI 带端口"            1 "mnode add vless-reality 30001 'a.com:443'"
t "SNI 带下划线开头"       1 "mnode add vless-reality 30001 '_a.com'"
t "不存在节点改端口"       1 "mnode port ghost-1 30001"
t "不存在节点改SNI"        1 "mnode sni ghost-1 a.com"
t "不存在节点删除"         1 "mnode del ghost-1"
t "不存在节点看详情"       1 "mnode show ghost-1"
t "不存在节点看二维码"     1 "mnode qr ghost-1"
t "ss2022 不能改SNI"       1 "mnode sni ss2022-1 a.com"
t "改端口到已占用端口"     1 "mnode port vless-reality-1 22"
t "缺参数 add"            1 "mnode add"
t "缺参数 port"           1 "mnode port vless-reality-1"
t "缺参数 sni"            1 "mnode sni vless-reality-1"
t "未知子命令"            1 "mnode nosuchcmd"

echo "===== B. 失败后零副作用 ====="
chk "节点数仍为 3"      "$(ls $ND/*.node | wc -l)" "3"
chk "reality 端口未变"  "$(pt vless-reality-1)" "$R"
chk "reality SNI 未变"  "$(sed -n 's/^sni=//p' $ND/vless-reality-1.node)" "www.tesla.com"
chk "服务仍运行"        "$(systemctl is-active mnode)" "active"
chk "3 端口都在听"      "$(( $(lsn $R) + $(lsn $S) + $(lsn $W) ))" "3"

echo "===== C. 幂等 ====="
t "端口改成相同值" 0 "mnode port vless-reality-1 $R"
t "SNI 改成相同值" 0 "mnode sni vless-reality-1 www.tesla.com"

echo "===== D. 改端口 / 改 SNI 落到配置与内核 ====="
t "改端口 → 24680"  0 "mnode port vless-reality-1 24680"
chk "节点文件已改"   "$(pt vless-reality-1)" "24680"
chk "24680 在监听"   "$(lsn 24680)" "1"
chk "旧端口已释放"   "$(lsn $R)" "0"
chk "config 已更新"  "$(grep -c 'port: 24680' /etc/mnode/config.yaml)" "1"
t "改 SNI → www.apple.com" 0 "mnode sni vless-reality-1 www.apple.com"
chk "dest 已更新"    "$(grep -c 'dest: www.apple.com:443' /etc/mnode/config.yaml)" "1"
chk "server-names 已更新" "$(grep -A6 'reality-config' /etc/mnode/config.yaml | grep -c '\- www.apple.com')" "1"
chk "分享链接含新 SNI" "$(mnode show vless-reality-1 | grep -c 'sni=www.apple.com')" "1"
chk "分享链接含新端口" "$(mnode show vless-reality-1 | grep -c ':24680')" "1"
t "vless-ws 改伪装域名" 0 "mnode sni vless-ws-1 cdn.newdomain.com"
chk "ws host 已更新"  "$(mnode show vless-ws-1 | grep -c 'host=cdn.newdomain.com')" "1"

echo "===== E. 删除 ====="
t "删除 vless-ws-1"     0 "mnode del vless-ws-1"
chk "节点数 2"          "$(ls $ND/*.node | wc -l)" "2"
chk "$W 已释放"         "$(lsn $W)" "0"
chk "config 无该节点"   "$(grep -c 'name: vless-ws-1' /etc/mnode/config.yaml || true)" "0"
chk "订阅少一条"        "$(mnode sub | openssl base64 -d -A | grep -c .)" "2"
t "重复删除应失败"      1 "mnode del vless-ws-1"
chk "其余 2 端口在听"   "$(( $(lsn 24680) + $(lsn $S) ))" "2"

echo "===== F. 删到 0 个：服务应停止 ====="
mnode del vless-reality-1 >/dev/null 2>&1
t "删最后一个"           0 "mnode del ss2022-1"
chk "节点数 0"           "$(ls $ND/*.node 2>/dev/null | wc -l)" "0"
chk "服务已停止"         "$(systemctl is-active mnode)" "inactive"
chk "listeners 空数组"   "$(grep -c '^  \[\]' /etc/mnode/config.yaml)" "1"
t "空节点 list 有提示"   1 "mnode list"
chk "24680 已释放"       "$(lsn 24680)" "0"

echo "===== G. 重建 + 重启存活 + 频繁增删压测 ====="
t "重建 reality" 0 "mnode add vless-reality 8443 www.tesla.com"
t "重建 ss2022"  0 "mnode add ss2022 8388"
chk "服务重新拉起" "$(systemctl is-active mnode)" "active"
systemctl restart mnode; sleep 5
chk "restart 后 active"  "$(systemctl is-active mnode)" "active"
chk "restart 后端口都在" "$(( $(lsn 8443) + $(lsn 8388) ))" "2"
echo "  连续 5 轮增删（压 systemd 启动频率限制）"
i=1; SEQ=1
while [ $i -le 5 ]; do
  mnode add ss2022 >/dev/null 2>&1 || SEQ=0
  L=$(basename "$(ls -t $ND/*.node | head -1)" .node)
  mnode del "$L" >/dev/null 2>&1 || SEQ=0
  i=$((i+1))
done
chk "5 轮增删全成功"  "$SEQ" "1"
chk "压测后 active"   "$(systemctl is-active mnode)" "active"
chk "压测后节点数 2"  "$(ls $ND/*.node | wc -l)" "2"

echo "===== H. 配置被污染时自愈 ====="
echo "!!! broken yaml @@@" >> /etc/mnode/config.yaml
t "add 重建配置"    0 "mnode add vless-ws 8446 cdn.test.com"
chk "配置重新合法"  "$(/usr/local/bin/mihomo -t -d /etc/mnode >/dev/null 2>&1 && echo ok || echo bad)" "ok"
chk "服务 active"   "$(systemctl is-active mnode)" "active"

echo "===== I. 单元文件被删也能自愈 ====="
systemctl stop mnode >/dev/null 2>&1
rm -f /etc/systemd/system/mnode.service; systemctl daemon-reload
t "restart 重建单元"  0 "mnode restart"
chk "单元文件恢复"    "$([ -f /etc/systemd/system/mnode.service ] && echo yes || echo no)" "yes"
chk "服务 active"     "$(systemctl is-active mnode)" "active"
chk "开机自启已启用"  "$(systemctl is-enabled mnode)" "enabled"

echo "===== J. 文件权限 ====="
chk "/etc/mnode 权限"     "$(stat -c %a /etc/mnode)" "700"
chk "config.yaml 权限"    "$(stat -c %a /etc/mnode/config.yaml)" "600"
chk "节点文件权限"        "$(stat -c %a $ND/vless-reality-1.node)" "600"

echo
echo "===== 汇总: PASS=$P FAIL=$F $([ $F -eq 0 ] && echo ALL-PASS || echo HAS-FAIL) ====="
