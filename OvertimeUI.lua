-- OvertimeUI — a Roblox-side UI library for scripts run under the Overtime Executor.
--
-- Phase 2 scope: Window / Tab / Section / Toggle / Keybind. Phase 3 will add
-- Slider / Dropdown / Button / Label / Paragraph / Notification.
--
-- Load pattern (scripts put this as their first non-comment line):
--     local UI = loadstring(readfile("OvertimeUI.lua"))()
--
-- If the marker for a given window name is already present on the LocalPlayer
-- (meaning an earlier run is still active) CreateWindow destroys the marker
-- — which triggers the old window's own cleanup via its Destroying hook —
-- and returns nil so the script can bail with `if not Window then return end`.
-- That gives the same toggle-off-by-re-running UX the three production
-- scripts already rely on.
--
-- The library owns the ScreenGui, the marker, all adornments, every
-- connection, and the drag handler. Consumers only see handles: a Window
-- from CreateWindow, Tabs from Window:CreateTab, Sections from
-- Tab:CreateSection, and control handles from Section:CreateX. Every
-- control handle supports :Set, :Get, :Destroy where applicable.
--
-- Keybind controls store their binding as a STRING identifier that can
-- name any keyboard KeyCode ("Q", "LeftShift", "F1"), any of the three
-- standard mouse buttons ("MouseButton1"/2/3), or the mouse X buttons
-- ("Mouse4"/"Mouse5"). Keyboard and MB1/2/3 dispatch through Roblox's
-- UserInputService; Mouse4/Mouse5 dispatch through the executor's
-- /input/mouse_ex bridge (isMouse4Down / isMouse5Down). A 50ms cache
-- sits in front of the X-button calls so per-frame IsHeld() polling
-- from scripts only hits the HTTP bridge 20 times per second.

local OvertimeUI = {}
OvertimeUI._VERSION = "0.1.0"

-- =========================================================================
-- Services & shared state
-- =========================================================================

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local LP         = Players.LocalPlayer

local FONT        = Enum.Font.Gotham
local FONT_BOLD   = Enum.Font.GothamBold
local FONT_SEMI   = Enum.Font.GothamMedium

-- Default theme. Individual windows can override `accent` via the Accent
-- field in CreateWindow config. Everything else is shared.
local function defaultTheme()
    return {
        bg          = Color3.fromRGB(14, 16, 22),
        bgAlt       = Color3.fromRGB(18, 21, 28),
        surface     = Color3.fromRGB(28, 32, 42),
        surfaceHi   = Color3.fromRGB(36, 41, 54),
        border      = Color3.fromRGB(48, 54, 68),
        accent      = Color3.fromRGB(90, 180, 255),
        text        = Color3.fromRGB(232, 234, 242),
        textDim     = Color3.fromRGB(150, 156, 170),
        danger      = Color3.fromRGB(220, 80, 80),
    }
end

-- =========================================================================
-- Mouse X-button cache
-- =========================================================================
-- isMouse4Down / isMouse5Down go through the executor's HTTP bridge. That's
-- cheap (~1-2ms) but not free, and per-frame aimbot-style IsHeld() polling
-- would bang on it at 60+ Hz unnecessarily. Cache at 50ms so callers get
-- a fresh value roughly every 3 frames at 60 FPS, with the HTTP round-trip
-- amortised across all keybinds that share the cache.

local mouseExCache = { t = 0, m4 = false, m5 = false }
local function pollMouseEx()
    local now = tick()
    if now - mouseExCache.t < 0.05 then return end
    mouseExCache.t = now
    local m4, m5 = false, false
    pcall(function()
        if isMouse4Down then m4 = isMouse4Down() end
        if isMouse5Down then m5 = isMouse5Down() end
    end)
    mouseExCache.m4 = m4
    mouseExCache.m5 = m5
end

-- =========================================================================
-- Keybind spec helpers
-- =========================================================================
-- A keybind string is either "None"/""/"Unknown" (unbound), a mouse button
-- name ("MouseButton1"/2/3 / "Mouse4" / "Mouse5"), or an Enum.KeyCode name
-- ("Q", "LeftShift", "F1", etc.). The helpers convert to/from that string.

local function isKeybindHeld(keyStr)
    if not keyStr or keyStr == "" or keyStr == "None" or keyStr == "Unknown" then
        return false
    end
    if keyStr == "MouseButton1" then
        return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
    elseif keyStr == "MouseButton2" then
        return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    elseif keyStr == "MouseButton3" then
        return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton3)
    elseif keyStr == "Mouse4" then
        pollMouseEx()
        return mouseExCache.m4
    elseif keyStr == "Mouse5" then
        pollMouseEx()
        return mouseExCache.m5
    end
    local keycode = Enum.KeyCode[keyStr]
    if keycode then
        return UIS:IsKeyDown(keycode)
    end
    return false
end

local function keybindLabel(keyStr)
    if not keyStr or keyStr == "" or keyStr == "None" or keyStr == "Unknown" then
        return "None"
    end
    if keyStr == "MouseButton1" then return "LMB" end
    if keyStr == "MouseButton2" then return "RMB" end
    if keyStr == "MouseButton3" then return "MMB" end
    if keyStr == "Mouse4"       then return "MB4" end
    if keyStr == "Mouse5"       then return "MB5" end
    return keyStr
