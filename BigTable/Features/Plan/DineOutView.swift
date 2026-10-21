import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

/// Plan a meal out: search restaurants near you (or near a city you type when location is
/// off), see them on a map, and pick one. Or just name the night ("Pizza night out").
struct PlanDineOutView: View {
    var ref: PlanSlotRef
    /// What's planned now, to prefill the name.
    var current: PlannerDineOut?
    var onSave: (PlannerDineOut) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

    @State private var location = PlanLocationProvider()
    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var isSearching = false
    @State private var isLocating = true
    @State private var message: String?
    @State private var searchCenter: CLLocationCoordinate2D?
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .automatic
    @State private var selectedKey: String?
    @State private var radiusMiles: Double = 25
    @State private var areaText = ""
    @State private var isFindingArea = false
    @State private var customLabel = ""

    private var api: BigTableAPI { .shared }
    private static let minimumQueryLength = 3
    private static let radiusOptions: [Double] = [5, 10, 25, 31]

    private static let quickSearches: [PlanQuickSearch] = [
        PlanQuickSearch(label: "Fast Food", query: "fast food", symbol: "takeoutbag.and.cup.and.straw"),
        PlanQuickSearch(label: "Diner", query: "diner", symbol: "cup.and.saucer"),
        PlanQuickSearch(label: "Restaurant", query: "restaurant", symbol: "fork.knife"),
        PlanQuickSearch(label: "Fine Dining", query: "fine dining", symbol: "sparkles"),
    ]

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var selectedPlace: PlaceResult? { results.first { $0.key == selectedKey } }

