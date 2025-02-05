//
//  ContentView.swift
//  developer utilities
//
//  Created by SAICHAND AKKINENI on 2025-01-27.
//

import SwiftUI

// Models for representing devices
struct Device: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: DeviceType
    let status: String
    let identifier: String
    let properties: [String: String]
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum DeviceType {
    case ios
    case android
    
    var imageName: String {
        switch self {
        case .ios: return "iphone"
        case .android: return "flipphone"
        }
    }
}

// Main content view
struct ContentView: View {
    @StateObject private var deviceManager = DeviceManager.shared
    @State private var selectedDevice: Device?
    @State private var isPerformingAction = false
    @State private var actionError: String?
    @State private var showingBundleIdPrompt = false
    @State private var bundleId = ""
    @State private var isRecording = false
    @State private var navigationPath = NavigationPath()
    
    var body: some View {
        NavigationSplitView {
            // Device List
            List(deviceManager.devices, selection: $selectedDevice) { device in
                DeviceRow(device: device)
                    .tag(device)
            }
            .navigationTitle("Devices")
        } detail: {
            if let device = selectedDevice {
                NavigationStack(path: $navigationPath) {
                    // Device Detail View
                    ScrollView {
                        VStack(spacing: 24) {
                            // Device Info
                            GroupBox("Device Information") {
                                ForEach(Array(device.properties.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                                    InfoRow(key, value)
                                }
                            }
                            
                            // Actions
                            GroupBox("Actions") {
                                VStack(spacing: 16) {
                                    // App Installation
                                    AppInstallDropZone(device: device)
                                    
                                    // Screen Recording
                                    NavigationLink(value: DeviceAction.screenRecording) {
                                        ActionButton(
                                            title: "Screen Recording",
                                            icon: "record.circle",
                                            isLoading: isPerformingAction
                                        )
                                    }
                                    
                                    // Device Logs
                                    NavigationLink(value: DeviceAction.logs) {
                                        ActionButton(
                                            title: "View Device Logs",
                                            icon: "doc.text.magnifyingglass",
                                            isLoading: isPerformingAction
                                        )
                                    }
                                    
                                    // Crash Analyzer
                                    NavigationLink(value: DeviceAction.crashAnalyzer) {
                                        ActionButton(
                                            title: "Crash Analyzer",
                                            icon: "exclamationmark.triangle",
                                            isLoading: isPerformingAction
                                        )
                                    }
                                    
                                    // Clear App Data
                                    Button {
                                        showingBundleIdPrompt = true
                                    } label: {
                                        ActionButton(
                                            title: "Clear App Data",
                                            icon: "trash",
                                            isLoading: isPerformingAction
                                        )
                                    }
                                    
                                    // Restart Device
                                    Button {
                                        Task {
                                            await restartDevice(device)
                                        }
                                    } label: {
                                        ActionButton(
                                            title: "Restart Device",
                                            icon: "arrow.clockwise",
                                            isLoading: isPerformingAction
                                        )
                                    }
                                }
                            }
                            
                            if let error = actionError {
                                Text(error)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                        .padding()
                    }
                    .navigationDestination(for: DeviceAction.self) { action in
                        switch action {
                        case .screenRecording:
                            ScreenRecordingView(device: device)
                        case .logs:
                            LogViewer(device: device)
                        case .crashAnalyzer:
                            CrashAnalyzerView()
                        }
                    }
                }
                .navigationTitle(device.name)
                .sheet(isPresented: $showingBundleIdPrompt) {
                    BundleIdPromptView(bundleId: $bundleId) { bundleId in
                        Task {
                            await clearAppData(bundleId: bundleId, for: device)
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Device Selected", systemImage: "iphone")
                } description: {
                    Text("Select a device to view details and perform actions")
                }
            }
        }
    }
    
    private func restartDevice(_ device: Device) async {
        isPerformingAction = true
        defer { isPerformingAction = false }
        
        do {
            try await DeviceManager.shared.restartDevice(device)
        } catch {
            actionError = error.localizedDescription
        }
    }
    
    private func clearAppData(bundleId: String, for device: Device) async {
        isPerformingAction = true
        defer { isPerformingAction = false }
        
        do {
            try await DeviceManager.shared.clearAppData(device: device, bundleId: bundleId)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

enum DeviceAction: Hashable {
    case screenRecording
    case logs
    case crashAnalyzer
}

// Helper Views
struct DeviceRow: View {
    let device: Device
    
    var body: some View {
        HStack {
            Image(systemName: device.type == .ios ? "iphone" : "android2")
            VStack(alignment: .leading) {
                Text(device.name)
                Text(device.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let isLoading: Bool
    
    var body: some View {
        HStack {
            Label {
                Text(title)
                    .frame(maxWidth: 200, alignment: .leading)
            } icon: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isLoading)
    }
}

#Preview {
    ContentView()
}
