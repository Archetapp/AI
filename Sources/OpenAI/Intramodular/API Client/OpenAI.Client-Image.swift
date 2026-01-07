//
// Copyright (c) Vatsal Manot
//

import CorePersistence
import Foundation
import Swallow

extension OpenAI.Client {
    /// The format in which the generated images are returned.
    public enum ImageResponseFormat: String, Codable, CaseIterable {
        /// URLs are only valid for 60 minutes after the image has been generated.
        case ephemeralURL = "url"
        case base64JSON = "b64_json"
    }

    /// Create an image using DALL-E.
    ///
    /// The maximum length for the prompt is `1000` characters for `dall-e-2` and `4000` characters for `dall-e-3`.
    public func createImage(
        prompt: String,
        responseFormat: ImageResponseFormat = .ephemeralURL,
        numberOfImages: Int = 1,
        quality: OpenAI.Image.Quality = .standard,
        size: OpenAI.Image.Size = .w1024h1024,
        style: OpenAI.Image.Style = .vivid,
        user: String? = nil
    ) async throws -> OpenAI.List<OpenAI.Image> {
        let requestBody = OpenAI.APISpecification.RequestBodies.CreateImage(
            prompt: prompt,
            model: .dalle3,
            responseFormat: responseFormat,
            numberOfImages: numberOfImages,
            quality: quality,
            size: size,
            style: style,
            user: user
        )

        let response = try await run(\.createImage, with: requestBody)

        return response
    }

    /// Edit an image using an input image and prompt.
    public func createImageWithInputs(
        imageData: Data,
        prompt: String,
        model: String = "gpt-image-1",
        numberOfImages: Int = 1,
        size: String = "1024x1024"
    ) async throws -> OpenAI.List<OpenAI.Image> {
        let boundary = UUID().uuidString
        var body = Data()

        func appendString(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        appendString("\(model)\r\n")

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
        appendString("\(prompt)\r\n")

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"n\"\r\n\r\n")
        appendString("\(numberOfImages)\r\n")

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"size\"\r\n\r\n")
        appendString("\(size)\r\n")

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"image\"; filename=\"image.png\"\r\n")
        appendString("Content-Type: image/png\r\n\r\n")
        body.append(imageData)
        appendString("\r\n")

        appendString("--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/edits")!)
        request.httpMethod = "POST"
        guard let apiKey = interface.configuration.apiKey else {
            throw OpenAI.APIError.apiKeyMissing
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAI.APIError.unknown(message: "Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenAI.APIError.unknown(message: "HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OpenAI.List<OpenAI.Image>.self, from: data)
    }
}
