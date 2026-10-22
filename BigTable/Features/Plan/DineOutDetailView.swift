import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

/// The restaurant planned for a meal: where it is on a map, its address, phone and website,
/// and directions in Maps.
struct PlanDineOutDetailView: View {
    var ref: PlanSlotRef
    var dineOut: PlannerDineOut?
    var canManage: Bool
    var onChange: () -> Void
    var onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accent) private var accent
    @State private var confirmsRemove = false

    var body: some View {
        NavigationStack {
            Group {
                if let dineOut {
                    content(dineOut)
                } else {
                    ContentUnavailableView("No restaurant planned", systemImage: "storefront", description: Text("This meal isn't planned as Dine Out anymore."))
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Dine Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
                if canManage, dineOut != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                onChange()
                            } label: {
                                Label { Text("Change Restaurant") } icon: { Image.menuIcon("storefront") }
                            }
                            Button(role: .destructive) {
                                confirmsRemove = true
                            } label: {
                                Label { Text("Remove Dine Out") } icon: { Image.menuIcon("trash", role: .destructive) }
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                        .accessibilityLabel("More")
                        // Not a confirm button: the text color, not the app's (AGENT.md).
                        .tint(.primary)
                    }
                }
            }
            .alert("Remove this Dine Out plan?", isPresented: $confirmsRemove) {
                Button("Remove", role: .destructive) {
                    onRemove()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func content(_ dineOut: PlannerDineOut) -> some View {
        let name = PlanDineOutFormat.displayName(dineOut)
        let phone = dineOut.phone?.trimmingCharacters(in: .whitespaces)
        let phoneURL = PlanDineOutFormat.phoneURL(phone)
        let website = PlanDineOutFormat.website(dineOut)
        let mapsURL = PlanDineOutFormat.mapsURL(dineOut)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                mapHero(dineOut, name: name)

                HStack(spacing: 14) {
                    PlanDineOutLogo(url: dineOut.logoUrl, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ref.title.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(name)
                            .font(.title2.bold())
                    }
                }
                .padding(.horizontal, 4)

                HStack(spacing: 10) {
                    actionButton("Directions", "arrow.triangle.turn.up.right.diamond.fill", url: mapsURL)
                    actionButton("Call", "phone.fill", url: phoneURL)
                    actionButton("Website", "safari.fill", url: website)
                }

                VStack(spacing: 0) {
                    if let address = dineOut.address, !address.isEmpty {
                        detailRow("mappin.and.ellipse", "Address", address, url: mapsURL)
                    }
                    if let phone, !phone.isEmpty {
                        detailRow("phone", "Phone", phone, url: phoneURL)
                    }
                    if let website {
                        detailRow("safari", "Website", website.host() ?? website.absoluteString, url: website)
                    }
                    if let hours = dineOut.hours, !hours.isEmpty {
                        detailRow("clock", "Hours", hours, url: nil)
                    }
                    if let cuisine = dineOut.cuisine, !cuisine.isEmpty {
                        detailRow("fork.knife", "Cuisine", cuisine, url: nil)
                    }
                    if let price = dineOut.price, !price.isEmpty {
                        detailRow("dollarsign.circle", "Price", price, url: nil)
                    }
                    if dineOut.name == nil {
                        detailRow("text.quote", "Plan", dineOut.label, url: nil)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func mapHero(_ dineOut: PlannerDineOut, name: String) -> some View {
        if let latitude = dineOut.latitude, let longitude = dineOut.longitude {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1600, longitudinalMeters: 1600)), interactionModes: []) {
                Marker(name, systemImage: "fork.knife", coordinate: coordinate)
                    .tint(accent)
            }
            .frame(height: 220)
            .clipShape(.rect(cornerRadius: 22))
            .accessibilityLabel("Map showing \(name)")
        } else {
            VStack(spacing: 6) {
                Image(systemName: "map")
                    .font(.title2)
                    .foregroundStyle(accent)
                Text("Map location unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }
    }

    private func actionButton(_ title: String, _ symbol: String, url: URL?) -> some View {
        Button {
            if let url { openURL(url) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(url == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    @ViewBuilder
    private func detailRow(_ symbol: String, _ label: String, _ value: String, url: URL?) -> some View {
        if let url {
            Button {
                openURL(url)
            } label: {
                detailLabel(symbol, label, value, isLink: true)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isLink)
        } else {
            detailLabel(symbol, label, value, isLink: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func detailLabel(_ symbol: String, _ label: String, _ value: String, isLink: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // A tappable row's icon matches its value's color (AGENT.md); info rows stay grey.
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(isLink ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}
