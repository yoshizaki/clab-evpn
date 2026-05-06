# Private Registry セットアップマニュアル

**Docker Registry v2 / Ubuntu 24.04 LTS / kubeadm + containerd v1.7.x 環境向け**
Version 1.1

---

## 1. 概要と設計方針

### 目的

外部レジストリ (ghcr.io, docker.io 等) へのアクセスを不要にし、以下のイメージをローカル環境から配信します。

| イメージ | 元のレジストリ | 用途 |
|---|---|---|
| ghcr.io/nokia/srlinux:24.10.1 | ghcr.io | SR Linux NOS |
| ghcr.io/srl-labs/alpine | ghcr.io | クライアントノード |
| ghcr.io/srl-labs/clabernetes/clabernetes-manager:0.4.1 | ghcr.io | Clabernetes Manager |
| ghcr.io/srl-labs/clabernetes/clabernetes-launcher:0.4.1 | ghcr.io | Clabernetes Launcher |
| ghcr.io/srl-labs/clabernetes/clabverter | ghcr.io | clabverter |
| registry.k8s.io/pause:3.x | registry.k8s.io | k8s インフラ用 |

XRd 等の他の NOS も同様の手順でイメージを追加できます。

### 構成

```
【外部アクセスあり (インターネット接続可能) な端末で実施】
  イメージ Pull → タグ付け → Registry VM に Push

【192.168.30.x のセグメント】
┌──────────────────┐   ┌──────────────────────────────────┐
│ Registry VM      │   │ k8s クラスター                    │
│ 192.168.30.50    │◄──│ k8s-cp  192.168.30.60            │
│ Docker Registry  │   │ k8s-w1  192.168.30.61            │
│ Port 5000 (HTTP) │   │ k8s-w2  192.168.30.62            │
└──────────────────┘   └──────────────────────────────────┘
```

### PoC 環境での設計選択

| 項目 | 選択 | 理由 |
|---|---|---|
| Registry ソフト | Docker Registry v2 | シンプル・軽量 |
| 認証 | なし | PoC のためシンプルに |
| TLS | なし (HTTP) | 自己署名証明書の管理を省略 |
| 配置 | 専用 VM | Controller / Worker と分離 |

> ⚠ 本設定は PoC 環境向けです。本番環境では TLS と認証 (Harbor 等) を使用してください。

---

## 2. 環境定義

| 役割 | ホスト名 | IP アドレス | vCPU | メモリ | ディスク |
|---|---|---|---|---|---|
| Private Registry | registry | 192.168.30.50 | 2 | 4 GB | 100 GB ※ |
| Control Plane | k8s-cp | 192.168.30.60 | 4 | 8 GB | 40 GB |
| Worker Node 1 | k8s-w1 | 192.168.30.61 | 4 | 8 GB | 60 GB |
| Worker Node 2 | k8s-w2 | 192.168.30.62 | 4 | 8 GB | 60 GB |

※ SR Linux (約 700MB) × 複数バージョン + 他 NOS を格納するため 100GB 以上を推奨します。

---

## 3. Registry VM のセットアップ

### 3.1 OS 初期設定

> **対象ノード: registry のみ**

静的 IP の設定:

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 192.168.30.50/24
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

/etc/hosts の設定:

```bash
sudo tee -a /etc/hosts <<EOF
192.168.30.50  registry
192.168.30.60  k8s-cp
192.168.30.61  k8s-w1
192.168.30.62  k8s-w2
EOF
```

パッケージ更新:

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl
```

### 3.2 Docker のインストール

> **対象ノード: registry のみ**

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $USER
newgrp docker
docker version
```

### 3.3 Docker Registry v2 の起動

> **対象ノード: registry のみ**

イメージ保存ディレクトリの作成:

```bash
sudo mkdir -p /opt/registry/data
sudo chown $USER:$USER /opt/registry/data
```

Registry コンテナの起動:

```bash
docker run -d \
  --name registry \
  --restart=always \
  -p 5000:5000 \
  -v /opt/registry/data:/var/lib/registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2
```

動作確認:

```bash
docker ps | grep registry
curl http://192.168.30.50:5000/v2/
# {} が返れば正常
```

---

## 4. イメージの取得と Push

> **対象: インターネットアクセス可能な端末 (Windows ホスト上の Docker 等)**
> Registry VM から直接実施することも可能です (インターネット接続がある場合)。

