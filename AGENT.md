# AGENT.md — BigTable

Rules for anyone (person or agent) changing BigTable's code. See README.md for how the app is
built and what each screen does.

## Design for every device

Always make sure layouts and designs work well on every device type BigTable runs on: every
iPhone size (small, standard, Max, and foldables such as an iPhone Duo or Fold), iPad in full
screen and in Split View, Slide Over and Stage Manager windows, and portrait and landscape.

- Lay out from the space available (size classes, `ViewThatFits`, adaptive grids), not from a
  device name or a fixed screen width.
- Check the smallest iPhone, the largest iPhone, an unfolded or split screen, and iPad before
  calling a screen done. Larger Dynamic Type sizes must not clip or overlap.

## Liquid Glass menus with icons

- Every menu item's icon must be the same **color** as its text: label-colored text gets a
  label-colored icon, and a destructive item's red text gets a red icon. Menus tint icons with
  the app's accent (set at the root) while the titles stay in the text color, so don't use
  `systemImage:` in menus. Use the helpers in `DesignSystem/MenuIcon.swift` instead:
  `Button("Rename", menuIcon: "pencil") { … }`, `Menu("Sort", menuIcon: …) { … }`,
  `Toggle("…", menuIcon: …, isOn: …)`, or `Label { Text("…") } icon: { Image.menuIcon("…") }`
  (pass `role: .destructive` for red). The only exception is a color swatch in a color picker.
- When a menu item is a checkmark selection (picking one option, or toggling options on and off),
  the checkmark goes on the **right** side of the item. iOS 26's native menus draw selection
  checkmarks on the left (a `Picker` or `Toggle` inside a `Menu`, or a `checkmark` symbol in the
  item's label, which takes the icon's place), so selection menus use the app's right-checkmark
  menu component instead — this is the one place a custom control beats the native one.
  This app doesn't have one yet; don't fake it with a `checkmark` label.

## Sheet buttons

- A sheet with both Done and Cancel at the top (Save, Add and Create count as Done) uses
  `SheetDoneButton` and `SheetCancelButton` from `DesignSystem/SheetButtons.swift`:
  - **Done** is a circular checkmark button filled with the app's color, with a white icon.
  - **Cancel** is a circular X button with no colored background, its icon in the text color
    (black in Light Mode, white in Dark Mode).
  Put them in `.confirmationAction` and `.cancellationAction`:
  `ToolbarItem(placement: .confirmationAction) { SheetDoneButton("Save") { save() } }`.
  Keep the title (it's read by VoiceOver); only the icon shows.

## iPad sidebar

- When the tab bar opens into the left sidebar on iPad (`.sidebarAdaptable`), every tab's icon
  is the same color as its name: black in Light Mode, white in Dark Mode, never the app's tint.
  The sidebar tints icons with the app's color, so on iPad (regular width) build each tab's
  label as `Label { Text(title) } icon: { Image.menuIcon(symbol) }` (from
  `DesignSystem/MenuIcon.swift`). The iPhone tab bar keeps plain symbols, so the selected tab
  still shows in the app's color.

## Prefer native

Prefer native iOS capabilities and components over custom ones: system controls, `List`/`Form`,
`Menu`, `Picker`, sheets, toolbars, search, `ShareLink`, SF Symbols, system colors and Dynamic
Type, and Apple frameworks over hand-built versions. Build something custom only when nothing
native does the job, and match the system's look and behavior when you do.

## Sync

BigTable is the exception to the Hearth apps' iCloud rule: the household, recipes, plans,
grocery lists and Community live on BigTable's server (the Hearth API and Supabase), so everyone
in a household sees the same data and the older Expo app keeps working. Don't move them to iCloud.

- A change on one device reaches every device signed in to the account, and everyone in the
  household, without the user doing anything (push notifications or realtime updates from the
  server, plus a refresh when the app returns to the foreground).
- Every screen that shows server data supports pull to refresh (`.refreshable`), which fetches
  the latest from the server before it finishes.

## Confirmations

When an action needs confirming (deleting, erasing, signing out, leaving), always use a native
alert (`.alert` with a `role: .destructive` button and a Cancel button) rather than a native
popup or popover (`.confirmationDialog`, action sheet, `.popover`), unless explicitly told
otherwise.

## Hearth household

The family (people, photos, birthdays, allergies, diets, likes and dislikes) is the **Hearth
household**: one record set in the family's iCloud (container `iCloud.com.stephenwarren.hearth`,
zone `Household`), shared with the family by a CKShare. `HearthHouseholdStore.shared` reads and
edits it, and every Hearth app on the device sees changes at once through the app group.
`HearthHouseholdView`, `HearthPersonView`, `HearthPersonEditor` and `HearthInviteSheet` are the
screens for it; don't build app-specific versions.

