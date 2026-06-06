# OvertimeUI

A single-file Roblox UI library for scripts loaded through the Overtime Executor (and any other executor with `loadstring` + `game:HttpGet` support).

Tabs, toggles, sliders, dropdowns, buttons, keybinds, color pickers, labels, paragraphs, toast notifications, and FOV-circle overlays — everything you need to build a clean cheat-menu-style interface in ~20 lines of config.

> **Scope:** this repository is the UI library only, and is MIT licensed. The Overtime Executor itself is closed source and is not distributed here.

## Quick start

```lua
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/overtimepog/OvertimeUI/main/OvertimeUI.lua"))()

local Window = UI:CreateWindow({
    Name   = "My Script",
    Accent = Color3.fromRGB(90, 180, 255),
})
if not Window then return end -- re-running toggles the window off; bail on nil

local Visuals = Window:CreateTab("Visuals")
local ESP = Visuals:CreateSection("ESP")

ESP:CreateToggle({
    Name         = "Enable ESP",
    CurrentValue = true,
    Callback     = function(v) print("ESP =", v) end,
})

ESP:CreateSlider({
    Name         = "Distance",
    Range        = { 0, 500 },
    Increment    = 10,
    CurrentValue = 200,
    Suffix       = " studs",
    Callback     = function(v) print("Distance =", v) end,
})

Window:OnClose(function()
    print("Window closed — script should do its cleanup here")
end)
```

**Pinning to a specific version** (recommended for production scripts):

```lua
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/overtimepog/OvertimeUI/v0.1.0/OvertimeUI.lua"))()
```

Loading from `main` always gives you the latest; loading from a tag like `v0.1.0` pins the code so a future breaking change won't silently break your script.

## Features

- **Tabs** on the left-side strip with per-tab scrolling bodies
- **Sections** as visual dividers within a tab
- **Toggles** (checkbox style) with `Get`/`Set`/`SetSilent` handles
- **Sliders** with range, increment, optional suffix, and integer or float display
- **Dropdowns** (single-select) with click-outside-to-close popups
- **Buttons** with optional two-stage "click to confirm" pattern
- **Keybinds** supporting keyboard, mouse 1/2/3, **and mouse 4/5** (most Roblox UI libraries cap out at LMB/RMB/MMB — see the note below)
- **Inline attached keybinds** Linoria-style: `:AddKeybind{...}` on a toggle puts the rebind button on the same row
- **Color pickers** with an HSV popup (saturation/value box + hue bar + hex readout)
- **FOV-circle overlays** anchored to the crosshair for aimbot visualization, rendered behind the menu so they never occlude controls
- **Labels** and **Paragraphs** for inline text / doc blocks
- **Toast notifications** with a shared stack, TweenService slide-in/out, and auto-dismiss
- **Self-contained lifecycle** — the library owns the ScreenGui and a `BoolValue` marker; re-running the script toggles the window off automatically
- **Per-window accent color override** (defaults to sky blue)
- **~1910 lines, single file, no external dependencies**

## API reference

### `UI:CreateWindow(config)`

Creates the top-level window. Returns a `Window` handle, or `nil` if an existing window with the same `Name` is already open (which means the script is being re-run to toggle off — the library destroys the old marker, the old instance self-cleans via its Destroying hook, and the second run returns `nil` so the script can bail).

| field | type | default | notes |
|---|---|---|---|
| `Name` | string | `"OvertimeUI"` | Used for the title bar text and the marker name |
| `SubTitle` | string | — | Small dimmed line under the title |
| `Accent` | `Color3` | sky blue | Per-window accent override |
| `Size` | `UDim2` | `(0, 520, 0, 360)` | Fixed panel size |
| `Position` | `UDim2` | centered | Starting position |
| `Theme` | table | — | **Color** overrides — any subset of theme keys (see below) |
| `Style` | table | — | **Structural** overrides — roundness / fonts / decorations (see below) |
| `Roundness` | number | `1` | Shorthand for `Style.roundness` |
| `Font` / `FontBold` / `FontSemi` | `Enum.Font` | Gotham family | Shorthand for the `Style` font fields |
| `Shadow` / `Sheen` / `Stripe` | boolean | `true` | Shorthand for the `Style` decoration flags |
| `Layout` | string | `"left"` | Shorthand for `Style.layout` — `"left"` sidebar or `"top"` tab bar |
| `TitleHeight` / `TitleAlign` / `TitleIcon` | — | — | Shorthand for the matching `Style` fields |
| `TabWidth` / `TabHeight` / `BodyPadding` / `Spacing` | number | — | Shorthand for the matching `Style` fields |
| `StrokeThickness` / `Animation` / `PanelTransparency` | number | — | Shorthand for the matching `Style` fields |
| `BackgroundImage` / `BackgroundImageTransparency` | — | — | Shorthand for the matching `Style` fields |
| `AccentGradient` | `ColorSequence` or `{Color3,...}` | — | Accent becomes a sweep on the stripe, tab indicators, and section ticks |

