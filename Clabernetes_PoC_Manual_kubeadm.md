# Clabernetes PoC セットアップマニュアル (kubeadm 版)

**VMware Workstation 25H2 / Ubuntu 24.04 LTS / kubeadm / Clabernetes v0.4.1**
Version 1.4

---

## 1. 環境定義

### ノード構成

| 役割 | ホスト名 | IP アドレス | vCPU | メモリ | ディスク |
|---|---|---|---|---|---|
| Control Plane | k8s-cp | 192.168.30.60 | 4 | 8 GB | 40 GB |
| Worker Node 1 | k8s-w1 | 192.168.30.61 | 4 | 8 GB | 60 GB |
| Worker Node 2 | k8s-w2 | 192.168.30.62 | 4 | 8 GB | 60 GB |

### ネットワーク設定

| 項目 | 値 |
|---|---|
| セグメント | 192.168.30.0/24 |
| Gateway | 192.168.30.1 |
| DNS | 192.168.30.1 |
| kube-vip IP range | 192.168.30.200 〜 192.168.30.220 |
| VMware NIC 種別 | ブリッジ接続 (物理 LAN 直結) |
| OS | Ubuntu 24.04 LTS |
| Kubernetes | v1.29.x |
| CNI | kindnet |
| LoadBalancer | kube-vip |

### バージョン情報

| コンポーネント | バージョン | 備考 |
|---|---|---|
| Clabernetes | **v0.4.1** | v0.5.0 は tc 実装に問題あり (後述) |
| containerd | **v1.7.x** | v2.x は clabernetes-puller が動作しない |
| Kubernetes | v1.29.x | |
| CNI | kindnet | Flannel は VXLAN MASQUERADE 問題あり (後述) |

---

## 2. 追加サーバの要否

| コンポーネント | 必要性 | 備考 |
|---|---|---|
| DNS / GW | 済 (192.168.30.1) | 既存ルーターで兼用 |
| NTP | 必須 | systemd-timesyncd で外部 NTP を使用 |
| Private Registry | 推奨 | 外部アクセス可能なら ghcr.io 直接でも可 |
| Bastion VM | 不要 | Windows ホストからブリッジ経由で直接アクセス可 |
| Monitoring | 任意 | PoC 範囲外 |

---

## 3. 既知の問題と制約

> ⚠ **本マニュアルを実施する前に必ず確認してください。**

### 3.1 clabernetes v0.5.0 の問題

v0.5.0 では VXLAN ステッチングの実装が tc ミラーリング方式に変わっており、以下の問題が発生します。

- `vx-srl2-e1-10` 等の inter-switch リンク用 VXLAN が自動作成されない
- `srl2-e1-10` の tc フィルターに無効なデバイス (`*`) が混入する
- Connectivity CR の ADDED イベントが `ignoring` されて VXLAN 設定がトリガーされない

**本マニュアルでは v0.4.1 を使用します。**

### 3.2 containerd v2.x の問題

containerd v2.x では clabernetes-puller Job が以下のエラーで失敗します。

```
exec: "exit": executable file not found in $PATH
```

**containerd は v1.7.x を使用し、`apt-mark hold` で自動アップグレードを防止します。**

### 3.3 CNI に Flannel を使用できない理由

Flannel 環境では Pod 内からの ClusterIP 宛 VXLAN パケットが MASQUERADE (SNAT) されて物理 NIC から送出されてしまいます。ClusterIP は物理 LAN に存在しないためパケットが消え、VXLAN トンネルが機能しません。

**本マニュアルでは kindnet を使用します。**

### 3.4 手動対処が必要な箇所

ラボデプロイ後に以下の手動対処が必要です (Section 10 で実施)。

- Connectivity CR の手動削除 (VXLAN 設定トリガー)
- `vx-srl2-e1-10` の手動作成 (srl1 / srl2 が別 Worker の場合)
- `srl2-e1-10` の tc フィルター修正

---

## 4. VM 作成 (VMware Workstation)

各 VM に以下の設定を適用します。

