import CoreLocation
import Foundation
import MapKit

/// Restaurant search for Dine Out, with Apple Maps on the device instead of the API's Google
/// Places proxy. Results keep the API's shape (`PlaceResult`), including the img.logo.dev logo
/// the Expo app showed, so saved Dine Out meals look the same in both apps.
enum PlaceSearch {
    /// Places where a family eats out. Food markets and grocery stores are left out.
    private static let categories: [MKPointOfInterestCategory] = [
        .restaurant, .cafe, .bakery, .brewery, .winery, .nightlife,
    ]

    static func restaurants(matching query: String, near center: CLLocationCoordinate2D, radiusMiles: Double = 5) async throws -> [PlaceResult] {
        let meters = min(max(radiusMiles, 1), 50) * 1609.344
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: center, latitudinalMeters: meters * 2, longitudinalMeters: meters * 2)
        request.regionPriority = .required
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)

        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        }
        return response.mapItems.compactMap(result)
    }

    private static func result(_ item: MKMapItem) -> PlaceResult? {
        guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let coordinate = item.location.coordinate
        let address = (item.address?.fullAddress ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let website = item.url?.absoluteString
        let key = item.identifier?.rawValue
            ?? "\(name.lowercased())@\(String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude))"
        let phone = item.phoneNumber?.trimmingCharacters(in: .whitespaces)
        return PlaceResult(
            key: key,
            name: name,
            address: address,
            phone: (phone?.isEmpty ?? true) ? nil : phone,
            logoUrl: logoURL(website: website, name: name),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            sourceClass: "amenity",
            sourceType: sourceType(item.pointOfInterestCategory),
            website: website
        )
    }

    private static func sourceType(_ category: MKPointOfInterestCategory?) -> String {
        switch category {
        case .cafe: "cafe"
        case .bakery: "bakery"
        case .brewery, .winery, .nightlife: "bar"
        default: "restaurant"
        }
    }

    /// The restaurant's logo by its website's domain, or by name when it has no website, as
    /// the API built it.
    static func logoURL(website: String?, name: String) -> String {
        let token = AppConfig.logoDevPublishableKey.isEmpty ? "" : "&token=\(AppConfig.logoDevPublishableKey)"
        if let website, let host = URL(string: website.hasPrefix("http") ? website : "https://\(website)")?.host()?.lowercased() {
            let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if !domain.isEmpty, let encoded = domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                return "https://img.logo.dev/\(encoded)?format=png&size=64\(token)"
            }
        }
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return "https://img.logo.dev/name/\(encodedName)?format=png&size=64\(token)"
    }
}
