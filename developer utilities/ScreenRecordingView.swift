import SwiftUI
import AVKit

struct ScreenRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    let device: Device
    @State private var isRecording = false
    @State private var recordingURL: URL?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var isExporting = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Back button
            HStack {
                Button(action: { dismiss() }) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            
            // Video preview
            if let player = player {
                VideoPlayer(player: player)
                    .frame(height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onAppear {
                        player.play() // Auto-play when preview is shown
                    }
            }
            
            // Controls
            HStack(spacing: 20) {
                Button(action: {
                    Task {
                        await toggleRecording()
                    }
                }) {
                    Label(isRecording ? "Stop Recording" : "Start Recording",
                          systemImage: isRecording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .blue)
                
                if let url = recordingURL {
                    Button(action: {
                        exportRecording(url)
                    }) {
                        Label("Save Recording", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .disabled(isExporting)
            
            if isExporting {
                ProgressView("Exporting recording...")
            }
            
            if let error = error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding()
        .navigationBarBackButtonHidden(true)
    }
    
    private func toggleRecording() async {
        do {
            if isRecording {
                let url = try await DeviceManager.shared.stopScreenRecording(for: device)
                recordingURL = url
                player = AVPlayer(url: url)
            } else {
                recordingURL = nil
                player = nil
                try await DeviceManager.shared.startScreenRecording(for: device)
            }
            isRecording.toggle()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    private func exportRecording(_ url: URL) {
        isExporting = true
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "recording.mp4"
        
        panel.begin { response in
            if response == .OK, let exportURL = panel.url {
                do {
                    try FileManager.default.copyItem(at: url, to: exportURL)
                    NSWorkspace.shared.activateFileViewerSelecting([exportURL])
                } catch {
                    self.error = "Failed to save recording: \(error.localizedDescription)"
                }
            }
            isExporting = false
        }
    }
} 