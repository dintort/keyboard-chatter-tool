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

An unsigned build is ad-hoc signed by the linker, and its designated requirement is the binary's own
code hash - so every rebuild is a new identity to TCC and the Input Monitoring grant is dropped.
Editing only the constants in the shell script avoids a rebuild and keeps the grant.

To stop re-granting altogether, sign with a real certificate. Copy `.env.example` to `.env` and set
`CHATTER_CODESIGN_IDENTITY` to an identity from `security find-identity -v -p codesigning`, quoted. The
requirement then becomes identifier plus team and survives rebuilds. `.env` is git-ignored, as the
identity names its owner. Approve the keychain prompt with **Always Allow**, or unattended rebuilds
will block on it.

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

Two intervals are measured per key press. `downToDown` is press to press; `upToDown` is release to
the next press, so `downToDown` is `upToDown` plus however long the key was held. Every threshold
names the interval it applies to.

Logging fires when either interval is short. Suppression needs **both** to be short, and stays off
until you set `downToDownDebounceThresholdMilliseconds` and `upToDownDebounceThresholdMilliseconds`
together - one without the other is rejected. A suppressed press is still logged.

Neither interval separates the two populations on its own:

- `upToDown` alone catches bounce but also swallows held-key repeats. Arrows and Backspace are held
  for 60-120 ms, so a leisurely 250 ms repeat rate still leaves only ~50 ms between release and the
  next press - indistinguishable from bounce.
- `downToDown` alone misses any bounce that follows a long press, because the hold time pushes the
  interval past the threshold.

Requiring both is what separates them: bounce is a short cycle *and* a short gap, while a held-key
repeat is a long cycle with a short gap. The cost is that bounce after a long hold is logged but not
suppressed - for those, only the switch can be fixed.

Measure before setting either value, and mind what the detector can see. While logging triggers only
on `downToDown`, nothing above that threshold is recordable, so bounce following a long hold is
invisible however often it happens. Run with a generous `upToDownLogThresholdMilliseconds` as well,
or the range you measure is bounded by your own cutoff rather than by the switch.

Measure with debounce off. Suppression changes how many times you press, and puts you in the business
of checking whether a press landed, so the sample stops describing how you normally type. Measure
during ordinary work too - a session of deliberate hammering describes your reflexes, not your usage.

On the reference keyboard, 270 logged events across 6500 key presses of normal work:

| Population  | n   | upToDown       |
|-------------|-----|----------------|
| Bounce      | 4   | 21.6 - 36.2 ms |
| Deliberate  | 266 | 59.1 ms and up |

`downToDown` is not usable as a discriminator: bounce on release keeps the hold time of the
legitimate press before it, so it runs as long as any deliberate repeat.

### Choosing the threshold

The gap between the populations is wide and the deliberate side barely reaches into it - 1st
percentile 62.4 ms, median 89.9 ms. Anywhere in the empty band catches every bounce event for free:

| Threshold | Bounce caught | Deliberate eaten |
|-----------|---------------|------------------|
| 40 ms     | 4/4           | 0/266            |
| 50 ms     | 4/4           | 0/266            |
| 55 ms     | 4/4           | 0/266            |
| 60 ms     | 4/4           | 1/266  (0.4%)    |

Repeated keys need no special treatment: runs of Backspace, Left, Right and F7 are all in this
sample and none of them reach the bounce range. Deliberate hammering does close the gap, but it is
not how anyone works, and a threshold tuned to it eats keystrokes during real use.

Put the threshold in the middle of the band, and watch for logged events above it - those say the
bounce distribution has moved and the band needs re-measuring.

On macOS this switches the tap from listen-only to active, which needs **Accessibility** on top of
Input Monitoring; the binary exits with a message if it is missing. On Windows the hook blocks the
event outright, so nothing is re-sent and modifier combinations are untouched.
