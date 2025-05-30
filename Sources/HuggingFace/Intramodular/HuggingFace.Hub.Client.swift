//
// Copyright (c) Preternatural AI, Inc.
//

import Combine
import CoreMI
import CorePersistence
import FoundationX
import Swallow

extension HuggingFace.Hub {
    @HadeanIdentifier("bihaz-rupug-pizoj-jivub")
    public final class Client: CoreMI._ServiceClientProtocol {
        public typealias RepoType = HuggingFace.Hub.RepoType
        public typealias Repo = HuggingFace.Hub.Repo
        
        public static let shared = Client()
        
        public var downloadBase: URL
        public var hfToken: String?
        public var endpoint: String
        
        public init(
            downloadBase: URL? = nil,
            hfToken: String? = nil,
            endpoint: String = "https://huggingface.co"
        ) {
            self.hfToken = hfToken
            
            if let downloadBase {
                self.downloadBase = downloadBase
            } else {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                
                self.downloadBase = documents.appending(component: "huggingface")
            }
            
            self.endpoint = endpoint
        }
        
        public convenience init(
            account: (any CoreMI._ServiceAccountProtocol)?
        ) async throws {
            let account: any CoreMI._ServiceAccountProtocol = try account.unwrap()
            let serviceVendorIdentifier: CoreMI._ServiceVendorIdentifier = try account.serviceVendorIdentifier.unwrap()
            
            guard serviceVendorIdentifier == CoreMI._ServiceVendorIdentifier._HuggingFace else {
                throw CoreMI._ServiceClientError.incompatibleVendor(serviceVendorIdentifier)
            }
            
            guard let credential = try account.credential as? CoreMI._ServiceCredentialTypes.APIKeyCredential else {
                throw CoreMI._ServiceClientError.invalidCredential(try account.credential)
            }
            
            self.init(hfToken: credential.apiKey)
        }
    }
}

/// File retrieval
extension HuggingFace.Hub.Client {
    /// Model data for parsed filenames
    public struct Sibling: Codable {
        public let rfilename: String
    }
    
    public struct SiblingsResponse: Codable {
        public let siblings: [Sibling]
    }
    
    /// Throws error if the response code is not 20X
    func httpGet(
        for url: URL
    ) async throws -> (
        Data,
        HTTPURLResponse
    ) {
        var request = URLRequest(url: url)
        if let hfToken = hfToken {
            request.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HuggingFace.Hub.HubClientError.unexpectedError }
        
        switch response.statusCode {
            case 200..<300: break
            case 400..<500: throw HuggingFace.Hub.HubClientError.authorizationRequired
            default: throw HuggingFace.Hub.HubClientError.httpStatusCode(response.statusCode)
        }
        
        return (data, response)
    }
    
    public func getFilenames(
        from repo: Repo,
        matching globs: [String] = []
    ) async throws -> [String] {
        // Read repo info and only parse "siblings"
        let url = URL(string: "\(endpoint)/api/\(repo.type)/\(repo.id)")!
        let (data, _) = try await httpGet(for: url)
        let response = try JSONDecoder().decode(SiblingsResponse.self, from: data)
        let filenames = response.siblings.map { $0.rfilename }
        guard globs.count > 0 else { return filenames }
        
        var selected: Set<String> = []
        for glob in globs {
            selected = selected.union(filenames.matching(glob: glob))
        }
        return Array(selected)
    }
    
    public func getFilenames(
        from repoId: String,
        matching globs: [String] = []
    ) async throws -> [String] {
        return try await getFilenames(from: Repo(id: repoId), matching: globs)
    }
    
    public func getFilenames(
        from repo: Repo,
        matching glob: String
    ) async throws -> [String] {
        return try await getFilenames(from: repo, matching: [glob])
    }
    
    public func getFilenames(
        from repoId: String,
        matching glob: String
    ) async throws -> [String] {
        return try await getFilenames(from: Repo(id: repoId), matching: [glob])
    }
}