- **NIC**: ブリッジ接続 (使用する物理アダプタを選択)
- **プロセッサ**: 「Intel VT-x/EPT または AMD-V/RVI を仮想化」にチェック
- **OS**: Ubuntu 24.04 LTS Server (minimal install)

> Ubuntu 24.04 のインストーラーは cloud-init ベースの Subiquity を使用します。インストール時に静的 IP を設定するか、インストール後に Netplan で設定します。

---

## 5. OS 共通初期設定 (全 3 台 — k8s-cp / k8s-w1 / k8s-w2)

### 5.1 NIC 名の確認

Ubuntu 24.04 では NIC 名が環境により異なります。**以降の手順で使用するため最初に確認してください。**

```bash
ip addr
# ens33 / ens160 / eth0 などが表示される
# 以降の手順では <NIC名> を実際の名前に置き換えること
```

### 5.2 静的 IP 設定 (Netplan)

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

k8s-cp の例。k8s-w1 は `192.168.30.61`、k8s-w2 は `192.168.30.62` に変更します。

```yaml
network:
  version: 2
  ethernets:
    ens33:               # 実際の NIC 名に変更
      addresses:
        - 192.168.30.60/24
      routes:
        - to: default
          via: 192.168.30.1
      nameservers:
        addresses:
          - 192.168.30.1
      dhcp4: false
```

```bash
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan apply
```

疎通確認:

```bash
ping -c 3 192.168.30.1
ping -c 3 8.8.8.8
```

### 5.3 /etc/hosts

```bash
sudo tee -a /etc/hosts <<EOF
192.168.30.60  k8s-cp
192.168.30.61  k8s-w1
192.168.30.62  k8s-w2
EOF
```

### 5.4 パッケージ更新

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl git jq apt-transport-https ca-certificates gnupg
```

### 5.5 swap 無効化

Ubuntu 24.04 はデフォルトで zswap が有効な場合があります。両方無効化します。

```bash
sudo swapoff -a
sudo sed -i 's/^.*swap.*$/#&/' /etc/fstab

# zswap 無効化
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="zswap.enabled=0 /' \
  /etc/default/grub
sudo update-grub
```

確認:

```bash
free -h  # Swap 行が 0B であることを確認
```

### 5.6 カーネルモジュールと sysctl

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 5.7 containerd v1.7.x インストール

Docker 公式リポジトリを追加します。

```bash
sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update
```

利用可能なバージョンを確認してから v1.7.x を指定してインストールします。

```bash
apt-cache madison containerd.io | grep 1.7

# 表示された最新の 1.7.x を指定 (例: 1.7.27-1)
sudo apt-get install -y containerd.io=1.7.27-1
sudo apt-mark hold containerd.io   # v2.x への自動アップグレードを防止
```

バージョン確認:

```bash
containerd --version  # v1.7.x が表示されることを確認
```

containerd の設定:

```bash
sudo containerd config default | sudo tee /etc/containerd/config.toml

# SystemdCgroup を有効化 (Ubuntu 24.04 は cgroup v2 を使用)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

# Clabernetes 必須: DinD がイメージレイヤーを再利用するために必要
sudo sed -i 's/discard_unpacked_layers = true/discard_unpacked_layers = false/' \
  /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

> ⚠ `discard_unpacked_layers = false` は Clabernetes の動作に必須です。設定漏れがあると Pod 内の containerlab がイメージを Pull できません。

設定確認:

```bash
grep -E 'SystemdCgroup|discard_unpacked' /etc/containerd/config.toml
# SystemdCgroup = true
# discard_unpacked_layers = false
# が出力されることを確認
```

### 5.8 kubeadm / kubelet / kubectl インストール

> **対象ノード: k8s-cp / k8s-w1 / k8s-w2 (全 3 台)**

まずリポジトリで利用可能なバージョンを確認してからインストールします。

```bash
KUBE_VERSION=1.29

curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
```

インストール可能なバージョンを確認します。

