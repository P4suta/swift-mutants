// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// A page somebody opens.
///
/// One file, no network, no build step. A report that fetched a script from a content
/// network would show nothing on a locked-down machine, in an air-gapped build, or in five
/// years - and a mutation report's whole job is to be read by somebody who was not there
/// when it was made.
///
/// It shows the code with the survivors marked on it. A list of line numbers is a list of
/// places to go and look, and the looking is the work.
public enum HtmlReport {

    /// The whole page.
    ///
    /// `high` and `low` are the scores a project decided are good and poor. They mark the
    /// headline, which is the one number anybody reads: a page that says 63% and nothing
    /// else leaves every reader to decide privately whether that is good, and the point of
    /// writing a threshold down is that a team decides it once.
    public static func page(
        of report: RunReport, sources: [String: String], high: Int = 80, low: Int = 60
    ) -> String {
        let survivors = report.mutants.filter { $0.outcome == "survived" }
        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <title>swift-mutants</title>
            <style>
            \(Self.style)
            </style>
            </head>
            <body>
            <h1>swift-mutants</h1>
            \(Self.scoreboard(report, high: high, low: low))
            \(survivors.isEmpty ? "<p class=\"clear\">Nothing survived.</p>" : Self.files(survivors, in: sources))
            <footer>\(Self.escaped(report.tool.name)) \(Self.escaped(report.tool.version))</footer>
            </body>
            </html>
            """
    }

    /// The counts and both scores.
    ///
    /// Both, because they answer different questions and one number is actively
    /// misleading: how much of the code the tests protect, and how good the tests that
    /// exist are.
    /// Which of the three a score is, or nothing when there is no score.
    ///
    /// Nothing is not poor. A score of `N/A` means the denominator was empty - nothing was
    /// measured - and colouring that red says the tests are bad when the truth is that
    /// there was nothing for them to catch.
    ///
    /// At the threshold counts as meeting it: `high = 80` reads as "eighty is good", and a
    /// team that hits exactly eighty being told it is only fair is the kind of detail that
    /// makes somebody stop believing the page.
    ///
    /// The two are in different units, as they always were: a score is a fraction and a
    /// threshold is a percentage, because that is how everybody writes one down.
    static func standing(_ fraction: Double?, high: Int, low: Int) -> String {
        guard let fraction else { return "" }
        if fraction >= Double(high) / 100 { return " good" }
        if fraction < Double(low) / 100 { return " poor" }
        return " fair"
    }

    static func scoreboard(_ report: RunReport, high: Int, low: Int) -> String {
        let summary = report.summary
        let columns = [
            ("killed", summary.killed), ("survived", summary.survived),
            ("unreached", summary.uncovered), ("rejected", summary.rejected),
            ("timed out", summary.timedOut), ("errored", summary.errored),
        ]
        let counts = columns.map {
            "<li><b>\($0.1)</b> \(Self.escaped($0.0))</li>"
        }.joined(separator: "\n")
        return """
            <section class="score">
            <p class="headline\(Self.standing(summary.score.value, high: high, low: low))">\
            \(Self.percentage(summary.score.value))
            <span>of the code these tests protect</span></p>
            <p class="headline\
            \(Self.standing(summary.scoreOfCoveredCode.value, high: high, low: low))">\
            \(Self.percentage(summary.scoreOfCoveredCode.value))
            <span>of the code they reach</span></p>
            <ul class="counts">
            \(counts)
            </ul>
            </section>
            """
    }

    /// A fraction as a percentage, or as the absence of one.
    ///
    /// Nothing measured is written as `N/A` rather than as nought. Nought reads as "caught
    /// none" and a hundred as "caught all"; both are claims about tests that never ran.
    static func percentage(_ fraction: Double?) -> String {
        guard let fraction else { return "N/A" }
        let hundredths = Int((fraction * 10000).rounded())
        return "\(hundredths / 100).\(hundredths % 100 < 10 ? "0" : "")\(hundredths % 100)%"
    }

    /// One section per file, with its survivors marked on its code.
    static func files(_ survivors: [RunReport.Mutant], in sources: [String: String]) -> String {
        var byFile: [String: [RunReport.Mutant]] = [:]
        for mutant in survivors { byFile[mutant.path, default: []].append(mutant) }
        return byFile.keys.sorted().map { path in
            let mutants = byFile[path] ?? []
            return """
                <section class="file">
                <h2>\(Self.escaped(path))</h2>
                \(Self.list(mutants))
                \(sources[path].map { Self.code($0, marking: mutants) } ?? "")
                </section>
                """
        }.joined(separator: "\n")
    }

    /// The survivors of one file, as a list somebody can act from.
    static func list(_ mutants: [RunReport.Mutant]) -> String {
        let rows = mutants.sorted { ($0.line.value ?? 0, $0.id) < ($1.line.value ?? 0, $1.id) }
            .map { mutant in
                let place = mutant.line.value.map { "\($0):\(mutant.column.value ?? 1)" } ?? "?"
                let kind =
                    mutant.testsStarted == 0
                    ? "<span class=\"unreached\">no test reaches it</span>"
                    : "<span class=\"unnoticed\">\(mutant.testsStarted) tests ran and nothing noticed</span>"
                return """
                    <li><code>\(Self.escaped(place))</code>
                    <code class="edit">\(Self.escaped(mutant.original)) -&gt; \
                    \(Self.escaped(mutant.replacement))</code>
                    \(Self.escaped(mutant.rule)) — \(kind)
                    <code class="id">\(Self.escaped(String(mutant.id.prefix(20))))</code></li>
                    """
            }
        return "<ul class=\"mutants\">\n\(rows.joined(separator: "\n"))\n</ul>"
    }

    /// The file's code, with the lines a survivor sits on marked.
    static func code(_ source: String, marking mutants: [RunReport.Mutant]) -> String {
        let marked = Set(mutants.compactMap { $0.line.value })
        let rows = source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { number, line in
                let numbered = number + 1
                return """
                    <tr class="\(marked.contains(numbered) ? "marked" : "")">\
                    <td class="number">\(numbered)</td><td><code>\(Self.escaped(String(line)))</code></td></tr>
                    """
            }
        return "<table class=\"code\">\n\(rows.joined(separator: "\n"))\n</table>"
    }

    /// Text that cannot become markup.
    ///
    /// Source is somebody's code and a report is a file they may publish. A `<` that
    /// survives into the markup is a page that renders wrongly at best and runs somebody
    /// else's script at worst.
    static func escaped(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Everything the page looks like, because there is nowhere else to put it.
    static let style = """
        :root { color-scheme: light dark; }
        body { font: 15px/1.5 ui-sans-serif, system-ui, sans-serif; margin: 0 auto;
               max-width: 60rem; padding: 2rem 1rem; }
        h1 { font-size: 1.3rem; letter-spacing: .02em; }
        h2 { font-size: 1rem; margin: 2rem 0 .5rem; font-family: ui-monospace, monospace; }
        .score { display: flex; flex-wrap: wrap; gap: 2rem; align-items: baseline;
                 border-block: 1px solid color-mix(in srgb, currentColor 20%, transparent);
                 padding-block: 1rem; }
        .headline { font-size: 2rem; font-weight: 600; margin: 0; }
        .headline.good { color: #1a7f37; }
        .headline.fair { color: #9a6700; }
        .headline.poor { color: #b3261e; }
        .headline span { display: block; font-size: .8rem; font-weight: 400; opacity: .7; }
        .counts { list-style: none; display: flex; flex-wrap: wrap; gap: 1rem;
                  margin: 0; padding: 0; opacity: .85; }
        .mutants { list-style: none; padding: 0; }
        .mutants li { padding: .35rem 0;
                      border-bottom: 1px solid color-mix(in srgb, currentColor 12%, transparent); }
        code { font-family: ui-monospace, monospace; font-size: .85rem; }
        .edit { padding: 0 .35rem; border-radius: .25rem;
                background: color-mix(in srgb, currentColor 10%, transparent); }
        .id { opacity: .5; }
        .unreached { color: #b45309; }
        .unnoticed { color: #9333ea; }
        .clear { font-size: 1.2rem; }
        .code { border-collapse: collapse; width: 100%; margin-top: .5rem; }
        .code td { padding: 0 .5rem; vertical-align: top; white-space: pre; }
        .number { text-align: right; opacity: .4; user-select: none; width: 3rem; }
        .marked { background: color-mix(in srgb, #f59e0b 18%, transparent); }
        footer { margin-top: 3rem; opacity: .5; font-size: .8rem; }
        """
}
