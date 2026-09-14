// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsCore
import Testing

@testable import SwiftMutantsReport

/// A page somebody opens.
///
/// One file, no network, no build step. A report that fetched a script from a CDN would be
/// a report that shows nothing on a locked-down machine, in an air-gapped build, or in five
/// years - and a mutation report's whole job is to be read by somebody who was not there
/// when it was made.
///
/// It shows the code with the survivors marked on it, because a list of line numbers is a
/// list of places to go and look, and the looking is the work.
@Suite("The HTML report")
struct HtmlReportTests {

    static func report(_ results: [(Outcome, [String])]) -> RunReport {
        RunReportTests.report(
            results: results.map { RunReportTests.Fixture.result($0.0, tests: $0.1) })
    }

    static func page(_ results: [(Outcome, [String])] = [(.survived, [])]) -> String {
        HtmlReport.page(
            of: Self.report(results),
            sources: ["Sources/Codec/Header.swift": "let a=1\nab< b\n"]
        )
    }

    @Test("is a page a browser will open")
    func isAPage() {
        let page = Self.page()
        #expect(page.hasPrefix("<!DOCTYPE html>"))
        #expect(page.contains("</html>"))
    }

    /// The whole point of a single file. A report that reached for a script is a report
    /// that shows nothing on a machine that will not let it.
    @Test("asks the network for nothing")
    func noNetwork() {
        let page = Self.page()
        for reach in ["http://", "https://", "<script src", "<link rel=\"stylesheet\"", "@import"] {
            #expect(!page.contains(reach), "it reaches for \(reach)")
        }
    }

    @Test("says what the run found")
    func saysTheScore() {
        let page = Self.page([(.killed, ["P.S/a()"]), (.survived, [])])
        #expect(page.contains("50.00%"))
        #expect(page.contains("<b>1</b> killed"))
        #expect(page.contains("<b>1</b> survived"))
    }

    /// A list of line numbers is a list of places to go and look. The looking is the work,
    /// so the page does it.
    @Test("shows the code the survivors are in")
    func showsTheCode() {
        #expect(Self.page().contains("ab&lt; b"))
    }

    @Test("marks each survivor where it is")
    func marksSurvivors() {
        let page = Self.page([(.survived, [])])
        #expect(page.contains("Sources/Codec/Header.swift"))
        #expect(page.contains("&lt; -&gt; &lt;="))
    }

    /// The two kinds of survivor want different work, so the page says which is which.
    @Test("tells a survivor nothing reached from one nothing noticed")
    func twoKindsOfSurvivor() {
        let page = Self.page([(.survived, []), (.survived, ["P.S/a()"])])
        #expect(page.contains("no test reaches"))
        #expect(page.contains("nothing noticed"))
    }

    /// Source is somebody's code and a report is a file they may publish. A `<` that
    /// survives into the markup is a page that renders wrongly at best and runs somebody
    /// else's script at worst.
    @Test("escapes what it puts in the markup")
    func escapesEverything() {
        let page = HtmlReport.page(
            of: Self.report([(.survived, [])]),
            sources: ["Sources/Codec/Header.swift": "let a=1\nx<script>alert(1)</script>\n"]
        )
        #expect(!page.contains("<script>alert(1)</script>"))
        #expect(page.contains("&lt;script&gt;"))
    }

    @Test("says so plainly when nothing survived")
    func nothingSurvived() {
        #expect(Self.page([(.killed, ["P.S/a()"])]).contains("Nothing survived"))
    }

    /// A file it has no source for still gets its survivors listed, because where they are
    /// is worth knowing even when the code cannot be shown.
    @Test("lists a survivor whose file it could not read")
    func withoutASource() {
        let page = HtmlReport.page(of: Self.report([(.survived, [])]), sources: [:])
        #expect(page.contains("Sources/Codec/Header.swift"))
        #expect(page.contains("2:3"))
    }

    /// One mutant in a named file, for the ordering test below.
    static func mutant(in path: String) -> RunReport.Mutant {
        RunReport.Mutant(
            id: String(repeating: "a", count: 64),
            path: path,
            line: .init(1),
            column: .init(1),
            span: RunReport.Span(start: 0, end: 1),
            rule: "lt-to-le@1",
            original: "<",
            replacement: "<=",
            outcome: "survived",
            killedBy: [],
            ran: [],
            testsStarted: 0,
            attempts: 1,
            durationMilliseconds: 1,
            index: 1
        )
    }

    /// Two pages of the same run are the same page, for the same reason two reports are.
    /// The part that could differ between processes is the order the files come out in - a
    /// dictionary enumerates one way in this process and another in the next - so that is
    /// what is asserted.
    @Test("puts its files in one order")
    func deterministic() {
        let paths = ["c.swift", "a.swift", "b.swift"]
        let page = HtmlReport.files(
            paths.map(Self.mutant(in:)),
            in: Dictionary(uniqueKeysWithValues: paths.map { ($0, "x\n") })
        )
        let places = paths.sorted().compactMap { page.range(of: "<h2>\($0)</h2>")?.lowerBound }
        #expect(places.count == paths.count)
        #expect(places == places.sorted())
    }

}
