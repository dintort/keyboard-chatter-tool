import Cocoa

func exitWithUsage() -> Never {
    FileHandle.standardError.write(Data("Usage: keyboard-chatter-tool <chatterThresholdMilliseconds> <summaryIntervalKeyPresses> <logFolder> [debounceThresholdMilliseconds]\n".utf8))
    exit(2)
}

func argument<Value>(_ index: Int, _ parse: (String) -> Value?) -> Value? {
    guard index < CommandLine.arguments.count else {
        return nil
    }
    guard let value = parse(CommandLine.arguments[index]) else {
        exitWithUsage()
    }
    return value
}

func requiredArgument<Value>(_ index: Int, _ parse: (String) -> Value?) -> Value {
    guard let value: Value = argument(index, parse) else {
        exitWithUsage()
    }
    return value
}

let chatterThresholdMilliseconds = requiredArgument(1) { Double($0) }
let summaryIntervalKeyPresses = requiredArgument(2) { Int($0) }
let logFolder = requiredArgument(3) { $0 }
let debounceThresholdMilliseconds: Double? = argument(4) { Double($0) }
let isDebounceEnabled = debounceThresholdMilliseconds != nil

var eventTap: CFMachPort?
var lastPressTimeByKeyCode: [Int64: Double] = [:]
var lastUpTimeByKeyCode: [Int64: Double] = [:]
var suppressedKeyCodes: Set<Int64> = []
var keyPressCount = 0
var chatterEventCount = 0
var timebase = mach_timebase_info_data_t()
var currentLogDateStamp = ""
var logFileHandle: FileHandle?

func machTimeToMilliseconds(_ machTime: UInt64) -> Double {
    return Double(machTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
}

func characterFor(event: CGEvent) -> String {
    var actualLength = 0
    var characters = [UniChar](repeating: 0, count: 4)
    event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &actualLength, unicodeString: &characters)
    return String(utf16CodeUnits: characters, count: actualLength)
}

let keyNamesByKeyCode: [Int64: String] = [
    36: "Return", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape",
    76: "KeypadEnter", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
    101: "F9", 103: "F11", 109: "F10", 111: "F12", 115: "Home", 116: "PageUp",
    117: "ForwardDelete", 118: "F4", 119: "End", 120: "F2", 121: "PageDown",
    122: "F1", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
]

func keyNameFor(event: CGEvent, keyCode: Int64) -> String {
    if let keyName = keyNamesByKeyCode[keyCode] {
        return keyName
    }
    let characters = characterFor(event: event)
    return characters.isEmpty ? "unknown" : characters
}

let timestampFormatter = ISO8601DateFormatter()

let dateStampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

let activeLogPath = "\(logFolder)/keyboard-chatter-tool.log"

func openActiveLog() {
    if !FileManager.default.fileExists(atPath: activeLogPath) {
        FileManager.default.createFile(atPath: activeLogPath, contents: nil)
    }
    logFileHandle = FileHandle(forWritingAtPath: activeLogPath)
    logFileHandle?.seekToEndOfFile()
}

// A restart after midnight must still archive what the previous day left in the active log.
func dateStampOfActiveLog() -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: activeLogPath),
            let modificationDate = attributes[.modificationDate] as? Date else {
        return ""
    }
    return dateStampFormatter.string(from: modificationDate)
}

func rotateIfNewDay() {
    let dateStamp = dateStampFormatter.string(from: Date())
    guard dateStamp != currentLogDateStamp else {
        return
    }
    if !currentLogDateStamp.isEmpty {
        logFileHandle?.closeFile()
        logFileHandle = nil
        let archivePath = "\(logFolder)/\(currentLogDateStamp)-keyboard-chatter-tool.log"
        if !FileManager.default.fileExists(atPath: archivePath) {
            try? FileManager.default.moveItem(atPath: activeLogPath, toPath: archivePath)
        }
    }
    currentLogDateStamp = dateStamp
    keyPressCount = 0
    chatterEventCount = 0
    openActiveLog()
}

func appendLine(_ text: String) {
    logFileHandle?.write(Data("\(timestampFormatter.string(from: Date())) \(text)\n".utf8))
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    // The system silently disables a tap that is too slow or blocked; re-enable or logging dies unnoticed.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap = eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // A swallowed press must take its release with it.
    if type == .keyUp {
        lastUpTimeByKeyCode[keyCode] = machTimeToMilliseconds(event.timestamp)
        return suppressedKeyCodes.remove(keyCode) == nil ? Unmanaged.passUnretained(event) : nil
    }
    // Held-key auto-repeat carries this flag; genuine switch bounce does not.
    guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
        return Unmanaged.passUnretained(event)
    }

    rotateIfNewDay()
    let now = machTimeToMilliseconds(event.timestamp)
    var isSuppressed = false
    if let previousPressTime = lastPressTimeByKeyCode[keyCode] {
        let delta = now - previousPressTime
        if delta < chatterThresholdMilliseconds {
            chatterEventCount += 1
            let millisecondsSinceKeyUp = lastUpTimeByKeyCode[keyCode].map { now - $0 } ?? -1
            appendLine("keyCode=\(keyCode) key=\(keyNameFor(event: event, keyCode: keyCode)) delta=\(String(format: "%.1f", delta))ms sinceUp=\(String(format: "%.1f", millisecondsSinceKeyUp))ms")
        }
        if let debounceThresholdMilliseconds = debounceThresholdMilliseconds, delta < debounceThresholdMilliseconds {
            isSuppressed = true
        }
    }
    keyPressCount += 1
    if keyPressCount % summaryIntervalKeyPresses == 0 {
        appendLine("summary: \(chatterEventCount) chatter events / \(keyPressCount) key presses")
    }

    if isSuppressed {
        suppressedKeyCodes.insert(keyCode)
        return nil
    }
    // Measured from the last accepted press, so a burst cannot extend suppression without end.
    lastPressTimeByKeyCode[keyCode] = now
    return Unmanaged.passUnretained(event)
}

mach_timebase_info(&timebase)
currentLogDateStamp = dateStampOfActiveLog()
rotateIfNewDay()

// A tap without Input Monitoring is created successfully but never receives a key event.
if !CGPreflightListenEventAccess() {
    CGRequestListenEventAccess()
    appendLine("Input Monitoring permission missing. Approve the prompt, or add the binary under System Settings > Privacy & Security > Input Monitoring, then rerun.")
    exit(1)
}

// Swallowing an event needs an active tap, which macOS gates behind Accessibility as well.
if isDebounceEnabled && !AXIsProcessTrusted() {
    appendLine("Debounce needs Accessibility permission. Add the binary under System Settings > Privacy & Security > Accessibility, then rerun.")
    exit(1)
}

let eventsOfInterest = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)

eventTap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: isDebounceEnabled ? .defaultTap : .listenOnly,
    eventsOfInterest: eventsOfInterest,
    callback: tapCallback,
    userInfo: nil)

guard let eventTap = eventTap else {
    appendLine("Cannot create event tap. Grant the binary both Input Monitoring and Accessibility in System Settings > Privacy & Security.")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)
let debounceDescription = debounceThresholdMilliseconds.map { "debounce \($0) ms" } ?? "debounce off"
appendLine("started, logging key presses repeating within \(chatterThresholdMilliseconds) ms, \(debounceDescription).")
CFRunLoopRun()
