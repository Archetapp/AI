//
// Copyright (c) Preternatural AI, Inc.
//

import Combine
import FoundationX
import Swallow

extension HuggingFace {
    class Downloader: NSObject, ObservableObject {
        private(set) var destination: URL
        
        enum DownloadState {
            case notStarted
            case downloading(Double)
            case completed(URL)
            case failed(Error)
        }
        
        enum DownloadError: Error {
            case invalidDownloadLocation
            case unexpectedError
        }
        
        private(set) lazy var downloadState: CurrentValueSubject<DownloadState, Never> = CurrentValueSubject(.notStarted)
        private var stateSubscriber: Cancellable?
        
        private var urlSession: URLSession? = nil
        
        init(from url: URL, to destination: URL, using authToken: String? = nil, inBackground: Bool = false) {
            self.destination = destination
            super.init()
            let sessionIdentifier = "swift-transformers.hub.downloader"
            
            var config = URLSessionConfiguration.default
            if inBackground {
                config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
                config.isDiscretionary = false
                config.sessionSendsLaunchEvents = true
            }
            
            self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            
            setupDownload(from: url, with: authToken)
        }
        
        private func setupDownload(from url: URL, with authToken: String?) {
            downloadState.value = .downloading(0)
            urlSession?.getAllTasks { tasks in
                // If there's an existing pending background task with the same URL, let it proceed.
                if let existing = tasks.filter({ $0.originalRequest?.url == url }).first {
                    switch existing.state {
                    case .running:
                        // print("Already downloading \(url)")
                        return
                    case .suspended:
                        // print("Resuming suspended download task for \(url)")
                        existing.resume()
                        return
                    case .canceling:
                        // print("Starting new download task for \(url), previous was canceling")
                        break
                    case .completed:
                        // print("Starting new download task for \(url), previous is complete but the file is no longer present (I think it's cached)")
                        break
                    @unknown default:
                        // print("Unknown state for running task; cancelling and creating a new one")
                        existing.cancel()
                    }
                }
                var request = URLRequest(url: url)
                if let authToken = authToken {
                    request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                }
                
                self.urlSession?.downloadTask(with: request).resume()
            }
        }
        
        @discardableResult
        func waitUntilDone() async throws -> URL {
            for try await state in downloadState.toAsyncStream().eraseToAnyAsyncSequence() {
                switch state {
                    case .completed, .failed:
                        break
                    default:
                        continue
                }
            }
            
            switch downloadState.value {
                case .completed(let url):
                    return url
                case .failed(let error):
                    throw error
                default:
                    throw DownloadError.unexpectedError
            }
        }
        
        func cancel() {
            urlSession?.invalidateAndCancel()
        }
    }
}

extension HuggingFace.Downloader: URLSessionDownloadDelegate {
    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        downloadState.value = .downloading(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // If the downloaded file already exists on the filesystem, overwrite it
            try FileManager.default.moveDownloadedFile(from: location, to: self.destination)
            downloadState.value = .completed(destination)
        } catch {
            downloadState.value = .failed(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            downloadState.value = .failed(error)
        }
    }
}

extension FileManager {
    func moveDownloadedFile(from srcURL: URL, to dstURL: URL) throws {
        if fileExists(atPath: dstURL.path) {
            try removeItem(at: dstURL)
        }
        try moveItem(at: srcURL, to: dstURL)
    }
}
