import Foundation

/// Restricts Spotify-provided artwork URLs to the CDN hostname documented in
/// Spotify Web API image examples. The policy is stateless and safe to share
/// with a URLSession that performs loading off the main actor.
final class MediaArtworkURLPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static let spotifyImageHost = "i.scdn.co"

    static func allows(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == spotifyImageHost,
              url.user == nil,
              url.password == nil
        else { return false }
        return url.port == nil || url.port == 443
    }

    /// Cancelling disallowed redirects prevents URLSession from making a
    /// follow-up request outside the exact CDN policy.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.allows(request.url) ? request : nil)
    }
}
