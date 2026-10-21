import Foundation

/// App-wide settings. The keys here are publishable client keys (Supabase anon key,
/// RevenueCat public SDK key), the same ones the Expo app shipped with; they're meant to be in
/// the app. Every build talks to the production backend.
nonisolated enum AppConfig {
    static let appName = "BigTable"
    static let appGroupID = "group.com.stephenwarren.bigtable"

    // Production backend for every build: the shared Hearth API (BigTable's routes live under
    // /v1/bigtable). Debug builds sign in to real accounts, so test with your own household.
    nonisolated static let apiBaseURL = URL(string: "https://api.hearthapps.com")!
    nonisolated static let supabaseURL = URL(string: "https://kvhvsztvfpydhfpzicyy.supabase.co")!
    nonisolated static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt2aHZzenR2ZnB5ZGhmcHppY3l5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk1ODI2ODIsImV4cCI6MjA5NTE1ODY4Mn0.403bjxC9vkgMJ_ytARSd3DvTnJix2jDbS8rJtd1BpPE"

    /// RevenueCat's Test Store in Debug (no real charges), the App Store in Release. Used by
    /// HearthKit's `HearthPurchases` (BigTable Plus, entitlement `bigtable_plus`, which also counts the legacy "BigTable Pro", and Hearth+).
    #if DEBUG
    nonisolated static let revenueCatAPIKey = "test_VWlSzocJhmnUcnzNbLGZvtLEPZY"
    #else
    nonisolated static let revenueCatAPIKey = "appl_uPeHmxuOBQOlDJCVmEfAoiywHgI"
    #endif

    /// img.logo.dev publishable key for restaurant logos (the Expo app shipped the same one).
    static let logoDevPublishableKey = "pk_M7uaQUcjQq6Zni3X4QMHSA"

    /// Feature switches the Expo app read from EXPO_PUBLIC_FEATURE_* (all on in production).
    static let socialEnabled = true
    static let publishingEnabled = true
    static let pushEnabled = true

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
    }
}
