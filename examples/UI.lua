-- UI.lua — smoke test for the OvertimeUI library.
--
-- Exercises every v0.1 control so you can eyeball the rendered window
-- in-game. Run from your executor and expect a window with four tabs
-- to appear, each containing a different control type. Interaction
-- with any control prints to the executor console.
--
-- Running the script a second time toggles the window off (library
-- handles the marker-destroy-rerun handshake internally, we just bail
-- on nil).

local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/overtimepog/OvertimeUI/main/OvertimeUI.lua"))()
if not UI then
    warn("[UI_Test] Failed to load OvertimeUI")
    return
end

local Window = UI:CreateWindow({
    Name = "UI Test",
    Accent = Color3.fromRGB(255, 140, 60),
})
if not Window then return end  -- re-ran to toggle off

print("[UI_Test] OvertimeUI version: " .. tostring(UI._VERSION))

-- =========================================================================
-- Visuals tab — toggles + an inline attached keybind (Linoria-style)
-- =========================================================================
local Visuals = Window:CreateTab("Visuals")

local EspSection = Visuals:CreateSection("ESP")

local EspToggle = EspSection:CreateToggle({
    Name = "ESP Highlights",
    CurrentValue = true,
    Callback = function(v) print("[UI_Test] ESP =", v) end,
})

-- Toggle with inline keybind. :AddKeybind attaches a rebind button to the
-- right side of the same row. The returned handle gains :GetKeybind,
-- :SetKeybind, :IsKeybindHeld alongside the existing :Get/:Set.
local Box2DToggle = EspSection:CreateToggle({
    Name = "2D Box ESP",
    CurrentValue = false,
    Callback = function(v) print("[UI_Test] Box2D =", v) end,
}):AddKeybind({
    CurrentKeybind = "B",
    Callback = function(k) print("[UI_Test] Box2D hotkey rebound to:", k) end,
})

EspSection:CreateToggle({
    Name = "Head Dot",
    CurrentValue = true,
    Callback = function(v) print("[UI_Test] HeadDot =", v) end,
})

EspSection:CreateColorPicker({
    Name = "Highlight Color",
    CurrentColor = Color3.fromRGB(255, 140, 60),
    Callback = function(c)
        print(string.format("[UI_Test] Highlight color = (%d, %d, %d)",
            math.floor(c.R * 255 + 0.5),
            math.floor(c.G * 255 + 0.5),
            math.floor(c.B * 255 + 0.5)))
    end,
})

-- Poll Box2D's attached keybind every frame. Lets us verify the inline
-- keybind plumbing works the same as a standalone keybind.
task.spawn(function()
    local lastHeld = false
    while not Window._destroyed do
        task.wait(0.05)
        local held = Box2DToggle:IsKeybindHeld()
        if held ~= lastHeld then
            print("[UI_Test] Box2D hotkey:", held and "HELD" or "released",
                "(binding: " .. Box2DToggle:GetKeybind() .. ")")
            lastHeld = held
        end
    end
end)

local InfoSection = Visuals:CreateSection("Info")
InfoSection:CreateLabel({ Text = "Label: static text row, dimmed by default." })
InfoSection:CreateToggle({
    Name = "Name Tags",
    CurrentValue = true,
    Callback = function(v) print("[UI_Test] Names =", v) end,
})
InfoSection:CreateToggle({
    Name = "Distance",
    CurrentValue = true,
    Callback = function(v) print("[UI_Test] Distance =", v) end,
})

-- =========================================================================
-- Aimbot tab — sliders, dropdown, keybind
-- =========================================================================
local AimbotTab = Window:CreateTab("Aimbot")
local AimSection = AimbotTab:CreateSection("Aimbot")

local AimToggle = AimSection:CreateToggle({
    Name = "Enable Aimbot",
    CurrentValue = false,
    Callback = function(v) print("[UI_Test] Aimbot =", v) end,
})

AimSection:CreateSlider({
    Name = "FOV",
    Range = {1, 30},
    Increment = 1,
    CurrentValue = 6,
    Suffix = "°",
    Callback = function(v) print("[UI_Test] FOV =", v) end,
})

AimSection:CreateSlider({
    Name = "Smoothness",
    Range = {0.01, 0.5},
    Increment = 0.01,
    CurrentValue = 0.12,
    Callback = function(v) print(string.format("[UI_Test] Smoothness = %.2f", v)) end,
})

AimSection:CreateSlider({
    Name = "Max Distance",
    Range = {50, 500},
    Increment = 10,
    CurrentValue = 300,
    Suffix = " studs",
    Callback = function(v) print("[UI_Test] MaxDist =", v) end,
})

AimSection:CreateDropdown({
    Name = "Target Part",
    Options = {"Head", "UpperTorso", "HumanoidRootPart"},
    CurrentOption = "Head",
    Callback = function(v) print("[UI_Test] Target =", v) end,
})

local AimKeyBind = AimSection:CreateKeybind({
    Name = "Aim Key",
    CurrentKeybind = "MouseButton2",
    Callback = function(k) print("[UI_Test] Aim Key rebound to:", k) end,
})

