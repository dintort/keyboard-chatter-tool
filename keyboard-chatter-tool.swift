import Cocoa

func exitWithUsage() -> Never {
    FileHandle.standardError.write(Data("Usage: keyboard-chatter-tool <chatterThresholdMilliseconds> <summaryIntervalKeyPresses> [debounceThresholdMilliseconds]\n".utf8))
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
let debounceThresholdMilliseconds: Double? = argument(3) { Double($0) }
let isDebounceEnabled = debounceThresholdMilliseconds != nil

var eventTap: CFMachPort?
var lastPressTimeByKeyCode: [Int64: Double] = [:]
var lastUpTimeByKeyCode: [Int64: Double] = [:]
var suppressedKeyCodes: Set<Int64> = []
var keyPressCount = 0
var chatterEventCount = 0
var timebase = mach_timebase_info_data_t()

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

    let now = machTimeToMilliseconds(event.timestamp)
    var isSuppressed = false
    if let previousPressTime = lastPressTimeByKeyCode[keyCode] {
        let delta = now - previousPressTime
        if delta < chatterThresholdMilliseconds {
            chatterEventCount += 1
            let stamp = timestampFormatter.string(from: Date())
            let millisecondsSinceKeyUp = lastUpTimeByKeyCode[keyCode].map { now - $0 } ?? -1
            print("\(stamp) keyCode=\(keyCode) key=\(keyNameFor(event: event, keyCode: keyCode)) delta=\(String(format: "%.1f", delta))ms sinceUp=\(String(format: "%.1f", millisecondsSinceKeyUp))ms")
        }
        if let debounceThresholdMilliseconds = debounceThresholdMilliseconds, delta < debounceThresholdMilliseconds {
            isSuppressed = true
        }
    }
    keyPressCount += 1
    if keyPressCount % summaryIntervalKeyPresses == 0 {
        print("\(timestampFormatter.string(from: Date())) summary: \(chatterEventCount) chatter events / \(keyPressCount) key presses")
    }

    if isSuppressed {
        suppressedKeyCodes.insert(keyCode)
        return nil
    }
    // Measured from the last accepted press, so a burst cannot extend suppression without end.
    lastPressTimeByKeyCode[keyCode] = now
    return Unmanaged.passUnretained(event)
}

setbuf(stdout, nil)
mach_timebase_info(&timebase)

// A tap without Input Monitoring is created successfully but never receives a key event.
if !CGPreflightListenEventAccess() {
    CGRequestListenEventAccess()
    FileHandle.standardError.write(Data("Input Monitoring permission missing. Approve the prompt, or add the launching terminal under System Settings > Privacy & Security > Input Monitoring, then rerun.\n".utf8))
    exit(1)
}

// Swallowing an event needs an active tap, which macOS gates behind Accessibility as well.
if isDebounceEnabled && !AXIsProcessTrusted() {
    FileHandle.standardError.write(Data("Debounce needs Accessibility permission. Add the binary under System Settings > Privacy & Security > Accessibility, then rerun.\n".utf8))
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
    FileHandle.standardError.write(Data("Cannot create event tap. Grant the launching terminal both Input Monitoring and Accessibility in System Settings > Privacy & Security.\n".utf8))
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)
let debounceDescription = debounceThresholdMilliseconds.map { "debounce \($0) ms" } ?? "debounce off"
FileHandle.standardError.write(Data("\(timestampFormatter.string(from: Date())) started, logging key presses repeating within \(chatterThresholdMilliseconds) ms, \(debounceDescription).\n".utf8))
CFRunLoopRun()