/// Configuration loading helpers
extension HuggingFace.Hub.Client {
    /// Assumes the file has already been downloaded.
    /// `filename` is relative to the download base.
    public func configuration(
        from filename: String,
        in repo: Repo
    ) throws -> HuggingFace.Config {
        let fileURL = localRepoLocation(repo).appending(path: filename)
        return try configuration(fileURL: fileURL)
    }
    
    /// Assumes the file is already present at local url.
    /// `fileURL` is a complete local file path for the given model
    public func configuration(
        fileURL: URL
    ) throws -> HuggingFace.Config {
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [String: Any] else { throw HuggingFace.Hub.HubClientError.parse }
        return HuggingFace.Config(dictionary)
    }
}

/// Whoami
extension HuggingFace.Hub.Client {
    public func whoami() async throws -> HuggingFace.Config {
        guard hfToken != nil else { throw HuggingFace.Hub.HubClientError.authorizationRequired }
        
        let url = URL(string: "\(endpoint)/api/whoami-v2")!
        let (data, _) = try await httpGet(for: url)
        
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [String: Any] else { throw HuggingFace.Hub.HubClientError.parse }
        return HuggingFace.Config(dictionary)
    }
}

/// Snaphsot download
extension HuggingFace.Hub.Client {
    public func localRepoLocation(_ repo: Repo) -> URL {
        downloadBase.appending(component: repo.type.rawValue).appending(component: repo.id)
    }
    
    public struct HubFileDownloader {
        public let repo: Repo
        public let repoDestination: URL
        public let relativeFilename: String
        public let hfToken: String?
        public let endpoint: String?
        
        public var source: URL {
            // https://huggingface.co/coreml-projects/Llama-2-7b-chat-coreml/resolve/main/tokenizer.json?download=true
            var url = URL(string: endpoint ?? "https://huggingface.co")!
            if repo.type != .models {
                url = url.appending(component: repo.type.rawValue)
            }
            url = url.appending(path: repo.id)
            url = url.appending(path: "resolve/main") // TODO: revisions
            url = url.appending(path: relativeFilename)
            return url
        }
        
        public var destination: URL {
            repoDestination.appending(path: relativeFilename)
        }
        
        public var downloaded: Bool {
            FileManager.default.fileExists(at: destination)
        }
        
        public func prepareDestination() throws {
            let directoryURL = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Note we go from Combine in Downloader to callback-based progress reporting
        // We'll probably need to support Combine as well to play well with Swift UI
        // (See for example PipelineLoader in swift-coreml-diffusers)
        @discardableResult
        func download(outputHandler: @escaping (Double) -> Void) async throws -> URL {
            guard !downloaded else {
                return destination
            }
            
            try prepareDestination()
            let downloader = HuggingFace.Downloader(from: source, to: destination, using: hfToken)
            
            let progressSubscription: AnyCancellable = downloader.downloadState.throttle(
                for: .milliseconds(50),
                scheduler: .mainThread,
                latest: true
            )
            .sink { state in
                if case .downloading(let progress) = state {
                    outputHandler(progress)
                }
            }

            try await _asyncWithExtendedLifetime(progressSubscription) {
                try await downloader.waitUntilDone()
            }

            return destination
        }
    }
    
    public func formRequest(repo: HuggingFace.Hub.Repo, relativeFilename: String, authToken: String?) -> URLRequest {
        var url: URL {
            // https://huggingface.co/coreml-projects/Llama-2-7b-chat-coreml/resolve/main/tokenizer.json?download=true
            var url = URL(string: endpoint)!
            if repo.type != .models {
                url = url.appending(component: repo.type.rawValue)
            }
            url = url.appending(path: repo.id)
            url = url.appending(path: "resolve/main") // TODO: revisions
            url = url.appending(path: relativeFilename)
            return url
        }
        
        var request = URLRequest(url: url)
        if let authToken = authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        
        return request
    }
    
