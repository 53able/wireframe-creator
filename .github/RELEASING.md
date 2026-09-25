# Release workflow

リリースはGitHub Actionsの **Release** ワークフローから実行する。

## 手順

1. `main`へリリース対象の変更をマージする。
2. GitHubの **Actions → Release → Run workflow** を開く。
3. `patch`、`minor`、`major`からSemVerの更新種別を選ぶ。
4. ワークフロー完了後、作成されたタグ、GitHub Release、添付ZIP・DMGを確認する。

## CIが実行する処理

### `release` ジョブ（スキルZIP、ubuntu-latest）

1. 現在の`VERSION`と同名のタグから`HEAD`までのコミットを収集する。
2. SemVerを更新し、`CHANGELOG.md`へ変更内容を追加する。
3. リリース用スクリプトとスキルのPythonスクリプトを検証する。
4. 配布対象を`SKILL.md`、`LICENSE`、`VERSION`、`assets/`、`references/`、`scripts/`に限定する。
5. `wireframe-creator/`をトップレベルフォルダとする決定的なZIPを生成し、展開テストを行う。
6. バージョン更新をコミットし、注釈付きタグと`main`をatomic pushする。
7. **draft状態の**GitHub Releaseを作成し、`wireframe-creator-vX.Y.Z.zip`を添付する。

GitHub Releaseを手作業で先に作らない。バージョン更新、タグ、Release、ZIP添付を同じワークフローが所有することで、タグだけ、または添付ファイルなしのReleaseが生じる経路を減らす。Releaseはdraftのまま作成し、`build-mac-app`ジョブがDMGの添付に成功するまで一般公開しない。これにより、DMGビルドが失敗してもスキルZIPだけが公開された不完全なReleaseが利用者に見えることを防ぐ。

### `build-mac-app` ジョブ（Macアプリのdmg、macos-latest、`release`ジョブの後に実行）

1. `release`ジョブが作成したタグをcheckoutする。
2. Node.js依存関係（Marko、Tailwind CSS）を`npm ci`でインストールする。
3. `scripts/package-mac-workspace.sh`で release ビルド・コード署名（アドホック）・DMG化まで行う。DMGファイル名のバージョンは`packaging/Info.plist`の`CFBundleShortVersionString`から取得する（スキル本体の`VERSION`とは独立して管理している。詳細は`docs/agent-workspace-architecture.md`を参照）。GitHub Actionsの`macos-latest`ランナーはApple Siliconのため、生成されるDMGはarm64版のみ。Intel Mac向けのビルドは行わない。
4. 生成した`Agent-Workspace-<app-version>-arm64.dmg`を、`release`ジョブが作成した同じGitHub Releaseへ`gh release upload`で追加する。
5. アップロード成功後、`gh release edit <tag> --draft=false`でReleaseを一般公開する。

Macアプリのバージョン（`packaging/Info.plist`）はスキル本体の`VERSION`とは別系統で、リリースワークフロー実行時に自動更新されない。DMGに含めるアプリのバージョンを上げる場合は、事前に`packaging/Info.plist`の`CFBundleShortVersionString`/`CFBundleVersion`を手動で更新してから`main`にマージすること。更新を忘れると、新しいタグのReleaseに古いバージョン表記のDMGが添付される。

## 失敗時

- タグのpush前に失敗した場合は、原因を修正して同じワークフローを再実行する。
- タグのpush後、`release`ジョブのRelease作成だけが失敗した場合は、新しいバージョンを作らない。既存タグに対してZIPを再生成し、`gh release create <tag> <zip> --draft --verify-tag`でdraft Releaseを復旧してから`build-mac-app`を実行する。
- `build-mac-app`ジョブだけが失敗した場合、GitHub ActionsのUIから **Re-run failed jobs** を使うこと。ワークフロー全体を`workflow_dispatch`で再起動すると`prepare-release.py`が新しいバージョンをbumpし別タグを作ってしまうため使わない。`Re-run failed jobs`なら`release`ジョブの成果（タグ、draft Release、outputs）を保持したまま`build-mac-app`だけを再実行できる。ローカルで復旧する場合は、Xcode・Node.js 22・`npm ci`済みの環境と`gh auth`済みの認証情報を用意し、既存タグをcheckoutして`scripts/package-mac-workspace.sh`を実行後、`gh release upload <tag> dist/Agent-Workspace-*.dmg --clobber`でDMGを追加し、最後に`gh release edit <tag> --draft=false`で公開すること。
- `main`のbranch protectionがGitHub Actionsからのpushを拒否する場合は、環境または専用のGitHub Appを設定し、長期PATをワークフローへ直接保存しない。

## 設計根拠

[`vercel-labs/skills`のPublishワークフロー](https://github.com/vercel-labs/skills/blob/main/.github/workflows/publish.yml)と同様に、手動起動、バージョン更新、タグのpush、GitHub Release作成を1つの書き込み権限付きジョブへまとめている。このリポジトリではnpm公開の代わりに、Agent Skill単体のZIP生成と添付を行う。
