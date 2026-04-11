# OvertimeUI

A single-file Roblox UI library for scripts loaded through the Overtime Executor (and any other executor with `loadstring` + `game:HttpGet` support).

Tabs, toggles, sliders, dropdowns, buttons, keybinds, labels, paragraphs, and toast notifications — everything you need to build a clean cheat-menu-style interface in ~20 lines of config.

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
- **Labels** and **Paragraphs** for inline text / doc blocks
- **Toast notifications** with a shared stack, TweenService slide-in/out, and auto-dismiss
- **Self-contained lifecycle** — the library owns the ScreenGui and a `BoolValue` marker; re-running the script toggles the window off automatically
- **Per-window accent color override** (defaults to sky blue)
- **~1460 lines, single file, no external dependencies**

## API reference

### `UI:CreateWindow(config)`

Creates the top-level window. Returns a `Window` handle, or `nil` if an existing window with the same `Name` is already open (which means the script is being re-run to toggle off — the library destroys the old marker, the old instance self-cleans via its Destroying hook, and the second run returns `nil` so the script can bail).

| field | type | default | notes |
|---|---|---|---|
| `Name` | string | `"OvertimeUI"` | Used for the title bar text and the marker name |
| `Accent` | `Color3` | sky blue | Per-window accent override |
| `Size` | `UDim2` | `(0, 520, 0, 360)` | Fixed panel size |
| `Position` | `UDim2` | centered | Starting position |

### `Window:CreateTab(name)`

Adds a tab to the left strip. Returns a `Tab` handle. The first tab created becomes active automatically.

### `Window:OnClose(callback)`

Registers a callback that fires when the window is destroyed — whether via the `×` button, `Window:Destroy()`, or the marker being destroyed externally.

### `Window:Destroy()`

Tear down the window immediately. Fires any `OnClose` callbacks, disconnects internal listeners, destroys the ScreenGui, removes the marker.

### `Tab:CreateSection(name)`

Adds a section header + container inside the tab body. Returns a `Section` handle. Sections are visually separated by a small spacer and an uppercase accent-color header.

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

See [`examples/UI_Test.lua`](examples/UI_Test.lua) for a full smoke test that exercises every control.

## License

MIT — see [LICENSE](LICENSE).
