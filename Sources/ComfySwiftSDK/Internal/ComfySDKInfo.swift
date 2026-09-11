import Foundation

enum ComfySDKInfo {
    static let version = "0.4.1"

    static let clientHeaderName = "X-Comfy-Client"

    static let clientHeaderValue = "comfyswiftsdk/\(version)"

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[clientHeaderName] = clientHeaderValue
        configuration.httpAdditionalHeaders = headers
        return configuration
    }
}