- **Privacy rules (never break these):**
  - Family profiles never go to a Hearth server. The server may hold membership (who's in a
    household, a seat id and a name where a feature needs one), nothing more.
  - Birthdays, allergies, diets, likes, dislikes and household restrictions are stored in
    CloudKit `encryptedValues`. A new sensitive field goes there too.
  - An AI request gets only `store.aiContext()` (`HearthAIContext`): ages, roles and food rules,
    no names, no photos, no birthdays, for that one request. Nothing is logged or saved.
  - Never put household data in analytics, logs (`privacy: .public`), crash reports or
    notifications' text beyond a first name.
- **Allergies are hard rules.** Anything that suggests food must never suggest one.
- **There is always a household** (a household of one is fine). New people get HearthKit's
  `HearthHouseholdOnboarding` step in onboarding; the root has
  `.hearthHouseholdRequired(isActive:accent:)` so nobody uses the app without one. Never build
  an app-specific person editor or a no-household fallback.
- **One invite for everything.** An app that shares its own data does it as an app zone in the
  Hearth container (`HearthZoneParticipant` + `HearthAppSharing`), shared automatically with the
  household. Never create another CKShare or invitation flow.
- **One entry, named "Household"** (`HearthHouseholdLabel.title`, symbol
  `HearthHouseholdLabel.symbol`), at the top of Settings or Profile, opening
  `HearthHouseholdView`. App-specific details about a person go on their page through
  `.environment(\.hearthPersonExtras)`, not on a separate screen.
- **The app's own people mirror the household.** Keep the app's model (Caloma's `Member`, etc.)
  and link it by Hearth id: `store.localID(of:app:among:)` to find a person's record here,
  `store.linkHere(_:app:localID:)` to link one (shared link when the app's data is the family's,
  per-device link otherwise), `store.member(app:appID:)` to go back. Only add people when
  `store.canEditEveryone`, so two phones don't both create one.
- **Edits go through the household.** For a linked person, edit with `HearthPersonEditor`; the
  mirror copies the change into the app.
- Invitations: the root view has `.hearthHouseholdInvitations()`, and the scene delegate hands
  CKShare metadata for the Hearth container to `HearthHouseholdStore.shared.receive` (see
  `HearthHouseholdStore.handles`).
- **In BigTable:** people come from the Hearth household (`AppModel.faces`, `householdSize`; a meal's "not eating" holds first names). Profile › Household opens the shared screens; the first run is `KitchenSetupView`.

## The kitchen (iCloud)

BigTable's private data lives in the family's iCloud, not on the server: recipes the family
wrote, tags, the meal plan and grocery lists (`Services/Kitchen/`).

- `KitchenStore` keeps it (a JSON copy on the device, CloudKit records in the `Kitchen` zone of
  `iCloud.com.stephenwarren.hearth`, content in `encryptedValues`, photos as `CKAsset`s in the
  app group's `kitchen-photos`). It syncs on the household's engines as a
  `HearthZoneParticipant`; never start another CKSyncEngine for it.
- Screens call `KitchenStore.shared.recipes/recipe/createRecipe/updateRecipe/currentPlan/
  updateSlot/grocerySnapshots/...` (same shapes as the old API calls). Published and community
  recipes, likes, favorites of published recipes, follows, notifications and AI go to the
  server through `BigTableAPI`.
- **Publishing copies a recipe to the server under the same id** (`PUT /recipes/:id/publication`,
  uploading its photo then). Nothing private goes to the server otherwise. The only personal
  detail the server gets is the first name shown on published recipes.
- AI routes save nothing: meal plans send `myRecipes` (and get `recipeLookup` back), grocery
  lists send `plannedMeals`; the app writes results into the kitchen.
- `KitchenSharing`: the household owner's BigTable shares the kitchen with the household's
  parents and adults and stores the share link and a server join code in the household
  (encrypted); everyone else's BigTable accepts the kitchen and redeems the code (shared
  subscription). Kids aren't added.
- `KitchenMove`: the one-time copy from the server (`/me/kitchen-export`), then
  `/me/kitchen-moved`; the server purges its copy 30 days later.

## Shared Hearth code

These are copies: in `Services/Hearth/`, `HearthShared.swift`, `HearthApps.swift`,
`HearthSync.swift`, `HearthPicker.swift`, `HearthIconLibrary.swift`, `HearthAccount.swift` and the
four `HearthHousehold*.swift` files, plus `Assets.xcassets/Hearth`. Edit the originals in
`~/Developer/hearthkit` and run `bash sync.sh` there; never edit a copy. App-specific Hearth code
(such as `HearthLink.swift`) also lives in `Services/Hearth/` and isn't touched by the sync.
