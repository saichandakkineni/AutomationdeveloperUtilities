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
        isCapturing = true
        
        Task {
            do {
                switch device.type {
                case .ios:
                    try await captureIOSLogs(device: device)
                case .android:
                    try await captureAndroidLogs(device: device)
                }
            } catch {
                logger.error("Failed to start log capture: \(error.localizedDescription)")
            }
        }
    }
    
    func stopCapturing(for device: Device) {
        logProcesses[device.identifier]?.terminate()
        logProcesses.removeValue(forKey: device.identifier)
        isCapturing = false
    }
    
    private func captureIOSLogs(device: Device) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "console", device.identifier]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        
        try process.run()
        logProcesses[device.identifier] = process
        
        for try await line in outputPipe.fileHandleForReading.bytes.lines {
            await parseiOSLog(line, deviceId: device.identifier)
        }
    }
    
    private func captureAndroidLogs(device: Device) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
        process.arguments = ["-s", device.identifier, "logcat", "-v", "threadtime"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        
        try process.run()
        logProcesses[device.identifier] = process
        
        for try await line in outputPipe.fileHandleForReading.bytes.lines {
            await parseAndroidLog(line, deviceId: device.identifier)
        }
    }
    
    @MainActor
    private func parseiOSLog(_ line: String, deviceId: String) {
        // Parse iOS console log format
        let components = line.components(separatedBy: " ")
        guard components.count >= 4 else { return }
        
        let dateStr = components[0] + " " + components[1]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        guard let timestamp = formatter.date(from: dateStr) else { return }
        
        let level: LogLevel = components[2].contains("[Error]") ? .error :
                            components[2].contains("[Warning]") ? .warning :
                            components[2].contains("[Info]") ? .info : .debug
        
        let message = components[3...].joined(separator: " ")
        
        let entry = LogEntry(
            timestamp: timestamp,
            level: level,
            tag: components[2],
            message: message,
            deviceId: deviceId
        )
        
        logs.append(entry)
        if logs.count > 10000 { // Limit buffer size
            logs.removeFirst(1000)
        }
    }
    
    @MainActor
    private func parseAndroidLog(_ line: String, deviceId: String) {
        // Parse Android logcat format
        let components = line.components(separatedBy: " ").filter { !$0.isEmpty }
        guard components.count >= 7 else { return }
        
        let dateStr = components[0] + " " + components[1]
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        
        guard let timestamp = formatter.date(from: dateStr) else { return }
        
        let level = LogLevel(rawValue: components[4]) ?? .info
        let tag = components[5]
        let message = components[6...].joined(separator: " ")
        
        let entry = LogEntry(
            timestamp: timestamp,
            level: level,
            tag: tag,
            message: message,
            deviceId: deviceId
        )
        
        logs.append(entry)
        if logs.count > 10000 { // Limit buffer size
            logs.removeFirst(1000)
        }
    }
}

struct LogViewer: View {
    let device: Device
    @StateObject private var logManager = LogManager()
    @State private var searchText = ""
    @State private var selectedLevels: Set<LogLevel> = Set(LogLevel.allCases)
    @State private var autoScroll = true
    
    var filteredLogs: [LogEntry] {
        logManager.logs.filter { log in
            let matchesSearch = searchText.isEmpty || 
                log.message.localizedCaseInsensitiveContains(searchText) ||
                log.tag.localizedCaseInsensitiveContains(searchText)
            let matchesLevel = selectedLevels.contains(log.level)
            return matchesSearch && matchesLevel && log.deviceId == device.identifier
        }
    }
    
    var body: some View {
        VStack {
            // Toolbar
            HStack {
                TextField("Search logs...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                
                ForEach(LogLevel.allCases, id: \.rawValue) { level in
                    Toggle(level.rawValue, isOn: .init(
                        get: { selectedLevels.contains(level) },
                        set: { isOn in
                            if isOn {
                                selectedLevels.insert(level)
                            } else {
                                selectedLevels.remove(level)
                            }
                        }
                    ))
                    .toggleStyle(.button)
                    .tint(level.color)
                }
                
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                
                Button(logManager.isCapturing ? "Stop" : "Start") {
                    if logManager.isCapturing {
                        logManager.stopCapturing(for: device)
                    } else {
                        logManager.startCapturing(for: device)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            
            // Log list in ScrollView
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredLogs) { log in
                        LogEntryRow(entry: log)
                    }
                }
            }
            .id("LogScrollView")
            .font(.system(.body, design: .monospaced))
            .onChange(of: filteredLogs.count) {
                if autoScroll {
                    // Scroll to bottom when new logs arrive
                    NSScrollView.scrollToBottom(identifier: "LogScrollView")
                }
            }
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