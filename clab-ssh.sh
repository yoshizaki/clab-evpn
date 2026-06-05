#!/usr/bin/env bash
# =============================================================================
# clab-ssh.sh — Containerlab ノード SSH ラッパー
# Usage:
#   ./clab-ssh.sh                    # 全ラボ一覧 → 対話的に選択
#   ./clab-ssh.sh -l <lab-name>      # 指定ラボのノード一覧 → 選択
#   ./clab-ssh.sh -n <node-name>     # ノード名を直指定して SSH
#   ./clab-ssh.sh -a                 # 全ラボの全ノード一覧 → 選択
#
# 依存: containerlab, jq, ssh
# =============================================================================

set -euo pipefail

# ─── デフォルト SSH オプション ────────────────────────────────────────────────
SSH_USER="${CLAB_SSH_USER:-admin}"
SSH_PORT="${CLAB_SSH_PORT:-22}"
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -p "$SSH_PORT"
)

# ─── カラー定義 ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── ヘルパー関数 ─────────────────────────────────────────────────────────────
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "コマンドが見つかりません: $cmd"
  done
}

# ─── clab inspect JSON 取得 ───────────────────────────────────────────────────
# 戻り値: [{name, lab_name, ipv4_address, ipv6_address, state, kind}, ...]
get_nodes_json() {
  local extra_opts=("$@")
  containerlab inspect "${extra_opts[@]}" --format json 2>/dev/null \
    | jq -r '[.. | objects | select(has("ipv4_address"))]' 2>/dev/null \
    || echo "[]"
}

# IPv4 アドレスからサブネットプレフィックスを除去 (例: 172.20.20.3/24 → 172.20.20.3)
strip_prefix() { echo "${1%%/*}"; }

# ─── ノード一覧表示 & 選択 ───────────────────────────────────────────────────
select_node() {
  local nodes_json="$1"
  local count
  count=$(echo "$nodes_json" | jq 'length')
  [[ "$count" -eq 0 ]] && die "対象ノードが見つかりません"

  echo ""
  echo -e "${BOLD}  #   Node Name                      IPv4 Address      State    Kind${RESET}"
  echo    "  ─────────────────────────────────────────────────────────────────────"

  local i=0
  local names=() ips=()
  while IFS=$'\t' read -r name ipv4 state kind; do
    local ip
    ip=$(strip_prefix "$ipv4")
    local state_color="$GREEN"
    [[ "$state" != "running" ]] && state_color="$RED"
    printf "  ${CYAN}%-3d${RESET} %-30s  %-17s  ${state_color}%-8s${RESET} %s\n" \
      "$((i+1))" "$name" "$ip" "$state" "$kind"
    names+=("$name")
    ips+=("$ip")
    ((i++))
  done < <(echo "$nodes_json" \
    | jq -r '.[] | [.name, .ipv4_address, .state, .kind] | @tsv')

  echo ""
  read -rp "  接続するノードの番号を入力 [1-${count}] (q で終了): " choice
  [[ "$choice" == "q" ]] && exit 0
  [[ ! "$choice" =~ ^[0-9]+$ ]] && die "無効な入力です"
  [[ "$choice" -lt 1 || "$choice" -gt "$count" ]] && die "番号が範囲外です"

  SELECTED_NAME="${names[$((choice-1))]}"
  SELECTED_IP="${ips[$((choice-1))]}"
}

# ─── SSH 接続 ─────────────────────────────────────────────────────────────────
do_ssh() {
  local host="$1"
  local node_name="${2:-$host}"

  [[ -z "$host" || "$host" == "N/A" ]] && die "IPv4 アドレスが取得できません: $node_name"

  info "接続先: ${BOLD}${node_name}${RESET} (${host}) — ユーザ: ${SSH_USER}"
  echo ""
  # パスワード認証が必要な NOS が多いため sshpass 対応も考慮
  # SSH_PASS 環境変数がセットされていれば sshpass を使う
  if [[ -n "${SSH_PASS:-}" ]] && command -v sshpass &>/dev/null; then
    sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}"
  else
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}"
  fi
}

# ─── メイン ───────────────────────────────────────────────────────────────────
main() {
  require_cmd containerlab jq ssh

  local mode="interactive"
  local lab_name=""
  local node_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--lab)   lab_name="${2:-}"; shift 2; mode="lab" ;;
      -n|--node)  node_name="${2:-}"; shift 2; mode="node" ;;
      -a|--all)   mode="all"; shift ;;
      -u|--user)  SSH_USER="${2:-}"; shift 2 ;;
      -p|--port)  SSH_PORT="${2:-}"; shift 2 ;;
      -h|--help)
        grep '^# ' "$0" | head -8 | sed 's/^# //'
        echo ""
        echo "環境変数:"
        echo "  CLAB_SSH_USER   SSH ユーザ名 (デフォルト: admin)"
        echo "  CLAB_SSH_PORT   SSH ポート番号 (デフォルト: 22)"
        echo "  SSH_PASS        パスワード (sshpass 使用時)"
        exit 0 ;;
      *) warn "不明なオプション: $1"; shift ;;
    esac
  done

  echo ""
  echo -e "${BOLD}  Containerlab SSH Helper${RESET}"
  echo    "  ─────────────────────────────────"

  case "$mode" in
    node)
      # ノード名から直接 IPv4 を取得
      local ip
      ip=$(containerlab inspect --all --format json 2>/dev/null \
        | jq -r --arg n "$node_name" \
            '[.. | objects | select(has("ipv4_address") and .name == $n)] | .[0].ipv4_address // empty')
      ip=$(strip_prefix "${ip:-}")
      [[ -z "$ip" ]] && die "ノードが見つかりません: $node_name"
      do_ssh "$ip" "$node_name"
      ;;

    lab)
      [[ -z "$lab_name" ]] && die "-l オプションにラボ名を指定してください"
      local json
      json=$(get_nodes_json --name "$lab_name")
      select_node "$json"
      do_ssh "$SELECTED_IP" "$SELECTED_NAME"
      ;;

    all)
      local json
      json=$(get_nodes_json --all)
      select_node "$json"
      do_ssh "$SELECTED_IP" "$SELECTED_NAME"
      ;;

    interactive)
      # まずラボ一覧を表示して選択させる
      local labs
      labs=$(containerlab inspect --all --format json 2>/dev/null \
        | jq -r 'keys[]' 2>/dev/null | sort -u || echo "")
      [[ -z "$labs" ]] && die "起動中のラボが見つかりません"

      local lab_count
      lab_count=$(echo "$labs" | wc -l)

      if [[ "$lab_count" -eq 1 ]]; then
        lab_name="$labs"
        info "ラボを自動選択: ${BOLD}${lab_name}${RESET}"
      else
        echo ""
        echo -e "${BOLD}  起動中のラボ一覧${RESET}"
        echo    "  ──────────────────"
        local idx=1
        local lab_arr=()
        while IFS= read -r l; do
          printf "  ${CYAN}%d${RESET}  %s\n" "$idx" "$l"
          lab_arr+=("$l")
          ((idx++))
        done <<< "$labs"
        echo ""
        read -rp "  ラボの番号を入力 [1-${lab_count}]: " lc
        [[ ! "$lc" =~ ^[0-9]+$ || "$lc" -lt 1 || "$lc" -gt "$lab_count" ]] \
          && die "無効な番号です"
        lab_name="${lab_arr[$((lc-1))]}"
      fi

      local json
      json=$(get_nodes_json --name "$lab_name")
      select_node "$json"
      do_ssh "$SELECTED_IP" "$SELECTED_NAME"
      ;;
  esac
}

main "$@"
