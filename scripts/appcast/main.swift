import CryptoKit
import Foundation
import FremspaceCore

// The release's side of updates, built and run by scripts/release.sh:
//
//   appcast feed <version> <archive-url> <archive> <ed-signature> <CHANGELOG.md>
//       prints the feed Sparkle reads, with one item: this release and its notes
//   appcast verify <file> <ed-signature> <public-key-base64>
//       fails unless the signature is the public key's over the file, which is what an installed
//       app will check
//   appcast keypair <private-key-file> <public-key-file>
//       writes a throwaway key pair in Sparkle's format, to try an update without the owner's key

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("appcast: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "feed":
    guard arguments.count == 6 else { fail("usage: feed <version> <archive-url> <archive> <ed-signature> <CHANGELOG.md>") }
    let version = arguments[1]
    guard let changelog = try? String(contentsOfFile: arguments[5], encoding: .utf8) else { fail("cannot read \(arguments[5])") }
    guard let notes = changelogSection(changelog, version: version) else {
        fail("no \"## \(version)\" section with something in it in \(arguments[5])")
    }
    guard let size = (try? FileManager.default.attributesOfItem(atPath: arguments[3]))?[.size] as? Int, size > 0 else {
        fail("cannot read \(arguments[3])")
    }
    print(appcast(version: version, url: arguments[2], length: size, signature: arguments[4],
                  notesHTML: releaseNotesHTML(notes), date: Date()), terminator: "")
case "verify":
    guard arguments.count == 4 else { fail("usage: verify <file> <ed-signature> <public-key-base64>") }
    guard let file = FileManager.default.contents(atPath: arguments[1]) else { fail("cannot read \(arguments[1])") }
    guard let signature = Data(base64Encoded: arguments[2]), let raw = Data(base64Encoded: arguments[3]), raw.count == 32,
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("the signature or the public key is not base64 (an Ed25519 public key is 32 bytes)")
    }
    guard key.isValidSignature(signature, for: file) else {
        fail("\(arguments[1]) is not signed by the key the app carries: installed apps would refuse it")
    }
case "keypair":
    guard arguments.count == 3 else { fail("usage: keypair <private-key-file> <public-key-file>") }
    let key = Curve25519.Signing.PrivateKey()
    do {
        try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: arguments[1]))
        try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: arguments[2]))
    } catch { fail("\(error.localizedDescription)") }
default:
    fail("usage: appcast feed|verify|keypair …")
}
