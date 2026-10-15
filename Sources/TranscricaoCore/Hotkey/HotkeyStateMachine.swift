// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Raw input for the hotkey state machine. Timestamps are monotonic seconds
/// (NSEvent.timestamp / ProcessInfo.systemUptime).
public enum HotkeyEvent: Equatable {
    case keyDown(TimeInterval)
    case keyUp(TimeInterval)
    /// Any non-hotkey key was pressed (e.g. Option used as a modifier: ⌥+E).
    case otherKey
    case escape
    /// Periodic/explicit timer tick used to close the double-tap window.
    case tick(TimeInterval)
}

public enum HotkeyAction: Equatable {
    case startCapture
    case stopAndProcess
    case cancel
}

/// Hold = push-to-talk; double tap = continuous until the next tap.
/// Capture starts on the first key down so no words are lost; an isolated
/// short tap is cancelled once the double-tap window closes.
public struct HotkeyStateMachine {
    public enum State: Equatable {
        case idle
        case pressed(at: TimeInterval)
        case awaitingSecondTap(releasedAt: TimeInterval)
        case continuous
    }

    public static let holdThreshold: TimeInterval = 0.25
    public static let doubleTapWindow: TimeInterval = 0.40

    public private(set) var state: State = .idle

    public init() {}

    public var isContinuous: Bool { state == .continuous }

    /// Forces the machine back to idle (e.g. capture was stopped by something other than the key).
    public mutating func reset() { state = .idle }

    public mutating func handle(_ event: HotkeyEvent) -> [HotkeyAction] {
        switch (state, event) {
        case (.idle, .keyDown(let t)):
            state = .pressed(at: t)
            return [.startCapture]
        case (.idle, _):
            return []

        case (.pressed(let start), .keyUp(let t)):
            if t - start >= Self.holdThreshold {
                state = .idle
                return [.stopAndProcess]
            }
            state = .awaitingSecondTap(releasedAt: t)
            return []

        case (.awaitingSecondTap(let released), .keyDown(let t)):
            if t - released <= Self.doubleTapWindow {
                state = .continuous
                return []
            }
            state = .pressed(at: t)
            return [.cancel, .startCapture]
        case (.awaitingSecondTap(let released), .tick(let t)):
            if t - released >= Self.doubleTapWindow {
                state = .idle
                return [.cancel]
            }
            return []

        case (.continuous, .keyDown):
            state = .idle
            return [.stopAndProcess]

        case (.pressed, .otherKey), (.awaitingSecondTap, .otherKey):
            state = .idle
            return [.cancel]

        case (_, .escape):
            state = .idle
            return [.cancel]

        default:
            return []
        }
    }
}
