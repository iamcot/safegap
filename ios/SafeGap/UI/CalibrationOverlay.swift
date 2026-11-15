// Màn hiệu chỉnh (phần ảnh): kéo 4 góc ROI, vạch capo, 2 vạch đo tờ A4.
import SafeGapCore
import SwiftUI

struct CalibrationOverlay: View {
    @ObservedObject var editor: CalibrationEditor
    let snapshot: FrameSnapshot

    private let space = "calib"

    var body: some View {
        GeometryReader { geo in
            let m = FrameMapping(frameWidth: editor.draft.frameWidth, frameHeight: editor.draft.frameHeight, viewSize: geo.size)
            ZStack {
                Canvas { ctx, _ in
                    for d in snapshot.detections {
                        ctx.stroke(Path(m.toView(d.box)), with: .color(.white.opacity(0.5)), lineWidth: 1)
                    }
                    var roi = Path()
                    roi.addLines(editor.draft.roi.map { m.toView(norm: $0) })
                    roi.closeSubpath()
                    ctx.fill(roi, with: .color(.green.opacity(0.15)))
                    ctx.stroke(roi, with: .color(.green), lineWidth: 2)
                    let yHood = editor.draft.maxBottomRatio * editor.draft.frameHeight
                    var hood = Path()
                    hood.move(to: m.toView(0, yHood))
                    hood.addLine(to: m.toView(editor.draft.frameWidth, yHood))
                    ctx.stroke(hood, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    if editor.a4On {
                        for x in [editor.a4Left, editor.a4Right] {
                            var p = Path()
                            p.move(to: m.toView(x, 0))
                            p.addLine(to: m.toView(x, editor.draft.frameHeight))
                            ctx.stroke(p, with: .color(.cyan), lineWidth: 1)
                        }
                    }
                }
                .allowsHitTesting(false)

                ForEach(0..<editor.draft.roi.count, id: \.self) { i in
                    handle(color: .white)
                        .position(m.toView(norm: editor.draft.roi[i]))
                        .gesture(DragGesture(coordinateSpace: .named(space)).onChanged { v in
                            editor.draft.roi[i] = m.toNorm(v.location)
                        })
                }

                let hoodY = m.toView(0, editor.draft.maxBottomRatio * editor.draft.frameHeight).y
                handle(color: .orange)
                    .position(x: m.rect.minX + 30, y: hoodY)
                    .gesture(DragGesture(coordinateSpace: .named(space)).onChanged { v in
                        editor.draft.maxBottomRatio = min(max(m.toNorm(v.location).y, 0.5), 1.0)
                    })

                if editor.a4On {
                    a4Handle(m, x: editor.a4Left) { editor.a4Left = $0 }
                    a4Handle(m, x: editor.a4Right) { editor.a4Right = $0 }
                }
            }
            .coordinateSpace(name: space)
        }
    }

    private func handle(color: Color) -> some View {
        Circle()
            .fill(color.opacity(0.9))
            .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1))
            .frame(width: 22, height: 22)
            .padding(10)          // vùng chạm rộng hơn
            .contentShape(Circle())
    }

    private func a4Handle(_ m: FrameMapping, x: Double, set: @escaping (Double) -> Void) -> some View {
        let p = m.toView(x, editor.draft.frameHeight / 2)
        return RoundedRectangle(cornerRadius: 4)
            .fill(.cyan.opacity(0.9))
            .frame(width: 14, height: 44)
            .padding(10)
            .contentShape(Rectangle())
            .position(p)
            .gesture(DragGesture(coordinateSpace: .named(space)).onChanged { v in
                set(min(max(m.toFrame(v.location).x, 0), editor.draft.frameWidth))
            })
    }
}
