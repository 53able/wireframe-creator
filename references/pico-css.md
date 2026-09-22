# Pico CSS dependency policy

## 埋め込みとライセンス

生成HTMLは単体で保存・配布される成果物であるため、Pico CSS本体に加えて著作権表示とMITライセンス全文を各HTMLの`style[data-pico-css]`へ埋め込む。この重複は意図的であり、オフライン動作と配布時のライセンス表示を自己完結させるためのものとする。

`assets/pico.manifest.json`を依存契約の正本とする。生成器、構造検証器、進捗処理、ホットリロードは、次を同じ契約として扱う。

- Pico CSSの固定バージョンと公式リリースURL
- `assets/pico.min.css`のSHA-256
- `assets/pico.LICENSE.md`のSHA-256
- 生成される`style[data-pico-css]`要素全体

## 固定版を更新する

更新は専用PRで行い、暗黙には追従しない。

1. Pico CSSの公式リリースから対象版のminified CSSとMITライセンスを取得する。
2. `assets/pico.min.css`と`assets/pico.LICENSE.md`を置き換える。
3. 両ファイルのSHA-256、バージョン、公式リリースURLを`assets/pico.manifest.json`へ記録する。
4. `README.md`などに記載された固定バージョンを更新する。
5. `python3 -m unittest discover -s tests -v`と`python3 -m py_compile scripts/*.py tests/*.py`を実行する。
6. 進捗シェル、代表的なワイヤーフレーム、狭幅・広幅、ホットリロードをブラウザで確認する。

チェックサム不一致は生成時点でエラーとなる。マニフェストだけ、または同梱ファイルだけを更新してはならない。

## 既存HTMLを移行する

既存HTMLが別版または改変済みの`style[data-pico-css]`を含む場合、通常の初期化は停止する。内容を確認したうえで、次の明示的な操作によりマニフェスト固定版へ置き換える。

```bash
python3 "$SKILL_ROOT/scripts/update-progress.py" init \
  "$PREVIEW_HTML" \
  --mode l3 \
  --upgrade-pico
```

この操作はPico CSS要素だけを正規内容へ置き換える。ワイヤーフレーム固有CSSの互換性はL3変更としてブラウザ検証する。

## CSS境界

`:root[data-theme="light"]`にはPicoのテーマ変数とワイヤーフレーム／進捗UIで共有する色トークンだけを置く。レイアウト、部品サイズ、画面切替、注釈などの固有規則は`[data-wireframe-root]`以下へスコープし、進捗UIへ漏らさない。完成時に生成される`[data-static-html-handoff]`だけはルート外の明示的な運用UIとして扱う。
