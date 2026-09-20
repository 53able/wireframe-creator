# 改稿反復プロトコル

既存ワイヤーフレームを改稿するときだけ、このプロトコルを読む。正本HTMLは単一ファイルのまま維持し、レビュー履歴、コメント入力、画像比較、承認状態をHTMLへ実装しない。

## 1. 変更影響度を判定する

複数レベルに該当する場合は、最も高いレベルを採用する。

| レベル | 変更例 | 編集範囲 | 中間検証範囲 |
|---|---|---|---|
| L0 | 注釈、前提、未解決事項、説明文 | 対象テキストのみ | 構造検証 |
| L1 | 単一画面の文言、項目、局所配置 | 対象画面のみ | 構造検証、対象画面の表示確認 |
| L2 | 遷移、入力、エラー、主要CTA | 対象画面と影響状態 | 構造検証、影響経路の操作、対象画面の視覚差分 |
| L3 | 共通CSS、ナビゲーション、レスポンシブ、テンプレート | 全体 | 全主要フロー、狭幅・広幅、視覚差分 |

最終化時は変更レベルにかかわらず完全検証を行う。変更レベルを理由に構造検証を省略しない。

## 2. 変更契約を固定する

編集前に次の形式を内部的に埋める。長い計画として表示せず、編集と検証の境界として保持する。

```yaml
change_id: C-01
level: L2
request: 申請フォームの入力順序を変更する
screens:
  - application-form
states:
  - input
  - validation-error
transitions:
  - application-form -> confirmation
unchanged:
  - start
  - application-history
  - success
validation:
  - structural
  - affected-path
  - visual-diff-1280
```

`unchanged` に記録した範囲を、変更理由なく整形、改名、再生成しない。編集後は差分を読み、契約外の変更を戻す。

## 3. 安定IDを必要な箇所だけ使う

- `C-xx`: 変更要求
- `D-xx`: ユーザー判断が必要な設計事項
- `Q-xx`: 回答がないと進めない質問
- `R-xx`: 重大な設計リスク

すべての要素へIDを付けない。再レビューで参照する変更と判断だけに付ける。

## 4. ベースラインと撮影範囲を管理する

レビューで合意された画面だけをベースラインとして保存する。初稿の全画面を自動的にベースラインへ昇格させない。

```text
$OUTPUT_ROOT/screenshots/wireframe-review/<slug>/
├── baseline/
│   ├── application-form--320.png
│   └── application-form--1280.png
├── current/
│   └── application-form--1280.png
└── diff/
    └── application-form--1280.png
```

撮影範囲を次のように限定する。

- L0: 撮影しない。
- L1: 変更画面を、変更時に使用した幅で撮影する。
- L2: 変更画面と影響状態を撮影する。
- L3と最終化時: 主要画面を320px前後と1280px前後で撮影する。

時刻、ランダム値、アニメーションなどの不安定要素を持ち込まない。必要な場合は撮影時に固定または非表示にする。

## 5. 視覚差分を外部で生成する

ODiffがすでに利用可能な場合は、次の形式で比較する。

```bash
odiff \
  "$OUTPUT_ROOT/screenshots/wireframe-review/<slug>/baseline/application-form--1280.png" \
  "$OUTPUT_ROOT/screenshots/wireframe-review/<slug>/current/application-form--1280.png" \
  "$OUTPUT_ROOT/screenshots/wireframe-review/<slug>/diff/application-form--1280.png"
```

リポジトリがPlaywrightのVisual comparisonsをすでに使用している場合は、Playwrightを使ってよい。差分確認だけを目的としてPlaywrightを新規導入しない。

ODiffもPlaywrightも利用できない場合は依存関係を無断で導入しない。変更前後の画像を並べて保存するか、現在画像だけを保存し、視覚差分を `not run` と報告する。

ベースラインは、ユーザーが変更を承認した後だけ更新する。

## 6. エージェント探索を任意実験として扱う

Jev Ultrafastを視覚差分の代わりに使わない。次の条件をすべて満たす場合だけ、任意のエージェント・スモークテストとして検討する。

- 主要CTA、ラベル、情報階層、画面遷移を変更した。
- 自然言語の目標から目的画面へ到達できるかを調べる必要がある。
- Python 3.12、`uv`、Browser Harness、必要なAPI認証情報を利用できる。
- 最終画面の `data-screen-id`、必要な文言、入力値などを確認する独立オラクルがある。

Jevの `DONE` を成功判定に使わない。エージェントが到達できたことを人間のユーザビリティ検証として扱わない。通常の改稿では決定論的な遷移検証を優先する。

## 7. 再レビュー報告を短く保つ

`assets/completion-report.template.md` を基本構造として使う。次の例を参考に改稿専用欄を埋め、共通の検証結果、実行コマンド、前提、未解決事項を省略しない。

```markdown
## 今回の変更

- C-01: 申請フォームの入力順序を変更
- C-02: 確認前の補足文を削除

## 変更していない範囲

- 開始画面
- 申請履歴
- 完了画面

## 検証結果

- 構造検証: pass
- application-form → confirmation: pass
- 1280px視覚差分: 生成済み
- 320px表示: not run（共通レイアウト変更なし）

## 再レビュー対象

- D-01: 入力順序が実際の判断順序と一致するか
```

「問題ありません」「使いやすくなりました」のような根拠のない評価を加えない。
