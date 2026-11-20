// Xe bên hông mà camera không còn thấy (chủ app 20/11): màn chính vẽ xe mình to, mũi xe sát mép dưới dải camera,
// nên chỉ cần vẽ xe ở làn bên cạnh đang đi ngang / sau xe mình. Camera chỉ thấy phía trước, nên nhớ xe cùng chiều
// đã thấy ở làn bên cạnh: khi nó ra khỏi khung hình lúc đang ở gần (xe mình vượt nó, hoặc nó áp sát ngang),
// đoán tiếp vị trí theo tốc độ tương đối lúc cuối, giữ tối đa `holdS` giây hoặc tới khi tụt hẳn ra sau.
import Foundation

public struct SideVehicle: Equatable, Sendable {
    public var id: Int
    /// Làn so với làn mình: −1 ngay bên trái, +1 ngay bên phải.
    public var lane: Int
    /// Mét, tính từ camera về phía trước (âm = phía sau camera; xe mình chiếm khoảng −3,2…1,4 m).
    public var z: Double
    public var cls: String

    public init(id: Int, lane: Int, z: Double, cls: String) {
        self.id = id; self.lane = lane; self.z = z; self.cls = cls
    }
}

public struct SideVehicleMemory: Sendable {
    public var holdS = 4.0
    /// Chỉ nhớ xe mất dấu khi đang ở gần hơn ngần này (xa hơn thì mất là do model, không phải đi ra ngoài khung).
    public var leaveNearZ = 12.0
    /// Tụt ra sau xe mình quá ngần này thì bỏ.
    public var minZ = -11.0

    private struct Track { var lane: Int; var z: Double; var vz: Double; var t: Double; var cls: String }
    private var tracks: [Int: Track] = [:]

    public init() {}

    public mutating func reset() { tracks = [:] }

    /// Xe mình đổi làn (−1 sang trái, +1 sang phải): làn của xe đã nhớ dời theo.
    public mutating func laneChanged(_ dir: Int) {
        guard dir != 0 else { return }
        for k in tracks.keys { tracks[k]?.lane -= dir }
    }

    /// `seen`: xe cùng chiều frame này (id track, làn so với làn mình, z mét). Trả về xe đang khuất bên hông.
    public mutating func update(t: Double, seen: [SideVehicle]) -> [SideVehicle] {
        var seenIds = Set<Int>()
        for v in seen {
            seenIds.insert(v.id)
            if var tr = tracks[v.id] {
                let dt = t - tr.t
                if dt > 0.02 {
                    let vz = (v.z - tr.z) / dt
                    tr.vz += 0.3 * (min(max(vz, -25), 25) - tr.vz)
                }
                tr.z = v.z; tr.t = t; tr.lane = v.lane; tr.cls = v.cls
                tracks[v.id] = tr
            } else {
                tracks[v.id] = Track(lane: v.lane, z: v.z, vz: 0, t: t, cls: v.cls)
            }
        }
        var out: [SideVehicle] = []
        for (id, tr) in tracks where !seenIds.contains(id) {
            let dt = t - tr.t
            // xe đang lùi dần về phía mình (vz < 0) mới đi vào vùng khuất; xe đang chạy xa ra thì mất là do model
            let z = tr.z + min(tr.vz, 0) * dt
            if dt > holdS || tr.z > leaveNearZ || tr.lane == 0 || abs(tr.lane) > 2 || z < minZ {
                tracks[id] = nil
                continue
            }
            out.append(SideVehicle(id: id, lane: tr.lane, z: z, cls: tr.cls))
        }
        return out.sorted { $0.id < $1.id }
    }
}
