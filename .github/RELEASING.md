# Release workflow

リリースはGitHub Actionsの **Release** ワークフローから実行する。

## 手順

1. `main`へリリース対象の変更をマージする。
2. GitHubの **Actions → Release → Run workflow** を開く。
3. `patch`、`minor`、`major`からSemVerの更新種別を選ぶ。
4. ワークフロー完了後、作成されたタグ、GitHub Release、添付ZIPを確認する。

## CIが実行する処理

1. 現在の`VERSION`と同名のタグから`HEAD`までのコミットを収集する。
2. SemVerを更新し、`CHANGELOG.md`へ変更内容を追加する。
3. リリース用スクリプトとスキルのPythonスクリプトを検証する。
4. 配布対象を`SKILL.md`、`LICENSE`、`VERSION`、`assets/`、`references/`、`scripts/`に限定する。
5. `wireframe-creator/`をトップレベルフォルダとする決定的なZIPを生成し、展開テストを行う。
6. バージョン更新をコミットし、注釈付きタグと`main`をatomic pushする。
7. GitHub Releaseを作成し、`wireframe-creator-vX.Y.Z.zip`を添付する。

GitHub Releaseを手作業で先に作らない。バージョン更新、タグ、Release、ZIP添付を同じワークフローが所有することで、タグだけ、または添付ファイルなしのReleaseが生じる経路を減らす。

## 失敗時

- タグのpush前に失敗した場合は、原因を修正して同じワークフローを再実行する。
- タグのpush後、Release作成だけが失敗した場合は、新しいバージョンを作らない。既存タグに対してZIPを再生成し、`gh release create <tag> <zip> --verify-tag`でReleaseを復旧する。
- `main`のbranch protectionがGitHub Actionsからのpushを拒否する場合は、環境または専用のGitHub Appを設定し、長期PATをワークフローへ直接保存しない。

## 設計根拠

[`vercel-labs/skills`のPublishワークフロー](https://github.com/vercel-labs/skills/blob/main/.github/workflows/publish.yml)と同様に、手動起動、バージョン更新、タグのpush、GitHub Release作成を1つの書き込み権限付きジョブへまとめている。このリポジトリではnpm公開の代わりに、Agent Skill単体のZIP生成と添付を行う。
