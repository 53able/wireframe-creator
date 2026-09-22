# wireframe-creator

プロジェクト要件から検証目的を定義し、操作可能な低忠実度HTMLワイヤーフレームを生成・検証する Agent Skill です。

## 特徴

- 外部依存のない単一HTMLを生成
- Pico CSS v2.1.1をインライン化したセマンティックなHTML
- 主要ユーザーフロー、状態、前提、未解決事項を明示
- 構造検証用のPythonスクリプトを同梱
- localhost限定のプレビューと作業中のホットリロードに対応
- 作業開始直後に進捗プレビューを開き、生成・検証状況を可視化
- 完了時刻付きの正本HTMLを生成し、静的HTMLの保存とブラウザ引継ぎを検証
- 新規作成、壁打ち、既存ワイヤーフレームの段階的改稿に対応

## インストール

[`skills`](https://github.com/vercel-labs/skills) CLIを使用します。

```bash
npx skills add 53able/wireframe-creator
```

特定のエージェントへグローバルインストールする場合:

```bash
npx skills add 53able/wireframe-creator -g -a claude-code -y
```

利用可能なスキルとして認識されるかだけを確認する場合:

```bash
npx skills add 53able/wireframe-creator --list
```

## 必要環境

- Python 3.10以上
- 完全な視覚検証を行う場合は、レンダリング済みページを操作できるブラウザ自動化ツール

Pythonスクリプトは標準ライブラリだけを使用します。

## Pico CSS

生成HTMLのスタイル基盤にはPico CSS v2.1.1を使用します。`assets/pico.manifest.json`でバージョン、取得元、CSSとライセンスのSHA-256を固定し、`scripts/render-wireframe-template.py`と進捗初期化処理が検証済みCSSをHTMLへインライン化します。CDNや実行時のネットワーク接続は使いません。

単体で保存・配布されるHTMLごとにライセンス条件を満たすため、Pico CSSの著作権表示とMITライセンス全文も`style[data-pico-css]`へ埋め込みます。原文は`assets/pico.LICENSE.md`、取得元は[Pico CSS v2.1.1](https://github.com/picocss/pico/releases/tag/v2.1.1)です。

固定版の更新と既存HTMLの明示的な移行手順は[`references/pico-css.md`](references/pico-css.md)に記載しています。

## 構成

```text
SKILL.md
assets/
references/
scripts/
```

`SKILL.md` は Agent Skills 仕様に準拠し、詳細なプロトコル、テンプレート、実行スクリプトを必要時に読み込む構成です。

## ライセンス

MIT License。詳細は [LICENSE](LICENSE) を参照してください。
