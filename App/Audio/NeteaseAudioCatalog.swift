import Foundation
import Security

enum NeteaseAudioCatalog {
    static let hotPlaylistID = 3778678
    private static let base = URL(string: "https://music.163.com")!
    static let webSignInURL = base.appendingPathComponent("login")
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    enum Failure: Error {
        case invalidResponse, http(Int), qrStatus(Int), missingSession, accountRejected(Int?)
        case signedOut, keychain(OSStatus), unavailable
    }

    struct SignIn {
        let key: String
        let expiresAt = Date.now.addingTimeInterval(180)

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
        let code: Int?
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
            let selected = Array(try await favoriteIDs(cookie: cookie).prefix(100))
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
        guard response.code == 200 else { throw Failure.qrStatus(response.code) }
        guard let key = response.unikey, !key.isEmpty else { throw Failure.invalidResponse }
        return SignIn(key: key)
    }

    static func checkSignIn(_ signIn: SignIn) async throws -> SignInStatus {
        let (response, http) = try await request(QRResponse.self, "login/qrcode/client/login",
            fields: ["type": "3", "key": signIn.key])
        switch response.code {
        case 800: return .expired
        case 801: return .waiting
        case 802: return .scanned
        case 803:
            guard let cookie = authorizationCookie(from: http) else { throw Failure.missingSession }
            return .authorized(cookie)
        default: throw Failure.qrStatus(response.code)
        }
    }

    static func verifySignIn(_ cookie: String) async throws {
        _ = try await accountID(cookie: cookie)
    }

    static func verifyWebSignIn(_ cookie: String) async throws -> Int {
        try await favoriteIDs(cookie: cookie).count
    }

    private static func favoriteIDs(cookie: String) async throws -> [Int] {
        let userID = try await accountID(cookie: cookie)
        let (likes, _) = try await request(Likes.self, "song/like/get", fields: ["uid": String(userID)], cookie: cookie)
        if likes.code == 301 { throw Failure.signedOut }
        guard likes.code == 200, let ids = likes.ids else { throw Failure.invalidResponse }
        return ids
    }

    private static func accountID(cookie: String) async throws -> Int {
        let (account, _) = try await request(Account.self, "nuser/account/get", cookie: cookie)
        guard let user = account.account, user.id > 0 else { throw Failure.accountRejected(account.code) }
        return user.id
    }

    static func webSessionCookie(from cookies: [HTTPCookie]) -> String? {
        for domain in ["music.163.com", "163.com"] {
            for cookie in cookies where cookie.name == "MUSIC_U" && cookie.path == "/" {
                guard cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == domain,
                      cookie.expiresDate.map({ $0 > .now }) ?? true else { continue }
                if let session = sessionCookie(token: cookie.value) { return session }
            }
        }
        return nil
    }

    private static func authorizationCookie(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        let name = "MUSIC_U"
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: base)
            .first(where: { $0.name == name })?.value
        // Foundation can combine multiple Set-Cookie fields into a single header line.
        let prefix = name + "="
        let combined = header.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        return parsed.flatMap(sessionCookie(token:)) ?? combined.flatMap(sessionCookie(token:))
    }

    private static func sessionCookie(token: String) -> String? {
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 44 && $0 != 59 }) else { return nil }
        return "MUSIC_U=" + token
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
        fields: [String: String] = [:], cookie: String? = nil) async throws -> (Response, HTTPURLResponse) {
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
        guard let http = response as? HTTPURLResponse, http.url?.host == base.host else { throw Failure.invalidResponse }
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
        return (try JSONDecoder().decode(type, from: data), http)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
