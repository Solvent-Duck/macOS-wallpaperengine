import AppKit
import CoreServices
import Foundation
import Testing
@testable import WallpaperEngine

/// Descriptor fixtures exercise the actual reader without starting a player,
/// accessing personal metadata or requesting Automation consent.
@MainActor
struct MediaPlayerReaderTests {
    @Test func musicMetadataDefersArtworkAndPreservesSeconds() throws {
        let properties = track(duration: 245.5)
        var requests: [String] = []
        let result = try AppleEventMediaPlayerReader.readSample(player: .music, processID: 123,
            previousTrackKey: nil, refreshArtwork: true) { object in
                let name = try propertyName(object)
                requests.append(name)
                switch name {
                case "pPlS": return NSAppleEventDescriptor(enumCode: code("kPSp"))
                case "pPos": return NSAppleEventDescriptor(double: 51.25)
                case "pALL":
                    let container = try #require(object.forKeyword(code("from")))
                    #expect(try propertyName(container) == "pTrk")
                    return properties
                default: throw UnexpectedRequest()
                }
            }
        let sample = try #require(result)
        #expect(requests == ["pPlS", "pALL", "pPos", "pALL"])
        #expect(sample.state.enabled && sample.state.playback == .paused)
        #expect(sample.state.properties.title == "Track" && sample.state.properties.artist == "Artist")
        #expect(sample.state.properties.albumTitle == "Album" && sample.state.properties.albumArtist == "Various")
        #expect(sample.state.properties.genres == "Ambient" && sample.state.properties.contentType == "music")
        #expect(sample.state.duration == 245.5 && sample.state.position == 51.25)
        guard case .music(let pid, let key) = sample.artwork else { Issue.record("Music artwork must be lazy"); return }
        #expect(pid == 123 && key == sample.trackKey)
    }

    @Test func spotifyUnitsAndArtworkRefreshPolicy() throws {
        let properties = track(duration: 180_000)
        properties.setDescriptor(NSAppleEventDescriptor(string: "https://i.scdn.co/image/cover"), forKeyword: code("aUrl"))
        func read(previous: String?, refresh: Bool) throws -> MediaPlayerSample {
            let result = try AppleEventMediaPlayerReader.readSample(player: .spotify, processID: 123,
                previousTrackKey: previous, refreshArtwork: refresh) { object in
                    switch try propertyName(object) {
                    case "pPlS": return NSAppleEventDescriptor(enumCode: code("kPSP"))
                    case "pPos": return NSAppleEventDescriptor(double: 250)
                    case "pALL": return properties
                    default: throw UnexpectedRequest()
                    }
                }
            return try #require(result)
        }
        let first = try read(previous: nil, refresh: false)
        #expect(first.state.duration == 180 && first.state.position == 180)
        guard case .remote(let url) = first.artwork else { Issue.record("Expected approved CDN artwork"); return }
        #expect(url.absoluteString == "https://i.scdn.co/image/cover")
        let unchanged = try read(previous: first.trackKey, refresh: false)
        guard case .unchanged = unchanged.artwork else { Issue.record("Should reuse accepted artwork"); return }
        properties.setDescriptor(NSAppleEventDescriptor(string: "https://127.0.0.1/image"), forKeyword: code("aUrl"))
        let refreshed = try read(previous: first.trackKey, refresh: true)
        guard case .absent = refreshed.artwork else { Issue.record("Unapproved artwork URL must be rejected"); return }
    }

    @Test func trackChangeIncludingArtistDiscardsMixedMetadata() throws {
        var records = 0
        let sample = try AppleEventMediaPlayerReader.readSample(player: .music, processID: 123,
            previousTrackKey: nil, refreshArtwork: true) { object in
                switch try propertyName(object) {
                case "pPlS": return NSAppleEventDescriptor(enumCode: code("kPSP"))
                case "pPos": return NSAppleEventDescriptor(double: 5)
                case "pALL":
                    records += 1
                    return track(artist: records == 1 ? "Artist" : "Different Artist")
                default: throw UnexpectedRequest()
                }
            }
        #expect(sample == nil)
    }

