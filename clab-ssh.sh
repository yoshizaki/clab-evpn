#!/usr/bin/env bash
# =============================================================================
# clab-ssh.sh — Containerlab ノード SSH ラッパー
# 使い方の詳細は ./clab-ssh.sh -h を参照
# 依存: containerlab, jq, ssh (パスワード認証には sshpass)
# =============================================================================

set -euo pipefail

SSH_USER="${CLAB_SSH_USER:-admin}"
SSH_PORT="${CLAB_SSH_PORT:-22}"

# ─── カラー定義 (出力が TTY のときのみ有効) ──────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ─── ヘルパー関数 ─────────────────────────────────────────────────────────────
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }

usage() {
  cat <<'EOF'
Usage:
  clab-ssh.sh                    # 全ラボ一覧 → 対話的に選択
  clab-ssh.sh <node-name>        # ノード名を直指定して SSH (-n と同じ)
  clab-ssh.sh -l <lab-name>      # 指定ラボのノード一覧 → 選択
  clab-ssh.sh -n <node-name>     # ノード名を直指定して SSH
  clab-ssh.sh -a                 # 全ラボの全ノード一覧 → 選択

オプション:
  -l, --lab <lab>     対象ラボを指定
  -n, --node <node>   ノード名を直指定
  -a, --all           全ラボの全ノードを対象にする
  -u, --user <user>   SSH ユーザ名 (デフォルト: admin)
  -p, --port <port>   SSH ポート番号 (デフォルト: 22)
  -h, --help          このヘルプを表示

環境変数:
  CLAB_SSH_USER   SSH ユーザ名 (デフォルト: admin)
  CLAB_SSH_PORT   SSH ポート番号 (デフォルト: 22)
  SSH_PASS        パスワード (sshpass 使用時)

依存: containerlab, jq, ssh (パスワード認証には sshpass)
EOF
}

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "コマンドが見つかりません: $cmd"
  done
}

