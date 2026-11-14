/// Why a window's desktop is being decided.
public enum RouteReason: Equatable {
    /// A new window (or an app launch).
    case appeared
    /// Fremspace started (not at login).
    case startup
    /// ⌃⌥⌘R.
    case reapply
    /// The first start of Fremspace in a login session, or "Restore everything now".
    case login
    /// The owner took the window to another desktop by hand (Mission Control), from `from`.
    case handMoved(from: ConfiguredDesktop)
}

public enum Route: Equatable {
    case stay
    case send(ConfiguredDesktop)
}

/// Which desktop a window belongs on (spec Part A), `here` being the configured desktop it is on (nil
/// when unconfigured) and `available` the configured desktops present now. In order:
/// - windows Fremspace does not manage stay;
/// - at login a window goes back to its remembered desktop;
/// - a window moved by hand goes back only when its slot there is locked and no command sent it
///   (`heldSlot`: the slot it held on the desktop it left; unknown, the first slot there that
///   takes it, which with a locked and an unlocked slot for one app depended on their order);
/// - a window on a free or unconfigured desktop stays; so does one on its remembered desktop, or on a
///   desktop where it matches a slot; so does one on its remembered desktop when that place was the
///   owner's choice (`rememberedDeliberately`: a command, a hand move, a free desktop), not a slot a
///   later configuration no longer gives it;
/// - a window on an ignored display (`onIgnoredDisplay`; macOS reopened it there) does not stay for
///   that reason: it goes where the next rule says, like a window on a desktop that is not its own;
/// - else it goes to its remembered desktop (when it has a slot there, or a command put it there),
///   or the first desktop with a matching slot; with none it stays;
/// - with `noFloating` (a general setting; owner, 2026-11-10: Messages sitting on "Code"), a desktop
///   with a layout keeps only the windows that have a slot there and those a command sent: the
///   others do not stay because they were remembered there, do not come back there at login, and,
///   with no slot anywhere, go to a free desktop (of their display first, else of any display). A
///   window dropped there by hand does not stay either (owner, 2026-11-10; "Send to desktop" is the
///   way to put one there). Fixed-size windows (Calculator) go too, though they never take a slot:
///   to the first desktop where their app has a slot (a mail reminder joins the mail window), else to
///   a free one. Windows of an app that has a slot on the desktop stay, whatever its profile or title
///   rule: they are that app's own side windows;
/// - on ⌃⌥⌘R, a window on a free desktop whose remembered place is a slot of another desktop goes
///   back to it: nobody put it on the free desktop, or the free desktop would be its remembered place;
/// - a window on a free or unconfigured desktop whose app was just given a slot (`givenASlot`: the
///   save that did it, once) goes to that slot, unless a command put it where it is;
/// - an app the owner lets float (`floatingApps`, a general setting; owner, 2026-11-13: a Finder
///   window opened from "Code" left for the free desktop) is outside both pulls: `noFloating` does
///   not send its windows away, and on a desktop with a layout where it has no slot a window of
///   it stays instead of going to a slot of its app elsewhere. What holds a window still holds
///   it: a locked slot it is dragged out of, its remembered desktop at login.
public func route(window: WindowInfo, on here: ConfiguredDesktop?, reason: RouteReason, configuration: Configuration,
                  remembered: ConfiguredDesktop?, rememberedDeliberately: Bool = true, heldSlot: String? = nil,
                  sentByCommand: Bool,
                  onIgnoredDisplay: Bool = false, noFloating: Bool = false, floatingApps: Set<String> = [],
                  givenASlot: Bool = false,
                  available: Set<ConfiguredDesktop>) -> Route {
    let floats = floatingApps.contains(window.bundleID)
    // For an app that may float, the setting is as good as off.
    let noFloating = noFloating && !floats
    // A fixed-size window takes no slot: only `noFloating` moves it, to a free desktop.
    let slotless = !window.isManageable
    guard !slotless || (noFloating && window.canChangeDesktop) else { return .stay }
    func layout(_ desktop: ConfiguredDesktop) -> Layout? {
        guard let display = displaySpec(for: desktop.display, in: configuration),
              display.spaces.indices.contains(desktop.index) else { return nil }
        return display.spaces[desktop.index].layout
    }
    func hasSlot(_ desktop: ConfiguredDesktop) -> Bool {
        layout(desktop)?.slots.contains { matches($0, window) } ?? false
    }
    func send(_ target: ConfiguredDesktop) -> Route {
        target == here || !available.contains(target) ? .stay : .send(target)
    }

    /// With `noFloating`, a desktop with a layout where the window has no slot is not its place.
    func mayNotFloat(_ desktop: ConfiguredDesktop) -> Bool {
        noFloating && !sentByCommand && layout(desktop) != nil && !hasSlot(desktop)
    }

    /// A slot of the window's app is on that desktop, whatever its profile or title rule.
    func holdsApp(_ desktop: ConfiguredDesktop) -> Bool {
        layout(desktop)?.slots.contains { $0.rules.contains { $0.bundleID == window.bundleID } } == true
    }
    /// The first desktop that is there and passes `test`: of `here`'s display first, else of any.
    func firstDesktop(from here: ConfiguredDesktop, where test: (ConfiguredDesktop) -> Bool) -> ConfiguredDesktop? {
        let displays = configuration.displays.filter { $0.identity == here.display }
            + configuration.displays.filter { $0.identity != here.display }
        for display in displays where !display.ignored {
            for index in display.spaces.indices {
                let desktop = ConfiguredDesktop(display: display.identity, index: index)
                if available.contains(desktop), test(desktop) { return desktop }
            }
        }
        return nil
    }

    /// The first free desktop for a window that may not float on `here`, nil when it may.
    func freeDesktop(from here: ConfiguredDesktop) -> Route? {
        guard mayNotFloat(here), !holdsApp(here) else { return nil }
        return firstDesktop(from: here) { layout($0) == nil }.map(send)
    }
    if slotless {
        guard let here, mayNotFloat(here), !holdsApp(here) else { return .stay }
        // Its app has a slot elsewhere: the window belongs beside it (owner, 2026-11-12: a mail
        // reminder that opened on "Code" went to the free desktop).
        if let home = firstDesktop(from: here, where: holdsApp) { return send(home) }
        return freeDesktop(from: here) ?? .stay
    }

    if reason == .login, let remembered, available.contains(remembered), !mayNotFloat(remembered) {
        return send(remembered)
    }
    if case .handMoved(let from) = reason {
        let slots = layout(from)?.slots ?? []
        let slot = slots.first { $0.id == heldSlot } ?? slots.first { matches($0, window) }
        if slot?.locked == true && !sentByCommand { return send(from) }
        // Elsewhere a hand move is the owner's will. With no floating, a desktop with a layout does
        // not keep the window: it goes where the rules below say.
        guard let here, mayNotFloat(here) else { return .stay }
    }
    // A free desktop keeps what is on it, with one exception: the app was just given a slot
    // (`givenASlot`, the save that did it). Its window may sit on the free desktop only for want
    // of a slot, sent there by `noFloating` (owner, 2026-11-13: Slack got its slot back and its
    // window stayed on the free desktop). What a command put there stays.
    let pulled = givenASlot && !sentByCommand && !floats && !(here.map { layout($0) != nil } ?? false)
    // And a second one, for ⌃⌥⌘R: the window's remembered place is a slot on another desktop. The
    // owner did not put it on the free desktop, or that would be its remembered place (a move by
    // hand and a command record it, without a slot): its app or macOS did (a browser showing its
    // windows again after a restart of the Mac). Owner, 2026-11-14: ⌃⌥⌘R left three such windows
    // where they were, and only "Restore everything now" sent them back.
    let strayed = reason == .reapply && !sentByCommand && !floats && !rememberedDeliberately
        && (here.map { layout($0) == nil } ?? false)
        && (remembered.map { $0 != here && available.contains($0) && hasSlot($0) } ?? false)
    if !onIgnoredDisplay, !pulled, !strayed {
        guard let here, layout(here) != nil else { return .stay }
        if hasSlot(here) { return .stay }
        if remembered == here, rememberedDeliberately || sentByCommand, !mayNotFloat(here) { return .stay }
        if floats { return .stay }
    }
    if let remembered, available.contains(remembered), hasSlot(remembered) || sentByCommand {
        return send(remembered)
    }
    for display in configuration.displays {
        for index in display.spaces.indices {
            let desktop = ConfiguredDesktop(display: display.identity, index: index)
            if available.contains(desktop), hasSlot(desktop) { return send(desktop) }
        }
    }
    return here.flatMap(freeDesktop) ?? .stay
}
