import ApplicationServices

/// Accessibility is required: without it Fremspace can neither read nor move windows.
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once per launch) when the app is not trusted yet.
    static func requestAccessibilityIfNeeded() {
        guard !accessibilityGranted else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
