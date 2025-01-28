import Foundation
import OSLog

// Move these struct definitions outside the function and before the DeviceManager class
private struct DeviceCtlDevice: Codable {
    let identifier: String
    let name: String
    let deviceType: String
    let deviceClass: String
    let connectionType: String
    let platform: String?
    let status: String
}

private struct DeviceCtlResponse: Codable {
    let devices: [DeviceCtlDevice]
}

class DeviceManager: ObservableObject {
    static let shared = DeviceManager()
    private let logger = Logger(subsystem: "com.cmobautomation.developer-utilities", category: "DeviceManager")
    
    @Published private(set) var devices: [Device] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?
    
    private var deviceScanTimer: Timer?
    private var recordingProcesses: [String: Process] = [:]
    private var recordingPaths: [String: URL] = [:]
    
    init() {
        startDeviceScan()
    }
    
    func startDeviceScan() {
        guard !isScanning else { return }
        isScanning = true
        
        // Start periodic device scanning
        deviceScanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scanForDevices()
        }
        
        scanForDevices() // Initial scan
    }
    
    private func scanForDevices() {
        // Scan for iOS devices using xcrun
        Task {
            do {
                let iosDevices = try await scanIOSDevices()
                let androidDevices = try await scanAndroidDevices()
                
                await MainActor.run {
                    self.devices = iosDevices + androidDevices
                    self.lastError = nil
                }
            } catch {
                logger.error("Device scan failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
    
    private func scanIOSDevices() async throws -> [Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "list", "devices", "--json"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        
        let outputData = try await outputPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
        let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
        
        if !errorData.isEmpty {
            let errorString = String(decoding: errorData, as: UTF8.self)
            logger.error("devicectl error: \(errorString)")
            throw DeviceScanError.processError(errorString)
        }
        
        // Parse JSON output from devicectl
        let response = try JSONDecoder().decode(DeviceCtlResponse.self, from: outputData)
        
        // Process devices sequentially using async/await
        var devices: [Device] = []
        for deviceInfo in response.devices {
            if let device = try await createIOSDevice(from: deviceInfo) {
                devices.append(device)
            }
        }
        
        return devices
    }
    
    private func createIOSDevice(from info: DeviceCtlDevice) async throws -> Device? {
        // Create device instance with additional properties
        guard info.deviceClass == "iPhone" || info.deviceClass == "iPad" else { return nil }
        
        let properties = [
            "Type": info.deviceType,
            "Class": info.deviceClass,
            "Connection": info.connectionType,
            "Platform": info.platform ?? "Unknown"
        ]
        
        return Device(
            name: info.name,
            type: .ios,
            status: info.status,
            identifier: info.identifier,
            properties: properties
        )
    }
    
    private func scanAndroidDevices() async throws -> [Device] {
        // First check if adb exists
        let adbPath = "/usr/local/bin/adb"
        guard FileManager.default.fileExists(atPath: adbPath) else {
            logger.error("ADB not found at \(adbPath)")
            throw DeviceScanError.commandNotFound("Android Debug Bridge (adb) not found. Please install Android SDK command-line tools.")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["devices", "-l"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        
        let outputData = try await outputPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
        let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
        
        if !errorData.isEmpty {
            let errorString = String(decoding: errorData, as: UTF8.self)
            if errorString.contains("daemon started successfully") {
                // ADB server just started, retry the scan
                return try await scanAndroidDevices()
            }
            throw DeviceScanError.processError(errorString)
        }
        
        let output = String(decoding: outputData, as: UTF8.self)
        let lines = output.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.contains("List of devices attached") }
        
        var devices: [Device] = []
        for line in lines {
            let components = line.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            
            guard components.count >= 2 else { continue }
            
            let identifier = components[0]
            let status = components[1]
            
            guard status == "device" else { continue } // Skip unauthorized/offline devices
            
            // Parse device properties
            var properties: [String: String] = ["identifier": identifier]
            components[2...].forEach { prop in
                let keyValue = prop.split(separator: ":")
                if keyValue.count == 2 {
                    properties[String(keyValue[0])] = String(keyValue[1])
                }
            }
            
            // Get device model name
            if let modelName = try await getAndroidDeviceModel(identifier: identifier) {
                let device = Device(
                    name: modelName,
                    type: .android,
                    status: "Connected",
                    identifier: identifier,
                    properties: properties
                )
                devices.append(device)
            }
        }
        
        return devices
    }
    
    private func getAndroidDeviceModel(identifier: String) async throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
        process.arguments = ["-s", identifier, "shell", "getprop", "ro.product.model"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        
        try process.run()
        let outputData = try await outputPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
        let model = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        
        return model.isEmpty ? nil : model
    }
    
    // Device operations
    func installApp(on device: Device, appPath: String) async throws {
        logger.info("Installing app on device: \(device.name)")
        switch device.type {
        case .ios:
            try await installIOSApp(device: device, appPath: appPath)
        case .android:
            try await installAndroidApp(device: device, appPath: appPath)
        }
    }
    
    private func installIOSApp(device: Device, appPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "install", "app", device.identifier, appPath]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
            let errorString = String(decoding: errorData, as: UTF8.self)
            throw DeviceScanError.processError("Failed to install app: \(errorString)")
        }
    }
    
    private func installAndroidApp(device: Device, appPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
        process.arguments = ["-s", device.identifier, "install", "-r", appPath]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
            let errorString = String(decoding: errorData, as: UTF8.self)
            throw DeviceScanError.processError("Failed to install app: \(errorString)")
        }
    }
    
    func captureScreenshot(of device: Device) async throws -> URL {
        logger.info("Capturing screenshot from device: \(device.name)")
        switch device.type {
        case .ios:
            return try await captureIOSScreenshot(device: device)
        case .android:
            return try await captureAndroidScreenshot(device: device)
        }
    }
    
    private func captureIOSScreenshot(device: Device) async throws -> URL {
        // Implementation using devicectl screenshot
        let screenshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot.png")
        // Add implementation
        return screenshotURL
    }
    
    private func captureAndroidScreenshot(device: Device) async throws -> URL {
        // Implementation using adb screenshot
        let screenshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot.png")
        // Add implementation
        return screenshotURL
    }
    
    func restartDevice(_ device: Device) async throws {
        logger.info("Restarting device: \(device.name)")
        switch device.type {
        case .ios:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["devicectl", "device", "shutdown", device.identifier]
            try await executeProcess(process)
            
            // Wait briefly then boot
            try await Task.sleep(for: .seconds(2))
            process.arguments = ["devicectl", "device", "boot", device.identifier]
            try await executeProcess(process)
            
        case .android:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
            process.arguments = ["-s", device.identifier, "reboot"]
            try await executeProcess(process)
        }
    }
    
    func clearAppData(_ device: Device, bundleId: String) async throws {
        logger.info("Clearing app data for \(bundleId) on \(device.name)")
        switch device.type {
        case .ios:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["devicectl", "device", "uninstall", device.identifier, bundleId]
            try await executeProcess(process)
            
        case .android:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
            process.arguments = ["-s", device.identifier, "shell", "pm", "clear", bundleId]
            try await executeProcess(process)
        }
    }
    
    func recordScreen(of device: Device) async throws -> URL {
        logger.info("Starting screen recording for: \(device.name)")
        let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.mp4")
        
        switch device.type {
        case .ios:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["devicectl", "device", "record", device.identifier, recordingURL.path]
            try await executeProcess(process)
            
        case .android:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
            process.arguments = ["-s", device.identifier, "shell", "screenrecord", "/sdcard/recording.mp4"]
            try await executeProcess(process)
            
            // Pull recording from device
            let pullProcess = Process()
            pullProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
            pullProcess.arguments = ["-s", device.identifier, "pull", "/sdcard/recording.mp4", recordingURL.path]
            try await executeProcess(pullProcess)
        }
        
        return recordingURL
    }
    
    func startScreenRecording(for device: Device) async throws {
        guard recordingProcesses[device.identifier] == nil else {
            throw DeviceScanError.processError("Recording already in progress")
        }
        
        logger.info("Starting screen recording for device: \(device.name)")
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        
        switch device.type {
        case .ios:
            try await startIOSRecording(device: device, outputURL: outputURL)
        case .android:
            try await startAndroidRecording(device: device, outputURL: outputURL)
        }
        
        recordingPaths[device.identifier] = outputURL
    }
    
    func stopScreenRecording(for device: Device) async throws -> URL {
        guard let process = recordingProcesses[device.identifier],
              let outputURL = recordingPaths[device.identifier] else {
            throw DeviceScanError.processError("No active recording found")
        }
        
        logger.info("Stopping screen recording for device: \(device.name)")
        
        switch device.type {
        case .ios:
            process.terminate()
        case .android:
            // Send Ctrl+C to stop Android recording
            let pid = process.processIdentifier
            kill(pid, SIGINT)
        }
        
        process.waitUntilExit()
        recordingProcesses.removeValue(forKey: device.identifier)
        recordingPaths.removeValue(forKey: device.identifier)
        
        // Optimize video
        return try await optimizeVideo(at: outputURL, for: device)
    }
    
    private func startIOSRecording(device: Device, outputURL: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "simctl", "io", device.identifier, "recordVideo",
            "--codec", "h264",
            "--mask", "ignored",
            "--force",
            outputURL.path
        ]
        
        try process.run()
        recordingProcesses[device.identifier] = process
    }
    
    private func startAndroidRecording(device: Device, outputURL: URL) async throws {
        let tempPath = "/sdcard/recording.mp4"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
        process.arguments = [
            "-s", device.identifier,
            "shell", "screenrecord",
            "--bit-rate", "8000000", // 8Mbps
            "--size", "1280x720", // 720p
            tempPath
        ]
        
        try process.run()
        recordingProcesses[device.identifier] = process
        
        // When stopped, we'll need to pull the file from the device
        // and delete the temporary file
        try await pullAndroidRecording(device: device, tempPath: tempPath, outputURL: outputURL)
    }
    
    private func pullAndroidRecording(device: Device, tempPath: String, outputURL: URL) async throws {
        let pullProcess = Process()
        pullProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
        pullProcess.arguments = ["-s", device.identifier, "pull", tempPath, outputURL.path]
        try await executeProcess(pullProcess)
        
        // Clean up temp file
        let cleanupProcess = Process()
        cleanupProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
        cleanupProcess.arguments = ["-s", device.identifier, "shell", "rm", tempPath]
        try await executeProcess(cleanupProcess)
    }
    
    private func optimizeVideo(at url: URL, for device: Device) async throws -> URL {
        let optimizedURL = url.deletingPathExtension().appendingPathExtension("optimized.mp4")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        process.arguments = [
            "-i", url.path,
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "23", // Balance between quality and size
            "-movflags", "+faststart", // Enable streaming
            "-y", // Overwrite output file
            optimizedURL.path
        ]
        
        try await executeProcess(process)
        
        // Clean up original file
        try FileManager.default.removeItem(at: url)
        
        return optimizedURL
    }
    
    private func executeProcess(_ process: Process) async throws {
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
            let errorString = String(decoding: errorData, as: UTF8.self)
            throw DeviceScanError.processError(errorString)
        }
    }
    
    func executeCommand(on device: Device, command: String) async throws {
        logger.info("Executing custom command on device \(device.name): \(command)")
        
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        if device.type == .ios {
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ideviceinstaller")
            process.arguments = ["-u", device.identifier, "--command", command]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/adb")
            process.arguments = ["-s", device.identifier, "shell", command]
        }
        
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
            let errorString = String(decoding: errorData, as: UTF8.self)
            throw DeviceScanError.processError(errorString)
        }
    }
}

struct DeviceInfo {
    let identifier: String
    let name: String
    let type: DeviceType
    let status: String
    let properties: [String: String]
}

enum DeviceScanError: Error {
    case processError(String)
    case commandNotFound(String)
    case parseError(String)
} 