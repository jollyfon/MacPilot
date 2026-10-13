import Foundation

/// A catalog entry: the verified release plus whatever compatibility manifest
/// was published for it. `compatibility == nil` means "not published for this
/// historical release" — compatibility unknown, never guessed. While a load is
/// still in flight, `nil` can also mean "manifest not fetched yet"; entries are
/// patched in place as the manifests arrive.
struct CatalogRelease: Identifiable, Equatable, Sendable {
    let release: SoftwareRelease
    let compatibility: ReleaseCompatibility?

    var id: String { release.version.description }
    var channel: AppChannel { release.isPrerelease ? .beta : .stable }

    func relation(to currentVersion: String) -> VersionRelation {
        release.relation(to: currentVersion)
    }

    var compatibilityState: ConfigurationCompatibility {
        ConfigurationCompatibility(release: self)
    }

    func withCompatibility(_ compatibility: ReleaseCompatibility) -> CatalogRelease {
        CatalogRelease(release: release, compatibility: compatibility)
    }
}

struct VersionCatalog: Equatable {
    /// Sorted by SemVer precedence, newest first. GitHub orders by date, which
    /// is not a reliable version order, so the catalog never trusts it.
    let releases: [CatalogRelease]
    let latestStable: SoftwareVersion?
    let latestBeta: SoftwareVersion?
    let fetchedAt: Date

    init(releases: [CatalogRelease], fetchedAt: Date) {
        let sorted = releases.sorted { $0.release.version > $1.release.version }
        self.releases = sorted
        latestStable = sorted.first { $0.channel == .stable }?.release.version
        latestBeta = sorted.first { $0.channel == .beta }?.release.version
        self.fetchedAt = fetchedAt
    }
}

/// Separate from `SoftwareUpdateState` on purpose: loading the history list
/// must never make the menu bar claim "checking for updates" or clobber the
/// result of a check the user just ran.
enum ReleaseCatalogState: Equatable {
    case idle
    case loading
    case loaded(VersionCatalog)
    case failed(SoftwareUpdateFailure)
}

/// Fetches every installable release for the Version Manager.
///
/// Only releases that carry a verified archive for this CPU (HTTPS URL, GitHub
/// SHA-256 digest, matching version) are listed; a release without one is
/// filtered out entirely instead of being shown with a disabled install
/// button. Results are cached for five minutes so repeatedly opening the page
/// does not walk the GitHub API each time; a manual refresh bypasses the cache.
///
/// Repositories accumulate hundreds of releases, so loading is incremental:
/// each page is published as soon as it is decoded, and the per-release
/// compatibility manifests are then fetched in small concurrent batches that
/// patch the already-visible rows. The sheet is interactive within the first
/// page instead of waiting for every page and every manifest.
@MainActor
final class ReleaseCatalogService: ObservableObject {
    static let cacheInterval: TimeInterval = 300
    /// 兼容性清单按小批并发拉取；一批完成就补进列表，避免逐个串行等待。
    static let compatibilityBatchSize = 6

    @Published private(set) var state: ReleaseCatalogState = .idle

    private let session: URLSession
    private let currentVersion: String
    private let architecture: AppArchitecture
    private let repositories: [String]
    private let now: () -> Date
    /// Injectable transport so tests stay deterministic without real network.
    /// `@Sendable` because compatibility manifests are fetched from detached
    /// batch tasks, not just from this actor.
    private let performRequest: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var cache: VersionCatalog?
    private var loadTask: Task<Void, Never>?
    private var entriesByRepository: [String: [CatalogRelease]] = [:]

    init(
        session: URLSession = .shared,
        currentVersion: String = AppVersionInfo.current().version,
        architecture: AppArchitecture = .current,
        repositories: [String] = AppIdentity.updateRepositories,
        now: @escaping () -> Date = Date.init,
        performRequest: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.session = session
        self.currentVersion = currentVersion
        self.architecture = architecture
        self.repositories = repositories
        self.now = now
        self.performRequest = performRequest ?? { request in
            try await session.data(for: request)
        }
    }