### 4.1 Registry VM からの insecure registry 設定

Registry VM の Docker daemon に insecure registry を許可します。

```bash
# registry VM にて実施
sudo tee /etc/docker/daemon.json <<EOF
{
  "insecure-registries": ["192.168.30.50:5000"]
}
EOF
sudo systemctl restart docker
```

### 4.2 Clabernetes 関連イメージ

```bash
# Manager
docker pull ghcr.io/srl-labs/clabernetes/clabernetes-manager:0.4.1
docker tag  ghcr.io/srl-labs/clabernetes/clabernetes-manager:0.4.1 \
            192.168.30.50:5000/srl-labs/clabernetes/clabernetes-manager:0.4.1
docker push 192.168.30.50:5000/srl-labs/clabernetes/clabernetes-manager:0.4.1

# Launcher
docker pull ghcr.io/srl-labs/clabernetes/clabernetes-launcher:0.4.1
docker tag  ghcr.io/srl-labs/clabernetes/clabernetes-launcher:0.4.1 \
            192.168.30.50:5000/srl-labs/clabernetes/clabernetes-launcher:0.4.1
docker push 192.168.30.50:5000/srl-labs/clabernetes/clabernetes-launcher:0.4.1

# clabverter (latest)
docker pull ghcr.io/srl-labs/clabernetes/clabverter
docker tag  ghcr.io/srl-labs/clabernetes/clabverter \
            192.168.30.50:5000/srl-labs/clabernetes/clabverter
docker push 192.168.30.50:5000/srl-labs/clabernetes/clabverter
```

### 4.3 SR Linux

```bash
docker pull ghcr.io/nokia/srlinux:24.10.1
docker tag  ghcr.io/nokia/srlinux:24.10.1 \
            192.168.30.50:5000/nokia/srlinux:24.10.1
docker push 192.168.30.50:5000/nokia/srlinux:24.10.1
```

### 4.4 Alpine (srl-labs)

```bash
docker pull ghcr.io/srl-labs/alpine
docker tag  ghcr.io/srl-labs/alpine \
            192.168.30.50:5000/srl-labs/alpine
docker push 192.168.30.50:5000/srl-labs/alpine
```

### 4.5 XRd (参考)

XRd は Cisco の認証が必要です。事前に `docker login` を済ませてから実施します。

```bash
docker login <cisco-registry>
docker pull <cisco-registry>/xrd/xrd-control-plane:<tag>
docker tag  <cisco-registry>/xrd/xrd-control-plane:<tag> \
            192.168.30.50:5000/xrd/xrd-control-plane:<tag>
docker push 192.168.30.50:5000/xrd/xrd-control-plane:<tag>
```

### 4.6 kube-vip

```bash
KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | \
  jq -r '.[0].name')

docker pull ghcr.io/kube-vip/kube-vip:${KVVERSION}
docker tag  ghcr.io/kube-vip/kube-vip:${KVVERSION} \
            192.168.30.50:5000/kube-vip/kube-vip:${KVVERSION}
docker push 192.168.30.50:5000/kube-vip/kube-vip:${KVVERSION}
```

### 4.7 格納済みイメージの確認

Registry に保存されているイメージ一覧を確認します。

```bash
# カタログ (リポジトリ一覧)
curl http://192.168.30.50:5000/v2/_catalog | python3 -m json.tool

# 特定リポジトリのタグ一覧
curl http://192.168.30.50:5000/v2/nokia/srlinux/tags/list | python3 -m json.tool
```

---

## 5. k8s ノードの containerd 設定

> **対象ノード: k8s-cp / k8s-w1 / k8s-w2 (全 3 台)**

containerd が Private Registry をミラーとして使用するよう設定します。

### 5.1 certs.d ディレクトリの作成

containerd v1.7.x では `hosts.toml` ファイルでレジストリごとのミラーを設定します。

```bash
# ghcr.io のミラー設定
sudo mkdir -p /etc/containerd/certs.d/ghcr.io

sudo tee /etc/containerd/certs.d/ghcr.io/hosts.toml <<EOF
server = "https://ghcr.io"

[host."http://192.168.30.50:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

```bash
# docker.io のミラー設定 (registry:2 イメージ取得用)
sudo mkdir -p /etc/containerd/certs.d/docker.io

sudo tee /etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://registry-1.docker.io"

