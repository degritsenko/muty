import SwiftUI
import AppKit

struct TerminalPaneLayout {
    let frames: [CGRect]
    let column: CGFloat?
    let row: CGFloat?
    let rowStart: CGFloat
    init(mode: String, size: CGSize, x: CGFloat, y: CGFloat) {
        let w = max(1, size.width), h = max(1, size.height)
        let minX = min(0.45, 180 / w), minY = min(0.45, 100 / h)
        let dx = (w * min(1 - minX, max(minX, x))).rounded()
        let dy = (h * min(1 - minY, max(minY, y))).rounded()
        let left = CGRect(x: 0, y: 0, width: dx, height: h)
        let right = CGRect(x: dx + 1, y: 0, width: max(1, w - dx - 1), height: h)
        let top = CGRect(x: 0, y: 0, width: w, height: dy)
        let bottom = CGRect(x: 0, y: dy + 1, width: w, height: max(1, h - dy - 1))
        switch mode {
        case "right": frames = [left, right]; column = dx; row = nil; rowStart = 0
        case "bottom": frames = [top, bottom]; column = nil; row = dy; rowStart = 0
        case "three":
            frames = [left, CGRect(x: right.minX, y: 0, width: right.width, height: dy), CGRect(x: right.minX, y: dy + 1, width: right.width, height: bottom.height)]
            column = dx; row = dy; rowStart = right.minX
        case "four":
            frames = [CGRect(x: 0, y: 0, width: dx, height: dy), CGRect(x: right.minX, y: 0, width: right.width, height: dy), CGRect(x: 0, y: bottom.minY, width: dx, height: bottom.height), CGRect(x: right.minX, y: bottom.minY, width: right.width, height: bottom.height)]
            column = dx; row = dy; rowStart = 0
        default: frames = [CGRect(origin: .zero, size: size)]; column = nil; row = nil; rowStart = 0
        }
    }
}

struct TerminalWorkspace<Pane: View>: View {
    @ObservedObject var model: AppModel
    let pane: (SSHConnection, Int?) -> Pane
    @ViewState private var columnFraction: CGFloat = 0.5
    @ViewState private var rowFraction: CGFloat = 0.5
    var body: some View {
        GeometryReader { geometry in
            let layout = TerminalPaneLayout(mode: model.splitMode, size: geometry.size, x: columnFraction, y: rowFraction)
            let slots: [UUID?] = model.splitMode == "none" ? [model.selectedTab] : model.splitSlots
            ZStack(alignment: .topLeading) {
                ForEach(model.tabs) { connection in
                    let index = slots.firstIndex(where: { $0 == connection.id })
                    let frame = layout.frames[min(index ?? 0, layout.frames.count - 1)]
                    pane(connection, model.splitMode == "none" ? nil : index)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .opacity(index != nil ? 1 : 0).allowsHitTesting(index != nil).accessibilityHidden(index == nil)
                        .simultaneousGesture(TapGesture().onEnded { model.selectTab(connection.id) })
                }
                if model.splitMode != "none" {
                    ForEach(layout.frames.indices, id: \.self) { index in
                        if index >= slots.count || !model.tabs.contains(where: { $0.id == slots[index] }) {
                            let frame = layout.frames[index]
                            VStack(spacing: 12) {
                                Text(LF("Pane %ld", index + 1)).foregroundStyle(.secondary)
                                Menu("Choose Session") {
                                    ForEach(model.tabs) { tab in
                                        Button(tab.tabName ?? tab.profile.name) { model.assignSplitTab(tab.id, to: index) }
                                    }
                                }.fixedSize()
                            }.frame(width: frame.width, height: frame.height)
                                .background(Color(nsColor: .windowBackgroundColor)).offset(x: frame.minX, y: frame.minY)
                        }
                    }
                }
                if let x = layout.column {
                    Rectangle().fill(Color.clear).frame(width: 7, height: geometry.size.height)
                        .overlay { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
                        .contentShape(Rectangle()).offset(x: x - 3)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mutyWorkspace")).onChanged { event in
                            columnFraction = min(0.85, max(0.15, event.location.x / max(1, geometry.size.width)))
                        })
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
                        .accessibilityLabel("Resize columns")
                }
                if let y = layout.row {
                    Rectangle().fill(Color.clear).frame(width: max(1, geometry.size.width - layout.rowStart), height: 7)
                        .overlay { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
                        .contentShape(Rectangle()).offset(x: layout.rowStart, y: y - 3)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mutyWorkspace")).onChanged { event in
                            rowFraction = min(0.85, max(0.15, event.location.y / max(1, geometry.size.height)))
                        })
                        .onHover { inside in if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
                        .accessibilityLabel("Resize rows")
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .coordinateSpace(name: "mutyWorkspace").clipped()
        }
    }
}