### Per-script visual style

Two override channels keep colour and structure independent, so every script can
look distinct without forking the library:

**`Theme`** — colour palette. Pass any subset; the rest fall back to the dark default.

| key | role |
|---|---|
| `bg` / `bgAlt` | panel base / sidebars + body |
| `surface` / `surfaceHi` | controls at rest / hover |
| `border` / `borderHi` | hairlines / focused edges |
| `accent` / `accentDim` / `accentGlow` | accent + muted fill + glow tint |
| `text` / `textDim` | primary / secondary text |
| `danger` | destructive / rebind-in-progress |

**`Style`** — structure (non-colour). Also settable via the top-level shorthand fields. Every token defaults to the original fixed look, so an existing script that passes nothing renders pixel-for-pixel as before.

| key | type | default | effect |
|---|---|---|---|
| `roundness` | number | `1` | Corner-radius multiplier (`0` = sharp, `2` = pill-y) |
| `font` / `fontBold` / `fontSemi` | `Enum.Font` | Gotham family | Body / title / label fonts |
| `shadow` | boolean | `true` | Soft drop behind the panel |
| `sheen` | boolean | `true` | Top-lit gradient on the panel |
| `stripe` | boolean | `true` | Accent stripe in the title bar |
| **`layout`** | string | `"left"` | **`"left"` sidebar tabs or `"top"` horizontal tab bar — the biggest single change in feel** |
| `titleHeight` | number | `36` | Title-bar height in px |
| `titleAlign` | string | `"left"` | `"left"` or `"center"` title text |
| `titleIcon` | string | — | `rbxassetid://…` logo shown by the title (replaces the accent stripe) |
| `tabWidth` | number | `120` | Sidebar width (`left` layout only) |
| `tabHeight` | number | `30` | Per-tab button height |
| `bodyPadding` | number | `12` | Inner padding of each tab page (density) |
| `spacing` | number | `2` | Vertical gap between control rows (density) |
| `strokeThickness` | number | `1` | Thickness of every hairline outline (`2`–`3` = framed look) |
| `animation` | number | `1` | Tween-duration multiplier (`0.5` snappier, `2` slower, `0` instant) |
| `sheenStrength` | number | `0.05` | How pronounced the panel sheen is |
| `shadowSpread` / `shadowTransparency` | number | `30` / `0.65` | Drop-shadow size / faintness |
| `panelTransparency` | number | `0` | `0` solid, `~0.1`–`0.3` glass / acrylic |
| `backgroundImage` | string | — | `rbxassetid://…` texture behind the panel body |
| `backgroundImageTransparency` | number | `0.85` | How subtle that texture is |
| **`gradientStroke`** | boolean | `false` | Key borders become a light-catching gradient (the modern depth trick) |
| **`accentGlow`** | boolean | `false` | Soft accent glow behind the panel + active toggles |
| **`gradientFill`** | boolean | `false` | Subtle top-lit fill gradient on surfaces |

The three **depth flags** are the single biggest "premium vs basic" lever. They default off (so the stock flat look is unchanged); turn them on — or use a preset that does — to lift the UI out of flatness. Also settable via the top-level shorthand `GradientStroke` / `AccentGlow` / `GradientFill`.

Plus the colour channel:

| key | type | effect |
|---|---|---|
| `AccentGradient` (top-level) or `Theme.accentGradient` | `ColorSequence` or `{Color3, Color3, …}` | Turns the accent into a colour sweep on the title stripe, tab indicators, and section ticks |

```lua
-- A sharp, flat, monospaced look — nothing like the rounded default.
local Window = UI:CreateWindow({
    Name      = "My Script",
    Accent    = Color3.fromRGB(235, 60, 120),
    Theme     = { bg = Color3.fromRGB(14, 14, 18), surface = Color3.fromRGB(28, 28, 34) },
    Roundness = 0,
    Font      = Enum.Font.Code,
    Shadow    = false,
    Sheen     = false,
})
```

### Making each script look unique

The defaults reproduce the stock look exactly, so the way to make a script's menu
*not* read as "generic OvertimeUI" is to lean on these tokens. Two recipes that
land in completely different places:

