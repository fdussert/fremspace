import AppKit

// `Fremspace --dump <file>` writes the "Dump windows" text and exits, without the menu bar app.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--dump") {
    let text = WindowDump.text(windows: AXWindows())
    if flag + 1 < arguments.count {
        try? text.write(toFile: arguments[flag + 1], atomically: true, encoding: .utf8)
    } else {
        print(text, terminator: "")
    }
    exit(0)
}

// `Fremspace --send <window id> <space id>` sends one window to another desktop and prints the
// result and the time it took (debug, plan 3 Task 3).
if let flag = arguments.firstIndex(of: "--send") {
    // Never fall through to the menu bar app (a second window manager) on a mistyped command.
    guard flag + 2 < arguments.count, let id = UInt32(arguments[flag + 1]), let sid = UInt64(arguments[flag + 2]) else {
        FileHandle.standardError.write(Data("usage: Fremspace --send <window id> <space id>\n".utf8))
        exit(2)
    }
    print("present: \(SpaceMover.isPresent), before: \(Spaces.spaceIDs(ofWindow: id))")
    let started = Date()
    SpaceMover.send(id, toSpace: sid) { arrived in
        print(String(format: "arrived: %@ in %.2fs, now: %@", arrived ? "yes" : "no", Date().timeIntervalSince(started),
                     "\(Spaces.spaceIDs(ofWindow: id))"))
        exit(arrived ? 0 : 1)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
