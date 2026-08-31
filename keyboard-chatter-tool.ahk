#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

upToDownLogThresholdMilliseconds := 40
upToDownChatterThresholdMilliseconds := 40
;upToDownDebounceThresholdMilliseconds := 90
;upToDownDebounceThresholdMilliseconds := 500

summaryIntervalKeyPresses := 500
logFolder := A_ScriptDir
logFile := logFolder "\keyboard-chatter-tool.log"
currentLogDateStamp := ""

; Stream the log in bash:
;  tail -F keyboard-chatter-tool.log
; Stream the log in PowerShell:
;  Get-Content -Wait -Tail 20 keyboard-chatter-tool.log


DllCall("QueryPerformanceFrequency", "Int64*", &performanceFrequency := 0)

pendingLines := []
logHandle := ""
isWriteFailed := false
lastPressTimeByKey := Map()
lastUpTimeByKey := Map()
downKeys := Map()
suppressedKeys := Map()
keyPressCount := 0
chatterEventCount := 0

CurrentMilliseconds() {
    global performanceFrequency
    DllCall("QueryPerformanceCounter", "Int64*", &counter := 0)
    return counter * 1000.0 / performanceFrequency
}

KeyIdentifierFor(virtualKey, scanCode) {
    return Format("vk{1:x}sc{2:03x}", virtualKey, scanCode)
}

; A restart after midnight must still archive what the previous day left in the active log.
; Taken from the first line rather than the modification time, which anything touching the file resets.
DateStampOfActiveLog() {
    global logFile
    if !FileExist(logFile)
        return ""
    try firstLine := FileReadLine(logFile, 1)
    catch
        return ""
    if (StrLen(firstLine) < 10)
        return ""
    return StrReplace(SubStr(firstLine, 1, 10), "-", "")
}

RotateIfNewDay() {
    global logFolder, logFile, logHandle, currentLogDateStamp, keyPressCount, chatterEventCount

    dateStamp := FormatTime(A_NowUTC, "yyyyMMdd")
    if (dateStamp = currentLogDateStamp)
        return
    if (currentLogDateStamp != "") {
        ; Lines still queued belong to the day that is ending.
        FlushLog()
        logHandle := ""
        archiveFile := logFolder "\" currentLogDateStamp "-keyboard-chatter-tool.log"
        if !FileExist(archiveFile)
            try FileMove(logFile, archiveFile)
    }
    currentLogDateStamp := dateStamp
    keyPressCount := 0
    chatterEventCount := 0
}

SummaryText() {
    global chatterEventCount, keyPressCount
    return Format("summary: {1} chatter events / {2} key presses", chatterEventCount, keyPressCount)
}