```lua
-- 1) Top tab-bar, pill-shaped, gradient accent, glassy panel, snappy motion.
local Window = UI:CreateWindow({
    Name           = "Aurora",
    SubTitle       = "build 7",
    TitleAlign     = "center",
    AccentGradient = { Color3.fromRGB(120, 90, 255), Color3.fromRGB(0, 200, 255) },
    Layout         = "top",
    Roundness      = 2,            -- pill-y
    PanelTransparency = 0.12,      -- acrylic
    Animation      = 0.6,          -- snappier
    Theme = { bg = Color3.fromRGB(18, 16, 28), bgAlt = Color3.fromRGB(24, 22, 36) },
})
```

```lua
-- 2) Dense, sharp, heavy-framed terminal look with a logo and no decorations.
local Window = UI:CreateWindow({
    Name        = "RootKit",
    TitleIcon   = "rbxassetid://0",   -- your logo asset
    Accent      = Color3.fromRGB(0, 255, 140),
    Roundness   = 0,                  -- hard corners
    Font        = Enum.Font.Code,
    StrokeThickness = 2,              -- chunky frames
    TabWidth    = 92,
    TabHeight   = 24,
    BodyPadding = 8,
    Spacing     = 1,                  -- tight
    Sheen       = false,
    Shadow      = false,
})
```

Each window resolves its own style independently — two differently-styled windows
can coexist and controls built into either after the fact stay on-style. See
[`examples/Showcase.lua`](examples/Showcase.lua) for several wildly different menus
built from the same library.

### Themes and presets

Rather than hand-rolling colours every time, start from a built-in palette or a
full preset.

**`UI.Themes`** — named colour palettes (`Dark`, `Midnight`, `Aqua`, `Rose`, `Mono`, `Forest`, `Amber`). Each is a partial `Theme` table you can drop straight into `CreateWindow`:

```lua
local Window = UI:CreateWindow({ Name = "My Script", Theme = UI.Themes.Aqua })
```

**`UI.Presets`** — finished **theme + structure + depth** bundles. Pass `Preset` and you get a distinct, premium look in one line; anything you pass alongside it overrides the preset (`Theme`/`Style` are deep-merged, everything else replaced):

```lua
local Window = UI:CreateWindow({ Preset = "Aurora", Name = "My Script" })
-- start from a preset, override just the accent:
local Window = UI:CreateWindow({ Preset = "Sleek", Name = "X", Accent = Color3.fromRGB(255, 90, 150) })
```

Shipped presets:

| preset | look |
|---|---|
| `Aurora` | frosted top tab-bar, gradient accent, glow — the modern "premium" look |
| `Sleek` | Rayfield-style lit sidebar: rounded, gradient framing, accent glow |
| `Terminal` | dense, sharp, monospaced, no glow |
| `Compact` | tight cheat-menu palette — pair with two-column groupboxes |
| `Velvet` | warm, roomy, languid |
| `Glass` | heavy translucent panel, big glow, gradients everywhere |

### `Window:CreateTab(name [, opts])`

Adds a tab to the strip. Returns a `Tab` handle. The first tab created becomes active automatically.

Pass an optional icon as `opts.Icon` (or a bare string): `Window:CreateTab("Combat", { Icon = "rbxassetid://123" })`. The icon sits left of the label and tints with the active/inactive state.

### `Window:OnClose(callback)`

Registers a callback that fires when the window is destroyed — whether via the `×` button, `Window:Destroy()`, or the marker being destroyed externally.

### `Window:Destroy()`

Tear down the window immediately. Fires any `OnClose` callbacks, disconnects internal listeners, destroys the ScreenGui, removes the marker.

### `Tab:CreateSection(name)`

Adds a section header + container inside the tab body. Returns a `Section` handle. Sections are visually separated by a small spacer and an uppercase accent-color header. This is the **single-column** layout.

### `Tab:CreateLeftGroupbox(name)` / `Tab:CreateRightGroupbox(name)`

The **two-column** "cheat menu" layout (Linoria-style). Each returns a `Section` handle — every `Section:CreateX` method works inside — rendered as a bordered, titled **card** stacked in the left or right column. The first groupbox call builds the two-column container; stack as many groupboxes per column as you like and they pack densely.

```lua
local combat = Window:CreateTab("Combat")
local aim = combat:CreateLeftGroupbox("Aimbot")
aim:CreateToggle({ Name = "Enabled", CurrentValue = true })
local esp = combat:CreateRightGroupbox("ESP")
esp:CreateToggle({ Name = "Boxes", CurrentValue = true })
```

> Pick **one** layout per tab: either `CreateSection` (single column) **or** groupboxes (two columns). Don't mix them in the same tab.

