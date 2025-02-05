import SwiftUI
import UniformTypeIdentifiers

struct AppInstallDropZone: View {
    let device: Device
    @State private var isDropTargeted = false
    @State private var isInstalling = false
    @State private var installError: String?
    
    // Updated supported file types with correct UTTypes
    private var supportedTypes: [UTType] {
        if device.type == .ios {
            return [UTType.ipa].compactMap { $0 }
        } else {
            // For Android, we'll accept any file that ends with .apk
            return [.data]
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(isDropTargeted ? .blue : .secondary)
                    .frame(height: 120)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.secondary.opacity(0.1))
                    }
                
                VStack(spacing: 8) {
                    if isInstalling {
                        ProgressView()
                            .controlSize(.large)
                        Text("Installing...")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 32))
                            .foregroundStyle(isDropTargeted ? .blue : .secondary)
                        Text("Drop \(device.type == .ios ? "IPA" : "APK") file here")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .animation(.smooth, value: isDropTargeted)
            .animation(.smooth, value: isInstalling)
            
            if let error = installError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding()
        .dropDestination(
            for: URL.self,
            action: { urls, location in
                Task {
                    await handleDroppedURLs(urls)
                }
                return true
            },
            isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }
        )
    }
    
    private func handleDroppedURLs(_ urls: [URL]) async {
        guard let url = urls.first else { return }
        
        // Verify file extension
        let fileExtension = url.pathExtension.lowercased()
        let isValidFile = device.type == .ios ? fileExtension == "ipa" : fileExtension == "apk"
        
        guard isValidFile else {
            installError = "Invalid file type for \(device.type == .ios ? "iOS" : "Android") device"
            return
        }
        
        isInstalling = true
        installError = nil
        
        do {
            try await DeviceManager.shared.installApp(on: device, appPath: url.path)
            // Success feedback
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        } catch {
            installError = error.localizedDescription
        }
        
        isInstalling = false
    }
}

// Add UTType extension for IPA files
extension UTType {
    static var ipa: UTType? {
        UTType("com.apple.itunes.ipa")
    }
} 