    func load(forceRefresh: Bool = false) async {
        if let cache, !forceRefresh, now().timeIntervalSince(cache.fetchedAt) < Self.cacheInterval {
            state = .loaded(cache)
            return
        }
        if let loadTask {
            _ = await loadTask.value
            return
        }
        state = .loading
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await self.fetchCatalog()
                self.cache = catalog
                self.state = .loaded(catalog)
            } catch {
                self.state = .failed(SoftwareUpdateFailure(error))
            }
            self.loadTask = nil
        }
        loadTask = task
        _ = await task.value
    }

    /// Catalog entries the Version Manager offers install actions for.
    func installableReleases() -> [CatalogRelease]? {
        guard case .loaded(let catalog) = state else { return nil }
        return catalog.releases
    }

    private func fetchCatalog() async throws -> VersionCatalog {
        entriesByRepository = [:]
        _ = try await ReleaseFetcher.queryRepositories(repositories) { [self] repository in
            do {
                return try await fetchCatalog(repository: repository)
            } catch {
                await discardRepository(repository)
                throw error
            }
        }
        return VersionCatalog(releases: mergedEntries(), fetchedAt: now())
    }

    private func fetchCatalog(repository: String) async throws -> [CatalogRelease] {
        var entries: [CatalogRelease] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let (responses, hasNextPage) = try await fetchReleasesPage(page, repository: repository)
            let fresh = installableEntries(from: responses)
            // 兼容性清单尚未拉取，先按"未知"上架：首屏不等所有分页和清单。
            let baseIndex = entries.count
            entries += fresh.map(\.entry)
            publish(entries, repository: repository)
            entries = await attachCompatibility(
                to: entries,
                repository: repository,
                pairs: fresh.enumerated().map { pair in
                    (index: baseIndex + pair.offset, response: pair.element.response)
                }
            )
            guard hasNextPage else { break }
            page += 1
        }
        return entries
    }

    private func mergedEntries() -> [CatalogRelease] {
        var releases: [SoftwareVersion: CatalogRelease] = [:]
        for repository in repositories {
            for entry in entriesByRepository[repository] ?? [] where releases[entry.release.version] == nil {
                releases[entry.release.version] = entry
            }
        }
        return Array(releases.values)
    }

    private func publish(_ entries: [CatalogRelease], repository: String) {
        entriesByRepository[repository] = entries
        state = .loaded(VersionCatalog(releases: mergedEntries(), fetchedAt: now()))
    }

    private func discardRepository(_ repository: String) {
        entriesByRepository.removeValue(forKey: repository)
        state = .loaded(VersionCatalog(releases: mergedEntries(), fetchedAt: now()))
    }

    private func fetchReleasesPage(_ page: Int, repository: String) async throws -> (responses: [GitHubReleaseResponse], hasNextPage: Bool) {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100&page=\(page)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SoftwareUpdateError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw SoftwareUpdateError.invalidResponse
        }
        let hasNextPage = httpResponse.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true
        return (try JSONDecoder().decode([GitHubReleaseResponse].self, from: data), hasNextPage)
    }

    /// Releases that carry a verified archive for this CPU, paired with their
    /// API response so the compatibility manifest can be fetched afterwards;
    /// the manifest itself is attached later by `attachCompatibility`.
    private func installableEntries(
        from responses: [GitHubReleaseResponse]
    ) -> [(response: GitHubReleaseResponse, entry: CatalogRelease)] {
        responses.compactMap { response in
            guard !response.draft else { return nil }
            let channel: AppChannel = response.prerelease ? .beta : .stable
            guard let release = try? SoftwareRelease.decode(
                response,
                architecture: architecture,
                channel: channel
            ) else {
                // No verified archive for this CPU (or the tag does not match
                // the channel): not installable, so it stays out of the list.
                return nil
            }
            return (response, CatalogRelease(release: release, compatibility: nil))
        }
    }

    /// Fetches the compatibility manifests for `pairs` in small concurrent
    /// batches, patching and republishing the list after each batch so badges
    /// fill in while the user is already reading the list.
    private func attachCompatibility(
        to entries: [CatalogRelease],
        repository: String,
        pairs: [(index: Int, response: GitHubReleaseResponse)]
    ) async -> [CatalogRelease] {
        var patched = entries
        let performRequest = self.performRequest
        let currentVersion = self.currentVersion
        for batchStart in stride(from: 0, to: pairs.count, by: Self.compatibilityBatchSize) {
            let batch = pairs[batchStart..<min(batchStart + Self.compatibilityBatchSize, pairs.count)]
            let manifests = await withTaskGroup(
                of: (index: Int, manifest: ReleaseCompatibility?).self
            ) { group in
                for pair in batch {
                    group.addTask {
                        let manifest = await VersionCompatibilityService.fetch(
                            for: pair.response,
                            currentVersion: currentVersion,
                            performRequest: performRequest
                        )
                        return (pair.index, manifest)
                    }
                }
                var collected: [(index: Int, manifest: ReleaseCompatibility?)] = []
                for await piece in group {
                    collected.append(piece)
                }
                return collected
            }
            var changed = false
            for piece in manifests {
                guard let manifest = piece.manifest else { continue }
                patched[piece.index] = patched[piece.index].withCompatibility(manifest)
                changed = true
            }
            if changed { publish(patched, repository: repository) }
        }
        return patched
    }
}
