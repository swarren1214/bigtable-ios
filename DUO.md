# BigTable on iPhone Duo

What changed for iPhone Duo, how each pose behaves, how to test it, and what's left. Nothing is
committed; review with `git diff` (and the new files below). Nothing was compiled: no Xcode was
reachable, so every file was only syntax-checked.

## What changed

New files:
- `BigTable/Features/Cook/CookSession.swift`: the recipe being cooked (one for the app):
  the step, the amounts chosen on the recipe page, and the kitchen timer (runs from an end date,
  pause, +1 minute, stop; a local notification when it's done, with only the recipe title and
  the timer's label). Also `RecipeAmounts`, the ingredient scaling the recipe page used, moved
  here so Cook Mode shows the same amounts.
- `BigTable/Features/Cook/CookModeView.swift`: Cook Mode (`CookModeView` full screen,
  `CookModeContent` in place) built on `HearthFoldOverlay`, and the Across the Kitchen board
  (`CookGlanceBoard`, a `HearthGlanceBoard`).
- `BigTable/Features/Plan/PlanWeekWide.swift`: the Open wide pieces: `PlanRecipeShelf`
  (recipes with search, All/Mine/Favorites and quick filters above them, draggable),
  `PlanNightsCard` (the week's dinners, with drop targets on empty nights) and
  `GroceryWeekPane` (the week beside the grocery list).

Changed files:
- `App/BigTableApp.swift`: `.hearthDuoPose()` once on the scene root (`AppRoot`), outside the tab view.
- `App/RootTabView.swift`: Ask BigTable and Notifications are `Label`s (title + symbol).
- `Features/Recipes/RecipeDetailView.swift`: the page is split into "what you need" and
  "what to do"; ingredients go in two columns when the card is 520 pt or wider; Start Cooking
  (opens Cook Mode full screen, or "Back to Cooking"); Book shows a two-page spread; Laptop
  turns the page into Cook Mode; the servings stepper and amount style follow into Cook Mode;
  toolbar buttons for Across the Kitchen and Cook Mode / Whole Recipe while cooking.
- `Features/Plan/PlanView.swift`: Open wide shows the recipe shelf beside the week (the
  existing plan column plus the Dinners card); drag a recipe onto an empty night to plan it as
  dinner; Add Meal on the toolbar in Open wide; Plan with AI is a `Label`. The body was split
  into `layout` and `planSections` with no change in other poses.
- `Features/Grocery/GroceryView.swift`: checked items sink to the bottom of their aisle; an
  Add Item toolbar button (first, before the options menu) on any Duo pose; Open wide shows the
  week beside the list; the options menu label is a `Label`.
- `Features/Recipes/RecipeCard.swift` (`RecipeGrid`) and `Features/Community/PublicProfileView.swift`:
  grids use an even number of columns (`HearthEvenColumns`) measured from their own width.
- `Features/Pantry/PantryView.swift`, `Features/Plan/DineOutDetailView.swift`,
  `Features/Community/PublicProfileView.swift`: "…" menus have a title (`Label`).
- `Features/Pantry/PantryCheckView.swift`: Skip has a symbol (`forward`).

## How each pose behaves now

- **Closed (outer display), "In the aisle"**: the standard tab bar and toolbars move to the
  rail by themselves (Plan, Recipes, Grocery, Community, Search). On Grocery, Add Item is the
  first toolbar action, before the options menu, the bell and the profile. Tapping an item
  checks it off and it sinks to the bottom of its aisle (this is now true in every pose).
- **Open tall (inner portrait), "The whole recipe"**: a recipe is one page: photo and details,
  the servings stepper (rescales every amount), ingredients in two columns when there's room,
  then Start Cooking and the steps.
- **Open wide (inner landscape), "Plan the week"**: Plan shows recipes on the leading pane
  (search and filters above the list) and the week on the trailing pane. Drag a recipe onto an
  empty night (today or later): the night shows a dashed drop target while you hover, and the
  recipe is planned as that night's dinner (entree). Long-press a recipe for "Add to … Dinner"
  without dragging. Plan with AI and Add Meal are on the toolbar (rail). Grocery shows the
  week's dinners beside the list.
- **Book (partly folded, held), "Cookbook spread"**: a recipe is two equal pages
  (`HearthFoldSplit`): photo, details, servings and ingredients on the left; Start Cooking,
  steps and attribution on the right. Each page scrolls on its own.
- **Laptop (partly folded, set down), "Cook Mode"** (signature): an open recipe becomes Cook
  Mode. The step (big), "Step n of m" and the next step read on the upright half; the flat half
  holds this step's ingredients, its timer (start / pause / +1 min / stop) and big Back and
  Next buttons (`HearthFoldOverlay`). Done Cooking on the last step ends it. The screen stays
  awake. "Whole Recipe" on the toolbar shows the full page; "Cook Mode" goes back. If another
  recipe is already cooking, its step and timer are kept and Start Cooking switches.
- **Tent, "Across the Kitchen"**: from Cook Mode's toolbar (or the recipe's toolbar while it's
  cooking), Across the Kitchen opens a full-screen board in the app's color: the timer huge (or
  "Step n of m" when no timer runs), the step and the next step under it. Its toolbar has
  Pause (or Start Timer), Next Step and Back. It's the same `CookSession`, so advancing here
  advances Cook Mode.
