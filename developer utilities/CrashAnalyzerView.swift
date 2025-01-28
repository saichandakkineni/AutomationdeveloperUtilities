import SwiftUI
import UniformTypeIdentifiers

struct CrashAnalyzerView: View {
    @StateObject private var analyzer = CrashAnalyzer()
    @State private var isDropTargeted = false
    @State private var selectedReport: CrashReport?
    @State private var exportType: ExportType?
    
    private let supportedTypes = [
        UTType("com.apple.crashreport")!,
        UTType.text,
        UTType("com.apple.ips")!
    ]
    
    enum ExportType {
        case json, markdown
    }
    
    var filteredReports: [CrashReport] {
        analyzer.reports.filter { report in
            let matchesSearch = analyzer.searchText.isEmpty ||
                report.exceptionType.localizedCaseInsensitiveContains(analyzer.searchText) ||
                report.moduleName.localizedCaseInsensitiveContains(analyzer.searchText)
            
            let matchesTimeRange: Bool = {
                switch analyzer.selectedTimeRange {
                case .all: return true
                case .lastHour: return report.timestamp > Date().addingTimeInterval(-3600)
                case .lastDay: return report.timestamp > Date().addingTimeInterval(-86400)
                case .lastWeek: return report.timestamp > Date().addingTimeInterval(-604800)
                }
            }()
            
            let matchesDevice = analyzer.selectedDevices.isEmpty ||
                analyzer.selectedDevices.contains(report.deviceModel)
            
            return matchesSearch && matchesTimeRange && matchesDevice
        }
    }
    
    var body: some View {
        HSplitView {
            // Crash list
            VStack {
                // Search and filters
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search crashes...", text: $analyzer.searchText)
                    
                    Picker("Time Range", selection: $analyzer.selectedTimeRange) {
                        ForEach([CrashAnalyzer.TimeRange.all, .lastHour, .lastDay, .lastWeek], id: \.self) { range in
                            Text(range.description).tag(range)
                        }
                    }
                }
                .padding()
                
                List(filteredReports, selection: $selectedReport) { report in
                    CrashReportRow(report: report)
                        .tag(report)
                }
            }
            .frame(minWidth: 300)
            
            // Crash details
            if let report = selectedReport {
                CrashDetailView(report: report)
            } else {
                ContentUnavailableView {
                    Label("No Crash Selected", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Select a crash report or drop a new crash log file")
                }
            }
        }
        .navigationTitle("Crash Analyzer")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    exportType = .json
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(selectedReport == nil)
                
                Button {
                    exportType = .markdown
                } label: {
                    Label("Export Markdown", systemImage: "doc.plaintext")
                }
                .disabled(selectedReport == nil)
            }
        }
        .dropDestination(
            for: Data.self,
            action: { items, _ in
                Task {
                    for item in items {
                        if let url = try? URL(dataRepresentation: item, relativeTo: nil) {
                            do {
                                let report = try await analyzer.analyzeCrashLog(url)
                                await MainActor.run {
                                    analyzer.addReport(report)
                                    selectedReport = report
                                }
                            } catch {
                                print("Failed to analyze crash log: \(error)")
                            }
                        }
                    }
                }
                return true
            },
            isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }
        )
    }
}

struct CrashReportRow: View {
    let report: CrashReport
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.exceptionType)
                .font(.headline)
            Text(report.moduleName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(report.timestamp, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct CrashDetailView: View {
    let report: CrashReport
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Crash info
                GroupBox("Crash Information") {
                    InfoRow("Exception", report.exceptionType)
                    InfoRow("Module", report.moduleName)
                    InfoRow("Thread", String(report.crashedThread))
                    InfoRow("Device", report.deviceModel)
                    InfoRow("OS Version", report.osVersion)
                    InfoRow("App Version", report.appVersion)
                }
                
                // Stack trace
                GroupBox("Stack Trace") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.stackTrace) { frame in
                            Text("\(frame.module):\(frame.symbol)")
                                .font(.system(.body, design: .monospaced))
                            if let line = frame.line {
                                Text("Line \(line)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                }
                
                // Suggested fixes
                if !report.suggestedFixes.isEmpty {
                    GroupBox("Suggested Fixes") {
                        ForEach(report.suggestedFixes, id: \.self) { fix in
                            Label(fix, systemImage: "lightbulb")
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding()
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    
    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }
    
    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .padding(.vertical, 4)
    }
}

extension CrashReport: Hashable {
    static func == (lhs: CrashReport, rhs: CrashReport) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
} 