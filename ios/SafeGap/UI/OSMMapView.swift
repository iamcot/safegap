// Bản đồ OpenStreetMap ở cột phải màn hình chính: nền ô bản đồ OSM, chấm vị trí xe, bản đồ xoay theo hướng xe chạy.
// Ô bản đồ tải từ tile.openstreetmap.org (cần mạng, MapKit tự cache); phải ghi "© OpenStreetMap" theo giấy phép.
import MapKit
import SwiftUI

struct OSMMapView: View {
    var dark: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            OSMMap()
            // ban đêm: làm tối ô bản đồ (ô OSM chỉ có bản sáng) để khỏi chói
            if dark { Color.black.opacity(0.35).allowsHitTesting(false) }
            Text("© OpenStreetMap")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.black)
                .padding(4)
        }
    }
}

private struct OSMMap: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        let tiles = OSMTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        tiles.canReplaceMapContent = true
        tiles.maximumZ = 19
        map.addOverlay(tiles, level: .aboveLabels)
        map.showsUserLocation = true
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.setCameraZoomRange(MKMapView.CameraZoomRange(minCenterCoordinateDistance: 150, maxCenterCoordinateDistance: 20_000),
                               animated: false)
        map.camera.centerCoordinateDistance = 700
        map.setUserTrackingMode(.followWithHeading, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {}

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: t) }
            return MKOverlayRenderer(overlay: overlay)
        }

        /// Kéo / chụm bản đồ thì MapKit bỏ chế độ bám xe; 8 s sau tự bám lại (đang lái không bấm lại được).
        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            guard mode != .followWithHeading else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak mapView] in
                guard let mapView, mapView.userTrackingMode != .followWithHeading else { return }
                mapView.setUserTrackingMode(.followWithHeading, animated: true)
            }
        }
    }
}

/// Tải ô bản đồ với User-Agent riêng của app (chính sách tile.openstreetmap.org) và cache trên đĩa.
private final class OSMTileOverlay: MKTileOverlay {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": "SafeGap-iOS/1.0 (driver assist app)"]
        c.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        Self.session.dataTask(with: url(forTilePath: path)) { data, _, error in result(data, error) }.resume()
    }
}
