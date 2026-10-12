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
# vacuole uninstall script: removes the root LaunchDaemon and the installed app
#
set -uo pipefail

APP_TO="/Applications/vacuole.app"
PLIST_DST="/Library/LaunchDaemons/com.vacuole.daemon.plist"

echo "==> Uninstalling the vacuole daemon"
sudo launchctl bootout system/com.vacuole.daemon 2>/dev/null || true
sudo pkill -f 'Contents/MacOS/vacuoled' 2>/dev/null || true
sudo rm -f "$PLIST_DST"

echo "==> Removing /Applications/vacuole.app"
rm -rf "$APP_TO"

echo "==> Done"