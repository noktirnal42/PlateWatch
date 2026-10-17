import Foundation
import HubAgentCore

/// Positive allowlist: hosted planners never receive queue/record contents or media URLs.
public enum NIMPublicContext {
    public static func sanitize(action: AgentAction, result: Data) throws -> Data {
        guard let value = try JSONSerialization.jsonObject(with: result) as? [String: Any] else { throw NIMError.invalidResponse }
        let output: [String: Any]
        switch action {
        case .reviewQueue, .findRecords: throw NIMError.invalidInput
        case .status: output = ["models": value["models"] ?? "unknown", "feeds": value["feeds"] ?? "unknown"]
        case .findFeeds, .feedDetails:
            let allowed = Set(["id", "name", "host", "kind", "status", "last_received_at"])
            let rows = (value["items"] as? [[String: Any]] ?? []).filter { row in
                guard row["terms_confirmed"] as? Bool == true, let host = row["host"] as? String,
                      host.contains("."), host.range(of: "^[0-9.:]+$", options: .regularExpression) == nil else { return false }
                return !host.hasSuffix(".local") && !host.hasSuffix(".localhost") && !host.hasSuffix(".internal")
            }.map { row in row.filter { allowed.contains($0.key) } }
            output = ["items": rows]
        default: output = ["action": action.rawValue, "completed": true]
        }
        return try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }
}