```bash
apt-cache madison kubeadm | head -5
# 例:
#   kubeadm | 1.29.2-1.1 | https://pkgs.k8s.io/...
#   kubeadm | 1.29.1-1.1 | https://pkgs.k8s.io/...
```

表示されたバージョンを確認してからインストールします。以降の手順では確認したバージョンを `--kubernetes-version` に指定します。

```bash
# 表示された最新バージョンを指定 (例: 1.29.2-1.1)
sudo apt-get install -y kubeadm=1.29.2-1.1 kubelet=1.29.2-1.1 kubectl=1.29.2-1.1
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

バージョン確認:

```bash
kubeadm version
kubectl version --client
```

---

## 6. Kubernetes クラスター構築

> **実施ノードのまとめ**
>
> | セクション | 手順 | k8s-cp | k8s-w1/w2 |
> |---|---|---|---|
> | 6.1 | Control Plane 初期化 | ✅ | ❌ |
> | 6.2 | CNI (kindnet) インストール | ✅ | ❌ |
> | 6.3 | join コマンド確認 | ✅ | ❌ |
> | 6.3 | kubeadm join 実行 | ❌ | ✅ |
> | 6.4 | クラスター確認 | ✅ | ❌ |

### 6.1 Control Plane 初期化 (k8s-cp のみ)

> **対象ノード: k8s-cp のみ**

`--kubernetes-version` には Section 5.8 で確認したバージョンを指定します。

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.30.60 \
  --kubernetes-version=v1.29.2   # Section 5.8 で確認したバージョンに合わせること
```

kubeconfig セットアップ:

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 6.2 CNI インストール (kindnet) — k8s-cp のみ

> **対象ノード: k8s-cp のみ**

> ⚠ Flannel は VXLAN MASQUERADE 問題 (Section 3.3 参照) があるため使用しません。kindnet を使用します。

```bash
kubectl apply -f \
  https://raw.githubusercontent.com/aojea/kindnet/main/install-kindnet.yaml

# kindnet Pod が Running になるまで待機
kubectl get pods -n kube-system | grep kindnet
```

### 6.3 Worker Node の参加 (k8s-w1, k8s-w2)

k8s-cp で join コマンドを確認します:

```bash
kubeadm token create --print-join-command
```

出力されたコマンドを k8s-w1 / k8s-w2 で実行します:

```bash
sudo kubeadm join 192.168.30.60:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

### 6.4 クラスター確認

```bash
kubectl get nodes -o wide
```

期待する出力:

```
NAME     STATUS   ROLES           AGE   VERSION   INTERNAL-IP
k8s-cp   Ready    control-plane   5m    v1.29.2   192.168.30.60
k8s-w1   Ready    <none>          3m    v1.29.2   192.168.30.61
k8s-w2   Ready    <none>          3m    v1.29.2   192.168.30.62
```

全ノードが `Ready` になるまで待機します。

---

## 7. Clabernetes インストール

> **Section 7 の作業は全て k8s-cp のみで実施します。**
>
> | セクション | 手順 | k8s-cp | k8s-w1/w2 |
> |---|---|---|---|
> | 7.1 | Helm インストール | ✅ | ❌ |
> | 7.2 | Clabernetes Manager デプロイ | ✅ | ❌ |
> | 7.3 | Docker インストール | ✅ | ❌ |
> | 7.4 | kube-vip 全手順 | ✅ | ❌ (k8s が自動で Pod を配置) |
> | 7.5 | clabverter セットアップ | ✅ | ❌ |

### 7.1 Helm インストール (k8s-cp)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 7.2 Clabernetes v0.4.1 Manager デプロイ

```bash
helm upgrade --install --create-namespace --namespace c9s \
    clabernetes oci://ghcr.io/srl-labs/clabernetes/clabernetes \
    --version 0.4.1