end

-- Converts a Roblox InputObject into our string form. Returns nil for
-- input types we don't handle (touch, gamepad, focus, etc.).
local function inputObjectToKeybind(input)
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseButton1 then return "MouseButton1" end
    if t == Enum.UserInputType.MouseButton2 then return "MouseButton2" end
    if t == Enum.UserInputType.MouseButton3 then return "MouseButton3" end
    if t == Enum.UserInputType.Keyboard and input.KeyCode ~= Enum.KeyCode.Unknown then
        return input.KeyCode.Name
    end
    return nil
end

-- =========================================================================
-- Tiny UI primitives — Create("Frame", {...}) etc.
-- =========================================================================

local function Create(class, props)
    local inst = Instance.new(class)
    if props then
        for k, v in pairs(props) do
            if k ~= "Parent" then inst[k] = v end
        end
        if props.Parent then inst.Parent = props.Parent end
    end
    return inst
end

local function corner(parent, radius)
    return Create("UICorner", { CornerRadius = UDim.new(0, radius or 6), Parent = parent })
end

local function stroke(parent, color, thickness)
    return Create("UIStroke", { Color = color, Thickness = thickness or 1, Parent = parent })
end

-- =========================================================================
-- Shared keybind button builder
-- =========================================================================
-- Used by Section:CreateKeybind (a full row with a name label + a keybind
-- button on the right) AND by Toggle:AddKeybind (a keybind button dropped
-- onto an existing toggle row). Factored out so the rebind picker logic,
-- the Mouse4/5 polling path, the 100ms opening-click debounce, and the
-- cleanup registration all live in one place.
--
-- Returns a small control table with:
--   .button  -- the TextButton itself, in case the caller needs it
--   .get()   -- current keybind string
--   .set(v, fireCallback) -- change the binding; fireCallback bool
--   .isHeld()            -- current hold state
--   .cleanup()            -- disconnect any in-flight rebind listeners
local function buildKeybindControl(theme, parent, initialKey, position, size, onKeyChanged)
    local keyStr = initialKey or "None"
    local rebinding = false
    local rebindOpened = 0
    local rebindConns = {}

    local btn = Create("TextButton", {
        Size = size or UDim2.fromOffset(56, 18),
        Position = position or UDim2.new(1, -60, 0.5, -9),
        BackgroundColor3 = theme.surface,
        BorderSizePixel = 0,
        Text = keybindLabel(keyStr),
        TextColor3 = theme.accent,
        Font = FONT_SEMI,
        TextSize = 11,
        AutoButtonColor = false,
        Parent = parent,
    })
    corner(btn, 3)
    stroke(btn, theme.border, 1)

    local function stopRebind()
        rebinding = false
        for _, c in ipairs(rebindConns) do c:Disconnect() end
        table.clear(rebindConns)
    end

    local function applyKey(newKey, fireCallback)
        keyStr = newKey or "None"
        btn.Text = keybindLabel(keyStr)
        btn.TextColor3 = theme.accent
        if fireCallback and onKeyChanged then
            task.spawn(onKeyChanged, keyStr)
        end
    end

    local function startRebind()
        if rebinding then return end
        rebinding = true
        rebindOpened = tick()
        btn.Text = "..."
        btn.TextColor3 = theme.danger

        table.insert(rebindConns, UIS.InputBegan:Connect(function(input, gpe)
            if gpe then return end
            if tick() - rebindOpened < 0.1 then return end
            local captured = inputObjectToKeybind(input)
            if captured then
                stopRebind()
                applyKey(captured, true)
            end
        end))

        table.insert(rebindConns, RunService.Heartbeat:Connect(function()
            if not rebinding then return end
            if tick() - rebindOpened < 0.1 then return end
            pollMouseEx()
            if mouseExCache.m4 then
                stopRebind()
                applyKey("Mouse4", true)
            elseif mouseExCache.m5 then
                stopRebind()
                applyKey("Mouse5", true)
            end
        end))
    end

    btn.MouseButton1Click:Connect(startRebind)

    return {
        button  = btn,
        get     = function() return keyStr end,
        set     = function(v, fire) applyKey(v, fire) end,
        isHeld  = function() return isKeybindHeld(keyStr) end,
        cleanup = stopRebind,
    }
end

-- =========================================================================
-- Section
-- =========================================================================

local Section = {}
Section.__index = Section

