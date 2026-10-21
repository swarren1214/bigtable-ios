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

- **Sign in**: Sign in with Apple, as in every Hearth app (one sign-in for BigTable, Sated and
  Suffice). New accounts can't be made with an email. Accounts made with an email before can
  still sign in (and reset a password) from "Signed up with an email? Sign in", and are then
  asked to add Sign in with Apple (`AppleLinkView`, Supabase manual identity linking with the
  Apple ID token), which keeps the same account. "Not Now" asks again in three days. Email
  sign-in goes away once those accounts have moved over.
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
- **New / Edit Recipe**: a new recipe starts on "What are we making?": one box to describe a
  recipe, ask for one, or paste a link (the mic listens the moment it's tapped), idea chips, Scan
  a Page and Photo or Screenshot (Pro), or Write It Myself. The editor has a photo hero (camera,
  library, or made with AI), the name and a line about it, Serves / Prep / Cook tiles,
  difficulty, ingredients typed however you like ("2 cups beef broth" is split up on the phone),
  numbered steps and tags. **Change It with AI**: say or type what to change ("dairy-free and
  enough for 12"); the recipe shows what's new, changed or removed, with Undo, and the mic sends
  when you pause. AI's recipes open there.
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
- **Pro**: BigTable Pro or Hearth+, through HearthKit's paywall (`.hearthPaywall`, `HearthLockedCard`).
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
                  fallback URL, token refresh), StorageClient (photo uploads), Hearth
                  (shared HearthKit code, incl. HearthPurchases/HearthPaywall), OnDevice (Apple Maps search, recipe parsing, link import,
                  transcription, grocery lists,
                  scanning, meal planning)
  Features/       Account, Onboarding, Profile, Plan, AIPlan, Recipes, Grocery,
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
- **Pro**: HearthKit's `HearthPurchases` (configured in `AppModel.configurePurchases`), the
  app's only RevenueCat setup: the shared Hearth sign-in's user id (the Supabase user id) as the
  app user id, entitlement "BigTable Pro" or `hearth_plus`, and the household organizer's plan
  from `/v1/me/entitlements`. Screens gate on `AppModel.hasPro`. RevenueCat's webhook keeps the
  server's tier current, and the server's usage and tier still set the AI limits. Free accounts
  get three web imports a month (`WebImportAllowance`, counted on the device).
- **On the device**: Dine Out searches Apple Maps (MapKit). Recipes from a link are read on the
  phone (schema.org recipe data, including prep and cook times, or the page's text through
  Apple's on-device model). What you say is heard on the phone (on-device speech recognition), but
  recipes written from a description and changes made by talking go to Claude through the API
  (`recipe-transcript`, `recipe-refine`): the on-device model only used the ingredients named. Ask BigTable answers and acts with on-device tools. AI grocery lists (Pro) add up the
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

## Hearth

BigTable is one of the Hearth apps. They share data on the device through the app group
`group.com.stephenwarren.hearth`, using `Services/Hearth/HearthShared.swift` (synced from
`~/Developer/hearthkit`; edit it there, not here). Each app writes only its own files.

- **Shares the meal plan** (`bigtable.meal-plan.json`): each day's breakfast, lunch and dinner
  from yesterday through three weeks ahead, with titles, recipe ids, photos, Dine Out places,
  who isn't eating and a link back into BigTable. Meals from yesterday through three days ahead
  also carry their recipes (servings and ingredients) so Sated can estimate nutrition. Those
  load in the background after the plan is shared, four at a time, and are kept in memory so
  edits don't fetch them again (`HearthPublisher`, `HearthRecipeCache`).
- **Shares the household** (`bigtable.family.json`): its name, people with birthdays, likes
  and dislikes, dietary restrictions, who "me" is (the member linked to the signed-in account,
  or the organizer's own row), and people's photos. Photos download in the background after
  the household is shared, are scaled to 512 px JPEGs in the shared `photos/` folder
  (`bigtable-<member id>.jpg`), and the household is shared again with them. Each photo's
  source URL is remembered, so unchanged photos aren't downloaded again; photos no longer used
  are deleted (`HearthPublisher`, `HearthPhotoDownloader`).
- **Borrows photos**: a household member with no photo in BigTable shows the photo another
  Hearth app has of someone with the same name (`MemberAvatar(hearthName:)`, in the face
  piles, who's-eating faces, household rows and the profile button). Decoded images are cached
  by name and dropped only when another app's family or photos change (`HearthPhotoCache`).
- **Reads Caloma's family**: while setting up or editing the household, the organizer is
  offered "Add your family from Caloma?" for anyone Caloma knows who isn't in the household yet.
  It adds names only (their Caloma photos show through the borrowed-photo fallback until a
  photo is added in BigTable); "Not now" isn't offered again for those people.
- **One sign-in** (`AuthClient`, `HearthAccounts`): BigTable, Suffice and Sated use the same
  Supabase project, and share the session in the Keychain under the app group.
  - At launch BigTable adopts the shared session when it has none (or its own is for a
    different person: the latest sign-in on the device wins), then loads the user's name.
    With its own session and none shared, it shares its own. For the same person, the session
    with the later expiry wins.
  - Before refreshing, it re-reads the shared session: if another app already refreshed it,
    BigTable uses that and skips its refresh while the token is good for another minute. A
    rejected refresh token also checks there before signing out.
  - Every sign-in and refresh is shared (never an anonymous session).
  - Signing out signs out of every Hearth app (`signOutEverywhere`); deleting the account
    does too. On `Hearth.didChange` and when the app becomes active, BigTable follows the
    shared sign-in: signed out elsewhere (only once it has seen its session shared) signs out
    here; a different person signs out and back in as them; newer tokens are picked up.
  - Sign in with Apple saves the Apple ID with the name and email Apple gave
    (`HearthAccounts.saveAppleID`). When Apple gives no name (it only does the first time)
    and the account has none, the name another Hearth app saved for the same Apple ID is used.
- Signing out removes BigTable's files and photos. Nothing is shared or read in screenshot
  mode.

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