```

確認:

```bash
kubectl get pods -n c9s -o wide -w
```

期待する出力 (Leader Election 完了後):

```
NAME                                   READY   STATUS    AGE
clabernetes-manager-xxx-aaa            1/1     Running   2m
clabernetes-manager-xxx-bbb            1/1     Running   2m
clabernetes-manager-xxx-ccc            1/1     Running   2m
```

### 7.3 Docker インストール (k8s-cp — kube-vip / clabverter 用)

kube-vip の DaemonSet マニフェスト生成と clabverter はいずれも `docker` コマンドを使用します。Docker 公式リポジトリは Section 5.7 で追加済みのため、パッケージのみ追加インストールします。

```bash
sudo apt-get install -y docker-ce docker-ce-cli
sudo usermod -aG docker $USER
newgrp docker
docker version
```

### 7.4 kube-vip LoadBalancer インストール

> **対象ノード: k8s-cp のみ** (DaemonSet は k8s が Worker へ自動配置)

**目的:** クラスター外部 (Windows ホスト等) からラボノードへ SSH / gNMI / SNMP でアクセスするための LoadBalancer です。kube-vip は物理 LAN 上に仮想 IP (EXTERNAL-IP) を払い出し、ポートマッピング経由で各ラボ Pod に転送します。kube-vip がないと LoadBalancer Service の EXTERNAL-IP が `<pending>` のまま外部からアクセスできません。

#### RBAC とクラウドプロバイダー

```bash
kubectl apply -f https://kube-vip.io/manifests/rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml
```

#### IP range 設定

```bash
kubectl create configmap --namespace kube-system kubevip \
  --from-literal range-global=192.168.30.200-192.168.30.220
```

#### kube-vip DaemonSet デプロイ

```bash
KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | \
  jq -r '.[0].name')

docker run --network host --rm ghcr.io/kube-vip/kube-vip:$KVVERSION \
  manifest daemonset --services --inCluster --arp --interface <NIC名> | \
  kubectl apply -f -
```

> ⚠ `--interface` には Worker Node の実際の NIC 名を指定します。`ip addr` で確認してください (ens33 / ens160 / eth0 等)。

確認:

```bash
kubectl get pods -A | grep kube-vip
# Worker 2台分の DaemonSet Pod が Running であることを確認
```

### 7.5 clabverter セットアップ

> **対象ノード: k8s-cp のみ**

**目的:** clabverter は containerlab の `.clab.yml` トポロジーファイルを Kubernetes マニフェスト (Topology CR / ConfigMap / Deployment) に変換するツールです。Docker コンテナとして提供されており、変換結果を `kubectl apply` にパイプすることでラボをデプロイします。

```bash
alias clabverter='sudo docker run --user $(id -u) \
    -v $(pwd):/clabernetes/work --rm \
    ghcr.io/srl-labs/clabernetes/clabverter'

echo "alias clabverter='sudo docker run --user \$(id -u) \
    -v \$(pwd):/clabernetes/work --rm \
    ghcr.io/srl-labs/clabernetes/clabverter'" >> ~/.bashrc
source ~/.bashrc
```

---

## 8. サンプルラボのデプロイ

### 8.1 ラボ取得

```bash
git clone --depth 1 https://github.com/srl-labs/srlinux-vlan-handling-lab.git
cd srlinux-vlan-handling-lab
```

### 8.2 デプロイ

```bash
clabverter --stdout --naming non-prefixed | kubectl apply -f -
```

### 8.3 状態確認

```bash
# Namespace 確認 (c9s と c9s-vlan が存在すること)
kubectl get ns

# Topology CR 確認
kubectl get topology -n c9s-vlan

# Pod 確認 (全て Ready になるまで待機)
kubectl get pods -n c9s-vlan -o wide -w

