import Foundation
import Testing
@testable import RhinoCore

/// `ScriptVersions` and `LineDiff`: keeping, merging and forgetting versions, and comparing texts by line.
@Suite struct VersionTests {
    private func makeVersions(limit: Int = 100) -> ScriptVersions {
        ScriptVersions(directory: FileManager.default.temporaryDirectory.appending(path: "rhino-versions-\(UUID().uuidString)"), limit: limit)
    }

    @Test func keepsTheStateBeforeTheFirstChange() throws {
        let versions = makeVersions()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try versions.record("two", of: "m", reason: .ai("Make it two"), previous: "one", now: start)
        #expect(first?.reason == .ai("Make it two"))

        // Nothing was kept yet, so how it was before is kept too: there is always a way back.
        let all = versions.versions(of: "m")
        #expect(all.map(\.source) == ["two", "one"])
        #expect(all.map(\.reason) == [.ai("Make it two"), .original])
        #expect(all[1].date < all[0].date)

        // The same source again is not a new version; neither is a blank "before".
        #expect(try versions.record("two", of: "m", reason: .edit, now: start.addingTimeInterval(5)) == nil)
        #expect(try versions.record("x", of: "other", reason: .edit, previous: "  \n", now: start) != nil)
        #expect(versions.versions(of: "other").count == 1)
    }

    @Test func oneBurstOfEditingIsOneVersion() throws {
        let versions = makeVersions()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try versions.record("a", of: "m", reason: .ai("Start"), now: start)
        try versions.record("ab", of: "m", reason: .edit, now: start.addingTimeInterval(60))
        try versions.record("abc", of: "m", reason: .edit, now: start.addingTimeInterval(120))
        #expect(versions.versions(of: "m").map(\.source) == ["abc", "a"])

        // Much later it is a new sitting, and an AI change never replaces anything.
        try versions.record("abcd", of: "m", reason: .edit, now: start.addingTimeInterval(120 + 3600))
        try versions.record("fixed", of: "m", reason: .repair, now: start.addingTimeInterval(120 + 3601))
        try versions.record("fixed!", of: "m", reason: .edit, now: start.addingTimeInterval(120 + 3602))
        #expect(versions.versions(of: "m").map(\.source) == ["fixed!", "fixed", "abcd", "abc", "a"])
    }

    @Test func forgetsTheOldestAndWholeScripts() throws {
        let versions = makeVersions(limit: 3)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for number in 1...5 {
            try versions.record("v\(number)", of: "a script/with odd:name", reason: .ai("\(number)"), now: start.addingTimeInterval(Double(number)))
        }
        #expect(versions.versions(of: "a script/with odd:name").map(\.source) == ["v5", "v4", "v3"])

        // They survive a new instance, and each script has its own.
        let again = ScriptVersions(directory: versions.directory)
        #expect(again.versions(of: "a script/with odd:name").count == 3)
        #expect(again.versions(of: "another").isEmpty)

        let restored = try #require(again.versions(of: "a script/with odd:name").last)
        try again.record(restored.source, of: "a script/with odd:name", reason: .restore(restored.date), now: start.addingTimeInterval(10))
        #expect(again.versions(of: "a script/with odd:name").first?.reason == .restore(restored.date))

        again.removeAll(of: "a script/with odd:name")
        #expect(again.versions(of: "a script/with odd:name").isEmpty)
    }

    @Test func comparesTextsLineByLine() {
        let old = "one\ntwo\nthree\nfour"
        let new = "one\n2\nthree\nfour\nfive"
        let lines = LineDiff.lines(from: old, to: new)
        #expect(lines.map(\.text) == ["one", "two", "2", "three", "four", "five"])
        #expect(lines.map(\.kind) == [.same, .removed, .added, .same, .same, .added])

        #expect(LineDiff.lines(from: "a\nb", to: "a\nb").allSatisfy { $0.kind == .same })
        #expect(LineDiff.lines(from: "a", to: "").map(\.kind) == [.removed, .added])
        #expect(LineDiff.lines(from: "x\ny", to: "y\nx").filter { $0.kind == .same }.count == 1)
    }
}
