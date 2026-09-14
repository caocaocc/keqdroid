import Foundation

/// XPC has already verified the installed application and its resources. This
/// gate separates ordinary proxy use from permission to change routes and DNS.
public enum SessionAccessPolicy {
    public static func isBusy(owner: ClientIdentity?, caller: ClientIdentity) -> Bool {
        owner.map { $0.uid != caller.uid || $0.connectionID != caller.connectionID } ?? false
    }
    public static func validate(method: String, arguments: [String: Any], identity: ClientIdentity, tunAuthorized: Bool, owner: ClientIdentity?, activeSessionID: String?, ownerDisconnected: Bool = false, recoveryPending: Bool = false) throws {
        guard identity.uid >= 500 else { throw ServiceFailure("authorizationDenied", "Network sessions require an ordinary macOS account.") }
        switch method {
        case "startProxySession":
            guard arguments["connectionMode"] as? String == "proxy", arguments["dnsAddress"] == nil, arguments["contextId"] == nil else {
                throw ServiceFailure("invalidRequest", "Proxy sessions cannot request TUN or system DNS changes.")
            }
        case "prepareNetworkContext", "startSession":
            guard tunAuthorized else { throw ServiceFailure("authorizationRequired", "Authorize TUN for this macOS account first.") }
        case "getSession", "stopSession": break
        default: throw ServiceFailure("unknownMethod", "Unknown network service method.")
        }
        // Only a native XPC disconnect (or a previous helper epoch recovered
        // from a protected journal) permits same-account residual cleanup.
        let residualStop = method == "stopSession" && arguments["sessionId"] == nil &&
            recoveryPending && ownerDisconnected && owner?.uid == identity.uid
        if let owner, !residualStop {
            guard owner.uid == identity.uid, owner.connectionID == identity.connectionID else {
                throw ServiceFailure("busy", "Another account or application instance owns this network session.")
            }
        }
        if let activeSessionID, !residualStop, method == "stopSession" || method == "getSession" && arguments["sessionId"] != nil {
            guard arguments["sessionId"] as? String == activeSessionID else { throw ServiceFailure("sessionMismatch", "The requested session no longer owns the connection.") }
        }
    }
}
