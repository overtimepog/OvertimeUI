-- UI_Test.lua — automated self-test runner for OvertimeUI.
--
-- Creates a single test window and programmatically exercises every
-- public API surface: Toggle Get/Set/SetSilent, Slider clamping and
-- increment snapping, Dropdown Refresh, Keybind rebinding, Toggle:Add
-- Keybind (including the double-call no-op warning), ColorPicker
-- Get/Set/SetSilent with non-Color3 rejection, FovCircle radius/color/
-- visibility/fill updates with input clamping and Destroy idempotence,
-- Button/Label/Paragraph updaters, UI:Notify, and Window lifecycle
-- (OnClose firing on Destroy, re-run toggle-off via marker handshake).
--
-- Each test is pcall-guarded with PASS/FAIL printed to the executor
-- console, then the pass/fail count is pushed back into the UI itself
-- via a Results section at the top. Final notification summarises.
--
-- Running the script a second time toggles the window off.

-- Local dev load: readfile the library straight off disk through a
-- directory junction in the executor's sandbox. Overtime's readfile
-- sandbox is rooted at <exe_dir>/Scripts and rejects absolute paths
-- and `..`, so we can't point at the repo directly. Instead there is
-- a one-time junction set up at:
--   <exe>\Scripts\OvertimeUI  →  C:\Users\truen\Desktop\Stuff\OvertimeUI
-- which lets the sandbox-relative path "OvertimeUI/OvertimeUI.lua"
-- resolve straight to the repo file. Edits show up on the next in-game
-- run with no commit or copy step.
--
-- If that junction is ever missing (fresh machine, rebuilt executor
-- package, etc.) recreate it from an elevated PowerShell with:
--   New-Item -ItemType Junction `
--     -Path   "<exe>\Scripts\OvertimeUI" `
--     -Target "C:\Users\truen\Desktop\Stuff\OvertimeUI"
--
-- The shipping smoke test in examples/UI_Test.lua uses the
-- raw.githubusercontent.com HttpGet loader instead — do NOT replace
-- this block with that one or you'll lose the fast iteration loop.
local LIB_PATH = "OvertimeUI/OvertimeUI.lua"

local ok, src = pcall(readfile, LIB_PATH)
if not ok or type(src) ~= "string" then
    warn("[UI_Test] Failed to readfile " .. LIB_PATH .. ": " .. tostring(src))
    warn("[UI_Test] If the junction is missing, see the block comment above.")
    return
end

local loaded, loadErr = loadstring(src, "@OvertimeUI.lua")
if not loaded then
    warn("[UI_Test] Failed to loadstring OvertimeUI.lua: " .. tostring(loadErr))
    return
end

local UI = loaded()
if not UI then
    warn("[UI_Test] OvertimeUI returned nil")
    return
end

local Window = UI:CreateWindow({
    Name   = "OvertimeUI Self-Test",
    Accent = Color3.fromRGB(255, 140, 60),
})
if not Window then return end  -- re-ran to toggle off

print("[UI_Test] OvertimeUI version: " .. tostring(UI._VERSION))

-- =========================================================================
-- Test harness
-- =========================================================================

local passed, failed = 0, 0
local failureLog = {}

