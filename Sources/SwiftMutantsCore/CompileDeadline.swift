// SPDX-FileCopyrightText: 2026 swift-mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Bounds package builds using the original build's measured duration.
public enum CompileDeadline {
    /// The minimum deadline, allowing for cold builds and instrumentation overhead.
    public static let floor = Duration.seconds(300)

    /// The deadline before an original build duration is available.
    public static let unmeasured = Duration.seconds(1800)

    /// The multiple of the original build duration allowed for a later build.
    public static let builds = 10

    /// Uses the measured duration when available, with the minimum deadline as a floor.
    public static func after(_ priming: Duration?) -> Duration {
        guard let priming else { return Self.unmeasured }
        let derived = priming * Self.builds
        return derived > Self.floor ? derived : Self.floor
    }
}