-- FOV circle demo. UI:CreateFovCircle returns a standalone handle (not
-- bound to a section) that draws a circle at the game viewport's center.
-- The controls below update the circle live; the OnClose at the bottom
-- of this script tears it down with the window.
local FovCircleSection = AimbotTab:CreateSection("FOV Circle")

local fovCircle = UI:CreateFovCircle({
    Radius    = 120,
    Color     = Color3.fromRGB(255, 140, 60),
    Thickness = 1,
    Visible   = false,
})

FovCircleSection:CreateToggle({
    Name = "Show FOV Circle",
    CurrentValue = false,
    Callback = function(v) fovCircle:SetVisible(v) end,
})

FovCircleSection:CreateSlider({
    Name = "Radius",
    Range = {20, 400},
    Increment = 5,
    CurrentValue = 120,
    Suffix = " px",
    Callback = function(v) fovCircle:SetRadius(v) end,
})

FovCircleSection:CreateSlider({
    Name = "Outline Thickness",
    Range = {0, 6},
    Increment = 1,
    CurrentValue = 1,
    Suffix = " px",
    Callback = function(v) fovCircle:SetThickness(v) end,
})

FovCircleSection:CreateColorPicker({
    Name = "Color",
    CurrentColor = Color3.fromRGB(255, 140, 60),
    Callback = function(c) fovCircle:SetColor(c) end,
})

FovCircleSection:CreateToggle({
    Name = "Filled",
    CurrentValue = false,
    Callback = function(v) fovCircle:SetFilled(v) end,
})

FovCircleSection:CreateSlider({
    Name = "Fill Transparency",
    Range = {0, 1},
    Increment = 0.05,
    CurrentValue = 0.8,
    Callback = function(v) fovCircle:SetFillTransparency(v) end,
})

-- Poll :IsHeld() every frame on a spare thread and print when the state
-- changes. This is the same pattern as Box2D above but for the standalone
-- keybind. Used to verify Mouse4/Mouse5 detection still works after the
-- helper refactor.
task.spawn(function()
    local lastHeld = false
    while not Window._destroyed do
        task.wait(0.05)
        local held = AimKeyBind:IsHeld()
        if held ~= lastHeld then
            print("[UI_Test] Aim key:", held and "HELD" or "released",
                "(binding: " .. AimKeyBind:Get() .. ")")
            lastHeld = held
        end
    end
end)

-- =========================================================================
-- Misc tab — buttons, paragraph, notifications
-- =========================================================================
local Misc = Window:CreateTab("Misc")

local InfoSec = Misc:CreateSection("About")
InfoSec:CreateParagraph({
    Title = "OvertimeUI v" .. tostring(UI._VERSION),
    Content = "A Roblox UI library for Overtime Executor scripts. Supports tabs, "
           .. "toggles, sliders, dropdowns, buttons, keybinds (including "
           .. "mouse X-buttons), labels, paragraphs, and toast notifications.",
})

local Actions = Misc:CreateSection("Actions")

Actions:CreateButton({
    Name = "Fire a Notification",
    Callback = function()
        UI:Notify({
            Title = "Hello",
            Content = "This is a test notification fired from the UI_Test button.",
            Duration = 4,
        })
    end,
})

Actions:CreateButton({
    Name = "Multi-Notify Spam",
    Callback = function()
        for i = 1, 3 do
            UI:Notify({
                Title = "Notification " .. i,
                Content = "Testing the stack — each notification should slide "
                       .. "in separately and stack vertically.",
                Duration = 3 + i,
            })
            task.wait(0.3)
        end
    end,
})

Actions:CreateButton({
    Name = "Dangerous Button (confirm)",
    Confirm = true,
    Callback = function()
        print("[UI_Test] Dangerous action confirmed")
        UI:Notify({
            Title = "Confirmed",
            Content = "The dangerous action ran.",
            Duration = 3,
        })
    end,
})

Actions:CreateButton({
    Name = "Close Window",
    Callback = function()
        Window:Destroy()
    end,
})

Misc:CreateSection("API checks"):CreateToggle({
    Name = "Debug",
    CurrentValue = false,
    Callback = function(v) print("[UI_Test] Debug =", v) end,
})

-- =========================================================================
-- Auto-API-flip test — verifies :Set() on an existing handle works.
-- =========================================================================
task.delay(5, function()
    if Window._destroyed then return end
    local current = EspToggle:Get()
    print("[UI_Test] Auto-flip ESP from " .. tostring(current) .. " to " .. tostring(not current))
    EspToggle:Set(not current)
end)

-- =========================================================================
-- Window lifecycle hook
-- =========================================================================
Window:OnClose(function()
    print("[UI_Test] Window closed — OnClose callback fired")
    fovCircle:Destroy()
end)

print("[UI_Test] Ready. Every tab has something to click.")
print("[UI_Test] Fire a Notification (Misc tab) tests the toast system.")
print("[UI_Test] Box2D toggle has an inline keybind next to it.")
