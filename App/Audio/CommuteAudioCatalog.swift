import Foundation

enum CommuteListening: String, CaseIterable, Identifiable, Codable {
    case off, music, podcast

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "关闭"
        case .music: "音乐"
        case .podcast: "播客"
        }
    }
}

struct CommuteAudioItem: Identifiable, Codable {
    let id: String
    let kind: CommuteListening
    let title: String
    let author: String
    let stream: URL
    let source: URL?
}

enum CommuteAudioCatalog {
    static let podcastWebsite = URL(string: "https://dao.fm/listening-guide")!
    private static let podcastFeed = URL(string: "https://feeds.daopub.com/all.xml")!

    static func episodes() async throws -> [CommuteAudioItem] {
        let data = try await fetch(podcastFeed)
        let delegate = PodcastFeed()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.episodes.isEmpty else { throw CatalogError.empty }
        return Array(delegate.episodes.prefix(24))
    }

    static func popularTracks(clientID: String) async throws -> [CommuteAudioItem] {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.jamendo.com"
        parts.path = "/v3.0/tracks/"
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "order", value: "popularity_week"),
            URLQueryItem(name: "limit", value: "24")
        ]
        guard let url = parts.url else { throw CatalogError.invalidResponse }
        let data = try await fetch(url)
        let response = try JSONDecoder().decode(JamendoResponse.self, from: data)
        guard response.headers.status == "success" else { throw CatalogError.invalidResponse }
        let tracks = response.results.compactMap { track -> CommuteAudioItem? in
            guard let stream = secureURL(track.audio), !track.id.isEmpty,
                  track.id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            let source = secureURL(track.shareurl) ?? URL(string: "https://www.jamendo.com/track/" + track.id)
            return CommuteAudioItem(id: "jamendo:" + track.id, kind: .music, title: track.name,
                                    author: track.artist_name, stream: stream, source: source)
        }
        guard !tracks.isEmpty else { throw CatalogError.empty }
        return tracks
    }

    fileprivate static func secureURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 12)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == "https", data.count <= 10_000_000 else { throw CatalogError.invalidResponse }
        return data
    }

    private enum CatalogError: Error {
        case invalidResponse, empty
    }

    private struct JamendoResponse: Decodable {
        struct Headers: Decodable { let status: String }
        struct Track: Decodable {
            let id: String
            let name: String
            let artist_name: String
            let audio: String
            let shareurl: String?
        }
        let headers: Headers
        let results: [Track]
    }
}

private final class PodcastFeed: NSObject, XMLParserDelegate {
    private struct Episode {
        var title = ""
        var guid = ""
        var author = ""
        var link = ""
        var stream: URL?
    }

    private var episode: Episode?
    private var stack: [String] = []
    private var text = ""
    private(set) var episodes: [CommuteAudioItem] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes attributeDict: [String: String]) {
        stack.append(elementName)
        text = ""
        if elementName == "item" {
            episode = Episode()
        } else if elementName == "enclosure", attributeDict["type"]?.hasPrefix("audio/") != false {
            episode?.stream = CommuteAudioCatalog.secureURL(attributeDict["url"])
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer {
            _ = stack.popLast()
            text = ""
        }
        if elementName == "item" {
            if let episode, let stream = episode.stream, !episode.title.isEmpty {
                let id = "dao:" + (episode.guid.isEmpty ? stream.absoluteString : episode.guid)
                if !episodes.contains(where: { $0.id == id }) {
                    episodes.append(CommuteAudioItem(
                        id: id, kind: .podcast, title: episode.title,
                        author: episode.author.isEmpty ? "津津乐道" : episode.author,
                        stream: stream, source: CommuteAudioCatalog.secureURL(episode.link) ?? CommuteAudioCatalog.podcastWebsite
                    ))
                }
            }
            episode = nil
            return
        }
        guard stack.dropLast().last == "item" else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": episode?.title = value
        case "guid": episode?.guid = value
        case "itunes:author": episode?.author = value
        case "link": episode?.link = value
        default: break
        }
    }
}
