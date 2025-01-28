import SwiftUI
import UniformTypeIdentifiers
import OSLog

struct CrashReport: Identifiable, Codable {
    let id = UUID()
    let timestamp: Date
    let deviceModel: String
    let osVersion: String
    let appVersion: String
    let exceptionType: String
    let crashedThread: Int
    let moduleName: String
    let stackTrace: [StackFrame]
    let deviceLogs: [String]
    var suggestedFixes: [String]
    
    struct StackFrame: Identifiable, Codable {
        let id = UUID()
        let module: String
        let symbol: String
        let offset: String
        let line: Int?
    }
}

class CrashAnalyzer: ObservableObject {
    @Published private(set) var reports: [CrashReport] = []
    @Published private(set) var isAnalyzing = false
    @Published var searchText = ""
    @Published var selectedTimeRange: TimeRange = .all
    @Published var selectedDevices: Set<String> = []
    
    private let logger = Logger(subsystem: "com.cmobautomation.developer-utilities", category: "CrashAnalyzer")
    
    enum TimeRange {
        case all, lastHour, lastDay, lastWeek
        
        var description: String {
            switch self {
            case .all: return "All Time"
            case .lastHour: return "Last Hour"
            case .lastDay: return "Last 24 Hours"
            case .lastWeek: return "Last Week"
            }
        }
    }
    
    func analyzeCrashLog(_ url: URL) async throws -> CrashReport {
        let fileExtension = url.pathExtension.lowercased()
        
        switch fileExtension {
        case "crash":
            return try await analyzeIOSCrash(url)
        case "txt":
            return try await analyzeAndroidCrash(url)
        default:
            throw CrashAnalyzerError.unsupportedFormat
        }
    }
    
    private func analyzeIOSCrash(_ url: URL) async throws -> CrashReport {
        // Symbolicate crash log using symbolicatecrash
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["symbolicatecrash", url.path]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        
        try process.run()
        let outputData = try await outputPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
        let symbolicated = String(decoding: outputData, as: UTF8.self)
        
        // Parse symbolicated crash log
        return try parseCrashLog(symbolicated)
    }
    
    private func analyzeAndroidCrash(_ url: URL) async throws -> CrashReport {
        // Parse Android crash log and fetch additional context from device
        let logContent = try String(contentsOf: url)
        return try parseAndroidLog(logContent)
    }
    
    private func parseCrashLog(_ content: String) throws -> CrashReport {
        // Basic iOS crash log parsing
        var lines = content.components(separatedBy: .newlines)
        
        // Extract basic information
        guard let exceptionLine = lines.first(where: { $0.contains("Exception Type:") }),
              let moduleLine = lines.first(where: { $0.contains("Crashed Thread:") }) else {
            throw CrashAnalyzerError.parseError("Missing required crash information")
        }
        
        let exceptionType = exceptionLine.components(separatedBy: "Exception Type:").last?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
        let crashedThread = Int(moduleLine.components(separatedBy: "Crashed Thread:").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        
        // Parse stack trace
        var stackTrace: [CrashReport.StackFrame] = []
        var inStackTrace = false
        
        for line in lines {
            if line.contains("Thread") && line.contains("Crashed:") {
                inStackTrace = true
                continue
            }
            
            if inStackTrace {
                if line.isEmpty {
                    break
                }
                
                // Parse stack frame
                let components = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                if components.count >= 4 {
                    let frame = CrashReport.StackFrame(
                        module: components[1],
                        symbol: components[3...].joined(separator: " "),
                        offset: components[2],
                        line: nil
                    )
                    stackTrace.append(frame)
                }
            }
        }
        
        return CrashReport(
            timestamp: Date(),
            deviceModel: "iPhone", // You might want to extract this from the log
            osVersion: "iOS 15.0", // Extract from log
            appVersion: "1.0", // Extract from log
            exceptionType: exceptionType,
            crashedThread: crashedThread,
            moduleName: stackTrace.first?.module ?? "Unknown",
            stackTrace: stackTrace,
            deviceLogs: [],
            suggestedFixes: suggestFixes(for: exceptionType, in: stackTrace)
        )
    }
    
    private func parseAndroidLog(_ content: String) throws -> CrashReport {
        // Basic Android crash log parsing
        var lines = content.components(separatedBy: .newlines)
        
        // Find the fatal exception
        guard let fatalLine = lines.firstIndex(where: { $0.contains("FATAL EXCEPTION") }) else {
            throw CrashAnalyzerError.parseError("No fatal exception found")
        }
        
        // Extract basic information
        let exceptionLine = lines[fatalLine...]
            .first(where: { $0.contains("Exception") }) ?? "Unknown Exception"
        let exceptionType = exceptionLine.components(separatedBy: ":").first ?? "Unknown"
        
        // Parse stack trace
        var stackTrace: [CrashReport.StackFrame] = []
        var inStackTrace = false
        
        for line in lines[fatalLine...] {
            if line.contains("at ") {
                inStackTrace = true
                // Parse stack frame line
                let frameLine = line.replacingOccurrences(of: "at ", with: "")
                let components = frameLine.components(separatedBy: "(")
                
                let methodParts = components[0].trimmingCharacters(in: .whitespaces).components(separatedBy: ".")
                let module = methodParts.dropLast().joined(separator: ".")
                let symbol = methodParts.last ?? "unknown"
                
                let lineNumber: Int? = {
                    if components.count > 1,
                       let lineStr = components[1].components(separatedBy: ":").last?.replacingOccurrences(of: ")", with: "") {
                        return Int(lineStr)
                    }
                    return nil
                }()
                
                let frame = CrashReport.StackFrame(
                    module: module,
                    symbol: symbol,
                    offset: "0x0",
                    line: lineNumber
                )
                stackTrace.append(frame)
            }
            
            if inStackTrace && line.isEmpty {
                break
            }
        }
        
        return CrashReport(
            timestamp: Date(),
            deviceModel: "Android Device", // Extract from log if available
            osVersion: "Android", // Extract from log
            appVersion: "1.0", // Extract from log
            exceptionType: exceptionType,
            crashedThread: 0,
            moduleName: stackTrace.first?.module ?? "Unknown",
            stackTrace: stackTrace,
            deviceLogs: [],
            suggestedFixes: suggestFixes(for: exceptionType, in: stackTrace)
        )
    }
    
    private func suggestFixes(for exceptionType: String, in stackTrace: [CrashReport.StackFrame]) -> [String] {
        var fixes: [String] = []
        
        // Add common fixes based on exception type
        switch exceptionType.lowercased() {
        case let type where type.contains("nullpointer"):
            fixes.append("Check for null object references")
            fixes.append("Add null checks before accessing objects")
        case let type where type.contains("outofmemory"):
            fixes.append("Optimize memory usage")
            fixes.append("Check for memory leaks")
            fixes.append("Implement proper resource cleanup")
        case let type where type.contains("arrayindexoutofbounds"):
            fixes.append("Verify array indices are within bounds")
            fixes.append("Add bounds checking before array access")
        default:
            fixes.append("Review the stack trace for potential issues")
        }
        
        return fixes
    }
    
    func addReport(_ report: CrashReport) {
        reports.append(report)
    }
}

enum CrashAnalyzerError: Error {
    case unsupportedFormat
    case parseError(String)
    case symbolicationFailed(String)
} 