    @Test func stoppedPlayerDoesNotReadTrackAndInvalidTimelineIsSanitized() throws {
        var calls = 0
        let stoppedResult = try AppleEventMediaPlayerReader.readSample(player: .music, processID: 123,
            previousTrackKey: nil, refreshArtwork: true) { object in
                calls += 1
                let name = try propertyName(object)
                #expect(name == "pPlS")
                return NSAppleEventDescriptor(enumCode: code("kPSS"))
            }
        let stopped = try #require(stoppedResult)
        #expect(calls == 1 && stopped.state.playback == .stopped && stopped.state.enabled)
        #expect(stopped.state.properties.title.isEmpty)
        let invalidResult = try AppleEventMediaPlayerReader.readSample(player: .music, processID: 123,
            previousTrackKey: nil, refreshArtwork: true) { object in
                switch try propertyName(object) {
                case "pPlS": return NSAppleEventDescriptor(enumCode: code("kPSP"))
                case "pPos": return NSAppleEventDescriptor(double: -.infinity)
                case "pALL": return track(duration: .nan)
                default: throw UnexpectedRequest()
                }
            }
        let invalid = try #require(invalidResult)
        #expect(invalid.state.duration == 0 && invalid.state.position == 0)
    }

    @Test func musicArtworkValidatesBothTrackReadsAndObjectNesting() throws {
        let expectedKey = "music:identifier\u{1f}Track\u{1f}Artist\u{1f}Album"
        let bytes = Data([1, 2, 3, 4])
        for changeAfterArtwork in [false, true] {
            var requests: [String] = []
            let result = try AppleEventMediaPlayerReader.readMusicArtwork(trackKey: expectedKey) { object in
                let name = try propertyName(object)
                requests.append(name)
                if name == "pALL" {
                    return track(artist: changeAfterArtwork && requests.count == 3 ? "Changed" : "Artist")
                }
                #expect(name == "pRaw")
                let art = try #require(object.forKeyword(code("from")))
                #expect(art.descriptorType == typeObjectSpecifier)
                #expect(art.forKeyword(code("want"))?.typeCodeValue == code("cArt"))
                #expect(art.forKeyword(code("form"))?.enumCodeValue == code("indx"))
                #expect(art.forKeyword(code("seld"))?.int32Value == 1)
                let container = try #require(art.forKeyword(code("from")))
                #expect(try propertyName(container) == "pTrk")
                return try #require(NSAppleEventDescriptor(descriptorType: code("tdta"), data: bytes))
            }
            #expect(requests == ["pALL", "pRaw", "pALL"])
            #expect(result == (changeAfterArtwork ? nil : bytes))
        }
        var calls = 0
        let stale = try AppleEventMediaPlayerReader.readMusicArtwork(trackKey: "obsolete") { _ in
            calls += 1
            return track()
        }
        #expect(stale == nil && calls == 1)
    }

    @Test func oversizedArtworkDescriptorIsRejectedBeforeCopyAndDecode() throws {
        var calls = 0
        let result = try AppleEventMediaPlayerReader.readMusicArtwork(trackKey: "music:identifier\u{1f}Track\u{1f}Artist\u{1f}Album") { object in
            calls += 1
            if try propertyName(object) == "pALL" { return track() }
            return try #require(NSAppleEventDescriptor(descriptorType: code("tdta"), data: Data(count: MediaArtworkDecoder.maximumInputBytes + 1)))
        }
        #expect(result == nil && calls == 2)
    }

    @Test func artworkCancellationStopsBeforeTheNextAppleEvent() throws {
        for cancelAfterRead in 0...3 {
            var calls = 0
            let result = try AppleEventMediaPlayerReader.readMusicArtwork(
                trackKey: "music:identifier\u{1f}Track\u{1f}Artist\u{1f}Album",
                isCancelled: { calls >= cancelAfterRead }) { object in
                    calls += 1
                    if try propertyName(object) == "pALL" { return track() }
                    return try #require(NSAppleEventDescriptor(descriptorType: code("tdta"), data: Data([1])))
                }
            #expect(result == nil && calls == cancelAfterRead)
        }
    }

    private func track(artist: String = "Artist", duration: Double = 180) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        for (key, value) in ["pPIS": "identifier", "ID  ": "spotify:track:test", "pnam": "Track", "pArt": artist,
                             "pAlb": "Album", "pAlA": "Various", "pGen": "Ambient"] {
            record.setDescriptor(NSAppleEventDescriptor(string: value), forKeyword: code(key))
        }
        record.setDescriptor(NSAppleEventDescriptor(double: duration), forKeyword: code("pDur"))
        return record
    }

    private func propertyName(_ object: NSAppleEventDescriptor) throws -> String {
        #expect(object.descriptorType == typeObjectSpecifier)
        #expect(object.forKeyword(code("want"))?.typeCodeValue == code("prop"))
        #expect(object.forKeyword(code("form"))?.enumCodeValue == code("prop"))
        let value = try #require(object.forKeyword(code("seld"))).typeCodeValue
        return String(bytes: [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)], encoding: .ascii)!
    }

    private func code(_ value: String) -> OSType { value.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
    private struct UnexpectedRequest: Error {}
}