function Section:CreateToggle(cfg)
    cfg = cfg or {}
    local window = self.tab.window
    local theme  = window.theme

    local state = cfg.CurrentValue == true
    local handle = {
        Type = "Toggle",
        Name = cfg.Name or "Toggle",
    }

    local row = Create("TextButton", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        LayoutOrder = self:_next(),
        Parent = self.container,
    })

    local box = Create("Frame", {
        Size = UDim2.fromOffset(14, 14),
        Position = UDim2.new(0, 2, 0.5, -7),
        BackgroundColor3 = state and theme.accent or theme.surface,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(box, 3)
    stroke(box, theme.border, 1)

    local check = Create("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "✓",
        TextColor3 = Color3.new(1, 1, 1),
        Font = FONT_BOLD,
        TextSize = 11,
        Visible = state,
        Parent = box,
    })

    local label = Create("TextLabel", {
        Size = UDim2.new(1, -26, 1, 0),
        Position = UDim2.new(0, 26, 0, 0),
        BackgroundTransparency = 1,
        Text = cfg.Name or "Toggle",
        TextColor3 = theme.text,
        Font = FONT,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })

    local function setState(v, fireCallback)
        v = not not v
        if v == state then return end
        state = v
        box.BackgroundColor3 = state and theme.accent or theme.surface
        check.Visible = state
        if fireCallback and cfg.Callback then
            task.spawn(cfg.Callback, state)
        end
    end

    row.MouseButton1Click:Connect(function() setState(not state, true) end)

    function handle:Get() return state end
    function handle:Set(v) setState(v, true) end
    function handle:SetSilent(v) setState(v, false) end

    -- Inline keybind (Linoria-style). Calling :AddKeybind{...} on a toggle
    -- handle attaches a small keybind button to the right side of the same
    -- row and wires in the same rebind picker the standalone Keybind
    -- control uses. The returned handle is the SAME toggle handle, just
    -- with extra methods bolted on — so scripts can write:
    --
    --     local Aim = Section:CreateToggle{Name="Aimbot", ...}:AddKeybind{
    --         CurrentKeybind = "MouseButton2",
    --         Callback = function(k) S.AimKey = k end,
    --     }
    --     if Aim:Get() and Aim:IsKeybindHeld() then ... end
    --
    -- Calling AddKeybind twice on the same toggle is a no-op with a warn.
    local kbCtrl -- filled in if AddKeybind is called
    function handle:AddKeybind(kbCfg)
        if kbCtrl then
            warn("[OvertimeUI] AddKeybind called twice on toggle '" .. tostring(cfg.Name) .. "'")
            return self
        end
        kbCfg = kbCfg or {}
        -- Shrink the label so it doesn't overlap the button
        label.Size = UDim2.new(1, -26 - 64, 1, 0)
        kbCtrl = buildKeybindControl(
            theme, row,
            kbCfg.CurrentKeybind or "None",
            UDim2.new(1, -60, 0.5, -9),
            UDim2.fromOffset(56, 18),
            kbCfg.Callback
        )
        table.insert(window._cleanup, kbCtrl.cleanup)

        function self:GetKeybind()      return kbCtrl.get() end
        function self:SetKeybind(v)     kbCtrl.set(v, true) end
        function self:SetKeybindSilent(v) kbCtrl.set(v, false) end
        function self:IsKeybindHeld()   return kbCtrl.isHeld() end
        return self
    end

    return handle
end

function Section:CreateKeybind(cfg)
    cfg = cfg or {}
    local window = self.tab.window
    local theme  = window.theme

    local handle = {
        Type = "Keybind",
        Name = cfg.Name or "Keybind",
    }

    local row = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })

    Create("TextLabel", {
        Size = UDim2.new(1, -64, 1, 0),
        Position = UDim2.new(0, 2, 0, 0),
        BackgroundTransparency = 1,
        Text = cfg.Name or "Keybind",
        TextColor3 = theme.text,
        Font = FONT,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })

    local ctrl = buildKeybindControl(
        theme, row,
        cfg.CurrentKeybind or "None",
        UDim2.new(1, -60, 0.5, -9),
        UDim2.fromOffset(56, 18),
        cfg.Callback
    )
    table.insert(window._cleanup, ctrl.cleanup)

    function handle:Get()       return ctrl.get() end
    function handle:Set(v)      ctrl.set(v, true) end
    function handle:SetSilent(v) ctrl.set(v, false) end
    function handle:IsHeld()    return ctrl.isHeld() end

    return handle
end

