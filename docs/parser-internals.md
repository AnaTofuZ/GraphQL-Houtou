# Parser Internals

## 目的

この文書は、2026-04-05 時点の `GraphQL-Houtou` の parser 内部実装を、
最適化検討の前提として読める形で整理したものである。

特に次の観点を明示する。

- どの API がどの内部経路を通るか
- `SV` / `HV` / `AV` をどこで使っているか
- 独自構造体をどこまで導入済みか
- `loc` / `location` をどこで計算しているか
- 今後、独自構造体化の効果が出やすい層はどこか

活動記録と benchmark の最新値は `docs/current-context.md` を参照。
現行の公開 parser surface は `graphql-perl` 互換 AST に固定されており、
この文書に残っている `graphqljs_*` の記述は parser compatibility 層の内部実装メモとして読む。
runtime / VM mainline とは別物であり、現在の本命経路ではない。

## 全体像

現在の parser 実装は、大きく次の 3 経路に分かれる。

1. `graphql-perl` dialect を XS で直接 parse する経路
2. `graphql-js` dialect の executable document を
   `source -> IR -> graphql-js AST` で処理する経路
3. `graphql-js` dialect の SDL / 非 executable document を
   いったん legacy AST に落としてから graphql-js AST へ変換する経路

重要なのは、内部実装がすでに一枚岩ではないことである。

- executable な `graphql-js` 互換経路は、過渡データを独自 IR へ寄せている
- それ以外の compatibility 経路は、今も `SV` / `HV` / `AV` を直接組み立てる比率が高い
- 公開 API の返り値は、現状どの経路でも Perl のネイティブデータ構造である

ここでいう `graphqljs_*` は public dialect ではなく、parser compatibility を支える
内部ヘッダ名である。

つまり、「全部 `SV` ベース」ではないが、「全部が独自構造体化済み」でもない。

## 公開 API から見た内部経路

### `graphql-perl` dialect

`parse_xs()` は `gql_parse_document()` を呼び、XS 側でそのまま legacy AST を組み立てる。

この経路では、各 node はその場で `HV` / `AV` / `SV` として生成される。
たとえば field, selection set, variable definitions などは
直接 `newHV()`, `newAV()`, `newSV*()` を使って materialize される。

### `graphql-js` dialect, executable

`graphqljs_parse_document_xs()` は入力が executable らしいと判定すると、
`graphqljs_parse_executable_document_xs()` へ振り分ける。

この経路では、

1. token を読みながら独自 IR を parse
2. IR ノードは arena 上に確保
3. その IR から graphql-js 風 AST を XS で build
4. 必要なら `loc` も build 時に付与

という流れになる。

この経路が、現状もっとも「独自構造体寄り」の実装である。

### `graphql-js` dialect, SDL / 非 executable

SDL や非 executable document では、いったん前処理で rewrite / metadata 抽出を行い、
その rewritten source を legacy parser に通したあと、graphql-js AST へ変換する。

流れとしては次の通り。

1. preprocess
2. legacy AST を XS parser で構築
3. legacy AST から graphql-js AST へ変換
4. metadata patch を適用
5. 必要なら `loc` を補完

この経路は executable 経路と比べると、`SV` ベースの中間表現が多い。

## コア lexer / parser 状態

低レベル parser の基本状態は `gql_parser_t` に入っている。

主な責務:

- source buffer 参照
- 現在位置と直前 token 位置の保持
- token kind / token span / value span の保持
- UTF-8 フラグの保持
- `no_location` 判定
- `line_starts` テーブルの保持
- executable IR 用 arena 参照の保持

この構造体自体は軽量な「走査状態」であり、AST そのものではない。

`line_starts` は parser 初期化時に source 全体を一度走査して構築され、
`location` / `loc` 計算に使われる。
最近の修正で、これは save-stack cleanup により `croak` 時でも解放されるようになっている。

## legacy AST 直組み経路

`graphql-perl` 用の XS parser は、recursive descent しながらその場で
legacy AST を Perl データ構造として作る。