### `Section:CreateToggle(config)` → `Toggle` handle

| field | type | default |
|---|---|---|
| `Name` | string | `"Toggle"` |
| `CurrentValue` | boolean | `false` |
| `Callback` | `function(value)` | — |

Toggle handle methods:
- `:Get()` — current state (boolean)
- `:Set(value)` — set and fire callback
- `:SetSilent(value)` — set without firing callback
- `:AddKeybind(config)` — attach an inline keybind picker to the same row (see below)

### `Toggle:AddKeybind(config)` → the same `Toggle` handle, extended

Attaches a rebind button to the right side of the toggle row. Useful for pairing a hold-to-aim hotkey with its "Enable Aimbot" toggle. The toggle handle gains these methods (in addition to its existing `:Get`/`:Set`):

- `:GetKeybind()` — current key string
- `:SetKeybind(str)` — set and fire the keybind callback
- `:SetKeybindSilent(str)` — set without firing callback
- `:IsKeybindHeld()` — is the bound key currently down?

Calling `:AddKeybind` twice on the same toggle is a no-op with a warning.

Config fields are the same as the standalone `CreateKeybind` config below.

### `Section:CreateKeybind(config)` → `Keybind` handle

Standalone keybind picker in its own row.

| field | type | default |
|---|---|---|
| `Name` | string | `"Keybind"` |
| `CurrentKeybind` | string | `"None"` |
| `Callback` | `function(keyString)` | — |

Valid `CurrentKeybind` strings:
- `"None"` or `"Unknown"` — unbound
- `"MouseButton1"`, `"MouseButton2"`, `"MouseButton3"` — standard mouse buttons
- `"Mouse4"`, `"Mouse5"` — mouse X-buttons (see mouse 4/5 note below)
- Any `Enum.KeyCode` name: `"Q"`, `"LeftShift"`, `"F1"`, `"Space"`, etc.

Handle methods:
- `:Get()` — current key string
- `:Set(str)` — set and fire callback
- `:SetSilent(str)` — set without firing callback
- `:IsHeld()` — is the bound key currently down?

### `Section:CreateSlider(config)` → `Slider` handle

| field | type | default |
|---|---|---|
| `Name` | string | `"Slider"` |
| `Range` | `{min, max}` | `{0, 100}` |
| `Increment` | number | `1` |
| `CurrentValue` | number | `min` |
| `Suffix` | string | `""` |
| `Callback` | `function(value)` | — |

Integer format when `Increment >= 1`; two-decimal float format otherwise. Drag to scrub, click-anywhere to snap.

Handle methods: `:Get()`, `:Set(v)`, `:SetSilent(v)`.

### `Section:CreateDropdown(config)` → `Dropdown` handle

| field | type | default |
|---|---|---|
| `Name` | string | `"Dropdown"` |
| `Options` | string[] | `{}` |
| `CurrentOption` | string | first option |
| `Callback` | `function(option)` | — |

Handle methods:
- `:Get()` / `:Set(option)` / `:SetSilent(option)`
- `:Refresh(newOptions, newCurrent)` — replace the option list (e.g. for a dynamic dropdown of live player names)

### `Section:CreateColorPicker(config)` → `ColorPicker` handle

| field | type | default |
|---|---|---|
| `Name` | string | `"Color"` |
| `CurrentColor` | `Color3` | white |
| `Callback` | `function(Color3)` | — |

Clicking the row's color swatch opens a popup with a saturation/value box, a vertical hue bar, and a hex readout. The callback fires on every drag step (same cadence as the slider — wrap your own debounce if the downstream work is heavy).

Handle methods:
- `:Get()` — current `Color3`
- `:Set(color)` — set and fire callback
- `:SetSilent(color)` — set without firing callback

### `Section:CreateButton(config)` → `Button` handle

| field | type | default |
|---|---|---|
| `Name` | string | `"Button"` |
| `Callback` | `function()` | — |
| `Confirm` | boolean | `false` |

When `Confirm = true`, the first click changes the button to "Click again to confirm" in red for 500ms; a second click within that window fires the callback; a timeout resets the button.

Handle method: `:SetText(text)`.

### `Section:CreateLabel(config)` → `Label` handle

| field | type | default |
|---|---|---|
| `Text` | string | `""` |
| `Color` | `Color3` | theme textDim |

Handle methods: `:SetText(text)`, `:SetColor(color)`.

### `Section:CreateParagraph(config)` → `Paragraph` handle

Bordered card with a title and a wrapped body.

| field | type | default |
|---|---|---|
| `Title` | string | `""` |
| `Content` | string | `""` |

