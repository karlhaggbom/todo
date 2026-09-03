import SwiftUI

/// Orange error banner with a Copy button, so full error text (including any
/// embedded response-body snippet) can be pasted elsewhere for diagnosis.
struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(4)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(message, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            if let onDismiss {
                Button("Dismiss", action: onDismiss)
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .padding(.horizontal, 14)
    }
}