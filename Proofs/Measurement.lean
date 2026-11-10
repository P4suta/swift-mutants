-- SPDX-FileCopyrightText: 2026 swift-mutants contributors
-- SPDX-License-Identifier: MIT OR Apache-2.0

import Init

set_option autoImplicit false

namespace MeasurementPolicy

inductive Inventory where
  | empty | changed | matched
  deriving DecidableEq

inductive Verdict where
  | killed | survived | timedOut | invalidEvidence | noTests | changedTests
  deriving DecidableEq

def classify (timedOut trustworthy : Bool) (inventory : Inventory) (failed : Bool) : Verdict :=
  if timedOut then .timedOut
  else if !trustworthy then .invalidEvidence
  else match inventory with
    | .empty => .noTests
    | .changed => .changedTests
    | .matched => if failed then .killed else .survived

theorem killed_iff (timedOut trustworthy : Bool) (inventory : Inventory) (failed : Bool) :
    classify timedOut trustworthy inventory failed = .killed ↔
      timedOut = false ∧ trustworthy = true ∧ inventory = .matched ∧ failed = true := by
  cases timedOut <;> cases trustworthy <;> cases inventory <;> cases failed <;> decide

theorem survived_iff (timedOut trustworthy : Bool) (inventory : Inventory) (failed : Bool) :
    classify timedOut trustworthy inventory failed = .survived ↔
      timedOut = false ∧ trustworthy = true ∧ inventory = .matched ∧ failed = false := by
  cases timedOut <;> cases trustworthy <;> cases inventory <;> cases failed <;> decide

theorem timeout_dominates (trustworthy : Bool) (inventory : Inventory) (failed : Bool) :
    classify true trustworthy inventory failed = .timedOut := by
  rfl

structure Counts where
  killed : Nat
  survived : Nat
  rejected : Nat
  timedOut : Nat
  errored : Nat

def score (counts : Counts) : Option (Nat × Nat) :=
  if counts.timedOut = 0 ∧ counts.errored = 0 ∧ 0 < counts.killed + counts.survived then
    some (counts.killed, counts.killed + counts.survived)
  else none

theorem score_exists_iff (counts : Counts) :
    (∃ numerator denominator, score counts = some (numerator, denominator)) ↔
      counts.timedOut = 0 ∧ counts.errored = 0 ∧ 0 < counts.killed + counts.survived := by
  constructor
  · intro result
    rcases result with ⟨numerator, denominator, equation⟩
    unfold score at equation
    split at equation
    · assumption
    · cases equation
  · intro complete
    exact ⟨counts.killed, counts.killed + counts.survived, ite_eq_left complete⟩

theorem denominator_positive (counts : Counts) (numerator denominator : Nat)
    (result : score counts = some (numerator, denominator)) : 0 < denominator := by
  unfold score at result
  split at result
  · rename_i complete
    have pair := Option.some.inj result
    have equal : counts.killed + counts.survived = denominator := congrArg Prod.snd pair
    exact equal ▸ complete.2.2
  · cases result

theorem rejected_does_not_change_score (counts : Counts) (rejected : Nat) :
    score { counts with rejected := rejected } = score counts := by
  rfl

/-- info: 'MeasurementPolicy.killed_iff' does not depend on any axioms -/
#guard_msgs in
#print axioms killed_iff

/-- info: 'MeasurementPolicy.survived_iff' does not depend on any axioms -/
#guard_msgs in
#print axioms survived_iff

/-- info: 'MeasurementPolicy.timeout_dominates' does not depend on any axioms -/
#guard_msgs in
#print axioms timeout_dominates

/-- info: 'MeasurementPolicy.score_exists_iff' does not depend on any axioms -/
#guard_msgs in
#print axioms score_exists_iff

/-- info: 'MeasurementPolicy.denominator_positive' does not depend on any axioms -/
#guard_msgs in
#print axioms denominator_positive

/-- info: 'MeasurementPolicy.rejected_does_not_change_score' does not depend on any axioms -/
#guard_msgs in
#print axioms rejected_does_not_change_score

def Inventory.render : Inventory → String
  | .empty => "empty"
  | .changed => "changed"
  | .matched => "matched"

def Verdict.render : Verdict → String
  | .killed => "killed"
  | .survived => "survived"
  | .timedOut => "timedOut"
  | .invalidEvidence => "invalidEvidence"
  | .noTests => "noTests"
  | .changedTests => "changedTests"

def Verdict.outcome : Verdict → String
  | .killed => "killed"
  | .survived => "survived"
  | .timedOut => "timedOut"
  | .invalidEvidence | .noTests | .changedTests => "errored"

theorem public_killed_iff (timedOut trustworthy : Bool) (inventory : Inventory) (failed : Bool) :
    (classify timedOut trustworthy inventory failed).outcome = "killed" ↔
      timedOut = false ∧ trustworthy = true ∧ inventory = .matched ∧ failed = true := by
  cases timedOut <;> cases trustworthy <;> cases inventory <;> cases failed <;> decide

theorem public_survived_iff (timedOut trustworthy : Bool) (inventory : Inventory) (failed : Bool) :
    (classify timedOut trustworthy inventory failed).outcome = "survived" ↔
      timedOut = false ∧ trustworthy = true ∧ inventory = .matched ∧ failed = false := by
  cases timedOut <;> cases trustworthy <;> cases inventory <;> cases failed <;> decide

/-- info: 'MeasurementPolicy.public_killed_iff' does not depend on any axioms -/
#guard_msgs in
#print axioms public_killed_iff

/-- info: 'MeasurementPolicy.public_survived_iff' does not depend on any axioms -/
#guard_msgs in
#print axioms public_survived_iff

def renderBool (value : Bool) : String := if value then "1" else "0"

def verdictRows : List String :=
  [false, true].flatMap fun timedOut =>
    [false, true].flatMap fun trustworthy =>
      [Inventory.empty, .changed, .matched].flatMap fun inventory =>
        [false, true].map fun failed =>
          let verdict := classify timedOut trustworthy inventory failed
          String.intercalate "," [renderBool timedOut, renderBool trustworthy,
            inventory.render, renderBool failed, verdict.render, verdict.outcome]

def scoreRows : List String :=
  [0, 1].flatMap fun killed =>
    [0, 1].flatMap fun survived =>
      [0, 1].flatMap fun rejected =>
        [0, 1].flatMap fun timedOut =>
          [0, 1].map fun errored =>
            let counts : Counts := ⟨killed, survived, rejected, timedOut, errored⟩
            let fraction := match score counts with
              | none => ["nil", "nil"]
              | some (numerator, denominator) => [toString numerator, toString denominator]
            String.intercalate "," ([toString killed, toString survived, toString rejected,
              toString timedOut, toString errored] ++ fraction)

end MeasurementPolicy
