import Foundation
import FremspaceCore

/// The version this app says it is: the one the build wrote in the bundle, which is what an update
/// is recognised by, else the one compiled in (a binary run outside a bundle).
enum AppVersion {
    static let current: String = {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return bundled.flatMap { $0.isEmpty ? nil : $0 } ?? FremspaceCore.version
    }()
}
