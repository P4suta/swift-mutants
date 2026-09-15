<!--
SPDX-FileCopyrightText: 2026 swift-mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# 0007. The shipped configuration gets its own tier, built from nothing

**Status:** accepted.

## Context

On 15 September 2026 this repository had 1137 passing tests across four tiers, and the
binary it ships died with a segmentation fault part way through measuring a real package.
The fault was inside `Validator.validate`, in `swift_retain`, and it was reproduced on two
different packages on two different machines.

Nothing that was tested could have reported it, and the reason is not that a test was
missing. It is that every tier compiled the same way:

| tier | configuration | what it drives |
| --- | --- | --- |
| unit | debug | libraries, through a scripted toolchain |
| integration | debug | a real Swift toolchain, against synthesised packages |
| toolchain | debug | Xcode, `.xctestrun`, result bundles |
| dogfood | release | the tool against itself — nightly, and not a gate |

The thing tested was not the thing shipped. An optimiser-dependent fault has no debug tier
that can see it, however many tests that tier contains, and adding a 1138th debug test
would not have changed that. This is the same failure shape the whole project is built to
refuse — a result indistinguishable from a real one — turned on the project itself.

Two further facts came out of investigating the crash, and both bear on what the gate has
to do rather than merely on whether one should exist.

**A stale build tree produces faults that look exactly like code bugs.** SwiftPM's
incremental build was observed three times on this package to leave a module compiled
against a stored-property layout a dependency no longer had. Each time the symptom was a
garbage read or a crash in `swift_retain`; each time the fix was deleting the tree. The
release tree that produced the shipped crash spanned an eighteen-hour window of source
changes and had never been deleted at all. Whether that is the cause of *this* crash can
no longer be established — see below — but a gate that built incrementally would sometimes
be measuring a tree nobody can reproduce, and a gate whose failures are sometimes
unreproducible teaches people to re-run it rather than read it.

**The compiler that produced the crashing binary no longer exists.** Xcode 27.0 finished
installing at 10:43:21; the newest object in the release tree was written at 10:38. So the
tree was built entirely by Swift 6.3.3, consistently, five minutes before the toolchain
that replaced it arrived — the crash is not a mixed-toolchain artefact, and it also cannot
be reproduced, because 6.3.3 is gone from the machine. The controlled experiment we wanted
("wipe, rebuild with the same compiler, see if it survives") has no same compiler to
rebuild with. That is written down here rather than quietly resolved in favour of the
hypothesis we already held.

## Decision

A fifth tier, `mise run gate:release`, run on every pull request. Three properties, and it
is worth little without any of them.

**Optimised.** The unit tier is compiled `-c release` and run. A library whose behaviour
changes under the optimiser fails here rather than in somebody's terminal. `-enable-testing`
is passed, because the suite uses `@testable import` in 134 places and without it a release
test build fails to load the modules rather than telling the truth about them. That costs
some cross-module optimisation, which is why the third property exists as well.

**Built from nothing.** The scratch tree is deleted first. This is not a workaround for
SwiftPM; it is what "the thing tested is the thing shipped" means when the build system's
incremental graph has been observed to be unsound across layout changes. A gate that
reproduced the mistake being gated against would prove nothing.

**In its own scratch directory.** `.build-release`, never `.build`. The debug tree belongs
to the inner loop, and a gate that wiped it would cost a full debug rebuild every time
somebody ran the gate once — which is how a gate stops being run. Separate trees are also
the only way "from nothing" is true rather than merely intended: nothing can be inherited
from a debug build if there is no debug build in the directory.

Then it runs the executable end to end against a two-function package whose answer is
known: one function a test asserts about, which must come back killed, and one nothing
asserts about, which must come back survived. Asserting on the outcome rather than on the
exit code is the point — a gate that checked only the status would pass on a tool that
found nothing and reported it politely, which is precisely the failure mode this tool
exists to detect in other people's test suites.

`dogfood` now depends on this gate and measures the binary it produced, rather than
building a second one incrementally on top of whatever tree happened to be present.

## Consequences

A pull request now pays for one optimised build of the package from nothing. That is the
most expensive gate in the repository by a wide margin, and it is the only one that can
observe the class of fault that shipped.

The `SWIFT_MUTANTS_REQUIRED_SWIFT` pin moves to 6.4 in the same change, because the 6.3
toolchain is not installable on this machine any more. A gate naming a compiler nobody can
obtain fails for a reason unrelated to the code.

What this tier still does not cover: `-enable-testing` means the tested modules are not
compiled exactly as the shipped ones are, so a fault that depends on cross-module
optimisation could pass the suite and fail the end-to-end run. The end-to-end run is the
part that would catch it, and it exercises one small package rather than the suite — so
the two halves cover different things and neither subsumes the other. If a fault is ever
found that neither sees, the answer is a third half, not a wider one of these.