-- =========================================================================
-- Slider
-- =========================================================================
-- Horizontal drag-to-set bar. Config:
--   Name         = "FOV"
--   Range        = {min, max}
--   Increment    = 1 (or 0.01 for finer steps; formats float vs int)
--   CurrentValue = 6
--   Suffix       = "°" (optional; appended to the live value display)
--   Callback     = function(value) ... end
-- Returns a handle with :Get(), :Set(v), :SetSilent(v).
function Section:CreateSlider(cfg)
    cfg = cfg or {}
    local window = self.tab.window
    local theme  = window.theme

    local minVal = (cfg.Range and cfg.Range[1]) or 0
    local maxVal = (cfg.Range and cfg.Range[2]) or 100
    local step   = cfg.Increment or 1
    local value  = cfg.CurrentValue or minVal
    local suffix = cfg.Suffix or ""

    local handle = { Type = "Slider", Name = cfg.Name or "Slider" }

    local row = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundTransparency = 1,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })

    local nameLbl = Create("TextLabel", {
        Size = UDim2.new(1, -80, 0, 14),
        Position = UDim2.new(0, 2, 0, 0),
        BackgroundTransparency = 1,
        Text = cfg.Name or "Slider",
        TextColor3 = theme.text,
        Font = FONT,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })

    local valLbl = Create("TextLabel", {
        Size = UDim2.new(0, 80, 0, 14),
        Position = UDim2.new(1, -82, 0, 0),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = theme.accent,
        Font = FONT_SEMI,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = row,
    })

    -- Track (background) and fill (foreground). The fill is a child of the
    -- track, sized 0..1 scale proportional to (value-min)/(max-min).
    local track = Create("Frame", {
        Size = UDim2.new(1, -4, 0, 6),
        Position = UDim2.new(0, 2, 0, 22),
        BackgroundColor3 = theme.surface,
        BorderSizePixel = 0,
        Active = true, -- required for InputBegan to fire on the track
        Parent = row,
    })
    corner(track, 3)

    local fill = Create("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = theme.accent,
        BorderSizePixel = 0,
        Parent = track,
    })
    corner(fill, 3)

    -- Formats a value for display. Integer step -> integer; sub-integer
    -- step -> two decimal places (enough precision for 0.01 increments
    -- without trailing noise from floating point).
    local function formatValue(v)
        if step >= 1 then
            return string.format("%d%s", math.floor(v + 0.5), suffix)
        end
        return string.format("%.2f%s", v, suffix)
    end

    local function setValue(v, fireCallback)
        v = math.clamp(v, minVal, maxVal)
        -- Snap to the nearest increment.
        if step > 0 then
            v = math.floor((v - minVal) / step + 0.5) * step + minVal
            v = math.clamp(v, minVal, maxVal)
        end
        if v == value and valLbl.Text ~= "" then return end
        value = v
        local pct = (maxVal > minVal) and ((v - minVal) / (maxVal - minVal)) or 0
        fill.Size = UDim2.new(pct, 0, 1, 0)
        valLbl.Text = formatValue(v)
        if fireCallback and cfg.Callback then
            task.spawn(cfg.Callback, v)
        end
    end
    setValue(value, false)

    -- Drag handling. Track InputBegan seeds the drag state and snaps the
    -- value to the click position; UIS.InputChanged updates while dragging.
    -- The UIS connection is stored on _cleanup so it's disconnected when
    -- the window is destroyed.
    local dragging = false
    local function updateFromInput(input)
        local relX = input.Position.X - track.AbsolutePosition.X
        local pct = math.clamp(relX / math.max(track.AbsoluteSize.X, 1), 0, 1)
        setValue(minVal + pct * (maxVal - minVal), true)
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            updateFromInput(input)
        end
    end)
    track.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    local moveConn = UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                      or input.UserInputType == Enum.UserInputType.Touch) then
            updateFromInput(input)
        end
    end)
    -- Also catch mouse-up outside the track so dragging doesn't stick on
    -- if the user releases while the cursor has left the bar.
    local releaseConn = UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    table.insert(window._cleanup, function()
        dragging = false
        moveConn:Disconnect()
        releaseConn:Disconnect()
    end)

    function handle:Get() return value end
    function handle:Set(v) setValue(v, true) end
    function handle:SetSilent(v) setValue(v, false) end

    return handle
end

