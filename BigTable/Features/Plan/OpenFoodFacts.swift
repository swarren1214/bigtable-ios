import Foundation

/// Searches Open Food Facts straight from the device for packaged snacks, as the Expo app did
/// (`lib/off-food-api.ts`): US products, 24 a page, English and accented-Latin names only.
nonisolated enum PlanOpenFoodFacts {
    nonisolated struct Page: Sendable {
        var results: [PlannerSnackItem]
        var hasMore: Bool
    }

    nonisolated struct SearchError: LocalizedError, Sendable {
        var status: Int
        var errorDescription: String? { "Food search isn't working right now (\(status)). Try again in a moment." }
    }

    static let pageSize = 24
    private static let fields = "code,product_name,brands,image_front_url,serving_size,nutriments"

    static func search(_ query: String, page: Int = 1) async throws -> Page {
        var components = URLComponents(string: "https://search.openfoodfacts.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "countries_tags", value: "en:united-states"),
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components.url else { throw SearchError(status: 0) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BigTable/2.0 (https://bigtableapp.com)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SearchError(status: status) }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        let results: [PlannerSnackItem] = (decoded.hits ?? []).compactMap { hit in
            guard let code = hit.code, !code.isEmpty,
                  let name = hit.productName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  !hasNonLatin(name) else { return nil }
            let brand = hit.brands?.trimmingCharacters(in: .whitespaces)
            let serving = hit.servingSize?.trimmingCharacters(in: .whitespaces)
            let kcal = hit.kcalServing ?? hit.kcal100g
            return PlannerSnackItem(
                offId: code,
                description: name,
                brandOwner: (brand?.isEmpty ?? true) ? nil : brand,
                imageUrl: (hit.imageFrontUrl?.isEmpty ?? true) ? nil : hit.imageFrontUrl,
                servingSize: (serving?.isEmpty ?? true) ? nil : serving,
                calories: kcal.map { $0.rounded() }
            )
        }
        var seen = Set<String>()
        let unique = results.filter { seen.insert($0.offId).inserted }
        let pageCount = decoded.pageCount ?? 1
        return Page(results: unique, hasMore: page < pageCount)
    }

    /// Anything past Latin Extended-B (Cyrillic, Arabic, CJK…), which the Expo app hid.
    private static func hasNonLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value > 0x24F && $0.value <= 0xFFFF }
    }

    // MARK: Response

    /// Lenient: a field of an unexpected type is skipped rather than failing the page.
    private nonisolated struct SearchResponse: Decodable {
        var hits: [Hit]?
        var pageCount: Int?

        enum CodingKeys: String, CodingKey {
            case hits
            case pageCount = "page_count"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hits = (try? c.decode([Lossy<Hit>].self, forKey: .hits))?.compactMap(\.value)
            pageCount = (try? c.decode(Int.self, forKey: .pageCount)) ?? (try? c.decode(Double.self, forKey: .pageCount)).map { Int($0) }
        }
    }

    private nonisolated struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    private nonisolated struct Hit: Decodable {
        var code: String?
        var productName: String?
        var brands: String?
        var imageFrontUrl: String?
        var servingSize: String?
        var kcalServing: Double?
        var kcal100g: Double?

        enum CodingKeys: String, CodingKey {
            case code
            case productName = "product_name"
            case brands
            case imageFrontUrl = "image_front_url"
            case servingSize = "serving_size"
            case nutriments
        }

        enum NutrimentKeys: String, CodingKey {
            case kcalServing = "energy-kcal_serving"
            case kcal100g = "energy-kcal_100g"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = (try? c.decode(String.self, forKey: .code)) ?? (try? c.decode(Int.self, forKey: .code)).map(String.init)
            productName = try? c.decode(String.self, forKey: .productName)
            // `brands` is a string ("Kellogg's, Pringles") or a list.
            if let list = try? c.decode([String].self, forKey: .brands) {
                brands = list.first
            } else if let text = try? c.decode(String.self, forKey: .brands) {
                brands = text.split(separator: ",").first.map(String.init) ?? text
            }
            imageFrontUrl = try? c.decode(String.self, forKey: .imageFrontUrl)
            servingSize = try? c.decode(String.self, forKey: .servingSize)
            if let n = try? c.nestedContainer(keyedBy: NutrimentKeys.self, forKey: .nutriments) {
                kcalServing = try? n.decode(Double.self, forKey: .kcalServing)
                kcal100g = try? n.decode(Double.self, forKey: .kcal100g)
            }
        }
    }
}
