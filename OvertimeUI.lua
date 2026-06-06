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
OvertimeUI._VERSION = "0.4.0"

-- =========================================================================
-- Services & shared state
-- =========================================================================

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local LP         = Players.LocalPlayer

-- Font + structural style are *mutable module state*, not constants. Every
-- control builder reads these upvalues directly (`Font = FONT`, `corner(x, 6)`),
-- so reassigning them in applyStyle() — before a window's controls are built —
-- restyles the whole tree without threading style through every call site.
-- Lua closures capture the variable, not the value, so the reassignment is
-- visible to code defined earlier in the file. DEFAULT_* hold the originals so
-- a window that omits a token falls back cleanly.
local DEFAULT_FONT      = Enum.Font.Gotham
local DEFAULT_FONT_BOLD = Enum.Font.GothamBold
local DEFAULT_FONT_SEMI = Enum.Font.GothamMedium

local FONT        = DEFAULT_FONT
local FONT_BOLD   = DEFAULT_FONT_BOLD
local FONT_SEMI   = DEFAULT_FONT_SEMI

-- Roundness is a global multiplier on every corner radius (1 = stock, 0 = sharp
-- corners, >1 = pillier). Set per-window by applyStyle().
local ROUNDNESS   = 1

-- Hairline thickness for every UIStroke the library draws (1 = stock). Lets a
-- script go from a barely-there 1px outline to a chunky 2-3px framed look.
local DEFAULT_STROKE = 1
local STROKE         = DEFAULT_STROKE

-- Animation duration multiplier. 1 = stock motion, 0.5 = twice as snappy,
-- 2 = languid, 0 = instant (no tweens). Applied inside tween() so it scales
-- every transition in the library at once.
local DEFAULT_ANIM = 1
local ANIM         = DEFAULT_ANIM

-- Depth flags — the difference between a flat single-layer look and a
-- premium one. All default OFF so the stock look is unchanged; presets and
-- scripts opt in. Mirrored into upvalues by applyStyle() so the global
-- builders can read them without a window reference.
--   gradientStroke : key borders become a light-catching colour sweep
--   accentGlow     : a soft accent-tinted glow behind the panel + active controls
--   gradientFill   : surfaces get a subtle top-lit fill gradient (depth)
local GRAD_STROKE = false
local ACCENT_GLOW = false
local GRAD_FILL   = false

-- Default *structural* style (non-color). Merged from CreateWindow's style
-- fields; colors live in defaultTheme(). Keeping them apart means a script can
-- recolor without touching layout, or resize roundness without recoloring.
--
-- The numeric/string layout tokens (layout, titleHeight, tabWidth, ...) are
-- read straight off the resolved style table by CreateWindow / CreateTab /
-- CreateSection, which all have a window reference. Only the four tokens used
-- by the global primitive helpers (corner/stroke/tween, which have no window
-- context) are mirrored into module upvalues by applyStyle(): roundness, the
-- three fonts, stroke thickness, and animation speed.
local function defaultStyle()
    return {
        -- corner / fonts / stroke / motion (mirrored into upvalues) ----------
        roundness   = 1,                       -- corner radius multiplier
        font        = DEFAULT_FONT,            -- body text
        fontBold    = DEFAULT_FONT_BOLD,       -- titles
        fontSemi    = DEFAULT_FONT_SEMI,       -- labels / buttons
        strokeThickness = 1,                   -- UIStroke hairline thickness
        animation   = 1,                       -- tween duration multiplier (0 = instant)
        -- panel decorations --------------------------------------------------
        shadow      = true,                    -- soft drop behind the panel
        sheen       = true,                    -- top-lit gradient on the panel
        stripe      = true,                    -- accent stripe in the title bar
        sheenStrength      = 0.05,             -- how pronounced the panel sheen is
        shadowSpread       = 30,               -- how far the drop shadow bleeds out
        shadowTransparency = 0.65,             -- how faint the drop shadow is
        panelTransparency  = 0,                -- 0 = solid, ~0.1-0.3 = glass/acrylic
        backgroundImage             = nil,     -- optional texture behind the panel body
        backgroundImageTransparency = 0.85,    -- how subtle that texture is
        -- layout / structure -------------------------------------------------
        layout      = "left",                  -- "left" sidebar tabs | "top" tab bar
        titleHeight = 36,                      -- title-bar height in px
        titleAlign  = "left",                  -- "left" | "center" title text
        titleIcon   = nil,                     -- optional rbxassetid:// logo by the title
        tabWidth    = 120,                     -- sidebar width (left layout only)
        tabHeight   = 30,                      -- per-tab button height
        bodyPadding = 12,                      -- inner padding of each tab page
        spacing     = 2,                       -- vertical gap between control rows
        -- depth (all off = stock flat look) ----------------------------------
        gradientStroke = false,                -- light-catching gradient borders
        accentGlow     = false,                -- accent glow behind panel + active controls
        gradientFill   = false,                -- subtle top-lit fill gradient on surfaces
    }
end

-- Push a window's resolved style into the mutable module upvalues so every
-- control built afterwards picks it up. Idempotent and cheap — safe to call at
-- the top of each builder so deferred control creation stays on-style even when
-- two differently-styled windows coexist.
local function applyStyle(style)
    if type(style) ~= "table" then return end
    ROUNDNESS = type(style.roundness) == "number" and math.max(0, style.roundness) or 1
    FONT      = (typeof(style.font)     == "EnumItem") and style.font     or DEFAULT_FONT
    FONT_BOLD = (typeof(style.fontBold) == "EnumItem") and style.fontBold or DEFAULT_FONT_BOLD
    FONT_SEMI = (typeof(style.fontSemi) == "EnumItem") and style.fontSemi or DEFAULT_FONT_SEMI
    STROKE    = type(style.strokeThickness) == "number" and math.max(0, style.strokeThickness) or DEFAULT_STROKE
    ANIM      = type(style.animation) == "number" and math.max(0, style.animation) or DEFAULT_ANIM
    GRAD_STROKE = style.gradientStroke == true
    ACCENT_GLOW = style.accentGlow == true
    GRAD_FILL   = style.gradientFill == true
end

-- Default theme. Individual windows can override `accent` via the Accent
-- field in CreateWindow config. Everything else is shared.
local function defaultTheme()
    return {
        -- Elevation ramp: each step a little lighter than the last so
        -- stacked surfaces read as physical layers instead of flat panes.
        bg          = Color3.fromRGB(11, 12, 17),   -- panel base (darkest)
        bgAlt       = Color3.fromRGB(16, 18, 25),   -- sidebars / body
        surface     = Color3.fromRGB(26, 29, 40),   -- controls at rest
        surfaceHi   = Color3.fromRGB(38, 43, 58),   -- hover / active
        border      = Color3.fromRGB(42, 47, 62),   -- hairlines (low contrast)
        borderHi    = Color3.fromRGB(64, 72, 92),   -- focused / hovered edges
        accent      = Color3.fromRGB(96, 165, 255),
        accentDim   = Color3.fromRGB(54, 92, 150),  -- muted accent for fills
        accentGlow  = Color3.fromRGB(120, 180, 255),-- glow tint
        text        = Color3.fromRGB(236, 238, 246),
        textDim     = Color3.fromRGB(138, 145, 162),
        danger      = Color3.fromRGB(235, 92, 96),
        shadow      = Color3.fromRGB(0, 0, 0),
    }
end

-- =========================================================================
-- Built-in palettes and presets
-- =========================================================================
-- Themes are partial colour tables merged over defaultTheme() — pass one
-- straight into CreateWindow's `Theme` field, or reference by name through a
-- preset. Presets are FULL config bundles (theme + structure + depth) so a
-- script gets a distinct, finished look in one line:
--
--     local Window = UI:CreateWindow({ Preset = "Aurora", Name = "My Script" })
--
-- Anything the script passes alongside `Preset` overrides the preset
-- (Theme/Style are deep-merged; everything else is replaced), so you can start
-- from a preset and tweak just the accent or the name.

local rgb = Color3.fromRGB

OvertimeUI.Themes = {
    Dark    = defaultTheme(),  -- the stock palette, for completeness
    Midnight = {
        bg = rgb(10, 12, 22), bgAlt = rgb(14, 17, 30), surface = rgb(22, 27, 46),
        surfaceHi = rgb(32, 40, 64), border = rgb(34, 42, 70), borderHi = rgb(60, 80, 140),
        accent = rgb(90, 130, 255), accentDim = rgb(48, 70, 150), accentGlow = rgb(120, 150, 255),
        text = rgb(232, 236, 252), textDim = rgb(120, 130, 165),
    },
    Aqua = {
        bg = rgb(8, 18, 20), bgAlt = rgb(12, 24, 27), surface = rgb(18, 36, 40),
        surfaceHi = rgb(26, 52, 58), border = rgb(24, 54, 58), borderHi = rgb(40, 110, 120),
        accent = rgb(0, 224, 200), accentDim = rgb(20, 110, 100), accentGlow = rgb(80, 255, 230),
        text = rgb(224, 248, 246), textDim = rgb(110, 150, 150),
    },
    Rose = {
        bg = rgb(24, 12, 18), bgAlt = rgb(32, 16, 24), surface = rgb(46, 24, 34),
        surfaceHi = rgb(64, 34, 48), border = rgb(64, 32, 46), borderHi = rgb(140, 60, 90),
        accent = rgb(255, 90, 150), accentDim = rgb(150, 50, 90), accentGlow = rgb(255, 130, 180),
        text = rgb(252, 234, 242), textDim = rgb(170, 130, 145),
    },
    Mono = {
        bg = rgb(14, 14, 16), bgAlt = rgb(20, 20, 23), surface = rgb(30, 30, 34),
        surfaceHi = rgb(44, 44, 50), border = rgb(48, 48, 54), borderHi = rgb(96, 96, 104),
        accent = rgb(230, 230, 236), accentDim = rgb(110, 110, 120), accentGlow = rgb(255, 255, 255),
        text = rgb(238, 238, 242), textDim = rgb(130, 130, 138),
    },
    Forest = {
        bg = rgb(10, 16, 12), bgAlt = rgb(14, 22, 16), surface = rgb(20, 32, 24),
        surfaceHi = rgb(30, 48, 36), border = rgb(28, 48, 34), borderHi = rgb(50, 100, 64),
        accent = rgb(80, 220, 120), accentDim = rgb(40, 110, 64), accentGlow = rgb(120, 255, 160),
        text = rgb(228, 244, 232), textDim = rgb(120, 150, 130),
    },
    Amber = {
        bg = rgb(22, 16, 8), bgAlt = rgb(30, 22, 12), surface = rgb(44, 32, 18),
        surfaceHi = rgb(62, 46, 26), border = rgb(60, 44, 24), borderHi = rgb(140, 100, 50),
        accent = rgb(255, 170, 50), accentDim = rgb(150, 100, 30), accentGlow = rgb(255, 200, 110),
        text = rgb(250, 240, 226), textDim = rgb(168, 148, 120),
    },
}

OvertimeUI.Presets = {
    -- Modern frosted top-bar with a gradient accent and glow — the "premium" look.
    Aurora = {
        Theme = OvertimeUI.Themes.Midnight,
        AccentGradient = { rgb(120, 90, 255), rgb(0, 200, 255) },
        Layout = "top", TitleAlign = "center", Roundness = 2,
        PanelTransparency = 0.10, Animation = 0.7,
        GradientStroke = true, AccentGlow = true, GradientFill = true,
    },
    -- Rayfield-style sleek single-column sidebar: rounded, lit, glowing accent.
    Sleek = {
        Theme = OvertimeUI.Themes.Dark,
        Accent = rgb(96, 165, 255),
        Roundness = 1.3, Animation = 0.8,
        GradientStroke = true, AccentGlow = true, GradientFill = true,
    },
    -- Dense, sharp, monospaced terminal: hard corners, chunky frame, no glow.
    Terminal = {
        Theme = OvertimeUI.Themes.Forest,
        Font = Enum.Font.Code, FontBold = Enum.Font.Code, FontSemi = Enum.Font.Code,
        Roundness = 0, StrokeThickness = 2,
        TabWidth = 96, TabHeight = 24, BodyPadding = 8, Spacing = 1,
        Sheen = false, Shadow = false,
    },
    -- Compact cheat-menu palette meant to be paired with two-column groupboxes.
    Compact = {
        Theme = OvertimeUI.Themes.Mono,
        Accent = rgb(120, 200, 255),
        Roundness = 0.5, TabWidth = 104, TabHeight = 26, BodyPadding = 8, Spacing = 1,
        GradientStroke = true,
    },
    -- Warm, roomy, languid — soft and unhurried.
    Velvet = {
        Theme = OvertimeUI.Themes.Rose,
        Roundness = 1.6, TitleHeight = 46, TabWidth = 148, TabHeight = 36,
        BodyPadding = 18, Spacing = 6, Animation = 1.5,
        AccentGlow = true, GradientFill = true,
    },
    -- Heavy glass: translucent panel, big glow, gradient everything.
    Glass = {
        Theme = OvertimeUI.Themes.Aqua,
        AccentGradient = { rgb(0, 224, 200), rgb(60, 140, 255) },
        Roundness = 1.8, PanelTransparency = 0.22, Animation = 0.8,
        GradientStroke = true, AccentGlow = true, GradientFill = true,
    },
}

-- Shadow / glow image. A soft 9-slice drop shadow used behind the panel and
-- as a tinted glow behind active elements. If this asset ever fails to load
-- in a given environment, swap it for rbxassetid://1316045217 (radial) —
-- the SliceCenter below is tuned for 6014261993.
local SHADOW_ASSET = "rbxassetid://6014261993"
local SHADOW_SLICE = Rect.new(49, 49, 450, 450)

