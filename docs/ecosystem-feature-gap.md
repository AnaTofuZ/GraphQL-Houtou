# GraphQL エコシステム機能ギャップ調査

## 目的

この文書は、GraphQL-Houtou が現時点で対応していない機能を、
以下の3つの観点から整理したものである。

1. **GraphQL 公式仕様**（graphql-spec）に定義されているが未実装の機能
2. **事実上の標準**（graphql-js、Apollo、Relay 等）として広く採用されているが未実装の機能
3. **運用・セキュリティ系**のエコシステム機能

調査日: 2026-04-06

---

## 1. GraphQL 公式仕様（graphql-spec）

### 1.1 実行仕様の不足

| 機能 | Houtou | graphql-perl | 備考 |
|------|--------|--------------|------|
| Mutation serial execution | ❌ TODO | ❌ | `_execute_fields_serially` が未実装。parallel で代用中 |
| `@defer` ディレクティブ | ❌ | ❌ | Incremental Delivery RFC |
| `@stream` ディレクティブ | ❌ | ❌ | Incremental Delivery RFC |
| `@oneOf` ディレクティブ | ❌ | ❌ | RFC 845 |
| OneOf Input Object バリデーション | ❌ | ❌ | exactly-one field、non-null 制約 |

### 1.2 スキーマ検証の不足

| 機能 | Houtou | graphql-perl | 備考 |
|------|--------|--------------|------|
| Interface 実装整合性チェック | ❌ | ❌ | `assert_object_implements_interface` が未実装 |
| SDL validator（スキーマ定義文書の検証） | ❌ | ❌ | |
| Schema build-time validator | ❌ | ❌ | 型定義の整合性チェック |

### 1.3 Introspection の仕様遅れ（graphql-perl 由来）

現行 graphql-perl の introspection は旧仕様ベースであり、以下が未対応。
Houtou はこれを引き継いでいる。

| フィールド | 状況 |
|-----------|------|
| `__Directive.isRepeatable` | ❌ |
| `__Type.specifiedByURL` | ❌ |
| `__Type.isOneOf` | ❌ |
| `__Field.args(includeDeprecated: true)` | ❌ |
| `__Directive.args(includeDeprecated: true)` | ❌ |
| `__Type.inputFields(includeDeprecated: true)` | ❌ |
| `__InputValue.isDeprecated` | ❌ |
| `__InputValue.deprecationReason` | ❌ |

### 1.4 Directive / Location（graphql-perl との差分）

| 機能 | Houtou | graphql-perl | 備考 |
|------|--------|--------------|------|
| `VARIABLE_DEFINITION` directive location | ✅ 対応済 | ❌ | graphql-perl は未対応 |
| `@specifiedBy` built-in directive | ✅ 対応済 | ❌ | graphql-perl は未対応 |
| Input field / argument の `@deprecated` | ❌ | ❌ | |

---

## 2. SDL ユーティリティ（graphql-js 準拠・事実上の標準）

GraphiQL、codegen、schema registry 等のツールとの統合に必要な API 群。

| 機能 | Houtou | graphql-perl | 備考 |
|------|--------|--------------|------|
| `buildSchema(sdl)` | ❌ | △ | graphql-perl に部分的な実装あり |
| `printSchema(schema)` | ❌ | ❌ | |
| `extendSchema(schema, ast)` | ❌ | ❌ | |
| `findBreakingChanges(old, new)` | ❌ | ❌ | CI での schema drift 検出用途 |
| Schema introspection → SDL 往復 | ❌ | ❌ | |

---

## 3. Apollo Federation（サブグラフ化に必要）

