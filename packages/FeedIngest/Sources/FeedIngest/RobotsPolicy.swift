import Foundation

/// Parsed robots.txt policy per RFC 9309.
public struct RobotsPolicy: Sendable {
    private let userAgent: String
    private let rules: [Rule]
    private let defaultAllow: Bool

    /// A rule with a pattern and whether it allows or disallows.
    private struct Rule: Sendable {
        let pattern: String
        let isAllow: Bool
        let specificity: Int

        init(pattern: String, isAllow: Bool) {
            self.pattern = pattern
            self.isAllow = isAllow
            // Specificity: length of pattern excluding wildcards and end anchor
            // Empty pattern has specificity 0
            let cleanPattern = pattern.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "$", with: "")
            self.specificity = cleanPattern.count
        }

        func matches(_ path: String) -> Bool {
            // Empty pattern matches everything
            if pattern.isEmpty {
                return true
            }

            var pattern = self.pattern
            let pathToMatch = path

            // Handle trailing $ anchor
            let hasEndAnchor = pattern.hasSuffix("$")
            if hasEndAnchor {
                pattern = String(pattern.dropLast())
            }

            // Convert glob pattern to regex
            // Escape special regex chars except * and $ (already handled)
            let regexPattern = pattern
                .replacingOccurrences(of: ".", with: "\\.")
                .replacingOccurrences(of: "+", with: "\\+")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "{", with: "\\{")
                .replacingOccurrences(of: "}", with: "\\}")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "^", with: "\\^")
                .replacingOccurrences(of: "?", with: "\\?")
                .replacingOccurrences(of: "*", with: ".*")

            let anchoredPattern = hasEndAnchor ? "^\(regexPattern)$" : "^\(regexPattern)"
            guard let regex = try? NSRegularExpression(pattern: anchoredPattern) else {
                return false
            }
            let range = NSRange(location: 0, length: pathToMatch.utf16.count)
            return regex.firstMatch(in: pathToMatch, options: [], range: range) != nil
        }
    }

    /// A group of rules for a specific user-agent.
    private struct Group: Sendable {
        let userAgents: [String]
        let rules: [Rule]

        func matchesUserAgent(_ agent: String) -> Bool {
            let lowerAgent = agent.lowercased()
            return userAgents.contains { lowerAgent.hasPrefix($0.lowercased()) }
        }
    }

    /// Creates a policy allowing all access.
    public static let allowAll = RobotsPolicy(parsing: "", userAgent: "")

    /// Creates a policy disallowing all access.
    public static let disallowAll = RobotsPolicy(parsing: "User-agent: *\nDisallow: /", userAgent: "")

    /// Initialize by parsing robots.txt text.
    /// - Parameters:
    ///   - text: The robots.txt content.
    ///   - userAgent: Our user-agent product token (e.g., "PlateWatchHub").
    public init(parsing text: String, userAgent: String) {
        self.userAgent = userAgent
        var groups: [Group] = []
        var currentUserAgents: [String] = []
        var currentRules: [Rule] = []

        func flushGroup() {
            if !currentUserAgents.isEmpty {
                groups.append(Group(userAgents: currentUserAgents, rules: currentRules))
            }
            currentUserAgents = []
            currentRules = []
        }

        // Normalize line endings
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespaces)

            // Strip inline comments
            if let commentIndex = trimmed.firstIndex(of: "#") {
                trimmed = String(trimmed[..<commentIndex]).trimmingCharacters(in: .whitespaces)
            }

            // Skip empty lines
            if trimmed.isEmpty {
                continue
            }

            // Split on first colon
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let field = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            switch field {
            case "user-agent":
                // If we encounter a new user-agent after having rules, flush the previous group
                if !currentRules.isEmpty || !currentUserAgents.isEmpty {
                    // Check if this is a continuation of the same group (multiple user-agents for same rules)
                    // RFC 9309: consecutive User-agent lines share the following rules
                    if !currentUserAgents.isEmpty && currentRules.isEmpty {
                        // Still building user-agent list for current group
                    } else {
                        flushGroup()
                    }
                }
                currentUserAgents.append(value)
            case "allow":
                currentRules.append(Rule(pattern: value, isAllow: true))
            case "disallow":
                // Per RFC 9309, empty Disallow means allow all (no restriction)
                if !value.isEmpty {
                    currentRules.append(Rule(pattern: value, isAllow: false))
                }
            default:
                break // Ignore unknown fields
            }
        }
        flushGroup()

        // Merge groups with same user-agent
        var mergedGroups: [String: Group] = [:]
        for group in groups {
            for ua in group.userAgents {
                let key = ua.lowercased()
                if let existing = mergedGroups[key] {
                    mergedGroups[key] = Group(userAgents: existing.userAgents, rules: existing.rules + group.rules)
                } else {
                    mergedGroups[key] = group
                }
            }
        }

        // Select the most specific matching group
        let matchingGroups = mergedGroups.values.filter { $0.matchesUserAgent(userAgent) }
        let selectedGroup: Group?
        if let exactMatch = matchingGroups.first(where: { $0.userAgents.contains { $0.lowercased() == userAgent.lowercased() } }) {
            selectedGroup = exactMatch
        } else if let prefixMatch = matchingGroups.max(by: { a, b in
            let aMax = a.userAgents.max { $0.count < $1.count }?.count ?? 0
            let bMax = b.userAgents.max { $0.count < $1.count }?.count ?? 0
            return aMax < bMax
        }) {
            selectedGroup = prefixMatch
        } else if let starGroup = mergedGroups["*"] {
            selectedGroup = starGroup
        } else {
            selectedGroup = nil
        }

        if let group = selectedGroup {
            self.rules = group.rules
            self.defaultAllow = true // Default is allow if no matching rule
        } else {
            self.rules = []
            self.defaultAllow = true
        }
    }

    /// Check if a path (including query string) is allowed.
    /// - Parameter path: The path starting with /, including query string if present.
    /// - Returns: true if allowed, false if disallowed.
    public func isAllowed(path: String) -> Bool {
        // Per RFC 9309, the path must start with / for matching.
        // If it doesn't, treat as allowed (not a valid path to restrict).
        guard path.hasPrefix("/") else { return true }

        // Find all matching rules
        var matchingRules: [Rule] = []
        for rule in rules {
            if rule.matches(path) {
                matchingRules.append(rule)
            }
        }

        if matchingRules.isEmpty {
            return defaultAllow
        }

        // Longest match wins; Allow wins ties
        let bestRule = matchingRules.max { a, b in
            if a.specificity != b.specificity {
                return a.specificity < b.specificity
            }
            // Allow wins tie: Disallow < Allow, so Allow is "greater" and wins
            return !a.isAllow && b.isAllow
        }

        return bestRule?.isAllow ?? defaultAllow
    }
}