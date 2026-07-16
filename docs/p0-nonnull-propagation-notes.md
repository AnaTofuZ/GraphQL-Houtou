# P0-2: Non-Null 伝播の実装メモ (2026-07-16, feature/p0-spec-conformance)

作業中の設計メモ。完了後は削除するか実装ドキュメントに昇格する。

## 仕様 (spec 6.4.4)

- Non-Null 位置のフィールドが null に完了した(resolver が null を返した /
  field error で null 化された)場合、**field error を記録し、親の
  オブジェクト/リスト位置へ null を伝播**する
- 伝播は nullable な位置に達するまで続く(全部 Non-Null なら data 自体が null)
- resolver 由来の field error が既にあるときは新しいエラーを足さない。
  「resolver が素で null を返した」ときだけ
  `Cannot return null for non-nullable field Parent.field.` を足す
- リスト: `[T!]` は null 項目でリスト全体が null 化(その位置からさらに
  外へ伝播判定)。`[T]!` はリスト自体が null 不可。`[T!]!` は両方

## 現状

- lowering(SchemaGraph の `_completion_family_for_type` 等)は NonNull
  ラッパーを**完全に剥がして捨てる**。slot/op に nullability の情報なし
- 4 実行系: async(frame/outcome)、fast SV(execute_block_fast_sv、
  bundle も同じ実行器)、fast JSON(文字列直書き)、+ legacy sync_now は
  削除済み

## 実装計画

### (a) Lowering: slot に 2 フラグ

- `non_null`(最外が NonNull)と `item_non_null`(LIST の項目型が NonNull。
  `[[Int!]!]` の多重は当面「最外リストの直下」だけ扱い、多重リストの
  中間 null 伝播は既知の制限として記録)
- 触る場所:
  - SchemaGraph のフィールド slot 構築部(completion_family を決めている
    場所)に `_nullability_for_type($type)` を追加
  - `Runtime/Slot.pm`: new / accessor / to_struct(full と compact 両方)
  - XS `gql_runtime_vm_parse_native_slot`: slot hv から読む(full 形式)。
    compact 形式のパーサがあれば配列 index 追加に注意(descriptor
    round-trip テスト t/07/t/14/t/22 を要確認)
  - OperationCompiler が op に slot 情報を写す場合はそちらも

### (b) fast SV レーン(bundle も同経路)

- `execute_block_fast_sv` が「伝播 null」を通知する必要がある。
  返り値 NULL = 「このブロックは non-null 違反で null 化された」の
  センチネルにする(現在 NULL を返す経路はない、要確認)
- フィールド消費側(execute_block_fast_sv のループ):
  - completed が undef 相当 && slot->non_null →
    - 直前にそのフィールドの field error を記録済みならそのまま、
      未記録なら "Cannot return null for non-nullable field %s.%s." を記録
      (block の type_name + slot->field_name)
  - → 自ブロックを即 null 化: data_hv を破棄して NULL を返す(残りの
    sibling op は実行しない: graphql-js も propagation 後は打ち切る…
    正確には並列だが sync 実行では打ち切りで可)
- object/abstract completion: child block が NULL を返したら undef を返す
  (呼び出し元のフィールドループが non_null 判定)
- リスト completion: 項目が undef && slot->item_non_null → エラー記録
  (index 付き path)+ リスト全体を undef に(残項目打ち切り)。
  リスト undef はフィールドループの non_null 判定へ

### (c) fast JSON レーン

- 文字列バッファに直書きしているので「親に戻って null に書き換え」が必要
- 方法: 各フィールド値の書き出し前に `STRLEN start = SvCUR(out)` を取り、
  子から伝播シグナル(int 返り値 or state のフラグ)を受けたら
  `SvCUR_set(out, field_start)` で切り戻して "null" を書く。
  ブロック単位: execute_block_fast_json も「{...} を書いたが伝播で null に
  なる」場合に呼び出し元が切り戻すため、開始 offset は呼び出し元が持つ
- シグナルは返り値 int(0=ok, 1=nulled-and-must-propagate)が明快。
  各 call site の書き換えが必要(execute_child_block_fast_json /
  execute_block_fast_json / list 経路)

### 進捗 (2026-07-16 時点)

- (a) 完了: slot に `return_type_kind_code == 8`(既存)と `item_non_null`
  (新設、compact index 13 / hv "item_non_null")。SchemaGraph
  `_item_non_null_for_type` で lowering
- (b) 完了: fast SV。`execute_block_fast_sv` が NULL 返却=伝播、
  `state->null_carries_error`(exec_state_t 新設)でエラー重複防止。
  リストは item_non_null で全体 null 化。全プローブ仕様一致
- (c) 完了: fast JSON。`execute_block_fast_json` / `child` / `list` が
  int 返却(1=伝播)。block/list/value の開始 offset を取り
  `SvCUR_set` で切り戻し。「値領域が 'null' 4 バイト」で null 判定。
  トップレベルは data:null。プローブで SV レーンと一致
- (d) 未着手 ← 次はここ
- (e) t/50 は sync 分から書く

### (d) async レーン

- 同期完了分: complete_current_native_async_sv 内で object/list の
  child outcome を見て non_null 判定 → error outcome 化(親 frame の
  値消費時に outcome → 伝播)
- 非同期完了分(frame resolve 時):
  - `consume_value_native_object` / `consume_outcome_native_object` の
    格納時に「undef && non_null」を検出する必要があるが、entry は
    slot_index を持っている(RESOLVED_VALUE_SV 系)/ GENERIC 系は
    P0-3 で leaf は RESOLVED 化済み。OBJECT/LIST の pending
    (BLOCK_FRAME_PTR / LIST_PENDING_PTR)は frame resolve 側
  - frame が null 化で resolve される表現: outcome KIND_SCALAR undef +
    non-null マーカー? 親 frame の値格納時に self の non_null 判定を
    できるよう、block_frame に「自分は non-null 位置」フラグと
    親 entry への伝播経路を追加
  - response frame(root)まで伝播したら data => null
- ここが最大の工数。frame 機構(pending merge、list_pending)を
  全経路確認すること(xs-coding-rules.md 5〜7 の不変条件に注意)

### (e) テスト

- t/50_nonnull_propagation.t: t/44 方式で全 6 エントリポイント ×
  形状(String! null / Obj! null / [T!] 項目 null / [T]! null /
  ネスト伝播 / 全 Non-Null チェーンで data null / エラー重複なし /
  resolver エラー起点の伝播)
- graphql-js の nonnull テストケース相当を参照

## 進め方

(a)→(b)→(e の sync 分)→(c)→(d)→(e 全部)。各段階でビルド+
minil test。段階間でレーン挙動が割れるのは作業中のみ許容し、
コミットは全レーン揃ってから 1 つにする(レーンパリティルール)。
