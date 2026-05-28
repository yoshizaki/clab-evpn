# Nokia EDA (Event-Driven Automation) on Proxmox VE 構築手順書

**対象バージョン:** EDA 26.4 / SR-Linux 26.4.x  
**対象ハードウェア:** Nokia 7220 IXR-D2L / D3L  
**ドキュメント参照:** https://docs.eda.dev/26.4/  
**最終更新:** 2026-05-25

> **25.12 版との主な差分については各セクション末尾の [🔄 26.4 変更点] ノートを参照してください。**

---

## 目次

1. [概要・前提知識](#1-概要前提知識)
2. [EDA 26.4 の主な新機能](#2-eda-264-の主な新機能)
3. [Part 1 — Try EDA（ラボ・検証用）](#part-1--try-edaラボ検証用)
4. [Part 2 — 正式インストール（本番環境用）](#part-2--正式インストール本番環境用)
5. [SR-Linux ノードのオンボーディング](#5-sr-linux-ノードのオンボーディング)
6. [動作確認](#6-動作確認)
7. [トラブルシューティング](#7-トラブルシューティング)

---

## 1. 概要・前提知識

### EDA の2つのデプロイモード

| 項目 | Try EDA（Playground） | 正式インストール |
|------|----------------------|----------------|
| 目的 | ラボ・学習・機能評価 | 本番・準本番運用 |
| Kubernetes | KinD（kind-in-Docker） | Talos Linux Kubernetes クラスター |
| VM 台数 | 1台（すべて同居） | 最小1台、推奨3台以上 |
| 高可用性 | なし | 3ノード構成で実現可能 |
| ライセンス | 不要 | Nokia ライセンス必要 |
| SR-Linux 接続 | ContainerLab（仮想） | 物理/仮想 SR-Linux 両対応 |
| セットアップ時間 | 約20〜30分 | 2〜4時間 |

### ネットワーク構成イメージ（Proxmox）

```
Proxmox VE Host
├── EDA VM (Ubuntu 22.04 / 24.04)
│   ├── vmbr0: 管理ネットワーク (OAM) ← ユーザー・API アクセス
│   └── vmbr1: ファブリック管理ネットワーク ← SR-Linux mgmt 接続
│
├── Nokia 7220 IXR-D2L (Leaf1)  ← mgmt: vmbr1
└── Nokia 7220 IXR-D3L (Spine1) ← mgmt: vmbr1
```

---

## 2. EDA 26.4 の主な新機能

25.12 から 26.4 で追加・変更された主要な機能です。

### Ask EDA（AI アシスタント）

EDA UI に組み込みの AI アシスタント機能が追加されました。自然言語でネットワーク状態の問い合わせや設定の確認ができます。

- EQL（EDA Query Language）クエリの自動生成
- アラームの原因分析と解決策の提案
- ダッシュボードの自動生成
- LLM プロバイダーの選択（OpenAI / Gemini など外部 LLM も設定可能）

### MCP Server

EDA が MCP（Model Context Protocol）サーバーとして機能します。Claude、GitHub Copilot などの外部 AI ツールから EDA の状態・設定を参照できます。

```
https://<EDA_VIP>/mcp/v1
```

### Branches / Merge Requests（Git ワークフロー）

ネットワーク設定変更に Git ブランチ・マージリクエストのワークフローが導入されました。

- `main` ブランチへのマージ前にドライランで変更影響を確認
- 複数エンジニアによるレビューと承認フロー
- ロールバック対応

### Workflows（操作自動化）

EDA UI からワークフロー（操作手順の自動実行）が実行できるようになりました。

- ISL Ping、System Ping などの接続確認ワークフロー
- Check BGP、Check Interfaces などの診断ワークフロー
- カスタムワークフローの作成

### Namespaces（マルチテナント）

EDA リソースを Namespace で分離管理できるようになりました。チームや環境（dev/prod）ごとの分離に使用します。

### アプリケーションの拡充

26.4 で追加・強化された Apps:

| App | 概要 |
|-----|------|
| AAA | RADIUS/TACACS+ 認証ポリシーの管理 |
| AIFabrics | AI ワークロード向けファブリック設定 |
| Anomalies | 異常検知・アラート |
| Filters | コントロールプレーンフィルター管理 |
| Micro Segmentation | グループタグベースのマイクロセグメンテーション |
| MPLS | LDP / MPLS ラベル管理 |
| QoS | QoS ポリシー管理 |
| OAM | ミラー・Ping・Tech Support |
| Routing | スタティックルート・OSPFなどのルーティング管理 |
| Services | Bridge Domain / VirtualNetwork / IRB |

---

## Part 1 — Try EDA（ラボ・検証用）

### 1.1 システム要件

| リソース | 最小要件 |
|---------|---------|
| vCPU | 8 vCPU |
| RAM | 16 GB |
| ストレージ | 30 GB SSD |
| OS | Ubuntu 22.04 LTS または 24.04 LTS |
| Docker | 24.x 以上 |

> **注意:** KinD（Kubernetes in Docker）を使用するため、Docker が必須です。

### 1.2 Proxmox VE での VM 作成

Proxmox WebUI または qm コマンドで以下のスペックで VM を作成します。

```bash
# Proxmox ホストにて
qm create 200 \
  --name eda-playground \
  --memory 16384 \
  --cores 8 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:32 \
  --net0 virtio,bridge=vmbr0 \
  --net1 virtio,bridge=vmbr1 \
  --ostype l26 \
  --boot c \
  --bootdisk scsi0
```

Ubuntu 22.04 または 24.04 Server をインストール後、ネットワークを設定します。

```bash
# VM内にて
# ホスト名設定
sudo hostnamectl set-hostname eda-playground

# 静的IP設定
sudo tee /etc/netplan/00-installer-config.yaml <<'EOF'
network:
  version: 2
  ethernets:
    ens18:
      addresses: [192.168.10.50/24]
      routes:
        - to: default
          via: 192.168.10.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
    ens19:
      addresses: [172.16.0.1/24]
EOF
sudo netplan apply
```

### 1.3 Docker のインストール

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker

# 動作確認
docker run hello-world
```

### 1.4 必要ツールのインストール

```bash
sudo apt update && sudo apt install -y git make curl wget

# kubectl（EDA操作に使用）
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### 1.5 EDA Playground のクローンと準備

```bash
# EDA Playground リポジトリをクローン
git clone https://github.com/nokia-eda/playground && cd playground

# ツール類のダウンロード（kind, kubectl, kpt, yq）
make download-tools

# EDA パッケージのダウンロード（eda-kpt, catalog）
make download-pkgs
```

### 1.6 EDA のデプロイ（Try EDA）

```bash
# EDA Playground を KinD クラスター上にデプロイ
# ※ インターネット接続が必要（ghcr.io からコンテナイメージをダウンロード）
make try-eda
```

> **所要時間:** 初回は20〜30分程度（イメージダウンロードを含む）

デプロイ完了後、以下のような出力が表示されます。

```
✅ EDA playground is up and running!
   UI:  https://192.168.10.50
   API: https://192.168.10.50/core/httpproxy/v1/
```

### 1.7 EDA UI へのアクセス確認

```bash
# KinD クラスターのノード確認
kubectl get nodes

# EDA 名前空間の Pod 確認
kubectl get pods -n eda

# SR-Linux 仮想ノードの確認（Playground 内に自動作成）
kubectl get toponodes -n eda
```

ブラウザで `https://192.168.10.50` にアクセスします。

- **ユーザー名:** `admin`
- **パスワード:** `admin`（初期値、変更推奨）

26.4 UI では **Ask EDA** ボタン（右上）から AI アシスタントを試せます。

### 1.8 ContainerLab との統合（Try EDA 拡張）

物理 SR-Linux の代わりに ContainerLab の仮想ノードを EDA で管理する場合の設定です。

```bash
# ContainerLab のインストール
bash -c "$(curl -sL https://get.containerlab.dev)"

# SR-Linux 26.4 トポロジーファイルの作成
cat > lab-topology.yml <<'EOF'
name: eda-lab
topology:
  nodes:
    leaf1:
      kind: nokia_srlinux
      image: ghcr.io/nokia/srlinux:26.4.1
      type: ixrd2l
    leaf2:
      kind: nokia_srlinux
      image: ghcr.io/nokia/srlinux:26.4.1
      type: ixrd2l
    spine1:
      kind: nokia_srlinux
      image: ghcr.io/nokia/srlinux:26.4.1
      type: ixrd3l
  links:
    - endpoints: ["leaf1:e1-1", "spine1:e1-1"]
    - endpoints: ["leaf2:e1-1", "spine1:e1-2"]
EOF

sudo containerlab deploy -t lab-topology.yml
```

```bash
# EDA TopoNode リソースの作成（leaf1 の例）
cat > toponode-leaf1.yaml <<'EOF'
apiVersion: topologies.eda.nokia.com/v1alpha1
kind: TopoNode
metadata:
  name: leaf1
  namespace: eda
spec:
  platform: 7220 IXR-D2L
  version: 26.4.1
  os: srl
  productionAddress:
    ipv4: <clab-leaf1-のIPアドレス>
EOF

kubectl apply -f toponode-leaf1.yaml
```

> **🔄 26.4 変更点:**
> - SR-Linux イメージバージョンを `26.4.1`（または最新の 26.4.x）に変更
> - ContainerLab で起動した SR-Linux ノードには EDA との gNMI 連携用の `eda-discovery` / `eda-mgmt` gRPC サーバーが自動追加されます
> - Namespace を指定した TopoNode 作成が推奨（26.4 ではマルチ Namespace 対応）

### 1.9 Try EDA のクリーンアップ

```bash
cd playground

# クリーンアップ（KinD クラスターごと削除）
make teardown

# 再デプロイ
make try-eda
```

---

## Part 2 — 正式インストール（本番環境用）

### 2.1 システム要件

#### EDA ノード（Talos Kubernetes VM）

| 構成 | ノード数 | 各ノードスペック |
|------|---------|----------------|
| 最小（シングル） | 1 | 8 vCPU / 32 GB RAM / 200 GB SSD |
| 推奨（冗長） | 3 | 16 vCPU / 32 GB RAM / 200 GB SSD |
| 大規模 | 3 Master + N Worker | 16 vCPU / 64 GB RAM / 200 GB SSD |

#### ツール実行環境（作業 Linux VM または Proxmox ホスト）

| ツール | バージョン |
|--------|-----------|
| Git | 2.x 以上 |
| kubectl | 1.29 以上 |
| kpt | 最新 |
| yq | v4 以上 |
| edaadm | EDA 26.4 対応版 |
| talosctl | edaadm が指定するバージョン |

#### ネットワーク要件

| 用途 | 必要数 | 説明 |
|------|--------|------|
| Kubernetes VIP | 1 | Kubernetes コントロールプレーン用仮想 IP |
| EDA API/UI VIP | 1 | EDA Web UI・API・MCP アクセス用仮想 IP |

> **重要:** 2つの VIP は管理ネットワーク内の**未使用** IP アドレスを事前に確保してください。DHCP による自動割り当てと競合しないよう注意。

### 2.2 Proxmox VE での EDA ノード VM 作成（3ノード構成）

```bash
# Proxmox ホストにて（3ノード分）
for i in 1 2 3; do
  qm create $((300 + i)) \
    --name eda-node-0${i} \
    --memory 32768 \
    --cores 16 \
    --scsihw virtio-scsi-pci \
    --scsi0 local-lvm:200 \
    --net0 virtio,bridge=vmbr0 \
    --net1 virtio,bridge=vmbr1 \
    --ostype l26
done
```

> **注意:** Talos Linux は ISO からブートします。Ubuntu などの OS インストールは不要です。VM 作成後すぐに Talos ISO をマウントして起動します。

### 2.3 インストール準備（作業 Linux 環境にて）

#### EDA Playground リポジトリのクローン

```bash
git clone https://github.com/nokia-eda/playground && cd playground

# ツール類（kubectl, kpt, yq, kind）のダウンロード
make download-tools

# EDA パッケージのダウンロード
make download-pkgs
```

#### edaadm ツールのダウンロード

```bash
git clone https://github.com/nokia-eda/edaadm && cd edaadm

# edaadm CLI のダウンロード
make -C bundles/ download-tools

# PATH に追加
export PATH=$PATH:$(pwd)/bundles/tools
edaadm version
# EDA 26.4.x と表示されることを確認
```

#### Talos マシンイメージのダウンロード（KVM 用）

```bash
# EDA 26.4 が要求する Talos バージョンを確認
TALOS_VERSION=$(edaadm talos-version)
echo "Required Talos version: ${TALOS_VERSION}"

# Talos Factory から KVM 用 ISO イメージを取得
wget -O talos-metal-amd64.iso \
  "https://factory.talos.dev/image/${TALOS_VERSION}/metal-amd64.iso"

# Proxmox の ISO ストレージに転送
scp talos-metal-amd64.iso root@<proxmox-host>:/var/lib/vz/template/iso/
```

> **🔄 26.4 変更点:**
> - EDA 26.4 では Talos v1.9.x 以降が要求される場合があります。必ず `edaadm talos-version` で確認してください。
> - Air-gapped インストール手順が 25.12 から再構成され、Assets VM デプロイフローが変更されています（`Preparing the Assets VM` ステップが削除され `Downloading the assets` → `Deploying the assets VM` → `Uploading the assets` の3ステップに）。

### 2.4 EDAADM 設定ファイルの作成

```yaml
# edaadm-config.yaml
# ※ IPアドレスは環境に合わせて変更してください

clusterName: eda-cluster

# Kubernetes コントロールプレーン VIP（未使用 IP を割り当て）
kubernetesVIP: 192.168.10.100

# EDA API/UI/MCP 用 VIP（未使用 IP を割り当て）
edaVIP: 192.168.10.101

nodes:
  - name: eda-node-01
    type: controlplane
    storage: true
    network:
      oam:
        interface: eth0
        ipAddress: 192.168.10.111/24
        gateway: 192.168.10.1
      fabric:
        interface: eth1
        ipAddress: 172.16.0.11/24

  - name: eda-node-02
    type: controlplane
    storage: true
    network:
      oam:
        interface: eth0
        ipAddress: 192.168.10.112/24
        gateway: 192.168.10.1
      fabric:
        interface: eth1
        ipAddress: 172.16.0.12/24

  - name: eda-node-03
    type: controlplane
    storage: true
    network:
      oam:
        interface: eth0
        ipAddress: 192.168.10.113/24
        gateway: 192.168.10.1
      fabric:
        interface: eth1
        ipAddress: 172.16.0.13/24

dns:
  - 8.8.8.8
  - 8.8.4.4
```

### 2.5 Talos マシン設定の生成

```bash
cd edaadm

# edaadm-config.yaml をもとに Talos 設定ファイルを生成
edaadm generate --config edaadm-config.yaml

# 生成されたファイルの確認
ls -la generated/
# controlplane.yaml  worker.yaml  talosconfig  kubeconfig（仮）など
```

### 2.6 Talos VM のデプロイ（Proxmox KVM）

Proxmox WebUI で各 EDA ノード VM（VMID 301〜303）に Talos ISO をマウントして起動します。

```bash
# Proxmox ホストにて：ISO を各 VM にマウントして起動
for i in 1 2 3; do
  qm set $((300 + i)) --cdrom local:iso/talos-metal-amd64.iso
  qm start $((300 + i))
done
```

VM が起動し、Talos の初期画面が表示されたら、設定を適用します。

```bash
# ノード01 への Talos 設定の適用（--insecure は初回のみ）
talosctl apply-config \
  --insecure \
  --nodes 192.168.10.111 \
  --file generated/controlplane.yaml

talosctl apply-config \
  --insecure \
  --nodes 192.168.10.112 \
  --file generated/controlplane.yaml

talosctl apply-config \
  --insecure \
  --nodes 192.168.10.113 \
  --file generated/controlplane.yaml
```

設定適用後、各 VM は自動的に再起動して設定を読み込みます（数分かかります）。

### 2.7 Talos Kubernetes クラスターのブートストラップ

```bash
# talosconfig を環境変数に設定
export TALOSCONFIG=$(pwd)/generated/talosconfig

# クラスターのブートストラップ（最初の1回のみ、ノード01で実行）
talosctl bootstrap \
  --nodes 192.168.10.111 \
  --endpoints 192.168.10.111

# kubeconfig の取得（Kubernetes VIP 経由）
talosctl kubeconfig \
  --nodes 192.168.10.111 \
  --endpoints 192.168.10.100 \
  ./kubeconfig

export KUBECONFIG=$(pwd)/kubeconfig

# ノードの Ready 確認（3〜5分かかる場合あり）
kubectl get nodes
# NAME          STATUS   ROLES           AGE   VERSION
# eda-node-01   Ready    control-plane   5m    v1.29.x
# eda-node-02   Ready    control-plane   4m    v1.29.x
# eda-node-03   Ready    control-plane   4m    v1.29.x
```

### 2.8 EDA アプリケーションのインストール

```bash
cd playground

# EDA インストール設定ファイルの編集
cat > eda-kpt/eda-config.yaml <<'EOF'
apiVersion: eda.nokia.com/v1alpha1
kind: EDAConfig
metadata:
  name: eda
spec:
  # EDA API/UI/MCP アクセス用 VIP
  edaVIP: 192.168.10.101

  # 初期管理者パスワード（変更必須・12文字以上推奨）
  adminPassword: "ChangeMe2026!"

  # Digital Twin（Sandbox）：ラボでは true、本番では false 推奨
  enableDigitalSandbox: false
EOF

# EDA アプリケーションのインストール
make install EDA_KUBECONFIG=./kubeconfig

# Pod の起動確認（10〜20分かかる場合あり）
kubectl get pods -n eda --watch
```

全 Pod が `Running` になれば完了です。

```
NAME                                    READY   STATUS    RESTARTS
eda-api-server-xxxxx                    1/1     Running   0
eda-ui-xxxxx                            1/1     Running   0
eda-bootstrap-server-xxxxx              1/1     Running   0
eda-gitea-xxxxx                         1/1     Running   0
eda-ask-eda-xxxxx                       1/1     Running   0
...
```

### 2.9 EDA UI へのアクセス確認

ブラウザで `https://192.168.10.101` にアクセスします。

- **ユーザー名:** `admin`
- **パスワード:** `ChangeMe2026!`（設定した値）

> **🔄 26.4 変更点:**
> - UI に **Ask EDA**（AI アシスタント）、**Branches**、**Merge Requests**、**Workflows**、**Alarms** メニューが追加されています。
> - **MCP Server** エンドポイント `https://192.168.10.101/mcp/v1` が自動的に有効化されます。Claude Desktop 等の AI ツールから接続可能です。
> - **Namespaces** による論理分割が利用可能です。デフォルトは `eda` Namespace。

---

## 5. SR-Linux ノードのオンボーディング

### 5.1 ネットワークトポロジーの定義

物理 Nokia 7220 IXR-D2L/D3L を EDA に登録します。

```yaml
# network-topology.yaml
apiVersion: topologies.eda.nokia.com/v1alpha1
kind: NetworkTopology
metadata:
  name: dc-fabric
  namespace: eda
spec:
  operation: replaceAll

  nodeTemplates:
    - name: leaf
      nodeProfile: srlinux-26.4.1
      platform: 7220 IXR-D2L
      labels:
        eda.nokia.com/security-profile: managed
        eda.nokia.com/role: leaf

    - name: spine
      nodeProfile: srlinux-26.4.1
      platform: 7220 IXR-D3L
      labels:
        eda.nokia.com/security-profile: managed
        eda.nokia.com/role: spine

  nodes:
    - name: leaf1
      template: leaf
    - name: leaf2
      template: leaf
    - name: spine1
      template: spine

  linkTemplates:
    - name: isl
      type: interSwitch
      speed: 10G
      encapType: "null"
      labels:
        eda.nokia.com/role: interSwitch

  links:
    - name: leaf1-spine1
      template: isl
      endpoints:
        - local:
            node: leaf1
            interface: ethernet-1-1
          remote:
            node: spine1
            interface: ethernet-1-1
    - name: leaf2-spine1
      template: isl
      endpoints:
        - local:
            node: leaf2
            interface: ethernet-1-1
          remote:
            node: spine1
            interface: ethernet-1-2
```

```bash
kubectl apply -f network-topology.yaml
```

### 5.2 物理ノードの TopoNode 定義

```yaml
# toponodes.yaml
---
apiVersion: topologies.eda.nokia.com/v1alpha1
kind: TopoNode
metadata:
  name: leaf1
  namespace: eda
spec:
  platform: 7220 IXR-D2L
  version: 26.4.1        # 実際の SR-Linux バージョンに合わせる
  os: srl
  productionAddress:
    ipv4: 172.16.0.21    # SR-Linux の mgmt IP アドレス

---
apiVersion: topologies.eda.nokia.com/v1alpha1
kind: TopoNode
metadata:
  name: leaf2
  namespace: eda
spec:
  platform: 7220 IXR-D2L
  version: 26.4.1
  os: srl
  productionAddress:
    ipv4: 172.16.0.22

---
apiVersion: topologies.eda.nokia.com/v1alpha1
kind: TopoNode
metadata:
  name: spine1
  namespace: eda
spec:
  platform: 7220 IXR-D3L
  version: 26.4.1
  os: srl
  productionAddress:
    ipv4: 172.16.0.31
```

```bash
kubectl apply -f toponodes.yaml
```

> **🔄 26.4 変更点:**
> - `nodeProfile` の名前が `srlinux-26.4.1` 形式に変更されています（EDA が管理するプロファイル名はインストール時に自動生成）。
> - `version` フィールドは物理スイッチの SR-Linux バージョンに合わせてください。EDA 26.4 は SR-Linux 26.x 系との組み合わせが推奨です。

### 5.3 SR-Linux 側の事前設定

EDA が gNMI 経由で接続するために、SR-Linux 側で以下の設定が必要です。

```
# SR-Linux CLI にて実行
# gNMI サーバーの有効化
set / system gnmi-server admin-state enable
set / system gnmi-server network-instance mgmt admin-state enable
set / system gnmi-server network-instance mgmt port 57400
set / system gnmi-server network-instance mgmt tls-profile tls-default

# EDA 管理用ユーザーの作成
set / system aaa authentication local-user eda-mgmt password <パスワード>
set / system aaa authentication local-user eda-mgmt role [admin]

# gNSI（gRPC Network Security Interface）の有効化（26.x 推奨）
set / system grpc-server eda-mgmt admin-state enable
set / system grpc-server eda-mgmt network-instance mgmt
set / system grpc-server eda-mgmt port 57400
set / system grpc-server eda-mgmt tls-profile tls-default
set / system grpc-server eda-mgmt services [ gnmi gnsi ]

commit now
```

> **🔄 26.4 変更点:**
> - SR-Linux 26.x では gNSI（gRPC Network Security Interface）が EDA の TLS 証明書管理に使われます。`services [ gnmi gnsi ]` の指定を忘れないようにしてください。
> - EDA はオンボーディング時に TLS セキュリティプロファイルを自動セットアップします。事前に手動で証明書を設定する必要はありません。

---

## 6. 動作確認

### 6.1 ノードのオンボーディング確認

```bash
# ノードの接続状態確認
kubectl get toponodes -n eda
# NAME     PLATFORM       VERSION   OS    ONBOARDED   MODE     NODE
# leaf1    7220 IXR-D2L   26.4.1    srl   true        normal   Connected  Synced
# leaf2    7220 IXR-D2L   26.4.1    srl   true        normal   Connected  Synced
# spine1   7220 IXR-D3L   26.4.1    srl   true        normal   Connected  Synced

# NPP (Node Proxy Pod) の確認
kubectl get pods -n eda | grep npp
```

### 6.2 edactl（CLI）での確認

26.4 では `edactl` がリファクタリングされ `Command line tools` として整理されています。

```bash
# edactl のダウンロード
kubectl -n eda exec deploy/eda-api-server -- \
  cat /usr/local/bin/edactl > ./edactl && chmod +x ./edactl

# EDA VIP を指定して接続
export EDA_SERVER=https://192.168.10.101
export EDA_USERNAME=admin
export EDA_PASSWORD=ChangeMe2026!

# ノード一覧
./edactl get nodes

# トランザクション履歴
./edactl get transactions

# EQL クエリ（例：全インターフェースの状態）
./edactl query "from interface select name, oper-state"
```

### 6.3 MCP Server への接続確認（26.4 新機能）

EDA 26.4 の MCP Server に接続することで Claude などの AI ツールから EDA を操作できます。

```bash
# MCP Server のエンドポイント確認
curl -k https://192.168.10.101/mcp/v1 \
  -H "Authorization: Bearer <token>"
```

Claude Desktop の MCP 設定例（`~/.config/claude/claude_desktop_config.json`）:

```json
{
  "mcpServers": {
    "eda": {
      "url": "https://192.168.10.101/mcp/v1",
      "headers": {
        "Authorization": "Bearer <EDA_API_TOKEN>"
      }
    }
  }
}
```

### 6.4 EDA UI での確認項目

ブラウザで EDA UI にアクセスし、以下を確認します。

- **Home（ダッシュボード）:** ノード数・アラーム数・トランザクション数の概要
- **Topology:** ノードグラフが表示され、全ノードが緑（Connected/Synced）
- **Nodes:** 各ノードのバージョン・プラットフォーム情報が正しく表示
- **Transactions:** 初期設定のトランザクションが Committed 状態
- **Ask EDA:** 「Show me all nodes」などの自然言語クエリが動作する

---

## 7. トラブルシューティング

### ノードが Synced にならない

```bash
# NPP Pod のログ確認
kubectl logs -n eda -l eda.nokia.com/node=leaf1 -c npp --tail=50

# Bootstrap Server のログ確認
kubectl logs -n eda deploy/eda-bootstrap-server --tail=50
```

よくある原因:

- SR-Linux の gNMI / gNSI が有効になっていない → 5.3 の設定を再確認
- EDA ファブリックネットワーク（vmbr1）への疎通不可 → `ping 172.16.0.21` で確認
- SR-Linux の TLS 設定が不正 → `show system tls` で確認
- SR-Linux バージョンと nodeProfile が一致しない → TopoNode の `version` フィールドを確認

### Kubernetes VIP への疎通不可

```bash
# Talos ノードのネットワーク確認
talosctl get addresses --nodes 192.168.10.111

# VIP がいずれかのノードに割り当てられているか確認
talosctl get vips --nodes 192.168.10.111
```

### Ask EDA が応答しない

```bash
# Ask EDA サービスの Pod 確認
kubectl get pods -n eda | grep ask

# LLM プロバイダーの設定確認（UI > Settings > Ask EDA）
# 外部 LLM（OpenAI 等）を使用する場合は API キーの設定が必要
```

### Pod が起動しない (Pending)

```bash
# リソース不足・スケジューリング失敗の確認
kubectl describe pod <pod-name> -n eda
kubectl top nodes
```

### 25.12 からのアップグレード

インプレースアップグレードは `software-install/upgrades/` ガイドを参照してください。**設定データは Gitea（内部 Git）に保存されているため、バックアップを取ってからアップグレードを実施することを推奨します。**

```bash
# バックアップの取得（26.4 UI より）
# Administration > Backup and Restore > Create Backup

# アップグレード前のバージョン確認
kubectl get pods -n eda -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}' | grep api-server
```

---

## 参考リンク

| リソース | URL |
|---------|-----|
| EDA 26.4 公式ドキュメント | https://docs.eda.dev/26.4/ |
| Try Nokia EDA ガイド | https://docs.eda.dev/26.4/getting-started/try-eda/ |
| Software Installation Guide | https://docs.eda.dev/26.4/software-install/ |
| EDA Playground (GitHub) | https://github.com/nokia-eda/playground |
| edaadm (GitHub) | https://github.com/nokia-eda/edaadm |
| Tour of EDA | https://docs.eda.dev/26.4/tour-of-eda/ |
| Ask EDA ユーザーガイド | https://docs.eda.dev/26.4/user-guide/ask-eda/ |
| MCP Server ガイド | https://docs.eda.dev/26.4/user-guide/mcp-server/ |
| Branches / Merge Requests | https://docs.eda.dev/26.4/user-guide/branches/ |
| ContainerLab 統合 | https://docs.eda.dev/26.4/user-guide/containerlab-integration/ |
| Backup and Restore | https://docs.eda.dev/26.4/user-guide/administration/backup-and-restore/ |
| EDA Discord | https://eda.dev/discord |
| EDA YouTube Playlist | https://www.youtube.com/watch?v=5Qk8opmjixk&list=PLgKNvl454BxdqOqs3xzCXFxmRna71C90T |
