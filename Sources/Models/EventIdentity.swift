import Foundation
import CryptoKit

/// Ledger, quota, and checkpoint identity share one lowercase SHA-256 hex face.
/// A different encoding would make two copies of the same event look distinct.
enum EventIdentity {
    static let hexLength = 64
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
}