# LoadBalancer の EXTERNAL-IP 確認
kubectl get svc -n c9s-vlan | grep -iv vx
```

期待する Service 出力:

```
NAME      TYPE           EXTERNAL-IP        PORT(S)
client1   LoadBalancer   192.168.30.200     22:XXXXX/TCP,...
client2   LoadBalancer   192.168.30.201     22:XXXXX/TCP,...
srl1      LoadBalancer   192.168.30.202     22:XXXXX/TCP,...
srl2      LoadBalancer   192.168.30.203     22:XXXXX/TCP,...
```

> 初回は SR Linux イメージの Pull に数分かかります。`kubectl logs -n c9s-vlan <pod名> 2>&1 | tail -20` で進捗を確認できます。

---

## 9. ラボ起動後の確認と対処

> clabernetes v0.4.1 には既知の問題があり、デプロイ後に手動対処が必要な場合があります。まず正常な状態を確認し、期待する出力と一致しない場合のみ対処手順を実施してください。

### 9.1 変数の設定

> **対象ノード: k8s-cp のみ**

以降の手順で使用する Pod 名を変数に格納します。

```bash
SRL1=$(kubectl -n c9s-vlan get pods | awk '/^srl1/{print $1}')
SRL2=$(kubectl -n c9s-vlan get pods | awk '/^srl2/{print $1}')
CL1=$(kubectl -n c9s-vlan get pods | awk '/^client1/{print $1}')
CL2=$(kubectl -n c9s-vlan get pods | awk '/^client2/{print $1}')

# 確認
echo "SRL1=$SRL1 SRL2=$SRL2 CL1=$CL1 CL2=$CL2"
```

---

### 9.2 VXLAN インターフェイスの確認

VXLAN インターフェイスが正しく作成されているか確認します。

```bash
kubectl -n c9s-vlan exec -it $SRL1 -- ip link show type vxlan
kubectl -n c9s-vlan exec -it $SRL2 -- ip link show type vxlan
```

**期待する出力 (srl1):**

```
vx-srl1-e1-1
vx-srl1-e1-10
```

**期待する出力 (srl2):**

```
vx-srl2-e1-1
vx-srl2-e1-10   ← srl1 と srl2 が別 Worker の場合に必要
```

**期待する出力と一致しない場合 → Section 9.3 を実施してください。**

---

### 9.3 VXLAN インターフェイスが作成されていない場合の対処

#### Step 1: Connectivity CR の削除 (VXLAN 設定トリガー)

clabernetes v0.4.1 では Connectivity CR の ADDED イベントが無視されるため、手動で削除することで VXLAN 設定をトリガーします。

```bash
kubectl delete connectivity -n c9s-vlan vlan

# VXLAN インターフェイスが作成されたか確認
sleep 10
kubectl -n c9s-vlan exec -it $SRL1 -- ip link show type vxlan
kubectl -n c9s-vlan exec -it $SRL2 -- ip link show type vxlan
```

Section 9.2 の期待する出力と一致したら Section 9.4 へ進みます。

#### Step 2: vx-srl2-e1-10 が作成されない場合

srl1 と srl2 が別 Worker にいる場合、srl2 の e1-10 用 VXLAN が自動作成されないことがあります。手動で作成します。

```bash
# srl1-vx の ClusterIP を取得
SRL1_VX_IP=$(kubectl get svc -n c9s-vlan srl1-vx -o jsonpath='{.spec.clusterIP}')
echo "srl1-vx ClusterIP: $SRL1_VX_IP"

# vx-srl2-e1-10 を作成
kubectl -n c9s-vlan exec -it $SRL2 -- \
  ip link add vx-srl2-e1-10 type vxlan \
  id 3 remote $SRL1_VX_IP dev eth0 dstport 14789

kubectl -n c9s-vlan exec -it $SRL2 -- ip link set vx-srl2-e1-10 up

# tc ミラーリング設定
kubectl -n c9s-vlan exec -it $SRL2 -- \
  tc qdisc add dev vx-srl2-e1-10 ingress

kubectl -n c9s-vlan exec -it $SRL2 -- \
  tc filter add dev vx-srl2-e1-10 ingress \
  protocol all pref 49152 u32 match u32 0 0 \
  action mirred egress redirect dev srl2-e1-10