Apollo Federation は公式仕様ではないが、マイクロサービス構成での GraphQL 統合の
事実上の標準として広く採用されている。
[Open Federation Spec](https://specs.apollo.dev/federation/) として公開されており、
Apollo 以外のサーバーも実装可能。

### Federation v1 / v2 ディレクティブ

| ディレクティブ | 用途 | 状況 |
|--------------|------|------|
| `@key` | エンティティのプライマリキー指定 | ❌ |
| `@external` | 他サービスが所有するフィールドのマーク | ❌ |
| `@requires` | 外部フィールドへの依存宣言 | ❌ |
| `@provides` | 解決可能な外部フィールドの宣言 | ❌ |
| `@shareable` | 複数サブグラフで解決可能なフィールド（v2） | ❌ |
| `@inaccessible` | スーパーグラフへの非公開フィールド（v2） | ❌ |
| `@override` | 別サービスからのフィールド移行（v2） | ❌ |
| `@link` | 外部仕様の import（v2） | ❌ |

### Federation 必須クエリ

| クエリ | 用途 | 状況 |
|--------|------|------|
| `_service { sdl }` | ゲートウェイへのスキーマ公開 | ❌ |
| `_entities(representations: [...])` | エンティティの解決 | ❌ |

### 現実的な対応策

Federation を使う構成として、Apollo Router / Apollo Gateway をゲートウェイとして立て、
Perl サーバーを subgraph として置く場合でも、`_service` と `_entities` の実装は必須となる。

---

## 4. Relay 仕様（Meta 標準・pagination の事実上の標準）

[Relay Cursor Connections Spec](https://relay.dev/graphql/connections.htm) および
[Global Object Identification](https://relay.dev/graphql/objectidentification.htm) は
Relay 以外のクライアントでも広く採用されている。

| 機能 | 状況 | 備考 |
|------|------|------|
| Global Object Identification（`Node` interface / `node()` query） | ❌ | 任意の型を ID で引ける標準パターン |
| Cursor Connection spec（`Connection` / `Edge` / `PageInfo`） | ❌ | カーソルベースのページネーション標準 |
| `pageInfo.hasNextPage` / `hasPreviousPage` | ❌ | Connection 内の必須フィールド |

---

## 5. HTTP / トランスポート層

GraphQL サーバーとして実際に動作させるためのトランスポート実装。

### Web フレームワーク統合

| 機能 | 状況 |
|------|------|
| PSGI / Plack integration | ❌ |
| Mojolicious integration | ❌ |
| Dancer2 integration | ❌ |
| Catalyst integration | ❌ |
| GraphiQL UI serving | ❌ |

### リクエスト形式

| 機能 | 状況 | 備考 |
|------|------|------|
| JSON バッチリクエスト（配列形式） | ❌ | 複数クエリを1リクエストで送る形式 |
| Multipart リクエスト（ファイルアップロード） | ❌ | [graphql-multipart-request-spec](https://github.com/jaydenseric/graphql-multipart-request-spec) |
| `Upload` scalar | ❌ | ファイルアップロード用スカラー |

---

## 6. Subscription トランスポートプロトコル

| プロトコル | 状況 | 備考 |
|-----------|------|------|
| `graphql-ws`（現行標準） | ❌ | WebSocket 上の現行標準プロトコル |
| `subscriptions-transport-ws`（旧来） | ❌ | Apollo Client が長らく使用していた旧プロトコル |
| Server-Sent Events（SSE）via multipart HTTP | ❌ | WebSocket 不要の代替手段 |
| AsyncIterator / cancel / disconnect 処理 | ❌ | Subscription の購読解除・切断処理 |

---

## 7. セキュリティ・運用系（事実上の標準）

本番運用において DoS 対策・コスト制御として広く使われる機能群。

| 機能 | 状況 | 備考 |
|------|------|------|
| Query Depth Limiting | ❌ | ネストの深さによる制限 |
| Query Complexity Analysis | ❌ | フィールド数・重みによるコスト計算 |
| Field-level rate limiting | ❌ | フィールド別のレート制限 |
| Persisted Queries | ❌ | クエリ文字列をサーバー側に事前登録 |
| Automatic Persisted Queries（APQ） | ❌ | クエリのハッシュキャッシュプロトコル |
| Query allowlist / safe-listing | ❌ | 許可済みクエリのみ受け付ける制限 |

---

## 8. Plugin / 拡張 API

| 機能 | 状況 | 備考 |
|------|------|------|
| `GraphQL::Plugin::Type`（custom scalar 登録） | ❌ | graphql-perl 互換の拡張ポイント |
| `GraphQL::Plugin::Convert`（schema 変換プラグイン） | ❌ | graphql-perl 互換の変換層 |
| Schema directives transformer | ❌ | apollo-server 式の `@directive` 実行時処理 |
| Execution middleware / interceptor | ❌ | 実行前後への処理の差し込み |
| execution result `extensions` 構築 hook | ❌ | レスポンスの `extensions` フィールドを組み立てる公開 hook |

---

## 優先度マトリクス

実用プロジェクトへの影響と実装コストを踏まえた優先度。

### 高優先度（実用化の前提）

| 機能 | 理由 |
|------|------|
| `buildSchema` / `printSchema` | SDL toolchain の基盤。GraphiQL・codegen との統合に必須 |
| HTTP / PSGI integration | 実際のサーバーとして動かすために必須 |
| Mutation serial execution | GraphQL 仕様の必須要件 |
| `_service { sdl }` / `_entities` | Federation subgraph の最低条件 |

### 中優先度（本番運用に必要）

| 機能 | 理由 |
|------|------|
| `graphql-ws` プロトコル | WebSocket subscription の現行標準 |
| Query depth / complexity 制限 | 本番運用の安全弁 |
| Modern introspection | GraphiQL・codegen・schema registry との互換 |
| `@defer` / `@stream` | 需要増加中の新仕様。イベントループ前提のため要アーキテクチャ検討 |

### 低優先度（用途依存）

| 機能 | 理由 |
|------|------|
| APQ / Persisted Queries | パフォーマンス最適化用途 |
| Relay spec | 特定ユーザー向け |
| `@oneOf` | RFC 段階、採用事例はまだ少ない |
| File upload | 用途が限定的 |

---

## 9. Perl 実装上の制約分析

未実装機能のうち、Perl の言語・実行モデルに起因する困難度を整理する。

### 9.1 技術的に実現困難（構造的問題）

#### `@defer` / `@stream`（Incremental Delivery）

「レスポンスの一部を送信しながら残りを計算し続ける」という構造が必要。

```
通常の GraphQL 実行:  全フィールドを計算 → レスポンス送信

@defer/@stream:       部分レスポンス送信 → 計算継続 → 次チャンク送信 → ...
```

Perl の PSGI には `psgi.streaming` があるため原理上は不可能ではないが、
この構造は**イベントループ上でのみ自然に実装できる**。
Mojo や AnyEvent ベースのサーバーなら実装可能だが、
従来の mod_perl / CGI / prefork PSGI 構成では構造的に不可能。

また Houtou の XS 実行エンジンは「全フィールドを計算して返す」前提で書かれており、
部分送信のための中断・再開機構が XS レベルにないため、対応には大規模な変更が必要。

#### 高並行 WebSocket Subscription

graphql-perl の `GraphQL::AsyncIterator` は**協調的な疑似非同期**（promise queue による
同期シミュレーション）として実装されており、真の非同期 I/O ではない。

```perl
# AsyncIterator の本質 - 同期的なキュー操作
if (my $next_promise = $self->_next_promise) {
    $next_promise->$method(ref $data eq 'ARRAY' ? @$data : $data);
```

Node.js のイベントループが真に非同期なのに対し、Perl では「イベントループを手動で回す」モデルになる。
高並行時の比較:

| 環境 | 同時接続の処理モデル |
|------|-------------------|
| Node.js | 1プロセスで数万接続（真の非同期 I/O） |
| Perl + Mojo / AnyEvent | 1プロセスで数百〜数千（可能だが非自然） |
| Perl + prefork PSGI | 接続数 = プロセス数（非現実的） |

#### XS グローバル状態のスレッド非安全性

`Promise::Adapter.pm` のプロセスグローバル変数:

```perl
my $DEFAULT_PROMISE_CODE;    # プロセスグローバル
my $HAS_XS_PROMISE_HELPERS;  # プロセスグローバル
```

Perl の `ithreads` 下では各スレッドがこれをコピーするが、
`schema_compiler.h` などの XS 側の C レベルキャッシュは `CLONE` サポートなしに共有されてしまう。
**Perl ithreads + XS の組み合わせは実質使えない**。

### 9.2 実装可能だがパフォーマンスが出にくい

#### DataLoader パターン（N+1 対策）

Federation の `_entities` や Relay の `node()` を実装すると N+1 問題が顕在化する。

Node.js の DataLoader が高効率なのは、**イベントループの1 tick** でリクエストを
自動バッチ化できるから:

```
[JS]   tick 内の全 resolver が蓄積 → 次の tick でまとめて DB query
[Perl] resolver が呼ばれるたびに即時実行 → バッチ化のタイミングが自然に作れない
```

Perl での DataLoader 相当を実装するには「明示的なバッチ収集フェーズ」を
API として設計する必要があり、ユーザー側の負担が増える。

#### 非同期キャッシュ I/O（APQ 等）

APQ 自体（SHA-256 計算 + キャッシュ）は Perl で問題なく実装できる。
ただしキャッシュバックエンド（Redis / Memcached）を非同期にしようとすると
上記と同じイベントループ依存の問題にぶつかる。
同期 I/O で許容できる場合は問題ない。

### 9.3 素直に実装可能

以下は Perl / XS で問題なく実装できる:

| 機能 | 理由 |
|------|------|
| `buildSchema` / `printSchema` | AST 操作のみ。XS パーサーが活用できる |
| Query Complexity / Depth Limiting | AST トラバーサル。XS 化も容易 |
| Persisted Queries（同期版） | ハッシュ計算 + ルックアップ |
| Federation `_service { sdl }` | SDL 文字列を返すのみ |
| Federation `_entities`（同期版） | 通常の resolver と同じ構造 |
| Modern Introspection | 既存 introspection の拡張で対応可能 |
| `@oneOf` バリデーション | バリデーションルールの追加のみ |
| Mutation serial execution | PP 側の実装追加で対応可能 |
| Relay Connection 型 | スキーマ定義の話。実行エンジンは無関係 |

### 9.4 サーバーアーキテクチャ別の現実的な方針

```
Mojo / AnyEvent / IO::Async ベース
  → @defer/@stream も将来的に射程圏
  → WebSocket subscription もスケール可能
  → ただし XS との統合設計が必要

prefork PSGI（Starman 等）/ mod_perl ベース
  → ストリーミング系（@defer/@stream、WebSocket）は切り捨て
  → 同期で動く機能群に絞るのが現実的:
      SDL toolchain / Federation subgraph 最低限 /
      Complexity 制限 / Modern Introspection / @oneOf
```

---

## 関連文書

- `docs/compatibility-roadmap.md` — graphql-perl 互換の開発ロードマップ
- `docs/validation-status.md` — validation ルールの実装状況詳細
- `docs/project-status.md` — 現在の実装状況の概要
