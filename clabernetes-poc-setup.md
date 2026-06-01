# Clabernetes PoC セットアップ手順書

> kubeadm 実機3ノード構成 + Calico + MetalLB + Private Registry 版
> 公式 Quickstart (`kind` ベース) を実機クラスタ向けに書き換えたもの

---

## このドキュメントの使い方（Claude Code 向け）

あなたは **実行制御ホスト 192.168.30.50 上で動作する Claude Code エージェント**です。controller / worker は手元には無く、すべて **SSH 経由 (user: `admin` / pass: `password`)** で操作します。本書を上から順に実行してください。

**接続先:**
| 役割 | ホスト | SSH 接続 |
|------|--------|---------|
| 制御ホスト（あなた） | 192.168.30.50 | — (ローカル) |
| controller | 192.168.30.60 | `ssh admin@192.168.30.60` |
| worker1 | 192.168.30.61 | `ssh admin@192.168.30.61` |
| worker2 | 192.168.30.62 | `ssh admin@192.168.30.62` |

**実行ルール:**
- 各コマンドブロックの先頭にある `[ ... ]` は **実行対象ノード** を示します。あなたはローカル (192.168.30.50) からは実行せず、必ず対象ノードへ SSH してそのノード上で実行すること。
  - `[ALL]` … controller / worker1 / worker2 すべてで実行
  - `[controller]` … controller (192.168.30.60) のみ
  - `[workers]` … worker1 / worker2 のみ
- **最初に Phase 0 で SSH 鍵を配布**し、以降の自動実行をパスワードレスにすること（パスワード対話を避ける）。
- 各 Phase 末尾の **検証** を必ず実行し、期待出力と一致するか確認してから次へ進む。
- **エラーが出たら作業を止め、エラー全文と直前のコマンドを報告**してから判断を仰ぐこと。
- `sudo` 前提。破壊的操作（`kubeadm reset` 等）の前は必ず確認を取ること。
- `kubectl` / `helm` / `clabverter` は `[controller]` 上で実行する（controller に kubeconfig がある）。

**SSH 越しの sudo について:**
- SSH 非インタラクティブ環境では `sudo` にターミナルが必要なため、`echo 'password' | sudo -S <command>` の形式を使うこと。
- `sudo tee` へのヒアドキュメントパイプは動作しない場合がある。**ファイル書き込みは `/tmp` に作成してから `sudo mv` する**方法が確実:
  ```bash
  printf 'line1\nline2\n' > /tmp/myfile.conf
  echo 'password' | sudo -S mv /tmp/myfile.conf /etc/target/myfile.conf
  ```
- `gpg --dearmor` は非インタラクティブ環境で `/dev/tty` を開こうとして失敗する。**`--batch --yes` フラグを付け、鍵はいったん `/tmp` に保存してからパイプせずにファイルとして渡す**こと:
  ```bash
  curl -fsSL <URL> -o /tmp/release.key
  echo 'password' | sudo -S gpg --batch --yes --dearmor -o /etc/apt/keyrings/xxx.gpg /tmp/release.key
  ```

---

## 0. 環境情報

| 項目 | 値 |
|------|-----|
| Hypervisor | VMware Workstation Pro 26H1 |
| 制御ホスト (Claude Code) | 192.168.30.50 / SSH クライアント |
| controller | 192.168.30.60 / Ubuntu 24.04 LTS |
| worker1 | 192.168.30.61 / Ubuntu 24.04 LTS |
| worker2 | 192.168.30.62 / Ubuntu 24.04 LTS |
| 認証 | user: `admin` / pass: `password` |
| Kubernetes | v1.36.1 (stable) |
| CNI | Calico (latest) |
| LoadBalancer | MetalLB (latest, L2 mode) |
| Container Runtime | containerd v2.3.1 |
| Clabernetes / clabverter | v0.5.0 |

### ネットワーク設計（重要・先に確認）

