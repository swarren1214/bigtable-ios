# Porting guide: Expo BigTable → native BigTable

The native app (`/mnt/user-data/outputs/bigtable-ios`) is a SwiftUI (iOS 26, Liquid Glass) client of
the **same backend** as the Expo app: the Next.js API on Vercel plus Supabase auth and storage.
Feature parity means every screen and behavior of the Expo app, rebuilt in the conventions of
Steve's other native apps (Caloma, Suffice, Sated, Hearken).

The Expo source is read-only at `/mnt/user-data/uploads/Developer/bigtable/apps/mobile/` (App.tsx is
9,000 lines and holds most of the behavior; `components/**` holds the screens) and the API at
`/mnt/user-data/uploads/Developer/bigtable/apps/api/` (routes under `app/api/**/route.ts`). A few
deeply nested API routes are not staged; their contracts are already in `BigTableAPI.swift`.

**Nothing can be compiled in this environment.** Write carefully, and re-read your own files for
compile errors before you finish.

## Build settings that bite

- Swift 5 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency.
  Everything is on the main actor unless marked `nonisolated`. Views, stores and helpers can stay
  main-actor. Pure value types that cross into `BigTableAPI` (a `nonisolated` struct) must be
  `nonisolated` + `Sendable` (all the API models already are).
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`: **every file imports what it uses**
  (`SwiftUI`, `UIKit` for `UIImage`/`Color(.systemGray3)`-style UIKit colors, `Foundation`,
  `PhotosUI`, `MapKit`, `CoreLocation`, `AVFoundation`, `Speech`, `RevenueCat`…).
- Regex literals: use `#/…/#` (bare `/…/` isn't enabled in Swift 5 mode).
- No SwiftData, no Core Data. State lives in `@Observable` stores; data comes from the API.

## What already exists (don't rewrite; use it)

- `App/AppModel.swift`: `AppModel.shared` (also in the environment as `@Environment(AppModel.self)`).
  `session`, `me` (`MeResponse`), `members`, `householdName`, `membership`, `isOrganizer`,
  `permissions`, `canManagePlan`, `canUseAIPlan`, `canUseAIGrocery`, `canEditMembers`, `usage`
  (`UsageCheckResponse`), `reload()`, `refreshUsage()`, `updateUsage(_:)`, `saveHousehold(_:)`,
  `markTutorialComplete()`, `signOut()`, `deleteAccount()`, `unreadCount`, `setUnreadCount(_:)`,
  `refreshUnreadCount()`, `faces` (members as `Face`s with colors), `color(forMember:)`.