-- One shared tween spec set so motion feels consistent across every control.
local EASE      = Enum.EasingStyle.Quint
local EASE_OUT  = Enum.EasingDirection.Out
local SPRING     = Enum.EasingStyle.Back   -- subtle overshoot, window arrival only
local T_FAST     = 0.12
local T_NORMAL   = 0.18
local T_SLOW     = 0.28

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
    local r = math.max(0, math.floor((radius or 6) * ROUNDNESS + 0.5))
    return Create("UICorner", { CornerRadius = UDim.new(0, r), Parent = parent })
end

local function stroke(parent, color, thickness)
    return Create("UIStroke", { Color = color, Thickness = thickness or STROKE, Parent = parent })
end

-- Fire-and-forget tween. Returns the Tween so callers can hook .Completed.
-- Duration is scaled by the window's `animation` token (ANIM upvalue) so one
-- style field speeds up or slows down every transition. At ANIM == 0 the tween
-- still runs but with a near-zero duration so .Completed fires next frame and
-- callers that chain off it keep working.
local function tween(inst, props, time, style, dir)
    local dur = (time or T_NORMAL) * ANIM
    local info = TweenInfo.new(dur, style or EASE, dir or EASE_OUT)
    local tw = TweenService:Create(inst, info, props)
    tw:Play()
    return tw
end

-- Apply an accent gradient to a frame's fill. `spec` is whatever the window
-- resolved for `accentGradient`: a ColorSequence, or a {Color3, Color3,...}
-- list we wrap into one. Returns the UIGradient (or nil if spec is unusable)
-- so callers can keep a reference. Used on the title stripe, tab indicators,
-- and section ticks so an accent can be a sweep instead of one flat colour.
local function applyAccentGradient(frame, spec, rotation)
    if not spec then return nil end
    local seq
    if typeof(spec) == "ColorSequence" then
        seq = spec
    elseif type(spec) == "table" then
        local kp = {}
        local n = #spec
        if n == 1 then
            kp[1] = ColorSequenceKeypoint.new(0, spec[1])
            kp[2] = ColorSequenceKeypoint.new(1, spec[1])
        elseif n >= 2 then
            for i = 1, n do
                kp[i] = ColorSequenceKeypoint.new((i - 1) / (n - 1), spec[i])
            end
        end
        if #kp >= 2 then seq = ColorSequence.new(kp) end
    end
    if not seq then return nil end
    return Create("UIGradient", { Color = seq, Rotation = rotation or 0, Parent = frame })
end

-- Vertical sheen: a subtle top-lighter / bottom-darker gradient that gives
-- a flat fill the sense of a lit surface. Brightness is a small +/- offset
-- applied symmetrically around the parent's own color.
local function sheen(parent, strength)
    strength = strength or 0.06
    return Create("UIGradient", {
        Rotation = 90,
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(
                math.floor((1 - strength) * 255),
                math.floor((1 - strength) * 255),
                math.floor((1 - strength) * 255))),
        }),
        Parent = parent,
    })
end

-- Soft drop shadow placed *behind* `parent` (as a sibling, lower ZIndex).
-- `spread` grows the shadow past the parent's bounds; `transparency` sets
-- how dark it is. Returns the ImageLabel so it can be retinted into a glow.
local function shadow(parent, spread, transparency, color)
    local img = Create("ImageLabel", {
        Name = "Shadow",
        BackgroundTransparency = 1,
        Image = SHADOW_ASSET,
        ImageColor3 = color or Color3.new(0, 0, 0),
        ImageTransparency = transparency or 0.55,
        ScaleType = Enum.ScaleType.Slice,
        SliceCenter = SHADOW_SLICE,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, (spread or 24) * 2, 1, (spread or 24) * 2),
        ZIndex = (parent.ZIndex or 1) - 1,
        Parent = parent,
    })
    return img
end

local function padding(parent, t, b, l, r)
    return Create("UIPadding", {
        PaddingTop    = UDim.new(0, t or 0),
        PaddingBottom = UDim.new(0, b or t or 0),
        PaddingLeft   = UDim.new(0, l or 0),
        PaddingRight  = UDim.new(0, r or l or 0),
        Parent = parent,
    })
end

-- =========================================================================
-- Depth helpers — gradients, glows. Used to lift the flat default into a
-- premium look when the matching Style flag is on (GRAD_STROKE / ACCENT_GLOW
-- / GRAD_FILL). Each is a no-op-ish fallback when its flag is off, so call
-- sites read the same whether depth is enabled or not.
-- =========================================================================

-- A gradient outline: a UIStroke carrying a child UIGradient that runs from
-- colorA to colorB, so the border catches light along its length (the modern
-- "UIStroke × UIGradient" trick). Returns the UIStroke.
local function gradStroke(parent, colorA, colorB, thickness, rotation)
    local s = Create("UIStroke", { Color = colorA, Thickness = thickness or STROKE, Parent = parent })
    Create("UIGradient", {
        Color = ColorSequence.new(colorA, colorB),
        Rotation = rotation or 90,
        Parent = s,
    })
    return s
end

-- Stroke a surface, honouring the GRAD_STROKE flag: gradient edge when on,
-- plain hairline when off. `hi` is the bright end of the gradient (defaults to
-- a lighter version of the base). Drop-in replacement for stroke() on the
-- panel, cards, and other framed surfaces.
local function depthStroke(parent, color, hi, thickness)
    if GRAD_STROKE then
        return gradStroke(parent, color, hi or color, thickness)
    end
    return Create("UIStroke", { Color = color, Thickness = thickness or STROKE, Parent = parent })
end

-- Soft accent-tinted glow behind `parent`. A single tinted 9-slice reads as a
-- hard rectangle outline (straight glowing edges = tacky). Instead we stack a
-- few copies with growing spread and fading opacity: the overlap makes a smooth
-- radial-ish bloom whose outer edge melts away, so it looks like ambient light
-- rather than a glowing box. `transparency`/`spread` set the brightest, tightest
-- inner layer; outer layers derive from them. Returns the innermost ImageLabel
-- (or nil when ACCENT_GLOW is off, unless `force`).
local function accentGlowBehind(parent, color, transparency, spread, force)
    if not (ACCENT_GLOW or force) then return nil end
    transparency = transparency or 0.74
    spread = spread or 26
    -- {spread multiplier, extra transparency added} — inner→outer.
    local layers = {
        { 0.55, 0.00 },
        { 1.25, 0.10 },
        { 2.40, 0.17 },
    }
    local inner
    for _, L in ipairs(layers) do
        local img = shadow(parent, spread * L[1], math.min(1, transparency + L[2]), color)
        inner = inner or img
    end
    return inner
end