- Folding, opening and closing never lose the step, the amounts or a running timer: they live
  in `CookSession.shared`, above every pose-specific view.

## How to test in the iPhone Duo simulator

1. Run on the iPhone Duo simulator (iOS 27.1). Use the simulator's Device › Posture menu (or
   the hinge control) for Closed, Open, Book, Laptop.
2. Closed: Grocery tab. Check the rail shows the tabs and Add Item first. Check items off and
   see them move to the bottom of their aisle.
3. Open, portrait: open a recipe with 8+ ingredients. Ingredients should be two columns. Turn
   on Scale ingredients and change servings.
4. Open, landscape: Plan tab. Recipes left, week right. Drag a recipe onto an empty night
   today or later; the night highlights, then shows the recipe. Try a past night (no target).
   Grocery tab shows the week beside the list.
5. Book: open a recipe. Two equal pages, nothing under the fold.
6. Laptop: with the recipe open, set it to Laptop. Cook Mode appears. Start a step's timer,
   tap Next, fold to Closed and back: same step, timer still running. Tap Across the Kitchen;
   tap Next Step there, close the board: Cook Mode is on the same step.
7. Also run an iPhone 17 and an iPad: everything should look as before, except Start Cooking
   on recipes, checked items sinking, the even-column recipe grid and two ingredient columns on
   iPad.

## Skipped, and why

- **Timers in the Dynamic Island / Live Activity**: needs a widget extension target with an
  ActivityKit Live Activity, a new subsystem. The timer keeps time from an end date and a
  notification fires when it's done, even with the phone closed.
- **"Next step" by voice**: no always-listening voice command. Next Step has Voice Control
  input labels ("Next Step", "Next"). A real hands-free command would need an App Intent
  (Siri) or the on-device speech code from Ask; left for a decision.
- **Per-step ingredients**: recipes don't link ingredients to steps. Cook Mode shows the
  ingredients whose names appear in the step's text (simple word match), so it can miss some
  ("the sauce") or show none.
