import Combine
import CoreLocation
import Foundation
import UIKit

@MainActor
final class CommuteTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var statusText: String?

    private enum Rules {
        static let departureMeters = 100.0
        static let arrivalMeters = 150.0
        static let dwellSeconds: TimeInterval = 20
        static let maximumAccuracyMeters = 30.0
        static let maximumArrivalSpeed = 3.0 // m/s
        static let maximumDwellMovement = 30.0
        static let maximumConfirmationGap: TimeInterval = 45
        static let maximumLocationGap: TimeInterval = 5 * 60
        static let departureTimeout: TimeInterval = 20 * 60
        static let tripTimeout: TimeInterval = 4 * 60 * 60
    }

    private struct Session {
        let id = UUID()
        let direction: String
        let destination: CLLocation
        let requestedAt = Date()
        var origin: TripPoint?
        var departureCandidate: TripPoint?
        var arrivalCandidate: TripPoint?
        var lastValidAt: Date?
        var trip: CommuteTrip?
    }

    private struct Pending {
        let session: Session
        let openNavigation: (UUID?) -> Void
    }

    private let logger: AppLogger
    private let manager = CLLocationManager()
    private let store = CommuteTripStore()
    private var pending: Pending?
    private var session: Session?
    private var watchdog: Timer?

    init(logger: AppLogger) {
        self.logger = logger
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        do {
            let history = try store.recoverInterruptedTrips()
            if history.recovered > 0 {
                logger.record("已标记上次未结束的通勤为中断")
            }
            if let latest = history.latest {
                statusText = latest.status == .arrived ? durationText(latest, prefix: "上次") : "上次通勤记录中断"
            }
        } catch {
            logger.record("无法恢复上次通勤文件", level: .error)
        }
    }

    func begin(direction: String, destination: CLLocation, openNavigation: @escaping (UUID?) -> Void) {
        if session?.direction == direction {
            openNavigation(nil)
            return
        }
        if session != nil {
            interrupt(message: "切换目的地，结束上一次记录")
        }
        pending = Pending(
            session: Session(direction: direction, destination: destination),
            openNavigation: openNavigation
        )
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            startIfReady()
        }
    }

    func foregrounded() {
        checkLimits()
        startIfReady()
    }

    func navigationFailed(for id: UUID?) {
        guard let id, session?.id == id else { return }
        interrupt(message: "高德跳转失败，已停止记录")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if session != nil, !canRecord {
            interrupt(message: "定位授权变化，通勤记录中断")
        }
        startIfReady()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            accept(location)
        }
        checkLimits()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard session != nil else { return }
        if let failure = error as? CLError {
            if failure.code == .locationUnknown { return }
            if failure.code == .denied {
                interrupt(message: "定位服务不可用，通勤记录中断")
                return
            }
        }
        logger.record("定位更新出错（错误码 \((error as NSError).code)）", level: .error)
    }

    private var canRecord: Bool {
        let status = manager.authorizationStatus
        return (status == .authorizedWhenInUse || status == .authorizedAlways)
            && manager.accuracyAuthorization == .fullAccuracy
    }

    private func startIfReady() {
        guard let pending, manager.authorizationStatus != .notDetermined,
              UIApplication.shared.applicationState == .active else { return }
        self.pending = nil
        guard canRecord else {
            statusText = "未开启精确定位，本次只导航"
            logger.record("未获得精确定位授权，跳过通勤记录")
            pending.openNavigation(nil)
            return
        }

        session = pending.session
        statusText = "正在获取起点…"
        logger.record("已开启通勤定位，等待有效起点")
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLimits() }
        }
        pending.openNavigation(pending.session.id)
    }

    private func accept(_ location: CLLocation) {
        guard var active = session,
              CLLocationCoordinate2DIsValid(location.coordinate),
              (0...Rules.maximumAccuracyMeters).contains(location.horizontalAccuracy),
              location.timestamp >= active.requestedAt,
              location.timestamp <= Date().addingTimeInterval(5) else { return }
        if let previous = active.lastValidAt {
            let gap = location.timestamp.timeIntervalSince(previous)
            guard gap > 0 else { return }
            if gap > Rules.maximumLocationGap {
                interrupt(message: "长时间未收到有效定位，通勤记录中断")
                return
            }
            if gap > Rules.maximumConfirmationGap {
                active.departureCandidate = nil
                active.arrivalCandidate = nil
            }
        }
        let point = TripPoint(location)
        guard let origin = active.origin else {
            guard Date().timeIntervalSince(point.time) <= 30 else { return }
            active.origin = point
            active.lastValidAt = point.time
            session = active
            statusText = "等待出发"
            logger.record("已取得有效起点，等待离开起点范围")
            return
        }
        active.lastValidAt = point.time
        if active.trip == nil {
            confirmDeparture(point, origin: origin, session: &active)
        }
        guard var trip = active.trip else {
            session = active
            return
        }
        if let arrival = confirmArrival(location, point: point, session: &active) {
            trip.arrive(at: arrival)
            let saved = save(trip)
            stop()
            let seconds = Int(trip.durationSeconds ?? 0)
            statusText = saved ? durationText(trip, prefix: "本次") : "已到达，行程保存失败"
            logger.record("已确认到达，通勤用时 \(seconds) 秒")
            return
        }
        if trip.sample(point) {
            save(trip)
        }
        active.trip = trip
        session = active
    }

    private func confirmDeparture(_ point: TripPoint, origin: TripPoint, session active: inout Session) {
        guard point.location.distance(from: origin.location) >= Rules.departureMeters else {
            active.departureCandidate = nil
            return
        }
        guard let first = active.departureCandidate else {
            active.departureCandidate = point
            return
        }
        let trip = CommuteTrip(id: active.id, direction: active.direction, requestedAt: active.requestedAt, departure: first)
        active.trip = trip
        save(trip)
        statusText = "正在记录通勤"
        logger.record("已确认出发，开始计时")
    }

    private func confirmArrival(_ location: CLLocation, point: TripPoint, session active: inout Session) -> TripPoint? {
        let aligned = GCJ02.fromGPS(location.coordinate)
        let mappedLocation = CLLocation(latitude: aligned.latitude, longitude: aligned.longitude)
        guard mappedLocation.distance(from: active.destination) <= Rules.arrivalMeters,
              location.speed < 0 || location.speed <= Rules.maximumArrivalSpeed else {
            active.arrivalCandidate = nil
            return nil
        }
        guard let first = active.arrivalCandidate,
              point.location.distance(from: first.location) <= Rules.maximumDwellMovement else {
            active.arrivalCandidate = point
            return nil
        }
        return point.time.timeIntervalSince(first.time) >= Rules.dwellSeconds ? first : nil
    }

    private func checkLimits() {
        guard let active = session else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(active.requestedAt)
        if now.timeIntervalSince(active.lastValidAt ?? active.requestedAt) >= Rules.maximumLocationGap {
            interrupt(message: "长时间未收到有效定位，通勤记录中断")
        } else if active.trip == nil && elapsed >= Rules.departureTimeout {
            interrupt(message: "未检测到出发，已停止定位")
        } else if elapsed >= Rules.tripTimeout {
            interrupt(message: "超过记录时限，通勤记录中断")
        }
    }

    private func interrupt(message: String) {
        guard let active = session else { return }
        var saved = true
        if var trip = active.trip {
            trip.interrupt(at: active.lastValidAt)
            saved = save(trip)
        }
        stop()
        statusText = saved ? message : "通勤记录中断，行程保存失败"
        logger.record(message)
    }

    private func stop() {
        session = nil
        watchdog?.invalidate()
        watchdog = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func durationText(_ trip: CommuteTrip, prefix: String) -> String {
        let direction = trip.direction == "work" ? "上班" : "回家"
        let seconds = Int(trip.durationSeconds ?? 0)
        return "\(prefix)\(direction)用时 \(seconds / 60) 分 \(seconds % 60) 秒"
    }

    @discardableResult
    private func save(_ trip: CommuteTrip) -> Bool {
        do {
            try store.save(trip)
            return true
        } catch {
            logger.record("无法写入通勤行程（错误码 \((error as NSError).code)）", level: .error)
            return false
        }
    }
}
