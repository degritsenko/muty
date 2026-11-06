import SwiftUI

struct OperationStatusView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let status = model.operationStatus {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(status).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { model.operationStatus = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss status")
            }
            .padding(12).frame(maxWidth: 600)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
            .padding(12)
        }
    }
}