-- Subtle top-lit fill gradient, gated on GRAD_FILL. No-op when off.
local function depthFill(parent, strength)
    if not GRAD_FILL then return nil end
    return sheen(parent, strength or 0.07)
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
    corner(btn, 4)
    local btnStroke = stroke(btn, theme.border, 1)

    btn.MouseEnter:Connect(function()
        if rebinding then return end
        tween(btn, { BackgroundColor3 = theme.surfaceHi }, T_FAST)
        tween(btnStroke, { Color = theme.borderHi }, T_FAST)
    end)
    btn.MouseLeave:Connect(function()
        if rebinding then return end
        tween(btn, { BackgroundColor3 = theme.surface }, T_FAST)
        tween(btnStroke, { Color = theme.border }, T_FAST)
    end)

    local function stopRebind()
        rebinding = false
        for _, c in ipairs(rebindConns) do c:Disconnect() end
        table.clear(rebindConns)
    end

    local function applyKey(newKey, fireCallback)
        keyStr = newKey or "None"
        btn.Text = keybindLabel(keyStr)
        btn.TextColor3 = theme.accent
        tween(btn, { BackgroundColor3 = theme.surface }, T_FAST)
        tween(btnStroke, { Color = theme.border }, T_FAST)
        if fireCallback and onKeyChanged then
            task.spawn(onKeyChanged, keyStr)
        end
    end

    local function startRebind()
        if rebinding then return end
        rebinding = true
        rebindOpened = tick()
        btn.Text = "..."
        tween(btn, { BackgroundColor3 = theme.surfaceHi }, T_FAST)
        tween(btnStroke, { Color = theme.danger }, T_FAST)
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
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        LayoutOrder = self:_next(),
        Parent = self.container,
    })

    -- Flat pill switch (Fluent-style): track tints surface→accent, a plain
    -- dot slides across. Off knob is a muted dot; on knob is white, so the
    -- state reads at a glance even before you clock the track colour. When
    -- accentGlow is on, an accent halo fades in behind the track while active.
    local TRACK_W, TRACK_H, KNOB = 36, 18, 14

    -- Glow sits behind the track (ZIndex 0, sibling in the row) so it never
    -- covers the knob. Only built when accentGlow is enabled.
    local trackGlow
    if ACCENT_GLOW then
        trackGlow = Create("ImageLabel", {
            Name = "Glow",
            BackgroundTransparency = 1,
            Image = SHADOW_ASSET,
            ImageColor3 = theme.accentGlow or theme.accent,
            ImageTransparency = state and 0.45 or 1,
            ScaleType = Enum.ScaleType.Slice,
            SliceCenter = SHADOW_SLICE,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0, 2 + TRACK_W / 2, 0.5, 0),
            Size = UDim2.fromOffset(TRACK_W + 22, TRACK_H + 22),
            ZIndex = 0,
            Parent = row,
        })
    end

    local track = Create("Frame", {
        Size = UDim2.fromOffset(TRACK_W, TRACK_H),
        Position = UDim2.new(0, 2, 0.5, -TRACK_H / 2),
        BackgroundColor3 = state and theme.accent or theme.surface,
        BorderSizePixel = 0,
        ZIndex = 1,
        Parent = row,
    })
    corner(track, TRACK_H / 2)
    local trackStroke = stroke(track, state and theme.accent or theme.border, 1)

    local knobOffOff = 2                          -- knob x when off
    local knobOnOff  = TRACK_W - KNOB - 2         -- knob x when on
    local knob = Create("Frame", {
        Size = UDim2.fromOffset(KNOB, KNOB),
        Position = UDim2.new(0, state and knobOnOff or knobOffOff, 0.5, -KNOB / 2),
        BackgroundColor3 = state and Color3.new(1, 1, 1) or theme.textDim,
        BorderSizePixel = 0,
        Parent = track,
    })
    corner(knob, KNOB / 2)

    local label = Create("TextLabel", {
        Size = UDim2.new(1, -46, 1, 0),
        Position = UDim2.new(0, 46, 0, 0),
        BackgroundTransparency = 1,
        Text = cfg.Name or "Toggle",
        TextColor3 = state and theme.text or theme.textDim,
        Font = FONT,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })

    local function setState(v, fireCallback)
        v = not not v
        if v == state then return end
        state = v
        tween(track, { BackgroundColor3 = state and theme.accent or theme.surface }, T_NORMAL)
        tween(trackStroke, { Color = state and theme.accent or theme.border }, T_NORMAL)
        if trackGlow then tween(trackGlow, { ImageTransparency = state and 0.45 or 1 }, T_NORMAL) end
        tween(label, { TextColor3 = state and theme.text or theme.textDim }, T_NORMAL)
        tween(knob, {
            Position = UDim2.new(0, state and knobOnOff or knobOffOff, 0.5, -KNOB / 2),
            BackgroundColor3 = state and Color3.new(1, 1, 1) or theme.textDim,
        }, T_NORMAL)
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
        label.Size = UDim2.new(1, -46 - 64, 1, 0)
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
    -- track, sized 0..1 scale proportional to (value-min)/(max-min). A small
    -- round thumb rides the leading edge of the fill — flat, no glow/shadow,
    -- just a white dot with a thin accent ring (Fluent-style).
    local track = Create("Frame", {
        Size = UDim2.new(1, -4, 0, 4),
        Position = UDim2.new(0, 2, 0, 25),
        BackgroundColor3 = theme.surface,
        BorderSizePixel = 0,
        Active = true, -- required for InputBegan to fire on the track
        Parent = row,
    })
    corner(track, 2)

    local fill = Create("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = theme.accent,
        BorderSizePixel = 0,
        Parent = track,
    })
    corner(fill, 2)

    local thumb = Create("Frame", {
        Size = UDim2.fromOffset(12, 12),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        ZIndex = 2,
        Parent = fill,
    })
    corner(thumb, 6)
    stroke(thumb, theme.accent, 1.5)

    -- Formats a value for display. Integer step -> integer; sub-integer
    -- step -> two decimal places (enough precision for 0.01 increments
    -- without trailing noise from floating point).
    local function formatValue(v)
        if step >= 1 then
            return string.format("%d%s", math.floor(v + 0.5), suffix)
        end
        return string.format("%.2f%s", v, suffix)
    end

    local function setValue(v, fireCallback, animate)
        v = math.clamp(v, minVal, maxVal)
        -- Snap to the nearest increment.
        if step > 0 then
            v = math.floor((v - minVal) / step + 0.5) * step + minVal
            v = math.clamp(v, minVal, maxVal)
        end
        if v == value and valLbl.Text ~= "" then return end
        value = v
        local pct = (maxVal > minVal) and ((v - minVal) / (maxVal - minVal)) or 0
        if animate then
            tween(fill, { Size = UDim2.new(pct, 0, 1, 0) }, T_NORMAL)
        else
            fill.Size = UDim2.new(pct, 0, 1, 0)
        end
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

    -- Thumb grows on hover for a touch of tactility.
    track.MouseEnter:Connect(function()
        tween(thumb, { Size = UDim2.fromOffset(14, 14) }, T_FAST)
    end)
    track.MouseLeave:Connect(function()
        if not dragging then tween(thumb, { Size = UDim2.fromOffset(12, 12) }, T_FAST) end
    end)

    function handle:Get() return value end
    function handle:Set(v) setValue(v, true, true) end
    function handle:SetSilent(v) setValue(v, false, true) end

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
        Size = UDim2.new(1, -4, 0, 22),
        Position = UDim2.new(0, 2, 0, 16),
        BackgroundColor3 = theme.surface,
        BorderSizePixel = 0,
        Text = " " .. tostring(current) .. "   ▼",
        TextColor3 = theme.text,
        Font = FONT,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = false,
        Parent = row,
    })
    corner(btn, 5)
    local btnStroke = stroke(btn, theme.border, 1)

    local popupOpen = false
    local popupBackdrop -- created on open, destroyed on close
    local popupFrame

    btn.MouseEnter:Connect(function()
        tween(btn, { BackgroundColor3 = theme.surfaceHi }, T_FAST)
        tween(btnStroke, { Color = theme.borderHi }, T_FAST)
    end)
    btn.MouseLeave:Connect(function()
        if popupOpen then return end
        tween(btn, { BackgroundColor3 = theme.surface }, T_FAST)
        tween(btnStroke, { Color = theme.border }, T_FAST)
    end)

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
            Position = UDim2.fromOffset(btn.AbsolutePosition.X, btn.AbsolutePosition.Y + btn.AbsoluteSize.Y + 4),
            BackgroundColor3 = theme.bgAlt,
            BorderSizePixel = 0,
            ZIndex = 51,
            Parent = popupBackdrop,
        })
        corner(popupFrame, 6)
        stroke(popupFrame, theme.borderHi, 1)
        shadow(popupFrame, 18, 0.7)

        -- Entrance: expand from a sliver + fade in, with a UIScale so the
        -- corner stays anchored to the button rather than scaling centrally.
        local uiscale = Create("UIScale", { Scale = 0.96, Parent = popupFrame })
        popupFrame.Size = UDim2.fromOffset(btn.AbsoluteSize.X, 0)
        tween(popupFrame, { Size = UDim2.fromOffset(btn.AbsoluteSize.X, totalH) }, T_NORMAL)
        tween(uiscale, { Scale = 1 }, T_NORMAL)

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
            corner(optBtn, 4)
            local isCur = (opt == current)
            optBtn.MouseEnter:Connect(function()
                if not isCur then tween(optBtn, { BackgroundColor3 = theme.surfaceHi }, T_FAST) end
            end)
            optBtn.MouseLeave:Connect(function()
                if not isCur then tween(optBtn, { BackgroundColor3 = theme.surface }, T_FAST) end
            end)
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
-- Color Picker
-- =========================================================================
-- HSV color picker in a popup. Config:
--   Name         = "Chams Color"
--   CurrentColor = Color3 (defaults to white)
--   Callback     = function(color) ... end
-- The popup has a saturation/value box and a vertical hue bar, parented
-- to the window's ScreenGui so it can extend outside the panel bounds
-- (same pattern as CreateDropdown). A full-screen transparent backdrop
-- captures click-outside-to-close. Returns a handle with :Get(), :Set(c),
-- :SetSilent(c), where `c` is a Color3.
function Section:CreateColorPicker(cfg)
    cfg = cfg or {}
    local window = self.tab.window
    local theme  = window.theme
    local gui    = window.gui

    local currentColor = cfg.CurrentColor or Color3.fromRGB(255, 255, 255)
    local h, s, v = currentColor:ToHSV()

    local handle = { Type = "ColorPicker", Name = cfg.Name or "Color" }

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
        Text = cfg.Name or "Color",
        TextColor3 = theme.text,
        Font = FONT,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })

    local swatch = Create("TextButton", {
        Size = UDim2.fromOffset(56, 18),
        Position = UDim2.new(1, -60, 0.5, -9),
        BackgroundColor3 = currentColor,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        Parent = row,
    })
    corner(swatch, 3)
    stroke(swatch, theme.border, 1)

    -- Popup widgets are allocated on open. Kept as upvalues so :Set can
    -- update them live when the popup happens to be open, and so
    -- closePopup can nil them out for re-open.
    local popupOpen = false
    local popupBackdrop, svBox, hueBar, svCursor, hueCursor, hexLabel
    local draggingSV, draggingHue = false, false
    local svMoveConn, hueMoveConn, releaseConn

    local function formatHex(c)
        return string.format("#%02X%02X%02X",
            math.floor(c.R * 255 + 0.5),
            math.floor(c.G * 255 + 0.5),
            math.floor(c.B * 255 + 0.5))
    end

    -- Rebuilds the Color3 from the current h/s/v, updates the swatch,
    -- and — if the popup is open — refreshes the SV box hue background,
    -- the cursor positions, and the hex readout. Fires the user callback
    -- only when fireCallback is true.
    local function applyHSV(fireCallback)
        local c = Color3.fromHSV(h, s, v)
        currentColor = c
        swatch.BackgroundColor3 = c
        if svBox then
            svBox.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
        end
        if svCursor then
            svCursor.Position = UDim2.new(s, -4, 1 - v, -4)
        end
        if hueCursor then
            hueCursor.Position = UDim2.new(0, -2, h, -1)
        end
        if hexLabel then
            hexLabel.Text = formatHex(c)
        end
        if fireCallback and cfg.Callback then
            task.spawn(cfg.Callback, c)
        end
    end

    local function setColor(c, fireCallback)
        if typeof(c) ~= "Color3" then return end
        h, s, v = c:ToHSV()
        applyHSV(fireCallback)
    end

    local function closePopup()
        popupOpen = false
        draggingSV = false
        draggingHue = false
        if svMoveConn  then svMoveConn:Disconnect()  svMoveConn  = nil end
        if hueMoveConn then hueMoveConn:Disconnect() hueMoveConn = nil end
        if releaseConn then releaseConn:Disconnect() releaseConn = nil end
        if popupBackdrop then
            popupBackdrop:Destroy()
            popupBackdrop = nil
            svBox, hueBar = nil, nil
            svCursor, hueCursor = nil, nil
            hexLabel = nil
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

        -- Right-align the popup under the swatch so its body doesn't
        -- run off the right edge of the screen.
        local popupW, popupH = 192, 160
        local popupX = swatch.AbsolutePosition.X + swatch.AbsoluteSize.X - popupW
        local popupY = swatch.AbsolutePosition.Y + swatch.AbsoluteSize.Y + 4

        local popupFrame = Create("Frame", {
            Size = UDim2.fromOffset(popupW, popupH),
            Position = UDim2.fromOffset(popupX, popupY),
            BackgroundColor3 = theme.bgAlt,
            BorderSizePixel = 0,
            ZIndex = 51,
            Parent = popupBackdrop,
        })
        corner(popupFrame, 6)
        stroke(popupFrame, theme.borderHi, 1)
        shadow(popupFrame, 18, 0.7)
        local cpScale = Create("UIScale", { Scale = 0.94, Parent = popupFrame })
        tween(cpScale, { Scale = 1 }, T_NORMAL)

        -- Saturation/Value box. The base frame is the pure hue; a
        -- horizontal white→transparent gradient gives the saturation
        -- axis, and a vertical transparent→black gradient gives the
        -- value axis. Active = true so the Frame receives InputBegan
        -- directly; the overlay children aren't Active, so clicks pass
        -- through to the SV box underneath.
        svBox = Create("Frame", {
            Size = UDim2.fromOffset(150, 120),
            Position = UDim2.fromOffset(8, 8),
            BackgroundColor3 = Color3.fromHSV(h, 1, 1),
            BorderSizePixel = 0,
            Active = true,
            ZIndex = 52,
            Parent = popupFrame,
        })
        corner(svBox, 3)

        local whiteOverlay = Create("Frame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 53,
            Parent = svBox,
        })
        corner(whiteOverlay, 3)
        Create("UIGradient", {
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0),
                NumberSequenceKeypoint.new(1, 1),
            }),
            Rotation = 0,
            Parent = whiteOverlay,
        })

        local blackOverlay = Create("Frame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = Color3.new(0, 0, 0),
            BorderSizePixel = 0,
            ZIndex = 54,
            Parent = svBox,
        })
        corner(blackOverlay, 3)
        Create("UIGradient", {
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1),
                NumberSequenceKeypoint.new(1, 0),
            }),
            Rotation = 90,
            Parent = blackOverlay,
        })

        svCursor = Create("Frame", {
            Size = UDim2.fromOffset(8, 8),
            Position = UDim2.new(s, -4, 1 - v, -4),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 55,
            Parent = svBox,
        })
        corner(svCursor, 4)
        stroke(svCursor, Color3.new(0, 0, 0), 1)

        -- Vertical hue bar. Gradient walks the full hue wheel top to
        -- bottom; wraps back to red at both ends so 0 and 1 match.
        hueBar = Create("Frame", {
            Size = UDim2.fromOffset(18, 120),
            Position = UDim2.fromOffset(166, 8),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            Active = true,
            ZIndex = 52,
            Parent = popupFrame,
        })
        corner(hueBar, 3)
        Create("UIGradient", {
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0.000, Color3.fromRGB(255, 0,   0  )),
                ColorSequenceKeypoint.new(0.166, Color3.fromRGB(255, 255, 0  )),
                ColorSequenceKeypoint.new(0.333, Color3.fromRGB(0,   255, 0  )),
                ColorSequenceKeypoint.new(0.500, Color3.fromRGB(0,   255, 255)),
                ColorSequenceKeypoint.new(0.666, Color3.fromRGB(0,   0,   255)),
                ColorSequenceKeypoint.new(0.833, Color3.fromRGB(255, 0,   255)),
                ColorSequenceKeypoint.new(1.000, Color3.fromRGB(255, 0,   0  )),
            }),
            Rotation = 90,
            Parent = hueBar,
        })

        hueCursor = Create("Frame", {
            Size = UDim2.new(1, 4, 0, 2),
            Position = UDim2.new(0, -2, h, -1),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 53,
            Parent = hueBar,
        })
        stroke(hueCursor, Color3.new(0, 0, 0), 1)

        hexLabel = Create("TextLabel", {
            Size = UDim2.new(1, -16, 0, 16),
            Position = UDim2.fromOffset(8, 136),
            BackgroundTransparency = 1,
            Text = formatHex(currentColor),
            TextColor3 = theme.textDim,
            Font = FONT_SEMI,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 52,
            Parent = popupFrame,
        })

        -- Drag handlers. SV box updates saturation+value from the click
        -- position; hue bar updates hue. Both call applyHSV(true) to
        -- refresh the swatch/cursors/hex and fire the user callback.
        local function updateSV(input)
            local rx = input.Position.X - svBox.AbsolutePosition.X
            local ry = input.Position.Y - svBox.AbsolutePosition.Y
            s = math.clamp(rx / math.max(svBox.AbsoluteSize.X, 1), 0, 1)
            v = 1 - math.clamp(ry / math.max(svBox.AbsoluteSize.Y, 1), 0, 1)
            applyHSV(true)
        end

        local function updateHue(input)
            local ry = input.Position.Y - hueBar.AbsolutePosition.Y
            h = math.clamp(ry / math.max(hueBar.AbsoluteSize.Y, 1), 0, 1)
            applyHSV(true)
        end

        svBox.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch then
                draggingSV = true
                updateSV(input)
            end
        end)
        hueBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch then
                draggingHue = true
                updateHue(input)
            end
        end)

        svMoveConn = UIS.InputChanged:Connect(function(input)
            if draggingSV and (input.UserInputType == Enum.UserInputType.MouseMovement
                            or input.UserInputType == Enum.UserInputType.Touch) then
                updateSV(input)
            end
        end)
        hueMoveConn = UIS.InputChanged:Connect(function(input)
            if draggingHue and (input.UserInputType == Enum.UserInputType.MouseMovement
                             or input.UserInputType == Enum.UserInputType.Touch) then
                updateHue(input)
            end
        end)
        releaseConn = UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch then
                draggingSV = false
                draggingHue = false
            end
        end)
    end

    swatch.MouseButton1Click:Connect(function()
        if popupOpen then closePopup() else openPopup() end
    end)

    table.insert(window._cleanup, closePopup)

    function handle:Get()        return currentColor end
    function handle:Set(c)       setColor(c, true) end
    function handle:SetSilent(c) setColor(c, false) end

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
        Size = UDim2.new(1, -4, 0, 28),
        BackgroundColor3 = theme.surface,
        BorderSizePixel = 0,
        Text = cfg.Name or "Button",
        TextColor3 = theme.text,
        Font = FONT_SEMI,
        TextSize = 13,
        AutoButtonColor = false,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })
    corner(btn, 5)
    local btnStroke = stroke(btn, theme.border, 1)

    local armedForConfirm = false
    local armedUntil = 0

    btn.MouseEnter:Connect(function()
        if armedForConfirm then return end
        tween(btn, { BackgroundColor3 = theme.surfaceHi }, T_FAST)
        tween(btnStroke, { Color = theme.borderHi }, T_FAST)
    end)
    btn.MouseLeave:Connect(function()
        if armedForConfirm then return end
        tween(btn, { BackgroundColor3 = theme.surface }, T_FAST)
        tween(btnStroke, { Color = theme.border }, T_FAST)
    end)
    -- Quick press feedback: a small dip then release.
    btn.MouseButton1Down:Connect(function()
        if armedForConfirm then return end
        tween(btn, { BackgroundColor3 = theme.surface }, 0.06)
    end)
    btn.MouseButton1Up:Connect(function()
        if armedForConfirm then return end
        tween(btn, { BackgroundColor3 = theme.surfaceHi }, T_FAST)
    end)

    btn.MouseButton1Click:Connect(function()
        if cfg.Confirm then
            if armedForConfirm and tick() < armedUntil then
                armedForConfirm = false
                btn.Text = cfg.Name or "Button"
                tween(btn, { BackgroundColor3 = theme.surface }, T_FAST)
                tween(btnStroke, { Color = theme.border }, T_FAST)
                if cfg.Callback then task.spawn(cfg.Callback) end
                return
            end
            armedForConfirm = true
            armedUntil = tick() + 0.5
            btn.Text = "Click again to confirm"
            tween(btn, { BackgroundColor3 = theme.danger }, T_FAST)
            tween(btnStroke, { Color = theme.danger }, T_FAST)
            task.delay(0.5, function()
                if tick() >= armedUntil then
                    armedForConfirm = false
                    btn.Text = cfg.Name or "Button"
                    tween(btn, { BackgroundColor3 = theme.surface }, T_FAST)
                    tween(btnStroke, { Color = theme.border }, T_FAST)
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

-- =========================================================================
-- Input — single-line text box with a name label.
-- =========================================================================
function Section:CreateInput(cfg)
    cfg = cfg or {}
    local theme = self.tab.window.theme

    local currentText = cfg.CurrentValue or ""
    local handle = {
        Type = "Input",
        Name = cfg.Name or "Input",
    }

    local row = Create("Frame", {
        Size = UDim2.new(1, -4, 0, 26),
        BackgroundTransparency = 1,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })

    local nameLabel = Create("TextLabel", {
        Size = UDim2.new(0.45, -4, 1, 0),
        Position = UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1,
        Text = cfg.Name or "Input",
        TextColor3 = theme.text,
        Font = FONT_SEMI,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    })

    local box = Create("TextBox", {
        Size = UDim2.new(0.55, -2, 0, 22),
        Position = UDim2.new(0.45, 2, 0.5, -11),
        BackgroundColor3 = theme.surface,
        BorderSizePixel = 0,
        Text = currentText,
        PlaceholderText = cfg.PlaceholderText or "",
        PlaceholderColor3 = theme.textDim,
        TextColor3 = theme.text,
        Font = FONT,
        TextSize = 12,
        ClearTextOnFocus = cfg.ClearTextOnFocus == true,
        Parent = row,
    })
    corner(box, 4)
    stroke(box, theme.border, 1)

    local function fireCallback()
        currentText = box.Text
        if cfg.Callback then
            task.spawn(cfg.Callback, currentText)
        end
    end

    box.FocusLost:Connect(function(enterPressed)
        fireCallback()
    end)

    -- Optional: fire on text change (debounced)
    if cfg.Immediate == true then
        local debounce
        box:GetPropertyChangedSignal("Text"):Connect(function()
            if debounce then task.cancel(debounce) end
            debounce = task.delay(0.3, function()
                debounce = nil
                fireCallback()
            end)
        end)
    end

    function handle:Get() return currentText end

    function handle:Set(text)
        if type(text) ~= "string" then return end
        currentText = text
        box.Text = text
        fireCallback()
    end

    function handle:SetSilent(text)
        if type(text) ~= "string" then return end
        currentText = text
        box.Text = text
    end

    return handle
end

-- =========================================================================
-- Divider — a thin themed separator, optionally with a centered label.
-- =========================================================================
function Section:CreateDivider(cfg)
    cfg = cfg or {}
    local theme = self.tab.window.theme
    local text  = type(cfg) == "string" and cfg or cfg.Text

    local row = Create("Frame", {
        Size = UDim2.new(1, -4, 0, text and 18 or 10),
        BackgroundTransparency = 1,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })

    local function makeLine(xScale, xOff, wScale, wOff)
        local line = Create("Frame", {
            Size = UDim2.new(wScale, wOff, 0, 1),
            Position = UDim2.new(xScale, xOff, 0.5, 0),
            BackgroundColor3 = theme.border,
            BorderSizePixel = 0,
            Parent = row,
        })
        Create("UIGradient", {
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.6),
                NumberSequenceKeypoint.new(0.5, 0),
                NumberSequenceKeypoint.new(1, 0.6),
            }),
            Parent = line,
        })
        return line
    end

    if text then
        Create("TextLabel", {
            Size = UDim2.new(0, 0, 1, 0),
            AutomaticSize = Enum.AutomaticSize.X,
            Position = UDim2.new(0.5, 0, 0, 0),
            AnchorPoint = Vector2.new(0.5, 0),
            BackgroundTransparency = 1,
            Text = " " .. tostring(text) .. " ",
            TextColor3 = theme.textDim,
            Font = FONT_SEMI,
            TextSize = 11,
            Parent = row,
        })
        makeLine(0, 0, 0.5, -28)
        makeLine(0.5, 28, 0.5, -28)
    else
        makeLine(0, 0, 1, 0)
    end

    local handle = { Type = "Divider" }
    function handle:Destroy() row:Destroy() end
    return handle
