# GraphQL Compatibility Roadmap

## 目的

この文書は、`GraphQL::Houtou` が CPAN の `GraphQL` distribution
と高い互換性を維持しつつ XS 実装へ寄せていくために、
何を開発対象とするべきかを整理したものである。

特に次の 2 点を分けて扱う。

- `graphql-perl` 互換として最低限必要な機能面
- 現行 `graphql-perl` 自体が GraphQL 仕様や `graphql-js` と比べて弱い点

ここでいう「互換」は parser 互換だけではない。
公開 API、型定義 API、schema 構築、execution、subscription、
introspection、error 形式まで含む。

## 前提

`GraphQL::Houtou` の現状の中心は parser と AST adapter である。

- `GraphQL::Houtou` の公開 facade は `parse` / `parse_with_options` を提供する
- `graphql-perl` 互換 AST と `graphql-js` 風 AST の両方を扱う
- executable な `graphql-js` path は `source -> IR -> graphql-js AST` の XS 中心経路である

参照:

- `lib/GraphQL/Houtou.pm`
- `docs/project-status.md`
- `docs/parser-internals.md`

一方、互換ターゲットである `graphql-perl` 側は parser だけではなく、
次の表面積を持つ。

- `GraphQL::Schema`
- `GraphQL::Execution::execute`
- `GraphQL::Subscription::subscribe`
- `GraphQL::Type::*`
- `GraphQL::Directive`
- `GraphQL::Introspection`
- `GraphQL::Plugin::Type`
- `GraphQL::Plugin::Convert`

参照:

- `../graphql-perl/lib/GraphQL.pm`
- `../graphql-perl/lib/GraphQL/Schema.pm`
- `../graphql-perl/lib/GraphQL/Execution.pm`
- `../graphql-perl/lib/GraphQL/Subscription.pm`
- `../graphql-perl/lib/GraphQL/Type.pm`
- `../graphql-perl/lib/GraphQL/Directive.pm`
- `../graphql-perl/lib/GraphQL/Introspection.pm`

## 互換達成のために必要な主要開発項目

### 1. schema compiler

最重要なのは、Perl 側の `GraphQL::Schema` / `GraphQL::Type::*` /
`GraphQL::Directive` を、実行向けの XS 内部表現へ compile する層である。

理由:

- ユーザー API は `Type::Tiny` と `Moo` を使う既存インターフェースのまま維持したい
- しかし execution 時に毎回 Perl object を深く辿るのは遅い
- parser と同様、runtime では compact な独自構造体へ寄せたほうがよい

望ましい形は次である。

- public API は今の `GraphQL::Type::*->new(...)` を維持
- `GraphQL::Schema` は Perl object として残す
- 初回実行時にだけ XS schema IR を構築して cache
- resolver / subscribe / scalar coercion だけ Perl callback に戻す

これは parser で採った
「公開 AST は Perl ネイティブのまま、内部は独自構造体を使う」
という方針と整合する。

### 2. validation engine

`graphql-perl` には `GraphQL::Validation` という名前のモジュールがあるが、
現状は実質スタブであり、execution からも使われていない。

参照:

- `../graphql-perl/lib/GraphQL/Validation.pm`
- `../graphql-perl/lib/GraphQL/Execution.pm`

したがって Houtou 側で互換を満たすには、
validator を実装する必要がある。

初期実装で優先すべき rule は次の通り。

- operation type existence
- operation name uniqueness
- lone anonymous operation
- subscription single root field
- field existence
- argument existence / uniqueness / required arguments
- variable uniqueness
- variables are input types
- all variable uses defined
- fragment target existence
- fragment cycle detection
- directives are defined
- directives are in valid locations
- directives are unique per location
- input object field names / uniqueness / required fields

validator は public API としても重要だが、
execution を安全に XS 化するための前提にもなる。

### 3. execution engine

`execute` の互換は parser 互換とは別問題である。

現行 `graphql-perl` の `execute` は、

- operation 選択
- variable default 適用
- field collection
- resolver 実行
- completion
- error 整形

を Perl で行う。

参照:

- `../graphql-perl/lib/GraphQL/Execution.pm`
- `../graphql-perl/lib/GraphQL/Type/Object.pm`
- `../graphql-perl/lib/GraphQL/Role/Abstract.pm`

Houtou で高速化を狙うなら、
次を XS 側へ移すのが本筋である。

- selection set の field collection
- argument coercion
- completion
- null propagation
- path / location を含む error 組み立て

一方で次は Perl callback のまま残すのが自然である。

