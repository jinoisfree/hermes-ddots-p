import Foundation

/// Only release assets in this private repository can become executable updates.
struct UpdateRelease: Equatable {
    static func channel(_ info: [String: Any]) -> (repository: String, requiresToken: Bool) {
        if info["DDotsUpdateRepository"] as? String == "jinoisfree/hermes-ddots-p",
           info["DDotsUpdateRequiresToken"] as? Bool == false {
            return ("jinoisfree/hermes-ddots-p", false)
        }
        return ("jinoisfree/hermes-ddots-p", true)
    }
    static let repository = channel(Bundle.main.infoDictionary ?? [:]).repository
    static let requiresToken = channel(Bundle.main.infoDictionary ?? [:]).requiresToken
    static func headers(token: String, requiresToken: Bool = Self.requiresToken) -> [String: String] {
        var result = ["Accept": "application/octet-stream", "X-GitHub-Api-Version": "2022-11-28"]
        if requiresToken { result["Authorization"] = "Bearer " + token }
        return result
    }
    static let api = "https://api.github.com/repos/" + repository
    static let latestURL = URL(string: api + "/releases/latest")!
    let version: String
    let feedID: Int64
    let archiveID: Int64
    let archiveSize: UInt64
    /// Sparkle asks for its feed with `Accept: application/rss+xml`, and GitHub's asset API answers that with the
    /// asset's JSON description, not the file. The signed feed is therefore also kept on the `update-feed` branch,
    /// whose raw address returns the file itself to a token that can read this repository (and nothing without one).
    static let rawFeedURL = URL(string: "https://raw.githubusercontent.com/" + repository + "/update-feed/appcast.xml")!
    var feedURL: URL { Self.rawFeedURL }
    var archiveURL: URL { Self.assetURL(archiveID) }

    static func assetURL(_ id: Int64) -> URL { URL(string: api + "/releases/assets/\(id)")! }

    static func decode(_ data: Data) throws -> Self {
        struct Asset: Decodable { let id: Int64; let name: String; let state: String; let size: UInt64 }
        struct Release: Decodable {
            let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [Asset]
        }
        let value = try JSONDecoder().decode(Release.self, from: data)
        let version = value.tag_name.hasPrefix("v") ? String(value.tag_name.dropFirst()) : value.tag_name
        guard !value.draft, !value.prerelease,
              version.range(of: #"^[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil else {
            throw UpdateFailure.invalidRelease
        }
        let feeds = value.assets.filter { $0.name == "appcast.xml" }
        let archives = value.assets.filter { $0.name == "ddots-\(version)-arm64.zip" }
        guard feeds.count == 1, archives.count == 1, let feed = feeds.first, let archive = archives.first,
              feed.id > 0, archive.id > 0, feed.id != archive.id,
              feed.state == "uploaded", archive.state == "uploaded",
              feed.size > 0, feed.size <= 1_048_576,
              archive.size > 0, archive.size <= 1_073_741_824 else { throw UpdateFailure.invalidRelease }
        return Self(version: version, feedID: feed.id, archiveID: archive.id, archiveSize: archive.size)
    }

    func allows(file: URL?, version: String, size: UInt64, installation: String,
                notes: URL?, information: URL?, hasDeltas: Bool) -> Bool {
        file == archiveURL && version == self.version && size == archiveSize &&
        installation == "application" && notes == nil && information == nil && !hasDeltas
    }
}

enum UpdateFailure: LocalizedError {
    case credentials, access, unavailable, invalidRelease, network, closing, relay
    var errorDescription: String? {
        switch self {
        case .credentials: return "업데이트 연결에서 GitHub 접근 토큰을 등록해 주세요."
        case .access: return "GitHub 접근 권한을 확인하지 못했어요. 토큰 만료와 ddots 저장소의 Contents 읽기 권한을 확인해 주세요."
        case .unavailable: return "아직 업데이트 릴리스가 없거나 저장소 접근 권한이 없어요."
        case .invalidRelease: return "설치 가능한 ddots 배포 파일을 확인하지 못했어요. 현재 앱은 그대로 유지됩니다."
        case .network: return "업데이트 서버에 연결하지 못했어요. 잠시 후 다시 확인해 주세요."
        case .closing: return "앱이 종료 중이에요."
        case .relay: return "다른 Mac과 대화 공유를 끈 뒤 업데이트해 주세요. 업데이트가 끝나면 다시 켤 수 있어요."
        }
    }
}

/// Metadata requests never follow redirects or send credentials to a different host.
/// Sparkle handles the separately signed appcast and archive downloads.
final class UpdateReleaseClient: NSObject, URLSessionTaskDelegate {
    private var session: URLSession!
    init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func close() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    @discardableResult
    func latest(token: String, completion: @escaping (Result<UpdateRelease, Error>) -> Void) -> URLSessionDataTask {
        request(url: UpdateRelease.latestURL, token: token) { result in
            completion(result.flatMap { data in Result { try UpdateRelease.decode(data) } })
        }
    }
    @discardableResult
    func validate(token: String, completion: @escaping (Result<Void, Error>) -> Void) -> URLSessionDataTask {
        request(url: URL(string: UpdateRelease.api)!, token: token) { completion($0.map { _ in () }) }
    }
    private func request(url: URL, token: String, completion: @escaping (Result<Data, Error>) -> Void) -> URLSessionDataTask {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        for (key, value) in UpdateRelease.headers(token: token) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ddots-updater", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse else {
                completion(.failure(UpdateFailure.network)); return
            }
            switch response.statusCode {
            case 200:
                guard let data, data.count <= 1_048_576 else { completion(.failure(UpdateFailure.invalidRelease)); return }
                completion(.success(data))
            case 401, 403: completion(.failure(UpdateFailure.access))
            case 404: completion(.failure(UpdateFailure.unavailable))
            default: completion(.failure(UpdateFailure.network))
            }
        }
        task.resume()
        return task
    }
}
