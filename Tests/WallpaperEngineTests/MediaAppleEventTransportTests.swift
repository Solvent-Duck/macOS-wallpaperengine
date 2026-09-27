import AppKit
import CoreServices
import Synchronization
import Testing
@testable import WallpaperEngine

/// Exercises real queued Apple Event delivery against this test process. No
/// external player, personal media or consent prompt is involved.
@MainActor
@Suite(.serialized)
struct MediaAppleEventTransportTests {
    @Test func cancelledQueuedArtworkReadsDoNotExecute() async {
        let queue = DispatchQueue(label: "WEMediaArtworkQueueTest")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let reads = Mutex<[Int]>([])
        let tasks = (0..<20).map { index in
            Task {
                await AppleEventMediaPlayerReader.performArtworkRead(on: queue) { _ in
                    reads.withLock { $0.append(index) }
                    return Data([UInt8(index)])
                }
            }
        }
        // Allow requests to enqueue behind the blocked worker, then cancel all
        // obsolete tracks. Only the current request should perform any I/O.
        for _ in 0..<20 { await Task.yield() }
        for task in tasks.dropLast() { task.cancel() }
        gate.signal()
        for task in tasks.dropLast() { #expect(await task.value == nil) }
        #expect(await tasks.last?.value == Data([19]))
        #expect(reads.withLock { $0 } == [19])
    }

    @Test func readerDeliversPIDAddressedGetEventsAndParsesReplies() async throws {
        _ = NSApplication.shared
        let handler = FixtureHandler()
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(handler, andSelector: #selector(FixtureHandler.handle(_:reply:)),
            forEventClass: AEEventClass(kAECoreSuite), andEventID: AEEventID(kAEGetData))
        defer { manager.removeEventHandler(forEventClass: AEEventClass(kAECoreSuite), andEventID: AEEventID(kAEGetData)) }
        let reader = AppleEventMediaPlayerReader()
        let result = await reader.read(player: .music, processID: ProcessInfo.processInfo.processIdentifier,
            previousTrackKey: nil, refreshArtwork: true)
        guard case .sample(let sample) = result else {
            Issue.record("Self-addressed Apple Event read failed: \(result)")
            return
        }
        #expect(handler.properties.withLock { $0 } == ["pPlS", "pALL", "pPos", "pALL"])
        #expect(sample.state.properties.title == "Transport fixture")
        #expect(sample.state.playback == .playing)
        #expect(sample.state.position == 17 && sample.state.duration == 120)
        guard case .music(let pid, _) = sample.artwork else { Issue.record("Expected deferred Music artwork"); return }
        #expect(pid == ProcessInfo.processInfo.processIdentifier)
    }

    @MainActor
    private final class FixtureHandler: NSObject {
        let properties = Mutex<[String]>([])
        // Self-addressed events are dispatched synchronously on the sender's
        // utility queue, not on the main actor like a normal AppKit UI callback.
        @objc nonisolated func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let object = event.paramDescriptor(forKeyword: keyDirectObject),
                  let property = object.forKeyword(AppleEventMediaPlayerReader.code("seld")) else {
                reply.setParam(NSAppleEventDescriptor(int32: Int32(errAEDescNotFound)), forKeyword: keyErrorNumber)
                return
            }
            let value = property.typeCodeValue
            let name = String(bytes: [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)], encoding: .ascii) ?? ""
            properties.withLock { $0.append(name) }
            let result: NSAppleEventDescriptor
            switch name {
            case "pPlS": result = NSAppleEventDescriptor(enumCode: AppleEventMediaPlayerReader.code("kPSP"))
            case "pPos": result = NSAppleEventDescriptor(double: 17)
            case "pALL":
                result = .record()
                result.setDescriptor(NSAppleEventDescriptor(string: "Transport fixture"), forKeyword: AppleEventMediaPlayerReader.code("pnam"))
                result.setDescriptor(NSAppleEventDescriptor(string: "fixture"), forKeyword: AppleEventMediaPlayerReader.code("pPIS"))
                result.setDescriptor(NSAppleEventDescriptor(double: 120), forKeyword: AppleEventMediaPlayerReader.code("pDur"))
            default:
                reply.setParam(NSAppleEventDescriptor(int32: Int32(errAEDescNotFound)), forKeyword: keyErrorNumber)
                return
            }
            reply.setParam(result, forKeyword: keyDirectObject)
        }
    }
}
