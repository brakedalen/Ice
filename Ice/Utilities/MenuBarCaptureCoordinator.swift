//
//  MenuBarCaptureCoordinator.swift
//  Ice
//

import Foundation

/// Serializes icon capture and shares an in-flight batch with callers requesting
/// the same sections. All state transitions are synchronous on the main actor.
@MainActor
final class MenuBarCaptureCoordinator<Section: Hashable & Sendable> {
    private struct Request {
        let requestedSections: Set<Section>
        var sections: Set<Section>
        let continuation: CheckedContinuation<Void, Never>
    }

    private let operation: @MainActor (Set<Section>, UInt64) async -> Void
    private let diagnosticLog: (String) -> Void
    private var requests = [UUID: Request]()
    private var worker: Task<Void, Never>?
    private var activeCapture: Task<Void, Never>?
    private var batchNumber: UInt64 = 0

    private(set) var generation: UInt64 = 0

    var pendingRequestCount: Int { requests.count }

    init(
        operation: @escaping @MainActor (Set<Section>, UInt64) async -> Void,
        diagnosticLog: @escaping (String) -> Void = { _ in }
    ) {
        self.operation = operation
        self.diagnosticLog = diagnosticLog
    }

    /// Invalidate the active snapshot, keeping its callers queued for a fresh
    /// capture after the cancelled API call has actually returned.
    func invalidate(reason: String) {
        generation &+= 1
        for id in Array(requests.keys) {
            guard var request = requests[id] else { continue }
            request.sections = request.requestedSections
            requests[id] = request
        }
        if let activeCapture, !activeCapture.isCancelled {
            diagnosticLog("CAPTURE_QUEUE state=invalidated reason=\(reason) generation=\(generation)")
            activeCapture.cancel()
        }
    }

    func request(_ sections: Set<Section>) async {
        guard !sections.isEmpty, !Task.isCancelled else {
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation may happen before the operation starts. Check
                // again before registering; the cancellation handler removes
                // registered requests on this same actor.
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                requests[id] = Request(requestedSections: sections, sections: sections, continuation: continuation)
                if worker == nil {
                    worker = Task { await self.drainRequests() }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelRequest(id) }
        }
    }

    private func cancelRequest(_ id: UUID) {
        guard let request = requests.removeValue(forKey: id) else {
            return
        }
        request.continuation.resume()
        if requests.isEmpty {
            activeCapture?.cancel()
        }
    }

    private func drainRequests() async {
        defer { worker = nil }

        while !requests.isEmpty {
            let sections = requests.values.reduce(into: Set<Section>()) {
                $0.formUnion($1.sections)
            }
            let startedGeneration = generation
            let startedAt = ProcessInfo.processInfo.systemUptime
            batchNumber &+= 1
            let batch = batchNumber
            diagnosticLog(
                "CAPTURE_QUEUE state=start batch=\(batch) generation=\(startedGeneration) " +
                "sections=\(sections.count) callers=\(requests.count)"
            )

            let capture = Task { await operation(sections, startedGeneration) }
            activeCapture = capture
            await capture.value
            activeCapture = nil

            // A cancellation releases its own caller promptly, but the owned
            // API task must finish before another capture is allowed to start.
            let isCurrent = generation == startedGeneration && !capture.isCancelled
            var completed = 0
            if isCurrent {
                for id in Array(requests.keys) {
                    guard var request = requests[id] else { continue }
                    request.sections.subtract(sections)
                    if request.sections.isEmpty {
                        requests.removeValue(forKey: id)
                        request.continuation.resume()
                        completed += 1
                    } else {
                        requests[id] = request
                    }
                }
            }

            let duration = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            diagnosticLog(
                "CAPTURE_QUEUE state=end batch=\(batch) current=\(isCurrent) " +
                "completed=\(completed) pending=\(requests.count) durationMs=\(duration)"
            )
        }
    }
}
