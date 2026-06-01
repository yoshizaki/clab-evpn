# Clabernetes Datapath Stitching トラブルシュート記録（改訂版 rev2）

> Phase 7（ラボデプロイ〜Datapath Stitching 確認）で発生した 2 件の問題について、
> 根本回避策・発見の経緯・切り分け手法・修正方法を記録する。
>
> **改訂方針（rev2）**: 手動修復を並べるのではなく、まず根本回避策（`connectivity: slurpeeth`）を
> 試し、それが使えない/不安定な場合のフォールバックとして手動修復を位置づける二段構えに再構成した。

---

## 0. 結論と推奨フロー（最初に読む）

今回の 2 問題（問題A・問題B）は、いずれも **「VXLAN トンネルを ClusterIP サービス経由で張る」** という
clabernetes デフォルト構成に起因する。したがって対処は次の二段構えが効率的。

```
[Step 1] connectivity: slurpeeth に切り替えて再デプロイ
            │
            ├─ 疎通OK ─→ 完了（推奨ルート。問題A・B とも回避される）
            │
            └─ NG / 採用不可（実験的機能を避けたい等）
                     │
            [Step 2] connectivity: vxlan のまま手動修復
                     ├─ 問題A: vx-* インターフェース欠落 → §3 で再作成
                     └─ 問題B: FDB 誤学習           → §4 で flush + nolearning
                        ※ 必ず A → B の順で実施
```

> ⚠️ **重要（どちらのルートでも共通）**: §3 / §4 の手動修復は **pod 内のランタイム（カーネル / netns）状態**を
> 直接書き換えるものであり、ファイルではない。そのため **ラボ再デプロイ時だけでなく、launcher pod が
> 再起動（eviction / node drain / OOM / ノード再起動）するたびに失われる**。
> `deployment.persistence`（PVC）はノードの設定ファイル永続化用であり、この netns 状態は保存しない。
> 恒久運用するなら slurpeeth 化、もしくは修復を再実行する仕組み（後述）が必要。

---

## 1. 根本回避策: `connectivity: slurpeeth` への切り替え

### なぜ効くのか

clabernetes の inter-node トンネルには 2 つのモードがある。

| 値 | 説明 |
|---|---|
| `vxlan` | VXLAN トンネル（デフォルト）。UDP/14789 を ClusterIP 宛に飛ばす |
| `slurpeeth` | 実験的な TCP トンネル。MTU 問題を回避する |

問題A（`vx-*` 削除バグ）も問題B（VXLAN FDB 誤学習）も **VXLAN 固有**の現象である。
slurpeeth は TCP ベースの別経路を使うため：

- VXLAN インターフェース (`vx-*`) を介した stitching を行わない → **問題A の削除バグの土俵に乗らない**
- VXLAN FDB が存在しない → **問題B の kube-proxy SNAT による FDB 誤学習が発生しない**

### 設定方法

Topology CR に 1 行追加する（clabverter で生成した manifests を編集、または元の生成時に反映）。

```yaml
# Topology CR (spec 直下)
spec:
  connectivity: slurpeeth
  definition:
    containerlab: |
      ...
```

既存のラボに後付けで適用する場合は、namespace ごと削除して再デプロイするのが確実。

```bash
# [controller]
kubectl delete ns c9s-vlan
# manifests.yml の spec に connectivity: slurpeeth を追記してから再適用
kubectl apply -f manifests.yml
```

### 検証

```bash
# [controller]
# LLDP ネイバー（srl1 pod に exec して srl1 コンテナを見る）
SRL1_POD=$(kubectl -n c9s-vlan get pods | grep ^srl1 | awk '{print $1}')
kubectl -n c9s-vlan exec ${SRL1_POD} -- docker exec srl1 sr_cli show system lldp neighbor
# => ethernet-1/10 に srl2 が表示される

# E2E 疎通
CL1_POD=$(kubectl -n c9s-vlan get pods | grep ^client1 | awk '{print $1}')
kubectl -n c9s-vlan exec ${CL1_POD} -- docker exec client1 ping -c 3 10.1.0.2
# => 0% packet loss
```

### 注意

- slurpeeth は **実験的（experimental）** 機能。本番採用前にラボで安定性・性能を確認すること。
- vxlan に戻す場合は `connectivity: vxlan`（または当該行を削除）で再デプロイ。
- slurpeeth でも疎通しない場合は §2（MTU）と §3/§4（vxlan 前提の手動修復）を参照。