[host."http://192.168.30.50:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

```bash
# registry.k8s.io のミラー設定
sudo mkdir -p /etc/containerd/certs.d/registry.k8s.io

sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<EOF
server = "https://registry.k8s.io"

[host."http://192.168.30.50:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

### 5.2 config.toml に certs.d パスを設定

```bash
# config_path が設定されているか確認
grep config_path /etc/containerd/config.toml
```

設定されていない場合は追加します。

```bash
sudo sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]/a\  config_path = "/etc/containerd/certs.d"' \
  /etc/containerd/config.toml

# 確認
grep -A2 'registry\]' /etc/containerd/config.toml | grep config_path
```

### 5.3 containerd の再起動

```bash
sudo systemctl restart containerd
sudo systemctl status containerd
```

### 5.4 ミラー設定の動作確認

```bash
# ctr コマンドで直接 Pull テスト (containerd に直接問い合わせ)
sudo ctr images pull ghcr.io/srl-labs/alpine:latest
sudo ctr images ls | grep alpine
```

Private Registry からの Pull であることをログで確認します。

```bash
sudo journalctl -u containerd -f | grep -i "registry\|mirror\|pull"
```

---

## 6. Docker daemon の insecure registry 設定

> **対象ノード: k8s-cp のみ** (Docker を使用するノード)

k8s-cp では clabverter / kube-vip 生成に Docker を使用します。Private Registry が HTTP のため insecure registry として登録します。

```bash
sudo tee /etc/docker/daemon.json <<EOF
{
  "insecure-registries": ["192.168.30.50:5000"]
}
EOF
sudo systemctl restart docker
```

---

## 7. Clabernetes のインストールを Private Registry から実施

### 7.1 Helm チャートのイメージ参照を変更

Helm インストール時に `--set` でイメージのリポジトリを上書きします。

```bash
helm upgrade --install --create-namespace --namespace c9s \
    clabernetes oci://ghcr.io/srl-labs/clabernetes/clabernetes \
    --version 0.4.1 \
    --set manager.image.repository=192.168.30.50:5000/srl-labs/clabernetes/clabernetes-manager \
    --set manager.image.tag=0.4.1
```

> Helm チャートのイメージ設定キー名は clabernetes のバージョンにより異なる場合があります。実際のキー名は以下で確認します。
>
> ```bash
> helm show values oci://ghcr.io/srl-labs/clabernetes/clabernetes --version 0.4.1 | grep -i image
> ```

### 7.2 ラボトポロジーのイメージ参照を変更

`.clab.yml` のイメージを Private Registry を指すように変更します。

```yaml
# 変更前
topology:
  nodes:
    srl1:
      kind: nokia_srlinux
      image: ghcr.io/nokia/srlinux:24.10.1

# 変更後
topology:
  nodes:
    srl1:
      kind: nokia_srlinux
      image: 192.168.30.50:5000/nokia/srlinux:24.10.1
```

---

## 8. Registry の管理

### 8.1 ディスク使用量の確認

```bash
# Registry VM にて実施
du -sh /opt/registry/data/
```

### 8.2 イメージの削除

Registry API でイメージを削除します。

```bash
# digest を取得
DIGEST=$(curl -s -I \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  http://192.168.30.50:5000/v2/nokia/srlinux/manifests/24.10.1 \
  | grep Docker-Content-Digest | awk '{print $2}' | tr -d $'\r')

echo "Digest: $DIGEST"

# 削除
curl -X DELETE http://192.168.30.50:5000/v2/nokia/srlinux/manifests/$DIGEST
```

### 8.3 Registry コンテナの再起動

```bash
docker restart registry
docker ps | grep registry
```

### 8.4 Registry のバックアップ

```bash
# /opt/registry/data を tar でバックアップ
sudo tar czf /backup/registry-$(date +%Y%m%d).tar.gz /opt/registry/data/
```

---

## 9. k8s インフライメージの格納 (完全オフライン化)

k8s のセットアップ自体もオフラインで実施するために、kubeadm が使用するインフライメージを Private Registry に格納します。

### 9.1 インフライメージの確認と取得

> **対象: インターネット接続可能な端末**

```bash
# kubeadm が使用するイメージ一覧を確認
kubeadm config images list --kubernetes-version=v1.29.2

# 出力例:
# registry.k8s.io/kube-apiserver:v1.29.2
# registry.k8s.io/kube-controller-manager:v1.29.2
# registry.k8s.io/kube-scheduler:v1.29.2
# registry.k8s.io/kube-proxy:v1.29.2
# registry.k8s.io/pause:3.9
# registry.k8s.io/etcd:3.5.10-0
# registry.k8s.io/coredns/coredns:v1.11.1

