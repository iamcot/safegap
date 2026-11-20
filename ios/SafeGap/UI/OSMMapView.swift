// Bản đồ OpenStreetMap ở cột phải màn hình chính: nền ô bản đồ OSM, xe ở giữa, bản đồ xoay theo hướng xe chạy.
// Vị trí lấy từ GPS của app (cùng nguồn với tốc độ), không dùng vị trí riêng của MapKit.
// Ô bản đồ tải từ tile.openstreetmap.org (cần mạng, cache đĩa); phải ghi "© OpenStreetMap" theo giấy phép.
// Đây là ô ẢNH bản đồ, khác với "ô dữ liệu đường" trong Cài đặt (chỉ số làn, tốc độ giới hạn, không có hình).
import Combine
import MapKit
import SwiftUI

/// Đếm ô ảnh bản đồ tải được / lỗi để hiện lên màn hình khi bản đồ trống.
final class OSMTileStatus: ObservableObject {
    @Published var loaded = 0
    @Published var failed = 0
    @Published var lastError: String?
}

struct OSMMapView: View {
    var dark: Bool
    var lat: Double?
    var lon: Double?
    var course: Double?
    @StateObject private var status = OSMTileStatus()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            OSMMap(lat: lat, lon: lon, course: course, status: status)
            // ban đêm: làm tối ô bản đồ (ô OSM chỉ có bản sáng) để khỏi chói
            if dark { Color.black.opacity(0.35).allowsHitTesting(false) }
            VStack(alignment: .trailing, spacing: 3) {
                if lat == nil {
                    tag("Đang chờ GPS…")
                } else if status.loaded == 0, let e = status.lastError {
                    tag("Không tải được bản đồ: \(e)")
                }
                tag("© OpenStreetMap")
            }
            .padding(4)
        }
    }

    private func tag(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.black)
            .multilineTextAlignment(.trailing)
    }
}

private struct OSMMap: UIViewRepresentable {
    var lat: Double?
    var lon: Double?
    var course: Double?
    let status: OSMTileStatus

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        let tiles = OSMTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        tiles.status = status
        tiles.canReplaceMapContent = true
        tiles.maximumZ = 19
        map.addOverlay(tiles, level: .aboveLabels)
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.addAnnotation(context.coordinator.car)
        for g in [UIPanGestureRecognizer(), UIPinchGestureRecognizer()] as [UIGestureRecognizer] {
            g.addTarget(context.coordinator, action: #selector(Coordinator.touched))
            g.delegate = context.coordinator
            map.addGestureRecognizer(g)
        }
        // Việt Nam, xa, tới khi có GPS
        map.camera = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 16, longitude: 106),
                                 fromDistance: 2_000_000, pitch: 0, heading: 0)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        guard let lat, let lon else { return }
        let c = context.coordinator
        let p = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        c.car.coordinate = p
        if let course { c.heading = course }
        // người dùng vừa kéo / chụm: 8 s sau mới bám lại
        let now = Date()
        guard now.timeIntervalSince(c.lastTouch) > 8, now.timeIntervalSince(c.lastMove) > 0.5 else { return }
        c.lastMove = now
        let dist = c.first ? 700 : map.camera.centerCoordinateDistance
        c.first = false
        let cam = MKMapCamera(lookingAtCenter: p, fromDistance: min(max(dist, 200), 20_000), pitch: 0, heading: c.heading)
        map.setCamera(cam, animated: true)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        let car = MKPointAnnotation()
        var heading = 0.0
        var first = true
        var lastTouch = Date.distantPast
        var lastMove = Date.distantPast

        @objc func touched() { lastTouch = Date() }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: t) }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "car") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "car")
            v.annotation = annotation
            let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
            v.image = UIImage(systemName: "location.north.circle.fill", withConfiguration: cfg)?
                .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
            return v
        }
    }
}

/// Tải ô bản đồ với User-Agent riêng của app (chính sách tile.openstreetmap.org) và cache trên đĩa.
private final class OSMTileOverlay: MKTileOverlay {
    weak var status: OSMTileStatus?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": "SafeGap-iOS/1.0 (driver assist app)"]
        c.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        Self.session.dataTask(with: url(forTilePath: path)) { [weak self] data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && code == 200 && data != nil
            let msg = error.map { $0.localizedDescription } ?? (code != 200 ? "HTTP \(code)" : nil)
            DispatchQueue.main.async {
                guard let st = self?.status else { return }
                if ok { st.loaded += 1 } else { st.failed += 1; st.lastError = msg }
            }
            result(ok ? data : nil, ok ? nil : (error ?? URLError(.badServerResponse)))
        }.resume()
    }
}
