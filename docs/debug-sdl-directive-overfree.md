# 調査メモ: 入力 coercion croak 後の破棄時 SEGV(PR #21 CI)

調査日: 2026-07-04〜05

## 解決(2026-07-05)

**根本原因**: block 実行ループが C スタック上の FieldFrame
(`init_stack_field_frame`)を `ExecState->field_frame` に保持したまま、
coercion / resolver からの die(croak = longjmp)が復元コードを飛び越えると、
`field_frame` が死んだ C スタックを指したまま残る。ExecState の破棄時
(program cache 経由でインタプリタ終了時)に `free_field_frame` が
dead stack のゴミを decref して SEGV。GitHub Actions 実機の gdb で確定:

```
gql_runtime_vm_path_frame_decref ← free_field_frame ← ExecState DESTROY ← global destruction
```

- **main に既存のバグ**(Unknown field 等の die でも発火)。#21 は露出させただけ
- x86_64 -O2 のヒープ/スタックレイアウトでのみ致命化(-O0 / aarch64 /
  ASan / valgrind では不可視 — スタック + SV アリーナ破壊のため)

**修正**: PR #22 — stack field frame 設置時に Perl save stack へ
`SAVEDESTRUCTOR_X` ガードを登録。die unwind 中(C スタックが生きている時点)に
発火して in-flight frame を解放・復元。正常系出口では disarm。
3サイト(sync loop / serial mutation / async path)すべてに適用。

**検証**: 実機 CI で修正前 3/3 SEGV → 修正後 3/3 clean。
回帰テスト `t/34_exec_state_croak_safety.t`。

**後始末**: `debug/oneof-segv-asan` ブランチと asan-debug workflow は
#22 マージ後に削除する。workflow は Phase B の ASan CI ゲートの原型として
performance plan に引き継ぐ。

---

以下は調査過程の記録(参考)。

## 症状

- PR #21(@oneOf)の CI で `t/33_oneof_input_objects.t` が SEGV
  (Wstat 139。全 subtest 成功後、インタプリタ終了時)
- CI ログでは直前に
  `Attempt to free unreferenced scalar: SV 0x... during global destruction.`
- ヒープレイアウト依存で、CI の run / perl バージョンごとに発生が揺れる

## 確定した事実(信頼できる再現手順ベース)

再現環境: `perldocker/perl-tester:5.42`(x86_64、Apple Silicon 上は
`--platform linux/amd64`)+ デフォルト最適化(-O2)ビルド +
`PERL_DESTRUCT_LEVEL=2`。

1. **最小再現(n=1 で決定的)**: `util/debug/oneof-segv-case.pl`
   — literal の input object 引数が @oneOf coercion で **die する execute を
   1 回**行い、プロセス終了させると SEGV(3/3)
2. **croak が必要条件**: coercion の croak を握りつぶす実験パッチ
   (coerce-nocroak)では完全に消える(0/3)。
   成功する execute のみ(×300)や build_schema のみ(×100)では発生しない
3. **cached bundle の prepare 段階は無関係**:
   `gql_runtime_vm_prepare_cached_bundle_in_place` を丸ごとスキップしても
   croak が実行段階に移るだけで SEGV は継続(3/3)
4. **croak 実装の変種は影響なし**: croak_sv を static message の croak に
   変える / スタック引数を mortal 化する / croak 前に POPs する、
   いずれも SEGV 継続 → coerce 内の croak 実装自体は問題ではなく、
   **croak の unwind が通過する先(またはその後の状態)**に問題がある
5. **極端なレイアウト依存**:
   - -O0 ビルドでは再現しない(0/5)
   - native aarch64 では増幅版(×300)でも再現しない(0/5)
   - トレース fprintf を仕込んだだけのビルドで消える
   → ローカルでのコード摂動による二分探索は信頼できない
6. スキーマ側オブジェクト(型・fields・schema 等)の REFCNT は
   失敗 execute を 70 回繰り返しても安定(過剰 dec の対象は
   per-request で作られる何か)
7. トレースできた 1 run では、破棄時に program の `cached_bundle` は
   NULL だった(croak が bundle 構築前に起きている経路がある)
8. qemu 環境の制約: gdb(ptrace 不可)、ASan(OOM kill)、
   valgrind(SV アリーナのため検出不能)、core(qemu の state で解析不能)

## 無効化された過去の結論(2026-07-05 訂正)

初期の絞り込みプローブに **シェルエスケープの欠陥**があった
(bash 二重引用符内の `\@` が Perl の `q<>` にそのまま渡りパース失敗
→ exit≠0 を「bad」と誤カウント)。これにより以下は**すべて根拠なし**:

- 「directive を含む parse 全般で発生」
- 「SDL 型定義の directive が引き金」
- 「初回コミットから存在する day-one バグ」
- 「main でも再現する」(main への影響は未確認。ただし coerce croak 自体は
  main にも存在する経路 — 例: input object の Unknown field die —
  なので、#21 固有ではなく既存メカニズムの可能性が高い)

教訓: プローブは必ずファイルベース(heredoc)にする。
exit≠0 と警告 grep は別カウントで報告する。

## 現在の進行中の手段

qemu 制約を回避するため、**GitHub Actions の実機 x86_64 上で ASan を実行**:

- ブランチ: `debug/oneof-segv-asan`(debug 専用、マージしない)
- workflow: `.github/workflows/asan-debug.yml`
  - 素のビルドで bare wstat 証跡を取得
  - ASan ビルド(-O2 -g -fsanitize=address + LD_PRELOAD libasan)で
    n=1 / n=300 / t/33 を実行しレポート取得

## 次のステップ

1. ASan レポートのスタックから corruption 箇所を特定
2. main 相当の croak(oneOf なしで coercion die する最小ケース、
   例: unknown input field literal)でも発生するかをファイルベースで確認
   → #21 のブロッカーか、既存バグの露出かを最終確定
3. 修正 → 再現手順で検証 → 独立 PR(または #21 に同梱するか判断)
4. `debug/oneof-segv-asan` ブランチと workflow を削除
5. 恒久対策: performance plan Phase B の ASan CI ゲート化
   (この workflow がその原型になる)

## 補足

- `ppport.h` は 3.73(最新)で無関係
- 実験用キルスイッチ(GQL_SKIP_PREPARE / GQL_COERCE_NOCROAK 等)は
  ローカル検証専用で、リポジトリには含めていない
