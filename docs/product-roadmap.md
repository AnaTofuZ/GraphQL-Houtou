# GraphQL::Houtou 全体ロードマップ(2026-07-06 改訂)

`docs/first-release-roadmap.md`(機能面)と
`docs/performance-and-robustness-plan.md`(性能・堅牢性)を統合し、
以後の優先順位はこの文書を正とする。

## 前提の更新

実 Web アプリケーションの主役ユースケースは
**SQL バックエンド + DataLoader バッチング + Promise::XS 非同期 resolver**
である(2026-07-06 の方針転換)。従来プランは sync fast lane を性能の
中心に据えていたが、これは persisted query / introspection / キャッシュ系
に限られる。**async / DataLoader ストーリーを製品の中心に再配置する。**

鍵になる実装上の発見: async XS スケジューラには既に
「ready frame queue が空になったが未解決 pending が残っている」という
**停滞(stall)ポイント**が存在する。ここに loader flush フックを差し込む
だけで、幅優先実行を待たずに DataLoader バッチングが成立する
(graphql-ruby の lazy_resolve と同じモデル)。停滞単位のバッチは
実行フロンティア全体を含むため、実質的にレベル単位のバッチングに近い。

## 完了済み(2026-07-04〜06)

- ファーストリリース必須機能: #15 依存整理 / #16 introspection 現代化 /
  #18 スキーマ検証 / #19 build_schema / #20 print_schema / #21 @oneOf
- 重大バグ修正: #17 alias 消失 / #22 croak 時 stack frame ダングリング /
  #25 cursor refcount 破壊 + parser location リーク
- 性能・堅牢性: #23 実トラフィックベンチゲート + variable-invariant 実行
  (varying vars 3.7x) / #24 ASan CI + RSS soak + CLONE_SKIP /
  #26 execute_to_json(sync 直 JSON、bundle 2.1x / document 2.2x)

## Track 1: DataLoader ファースト(最優先)

### L1: バッチング基盤(2層設計)

設計判断(2026-07-06): flush タイミングを知っているのは executor だけ
なので **フックはコア**、loader 本体は **公開フック API の上だけに書いた
薄い同梱リファレンス実装**とし、executor 内部とは疎結合に保つ。
graphql-ruby 型の「executor と不可分な組み込み」は採らない。
第三者 loader / ORM 固有バッチャは同じフックで一級市民として書ける。

**L1-a: コア — stall-flush フック + run-to-completion(公開契約)**

- exec-state / runtime に flush コールバック registry(`on_stall` 登録)
- `async_scheduler_drain` が停滞(ready queue 空 & 未解決 pending 残)
  したら登録コールバックを順に呼ぶ。flush 後も進展がなければ
  deadlock として明確なエラー
- flush は同期呼び出しなので `execute_document` は内部で完了まで
  ループでき、**利用者には同期的に完成 envelope を返せる**
- この契約(フック順序・呼び出しタイミング・deadlock 条件)を
  POD で安定 API として明文化する
- 併せて async リーク残差(タスク #11、~425B/req)をここで解消する

**L1-b: 同梱リファレンス — `GraphQL::Houtou::DataLoader`**

- `load` / `load_many` / `prime`、per-request キャッシュ、
  batch 関数(keys → values / per-key error)。dataloader(JS)の
  セマンティクスを踏襲
- 実装は L1-a の公開フック API のみに依存する(規律)。
  将来 L4 で flush モデルが進化しても loader は無傷、
  必要になれば別ディストリへの切り出しも自由
- 検証: SQLite バッチングの example、soak の dataloader シナリオ追加、
  「N+1 が 1+levels 回のクエリになる」ことのテスト

### L2: async response の direct-JSON tail

- async レーンの完成 data(SV ツリー)+ writer error records を
  #26 の C シリアライザで直接 JSON 化し、
  `execute_document_to_json` を sync/async 透過にする
- 見込み: async リクエストの +15〜25%(envelope + encode 境界の除去)

### L3: async hot path の磨き込み(旧 Phase E)

- ownership provenance による clone 削減、object/abstract completion の
  native-first 化、Promise::XS continuation の特化
- ゲート: async_* ベンチ + L1 で追加する dataloader ベンチケース
- 目標: sync 比 3〜4x の差の半減

### L4: 幅優先実行(発展形)

- stall-flush の一般化。レベル駆動スケジューリングで flush 回数と
  スケジューラ往復を削減し、ロード済み行配下の **sync サブツリーを
  sync fast lane に委譲**するハイブリッド、および完成値を native のまま
  保持して **native → JSON 直結**(L2 の上位互換)
- L1〜L3 の計測結果を見てから投資判断(L1 だけでバッチング品質が
  十分なら優先度を下げる)

## Track 2: Web 提供面(Track 1 と並行可)

### W1: PSGI/Plack アダプタ

- GraphQL over HTTP 準拠(POST JSON / `application/graphql-response+json`)
  + GraphiQL 配信
- sync スキーマは #26 の to_json 直行、async スキーマは L1 の同期完了
  (L2 以降は同じく to_json)
- ファーストリリースロードマップ第2段の主役

### W2: APQ(Automatic Persisted Queries)

- SHA-256 プロトコル。persisted 基盤(program cache / bundle)への結線のみ

## Track 3: リリースと残タスク

### R1: CPAN ファーストリリース

- 機能面の必須項目は現 main で充足済み
- 推奨: **L1 + W1 を含めて 0.01** とし、「SQL バックエンドの Web アプリで
  そのまま使える」を初回の訴求にする(DataLoader なしのリリースは
  主役ユースケースに刺さらない)

### 低優先(機会があれば)

- 旧 Phase D: input coercion の native 化(XS→PP 往復除去)
- 旧 Phase F: スキーマの boot-time コンパイルキャッシュ
- リーク残差: resolver_error ~125B/req(タスク #10)、
  program_cache_eviction ~110B/req(タスク #12)
- Federation subgraph(ロードマップ第3段。print_schema 済みで前提は充足)

## 実施順序

```
L1-a (stall-flush フック + run-to-completion, #11 込み)
  → L1-b (同梱 DataLoader)
  → W1 (PSGI) + L2 (async to_json)   ← 並行可
  → R1 (0.01 リリース)
  → L3 (async hot path)
  → L4 (幅優先) / W2 (APQ) / Federation
```

## 運用ルール(継続)

- benchmark gate(checkpoint、async/dataloader ケース含む)と
  robustness gate(ASan CI + soak)を全フェーズの必須通過条件とする
- checkpoint 結果は `docs/current-context.md` に追記