# 一括 Pull
kubeadm config images pull --kubernetes-version=v1.29.2
```

### 9.2 インフライメージを Private Registry に Push

```bash
for IMAGE in $(kubeadm config images list --kubernetes-version=v1.29.2); do
  # registry.k8s.io/kube-apiserver:v1.29.2
  #   → 192.168.30.50:5000/kube-apiserver:v1.29.2
  REPO=$(echo $IMAGE | sed 's|registry.k8s.io/||')
  docker tag  $IMAGE 192.168.30.50:5000/$REPO
  docker push 192.168.30.50:5000/$REPO
  echo "Pushed: 192.168.30.50:5000/$REPO"
done
```

### 9.3 kindnet イメージの取得と格納

```bash
# kindnet の最新タグを確認してから Pull
KINDNET_VERSION=v1.4.0   # 実際のバージョンに合わせて変更
docker pull ghcr.io/aojea/kindnet:${KINDNET_VERSION}
docker tag  ghcr.io/aojea/kindnet:${KINDNET_VERSION} \
            192.168.30.50:5000/aojea/kindnet:${KINDNET_VERSION}
docker push 192.168.30.50:5000/aojea/kindnet:${KINDNET_VERSION}
```

kindnet の manifest ファイルもダウンロードしてイメージ参照を書き換えます。

```bash
curl -o kindnet.yaml \
  https://raw.githubusercontent.com/aojea/kindnet/main/install-kindnet.yaml

# イメージ参照を Private Registry に書き換え
sed -i "s|ghcr.io/aojea/kindnet|192.168.30.50:5000/aojea/kindnet|g" kindnet.yaml

# 確認
grep image kindnet.yaml
```

### 9.4 kubeadm init で Private Registry を指定

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.30.60 \
  --kubernetes-version=v1.29.2 \
  --image-repository=192.168.30.50:5000   # ← Private Registry を指定
```

CNI は書き換え済みのローカルファイルから適用します。

```bash
kubectl apply -f kindnet.yaml
```

---

## 10. 完全オフライン環境向け事前準備

インターネット接続が不要な完全オフライン環境を再現するために必要な全てのリソースを事前に取得・保存します。

### 10.1 オフライン化の対象と方法

| リソース | 形式 | 保存方法 | 備考 |
|---|---|---|---|
| k8s インフライメージ | コンテナイメージ | Private Registry | Section 9 参照 |
| kindnet イメージ | コンテナイメージ | Private Registry | Section 9.3 参照 |
| kindnet manifest | YAML ファイル | ローカルファイル | image 参照を書き換え |
| kube-vip イメージ | コンテナイメージ | Private Registry | Section 4.6 参照 |
| kube-vip RBAC manifest | YAML ファイル | ローカルファイル | |
| kube-vip Cloud Provider manifest | YAML ファイル | ローカルファイル | |
| Clabernetes イメージ | コンテナイメージ | Private Registry | Section 4.2 参照 |
| **Clabernetes Helm チャート** | **.tgz ファイル** | **ローカルファイル** | OCI のため Registry では不安定 |
| SR Linux / NOS イメージ | コンテナイメージ | Private Registry | Section 4.3 参照 |
| Alpine イメージ | コンテナイメージ | Private Registry | Section 4.4 参照 |
| clabverter イメージ | コンテナイメージ | Private Registry | Section 4.2 参照 |

### 10.2 Helm チャートをローカルファイルとして保存

Clabernetes の Helm チャートは OCI 形式で配布されています。Docker Registry v2 では OCI アーティファクトの互換性が不完全なため、`.tgz` ファイルとしてローカルに保存します。

```bash
# チャートをファイルとしてダウンロード
helm pull oci://ghcr.io/srl-labs/clabernetes/clabernetes --version 0.4.1

# clabernetes-0.4.1.tgz が生成される
ls -la clabernetes-0.4.1.tgz
```

### 10.3 manifest ファイルのダウンロード

