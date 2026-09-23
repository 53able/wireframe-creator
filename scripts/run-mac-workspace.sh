#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
swift build
bin_dir=$(swift build --show-bin-path)
app_dir="$repo_root/dist/Agent Workspace.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/AgentWorkspace" "$app_dir/Contents/MacOS/AgentWorkspace"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AgentWorkspace</string>
  <key>CFBundleIdentifier</key><string>dev.wireframe.agentworkspace</string>
  <key>CFBundleName</key><string>Agent Workspace</string>
  <key>CFBundleDisplayName</key><string>Agent Workspace</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.4</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
open -a "$app_dir" --args --repo-root "$repo_root"
