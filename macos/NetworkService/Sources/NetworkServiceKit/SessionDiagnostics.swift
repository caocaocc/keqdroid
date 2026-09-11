import Foundation

/// Completion releases network ownership, but its log still belongs to the
/// originating XPC connection. Never retain controller credentials here.
public enum SessionDiagnostics {
    public static func canRead(owner: ClientIdentity?, caller: ClientIdentity) -> Bool {
        owner?.uid == caller.uid && owner?.connectionID == caller.connectionID
    }

    public static func snapshot(_ source: [String: Any], owner: ClientIdentity?, caller: ClientIdentity, disconnected: Bool = false) -> [String: Any] {
        guard canRead(owner: owner, caller: caller) else { return ["status": "disconnected"] }
        var result: [String: Any] = ["status": !disconnected && source["status"] as? String == "error" ? "error" : "disconnected"]
        for key in ["log", "error", "errorCode", "errorStage", "recoveryError"] {
            if let value = source[key] as? String { result[key] = value }
        }
        // Monitor-triggered cleanup still asks the client to reconnect. An
        // explicit stop cancels that request even when it retains the log.
        if !disconnected, let reconnect = source["requiresReconnect"] as? Bool {
            result["requiresReconnect"] = reconnect
        }
        return result
    }
}
