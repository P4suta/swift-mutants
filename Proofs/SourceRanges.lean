-- SPDX-FileCopyrightText: 2026 swift-mutants contributors
-- SPDX-License-Identifier: MIT OR Apache-2.0

import Init

set_option autoImplicit false

namespace SourceRanges

def wrap (bound value : Int) : Int :=
  if value < bound then value else value - (bound + bound)

def shifted (bound start finish distance : Int) : Option (Int × Int) :=
  let first := wrap bound (start + distance)
  let last := wrap bound (finish + distance)
  if 0 ≤ first ∧ first ≤ last then some (first, last) else none

def specified (bound start finish distance : Int) : Option (Int × Int) :=
  if 0 ≤ start + distance ∧ start + distance ≤ finish + distance ∧ finish + distance < bound then
    some (start + distance, finish + distance)
  else none

theorem no_negative_overflow (bound start distance : Int)
    (nonnegative : 0 ≤ start) (lower : -bound ≤ distance) : -bound ≤ start + distance := by
  have shiftedLower : distance ≤ start + distance := by
    simpa using Int.add_le_add_right nonnegative distance
  exact Int.le_trans lower shiftedLower

theorem shifted_matches_spec (bound start finish distance : Int)
    (ordered : start ≤ finish) (ending : finish < bound) (upper : distance < bound) :
    shifted bound start finish distance = specified bound start finish distance := by
  by_cases fits : finish + distance < bound
  · have firstFits : start + distance < bound :=
      Int.lt_of_le_of_lt (Int.add_le_add_right ordered distance) fits
    simp [shifted, specified, wrap, fits, firstFits]
  · have negative : wrap bound (finish + distance) < 0 := by
      simp only [wrap, ite_eq_right fits]
      exact Int.sub_neg_of_lt (Int.add_lt_add ending upper)
    have invalid : ¬(0 ≤ wrap bound (start + distance) ∧
        wrap bound (start + distance) ≤ wrap bound (finish + distance)) := by
      intro accepted
      exact Int.not_le_of_gt negative (Int.le_trans accepted.1 accepted.2)
    simp [shifted, specified, invalid, fits]

theorem shifting_contract (bound start finish distance : Int)
    (nonnegative : 0 ≤ start) (ordered : start ≤ finish) (ending : finish < bound)
    (lower : -bound ≤ distance) (upper : distance < bound) :
    (-bound ≤ start + distance ∧ -bound ≤ finish + distance) ∧
      shifted bound start finish distance = specified bound start finish distance := by
  have firstLower := no_negative_overflow bound start distance nonnegative lower
  exact ⟨⟨firstLower, Int.le_trans firstLower (Int.add_le_add_right ordered distance)⟩,
    shifted_matches_spec bound start finish distance ordered ending upper⟩

/-- info: 'SourceRanges.no_negative_overflow' depends on axioms: [propext] -/
#guard_msgs in
#print axioms no_negative_overflow

/-- info: 'SourceRanges.shifted_matches_spec' depends on axioms: [propext] -/
#guard_msgs in
#print axioms shifted_matches_spec

/-- info: 'SourceRanges.shifting_contract' depends on axioms: [propext] -/
#guard_msgs in
#print axioms shifting_contract

def offsets : List Int := [0, 1, 2, 7, 9223372036854775806, 9223372036854775807]

def distances : List Int :=
  [-9223372036854775808, -9223372036854775807, -7, -1, 0, 1, 7,
    9223372036854775806, 9223372036854775807]

def rows : List String :=
  offsets.flatMap fun start =>
    (offsets.filter fun finish => start ≤ finish).flatMap fun finish =>
      distances.map fun distance =>
        let result := match shifted 9223372036854775808 start finish distance with
          | none => ["nil", "nil"]
          | some (first, last) => [toString first, toString last]
        String.intercalate "," ([toString start, toString finish, toString distance] ++ result)

end SourceRanges

