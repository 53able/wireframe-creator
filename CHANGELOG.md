# Changelog

このプロジェクトの主な変更を記録します。

## Unreleased

### 変更

- HTML出力と進捗UIのスタイル基盤をPico CSS v2.1.1へ移行
- 自己完結型HTMLへPico CSSのMITライセンス全文を埋め込む生成・検証処理を追加
- Pico CSSのバージョン・取得元・SHA-256を単一マニフェストで固定し、明示的な更新経路を追加
- ホットリロードのstyle同期とロールバックを属性を含む要素単位へ強化

## 3.0.1 - 2026-09-22

### 修正

- keep browser progress labels in sync

### 変更

- Merge pull request #2 from 53able/fix/progress-state-label-parity

## 3.0.0 - 2026-09-21

### 新機能

- add context interview phase

### 変更

- Merge pull request #1 from 53able/feature/context-interview/00-add-context-questions

## 2.0.0 - 2026-09-21

### 破壊的変更

- add completion-timestamped static handoff

### ドキュメント

- define agent skill versioning policy
- remove release metadata from README

### CI

- automate skill release packaging

## 1.0.0 - 2026-09-20

### 新機能

- 操作可能な低忠実度HTMLワイヤーフレームを作成・検証する初回公開版
- 新規作成、壁打ち、段階的改稿のワークフロー
- 構造検証、作業進捗表示、localhost限定プレビュー用のPythonスクリプト
- Agent Skills CLIおよびClaude Cowork向け配布形式
