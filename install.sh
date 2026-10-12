#!/bin/bash
# Copyright 2026 Wang Jian
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# vacuole install script
#   1) Release build
#   2) Install to /Applications
#   3) Register root LaunchDaemon vacuoled (legacy launchd, no code-signing certificate required)
#
# Must be run in a real terminal (will prompt for the sudo password).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_FROM="build/Build/Products/Release/vacuole.app"
APP_TO="/Applications/vacuole.app"
PLIST_SRC="Config/com.vacuole.daemon.legacy.plist"
PLIST_DST="/Library/LaunchDaemons/com.vacuole.daemon.plist"

echo "==> [1/5] Generating Xcode project"
xcodegen generate

echo "==> [2/5] Release build"
xcodebuild -project vacuole.xcodeproj -scheme vacuole -configuration Release -derivedDataPath build build

echo "==> [3/5] Installing app to /Applications"
rm -rf "$APP_TO"
ditto "$APP_FROM" "$APP_TO"
xattr -dr com.apple.quarantine "$APP_TO" 2>/dev/null || true

echo "==> [4/5] Unloading old daemon registration"
sudo launchctl bootout system/com.vacuole.daemon 2>/dev/null || true
sudo pkill -f 'Contents/MacOS/vacuoled' 2>/dev/null || true
sleep 1

echo "==> [5/5] Installing and loading LaunchDaemon"
sudo cp "$PLIST_SRC" "$PLIST_DST"
sudo chown root:wheel "$PLIST_DST"
sudo chmod 644 "$PLIST_DST"
sudo launchctl bootstrap system "$PLIST_DST"
sudo launchctl enable system/com.vacuole.daemon
sudo launchctl kickstart -k system/com.vacuole.daemon

echo
echo "==> Done. Verifying:"
sudo launchctl print system/com.vacuole.daemon | head -20
echo
echo "You can now launch the app: open /Applications/vacuole.app"