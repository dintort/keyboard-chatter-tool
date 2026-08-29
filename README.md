# keyboard-chatter-tool

Measures, records, and blocks keyboard chatter - one physical key press registering twice. macOS and Windows.

Logs only chatter events and periodic counts. It never records the keystroke stream.

## Measure before you block

Most chatter tools jump straight to suppression with a guessed threshold. A guess that is too low
misses real chatter; too high and it eats keystrokes you meant to type.

There are two populations, and they are separable on your own hardware:

| Population                                   | Typical range |
|----------------------------------------------|---------------|
| Chatter                                      | 40 - 90 ms    |
| Same key pressed twice while typing normally | 140 - 200 ms  |

Run the logger for a few days of ordinary work, then set the threshold in the empty band between
them. Fast repeats of Backspace and the arrow keys are the ones to check - they are the fastest
deliberate repeats most people produce.

## Files

| File                          | Purpose                                                                     |
|-------------------------------|-----------------------------------------------------------------------------|
| `keyboard-chatter-tool.swift` | macOS logger, `CGEventTap` at HID level                                     |
| `keyboard-chatter-tool.sh`    | Builds the binary, generates a LaunchAgent, reloads it. Holds all constants |
| `keyboard-chatter-tool.ahk`   | Windows logger, AutoHotkey v2. Constants at top of file                     |
| `keyboard-chatter-tool.html`  | Browser page for deliberate hammer-testing, any OS                          |

## macOS

```sh
./keyboard-chatter-tool.sh && tail -f keyboard-chatter-tool.log
```

Builds the binary, writes the LaunchAgent and starts it. Then grant the binary **Input Monitoring**
in System Settings > Privacy & Security - without it the event tap is created but silently receives
nothing.

The binary, the log and the generated LaunchAgent plist are written next to the script, and are all
git-ignored.

Rebuilding the binary changes its code hash and macOS drops the Input Monitoring grant. Editing only
the constants in the shell script avoids a rebuild.

`launchd` cannot execute or open files under `~/Documents`; keep the tool elsewhere.

## Windows

Run `keyboard-chatter-tool.ahk` with AutoHotkey v2. For auto-start, put a shortcut in
`shell:startup`. Constants live at the top of the file.

Stream the log in PowerShell:
`Get-Content -Wait -Tail 20 keyboard-chatter-tool.log`

## Output

```
2026-08-23T14:03:49Z keyCode=49 key=Space delta=48.1ms
2026-08-23T14:03:59Z keyCode=34 key=i delta=67.3ms
2026-08-27T22:31:56Z summary: 3 chatter events / 500 key presses
```

Held keys are filtered out, so auto-repeat is never counted as chatter.

## Debounce

Both scripts carry `debounceThresholdMilliseconds` parameter.
Set it and a repeat closer than that is swallowed rather than only logged.
Chatter is still logged either way, so the two thresholds are independent - log wide, suppress narrow.

Measure first. A suppression threshold above your own fastest deliberate repeat eats keystrokes you
meant to type, and arrow keys are the fastest, not Backspace.

On macOS this switches the tap from listen-only to active, which needs **Accessibility** on top of
Input Monitoring; the binary exits with a message if it is missing. On Windows the hook blocks the
event outright, so nothing is re-sent and modifier combinations are untouched.
