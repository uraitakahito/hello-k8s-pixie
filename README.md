# Hello K8s Pixie

[hello-k8s](https://github.com/uraitakahito/hello-k8s) をベースに、**Pixie（eBPF ベースの自動観測ツール）によるメトリクス可視化** を追加した教材です。
アプリケーションのコードやマニフェストを一切変更せずに、HTTP メトリクス・サービスマップ・DNS 分析・CPU プロファイリングを自動取得します。

## 前提条件

- [OrbStack](https://orbstack.dev/) がインストール済み
- OrbStack の Kubernetes が有効（Settings → Kubernetes → Enable Kubernetes）
- [Pixie](https://px.dev/) のアカウント（無料）

## プロジェクト構成

```
.
├── app/
│   ├── Dockerfile             # Nginx イメージ（hello-k8s と同一）
│   ├── default.conf
│   ├── docker-entrypoint.sh
│   ├── index-blue.html
│   └── index-green.html
├── k8s/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── deployment-blue.yaml
│   ├── deployment-green.yaml
│   ├── service-blue.yaml
│   └── service-green.yaml
├── pxl/
│   ├── http_metrics.pxl       # HTTP メトリクス（レイテンシ・エラー率）
│   ├── service_map.pxl        # サービス間通信グラフ
│   ├── dns_metrics.pxl        # DNS クエリ分析
│   └── cpu_profile.pxl        # CPU プロファイリング
├── scripts/
│   └── load-gen.sh            # トラフィック生成
└── README.md
```

## 手順

### 1. Pixie CLI のインストール

```bash
bash -c "$(curl -fsSL https://withpixie.ai/install.sh)"
```

### 2. Pixie にログイン & クラスタへデプロイ

```bash
px auth login
px deploy
```

デプロイ後、Pixie の Pod が起動するまで待ちます。

```bash
kubectl get pods -n pl -w
kubectl get pods -n px-operator -w
```

すべての Pod が Running になったら、Pixie のステータスを確認します。

```bash
px get viziers
```

### 3. Docker イメージをビルド

```bash
docker build -t hello-k8s-pixie-web ./app
```

### 4. アプリケーションをデプロイ

```bash
kubectl apply -k k8s/
```

Pod が Running になるまで待ちます。

```bash
kubectl get pods -n hello-k8s-pixie -w
```

### 5. 動作確認

```bash
# Blue（ポート 30080）, Green（ポート 30081）
curl http://localhost:30080
curl http://localhost:30081
```

OrbStack では Service 名でもアクセスできます。

```bash
curl http://web-blue.hello-k8s-pixie.svc.cluster.local:8080
curl http://web-green.hello-k8s-pixie.svc.cluster.local:8080
```

### 6. トラフィックを生成

Pixie でメトリクスを観測するために、トラフィックを生成します。

```bash
./scripts/load-gen.sh 60 10    # 60秒間、10 RPS
```

### 7. Pixie でメトリクスを確認

#### 組み込みスクリプトで確認（OrbStack で動作）

```bash
# Namespace ごとのプロセス・ネットワーク統計
px run px/namespaces

# ネットワーク統計（Pod ごとの送受信バイト数・パケット数）
px run px/network_stats -- --namespace=hello-k8s-pixie

# Pixie エージェントの状態
px run px/agent_status
```

#### カスタム PxL スクリプトで確認（GKE / EKS 環境向け）

以下のスクリプトは `http_events` / `dns_events` / `stack_traces` テーブルを使用します。
OrbStack 環境ではこれらのテーブルが利用できないため、GKE や EKS などのクラウド環境で実行してください（[制限事項](#orbstack-上の制限事項2025年3月時点)を参照）。

```bash
# HTTP メトリクス（リクエスト数・レイテンシ・エラー率）
px run -f pxl/http_metrics.pxl

# サービスマップ（Pod 間通信）
px run -f pxl/service_map.pxl

# DNS メトリクス
px run -f pxl/dns_metrics.pxl

# CPU プロファイル
px run -f pxl/cpu_profile.pxl
```

#### Web UI で確認

Pixie の Web UI（[work.withpixie.ai](https://work.withpixie.ai)）にアクセスし、クラスタを選択してください。
Namespace を `hello-k8s-pixie` でフィルタすると、以下のダッシュボードが利用できます。

- **px/cluster** — クラスタ全体の概要
- **px/namespace** — Namespace 別のメトリクス
- **px/service** — サービス別の HTTP メトリクス（GKE / EKS 環境のみ）
- **px/pod** — Pod 別の詳細

## 学習ポイント

### eBPF によるゼロインストルメンテーション観測

Pixie は Linux カーネルの eBPF（extended Berkeley Packet Filter）を使い、アプリケーションに一切手を加えずにメトリクスを自動収集します。

- **HTTP リクエスト**: カーネルのネットワークスタックで HTTP プロトコルをパースし、リクエスト/レスポンスのメタデータを取得
- **DNS クエリ**: DNS パケットを自動キャプチャし、Kubernetes のサービスディスカバリで発生する名前解決を可視化
- **サービスマップ**: syscall（`connect`, `accept` など）をトレースし、Pod 間の通信関係を自動構築
- **CPU プロファイリング**: `perf_event` を使ってスタックトレースをサンプリングし、フレームグラフを生成

### hello-k8s-logging（サイドカー）との比較

| | サイドカー + Fluent Bit | Pixie（eBPF） |
|---|---|---|
| 導入方法 | マニフェスト変更が必要（サイドカーコンテナ、ボリューム、ConfigMap を追加） | **マニフェスト変更不要**（クラスタに Pixie をデプロイするだけ） |
| 取得データ | アプリケーションが出力するログファイル | HTTP/DNS/ネットワーク/CPU など**自動収集** |
| データ粒度 | ログ行（テキスト） | 構造化メトリクス（レイテンシ分布、エラー率など） |
| Pod への影響 | サイドカーコンテナ追加（リソース消費） | Pod に変更なし（DaemonSet として動作） |
| データ保持 | 外部に転送可能（長期保存） | **インクラスタ短期保持（約24時間）** |
| セキュリティ | PSS Restricted 適合（emptyDir 使用） | DaemonSet + 特権コンテナが必要 |

**使い分けの指針:**
- **Pixie**: 開発・デバッグ時のリアルタイム観測、パフォーマンス分析、サービス間の通信把握
- **サイドカー + Fluent Bit**: ログの長期保存、コンプライアンス対応、外部ログ基盤への転送

### Pixie のデータ保持とトレードオフ

Pixie はすべてのデータをクラスタ内（各ノードの PEM — Pixie Edge Module）に保持します。
外部にデータを送信しないため、データの主権（Data Sovereignty）が保たれますが、保持期間は約24時間に限られます。

長期保存が必要な場合は、Pixie の [OpenTelemetry エクスポート機能](https://docs.px.dev/tutorials/integrations/otel/) を使って外部の観測基盤に転送できます。

### OrbStack での動作と制限事項

OrbStack は macOS 上で軽量 Linux VM を実行し、その中で Kubernetes を動かしています。
この VM のカーネル（Linux 6.17.8）は eBPF に必要なすべてのカーネルオプションが有効になっています。

- `CONFIG_BPF=y`, `CONFIG_BPF_SYSCALL=y` — BPF コアサポート
- `CONFIG_BPF_JIT=y` — JIT コンパイル
- `CONFIG_KPROBES=y`, `CONFIG_UPROBES=y` — カーネル/ユーザースペースプローブ
- `CONFIG_DEBUG_INFO_BTF=y` — BTF（CO-RE サポート）

#### OrbStack 上の制限事項（2025年3月時点）

Pixie のデプロイ自体は成功し、`process_stats`（プロセス統計）と `network_stats`（ネットワーク統計）は正常に動作します。
しかし、以下の機能は **OrbStack 環境では動作しません**。

| 機能 | Pixie 内部コネクタ | 状態 | 原因 |
|------|-------------------|------|------|
| HTTP メトリクス | `socket_tracer` | 動作しない | カーネルヘッダー互換性問題 |
| DNS メトリクス | `socket_tracer` | 動作しない | 同上 |
| サービスマップ | `socket_tracer` | 動作しない | 同上 |
| CPU プロファイリング | `perf_profiler` | 動作しない | 同上 |

**原因の詳細:**

Pixie は BCC（BPF Compiler Collection）を使って eBPF プログラムをランタイムでコンパイルします。
この方式ではカーネルヘッダーが必須ですが、OrbStack のカスタムカーネル（6.17.8）は以下の2つの問題を抱えています。

1. **カーネルヘッダーの不在**: OrbStack VM の `/lib/modules/<version>/build` にヘッダーが配置されていない。`/sys/kernel/kheaders.tar.xz` は存在するが `Makefile` が欠けている
2. **カーネルバージョンの互換性**: カーネル 6.17.8 のヘッダーには Pixie 0.14.15 の BCC が未対応の新しい BPF 命令（`BPF_LOAD_ACQ`, `BPF_STORE_REL`）が含まれており、コンパイルに失敗する

Pixie が BCC から CO-RE/libbpf ベースに移行すれば、BTF さえあれば動作するようになります（OrbStack の BTF は `/sys/kernel/btf/vmlinux` で利用可能）。しかし Pixie はカーネル 4.14 以降をサポートしており（BTF 未対応カーネルを含む）、CO-RE への移行時期は未定です。

#### 動作する機能の確認方法

```bash
# Namespace ごとのプロセス・ネットワーク統計（動作する）
px run px/namespaces

# Pod ごとのネットワーク統計（動作する）
px run px/network_stats -- --namespace=hello-k8s-pixie

# Pixie エージェントの状態（動作する）
px run px/agent_status
```

#### GKE / EKS での利用

クラウド環境の Kubernetes（GKE、EKS など）では標準的なカーネルヘッダーが提供されるため、
HTTP メトリクス・DNS・サービスマップ・CPU プロファイリングを含むすべての Pixie 機能が利用できます。
`pxl/` ディレクトリの PxL スクリプトはこれらの環境向けに用意されています。

## クリーンアップ

```bash
# アプリケーションの削除
kubectl delete -k k8s/

# Pixie の削除（必要な場合）
px delete

# Docker イメージの削除
docker rmi hello-k8s-pixie-web
```

## 参考

- [hello-k8s](https://github.com/uraitakahito/hello-k8s) — ベースプロジェクト
- [hello-k8s-logging](https://github.com/uraitakahito/hello-k8s-logging) — サイドカーログ収集版
- [Pixie Documentation](https://docs.px.dev/)
- [PxL Language Reference](https://docs.px.dev/reference/pxl/)
- [Pixie eBPF の仕組み](https://docs.px.dev/about-pixie/pixie-ebpf/)