| 用途 | CIDR / レンジ | 備考 |
|------|--------------|------|
| ノード管理 / L2 | 192.168.30.0/24 | 既存 |
| Pod CIDR | `10.244.0.0/16` | **Calico デフォルトの 192.168.0.0/16 は管理網と衝突するため変更** |
| Service CIDR | `10.96.0.0/12` | k8s デフォルト |
| MetalLB プール | `192.168.30.200-192.168.30.250` | **管理網内の未使用レンジ**（外部から ARP で到達させるため必須） |

> ⚠️ MetalLB プールが他機器の固定IP / DHCP レンジと重複しないことを事前確認すること。重複する場合はレンジを調整。

---

## Phase 0. SSH 準備（制御ホスト 192.168.30.50 で実行）

以降のコマンドを SSH 経由でパスワード対話なしに流せるよう、鍵認証をセットアップする。

```bash
# [制御ホスト 192.168.30.50]
# sshpass が無ければ導入（鍵配布の初回パスワード入力を自動化するため）
sudo apt-get update && sudo apt-get install -y sshpass openssh-client

# 鍵が無ければ生成
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

# 3 ノードへ公開鍵を配布
for IP in 192.168.30.60 192.168.30.61 192.168.30.62; do
  sshpass -p 'password' ssh-copy-id -o StrictHostKeyChecking=no admin@${IP}
done
```

以降、各ノードへは次の形で実行する（例: controller で `kubectl get nodes`）:

```bash
# [制御ホスト]
# パターン: ssh admin@<IP> '<コマンド>'
ssh admin@192.168.30.60 'kubectl get nodes'

# sudo を伴う場合（パスワードを stdin で渡す）
ssh admin@192.168.30.60 "echo 'password' | sudo -S <command>"
```

> ℹ️ ヒアドキュメント（`cat <<EOF | sudo tee ...`）を SSH 越しに流す場合は、ローカルでファイルを作成して `scp` で転送 → リモートで配置、の方が確実な場合がある。状況に応じて使い分けること。

### ✅ Phase 0 検証

```bash
# [制御ホスト]
for IP in 192.168.30.60 192.168.30.61 192.168.30.62; do
  echo "== ${IP} =="; ssh admin@${IP} 'hostname && whoami'
done
# => 各ノードのホスト名と admin がパスワード入力なしで返ること
```

---

## Phase 1. 全ノード共通の OS / ランタイム準備

### 1-1. カーネルモジュールと sysctl

```bash
# [ALL]
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
vxlan
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
sudo modprobe vxlan   # Clabernetes の datapath stitching (VXLAN tunnel) に必須

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

### 1-2. swap 無効化

```bash
# [ALL]
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
```

### 1-3. containerd v2.3.1 インストール（バイナリ）

> apt の `containerd.io` ではバージョン固定が難しいため、公式バイナリで v2.3.1 を導入する。

```bash
# [ALL]
cd /tmp

# containerd v2.3.1
curl -fsSLO https://github.com/containerd/containerd/releases/download/v2.3.1/containerd-2.3.1-linux-amd64.tar.gz
echo 'password' | sudo -S tar Cxzvf /usr/local containerd-2.3.1-linux-amd64.tar.gz

# systemd unit
echo 'password' | sudo -S curl -fsSL -o /etc/systemd/system/containerd.service \
  https://raw.githubusercontent.com/containerd/containerd/main/containerd.service

