import AppKit

/// The pages of the project the app sends the owner to, in their browser. Opening one is the
/// owner's click, never something Fremspace does by itself.
enum Links {
    /// The forms for a bug or an idea.
    static let reportProblem = URL(string: "https://github.com/fdussert/fremspace/issues/new/choose")!

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
