-- SPDX-FileCopyrightText: 2026 swift-mutants contributors
-- SPDX-License-Identifier: MIT OR Apache-2.0

import Measurement
import SourceRanges

private def fixture (write : Bool) (path header : String) (rows : List String) : IO Unit := do
  let expected := String.intercalate "\n" (header :: rows) ++ "\n"
  if write then
    IO.FS.writeFile path expected
    return
  let actual ← IO.FS.readFile path
  unless actual == expected do
    throw (IO.userError s!"{path} differs from the checked measurement model")

def main (args : List String) : IO Unit := do
  unless args = [] ∨ args = ["--write-fixtures"] do
    throw (IO.userError "Expected --write-fixtures or no arguments.")
  let write := args = ["--write-fixtures"]
  fixture write "verdicts.csv" "timedOut,trustworthy,inventory,failed,verdict,outcome"
    MeasurementPolicy.verdictRows
  fixture write "scores.csv" "killed,survived,rejected,timedOut,errored,numerator,denominator"
    MeasurementPolicy.scoreRows
  fixture write "ranges.csv" "start,end,distance,shiftedStart,shiftedEnd" SourceRanges.rows
  for module in ["Measurement", "SourceRanges"] do
    let checked ← IO.Process.output {cmd := "leanchecker", args := #["--fresh", module]}
    unless checked.exitCode == 0 do
      throw (IO.userError s!"Proof replay failed for {module}:\n{checked.stdout}\n{checked.stderr}")
  IO.println "Checked 24 verdict classes, 32 score classes, and 189 source shifts."