- **Rail placement details** ("the left page keeps a horizontal bar; the detail page gets the
  rail", Plan actions on the trailing rail): that's the system's job with standard toolbars;
  nothing custom was added. Check it in the simulator.
- **Describe the Week**: the app's equivalent is Plan with AI (prompt-based); it's on the rail.
- **List → detail split on iPad (Recipes, Community)**: these push a detail; turning them into
  `NavigationSplitView` would restructure navigation and the tour/screenshot paths. Not done.
- **Bottom buttons in sheets** (Snacks, Dine Out, Plan with AI, Preview, Receipt Put Away, the
  recipe editor's AI button): kept. They are full-width primary actions in sheets, not bars.
- **`DeviceName` (Theme.swift)** still uses `userInterfaceIdiom`, only for the words "iPhone"
  or "iPad" in text, not for layout. Kept.

## Decisions for Steve

- Checked grocery items now sink to the bottom of their aisle on every device, not only Duo.
- Grocery's Add Item toolbar button shows on any Duo pose (not on other iPhones/iPad, where
  the add row is enough). It focuses the add row; if the row is scrolled off, check it scrolls.
- Dropping a recipe on a night adds it to **dinner** as the **entree**, and won't replace a
  Dine Out night (it shows a message instead). The Dinners card only targets dinners.
- Start Cooking is on every recipe with steps, in every pose (a Glass button, text color).
- The ingredient two-column threshold is a card width of 520 pt.
- Laptop turns an open recipe into Cook Mode automatically (the design says so). If that
  surprises people reading on a desk, make it opt-in.
- Cook Mode's timer is separate from the Apple Watch's timer (they don't sync).

## Review (overnight)

A second pass, also without Xcode. Every symbol the new code uses was checked against the
codebase (names, labels, types, access). The syntax check passes on all 14 changed files.

### Checked and fine
- `page<Content>` helper, the two-column ingredient loop (`ForEach(slice, id: \.element.id) { index, ingredient in }`,
  the same tuple pattern the old code used), `.draggable(recipe.id)` (the id is a `String`, which is
  `Transferable`), `.dropDestination(for: String.self) { items, location in Bool } isTargeted:`,
  `HearthGlanceBoard`'s actions (`ToolbarItemGroup` with `if`/`else` inside), `.accessibilityInputLabels([Text])`,
  `Duration.formatted(.time(pattern: .minuteSecond / .hourMinuteSecond))`.
- Concurrency: `CookSession` is `@MainActor @Observable` (the project's default isolation is
  MainActor anyway). `RecipeAmounts` is `nonisolated` and only calls `nonisolated` helpers
  (`Ingredients`), which is right for a pure function. No `Timer`; the clock is a `TimelineView`.
  The notification code matches the watch's `CookTimer`.
- Ingredient scaling: `RecipeAmounts.parts` is the old `ingredientParts` body unchanged, so the
  recipe page shows the same amounts.
- Notification text: title "<timer label> is done", body the recipe title. Nothing about the household.
- No banned APIs; no `UIScreen`/idiom layout (only `DeviceName`, text only).

### Fixed
- `RecipeDetailView.swift:122–142`: two `.fullScreenCover`s on one view (only one presents
  reliably). Now one `.fullScreenCover(item:)` with `RecipeCookCover` (`.cookMode` / `.board`).
- `RecipeDetailView.swift:202` + `CookModeView.swift:40,59,75`: in Laptop the board was presented
  by the in-page Cook Mode, so unfolding or closing the phone removed that view and dismissed the
  board. Now the recipe page presents it (`CookModeContent(presentsBoard: false)`); full-screen
  Cook Mode still presents its own. This also replaces `$cook.showsBoard`.
- `RecipeDetailView.swift:86,141,710`: Laptop started Cook Mode for any recipe page still in
  memory (under another tab, or under a pushed screen). It now only starts for the page that's showing.
- `BigTableApp.swift:58`: tapping the timer's notification opened the Notifications sheet (the
  delegate does that for every notification). The cook timer's notification now just opens the app.
- `CookSession.swift:148,189`: the static `timerLabel(for:number:)` had the same name as the
  `timerLabel` property; renamed `timerName(for:number:)` to avoid any lookup confusion.
- `CookSession.swift:206`: a step under a minute ("rest 30 seconds") made a "Start  Timer" button
  with no time; seconds are now allowed in the short duration.

### Remaining risks
- `PlanWeekWide.swift:216`: `.dropDestination(for:action:isTargeted:)` may be deprecated in the
  iOS 26 SDK (a warning, not an error).
- `GroceryView.swift:383`: Add Item focuses the add row's text field. In a `List`, if that row is
  scrolled away it may not exist, so focus can do nothing. Check on the outer display.
- `PlanView.swift:38`: in Open wide the plan's `.refreshable` also covers the recipe shelf, so
  pulling the shelf syncs the kitchen and reloads the plan (recipes follow through
  `KitchenStore.revision`). Fine, but not a shelf-specific reload.
- The board and Cook Mode both toggle `isIdleTimerDisabled` on appear/disappear; the order when
  the board closes is put right by `onChange(of: showsBoard)`, but check the screen stays awake.

### For Steve
- Laptop auto-starts Cook Mode only when the recipe page is showing; returning to a page after
  Done Cooking doesn't restart it until the pose changes or the recipe reloads. OK?
- Tapping the timer's notification opens the app where it was; should it open Cook Mode?
