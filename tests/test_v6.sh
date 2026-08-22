#!/bin/bash
# 真机测试套件 C：IPv6 探测逻辑（用桩函数模拟有/无 v6 的服务器）
set -u
S=/usr/local/bin/mnode
export MNODE_ROOT=/tmp/v6root
export MNODE_CORE=/usr/local/bin/mihomo
export MNODE_NO_SERVICE=1
rm -rf "$MNODE_ROOT"; mkdir -p "$MNODE_ROOT/nodes"

# 去掉末尾 main "$@" 后 source，拿到全部函数
sed '$ d' "$S" > /tmp/mnode_lib.sh
# shellcheck disable=SC1090
. /tmp/mnode_lib.sh

P=0; F=0
chk()   { if [ "$2" = "$3" ]; then printf '  PASS  %-40s = %s\n' "$1" "$2"; P=$((P+1))
          else printf '  FAIL  %-40s = %s (期望 %s)\n' "$1" "$2" "$3"; F=$((F+1)); fi; }
chkrc() { local d="$1" e="$2"; shift 2; "$@" >/dev/null 2>&1; local r=$?
          if [ "$r" = "$e" ]; then printf '  PASS  %-40s rc=%s\n' "$d" "$r"; P=$((P+1))
          else printf '  FAIL  %-40s rc=%s (期望 %s)\n' "$d" "$r" "$e"; F=$((F+1)); fi; }

echo "===== 1. 真实环境探测（这台机器无公网 IPv6）====="
detect_addrs 1
chk  "探测到的 IPv4"      "$(addr4)" "YOUR_SERVER_IP"
chkrc "has_v6 应为假"  1 has_v6
chk  ".ip6 不该存在"      "$([ -e $MNODE_ROOT/.ip6 ] && echo yes || echo no)" "no"
chkrc "kernel_v6（内核支持）" 0 kernel_v6
chkrc "nic_v6（网卡无公网v6）" 1 nic_v6
chkrc "v6_route（无默认路由）" 1 v6_route
chk  "listen_addr（内核有v6→::）" "$(listen_addr)" "::"

echo "===== 2. ip4_public 判定 ====="
for x in 8.8.8.8 YOUR_SERVER_IP 172.15.0.2 1.1.1.1; do chkrc "公网 $x" 0 ip4_public $x; done
for x in 10.0.0.5 172.17.0.2 192.168.1.1 127.0.0.1 169.254.1.1 100.64.0.1 0.0.0.0 not-ip 2001:db8::1; do
  chkrc "非公网 $x" 1 ip4_public $x; done

echo "===== 3. ip6_public 判定 ====="
for x in 2001:db8::1 2408:8207::1 2A02:CAFE::1 240e:0:1::9; do chkrc "公网 $x" 0 ip6_public $x; done
for x in ::1 :: fe80::1 FE80::1 fd00::1 fc00::1 ff02::1 8.8.8.8 abc; do
  chkrc "非公网 $x" 1 ip6_public $x; done

echo "===== 4. url_host ====="
chk "v4 不加括号"  "$(url_host 1.2.3.4)"       "1.2.3.4"
chk "v6 加括号"    "$(url_host 2001:db8::1)"   "[2001:db8::1]"
chk "域名不加括号" "$(url_host a.example.com)" "a.example.com"

# 造一个节点用于链接检查
cat > "$MNODE_ROOT/nodes/ss2022-1.node" <<'EOF'
id=ss2022-1
proto=ss2022
port=8388
cipher=2022-blake3-aes-128-gcm
password=AAAABBBBCCCCDDDD1234==
EOF

echo "===== 5. 场景：服务器无 IPv6 → 只输出 v4 ====="
probe4() { printf '203.0.113.10'; }
probe6() { return 1; }
nic_v6()  { return 1; }
detect_addrs 1
chkrc "has_v6 假" 1 has_v6
chk "链接条数"     "$(links_all | grep -c .)" "1"
chk "无 v6 标签"   "$(links_all | grep -c -- '-v6')" "0"
chk "链接为 v4"    "$(links_all | grep -c '@203.0.113.10:8388')" "1"

