// Dữ liệu đường OpenStreetMap: tải theo ô từ Overpass API, lưu ở Documents/roads/<ô>.json, gộp vào một RoadMap.
// Tự tải các ô quanh xe khi có mạng (mỗi lần một ô, lỗi thì thử lại sau). Không vẽ bản đồ, chỉ tra số làn.
import Foundation
import SafeGapCore

final class RoadStore: ObservableObject {
    @Published private(set) var tileCount = 0
    @Published private(set) var wayCount = 0
    @Published private(set) var bytesOnDisk = 0
    @Published private(set) var downloading: String?
    @Published private(set) var lastError: String?
    @Published private(set) var queued = 0

    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    /// Vùng tải sẵn TP.HCM (nam, tây, bắc, đông).
    static let hcm = (s: 10.65, w: 106.55, n: 10.95, e: 106.85)

    private let map = RoadMap()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "roads", qos: .utility)
    private var have = Set<OSMTile.Key>()
    private var pending: [OSMTile.Key] = []
    private var failedAt: [OSMTile.Key: Date] = [:]
    private var busy = false
    private let dir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("roads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        queue.async { self.loadAll() }
    }

    // MARK: tra cứu (gọi từ luồng xử lý frame)

    func match(lat: Double, lon: Double, courseDeg: Double?) -> RoadMatch? {
        lock.lock()
        defer { lock.unlock() }
        return map.match(lat: lat, lon: lon, courseDeg: courseDeg)
    }

    func ahead(lat: Double, lon: Double, courseDeg: Double?) -> RoadAhead? {
        lock.lock()
        defer { lock.unlock() }
        return map.ahead(lat: lat, lon: lon, courseDeg: courseDeg)
    }

    /// Xếp hàng tải các ô quanh vị trí còn thiếu.
    func ensureAround(lat: Double, lon: Double) {
        enqueue(OSMTile.around(lat: lat, lon: lon))
    }

    func downloadHCM() {
        let b = Self.hcm
        enqueue(OSMTile.keys(s: b.s, w: b.w, n: b.n, e: b.e), force: true)
    }

    func deleteAll() {
        queue.async {
            try? FileManager.default.removeItem(at: self.dir)
            try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
            self.lock.lock()
            self.have.removeAll()
            self.pending.removeAll()
            self.failedAt.removeAll()
            self.lock.unlock()
            self.reloadMapFromDisk()
        }
    }

    // MARK: nội bộ

    private func enqueue(_ keys: [OSMTile.Key], force: Bool = false) {
        queue.async {
            let now = Date()
            self.lock.lock()
            for k in keys where !self.have.contains(k) && !self.pending.contains(k) {
                if !force, let f = self.failedAt[k], now.timeIntervalSince(f) < 600 { continue }  // lỗi gần đây: 10 phút sau thử lại
                self.pending.append(k)
            }
            let n = self.pending.count
            self.lock.unlock()
            DispatchQueue.main.async { self.queued = n }
            self.next()
        }
    }

    /// Chạy trên `queue`.
    private func next() {
        lock.lock()
        guard !busy, !pending.isEmpty else { lock.unlock(); return }
        busy = true
        let k = pending.removeFirst()
        let left = pending.count
        lock.unlock()
        DispatchQueue.main.async { self.downloading = k.name; self.queued = left }

        var req = URLRequest(url: Self.endpoint, timeoutInterval: 150)
        req.httpMethod = "POST"
        req.setValue("SafeGap/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let q = OSMTile.overpassQuery(k).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        req.httpBody = "data=\(q)".data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            self.queue.async { self.finish(k, data: data, resp: resp, err: err) }
        }.resume()
    }

    private func finish(_ k: OSMTile.Key, data: Data?, resp: URLResponse?, err: Error?) {
        var failure: String?
        if let err {
            failure = err.localizedDescription
        } else if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            failure = "Overpass trả mã \(h.statusCode)" + (h.statusCode == 429 ? " (quá nhiều yêu cầu, thử lại sau)" : "")
        } else if let data {
            do {
                let ways = try OSMTile.parseOverpass(data)
                let enc = try JSONEncoder().encode(ways)
                try enc.write(to: file(k), options: .atomic)
                lock.lock()
                map.add(ways)
                have.insert(k)
                lock.unlock()
            } catch {
                failure = "Đọc dữ liệu ô \(k.name) lỗi: \(error.localizedDescription)"
            }
        }
        lock.lock()
        if failure != nil { failedAt[k] = Date() }
        busy = false
        lock.unlock()
        publishStats(error: failure)
        next()
    }

    private func file(_ k: OSMTile.Key) -> URL { dir.appendingPathComponent("\(k.name).json") }

    private func loadAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            let parts = f.deletingPathExtension().lastPathComponent.split(separator: "_").compactMap { Int($0) }
            guard parts.count == 2, let d = try? Data(contentsOf: f),
                  let ways = try? JSONDecoder().decode([RoadWay].self, from: d) else { continue }
            lock.lock()
            map.add(ways)
            have.insert(OSMTile.Key(lat: parts[0], lon: parts[1]))
            lock.unlock()
        }
        publishStats(error: nil)
    }

    private func reloadMapFromDisk() {
        lock.lock()
        map.removeAll()
        lock.unlock()
        loadAll()
    }

    private func publishStats(error: String?) {
        lock.lock()
        let t = have.count, w = map.count, q = pending.count
        lock.unlock()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        DispatchQueue.main.async {
            self.tileCount = t
            self.wayCount = w
            self.bytesOnDisk = bytes
            self.queued = q
            self.downloading = nil
            if let error { self.lastError = error } else if q == 0 { self.lastError = nil }
        }
    }
}