---

## 2. 前提アーキテクチャと MTU（二重カプセル化に注意）

### VXLAN-in-VXLAN 構造

本構成では CNI に Calico を `VXLANCrossSubnet` で使用しているため、**Calico の VXLAN の上に
clabernetes の VXLAN が乗る二重カプセル化**になっている。

```
[ inner Ethernet frame (lab) ]
   └─ clabernetes VXLAN ヘッダ (+50B, UDP/14789)   ← stitching 用
        └─ Calico VXLAN ヘッダ (+50B, UDP/4789)     ← CNI overlay
             └─ ノード物理 NIC (MTU 1500)
```

ノード MTU 1500 に対し、Calico VXLAN で実効 1450、その上に clabernetes VXLAN でさらに約 50B 減り、
ラボ内インターフェースの実効 MTU は **おおむね 1400 程度かそれ以下**になる。

### MTU 起因の典型症状

- LLDP（小さいフレーム）や default サイズの `ping`（56B payload）は通る
- しかしフルサイズフレーム（大きい TCP 転送、ファイルコピー、ジャンボ）が **ブラックホール化**する
- slurpeeth が「MTU 問題を回避」とされるのはこの二重カプセル化の解消が理由

### 確認コマンド（DF 付き大パケット試験を検証に追加することを推奨）

```bash
# [controller]
CL1_POD=$(kubectl -n c9s-vlan get pods | grep ^client1 | awk '{print $1}')
# DF ビット付きで 1400B を送り、抜けるか確認
kubectl -n c9s-vlan exec ${CL1_POD} -- docker exec client1 ping -c 3 -s 1400 -M do 10.1.0.2
# => 通れば MTU は十分。"Frag needed" / 無応答なら MTU 起因を疑い、
#    ラボ側インターフェース MTU を下げる or slurpeeth 化を検討
```

---

## 3. 問題A: clabernetes v0.5.0 で `vx-*` が即削除されるバグ（vxlan モード時）

> slurpeeth が使えない場合のフォールバック手順。**§4 より先に実施すること**（順序依存は §4 冒頭参照）。

### 症状

- srl1 ↔ srl2 の LLDP ネイバーが確立しない
- `client1 → client2` の ping が `Destination Host Unreachable`

### 発見の経緯

**Step 1 — LLDP テーブルが空であることを確認**

```bash
SRL1_POD=$(kubectl -n c9s-vlan get pods | grep ^srl1 | awk '{print $1}')
kubectl -n c9s-vlan exec ${SRL1_POD} -- docker exec srl1 sr_cli show system lldp neighbor
# => テーブルが空
```

**Step 2 — VXLAN サービスが存在することを確認**

```bash
kubectl get svc -n c9s-vlan
# => srl1-vx, srl2-vx, client1-vx, client2-vx の ClusterIP が存在
```

VXLAN サービスが揃っているのにネイバーが見えない → トンネル自体が壊れているはず。

**Step 3 — srl1 / srl2 pod のインターフェースを比較**

```bash
SRL2_POD=$(kubectl -n c9s-vlan get pods | grep ^srl2 | awk '{print $1}')
kubectl -n c9s-vlan exec ${SRL1_POD} -- ip link show | grep vx-   # => vx-srl1-e1-1, vx-srl1-e1-10
kubectl -n c9s-vlan exec ${SRL2_POD} -- ip link show | grep vx-   # => vx-srl2-e1-1 のみ！e1-10 が欠落
```

**Step 4 — launcher ログで根本原因を特定**

```bash
kubectl -n c9s-vlan logs ${SRL2_POD} 2>&1 | grep -E 'vxlan|e1-10|Delet'
```

```
INFO  | clabernetes | connectivity mode is 'vxlan', setting up any required tunnels...
ERROR |             | No links found by specified prefix vx-srl2-e1-10.
INFO  | clabernetes | configuring ingress mirroring with tc: host:vx-srl2-e1-10 -> host:srl2-e1-10
INFO  | clabernetes | Deleting VxLAN link vx-srl2-e1-10   ← 作成直後に自分で削除している
```

srl1 側の同ログには "Deleting VxLAN link" が出ない。**srl2 側だけ削除が走る v0.5.0 のバグ**。

### 検出ロジック（srl2 固定ではなく、欠落を自動判定する）

