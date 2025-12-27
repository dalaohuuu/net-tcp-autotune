#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# BBR+fq TCP 调优 + 冲突清理（智能版：自动识别SSH客户端IP）
# - 新增：优先自动从SSH连接中获取客户端IP进行RTT测试，失败则回退到手动输入
# - 新增：--dry-run / --apply 命令行接口
#   * 默认 dry-run：只展示将要做的修改，不写入、不移动、不应用
#   * --apply：真正执行修改
# - 计算：BDP(bytes)=Mbps*125*ms；max = min(2*BDP, 3%RAM, 64MB)；向下桶化至 {4,8,16,32,64}MB
# - 写入：/etc/sysctl.d/999-net-bbr-fq.conf
# - 清理：备份并注释 /etc/sysctl.conf 的冲突键；备份并移除 /etc/sysctl.d/*.conf 中含冲突键的旧文件
# - 其他目录（/usr/lib|/lib|/usr/local/lib|/run/sysctl.d）：仅提示不改
# =========================================================

note() { echo -e "\033[1;34m[i]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
bad()  { echo -e "\033[1;31m[!!]\033[0m $*"; }

usage() {
  cat <<'EOF'
Usage:
  net-tcp-autotune.sh [--dry-run] [--apply] [--yes]

Modes:
  --dry-run   预演模式（默认）：只打印将要执行的操作，不改系统
  --apply     应用模式：真正修改系统（写入/备份/移动/sysctl/tc）

Options:
  --yes       在 --apply 下跳过二次确认

Examples:
  ./net-tcp-autotune.sh
  ./net-tcp-autotune.sh --dry-run
  ./net-tcp-autotune.sh --apply
  ./net-tcp-autotune.sh --apply --yes
EOF
}

# ---- dry-run / apply 开关 ----
MODE="dry-run"   # 默认
ASSUME_YES=0

for arg in "${@:-}"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --apply)   MODE="apply" ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      bad "未知参数: $arg"
      usage
      exit 2
      ;;
  esac
done

DRY_RUN=0
if [ "$MODE" = "dry-run" ]; then
  DRY_RUN=1
  warn "DRY-RUN 模式：不会对系统做任何修改（仅预演）。要真正生效请加 --apply"
else
  note "APPLY 模式：将对系统进行修改"
fi

# 统一封装执行器：dry-run 时只打印，不执行
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    note "DRY-RUN: $*"
    return 0
  fi
  eval "$@"
}

run_quiet() {
  if [ "$DRY_RUN" -eq 1 ]; then
    note "DRY-RUN: $*"
    return 0
  fi
  eval "$@" >/dev/null 2>&1
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    bad "请以 root 运行"
    exit 1
  fi
}

default_iface(){ ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true; }

# --- 自动检测函数 ---
get_mem_gib() {
  local mem_bytes
  mem_bytes=$(free -b | awk '/^Mem:/ {print $2}')
  awk -v bytes="$mem_bytes" 'BEGIN {printf "%.2f", bytes / 1024^3}'
}