end

-- =========================================================================
-- Image — an in-panel picture row (logo, banner, preview).
-- =========================================================================
-- cfg.Image (rbxassetid), cfg.Height (default 80), cfg.Rounding,
-- cfg.ScaleType, cfg.Color (ImageColor3 tint). Returns a handle with
-- :SetImage / :SetColor / :Destroy.
function Section:CreateImage(cfg)
    cfg = cfg or {}
    local theme = self.tab.window.theme

    local frame = Create("ImageLabel", {
        Size = UDim2.new(1, -4, 0, cfg.Height or 80),
        BackgroundColor3 = theme.surface,
        BackgroundTransparency = cfg.Background == false and 1 or 0,
        BorderSizePixel = 0,
        Image = tostring(cfg.Image or ""),
        ImageColor3 = (typeof(cfg.Color) == "Color3") and cfg.Color or Color3.new(1, 1, 1),
        ScaleType = cfg.ScaleType or Enum.ScaleType.Fit,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })
    corner(frame, cfg.Rounding or 6)
    if cfg.Background ~= false then stroke(frame, theme.border, 1) end

    local handle = { Type = "Image" }
    function handle:SetImage(i) frame.Image = tostring(i) end
    function handle:SetColor(c) if typeof(c) == "Color3" then frame.ImageColor3 = c end end
    function handle:GetInstance() return frame end
    function handle:Destroy() frame:Destroy() end
    return handle
end

-- =========================================================================
-- Custom — escape hatch for fully bespoke widgets.
-- =========================================================================
-- Creates a themed container row and hands it to your builder along with the
-- window theme and the styling Util kit, so a script can render anything it
-- likes while still matching the rest of the UI:
--
--     Section:CreateCustom({ Height = 60 }, function(box, theme, U)
--         local b = U.Create("TextButton", { Size = UDim2.fromScale(1,1),
--             BackgroundColor3 = theme.surface, Text = "Hi", Parent = box })
--         U.corner(b, 6) ; U.stroke(b, theme.accent, 1)
--     end)
--
-- Pass Height for a fixed-height row, or Auto = true to size to contents.
-- Returns a handle with :GetInstance() (the container) and :Destroy().
function Section:CreateCustom(cfg, builder)
    if type(cfg) == "function" then builder, cfg = cfg, {} end
    cfg = cfg or {}
    local theme = self.tab.window.theme

    local box = Create("Frame", {
        Size = UDim2.new(1, -4, 0, cfg.Auto and 0 or (cfg.Height or 40)),
        AutomaticSize = cfg.Auto and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
        BackgroundColor3 = theme.surface,
        BackgroundTransparency = cfg.Background == false and 1 or 0,
        BorderSizePixel = 0,
        LayoutOrder = self:_next(),
        Parent = self.container,
    })
    if cfg.Background ~= false then
        corner(box, cfg.Rounding or 6)
        stroke(box, theme.border, 1)
    end

    if type(builder) == "function" then
        local ok, err = pcall(builder, box, theme, OvertimeUI.Util)
        if not ok then warn("[OvertimeUI] CreateCustom builder error: " .. tostring(err)) end
    end

    local handle = { Type = "Custom" }
    function handle:GetInstance() return box end
    function handle:Destroy() box:Destroy() end
    return handle
end

-- LayoutOrder counter so items show up in the order they were added even
-- though they share a parent UIListLayout.
function Section:_next()
    -- Every control builder calls _next() before it lays anything out, so this
    -- is the single chokepoint that re-asserts the owning window's style. Keeps
    -- deferred control creation (and coexisting differently-styled windows)
    -- on-style without an applyStyle() call in each Create* method.
    local w = self.tab and self.tab.window
    if w and w.style then applyStyle(w.style) end
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
    if window.style then applyStyle(window.style) end

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

    -- Header row = a transparent list item holding the accent tick + the
    -- title. The page's UIListLayout overrides a child's Position, so the
    -- tick can't live directly on the laid-out label (it would land at x=0,
    -- overprinting the first letter — that's what turned "INFO" into "NFO").
    -- Wrapping them in this non-laid-out frame lets both sit where we put
    -- them: tick in the control column, title indented just past it.
    local headerRow = Create("Frame", {
        Size = UDim2.new(1, -10, 0, 16),
        BackgroundTransparency = 1,
        LayoutOrder = sectionOrder * 1000 + 1,
        Parent = self.page,
    })
    local tick = Create("Frame", {
        Size = UDim2.fromOffset(3, 11),
        Position = UDim2.new(0, 2, 0.5, -5),
        BackgroundColor3 = theme.accent,
        BorderSizePixel = 0,
        Parent = headerRow,
    })
    corner(tick, 2)
    applyAccentGradient(tick, window.accentGradient, 90)
    local header = Create("TextLabel", {
        Size = UDim2.new(1, -12, 1, 0),
        Position = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Text = string.upper(name or "Section"),
        TextColor3 = theme.accent,
        Font = FONT_BOLD,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = headerRow,
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
        Padding = UDim.new(0, math.max(0, math.floor((window.style and window.style.spacing) or 2))),
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
-- Groupboxes — two-column "cheat menu" layout (Linoria-style)
-- =========================================================================
-- Tab:CreateLeftGroupbox(name) / CreateRightGroupbox(name) each return a
-- Section handle (same metatable — every Section:CreateX works inside) rendered
-- as a bordered, titled CARD stacked in the left or right column. The first
-- call lazily builds the two-column container inside the tab page; you can stack
-- as many groupboxes per column as you like and they pack densely. Pick ONE
-- layout per tab: either CreateSection (single column) or groupboxes (two
-- columns) — don't mix them in the same tab.

function Tab:_ensureColumns()
    if self._columns then return self._columns end
    local window = self.window
    if window.style then applyStyle(window.style) end

    local row = Create("Frame", {
        Name = "Columns",
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        Parent = self.page,
    })
    Create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 8),
        VerticalAlignment = Enum.VerticalAlignment.Top,
        Parent = row,
    })

    local function makeColumn(order)
        local col = Create("Frame", {
            Size = UDim2.new(0.5, -6, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            LayoutOrder = order,
            Parent = row,
        })
        Create("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 8),
            Parent = col,
        })
        return col
    end

    self._columns = { left = makeColumn(1), right = makeColumn(2) }
    return self._columns
end

function Tab:CreateGroupbox(side, name)
    local window = self.window
    if window.style then applyStyle(window.style) end
    local theme = window.theme
    local cols  = self:_ensureColumns()
    local parentCol = (side == "right") and cols.right or cols.left

    -- The card itself: a bordered, optionally-gradient-framed surface that grows
    -- to fit its controls.
    local card = Create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = theme.bgAlt,
        BorderSizePixel = 0,
        LayoutOrder = (#self.sections + 1),
        Parent = parentCol,
    })
    corner(card, 6)
    depthStroke(card, theme.border, theme.borderHi)
    depthFill(card, 0.06)

    local header = Create("TextLabel", {
        Size = UDim2.new(1, -20, 0, 26),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Text = string.upper(name or "Group"),
        TextColor3 = theme.accent,
        Font = FONT_BOLD,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = card,
    })
    -- A faint divider under the header gives the card a "titled panel" read.
    local hsep = Create("Frame", {
        Size = UDim2.new(1, -20, 0, 1),
        Position = UDim2.new(0, 10, 0, 25),
        BackgroundColor3 = theme.border,
        BorderSizePixel = 0,
        Parent = card,
    })
    applyAccentGradient(hsep, window.accentGradient, 0)

    -- Inner container holds the controls; positioned below the header, grows
    -- downward. A bottom padding keeps the last control off the card edge.
    local container = Create("Frame", {
        Size = UDim2.new(1, -20, 0, 0),
        Position = UDim2.new(0, 10, 0, 30),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = card,
    })
    Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, math.max(0, math.floor((window.style and window.style.spacing) or 2))),
        Parent = container,
    })
    Create("UIPadding", { PaddingBottom = UDim.new(0, 10), Parent = container })

    local section = setmetatable({
        tab = self,
        name = name,
        header = header,
        container = container,
        card = card,
    }, Section)
    table.insert(self.sections, section)
    return section
end

function Tab:CreateLeftGroupbox(name)  return self:CreateGroupbox("left",  name) end
function Tab:CreateRightGroupbox(name) return self:CreateGroupbox("right", name) end

-- =========================================================================
-- Window
-- =========================================================================

local Window = {}
Window.__index = Window

