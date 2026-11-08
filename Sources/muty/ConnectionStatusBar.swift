import SwiftUI

struct ConnectionStatusBar: View {
    @ObservedObject var connection: SSHConnection

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(detail: 2, compact: false)
            row(detail: 1, compact: false)
            row(detail: 0, compact: false)
            row(detail: 0, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
    }

    private func row(detail: Int, compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let error = connection.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).lineLimit(1)
                    .truncationMode(.tail).layoutPriority(2)
            } else {
                Text(connection.status).foregroundStyle(.secondary)
                    .lineLimit(1).layoutPriority(2)
            }
            if !connection.running {
                Text(compact ? (connection.profile.connectionType == .localShell ? "Enter to restart" : "Enter to reconnect") :
                     connection.profile.connectionType == .localShell ? "Press Enter to restart shell" : "Press Enter to reconnect")
                    .foregroundStyle(.secondary).lineLimit(1).layoutPriority(2)
            }
            Spacer(minLength: 4)
            if connection.profile.connectionType == .ssh {
                Text(connection.profile.endpoint).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                if detail > 0, let jump = connection.connectedJumpProfile {
                    Text(detail == 2 ? "via \(jump.host):\(jump.port)" : "via \(jump.host)")
                        .lineLimit(1).foregroundStyle(.secondary)
                }
                if detail > 0, connection.transportReady {
                    Text(detail == 2 ? connection.negotiatedCipher.map { "SSH2 · " + $0 } ?? "SSH2" : "SSH2")
                        .lineLimit(1).foregroundStyle(.secondary)
                }
            }
        }
    }
}
