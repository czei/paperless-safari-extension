import Foundation

/// Static configuration values that must be the same on both macOS and iOS.
///
/// `backgroundUploadIdentifier` MUST stay stable across app launches: the OS
/// uses it to reattach completed uploads (which may have run while the app
/// was terminated) to the current process. Changing the string mid-flight
/// loses pending transfers.
public enum PaperlessClientConfig {
    public static let backgroundUploadIdentifier = "org.czei.PaperlessClipper.upload"

    /// Pre-flight: a server URL must be HTTPS. Plain HTTP is rejected per
    /// FR-014. (Self-signed certs trusted at the OS level remain acceptable
    /// because the channel is still encrypted.)
    public static func isAcceptableServerScheme(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }
}