-- CreateTab(name)  or  CreateTab(name, { Icon = "rbxassetid://..." })
-- A second string arg is also accepted as the icon, so CreateTab(name, iconId)
-- works too.
function Window:CreateTab(name, opts)
    local theme = self.theme
    if self.style then applyStyle(self.style) end

    local iconId
    if type(opts) == "table" then iconId = opts.Icon
    elseif type(opts) == "string" then iconId = opts end

    local tab = setmetatable({
        window = self,
        name = name,
        sections = {},
    }, Tab)

    local topTabs  = (self.style.layout == "top")
    local tabHeight = math.max(20, math.floor(self.style.tabHeight))

    -- Tab strip button. The label is a separate child TextLabel (not button.Text)
    -- so an optional icon can sit to its left with a guaranteed gap — relying on
    -- the button's own text + UIPadding to clear an icon is unreliable. Left
    -- layout: a full-width row. Top layout: an auto-width pill that fits its
    -- contents (the label drives the width via AutomaticSize).
    local leftInset = iconId and 30 or 12   -- where the label starts
    local button
    if topTabs then
        button = Create("TextButton", {
            Size = UDim2.new(0, 0, 1, 0),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundColor3 = theme.bgAlt,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            LayoutOrder = #self.tabs + 1,
            Parent = self._tabStrip,
        })
        Create("UIPadding", { PaddingRight = UDim.new(0, 14), Parent = button })
    else
        button = Create("TextButton", {
            Size = UDim2.new(1, -8, 0, tabHeight),
            BackgroundColor3 = theme.bgAlt,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            LayoutOrder = #self.tabs + 1,
            Parent = self._tabStrip,
        })
    end
    corner(button, 6)
    tab.button = button

    -- The label. AutomaticSize.X in top layout so the pill grows to fit it.
    local label = Create("TextLabel", {
        Name = "Label",
        Size = topTabs and UDim2.new(0, 0, 1, 0) or UDim2.new(1, -(leftInset + 8), 1, 0),
        AutomaticSize = topTabs and Enum.AutomaticSize.X or Enum.AutomaticSize.None,
        Position = UDim2.new(0, leftInset, 0, 0),
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = theme.textDim,
        Font = FONT_SEMI,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = button,
    })
    tab._label = label

    -- Optional tab icon, left of the label. Tint follows active state (SwitchTab).
    if iconId then
        tab._icon = Create("ImageLabel", {
            Name = "Icon",
            Size = UDim2.fromOffset(16, 16),
            Position = UDim2.new(0, 8, 0.5, -8),
            BackgroundTransparency = 1,
            Image = iconId,
            ImageColor3 = theme.textDim,
            ZIndex = 2,
            Parent = button,
        })
    end

    -- Accent indicator. Left layout: a vertical bar on the row's left edge that
    -- grows from zero height when selected. Top layout: a horizontal underline
    -- that grows from zero width. Active/idle target sizes are stashed on the
    -- tab so SwitchTab can animate to the right orientation.
    local indicator
    if topTabs then
        indicator = Create("Frame", {
            Size = UDim2.new(0, 0, 0, 2),
            Position = UDim2.new(0.5, 0, 1, -1),
            AnchorPoint = Vector2.new(0.5, 1),
            BackgroundColor3 = theme.accent,
            BorderSizePixel = 0,
            Parent = button,
        })
        tab._indicatorActive = UDim2.new(1, -10, 0, 2)
        tab._indicatorIdle   = UDim2.new(0, 0, 0, 2)
    else
        local indH = math.clamp(math.floor(tabHeight * 0.53), 8, tabHeight)
        indicator = Create("Frame", {
            Size = UDim2.new(0, 3, 0, 0),
            Position = UDim2.new(0, 0, 0.5, 0),
            AnchorPoint = Vector2.new(0, 0.5),
            BackgroundColor3 = theme.accent,
            BorderSizePixel = 0,
            Parent = button,
        })
        tab._indicatorActive = UDim2.new(0, 3, 0, indH)
        tab._indicatorIdle   = UDim2.new(0, 3, 0, 0)
    end
    corner(indicator, 2)
    applyAccentGradient(indicator, self.accentGradient, topTabs and 0 or 90)
    tab.indicator = indicator

    button.MouseEnter:Connect(function()
        if self.activeTab == tab then return end
        tween(button, { BackgroundTransparency = 0.4 }, T_FAST)
        tween(label, { TextColor3 = theme.text }, T_FAST)
    end)
    button.MouseLeave:Connect(function()
        if self.activeTab == tab then return end
        tween(button, { BackgroundTransparency = 1 }, T_FAST)
        tween(label, { TextColor3 = theme.textDim }, T_FAST)
    end)

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
    local bp = math.max(0, math.floor(self.style.bodyPadding))
    Create("UIPadding", {
        PaddingTop = UDim.new(0, math.max(4, bp - 4)),
        PaddingBottom = UDim.new(0, bp),
        PaddingLeft = UDim.new(0, bp),
        PaddingRight = UDim.new(0, bp + 4),
        Parent = page,
    })
    Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, math.max(0, math.floor(self.style.spacing))),
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
        tween(t.button, {
            BackgroundTransparency = active and 0 or 1,
            BackgroundColor3 = theme.surface,
        }, T_NORMAL)
        if t._label then
            tween(t._label, { TextColor3 = active and theme.accent or theme.textDim }, T_NORMAL)
        end
        if t.indicator then
            tween(t.indicator,
                { Size = active and t._indicatorActive or t._indicatorIdle },
                T_NORMAL)
        end
        if t._icon then
            tween(t._icon, { ImageColor3 = active and theme.accent or theme.textDim }, T_NORMAL)
        end
    end
    self.activeTab = tab
end

function Window:OnClose(cb)
    if type(cb) == "function" then
        table.insert(self.onCloseCallbacks, cb)
    end
end

-- =====================================================================
-- Visibility — Show / Hide / Toggle, animated to match the entrance.
-- =====================================================================
-- SetVisible(true)  scales the panel up from 0.92 + fades it in.
-- SetVisible(false) reverses it, then flips gui.Enabled off so a hidden
-- menu costs nothing to render and can't be clicked through.
function Window:SetVisible(state)
    if self._destroyed then return end
    state = not not state
    if state == self._visible then return end
    self._visible = state

    if state then
        self.gui.Enabled = true
        tween(self._scale, { Scale = 1 }, T_NORMAL, SPRING)
        tween(self.panel, { BackgroundTransparency = self._panelT or 0 }, T_NORMAL)
    else
        tween(self._scale, { Scale = 0.92 }, T_FAST)
        local tw = tween(self.panel, { BackgroundTransparency = 1 }, T_FAST)
        -- Disable the ScreenGui only once the fade-out has finished, and
        -- only if we haven't been re-shown in the meantime.
        tw.Completed:Connect(function()
            if not self._visible and not self._destroyed then
                self.gui.Enabled = false
            end
        end)
    end
end

function Window:Show()   self:SetVisible(true)  end
function Window:Hide()   self:SetVisible(false) end
function Window:Toggle() self:SetVisible(not self._visible) end
function Window:IsVisible() return self._visible end

-- =====================================================================
-- Toggle key — bind a keyboard key (or LMB/RMB/MMB) to show/hide the menu.
-- =====================================================================
-- Accepts the same string form as the keybind controls ("RightShift",
-- "Insert", "MouseButton3", ...) or "None"/nil to clear. Re-calling it
-- replaces the previous binding. The listener is torn down on Destroy.
function Window:SetToggleKey(keyStr)
    if self._toggleConn then
        self._toggleConn:Disconnect()
        self._toggleConn = nil
    end
    self._toggleKey = keyStr

    -- Register a one-time cleanup that always disconnects whatever the
    -- current binding is, so re-binding never leaks connections.
    if not self._toggleCleanupRegistered then
        self._toggleCleanupRegistered = true
        table.insert(self._cleanup, function()
            if self._toggleConn then
                self._toggleConn:Disconnect()
                self._toggleConn = nil
            end
        end)
    end

    if not keyStr or keyStr == "" or keyStr == "None" or keyStr == "Unknown" then
        return
    end

    self._toggleConn = UIS.InputBegan:Connect(function(input, gameProcessed)
        -- gameProcessed is true when the input was already consumed by
        -- the engine (e.g. the user is typing in a TextBox) — ignore it
        -- so the toggle key doesn't fire mid-edit.
        if gameProcessed then return end
        local pressed = inputObjectToKeybind(input)
        if pressed and pressed == self._toggleKey then
            self:Toggle()
        end
    end)
end

function Window:GetToggleKey() return self._toggleKey or "None" end

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

-- Merge a named Preset under an explicit config. Preset fields are the base;
-- whatever the caller passes alongside `Preset` wins. Theme/Style sub-tables are
-- deep-merged (so `{Preset="Aurora", Theme={accent=...}}` keeps Aurora's other
-- colours); all other keys are replaced wholesale. Returns the merged config.
local function mergePreset(cfg)
    local preset = cfg.Preset and OvertimeUI.Presets[cfg.Preset]
    if type(preset) ~= "table" then return cfg end
    local out = {}
    for k, v in pairs(preset) do out[k] = v end
    for k, v in pairs(cfg) do
        if (k == "Theme" or k == "Style") and type(v) == "table" and type(out[k]) == "table" then
            local merged = {}
            for kk, vv in pairs(out[k]) do merged[kk] = vv end
            for kk, vv in pairs(v)      do merged[kk] = vv end
            out[k] = merged
        else
            out[k] = v
        end
    end
    return out
end

