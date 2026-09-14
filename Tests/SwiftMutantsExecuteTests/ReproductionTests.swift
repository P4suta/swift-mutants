// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftMutantsBuild
import SwiftMutantsRunner
import Testing

@testable import SwiftMutantsExecute

/// The command somebody pastes to watch one mutant run.
///
/// The point of the line is that it is the one that ran. A command assembled separately by
/// whatever prints it would be a plausible-looking line that works until the day the runner
/// adds a flag, and then it silently runs a different program - the mutant behaves
/// differently under the debugger than it did in the report, and nobody can tell why.
///
/// So there is one function that builds the invocation, the trial uses it, and anything
/// that wants to show somebody the command asks it. This is what holds those together.
@Suite("Reproducing one mutant")
struct ReproductionTests {

    static let plan = TestPlan(
        executable: "/tmp/tree/.build/debug/PTests.xctest/Contents/MacOS/PTests",
        arguments: ["--quiet"],
        environment: ["PATH": "/usr/bin"],
        directory: "/tmp/tree",
        eventStreamVersion: "6.3"
    )

    static func specification(
        waking indices: [UInt32] = [7], onlyTests: [String]? = ["P.S/a()"]
    ) -> ProcessSpec {
        Launch(
            plan: Self.plan,
            worker: 2,
            timeout: .seconds(30)
        ).specification(
            writingEventsTo: "/tmp/pipe",
            waking: indices,
            onlyTests: onlyTests
        )
    }

    /// The trial runs what this builds. Not "something like it": the same value.
    @Test("the trial runs exactly what this builds")
    func theTrialRunsThis() async throws {
        let fake = try ScriptedBundle.fake(failingFor: [])
        defer { fake.cleanUp() }
        let trial = Trial(
            plan: fake.plan,
            runner: SchedulerTests.runner(),
            scratch: fake.scratch,
            timeout: .seconds(30),
            worker: 2
        )
        let launch = Launch(plan: fake.plan, worker: 2, timeout: .seconds(30))
        #expect(
            trial.specification(writingEventsTo: "/tmp/pipe", waking: [7], onlyTests: ["P.S/a()"])
                == launch.specification(
                    writingEventsTo: "/tmp/pipe",
                    waking: [7],
                    onlyTests: ["P.S/a()"]
                )
        )
    }

    @Test("wakes the mutant it was asked for, and nothing else")
    func wakesOne() {
        #expect(Self.specification().environment["SWIFT_MUTANTS_ACTIVE"] == "7")
        #expect(Self.specification(waking: []).environment["SWIFT_MUTANTS_ACTIVE"] == nil)
        #expect(Self.specification(waking: [7, 9]).environment["SWIFT_MUTANTS_ACTIVE"] == "7,9")
    }

    /// One `--filter` per test rather than one alternation, so no identifier has to survive
    /// being spliced into a bigger pattern.
    @Test("names each test it was asked for, one flag at a time")
    func namesEachTest() {
        let arguments = Self.specification(onlyTests: ["P.S/a()", "P.S/b()"]).arguments
        #expect(arguments.count { $0 == "--filter" } == 2)
        #expect(arguments.contains(Prober.exactly("P.S/a()")))
    }

    /// Absent means the whole suite, which is what a run without coverage does.
    @Test("names no test when it was given none")
    func namesNoTest() {
        #expect(!Self.specification(onlyTests: nil).arguments.contains("--filter"))
    }

    /// The three flags that are about watching a run rather than running one.
    @Test("asks for the events it has to watch")
    func asksForEvents() {
        let arguments = Self.specification().arguments
        #expect(arguments.contains("--event-stream-output-path"))
        #expect(arguments.contains("--event-stream-version"))
        #expect(arguments.contains("--no-parallel"))
        // And the plan's own arguments come first, which is what makes them the plan's.
        #expect(arguments.first == "--quiet")
    }

    /// A line somebody pastes needs a shell, and a shell needs the quoting. A path with a
    /// space in it is ordinary on a Mac, and an unquoted one runs a different program.
    @Test("renders a line a shell would run")
    func rendersAShellLine() {
        let rendered = ProcessSpec.rendered(
            Launch(
                plan: TestPlan(
                    executable: "/tmp/my tree/PTests",
                    arguments: [],
                    environment: [:],
                    directory: "/tmp/my tree",
                    eventStreamVersion: "6.3"
                ),
                worker: 0,
                timeout: nil
            ).specification(
                writingEventsTo: "/dev/null",
                waking: [7],
                onlyTests: ["P.S/a()"]
            ))
        #expect(rendered.contains("'/tmp/my tree/PTests'"))
        #expect(rendered.contains("SWIFT_MUTANTS_ACTIVE=7"))
        #expect(rendered.contains("--filter"))
    }

    /// Only the variables this tool sets. A line carrying somebody's whole environment
    /// would be unreadable, and a line carrying their secrets would be worse.
    @Test("carries only the variables this tool sets")
    func carriesOnlyOurVariables() {
        let rendered = ProcessSpec.rendered(Self.specification())
        #expect(!rendered.contains("PATH="))
        #expect(rendered.contains("SWIFT_MUTANTS=1"))
        #expect(rendered.contains("SWIFT_MUTANTS_TEST_TOKEN=2"))
    }
}

