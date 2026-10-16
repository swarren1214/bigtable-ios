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

## Shared Hearth code

`Services/Hearth/HearthShared.swift`, `Services/Hearth/HearthApps.swift` and
`Assets.xcassets/Hearth` are copies. Edit the originals in `~/Developer/hearthkit` and run its
`sync.sh`.