典型的には次のような形で node を作る。

- object node: `HV`
- list node: `AV`
- scalar payload: `SV`

具体例:

- directive は `HV { name, arguments? }`
- selection set は `HV { selections => AV[...] }`
- field は `HV { kind, name, alias?, arguments?, directives?, selections?, location? }`
- operation は `HV { kind, operationType?, name?, variables?, directives?, selections, location? }`

この経路の特徴は次の通り。

- parse 中に最終 AST 形状まで一気に作る
- 後段 builder が不要
- 互換 AST を最短距離で返せる
- その代わり parse 中の allocation 数は多くなりやすい

現状の benchmark では、この「legacy AST を直接組む XS 経路」が依然として最速である。
これは、追加の変換段がないことの効果が大きいと考えてよい。

## executable 用 IR 経路

### 目的

`graphql-js` executable path では、legacy AST を経由せず、
専用 IR を parse してから graphql-js AST を build する。

これは次の問題を避けるために導入された。

- legacy AST を一度作ってから graphql-js AST へ変換する二重構築コスト
- `loc` を後段で再走査して付けるコスト
- 大量の小さな Perl object を parse の途中段階で持つコスト

### IR の構造

IR には専用の C 構造体がある。

- `gql_ir_type`
- `gql_ir_value`
- `gql_ir_argument`
- `gql_ir_directive`
- `gql_ir_object_field`
- `gql_ir_variable_definition`
- `gql_ir_field`
- `gql_ir_fragment_spread`
- `gql_ir_inline_fragment`
- `gql_ir_selection`
- `gql_ir_selection_set`
- `gql_ir_operation_definition`
- `gql_ir_fragment_definition`
- `gql_ir_definition`
- `gql_ir_document`

各 node は kind と `start_pos` を持ち、必要に応じて `name_pos` なども持つ。
これにより、builder 段階で `loc` を付けられる。

### arena allocator

IR ノード本体は chunk arena 上に確保される。

設計の意図:

- node ごとの `malloc` 相当を避ける
- parse 成功後の解放を document 単位でまとめる
- 失敗時 cleanup を単純化する

arena は固定長 chunk を繋いだ構造で、足りなくなったらより大きい chunk を追加する。
document 単位の破棄時に chunk をまとめて解放する。

### 可変長配列

IR の children は `gql_ir_ptr_array_t` で保持される。

用途:

- arguments
- directives
- list value items
- object value fields
- selections
- definitions

ここは Perl の `AV` ではなく、単純な `void **` ベースの伸長配列である。

### ただし IR でもまだ `SV` は残っている

IR が完全に `SV` フリーというわけではない。
たとえば次は現在も `SV *` を持つ。

- type 名
- argument 名
- object field 名
- enum / int / float / string などの payload
- field 名 / alias
- fragment 名

つまり現状の executable IR は、

- node の骨格と入れ子構造は独自構造体
- 文字列 payload や一部 scalar は `SV`

という折衷設計である。

このため、「独自構造体化」はすでに始まっているが、まだ完全ではない。

## IR から graphql-js AST を build する経路

IR parse 後は、専用 builder が graphql-js 風 AST を `HV` / `AV` として構築する。

主な builder:

- type builder
- value builder
- arguments builder
- directives builder
- selection builder
- selection set builder
- variable definitions builder
- executable definition builder
- document builder

ここで初めて最終返り値としての Perl AST が materialize される。

この段階の特徴:

- executable path の最終 AST は Perl ネイティブ構造で返る
- ただし parse 中は legacy AST を経由しない
- `loc` を build 時に直接付けられる

## SDL / 非 executable の graphql-js 経路

こちらは executable path ほど整理されていない。

現状は次のような段階的変換になる。

1. source を前処理し、rewrite と metadata を得る
2. rewritten source を legacy parser に通す
3. legacy AST を graphql-js AST に変換する
4. extension や variable directives などの metadata を patch する
5. `loc` を補完する

この経路の意味は次の通り。

