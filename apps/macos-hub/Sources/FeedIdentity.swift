import FeedIngest
import PlateKit

/// Identity for a sighting from a fixed camera or any Hub ingest path (docs/IDENTITY.md, docs/FEED-SOURCES.md §1-2):
/// the source's catalogued/operator-set position is the location hint (never this Mac's), review is forced below full
/// resolution, and the smallest frames assert no identity at all.
enum FeedIdentity {
    static func resolve(resolver: IdentityResolver, vehicle: VehicleObservation, markings: FleetMarkings,
                        confidence: Double, tier: AnalysisTier, geohash6: String) -> VehicleIdentity? {
        guard tier != .appearanceOnly else { return nil }
        return resolver.syncIdentity(vehicle: vehicle, markings: markings, confidence: confidence,
                                     location: .init(geohash6: geohash6),
                                     forceReview: !tier.identityMayBeConfirmed)
    }
}
