#!/usr/bin/env bash
# =============================================================================
#  mnode — mihomo 节点搭建脚本
#
#  功能范围（有意保持最小）：
#    1. 搭建节点      2. 删除节点      3. 修改端口      4. 修改 SNI
#
#  协议：VLESS（REALITY / WS-TLS / WS 明文）、Shadowsocks-2022
#
#  一键安装：
#    bash <(curl -fsSL https://raw.githubusercontent.com/k6nfmm7dbr-commits/mnode/main/mnode.sh)
#  之后用 `mnode` 进菜单，或 `mnode --help` 看命令行用法。
# =============================================================================

set -o pipefail

readonly VERSION="1.0.0"
readonly CORE_REPO="MetaCubeX/mihomo"
readonly CORE_FALLBACK="v1.19.30"
# 通过 bash <(curl ...) 运行时 $0 是已读完的管道，自安装要回退到从这里下载
readonly SELF_URL="${MNODE_SELF_URL:-https://raw.githubusercontent.com/k6nfmm7dbr-commits/mnode/main/mnode.sh}"

# ---- 路径（可用环境变量覆盖，便于沙箱测试）----------------------------------
ROOT="${MNODE_ROOT:-/etc/mnode}"
NODES="$ROOT/nodes"
CONF="$ROOT/config.yaml"
LOG="$ROOT/mihomo.log"
PIDF="$ROOT/mihomo.pid"
CORE="${MNODE_CORE:-/usr/local/bin/mihomo}"
SELF="${MNODE_SELF:-/usr/local/bin/mnode}"
SVC="mnode"
SVC_FILE="/etc/systemd/system/${SVC}.service"
API_PORT="${MNODE_API_PORT:-19090}"
NO_SVC="${MNODE_NO_SERVICE:-0}"

# ---- 颜色 -------------------------------------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'
  D=$'\033[2m';  W=$'\033[1m';  N=$'\033[0m'
else
  R=; G=; Y=; B=; D=; W=; N=
fi

msg()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${B}·${N} $*"; }
ok()   { printf '%s\n' "${G}✓${N} $*"; }
warn() { printf '%s\n' "${Y}!${N} $*" >&2; }
err()  { printf '%s\n' "${R}✗${N} $*" >&2; }
die()  { err "$*"; exit 1; }
line() { printf '%s\n' "${D}────────────────────────────────────────────────────────────${N}"; }

has() { command -v "$1" >/dev/null 2>&1; }

# =============================================================================
#  环境准备
# =============================================================================
need_root() { [ "$(id -u)" = 0 ] || die "请用 root 运行（sudo -i 后重试）"; }

pkg_install() {
  [ $# -gt 0 ] || return 0
  if   has apt-get; then DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
                         DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
  elif has dnf;     then dnf install -y -q "$@" >/dev/null 2>&1
  elif has yum;     then yum install -y -q "$@" >/dev/null 2>&1
  elif has apk;     then apk add --no-cache "$@" >/dev/null 2>&1
  elif has pacman;  then pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1
  elif has zypper;  then zypper -q install -y "$@" >/dev/null 2>&1
  else return 1; fi
}

ensure_deps() {
  local need=""
  has curl    || need="$need curl"
  has openssl || need="$need openssl"
  has gzip    || need="$need gzip"
  if [ -n "$need" ]; then
    info "安装依赖:$need"
    pkg_install $need || warn "依赖自动安装失败，请手动安装:$need"
  fi
  has curl    || die "缺少 curl"
  has openssl || die "缺少 openssl"
  has gzip    || die "缺少 gzip"
  # 可选：二维码
  has qrencode || pkg_install qrencode >/dev/null 2>&1 || true
}

core_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then echo amd64-v3
      else echo amd64-compatible; fi ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l|armv7)   echo armv7 ;;
    armv6l|armv6)   echo armv6 ;;
    armv5tel|armv5) echo armv5 ;;
    i386|i686)      echo 386 ;;
    s390x)          echo s390x ;;
    riscv64)        echo riscv64 ;;
    loongarch64)    echo loong64 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

core_latest() {
  local v
  v="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${CORE_REPO}/releases/latest" 2>/dev/null \
       | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  printf '%s' "${v:-$CORE_FALLBACK}"
}

core_install() {
  local force="${1:-0}"
  if [ -x "$CORE" ] && [ "$force" != 1 ]; then return 0; fi
  local arch ver url tmp
  arch="$(core_arch)"; ver="$(core_latest)"
  url="https://github.com/${CORE_REPO}/releases/download/${ver}/mihomo-linux-${arch}-${ver}.gz"
  info "下载 mihomo ${ver} (linux-${arch})"
  tmp="$(mktemp -d)"
  if ! curl -fL --retry 3 --connect-timeout 20 -o "$tmp/c.gz" "$url" 2>/dev/null; then
    warn "GitHub 直连失败，改用镜像"
    curl -fL --retry 2 --connect-timeout 25 -o "$tmp/c.gz" "https://ghfast.top/$url" 2>/dev/null \
      || { rm -rf "$tmp"; die "内核下载失败"; }
  fi
  gzip -dc "$tmp/c.gz" > "$tmp/core" 2>/dev/null || { rm -rf "$tmp"; die "内核解压失败"; }
  chmod +x "$tmp/core"
  "$tmp/core" -v >/dev/null 2>&1 || { rm -rf "$tmp"; die "内核无法执行（架构不符？）"; }
  mkdir -p "$(dirname "$CORE")"
  cat "$tmp/core" > "$CORE" && chmod +x "$CORE"
  rm -rf "$tmp"
  ok "内核: $("$CORE" -v 2>/dev/null | head -n1)"
}

