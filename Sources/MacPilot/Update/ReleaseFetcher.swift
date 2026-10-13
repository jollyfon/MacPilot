import Foundation

enum ReleaseFetcher {
    /// Query independently so an unavailable repository cannot prevent the
    /// other one from returning verified releases. Cancellation stops all work.
    static func queryRepositories<Value: Sendable>(
        _ repositories: [String],
        fetch: @escaping @Sendable (String) async throws -> Value
    ) async throws -> [Value] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Result<Value, Error>).self) { group in
            for (index, repository) in repositories.enumerated() {
                group.addTask {
                    do { return (index, .success(try await fetch(repository))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var values: [(Int, Value)] = []
            var firstError: Error?
            for try await (index, result) in group {
                try Task.checkCancellation()
                switch result {
                case .success(let value): values.append((index, value))
                case .failure(let error):
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        group.cancelAll()
                        throw error
                    }
                    firstError = firstError ?? error
                    DiagnosticLog.write("SoftwareUpdate", "Release source \(repositories[index]) failed: \(error.localizedDescription)")
                }
            }
            guard !values.isEmpty else { throw firstError ?? SoftwareUpdateError.invalidResponse }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func fetchLatest(
        channel: AppChannel,
        session: URLSession,
        currentVersion: String,
        repositories: [String] = AppIdentity.updateRepositories
    ) async throws -> SoftwareRelease? {
        let releases = try await queryRepositories(repositories) { repository in
            if channel == .beta {
                return try await fetchBeta(repository: repository, session: session, currentVersion: currentVersion)
            }
            return try await fetchStable(repository: repository, session: session, currentVersion: currentVersion)
        }
        return releases.compactMap { $0 }.max { $0.version < $1.version }
    }

    static func selectBeta(_ data: Data, architecture: AppArchitecture = .current) throws -> SoftwareRelease? {
        try JSONDecoder().decode([GitHubReleaseResponse].self, from: data)
            .compactMap { try? SoftwareRelease.decode($0, architecture: architecture, channel: .beta) }
            .max { $0.version < $1.version }
    }

    /// Scan every page: GitHub orders releases by date, not SemVer precedence.
    static func fetchBeta(session: URLSession, currentVersion: String) async throws -> SoftwareRelease? {
        try await fetchLatest(channel: .beta, session: session, currentVersion: currentVersion)
    }

    private static func fetchBeta(repository: String, session: URLSession, currentVersion: String) async throws -> SoftwareRelease? {
        var page = 1
        var best: SoftwareRelease?
        while true {
            try Task.checkCancellation()
            let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100&page=\(page)")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw SoftwareUpdateError.invalidResponse
            }
            if let candidate = try selectBeta(data), best.map({ $0.version < candidate.version }) ?? true {
                best = candidate
            }
            guard response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true else { return best }
            page += 1
        }
    }

    private static func request(_ url: URL, currentVersion: String, isAPI: Bool = false) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if isAPI { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        return request
    }

    private static func fetchStable(repository: String, session: URLSession, currentVersion: String) async throws -> SoftwareRelease? {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let (data, response) = try await session.data(for: request(url, currentVersion: currentVersion, isAPI: true))
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw SoftwareUpdateError.invalidResponse }
        if status == 403 || status == 429 {
            return try await fetchStableFromWeb(repository: repository, session: session, currentVersion: currentVersion)
        }
        guard status == 200 else { throw SoftwareUpdateError.invalidResponse }
        return try SoftwareRelease.decodeGitHubResponse(data)
    }

    private static func fetchStableFromWeb(repository: String, session: URLSession, currentVersion: String) async throws -> SoftwareRelease {
        let url = URL(string: "https://github.com/\(repository)/releases/latest")!
        let (_, response) = try await session.data(for: request(url, currentVersion: currentVersion))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let finalURL = response.url,
              let tagName = finalURL.pathComponents.last,
              !tagName.isEmpty, tagName != "latest" else { throw SoftwareUpdateError.invalidResponse }
        let assetsURL = URL(string: "https://github.com/\(repository)/releases/expanded_assets/\(tagName)")!
        let (data, assetsResponse) = try await session.data(for: request(assetsURL, currentVersion: currentVersion))
        guard (assetsResponse as? HTTPURLResponse)?.statusCode == 200 else { throw SoftwareUpdateError.invalidResponse }
        return try SoftwareRelease.decodeGitHubAssetsHTML(data, tagName: tagName)
    }
}
