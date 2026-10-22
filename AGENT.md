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

## iPhone Duo

The shared Duo layer is `Services/Hearth/HearthDuo.swift` (canonical copy in ~/Developer/hearthkit).
Design: the "Hearth on iPhone Duo" canvas. This app's Duo features are described in `DUO.md`.

- One layout that grows with the space: compact on the outer display, regular inside. A pose gets
  its own mode only where the way people hold the device changes the job.
- `.hearthDuoPose()` sits on the scene root, and on the root of any `.fullScreenCover` whose content
  reads `\.hearthDuoPose` (a cover takes the presenter out of the window).
- Use standard toolbars and tab views so the system moves bars to the trailing rail. Every toolbar
  item that isn't text-only is a `Label` with a title and a symbol; Back/Close first
  (`.cancellationAction`), then the prominent action. Controls for a leading pane stay above it.
- Nothing in the fold: two related views go in `HearthFoldSplit` (or a NavigationSplitView); "read up
  top, tap below" screens use `HearthFoldOverlay`; grids use an even number of columns
  (`HearthEvenColumns`). Never put an arrangement inside a List, ScrollView or split view.
- No layout from `UIScreen` bounds, `userInterfaceIdiom` or fixed phone widths: use size classes and
  the container's size.
- Same functions in every pose, and state follows the hand: keep state above pose-specific views so
  opening, closing or folding never loses it.
- Tent boards (`HearthGlanceBoard`) open from a toolbar button; the system can't detect Tent.
- Duo APIs need iOS 27.1 and Xcode 27.1; HearthDuo wraps them in `#available` with iOS 26 fallbacks.

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

## App color

The app's color (its accent, which the root `.tint` passes to everything below it) is for things
large or bold enough to stay legible in it. It's never for menus or running text.

- **The app's color is fine for:**
  - Large titles and big numbers (`.largeTitle`, `.title` and up, a hero figure or a stat).
  - Icons that stand on their own: an icon tile with a white glyph, a large feature or empty-state
    symbol, the selected tab on the iPhone tab bar.
  - Components: toggles, sliders, steppers' fills, progress bars and rings, charts, selection
    highlights, the filled `SheetDoneButton`, and filled or prominent buttons with white text.
- **Never use the app's color for:**
  - Menus: a menu's button or label, its items, their icons and their checkmarks (see the menu
    rules above).
  - A menu-style `Picker`'s value (the "Stars ⌃⌄" beside a row's title).
  - Standard text: body, callout, subheadline, footnote and caption text, links, and buttons whose
    label is text, such as an action row in a `Form` or `List`.
  - Headers: section headers, list headers and small all-caps labels.
  - Small icons: a symbol beside a row's title, inside a `Label`, inline with text, or in a
    small toolbar or row button.
  These use the text color: `.primary` (black in Light Mode, white in Dark Mode), or `.secondary`
  for supporting text and small icons that aren't part of a button (see
  the next rule). A destructive action stays red.
- **A button's icon is always the same color as its text**, unless Steve explicitly asks for an
  exception. This covers every tappable thing with a label: `Button`, `Link`, `ShareLink`,
  `PhotosPicker`, a `Menu`'s label, and a tappable row (`NavigationLink` or `Button`) in a `List`
  or `Form`. Text in the text color gets an icon in the text color, a destructive button's text
  and icon are both red, and a filled button's text and icon are both white. Never color the icon
  on its own: no `.foregroundStyle` on just the `Image`, no `LabelStyle` that tints or greys the
  icon, and no row icon left to pick up the app's color from the root `.tint` while its title
  stays in the text color (put `.tint(.primary)` on the row or its `Section`). A filled icon tile
  (a white glyph on a colored square, as in the Settings app) is a component, not the button's
  icon, and is fine.
- **Approved exceptions** (Steve asked for these; keep them): the iCloud Sync card's Sync Now
  button (`HearthSyncCard` in HearthSync.swift) is a bordered capsule with a light wash of the
  app's color and its icon and text in the app's color.
- The root `.tint` leaks the app's color into every control that doesn't set its own color. So
  put `.tint(.primary)` on a `Menu`, a menu-style `Picker`, and a text `Button` in a `Form` or
  `List` row. Never use `.foregroundStyle` with the app's color (or `.tint`/`Color.accentColor`)
  on text or small symbols.
- Even where it's allowed, use the app's color only where it stays legible against what's behind
  it in both Light and Dark Mode. A dark accent on a dark background, a light accent on white, or
  the accent on an accent-tinted fill all fail. When in doubt, use the text color.

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
popup or popover (`.confirmationDialog`, action sheet, `.popover`, a custom card or sheet),
unless explicitly told otherwise.

- **Alert button colors:** every button in an alert uses the standard text color (black in
  Light Mode, white in Dark Mode), never the app's color. Only a destructive action's button
  is different: the standard red, from `role: .destructive`. The app sets this once at launch
  with `UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor =
  .label`; don't tint alert buttons yourself, and don't color a destructive button any other
  way than its role.

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
