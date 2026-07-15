# リリース準備状況の評価 (2026-07-15)

「リリース」= プロダクションで実務が可能、の定義で残作業を棚卸しした
結果。既存ロードマップ(docs/product-roadmap.md)との差分は、**実挙動の
プローブで確認した仕様適合ギャップ**が中心。各項目は最小スキーマに対する
実行結果を根拠にしている。

## 結論(サマリ)

性能と足回り(ASan CI / soak / レーンパリティ / DataLoader / PSGI)は
実務水準に達している。**ブロッカーは仕様適合の 4 点**で、いずれも
「不正な入力・不正な resolver 出力のときに間違った応答を返す」類。
正常系だけ動けばよい内部ツールなら現状でも使えるが、公開 API サーバと
しては 4 点の解消が必要。

## P0: リリースブロッカー(仕様適合)

### 1. クエリ validation が実行パスに未結線

- **実測**: `{ nope }`(未知フィールド)→ `{data:{},errors:[]}` で成功扱い。
  必須引数欠落 `{ hello }`(name: String! 必須)→ `hello: "hi "` で素通し。
- **一方で** `GraphQL::Houtou::Validation::validate($schema, $doc)` を
  手で呼ぶと両方とも正しくエラーを返す(XS 実装 14 ルールは健在)。
  つまり実装済みの validation が `execute_document` / PSGI から
  呼ばれていないだけ。
- **やること**: compile 前に validate を 1 回実行し、エラーがあれば
  data なし envelope(HTTP では 400)を返す。program cache ヒット時は
  スキップ(検証済みの document だけが cache に入る設計にする)。
  ベンチゲートで結線後の cold-path 退行を計測。

### 2. Non-Null 伝播が未実装

- **実測**: `req: String!` の resolver が undef →
  `{data:{inner:{req:null}}, errors:[]}`。仕様では field error +
  親オブジェクトの null 化(伝播)+ errors 記録。
- 4 実行レーン(async / fast SV / fast JSON / bundle)全てに欠けている。
  リスト内の non-null 項目 `[T!]` の伝播も同様。
- **やること**: slot に non-null フラグを lower し、completion の
  null 化時に親へ伝播するセマンティクスを全レーンに実装。
  t/44 のレーンパリティバッテリに non-null ケース群を追加して固定。
  実装コストは P0 の中で最大(async の bubble-up が pending/frame
  機構と交差する)。

### 3. 結果コアーション(serialize)未実施

- **実測**: `Int` フィールドが `"abc"` を返すと `"abc"` のまま応答。
  `String` が数値 12345 を返すと JSON 数値のまま。Enum は非メンバー値
  (`'ANGRY'`)を素通し。カスタムスカラーの `serialize` フックは型に
  定義できるが実行系から呼ばれない(XS 内の参照ゼロ)。
- **やること**: leaf completion で組み込みスカラーの型チェック
  (Int: 32bit 整数、Float: 数値、String/ID: 文字列化、Boolean: 真偽)、
  Enum のメンバー検証、カスタムスカラーの serialize 呼び出し。
  違反は field error + null(non-null なら 2. の伝播)。
  hot path なので組み込みスカラーは XS 内で完結させ、カスタム
  serialize だけコールバックにする。ベンチゲート必須。

### 4. リクエストエラーの envelope 化と error 形状

- **実測**: parse エラー・variable コアーションエラー
  (`String! given null value.` / `Not a String.`)は `die` で例外に
  なる。Pegex の内部形式(`Error parsing Pegex document: msg: ...`)が
  そのまま利用者に露出する。
- error entry に `locations` が無い(`message` / `path` のみ)。
  GraphQL over HTTP を話すクライアント(Apollo 等)は locations を
  期待する。`extensions` の受け皿も未対応。
- **やること**: `execute_document` 系はリクエストエラーを
  `{ errors => [...] }`(data キーなし)で返す。parse エラーの
  メッセージを spec 風(`Syntax Error: ...` + line/column)に整形。
  エラーレコードに locations を追加(parser の location は既にある)。
  resolver die のオブジェクト(GraphQL::Houtou::Error)から
  extensions を引き継ぐ。

