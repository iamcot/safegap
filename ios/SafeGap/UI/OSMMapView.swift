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
    /// Nguồn ô đang dùng (ghi bản quyền đúng nguồn).
    @Published var source = OSMTileOverlay.sources[0].name
    /// Không máy chủ ô nào kết nối được (20/11: tile.openstreetmap.org báo "không thể kết nối máy chủ" ở VN):
    /// bỏ lớp ô, dùng nền Apple Maps.
    @Published var useApple = false
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
                } else if status.loaded == 0, !status.useApple, let e = status.lastError {
                    tag("Không tải được bản đồ: \(e)")
                }
                tag(status.useApple ? "Apple Maps (không tải được ô OSM)" : status.source)
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
        if status.useApple, !map.overlays.isEmpty { map.removeOverlays(map.overlays) }
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
/// Máy chủ chính không kết nối được thì thử máy chủ dự phòng (cùng dữ liệu OSM) và nhớ máy chủ chạy được;
/// tất cả đều lỗi (chưa tải được ô nào sau nhiều lần) thì chuyển nền Apple Maps.
final class OSMTileOverlay: MKTileOverlay {
    static let sources: [(name: String, url: String)] = [
        ("© OpenStreetMap", "https://tile.openstreetmap.org/{z}/{x}/{y}.png"),
        ("© OpenStreetMap © CARTO", "https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png"),
        ("© OpenStreetMap France", "https://a.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png"),
    ]
    private static var preferred = 0
    private static let lock = NSLock()
    weak var status: OSMTileStatus?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": "SafeGap-iOS/1.0 (driver assist app)"]
        c.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    private static func tileURL(_ i: Int, _ p: MKTileOverlayPath) -> URL? {
        URL(string: sources[i].url.replacingOccurrences(of: "{z}", with: "\(p.z)")
            .replacingOccurrences(of: "{x}", with: "\(p.x)").replacingOccurrences(of: "{y}", with: "\(p.y)"))
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        Self.lock.lock(); let start = Self.preferred; Self.lock.unlock()
        attempt(start, tried: 0, path, result)
    }

    private func attempt(_ i: Int, tried: Int, _ path: MKTileOverlayPath, _ result: @escaping (Data?, Error?) -> Void) {
        let n = Self.sources.count
        guard let url = Self.tileURL(i, path) else { result(nil, URLError(.badURL)); return }
        Self.session.dataTask(with: url) { [weak self] data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && code == 200 && data != nil
            if ok {
                Self.lock.lock(); Self.preferred = i; Self.lock.unlock()
                DispatchQueue.main.async {
                    guard let st = self?.status else { return }
                    st.loaded += 1
                    if st.source != Self.sources[i].name { st.source = Self.sources[i].name }
                }
                result(data, nil)
                return
            }
            if tried + 1 < n {
                self?.attempt((i + 1) % n, tried: tried + 1, path, result)
                return
            }
            let msg = error.map { $0.localizedDescription } ?? "HTTP \(code)"
            DispatchQueue.main.async {
                guard let st = self?.status else { return }
                st.failed += 1; st.lastError = msg
                if st.loaded == 0 && st.failed >= 6 { st.useApple = true }
            }
            result(nil, error ?? URLError(.badServerResponse))
        }.resume()
    }
}