# runc (latest)
RUNC_VER=$(curl -s https://api.github.com/repos/opencontainers/runc/releases/latest | jq -r .tag_name)
curl -fsSLO https://github.com/opencontainers/runc/releases/download/${RUNC_VER}/runc.amd64
echo 'password' | sudo -S install -m 755 runc.amd64 /usr/local/sbin/runc

# CNI plugins (latest)
CNI_VER=$(curl -s https://api.github.com/repos/containernetworking/plugins/releases/latest | jq -r .tag_name)
echo 'password' | sudo -S mkdir -p /opt/cni/bin
curl -fsSLO https://github.com/containernetworking/plugins/releases/download/${CNI_VER}/cni-plugins-linux-amd64-${CNI_VER}.tgz
echo 'password' | sudo -S tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-${CNI_VER}.tgz
```

> `jq` が無ければ先に `echo 'password' | sudo -S apt-get update && echo 'password' | sudo -S apt-get install -y jq` を実行。

### 1-4. containerd 設定（SystemdCgroup）

```bash
# [ALL]
echo 'password' | sudo -S mkdir -p /etc/containerd

# config を /tmp に生成してから sudo mv する（sudo tee へのパイプは不安定）
containerd config default > /tmp/containerd-config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /tmp/containerd-config.toml
echo 'password' | sudo -S mv /tmp/containerd-config.toml /etc/containerd/config.toml

echo 'password' | sudo -S systemctl daemon-reload
echo 'password' | sudo -S systemctl enable --now containerd
# 設定変更後は必ず restart して shim を正常状態にすること（後述の注意事項参照）
echo 'password' | sudo -S systemctl restart containerd
```

> ⚠️ **containerd の TTRPC shim 問題（実機検証で発生）**
> containerd をバイナリインストール直後や設定変更後に `systemctl start` しただけでは、
> shim の TTRPC 接続が失敗して Pod が一切起動しない場合がある（`failed to create TTRPC connection` エラー）。
> `systemctl restart containerd` を必ず実行すること。
> kubeadm init 後に同症状が出た場合は `kubeadm reset -f` → `systemctl restart containerd` → 再度 `kubeadm init` の順で対処する。

> ℹ️ ラボのイメージ（SR Linux / alpine 等）は公開レジストリ `ghcr.io` から直接 pull する。Clabernetes の launcher Pod が各 worker 上で pull するため、全ノードがインターネットへ到達できることを確認しておくこと。

### 1-5. kubeadm / kubelet / kubectl v1.36 インストール

```bash
# [ALL]
echo 'password' | sudo -S apt-get update -q
echo 'password' | sudo -S apt-get install -y apt-transport-https ca-certificates curl gpg

echo 'password' | sudo -S mkdir -p /etc/apt/keyrings

# gpg は非インタラクティブ環境で /dev/tty を開こうとするため、
# --batch --yes を付けてファイル経由で処理する
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
  -o /tmp/k8s-release.key
echo 'password' | sudo -S gpg --batch --yes \
  --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s-release.key
rm /tmp/k8s-release.key

printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /\n' \
  > /tmp/kubernetes.list
echo 'password' | sudo -S mv /tmp/kubernetes.list /etc/apt/sources.list.d/kubernetes.list

echo 'password' | sudo -S apt-get update -q

# すでに別バージョンが hold されている場合は unhold してから install する
echo 'password' | sudo -S apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
echo 'password' | sudo -S apt-get install -y \
  --allow-change-held-packages \
  kubelet=1.36.1-* kubeadm=1.36.1-* kubectl=1.36.1-*
echo 'password' | sudo -S apt-mark hold kubelet kubeadm kubectl
echo 'password' | sudo -S systemctl enable --now kubelet
```

> ℹ️ Ubuntu 24.04 LTS の場合、docker.io パッケージ経由で kubelet/kubeadm が v1.29 系で `hold` 済みのことがある。
> `apt-mark unhold` → `apt-get install --allow-change-held-packages` の順で上書きインストールすること。

### ✅ Phase 1 検証

```bash
# [ALL]
containerd --version            # => containerd github.com/containerd/containerd/v2 v2.3.1 ...
runc --version                  # => runc version 1.x.x
kubeadm version -o short        # => v1.36.1
systemctl is-active containerd  # => active
```

---

## Phase 2. クラスタ初期化（controller）

### 2-1. kubeadm init

```bash
# [controller]
echo 'password' | sudo -S kubeadm init \
  --kubernetes-version=v1.36.1 \
  --apiserver-advertise-address=192.168.30.60 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --cri-socket=unix:///run/containerd/containerd.sock
```

> 成功すると末尾に `kubeadm join 192.168.30.60:6443 --token ... --discovery-token-ca-cert-hash sha256:...` が出力される。**この join コマンドを控えること**（Phase 3 で使用）。

> ⚠️ **init が `failed to create TTRPC connection` で失敗した場合:**
> containerd shim の起動直後に発生する既知の一時的な問題。以下の手順でリカバリする:
> ```bash
> # [controller]
> echo 'password' | sudo -S kubeadm reset -f
> echo 'password' | sudo -S systemctl restart containerd
> # 少し待ってから再実行
> echo 'password' | sudo -S kubeadm init \
>   --kubernetes-version=v1.36.1 \
>   --apiserver-advertise-address=192.168.30.60 \
>   --pod-network-cidr=10.244.0.0/16 \
>   --service-cidr=10.96.0.0/12 \
>   --cri-socket=unix:///run/containerd/containerd.sock
> ```

### 2-2. kubeconfig 配置

```bash
# [controller]
mkdir -p $HOME/.kube
echo 'password' | sudo -S cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
echo 'password' | sudo -S chown $(id -u):$(id -g) $HOME/.kube/config
```

### ✅ Phase 2 検証

```bash
# [controller]
kubectl get nodes
# => controller   NotReady   control-plane   ...   v1.36.1
#    （CNI 未導入のため NotReady で正常）
```

---

## Phase 3. Worker 参加

### 3-1. join 実行

Phase 2-1 で控えた join コマンドを各 worker で実行:

```bash
# [workers]  ※ 実際のトークン / ハッシュに置換
echo 'password' | sudo -S kubeadm join 192.168.30.60:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --cri-socket=unix:///run/containerd/containerd.sock
```

> トークンを紛失した場合は controller で再生成:
> `kubeadm token create --print-join-command`

### ✅ Phase 3 検証

```bash
# [controller]
kubectl get nodes
# => controller / worker1 / worker2 が表示される（まだ全て NotReady で正常）
```

> ⚠️ **worker で ContainerCreating が長時間続く場合:**
> Phase 4 以降で worker 上の Pod が ContainerCreating から進まず、
> kubelet ログに `failed to create TTRPC connection` が出る場合は、
> 該当 worker で containerd を再起動すること:
> ```bash
> # [workers] — 問題が出た worker で実行
> echo 'password' | sudo -S systemctl restart containerd
> ```

---

## Phase 4. CNI: Calico

> Pod CIDR を `10.244.0.0/16` に変更しているため、Tigera Operator + カスタム Installation CR で導入する。

```bash
# [controller]
CALICO_VER=$(curl -s https://api.github.com/repos/projectcalico/calico/releases/latest | jq -r .tag_name)
echo "Calico version: ${CALICO_VER}"

# Operator + CRD
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/tigera-operator.yaml
```

Tigera Operator Pod が Running になったら、**worker の containerd を事前に再起動**してから Installation CR を適用する（TTRPC shim 問題の予防的対処）:

```bash
# [制御ホスト] — Tigera Operator が Running になった後、Installation CR 適用前に実行
# 制御ホストから SSH で各 worker の containerd を再起動する（TTRPC shim 問題の予防的対処）
for IP in 192.168.30.61 192.168.30.62; do
  ssh admin@${IP} "echo 'password' | sudo -S systemctl restart containerd" &
done
wait
```

カスタム Installation（Pod CIDR を明示）:

```bash
# [controller]
kubectl wait --for=condition=established \
  crd installations.operator.tigera.io --timeout=60s

kubectl create -f - <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.244.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
```

### ✅ Phase 4 検証

```bash
# [controller]
watch kubectl get pods -n calico-system   # 全て Running になるまで待機（数分）
kubectl get nodes                          # => 全ノード Ready
```

---

## Phase 5. LoadBalancer: MetalLB (L2 mode)

```bash
# [controller]
METALLB_VER=$(curl -s https://api.github.com/repos/metallb/metallb/releases/latest | jq -r .tag_name)
echo "MetalLB version: ${METALLB_VER}"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VER}/config/manifests/metallb-native.yaml

# controller Pod が立ち上がるまで待機
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s
```

IPAddressPool + L2Advertisement（**管理網内レンジ**）:

```bash
# [controller]
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.30.200-192.168.30.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - lab-pool
EOF
```

### ✅ Phase 5 検証

```bash
# [controller]
kubectl get pods -n metallb-system          # controller + speaker (各ノード) が Running
kubectl get ipaddresspool -n metallb-system # lab-pool が表示される
```

---

## Phase 6. Clabernetes v0.5.0 インストール

### 6-1. Helm 準備

```bash
# [controller]
# helm をネイティブ導入する（インストールスクリプトは sudo が必要なため手動インストール）
cd /tmp
HELM_VER=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)
curl -fsSLO https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz
tar xzvf helm-${HELM_VER}-linux-amd64.tar.gz linux-amd64/helm
echo 'password' | sudo -S mv linux-amd64/helm /usr/local/bin/helm
helm version --short
```

> ℹ️ `curl ... | bash` 形式のインストールスクリプトは内部で `sudo` を呼ぶため非インタラクティブ環境では失敗する。
> tarball を手動ダウンロード → `sudo mv` の手順を使うこと。

### 6-2. Clabernetes manager 導入（v0.5.0 固定）

```bash
# [controller]
helm upgrade --install --create-namespace --namespace c9s \
    --version 0.5.0 \
    clabernetes oci://ghcr.io/srl-labs/clabernetes/clabernetes
```

### ✅ Phase 6 検証

```bash
# [controller]
kubectl get -n c9s pods -o wide
# => clabernetes-manager の Pod が 3 つ Running（リーダー選出まで一部 Init の場合あり）
```

---

## Phase 7. ラボのデプロイと Datapath Stitching

公式 Quickstart と同じ **SR Linux VLAN handling lab**（srl1/srl2 + client1/client2）をデプロイし、異なる worker に分散配置された SR Linux 間が VXLAN tunnel で stitching されることを確認する。

### 7-1. clabverter エイリアス（v0.5.0 固定）

```bash
# [controller]
# admin ユーザーは docker グループに所属しているため sudo 不要
alias clabverter='docker run --user $(id -u) \
    -v $(pwd):/clabernetes/work --rm \
    ghcr.io/srl-labs/clabernetes/clabverter:0.5.0'
```

> ⚠️ `clabverter` は **docker を必要とする**。controller に docker が無い場合は、docker を導入できる制御ホスト (192.168.30.50) 等でラボを clone → `clabverter --stdout > manifests.yml` で生成 → controller へ `scp` 転送 → controller 上で `kubectl apply -f manifests.yml` の流れに切り替えること。以降の手順は controller に docker がある前提で記載。
>
> ℹ️ controller の `admin` ユーザーが `docker` グループに属していれば `sudo` は不要。`id` コマンドで確認すること。

### 7-2. ラボ取得

```bash
# [controller]
git clone --depth 1 https://github.com/srl-labs/srlinux-vlan-handling-lab.git
cd srlinux-vlan-handling-lab
```

> ラボ内の `*.clab.yml` が参照するイメージ（SR Linux / alpine）は `ghcr.io` の公開イメージをそのまま使用する。書き換え不要。

### 7-3. clabverter で変換 → 適用

```bash
# [controller]  ※ ラボディレクトリ内で実行
# clabverter の INFO ログは stderr に出るため 2>/dev/null でフィルタすると kubectl へ渡す YAML が安全
clabverter --stdout --naming non-prefixed 2>/dev/null | kubectl apply -f -
```

> 中身を確認したい場合: `clabverter --stdout --naming non-prefixed > manifests.yml` で生成物を inspect 可能。
>
> ℹ️ `2>/dev/null` を付けないと clabverter の INFO ログが YAML に混入し `kubectl apply` が失敗する。

### 7-4. デプロイ確認

```bash
# [controller]
kubectl get ns                                  # => c9s-vlan が作成される
kubectl get --namespace c9s-vlan Topology       # => vlan / containerlab
kubectl -n c9s-vlan get deployments             # => client1 client2 srl1 srl2 (各 1/1)
kubectl get pods -n c9s-vlan -o wide            # => 4 Pod Running（worker に分散）
```

> Pod が `Running` でも内部の containerlab がイメージ pull 中の場合あり。
> `kubectl -n c9s-vlan exec -it <srl1-pod> -- tail -f containerlab.log` で進捗確認可。

### 7-4b. ★【既知バグ】vx-srl2-e1-10 の手動修復（v0.5.0 必須対応）

clabernetes v0.5.0 の launcher バグにより、**srl2 pod の `vx-srl2-e1-10` インターフェース（srl1↔srl2 の VXLAN トンネル）が作成直後に削除される**。
全 Pod が Running になった後、以下の修復手順を必ず実行すること。

```bash
# [controller]
SRL2_POD=$(kubectl -n c9s-vlan get pods | grep ^srl2 | awk '{print $1}')
SRL1_VX_IP=$(kubectl -n c9s-vlan get svc srl1-vx -o jsonpath='{.spec.clusterIP}')
echo "srl2 pod: ${SRL2_POD}, srl1-vx ClusterIP: ${SRL1_VX_IP}"

# 欠落確認
kubectl -n c9s-vlan exec ${SRL2_POD} -- ip link show vx-srl2-e1-10 2>&1 \
  && echo "EXISTS (no repair needed)" || echo "MISSING - starting repair"

# ⚠️ 全操作を単一 sh -c に集約すること。
# launcher の reconciliation ループが稼働中のため、kubectl exec を複数回に
# 分けると vx-srl2-e1-10 が削除されてしまい "Cannot find device" エラーになる。
kubectl -n c9s-vlan exec ${SRL2_POD} -- sh -c "
  # 既存インターフェースをクリーンアップして再作成
  ip link del vx-srl2-e1-10 2>/dev/null || true
  ip link add vx-srl2-e1-10 type vxlan id 3 \
    remote ${SRL1_VX_IP} dev eth0 dstport 14789
  ip link set vx-srl2-e1-10 up

  # srl2-e1-10 の tc を完全リセット
  # （launcher が ingress qdisc なしの状態で終了しているため add が必要）
  tc filter del dev srl2-e1-10 ingress 2>/dev/null || true
  tc qdisc del dev srl2-e1-10 ingress 2>/dev/null || true
  tc qdisc add dev srl2-e1-10 ingress

  # vx-srl2-e1-10 の ingress qdisc（既存なら無視）
  tc qdisc add dev vx-srl2-e1-10 ingress 2>/dev/null || true

  # tc redirect ルール設定
  tc filter add dev srl2-e1-10 ingress protocol all u32 match u8 0 0 \
    action mirred egress redirect dev vx-srl2-e1-10
  tc filter add dev vx-srl2-e1-10 ingress protocol all u32 match u8 0 0 \
    action mirred egress redirect dev srl2-e1-10

  echo DONE
  ip link show vx-srl2-e1-10 | head -1
"

echo "srl2 vx-srl2-e1-10 repair done"
```

> 詳細な発見手順・根本原因・恒久対策は `troubleshooting-vxlan-stitching.md` の「問題 1」を参照。

### 7-4c. ★【既知問題】VXLAN FDB 誤学習の修正（v0.5.0 必須対応）

kube-proxy の SNAT により、VXLAN インターフェースがノード IP を VTEP として誤学習する。
この状態ではユニキャスト（ARP Reply / ICMP 等）が消失し、**LLDP は通るが ping が通らない**症状になる。
7-4b の修復後、または SR Linux コンテナが起動してから約 30 秒以上経過した時点で以下を実行すること。

```bash
# [controller]
for NODE in srl1 srl2 client1 client2; do
  POD=$(kubectl -n c9s-vlan get pods | grep ^${NODE} | awk '{print $1}')
  VXLAN_IFACES=$(kubectl -n c9s-vlan exec ${POD} -- ip link show 2>/dev/null \
    | grep '^[0-9].*vx-' | cut -d: -f2 | tr -d ' ')
  for IFACE in ${VXLAN_IFACES}; do
    # permanent エントリ以外（学習済みノード IP エントリ）を削除
    kubectl -n c9s-vlan exec ${POD} -- sh -c \
      "bridge fdb show dev ${IFACE} \
       | grep -v permanent | grep -v '^\$' \
       | awk '{print \$1}' \
       | xargs -I{} bridge fdb del {} dev ${IFACE}" 2>/dev/null || true
    # 再学習を無効化
    kubectl -n c9s-vlan exec ${POD} -- \
      ip link set ${IFACE} type vxlan nolearning 2>/dev/null || true
    echo "${NODE}/${IFACE}: flushed and nolearning set"
  done
done
```

> 詳細な発見手順・根本原因・恒久対策は `troubleshooting-vxlan-stitching.md` の「問題 2」を参照。

### 7-5. ★ Datapath Stitching 動作確認（7-4b・7-4c の修復後に実行）

**(a) LLDP ネイバー確認**（srl1 ↔ srl2 が VXLAN tunnel 経由で隣接しているか）:

```bash
# [controller]
NS=c9s-vlan POD=srl1; \
kubectl -n $NS exec -it \
  $(kubectl -n $NS get pods | grep ^$POD | awk '{print $1}') -- \
    docker exec $POD sr_cli show system lldp neighbor
```

> 期待: `ethernet-1/10` に Neighbor System Name = `srl2` が表示される。

**(b) エンドツーエンド疎通**（client1 → client2、VLAN/stitching が機能しているか）:

```bash
# [controller]
NS=c9s-vlan POD=client1; \
kubectl -n $NS exec -it \
  $(kubectl -n $NS get pods | grep ^$POD | awk '{print $1}') -- \
    docker exec -it $POD ping -c 3 10.1.0.2
```

> 期待: `0% packet loss`。これが通れば **datapath stitching 成功**。

**(c) LoadBalancer 経由の外部アクセス確認**（MetalLB 動作確認）:

```bash
# [controller]
kubectl get -n c9s-vlan svc | grep -iv vx
# => srl1 / srl2 / client1 / client2 に EXTERNAL-IP (192.168.30.200番台) が付与される

# 付与された srl1 の IP へ SSH（外部端末から）
# ssh admin@192.168.30.2xx   (pass: NokiaSrl1!)
```

---

## Phase 8. クリーンアップ

```bash
# ラボのみ削除
# [controller]
kubectl delete ns c9s-vlan

# Clabernetes manager 削除
helm uninstall clabernetes -n c9s

# クラスタ全削除（リセット）
# [ALL]  ※ 破壊的: 実行前に必ず確認
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d $HOME/.kube
```

---

## トラブルシュート早見表

| 症状 | 確認ポイント |
|------|------------|
| ノードが `NotReady` のまま | Calico Pod 状態 (`kubectl get pods -n calico-system`)、`journalctl -u kubelet` |
| Pod が `ImagePullBackOff` | 各ノードのインターネット到達性、`ghcr.io` への名前解決・疎通、イメージタグの存在確認 |
| LoadBalancer EXTERNAL-IP が `<pending>` | MetalLB speaker 稼働、IPAddressPool レンジ、L2 到達性 |
| LLDP ネイバー出ない / ping 不通 | 各ノードで `vxlan` モジュール、VXLAN サービス (`kubectl get svc -n c9s-vlan \| grep vx`)、MTU（VXLAN オーバーヘッド 50B） |
| `SystemdCgroup` 不一致エラー | containerd config.toml の `SystemdCgroup = true`、`systemctl restart containerd` |
| Pod が `ContainerCreating` のまま（TTRPC エラー）| `kubectl describe pod` で `failed to create TTRPC connection` を確認 → 該当ノードで `systemctl restart containerd` |
| LLDP は通るが ping が通らない | VXLAN FDB の誤学習（`bridge fdb show dev vx-*` でノード IP エントリを確認）→ 7-4c の FDB フラッシュ手順を実施 |
| srl1 ↔ srl2 が LLDP ネイバーにならない | srl2 pod に `vx-srl2-e1-10` が存在するか確認（`ip link show \| grep vx-`）→ 存在しなければ 7-4b の修復手順を実施 |
| 7-4b で "Cannot find device vx-srl2-e1-10" | launcher の reconciliation が修復中にインターフェースを再削除している → 全操作を単一 `sh -c` exec にまとめて実行すること |
| 7-4b で `tc qdisc add dev srl2-e1-10` がエラー | `srl2-e1-10` に ingress qdisc がない（launcher が残した状態）→ `tc qdisc add dev srl2-e1-10 ingress` を実行してから `tc filter add` すること |
| `kubeadm init` が `rate: Wait(n=1) would exceed context deadline` で失敗 | containerd shim の初期化問題 → `kubeadm reset -f` → `systemctl restart containerd` → 再度 `kubeadm init` |

---

## 補足: 公式 Quickstart との主な差分

1. **クラスタ作成**: `kind` → `kubeadm`（実機3ノード）
2. **CNI**: kind 同梱 → Calico（Pod CIDR を管理網と非衝突の `10.244.0.0/16` に変更）
3. **LoadBalancer**: kube-vip → MetalLB（L2 mode、プールは管理網内）
4. それ以降（Clabernetes / clabverter / datapath stitching）は公式 Quickstart と同一フロー（イメージは `ghcr.io` の公開イメージを直接使用）

---

## 補足: 実機検証で判明した clabernetes v0.5.0 の既知問題

実機 3 ノード（kubeadm + Calico + MetalLB）構成で検証した結果、以下の 2 点が v0.5.0 固有の問題として確認された。
詳細な調査記録は [`troubleshooting-vxlan-stitching.md`](./troubleshooting-vxlan-stitching.md) を参照。

### 問題 A: `vx-srl2-e1-10` の即時削除バグ

- **現象**: srl2 の launcher Pod が `vx-srl2-e1-10`（srl1↔srl2 間の VXLAN インターフェース）を作成した直後に自ら削除する。結果として srl1↔srl2 の LLDP ネイバーが確立しない。
- **対処**: 7-4b の手動修復手順（インターフェース再作成 + tc ルール設定）を毎回のラボデプロイ後に実施する。
- **対象バージョン**: v0.5.0 で確認。上位バージョンでの修正状況は要確認。

### 問題 B: kube-proxy SNAT による VXLAN FDB 誤学習

- **現象**: kube-proxy が VXLAN の outer パケット送信元 IP をノード IP に SNAT するため、受信側の VXLAN インターフェースがノード IP を VTEP として FDB に学習する。以降のユニキャスト（ARP Reply・ICMP）がノード IP 宛に直送されて kube-proxy を迂回し消失する。LLDP（マルチキャスト）は FDB のデフォルトエントリを使うため影響を受けず通る。
- **対処**: 7-4c の FDB フラッシュ + `nolearning` 設定を毎回のラボデプロイ後に実施する。
- **根本原因**: VXLAN 作成時に `nolearning` オプションが付与されていないこと。上位バージョンでの修正状況は要確認。
