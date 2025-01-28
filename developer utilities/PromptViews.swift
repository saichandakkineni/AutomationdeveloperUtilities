import SwiftUI

struct BundleIdPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var bundleId: String
    let onSubmit: (String) -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Enter Bundle ID")
                .font(.headline)
            
            TextField("com.example.app", text: $bundleId)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                
                Button("Clear Data") {
                    onSubmit(bundleId)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

struct CustomCommandView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var command: String
    let onSubmit: (String) -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Execute Custom Command")
                .font(.headline)
            
            TextField("Enter command", text: $command)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                
                Button("Execute") {
                    onSubmit(command)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400)
    }
} 