// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// These are values too, for the same reason the report is: nothing here names anything from
// another module.

/// The rows a report is made of, and the two shapes every row is written in.
///
/// Apart from the report itself because the report is a promise about a *run* - what was
/// scoped, what the baseline did, what the totals came to - and these are a promise about
/// one row of it. A reader adding a column to the summary and a reader adding a field to a
/// mutant are doing different work, and a decoder written for a version that had neither
/// has to keep working in both cases.
extension RunReport {

    /// What became of one mutant.
    public struct Mutant: Codable, Sendable, Hashable {
        /// The whole identity, not the twenty characters a terminal shows.
        public let id: String

        /// Where it is, as the repository names the file - never as the copy did.
        public let path: String

        /// Where a person looks. `null` when the run has no line index for the file.
        public let line: Reported<Int>

        /// The column, counted in UTF-8 bytes as the compiler counts them.
        public let column: Reported<Int>
        /// Where a program looks: the bytes of the file the user wrote.
        public let span: Span

        /// Which rule produced it, with the version that took part in its identity.
        public let rule: String

        /// The bytes it replaced, as the user wrote them.
        public let original: String

        /// The bytes it put there instead.
        ///
        /// Carried so that a report says what a mutant was rather than naming a rule and a
        /// position and sending a reader back to a file that may have moved on.
        public let replacement: String

        /// What became of it.
        public let outcome: String

        /// The tests that failed with it awake, in the order their failures arrived.
        public let killedBy: [String]

        /// Which tests ran with it awake, as positions in ``RunReport/tests``.
        ///
        /// The tests that looked at a survivor and said nothing are the whole of what to do
        /// about it - one of them is where the missing assertion belongs - so a report that
        /// only counted them would leave a reader to find them among four hundred.
        public let ran: [Int]

        /// How many tests it was offered and began.
        public let testsStarted: Int

        /// How many times it had to be run. More than once means the first attempt ran out
        /// of time and was tried again on a quiet machine.
        public let attempts: Int

        /// How long the run that decided it took.
        public let durationMilliseconds: Int

        /// Which guard in the instrumented tree this mutant is.
        ///
        /// The number the runtime switches on, which is what `SWIFT_MUTANTS_ACTIVE` takes.
        /// Nothing else uses it - a mutant's identity is its name everywhere a person or a
        /// cache is concerned - but a command that wakes this mutant needs it, and working
        /// it out afterwards would mean instrumenting the tree again.
        public let index: Int

        /// Records what became of one mutant.
        public init(
            id: String,
            path: String,
            line: Reported<Int>,
            column: Reported<Int>,
            span: Span,
            rule: String,
            original: String,
            replacement: String,
            outcome: String,
            killedBy: [String],
            ran: [Int],
            testsStarted: Int,
            attempts: Int,
            durationMilliseconds: Int,
            index: Int
        ) {
            self.id = id
            self.path = path
            self.line = line
            self.column = column
            self.span = span
            self.rule = rule
            self.original = original
            self.replacement = replacement
            self.outcome = outcome
            self.killedBy = killedBy
            self.ran = ran
            self.testsStarted = testsStarted
            self.attempts = attempts
            self.durationMilliseconds = durationMilliseconds
            self.index = index
        }
    }

    /// A half-open range of bytes.
    public struct Span: Codable, Sendable, Hashable {

        /// The first byte, counted from the start of the file the user wrote.
        public let start: Int

        /// One past the last byte.
        public let end: Int

        /// Records a half-open range of bytes.
        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    /// A value a report carries whether or not the run had one.
    ///
    /// Swift's synthesised encoding omits an optional property that is `nil`, which is the
    /// one thing a report must not do: a key that disappears when there is nothing to say
    /// leaves a reader unable to tell "nothing to say" from "this version does not say it",
    /// and those are different facts. This writes `null` and keeps the key.
    public struct Reported<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {

        /// What was measured, or nothing.
        public let value: Value?

        /// Carries a value, or the absence of one.
        public init(_ value: Value?) { self.value = value }

        /// Reads `null` as nothing and anything else as a value.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.value = container.decodeNil() ? nil : try container.decode(Value.self)
        }

        /// Writes the value, or `null` - never nothing at all.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value {
                try container.encode(value)
            } else {
                try container.encodeNil()
            }
        }
    }

    /// One mutant the compiler would not accept, in the compiler's own words.
    ///
    /// The words rather than a code, because a rejection is a fact about somebody's
    /// program and the compiler said it better than this could. They exist only while the
    /// tree is instrumented, so a report that summarised them would be the last place they
    /// were ever written down.
    public struct Refusal: Codable, Sendable, Hashable {

        /// The whole identity of the mutant that was refused.
        public let id: String

        /// Which rule produced it.
        public let rule: String

        /// Where it was.
        public let span: Span

        /// What the compiler said about it.
        public let diagnostics: [Diagnostic]
    }

    /// One thing the compiler said.
    public struct Diagnostic: Codable, Sendable, Hashable {

        /// The file the compiler named.
        public let file: String

        /// The line it named.
        public let line: Int

        /// The column it named, counted in UTF-8 bytes as the compiler counts them.
        public let column: Int

        /// `error`, `warning` or `note`.
        public let severity: String

        /// What it said, with the severity and position stripped off the front.
        public let message: String
    }
}