/// Which variables a line somebody reads carries.
///
/// Two kinds, and only two. The ones this tool sets to wake a mutant, and the ones it
/// worked out so that the bundle can be loaded at all - on a Mac the test bundle is a
/// dylib that needs `Testing.framework` on its search path, and without it the command
/// fails with `Library not loaded` and looks like a bug in the package. Found exactly that
/// way, by pasting the line this generates.
///
/// Everything else a run inherited stays out. A line carrying somebody's whole environment
/// would be unreadable, and one carrying their tokens would end up in a bug report.
@Suite("What a reproduce line carries")
struct RenderedEnvironmentTests {

    static func spec(_ environment: [String: String]) -> ProcessSpec {
        Launch(
            plan: TestPlan(
                executable: "/tmp/w/PTests",
                arguments: [],
                environment: environment,
                directory: "/tmp/w"
            ),
            worker: 0,
            timeout: nil
        ).specification(
            writingEventsTo: "/dev/null",
            waking: [7],
            onlyTests: nil
        )
    }

    @Test("carries a variable it was told to show")
    func carriesWhatItIsShown() {
        let rendered = ProcessSpec.rendered(
            Self.spec(["DYLD_FRAMEWORK_PATH": "/p/f", "SECRET": "x"]),
            showing: ["DYLD_FRAMEWORK_PATH"]
        )
        #expect(rendered.contains("DYLD_FRAMEWORK_PATH=/p/f"))
        #expect(!rendered.contains("SECRET"))
    }

    @Test("carries the ones this tool sets without being told")
    func alwaysCarriesOurs() {
        let rendered = ProcessSpec.rendered(Self.spec([:]), showing: [])
        #expect(rendered.contains("SWIFT_MUTANTS_ACTIVE=7"))
    }

    /// In a fixed order, so two runs of the same package produce the same line and a
    /// difference between two lines is a difference that matters.
    @Test("puts them in one order")
    func oneOrder() {
        let rendered = ProcessSpec.rendered(
            Self.spec(["DYLD_LIBRARY_PATH": "/b", "DYLD_FRAMEWORK_PATH": "/a"]),
            showing: ["DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"]
        )
        // Alphabetical, so FRAMEWORK comes before LIBRARY however the dictionary was built.
        let framework = rendered.range(of: "DYLD_FRAMEWORK_PATH")?.lowerBound
        let library = rendered.range(of: "DYLD_LIBRARY_PATH")?.lowerBound
        #expect(framework != nil)
        #expect(library != nil)
        #expect(framework.flatMap { first in library.map { first < $0 } } == true)
    }

    /// A path with a space in it is ordinary on a Mac, and an unquoted one sets a different
    /// variable and runs a different program.
    @Test("quotes a value a shell would split")
    func quotesAValue() {
        let rendered = ProcessSpec.rendered(
            Self.spec(["DYLD_FRAMEWORK_PATH": "/my platform/Frameworks"]),
            showing: ["DYLD_FRAMEWORK_PATH"]
        )
        #expect(rendered.contains("DYLD_FRAMEWORK_PATH='/my platform/Frameworks'"))
    }
}