echo "===== 6. 场景：服务器有公网 IPv6 → v4 + v6 双输出 ====="
probe6() { printf '2001:db8:1234::5'; }
detect_addrs 1
chkrc "has_v6 真"  0 has_v6
chk "addr6"         "$(addr6)" "2001:db8:1234::5"
chk "ip6state"      "$(cat $MNODE_ROOT/.ip6state)" "ok"
chk "链接条数"      "$(links_all | grep -c .)" "2"
chk "v6 链接带方括号" "$(links_all | grep -c '@\[2001:db8:1234::5\]:8388')" "1"
chk "v6 链接有 -v6 后缀" "$(links_all | grep -c -- '-v6$')" "1"
chk "订阅解码后 2 条" "$(sub_b64 | openssl base64 -d -A | grep -c .)" "2"
chk "show 显示 IPv6 地址行" "$(show_node ss2022-1 | grep -c '^  IPv6    :')" "1"
chk "show 有两条链接"   "$(show_node ss2022-1 | grep -c '^ss://')" "2"

echo "===== 7. 场景：网卡有 v6 但 curl -6 不通 + 有默认路由 → 输出且标注未验证 ====="
probe6() { return 1; }
nic_v6()  { printf '2408:8207:abcd::9'; }
v6_route(){ return 0; }
detect_addrs 1
chkrc "has_v6 真"    0 has_v6
chk "ip6state"        "$(cat $MNODE_ROOT/.ip6state)" "unverified"
chk "链接条数"        "$(links_all | grep -c .)" "2"
chk "show 标注未验证" "$(show_node ss2022-1 | grep -c '出站未验证')" "1"

echo "===== 8. 场景：网卡有 v6 但没有默认路由 → 不输出 v6 ====="
v6_route(){ return 1; }
detect_addrs 1
chkrc "has_v6 假"  1 has_v6
chk "链接条数"      "$(links_all | grep -c .)" "1"

echo "===== 9. 场景：v6 从有变无 → 缓存被清除 ====="
probe6() { printf '2001:db8:1234::5'; }; v6_route(){ return 0; }
detect_addrs 1; chkrc "先有 v6" 0 has_v6
probe6() { return 1; }; nic_v6() { return 1; }
detect_addrs 1
chkrc "现在无 v6"     1 has_v6
chk ".ip6 已删"        "$([ -e $MNODE_ROOT/.ip6 ] && echo yes || echo no)" "no"
chk ".ip6state 已删"   "$([ -e $MNODE_ROOT/.ip6state ] && echo yes || echo no)" "no"
chk "链接回到 1 条"    "$(links_all | grep -c .)" "1"

echo "===== 10. 场景：v4 探测全失败 → 回退 127.0.0.1 不报错 ====="
rm -f "$MNODE_ROOT/.ip4"
probe4() { return 1; }
chkrc "detect_addrs 仍返回 0" 0 detect_addrs 1
chk "addr4 回退"  "$(addr4)" "127.0.0.1"

echo "===== 11. 无 v6 内核时监听地址退回 0.0.0.0 ====="
kernel_v6() { return 0; }; chk "有 v6 内核"  "$(listen_addr)" "::"
kernel_v6() { return 1; }; chk "无 v6 内核"  "$(listen_addr)" "0.0.0.0"
chk "配置里 listen 字段" "$(render_one ss2022-1 | sed -n 's/.*listen: //p')" '"0.0.0.0"'

echo
echo "===== 汇总: PASS=$P FAIL=$F $([ $F -eq 0 ] && echo ALL-PASS || echo HAS-FAIL) ====="
rm -rf "$MNODE_ROOT" /tmp/mnode_lib.sh
