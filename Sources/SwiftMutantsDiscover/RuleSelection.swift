// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import SwiftMutantsConfig
public import SwiftMutantsCore

/// Which of the rules this build knows about a run is asking for.
///
/// A settings file offers two ways to narrow the catalogue, and until now it honoured
/// neither: `profile` and `operators` were read, validated, written into the file `init`
/// produces with a comment explaining the tiers, and then used by nothing. Setting
/// `profile = "all"` changed no mutant, and the only way to find that out was to read the
/// source of this tool - which is precisely the failure this project exists to refuse.
///
/// Narrowing happens here rather than in the walk because a rule left out has to leave a
/// **skip** behind. A candidate that vanishes with no reason is what makes a catalogue
/// smaller than somebody expected with nothing to ask about it.
public struct RuleSelection: Sendable, Hashable {

    /// The families each tier adds to the one below it.
    ///
    /// Inclusive in the order the settings file claims, and written as what each tier
    /// *adds* so that the claim is a property of the structure rather than of three lists
    /// somebody has to keep in agreement.
    ///
    /// `balanced` is the everyday set: the operators whose survivors are almost always a
    /// real hole. `strong` adds the ones whose meaning is narrower - a package that does no
    /// bit manipulation gets only noise from bitwise rules, and a package that does wants
    /// them. `all` adds nothing yet, because the rules its tier is for - literal
    /// replacement and unary deletion - are not built; the subset relation the settings
    /// file states still holds, and will go on holding when they are.
    public static let tiers: [(tier: Configuration.Profile, adds: Set<String>)] = [
        (
            .balanced,
            [
                "comparison", "boolean-connective", "boolean-literal", "integer-arithmetic",
                "condition-decision", "concatenation",
            ]
        ),
        (.strong, ["arithmetic-assignment", "bitwise", "range-operator", "optional-handling"]),
        (.all, []),
    ]

    /// Every family this build can produce, whatever tier it is in.
    ///
    /// Derived from the tiers rather than listed again: a family added to a tier is a
    /// family this knows about, and a family in neither would otherwise be selected by
    /// nothing and reported as nothing.
    public static var everyFamily: Set<String> {
        Self.tiers.reduce(into: Set<String>()) { $0.formUnion($1.adds) }
    }

    /// The families the tier takes in.
    private let families: Set<String>

    /// The rules named outright, which answer instead of the tier when there are any.
    private let named: Set<String>

    /// Whether whole-body replacement was asked for.
    ///
    /// Its own question rather than a tier, because it is a different kind of decision: the
    /// tiers trade noise for coverage among operators, and this multiplies the catalogue by
    /// the number of declarations. A project choosing `all` has said what it wants from the
    /// operators and nothing at all about this.
    private let replacesBodies: Bool

    /// Reads a run's settings.
    public init(_ mutation: Configuration.Mutation) {
        self.named = Set(mutation.operators)
        self.replacesBodies = mutation.extreme
        var taken: Set<String> = []
        for step in Self.tiers {
            taken.formUnion(step.adds)
            if step.tier == mutation.profile { break }
        }
        self.families = taken
    }

    /// Every tier, for a caller with no settings in hand.
    ///
    /// Not body replacement, which is asked for rather than tiered - and a default is not
    /// a request. A caller with nothing written down has said nothing about whether they
    /// want the catalogue multiplied by the number of declarations in their package, and
    /// reading silence as yes is how a tool ends up doing something nobody chose.
    public static let everything = RuleSelection(Self.everyTier)

    private static var everyTier: Configuration.Mutation {
        var mutation = Configuration.Mutation()
        mutation.profile = .all
        return mutation
    }

    /// Whether a rule of this name and family is wanted, and if not, why not.
    ///
    /// A name is more specific than a tier, so naming one outside the tier offers it: a
    /// setting that quietly lost to another setting would be the same defect one level up.
    public func verdict(rule: String, family: String) -> SkipReason? {
        guard family != Self.bodies else { return replacesBodies ? nil : .outsideProfile }
        guard named.isEmpty else { return named.contains(rule) ? nil : .notSelected }
        return families.contains(family) ? nil : .outsideProfile
    }

    /// Whether a run was asked to replace whole bodies, which discovery needs before it
    /// walks a declaration rather than after it has produced a candidate: the work of
    /// deciding whether a body can be replaced is worth skipping when nobody asked.
    public var replacesWholeBodies: Bool { replacesBodies }

    /// The family that is asked for rather than tiered.
    static let bodies = "body-replacement"
}
