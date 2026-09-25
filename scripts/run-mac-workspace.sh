#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
swift build
bin_dir=$(swift build --show-bin-path)
app_dir="$repo_root/dist/Agent Workspace.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/AgentWorkspace" "$app_dir/Contents/MacOS/AgentWorkspace"
cp packaging/Info.plist "$app_dir/Contents/Info.plist"
open -a "$app_dir" --args --repo-root "$repo_root"