毎回 srl2 が被害者とは限らないため、**「tc redirect が参照しているのに実在しない `vx-*` デバイス」**
というバグの指紋で、どの pod のどのトンネルが欠落しているかを汎用的に検出する。

```bash
# [controller]
for POD in $(kubectl -n c9s-vlan get pods --no-headers -o custom-columns=:.metadata.name); do
  echo "== ${POD} =="
  kubectl -n c9s-vlan exec ${POD} -- sh -c '
    for DEV in $(tc qdisc show 2>/dev/null | grep ingress | grep -oE "dev [^ ]+" | awk "{print \$2}" | sort -u); do
      TGT=$(tc filter show dev "$DEV" ingress 2>/dev/null | grep -oE "redirect dev [^ ]+" | awk "{print \$3}" | head -1)
      [ -n "$TGT" ] || continue
      if ! ip link show "$TGT" >/dev/null 2>&1; then
        echo "  MISSING tunnel: $TGT  (referenced by $DEV)"
      fi
    done
  ' 2>/dev/null
done
# => "MISSING tunnel: vx-srl2-e1-10 (referenced by srl2-e1-10)" のように欠落が一覧表示される
```

### 修復手順（単一 `sh -c` に集約すること）

> ⚠️ **launcher の reconciliation ループが稼働中**のため、`kubectl exec` を複数回に分けると
> 途中で `vx-*` を再削除され `Cannot find device` になる。**必ず単一の `sh -c` にまとめて**実行する。
> 各削除系コマンドには `|| true` を付け、再実行（idempotent）でも止まらないようにする。

```bash
# [controller]  ※ 検出された (POD, 欠落IF, データIF) に合わせて変数を設定
SRL2_POD=$(kubectl -n c9s-vlan get pods | grep ^srl2 | awk '{print $1}')

# VNI（tunnelID）と remote（対向 -vx の ClusterIP）を Connectivity CR / svc から取得
TUNNEL_ID=$(kubectl -n c9s-vlan get connectivity vlan -o yaml | grep -A8 'srl2:' | grep -m1 tunnelID | grep -oE '[0-9]+')
SRL1_VX_IP=$(kubectl -n c9s-vlan get svc srl1-vx -o jsonpath='{.spec.clusterIP}')
echo "pod=${SRL2_POD} vni=${TUNNEL_ID} remote=${SRL1_VX_IP}"

kubectl -n c9s-vlan exec ${SRL2_POD} -- sh -c "
  set -e
  # 1) 既存（壊れた）インターフェースをクリーンアップして再作成
  ip link del vx-srl2-e1-10 2>/dev/null || true
  ip link add vx-srl2-e1-10 type vxlan id ${TUNNEL_ID} \
    remote ${SRL1_VX_IP} dev eth0 dstport 14789
  ip link set vx-srl2-e1-10 up

  # 2) データ IF 側 tc を完全リセット（launcher が ingress qdisc なしで終了している場合に対応）
  tc filter del dev srl2-e1-10 ingress 2>/dev/null || true
  tc qdisc  del dev srl2-e1-10 ingress 2>/dev/null || true
  tc qdisc  add dev srl2-e1-10 ingress

  # 3) トンネル IF 側 ingress qdisc（既存なら無視）
  tc qdisc add dev vx-srl2-e1-10 ingress 2>/dev/null || true

  # 4) 双方向 tc redirect
  tc filter add dev srl2-e1-10    ingress protocol all u32 match u8 0 0 \
    action mirred egress redirect dev vx-srl2-e1-10
  tc filter add dev vx-srl2-e1-10 ingress protocol all u32 match u8 0 0 \
    action mirred egress redirect dev srl2-e1-10

  echo DONE
  ip link show vx-srl2-e1-10 | head -1
"
```

> VNI は必ず Connectivity CR の `tunnelID` と一致させること。remote は対向ノードの `-vx` サービスの ClusterIP。

### 検証（コマンドの宛先 pod / コンテナに注意）

```bash
# [controller]
# srl1 の LLDP ネイバーを見るには srl1 pod に exec する（srl2 pod で docker exec srl1 はできない）
SRL1_POD=$(kubectl -n c9s-vlan get pods | grep ^srl1 | awk '{print $1}')
kubectl -n c9s-vlan exec ${SRL1_POD} -- docker exec srl1 sr_cli show system lldp neighbor
# => ethernet-1/10 に srl2 が表示される
```