# 値を取るオプションに値が渡されているか検証する (need_arg "$@" で呼ぶ)
need_arg() {
  [[ $# -ge 2 ]] || die "オプション $1 には値が必要です"
}

# ─── clab inspect JSON 取得 ───────────────────────────────────────────────────
# 戻り値: [{name, lab_name, ipv4_address, ipv6_address, state, kind}, ...]
# containerlab のバージョンによる出力形式の差異を吸収するため、
# トップレベル構造には依存せず ipv4_address を持つオブジェクトを再帰的に拾う
get_nodes_json() {
  # containerlab は成功時にも stderr へ INFO ログを出すため、stdout と混ぜずに
  # 別ファイルへ退避し、失敗時のみエラーメッセージとして表示する
  local raw err err_file rc=0
  err_file=$(mktemp)
  raw=$(containerlab inspect "$@" --format json 2>"$err_file") || rc=$?
  err=$(<"$err_file")
  rm -f "$err_file"
  if [[ "$rc" -ne 0 ]]; then
    die "containerlab inspect に失敗しました:\n${err}"
  fi
  [[ -z "$raw" ]] && { echo "[]"; return; }
  jq '[.. | objects | select(has("ipv4_address"))]' <<< "$raw" \
    || die "containerlab inspect の出力を JSON として解析できませんでした"
}

# IPv4 アドレスからサブネットプレフィックスを除去 (例: 172.20.20.3/24 → 172.20.20.3)
strip_prefix() { echo "${1%/[0-9]*}"; }

# ─── ノード一覧表示 & 選択 ───────────────────────────────────────────────────
# 選択結果はグローバル変数 SELECTED_NAME / SELECTED_IP に設定される
SELECTED_NAME=""
SELECTED_IP=""

select_node() {
  local nodes_json="$1"
  local allow_auto="${2:-1}"  # 1 ならノードが 1 台のとき自動選択する
  local count
  count=$(jq 'length' <<< "$nodes_json")
  [[ "$count" -eq 0 ]] && die "対象ノードが見つかりません"

  local names=() ips=() states=() kinds=()
  while IFS=$'\t' read -r name ipv4 state kind; do
    names+=("$name")
    ips+=("$(strip_prefix "$ipv4")")
    states+=("$state")
    kinds+=("$kind")
  done < <(jq -r '.[] | [.name, .ipv4_address, .state, .kind] | @tsv' <<< "$nodes_json")

  # ノードが 1 台だけなら一覧を出さずに自動選択 (ログアウト後の再表示時は除く)
  if [[ "$count" -eq 1 && "$allow_auto" -eq 1 ]]; then
    SELECTED_NAME="${names[0]}"
    SELECTED_IP="${ips[0]}"
    info "ノードを自動選択: ${BOLD}${SELECTED_NAME}${RESET}"
    return
  fi

  # Node Name 列は最長のノード名に合わせて幅を決める (ヘッダ "Node Name" 分は最低確保)
  local name_w=9 n
  for n in "${names[@]}"; do
    (( ${#n} > name_w )) && name_w=${#n}
  done

  echo ""
  printf "  ${BOLD}%-3s %-${name_w}s  %-17s  %-8s %s${RESET}\n" \
    "#" "Node Name" "IPv4 Address" "State" "Kind"
  printf "  %s\n" "$(printf '─%.0s' $(seq $((name_w + 38))))"

  local i
  for ((i = 0; i < count; i++)); do
    local state_color="$GREEN"
    [[ "${states[$i]}" != "running" ]] && state_color="$RED"
    printf "  ${CYAN}%-3d${RESET} %-${name_w}s  %-17s  ${state_color}%-8s${RESET} %s\n" \
      "$((i+1))" "${names[$i]}" "${ips[$i]}" "${states[$i]}" "${kinds[$i]}"
  done

  echo ""
  # 無効な入力は終了せずに再入力を促す
  local choice
  while true; do
    read -rp "  接続するノードの番号を入力 [1-${count}] (q で終了): " choice
    [[ "$choice" == "q" ]] && exit 0
    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$count" ]] && break
    warn "無効な入力です: '${choice}' (1-${count} の番号か q を入力してください)"
  done

  SELECTED_NAME="${names[$((choice-1))]}"
  SELECTED_IP="${ips[$((choice-1))]}"
}

# ─── SSH 接続 ─────────────────────────────────────────────────────────────────
do_ssh() {
  local host="$1"
  local node_name="${2:-$host}"

  [[ -z "$host" || "$host" == "N/A" ]] && die "IPv4 アドレスが取得できません: $node_name"

  # -u/-p オプションを反映するため、SSH オプションは接続直前に組み立てる
  local ssh_opts=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
    -o LogLevel=ERROR
    -p "$SSH_PORT"
  )

  info "接続先: ${BOLD}${node_name}${RESET} (${host}) — ユーザ: ${SSH_USER}"
  echo ""
  # SSH_PASS 環境変数がセットされていれば sshpass でパスワード認証する
  # ログアウト後にノード一覧へ戻れるよう、ssh の終了コードではスクリプトを止めない
  local rc=0
  if [[ -n "${SSH_PASS:-}" ]]; then
    if command -v sshpass &>/dev/null; then
      SSHPASS="$SSH_PASS" sshpass -e ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" || rc=$?
    else
      warn "SSH_PASS が設定されていますが sshpass が見つかりません。対話認証にフォールバックします"
      ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" || rc=$?
    fi
  else
    ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" || rc=$?
  fi

  echo ""
  if [[ "$rc" -eq 0 ]]; then
    info "切断しました: ${node_name}"
  else
    warn "SSH セッションが終了コード ${rc} で終了しました: ${node_name}"
  fi
  return "$rc"
}

# ─── 接続ループ ───────────────────────────────────────────────────────────────
# ノード一覧 → SSH → ログアウト後に一覧へ戻る、を q が入力されるまで繰り返す。
# 引数はそのまま get_nodes_json (containerlab inspect) に渡す。
# 一覧は毎回取り直すため、ループ中のノード状態の変化も反映される。
session_loop() {
  local first=1 json
  while true; do
    json=$(get_nodes_json "$@")
    select_node "$json" "$first"   # q 入力で exit 0
    first=0
    # 接続失敗でもループを継続する (do_ssh 内で警告表示済み)
    do_ssh "$SELECTED_IP" "$SELECTED_NAME" || true
  done
}

# ─── メイン ───────────────────────────────────────────────────────────────────
main() {
  require_cmd containerlab jq ssh

  local mode="interactive"
  local lab_name=""
  local node_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--lab)   need_arg "$@"; lab_name="$2";  mode="lab";  shift 2 ;;
      -n|--node)  need_arg "$@"; node_name="$2"; mode="node"; shift 2 ;;
      -a|--all)   mode="all"; shift ;;
      -u|--user)  need_arg "$@"; SSH_USER="$2"; shift 2 ;;
      -p|--port)  need_arg "$@"; SSH_PORT="$2"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      -*)         die "不明なオプション: $1 (-h でヘルプを表示)" ;;
      *)          node_name="$1"; mode="node"; shift ;;  # 位置引数はノード名扱い
    esac
  done

  echo ""
  echo -e "${BOLD}  Containerlab SSH Helper${RESET}"
  echo    "  ─────────────────────────────────"

  case "$mode" in
    node)
      local json hits
      json=$(get_nodes_json --all \
        | jq --arg n "$node_name" '[.[] | select(.name == $n)]')
      hits=$(jq 'length' <<< "$json")
      if [[ "$hits" -eq 0 ]]; then
        die "ノードが見つかりません: $node_name"
      elif [[ "$hits" -gt 1 ]]; then
        warn "同名ノードが ${hits} 件見つかりました。接続先を選択してください"
        select_node "$json"
      else
        SELECTED_NAME="$node_name"
        SELECTED_IP=$(strip_prefix "$(jq -r '.[0].ipv4_address' <<< "$json")")
      fi
      do_ssh "$SELECTED_IP" "$SELECTED_NAME"
      ;;

    lab)
      session_loop --name "$lab_name"
      ;;

    all)
      session_loop --all
      ;;

    interactive)
      # まずラボ一覧を表示して選択させる
      # (ラボ名はトップレベルのキーではなく各ノードの lab_name から集める)
      local json labs
      json=$(get_nodes_json --all)
      labs=$(jq -r '.[].lab_name // empty' <<< "$json" | sort -u)
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
          idx=$((idx+1))
        done <<< "$labs"
        echo ""
        # 無効な入力は終了せずに再入力を促す
        local lc
        while true; do
          read -rp "  ラボの番号を入力 [1-${lab_count}] (q で終了): " lc
          [[ "$lc" == "q" ]] && exit 0
          [[ "$lc" =~ ^[0-9]+$ && "$lc" -ge 1 && "$lc" -le "$lab_count" ]] && break
          warn "無効な入力です: '${lc}' (1-${lab_count} の番号か q を入力してください)"
        done
        lab_name="${lab_arr[$((lc-1))]}"
      fi

      session_loop --name "$lab_name"
      ;;
  esac
}

main "$@"
