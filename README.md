# BigTable

A native iPhone and iPad app for planning meals and groceries for a big family. It is the Expo
app in `~/Developer/bigtable` rebuilt in SwiftUI with Liquid Glass and the conventions of Caloma,
Suffice, Sated and Hearken, at feature parity, on the **same backend**: the Next.js API on Vercel
and Supabase (accounts, the household, recipes, the plan and grocery lists) with RevenueCat for
Pro. Beta users sign in with the account they have and find their household as they left it, and
the Expo app keeps working alongside this one while the native app rolls out.

It ships as version 2.0 of the same App Store record (`com.stephenwarren.bigtable`), so current
subscribers stay subscribed.

Requires Xcode 26 and iOS 26. iPhone and iPad.

## First run

1. Open `BigTable.xcodeproj`. Xcode fetches RevenueCat (`purchases-ios-spm` 5.x) the first time.
2. Select the **BigTable** target › **Signing & Capabilities** and confirm your **Team** (the same
   team as Caloma). Sign in with Apple, Push Notifications, Associated Domains
   (`applinks:bigtableapp.com`) and the App Group are in the entitlements.
3. Every build talks to the **production** backend (`App/AppConfig.swift`); there is no hosted
   staging. Debug builds use RevenueCat's Test Store, so purchases there cost nothing.
4. Run, and sign in with your own account.

## Screens

- **Sign in**: Sign in with Apple, email and password, create an account (with the strength
  gauge), forgot password. Links in the confirmation and reset emails (`bigtable://auth`) sign
  the person in, or ask for a new password.
- **Household setup** (first sign-in): set up a household (name, people with birthdays, likes,
  dislikes and photos, dietary restrictions) or join one (accept a pending invitation).
- **Plan**: the week (Sunday start; swipe or arrows), Tonight, and each day's breakfast, lunch and
  dinner: recipes with roles (entree, side, dessert, other), a custom meal, or Dine Out, plus
  snacks; who's eating; cooked; "update available" for recipes with a newer version; read-only
  for household members without plan permission. The App Store review prompt comes after a few
  cooked meals.
- **Dine Out**: restaurants near you (or a typed area) on a map, or just a label; details with the
  map, phone, website and directions.
- **Snacks**: Open Food Facts search, straight from the device.
- **Plan My Week** (AI, ⌘K): prompt, quick tags, meal style, recipe mix, days and meals, replace or
  fill; a preview of what changes, then Add to Plan. Shows usage; over the limit opens the paywall.
- **Recipes**: All / Mine / Favorites, search, quick filters, infinite scroll. Recipe detail with
  servings scaling, attribution, creator, like, favorite, share, Add to Plan, edit, publish /
  unpublish, duplicate, delete, version updates.
- **New / Edit Recipe**: photo (camera, library, or generated with AI), ingredients with amounts and
  measurements, steps, tags (including custom tags), and imports: say or type it (recording or
  on-device dictation), and with Pro scan a page, read a photo or screenshot, or a link.
- **Grocery**: the active list by section with checks (saved as you shop), stats and the estimate,
  add/edit/remove items, share; generate with AI for a date range (warehouse sizes, a note,
  replace or merge) with a review step; history and restore (Pro).
- **Community**: Discover, Following and Followers; public profiles with their recipes, follow,
  invite to your household, block.
- **Notifications** (the bell): every notification type, read/unread, accept or decline household
  invitations inline.
- **Profile** (the avatar): account, membership (leave household), household editor, joined
  members and their permissions, invitations, BigTable Pro and usage, notification settings,
  privacy (Community visibility, blocked people), deleted recipes, manage tags, appearance and
  accent, invite a friend, the tour, help links, sign out, delete account.
- **Pro**: RevenueCat offerings (annual first), subscribe, restore.
- **Tour**: the Expo app's tutorial slides, shown once to new organizers.

## How it's built

