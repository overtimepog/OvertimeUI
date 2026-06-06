-- Showcase.lua — four windows, one library, zero family resemblance.
--
-- Every window below is built from the *same* OvertimeUI. The only thing that
-- differs is the Theme (colours) and Style (structure) passed to CreateWindow.
-- Run it and you should see four menus that don't look like they came from the
-- same place — which is the whole point: the library shouldn't stamp a generic
-- look onto your script.
--
-- Re-run to toggle each window off (they share the standard marker handshake;
-- because each has a distinct Name, each toggles independently — but this demo
-- re-runs them together, so a second run clears all four).

-- The library version this showcase was written against. If the version that
-- actually loads doesn't match, you're almost certainly looking at a stale
-- raw.githubusercontent CDN copy (cached up to ~5 min) — the new tokens won't
-- render until it catches up. The check below shouts about that so you don't
-- waste time wondering why "top" layout / gradients aren't showing.
local EXPECTED_VERSION = "0.2.0"

local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/overtimepog/OvertimeUI/main/OvertimeUI.lua"))()
if not UI then warn("[Showcase] Failed to load OvertimeUI"); return end

local loaded = tostring(UI._VERSION)
if loaded ~= EXPECTED_VERSION then
    warn(("[Showcase] Loaded OvertimeUI v%s but this showcase expects v%s — "
        .. "you're seeing a STALE cached library. Wait a few minutes for the "
        .. "raw.githubusercontent CDN to refresh, then re-run."):format(loaded, EXPECTED_VERSION))
else
    print("[Showcase] OvertimeUI v" .. loaded .. " (matches expected v" .. EXPECTED_VERSION .. ")")
end

-- Small helper so each window gets a couple of representative controls without
-- repeating the boilerplate four times.
local function populate(Window, accent)
    if not Window then return end
    local tabA = Window:CreateTab("Main")
    local s1 = tabA:CreateSection("General")
    s1:CreateToggle({ Name = "Enable", CurrentValue = true,
        Callback = function(v) print("enable", v) end })
    s1:CreateSlider({ Name = "Strength", Range = { 0, 100 }, CurrentValue = 50, Suffix = "%",
        Callback = function(v) print("strength", v) end })
    s1:CreateDropdown({ Name = "Mode", Options = { "Smooth", "Snap", "Predict" }, CurrentOption = "Smooth",
        Callback = function(o) print("mode", o) end })
    local s2 = tabA:CreateSection("Color")
    s2:CreateColorPicker({ Name = "Highlight", CurrentColor = accent,
        Callback = function(c) print("color", c) end })
    s2:CreateButton({ Name = "Apply", Callback = function() print("apply") end })

    local tabB = Window:CreateTab("Misc")
    local s3 = tabB:CreateSection("Info")
    s3:CreateParagraph({ Title = "About", Content = "Same library, custom skin." })
    s3:CreateKeybind({ Name = "Panic Key", CurrentKeybind = "RightShift",
        Callback = function(k) print("panic", k) end })
end

-- 1) "Aurora" — top tab-bar, centred title, pill corners, gradient accent,
--    glassy panel, snappy motion. Top-left of the screen.
populate(UI:CreateWindow({
    Name              = "Aurora",
    SubTitle          = "top bar · glass",
    Position          = UDim2.fromOffset(40, 40),
    TitleAlign        = "center",
    AccentGradient    = { Color3.fromRGB(120, 90, 255), Color3.fromRGB(0, 200, 255) },
    Layout            = "top",
    Roundness         = 2,
    PanelTransparency = 0.12,
    Animation         = 0.6,
    Theme = { bg = Color3.fromRGB(18, 16, 28), bgAlt = Color3.fromRGB(24, 22, 36),
              surface = Color3.fromRGB(34, 31, 50), surfaceHi = Color3.fromRGB(48, 44, 70) },
}), Color3.fromRGB(120, 90, 255))

-- 2) "RootKit" — dense, sharp, heavy-framed terminal look, no decorations.
--    Top-right of the screen.
populate(UI:CreateWindow({
    Name            = "RootKit",
    Position        = UDim2.new(1, -480, 0, 40),
    Size            = UDim2.fromOffset(440, 320),
    Accent          = Color3.fromRGB(0, 255, 140),
    Roundness       = 0,
    Font            = Enum.Font.Code,
    FontBold        = Enum.Font.Code,
    FontSemi        = Enum.Font.Code,
    StrokeThickness = 2,
    TabWidth        = 96,
    TabHeight       = 24,
    BodyPadding     = 8,
    Spacing         = 1,
    Sheen           = false,
    Shadow          = false,
    Theme = { bg = Color3.fromRGB(8, 10, 9), bgAlt = Color3.fromRGB(12, 16, 14),
              surface = Color3.fromRGB(18, 24, 20), border = Color3.fromRGB(0, 90, 50),
              borderHi = Color3.fromRGB(0, 160, 90), text = Color3.fromRGB(180, 255, 210) },
}), Color3.fromRGB(0, 255, 140))

-- 3) "Velvet" — warm, soft, roomy, big rounded sidebar, languid motion.
--    Bottom-left of the screen.
populate(UI:CreateWindow({
    Name        = "Velvet",
    SubTitle    = "warm · roomy",
    Position    = UDim2.new(0, 40, 1, -400),
    Size        = UDim2.fromOffset(540, 360),
    Accent      = Color3.fromRGB(255, 120, 90),
    Roundness   = 1.6,
    TitleHeight = 48,
    TabWidth    = 150,
    TabHeight   = 38,
    BodyPadding = 18,
    Spacing     = 6,
    Animation   = 1.5,
    Theme = { bg = Color3.fromRGB(30, 22, 24), bgAlt = Color3.fromRGB(40, 30, 32),
              surface = Color3.fromRGB(54, 40, 42), surfaceHi = Color3.fromRGB(72, 54, 56),
              text = Color3.fromRGB(245, 236, 232), textDim = Color3.fromRGB(180, 150, 148) },
}), Color3.fromRGB(255, 120, 90))

-- 4) "Stock" — defaults, for side-by-side comparison. Bottom-right.
populate(UI:CreateWindow({
    Name     = "Stock",
    SubTitle = "defaults · v" .. loaded,
    Position = UDim2.new(1, -560, 1, -400),
    Accent   = Color3.fromRGB(96, 165, 255),
}), Color3.fromRGB(96, 165, 255))

print(("[Showcase] Four windows up (OvertimeUI v%s) — same library, four looks. Re-run to clear.")
    :format(loaded))