function OvertimeUI:CreateWindow(cfg)
    cfg = mergePreset(cfg or {})
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
    -- Full palette override: pass any subset of theme keys (bg, surface,
    -- border, accent, text, ...) and they're merged over the defaults, so
    -- each script can give its menu a unique look. Accent stays as a
    -- dedicated shortcut.
    if type(cfg.Theme) == "table" then
        for k, v in pairs(cfg.Theme) do
            if typeof(v) == "Color3" then self.theme[k] = v end
        end
    end
    if typeof(cfg.Accent) == "Color3" then self.theme.accent = cfg.Accent end

    -- Accent gradient (optional). When set, the title stripe, tab indicators,
    -- and section ticks become a colour sweep instead of one flat accent.
    -- Accepts a ColorSequence or a {Color3, Color3, ...} list. Not a Color3, so
    -- it can't ride in the Theme table — it lives on the window and is read by
    -- the structural builders via applyAccentGradient().
    do
        local g = cfg.AccentGradient
        if g == nil and type(cfg.Theme) == "table" then g = cfg.Theme.accentGradient end
        if typeof(g) == "ColorSequence" or type(g) == "table" then
            self.accentGradient = g
        end
    end

    -- Structural style (non-color). Resolve from cfg.Style (a table) and/or the
    -- top-level shorthand fields, then push it into the module upvalues so this
    -- window's whole tree builds on-style. Re-asserted by Section:_next().
    self.style = defaultStyle()
    do
        local st = type(cfg.Style) == "table" and cfg.Style or {}
        local function pick(a, b) if a ~= nil then return a else return b end end
        -- numbers: take the override only if it's actually a number, else keep
        -- the default already sitting in self.style.
        local function num(a, b)
            local v = pick(a, b)
            if type(v) == "number" then return v end
            return nil
        end
        self.style.roundness = pick(cfg.Roundness, st.roundness)
        if type(self.style.roundness) ~= "number" then self.style.roundness = 1 end
        self.style.font     = pick(cfg.Font,     st.font)     or DEFAULT_FONT
        self.style.fontBold = pick(cfg.FontBold, st.fontBold) or DEFAULT_FONT_BOLD
        self.style.fontSemi = pick(cfg.FontSemi, st.fontSemi) or DEFAULT_FONT_SEMI
        local sh = pick(cfg.Shadow, st.shadow); self.style.shadow = (sh ~= false)
        local sn = pick(cfg.Sheen,  st.sheen);  self.style.sheen  = (sn ~= false)
        local sp = pick(cfg.Stripe, st.stripe); self.style.stripe = (sp ~= false)

        -- Depth flags default OFF, so they only turn on when explicitly enabled.
        self.style.gradientStroke = pick(cfg.GradientStroke, st.gradientStroke) == true
        self.style.accentGlow     = pick(cfg.AccentGlow,     st.accentGlow)     == true
        self.style.gradientFill   = pick(cfg.GradientFill,   st.gradientFill)   == true

        -- New structural tokens — each falls back to the default in
        -- defaultStyle() when the override is missing or the wrong type.
        self.style.strokeThickness    = num(cfg.StrokeThickness, st.strokeThickness) or self.style.strokeThickness
        self.style.animation          = num(cfg.Animation,       st.animation)       or self.style.animation
        self.style.sheenStrength      = num(nil,                 st.sheenStrength)     or self.style.sheenStrength
        self.style.shadowSpread       = num(nil,                 st.shadowSpread)      or self.style.shadowSpread
        self.style.shadowTransparency = num(nil,                 st.shadowTransparency) or self.style.shadowTransparency
        self.style.panelTransparency  = num(cfg.PanelTransparency, st.panelTransparency) or self.style.panelTransparency
        self.style.titleHeight        = num(cfg.TitleHeight,     st.titleHeight)       or self.style.titleHeight
        self.style.tabWidth           = num(cfg.TabWidth,        st.tabWidth)          or self.style.tabWidth
        self.style.tabHeight          = num(cfg.TabHeight,       st.tabHeight)         or self.style.tabHeight
        self.style.bodyPadding        = num(cfg.BodyPadding,     st.bodyPadding)       or self.style.bodyPadding
        self.style.spacing            = num(cfg.Spacing,         st.spacing)           or self.style.spacing

        local layout = pick(cfg.Layout, st.layout)
        if layout == "top" or layout == "left" then self.style.layout = layout end
        local talign = pick(cfg.TitleAlign, st.titleAlign)
        if talign == "center" or talign == "left" then self.style.titleAlign = talign end

        local ti = pick(cfg.TitleIcon, st.titleIcon)
        if type(ti) == "string" then self.style.titleIcon = ti end
        local bg = pick(cfg.BackgroundImage, st.backgroundImage)
        if type(bg) == "string" then self.style.backgroundImage = bg end
        self.style.backgroundImageTransparency =
            num(cfg.BackgroundImageTransparency, st.backgroundImageTransparency)
            or self.style.backgroundImageTransparency
    end
    applyStyle(self.style)

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

    -- Resolved structural style — pulled into locals so the construction below
    -- reads off the window's tokens instead of magic numbers. Defaults in
    -- defaultStyle() reproduce the original fixed look exactly.
    local S        = self.style
    local titleH   = math.max(20, math.floor(S.titleHeight))
    local panelT   = math.clamp(S.panelTransparency or 0, 0, 1)
    local topTabs  = (S.layout == "top")
    local tabW     = math.max(48, math.floor(S.tabWidth))
    local topStripH = math.max(24, math.floor(S.tabHeight) + 8) -- top-layout strip height
    local GAP      = 8

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
        ZIndex = 2,
        Parent = gui,
    })
    corner(panel, 10)
    depthStroke(panel, self.theme.border, self.theme.borderHi)
    if S.sheen then sheen(panel, S.sheenStrength) end
    depthFill(panel, 0.05)
    self.panel = panel

    -- Optional background texture, behind every other panel child. ZIndex 0 so
    -- it sits under the title bar (ZIndex 3) and content (default 1). Clipped to
    -- the panel's rounded corners by a matching UICorner.
    if S.backgroundImage then
        local bgImg = Create("ImageLabel", {
            Name = "Background",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Image = S.backgroundImage,
            ImageTransparency = math.clamp(S.backgroundImageTransparency or 0.85, 0, 1),
            ScaleType = Enum.ScaleType.Crop,
            ZIndex = 0,
            Parent = panel,
        })
        corner(bgImg, 10)
    end

    -- Drop shadow lives in a sibling holder *behind* the panel (a child of
    -- the panel would render in front of its fill). The holder mirrors the
    -- panel's transform; drag/minimize update it alongside the panel.
    local shadowHolder = Create("Frame", {
        Name = "PanelShadow",
        Size = size,
        Position = pos,
        BackgroundTransparency = 1,
        ZIndex = 1,
        Parent = gui,
    })
    -- The ONE shadow in the whole UI: a single soft drop behind the root
    -- window so it lifts off the game world. Spread / faintness are style tokens.
    if S.shadow then shadow(shadowHolder, S.shadowSpread, S.shadowTransparency) end
    -- Accent glow: a wide, faint, layered accent halo behind the panel so it
    -- reads as ambient light rather than a glowing box. Only when accentGlow is on.
    accentGlowBehind(shadowHolder, self.theme.accentGlow or self.theme.accent,
        0.80, math.max(S.shadowSpread, 34))
    self._shadowHolder = shadowHolder

    -- Entrance: gentle scale-up + fade so the window arrives instead of
    -- popping. UIScale keeps the centre anchored and is reused by
    -- Show/Hide so visibility toggles animate the same way. The rest-state
    -- transparency is panelT (so glass panels stay glassy after the fade-in).
    local entrance = Create("UIScale", { Scale = 0.92, Parent = panel })
    self._scale = entrance
    self._visible = true
    self._panelT = panelT
    panel.BackgroundTransparency = 1
    tween(entrance, { Scale = 1 }, T_SLOW, SPRING)
    tween(panel, { BackgroundTransparency = panelT }, T_SLOW)

    -- Title bar. Active = true so InputBegan fires on this Frame when
    -- the user clicks it (Frames with Active = false pass clicks through).
    local titleBar = Create("Frame", {
        Name = "TitleBar",
        Size = UDim2.new(1, 0, 0, titleH),
        BackgroundTransparency = 1,
        Active = true,
        ZIndex = 3,
        Parent = panel,
    })

    -- A title icon (logo) takes the place of the accent stripe when present.
    local textLeft = 24
    if S.titleIcon then
        local iconSz = math.min(titleH - 10, 22)
        Create("ImageLabel", {
            Size = UDim2.fromOffset(iconSz, iconSz),
            Position = UDim2.new(0, 12, 0.5, -math.floor(iconSz / 2)),
            BackgroundTransparency = 1,
            Image = S.titleIcon,
            ZIndex = 3,
            Parent = titleBar,
        })
        textLeft = 12 + iconSz + 8
    else
        local stripeH = math.max(10, math.floor(titleH * 0.5))
        local accentStripe = Create("Frame", {
            Size = UDim2.fromOffset(4, stripeH),
            Position = UDim2.new(0, 12, 0.5, -math.floor(stripeH / 2)),
            BackgroundColor3 = self.theme.accent,
            BorderSizePixel = 0,
            ZIndex = 3,
            Visible = S.stripe,
            Parent = titleBar,
        })
        corner(accentStripe, 2)
        applyAccentGradient(accentStripe, self.accentGradient, 90)
    end

    local centered = (S.titleAlign == "center")
    local titleXAlign = centered and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
    local titleX = centered and 0 or textLeft
    local titleWidth = centered and 0 or -(textLeft + 76)
    Create("TextLabel", {
        Size = UDim2.new(1, titleWidth, 0, cfg.SubTitle and math.floor(titleH * 0.5) or titleH),
        Position = UDim2.new(0, titleX, 0, cfg.SubTitle and math.floor(titleH * 0.12) or 0),
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = self.theme.text,
        Font = FONT_BOLD,
        TextSize = 15,
        TextXAlignment = titleXAlign,
        TextYAlignment = cfg.SubTitle and Enum.TextYAlignment.Bottom or Enum.TextYAlignment.Center,
        ZIndex = 3,
        Parent = titleBar,
    })
    if cfg.SubTitle then
        Create("TextLabel", {
            Size = UDim2.new(1, titleWidth, 0, math.floor(titleH * 0.34)),
            Position = UDim2.new(0, titleX, 0, math.floor(titleH * 0.56)),
            BackgroundTransparency = 1,
            Text = tostring(cfg.SubTitle),
            TextColor3 = self.theme.textDim,
            Font = FONT,
            TextSize = 11,
            TextXAlignment = titleXAlign,
            ZIndex = 3,
            Parent = titleBar,
        })
    end

    local btnY = math.max(0, math.floor((titleH - 24) / 2))
    local function makeIconBtn(icon, color, xOffset)
        local b = Create("TextButton", {
            Size = UDim2.fromOffset(24, 24),
            Position = UDim2.new(1, xOffset, 0, btnY),
            BackgroundColor3 = self.theme.surface,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = icon,
            TextColor3 = color,
            Font = FONT_BOLD,
            TextSize = 15,
            AutoButtonColor = false,
            ZIndex = 4,
            Parent = titleBar,
        })
        corner(b, 6)
        b.MouseEnter:Connect(function()
            tween(b, { BackgroundTransparency = 0, BackgroundColor3 = color }, T_FAST)
            tween(b, { TextColor3 = self.theme.bg }, T_FAST)
        end)
        b.MouseLeave:Connect(function()
            tween(b, { BackgroundTransparency = 1 }, T_FAST)
            tween(b, { TextColor3 = color }, T_FAST)
        end)
        return b
    end
    local closeBtn = makeIconBtn("×", self.theme.danger, -32)
    local minBtn   = makeIconBtn("–", self.theme.textDim, -60)

    closeBtn.MouseButton1Click:Connect(function() self:Destroy() end)

    -- Title separator — a 1px line that fades toward both ends.
    local sep = Create("Frame", {
        Size = UDim2.new(1, -24, 0, 1),
        Position = UDim2.new(0, 12, 0, titleH + 1),
        BackgroundColor3 = self.theme.borderHi,
        BorderSizePixel = 0,
        ZIndex = 3,
        Parent = panel,
    })
    Create("UIGradient", {
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.15, 0),
            NumberSequenceKeypoint.new(0.85, 0),
            NumberSequenceKeypoint.new(1, 1),
        }),
        Parent = sep,
    })

    -- Content container sits below the title bar. The tab strip / tab body split
    -- inside it is horizontal (sidebar) for "left" layout or vertical (top bar)
    -- for "top" layout.
    local content = Create("Frame", {
        Name = "Content",
        Size = UDim2.new(1, -16, 1, -(titleH + 12)),
        Position = UDim2.new(0, 8, 0, titleH + 4),
        BackgroundTransparency = 1,
        Parent = panel,
    })
    self.content = content

    local tabStrip, tabBody
    if topTabs then
        -- Horizontal tab bar across the top of the content area.
        tabStrip = Create("Frame", {
            Name = "TabStrip",
            Size = UDim2.new(1, 0, 0, topStripH),
            BackgroundColor3 = self.theme.bgAlt,
            BorderSizePixel = 0,
            Parent = content,
        })
        corner(tabStrip, 8)
        Create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 4),
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Parent = tabStrip,
        })
        Create("UIPadding", {
            PaddingLeft = UDim.new(0, 6),
            PaddingRight = UDim.new(0, 6),
            Parent = tabStrip,
        })

        tabBody = Create("Frame", {
            Name = "TabBody",
            Size = UDim2.new(1, 0, 1, -(topStripH + GAP)),
            Position = UDim2.new(0, 0, 0, topStripH + GAP),
            BackgroundColor3 = self.theme.bgAlt,
            BorderSizePixel = 0,
            Parent = content,
        })
        corner(tabBody, 8)
    else
        -- Vertical sidebar of tabs on the left.
        tabStrip = Create("Frame", {
            Name = "TabStrip",
            Size = UDim2.new(0, tabW, 1, 0),
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

        tabBody = Create("Frame", {
            Name = "TabBody",
            Size = UDim2.new(1, -(tabW + GAP), 1, 0),
            Position = UDim2.new(0, tabW + GAP, 0, 0),
            BackgroundColor3 = self.theme.bgAlt,
            BorderSizePixel = 0,
            Parent = content,
        })
        corner(tabBody, 8)
    end
    -- Depth on the columns: frame them with a gradient edge and lift them with a
    -- subtle fill gradient. Gated on the flags, so the default columns stay
    -- borderless and flat exactly as before.
    if GRAD_STROKE then
        gradStroke(tabStrip, self.theme.border, self.theme.borderHi)
        gradStroke(tabBody,  self.theme.border, self.theme.borderHi)
    end
    depthFill(tabStrip, 0.06)
    depthFill(tabBody, 0.06)
    self._tabStrip = tabStrip
    self._tabBody  = tabBody

    -- Minimize behavior: collapse everything below the title bar.
    local minimized = false
    local fullSize = size
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        local target = minimized and UDim2.fromOffset(fullSize.X.Offset, titleH) or fullSize
        if minimized then content.Visible = false end
        tween(panel, { Size = target }, T_NORMAL)
        tween(shadowHolder, { Size = target }, T_NORMAL)
        minBtn.Text = minimized and "+" or "–"
        if not minimized then
            task.delay(T_NORMAL * 0.5 * math.max(ANIM, 0.01), function()
                if not minimized then content.Visible = true end
            end)
        end
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
                local newPos = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
                panel.Position = newPos
                shadowHolder.Position = newPos
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
    -- Adopt an existing container if one's already in PlayerGui. Each
    -- loadstring(OvertimeUI)() builds a fresh module with its own nil
    -- notifyGui upvalue, so without this every script re-load would spawn
    -- another empty ScreenGui that never gets cleaned up. Reusing by name
    -- keeps exactly one shared container no matter how many times we load.
    local parent = LP:FindFirstChild("PlayerGui") or game:GetService("CoreGui")
    local existing = parent:FindFirstChild("OvertimeUI_Notifications")
    if existing then
        notifyGui = existing
        notifyStack = existing:FindFirstChild("Stack")
        if notifyStack then return end
        existing:ClearAllChildren()
    else
        notifyGui = Create("ScreenGui", {
            Name = "OvertimeUI_Notifications",
            ResetOnSpawn = false,
            ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
            IgnoreGuiInset = true,
            Parent = parent,
        })
    end
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
        BackgroundColor3 = theme.bgAlt,
        BorderSizePixel = 0,
        LayoutOrder = notifyOrder,
        Parent = notifyStack,
    })
    corner(toast, 8)
    stroke(toast, theme.borderHi, 1)

    local stripe = Create("Frame", {
        Size = UDim2.new(0, 3, 1, -14),
        Position = UDim2.new(0, 8, 0, 7),
        BackgroundColor3 = theme.accent,
        BorderSizePixel = 0,
        ZIndex = 2,
        Parent = toast,
    })
    corner(stripe, 2)

    -- Countdown bar pinned to the bottom edge; shrinks to zero over the
    -- toast's lifetime so the user can see how long it'll stay up.
    local progress = Create("Frame", {
        Size = UDim2.new(1, -16, 0, 2),
        Position = UDim2.new(0, 8, 1, -5),
        AnchorPoint = Vector2.new(0, 0),
        BackgroundColor3 = theme.accent,
        BorderSizePixel = 0,
        ZIndex = 2,
        Parent = toast,
    })
    corner(progress, 1)

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

    -- Linear countdown bar over the full duration.
    TweenService:Create(progress,
        TweenInfo.new(duration, Enum.EasingStyle.Linear),
        { Size = UDim2.new(0, 0, 0, 2) }
    ):Play()

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

-- =========================================================================
-- Mouse freedom — force the cursor unlocked and visible.
-- =========================================================================
-- Many games re-lock the mouse to screen centre every frame (shift-lock,
-- first person, custom camera scripts). A one-shot
-- `UIS.MouseBehavior = Default` gets stomped on the next frame, so
-- SetMouseFree(true) re-asserts it on Heartbeat for as long as it's on.
--
-- SetMouseFree(false) must ACTIVELY hand the mouse back, not just stop
-- asserting: plenty of games only set their lock once (not every frame), so
-- merely disconnecting would leave the cursor free forever and you could
-- never swap back to playing. So on free we snapshot the game's mouse state
-- and on release we restore EXACTLY that snapshot — including a free/Default
-- state. A game that already had a free cursor gets its free cursor back; a
-- first-person game that had LockCenter gets locked play back. (Earlier this
-- force-LockCenter'd whenever the snapshot looked free, which wrongly locked
-- games that are meant to be played with a free mouse.) The state is
-- process-global (the mouse is shared); idempotent and safe to call repeatedly.

local mouseFreeConn
local mouseSavedBehavior, mouseSavedIcon
function OvertimeUI:SetMouseFree(state)
    state = state ~= false  -- nil/true -> free; false -> release
    if state then
        if mouseFreeConn then return end
        -- Snapshot what the game had so release can put it back.
        mouseSavedBehavior = UIS.MouseBehavior
        mouseSavedIcon     = UIS.MouseIconEnabled
        mouseFreeConn = RunService.Heartbeat:Connect(function()
            if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
                UIS.MouseBehavior = Enum.MouseBehavior.Default
            end
            if not UIS.MouseIconEnabled then
                UIS.MouseIconEnabled = true
            end
        end)
    elseif mouseFreeConn then
        mouseFreeConn:Disconnect()
        mouseFreeConn = nil
        -- Restore exactly what the game had when we freed it. If the snapshot
        -- was a free state, the game stays free — never force a lock the game
        -- didn't ask for.
        if mouseSavedBehavior ~= nil then
            UIS.MouseBehavior = mouseSavedBehavior
        end
        if mouseSavedIcon ~= nil then
            UIS.MouseIconEnabled = mouseSavedIcon
        end
        mouseSavedBehavior, mouseSavedIcon = nil, nil
    end
