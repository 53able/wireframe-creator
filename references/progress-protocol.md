# ライブ進捗プロトコル

ワイヤーフレーム生成、L2〜L3改稿、または進捗表示を使うL1改稿・壁打ちで読む。`SKILL.md` で設定した `SKILL_ROOT` と `OUTPUT_ROOT` をコマンドに使う。最終化後の正本HTMLへ進捗UIを残さない。

## 1. 工程ID

| 工程ID | 表示名 |
|---|---|
| `input` | 入力と保存場所を確認 |
| `brief` | 検証目的と対象フローを定義 |
| `design` | 画面と状態を設計 |
| `html-generation` | HTMLを生成または部分編集 |
| `structural-validation` | 構造検証 |
| `browser-validation` | ブラウザ検証 |
| `finalization` | 最終化 |

進捗率や残り時間を表示しない。工程状態は作業時間の比率ではない。

## 2. 状態

- `pending`: 未着手
- `running`: 実行中
- `pass`: 完了
- `fail`: 失敗または対応が必要
- `not-run`: 環境制約または変更範囲により未実施

同時に `running` にできる工程は1件だけとする。先行工程がすべて `pass` または `not-run` になってから次工程を開始する。工程を開始する直前に `running`、完了直後に `pass` へ更新する。未実施は理由をメッセージへ記録する。

`fail` から再試行するときは同じ工程を `running` へ戻す。完了済み工程を再実行するときも `running` へ戻してよい。状態を実際の処理より先へ進めない。

## 3. モード別の利用

| モード | 既定 |
|---|---|
| 壁打ち | 依頼または作業計画にブラウザ検証、視覚差分、または2回以上の生成・改稿反復が含まれる場合だけ使用する |
| 新規作成 | 使用する |
| L0改稿 | 使用しない |
| L1改稿 | 依頼または変更契約にブラウザ検証、視覚差分、または2回以上の生成・改稿反復が含まれる場合だけ使用する |
| L2改稿 | 使用する |
| L3改稿 | 使用する |

進捗表示を使わない場合でも、既存の構造検証と報告手順は省略しない。

## 4. 正本HTML、一時作業HTML、プレビュー

新規作成では、保存先確定後に `init` で正本HTMLのパスへ進捗シェルを作る。画面HTMLは一時作業HTMLへ生成し、`stage` で正本HTMLへ反映する。

改稿では、`init` で既存の正本HTMLへ進捗ブロックを挿入する。正本HTMLから進捗ブロックを除いた内容を一時作業HTMLへコピーして編集し、`stage` で反映する。

`init` 後に `preview-process-lifecycle.md` に従って停止に使えるPID、process handle、またはjob IDを記録し、次のプレビューサーバーを起動する。stdoutの `PREVIEW_URL` を `browser-preview-protocol.md` で決定した規定ブラウザのナビゲーションAPIで開く。OSの既定アプリへ委ねるコマンドは使わない。

```bash
python3 "$SKILL_ROOT/scripts/serve-preview.py" \
  "$OUTPUT_ROOT/path/to/example-wireframe.html" --port 0
```

サーバーはlocalhostだけへバインドし、対象HTML以外を配信しない。進捗と画面本体はSSE通知後に部分更新し、文書全体を再読込しない。`file://` で直接開いた場合は経過時間だけを更新し、ホットリロードを実施したと主張しない。

version 1 の進捗ブロックを検出した場合は暗黙移行しない。開始時刻を新しく設定することを理解したうえで、次を明示的に実行する。

```bash
python3 "$SKILL_ROOT/scripts/update-progress.py" init \
  "$OUTPUT_ROOT/path/to/example-wireframe.html" --mode <mode> --upgrade
```

正本HTMLを全面上書きして進捗状態を消さない。一時作業HTMLをユーザー向け成果物として報告しない。

## 5. 更新例

```bash
python3 "$SKILL_ROOT/scripts/update-progress.py" init \
  "$OUTPUT_ROOT/path/to/example-wireframe.html" \
  --mode <mode> \
  --title "申請フロー"

python3 "$SKILL_ROOT/scripts/update-progress.py" set \
  "$OUTPUT_ROOT/path/to/example-wireframe.html" \
  --step input --state pass \
  --message "保存先と対象デバイスを確認しました"

python3 "$SKILL_ROOT/scripts/update-progress.py" set \
  "$OUTPUT_ROOT/path/to/example-wireframe.html" \
  --step brief --state running \
  --message "主要タスクと最大リスクを整理しています"

# 改稿時だけ、進捗UIを含まない作業コピーを作る
python3 "$SKILL_ROOT/scripts/update-progress.py" prepare \
  "$OUTPUT_ROOT/path/to/example-wireframe.html" \
  --destination "$OUTPUT_ROOT/path/to/.example-wireframe-work.html"

python3 "$SKILL_ROOT/scripts/update-progress.py" stage \
  "$OUTPUT_ROOT/path/to/example-wireframe.html" \
  --source "$OUTPUT_ROOT/path/to/.example-wireframe-work.html"
```