> ℹ️ 旧版手順にあった `kubectl exec ${SRL2_POD%} -- docker exec srl1 ...` は 2 点誤りがあった：
> (1) `${SRL2_POD%}` の `%` は誤記、(2) srl2 pod 内に srl1 コンテナは存在しない。上記が正しい。

### 恒久対策

v0.5.0 では本バグが残るため、vxlan モードのままだと **再デプロイ・pod 再起動のたびに**本修復が必要。
推奨は §1 の slurpeeth 化。vxlan を維持する場合は、上流（srl-labs/clabernetes）の Issue 状況を確認し
修正版が出ていれば `helm` で manager を更新、または `deployment.launcherImage` で修正済み launcher を
ピン留めする方法を検討する。

---

## 4. 問題B: kube-proxy の SNAT による VXLAN FDB 誤学習（vxlan モード時）

> ⚠️ **順序依存**: §3 で手動作成した `vx-srl2-e1-10` は `nolearning` 無しで作られる。
> 本節の修復で全 `vx-*` に `nolearning` を付与するため、**必ず §3 →§4 の順**で実施すること。

### 症状

- LLDP（マルチキャスト）は srl1 ↔ srl2 ↔ client で到達する
- しかし `ping`（ユニキャスト ICMP）は `Destination Host Unreachable` のまま
- ARP Request は届くが ARP Reply が戻ってこない

### 構造的背景

各 VXLAN トンネルの outer destination は対向の **ClusterIP**（kube-proxy が DNAT して pod に届ける）。
一方 kube-proxy はサービス経由通信に **SNAT** を適用し、**outer src を ClusterIP ではなくノード IP に
書き換える**ことがある。受信側 VXLAN はこの outer src（ノード IP）を VTEP として FDB に学習してしまう。

```
srl2 pod が VXLAN 送信
  └─ outer src = srl2 pod IP
  └─ kube-proxy SNAT → outer src = ノード IP (192.168.30.61)
  └─ client2 pod が受信
client2 の vx-client2-eth1 が学習: 「この MAC は 192.168.30.61 にいる」→ FDB 登録
次に client2 が同 MAC へユニキャスト: FDB 参照 → 192.168.30.61:14789 へ直送
  → ノード IP には VXLAN listener が無く消失（kube-proxy を経由しないため）
```

ブロードキャスト / マルチキャスト（LLDP 等）はデフォルト FDB エントリ（ClusterIP）を使うので影響を
受けないが、ユニキャスト（ARP Reply・ICMP）は学習済みエントリを使うため誤った宛先に送られる。

### 発見の経緯（要点）

```bash
SRL2_POD=$(kubectl -n c9s-vlan get pods | grep ^srl2 | awk '{print $1}')
CL2_POD=$(kubectl -n c9s-vlan get pods | grep ^client2 | awk '{print $1}')

# (1) VXLAN RX カウンタがゼロのインターフェースを特定
kubectl -n c9s-vlan exec ${SRL2_POD} -- ip -s link show vx-srl2-e1-1   # RX: 0 packets

# (2) pod eth0 で raw UDP キャプチャ → outer src を確認
kubectl -n c9s-vlan exec ${SRL2_POD} -- sh -c 'timeout 6 tcpdump -n -i eth0 udp port 14789 2>&1'

# (3) hex ダンプで VNI をデコード（offset 42〜49 の VXLAN ヘッダ）
kubectl -n c9s-vlan exec ${SRL2_POD} -- sh -c 'timeout 5 tcpdump -n -XX -c 3 -i eth0 udp port 14789 2>&1'
#   0x08 00 00 00 / 0x00 00 03 00 → VNI=3（inter-switch のみ受信、VNI=2 が来ていない）

# (4) FDB を確認して誤学習を特定
kubectl -n c9s-vlan exec ${CL2_POD} -- bridge fdb show dev vx-client2-eth1
#   00:00:00:00:00:00 dst <ClusterIP> ... permanent   ← 正常（デフォルト）
#   aa:c1:ab:00:00:01 dst 192.168.30.61 self          ← 誤学習（ノード IP）
```

### 修復手順（FDB フラッシュ + `nolearning`、単一 `sh -c`）