Handle methods: `:SetTitle(text)`, `:SetContent(text)`.

### `UI:Notify(config)`

Fires a toast-style notification in the top-right corner. Notifications live in their own shared ScreenGui so they persist across window destroys.

| field | type | default |
|---|---|---|
| `Title` | string | `""` |
| `Content` | string | `""` |
| `Duration` | number | `4` (seconds) |
| `Accent` | `Color3` | default sky blue |

### `UI:CreateFovCircle(config)` → `FovCircle` handle

Draws a circle overlay at the center of the game viewport for aimbot FOV visualization. The circle lives in its own shared ScreenGui at `DisplayOrder = -1` so it always renders behind window UIs and never occludes controls. It's not bound to any window — create it once, update it from your slider/toggle callbacks, and call `:Destroy()` from your `Window:OnClose` handler (or whenever your script unloads).

| field | type | default |
|---|---|---|
| `Radius` | number | `100` (pixels, half-width) |
| `Color` | `Color3` | white |
| `Thickness` | number | `1` (outline px) |
| `Filled` | boolean | `false` |
| `FillTransparency` | number | `0.8` (0 = opaque, 1 = invisible) |
| `Visible` | boolean | `true` |

All setters silently ignore wrong-typed input — so you can bind them directly to slider and toggle callbacks without a guard wrapper. Calls after `:Destroy()` are no-ops.

Handle methods:
- `:SetRadius(r)` / `:GetRadius()` — radius in pixels, clamped to `>= 0`
- `:SetColor(c)` / `:GetColor()` — outline and fill color
- `:SetThickness(t)` / `:GetThickness()` — outline width in pixels
- `:SetFilled(bool)` / `:IsFilled()` — show/hide the interior fill
- `:SetFillTransparency(t)` / `:GetFillTransparency()` — clamped to `[0, 1]`
- `:SetVisible(bool)` / `:IsVisible()` — show/hide the whole overlay
- `:Destroy()` — idempotent; setters after destroy no-op silently

Rendered as a single `Frame` + `UICorner` + `UIStroke` — no Drawing library, no image assets — so it works in any ScreenGui stack including CoreGui fallbacks.

## Mouse 4 / Mouse 5 detection

Roblox's `UserInputService` does not expose the mouse X-buttons at all — the `Enum.UserInputType` enum tops out at `MouseButton3`, and `GetKeysPressed` / `IsMouseButtonPressed` don't surface them either. Every Roblox-only UI library, including Rayfield, is stuck with LMB/RMB/MMB for keybinds for this reason.

OvertimeUI works around this by calling two globals the Overtime Executor exposes:

- `isMouse4Down()` — returns `true` while mouse 4 is held
- `isMouse5Down()` — returns `true` while mouse 5 is held

Those globals are backed by a `GetAsyncKeyState(VK_XBUTTON1/VK_XBUTTON2)` call on the executor side (a separate process, so it works regardless of Roblox window focus). The library caches the result at 50ms so per-frame `IsHeld()` polling from scripts doesn't bang on the bridge unnecessarily.

**On any executor that doesn't expose those globals, the library silently degrades** — mouse 4/5 always report `false` and the rebind picker can't capture them, but every other control works exactly as before. You'll still get keyboard and MB1/2/3 support everywhere.

The Overtime Executor itself is closed source, so there's no public diff to point at — but if you're building your own executor and want mouse 4/5 support, the approach is straightforward: roughly 20 lines of C++ wrapping `GetAsyncKeyState(VK_XBUTTON1/VK_XBUTTON2)` and exposing the results to Lua as `isMouse4Down()` / `isMouse5Down()` globals (directly, or via a local HTTP bridge if your executor runs out-of-process).

## Lifecycle and re-run semantics

Each window is anchored to a `BoolValue` marker inside `LocalPlayer` named `_OvertimeUI_<WindowName>`. The marker is owned by the library — scripts don't touch it directly.

When the user re-runs the script to toggle it off:

1. The new `CreateWindow` call sees the existing marker, destroys it, and returns `nil`.
2. The old instance's `Destroying` hook on the marker fires, which calls the old `Window:Destroy()`, which fires registered `OnClose` callbacks and tears down the old ScreenGui.
3. The script's own `if not Window then return end` bails after the new `CreateWindow` returns `nil`.

Net result: running the script once creates the window, running it again destroys it. Same behavior as every hand-rolled cheat script on the Roblox exploit ecosystem, but you don't have to write the marker logic yourself.

## Example

See [`examples/UI.lua`](examples/UI.lua) for a full smoke test that exercises every control.

## License

MIT — see [LICENSE](LICENSE).
