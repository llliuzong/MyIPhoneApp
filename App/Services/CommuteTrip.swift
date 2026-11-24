import CoreLocation
import Foundation

struct TripPoint: Codable {
    // Raw Core Location coordinates (WGS 84).
    let latitude: Double
    let longitude: Double
    let time: Date
    let accuracyMeters: Double

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        time = location.timestamp
        accuracyMeters = location.horizontalAccuracy
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

struct CommuteTrip: Codable {
    enum Status: String, Codable {
        case recording, arrived, interrupted
    }

    let id: UUID
    let direction: String
    let requestedAt: Date
    let departedAt: Date
    var endedAt: Date?
    var durationSeconds: TimeInterval?
    var status: Status = .recording
    var points: [TripPoint]

    init(id: UUID, direction: String, requestedAt: Date, departure: TripPoint) {
        self.id = id
        self.direction = direction
        self.requestedAt = requestedAt
        departedAt = departure.time
        points = [departure]
    }

    mutating func sample(_ point: TripPoint) -> Bool {
        guard let last = points.last, point.time.timeIntervalSince(last.time) >= 30 else { return false }
        points.append(point)
        return true
    }

    mutating func arrive(at point: TripPoint) {
        points.removeAll { $0.time >= point.time }
        points.append(point)
        status = .arrived
        endedAt = point.time
        durationSeconds = point.time.timeIntervalSince(departedAt)
    }

    mutating func interrupt(at lastKnownTime: Date?) {
        status = .interrupted
        endedAt = lastKnownTime ?? points.last?.time
        durationSeconds = endedAt?.timeIntervalSince(departedAt)
    }
}

struct CommuteTripStore {
    private let folder = URL.applicationSupportDirectory.appendingPathComponent("CommuteTrips", isDirectory: true)

    func save(_ trip: CommuteTrip) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(trip.id.uuidString).appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(trip).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func recoverInterruptedTrips() throws -> (recovered: Int, latest: CommuteTrip?) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return (0, nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var recovered = 0
        var latest: CommuteTrip?
        for file in files where file.pathExtension == "json" {
            var trip = try decoder.decode(CommuteTrip.self, from: Data(contentsOf: file))
            if trip.status == .recording {
                trip.interrupt(at: nil)
                try save(trip)
                recovered += 1
            }
            if latest.map({ trip.requestedAt > $0.requestedAt }) ?? true {
                latest = trip
            }
        }
        return (recovered, latest)
    }
}