```

作成後に再確認します。

```bash
kubectl -n c9s-vlan exec -it $SRL2 -- ip link show type vxlan
```

---

### 9.4 tc フィルターの確認

srl2-e1-10 の ingress tc フィルターが正しく設定されているか確認します。

```bash
kubectl -n c9s-vlan exec -it $SRL2 -- tc filter show dev srl2-e1-10 ingress
```

**期待する出力:**

```
action order 1: mirred (Egress Mirror to device vx-srl2-e1-10) pipe
```

**以下の出力が含まれる場合は対処が必要です:**

```
action order 1: mirred (Egress Mirror to device *) pipe   ← 無効なデバイス
```

**期待する出力と一致しない場合 → Section 9.5 を実施してください。**

---

### 9.5 tc フィルターが不正な場合の対処

```bash
# tc フィルターを全削除してやり直し
kubectl -n c9s-vlan exec -it $SRL2 -- tc filter del dev srl2-e1-10 ingress

# Mirror で再設定
kubectl -n c9s-vlan exec -it $SRL2 -- \
  tc filter add dev srl2-e1-10 ingress \
  protocol all pref 49152 u32 match u32 0 0 \
  action mirred egress mirror dev vx-srl2-e1-10 pipe
```

再確認:

```bash
kubectl -n c9s-vlan exec -it $SRL2 -- tc filter show dev srl2-e1-10 ingress
# mirred (Egress Mirror to device vx-srl2-e1-10) pipe が表示されることを確認
```

---

## 10. 疎通確認

### 10.1 データパス疎通 (ping)

```bash
kubectl -n c9s-vlan exec $CL1 -- docker exec client1 ping -c 3 10.1.0.2
```

期待する出力:

```
64 bytes from 10.1.0.2: icmp_seq=1 ttl=64 time=2.59 ms
64 bytes from 10.1.0.2: icmp_seq=2 ttl=64 time=1.89 ms
64 bytes from 10.1.0.2: icmp_seq=3 ttl=64 time=1.20 ms
0% packet loss
```

### 10.2 LLDP ネイバー確認

```bash
kubectl -n c9s-vlan exec -it $SRL1 -- \
  docker exec srl1 sr_cli show system lldp neighbor
```

`ethernet-1/10` に srl2 が表示されることを確認します。

### 10.3 SSH アクセス (Windows ホストから直接)

ブリッジ接続のため、Windows ホストから LoadBalancer の IP に直接 SSH できます。

```bash
ssh admin@192.168.30.202   # srl1
# Password: NokiaSrl1!
```

### 10.4 Pod シェル経由

```bash
kubectl -n c9s-vlan exec -it $SRL1 -- ssh srl1
```

---

## 11. VXLAN カプセル構造と MTU

### 11.1 本環境での VXLAN スタック

| レイヤー | 区間 | 主体 |
|---|---|---|
| 物理 Ethernet | Windows NIC ↔ 物理 SW ↔ VM NIC | VMware ブリッジ |
| Clabernetes VXLAN | Worker Pod ↔ Worker Pod 間 (ClusterIP 経由) | clabernetes |
| Docker veth / bridge | Pod 内コンテナ ↔ コンテナ | containerlab (DinD) |

### 11.2 VXLAN Remote の仕組み

clabernetes は `-vx` Service の ClusterIP を VXLAN の remote として使用します。Pod からのパケットは Node の kube-proxy (iptables) で DNAT されて相手 Pod に届きます。

### 11.3 MTU の考慮

ブリッジ接続環境では物理スイッチの MTU (通常 1500) が上限となります。VXLAN オーバーヘッド (+50 byte) により断片化が発生する場合があります。

```bash
# 全ノードで実施
sudo sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.cni\]/a\    mtu = 1450' \
  /etc/containerd/config.toml
sudo systemctl restart containerd
```

---

## 12. クリーンアップ

### 12.1 ラボの削除

```bash
kubectl delete namespace c9s-vlan --wait=true
# Terminating から進まない場合は以下を実行
kubectl get namespace c9s-vlan -o json | \
  python3 -c "
