import Foundation
import RepoShellShared

public enum AppUpdateClientError: LocalizedError, Equatable, Sendable {
    case invalidRepositorySlug(String)
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepositorySlug(let slug):
            return "Invalid GitHub repository slug: \(slug)"
        case .invalidResponse:
            return "Invalid response from GitHub Releases API."
        case .httpError(let code, let message):
            return message.isEmpty ? "GitHub API returned HTTP \(code)." : "GitHub API returned HTTP \(code): \(message)"
        case .decodingFailed(let detail):
            return "Failed to parse GitHub release metadata: \(detail)"
        }
    }
}

public enum AppUpdateCheckResult: Equatable, Sendable {
    case upToDate(currentVersion: String, latestVersion: String)
    case updateAvailable(AppUpdateState)
    case noPublishedRelease
}

private struct GitHubReleaseAPIModel: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64?
        let content_type: String?
    }

    let tag_name: String
    let name: String?
    let body: String?
    let html_url: String
    let draft: Bool?
    let prerelease: Bool?
    let published_at: Date?
    let assets: [Asset]?
}

public enum GitHubReleaseParser {
    public static func parseLatestRelease(data: Data, checkedAt: Date = Date()) throws -> AppUpdateState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let model: GitHubReleaseAPIModel
        do {
            model = try decoder.decode(GitHubReleaseAPIModel.self, from: data)
        } catch {
            throw AppUpdateClientError.decodingFailed(error.localizedDescription)
        }

        if model.draft == true || model.prerelease == true {
            return nil
        }

        let normalizedVersion = SemanticVersion(parsing: model.tag_name)?.normalizedString
            ?? model.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let selectedAsset = selectMacOSAsset(from: model.assets ?? [])

        return AppUpdateState(
            latestVersion: normalizedVersion,
            tagName: model.tag_name,
            releaseName: (model.name?.isEmpty == false ? model.name! : model.tag_name),
            releaseNotes: model.body ?? "",
            htmlURL: model.html_url,
            downloadURL: selectedAsset?.browser_download_url,
            assetName: selectedAsset?.name,
            assetSize: selectedAsset?.size,
            checkedAt: checkedAt
        )
    }

    private static func selectMacOSAsset(from assets: [GitHubReleaseAPIModel.Asset]) -> GitHubReleaseAPIModel.Asset? {
        let validAssets = assets.filter { !$0.browser_download_url.isEmpty }
        // Prefer .zip (supports seamless ditto extraction and in-place replacement), then .dmg
        let zipAssets = validAssets.filter { $0.name.lowercased().hasSuffix(".zip") }
        if let namedZip = zipAssets.first(where: { $0.name.localizedCaseInsensitiveContains("RepoShell") }) {
            return namedZip
        }
        if let anyZip = zipAssets.first {
            return anyZip
        }
        let dmgAssets = validAssets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        if let namedDmg = dmgAssets.first(where: { $0.name.localizedCaseInsensitiveContains("RepoShell") }) {
            return namedDmg
        }
        return dmgAssets.first
    }
}

public struct AppUpdateClient: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let loader: DataLoader

    public init(loader: @escaping DataLoader = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.loader = loader
    }

    public func checkForUpdate(
        repoSlug: String = AppConstants.githubRepoSlug,
        currentVersion: String = AppConstants.currentVersion
    ) async throws -> AppUpdateCheckResult {
        let trimmedSlug = repoSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmedSlug.split(separator: "/")
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              let apiURL = URL(string: "https://api.github.com/repos/\(components[0])/\(components[1])/releases/latest") else {
            throw AppUpdateClientError.invalidRepositorySlug(repoSlug)
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppConstants.appName)/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await loader(request)
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateClientError.invalidResponse
        }

        if http.statusCode == 404 {
            // No published release exists yet on GitHub
            return .noPublishedRelease
        }

        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            throw AppUpdateClientError.httpError(statusCode: http.statusCode, message: msg)
        }

        guard let latest = try GitHubReleaseParser.parseLatestRelease(data: data) else {
            return .noPublishedRelease
        }

        if latest.isNewer(than: currentVersion) {
            return .updateAvailable(latest)
        }
        return .upToDate(currentVersion: currentVersion, latestVersion: latest.latestVersion)
    }
}