WriteLine(text) {
    global pendingLines
    pendingLines.Push(FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss") "." Format("{:03}", A_MSec) "Z " text "`n")
}

; The log can be held open by another process, and a blocking write inside the hook risks Windows dropping it.
FlushLog(*) {
    global pendingLines, logFile, logHandle, isWriteFailed
    if !pendingLines.Length
        return
    ; The hook can push a line while the write is in progress.
    lines := pendingLines
    pendingLines := []
    text := ""
    for line in lines
        text .= line
    try {
        ; Sharing is settled when the file is opened, so one handle held open outlives any reader's lock.
        if !logHandle
            logHandle := FileOpen(logFile, "a", "UTF-8")
        logHandle.Write(text)
        ; Reading the handle commits AutoHotkey's write buffer.
        flushedHandle := logHandle.Handle
        isWriteFailed := false
    } catch Error as caughtError {
        logHandle := ""
        pendingLines.InsertAt(1, lines*)
        if !isWriteFailed {
            isWriteFailed := true
            WriteLine("log write failed: " caughtError.Message)
        }
    }
}

HandleKeyDown(virtualKey, scanCode, flags) {
    global lastPressTimeByKey, lastUpTimeByKey, downKeys, suppressedKeys, keyPressCount, chatterEventCount
    global upToDownLogThresholdMilliseconds, summaryIntervalKeyPresses
    global upToDownChatterThresholdMilliseconds
    global upToDownDebounceThresholdMilliseconds

    keyIdentifier := KeyIdentifierFor(virtualKey, scanCode)
    ; A held key repeats without an intervening key-up; genuine switch bounce releases first.
    if downKeys.Has(keyIdentifier)
        return false
    downKeys[keyIdentifier] := true

    RotateIfNewDay()

    now := CurrentMilliseconds()
    keyPressCount += 1
    isSuppressed := false
    upToDown := lastUpTimeByKey.Has(keyIdentifier) ? now - lastUpTimeByKey[keyIdentifier] : -1
    ; The press before this one ended when it was released, so its hold is the rest of the interval.
    hold := (lastPressTimeByKey.Has(keyIdentifier) && upToDown >= 0)
        ? now - lastPressTimeByKey[keyIdentifier] - upToDown
        : -1
    if (upToDown >= 0 && upToDown < upToDownLogThresholdMilliseconds) {
        WriteLine(Format("key={1} {2} upToDown={3:.1f}ms hold={4:.1f}ms flags=0x{5:x}"
            , GetKeyName(keyIdentifier), keyIdentifier, upToDown
            , hold
            , flags))
        ; Logging casts a wider net than the count, so a wide window never inflates the rate.
        if (upToDown < upToDownChatterThresholdMilliseconds) {
            chatterEventCount += 1
            WriteLine(SummaryText())
        }
    }
    if (IsSet(upToDownDebounceThresholdMilliseconds) && upToDown >= 0
        && upToDown < upToDownDebounceThresholdMilliseconds)
        isSuppressed := true

    if (Mod(keyPressCount, summaryIntervalKeyPresses) = 0)
        WriteLine(SummaryText())

    lastPressTimeByKey[keyIdentifier] := now
    if (isSuppressed) {
        suppressedKeys[keyIdentifier] := true
        return true
    }
    return false
}

HandleKeyUp(virtualKey, scanCode) {
    global downKeys, suppressedKeys, lastUpTimeByKey

    keyIdentifier := KeyIdentifierFor(virtualKey, scanCode)
    lastUpTimeByKey[keyIdentifier] := CurrentMilliseconds()
    if downKeys.Has(keyIdentifier)
        downKeys.Delete(keyIdentifier)
    ; A swallowed press must take its release with it.
    if suppressedKeys.Has(keyIdentifier) {
        suppressedKeys.Delete(keyIdentifier)
        return true
    }
    return false
}

KeyboardHook(nCode, wParam, lParam) {
    if (nCode >= 0) {
        flags := NumGet(lParam, 8, "UInt")
        ; Injected events come from other software, never from a switch.
        if !(flags & 0x10) {
            virtualKey := NumGet(lParam, 0, "UInt")
            scanCode := NumGet(lParam, 4, "UInt")
            ; Arrows and their numeric-keypad twins share a scan code until the extended bit is folded in.
            if (flags & 0x01)
                scanCode += 0x100
            if (wParam = 0x100 || wParam = 0x104) {
                if HandleKeyDown(virtualKey, scanCode, flags)
                    return 1
            } else if (wParam = 0x101 || wParam = 0x105) {
                if HandleKeyUp(virtualKey, scanCode)
                    return 1
            }
        }
    }
    return DllCall("CallNextHookEx", "Ptr", 0, "Int", nCode, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

hookCallback := CallbackCreate(KeyboardHook, "Fast", 3)
hookHandle := DllCall("SetWindowsHookEx", "Int", 13, "Ptr", hookCallback
    , "Ptr", DllCall("GetModuleHandle", "Ptr", 0, "Ptr"), "UInt", 0, "Ptr")
if !hookHandle {
    MsgBox("Cannot install the low-level keyboard hook.")
    ExitApp()
}
OnExit((*) => (DllCall("UnhookWindowsHookEx", "Ptr", hookHandle), FlushLog()))

currentLogDateStamp := DateStampOfActiveLog()
RotateIfNewDay()
WriteLine(Format("started, logging upToDown under {1} ms, counting chatter under {2} ms, debounce {3}"
    , upToDownLogThresholdMilliseconds
    , upToDownChatterThresholdMilliseconds
    , IsSet(upToDownDebounceThresholdMilliseconds) ? upToDownDebounceThresholdMilliseconds " ms" : "off"))
SetTimer(FlushLog, 1000)