- field resolver
- subscribe resolver
- custom scalar の serialize / parse_value
- custom abstract type resolution

### 4. subscription engine

`graphql-perl` は subscription を public feature として持っている。

参照:

- `../graphql-perl/lib/GraphQL.pm`
- `../graphql-perl/lib/GraphQL/Subscription.pm`
- `../graphql-perl/lib/GraphQL/PubSub.pm`
- `../graphql-perl/t/subscribe.t`

したがって Houtou 側でも、少なくとも次を互換対象に入れる必要がある。

- `subscribe(...)` と同じ引数形
- `PromiseCode` 互換
- `AsyncIterator` 前提の source stream
- event ごとの execution
- GraphQL error の response 化

subscription は query/mutation より利用者は少ないが、
互換性という観点では切り捨てにくい。

### 5. introspection 実装

`graphql-perl` は独自の introspection object 群を持つ。

参照:

- `../graphql-perl/lib/GraphQL/Introspection.pm`
- `../graphql-perl/t/type-introspection.t`

ただし現行実装は旧仕様寄りであり、
Houtou 側で手を入れるなら parser 互換よりむしろ
ここを現行 spec に寄せる価値が高い。

最終的には、schema compiler が作った XS schema IR から
introspection response を直接生成できるようにするのが望ましい。

### 6. plugin / type registration 互換

`graphql-perl` には user 拡張の入口がある。

- `GraphQL::Plugin::Type`
- `GraphQL::Plugin::Convert`

参照:

- `../graphql-perl/lib/GraphQL/Plugin/Type.pm`
- `../graphql-perl/lib/GraphQL/Plugin/Convert.pm`

これらは速度面の主戦場ではないが、
既存利用者の移行コストに強く効く。

特に `GraphQL::Plugin::Type` は custom scalar の登録口として重要であり、
schema compiler 側が registered type を自然に取り込める必要がある。

## 現行 graphql-perl 側の未対応・弱い点

ここでは「Houtou が埋めるべき互換 surface」と、
「そもそも upstream 側が弱いところ」を分けて整理する。

### validation が未実装

`GraphQL::Validation` はスタブである。

参照:

- `../graphql-perl/lib/GraphQL/Validation.pm`

これは仕様追従の観点で最大の不足であり、
Houtou 側で validator を持つ理由にもなる。

### mutation の serial execution が未実装

`_execute_fields_serially` は TODO のままで、
実装上は通常の field execution 経路へ流れている。

参照:

- `../graphql-perl/lib/GraphQL/Execution.pm`

したがって現行 upstream は、
mutation の順序保証という spec 上重要な点で弱い。

### interface 実装整合性チェックが未実装

`GraphQL::Schema` には
`assert_object_implements_interface` の TODO が残っている。

参照:

- `../graphql-perl/lib/GraphQL/Schema.pm`

これは schema validation / build-time validation に属する不足である。

### introspection が旧仕様寄り

現行 `graphql-perl` の introspection は、
古い GraphQL 仕様に基づく設計が残っている。

不足または弱い点:

- `__Directive.isRepeatable`
- `__Type.specifiedByURL`
- `__Type.isOneOf`
- `__Field.args(includeDeprecated:)`
- `__Directive.args(includeDeprecated:)`
- `__Type.inputFields(includeDeprecated:)`
- `__InputValue.isDeprecated`
- `__InputValue.deprecationReason`

参照:

- `../graphql-perl/lib/GraphQL/Introspection.pm`
- `../graphql-perl/t/type-introspection.t`

### built-in directive / directive location が古い

現行 `GraphQL::Directive` は location 一覧が古く、
`VARIABLE_DEFINITION` を持たない。
また built-in directive も
`@skip` / `@include` / `@deprecated` のみである。

参照:

- `../graphql-perl/lib/GraphQL/Directive.pm`

したがって、少なくとも modern SDL/introspection 互換を目指すなら、
ここは Houtou 側で拡張する必要がある。

### OneOf input object 未対応

`GraphQL::Type::InputObject` は通常の input object としてしか振る舞わず、
OneOf 用の

- exactly one field
- member value must be non-null
- extension 上の制約

を持たない。

参照:

- `../graphql-perl/lib/GraphQL/Type/InputObject.pm`

### subscription 周辺の validation / cancellation が弱い

`subscribe` 自体は存在するが、
validator がないため事前検証が薄い。
また test には disconnection 対応の TODO が残っている。

参照:

- `../graphql-perl/lib/GraphQL/Subscription.pm`
- `../graphql-perl/t/subscribe.t`