## P1: リリース前に入れるべき(堅牢性・運用)

### 5. 悪意ある入力への上限

- depth limit(既定 15)はあるが:
  - **alias flooding**(横方向の爆発 `{a:f b:f c:f ...}` × ネスト)に
    上限がない → クエリ複雑度 or 最大ノード数上限を追加
  - **PSGI のリクエストボディサイズ上限がない**(CONTENT_LENGTH を
    信じて全部読む)→ max_body_size(既定 1MB 程度)
  - パーサのトークン数上限がない(graphql-js の maxTokens 相当)
- fragment 爆発は validation の cycle 検出があるので結線(P0-1)で
  ほぼ塞がる。

### 6. パーサの敵対的入力テスト(fuzz スモーク)

- パーサは C 実装で、公開サーバでは信頼できない入力に直接晒される。
  クラッシュ = ワーカープロセス死。
- フル AFL でなくてよいが、最低限:
  - 既存 fixture(kitchen-sink 等)のランダム変異(切詰め・バイト
    反転・重複挿入)を ASan ビルドに数万件流すスモークを util/ に追加
  - 不正 UTF-8、NUL 埋め込み、深い括弧ネスト、巨大数値リテラルの
    定型ケースを t/ に固定
- CI の robustness.yml(ASan)に組み込めば継続的に回る。

### 7. パッケージング / ドキュメント

- `Changes` が初期テンプレのまま → 0.01 の変更履歴を書く
- 公開 API の POD 棚卸し(execute_document の全オプション、on_stall
  契約、PSGI、DataLoader、エラー形状)— 「エラーがどう返るか」は
  P0-4 確定後に書く
- cpanfile: runtime 依存は妥当(JSON::MaybeXS / Promise::XS /
  Role::Tiny)。Promise::XS を optional(suggests)にするか判断
  (sync-only 利用者に XS 依存を強制するか)
- min perl 5.24 × CI 5.24〜5.42 は十分。macOS CI の追加を検討
  (開発は darwin、CI は Linux のみ)

## P2: リリース直後でよい

- **APQ**(W2、SHA-256 persisted queries)— 基盤は persisted bundle で
  実装済み、結線のみ
- **性能 L3/L4**(async 60.5k/s → 80k/s 目標、幅優先ハイブリッド)—
  graphql-perl 比 ~12x で実務上は既に十分。P0-2/3 の結線でどれだけ
  下がるかを見てから再開
- **Query complexity の本格版**(コスト重み付け)— P1-5 の素朴な
  上限で当面は足りる
- `@defer` / `@stream`、Subscription トランスポート、Federation —
  従来どおりスコープ外(docs/first-release-roadmap.md の判断を維持)

## 実務可否の判断基準(受け入れテスト)

リリース判定は「以下が全部グリーン」で行う:

1. graphql-js の execution テスト相当ケース(Star Wars / t/40 は導入
   済み)+ non-null 伝播ケース群が全レーンで一致(t/44 方式)
2. 不正クエリ 20 種(未知フィールド、型不一致、必須引数欠落、
   variable 欠落/型違い、構文エラー)が全て spec 形状のエラー envelope
   を返し、プロセスが死なない
3. 不正 resolver 出力 10 種(型違い leaf、非配列 list、解決不能
   abstract、non-null null)が全レーンで同一応答
4. ASan + シード掃引 + fuzz スモーク + 24h 相当 soak が CI でグリーン
5. PSGI 経由の GraphQL over HTTP 準拠(400/405/415、content-type、
   ボディ上限)を Plack::Test で固定

## 参考: 今回のプローブに使った再現コード

スクラッチパッドの `prod-probe.pl` / `lane-audit.pl` 相当。要点だけ:

```perl
# validation 未結線: errors が空のまま成功
$rt->execute_document('{ nope }');           # {data=>{},errors=>[]}
# non-null 伝播なし: req は String! なのに null + エラーなし
$rt->execute_document('{ inner { req } }');  # {data=>{inner=>{req=>undef}},errors=>[]}
# 結果コアーションなし: Int が文字列を素通し
$rt->execute_document_to_json('{ num }');    # {"data":{"num":"abc"},...}
```