```
BigTable/
  App/            Entry, router and sheets, tab bar and shared toolbar, AppModel (session,
                  household, permissions, usage, unread count), configuration
  DesignSystem/   Theme, cards, avatars, chips, checks, recipe photo, onboarding layout,
                  FlowLayout, PhotoTools, CameraPicker, error/loading/retry cards, Pro cards
  Models/         API shapes (one for one with the Expo app's types), ingredient parsing
                  (ported from lib/recipe-ingredients.ts), ISODay
  Services/       AuthClient (Supabase Auth over REST, Keychain), BigTableAPI (every endpoint,
                  fallback URL, token refresh), StorageClient (photo uploads), Subscriptions
                  (RevenueCat), OnDevice (Apple Maps search, recipe parsing, link import,
                  transcription, grocery lists,
                  scanning, meal planning)
  Features/       Account, Profile, Paywall, Tutorial, Plan, AIPlan, Recipes, Grocery,
                  Community, Notifications (each with its own @Observable store)
BigTableTests/    Swift Testing: ingredient parsing, dates, API decoding
docs/             PORTING_GUIDE.md (how the port is organized)
```

- **Data**: everything lives on the server, as before. Stores are `@Observable` and main-actor;
  edits update the screen at once and roll back if the API refuses.
- **Auth**: `AuthClient` signs in against Supabase (`/auth/v1`) with the publishable anon key, keeps
  the session in the Keychain and refreshes it a minute before it expires (one refresh at a time).
  Every API call carries the access token; a 401 refreshes once and retries.
- **API**: tries `api.bigtableapp.com` first and the Vercel URL when that can't be
  reached or answers with a 5xx, like the Expo app.
- **Pro**: RevenueCat with the Supabase user id as the app user id, the same entitlement
  ("BigTable Pro") and products. RevenueCat's webhook keeps the server's tier current, and the
  server's tier (`/api/usage/check`) is what gates AI.
- **On the device**: Dine Out searches Apple Maps (MapKit). Recipes from a link are read on the
  phone (schema.org recipe data, or the page's text through Apple's on-device model). Recipes
  you say, type or record are understood by Apple's on-device model (Foundation Models), and
  recordings are transcribed on the phone (SpeechAnalyzer). AI grocery lists (Pro) add up the
  planned recipes' ingredients on the phone and let the on-device model choose store sections
  and how many to buy. Scans of cookbook pages and screenshots are read with Vision and the
  on-device model. Plan My Week (Pro, organizers) narrows the household's recipes in code
  (restrictions, recipe mix, meal type, quick tags, dislikes) to a short list the on-device
  model places; the plan is sent back to the API, which builds the preview and saves it
  without calling Claude. Each falls back to the API when
  the phone can't (no Apple Intelligence, a page the phone can't load, very long text), so
  `/api/places/search` is no longer used and the AI recipe endpoints only see those fallbacks.
  `Services/OnDevice/`.
- **Photos**: uploaded to Supabase Storage (`member-avatars`, `recipe-images`) under the user's
  id; member photos are saved as storage paths, as the Expo app saved them.

## Before shipping

- **Push notifications need a server change.** The API sends through Expo's push service, which
  only accepts Expo tokens. The native app registers its APNs device token with
  `platform: "ios-apns"`; the API's `lib/notifications.ts` needs to send those directly to APNs
  (with an APNs auth key) alongside the Expo tokens. In-app notifications work without it.
- **Supabase Auth**: add `bigtable://auth` to the redirect allow list (it's the Expo app's scheme,
  so it's likely there), and keep `com.stephenwarren.bigtable` in the Apple provider's client ids.
- **AI grocery lists for members**: the API only lets the organizer save a whole list, so the AI
  list is organizer-only (as in the Expo app).

## Next up

Widgets (Tonight, Grocery), a Watch grocery list, App Intents ("What's for dinner"), and the iPad
week grid, from the BigTable designs on the Claude Design canvas.
