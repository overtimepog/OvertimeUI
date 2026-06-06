-- Showcase.lua — many looks, one library.
--
-- Each window is built from the SAME OvertimeUI. The differences are all
-- config: presets (curated theme + structure + depth bundles), the depth flags
-- (gradient strokes, accent glow, gradient fills), tab icons, and the two-column
-- groupbox layout. Run it and you should see menus that don't look related.
--
-- Re-run to toggle the windows off.

-- Bump this whenever the library changes so a stale raw.githubusercontent CDN
-- copy (cached up to ~5 min) is obvious instead of looking like a broken build.
local EXPECTED_VERSION = "0.3.1"

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

-- Fill a single-column (Section-based) window with a representative spread.
local function populate(Window, accent)
    if not Window then return end
    local main = Window:CreateTab("Main", { Icon = "rbxassetid://10709790644" })   -- a gear-ish icon
    local g = main:CreateSection("General")
    g:CreateToggle({ Name = "Enable", CurrentValue = true, Callback = function() end })
    g:CreateSlider({ Name = "Strength", Range = { 0, 100 }, CurrentValue = 60, Suffix = "%", Callback = function() end })
    g:CreateDropdown({ Name = "Mode", Options = { "Smooth", "Snap", "Predict" }, Callback = function() end })
    local c = main:CreateSection("Color")
    c:CreateColorPicker({ Name = "Highlight", CurrentColor = accent, Callback = function() end })
    c:CreateButton({ Name = "Apply", Callback = function() end })
    local misc = Window:CreateTab("Misc", { Icon = "rbxassetid://10734898355" })   -- an info-ish icon
    local i = misc:CreateSection("Info")
    i:CreateParagraph({ Title = "About", Content = "Same library — the look is all config." })
    i:CreateKeybind({ Name = "Panic Key", CurrentKeybind = "RightShift", Callback = function() end })
end

-- 1) AURORA preset — modern frosted top-bar, gradient accent, glow. Top-left.
populate(UI:CreateWindow({
    Preset = "Aurora", Name = "Aurora", SubTitle = "preset · top · glass",
    Position = UDim2.fromOffset(40, 40),
}), Color3.fromRGB(120, 90, 255))

-- 2) SLEEK preset — Rayfield-style sidebar with glow + gradient framing. Top-right.
populate(UI:CreateWindow({
    Preset = "Sleek", Name = "Sleek", SubTitle = "preset · lit sidebar",
    Position = UDim2.new(1, -480, 0, 40),
}), Color3.fromRGB(96, 165, 255))

-- 3) TERMINAL preset — dense, sharp, monospaced, no glow. Bottom-left.
populate(UI:CreateWindow({
    Preset = "Terminal", Name = "RootKit", SubTitle = "preset · dense",
    Position = UDim2.new(0, 40, 1, -400), Size = UDim2.fromOffset(440, 320),
}), Color3.fromRGB(80, 220, 120))

-- 4) COMPACT preset + TWO-COLUMN GROUPBOXES — the Linoria "cheat menu" energy.
--    Bottom-right. This is a different STRUCTURE, not just a recolor.
do
    local W = UI:CreateWindow({
        Preset = "Compact", Name = "Cobalt", SubTitle = "preset · two columns · v" .. loaded,
        Position = UDim2.new(1, -560, 1, -400), Size = UDim2.fromOffset(540, 380),
    })
    if W then
        local combat = W:CreateTab("Combat", { Icon = "rbxassetid://10709805956" })
        local aim = combat:CreateLeftGroupbox("Aimbot")
        aim:CreateToggle({ Name = "Enabled", CurrentValue = true, Callback = function() end })
            :AddKeybind({ CurrentKeybind = "MouseButton2", Callback = function() end })
        aim:CreateSlider({ Name = "FOV", Range = { 0, 360 }, CurrentValue = 120, Callback = function() end })
        aim:CreateSlider({ Name = "Smoothness", Range = { 0, 1 }, Increment = 0.05, CurrentValue = 0.3, Callback = function() end })
        aim:CreateDropdown({ Name = "Target", Options = { "Head", "Torso", "Nearest" }, Callback = function() end })

        local esp = combat:CreateRightGroupbox("ESP")
        esp:CreateToggle({ Name = "Boxes", CurrentValue = true, Callback = function() end })
        esp:CreateToggle({ Name = "Names", CurrentValue = true, Callback = function() end })
        esp:CreateToggle({ Name = "Tracers", CurrentValue = false, Callback = function() end })
        esp:CreateColorPicker({ Name = "Color", CurrentColor = Color3.fromRGB(120, 200, 255), Callback = function() end })

        local cfg = combat:CreateRightGroupbox("Config")
        cfg:CreateButton({ Name = "Save", Callback = function() end })
        cfg:CreateButton({ Name = "Load", Callback = function() end })
    end
end

print(("[Showcase] Windows up (OvertimeUI v%s) — presets, depth, icons, two-column groupboxes.")
    :format(loaded))
