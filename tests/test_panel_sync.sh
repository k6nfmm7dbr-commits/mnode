#!/bin/bash
# 套件F：面板与节点联动（改端口/增删节点后计数规则换代、累计不丢不重）
set -u
ND=/etc/mnode/nodes
P=0; F=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %-38s = %s\n' "$1" "$2"; P=$((P+1))
  else printf '  FAIL  %-38s = %s (期望 %s)\n' "$1" "$2" "$3"; F=$((F+1)); fi; }
ok_ge() { if [ "$2" -ge "$3" ]; then printf '  PASS  %-38s = %s (≥%s)\n' "$1" "$2" "$3"; P=$((P+1))
  else printf '  FAIL  %-38s = %s (应≥%s)\n' "$1" "$2" "$3"; F=$((F+1)); fi; }
lsn() { ss -lntH 2>/dev/null | grep -c ":$1\b"; }
PP="$(mnode panel url | sed -E 's|.*:([0-9]+)/.*|\1|')"
PT="$(mnode panel url | sed -E 's|.*token=||')"
api() { curl -s --max-time 15 "http://127.0.0.1:$PP/api/$1&token=$PT"; }
tot() { api "summary?_=1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d['nodes']:
    if n['name']==sys.argv[1]: print(n['total']['rx']+n['total']['tx']); break
else: print(0)
" "$1"; }
epoch() { nft list counters table inet sbx_traffic 2>/dev/null | sed -n 's/.*counter sbx_epoch_\([0-9]*\).*/\1/p' | head -1; }
pid_of() { sed -n 's/^pid=//p' "$ND/$1.node"; }

echo "===== 0. 起点 ====="
chk "节点数 3" "$(ls $ND/*.node | wc -l)" "3"
E0="$(epoch)"; echo "  当前世代 $E0"

echo "===== 1. 制造一些流量作为基线 ====="
for i in 1 2; do
  curl -s --max-time 30 -o /dev/null "http://127.0.0.1:$PP/api/summary?token=$PT" >/dev/null
done
# 从公网访问节点端口，让计数器有非零值（TCP 握手即计入）
for p in 8443 8388 8446; do
  timeout 3 bash -c "exec 3<>/dev/tcp/YOUR_SERVER_IP/$p && printf 'x' >&3" 2>/dev/null || true
done
sleep 6
B_R="$(tot vless-reality-1)"; B_S="$(tot ss2022-1)"; B_W="$(tot vless-ws-1)"
echo "  基线累计: reality=$B_R ss=$B_S ws=$B_W"

echo "===== 2. 改端口：规则换代 + 累计不丢 ====="
mnode port vless-reality-1 28443 >/dev/null 2>&1
sleep 6
E1="$(epoch)"
chk "世代已变化"        "$([ "$E0" != "$E1" ] && echo yes || echo no)" "yes"
chk "新端口在听"        "$(lsn 28443)" "1"
chk "旧端口已释放"      "$(lsn 8443)" "0"
chk "nft 规则用新端口"  "$(nft list table inet sbx_traffic | grep -c 'dport 28443')" "1"
chk "nft 无旧端口规则"  "$(nft list table inet sbx_traffic | grep -c 'dport 8443')" "0"
chk "面板节点表已更新"  "$(python3 -c 'import json;print([n["port"] for n in json.load(open("/etc/mnode/panel/nodes.json")) if n["name"]=="vless-reality-1"][0])')" "28443"
chk "pid 未变（历史保留）" "$(pid_of vless-reality-1)" "1"
ok_ge "累计流量未被清零" "$(tot vless-reality-1)" "$B_R"
ok_ge "其他节点累计未受影响" "$(tot ss2022-1)" "$B_S"

echo "===== 3. 删除节点：规则移除，其它节点累计保留 ====="
mnode del vless-ws-1 >/dev/null 2>&1
sleep 6
chk "节点数 2"          "$(ls $ND/*.node | wc -l)" "2"
chk "8446 已释放"       "$(lsn 8446)" "0"
chk "nft 无该端口规则"  "$(nft list table inet sbx_traffic | grep -c 'dport 8446')" "0"
chk "面板节点表 2 条"   "$(python3 -c 'import json;print(len(json.load(open("/etc/mnode/panel/nodes.json"))))')" "2"
chk "面板 API 2 节点"   "$(api 'summary?_=1' | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["nodes"]))')" "2"
ok_ge "reality 累计保留" "$(tot vless-reality-1)" "$B_R"
ok_ge "ss 累计保留"      "$(tot ss2022-1)" "$B_S"
chk "已删节点不在面板"   "$(api 'summary?_=1' | grep -c 'vless-ws-1')" "0"

echo "===== 4. 新建节点：pid 不复用（历史不串号）====="
mnode add vless-ws 8447 cdn.new.com >/dev/null 2>&1
sleep 6
NEWPID="$(pid_of vless-ws-1)"
chk "新节点 pid = 4（不复用 3）" "$NEWPID" "4"
chk "nft 用新 pid 计数器" "$(nft list counters table inet sbx_traffic | grep -c "sbx_n${NEWPID}_i")" "1"
chk "旧 pid 3 的计数器已消失" "$(nft list counters table inet sbx_traffic | grep -c 'sbx_n3_i')" "0"
chk "新节点累计从 0 开始" "$(tot vless-ws-1)" "0"
chk "8447 在听" "$(lsn 8447)" "1"

echo "===== 5. 改 SNI 不影响端口与计数 ====="
E2="$(epoch)"
B2="$(tot vless-reality-1)"
mnode sni vless-reality-1 www.apple.com >/dev/null 2>&1
sleep 6
chk "SNI 已改"       "$(sed -n 's/^sni=//p' $ND/vless-reality-1.node)" "www.apple.com"
chk "端口未变"       "$(sed -n 's/^port=//p' $ND/vless-reality-1.node)" "28443"
chk "端口仍在听"     "$(lsn 28443)" "1"
ok_ge "累计未丢"     "$(tot vless-reality-1)" "$B2"

echo "===== 6. 恢复基线端口 ====="
mnode port vless-reality-1 8443 >/dev/null 2>&1
mnode del vless-ws-1 >/dev/null 2>&1
mnode add vless-ws 8446 cdn.example.com >/dev/null 2>&1
sleep 6
chk "节点数 3"   "$(ls $ND/*.node | wc -l)" "3"
chk "8443 在听"  "$(lsn 8443)" "1"
chk "8446 在听"  "$(lsn 8446)" "1"
chk "服务 active" "$(systemctl is-active mnode)" "active"
chk "面板 active" "$(systemctl is-active mnode-panel)" "active"

echo
echo "===== 汇总: PASS=$P FAIL=$F $([ $F -eq 0 ] && echo ALL-PASS || echo HAS-FAIL) ====="