```bash
# [controller]
for NODE in srl1 srl2 client1 client2; do
  POD=$(kubectl -n c9s-vlan get pods | grep ^${NODE} | awk '{print $1}')
  [ -n "${POD}" ] || continue
  kubectl -n c9s-vlan exec ${POD} -- sh -c '
    for IFACE in $(ip -o link show 2>/dev/null | grep -oE "vx-[^:@ ]+" | sort -u); do
      # permanent 以外（学習済みノード IP エントリ）を削除
      bridge fdb show dev "$IFACE" 2>/dev/null \
        | grep -v permanent | grep -v "^$" | awk "{print \$1}" \
        | xargs -r -I{} bridge fdb del {} dev "$IFACE" 2>/dev/null || true
      # 新規学習を無効化（点対点構成ではデフォルト FDB エントリのみで足りる）
      ip link set "$IFACE" type vxlan nolearning 2>/dev/null || true
      echo "'"${NODE}"'/$IFACE: flushed and nolearning set"
    done
  ' 2>/dev/null || true
done
```

### 検証

```bash
# [controller]
CL2_POD=$(kubectl -n c9s-vlan get pods | grep ^client2 | awk '{print $1}')
kubectl -n c9s-vlan exec ${CL2_POD} -- bridge fdb show dev vx-client2-eth1
# => permanent エントリ（ClusterIP）のみ残ることを確認

CL1_POD=$(kubectl -n c9s-vlan get pods | grep ^client1 | awk '{print $1}')
kubectl -n c9s-vlan exec ${CL1_POD} -- docker exec client1 ping -c 5 10.1.0.2
# => 0% packet loss
# 仕上げに §2 の大パケット試験 (-s 1400 -M do) も実施すると MTU 起因の取りこぼしを排除できる
```

### `nolearning` の意味と影響

- **メリット**: kube-proxy SNAT による誤学習が起きない（常にデフォルト FDB = ClusterIP 経由）
- **デメリット**: 静的エントリが無いユニキャストはフラッディングされる
  → clabernetes のように「相手が常に 1 つの ClusterIP の先にいる」点対点構成では実害なし

### 恒久対策

launcher が VXLAN 作成時に `nolearning` を付与するのが根本解決。v0.5.0 では未付与のため、vxlan 維持なら
再デプロイ・pod 再起動のたびに本手順が必要。やはり §1 の slurpeeth 化が運用上は最も楽。

---

## 5. 切り分けクイックリファレンス

| 確認したいこと | コマンド / 観点 |
|---|---|
| 欠落トンネルの自動検出 | §3 の検出ループ（tc redirect 先が実在しない `vx-*` を抽出） |
| VXLAN インターフェース有無 | `ip link show \| grep vx-` で全 pod を比較 |
| tc redirect ルール | `tc filter show dev <iface> ingress` |
| launcher の "Deleting" ログ | `kubectl logs <pod> \| grep Delet` |
| Connectivity CR の定義 | `kubectl -n c9s-vlan get connectivity vlan -o yaml` |
| VXLAN RX カウンタ | `ip -s link show vx-*`（受信ゼロのトンネルを特定） |
| outer src / VNI の確認 | `tcpdump -n -XX -i eth0 udp port 14789`（offset 42〜49 を読む） |
| FDB の誤学習 | `bridge fdb show dev <vxlan-iface>`（ノード IP エントリの有無） |
| MTU 起因の取りこぼし | `ping -s 1400 -M do <dst>`（DF 付き大パケット） |

---

## 6. まとめ

| # | 問題 | 発見トリガー | 根本原因 | 推奨対処 | フォールバック |
|---|---|---|---|---|---|
| — | （両問題の共通根） | — | VXLAN を ClusterIP 経由で張る構成 | **`connectivity: slurpeeth`** | 下記の手動修復 |
| A | `vx-*` が欠落 | `ip link`/tc 参照先の比較 | v0.5.0 launcher が作成直後に削除 | slurpeeth 化 | VXLAN IF 手動再作成 + tc（§3） |
| B | ユニキャスト不達 | `bridge fdb` にノード IP | kube-proxy SNAT による FDB 誤学習 | slurpeeth 化 | FDB flush + `nolearning`（§4） |

> 手動修復（A・B）は **A → B の順**で実施し、**pod 再起動のたびに失われる**点に留意する。
> 恒久運用では slurpeeth 化、または修復を再適用する仕組み（検出ループ＋修復を定期実行する Job 等）を検討する。
