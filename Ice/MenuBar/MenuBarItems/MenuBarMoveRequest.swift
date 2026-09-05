//
//  MenuBarMoveRequest.swift
//  Ice
//

import Foundation

/// Revalidates the caller's intent after asynchronous work and before starting
/// another synthetic drag. Existing callers without a predicate keep their
/// normal move behavior; temporary rehide requests can lose ownership.
@MainActor
struct MenuBarMoveRequest {
    struct Invalidated: Error { }

    private let isValid: (() -> Bool)?
    private let maximumAttempts: Int?

    var hasValidityCondition: Bool { isValid != nil }

    init(isValid: (() -> Bool)?, maximumAttempts: Int? = nil) {
        self.isValid = isValid
        self.maximumAttempts = maximumAttempts
    }

    /// A rehide round sends at most one drag; its lifetime budget and delay
    /// are owned by TemporaryRehideRetryState, not the inner move loop.
    func attemptLimit(default defaultLimit: Int) -> Int {
        min(defaultLimit, max(1, maximumAttempts ?? defaultLimit))
    }

    func checkValidity() throws {
        try Task.checkCancellation()
        guard isValid?() != false else {
            throw Invalidated()
        }
    }
}