- `App/BigTableApp.swift`: `AppRouter` (`@Environment(AppRouter.self)`): `tab`, `weekStart`
  (the Plan tab's Sunday, "YYYY-MM-DD"), `present(_ sheet: AppSheet)` with `.paywall`,
  `.profile`, `.notifications`, `.newRecipe`, `.aiPlan`, `.recipe(id:versionID:)`,
  `.publicProfile(id:)`. `AppRoot` shows `AuthView` / `HouseholdSetupView` / `RootTabView`.
- `App/RootTabView.swift`: the tabs, and `.bigTableToolbar()` (bell + profile avatar). **Every tab's
  root screen calls `.bigTableToolbar()`.**
- `Services/API/BigTableAPI.swift`: `BigTableAPI.shared`, one method per endpoint (read it). Errors
  are `APIError` (`kind`, `status`, `code`, `message`, `isLimitReached`, `isForbidden`,
  `localizedDescription`). When an AI call fails with `isLimitReached` or a Pro-only 403, present
  `.paywall`.
- `Services/API/StorageClient.swift`: `uploadMemberPhoto(_:memberKey:)`, `uploadRecipePhoto(_:mimeType:)`
  → public URL string.
- `Services/Auth/AuthClient.swift`: `AuthClient.shared` (actor): `signIn`, `signUp`
  (returns false when email confirmation is needed), `signInWithApple(idToken:nonce:fullName:)`,
  `sendPasswordReset`, `updatePassword`, `updateFullName`, `signOut`.
- `Services/Hearth/HearthPurchases.swift` (HearthKit copy): `HearthPurchases.shared`
  (RevenueCat): `isUnlocked`, `hasHearthPlus`, `membership`, `billingIssueUntil`. Screens use
  `AppModel.hasPro` (that, or the server's tier). The *server's* usage (`AppModel.usage`) still
  sets the AI limits.
- `Models/API/APIModels.swift`: every API shape (`PlannerResponse`, `PlannerSlot`, `PlanSlotUpdate`,
  `RecipeSummary`, `RecipeDetail`, `RecipePayload`, `MeResponse`, `HouseholdMember`,
  `GrocerySnapshot`, `NotificationRecord`, `FollowProfile`, `UsageCheckResponse`, `MealPlanRequest`,
  `GroceryListRequest`, `PlaceResult`…) and `ISODay` (local "YYYY-MM-DD" helpers, `weekStart`,
  `timestamp`).
- `Models/Ingredients.swift`: measurement options, `parseAmount`, `formatAmount`, `displayAmount`,
  `parseLine` (a typed/imported line → `RecipeIngredientInput`), `line`, `plainLine`, `shortLabel`.
- Design system (`DesignSystem/`): `BigTableScreen(title:)` (scrolling large-title screen on grouped
  gray), `Card`, `CardList`, `SectionTitle`, `IconTile`, `MemberAvatar(name:color:url:photo:size:)`,
  `FacePile(faces:skipped:)`, `Chip`, `TagLabel`, `RoundCheck`, `RecipePhoto(url:data:)`,
  `EmptyCard`, `LinkCard`, `LoadingCard`, `RetryCard`, `ProBadge`, `UpgradeCard`, `FlowLayout`,
  `.errorAlert($message)`, `PhotoTools.jpeg/load`, `CameraPicker`, `relativeTime(_:)`,
  `OnboardingPage` (+ `OnboardingPrimaryButton`, `OnboardingSymbolIcon`, `OnboardingFeatureRow`,
  `AppIconBadge`), colors: `Brand`, `PersonColor.forIndex/forKey`, `MealSlotType.color`,
  `PlannerMealRole.color`, `SnackStyle`, `GroceryAisleStyle.color/symbol`, `@Environment(\.accent)`,
  `SettingsKey`, `durationText(minutes:)`, `Fraction.format`.

## Conventions (match Caloma)

- Large titles, grouped-gray background, white 22 pt cards, tinted icon tiles, capsule chips,
  system Liquid Glass (`.buttonStyle(.glassProminent)`, `.glassEffect`), SF Symbols (never emoji).
- Sheets are `NavigationStack`s with an inline title, a Cancel/Close (`systemImage: "xmark"`) and a
  confirm (`systemImage: "checkmark"`) toolbar button.
- Plain, warm copy in sentence case; no exclamation marks except celebrations.
- Doc comments on every type say what it is for the person using the app.
- Loading: show `LoadingCard` or `ProgressView`; failures: `RetryCard` or `.errorAlert`.
- iPad: keep content to a readable column (`BigTableScreen` does it), grids adapt.
- Accessibility labels on icon-only buttons; 44 pt targets.

## Ownership (each agent writes ONLY in its own folders)

| Agent | Folders | Views other code already calls (exact signatures) |
|---|---|---|
| Account | `Features/Account/`, `Features/Profile/`, `Features/Tutorial/` | `AuthView()`, `NewPasswordView()`, `HouseholdSetupView()`, `ProfileView()`, `TutorialView(onFinish: @escaping () -> Void)` |
| Plan | `Features/Plan/`, `Features/AIPlan/` | `PlanView()`, `AIPlanView()` |
| Recipes | `Features/Recipes/` | `RecipesView()`, `RecipeSearchView()`, `RecipeDetailView(recipeID: String, versionID: String?)`, `RecipeEditorView(mode: RecipeEditorMode)` with `enum RecipeEditorMode { case create; case edit(RecipeDetail) }`, `DeletedRecipesView()`, `ManageTagsView()`, `RecipePickerView(onPick: (RecipeSummary) -> Void)` |
| Grocery & Community | `Features/Grocery/`, `Features/Community/`, `Features/Notifications/` | `GroceryView()`, `CommunityView()`, `PublicProfileView(profileID: String)`, `NotificationsView()` |

Cross-feature calls go only through those signatures (or `router.present`). Name private helper types
with a feature prefix (`PlanSlotCard`, `GroceryItemRow`…) so nothing collides across agents. If you
need something changed in a shared file, don't edit it: describe the change in your final report.
