import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ScriptStorageTests {
    @Test func unpublishedWallpapersDoNotShareAnEmptyWorkshopIdentity() {
        let left = URL(fileURLWithPath: "/tmp/local-wallpaper-left")
        let right = URL(fileURLWithPath: "/tmp/local-wallpaper-right")
        let identity = SceneScriptStorage.wallpaperIdentity(workshopID: "", directory: left)
        #expect(identity == SceneScriptStorage.wallpaperIdentity(workshopID: "0", directory: left))
        #expect(identity == SceneScriptStorage.wallpaperIdentity(workshopID: nil, directory: left))
        #expect(identity != SceneScriptStorage.wallpaperIdentity(workshopID: "", directory: right))
        #expect(SceneScriptStorage.wallpaperIdentity(workshopID: "123", directory: left)
            == SceneScriptStorage.wallpaperIdentity(workshopID: "123", directory: right))
    }

    private func evaluate(_ source: String, host: ScriptHost) throws -> FrameValue {
        try host.evaluate(source: "export function update() { \(source) }", baseValue: .bool(false), properties: [:])
    }

    @Test func arbitraryJSONValuesAreCopiedAndMissingDiffersFromNull() throws {
        let host = ScriptHost()
        #expect(try evaluate("""
        if (localStorage.get('missing') !== undefined) return false;
        let data = {position: new Vec3(2, 4, 6), list: [false, null, '雪']};
        localStorage.set('__proto__', data);
        data.position.x = 100;
        let saved = localStorage.get('__proto__');
        saved.position.y = 200;
        let reread = localStorage.get('__proto__');
        localStorage.set('null', null);
        return reread.position.x === 2 && reread.position.y === 4 && reread.list[2] === '雪'
            && localStorage.get('null') === null && localStorage.get('missing') === undefined;
        """, host: host) == .bool(true))
    }

    @Test func screensShareOnlyGlobalValuesAndScopesCanBeClearedIndependently() throws {
        let storage = try SceneScriptStorage()
        let left = ScriptHost(storage: storage.forScreen("left"))
        let right = ScriptHost(storage: storage.forScreen("right"))
        #expect(try evaluate("localStorage.set('key', 1); localStorage.set('key', 8, localStorage.LOCATION_GLOBAL); return true;", host: left) == .bool(true))
        #expect(try evaluate("return localStorage.get('key') === undefined && localStorage.get('key', localStorage.LOCATION_GLOBAL) === 8;", host: right) == .bool(true))
        #expect(try evaluate("localStorage.set('key', 2); localStorage.clear(localStorage.LOCATION_GLOBAL); return localStorage.get('key') === 2;", host: right) == .bool(true))
        #expect(try evaluate("return localStorage.get('key') === 1 && localStorage.get('key', localStorage.LOCATION_GLOBAL) === undefined;", host: left) == .bool(true))
        #expect(try evaluate("return localStorage.delete('key') === true && localStorage.delete('key') === false;", host: left) == .bool(true))
        try storage.reset()
        #expect(try evaluate("return localStorage.get('key') === undefined;", host: right) == .bool(true))
    }

    @Test func valuesPersistAcrossHostsAndWallpaperIdentitiesStayIsolated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("script-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        func save() throws {
            let host = ScriptHost(storage: try SceneScriptStorage(directory: directory, wallpaperID: "one", screenID: "left"))
            #expect(try evaluate("localStorage.set('saved', 9); return true;", host: host) == .bool(true))
        }
        try save()
        let reopened = ScriptHost(storage: try SceneScriptStorage(directory: directory, wallpaperID: "one", screenID: "left"))
        #expect(try evaluate("return localStorage.get('saved') === 9;", host: reopened) == .bool(true))
        let other = ScriptHost(storage: try SceneScriptStorage(directory: directory, wallpaperID: "two", screenID: "left"))
        #expect(try evaluate("return localStorage.get('saved') === undefined;", host: other) == .bool(true))
        let anotherScreen = try SceneScriptStorage(directory: directory, wallpaperID: "one", screenID: "right")
        try anotherScreen.reset()
        #expect(try evaluate("return localStorage.get('saved') === undefined;", host: reopened) == .bool(true))
    }

    @Test func quotaFailurePreservesAllPreviousValues() throws {
        let storage = try SceneScriptStorage()
        let left = ScriptHost(storage: storage.forScreen("left"))
        let right = ScriptHost(storage: storage.forScreen("right"))
        #expect(try evaluate("localStorage.set('data', 'x'.repeat(60000)); return true;", host: left) == .bool(true))
        #expect(try evaluate("""
        localStorage.set('small', 7);
        try { localStorage.set('data', 'y'.repeat(60000)); return false; }
        catch (error) { return String(error).includes('100 KB') && localStorage.get('small') === 7 && localStorage.get('data') === undefined; }
        """, host: right) == .bool(true))
        #expect(try evaluate("return localStorage.get('data').length === 60000;", host: left) == .bool(true))
        #expect(try evaluate("let x = {}; x.self = x; try { localStorage.set('cycle', x); return false; } catch (error) { return localStorage.get('cycle') === undefined; }", host: left) == .bool(true))
    }

    @Test func destroyCanSaveBeforeSettingsResetAndFreshHostsHaveIsolatedDefaults() throws {
        let storage = try SceneScriptStorage()
        let host = ScriptHost(storage: storage)
        let source = "export function init() {} export function update() { return 1; } export function destroy() { localStorage.set('destroyed', true); }"
        _ = try host.evaluate(source: source, baseValue: .int(0), properties: [:])
        host.shutdown()
        #expect(try evaluate("return localStorage.get('destroyed') === true;", host: ScriptHost(storage: storage)) == .bool(true))
        #expect(try evaluate("return localStorage.get('destroyed') === undefined;", host: ScriptHost()) == .bool(true))
        try storage.reset()
        #expect(try evaluate("return localStorage.get('destroyed') === undefined;", host: ScriptHost(storage: storage)) == .bool(true))
    }
}
