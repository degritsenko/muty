import SwiftUI
import AppKit

struct SSHConnectionDiagnosticsPopover: View {
    @ObservedObject var connection: SSHConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SSH diagnostics").font(.headline)
            Label(connection.diagnostics.currentStep,
                  systemImage: connection.diagnostics.issue == nil ? "info.circle" : "exclamationmark.triangle")
                .font(.subheadline)
            LabeledContent("Destination", value: connection.diagnostics.targetEndpoint)
            if let jump = connection.diagnostics.jumpEndpoint {
                LabeledContent("Jump host", value: jump)
            }
            if let issue = connection.diagnostics.issue {
                Text(issue.explanation).fixedSize(horizontal: false, vertical: true)
                Text(issue.nextStep).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = connection.error, connection.diagnostics.issue == nil || connection.diagnostics.issue?.kind == .unknown {
                Text(error).fixedSize(horizontal: false, vertical: true)
            }
            Button("Copy diagnostics", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(connection.diagnostics.copyableReport, forType: .string)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