-- =========================================================================
-- Dropdown
-- =========================================================================
-- Single-select dropdown. Config:
--   Name          = "Target Part"
--   Options       = {"Head", "UpperTorso", ...}
--   CurrentOption = "Head"
--   Callback      = function(option) ... end
-- The popup is parented to the window's ScreenGui (not the panel) so it
-- can extend outside the panel bounds. A full-screen transparent backdrop
-- captures click-outside-to-close.
function Section:CreateDropdown(cfg)
    cfg = cfg or {}
    local window = self.tab.window
    local theme  = window.theme
    local gui    = window.gui

    local options = cfg.Options or {}
    local current = cfg.CurrentOption or options[1] or ""

    local handle = { Type = "Dropdown", Name = cfg.Name or "Dropdown" }

    local row = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 38),
        BackgroundTransparency = 1,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })

    Create("TextLabel", {
        Size = UDim2.new(1, -4, 0, 14),
        Position = UDim2.new(0, 2, 0, 0),
        BackgroundTransparency = 1,
        Text = cfg.Name or "Dropdown",
        TextColor3 = theme.text,
        Font = FONT,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })

    local btn = Create("TextButton", {
        Size = UDim2.new(1, -4, 0, 20),
        Position = UDim2.new(0, 2, 0, 16),
        BackgroundColor3 = theme.surface,
        BorderSizePixel = 0,
        Text = " " .. tostring(current) .. "   ▼",
        TextColor3 = theme.text,
        Font = FONT,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = false,
        Parent = row,
    })
    corner(btn, 4)
    stroke(btn, theme.border, 1)

    local popupOpen = false
    local popupBackdrop -- created on open, destroyed on close
    local popupFrame

    local function closePopup()
        popupOpen = false
        if popupBackdrop then
            popupBackdrop:Destroy()
            popupBackdrop = nil
            popupFrame = nil
        end
    end

    local function rebuildButtonLabel()
        btn.Text = " " .. tostring(current) .. "   ▼"
    end

    local function setOption(v, fireCallback)
        current = v
        rebuildButtonLabel()
        if fireCallback and cfg.Callback then
            task.spawn(cfg.Callback, v)
        end
    end

    local function openPopup()
        if popupOpen then return end
        popupOpen = true

        -- Full-screen backdrop catches clicks outside the popup.
        popupBackdrop = Create("TextButton", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "",
            AutoButtonColor = false,
            ZIndex = 50,
            Parent = gui,
        })
        popupBackdrop.MouseButton1Click:Connect(closePopup)

        -- Popup frame sits directly below the dropdown button. Width
        -- matches the button's AbsoluteSize; height grows with options.
        local optHeight = 22
        local totalH = math.min(#options, 8) * optHeight + 4
        popupFrame = Create("Frame", {
            Size = UDim2.fromOffset(btn.AbsoluteSize.X, totalH),
            Position = UDim2.fromOffset(btn.AbsolutePosition.X, btn.AbsolutePosition.Y + btn.AbsoluteSize.Y + 2),
            BackgroundColor3 = theme.bgAlt,
            BorderSizePixel = 0,
            ZIndex = 51,
            Parent = popupBackdrop,
        })
        corner(popupFrame, 4)
        stroke(popupFrame, theme.border, 1)

        local scroll = Create("ScrollingFrame", {
            Size = UDim2.new(1, -4, 1, -4),
            Position = UDim2.fromOffset(2, 2),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = theme.border,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ZIndex = 52,
            Parent = popupFrame,
        })
        Create("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 2),
            Parent = scroll,
        })

        for i, opt in ipairs(options) do
            local optBtn = Create("TextButton", {
                Size = UDim2.new(1, 0, 0, 20),
                BackgroundColor3 = (opt == current) and theme.surfaceHi or theme.surface,
                BorderSizePixel = 0,
                Text = " " .. tostring(opt),
                TextColor3 = (opt == current) and theme.accent or theme.text,
                Font = FONT,
                TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Left,
                AutoButtonColor = false,
                LayoutOrder = i,
                ZIndex = 53,
                Parent = scroll,
            })
            corner(optBtn, 3)
            optBtn.MouseButton1Click:Connect(function()
                setOption(opt, true)
                closePopup()
            end)
        end
    end

    btn.MouseButton1Click:Connect(function()
        if popupOpen then closePopup() else openPopup() end
    end)

    -- Tear down any open popup when the window goes away.
    table.insert(window._cleanup, closePopup)

    function handle:Get() return current end
    function handle:Set(v)       setOption(v, true) end
    function handle:SetSilent(v) setOption(v, false) end
    function handle:Refresh(newOptions, newCurrent)
        options = newOptions or {}
        if newCurrent ~= nil then
            current = newCurrent
        elseif not table.find(options, current) then
            current = options[1] or ""
        end
        rebuildButtonLabel()
        closePopup()
    end

    return handle
end

-- =========================================================================
-- Button
-- =========================================================================
-- Single-action button. Config:
--   Name     = "Unload"
--   Callback = function() ... end
--   Confirm  = true  (optional; first click asks "Click again to confirm"
--                     for 500ms, second click fires, timeout resets)
function Section:CreateButton(cfg)
    cfg = cfg or {}
    local theme = self.tab.window.theme

    local handle = { Type = "Button", Name = cfg.Name or "Button" }

    local btn = Create("TextButton", {
        Size = UDim2.new(1, -4, 0, 26),
        BackgroundColor3 = theme.surface,
        BorderSizePixel = 0,
        Text = cfg.Name or "Button",
        TextColor3 = theme.text,
        Font = FONT_SEMI,
        TextSize = 12,
        AutoButtonColor = false,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })
    corner(btn, 4)
    stroke(btn, theme.border, 1)

    local armedForConfirm = false
    local armedUntil = 0

    btn.MouseEnter:Connect(function() btn.BackgroundColor3 = theme.surfaceHi end)
    btn.MouseLeave:Connect(function()
        if not armedForConfirm then btn.BackgroundColor3 = theme.surface end
    end)

    btn.MouseButton1Click:Connect(function()
        if cfg.Confirm then
            if armedForConfirm and tick() < armedUntil then
                armedForConfirm = false
                btn.Text = cfg.Name or "Button"
                btn.BackgroundColor3 = theme.surface
                if cfg.Callback then task.spawn(cfg.Callback) end
                return
            end
            armedForConfirm = true
            armedUntil = tick() + 0.5
            btn.Text = "Click again to confirm"
            btn.BackgroundColor3 = theme.danger
            task.delay(0.5, function()
                if tick() >= armedUntil then
                    armedForConfirm = false
                    btn.Text = cfg.Name or "Button"
                    btn.BackgroundColor3 = theme.surface
                end
            end)
            return
        end
        if cfg.Callback then task.spawn(cfg.Callback) end
    end)

    function handle:SetText(text)
        cfg.Name = text
        if not armedForConfirm then btn.Text = text end
    end

    return handle
end

-- =========================================================================
-- Label — static single-line text row.
-- =========================================================================
function Section:CreateLabel(cfg)
    cfg = cfg or {}
    local theme = self.tab.window.theme
    local color = cfg.Color or theme.textDim

    local lbl = Create("TextLabel", {
        Size = UDim2.new(1, -4, 0, 16),
        BackgroundTransparency = 1,
        Text = cfg.Text or "",
        TextColor3 = color,
        Font = FONT,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = false,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })

    local handle = { Type = "Label" }
    function handle:SetText(text) lbl.Text = text end
    function handle:SetColor(c) lbl.TextColor3 = c end
    return handle
