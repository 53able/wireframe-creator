#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

if [ ! -x node_modules/.bin/tailwindcss ] || [ ! -d node_modules/marko ]; then
  echo "Markoの依存関係がありません。先に npm ci を実行してください。" >&2
  exit 1
fi

app_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" packaging/Info.plist)

swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
stage=$(mktemp -d "${TMPDIR:-/tmp}/agent-workspace-package.XXXXXX")
cleanup() {
  python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$stage"
}
trap cleanup EXIT

app_dir="$stage/Agent Workspace.app"
resources="$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/MacOS" "$resources/assets" "$resources/scripts" "$resources/examples" "$resources/bin"
cp "$bin_dir/AgentWorkspace" "$app_dir/Contents/MacOS/AgentWorkspace"
cp packaging/Info.plist "$app_dir/Contents/Info.plist"
cp package.json package-lock.json LICENSE "$resources/"
cp examples/wireframe.json "$resources/examples/"
cp scripts/validate-wireframe.py scripts/pico_assets.py scripts/provider-bridge.mjs scripts/skill-catalog.mjs scripts/skill-tool-gate.mjs "$resources/scripts/"
cp "$(command -v node)" "$resources/bin/node"
ditto builder "$resources/builder"
ditto assets "$resources/assets"
ditto node_modules "$resources/node_modules"
codesign --force --sign - --timestamp=none "$resources/bin/node"
codesign --force --sign - --timestamp=none "$app_dir"

cp packaging/README.txt "$stage/お読みください.txt"
ln -s /Applications "$stage/Applications"
mkdir -p dist
archive="$repo_root/dist/Agent-Workspace-${app_version}-$(uname -m).dmg"
hdiutil create -quiet -volname "Agent Workspace" -srcfolder "$stage" -format UDZO -ov "$archive"
echo "Created $archive"
