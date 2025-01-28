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
    @State private var isShowingAppPicker = false
    @State private var isPerformingAction = false
    @State private var actionError: String?
    @State private var isShowingCustomCommandPrompt = false
    @State private var customCommand = ""
    @State private var isShowingBundleIdPrompt = false
    @State private var bundleIdToReset = ""
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(deviceManager.devices, selection: $selectedDevice) { device in
                DeviceRow(device: device)
            }
            .navigationTitle("Devices")
            .overlay {
                if deviceManager.devices.isEmpty {
                    ContentUnavailableView(
                        "No Devices Found",
                        systemImage: "devices",
                        description: Text("Connect an iOS or Android device to get started")
                    )
                }
            }
        } detail: {
            if let device = selectedDevice {
                TabView {
                    // Detail view
                    DeviceDetailView(device: device)
                    
                    // Add crash analyzer tab
                    CrashAnalyzerView()
                        .tabItem {
                            Label("Crash Analyzer", systemImage: "exclamationmark.triangle")
                        }
                    
                    // Custom Commands section
                    GroupBox("Custom Commands") {
                        ActionButton(
                            title: "Execute Command",
                            icon: "terminal",
                            isLoading: isPerformingAction
                        ) {
                            isShowingCustomCommandPrompt = true
                        }
                    }
                }
            } else {
                Text("Select a device")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .toolbar {
            ToolbarItem {
                Button(action: { deviceManager.startDeviceScan() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $isShowingBundleIdPrompt) {
            BundleIdPromptView(bundleId: $bundleIdToReset) { bundleId in
                Task {
                    await clearAppData(bundleId: bundleId, for: selectedDevice!)
                }
            }
        }
        .sheet(isPresented: $isShowingCustomCommandPrompt) {
            CustomCommandView(command: $customCommand) { command in
                Task {
                    do {
                        if let device = selectedDevice {
                            try await DeviceManager.shared.executeCommand(on: device, command: command)
                        }
                    } catch {
                        await MainActor.run {
                            actionError = error.localizedDescription
                        }
                    }
                }
            }
        }
        .alert("Error", isPresented: .constant(actionError != nil)) {
            Button("OK") {
                actionError = nil
            }
        } message: {
            Text(actionError ?? "")
        }
    }
    
    private func executeCustomCommand(for device: Device) {
        let commandPrompt = CustomCommandView(command: .constant("")) { command in
            Task {
                do {
                    try await DeviceManager.shared.executeCommand(on: device, command: command)
                } catch {
                    await MainActor.run {
                        actionError = error.localizedDescription
                    }
                }
            }
        }
        
        presentSheet(commandPrompt)
    }
    
    private func presentSheet(_ sheet: some View) {
        // Implementation of presentSheet function
    }
    
    private func clearAppData(bundleId: String, for device: Device) async {
        isPerformingAction = true
        defer { isPerformingAction = false }
        
        do {
            try await DeviceManager.shared.clearAppData(device, bundleId: bundleId)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// Device row in sidebar
struct DeviceRow: View {
    let device: Device
    
    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.headline)
                Text(device.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: device.type.imageName)
                .foregroundStyle(device.type == .ios ? .blue : .green)
        }
        .padding(.vertical, 4)
    }
}

// Detail view showing device actions
struct DeviceDetailView: View {
    let device: Device
    @State private var isPerformingAction = false
    @State private var actionError: String?
    @State private var selectedTab = 0
    @State private var isRecording = false
    @State private var isShowingCustomCommandPrompt = false
    @State private var customCommand = ""
    @State private var isShowingBundleIdPrompt = false
    @State private var bundleIdToReset = ""
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Actions tab
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Device info
                    VStack(alignment: .leading) {
                        Text(device.name)
                            .font(.title)
                        Text(device.status)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom)
                    
                    // App installation section
                    GroupBox("App Installation") {
                        AppInstallDropZone(device: device)
                    }
                    
                    // Device Control
                    GroupBox("Device Control") {
                        VStack(alignment: .leading, spacing: 12) {
                            ActionButton(
                                title: "Restart Device",
                                icon: "arrow.clockwise",
                                isLoading: isPerformingAction
                            ) {
                                Task {
                                    await restartDevice()
                                }
                            }
                            
                            ActionButton(
                                title: "Clear App Data",
                                icon: "trash",
                                isLoading: isPerformingAction
                            ) {
                                isShowingBundleIdPrompt = true
                            }
                        }
                    }
                    
                    // Media Actions
                    GroupBox("Media Actions") {
                        VStack(alignment: .leading, spacing: 12) {
                            ActionButton(
                                title: "Capture Screenshot",
                                icon: "camera",
                                isLoading: isPerformingAction
                            ) {
                                Task {
                                    await captureScreenshot()
                                }
                            }
                            
                            // Add screen recording view
                            ScreenRecordingView(device: device)
                        }
                    }
                }
                .padding()
            }
            .tabItem {
                Label("Actions", systemImage: "gear")
            }
            .tag(0)
            
            // Logs tab
            LogViewer(device: device)
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }
                .tag(1)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isShowingBundleIdPrompt) {
            BundleIdPromptView(bundleId: $bundleIdToReset) { bundleId in
                Task {
                    await clearAppData(bundleId: bundleId, for: device)
                }
            }
        }
        .sheet(isPresented: $isShowingCustomCommandPrompt) {
            CustomCommandView(command: $customCommand) { command in
                Task {
                    do {
                        try await DeviceManager.shared.executeCommand(on: device, command: command)
                    } catch {
                        await MainActor.run {
                            actionError = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
    
    private func captureScreenshot() async {
        isPerformingAction = true
        defer { isPerformingAction = false }
        
        do {
            let screenshotURL = try await DeviceManager.shared.captureScreenshot(of: device)
            // Handle the screenshot - maybe show it in a preview window
        } catch {
            actionError = error.localizedDescription
        }
    }
    
    private func restartDevice() async {
        isPerformingAction = true
        defer { isPerformingAction = false }
        
        do {
            try await DeviceManager.shared.restartDevice(device)
        } catch {
            actionError = error.localizedDescription
        }
    }
    
    private func toggleRecording() async {
        isPerformingAction = true
        defer { isPerformingAction = false }
        
        do {
            if isRecording {
                // Stop recording logic
                isRecording = false
            } else {
                let recordingURL = try await DeviceManager.shared.recordScreen(of: device)
                isRecording = true
                // Handle recording URL (maybe show in Finder)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }
    
    private func clearAppData(bundleId: String, for device: Device) async {
        isPerformingAction = true
        defer { isPerformingAction = false }
        
        do {
            try await DeviceManager.shared.clearAppData(device, bundleId: bundleId)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// Reusable action button
struct ActionButton: View {
    let title: String
    let icon: String
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
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
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isLoading)
    }
}

#Preview {
    ContentView()
}