end

-- =========================================================================
-- Paragraph — title + wrapped body block.
-- =========================================================================
function Section:CreateParagraph(cfg)
    cfg = cfg or {}
    local theme = self.tab.window.theme

    local container = Create("Frame", {
        Size = UDim2.new(1, -4, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = theme.surface,
        BorderSizePixel = 0,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })
    corner(container, 5)
    stroke(container, theme.border, 1)

    local pad = Create("UIPadding", {
        PaddingTop    = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
        PaddingLeft   = UDim.new(0, 10),
        PaddingRight  = UDim.new(0, 10),
        Parent = container,
    })

    local layout = Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4),
        Parent = container,
    })

    local title = Create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = cfg.Title or "",
        TextColor3 = theme.accent,
        Font = FONT_BOLD,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = 1,
        Parent = container,
    })

    local body = Create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text = cfg.Content or "",
        TextColor3 = theme.text,
        Font = FONT,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        LayoutOrder = 2,
        Parent = container,
    })

    local handle = { Type = "Paragraph" }
    function handle:SetTitle(t)   title.Text = t end
    function handle:SetContent(c) body.Text = c end
    return handle
end

-- LayoutOrder counter so items show up in the order they were added even
-- though they share a parent UIListLayout.
function Section:_next()
    self._order = (self._order or 0) + 1
    return self._order
end

-- =========================================================================
-- Tab
-- =========================================================================

local Tab = {}
Tab.__index = Tab

function Tab:CreateSection(name)
    local window = self.window
    local theme  = window.theme

    local sectionOrder = self:_next()

    -- Add a bit of extra top padding on sections after the first so
    -- they're visually separated from the section above.
    if sectionOrder > 1 then
        Create("Frame", {
            Size = UDim2.new(1, 0, 0, 8),
            BackgroundTransparency = 1,
            LayoutOrder = sectionOrder * 1000,
            Parent = self.page,
        })
    end

    local header = Create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Text = string.upper(name or "Section"),
        TextColor3 = theme.accent,
        Font = FONT_BOLD,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = sectionOrder * 1000 + 1,
        Parent = self.page,
    })

    -- Container for the section's controls. Uses its own UIListLayout so
    -- the controls stack cleanly under the header.
    local container = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = sectionOrder * 1000 + 2,
        Parent = self.page,
    })
    Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 2),
        Parent = container,
    })

    local section = setmetatable({
        tab = self,
        name = name,
        header = header,
        container = container,
    }, Section)

    table.insert(self.sections, section)
    return section
end

function Tab:_next()
    self._order = (self._order or 0) + 1
    return self._order
end

-- =========================================================================
-- Window
-- =========================================================================

local Window = {}
Window.__index = Window

function Window:CreateTab(name)
    local theme = self.theme

    local tab = setmetatable({
        window = self,
        name = name,
        sections = {},
    }, Tab)

    -- Tab strip button
    local button = Create("TextButton", {
        Size = UDim2.new(1, -8, 0, 28),
        BackgroundColor3 = theme.bgAlt,
        BorderSizePixel = 0,
        Text = "  " .. name,
        TextColor3 = theme.textDim,
        Font = FONT_SEMI,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = false,
        LayoutOrder = #self.tabs + 1,
        Parent = self._tabStrip,
    })
    corner(button, 5)
    tab.button = button

    -- Tab body page (ScrollingFrame so overflowing content can scroll)
    local page = Create("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = theme.border,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false,
        Parent = self._tabBody,
    })
    Create("UIPadding", {
        PaddingTop = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 12),
        PaddingLeft = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 16),
        Parent = page,
    })
    Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 2),
        Parent = page,
    })
    tab.page = page

    button.MouseButton1Click:Connect(function()
        self:SwitchTab(tab)
    end)

    table.insert(self.tabs, tab)
    if not self.activeTab then
        self:SwitchTab(tab)
    end
    return tab
end

function Window:SwitchTab(tab)
    local theme = self.theme
    for _, t in ipairs(self.tabs) do
        local active = (t == tab)
        t.page.Visible = active
        t.button.BackgroundColor3 = active and theme.surface or theme.bgAlt
        t.button.TextColor3 = active and theme.accent or theme.textDim
    end
    self.activeTab = tab
end

function Window:OnClose(cb)
    if type(cb) == "function" then
        table.insert(self.onCloseCallbacks, cb)
    end
end

