#!/usr/bin/env bash
set -euo pipefail

chatterThresholdMilliseconds=90
#chatterThresholdMilliseconds=500
#debounceThresholdMilliseconds=92
#debounceThresholdMilliseconds=500
summaryIntervalKeyPresses=500

scriptFolder="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sourceFile="$scriptFolder/keyboard-chatter-tool.swift"
binaryFile="$scriptFolder/keyboard-chatter-tool-mac"
logFolder="${CHATTER_LOG_FOLDER:-$scriptFolder}"
agentLabel="local.keyboard-chatter-tool"
plistFile="$scriptFolder/$agentLabel.plist"

touch "$logFolder/keyboard-chatter-tool.log"

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
        <string>exec $binaryFile $chatterThresholdMilliseconds $summaryIntervalKeyPresses $logFolder ${debounceThresholdMilliseconds:-}</string>
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
# Bootout returns before the service is deregistered, and bootstrapping over it fails with EIO.
for _ in $(seq 50); do
    launchctl print "gui/$UID/$agentLabel" >/dev/null 2>&1 || break
    sleep 0.1
done
launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/$agentLabel.plist"
echo "Loaded $agentLabel, threshold ${chatterThresholdMilliseconds}ms, debounce ${debounceThresholdMilliseconds:-off}, summary every ${summaryIntervalKeyPresses} key presses, logging to $logFolder/keyboard-chatter-tool.log"