### top-level extensions hook が薄い

`GraphQL::Error` には `extensions` があるが、
execution result 全体の `extensions` を構築する明確な public hook は見当たらない。

参照:

- `../graphql-perl/lib/GraphQL/Error.pm`
- `../graphql-perl/lib/GraphQL/Type/Library.pm`

## GraphQL::Houtou での実装方針

### 基本方針

API 互換と runtime 最適化を分離する。

- public API は Perl object / hash / array を維持
- hot path は compile 済み XS IR を使う
- Perl callback が必要な点だけ VM へ戻る

これは parser で採っている方針の execution 版である。

### schema compiler の設計

最低限必要な IR 情報:

- name -> type lookup
- root operation types
- abstract type -> possible types
- object -> interfaces
- field definition
- argument definition
- directive definition
- scalar coercion callback
- resolver / subscribe callback
- deprecation / description / default value metadata

設計上の要点:

- compile は schema 単位で一回
- schema object に cache をぶら下げる
- plugin registered type を compile 時に取り込む
- introspection metadata も同時に前計算する

### validator の設計

parser と同じく、
validator も node ごとの Perl object 巡回ではなく
IR / canonical AST を前提にした方がよい。

段階としては次がよい。

1. executable document validator
2. SDL validator
3. schema build-time validator

特に query execution の前段 validator は、
cache しやすいので XS 化との相性がよい。

### execution の設計

実行系は次の 3 層に分けるのがよい。

1. operation planning
2. field execution / completion
3. result / error assembly

このうち 1 と 2 の大部分は XS 化対象である。

Perl callback に戻す箇所:

- field `resolve`
- field `subscribe`
- scalar `serialize`
- scalar `parse_value`
- abstract `resolve_type`
- object `is_type_of`

### introspection の設計

現行 `graphql-perl` の introspection object 群をそのまま高速化するより、
schema IR を source of truth にして
introspection 用 node を生成する方が整理しやすい。

これにより次を同時に達成できる。

- upstream 互換 API の維持
- modern spec への追従
- old introspection 実装との差分吸収

### subscription の設計

subscription は query execution と別エンジンにせず、

- source stream の初期化
- 各 event に対する execute

の 2 段に切るべきである。

query/mutation と共通化できる部分:

- variable coercion
- field collection
- completion
- error shaping

別管理にすべき部分:

- source event stream
- iterator cancellation
- unsubscribe / disconnect

## 優先順位

実装順は次が妥当である。

1. schema compiler
2. executable validator
3. `execute(query)` fast path
4. mutation serial execution
5. modern introspection
6. `subscribe(...)` fast path
7. SDL validator / schema validator
8. plugin/convert 互換の強化

理由:

- parser はすでに Houtou 側の強みである
- 互換面で最大の穴は validation / execution である
- `GraphQL` distribution を置き換える説得力が出るのは execute 互換が入ってからである

## 短期の具体タスク

すぐ着手できるものは次の通り。

### A. 実行互換の要件固定

まず `graphql-perl` の test を棚卸しし、
どこまでを Houtou の execute 互換対象にするかを固定する。

対象候補:

- `t/execution-execute.t`
- `t/execution-abstract.t`
- `t/execution-directives.t`
- `t/type-introspection.t`
- `t/subscribe.t`
- `t/util-buildschema.t`

### B. schema IR の最小版

最初は次だけ持てればよい。

- query root
- object fields
- scalar types
- arguments
- resolver callback

これで query execution の最小 fast path を試せる。

### C. validator 最小版

最初は次だけで価値がある。

- operation selection
- field existence
- argument existence
- variable input type
- subscription single root field

### D. modern introspection の差分テスト化

upstream にない spec 差分を、
Houtou 側で独自 test として先に固定する。

候補:

- `isRepeatable`
- `specifiedByURL`
- `isOneOf`
- deprecated input field / argument introspection

## 補足

### parser 先行対応との関係

Houtou は parser 面では upstream より先に扱えているものがある。

例:

- repeatable directive definitions
- interface `implements`
- variable definition directives

一方で parser が先行しても、
schema / validation / execution が追いつかなければ
「GraphQL モジュール互換」とは言い切れない。

### 互換性を緩めない前提

この文書の前提は、
Type::Tiny を使った既存の型定義 API と
Perl レベルで扱いやすい public object/structure をなるべく維持することである。

したがって Houtou 側の最適化は、
public API を C struct に置き換える方向ではなく、
内部表現のみを compile / cache / lazy 化する方向で進めるべきである。