function Window:Destroy()
    if self._destroyed then return end
    self._destroyed = true
    for _, cb in ipairs(self.onCloseCallbacks) do
        local ok, err = pcall(cb)
        if not ok then warn("[OvertimeUI] OnClose callback error: " .. tostring(err)) end
    end
    for _, cleanup in ipairs(self._cleanup) do
        pcall(cleanup)
    end
    pcall(function() self.gui:Destroy() end)
    -- The marker may already be destroyed (that's how we got here); pcall
    -- shields the re-destroy call from throwing.
    pcall(function()
        if self.marker and self.marker.Parent then self.marker:Destroy() end
    end)
end

-- =========================================================================
-- CreateWindow — public entry point
-- =========================================================================

function OvertimeUI:CreateWindow(cfg)
    cfg = cfg or {}
    local name = cfg.Name or "OvertimeUI"
    local markerName = "_OvertimeUI_" .. name:gsub("[^%w]", "_")

    -- Toggle-off support: if our marker already exists (because the
    -- script is being re-run), destroy it — the old window's Destroying
    -- hook does its own cleanup — and return nil so the script can bail.
    local existing = LP:FindFirstChild(markerName)
    if existing then
        existing:Destroy()
        return nil
    end

    local self = setmetatable({}, Window)
    self.name              = name
    self.theme             = defaultTheme()
    if typeof(cfg.Accent) == "Color3" then self.theme.accent = cfg.Accent end
    self.tabs              = {}
    self.activeTab         = nil
    self.onCloseCallbacks  = {}
    self._cleanup          = {}
    self._destroyed        = false

    -- Marker — owned by the library. The script never needs to touch it.
    local marker = Instance.new("BoolValue")
    marker.Name = markerName
    marker.Parent = LP
    self.marker = marker

    -- Marker-driven toggle-off: re-running the script destroys the marker,
    -- which fires Destroying and tears the window down.
    marker.Destroying:Connect(function() self:Destroy() end)

    -- ScreenGui
    local gui = Create("ScreenGui", {
        Name = "OvertimeUI_" .. name,
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
        Parent = LP:FindFirstChild("PlayerGui") or game:GetService("CoreGui"),
    })
    self.gui = gui

    -- Fixed-size draggable panel.
    local size = (typeof(cfg.Size) == "UDim2") and cfg.Size or UDim2.fromOffset(520, 360)
    local pos  = (typeof(cfg.Position) == "UDim2") and cfg.Position
                 or UDim2.new(0.5, -size.X.Offset / 2, 0.5, -size.Y.Offset / 2)

    local panel = Create("Frame", {
        Name = "Panel",
        Size = size,
        Position = pos,
        BackgroundColor3 = self.theme.bg,
        BorderSizePixel = 0,
        Active = true,
        Parent = gui,
    })
    corner(panel, 10)
    stroke(panel, self.theme.border, 1)
    self.panel = panel

    -- Title bar. Active = true so InputBegan fires on this Frame when
    -- the user clicks it (Frames with Active = false pass clicks through).
    local titleBar = Create("Frame", {
        Name = "TitleBar",
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundTransparency = 1,
        Active = true,
        Parent = panel,
    })

    local accentStripe = Create("Frame", {
        Size = UDim2.fromOffset(3, 16),
        Position = UDim2.new(0, 10, 0.5, -8),
        BackgroundColor3 = self.theme.accent,
        BorderSizePixel = 0,
        Parent = titleBar,
    })
    corner(accentStripe, 2)

    Create("TextLabel", {
        Size = UDim2.new(1, -100, 1, 0),
        Position = UDim2.new(0, 20, 0, 0),
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = self.theme.text,
        Font = FONT_BOLD,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = titleBar,
    })

    local function makeIconBtn(icon, color, xOffset)
        local b = Create("TextButton", {
            Size = UDim2.fromOffset(22, 22),
            Position = UDim2.new(1, xOffset, 0, 7),
            BackgroundColor3 = self.theme.surface,
            BorderSizePixel = 0,
            Text = icon,
            TextColor3 = color,
            Font = FONT_BOLD,
            TextSize = 14,
            AutoButtonColor = false,
            Parent = titleBar,
        })
        corner(b, 4)
        return b
    end
    local closeBtn = makeIconBtn("×", self.theme.danger, -30)
    local minBtn   = makeIconBtn("–", self.theme.text,   -56)

    closeBtn.MouseButton1Click:Connect(function() self:Destroy() end)

    -- Title separator
    Create("Frame", {
        Size = UDim2.new(1, -20, 0, 1),
        Position = UDim2.new(0, 10, 0, 36),
        BackgroundColor3 = self.theme.border,
        BorderSizePixel = 0,
        Parent = panel,
    })

    -- Content container: horizontal split (tab strip | tab body)
    local content = Create("Frame", {
        Name = "Content",
        Size = UDim2.new(1, -16, 1, -48),
        Position = UDim2.new(0, 8, 0, 40),
        BackgroundTransparency = 1,
        Parent = panel,
    })
    self.content = content

    local tabStrip = Create("Frame", {
        Name = "TabStrip",
        Size = UDim2.new(0, 120, 1, 0),
        BackgroundColor3 = self.theme.bgAlt,
        BorderSizePixel = 0,
        Parent = content,
    })
    corner(tabStrip, 8)
    Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4),
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        Parent = tabStrip,
    })
    Create("UIPadding", {
        PaddingTop = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
        Parent = tabStrip,
    })
    self._tabStrip = tabStrip

    local tabBody = Create("Frame", {
        Name = "TabBody",
        Size = UDim2.new(1, -128, 1, 0),
        Position = UDim2.new(0, 128, 0, 0),
        BackgroundColor3 = self.theme.bgAlt,
        BorderSizePixel = 0,
        Parent = content,
    })
    corner(tabBody, 8)
    self._tabBody = tabBody

    -- Minimize behavior: collapse everything below the title bar.
    local minimized = false
    local fullSize = size
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        content.Visible = not minimized
        panel.Size = minimized and UDim2.fromOffset(fullSize.X.Offset, 36) or fullSize
        minBtn.Text = minimized and "+" or "–"
    end)

    -- Drag handling. Roblox's legacy `Draggable = true` is deprecated and
    -- sometimes doesn't compose with AutomaticSize, so we roll our own
    -- against the title bar specifically (clicking controls in the body
    -- shouldn't drag the window). The InputBegan/Ended connections live
    -- on titleBar itself and Roblox disconnects them automatically when
    -- the gui is destroyed, but the InputChanged connection lives on
    -- UserInputService — a global service we don't own — so we have to
    -- disconnect it ourselves on cleanup or it outlives the window.
    do
        local dragging = false
        local dragStart, startPos
        titleBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragStart = input.Position
                startPos = panel.Position
            end
        end)
        titleBar.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
        local dragConn = UIS.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                          or input.UserInputType == Enum.UserInputType.Touch) then
                local delta = input.Position - dragStart
                panel.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
            end
        end)
        table.insert(self._cleanup, function()
            dragging = false
            dragConn:Disconnect()
        end)
    end

    return self
