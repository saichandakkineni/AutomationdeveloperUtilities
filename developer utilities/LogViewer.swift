import SwiftUI
import OSLog

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let tag: String
    let message: String
    let deviceId: String
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

enum LogLevel: String, CaseIterable {
    case verbose = "V"
    case debug = "D"
    case info = "I"
    case warning = "W"
    case error = "E"
    case fatal = "F"
    
    var color: Color {
        switch self {
        case .verbose: return .secondary
        case .debug: return .primary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .fatal: return .purple
        }
    }
}

class LogManager: ObservableObject {
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var isCapturing = false
    private var logProcesses: [String: Process] = [:]
    private let logger = Logger(subsystem: "com.cmobautomation.developer-utilities", category: "LogManager")
    
    func startCapturing(for device: Device) {
        guard !isCapturing else { return }
        
        do {
            let process = try createLogProcess(for: device)
            logProcesses[device.identifier] = process
            isCapturing = true
        } catch {
            logger.error("Failed to start log capture: \(error.localizedDescription)")
        }
    }
    
    func stopCapturing(for device: Device) {
        guard let process = logProcesses[device.identifier] else { return }
        process.terminate()
        logProcesses.removeValue(forKey: device.identifier)
        isCapturing = false
    }
    
    private func createLogProcess(for device: Device) throws -> Process {
        let process = Process()
        let pipe = Pipe()
        
        if device.type == .ios {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "spawn", device.identifier, "log", "stream", "--level", "debug"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/Users/SAICHAND.Z.Akkineni@td.com/Library/Android/sdk/platform-tools/adb")
            process.arguments = ["-s", device.identifier, "logcat", "*:D"]
        }
        
        process.standardOutput = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let data = try? handle.read(upToCount: 1024),
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }
            
            DispatchQueue.main.async {
                self?.processLogLine(line, for: device)
            }
        }
        
        try process.run()
        return process
    }
    
    private func processLogLine(_ line: String, for device: Device) {
        let entry = parseLogLine(line, deviceId: device.identifier)
        logs.append(entry)
        
        // Keep only last 1000 logs for memory efficiency
        if logs.count > 1000 {
            logs.removeFirst(logs.count - 1000)
        }
    }
    
    private func parseLogLine(_ line: String, deviceId: String) -> LogEntry {
        // Basic parsing logic - enhance based on actual log format
        let components = line.components(separatedBy: " ")
        let level: LogLevel = components.first?.first.flatMap { char in
            LogLevel.allCases.first { $0.rawValue == String(char) }
        } ?? .info
        
        let tag = components.count > 2 ? components[1] : "System"
        let message = components.dropFirst(2).joined(separator: " ")
        
        return LogEntry(
            timestamp: Date(),
            level: level,
            tag: tag,
            message: message,
            deviceId: deviceId
        )
    }
}

struct LogViewer: View {
    @Environment(\.dismiss) private var dismiss
    let device: Device
    @StateObject private var logManager = LogManager()
    @State private var selectedLogLevel: LogLevel?
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var isSaving = false
    
    var filteredLogs: [LogEntry] {
        logManager.logs.filter { log in
            let matchesLevel = selectedLogLevel == nil || log.level == selectedLogLevel
            let matchesSearch = searchText.isEmpty || 
                log.message.localizedCaseInsensitiveContains(searchText) ||
                log.tag.localizedCaseInsensitiveContains(searchText)
            return matchesLevel && matchesSearch && log.deviceId == device.identifier
        }
    }
    
    var body: some View {
        VStack {
            // Back button
            HStack {
                Button(action: { dismiss() }) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.horizontal)
            
            // Controls
            HStack {
                // Log level filter
                Picker("Log Level", selection: $selectedLogLevel) {
                    Text("All").tag(nil as LogLevel?)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level as LogLevel?)
                    }
                }
                .frame(width: 100)
                
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search logs...", text: $searchText)
                }
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.1))
                }
                
                // Auto-scroll toggle
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                
                // Start/Stop button
                Button(logManager.isCapturing ? "Stop" : "Start") {
                    if logManager.isCapturing {
                        logManager.stopCapturing(for: device)
                    } else {
                        logManager.startCapturing(for: device)
                    }
                }
                .buttonStyle(.bordered)
                
                // Add Save button
                Button(action: saveLogFile) {
                    Label("Save Logs", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(filteredLogs.isEmpty || isSaving)
            }
            .padding()
            
            // Log list in ScrollView
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredLogs) { log in
                        LogEntryRow(entry: log)
                    }
                }
                .padding(.horizontal)
            }
            .id("LogScrollView")
            .font(.system(.body, design: .monospaced))
            .onChange(of: filteredLogs.count) {
                if autoScroll {
                    scrollToBottom()
                }
            }
        }
        .navigationBarBackButtonHidden(true)
    }
    
    private func scrollToBottom() {
        DispatchQueue.main.async {
            NSScrollView.scrollToBottom(identifier: "LogScrollView")
        }
    }
    
    private func saveLogFile() {
        isSaving = true
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .text]
        panel.nameFieldStringValue = "device_logs_\(timestamp).log"
        
        panel.begin { response in
            if response == .OK, let exportURL = panel.url {
                do {
                    var logContent = ""
                    for log in filteredLogs {
                        logContent += "[\(log.formattedTimestamp)] [\(log.level.rawValue)] [\(log.tag)]: \(log.message)\n"
                    }
                    try logContent.write(to: exportURL, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.activateFileViewerSelecting([exportURL])
                } catch {
                    // Handle error
                    print("Failed to save logs: \(error.localizedDescription)")
                }
            }
            isSaving = false
        }
    }
}

struct LogEntryRow: View {
    let entry: LogEntry
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.formattedTimestamp)
                .foregroundStyle(.secondary)
            
            Text(entry.level.rawValue)
                .foregroundStyle(entry.level.color)
                .fontWeight(.bold)
            
            Text(entry.tag)
                .foregroundStyle(.secondary)
            
            Text(entry.message)
                .foregroundStyle(.primary)
        }
        .textSelection(.enabled)
    }
}

// Alternative implementation with identifier
extension NSScrollView {
    static func scrollToBottom(identifier: String = "LogScrollView") {
        DispatchQueue.main.async {
            guard let scrollView = NSApp.keyWindow?.contentView?.subviews.first(where: { 
                ($0 is NSScrollView) && $0.identifier?.rawValue == identifier 
            }) as? NSScrollView else { return }
            let maxScroll = scrollView.documentView?.frame.height ?? 0
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxScroll))
        }
    }
} 