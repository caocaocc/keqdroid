import Foundation
import CNetworkXPC

public struct NetworkServiceError: LocalizedError {
    public let code: String
    public let message: String
    public let stage: String?
    public var errorDescription: String? { message }
    public init(code: String, message: String, stage: String? = nil) { self.code = code; self.message = message; self.stage = stage }
    public init(response: [String: Any]) {
        self.init(code: response["code"] as? String ?? "serviceError", message: response["message"] as? String ?? "Network service failed.", stage: response["stage"] as? String)
    }

    public static func bridge(_ error: Error, method: String) -> (code: String, message: String, details: [String: String]) {
        var details = ["method": method]
        guard let service = error as? NetworkServiceError else { return ("macos_network", error.localizedDescription, details) }
        details["serviceCode"] = service.code
        if let stage = service.stage { details["stage"] = stage }
        return (service.code, service.message, details)
    }
}

private final class ResponseBox {
    let method: String
    let completion: (Result<[String: Any], Error>) -> Void
    init(method: String, _ completion: @escaping (Result<[String: Any], Error>) -> Void) { self.method = method; self.completion = completion }
    func receive(_ text: String) {
        let result: Result<[String: Any], Error>
        do {
            guard let envelope = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw NetworkServiceError(code: "invalidResponse", message: "Invalid network service response.")
            }
            if envelope["ok"] as? Bool == true {
                guard let value = envelope["result"] as? [String: Any] else { throw NetworkServiceError(code: "invalidResponse", message: "Invalid network service result.") }
                result = .success(value)
            } else {
                guard envelope["ok"] as? Bool == false, let error = envelope["error"] as? [String: Any], error["code"] is String else { throw NetworkServiceError(code: "invalidResponse", message: "Invalid network service error response.") }
                let failure = NetworkServiceError(response: error)
                result = .failure(NetworkServiceClient.classify(failure, method: method))
            }
        } catch {
            let failure = error as? NetworkServiceError ?? NetworkServiceError(code: "invalidResponse", message: "Cannot decode the network service response.")
            result = .failure(NetworkServiceClient.classify(failure, method: method))
        }
        DispatchQueue.main.async { self.completion(result) }
    }
}

/// Retain one instance for the Runner lifetime. Closing its XPC connection ends
/// its active network session. Completions are always delivered on the main queue.
public final class NetworkServiceClient {
    private let connection: UnsafeMutableRawPointer?
    public init() { connection = keq_client_create() }
    deinit { keq_client_destroy(connection) }

    public static func classify(_ error: NetworkServiceError, method: String) -> NetworkServiceError {
        if ["startSession", "startProxySession"].contains(method),
           ["timeout", "serviceInterrupted", "serviceInvalidated", "serviceUnavailable", "invalidResponse"].contains(error.code) {
            return NetworkServiceError(code: "requestOutcomeUnknown", message: "The start request lost its reply. Check the existing session before starting again.", stage: error.code)
        }
        return error
    }

    public func call(method: String, arguments: [String: Any] = [:], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["method": method, "arguments": arguments])
            guard data.count <= 4 * 1024 * 1024, let json = String(data: data, encoding: .utf8) else {
                throw NetworkServiceError(code: "invalidRequest", message: "Network request is too large.")
            }
            let context = Unmanaged.passRetained(ResponseBox(method: method, completion)).toOpaque()
            keq_client_call(connection, json, { response, context in
                guard let context else { return }
                let box = Unmanaged<ResponseBox>.fromOpaque(context).takeRetainedValue()
                box.receive(response.map { String(cString: $0) } ?? "{}")
            }, context)
        } catch { DispatchQueue.main.async { completion(.failure(error)) } }
    }

    /// Requests the administrator-approved persistent TUN grant for the current
    /// account. Password handling belongs to macOS Authorization Services.
    public func authorize(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        call(method: "getServiceStatus") { status in
            guard case .success(let info) = status else { completion(status); return }
            if info["authorized"] as? Bool == true { completion(.success(info)); return }
            DispatchQueue.global(qos: .userInitiated).async {
                var bytes = [UInt8](repeating: 0, count: 32)
                var authorization: UnsafeMutableRawPointer?
                let status = keq_authorization_external(&bytes, bytes.count, &authorization)
                guard status == 0 else {
                    DispatchQueue.main.async { completion(.failure(NetworkServiceError(code: status == -60006 ? "authorizationCancelled" : "authorizationDenied", message: "Administrator authorization was not granted (\(status))."))) }
                    return
                }
                // Keep the original AuthorizationRef alive until the daemon
                // has imported and checked the online external form.
                let retainedAuthorization = authorization
                self.call(method: "authorize", arguments: ["authorization": Data(bytes).base64EncodedString()]) { result in
                    keq_authorization_release(retainedAuthorization)
                    completion(result)
                }
            }
        }
    }
}
