import Foundation

/// Errors that can occur during feed terms review.
public enum FeedTermsReviewError: Error, Equatable {
    case unknownSource
    case termsURLRequired
    case insecureTermsURL
    case licenceClassNotUsable
    case attributionRequired
    case noSourcesForHost
}

/// Summary of a feed host for review UI.
public struct FeedHostSummary: Sendable, Equatable, Hashable {
    public let host: String
    public let totalCount: Int
    public let confirmedCount: Int

    public init(host: String, totalCount: Int, confirmedCount: Int) {
        self.host = host
        self.totalCount = totalCount
        self.confirmedCount = confirmedCount
    }
}

extension FeedCatalogue {
    /// Returns a summary of feed hosts with total and confirmed counts, sorted by host.
    public func hosts() -> [FeedHostSummary] {
        var counts: [String: (total: Int, confirmed: Int)] = [:]

        for source in sources {
            let host = source.url.host?.lowercased() ?? ""
            var entry = counts[host] ?? (total: 0, confirmed: 0)
            entry.total += 1
            if source.mayBeAnalysed {
                entry.confirmed += 1
            }
            counts[host] = entry
        }

        return counts
            .map { FeedHostSummary(host: $0.key, totalCount: $0.value.total, confirmedCount: $0.value.confirmed) }
            .sorted { $0.host < $1.host }
    }

    /// Confirms terms for all sources on a given host.
    /// - Parameters:
    ///   - host: The image URL host (case-insensitive).
    ///   - licenseClass: The license class (must not be .unknown or .askFirst).
    ///   - termsURL: The HTTPS URL of the terms page (must have non-empty host).
    ///   - attribution: Attribution string (required for .openLicence and .permissioned).
    ///   - now: The date the terms were read (for audit trail).
    /// - Returns: A new FeedCatalogue with updated sources.
    /// - Throws: FeedTermsReviewError for validation failures.
    public func confirmingTerms(
        forHost host: String,
        licenseClass: FeedTerms.LicenseClass,
        termsURL: URL,
        attribution: String,
        now: Date = Date()
    ) throws -> FeedCatalogue {
        let targetHost = host.lowercased()

        // Validate termsURL
        guard termsURL.scheme?.lowercased() == "https" else {
            throw FeedTermsReviewError.insecureTermsURL
        }
        guard let termsURLHost = termsURL.host, !termsURLHost.isEmpty else {
            throw FeedTermsReviewError.insecureTermsURL
        }

        // Validate licenseClass
        guard licenseClass != .unknown && licenseClass != .askFirst else {
            throw FeedTermsReviewError.licenceClassNotUsable
        }

        // Validate attribution
        let trimmedAttribution = attribution.trimmingCharacters(in: .whitespacesAndNewlines)
        if (licenseClass == .openLicence || licenseClass == .permissioned) && trimmedAttribution.isEmpty {
            throw FeedTermsReviewError.attributionRequired
        }

        // Find matching sources
        let matchingIndices = sources.indices.filter {
            sources[$0].url.host?.lowercased() == targetHost
        }

        guard !matchingIndices.isEmpty else {
            throw FeedTermsReviewError.noSourcesForHost
        }

        var newSources = sources
        for index in matchingIndices {
            var source = newSources[index]
            var terms = source.terms
            terms.licenseClass = licenseClass
            terms.termsURL = termsURL
            terms.termsReadOn = now
            // Keep existing attribution if new one is empty and class doesn't require it
            if !trimmedAttribution.isEmpty {
                terms.attribution = trimmedAttribution
            }
            terms.automatedUseAllowed = true
            source.terms = terms
            newSources[index] = source
        }

        return FeedCatalogue(schemaVersion: schemaVersion, sources: newSources)
    }

    /// Confirms terms for a single source by ID.
    /// - Parameters:
    ///   - id: The source UUID.
    ///   - licenseClass: The license class (must not be .unknown or .askFirst).
    ///   - termsURL: The HTTPS URL of the terms page (must have non-empty host).
    ///   - attribution: Attribution string (required for .openLicence and .permissioned).
    ///   - now: The date the terms were read (for audit trail).
    /// - Returns: A new FeedCatalogue with the updated source.
    /// - Throws: FeedTermsReviewError for validation failures.
    public func confirmingTerms(
        forSourceID id: UUID,
        licenseClass: FeedTerms.LicenseClass,
        termsURL: URL,
        attribution: String,
        now: Date = Date()
    ) throws -> FeedCatalogue {
        // Validate termsURL
        guard termsURL.scheme?.lowercased() == "https" else {
            throw FeedTermsReviewError.insecureTermsURL
        }
        guard let termsURLHost = termsURL.host, !termsURLHost.isEmpty else {
            throw FeedTermsReviewError.insecureTermsURL
        }

        // Validate licenseClass
        guard licenseClass != .unknown && licenseClass != .askFirst else {
            throw FeedTermsReviewError.licenceClassNotUsable
        }

        // Validate attribution
        let trimmedAttribution = attribution.trimmingCharacters(in: .whitespacesAndNewlines)
        if (licenseClass == .openLicence || licenseClass == .permissioned) && trimmedAttribution.isEmpty {
            throw FeedTermsReviewError.attributionRequired
        }

        // Find matching source
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            throw FeedTermsReviewError.unknownSource
        }

        var newSources = sources
        var source = newSources[index]
        var terms = source.terms
        terms.licenseClass = licenseClass
        terms.termsURL = termsURL
        terms.termsReadOn = now
        if !trimmedAttribution.isEmpty {
            terms.attribution = trimmedAttribution
        }
        terms.automatedUseAllowed = true
        source.terms = terms
        newSources[index] = source

        return FeedCatalogue(schemaVersion: schemaVersion, sources: newSources)
    }

    /// Revokes confirmation for all sources on a given host.
    /// Sets automatedUseAllowed = false but keeps termsURL/termsReadOn for audit trail.
    /// - Parameter host: The image URL host (case-insensitive).
    /// - Returns: A new FeedCatalogue with updated sources.
    public func revokingConfirmation(forHost host: String) -> FeedCatalogue {
        let targetHost = host.lowercased()
        var newSources = sources

        for index in sources.indices where newSources[index].url.host?.lowercased() == targetHost {
            var source = newSources[index]
            var terms = source.terms
            terms.automatedUseAllowed = false
            source.terms = terms
            newSources[index] = source
        }

        return FeedCatalogue(schemaVersion: schemaVersion, sources: newSources)
    }

    /// Revokes confirmation for a single source by ID.
    /// Sets automatedUseAllowed = false but keeps termsURL/termsReadOn for audit trail.
    /// - Parameter id: The source UUID.
    /// - Returns: A new FeedCatalogue with the updated source.
    public func revokingConfirmation(forSourceID id: UUID) -> FeedCatalogue {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            return self
        }

        var newSources = sources
        var source = newSources[index]
        var terms = source.terms
        terms.automatedUseAllowed = false
        source.terms = terms
        newSources[index] = source

        return FeedCatalogue(schemaVersion: schemaVersion, sources: newSources)
    }
}