end

function OvertimeUI:IsMouseFree()
    return mouseFreeConn ~= nil
end

-- =========================================================================
-- Global key binding — run a callback on key press, independent of any
-- control or window.
-- =========================================================================
-- Accepts the same string form as the keybind controls ("F2", "Insert",
-- "MouseButton3", ...). Returns an unbind function; call it to remove the
-- binding. Bindings are NOT auto-cleaned by a window's Destroy (they're
-- standalone), so keep the returned function if the binding should be
-- temporary. gameProcessed input (e.g. typing in a TextBox) is ignored.
--
--     local unbind = UI:BindKey("F", function() print("F pressed") end)
--     ...
--     unbind()  -- later, to remove it
function OvertimeUI:BindKey(keyStr, callback)
    assert(type(callback) == "function", "[OvertimeUI] BindKey requires a callback function")
    if not keyStr or keyStr == "" or keyStr == "None" or keyStr == "Unknown" then
        return function() end
    end
    local conn = UIS.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if inputObjectToKeybind(input) == keyStr then
            task.spawn(callback)
        end
    end)
    return function()
        if conn then
            conn:Disconnect()
            conn = nil
        end
    end
end

-- =========================================================================
-- Overlay drawing kit — generic on-screen shapes for ESP, FOV rings,
-- crosshairs, tracers, watermarks, and freeform decoration.
-- =========================================================================
-- These are NOT tied to any window. Each shape is created on a shared,
-- lazily-built ScreenGui (or a Parent you pass in) and returns a handle.
-- Every handle supports a common set of setters/getters plus shape-specific
-- ones, and a :Destroy. Setters ignore wrong-typed input and no-op after
-- :Destroy, so they can be wired straight to slider/toggle/colorpicker
-- callbacks without guard wrappers, and they return the handle so calls
-- chain:
--
--     local ring = UI:CreateCircle{ Center = true, Radius = 120, Glow = true }
--     fovSlider.Callback   = function(v) ring:SetRadius(v) end
--     colorPicker.Callback = function(c) ring:SetColor(c) end
--     espToggle.Callback   = function(on) ring:SetVisible(on) end
--
-- The shared overlay sits above the game world; call SetOverlayDisplayOrder
-- to move it relative to your windows (negative = behind them, which is the
-- old FOV-circle behaviour).

local overlayGui
local OVERLAY_ORDER = 10

local function ensureOverlay()
    if overlayGui and overlayGui.Parent then return overlayGui end
    -- Adopt an existing overlay if present (see ensureNotifyContainer) so
    -- repeated script loads share one ScreenGui instead of leaving a trail
    -- of empty ones behind.
    local parent = LP:FindFirstChild("PlayerGui") or game:GetService("CoreGui")
    local existing = parent:FindFirstChild("OvertimeUI_Overlay")
    if existing then
        overlayGui = existing
        overlayGui.DisplayOrder = OVERLAY_ORDER
        return overlayGui
    end
    overlayGui = Create("ScreenGui", {
        Name = "OvertimeUI_Overlay",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = OVERLAY_ORDER,
        IgnoreGuiInset = true,
        Parent = parent,
    })
    return overlayGui
end

function OvertimeUI:SetOverlayDisplayOrder(n)
    if type(n) ~= "number" then return end
    OVERLAY_ORDER = n
    if overlayGui then overlayGui.DisplayOrder = n end
end

function OvertimeUI:GetOverlay()
    return ensureOverlay()
end

-- Common handle plumbing shared by the shapes: visibility, colour, position,
-- transparency, raw-instance access, destroy. `glowImg` is optional and is
-- retinted alongside the colour when present.
local function attachShapeCommon(handle, frame, glowImg)
    local destroyed = false
    handle.GetInstance = function() return frame end
    handle._isDestroyed = function() return destroyed end
    function handle:SetVisible(v) if not destroyed then frame.Visible = v ~= false end return self end
    function handle:IsVisible() return (not destroyed) and frame.Visible end
    function handle:SetPosition(p) if not destroyed and typeof(p) == "UDim2" then frame.Position = p end return self end
    function handle:GetPosition() return frame and frame.Position end
    function handle:SetColor(c)
        if destroyed or typeof(c) ~= "Color3" then return self end
        frame.BackgroundColor3 = c
        local st = frame:FindFirstChildOfClass("UIStroke")
        if st then st.Color = c end
        if glowImg then glowImg.ImageColor3 = c end
        return self
    end
    function handle:SetTransparency(t)
        if not destroyed and type(t) == "number" then frame.BackgroundTransparency = math.clamp(t, 0, 1) end
        return self
    end
    function handle:Destroy()
        if destroyed then return end
        destroyed = true
        if frame then frame:Destroy() frame = nil end
    end
    return handle
end

local function shapeParent(cfg) return (typeof(cfg.Parent) == "Instance") and cfg.Parent or ensureOverlay() end
local function shapeColor(cfg) return (typeof(cfg.Color) == "Color3") and cfg.Color or Color3.fromRGB(96, 165, 255) end

-- Circle / ring. The generic replacement for the old FOV circle: pass
-- Center = true to anchor it on the viewport crosshair, or Position for free
-- placement. Filled controls the interior; Glow adds a soft halo.
function OvertimeUI:CreateCircle(cfg)
    cfg = cfg or {}
    local color     = shapeColor(cfg)
    local radius    = (type(cfg.Radius) == "number") and math.max(cfg.Radius, 0) or 60
    local thickness = (type(cfg.Thickness) == "number") and math.max(cfg.Thickness, 0) or 2
    local filled    = cfg.Filled == true
    local fillTrans = (type(cfg.FillTransparency) == "number") and math.clamp(cfg.FillTransparency, 0, 1) or 0.8

    local frame = Create("Frame", {
        Name = cfg.Name or "Circle",
        AnchorPoint = (typeof(cfg.AnchorPoint) == "Vector2") and cfg.AnchorPoint or Vector2.new(0.5, 0.5),
        Position = (typeof(cfg.Position) == "UDim2") and cfg.Position
                   or (cfg.Center and UDim2.fromScale(0.5, 0.5) or UDim2.fromOffset(200, 200)),
        Size = UDim2.fromOffset(radius * 2, radius * 2),
        BackgroundColor3 = color,
        BackgroundTransparency = filled and fillTrans or 1,
        BorderSizePixel = 0,
        Visible = cfg.Visible ~= false,
        ZIndex = cfg.ZIndex or 1,
        Parent = shapeParent(cfg),
    })
    Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = frame })
    local strokeInst = Create("UIStroke", { Color = color, Thickness = thickness, Parent = frame })
    local glowImg = cfg.Glow and shadow(frame, cfg.GlowSpread or 16, cfg.GlowTransparency or 0.4, color) or nil

    local handle = { Type = "Circle" }
    attachShapeCommon(handle, frame, glowImg)
    function handle:SetRadius(r)
        if handle._isDestroyed() or type(r) ~= "number" then return self end
        radius = math.max(r, 0)
        frame.Size = UDim2.fromOffset(radius * 2, radius * 2)
        return self
    end
    function handle:GetRadius() return radius end
    function handle:SetThickness(t)
        if handle._isDestroyed() or type(t) ~= "number" then return self end
        thickness = math.max(t, 0)
        strokeInst.Thickness = thickness
        return self
    end
    function handle:SetFilled(f)
        if handle._isDestroyed() then return self end
        filled = f == true
        frame.BackgroundTransparency = filled and fillTrans or 1
        return self
    end
    function handle:SetFillTransparency(t)
        if handle._isDestroyed() or type(t) ~= "number" then return self end
        fillTrans = math.clamp(t, 0, 1)
        if filled then frame.BackgroundTransparency = fillTrans end
        return self
    end
    return handle
end

-- Rectangle / box. Good for ESP boxes and panels. Size accepts a UDim2 or a
-- number (square, in pixels). Rounding sets the corner radius.
function OvertimeUI:CreateSquare(cfg)
    cfg = cfg or {}
    local color     = shapeColor(cfg)
    local thickness = (type(cfg.Thickness) == "number") and math.max(cfg.Thickness, 0) or 2
    local filled    = cfg.Filled == true
    local fillTrans = (type(cfg.FillTransparency) == "number") and math.clamp(cfg.FillTransparency, 0, 1) or 0.85
    local size = (typeof(cfg.Size) == "UDim2") and cfg.Size
                 or (type(cfg.Size) == "number" and UDim2.fromOffset(cfg.Size, cfg.Size))
                 or UDim2.fromOffset(120, 120)

    local frame = Create("Frame", {
        Name = cfg.Name or "Square",
        AnchorPoint = (typeof(cfg.AnchorPoint) == "Vector2") and cfg.AnchorPoint or Vector2.new(0, 0),
        Position = (typeof(cfg.Position) == "UDim2") and cfg.Position or UDim2.fromOffset(200, 200),
        Size = size,
        BackgroundColor3 = color,
        BackgroundTransparency = filled and fillTrans or 1,
        BorderSizePixel = 0,
        Visible = cfg.Visible ~= false,
        ZIndex = cfg.ZIndex or 1,
        Parent = shapeParent(cfg),
    })
    corner(frame, cfg.Rounding or 4)
    local strokeInst = Create("UIStroke", { Color = color, Thickness = thickness, Parent = frame })
    local glowImg = cfg.Glow and shadow(frame, cfg.GlowSpread or 16, cfg.GlowTransparency or 0.4, color) or nil

    local handle = { Type = "Square" }
    attachShapeCommon(handle, frame, glowImg)
    function handle:SetSize(s)
        if handle._isDestroyed() then return self end
        if typeof(s) == "UDim2" then frame.Size = s
        elseif type(s) == "number" then frame.Size = UDim2.fromOffset(s, s) end
        return self
    end
    function handle:GetSize() return frame and frame.Size end
    function handle:SetThickness(t)
        if handle._isDestroyed() or type(t) ~= "number" then return self end
        strokeInst.Thickness = math.max(t, 0)
        return self
    end
    function handle:SetFilled(f)
        if handle._isDestroyed() then return self end
        filled = f == true
        frame.BackgroundTransparency = filled and fillTrans or 1
        return self
    end
    return handle
end

-- Line / tracer between two pixel points. From/To are Vector2 offsets (screen
-- pixels); rebuild with :SetPoints(a, b). A thin rotated frame, so no Drawing
-- API needed.
function OvertimeUI:CreateLine(cfg)
    cfg = cfg or {}
    local color     = shapeColor(cfg)
    local thickness = (type(cfg.Thickness) == "number") and math.max(cfg.Thickness, 1) or 2

    local frame = Create("Frame", {
        Name = cfg.Name or "Line",
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        Visible = cfg.Visible ~= false,
        ZIndex = cfg.ZIndex or 1,
        Parent = shapeParent(cfg),
    })
    corner(frame, math.floor(thickness / 2))

    local handle = { Type = "Line" }
    attachShapeCommon(handle, frame, nil)
    function handle:SetPoints(a, b)
        if handle._isDestroyed() or typeof(a) ~= "Vector2" or typeof(b) ~= "Vector2" then return self end
        local delta = b - a
        local mid = a + delta / 2
        frame.Position = UDim2.fromOffset(mid.X, mid.Y)
        frame.Size = UDim2.fromOffset(delta.Magnitude, thickness)
        frame.Rotation = math.deg(math.atan2(delta.Y, delta.X))
        return self
    end
    function handle:SetThickness(t)
        if handle._isDestroyed() or type(t) ~= "number" then return self end
        thickness = math.max(t, 1)
        frame.Size = UDim2.fromOffset(frame.Size.X.Offset, thickness)
        return self
    end
    if typeof(cfg.From) == "Vector2" and typeof(cfg.To) == "Vector2" then
        handle:SetPoints(cfg.From, cfg.To)
    end
    return handle
end

-- Floating text. Labels, watermark-style stats, ESP names. Has an outline
-- stroke by default so it stays readable over any background.
function OvertimeUI:CreateText(cfg)
    cfg = cfg or {}
    local color = (typeof(cfg.Color) == "Color3") and cfg.Color or Color3.fromRGB(236, 238, 246)
    local frame = Create("TextLabel", {
        Name = cfg.Name or "Text",
        AnchorPoint = (typeof(cfg.AnchorPoint) == "Vector2") and cfg.AnchorPoint or Vector2.new(0, 0),
        Position = (typeof(cfg.Position) == "UDim2") and cfg.Position
                   or (cfg.Center and UDim2.fromScale(0.5, 0.5) or UDim2.fromOffset(200, 200)),
        Size = UDim2.fromOffset(0, 0),
        AutomaticSize = Enum.AutomaticSize.XY,
        BackgroundTransparency = 1,
        Text = tostring(cfg.Text or ""),
        TextColor3 = color,
        Font = cfg.Font or FONT_SEMI,
        TextSize = cfg.TextSize or 14,
        Visible = cfg.Visible ~= false,
        ZIndex = cfg.ZIndex or 1,
        Parent = shapeParent(cfg),
    })
    if cfg.Stroke ~= false then
        Create("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = cfg.StrokeThickness or 1.5,
            Transparency = cfg.StrokeTransparency or 0.35, Parent = frame })
    end

    local handle = { Type = "Text" }
    local destroyed = false
    handle.GetInstance = function() return frame end
    function handle:SetText(t) if not destroyed then frame.Text = tostring(t) end return self end
    function handle:SetColor(c) if not destroyed and typeof(c) == "Color3" then frame.TextColor3 = c end return self end
    function handle:SetPosition(p) if not destroyed and typeof(p) == "UDim2" then frame.Position = p end return self end
    function handle:SetVisible(v) if not destroyed then frame.Visible = v ~= false end return self end
    function handle:IsVisible() return (not destroyed) and frame.Visible end
    function handle:Destroy() if not destroyed then destroyed = true frame:Destroy() frame = nil end end
    return handle