    /// Changes whenever a new search should run.
    private var searchKey: String {
        let center = searchCenter.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) } ?? "none"
        return "\(normalizedQuery)|\(Int(radiusMiles))|\(center)"
    }

    /// The map has moved well away from where the results came from.
    private var mapMovedAway: Bool {
        guard let mapCenter, let searchCenter else { return false }
        return Self.miles(from: mapCenter, to: searchCenter) > max(1, radiusMiles / 5)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    map
                    if searchCenter == nil, !isLocating {
                        areaCard
                    }
                    quickChips
                    resultsSection
                    customSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Restaurants, cuisines, or a name")
            .navigationTitle("Dine Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Distance", selection: $radiusMiles) {
                            ForEach(Self.radiusOptions, id: \.self) { miles in
                                Text("Within \(Int(miles)) miles").tag(miles)
                            }
                        }
                    } label: {
                        Label("Distance", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .accessibilityLabel("Distance, within \(Int(radiusMiles)) miles")
                    // Not a confirm button: the text color, not the app's (AGENT.md).
                    .tint(.primary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let place = selectedPlace {
                    Button {
                        save(place)
                    } label: {
                        Text("Plan \(place.name)")
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .task { await locate() }
            .task(id: searchKey) { await search() }
            .onAppear {
                if let current, current.name == nil { customLabel = current.label }
            }
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera, selection: $selectedKey) {
            UserAnnotation()
            ForEach(results) { place in
                Marker(place.name, systemImage: "fork.knife", coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
                    .tint(place.key == selectedKey ? accent : Color.gray)
                    .tag(place.key)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            mapCenter = context.region.center
        }
        .onChange(of: selectedKey) { _, key in
            guard let key, let place = results.first(where: { $0.key == key }) else { return }
            withAnimation(.smooth) {
                camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), latitudinalMeters: 2500, longitudinalMeters: 2500))
            }
        }
        .frame(height: 250)
        .clipShape(.rect(cornerRadius: 22))
        .overlay(alignment: .top) {
            if mapMovedAway {
                Button {
                    searchCenter = mapCenter
                } label: {
                    Label("Search This Area", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .padding(.top, 10)
            } else if isLocating {
                Label("Finding you…", systemImage: "location")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect()
                    .padding(.top, 10)
            }
        }
        .accessibilityLabel("Map of restaurants")
    }

    /// Location is off: search near a city or neighborhood instead.
    private var areaCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(location.isDenied ? "Location is off" : "Where are you eating?", systemImage: "location.slash")
                    .font(.headline)
                Text("Type a city, neighborhood or ZIP code to find restaurants there. You can also turn on location for BigTable in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("City or neighborhood", text: $areaText)
                        .textContentType(.addressCity)
                        .submitLabel(.search)
                        .onSubmit { Task { await findArea() } }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12))
                    Button {
                        Task { await findArea() }
                    } label: {
                        if isFindingArea {
                            ProgressView()
                        } else {
                            Text("Go")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(areaText.trimmingCharacters(in: .whitespaces).isEmpty || isFindingArea)
                }
                if location.isDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: settings)
                        .font(.footnote.weight(.semibold))
                        .tint(.primary)
                }
            }
        }
    }

    private var quickChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.quickSearches, id: \.query) { chip in
                    let isOn = normalizedQuery == chip.query
                    Button {
                        query = chip.query
                    } label: {
                        Label(chip.label, systemImage: chip.symbol)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .background(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsSection: some View {
        if normalizedQuery.count < Self.minimumQueryLength {
            Text("Search for a restaurant, or tap a kind of place above. Results are within \(Int(radiusMiles)) miles.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else if isSearching && results.isEmpty {
            LoadingCard(title: "Searching nearby…")
        } else if results.isEmpty {
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(results.count == 1 ? "1 result" : "\(results.count) results")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 4)
                CardList(items: results, inset: 70) { place in
                    resultRow(place)
                }
            }
        }
    }

    private func resultRow(_ place: PlaceResult) -> some View {
        let isSelected = place.key == selectedKey
        return Button {
            withAnimation(.snappy) { selectedKey = isSelected ? nil : place.key }
        } label: {
            HStack(spacing: 12) {
                PlanDineOutLogo(url: place.logoUrl, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(PlanDineOutFormat.conciseAddress(place.address))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if let distance = distanceText(place) {
                        Text(distance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Selects this restaurant")
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or just name it")
                .font(.headline)
                .padding(.horizontal, 4)
            Card(padding: 12) {
                HStack(spacing: 8) {
                    TextField("Pizza night out", text: $customLabel)
                        .submitLabel(.done)
                        .onSubmit(saveCustom)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 44)
                    Button("Save", action: saveCustom)
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .disabled(customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("Plans the meal as eating out without picking a place.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Actions

    private func locate() async {
        isLocating = true
        defer { isLocating = false }
        if let coordinate = await location.locate() {
            center(on: coordinate)
        } else if let last = PlanLocationProvider.lastKnown {
            center(on: last)
        }
    }

    private func center(on coordinate: CLLocationCoordinate2D) {
        searchCenter = coordinate
        mapCenter = coordinate
        PlanLocationProvider.remember(coordinate)
        camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 9000, longitudinalMeters: 9000))
    }

    private func findArea() async {
        let text = areaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isFindingArea = true
        defer { isFindingArea = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = .address
        do {
            let response = try await MKLocalSearch(request: request).start()
            center(on: response.boundingRegion.center)
            message = nil
        } catch {
            message = "Couldn't find \u{201C}\(text)\u{201D}. Try a city and state."
        }
    }

    private func search() async {
        let text = normalizedQuery
        guard text.count >= Self.minimumQueryLength else {
            results = []
            selectedKey = nil
            message = nil
            return
        }
        guard let center = searchCenter else {
            results = []
            message = isLocating ? nil : "Turn on location or type an area above to search nearby."
            return
        }
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await PlaceSearch.restaurants(matching: text, near: center, radiusMiles: radiusMiles)
            guard !Task.isCancelled else { return }
            results = Self.rank(found, query: text, near: center)
            if let selectedKey, !results.contains(where: { $0.key == selectedKey }) { self.selectedKey = nil }
            message = results.isEmpty ? "No restaurants found. Try another neighborhood, cuisine, or city." : nil
            fitCamera()
        } catch is CancellationError {
            return
        } catch {
            results = []
            message = FriendlyError.message(error)
        }
    }

    private func fitCamera() {
        guard !results.isEmpty else { return }
        let latitudes = results.map(\.latitude), longitudes = results.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(), let minLon = longitudes.min(), let maxLon = longitudes.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.4), longitudeDelta: max(0.02, (maxLon - minLon) * 1.4))
        withAnimation(.smooth) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
        mapCenter = searchCenter
    }

    private func save(_ place: PlaceResult) {
        let concise = PlanDineOutFormat.conciseAddress(place.address)
        let label = concise.isEmpty ? place.name : "\(place.name) - \(concise)"
        onSave(PlannerDineOut(
            label: String(label.prefix(160)),
            name: place.name,
            address: concise.isEmpty ? nil : concise,
            phone: (place.phone?.isEmpty ?? true) ? nil : place.phone,
            latitude: place.latitude,
            longitude: place.longitude,
            logoUrl: (place.logoUrl?.isEmpty ?? true) ? nil : place.logoUrl,
            website: (place.website?.isEmpty ?? true) ? nil : place.website
        ))
        dismiss()
    }

    private func saveCustom() {
        let label = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        onSave(PlannerDineOut(label: String(label.prefix(160))))
        dismiss()
    }

    // MARK: Ranking

    private func distanceText(_ place: PlaceResult) -> String? {
        guard let searchCenter else { return nil }
        let miles = Self.miles(from: searchCenter, to: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
        return miles < 10 ? String(format: "%.1f mi", miles) : "\(Int(miles.rounded())) mi"
    }

    static func miles(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1609.344
    }

    private static let broadQueries: Set<String> = [
        "restaurant", "restaurants", "fast food", "fast_food", "diner", "diners", "fine dining", "food",
        "eatery", "eateries", "cafe", "cafes", "coffee",
    ]

    /// Broad searches ("diner") sort nearest first; named searches put name matches first,
    /// then nearest, as the Expo app did.
    static func rank(_ places: [PlaceResult], query: String, near center: CLLocationCoordinate2D) -> [PlaceResult] {
        var seen = Set<String>()
        let unique = places.filter { seen.insert($0.key).inserted }
        func distance(_ place: PlaceResult) -> Double {
            miles(from: center, to: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
        }
        if broadQueries.contains(query) {
            return unique.sorted { distance($0) < distance($1) }
        }
        func score(_ place: PlaceResult) -> Int {
            let name = place.name.lowercased()
            if name == query { return 0 }
            if name.hasPrefix(query) { return 1 }
            if name.contains(query) { return 2 }
            return 3
        }
        return unique.sorted { lhs, rhs in
            let left = score(lhs), right = score(rhs)
            return left == right ? distance(lhs) < distance(rhs) : left < right
        }
    }
}

/// A kind of place to search for with one tap.
private struct PlanQuickSearch: Hashable {
    var label: String
    var query: String
    var symbol: String
}
