import CoreLocation
import SwiftUI

@MainActor
struct ContentView: View {
    let logger: AppLogger
    @ObservedObject var tracker: CommuteTracker
    @Environment(\.openURL) private var openURL
    @AppStorage("commute.work") private var workCoordinates = ""
    @AppStorage("commute.home") private var homeCoordinates = ""
    @State private var editing: Destination?
    @State private var showLaunchError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    navigationButton(.work)
                    navigationButton(.home)
                    Text("长按按钮可编辑地点")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let status = tracker.statusText {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("通勤")
        }
        .sheet(item: $editing) { destination in
            DestinationEditor(destination: destination, coordinates: coordinates(for: destination)) { point in
                switch destination {
                case .work: workCoordinates = point.storedValue
                case .home: homeCoordinates = point.storedValue
                }
                logger.record("目的地已保存：\(destination.placeName)")
            } invalidInput: {
                logger.record("目的地坐标校验失败：\(destination.placeName)", level: .error)
            }
        }
        .alert("无法打开高德地图", isPresented: $showLaunchError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请确认 iPhone 已安装高德地图，然后再试一次。")
        }
    }

    private func navigationButton(_ destination: Destination) -> some View {
        Button {
            navigate(to: destination)
        } label: {
            Label(destination.title, systemImage: destination.icon)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.borderedProminent)
        .tint(destination == .work ? .blue : .teal)
        .contextMenu {
            Button {
                edit(destination)
            } label: {
                Label("编辑\(destination.placeName)地点", systemImage: "pencil")
            }
        }
        .accessibilityAction(named: Text("编辑\(destination.placeName)地点")) {
            edit(destination)
        }
    }

    private func coordinates(for destination: Destination) -> Coordinates? {
        Coordinates(storedValue: destination == .work ? workCoordinates : homeCoordinates)
    }

    private func edit(_ destination: Destination) {
        logger.record("打开地点编辑：\(destination.placeName)")
        editing = destination
    }

    private func navigate(to destination: Destination) {
        logger.record("点击\(destination.title)")
        guard let point = coordinates(for: destination) else {
            logger.record("尚未配置有效目的地：\(destination.placeName)")
            edit(destination)
            return
        }
        guard let url = point.navigationURL(placeName: destination.placeName) else {
            logger.record("无法生成高德导航请求：\(destination.placeName)", level: .error)
            showLaunchError = true
            return
        }
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        tracker.begin(direction: destination.rawValue, destination: location) { sessionID in
            logger.record("请求打开高德驾车导航：\(destination.placeName)")
            openURL(url) { accepted in
                if accepted {
                    logger.record("系统接受高德导航跳转：\(destination.placeName)")
                } else {
                    tracker.navigationFailed(for: sessionID)
                    logger.record("系统无法打开高德导航：\(destination.placeName)", level: .error)
                    showLaunchError = true
                }
            }
        }
    }
}

private enum Destination: String, Identifiable {
    case work, home

    var id: Self { self }
    var title: String { self == .work ? "上班" : "回家" }
    var placeName: String { self == .work ? "公司" : "家" }
    var icon: String { self == .work ? "building.2" : "house" }
}

private struct DestinationEditor: View {
    let destination: Destination
    let onSave: (Coordinates) -> Void
    let invalidInput: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var longitude: String
    @State private var latitude: String
    @State private var showInvalidCoordinates = false

    init(destination: Destination, coordinates: Coordinates?, onSave: @escaping (Coordinates) -> Void,
         invalidInput: @escaping () -> Void) {
        self.destination = destination
        self.onSave = onSave
        self.invalidInput = invalidInput
        _longitude = State(initialValue: coordinates.map { String($0.longitude) } ?? "")
        _latitude = State(initialValue: coordinates.map { String($0.latitude) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("经度", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("纬度", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("高德坐标（GCJ-02）")
                } footer: {
                    Text("使用高德坐标拾取器获取经纬度。驾车目的地建议选停车场或小区入口。")
                }
            }
            .navigationTitle("编辑\(destination.placeName)地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                }
            }
            .alert("坐标格式有误", isPresented: $showInvalidCoordinates) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请输入有效的数字。经度范围为 -180 到 180，纬度范围为 -90 到 90。")
            }
        }
    }

    private func save() {
        guard let point = Coordinates(longitude: longitude, latitude: latitude) else {
            invalidInput()
            showInvalidCoordinates = true
            return
        }
        onSave(point)
        dismiss()
    }
}

private struct Coordinates {
    let longitude: Double
    let latitude: Double

    init?(longitude: String, latitude: String) {
        guard let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              (-180...180).contains(lon), (-90...90).contains(lat) else { return nil }
        self.longitude = lon
        self.latitude = lat
    }

    init?(storedValue: String) {
        let parts = storedValue.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(longitude: String(parts[0]), latitude: String(parts[1]))
    }

    var storedValue: String { "\(longitude),\(latitude)" }

    func navigationURL(placeName: String) -> URL? {
        var components = URLComponents()
        components.scheme = "iosamap"
        components.host = "navi"
        components.queryItems = [
            URLQueryItem(name: "sourceApplication", value: "MyIPhoneApp"),
            URLQueryItem(name: "poiname", value: placeName),
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude)),
            URLQueryItem(name: "dev", value: "0"),
            URLQueryItem(name: "style", value: "0")
        ]
        return components.url
    }
}