core_ver() { "$CORE" -v 2>/dev/null | awk '{print $3}'; }

# =============================================================================
#  地址族探测：有公网 IPv6 才输出 v6 链接
# =============================================================================
ip4_public() {
  printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
  case "$1" in
    10.*|127.*|0.*|169.254.*|192.168.*) return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
  esac
  return 0
}

ip6_public() {
  local a; a="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$a" in *:*) ;; *) return 1 ;; esac
  case "$a" in
    ::1|::|fe80:*|fe9?:*|fea?:*|feb?:*|fc??:*|fd??:*|ff??:*) return 1 ;;
  esac
  return 0
}

kernel_v6() { [ -e /proc/net/if_inet6 ]; }

# 网卡上的公网 v6（curl 不通时的兜底信息源）
nic_v6() {
  kernel_v6 || return 1
  local a=""
  if has ip; then
    a="$(ip -6 addr show scope global 2>/dev/null \
         | sed -n 's#.*inet6 \([0-9a-fA-F:]\{2,\}\)/.*#\1#p' | head -n1)"
  fi
  [ -n "$a" ] || return 1
  ip6_public "$a" || return 1
  printf '%s' "$a"
}

# 是否存在 IPv6 默认路由（没有路由 = 出不去，不该输出 v6 链接）
v6_route() {
  has ip || return 1
  ip -6 route show default 2>/dev/null | grep -q . || return 1
  return 0
}

probe4() {
  local ip u
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://v4.ident.me https://ifconfig.me/ip; do
    ip="$(curl -4 -fsSL --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')"
    ip4_public "${ip:-}" && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

probe6() {
  kernel_v6 || return 1
  nic_v6 >/dev/null 2>&1 || return 1     # 网卡没有公网 v6，不必发请求
  local ip u
  for u in https://api6.ipify.org https://ipv6.icanhazip.com https://v6.ident.me; do
    ip="$(curl -6 -fsSL --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')"
    ip6_public "${ip:-}" && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

# detect_addrs [quiet]
#   写 $ROOT/.ip4；有公网 v6 写 $ROOT/.ip6，否则删除它
detect_addrs() {
  local quiet="${1:-0}" a4 a6
  mkdir -p "$ROOT"
  [ "$quiet" = 1 ] || info "探测公网地址..."

  a4="$(probe4)" || a4=""
  if [ -n "$a4" ]; then printf '%s' "$a4" > "$ROOT/.ip4"
  elif [ ! -s "$ROOT/.ip4" ]; then printf '%s' "127.0.0.1" > "$ROOT/.ip4"; fi

  a6="$(probe6)" || a6=""
  if [ -n "$a6" ]; then
    printf '%s' "$a6"  > "$ROOT/.ip6"
    printf 'ok'        > "$ROOT/.ip6state"
    [ "$quiet" = 1 ] || ok "IPv4 $(cat "$ROOT/.ip4")   IPv6 $a6"
    return 0
  fi
  # curl 不通，但网卡有公网 v6 且有默认路由 → 仍然输出，但标注未验证
  a6="$(nic_v6)" || a6=""
  if [ -n "$a6" ] && v6_route; then
    printf '%s' "$a6"    > "$ROOT/.ip6"
    printf 'unverified'  > "$ROOT/.ip6state"
    [ "$quiet" = 1 ] || warn "本机有 IPv6 $a6（出站未验证），仍输出 v6 链接"
    return 0
  fi
  rm -f "$ROOT/.ip6" "$ROOT/.ip6state"
  [ "$quiet" = 1 ] || info "IPv4 $(cat "$ROOT/.ip4")   无公网 IPv6 → 只输出 IPv4 节点"
  return 0
}

addr4()  { cat "$ROOT/.ip4" 2>/dev/null; }
addr6()  { cat "$ROOT/.ip6" 2>/dev/null; }
has_v6() { [ -s "$ROOT/.ip6" ]; }
v6_unverified() { [ "$(cat "$ROOT/.ip6state" 2>/dev/null)" = unverified ]; }

# 监听地址：内核有 v6 用 "::"（v4 映射同时收），否则 0.0.0.0
listen_addr() { if kernel_v6; then printf '::'; else printf '0.0.0.0'; fi; }

# URL 里的主机：v6 要方括号
url_host() { case "$1" in *:*) printf '[%s]' "$1" ;; *) printf '%s' "$1" ;; esac; }

# =============================================================================
#  小工具
# =============================================================================
gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  else "$CORE" generate uuid 2>/dev/null; fi
}
gen_hex()  { openssl rand -hex "${1:-4}"; }
gen_pw()   { openssl rand -base64 "${1:-16}"; }

