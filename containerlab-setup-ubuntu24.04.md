# ContainerLab セットアップ手順書（Ubuntu 24.04 / インターネットアクセスあり）

**対象OS:** Ubuntu 24.04.4 LTS Server  
**インストール方式:** インターネット直接インストール  
**更新日:** 2025-05-14

---

## 目次

1. [前提条件・確認事項](#1-前提条件確認事項)
2. [システムアップデート](#2-システムアップデート)
3. [Docker インストール](#3-docker-インストール)
4. [Docker ネットワーク設定変更](#4-docker-ネットワーク設定変更)
5. [ContainerLab インストール](#5-containerlab-インストール)
6. [動作確認](#6-動作確認)
7. [オフライン環境向け：必要パッケージ整理](#7-オフライン環境向け必要パッケージ整理)

---

## 1. 前提条件・確認事項

### ハードウェア・OS要件

| 項目 | 要件 |
|------|------|
| OS | Ubuntu 24.04.4 LTS Server (x86_64) |
| CPU | 4コア以上推奨 |
| RAM | 8GB以上推奨（ラボ規模による） |
| Disk | 50GB以上の空き容量推奨 |
| ネットワーク | インターネット接続（apt/curl 経由） |

### 実行ユーザー

- `sudo` 権限を持つユーザーで実行する
- `root` 直接実行は非推奨

### OS バージョン確認

```bash
lsb_release -a
uname -r
```

---

## 2. システムアップデート

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common
```

---

## 3. Docker インストール

公式リポジトリから最新版の Docker Engine をインストールする。

### 3.1 Docker 公式 GPG キーの追加

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

### 3.2 Docker リポジトリの追加

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### 3.3 Docker Engine のインストール

```bash
sudo apt update
sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
```

### 3.4 Docker サービスの有効化・起動

```bash
sudo systemctl enable docker
sudo systemctl start docker
```

### 3.5 一般ユーザーへの権限付与

```bash
sudo usermod -aG docker $USER
```

> **注意:** グループ変更を反映するには、いったんログアウト＆再ログイン（またはセッション再起動）が必要。

```bash
# 再ログインせずに即時反映したい場合（一時的）
newgrp docker
```

### 3.6 インストール確認

```bash
docker version
docker run hello-world
```

---

## 4. Docker ネットワーク設定変更

デフォルトの `172.17.0.0/16` から変更し、ContainerLab や他サービスとのアドレス競合を回避する。

### 変更内容

| 設定項目 | 変更前（デフォルト） | 変更後 |
|----------|---------------------|--------|
| `default-address-pools` base | `172.17.0.0/16` (bridge) | `172.32.0.0/16` |
| `default-address-pools` size | `/20` | `/24` |
| `bip` (docker0 ブリッジ) | `172.17.0.1/16` | `172.31.0.1/16` |

### 4.1 `/etc/docker/daemon.json` の作成・編集

```bash
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "bip": "172.31.0.1/16",
  "default-address-pools": [
    {
      "base": "172.32.0.0/16",
      "size": 24
    }
  ]
}
EOF
```

> **設定解説:**
> - `bip`: `docker0` ブリッジインターフェース自身のIPアドレス（デフォルトネットワーク）
> - `default-address-pools`: `docker network create` で自動払い出されるサブネットのプール
>   - `base`: プール全体の範囲
>   - `size`: 各ネットワークに払い出すプレフィックス長（`/24` = 256アドレス/ネットワーク）

### 4.2 Docker の再起動

```bash
sudo systemctl restart docker
```

### 4.3 設定反映確認

```bash
# docker0 インターフェースのアドレス確認
ip addr show docker0

# 新規ネットワーク作成時のプール確認
docker network create test-net
docker network inspect test-net | grep Subnet
docker network rm test-net
```

期待される出力例（`docker0`）:
```
inet 172.31.0.1/16 brd 172.31.255.255 scope global docker0
```

---

## 5. ContainerLab インストール

### 5.1 公式インストールスクリプトによるインストール

```bash
bash -c "$(curl -sL https://get.containerlab.dev)"
```

> スクリプトは以下を自動実行する:
> - `containerlab` パッケージをダウンロード・インストール
> - `/usr/bin/containerlab` にバイナリを配置
> - 必要な依存関係の確認

### 5.2 インストール確認

```bash
containerlab version
```

期待される出力例:
```
                           _                   _       _
                 _        (_)                 | |     | |
 ____ ___  ____| |_  ____ _ ____   ____  ____| | ____| | _
/ ___) _ \|  _ |  _)/ _  | |  _ \ / _  )/ ___) |/ _  | || \
( (__| |_|| | | | |_( ( | | | | |( (/ /| |   | ( ( | | |_) )
\____)___/|_| |_|\___)_||_|_|_| |_|\____)_|   |_|\_||_|____/

    version: X.X.X
    ...
```

### 5.3 PATH 確認

```bash
which containerlab
containerlab --help
```

---

## 6. 動作確認

### 6.1 サンプルトポロジーで起動テスト

以下はシンプルな2ノード構成のサンプルトポロジー:

```bash
mkdir -p ~/clab-test && cd ~/clab-test

cat <<'EOF' > test.clab.yml
name: test

topology:
  nodes:
    node1:
      kind: linux
      image: alpine:latest
    node2:
      kind: linux
      image: alpine:latest

  links:
    - endpoints: ["node1:eth1", "node2:eth1"]
EOF
```

```bash
# ラボのデプロイ
sudo containerlab deploy -t test.clab.yml

# 起動確認
sudo containerlab inspect -t test.clab.yml

# ラボの削除
sudo containerlab destroy -t test.clab.yml
```

### 6.2 確認ポイント

- [ ] `containerlab version` でバージョンが表示される
- [ ] `docker version` で Server/Client ともに表示される
- [ ] `docker0` のIPが `172.31.0.1/16` であること
- [ ] `docker network create` で `172.32.x.0/24` レンジのサブネットが払い出されること
- [ ] サンプルトポロジーがエラーなくデプロイ・削除できること

---

## 7. オフライン環境向け：必要パッケージ整理

オフライン環境での手順書作成に向けて、必要なパッケージ・バイナリを整理する。

### 7.1 apt パッケージ（事前ダウンロード対象）

#### 7.1.1 共通依存パッケージ

```
ca-certificates
curl
gnupg
lsb-release
apt-transport-https
software-properties-common
```

#### 7.1.2 Docker Engine 関連パッケージ

以下のパッケージとその依存関係（`.deb`）をオンライン環境で取得する:

```
docker-ce
docker-ce-cli
containerd.io
docker-buildx-plugin
docker-compose-plugin
```

**オフライン用ダウンロードコマンド（オンライン環境で実行）:**

```bash
# Docker リポジトリ追加後に実行
mkdir -p ~/docker-offline-pkgs
cd ~/docker-offline-pkgs

# 依存パッケージ含めて全てダウンロード
sudo apt-get install --download-only -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# キャッシュからコピー
cp /var/cache/apt/archives/*.deb ~/docker-offline-pkgs/
ls -lh ~/docker-offline-pkgs/
```

**オフライン環境でのインストール:**

```bash
sudo dpkg -i ~/docker-offline-pkgs/*.deb
# 依存関係エラーが出た場合
sudo apt-get install -f
```

### 7.2 ContainerLab バイナリ

ContainerLab は以下の方法でオフライン配布用バイナリを取得する:

**GitHub Releases からの直接ダウンロード:**

```bash
# バージョン確認（最新版を取得）
CLAB_VERSION=$(curl -s https://api.github.com/repos/srl-labs/containerlab/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')

echo "Latest version: $CLAB_VERSION"

# バイナリのダウンロード（x86_64 の場合）
curl -LO "https://github.com/srl-labs/containerlab/releases/download/v${CLAB_VERSION}/containerlab_${CLAB_VERSION}_linux_amd64.deb"

# または tar.gz 形式
curl -LO "https://github.com/srl-labs/containerlab/releases/download/v${CLAB_VERSION}/containerlab_${CLAB_VERSION}_linux_amd64.tar.gz"
```

**オフライン環境でのインストール（.deb）:**

```bash
sudo dpkg -i containerlab_*_linux_amd64.deb
```

**オフライン環境でのインストール（tar.gz）:**

```bash
tar -xzf containerlab_*_linux_amd64.tar.gz
sudo mv containerlab /usr/bin/
sudo chmod +x /usr/bin/containerlab
```

### 7.3 Docker コンテナイメージ

使用するノードイメージは事前に `docker save` で tar アーカイブ化して持ち込む。

**オンライン環境でのイメージ保存:**

```bash
# 使用イメージを pull してから save
docker pull ghcr.io/nokia/srlinux:24.10.4
docker pull vrnetlab/vr-csr:17.03.08  # 例
docker pull alpine:latest

# tar アーカイブ化
docker save ghcr.io/nokia/srlinux:24.10.4 \
    | gzip > srlinux-24.10.4.tar.gz

docker save alpine:latest \
    | gzip > alpine-latest.tar.gz
```

**オフライン環境でのイメージロード:**

```bash
docker load < srlinux-24.10.4.tar.gz
docker load < alpine-latest.tar.gz

# ロード確認
docker images
```

### 7.4 オフライン環境用パッケージ一覧まとめ

| 種別 | アイテム | 取得方法 | 備考 |
|------|----------|----------|------|
| apt .deb | 共通依存パッケージ群 | `apt-get --download-only` | 約10〜20ファイル |
| apt .deb | Docker Engine パッケージ群 | `apt-get --download-only` | 約15〜25ファイル |
| apt .deb | Docker GPG キー | `curl` で `.gpg` 取得 | `/etc/apt/keyrings/` に配置 |
| バイナリ | `containerlab` | GitHub Releases `.deb` or `.tar.gz` | アーキテクチャ確認必須 |
| コンテナイメージ | 使用ノードイメージ | `docker save \| gzip` | ラボ設計に依存 |

### 7.5 オフライン環境用 Docker リポジトリ設定（代替手順）

インターネットなし環境では apt リポジトリが使えないため、ローカルリポジトリか dpkg 直接インストールを使用する。

```bash
# ローカルリポジトリ作成（オフライン環境側）
mkdir -p /opt/local-repo
cp ~/docker-offline-pkgs/*.deb /opt/local-repo/
cd /opt/local-repo
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

# apt ソースとして追加
echo "deb [trusted=yes] file:/opt/local-repo ./" \
    | sudo tee /etc/apt/sources.list.d/local-docker.list

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
```

---

## 参考リンク

- [ContainerLab 公式ドキュメント](https://containerlab.dev/)
- [Docker 公式インストールガイド（Ubuntu）](https://docs.docker.com/engine/install/ubuntu/)
- [ContainerLab GitHub Releases](https://github.com/srl-labs/containerlab/releases)
- [Docker daemon.json 設定リファレンス](https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-configuration-file)
