#!/usr/bin/env bash
set -euo pipefail

chatterThresholdMilliseconds=90
#chatterThresholdMilliseconds=500
debounceThresholdMilliseconds=91
#debounceThresholdMilliseconds=500
summaryIntervalKeyPresses=500

scriptFolder="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sourceFile="$scriptFolder/keyboard-chatter-tool.swift"
binaryFile="$scriptFolder/keyboard-chatter-tool-mac"
logFile="${CHATTER_LOG:-$scriptFolder/keyboard-chatter-tool.log}"
agentLabel="local.keyboard-chatter-tool"
plistFile="$scriptFolder/$agentLabel.plist"

# Building over a running executable fails with ETXTBSY; replacing the directory entry does not.
if [[ ! -x "$binaryFile" || "$sourceFile" -nt "$binaryFile" ]]; then
    swiftc -O -o "$binaryFile.new" "$sourceFile"
    mv -f "$binaryFile.new" "$binaryFile"
fi

cat > "$plistFile" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$agentLabel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>exec $binaryFile $chatterThresholdMilliseconds $summaryIntervalKeyPresses ${debounceThresholdMilliseconds:-} >> $logFile 2>&amp;1</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST

ln -sf "$plistFile" "$HOME/Library/LaunchAgents/$agentLabel.plist"
launchctl bootout "gui/$UID/$agentLabel" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/$agentLabel.plist"
echo "Loaded $agentLabel, threshold ${chatterThresholdMilliseconds}ms, summary every ${summaryIntervalKeyPresses} key presses, logging to $logFile"