```bash
# 保存用ディレクトリを作成
mkdir -p ~/offline-resources

# kindnet
curl -o ~/offline-resources/kindnet.yaml \
  https://raw.githubusercontent.com/aojea/kindnet/main/install-kindnet.yaml
sed -i "s|ghcr.io/aojea/kindnet|192.168.30.50:5000/aojea/kindnet|g" \
  ~/offline-resources/kindnet.yaml

# kube-vip RBAC
curl -o ~/offline-resources/kube-vip-rbac.yaml \
  https://kube-vip.io/manifests/rbac.yaml

# kube-vip Cloud Provider
curl -o ~/offline-resources/kube-vip-cloud-provider.yaml \
  https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml

# 確認
ls -la ~/offline-resources/
```

### 10.4 kube-vip DaemonSet manifest の生成と保存

kube-vip の DaemonSet manifest は `docker run` で動的生成するため、事前に生成してファイルとして保存します。

```bash
KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | \
  jq -r '.[0].name')

docker run --network host --rm \
  192.168.30.50:5000/kube-vip/kube-vip:${KVVERSION} \
  manifest daemonset --services --inCluster --arp --interface <NIC名> \
  > ~/offline-resources/kube-vip-daemonset.yaml

# イメージ参照を Private Registry に書き換え
sed -i "s|ghcr.io/kube-vip/kube-vip|192.168.30.50:5000/kube-vip/kube-vip|g" \
  ~/offline-resources/kube-vip-daemonset.yaml

cat ~/offline-resources/kube-vip-daemonset.yaml | grep image
```

### 10.5 Helm チャートの移送

```bash
# オフラインリソースをまとめて tar に圧縮
tar czf offline-resources-$(date +%Y%m%d).tar.gz \
  ~/offline-resources/ \
  clabernetes-0.4.1.tgz

# 必要に応じて USB メモリや SCP でオフライン環境に転送
scp offline-resources-*.tar.gz tomo@192.168.30.60:~/
```

### 10.6 オフライン環境でのインストール手順

全てのリソースが Private Registry とローカルファイルに揃った状態でのインストール手順です。

#### kubeadm init (インフライメージを Private Registry から取得)

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.30.60 \
  --kubernetes-version=v1.29.2 \
  --image-repository=192.168.30.50:5000
```

#### CNI のインストール (ローカルファイルから)

```bash
kubectl apply -f ~/offline-resources/kindnet.yaml
```

#### kube-vip のインストール (ローカルファイルから)

```bash
kubectl apply -f ~/offline-resources/kube-vip-rbac.yaml
kubectl apply -f ~/offline-resources/kube-vip-cloud-provider.yaml

kubectl create configmap --namespace kube-system kubevip \
  --from-literal range-global=192.168.30.200-192.168.30.220

kubectl apply -f ~/offline-resources/kube-vip-daemonset.yaml
```

#### Clabernetes のインストール (ローカルチャートから)

```bash
helm upgrade --install --create-namespace --namespace c9s \
  clabernetes ./clabernetes-0.4.1.tgz \
  --set manager.image.repository=192.168.30.50:5000/srl-labs/clabernetes/clabernetes-manager \
  --set manager.image.tag=0.4.1
```

### 10.7 オフライン化の完了確認

以下のコマンドで外部へのアクセスが発生していないことを確認します。

```bash
# 外部向けの通信をモニタリング (Registry VM で実施)
sudo tcpdump -i <NIC名> -n \
  not host 192.168.30.0/24 \
  and port 80 or port 443 \
  and not arp
```

k8s セットアップ中に外部向けパケットが発生しなければ完全オフライン化が達成されています。

---

## 11. トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `http: server gave HTTP response to HTTPS client` | containerd が HTTPS を要求している | hosts.toml の endpoint が `http://` になっているか確認 |
| `connection refused` | Registry コンテナが停止している | `docker ps` で確認、`docker start registry` で起動 |
| Pull が Registry ではなく ghcr.io から行われる | config_path が設定されていない | Section 5.2 を実施して containerd を再起動 |
| `unauthorized` エラー | 認証情報が必要なイメージ | 元のレジストリに `docker login` してから Pull |
| ディスク不足 | イメージが大きい | `du -sh /opt/registry/data/` で確認し不要イメージを削除 |

### ミラー設定の確認

```bash
# hosts.toml の内容確認
cat /etc/containerd/certs.d/ghcr.io/hosts.toml

# containerd のレジストリ設定確認
sudo containerd config dump | grep -A 10 registry

# Pull 時のログ確認
sudo journalctl -u containerd --since "5 minutes ago" | grep -i "mirror\|registry\|pull"
```
