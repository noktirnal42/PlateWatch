import Foundation

/// Delivery and analysis are independent: a busy analyzer does not imply a frozen camera.
struct LiveFeedHealth: Equatable {
    enum Delivery: Equatable { case waiting, current, delayed }
    let delivery: Delivery
    let analysisAge: Int?
    let unchanged: Bool

    init(now: Date, received: Date?, analysed: Date?, changed: Date? = nil,
         snapshotInterval: TimeInterval? = nil) {
        let deliveryLimit = snapshotInterval.map { max(60, $0 * 2) } ?? 6
        if let received {
            delivery = now.timeIntervalSince(received) > deliveryLimit ? .delayed : .current
        } else {
            delivery = .waiting
        }
        analysisAge = analysed.map { max(0, Int(now.timeIntervalSince($0))) }
        unchanged = snapshotInterval.map { interval in
            changed.map { now.timeIntervalSince($0) > max(600, interval * 2) } ?? false
        } ?? false
    }

    var deliveryText: String {
        switch delivery {
        case .waiting: "Waiting for a frame"
        case .current: "Frames arriving"
        case .delayed: "No recent frame delivery"
        }
    }

    var analysisText: String {
        guard let analysisAge else { return "Awaiting analysis" }
        return "Analysis \(analysisAge)s ago"
    }
}