    // main snapshot function
    @discardableResult
    public func snapshot(
        from repo: Repo,
        matching globs: [String] = [],
        outputHandler: @escaping (
            Progress
        ) -> Void = {
            _ in
        }
    ) async throws -> URL {
        let filenames = try await getFilenames(from: repo, matching: globs)
        let progress = Progress(totalUnitCount: Int64(filenames.count))
        let repoDestination = localRepoLocation(repo)
        for filename in filenames {
            let fileProgress = Progress(totalUnitCount: 100, parent: progress, pendingUnitCount: 1)
            let downloader = HubFileDownloader(
                repo: repo,
                repoDestination: repoDestination,
                relativeFilename: filename,
                hfToken: hfToken,
                endpoint: endpoint
            )
            try await downloader.download { fractionDownloaded in
                fileProgress.completedUnitCount = Int64(100 * fractionDownloaded)
                outputHandler(progress)
            }
            fileProgress.completedUnitCount = 100
        }
        outputHandler(progress)
        return repoDestination
    }
    
    @discardableResult
    public func snapshot(
        from repoId: String,
        matching globs: [String] = [],
        outputHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        return try await snapshot(
            from: Repo(id: repoId),
            matching: globs,
            outputHandler: outputHandler
        )
    }
    
    @discardableResult
    public func snapshot(
        from repo: Repo,
        matching glob: String,
        outputHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        return try await snapshot(from: repo, matching: [glob], outputHandler: outputHandler)
    }
    
    @discardableResult
    public func snapshot(
        from repoId: String,
        matching glob: String,
        outputHandler: @escaping (Progress) -> Void = {_ in }
    ) async throws -> URL {
        return try await snapshot(from: Repo(id: repoId), matching: [glob], outputHandler: outputHandler)
    }
}

/// Stateless wrappers that use `HubApi` instances
extension HuggingFace.Hub {
    public static func getFilenames(
        from repo: HuggingFace.Hub.Repo,
        matching globs: [String] = []
    ) async throws -> [String] {
        return try await HuggingFace.Hub.Client.shared.getFilenames(from: repo, matching: globs)
    }
    
    public static func getFilenames(
        from repoId: String,
        matching globs: [String] = []
    ) async throws -> [String] {
        return try await HuggingFace.Hub.Client.shared.getFilenames(from: Repo(id: repoId), matching: globs)
    }
    
    public static func getFilenames(
        from repo: Repo,
        matching glob: String
    ) async throws -> [String] {
        return try await HuggingFace.Hub.Client.shared.getFilenames(from: repo, matching: glob)
    }
    
    public static func getFilenames(
        from repoId: String,
        matching glob: String
    ) async throws -> [String] {
        return try await HuggingFace.Hub.Client.shared.getFilenames(
            from: Repo(id: repoId),
            matching: glob
        )
    }
    
    public static func snapshot(
        from repo: Repo,
        matching globs: [String] = [],
        outputHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        return try await HuggingFace.Hub.Client.shared.snapshot(from: repo, matching: globs, outputHandler: outputHandler)
    }
    
    public static func snapshot(
        from repoId: String,
        matching globs: [String] = [],
        outputHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        return try await HuggingFace.Hub.Client.shared.snapshot(from: Repo(id: repoId), matching: globs, outputHandler: outputHandler)
    }
    
    public static func snapshot(
        from repo: Repo,
        matching glob: String,
        outputHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        return try await HuggingFace.Hub.Client.shared.snapshot(from: repo, matching: glob, outputHandler: outputHandler)
    }
    
    public static func snapshot(
        from repoId: String,
        matching glob: String,
        outputHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        return try await HuggingFace.Hub.Client.shared.snapshot(from: Repo(id: repoId), matching: glob, outputHandler: outputHandler)
    }
    
    public static func whoami(token: String) async throws -> HuggingFace.Config {
        return try await HuggingFace.Hub.Client(hfToken: token).whoami()
    }
}

extension [String] {
    fileprivate func matching(glob: String) -> [String] {
        filter { fnmatch(glob, $0, 0) == 0 }
    }
}