get_rtt_ms() {
  local ping_target=""
  local ping_desc=""

  # 1) 优先从 SSH 环境变量中自动获取客户端 IP（set -u 安全展开）
  if [ -n "${SSH_CONNECTION:-}" ]; then
    ping_target=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    ping_desc="SSH 客户端 ${ping_target}"
    note "成功从 SSH 连接中自动检测到客户端 IP: ${ping_target}"
  else
    # 2) 非 SSH 环境回退：手动输入
    note "未检测到 SSH 连接环境，需要您提供一个客户机IP。"
    local client_ip
    read -r -p "请输入一个代表性客户机IP进行ping测试 (直接回车则ping 1.1.1.1): " client_ip
    if [ -n "$client_ip" ]; then
      ping_target="$client_ip"
      ping_desc="客户机IP ${ping_target}"
    fi
  fi

  # 3) 仍未获得目标则用公共地址
  if [ -z "$ping_target" ]; then
    ping_target="1.1.1.1"
    ping_desc="公共地址 ${ping_target} (通用网络)"
    note "未提供IP，将使用 ${ping_desc} 进行测试。"
  fi

  note "正在通过 ping ${ping_desc} 测试网络延迟..."

  # 更稳的解析：匹配统计行（iputils: rtt；部分实现: round-trip）
  local ping_result
  ping_result=$(
    ping -c 4 -W 2 "$ping_target" 2>/dev/null \
      | awk -F'/' '/(rtt|round-trip)/ {print $5; exit}'
  )

  if [[ "${ping_result:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    ok "检测到平均 RTT: ${ping_result} ms"
    printf "%.0f" "$ping_result"
  else
    warn "Ping ${ping_target} 失败或无法解析 RTT。将使用默认值 150 ms。"
    echo "150"
  fi
}

# --- 使用自动检测的值作为默认值 ---
DEFAULT_MEM_G=$(get_mem_gib)
DEFAULT_RTT_MS=$(get_rtt_ms)
DEFAULT_BW_Mbps=1000

read -r -p "内存大小 (GiB) [自动检测: ${DEFAULT_MEM_G}] : " MEM_G_INPUT
read -r -p "带宽 (Mbps) [默认: ${DEFAULT_BW_Mbps}] : " BW_Mbps_INPUT
read -r -p "往返延迟 RTT (ms) [自动检测: ${DEFAULT_RTT_MS}] : " RTT_ms_INPUT

MEM_G="${MEM_G_INPUT:-$DEFAULT_MEM_G}"
BW_Mbps="${BW_Mbps_INPUT:-$DEFAULT_BW_Mbps}"
RTT_ms="${RTT_ms_INPUT:-$DEFAULT_RTT_MS}"

is_num() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_num "$MEM_G"   || MEM_G="$DEFAULT_MEM_G"
is_int "$BW_Mbps" || BW_Mbps="$DEFAULT_BW_Mbps"
is_num "$RTT_ms"  || RTT_ms="$DEFAULT_RTT_MS"

SYSCTL_TARGET="/etc/sysctl.d/999-net-bbr-fq.conf"

# 修复：允许前导空白，避免漏匹配
KEY_REGEX='^[[:space:]]*(net\.core\.default_qdisc|net\.core\.rmem_max|net\.core\.wmem_max|net\.core\.rmem_default|net\.core\.wmem_default|net\.ipv4\.tcp_rmem|net\.ipv4\.tcp_wmem|net\.ipv4\.tcp_congestion_control)[[:space:]]*='

# ---- 计算 ----
BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
MEM_BYTES=$(awk -v g="$MEM_G" 'BEGIN{ printf "%.0f", g*1024*1024*1024 }')
TWO_BDP=$(( BDP_BYTES*2 ))
RAM3_BYTES=$(awk -v m="$MEM_BYTES" 'BEGIN{ printf "%.0f", m*0.03 }')
CAP64=$(( 64*1024*1024 ))
MAX_NUM_BYTES=$(awk -v a="$TWO_BDP" -v b="$RAM3_BYTES" -v c="$CAP64" 'BEGIN{ m=a; if(b<m)m=b; if(c<m)m=c; printf "%.0f", m }')

bucket_le_mb() {
  local mb="${1:-0}"
  if   [ "$mb" -ge 64 ]; then echo 64
  elif [ "$mb" -ge 32 ]; then echo 32
  elif [ "$mb" -ge 16 ]; then echo 16
  elif [ "$mb" -ge  8 ]; then echo 8
  elif [ "$mb" -ge  4 ]; then echo 4
  else echo 4
  fi
}
MAX_MB_NUM=$(( MAX_NUM_BYTES/1024/1024 ))
MAX_MB=$(bucket_le_mb "$MAX_MB_NUM")
MAX_BYTES=$(( MAX_MB*1024*1024 ))

if [ "$MAX_MB" -ge 32 ]; then
  DEF_R=262144; DEF_W=524288
elif [ "$MAX_MB" -ge 8 ]; then
  DEF_R=131072; DEF_W=262144
else
  DEF_R=131072; DEF_W=131072
fi

TCP_RMEM_MIN=4096; TCP_RMEM_DEF=87380; TCP_RMEM_MAX=$MAX_BYTES
TCP_WMEM_MIN=4096; TCP_WMEM_DEF=65536; TCP_WMEM_MAX=$MAX_BYTES

# ---- 冲突清理 ----
comment_conflicts_in_sysctl_conf() {
  local f="/etc/sysctl.conf"
  [ -f "$f" ] || { ok "/etc/sysctl.conf 不存在"; return 0; }
  if grep -Eq "$KEY_REGEX" "$f"; then
    local backup_file="${f}.bak.$(date +%Y%m%d-%H%M%S)"
    note "发现冲突，备份 /etc/sysctl.conf 至 ${backup_file}"
    run "cp -a '$f' '$backup_file'"

    note "注释 /etc/sysctl.conf 中的冲突键"
    if [ "$DRY_RUN" -eq 1 ]; then
      note "DRY-RUN: 将会注释以下行："
      grep -nE "$KEY_REGEX" "$f" || true
      return 0
    fi

    awk -v re="$KEY_REGEX" '
      $0 ~ re && $0 !~ /^[[:space:]]*#/ { print "# " $0; next }
      { print $0 }
    ' "$f" > "${f}.tmp.$$"
    install -m 0644 "${f}.tmp.$$" "$f"
    rm -f "${f}.tmp.$$"
    ok "已注释掉冲突键"
  else
    ok "/etc/sysctl.conf 无冲突键"
  fi
}

delete_conflict_files_in_dir() {
  local dir="$1"
  [ -d "$dir" ] || { ok "$dir 不存在"; return 0; }
  shopt -s nullglob
  local moved=0
  local backup_suffix=".bak.$(date +%Y%m%d-%H%M%S)"
  for f in "$dir"/*.conf; do
    [ "$(readlink -f "$f")" = "$(readlink -f "$SYSCTL_TARGET")" ] && continue
    if grep -Eq "$KEY_REGEX" "$f"; then
      note "命中冲突键（将备份移除）：$f"
      grep -nE "$KEY_REGEX" "$f" || true
      local backup_file="${f}${backup_suffix}"
      run "mv -- '$f' '$backup_file'"
      note "已备份并移除冲突文件: $f -> $backup_file"
      moved=1
    fi
  done
  shopt -u nullglob
  [ "$moved" -eq 1 ] && ok "$dir 中的冲突文件已处理" || ok "$dir 无需处理"
}

scan_conflicts_ro() {
  local dir="$1"
  [ -d "$dir" ] || { ok "$dir 不存在"; return 0; }
  if grep -RIlEq "$KEY_REGEX" "$dir" 2>/dev/null; then
    warn "发现潜在冲突（只提示不改）：$dir"
    grep -RhnE "$KEY_REGEX" "$dir" 2>/dev/null || true
  else
    ok "$dir 未发现冲突"
  fi
}

# ---- APPLY 前二次确认（可 --yes 跳过）----
confirm_apply() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi

  cat <<EOF
即将对系统做修改，包括：
- 可能备份并注释 /etc/sysctl.conf 的冲突项
- 可能备份并移动 /etc/sysctl.d/*.conf（含冲突键的文件）
- 写入 ${SYSCTL_TARGET}
- 执行 sysctl --system（应用内核参数）
- 尝试对默认网卡设置 fq qdisc

如要继续请输入: APPLY
EOF
  local ans
  read -r -p "> " ans
  if [ "$ans" != "APPLY" ]; then
    bad "已取消"
    exit 1
  fi
}

# ---- 主流程 ----
require_root

# 先展示计算结果（dry-run/apply 都展示）
echo "==== PLAN ===="
echo "将使用值 -> 内存: ${MEM_G} GiB, 带宽: ${BW_Mbps} Mbps, RTT: ${RTT_ms} ms"
echo "BDP: ${BDP_BYTES} bytes (~$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB)"
echo "桶值: ${MAX_MB} MB (max buffer = ${MAX_BYTES} bytes)"
echo "写入目标: ${SYSCTL_TARGET}"
echo "模式: ${MODE}"
echo "============="

confirm_apply

note "步骤A：备份并注释 /etc/sysctl.conf 冲突键"
comment_conflicts_in_sysctl_conf

note "步骤B：备份并移除 /etc/sysctl.d 下含冲突键的旧文件"
delete_conflict_files_in_dir "/etc/sysctl.d"

note "步骤C：扫描其他目录（只读提示，不改）"
/usr/bin/true
scan_conflicts_ro "/usr/local/lib/sysctl.d"
scan_conflicts_ro "/usr/lib/sysctl.d"
scan_conflicts_ro "/lib/sysctl.d"
scan_conflicts_ro "/run/sysctl.d"

# ---- 启用 BBR 模块（若为内置则无影响）----
if command -v modprobe >/dev/null 2>&1; then
  run_quiet "modprobe tcp_bbr" || true
fi

# ---- 写入 sysctl 配置 ----
tmpf="$(mktemp)"
SYSCTL_LOG="$(mktemp)"
trap 'rm -f "$tmpf" "$SYSCTL_LOG"' EXIT

cat >"$tmpf" <<EOF
# Auto-generated by net-tcp-autotune (smart-detect + backup-conflicts)
# Inputs: MEM_G=${MEM_G}GiB, BW=${BW_Mbps}Mbps, RTT=${RTT_ms}ms
# BDP: ${BDP_BYTES} bytes (~$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB)
# Caps: min(2*BDP, 3%RAM, 64MB) -> Bucket ${MAX_MB} MB

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}

net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
EOF

if [ "$DRY_RUN" -eq 1 ]; then
  note "DRY-RUN: 将写入 ${SYSCTL_TARGET} 的内容如下："
  sed -n '1,200p' "$tmpf"
else
  run "install -m 0644 '$tmpf' '$SYSCTL_TARGET'"
fi

# ---- 应用 sysctl（只执行一次并复用输出）----
if [ "$DRY_RUN" -eq 1 ]; then
  note "DRY-RUN: 将执行 sysctl --system"
else
  if ! sysctl --system >"$SYSCTL_LOG" 2>&1; then
    warn "sysctl --system 应用时出现错误（可能有不支持的参数/旧文件），输出前120行："
    sed -n '1,120p' "$SYSCTL_LOG" || true
  else
    ok "sysctl --system 已应用"
  fi
fi

# ---- tc 设置 fq ----
IFACE="$(default_iface)"
if command -v tc >/dev/null 2>&1 && [ -n "${IFACE:-}" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    note "DRY-RUN: 将执行 tc qdisc replace dev '${IFACE}' root fq"
  else
    if ! tc qdisc replace dev "$IFACE" root fq 2>/dev/null; then
      warn "tc 设置 fq 失败（可能容器/内核/权限限制），已跳过"
    fi
  fi
fi

# ---- 输出结果 ----
echo "==== RESULT ===="
echo "最终使用值 -> 内存: ${MEM_G} GiB, 带宽: ${BW_Mbps} Mbps, RTT: ${RTT_ms} ms"
echo "计算出的桶值: ${MAX_MB} MB"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "(DRY-RUN 模式：未应用 sysctl，以下为“计划值”，非实际内核值)"
  echo "net.ipv4.tcp_congestion_control = bbr"
  echo "net.core.default_qdisc = fq"
  echo "net.core.rmem_max = ${MAX_BYTES}"
  echo "net.core.wmem_max = ${MAX_BYTES}"
  echo "net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}"
  echo "net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}"
else
  sysctl -n net.ipv4.tcp_congestion_control || true
  sysctl -n net.core.default_qdisc || true
  sysctl -n net.core.rmem_max || true
  sysctl -n net.core.wmem_max || true
  sysctl -n net.ipv4.tcp_rmem || true
  sysctl -n net.ipv4.tcp_wmem || true
  if command -v tc >/dev/null 2>&1 && [ -n "${IFACE:-}" ]; then
    echo "qdisc on ${IFACE}:"
    tc qdisc show dev "$IFACE" || true
  fi
fi
echo "==============="

note "复核：查看加载顺序及最终值来源（只读）"
if [ "$DRY_RUN" -eq 1 ]; then
  note "DRY-RUN: 将从 sysctl --system 输出中过滤以下关键行：Applying / rmem/wmem / qdisc / congestion_control"
else
  grep -nE --color=never 'Applying|net\.core\.(rmem|wmem)|net\.core\.default_qdisc|net\.ipv4\.tcp_(rmem|wmem)|tcp_congestion_control' "$SYSCTL_LOG" || true
fi
