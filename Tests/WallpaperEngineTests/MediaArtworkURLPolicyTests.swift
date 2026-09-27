import Foundation
import Synchronization
import Testing
@testable import WallpaperEngine

struct MediaArtworkURLPolicyTests {
    @Test func acceptsOnlyExactSpotifyCDNHTTPSOrigin() {
        #expect(MediaArtworkURLPolicy.allows(URL(string: "https://i.scdn.co/image/abc")))
        #expect(MediaArtworkURLPolicy.allows(URL(string: "HTTPS://I.SCDN.CO:443/image/abc")))
        #expect(!MediaArtworkURLPolicy.allows(URL(string: "http://i.scdn.co/image/abc")))
        #expect(!MediaArtworkURLPolicy.allows(URL(string: "https://cdn.i.scdn.co/image/abc")))
        #expect(!MediaArtworkURLPolicy.allows(URL(string: "https://i.scdn.co.evil.example/image/abc")))
        #expect(!MediaArtworkURLPolicy.allows(URL(string: "https://i.scdn.co:444/image/abc")))
        #expect(!MediaArtworkURLPolicy.allows(URL(string: "https://user:secret@i.scdn.co/image/abc")))
        #expect(!MediaArtworkURLPolicy.allows(nil))
    }

    @Test func redirectDelegateRejectsDestinationOutsidePolicyBeforeFollow() {
        let policy = MediaArtworkURLPolicy()
        let session = URLSession(configuration: .ephemeral, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let source = URL(string: "https://i.scdn.co/image/original")!
        let task = session.dataTask(with: source)
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!

        let rejected = Mutex<URLRequest?>(nil)
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                          newRequest: URLRequest(url: URL(string: "https://evil.example/pixel")!)) { request in
            rejected.withLock { stored in stored = request }
        }
        #expect(rejected.withLock { $0 } == nil)

        let accepted = Mutex<URLRequest?>(nil)
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                          newRequest: URLRequest(url: URL(string: "https://i.scdn.co/image/replacement")!)) { request in
            accepted.withLock { stored in stored = request }
        }
        #expect(accepted.withLock { $0?.url?.host?.lowercased() } == MediaArtworkURLPolicy.spotifyImageHost)
    }
}