valid_port() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_host() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$' || return 1
  printf '%s' "$1" | grep -q '\.' || return 1
  return 0
}

port_used() {
  local p="$1" f
  # 本脚本已有节点
  if [ -d "$NODES" ]; then
    for f in "$NODES"/*.node; do
      [ -f "$f" ] || continue
      [ "$(sed -n 's/^port=//p' "$f" | head -n1)" = "$p" ] && return 0
    done
  fi
  # 系统占用（排除自己的内核进程，避免改端口时误判）
  if has ss; then
    ss -lntuH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}\$" && return 0
  elif has netstat; then
    netstat -lntu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
  fi
  return 1
}

free_port() {
  local p
  while :; do
    p=$(( (RANDOM % 40000) + 20000 ))
    port_used "$p" || { printf '%s' "$p"; return; }
  done
}

urlenc() {
  local s="$1" o="" i=0 c
  while [ $i -lt ${#s} ]; do
    c="${s:$i:1}"
    case "$c" in
      [A-Za-z0-9.~_-]) o="$o$c" ;;
      *) o="$o$(printf '%%%02X' "'$c")" ;;
    esac
    i=$((i+1))
  done
  printf '%s' "$o"
}

# =============================================================================
#  节点存储：$NODES/<id>.node，key=value 一行一个
# =============================================================================
node_ids() {
  [ -d "$NODES" ] || return 0
  local f
  for f in "$NODES"/*.node; do
    [ -f "$f" ] || continue
    basename "$f" .node
  done
}
node_n()  { node_ids | grep -c . ; }
nget()    { sed -n "s/^$2=//p" "$NODES/$1.node" 2>/dev/null | head -n1; }
nexists() { [ -f "$NODES/$1.node" ]; }

nset() {
  local f="$NODES/$1.node" k="$2" v="$3" t
  [ -f "$f" ] || return 1
  t="$(mktemp)"
  if grep -q "^$k=" "$f"; then sed "s|^$k=.*|$k=$v|" "$f" > "$t"
  else cat "$f" > "$t"; printf '%s=%s\n' "$k" "$v" >> "$t"; fi
  cat "$t" > "$f"; rm -f "$t"
}

next_id() {
  local p="$1" n=1
  while [ -f "$NODES/${p}-${n}.node" ]; do n=$((n+1)); done
  printf '%s-%s' "$p" "$n"
}

proto_name() {
  case "$1" in
    vless-reality) echo "VLESS-REALITY" ;;
    vless-ws)      echo "VLESS-WS(明文/CDN)" ;;
    ss2022)        echo "Shadowsocks-2022" ;;
    *)             echo "$1" ;;
  esac
}

proto_valid() {
  case "$1" in vless-reality|vless-ws|ss2022) return 0 ;; *) return 1 ;; esac
}

# 该协议是否有 SNI / 伪装域名可改
proto_sni() {
  case "$1" in vless-reality|vless-ws) return 0 ;; *) return 1 ;; esac
}

# =============================================================================
#  渲染 mihomo 配置
# =============================================================================
build_conf() {
  mkdir -p "$ROOT"
  local t; t="$(mktemp)"
  {
    printf '# 由 mnode v%s 生成于 %s —— 手工修改会在下次操作时被覆盖\n' \
      "$VERSION" "$(date '+%F %T')"
    echo 'log-level: warning'
    echo 'mode: rule'
    echo 'ipv6: true'
    echo 'find-process-mode: off'
    echo 'geodata-mode: false'
    echo 'unified-delay: true'
    printf 'external-controller: 127.0.0.1:%s\n' "$API_PORT"
    echo
    echo 'listeners:'
    local id any=0
    for id in $(node_ids); do
      render_one "$id" && any=1
    done
    [ "$any" = 1 ] || echo '  []'
    echo
    echo 'rules:'
    echo '  - MATCH,DIRECT'
  } > "$t"
  cat "$t" > "$CONF"; rm -f "$t"
  chmod 600 "$CONF"
}

render_one() {
  local id="$1" proto port la
  proto="$(nget "$id" proto)"; port="$(nget "$id" port)"
  [ -n "$proto" ] && [ -n "$port" ] || return 1
  la="$(listen_addr)"
  printf '  - name: %s\n' "$id"
  case "$proto" in
    vless-reality)
      printf '    type: vless\n    port: %s\n    listen: "%s"\n' "$port" "$la"
      printf '    users:\n      - username: user\n        uuid: %s\n        flow: xtls-rprx-vision\n' "$(nget "$id" uuid)"
      printf '    reality-config:\n      dest: %s:443\n' "$(nget "$id" sni)"
      printf '      private-key: %s\n' "$(nget "$id" prk)"
      printf '      short-id:\n        - "%s"\n' "$(nget "$id" sid)"
      printf '      server-names:\n        - %s\n' "$(nget "$id" sni)"
      ;;
    vless-ws)
      printf '    type: vless\n    port: %s\n    listen: "%s"\n' "$port" "$la"
      printf '    users:\n      - username: user\n        uuid: %s\n' "$(nget "$id" uuid)"
      printf '    ws-path: %s\n' "$(nget "$id" wspath)"
      printf '    allow-insecure: true\n'
      ;;
    ss2022)
      printf '    type: shadowsocks\n    port: %s\n    listen: "%s"\n' "$port" "$la"
      printf '    cipher: %s\n' "$(nget "$id" cipher)"
      printf '    password: "%s"\n' "$(nget "$id" password)"
      printf '    udp: true\n'
      ;;
    *) return 1 ;;
  esac
  return 0
}

# =============================================================================
#  服务与防火墙
# =============================================================================
use_systemd() {
  [ "$NO_SVC" = 1 ] && return 1
  has systemctl && [ -d /run/systemd/system ]
}

svc_install() {
  use_systemd || return 0
  local t; t="$(mktemp)"
  cat > "$t" <<EOF
[Unit]
Description=mnode (mihomo proxy nodes)
After=network-online.target
Wants=network-online.target
# 频繁增删节点会短时间内多次重启，关掉 systemd 的启动频率限制
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Type=simple
User=root
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
ExecStart=$CORE -d $ROOT
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  # 内容变了才写盘 + reload（幂等，且老版本能自动升级）
  if ! cmp -s "$t" "$SVC_FILE" 2>/dev/null; then
    cat "$t" > "$SVC_FILE"
    systemctl daemon-reload >/dev/null 2>&1
  fi
  rm -f "$t"
  systemctl enable "$SVC" >/dev/null 2>&1
  return 0
}

svc_start() {
  if use_systemd; then
    svc_install                                     # 确保单元存在且是最新内容（自愈/自升级）
    systemctl reset-failed "$SVC" >/dev/null 2>&1   # 清失败计数，避免 start-limit-hit
    systemctl restart "$SVC" >/dev/null 2>&1
  else
    svc_stop
    nohup "$CORE" -d "$ROOT" > "$LOG" 2>&1 &
    echo $! > "$PIDF"
  fi
}

svc_stop() {
  if use_systemd; then systemctl stop "$SVC" >/dev/null 2>&1
  else
    [ -f "$PIDF" ] && kill "$(cat "$PIDF")" >/dev/null 2>&1
    rm -f "$PIDF"
  fi
  return 0
}

svc_up() {
  if use_systemd; then systemctl is-active --quiet "$SVC"
  else [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" >/dev/null 2>&1; fi
}

svc_state() {
  if [ "$(node_n)" = 0 ]; then printf '%s' "${D}未运行(无节点)${N}"
  elif svc_up; then printf '%s' "${G}运行中${N}"
  else printf '%s' "${R}已停止${N}"; fi
}

svc_log() {
  if use_systemd; then journalctl -u "$SVC" -n "${1:-40}" --no-pager 2>/dev/null
  else tail -n "${1:-40}" "$LOG" 2>/dev/null; fi
}

fw_open() {
  local p="$1"
  if has ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "$p/tcp" >/dev/null 2>&1; ufw allow "$p/udp" >/dev/null 2>&1
  fi
  if has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1
    firewall-cmd --permanent --add-port="$p/udp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
  fi
  return 0
}

fw_close() {
  local p="$1"
  if has ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw delete allow "$p/tcp" >/dev/null 2>&1; ufw delete allow "$p/udp" >/dev/null 2>&1
  fi
  if has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$p/tcp" >/dev/null 2>&1
    firewall-cmd --permanent --remove-port="$p/udp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
  fi
  return 0
}

# 生成 → 校验 → 重启；失败自动回滚旧配置
apply() {
  local bak=""
  [ -f "$CONF" ] && { bak="$(mktemp)"; cat "$CONF" > "$bak"; }
  build_conf
  if ! "$CORE" -t -d "$ROOT" > "$ROOT/.check" 2>&1; then
    err "配置校验失败，已回滚:"
    grep -v 'level=info' "$ROOT/.check" | tail -n 5 >&2
    [ -n "$bak" ] && { cat "$bak" > "$CONF"; rm -f "$bak"; }
    return 1
  fi
  [ -n "$bak" ] && rm -f "$bak"
  if [ "$(node_n)" = 0 ]; then
    svc_stop; ok "已无节点，服务已停止"; return 0
  fi
  svc_start
  local i=0
  while [ $i -lt 10 ]; do
    svc_up && break
    sleep 1; i=$((i+1))
  done
  if ! svc_up; then
    err "服务启动失败:"; svc_log 15 >&2; return 1
  fi
  # 复核每个节点端口真的在监听（内核绑定要几秒，轮询等待）
  has ss || return 0
  local miss id p
  i=0
  while [ $i -lt 20 ]; do
    miss=""
    for id in $(node_ids); do
      p="$(nget "$id" port)"
      ss -lntuH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}\$" || miss="$miss $id($p)"
    done
    [ -z "$miss" ] && break
    sleep 1; i=$((i+1))
  done
  if [ -n "$miss" ]; then
    err "以下节点端口未能监听:$miss"
    svc_log 20 | grep -iE 'listen err|bind' >&2
    return 1
  fi
  return 0
}

# =============================================================================
#  分享链接
# =============================================================================
# link <id> <host> [标签后缀]
link() {
  local id="$1" hostraw="$2" sfx="${3:-}" proto port host tag
  proto="$(nget "$id" proto)"; port="$(nget "$id" port)"
  host="$(url_host "$hostraw")"
  tag="$(urlenc "${id}${sfx}")"
  case "$proto" in
    vless-reality)
      printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
        "$(nget "$id" uuid)" "$host" "$port" "$(nget "$id" sni)" \
        "$(nget "$id" pbk)" "$(nget "$id" sid)" "$tag" ;;
    vless-ws)
      printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&host=%s&path=%s#%s\n' \
        "$(nget "$id" uuid)" "$host" "$port" "$(nget "$id" sni)" \
        "$(urlenc "$(nget "$id" wspath)")" "$tag" ;;
    ss2022)
      local ui
      ui="$(printf '%s:%s' "$(nget "$id" cipher)" "$(nget "$id" password)" \
            | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
      printf 'ss://%s@%s:%s#%s\n' "$ui" "$host" "$port" "$tag" ;;
  esac
}

# 单节点全部链接：v4 必有；探测到公网 v6 时追加一条 -v6
links_of() {
  local id="$1" a4
  a4="$(addr4)"; [ -n "$a4" ] || a4="127.0.0.1"
  link "$id" "$a4"
  has_v6 && link "$id" "$(addr6)" "-v6"
  return 0
}

links_all() { local id; for id in $(node_ids); do links_of "$id"; done; }

sub_b64() { links_all | openssl base64 -A; printf '\n'; }

show_qr() {
  has qrencode || return 0
  printf '%s二维码%s\n' "$D" "$N"
  qrencode -t ANSIUTF8 -m 1 "$1" 2>/dev/null
}

show_node() {
  local id="$1" proto
  nexists "$id" || { err "节点不存在: $id"; return 1; }
  proto="$(nget "$id" proto)"
  line
  printf '%s%s%s  %s[%s]%s\n' "$W" "$id" "$N" "$D" "$(proto_name "$proto")" "$N"
  printf '  IPv4    : %s\n' "$(addr4)"
  if has_v6; then
    if v6_unverified; then
      printf '  IPv6    : %s %s(本机地址，出站未验证)%s\n' "$(addr6)" "$D" "$N"
    else
      printf '  IPv6    : %s\n' "$(addr6)"
    fi
  fi
  printf '  端口    : %s%s%s\n' "$Y" "$(nget "$id" port)" "$N"
  case "$proto" in
    vless-reality)
      printf '  UUID    : %s\n'  "$(nget "$id" uuid)"
      printf '  SNI     : %s%s%s\n' "$Y" "$(nget "$id" sni)" "$N"
      printf '  公钥    : %s\n'  "$(nget "$id" pbk)"
      printf '  ShortId : %s\n'  "$(nget "$id" sid)"
      printf '  流控    : xtls-rprx-vision\n' ;;
    vless-ws)
      printf '  UUID    : %s\n'  "$(nget "$id" uuid)"
      printf '  Host    : %s%s%s %s(明文 WS，建议套 CDN)%s\n' "$Y" "$(nget "$id" sni)" "$N" "$D" "$N"
      printf '  WS 路径 : %s\n'  "$(nget "$id" wspath)" ;;
    ss2022)
      printf '  加密    : %s\n'  "$(nget "$id" cipher)"
      printf '  密码    : %s\n'  "$(nget "$id" password)"
      printf '  UDP     : 开启\n' ;;
  esac
  if has_v6; then
    printf '\n%sIPv4 链接%s\n%s\n' "$G" "$N" "$(link "$id" "$(addr4)")"
    printf '%sIPv6 链接%s\n%s\n'   "$G" "$N" "$(link "$id" "$(addr6)" "-v6")"
  else
    printf '\n%s分享链接%s\n%s\n'  "$G" "$N" "$(link "$id" "$(addr4)")"
  fi
  return 0
}

list_nodes() {
  [ "$(node_n)" = 0 ] && { warn "还没有节点"; return 1; }
  line
  printf '%s%-4s %-18s %-18s %-7s %s%s\n' "$W" "序号" "节点名" "协议" "端口" "SNI" "$N"
  local i=1 id s
  for id in $(node_ids); do
    s="$(nget "$id" sni)"; [ -n "$s" ] || s="-"
    printf '%-4s %-18s %-18s %-7s %s\n' "$i" "$id" "$(nget "$id" proto)" "$(nget "$id" port)" "$s"
    i=$((i+1))
  done
  line
  return 0
}

# 交互选节点；filter=sni 时只列可改 SNI 的
pick() {
  local filter="${1:-}" ids="" id
  for id in $(node_ids); do
    [ "$filter" = sni ] && { proto_sni "$(nget "$id" proto)" || continue; }
    ids="$ids $id"
  done
  PICKED=""
  if [ -z "$ids" ]; then
    if [ "$filter" = sni ]; then warn "没有带 SNI 的节点（Shadowsocks-2022 不含 TLS）"
    else warn "还没有节点"; fi
    return 1
  fi
  line
  printf '%s%-4s %-18s %-18s %-7s %s%s\n' "$W" "序号" "节点名" "协议" "端口" "SNI" "$N"
  local i=1 s
  for id in $ids; do
    s="$(nget "$id" sni)"; [ -n "$s" ] || s="-"
    printf '%-4s %-18s %-18s %-7s %s\n' "$i" "$id" "$(nget "$id" proto)" "$(nget "$id" port)" "$s"
    i=$((i+1))
  done
  line
  set -- $ids
  printf '选择序号 (1-%s，回车取消): ' "$#"
  local sel; read -r sel
  [ -n "$sel" ] || return 1
  case "$sel" in ''|*[!0-9]*) err "序号无效"; return 1 ;; esac
  { [ "$sel" -ge 1 ] && [ "$sel" -le $# ]; } || { err "序号超出范围"; return 1; }
  eval "PICKED=\${$sel}"
  return 0
}

# =============================================================================
#  1) 搭建节点
# =============================================================================
DEF_SNI="www.tesla.com"

node_add() {
  local proto="$1" port="${2:-}" sni="${3:-}"
  proto_valid "$proto" || { err "未知协议: $proto（vless-reality | vless-ws | ss2022）"; return 1; }
  mkdir -p "$NODES"

  if [ -z "$port" ]; then port="$(free_port)"
  else
    valid_port "$port" || { err "端口无效: $port"; return 1; }
    port_used "$port"  && { err "端口 $port 已被占用"; return 1; }
  fi

  if proto_sni "$proto"; then
    [ -n "$sni" ] || sni="$DEF_SNI"
    valid_host "$sni" || { err "SNI 域名无效: $sni"; return 1; }
  fi

  # 每次搭建都重新探测地址族
  if [ -s "$ROOT/.ip4" ]; then detect_addrs 1; else detect_addrs 0; fi

  local id f
  id="$(next_id "$proto")"
  f="$NODES/$id.node"
  {
    printf 'id=%s\nproto=%s\nport=%s\ncreated=%s\n' \
      "$id" "$proto" "$port" "$(date '+%F %T')"
  } > "$f"

  case "$proto" in
    vless-reality)
      local kp prk pbk
      kp="$("$CORE" generate reality-keypair 2>/dev/null)"
      prk="$(printf '%s' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n1)"
      pbk="$(printf '%s' "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p'  | head -n1)"
      [ -n "$prk" ] && [ -n "$pbk" ] || { rm -f "$f"; err "REALITY 密钥生成失败"; return 1; }
      printf 'uuid=%s\nsni=%s\nprk=%s\npbk=%s\nsid=%s\n' \
        "$(gen_uuid)" "$sni" "$prk" "$pbk" "$(gen_hex 4)" >> "$f" ;;
    vless-ws)
      printf 'uuid=%s\nsni=%s\nwspath=/%s\n' "$(gen_uuid)" "$sni" "$(gen_hex 4)" >> "$f" ;;
    ss2022)
      printf 'cipher=%s\npassword=%s\n' "2022-blake3-aes-128-gcm" "$(gen_pw 16)" >> "$f" ;;
  esac
  chmod 600 "$f"

  fw_open "$port"
  if ! apply; then
    rm -f "$f"
    apply >/dev/null 2>&1
    fw_close "$port"
    err "节点创建失败，已回滚"
    return 1
  fi
  ok "节点已创建: $id"
  show_node "$id"
  return 0
}

# =============================================================================
#  2) 删除节点
# =============================================================================
node_del() {
  local id="$1"
  nexists "$id" || { err "节点不存在: $id"; return 1; }
  local port bak
  port="$(nget "$id" port)"
  bak="$(mktemp)"; cat "$NODES/$id.node" > "$bak"
  rm -f "$NODES/$id.node"
  if ! apply; then
    cat "$bak" > "$NODES/$id.node"; rm -f "$bak"
    apply >/dev/null 2>&1
    err "删除失败，已还原"
    return 1
  fi
  rm -f "$bak"
  fw_close "$port"
  ok "已删除 $id（端口 $port 已释放）"
  return 0
}

# =============================================================================
#  3) 修改端口
# =============================================================================
node_port() {
  local id="$1" new="$2"
  nexists "$id" || { err "节点不存在: $id"; return 1; }
  valid_port "$new" || { err "端口无效: $new"; return 1; }
  local old; old="$(nget "$id" port)"
  [ "$old" = "$new" ] && { warn "端口没有变化"; return 0; }
  # 新端口不会是本节点当前监听的端口，直接查占用即可，无需停服务
  port_used "$new" && { err "端口 $new 已被占用"; return 1; }
  nset "$id" port "$new"
  fw_open "$new"
  if ! apply; then
    nset "$id" port "$old"; fw_close "$new"; apply >/dev/null 2>&1
    err "改端口失败，已还原为 $old"; return 1
  fi
  fw_close "$old"
  ok "$id 端口 $old → $new"
  show_node "$id"
  return 0
}

# =============================================================================
#  4) 修改 SNI
# =============================================================================
node_sni() {
  local id="$1" new="$2"
  nexists "$id" || { err "节点不存在: $id"; return 1; }
  local proto; proto="$(nget "$id" proto)"
  proto_sni "$proto" || { err "$(proto_name "$proto") 没有 SNI 可改"; return 1; }
  valid_host "$new" || { err "SNI 域名无效: $new"; return 1; }
  local old; old="$(nget "$id" sni)"
  [ "$old" = "$new" ] && { warn "SNI 没有变化"; return 0; }
  nset "$id" sni "$new"
  if ! apply; then
    nset "$id" sni "$old"; apply >/dev/null 2>&1
    err "改 SNI 失败，已还原为 $old"; return 1
  fi
  ok "$id SNI $old → $new"
  show_node "$id"
  return 0
}

# =============================================================================
#  交互菜单
# =============================================================================
head_ui() {
  clear 2>/dev/null
  printf '%s\n' "${B}${W}  ╭──────────────────────────────────────────╮${N}"
  printf '%s\n' "${B}${W}  │   mnode · mihomo 节点管理     v${VERSION}    │${N}"
  printf '%s\n' "${B}${W}  ╰──────────────────────────────────────────╯${N}"
  printf '  内核 %s  服务 %s  节点 %s%s%s\n' \
    "$(core_ver)" "$(svc_state)" "$W" "$(node_n)" "$N"
  if has_v6; then
    printf '  IPv4 %s   IPv6 %s%s%s\n\n' "$(addr4)" "$G" "$(addr6)" "$N"
  else
    printf '  IPv4 %s   IPv6 %s无%s\n\n' "$(addr4)" "$D" "$N"
  fi
}

ui_add() {
  line
  printf '%s搭建哪种节点？%s\n' "$W" "$N"
  printf '  1) VLESS-REALITY     %s免证书、抗封锁，首选%s\n'    "$D" "$N"
  printf '  2) VLESS-WS 明文     %s套 Cloudflare 等 CDN%s\n'   "$D" "$N"
  printf '  3) Shadowsocks-2022  %s轻量，UDP 全开%s\n'         "$D" "$N"
  printf '  0) 返回\n'
  printf '选择: '; local c; read -r c
  local proto
  case "$c" in
    1) proto=vless-reality ;;
    2) proto=vless-ws ;;
    3) proto=ss2022 ;;
    0|'') return 0 ;;
    *) err "无效选择"; return 1 ;;
  esac
  printf '端口 (回车 = 随机): '; local p; read -r p
  local sni=''
  if proto_sni "$proto"; then
    if [ "$proto" = vless-ws ]; then printf 'CDN 回源域名 (回车 = %s): ' "$DEF_SNI"
    else printf 'SNI 域名 (回车 = %s): ' "$DEF_SNI"; fi
    read -r sni
  fi
  node_add "$proto" "$p" "$sni"
}

ui_del() {
  pick || return 0
  printf '确认删除 %s%s%s ? [y/N]: ' "$Y" "$PICKED" "$N"
  local a; read -r a
  case "$a" in y|Y|yes|YES) node_del "$PICKED" ;; *) info "已取消" ;; esac
}

ui_port() {
  pick || return 0
  printf '当前端口 %s，新端口 (回车 = 随机): ' "$(nget "$PICKED" port)"
  local p; read -r p
  [ -n "$p" ] || p="$(free_port)"
  node_port "$PICKED" "$p"
}

ui_sni() {
  pick sni || return 0
  printf '当前 SNI %s，新 SNI: ' "$(nget "$PICKED" sni)"
  local s; read -r s
  [ -n "$s" ] || { info "已取消"; return 0; }
  node_sni "$PICKED" "$s"
}

ui_show() {
  [ "$(node_n)" = 0 ] && { warn "还没有节点"; return 0; }
  local id
  for id in $(node_ids); do show_node "$id"; done
  line
  printf '%s订阅（Base64，客户端可直接导入）%s\n' "$G" "$N"
  sub_b64
}

ui_uninstall() {
  printf '%s将删除内核、所有节点与配置，确认卸载？[y/N]: %s' "$R" "$N"
  local a; read -r a
  case "$a" in y|Y|yes|YES) ;; *) info "已取消"; return 0 ;; esac
  local id
  for id in $(node_ids); do fw_close "$(nget "$id" port)"; done
  svc_stop
  if use_systemd; then
    systemctl disable "$SVC" >/dev/null 2>&1
    rm -f "$SVC_FILE"; systemctl daemon-reload >/dev/null 2>&1
  fi
  rm -rf "$ROOT"; rm -f "$CORE" "$SELF"
  ok "已卸载干净"
  exit 0
}

menu() {
  while :; do
    head_ui
    printf '  1) 搭建节点        2) 删除节点\n'
    printf '  3) 修改端口        4) 修改 SNI\n'
    printf '  5) 查看节点/订阅\n'
    line
    printf '  6) 重启服务   7) 查看日志   8) 更新内核\n'
    printf '  9) 重新探测IP 10) 卸载      0) 退出\n'
    printf '\n选择: '
    local c; read -r c; printf '\n'
    case "$c" in
      1) ui_add ;;
      2) ui_del ;;
      3) ui_port ;;
      4) ui_sni ;;
      5) ui_show ;;
      6) apply && ok "服务已重启" ;;
      7) svc_log 40 ;;
      8) core_install 1 && apply && ok "内核已更新" ;;
      9) detect_addrs 0 ;;
      10) ui_uninstall ;;
      0|q|Q) exit 0 ;;
      *) err "无效选择" ;;
    esac
    printf '\n%s按回车继续…%s' "$D" "$N"; read -r _
  done
}

# =============================================================================
#  CLI
# =============================================================================
usage() {
  cat <<EOF
${W}mnode v${VERSION}${N} — mihomo 节点搭建 / 删除 / 改端口 / 改 SNI

  mnode                          交互菜单
  mnode add <协议> [端口] [SNI]   搭建节点（端口留空 = 随机）
  mnode del <节点名>              删除节点
  mnode port <节点名> <新端口>     修改端口
  mnode sni  <节点名> <新SNI>      修改 SNI
  mnode list                     节点列表
  mnode show [节点名]             详情 + 分享链接
  mnode sub                      Base64 订阅
  mnode qr <节点名>               二维码
  mnode ip                       重新探测公网 IPv4/IPv6
  mnode restart | log | update | uninstall | version

协议:
  vless-reality   VLESS + REALITY（免证书、抗封锁，首选）
  vless-ws        VLESS + WS 明文（套 CDN 用，SNI 即回源域名）
  ss2022          Shadowsocks-2022（无 SNI）

例:
  mnode add vless-reality 8443 www.tesla.com
  mnode add ss2022
  mnode port vless-reality-1 23456
  mnode sni  vless-reality-1 www.apple.com

说明: 服务器有公网 IPv6 时，每个节点会额外输出一条 IPv6 链接（标签后缀 -v6）；
      没有 IPv6 则只输出 IPv4，不产生无效链接。
EOF
}

# 把自己装成 /usr/local/bin/mnode
#   直接执行脚本文件 → 复制 $0
#   bash <(curl ...) / 管道执行 → $0 是不可复用的 fd，改为从 SELF_URL 重新下载
self_install() {
  [ "${MNODE_NO_SELFCOPY:-0}" = 1 ] && return 0
  [ "$0" = "$SELF" ] && return 0
  if [ -f "$0" ] && head -n1 "$0" 2>/dev/null | grep -q '^#!'; then
    cat "$0" > "$SELF" 2>/dev/null && chmod +x "$SELF" && { ok "已安装命令: mnode"; return 0; }
  fi
  local tmp; tmp="$(mktemp)"
  if curl -fsSL --retry 2 --max-time 30 -o "$tmp" "$SELF_URL" 2>/dev/null \
     || curl -fsSL --retry 1 --max-time 30 -o "$tmp" "https://ghfast.top/$SELF_URL" 2>/dev/null; then
    if head -n1 "$tmp" | grep -q '^#!' && bash -n "$tmp" 2>/dev/null; then
      cat "$tmp" > "$SELF" && chmod +x "$SELF" && ok "已安装命令: mnode"
      rm -f "$tmp"; return 0
    fi
  fi
  rm -f "$tmp"
  warn "未能自动安装 mnode 命令，可手动下载: curl -fsSLo $SELF $SELF_URL && chmod +x $SELF"
  return 0
}

bootstrap() {
  need_root
  ensure_deps
  mkdir -p "$ROOT" "$NODES"
  chmod 700 "$ROOT"
  core_install 0
  self_install
  svc_install
  [ -s "$ROOT/.ip4" ] || detect_addrs 0
  [ -f "$CONF" ] || build_conf
}

main() {
  if [ $# -eq 0 ]; then bootstrap; menu; return; fi
  case "$1" in
    -h|--help|help) usage; return 0 ;;
    -v|--version|version) printf 'mnode %s\n' "$VERSION"; return 0 ;;
  esac
  need_root
  # 内核或 mnode 命令任一缺失都要走一次 bootstrap
  { [ -x "$CORE" ] && [ -x "$SELF" ]; } || bootstrap
  local cmd="$1"; shift
  case "$cmd" in
    add)  [ $# -ge 1 ] || { err "用法: mnode add <协议> [端口] [SNI]"; return 1; }
          node_add "$1" "${2:-}" "${3:-}" ;;
    del|rm|delete)
          [ $# -ge 1 ] || { err "用法: mnode del <节点名>"; return 1; }
          node_del "$1" ;;
    port) [ $# -ge 2 ] || { err "用法: mnode port <节点名> <新端口>"; return 1; }
          node_port "$1" "$2" ;;
    sni)  [ $# -ge 2 ] || { err "用法: mnode sni <节点名> <新SNI>"; return 1; }
          node_sni "$1" "$2" ;;
    list|ls) list_nodes ;;
    show) if [ $# -ge 1 ]; then show_node "$1"; else ui_show; fi ;;
    sub)  sub_b64 ;;
    qr)   [ $# -ge 1 ] || { err "用法: mnode qr <节点名>"; return 1; }
          nexists "$1" || { err "节点不存在: $1"; return 1; }
          show_qr "$(link "$1" "$(addr4)")" ;;
    ip|addr) detect_addrs 0 ;;
    restart|apply) apply && ok "服务已重启" ;;
    log|logs) svc_log 50 ;;
    update) core_install 1 && apply && ok "内核已更新" ;;
    uninstall) ui_uninstall ;;
    menu) menu ;;
    *) err "未知命令: $cmd"; usage; return 1 ;;
  esac
}

main "$@"
