//
//  AutomationDiagnosticLogger.swift
//  Ice
//

import Foundation
import OSLog

/// Writes a compact, human-readable diagnostic log for menu bar automation.
///
/// The unified system log remains the primary logging mechanism. This file log
/// exists so placement-memory problems can be inspected after a restart without
/// requiring a `log show` predicate or Console.app knowledge.
final class AutomationDiagnosticLogger: @unchecked Sendable {
    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    static let shared = AutomationDiagnosticLogger()

    private let queue = DispatchQueue(label: "AutomationDiagnosticLogger.queue", qos: .utility)
    private let fileManager = FileManager.default
    private let maxFileSize = 2 * 1_024 * 1_024
    private let logger = Logger(category: "AutomationDiagnosticLogger")
    private var fileHandle: FileHandle?
    private var currentFileSize = 0

    /// Location of the current diagnostic log.
    let logURL: URL

    private init() {
        let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let directoryURL = libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Ice", isDirectory: true)
        self.logURL = directoryURL.appendingPathComponent("automation.log", isDirectory: false)

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }
            currentFileSize = try fileManager.attributesOfItem(atPath: logURL.path)[.size] as? Int ?? 0
        } catch {
            logger.error("Failed to create automation diagnostic log: \(error, privacy: .public)")
        }
    }

    /// Appends a timestamped message to the diagnostic log.
    func write(_ message: String, level: Level = .info) {
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")

        queue.async { [self] in
            let timestamp = Self.timestampFormatter.string(from: Date())
            let line = "\(timestamp) [\(level.rawValue)] \(sanitized)\n"
            append(line)
        }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else {
            return
        }

        do {
            try rotateIfNeeded(adding: data.count)
            let handle = try openFileHandle()
            try handle.write(contentsOf: data)
            currentFileSize += data.count
        } catch {
            logger.error("Failed writing automation diagnostic log: \(error, privacy: .public)")
        }
    }

    /// Reuses one file descriptor instead of opening and closing the log for
    /// every line. During the OneDrive reproduction, per-line opens accounted
    /// for almost the entire diagnostic logging worker's sampled run time.
    private func openFileHandle() throws -> FileHandle {
        if let fileHandle {
            return fileHandle
        }
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        currentFileSize = Int(try handle.seekToEnd())
        fileHandle = handle
        return handle
    }

    private func rotateIfNeeded(adding byteCount: Int) throws {
        guard currentFileSize + byteCount > maxFileSize else {
            return
        }

        try fileHandle?.close()
        fileHandle = nil

        let firstBackup = logURL.appendingPathExtension("1")
        let secondBackup = logURL.appendingPathExtension("2")

        if fileManager.fileExists(atPath: secondBackup.path) {
            try fileManager.removeItem(at: secondBackup)
        }
        if fileManager.fileExists(atPath: firstBackup.path) {
            try fileManager.moveItem(at: firstBackup, to: secondBackup)
        }
        if fileManager.fileExists(atPath: logURL.path) {
            try fileManager.moveItem(at: logURL, to: firstBackup)
        }
        currentFileSize = 0
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
