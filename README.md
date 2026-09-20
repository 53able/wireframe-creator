# wireframe-creator

プロジェクト要件から検証目的を定義し、操作可能な低忠実度HTMLワイヤーフレームを生成・検証する Agent Skill です。

## 特徴

- 外部依存のない単一HTMLを生成
- 主要ユーザーフロー、状態、前提、未解決事項を明示
- 構造検証用のPythonスクリプトを同梱
- localhost限定のプレビューと作業中のホットリロードに対応
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

### Claude Cowork / Claude向け

[Releases](https://github.com/53able/wireframe-creator/releases) から最新の `wireframe-creator-vX.Y.Z.zip` をダウンロードし、Claudeのスキル設定からアップロードしてください。ZIP内には `wireframe-creator/` ディレクトリがあり、その直下に `SKILL.md` と関連ファイルが収録されています。

## バージョン

現在のリリース番号は [VERSION](VERSION)、変更履歴は [CHANGELOG.md](CHANGELOG.md) で管理します。

## 必要環境

- Python 3.10以上
- 完全な視覚検証を行う場合は、レンダリング済みページを操作できるブラウザ自動化ツール

Pythonスクリプトは標準ライブラリだけを使用します。

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
