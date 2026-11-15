// Màn hình ngang: trái là camera + box, phải là bảng HUD (hoặc bảng hiệu chỉnh).
import SafeGapCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    CameraPreview(session: model.camera.session)
                    if let editor = model.editor, model.screen == .calibration {
                        CalibrationOverlay(editor: editor, snapshot: model.snapshot)
                    } else {
                        DetectionOverlay(snapshot: model.snapshot, calibration: model.calibration)
                    }
                }
                .clipped()
                Group {
                    if let editor = model.editor, model.screen == .calibration {
                        CalibrationPanel(editor: editor)
                    } else {
                        HUDPanel(showSettings: $showSettings)
                    }
                }
                .frame(width: max(260, geo.size.width * 0.34))
            }
        }
        .background(model.snapshot.result.level.color.ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
        .alert("SafeGap", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