end

-- Image. Logos, custom cursors, ESP icons, decorative accents.
function OvertimeUI:CreateImage(cfg)
    cfg = cfg or {}
    local frame = Create("ImageLabel", {
        Name = cfg.Name or "Image",
        AnchorPoint = (typeof(cfg.AnchorPoint) == "Vector2") and cfg.AnchorPoint or Vector2.new(0, 0),
        Position = (typeof(cfg.Position) == "UDim2") and cfg.Position or UDim2.fromOffset(200, 200),
        Size = (typeof(cfg.Size) == "UDim2") and cfg.Size or UDim2.fromOffset(64, 64),
        BackgroundTransparency = 1,
        Image = tostring(cfg.Image or ""),
        ImageColor3 = (typeof(cfg.Color) == "Color3") and cfg.Color or Color3.new(1, 1, 1),
        ImageTransparency = (type(cfg.Transparency) == "number") and cfg.Transparency or 0,
        ScaleType = cfg.ScaleType or Enum.ScaleType.Fit,
        Visible = cfg.Visible ~= false,
        ZIndex = cfg.ZIndex or 1,
        Parent = shapeParent(cfg),
    })
    if cfg.Rounding then corner(frame, cfg.Rounding) end

    local handle = { Type = "Image" }
    local destroyed = false
    handle.GetInstance = function() return frame end
    function handle:SetImage(i) if not destroyed then frame.Image = tostring(i) end return self end
    function handle:SetColor(c) if not destroyed and typeof(c) == "Color3" then frame.ImageColor3 = c end return self end
    function handle:SetTransparency(t) if not destroyed and type(t) == "number" then frame.ImageTransparency = math.clamp(t, 0, 1) end return self end
    function handle:SetPosition(p) if not destroyed and typeof(p) == "UDim2" then frame.Position = p end return self end
    function handle:SetSize(s) if not destroyed and typeof(s) == "UDim2" then frame.Size = s end return self end
    function handle:SetVisible(v) if not destroyed then frame.Visible = v ~= false end return self end
    function handle:IsVisible() return (not destroyed) and frame.Visible end
    function handle:Destroy() if not destroyed then destroyed = true frame:Destroy() frame = nil end end
    return handle
end

-- =========================================================================
-- Watermark — a small draggable status chip (name / FPS / ping / build).
-- =========================================================================
-- A classic decoration: a rounded chip with an accent stripe that sits in a
-- corner and shows live text. Returns a handle with :SetText,
-- :SetAccent, :SetVisible, :Destroy. Drag it anywhere.
function OvertimeUI:CreateWatermark(cfg)
    cfg = cfg or {}
    local theme = defaultTheme()
    if typeof(cfg.Accent) == "Color3" then theme.accent = cfg.Accent end
    local gui = ensureOverlay()

    local chip = Create("Frame", {
        Name = "Watermark",
        Size = UDim2.fromOffset(cfg.Width or 200, 30),
        Position = (typeof(cfg.Position) == "UDim2") and cfg.Position or UDim2.fromOffset(16, 16),
        BackgroundColor3 = theme.bg,
        BorderSizePixel = 0,
        Active = true,
        Visible = cfg.Visible ~= false,
        Parent = gui,
    })
    corner(chip, 8)
    stroke(chip, theme.borderHi, 1)
    -- One faint drop so the floating chip lifts off the game world; no glow.
    shadow(chip, 16, 0.7)

    local stripe = Create("Frame", {
        Size = UDim2.new(0, 3, 1, -12),
        Position = UDim2.new(0, 8, 0, 6),
        BackgroundColor3 = theme.accent,
        BorderSizePixel = 0,
        ZIndex = 2,
        Parent = chip,
    })
    corner(stripe, 2)

    local lbl = Create("TextLabel", {
        Size = UDim2.new(1, -22, 1, 0),
        Position = UDim2.new(0, 18, 0, 0),
        BackgroundTransparency = 1,
        Text = tostring(cfg.Text or "OvertimeUI"),
        TextColor3 = theme.text,
        Font = FONT_SEMI,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 2,
        Parent = chip,
    })

    local dragging, dragStart, startPos = false, nil, nil
    chip.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true ; dragStart = input.Position ; startPos = chip.Position
        end
    end)
    chip.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    local dragConn = UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                      or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            chip.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                      startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)

    local handle = { Type = "Watermark" }
    local destroyed = false
    function handle:SetText(t) if not destroyed then lbl.Text = tostring(t) end return self end
    function handle:SetAccent(c)
        if destroyed or typeof(c) ~= "Color3" then return self end
        stripe.BackgroundColor3 = c
        return self
    end
    function handle:SetVisible(v) if not destroyed then chip.Visible = v ~= false end return self end
    function handle:IsVisible() return (not destroyed) and chip.Visible end
    function handle:Destroy()
        if destroyed then return end
        destroyed = true
        if dragConn then dragConn:Disconnect() dragConn = nil end
        chip:Destroy()
    end
    return handle
end

-- =========================================================================
-- Toolkit — OvertimeUI as an importable UI utility library.
-- =========================================================================
-- The high-level CreateWindow/CreateTab/CreateSection API above stamps one
-- house style. The toolkit below is the opposite: it hands you the HARD parts
-- (managed ScreenGui + re-run lifecycle, dragging, the HSV colour picker,
-- slider drag, dropdown popups, keybind capture + held-detection, notifications,
-- Drawing shapes) as standalone pieces, so you can lay out a genuinely bespoke
-- menu and still not re-implement any of the fiddly bits.
--
--     local UI = loadstring(game:HttpGet(".../OvertimeUI.lua"))()
--     local root = UI.Util.Root({ Name = "MyScript" })   -- nil on re-run (toggle off)
--     if not root then return end
--     local panel = UI.Util.Create("Frame", { Size = UDim2.fromOffset(300, 400),
--         BackgroundColor3 = Color3.fromRGB(20,20,28), Parent = root.gui })
--     root:Drag(panel)                                    -- drag the whole panel
--     root:SetToggleKey("RightShift")
--     -- drop real widgets anywhere via a Host bound to any frame:
--     local sec = root:Host(panel)                        -- or UI.Util.Host{Parent=panel}
--     sec:CreateToggle({ Name = "Enable", Callback = function(v) ... end })
--     sec:CreateColorPicker({ Name = "Color", Callback = function(c) ... end })
--
-- A Host is a real Section under the hood, so EVERY Section:CreateX method works
-- (toggle, slider, dropdown, colorpicker, keybind, button, label, paragraph,
-- input, divider, image, custom) — fully reusing the library's widget code.

OvertimeUI.Theme = function() return defaultTheme() end

-- Walk up to the ScreenGui that hosts an instance (popup/overlay parenting).
local function ancestorScreenGui(inst)
    local cur = inst
    while cur do
        if typeof(cur) == "Instance" and cur:IsA("ScreenGui") then return cur end
        cur = cur and cur.Parent
    end
    return nil
end

-- Host: a synthetic Section bound to an arbitrary frame. Lets every Section
-- widget builder be placed into a bespoke layout. cfg.Parent is required;
-- cfg.Theme / cfg.Style / cfg.Overlay / cfg.AccentGradient / cfg.Cleanup are
-- optional (sensible defaults). Returns a Section handle.
local function makeHost(cfg)
    cfg = cfg or {}
    local parent = cfg.Parent
    assert(typeof(parent) == "Instance", "UI.Util.Host requires a Parent frame")
    local fakeWindow = {
        theme           = cfg.Theme or defaultTheme(),
        style           = cfg.Style or defaultStyle(),
        _cleanup        = cfg.Cleanup or {},
        gui             = cfg.Overlay or ancestorScreenGui(parent) or ensureOverlay(),
        accentGradient  = cfg.AccentGradient,
    }
    return setmetatable({
        tab       = { window = fakeWindow },
        container = parent,
        _order    = 0,
    }, Section)
end

-- Root: a managed top-level UI host. Owns a ScreenGui + a re-run marker (so
-- running the script again returns nil and tears the old one down — the same
-- toggle-off UX as CreateWindow), connection cleanup, dragging and a toggle key.
-- It does NOT draw any chrome — you build whatever you want inside root.gui.
local function makeRoot(cfg)
    cfg = cfg or {}
    local name = cfg.Name or "OvertimeRoot"
    local markerName = "_OvertimeRoot_" .. tostring(name):gsub("[^%w]", "_")

    local existing = LP:FindFirstChild(markerName)
    if existing then existing:Destroy(); return nil end

    local self = { _cleanup = {}, _closeCbs = {}, _destroyed = false }

    local gui = Create("ScreenGui", {
        Name = "Overtime_" .. tostring(name),
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
        DisplayOrder = cfg.DisplayOrder or 10,
        Parent = LP:FindFirstChild("PlayerGui") or game:GetService("CoreGui"),
    })
    self.gui = gui

    local marker = Instance.new("BoolValue")
    marker.Name = markerName
    marker.Parent = LP
    self.marker = marker
    marker.Destroying:Connect(function() self:Destroy() end)

    function self:Track(c) table.insert(self._cleanup, c); return c end
    function self:OnClose(cb) if type(cb) == "function" then table.insert(self._closeCbs, cb) end end

    function self:Destroy()
        if self._destroyed then return end
        self._destroyed = true
        for _, cb in ipairs(self._closeCbs) do pcall(cb) end
        for _, c in ipairs(self._cleanup) do
            pcall(function()
                if typeof(c) == "RBXScriptConnection" then c:Disconnect() else c() end
            end)
        end
        pcall(function() gui:Destroy() end)
        pcall(function() if marker and marker.Parent then marker:Destroy() end end)
    end

    -- Drag `frame` by grabbing `handle` (defaults to the frame itself).
    function self:Drag(frame, handle)
        handle = handle or frame
        handle.Active = true
        local dragging, startInput, startPos
        handle.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                    or i.UserInputType == Enum.UserInputType.Touch then
                dragging = true; startInput = i.Position; startPos = frame.Position
            end
        end)
        handle.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                    or i.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
        self:Track(UIS.InputChanged:Connect(function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
                          or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - startInput
                frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                           startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end))
    end

    -- Show/hide the whole UI; bind a key to toggle it.
    function self:SetVisible(v) gui.Enabled = v ~= false end
    function self:Toggle() gui.Enabled = not gui.Enabled end
    function self:IsVisible() return gui.Enabled end
    function self:SetToggleKey(keyStr)
        if self._toggleConn then self._toggleConn:Disconnect(); self._toggleConn = nil end
        if not keyStr or keyStr == "" or keyStr == "None" or keyStr == "Unknown" then return end
        self._toggleConn = UIS.InputBegan:Connect(function(input, gpe)
            if gpe then return end
            if inputObjectToKeybind(input) == keyStr then gui.Enabled = not gui.Enabled end
        end)
        if not self._toggleTracked then
            self._toggleTracked = true
            self:Track(function() if self._toggleConn then self._toggleConn:Disconnect() end end)
        end
    end

    -- A Host (synthetic Section) bound to a frame inside this root, sharing the
    -- root's cleanup + overlay so popups render above and connections are freed.
    function self:Host(parent, opts)
        opts = opts or {}
        opts.Parent  = parent
        opts.Overlay = opts.Overlay or gui
        opts.Cleanup = opts.Cleanup or self._cleanup
        return makeHost(opts)
    end

    return self
end

-- Standalone keybind picker placed in `parent`. Adds OnPress (fires when the
-- bound key is pressed — a real hotkey) on top of the rebind Callback + IsHeld.
local function makeKeybind(parent, cfg)
    cfg = cfg or {}
    local theme = cfg.Theme or defaultTheme()
    local ctrl = buildKeybindControl(theme, parent,
        cfg.Default or cfg.CurrentKeybind or "None", cfg.Position, cfg.Size, cfg.Callback)
    local handle = { button = ctrl.button }
    function handle:Get()        return ctrl.get() end
    function handle:Set(v)       ctrl.set(v, true) end
    function handle:SetSilent(v) ctrl.set(v, false) end
    function handle:IsHeld()     return ctrl.isHeld() end
    if type(cfg.OnPress) == "function" then
        local conn = UIS.InputBegan:Connect(function(input, gpe)
            if gpe then return end
            local pressed = inputObjectToKeybind(input)
            if pressed and pressed == ctrl.get() then task.spawn(cfg.OnPress, pressed) end
        end)
        if cfg.Cleanup then table.insert(cfg.Cleanup, conn) end
        handle._conn = conn
    end
    return handle
end

-- OvertimeUI.Util gives the same low-level builders the library uses
-- internally, plus the lifecycle/host/drag helpers described above.
OvertimeUI.Util = {
    -- visual primitives
    Create        = Create,
    corner        = corner,
    stroke        = stroke,
    gradStroke    = gradStroke,
    sheen         = sheen,
    gradient      = sheen,
    accentGradient = applyAccentGradient,
    shadow        = shadow,
    glow          = function(parent, color, transparency, spread)
                        return accentGlowBehind(parent, color, transparency, spread, true)
                    end,
    padding       = padding,
    tween         = tween,
    keybindLabel  = keybindLabel,
    isKeybindHeld = isKeybindHeld,
    Easing        = { Style = EASE, Direction = EASE_OUT, Spring = SPRING,
                      Fast = T_FAST, Normal = T_NORMAL, Slow = T_SLOW },
    Fonts         = { Regular = DEFAULT_FONT, Bold = DEFAULT_FONT_BOLD, Semi = DEFAULT_FONT_SEMI },
    -- palettes / presets
    Theme         = function() return defaultTheme() end,
    Themes        = OvertimeUI.Themes,
    Presets       = OvertimeUI.Presets,
    -- the hard parts
    Root          = makeRoot,
    Host          = makeHost,
    Keybind       = makeKeybind,
}

return OvertimeUI
