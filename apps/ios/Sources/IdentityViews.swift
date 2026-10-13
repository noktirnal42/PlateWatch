import PlateKit
import SwiftUI

/// Everything PlateWatch could read off one vehicle, structured the way it will be cross-referenced:
/// who operates it, where its plate was issued, its unit number, what it is — and *how each fact was
/// determined*. Inference is labelled as inference; ambiguity is shown, never hidden.
struct IdentityCard: View {
    let identity: VehicleIdentity
    /// Called with a USPS state code when the reviewer settles an ambiguous place ("Atlanta, GA").
    var onChooseState: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let agency = identity.agency { agencyBlock(agency) }
            else { Label("Agency not identified", systemImage: "questionmark.building").foregroundStyle(.secondary) }

            if let plate = identity.plate, !plate.registration.isEmpty || plate.state != nil { plateBlock(plate) }
            if !identity.unitNumbers.isEmpty {
                fact("Unit", identity.unitNumbers.joined(separator: ", "), icon: "number")
            }
            if !identity.vehicle.isEmpty {
                fact("Vehicle", ([identity.vehicle.make, identity.vehicle.model].compactMap { $0 }
                                 + identity.vehicle.traits).joined(separator: " · "), icon: "car.side")
            }
            DisclosureGroup("How this was determined") { evidence }
                .font(.subheadline)
            if let key = identity.agency?.agencyKey {
                Label { Text(key).font(.caption.monospaced()).textSelection(.enabled) }
                    icon: { Image(systemName: "link") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cross-reference key \(key)")
            }
        }
        .padding(.vertical, 4)
    }

    private func agencyBlock(_ a: AgencyIdentity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(a.name).font(.headline)
                Spacer(minLength: 8)
                confidenceChip(a)
            }
            Text(subtitle(for: a)).font(.subheadline).foregroundStyle(.secondary)
            if a.isInferred && !a.needsReview {
                Label("Inferred from the markings and the plate", systemImage: "wand.and.stars")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if a.needsReview {
                Label(a.alternatives.isEmpty ? "Please check this reading" : "More than one place fits — which is it?",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(PWStyle.queued)
                if !a.alternatives.isEmpty, let onChooseState {
                    FlowButtons(options: a.alternatives) { option in
                        if let code = option.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
                           USStates.name(forCode: code) != nil { onChooseState(code) }
                    }
                }
            }
        }
    }

    private func subtitle(for a: AgencyIdentity) -> String {
        [a.service, a.place.map { p in a.state.map { "\(p), \(USStates.name(forCode: $0) ?? $0)" } ?? p }
            ?? a.state.flatMap(USStates.name(forCode:))]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func confidenceChip(_ a: AgencyIdentity) -> some View {
        Text(a.needsReview ? "Review" : "\(Int(a.confidence * 100))%")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((a.needsReview ? PWStyle.queued : PWStyle.synced).opacity(0.18), in: .capsule)
            .foregroundStyle(a.needsReview ? PWStyle.queued : PWStyle.synced)
    }

    private func plateBlock(_ p: PlateIdentity) -> some View {
        HStack(spacing: 10) {
            if !p.registration.isEmpty { PlateBadge(text: p.registration) }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.stateName.map { "Issued in \($0)" } ?? "Issuing state unknown").font(.subheadline)
                if p.design == "government-official" {
                    Text("Government / official plate").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fact(_ title: String, _ value: String, icon: String) -> some View {
        Label { VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline)
        } } icon: { Image(systemName: icon).frame(width: 22) }
    }

    @ViewBuilder private var evidence: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(identity.evidence.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .top, spacing: 8) {
                    Text(label(for: e.source)).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: .rect(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(e.field.capitalized): \(e.value)").font(.footnote.weight(.medium))
                        if let d = e.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            ForEach(identity.consistency, id: \.self) {
                Label($0, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
            }
            if identity.agency?.citation != nil {
                Label("Place names checked against the US Census Gazetteer", systemImage: "books.vertical")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }

    private func label(for s: IdentityEvidence.Source) -> String {
        switch s {
        case .doorText: "ON VEHICLE"
        case .plateText: "PLATE"
        case .plateHeader: "PLATE HEADER"
        case .classifier: "IMAGE"
        case .gazetteer: "CENSUS"
        case .inference: "INFERRED"
        case .user: "YOU"
        }
    }
}

/// Wrapping row of small tappable choices.
private struct FlowButtons: View {
    let options: [String]
    let action: (String) -> Void
    var body: some View {
        HStack(spacing: 8) {
            ForEach(options.prefix(4), id: \.self) { option in
                Button(option) { action(option) }
                    .buttonStyle(.bordered).controlSize(.small).tint(PWStyle.fleet)
            }
        }
    }
}