end

-- =========================================================================
-- Notifications — toast-style popups stacked in the top-right corner.
-- =========================================================================
-- UI:Notify{
--     Title    = "Aimbot",
--     Content  = "Target Part changed to Head",
--     Duration = 3,                         -- optional; default 4 seconds
--     Accent   = Color3.fromRGB(...),       -- optional; per-toast override
-- }
--
-- Notifications live in their own ScreenGui that's shared across every
-- window in the process. That way a window getting destroyed doesn't
-- kill in-flight toasts, and scripts can fire notifications from
-- anywhere without needing a window reference. The container is lazily
-- created on the first Notify call. The stack reorders automatically
-- when toasts expire via UIListLayout with SortOrder = LayoutOrder.

local notifyGui    -- ScreenGui, lazy
local notifyStack  -- Frame with UIListLayout, parent for individual toasts
local notifyOrder  = 0

local function ensureNotifyContainer()
    if notifyGui and notifyGui.Parent then return end
    notifyGui = Create("ScreenGui", {
        Name = "OvertimeUI_Notifications",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
        Parent = LP:FindFirstChild("PlayerGui") or game:GetService("CoreGui"),
    })
    notifyStack = Create("Frame", {
        Name = "Stack",
        Size = UDim2.new(0, 320, 1, -40),
        Position = UDim2.new(1, -336, 0, 20),
        BackgroundTransparency = 1,
        Parent = notifyGui,
    })
    Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 8),
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        VerticalAlignment = Enum.VerticalAlignment.Top,
        Parent = notifyStack,
    })
end

function OvertimeUI:Notify(cfg)
    cfg = cfg or {}
    ensureNotifyContainer()
    notifyOrder = notifyOrder + 1

    local theme  = defaultTheme()
    if typeof(cfg.Accent) == "Color3" then theme.accent = cfg.Accent end
    local duration = cfg.Duration or 4

    -- Each toast is a Frame with a title + content + left-edge accent
    -- stripe. Starts offscreen (X = 1.2) and tweens in. Uses TweenService
    -- for the slide-in/out so we don't fight the parent UIListLayout.
    local toast = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Position = UDim2.new(1.2, 0, 0, 0),
        BackgroundColor3 = theme.bg,
        BorderSizePixel = 0,
        LayoutOrder = notifyOrder,
        Parent = notifyStack,
    })
    corner(toast, 8)
    stroke(toast, theme.border, 1)

    local stripe = Create("Frame", {
        Size = UDim2.new(0, 3, 1, -14),
        Position = UDim2.new(0, 8, 0, 7),
        BackgroundColor3 = theme.accent,
        BorderSizePixel = 0,
        Parent = toast,
    })
    corner(stripe, 2)

    local contentBox = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = toast,
    })
    Create("UIPadding", {
        PaddingTop    = UDim.new(0, 10),
        PaddingBottom = UDim.new(0, 10),
        PaddingLeft   = UDim.new(0, 20),
        PaddingRight  = UDim.new(0, 12),
        Parent = contentBox,
    })
    Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4),
        Parent = contentBox,
    })

    Create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = cfg.Title or "",
        TextColor3 = theme.accent,
        Font = FONT_BOLD,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = 1,
        Parent = contentBox,
    })

    if cfg.Content and cfg.Content ~= "" then
        Create("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Text = cfg.Content,
            TextColor3 = theme.text,
            Font = FONT,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
            LayoutOrder = 2,
            Parent = contentBox,
        })
    end

    local slideInInfo  = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
    local slideOutInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In)

    TweenService:Create(toast, slideInInfo, { Position = UDim2.new(0, 0, 0, 0) }):Play()

    task.delay(duration, function()
        local outTween = TweenService:Create(toast, slideOutInfo, {
            Position = UDim2.new(1.2, 0, 0, 0),
        })
        outTween:Play()
        outTween.Completed:Connect(function()
            toast:Destroy()
        end)
    end)
end

return OvertimeUI