import json, sys
ns = json.load(sys.stdin)
ns['spec']['finalizers'] = []
print(json.dumps(ns))
" | kubectl replace --raw /api/v1/namespaces/c9s-vlan/finalize -f -
```

### 12.2 Clabernetes の削除

```bash
helm uninstall clabernetes -n c9s
kubectl delete namespace c9s
```

### 12.3 Kubernetes クラスターのアンインストール

全ノードで実施します。

```bash
# kubeadm リセット
sudo kubeadm reset -f

# パッケージ削除
sudo apt-get remove -y kubeadm kubelet kubectl
sudo apt-get autoremove -y

# CNI 設定の削除
sudo rm -rf /etc/cni/net.d/
sudo rm -rf /var/lib/cni/

# iptables のリセット
sudo iptables -F && sudo iptables -X
sudo iptables -t nat -F && sudo iptables -t nat -X
sudo iptables -t mangle -F && sudo iptables -t mangle -X

# 残留ファイルの削除
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/
sudo rm -rf $HOME/.kube/

# 残留インターフェイスの削除
sudo ip link delete cni0 2>/dev/null
sudo ip link delete kindnet0 2>/dev/null

sudo systemctl restart containerd
```

k8s-cp のみ追加実施:

```bash
sudo rm -f /usr/local/bin/helm
sed -i '/clabverter/d' ~/.bashrc
```

---

## 13. トラブルシューティング

| 症状 | 考えられる原因 | 対処 |
|---|---|---|
| `kubeadm only supports deploying clusters with the control plane version >= 1.35.0` | kubeadm が v1.35 以上にアップグレードされている | Section 5.8 で確認したバージョンを `apt-get install kubeadm=x.x.x-x.x` で再インストール |
| Node が NotReady | CNI 未適用 / swap 残存 | `kubectl describe node` で確認、`swapoff -a` 再実行 |
| Pod が Pending | リソース不足 / Taint | `kubectl describe pod` の Events を確認 |
| EXTERNAL-IP が `<pending>` | kube-vip 未起動 / IP range が重複 | `kubectl get pods -n kube-system \| grep vip` で Pod 状態確認 |
| puller が RunContainerError | containerd v2.x を使用 | containerd を v1.7.x にダウングレード、config.toml を再生成 |
| VXLAN インターフェイスが作成されない | Connectivity CR の ADDED イベントが ignoring | Section 9.2 の手動削除を実施 |
| `vx-srl2-e1-10` が存在しない | clabernetes v0.4.1 のバグ | Section 9.3 の手動作成を実施 |
| srl2-e1-10 に `device *` フィルター | 手動作成時の残留ルール | Section 9.4 の tc フィルター修正を実施 |
| ping が通らない (dropped が多い) | tc フィルターの競合 | Section 9.4 を実施 |
| namespace が Terminating から進まない | Finalizer が残存 | Section 12.1 の強制削除を実施 |
| containerd が起動しない | config.toml が v2.x 形式 (version = 3) | `sudo containerd config default \| sudo tee /etc/containerd/config.toml` で再生成 |

### デバッグコマンド

```bash
# Pod のログ確認
kubectl logs -n c9s-vlan <pod名> 2>&1 | tail -30

# tc フィルターの確認
kubectl -n c9s-vlan exec -it <pod名> -- tc filter show dev <device> ingress

# VXLAN 統計確認
kubectl -n c9s-vlan exec -it <pod名> -- ip -s link show type vxlan

# Connectivity CR の確認
kubectl get connectivity -n c9s-vlan -o yaml

# Clabernetes Manager のログ
kubectl logs -n c9s -l app.kubernetes.io/name=clabernetes 2>/dev/null | tail -30

# Node のリソース使用量
kubectl top nodes
kubectl top pods -n c9s-vlan
```

---

## 参考リンク

- Clabernetes Quickstart: https://containerlab.dev/manual/clabernetes/quickstart/
- Clabernetes Install: https://containerlab.dev/manual/clabernetes/install/
- kube-vip: https://kube-vip.io/docs/usage/kind/
- kubeadm セットアップ: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/
- kindnet: https://github.com/aojea/kindnet
- SR Linux コンテナイメージ: https://github.com/nokia/srlinux-container-image
