-- SPDX-FileCopyrightText: 2026 swift-mutants contributors
-- SPDX-License-Identifier: MIT OR Apache-2.0

import Measurement

private def checkFixture (path header : String) (rows : List String) : IO Unit := do
  let expected := String.intercalate "\n" (header :: rows) ++ "\n"
  let actual ← IO.FS.readFile path
  unless actual == expected do
    throw (IO.userError s!"{path} differs from the checked measurement model")

def main : IO Unit := do
  checkFixture "verdicts.csv" "timedOut,trustworthy,inventory,failed,verdict,outcome"
    MeasurementPolicy.verdictRows
  checkFixture "scores.csv" "killed,survived,rejected,timedOut,errored,numerator,denominator"
    MeasurementPolicy.scoreRows
  let checked ← IO.Process.output {cmd := "leanchecker", args := #["--fresh", "Measurement"]}
  unless checked.exitCode == 0 do
    throw (IO.userError s!"Proof replay failed:\n{checked.stdout}\n{checked.stderr}")
  IO.println "Checked 24 verdict classes and 32 score classes."
