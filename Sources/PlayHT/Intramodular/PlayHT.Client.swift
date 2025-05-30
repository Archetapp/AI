//
//  PlayHT.Client.swift
//  AI
//
//  Created by Jared Davidson on 11/20/24.
//

import CorePersistence
import LargeLanguageModels
import Merge
import NetworkKit
import Swallow

extension PlayHT {
    @RuntimeDiscoverable
    public final class Client: HTTPClient, _StaticSwift.Namespace {
        public static var persistentTypeRepresentation: some IdentityRepresentation {
            CoreMI._ServiceVendorIdentifier._PlayHT
        }
        
        public typealias API = PlayHT.APISpecification
        public typealias Session = HTTPSession
        
        public let interface: API
        public let session: Session
        public var sessionCache: EmptyKeyedCache<Session.Request, Session.Request.Response>
        
        public required init(configuration: API.Configuration) {
            self.interface = API(configuration: configuration)
            self.session = HTTPSession.shared
            self.sessionCache = .init()
        }
        
        public convenience init(apiKey: String, userID: String) {
            self.init(configuration: .init(apiKey: apiKey, userId: userID))
        }
    }
}

extension PlayHT.Client: CoreMI._ServiceClientProtocol {
    public convenience init(
        account: (any CoreMI._ServiceAccountProtocol)?
    ) async throws {
        let account: any CoreMI._ServiceAccountProtocol = try account.unwrap()
        let serviceVendorIdentifier: CoreMI._ServiceVendorIdentifier = try account.serviceVendorIdentifier.unwrap()
        
        guard serviceVendorIdentifier == CoreMI._ServiceVendorIdentifier._PlayHT else {
            throw CoreMI._ServiceClientError.incompatibleVendor(serviceVendorIdentifier)
        }
        
        guard let credential = try account.credential as? CoreMI._ServiceCredentialTypes.PlayHTCredential else {
            throw CoreMI._ServiceClientError.invalidCredential(try account.credential)
        }
        
        self.init(apiKey: credential.apiKey, userID: credential.userID)
    }
}

extension PlayHT.Client {
    
    public func getAllAvailableVoices() async throws -> [PlayHT.Voice] {
        async let htVoices = availableVoices()
        async let clonedVoices = clonedVoices()
        
        let (available, cloned) = try await (htVoices, clonedVoices)
        return available + cloned
    }
    
    public func availableVoices() async throws -> [PlayHT.Voice] {
        try await run(\.listVoices).voices
    }
    
    public func clonedVoices() async throws -> [PlayHT.Voice] {
        try await run(\.listClonedVoices).voices
    }
    
    public func streamTextToSpeech(
        text: String,
        voice: String,
        settings: PlayHT.VoiceSettings,
        outputSettings: PlayHT.OutputSettings = .default,
        model: PlayHT.Model
    ) async throws -> Data {

        let input = PlayHT.APISpecification.RequestBodies.TextToSpeechInput(
            text: text,
            voice: voice,
            voiceEngine: model,
            quality: outputSettings.quality.rawValue,
            outputFormat: outputSettings.format.rawValue
        )
        
        let responseData = try await run(\.streamTextToSpeech, with: input)
        
        guard let url = URL(string: responseData.href) else {
            throw PlayHTError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(interface.configuration.userId ?? "", forHTTPHeaderField: "X-USER-ID")
        request.addValue(interface.configuration.apiKey ?? "", forHTTPHeaderField: "AUTHORIZATION")
        
        let (audioData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw PlayHTError.audioFetchFailed
        }
        
        guard !audioData.isEmpty else {
            throw PlayHTError.audioFetchFailed
        }
        
        return audioData
    }
    
    
    public func instantCloneVoice(
        sampleFileURL: String,
        name: String
    ) async throws -> PlayHT.Voice.ID {
        let input = PlayHT.APISpecification.RequestBodies.InstantCloneVoiceInput(
            sampleFileURL: sampleFileURL,
            voiceName: name
        )
        
        let response = try await run(\.instantCloneVoice, with: input)
        return .init(rawValue: response.id)
    }
    
    public func instantCloneVoice(
        url: String,
        name: String
    ) async throws -> PlayHT.Voice.ID {
        let input = PlayHT.APISpecification.RequestBodies.InstantCloneVoiceWithURLInput(
            url: url,
            voiceName: name
        )
        
        let response = try await run(\.instantCloneVoiceWithURL, with: input)
        return .init(rawValue: response.id)
    }
    
    public func deleteClonedVoice(
        voice: PlayHT.Voice.ID
    ) async throws {
        try await run(\.deleteClonedVoice, with: .init(voiceID: voice.rawValue))
    }
}

extension PlayHT.Client {
    enum PlayHTError: LocalizedError {
        case invalidURL
        case audioFetchFailed
        
        var errorDescription: String? {
            switch self {
                case .invalidURL:
                    return "Invalid audio URL received from PlayHT"
                case .audioFetchFailed:
                    return "Failed to fetch audio data from PlayHT"
            }
        }
    }
}
