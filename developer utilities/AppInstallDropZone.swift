import SwiftUI
import UniformTypeIdentifiers

struct AppInstallDropZone: View {
    let device: Device
    @State private var isDropTargeted = false
    @State private var isInstalling = false
    @State private var installError: String?
    
    // Supported file types
    private let supportedTypes = [
        UTType("com.apple.iphone.ipa")!, // IPA files
        UTType("application.vnd.android.package-archive")!, // APK files
        .application // General apps
    ]
    
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
        .onDrop(of: supportedTypes, isTargeted: $isDropTargeted) { providers in
            Task {
                await handleDrop(providers)
            }
            return true
        }
    }
    
    private func handleDrop(_ providers: [NSItemProvider]) async {
        guard let provider = providers.first else { return }
        
        // Verify file type matches device type
        let validTypes = device.type == .ios ? 
            [UTType("com.apple.iphone.ipa")!] :
            [UTType("application.vnd.android.package-archive")!]
        
        guard provider.hasItemConformingToTypeIdentifier(validTypes[0].identifier) else {
            installError = "Invalid file type for \(device.type == .ios ? "iOS" : "Android") device"
            return
        }
        
        isInstalling = true
        installError = nil
        
        do {
            let url = try await provider.loadItem(forTypeIdentifier: validTypes[0].identifier, options: nil) as! URL
            try await DeviceManager.shared.installApp(on: device, appPath: url.path)
            
            // Success feedback
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        } catch {
            installError = error.localizedDescription
        }
        
        isInstalling = false
    }
} 