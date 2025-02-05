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
    
    // Update ADB path to use home directory
    private let adbPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Android/sdk/platform-tools/adb"
    
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
        Task {
            do {
                var allDevices: [Device] = []
                var errors: [String] = []
                
                // Scan for iOS devices
                do {
                    let iosDevices = try await scanIOSDevices()
                    allDevices.append(contentsOf: iosDevices)
                } catch {
                    errors.append("iOS scan error: \(error.localizedDescription)")
                }
                
                // Scan for Android devices
                do {
                    let androidDevices = try await scanAndroidDevices()
                    allDevices.append(contentsOf: androidDevices)
                } catch {
                    errors.append("Android scan error: \(error.localizedDescription)")
                }
                
                // Update the devices list on the main thread
                await MainActor.run {
                    self.devices = allDevices
                    if !errors.isEmpty {
                        self.lastError = errors.joined(separator: "\n")
                    } else {
                        self.lastError = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    logger.error("Device scan failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func scanIOSDevices() async throws -> [Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        
        // Updated command arguments to match correct syntax
        process.arguments = ["devicectl", "list", "devices", "--json-output", "-"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
                let errorString = String(decoding: errorData, as: UTF8.self)
                logger.error("devicectl error: \(errorString)")
                throw DeviceScanError.processError(errorString)
            }
            
            let outputData = try await outputPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
            
            // Add debug logging
            let outputString = String(decoding: outputData, as: UTF8.self)
            logger.debug("Device scan output: \(outputString)")
            
            let response = try JSONDecoder().decode(DeviceCtlResponse.self, from: outputData)
            
            var devices: [Device] = []
            for deviceInfo in response.devices {
                if let device = try await createIOSDevice(from: deviceInfo) {
                    devices.append(device)
                }
            }
            
            return devices
        } catch {
            logger.error("Failed to scan iOS devices: \(error.localizedDescription)")
            throw DeviceScanError.processError(error.localizedDescription)
        }
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
        // First, try to start ADB server if it's not running
        do {
            let startServerProcess = Process()
            startServerProcess.executableURL = URL(fileURLWithPath: "/Users/SAICHAND.Z.Akkineni@td.com/Library/Android/sdk/platform-tools/adb")
            startServerProcess.arguments = ["start-server"]
            try startServerProcess.run()
            startServerProcess.waitUntilExit()
        } catch {
            logger.error("Failed to start ADB server: \(error.localizedDescription)")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Users/SAICHAND.Z.Akkineni@td.com/Library/Android/sdk/platform-tools/adb")
        process.arguments = ["devices", "-l"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outputData = try await outputPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
            let outputString = String(decoding: outputData, as: UTF8.self)
            
            // Debug logging
            logger.debug("ADB devices output: \(outputString)")
            
            if process.terminationStatus != 0 {
                let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
                let errorString = String(decoding: errorData, as: UTF8.self)
                logger.error("ADB error: \(errorString)")
                
                // If ADB server is not running, start it and retry
                if errorString.contains("adb server") {
                    logger.info("ADB server not running, attempting to start it...")
                    return try await scanAndroidDevices() // Retry after starting server
                }
                throw DeviceScanError.processError(errorString)
            }
            
            // Parse adb devices output
            var devices: [Device] = []
            let lines = outputString.components(separatedBy: .newlines)
                .filter { !$0.isEmpty && !$0.contains("List of devices attached") }
            
            for line in lines {
                let components = line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                
                guard components.count >= 2 else { continue }
                
                let identifier = components[0]
                let status = components[1]
                
                // Only add authorized devices
                if status == "device" {
                    // Get device name
                    let name = try await getAndroidDeviceName(identifier) ?? "Android Device"
                    
                    // Get additional properties
                    var properties: [String: String] = [:]
                    if components.count > 2 {
                        components[2...].forEach { prop in
                            let keyValue = prop.split(separator: ":")
                            if keyValue.count == 2 {
                                properties[String(keyValue[0])] = String(keyValue[1])
                            }
                        }
                    }
                    
                    let device = Device(
                        name: name,
                        type: .android,
                        status: "Connected",
                        identifier: identifier,
                        properties: properties
                    )
                    devices.append(device)
                    logger.info("Found Android device: \(name) (\(identifier))")
                }
            }
            
            return devices
        } catch {
            logger.error("Failed to scan Android devices: \(error.localizedDescription)")
            throw DeviceScanError.processError(error.localizedDescription)
        }
    }
    
    private func getAndroidDeviceName(_ identifier: String) async throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Users/SAICHAND.Z.Akkineni@td.com/Library/Android/sdk/platform-tools/adb")
        process.arguments = ["-s", identifier, "shell", "getprop", "ro.product.model"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            let outputData = try await outputPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
            let name = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
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
        process.executableURL = URL(fileURLWithPath: adbPath)
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
            process.executableURL = URL(fileURLWithPath: "/Users/SAICHAND.Z.Akkineni@td.com/Library/Android/sdk/platform-tools/adb")
            process.arguments = ["-s", device.identifier, "reboot"]
            try await executeProcess(process)
        }
    }
    
    func clearAppData(device: Device, bundleId: String) async throws {
        switch device.type {
        case .ios:
            try await clearIOSAppData(device: device, bundleId: bundleId)
        case .android:
            try await clearAndroidAppData(device: device, bundleId: bundleId)
        }
    }
    
    private func clearIOSAppData(device: Device, bundleId: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "uninstall", device.identifier, bundleId]
        try await executeProcess(process)
    }
    
    private func clearAndroidAppData(device: Device, bundleId: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", device.identifier, "shell", "pm", "clear", bundleId]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
            let errorString = String(decoding: errorData, as: UTF8.self)
            throw DeviceScanError.processError("Failed to clear app data: \(errorString)")
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
            process.executableURL = URL(fileURLWithPath: "/Users/SAICHAND.Z.Akkineni@td.com/Library/Android/sdk/platform-tools/adb")
            process.arguments = ["-s", device.identifier, "shell", "screenrecord", "/sdcard/recording.mp4"]
            try await executeProcess(process)
            
            // Pull recording from device
            let pullProcess = Process()
            pullProcess.executableURL = URL(fileURLWithPath: "/Users/SAICHAND.Z.Akkineni@td.com/Library/Android/sdk/platform-tools/adb")
            pullProcess.arguments = ["-s", device.identifier, "pull", "/sdcard/recording.mp4", recordingURL.path]
            try await executeProcess(pullProcess)
        }
        
        return recordingURL
    }
    
    func startScreenRecording(for device: Device) async throws {
        switch device.type {
        case .ios:
            try await startIOSScreenRecording(device: device)
        case .android:
            try await startAndroidScreenRecording(device: device)
        }
    }
    
    func stopScreenRecording(for device: Device) async throws -> URL {
        switch device.type {
        case .ios:
            return try await stopIOSScreenRecording(device: device)
        case .android:
            return try await stopAndroidScreenRecording(device: device)
        }
    }
    
    private func startIOSScreenRecording(device: Device) async throws {
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        
        recordingPaths[device.identifier] = recordingURL
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "simctl", "io", device.identifier, "recordVideo",
            "--codec", "h264",
            "--mask", "ignored",
            "--force",
            recordingURL.path
        ]
        
        try process.run()
        recordingProcesses[device.identifier] = process
    }
    
    private func startAndroidScreenRecording(device: Device) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", device.identifier, "shell", "screenrecord", "/sdcard/recording.mp4"]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        try process.run()
        // Don't wait for completion as it records until stopped
    }
    
    private func stopIOSScreenRecording(device: Device) async throws -> URL {
        guard let process = recordingProcesses[device.identifier],
              let outputURL = recordingPaths[device.identifier] else {
            throw DeviceScanError.processError("No active recording found")
        }
        
        logger.info("Stopping screen recording for device: \(device.name)")
        
        process.terminate()
        process.waitUntilExit()
        recordingProcesses.removeValue(forKey: device.identifier)
        recordingPaths.removeValue(forKey: device.identifier)
        
        // Optimize video
        return try await optimizeVideo(at: outputURL, for: device)
    }
    
    private func stopAndroidScreenRecording(device: Device) async throws -> URL {
        // First, kill the screenrecord process
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: adbPath)
        killProcess.arguments = ["-s", device.identifier, "shell", "killall", "screenrecord"]
        try killProcess.run()
        killProcess.waitUntilExit()
        
        // Wait a moment for the file to be saved
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Create temporary directory for the recording
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let localPath = tempDir.appendingPathComponent("recording.mp4")
        
        // Pull the recording from device
        let pullProcess = Process()
        pullProcess.executableURL = URL(fileURLWithPath: adbPath)
        pullProcess.arguments = ["-s", device.identifier, "pull", "/sdcard/recording.mp4", localPath.path]
        
        let errorPipe = Pipe()
        pullProcess.standardError = errorPipe
        
        try pullProcess.run()
        pullProcess.waitUntilExit()
        
        if pullProcess.terminationStatus != 0 {
            let errorData = try await errorPipe.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }
            let errorString = String(decoding: errorData, as: UTF8.self)
            throw DeviceScanError.processError("Failed to get recording: \(errorString)")
        }
        
        // Clean up the recording on device
        let cleanupProcess = Process()
        cleanupProcess.executableURL = URL(fileURLWithPath: adbPath)
        cleanupProcess.arguments = ["-s", device.identifier, "shell", "rm", "/sdcard/recording.mp4"]
        try cleanupProcess.run()
        cleanupProcess.waitUntilExit()
        
        return localPath
    }
    
    private func optimizeVideo(at inputURL: URL, for device: Device) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        
        // Compression settings
        process.arguments = [
            "-i", inputURL.path,
            "-vf", "scale=1280:-1", // Scale width to 1280px, maintain aspect ratio
            "-c:v", "h264",
            "-preset", "fast",
            "-crf", "23", // Compression quality (18-28 is good, lower = better quality)
            "-c:a", "aac",
            "-b:a", "128k",
            outputURL.path
        ]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                // Delete original file
                try? FileManager.default.removeItem(at: inputURL)
                return outputURL
            } else {
                // If compression fails, return original file
                logger.error("Video compression failed, using original file")
                return inputURL
            }
        } catch {
            logger.error("Failed to compress video: \(error.localizedDescription)")
            return inputURL // Return original file if compression fails
        }
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
            process.executableURL = URL(fileURLWithPath: "/Users/SAICHAND.Z.Akkineni@td.com/Library/Android/sdk/platform-tools/adb")
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