メッセージには現在実行している具体的な作業だけを書く。「まもなく完了」「ほぼ完成」など、根拠のない予測を書かない。

## 6. 経過時間とホットリロード

`init` は `startedAtEpochMs` を一度だけ記録する。`set`、`prepare`、`stage`、SSE再接続では開始時刻を変更しない。経過時間は次の規則で表示する。

- 常に `hh:mm:ss` とし、1時間未満でも時間を省略しない。
- 24時間で折り返さず、27時間なら `27:00:00` 以降として表示する。
- 1秒ごとに `Date.now() - startedAtEpochMs` から再計算する。
- 失敗、再試行、接続断を含む壁時計時間とし、一時停止しない。
- 毎秒の更新をスクリーンリーダーへ通知しない。ライブリージョンは進捗メッセージだけに使う。

ホットリロードでは、タイトル、`style[data-wireframe-style]`、`[data-wireframe-root]`、`script[data-wireframe-runtime]` の4境界だけを同期する。

同じ画面ID、入力識別子、フォーカス対象が残る場合は状態を復元する。同名要素が同じ画面またはフォーム内に複数ある場合は、一意の `id` または `data-preview-key` を付ける。ファイル入力の選択内容はブラウザの制約により復元しない。

取得HTMLが不正、更新境界がない、または境界が重複する場合は現在のDOMを維持し、進捗パネルへ失敗理由を表示する。

作業中プレビューでは、ホットリロードクライアントが固定の画面遷移ランタイムを一度だけ初期化する。取得した `script[data-wireframe-runtime]` は構文検査するが実行せず、不活性なマーカーとして同期する。最終化後の正本HTMLを直接開く場合だけ、正本HTML内の通常ランタイムを実行する。

## 7. 失敗と再開

自動復旧できない失敗は次のように記録する。

```bash
python3 "$SKILL_ROOT/scripts/update-progress.py" fail \
  "$OUTPUT_ROOT/path/to/example-wireframe.html" \
  --step browser-validation \
  --message "ブラウザを起動できません。構造検証までは完了しています"
```

失敗したHTMLを正本HTMLとして報告しない。再開できる場合は同じ工程を `running` へ戻し、成功後に `pass` へ進める。

進捗更新スクリプト自体が失敗した場合は、ワイヤーフレーム生成を直ちに中止しない。`stderr` を確認し、正本HTMLが破損していないことを確認してから、進捗表示なしで作業を続ける。その場合はリアルタイム表示を実施したと報告しない。

## 8. 最終化

最終化前に `input` から `browser-validation` までを `pass` または `not-run` にする。`finalization` を `running` にしてから次を実行する。

```bash
python3 "$SKILL_ROOT/scripts/update-progress.py" finalize \
  "$OUTPUT_ROOT/path/to/example-wireframe.html"
python3 "$SKILL_ROOT/scripts/update-progress.py" verify-final \
  "$OUTPUT_ROOT/path/to/example-wireframe.html"
python3 "$SKILL_ROOT/scripts/validate-wireframe.py" \
  "$OUTPUT_ROOT/path/to/example-wireframe.html" --min-screens 2 --require-actions
```

`finalize` は進捗ブロック、経過時間、開始時刻、ホットリロードクライアントを除去する。ブラウザ側は正本HTMLのタイトル、スタイル、本体、ランタイムを先に反映し、その後でSSEとタイマーを停止する。`verify-final` は進捗マーカー、`startedAtEpochMs`、`EventSource`、プレビューURL、進捗用属性が残っていないことを検査する。

最終化後は `browser-preview-protocol.md` に従い、正本HTMLの絶対パスからパーセントエンコード済みの `file://` URLを生成する。プレビューサーバーを停止する前に、同じ規定ブラウザの現在のプレビュータブをそのURLへ再ナビゲーションし、現在URL、タイトル、`[data-wireframe-root]` を確認する。開始画面から主要タスクの完了状態まで操作し、作業中の固定プレビューランタイムではなく、正本HTML内の通常ランタイムが動作することを確認する。

静的HTMLへの引継ぎと最終操作検証が成功した後だけ、`preview-process-lifecycle.md` に従ってプレビューサーバーを停止・回収する。停止要求後にPIDまたはhandleが生存していないこと、zombie/defunct状態でないこと、プレビューURLが応答しないことを確認し、その後も `file://` の画面が表示されていることを確認する。規定ブラウザを利用できない、操作権限がない、または `file://` を開けない場合は別ブラウザへ無断で切り替えず、サーバーを停止しない。人向け報告へ静的HTML引継ぎを `not run（理由）`、サーバー状態を `intentional-handoff` と記録し、残存URLとPIDまたはhandleを報告する。停止・回収・生存確認のいずれかを確認できない場合も、未検証状態を隠さず報告する。

## 9. 可視性の報告

機械状態には `not-run`、人向け報告には `not run（理由）` を使う。

HTMLを可視ブラウザで開いていない場合は、「リアルタイム表示した」「経過時間を目視確認した」と記載しない。実装されていることと、利用者が実際に表示を見たことを分ける。