local function test(label, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("[PASS] " .. label)
    else
        failed = failed + 1
        local msg = tostring(err)
        table.insert(failureLog, label .. ": " .. msg)
        warn("[FAIL] " .. label .. " — " .. msg)
    end
end

-- Strict equality assertion with a readable error message.
local function assertEq(actual, expected, context)
    if actual ~= expected then
        error((context or "assertEq")
            .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

-- Approximate equality for floats (increment-snapped slider values can
-- sit slightly off the intended value after floating-point arithmetic).
local function assertApprox(actual, expected, eps, context)
    eps = eps or 1e-6
    if math.abs(actual - expected) > eps then
        error((context or "assertApprox")
            .. ": expected ~" .. tostring(expected)
            .. " (eps " .. tostring(eps) .. ")"
            .. ", got " .. tostring(actual), 2)
    end
end

-- Per-channel approximate Color3 equality. The color picker round-trips
-- through HSV on every Set, which can introduce up to ~1/255 of drift
-- per channel, so bit-exact equality is too strict. Default eps = 0.01.
local function assertColorEq(actual, expected, eps, context)
    eps = eps or 0.01
    if typeof(actual) ~= "Color3" then
        error((context or "assertColorEq") .. ": expected a Color3, got " .. typeof(actual), 2)
    end
    local dr = math.abs(actual.R - expected.R)
    local dg = math.abs(actual.G - expected.G)
    local db = math.abs(actual.B - expected.B)
    if dr > eps or dg > eps or db > eps then
        error((context or "assertColorEq")
            .. string.format(": expected (%.3f, %.3f, %.3f), got (%.3f, %.3f, %.3f)",
                expected.R, expected.G, expected.B,
                actual.R,   actual.G,   actual.B), 2)
    end
end

-- =========================================================================
-- Window / tab / section layout
-- =========================================================================

local MainTab = Window:CreateTab("Self-Test")

-- Results section: placeholders that get populated at the end of the run
-- with the final pass/fail count. The paragraph's Content is mutated via
-- :SetContent after the tests finish.
local ResultsSection = MainTab:CreateSection("Results")
local statusLabel = ResultsSection:CreateLabel({ Text = "Running tests..." })
local summaryPara = ResultsSection:CreateParagraph({
    Title   = "OvertimeUI Self-Test",
    Content = "Tests are running. This card is updated once they finish.",
})
ResultsSection:CreateButton({
    Name = "Close Self-Test Window",
    Callback = function() Window:Destroy() end,
})

-- Workspace section: test artifacts (toggles, sliders, etc.) get created
-- here so the user can see the post-test state of every control that
-- was exercised. Section is cluttered by design.
local Workspace = MainTab:CreateSection("Test Artifacts")

-- =========================================================================
-- Toggle tests
-- =========================================================================

test("Toggle :Get returns the initial value", function()
    local fired = false
    local t = Workspace:CreateToggle({
        Name         = "toggle:init",
        CurrentValue = true,
        Callback     = function() fired = true end,
    })
    assertEq(t:Get(), true, "initial Get")
    assertEq(fired, false, "callback should NOT fire during construction")
end)

test("Toggle :Set flips state and fires callback", function()
    local fired
    local t = Workspace:CreateToggle({
        Name         = "toggle:set",
        CurrentValue = false,
        Callback     = function(v) fired = v end,
    })
    t:Set(true)
    -- Callback runs in task.spawn, so give it one scheduler tick to land.
    task.wait()
    assertEq(t:Get(), true, "after Set(true)")
    assertEq(fired, true, "callback value")
end)

test("Toggle :SetSilent updates without firing the callback", function()
    local fired = false
    local t = Workspace:CreateToggle({
        Name         = "toggle:silent",
        CurrentValue = false,
        Callback     = function() fired = true end,
    })
    t:SetSilent(true)
    task.wait()
    assertEq(t:Get(), true, "after SetSilent(true)")
    assertEq(fired, false, "callback should NOT fire on SetSilent")
end)

test("Toggle :Set with the current value is a no-op", function()
    local fires = 0
    local t = Workspace:CreateToggle({
        Name         = "toggle:noop",
        CurrentValue = false,
        Callback     = function() fires = fires + 1 end,
    })
    t:Set(false); task.wait()
    assertEq(fires, 0, "same-value Set should not fire")
    t:Set(true); task.wait()
    assertEq(fires, 1, "different-value Set fires once")
    t:Set(true); task.wait()
    assertEq(fires, 1, "repeated same-value Set after flip should not fire again")
end)

test("Toggle handles a nil callback without erroring", function()
    local t = Workspace:CreateToggle({
        Name         = "toggle:nocallback",
        CurrentValue = false,
        -- no Callback field
    })
    t:Set(true); task.wait()
    assertEq(t:Get(), true, "state updated even without callback")
end)

-- =========================================================================
-- Slider tests
-- =========================================================================

test("Slider :Get returns the initial value", function()
    local s = Workspace:CreateSlider({
        Name         = "slider:init",
        Range        = { 1, 30 },
        Increment    = 1,
        CurrentValue = 6,
        Suffix       = "°",
        Callback     = function() end,
    })
    assertEq(s:Get(), 6, "initial Get")
end)

test("Slider :Set clamps values above the max", function()
    local s = Workspace:CreateSlider({
        Name         = "slider:clamp-high",
        Range        = { 0, 10 },
        Increment    = 1,
        CurrentValue = 5,
        Callback     = function() end,
    })
    s:Set(9999)
    assertEq(s:Get(), 10, "should clamp to 10")
end)

test("Slider :Set clamps values below the min", function()
    local s = Workspace:CreateSlider({
        Name         = "slider:clamp-low",
        Range        = { 5, 15 },
        Increment    = 1,
        CurrentValue = 10,
        Callback     = function() end,
    })
    s:Set(-9999)
    assertEq(s:Get(), 5, "should clamp to 5")
end)

test("Slider snaps to the configured integer increment", function()
    local s = Workspace:CreateSlider({
        Name         = "slider:snap-int",
        Range        = { 0, 10 },
        Increment    = 2,
        CurrentValue = 0,
        Callback     = function() end,
    })
    s:Set(7)
    assertEq(s:Get(), 8, "7 should snap to 8 (nearest multiple of 2)")
    s:Set(3)
    assertEq(s:Get(), 4, "3 should snap to 4")
    s:Set(0)
    assertEq(s:Get(), 0, "0 is a valid snap target")
end)

test("Slider snaps to a sub-integer increment (0.01)", function()
    local s = Workspace:CreateSlider({
        Name         = "slider:snap-float",
        Range        = { 0, 1 },
        Increment    = 0.01,
        CurrentValue = 0.5,
        Callback     = function() end,
    })
    s:Set(0.1234)
    assertApprox(s:Get(), 0.12, 1e-4, "0.1234 should snap to ~0.12")
    s:Set(0.177)
    assertApprox(s:Get(), 0.18, 1e-4, "0.177 should snap to ~0.18")
end)

test("Slider :Set fires the callback with the snapped value", function()
    local fired
    local s = Workspace:CreateSlider({
        Name         = "slider:callback",
        Range        = { 0, 100 },
        Increment    = 5,
        CurrentValue = 0,
        Callback     = function(v) fired = v end,
    })
    s:Set(37); task.wait()
    -- 37 snaps to 35 (nearest multiple of 5)
    assertEq(fired, 35, "callback should receive the snapped value")
end)

test("Slider :SetSilent updates without firing the callback", function()
    local fired = false
    local s = Workspace:CreateSlider({
        Name         = "slider:silent",
        Range        = { 0, 10 },
        Increment    = 1,
        CurrentValue = 0,
        Callback     = function() fired = true end,
    })
    s:SetSilent(5); task.wait()
    assertEq(s:Get(), 5, "value updated")
    assertEq(fired, false, "callback should NOT fire")
end)

-- =========================================================================
-- Dropdown tests
-- =========================================================================

test("Dropdown :Get returns the initial option", function()
    local d = Workspace:CreateDropdown({
        Name          = "dropdown:init",
        Options       = { "Alpha", "Bravo", "Charlie" },
        CurrentOption = "Bravo",
        Callback      = function() end,
    })
    assertEq(d:Get(), "Bravo", "initial Get")
end)

test("Dropdown :Set changes option and fires callback", function()
    local fired
    local d = Workspace:CreateDropdown({
        Name          = "dropdown:set",
        Options       = { "Alpha", "Bravo", "Charlie" },
        CurrentOption = "Alpha",
        Callback      = function(v) fired = v end,
    })
    d:Set("Charlie"); task.wait()
    assertEq(d:Get(), "Charlie", "after Set")
    assertEq(fired, "Charlie", "callback value")
end)

test("Dropdown :Refresh replaces options and falls back to first", function()
    local d = Workspace:CreateDropdown({
        Name          = "dropdown:refresh",
        Options       = { "A", "B", "C" },
        CurrentOption = "A",
        Callback      = function() end,
    })
    d:Refresh({ "X", "Y", "Z" })
    assertEq(d:Get(), "X", "old option gone — should select first of new list")
end)

test("Dropdown :Refresh honours an explicit new current", function()
    local d = Workspace:CreateDropdown({
        Name          = "dropdown:refresh-current",
        Options       = { "A", "B", "C" },
        CurrentOption = "A",
        Callback      = function() end,
    })
    d:Refresh({ "P", "Q", "R" }, "R")
    assertEq(d:Get(), "R", "explicit current should be honoured")
end)

test("Dropdown :Refresh preserves current if still in new list", function()
    local d = Workspace:CreateDropdown({
        Name          = "dropdown:refresh-preserve",
        Options       = { "A", "B", "C" },
        CurrentOption = "B",
        Callback      = function() end,
    })
    d:Refresh({ "A", "B", "C", "D" })
    assertEq(d:Get(), "B", "should preserve existing current if still present")
end)

-- =========================================================================
-- Keybind tests
-- =========================================================================

test("Keybind :Get returns the initial binding", function()
    local k = Workspace:CreateKeybind({
        Name           = "kb:init",
        CurrentKeybind = "F",
        Callback       = function() end,
    })
    assertEq(k:Get(), "F", "initial Get")
end)

test("Keybind :Set updates binding and fires callback", function()
    local fired
    local k = Workspace:CreateKeybind({
        Name           = "kb:set",
        CurrentKeybind = "F",
        Callback       = function(v) fired = v end,
    })
    k:Set("G"); task.wait()
    assertEq(k:Get(), "G", "after Set")
    assertEq(fired, "G", "callback value")
end)

test("Keybind :SetSilent updates without firing the callback", function()
    local fired = false
    local k = Workspace:CreateKeybind({
        Name           = "kb:silent",
        CurrentKeybind = "F",
        Callback       = function() fired = true end,
    })
    k:SetSilent("Q"); task.wait()
    assertEq(k:Get(), "Q", "after SetSilent")
    assertEq(fired, false, "callback should NOT fire")
end)

test("Keybind accepts Mouse4 and Mouse5 as valid strings", function()
    local k = Workspace:CreateKeybind({
        Name           = "kb:mouse4",
        CurrentKeybind = "Mouse4",
        Callback       = function() end,
    })
    assertEq(k:Get(), "Mouse4", "Mouse4 should be accepted")
    k:SetSilent("Mouse5")
    assertEq(k:Get(), "Mouse5", "Mouse5 should be accepted")
end)

-- =========================================================================
-- Toggle :AddKeybind tests
-- =========================================================================

test("Toggle :AddKeybind attaches an inline keybind picker", function()
    local kbFired
    local t = Workspace:CreateToggle({
        Name         = "toggle+kb:attach",
        CurrentValue = false,
        Callback     = function() end,
    }):AddKeybind({
        CurrentKeybind = "X",
        Callback       = function(k) kbFired = k end,
    })
    assertEq(t:GetKeybind(), "X", "initial keybind")
    t:SetKeybind("Y"); task.wait()
    assertEq(t:GetKeybind(), "Y", "after SetKeybind")
    assertEq(kbFired, "Y", "keybind callback fired with new value")
end)

test("Toggle :AddKeybind second call warns and preserves existing binding", function()
    local t = Workspace:CreateToggle({
        Name         = "toggle+kb:double",
        CurrentValue = false,
        Callback     = function() end,
    }):AddKeybind({
        CurrentKeybind = "A",
        Callback       = function() end,
    })
    -- Second call should no-op (with a warn); first binding stays intact.
    t:AddKeybind({
        CurrentKeybind = "B",
        Callback       = function() error("second callback should not be installed") end,
    })
    assertEq(t:GetKeybind(), "A", "binding should remain at the first AddKeybind value")
end)

test("Toggle with inline keybind keeps toggle :Get/:Set working", function()
    local t = Workspace:CreateToggle({
        Name         = "toggle+kb:state",
        CurrentValue = true,
        Callback     = function() end,
    }):AddKeybind({
        CurrentKeybind = "C",
        Callback       = function() end,
    })
    assertEq(t:Get(), true, "toggle Get after AddKeybind")
    t:Set(false); task.wait()
    assertEq(t:Get(), false, "toggle Set after AddKeybind")
    assertEq(t:GetKeybind(), "C", "keybind still at original value")
end)

test("Toggle :SetKeybindSilent updates binding without firing the callback", function()
    local fired = false
    local t = Workspace:CreateToggle({
        Name         = "toggle+kb:silent",
        CurrentValue = false,
        Callback     = function() end,
    }):AddKeybind({
        CurrentKeybind = "A",
        Callback       = function() fired = true end,
    })
    t:SetKeybindSilent("B"); task.wait()
    assertEq(t:GetKeybind(), "B", "binding updated")
    assertEq(fired, false, "callback should NOT fire on silent")
end)

-- =========================================================================
-- ColorPicker tests
-- =========================================================================

test("ColorPicker :Get returns the initial color", function()
    local cp = Workspace:CreateColorPicker({
        Name         = "cp:init",
        CurrentColor = Color3.fromRGB(255, 140, 60),
        Callback     = function() end,
    })
    assertColorEq(cp:Get(), Color3.fromRGB(255, 140, 60), nil, "initial Get")
end)

test("ColorPicker defaults to white when CurrentColor is omitted", function()
    local cp = Workspace:CreateColorPicker({
        Name     = "cp:default",
        Callback = function() end,
    })
    assertColorEq(cp:Get(), Color3.fromRGB(255, 255, 255), nil, "default should be white")
end)

test("ColorPicker :Set updates color and fires callback", function()
    local fired
    local cp = Workspace:CreateColorPicker({
        Name         = "cp:set",
        CurrentColor = Color3.fromRGB(255, 255, 255),
        Callback     = function(c) fired = c end,
    })
    cp:Set(Color3.fromRGB(80, 180, 255)); task.wait()
    assertColorEq(cp:Get(), Color3.fromRGB(80, 180, 255), nil, "after Set")
    if typeof(fired) ~= "Color3" then
        error("callback should receive a Color3, got " .. typeof(fired))
    end
    assertColorEq(fired, Color3.fromRGB(80, 180, 255), nil, "callback value")
end)

test("ColorPicker :SetSilent updates without firing the callback", function()
    local fired = false
    local cp = Workspace:CreateColorPicker({
        Name         = "cp:silent",
        CurrentColor = Color3.fromRGB(0, 0, 0),
        Callback     = function() fired = true end,
    })
    cp:SetSilent(Color3.fromRGB(200, 50, 50)); task.wait()
    assertColorEq(cp:Get(), Color3.fromRGB(200, 50, 50), nil, "value updated")
    assertEq(fired, false, "callback should NOT fire on SetSilent")
end)

test("ColorPicker :Set silently ignores non-Color3 values", function()
    local cp = Workspace:CreateColorPicker({
        Name         = "cp:typecheck",
        CurrentColor = Color3.fromRGB(50, 100, 150),
        Callback     = function() end,
    })
    cp:Set("not a color")
    cp:Set(42)
    cp:Set(nil)
    assertColorEq(cp:Get(), Color3.fromRGB(50, 100, 150), nil,
        "color should be unchanged after non-Color3 Set calls")
end)

-- =========================================================================
-- FovCircle tests
-- =========================================================================
-- Each test creates its own circle and destroys it at the end so the
-- screen doesn't end up with a stack of overlays when the run is over.

test("FovCircle :GetRadius returns the initial radius", function()
    local fc = UI:CreateFovCircle({ Radius = 120, Visible = false })
    assertEq(fc:GetRadius(), 120, "initial GetRadius")
    fc:Destroy()
end)

test("FovCircle defaults to radius 100 when omitted", function()
    local fc = UI:CreateFovCircle({ Visible = false })
    assertEq(fc:GetRadius(), 100, "default radius")
    fc:Destroy()
end)

test("FovCircle :SetRadius updates and clamps negatives to 0", function()
    local fc = UI:CreateFovCircle({ Radius = 50, Visible = false })
    fc:SetRadius(200)
    assertEq(fc:GetRadius(), 200, "after SetRadius(200)")
    fc:SetRadius(-5)
    assertEq(fc:GetRadius(), 0, "negative radius clamped to 0")
    fc:Destroy()
end)

test("FovCircle :SetRadius ignores non-number input", function()
    local fc = UI:CreateFovCircle({ Radius = 75, Visible = false })
    fc:SetRadius("wide")
    fc:SetRadius(nil)
    fc:SetRadius({})
    assertEq(fc:GetRadius(), 75, "radius unchanged after bad inputs")
    fc:Destroy()
end)

test("FovCircle :GetColor returns initial and :SetColor updates", function()
    local fc = UI:CreateFovCircle({
        Color = Color3.fromRGB(255, 140, 60),
        Visible = false,
    })
    assertColorEq(fc:GetColor(), Color3.fromRGB(255, 140, 60), nil, "initial GetColor")
    fc:SetColor(Color3.fromRGB(80, 180, 255))
    assertColorEq(fc:GetColor(), Color3.fromRGB(80, 180, 255), nil, "after SetColor")
    fc:Destroy()
end)

test("FovCircle :SetColor ignores non-Color3 input", function()
    local original = Color3.fromRGB(120, 200, 120)
    local fc = UI:CreateFovCircle({ Color = original, Visible = false })
    fc:SetColor("red")
    fc:SetColor(42)
    fc:SetColor(nil)
    assertColorEq(fc:GetColor(), original, nil, "color unchanged after bad inputs")
    fc:Destroy()
end)

test("FovCircle :SetVisible and :IsVisible toggle cleanly", function()
    local fc = UI:CreateFovCircle({ Visible = false })
    assertEq(fc:IsVisible(), false, "initial (Visible = false)")
    fc:SetVisible(true)
    assertEq(fc:IsVisible(), true, "after SetVisible(true)")
    fc:SetVisible(false)
    assertEq(fc:IsVisible(), false, "after SetVisible(false)")
    fc:Destroy()
end)

test("FovCircle defaults Visible to true when omitted", function()
    local fc = UI:CreateFovCircle({ Radius = 10 })  -- Visible omitted
    assertEq(fc:IsVisible(), true, "default visibility")
    fc:SetVisible(false)  -- hide so it doesn't pile on screen
    fc:Destroy()
end)

test("FovCircle :SetFilled and :IsFilled toggle cleanly", function()
    local fc = UI:CreateFovCircle({ Visible = false })
    assertEq(fc:IsFilled(), false, "default Filled = false")
    fc:SetFilled(true)
    assertEq(fc:IsFilled(), true, "after SetFilled(true)")
    fc:SetFilled(false)
    assertEq(fc:IsFilled(), false, "after SetFilled(false)")
    fc:Destroy()
end)

test("FovCircle :SetFillTransparency clamps to [0, 1]", function()
    local fc = UI:CreateFovCircle({ Visible = false })
    fc:SetFillTransparency(0.3)
    assertApprox(fc:GetFillTransparency(), 0.3, 1e-6, "in-range")
    fc:SetFillTransparency(-2)
    assertApprox(fc:GetFillTransparency(), 0, 1e-6, "below-range clamped to 0")
    fc:SetFillTransparency(5)
    assertApprox(fc:GetFillTransparency(), 1, 1e-6, "above-range clamped to 1")
    fc:Destroy()
end)

test("FovCircle :Destroy is idempotent and setters no-op after", function()
    local fc = UI:CreateFovCircle({ Radius = 60, Visible = false })
    fc:Destroy()
    fc:Destroy()  -- second call must not error
    -- Setters after destroy should silently no-op; getters return the
    -- last value the handle recorded (nothing throws).
    fc:SetRadius(999)
    fc:SetColor(Color3.fromRGB(1, 2, 3))
    fc:SetVisible(true)
    assertEq(fc:GetRadius(), 60, "radius should not change after destroy")
end)

-- =========================================================================
-- Button / Label / Paragraph updater tests
-- =========================================================================

test("Button :SetText updates without erroring", function()
    local b = Workspace:CreateButton({
        Name     = "btn:initial",
        Callback = function() end,
    })
    b:SetText("btn:updated")  -- visual change only; no :Get to verify
end)

test("Button with Confirm mode constructs without erroring", function()
    Workspace:CreateButton({
        Name     = "btn:confirm",
        Confirm  = true,
        Callback = function() end,
    })
end)

test("Label :SetText and :SetColor update without erroring", function()
    local l = Workspace:CreateLabel({ Text = "label:initial" })
    l:SetText("label:updated")
    l:SetColor(Color3.fromRGB(255, 200, 0))
end)

test("Paragraph :SetTitle and :SetContent update without erroring", function()
    local p = Workspace:CreateParagraph({
        Title   = "para:title",
        Content = "para:initial content",
    })
    p:SetTitle("para:updated title")
    p:SetContent("para:updated content with a much longer body that should wrap across multiple lines when rendered.")
end)

-- =========================================================================
-- Notification test
-- =========================================================================

test("UI:Notify fires a toast without erroring", function()
    UI:Notify({
        Title    = "Self-test notification",
        Content  = "If you can see this toast, UI:Notify is working.",
        Duration = 3,
    })
end)

-- =========================================================================
-- Window lifecycle tests (use throwaway second/third windows so the main
-- self-test window stays visible)
-- =========================================================================

test("Window:OnClose fires synchronously on Destroy", function()
    local closeFired = false
    local sink = UI:CreateWindow({
        Name   = "OvertimeUI Self-Test Sink",
        Accent = Color3.fromRGB(220, 80, 80),
    })
    assert(sink, "failed to create sink window")
    sink:OnClose(function() closeFired = true end)
    sink:Destroy()
    assertEq(closeFired, true, "OnClose should have fired during Destroy")
end)

test("Window with multiple OnClose callbacks fires them all", function()
    local a, b, c = false, false, false
    local sink = UI:CreateWindow({
        Name   = "OvertimeUI Self-Test Sink 2",
        Accent = Color3.fromRGB(80, 180, 90),
    })
    assert(sink, "failed to create sink window")
    sink:OnClose(function() a = true end)
    sink:OnClose(function() b = true end)
    sink:OnClose(function() c = true end)
    sink:Destroy()
    assertEq(a, true, "first callback")
    assertEq(b, true, "second callback")
    assertEq(c, true, "third callback")
end)

test("CreateWindow with an existing marker returns nil and tears the old one down", function()
    local closeFired = false
    local first = UI:CreateWindow({ Name = "OvertimeUI Self-Test Rerun" })
    assert(first, "first CreateWindow should return a window")
    first:OnClose(function() closeFired = true end)
    -- Second CreateWindow under the same name should destroy the marker,
    -- which fires the Destroying hook, which tears the first window down
    -- and fires its OnClose callbacks — all before the second call returns.
    local second = UI:CreateWindow({ Name = "OvertimeUI Self-Test Rerun" })
    assertEq(second, nil, "second CreateWindow should return nil")
    assertEq(closeFired, true, "first window's OnClose should have fired")
end)

test("Window:Destroy is idempotent", function()
    local fires = 0
    local sink = UI:CreateWindow({ Name = "OvertimeUI Self-Test Idempotent" })
    assert(sink, "failed to create sink window")
    sink:OnClose(function() fires = fires + 1 end)
    sink:Destroy()
    sink:Destroy()  -- should not fire the callback again
    sink:Destroy()
    assertEq(fires, 1, "OnClose should fire exactly once even on repeated Destroy")
end)

-- =========================================================================
-- Publish results
-- =========================================================================

print("")
print(string.format("=== Self-test summary ===   Passed: %d   Failed: %d", passed, failed))
if failed > 0 then
    print("Failures:")
    for _, line in ipairs(failureLog) do print("  " .. line) end
end

statusLabel:SetText(string.format("Tests done — Passed: %d   Failed: %d", passed, failed))
if failed == 0 then
    statusLabel:SetColor(Color3.fromRGB(80, 220, 120))
    summaryPara:SetTitle("✓ All tests passed")
    summaryPara:SetContent(string.format(
        "All %d automated tests passed. Every Window / Tab / Section / Toggle / "
        .. "Slider / Dropdown / Keybind / ColorPicker / FovCircle / Button / Label / "
        .. "Paragraph / Notify / lifecycle assertion succeeded. The test artifacts "
        .. "below show the final state of every control the suite exercised.", passed))
    UI:Notify({
        Title    = "OvertimeUI self-test",
        Content  = string.format("All %d tests passed", passed),
        Duration = 5,
    })
else
    statusLabel:SetColor(Color3.fromRGB(220, 80, 80))
    summaryPara:SetTitle("✗ Self-test failed")
    local body = string.format("%d of %d tests failed:\n\n", failed, passed + failed)
    for _, line in ipairs(failureLog) do
        body = body .. "• " .. line .. "\n"
    end
    summaryPara:SetContent(body)
    UI:Notify({
        Title    = "OvertimeUI self-test FAILED",
        Content  = string.format("%d test(s) failed — see Console and Results", failed),
        Duration = 10,
        Accent   = Color3.fromRGB(220, 80, 80),
    })
end

Window:OnClose(function()
    print("[UI_Test] Window closed")
end)

print("[UI_Test] Self-test complete.")
