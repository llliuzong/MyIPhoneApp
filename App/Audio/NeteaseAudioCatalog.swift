import Foundation
import Security

enum NeteaseAudioCatalog {
    static let hotPlaylistID = 3778678
    private static let base = URL(string: "https://music.163.com")!
    private static let session = URLSession(configuration: .ephemeral)

    enum Failure: Error {
        case invalidResponse, signedOut, keychain(OSStatus), unavailable
    }

    struct SignIn {
        let key: String

        var url: URL {
            var parts = URLComponents(url: base.appendingPathComponent("login"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "codekey", value: key)]
            return parts.url!
        }
    }

    enum SignInStatus {
        case waiting, scanned, expired, authorized(String)
    }

    private struct Track: Decodable {
        struct Artist: Decodable { let name: String }
        let id: Int
        let name: String
        let ar: [Artist]
    }

    private struct Tracks: Decodable {
        struct Playlist: Decodable { let tracks: [Track] }
        let code: Int
        let playlist: Playlist?
        let songs: [Track]?
    }

    private struct Account: Decodable {
        struct User: Decodable { let id: Int }
        let account: User?
    }

    private struct Likes: Decodable {
        let code: Int
        let ids: [Int]?
    }

    private struct QRResponse: Decodable {
        let code: Int
        let unikey: String?
    }

    private struct Streams: Decodable {
        struct Entry: Decodable {
            struct Trial: Decodable {}
            let id: Int
            let code: Int
            let url: String?
            let expi: Double?
            let freeTrialInfo: Trial?
        }
        let code: Int
        let data: [Entry]?
    }

    static func tracks(cookie: String?, favorites: Bool) async throws -> [CommuteAudioItem] {
        let tracks: [Track]
        if favorites, let cookie {
            let (account, _) = try await request(Account.self, "nuser/account/get", cookie: cookie)
            guard let user = account.account else { throw Failure.signedOut }
            let (likes, _) = try await request(Likes.self, "song/like/get", fields: ["uid": String(user.id)], cookie: cookie)
            if likes.code == 301 { throw Failure.signedOut }
            guard likes.code == 200, let ids = likes.ids else { throw Failure.invalidResponse }
            let selected = Array(ids.prefix(100))
            guard !selected.isEmpty else { return [] }
            let selection = try JSONEncoder().encode(selected.map { ["id": $0] })
            let (details, _) = try await request(Tracks.self, "v3/song/detail",
                fields: ["c": String(decoding: selection, as: UTF8.self)], cookie: cookie)
            guard details.code == 200, let songs = details.songs else { throw Failure.invalidResponse }
            let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            tracks = selected.compactMap { byID[$0] }
        } else {
            let (details, _) = try await request(Tracks.self, "v6/playlist/detail",
                fields: ["id": String(hotPlaylistID), "n": "24", "s": "0"], cookie: cookie)
            guard details.code == 200, let playlist = details.playlist else { throw Failure.invalidResponse }
            tracks = playlist.tracks
        }
        guard !tracks.isEmpty else { return [] }
        let available = try await streams(for: tracks.map(\.id), cookie: cookie)
        return tracks.compactMap { track in
            guard let (url, expiry) = available[track.id] else { return nil }
            return CommuteAudioItem(id: String(track.id), kind: .netease, title: track.name,
                author: track.ar.map(\.name).joined(separator: " / "), stream: url,
                source: base.appendingPathComponent("song").appending(queryItems: [.init(name: "id", value: String(track.id))]),
                expiresAt: expiry)
        }
    }

    static func stream(for item: CommuteAudioItem, cookie: String?) async throws -> URL {
        guard let id = Int(item.id), let (url, _) = try await streams(for: [id], cookie: cookie)[id] else {
            throw Failure.unavailable
        }
        return url
    }

    static func startSignIn() async throws -> SignIn {
        let (response, _) = try await request(QRResponse.self, "login/qrcode/unikey", fields: ["type": "3"])
        guard response.code == 200, let key = response.unikey, !key.isEmpty else { throw Failure.invalidResponse }
        return SignIn(key: key)
    }

    static func checkSignIn(_ signIn: SignIn) async throws -> SignInStatus {
        let (response, cookies) = try await request(QRResponse.self, "login/qrcode/client/login",
            fields: ["type": "3", "key": signIn.key])
        switch response.code {
        case 800: return .expired
        case 801: return .waiting
        case 802: return .scanned
        case 803:
            guard let token = cookies.first(where: { $0.name == "MUSIC_U" })?.value,
                  !token.isEmpty,
                  token.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 59 }) else { throw Failure.invalidResponse }
            let cookie = "MUSIC_U=" + token
            let (account, _) = try await request(Account.self, "nuser/account/get", cookie: cookie)
            guard account.account != nil else { throw Failure.signedOut }
            return .authorized(cookie)
        default: throw Failure.invalidResponse
        }
    }

    static func savedCookie() -> String? {
        var result: CFTypeRef?
        var query = keychainQuery
        query[kSecReturnData as String] = true
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveCookie(_ cookie: String) throws {
        let data = Data(cookie.utf8)
        var status = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = keychainQuery
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    static func forgetCookie() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "LongWay.Netease",
            kSecAttrAccount as String: "ConsumerSession"
        ]
    }

    private static func streams(for ids: [Int], cookie: String?) async throws -> [Int: (URL, Date)] {
        let list = try JSONEncoder().encode(ids)
        let (response, _) = try await request(Streams.self, "song/enhance/player/url/v1",
            fields: ["ids": String(decoding: list, as: UTF8.self), "level": "standard", "encodeType": "mp3"], cookie: cookie)
        if response.code == 301 { throw Failure.signedOut }
        guard response.code == 200, let entries = response.data else { throw Failure.invalidResponse }
        var result: [Int: (URL, Date)] = [:]
        for entry in entries where entry.code == 200 && entry.freeTrialInfo == nil {
            guard let value = entry.url, var components = URLComponents(string: value),
                  components.scheme == "http" || components.scheme == "https",
                  let host = components.host?.lowercased(), host.hasSuffix(".music.126.net"),
                  components.user == nil, components.password == nil else { continue }
            components.scheme = "https"
            guard let url = components.url else { continue }
            result[entry.id] = (url, .now.addingTimeInterval(max(0, (entry.expi ?? 300) - 45)))
        }
        return result
    }

    private static func request<Response: Decodable>(_ type: Response.Type, _ path: String,
        fields: [String: String] = [:], cookie: String? = nil) async throws -> (Response, [HTTPCookie]) {
        var request = URLRequest(url: base.appendingPathComponent("api/" + path), timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(base.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8) ?? Data()
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let responseURL = http.url, responseURL.host == base.host else { throw Failure.invalidResponse }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String { result[name] = value }
        }
        return (try JSONDecoder().decode(type, from: data), HTTPCookie.cookies(withResponseHeaderFields: headers, for: responseURL))
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