- grammar 差分や metadata 差分への実装コストを抑えやすい
- ただし表現を複数回組み替えるので、allocation 的には重い
- executable path ほど独自構造体化されていない

最適化観点では、この経路はまだ「legacy AST を中間表現として使っている」比率が高い。

## `location` と `loc`

### graphql-perl dialect

legacy AST では `location => { line, column }` を保持する。

これは parse 中の token 位置と `line_starts` を使って XS 側で計算される。

### graphql-js dialect

graphql-js AST では `loc` を保持する。

executable path では、IR node の `start_pos` と `name_pos` をもとに、
AST build 時に直接 `loc` を付与できる。

さらに `lazy_location` や `compact_location` のモードがあり、
用途に応じて `loc` の表現コストを下げられる。

一方、非 executable path では rewrite と metadata patch があるため、
`loc` 処理は executable path より複雑である。

## `SV` / `HV` / `AV` の使われ方の整理

### すでに独自構造体化されている層

- executable document の IR node 骨格
- executable document の child list 管理
- executable document の node allocation

### まだ Perl object が中心の層

- legacy `graphql-perl` AST そのもの
- SDL / 非 executable の中間 legacy AST
- graphql-js AST の最終返り値
- token 列の返却値
- error object

### 折衷になっている層

- executable IR の文字列 payload
- executable IR の名前文字列
- executable IR の数値 / enum / string 値

## メモリ効率の観点から見た現在地

### すでに改善済みの点

- executable path の node 骨格は arena 化済み
- executable path は legacy AST の二重構築を避ける
- `loc` は build 後の別 traversal ではなく build 時に付与できる

### まだ `SV` 起因のコストが残る点

- IR 内の name / scalar payload が `SV *`
- SDL / 非 executable path は legacy AST を中間表現として持つ
- 最終返り値 AST は互換性のため Perl object のまま

### AST まで独自構造体化しない理由

現状の distribution は、公開 API と互換レイヤが
Perl の `HASH` / `ARRAY` 返却を前提にしている。

そのため AST まで独自構造体化しても、最終的にはどこかで
`SV` / `HV` / `AV` へ materialize する必要がある。

この場合、

- 実装複雑性
- 保守コスト
- 変換段の追加

に対して、常に十分な利益が出るとは限らない。

特に `graphql-perl + xs` のような最短経路は、
「直接最終 AST を組む」こと自体が速さの理由でもある。

## 最適化余地が大きい層

現状、独自構造体化の余地がもっとも大きいのは次の層である。

1. executable IR 内の `SV *` payload
2. SDL / 非 executable path の中間表現
3. `loc` 付与に必要な位置情報の持ち方

逆に、最初から大規模に着手すると割に合いにくいのは次の層である。

1. 公開返り値 AST 全体の独自構造体化
2. Perl 互換 API を壊すような表現変更
3. profiler を見ずに legacy path を全面書き換えすること

## 実務的な読み替え

現在の内部実装は、次のように理解するとよい。

- parser の走査状態は軽量な C 構造体
- executable path の中間 node は専用 IR 構造体
- ただし文字列 payload はまだかなり `SV`
- 非 executable path はまだ Perl object 中心
- 最終返り値は互換性のため Perl AST

したがって、

- 「独自構造体に寄せる」という方針自体は正しい
- ただし適用対象はまず IR 層と過渡表現である
- 最終 AST まで一気に独自構造体化するのは別の判断になる

## いま見るべき具体ポイント

独自構造体化の妥当性をさらに詰めるなら、次の順で見るのがよい。

1. executable IR 内の `SV *name` / `SV *payload` を span 化できるか
2. SDL path を legacy AST 経由なしで build できる範囲はどこか
3. benchmark と NYTProf で、本当に `SV` allocation が支配的か
4. `graphql-perl + xs` の速さを崩さずに共通化できる境界はどこか

この順に見れば、「全部を構造体化するべきか」という大雑把な議論ではなく、
どの層に投資すると実際に効くかを切り分けられる。
