addon.name      = 'multichat';
addon.author    = 'Sprort';
addon.version   = '2.0.0';
addon.desc      = 'Splits chat into one multi-tab window (LS1, LS2, Party, Tell, Say, Shout/Yell, Craft, Combat, NPC, SYS) with per-channel colors, filters, split view and pop-out windows. Read-only: reorganizes text your client already shows, never sends or alters anything.';
addon.link      = '';

require('common');
local imgui = require('imgui');

-- Optional settings (guarded)
local have_settings, settings = pcall(require, 'settings');

-- Shift-JIS -> UTF-8 conversion (see clean_str/fix_special_chars). FFXI's own text is
-- Shift-JIS, but ImGui expects UTF-8, so without this, any real Japanese text (as opposed to
-- the handful of individual typographic symbols fix_special_chars maps by hand) renders as "?"
-- placeholders regardless of which font is loaded. Vendored from the gdifonts library (MIT,
-- ThornyFFXI, see gdifonts/LICENSE), already used the same way by the approved Balloon addon
-- (Balloon.lua's convert_shiftjis_to_utf8) -- only encoding.lua is needed here since MultiChat
-- renders through ImGui already and has no use for gdifonts' GDI-based font rendering.
local have_encoding, encoding = pcall(require, 'gdifonts.encoding');

-- In-game update checking (see check_for_update/perform_update further down). Technique
-- researched from the approved anglin addon's own working self-updater (addons/anglin/
-- anglin.lua) -- no code copied, only the approach: fetch the raw .lua file straight from
-- GitHub and regex the addon.version line out of it directly, no separate manifest/API needed.
-- socket.ssl.https lives at the shared addons/libs/socket/ssl/https.lua, the same one anglin
-- itself relies on -- not something either addon bundles.
local have_https, https = pcall(require, 'socket.ssl.https');

print(string.format('[%s] v%s loaded. Type /multichat to toggle the window (Settings are the gear icon inside it).', addon.name, addon.version));

-- Chat state
-- Per-channel history capacity. A plain array with table.remove(bucket, 1) eviction is O(n) per
-- removal -- every remaining element shifts down -- and that runs on every single new message
-- once a channel is full, so the cost scales with capacity. Backed by a ring buffer instead (see
-- RingBuffer below), whose eviction is O(1) regardless of size, so this can be sized generously
-- (enough to review a whole fight or conversation afterward) without a growing per-message cost.
local MAX_MESSAGES_PER_CHANNEL = 5000;
-- How many of a channel's most recent (visible-after-filter) messages are actually drawn per
-- frame. Storage stays at MAX_MESSAGES_PER_CHANNEL above (so Copy still grabs the whole
-- history), but the per-frame render cost -- ImGui draw calls plus per-row string/timestamp
-- work -- scales with what's *drawn*, not what's stored. Rendering all 5000 was the cause of a
-- severe FPS drop reported after ~30 min in a leveling party, once Combat's buffer filled:
-- every frame was emitting thousands of off-screen rows' worth of draw calls and os.date/
-- string.format allocations. Only the last few hundred lines are realistically scrolled through
-- live anyway (deep review is better served by the copy-out and the planned on-disk log), so
-- this bounds the live render window while leaving stored history untouched. Raise it for more
-- in-window scrollback at some per-frame cost.
local MAX_RENDERED_ROWS = 500;
-- Reference point size the Font Size slider displays against. cfg.font_scale (the value actually
-- passed to imgui.SetWindowFontScale) is stored as a ratio, not an absolute size, since Ashita's
-- loaded font(s) are whatever size(s) the player's own boot profile configured; this is purely
-- for showing the slider as a recognizable "px" number instead of a percentage. 18 matches
-- Ashita's own documented default ImGui font size when none is explicitly configured.
local FONT_BASE_SIZE = 18;
-- FontAwesome 6 "gear" icon (U+F013), from Ashita's plugins/sdk/ImGuiFontAwesome.h
-- (ICON_FA_GEAR). Ashita merges the FontAwesome glyph map into every loaded ImGui font, so
-- this renders regardless of which font(s) the player's boot profile configures.
local ICON_GEAR = "\239\128\147";

-- ===== Ring buffer (per-channel message history) =====
-- Fixed-capacity circular buffer: push() overwrites the oldest slot once full instead of
-- shifting every remaining element down, so eviction stays O(1) no matter how large `capacity` is.
local RingBuffer = {}
RingBuffer.__index = RingBuffer

local function new_ring_buffer(capacity)
    return setmetatable({ capacity = capacity, slots = {}, head = 1, count = 0 }, RingBuffer)
end

function RingBuffer:push(entry)
    local writeAt = (self.head + self.count - 1) % self.capacity + 1
    if self.count < self.capacity then
        self.count = self.count + 1
    else
        self.head = self.head % self.capacity + 1
    end
    self.slots[writeAt] = entry
end

-- Iterates oldest to newest, matching chat log order (oldest at top, newest at bottom).
function RingBuffer:each(fn)
    for i = 0, self.count - 1 do
        fn(self.slots[(self.head + i - 1) % self.capacity + 1])
    end
end

-- Most recently pushed entry, or nil if the buffer is empty.
function RingBuffer:last()
    if self.count == 0 then return nil end
    return self.slots[(self.head + self.count - 2) % self.capacity + 1]
end

local chat = {
    -- messages[channel] = RingBuffer of {timestamp=, username=, message=, ...}
    messages       = {
        linkshell  = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
        linkshell2 = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
        party      = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
        tell       = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
        say        = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
        craft      = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
        combat     = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
        quest      = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
        shout      = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
        sys        = new_ring_buffer(MAX_MESSAGES_PER_CHANNEL),
    },
    is_open        = { true, },
    active_channel = 'linkshell',  -- 'linkshell' | 'linkshell2' | 'party' | 'tell' | 'say' | 'shout' | 'craft' | 'combat' | 'quest' | 'sys'
};

-- Settings window UI state
local settings_ui = {
    is_open = { false },
}

-- Measured width (in pixels) of the main window's Pop Out/Split/Copy/Settings button cluster,
-- used to right-align it flush against the window's edge. Self-corrected every frame (see where
-- it's used below) from the buttons' actual rendered rects rather than an estimated formula, so
-- it's pixel-accurate regardless of font/DPI/padding quirks an estimate could get wrong. Starts
-- at a reasonable guess and converges within a frame or two.
local action_cluster_w = 220

-- Split view state (second pane)
local split = {
    enabled       = false,
    right_channel = 'tell',
    orientation   = 'horizontal', -- 'horizontal' (side-by-side) | 'vertical' (stacked)
    ratio         = 0.55,     -- primary pane's share of width (horizontal) or height (vertical), 0..1
    min_px        = 160,      -- minimum pane size (width or height) in pixels
    grip_px       = 6,        -- splitter thickness
}

-- Channel colors (RGBA 0..1)
local channelColors = {
    linkshell  = {157/255, 255/255, 206/255, 1.0},
    linkshell2 = { 30/255, 255/255,  61/255, 1.0},
    party      = { 83/255, 255/255, 255/255, 1.0},
    tell       = {255/255, 133/255, 255/255, 1.0},
    say        = {255/255, 255/255, 255/255, 1.0},
    craft      = {255/255, 200/255,  87/255, 1.0},
    combat     = {255/255, 100/255, 100/255, 1.0},
    quest      = { 90/255, 210/255, 190/255, 1.0},
    shout      = {225/255,  55/255,  85/255, 1.0},
    sys        = {180/255, 150/255, 255/255, 1.0},
}

local channelLabels = {
    linkshell  = 'LS1',
    linkshell2 = 'LS2',
    party      = 'Party',
    tell       = 'Tell',
    say        = 'Say',
    craft      = 'Craft',
    combat     = 'Combat',
    quest      = 'NPC',
    shout      = 'Sh/Y',
    sys        = 'SYS',
}

-- Pop-out / alert state (alert = invert-flash until acknowledged)
local pop = {
    linkshell  = { popped = false, is_open = { true }, alert = false },
    linkshell2 = { popped = false, is_open = { true }, alert = false },
    party      = { popped = false, is_open = { true }, alert = false },
    tell       = { popped = false, is_open = { true }, alert = false },
    say        = { popped = false, is_open = { true }, alert = false },
    craft      = { popped = false, is_open = { true }, alert = false },
    combat     = { popped = false, is_open = { true }, alert = false },
    quest      = { popped = false, is_open = { true }, alert = false },
    shout      = { popped = false, is_open = { true }, alert = false },
    sys        = { popped = false, is_open = { true }, alert = false },
}

local function copy_color(c) return { c[1], c[2], c[3], c[4] } end

-- Config (saved if settings lib is present)
local default_config = {
    windows = {
        main       = { x = 300, y = 300, w = 560, h = 480 },
        linkshell  = { x = 100, y = 100, w = 420, h = 360 },
        linkshell2 = { x = 150, y = 150, w = 420, h = 360 },
        party      = { x = 200, y = 200, w = 420, h = 360 },
        tell       = { x = 250, y = 250, w = 420, h = 360 },
        say        = { x = 300, y = 300, w = 420, h = 360 },
        craft      = { x = 350, y = 350, w = 420, h = 360 },
        combat     = { x = 400, y = 400, w = 420, h = 360 },
        quest      = { x = 450, y = 450, w = 420, h = 360 },
        shout      = { x = 325, y = 325, w = 420, h = 360 },
        sys        = { x = 475, y = 475, w = 420, h = 360 },
    },
    chat_bg_alpha    = 0.25,  -- chat log child background opacity (0..1), set from the Settings window
    font_scale       = 1.0,   -- per-window text scale multiplier (0.5 .. 2.5)
    line_spacing     = 0,     -- vertical pixel gap between chat lines (0 .. 16), independent of font_scale
    dedupe_sec       = 1.5,   -- window for duplicate suppression
    timestamp_format = 'hms', -- 'hms' (HH:MM:SS) | 'hm' (HH:MM)
    timestamp_12h    = false, -- false = 24-hour, true = 12-hour with AM/PM
    shoutyell_filter = 'both', -- 'both' | 'shout' | 'yell' -- which to show in the Shout/Yell channel
    craft_filter     = 'all', -- 'all' | 'mine' -- who to show in the Craft channel
    combat_filter    = 'all', -- 'all' | 'mine' -- who to show in the Combat channel
    -- Per-channel popped-out state. Window positions/sizes were already persisted (in `windows`
    -- above), which is why re-popping a window restores where it was -- but whether a channel
    -- was popped out at all wasn't, so a reload dropped every pop-out back into the main window.
    -- Kept in step with reality each frame and re-applied on load (see restore_popped_state).
    popped           = {},
    colors = {
        -- per_channel = false -> use "all"; per_channel = true -> use "channels[<channel>]"
        -- Default all three to each channel's tab color.
        -- Craft/Combat are deliberately absent here -- those two channels use fixed,
        -- message-type-based colors (ability/damage/heal) instead of user-configurable ones.
        timestamp = { per_channel = true, all = {1,1,1,1}, channels = {
            linkshell  = copy_color(channelColors.linkshell),
            linkshell2 = copy_color(channelColors.linkshell2),
            party      = copy_color(channelColors.party),
            tell       = copy_color(channelColors.tell),
            say        = copy_color(channelColors.say),
        }},
        username = { per_channel = true, all = {1,1,1,1}, channels = {
            linkshell  = copy_color(channelColors.linkshell),
            linkshell2 = copy_color(channelColors.linkshell2),
            party      = copy_color(channelColors.party),
            tell       = copy_color(channelColors.tell),
            say        = copy_color(channelColors.say),
        }},
        text = { per_channel = true, all = {1,1,1,1}, channels = {
            linkshell  = copy_color(channelColors.linkshell),
            linkshell2 = copy_color(channelColors.linkshell2),
            party      = copy_color(channelColors.party),
            tell       = copy_color(channelColors.tell),
            say        = copy_color(channelColors.say),
        }},
    },
}

-- Fills in any fields missing from a loaded settings table (e.g. an older save predating a
-- newer field) with defaults. Applied both at initial load and any time the settings library
-- swaps in a freshly-reloaded table (see the settings.register call below).
local function apply_cfg_defaults(c)
    c.chat_bg_alpha     = (c.chat_bg_alpha ~= nil) and c.chat_bg_alpha or 0.25
    c.font_scale        = c.font_scale or 1.0
    c.line_spacing      = (c.line_spacing ~= nil) and c.line_spacing or 0
    c.dedupe_sec        = c.dedupe_sec or 1.5
    c.timestamp_format  = c.timestamp_format or 'hms'
    if c.timestamp_12h == nil then c.timestamp_12h = false end
    c.craft_filter      = c.craft_filter or 'all'
    c.combat_filter     = c.combat_filter or 'all'
    if c.craft_filter ~= 'mine' then c.craft_filter = 'all' end
    if c.combat_filter ~= 'mine' then c.combat_filter = 'all' end
    c.shoutyell_filter  = c.shoutyell_filter or 'both'
    if c.shoutyell_filter ~= 'shout' and c.shoutyell_filter ~= 'yell' then c.shoutyell_filter = 'both' end

    -- Normalize the saved popped-out flags to real booleans, with an entry for every channel
    -- (an older save predating this field, or a hand-edited one, may be missing or malformed).
    c.popped = (type(c.popped) == 'table') and c.popped or {}
    for ch, _ in pairs(pop) do
        c.popped[ch] = (c.popped[ch] == true)
    end

    c.colors = c.colors or default_config.colors
    for _, key in ipairs({'timestamp', 'username', 'text'}) do
        c.colors[key] = c.colors[key] or default_config.colors[key]
        if c.colors[key].per_channel == nil then c.colors[key].per_channel = default_config.colors[key].per_channel end
        c.colors[key].all = c.colors[key].all or default_config.colors[key].all
        c.colors[key].channels = c.colors[key].channels or {}
        for _, ch in ipairs({'linkshell','linkshell2','party','tell','say'}) do
            c.colors[key].channels[ch] = c.colors[key].channels[ch] or copy_color(default_config.colors[key].channels[ch])
        end
    end

    return c
end

-- Re-applies the saved popped-out state to the live `pop` table, so channels that were popped
-- out when you last played come back popped out (into their saved positions) instead of
-- collapsing into the main window on reload. Takes the config table as an argument rather than
-- reading the `cfg` local, so it can be defined ahead of it and used by both load paths below.
local function restore_popped_state(c)
    if type(c) ~= 'table' or type(c.popped) ~= 'table' then return end
    for ch, state in pairs(pop) do
        state.popped = (c.popped[ch] == true)
        -- A restored pop-out must also be un-closed, or it'd be popped but not drawn.
        if state.popped then state.is_open[1] = true end
    end
end

local cfg = default_config;
if have_settings and type(settings.load) == 'function' then
    local ok, loaded = pcall(settings.load, default_config);
    if ok and type(loaded) == 'table' and type(loaded.windows) == 'table' then
        cfg = apply_cfg_defaults(loaded);
        restore_popped_state(cfg);
    end

    -- The settings library monitors character login/logout itself (via zone packets) and, on
    -- those transitions, re-saves then reloads its own internally tracked table, replacing the
    -- object reference entirely. If we kept using the table from the initial settings.load()
    -- call above, every change made after that first swap (i.e. for essentially the entire
    -- play session, since logging in triggers it almost immediately) would be silently mutated
    -- into an orphaned table the library no longer saves. Registering here keeps `cfg` pointed
    -- at whatever table the library is actually tracking, so nothing gets lost.
    if type(settings.register) == 'function' then
        pcall(function()
            settings.register('settings', 'multichat_settings_sync', function (new_settings)
                if type(new_settings) == 'table' then
                    cfg = apply_cfg_defaults(new_settings);
                    -- The character-specific settings only actually arrive on this swap (the
                    -- initial load above runs before a character is known), so this is where a
                    -- saved pop-out layout really gets applied.
                    restore_popped_state(cfg);
                end
            end)
        end)
    end
end

-- ================= Safe ImGui vec helpers =================
local function get_x(v)
    if v == nil then return 0 end
    if type(v) == 'number' then return v end
    if type(v) == 'table' then
        if v.x ~= nil and type(v.x) == 'number' then return v.x end
        if v[1] ~= nil and type(v[1]) == 'number' then return v[1] end
    end
    local ok, x = pcall(function() return v.x end)
    if ok and type(x) == 'number' then return x end
    local ok2, x2 = pcall(function() return v[1] end)
    if ok2 and type(x2) == 'number' then return x2 end
    return 0
end

local function get_y(v)
    if v == nil then return 0 end
    if type(v) == 'table' then
        if v.y ~= nil and type(v.y) == 'number' then return v.y end
        if v[2] ~= nil and type(v[2]) == 'number' then return v[2] end
    end
    local ok, y = pcall(function() return v.y end)
    if ok and type(y) == 'number' then return y end
    local ok2, y2 = pcall(function() return v[2] end)
    if ok2 and type(y2) == 'number' then return y2 end
    return 0
end

local function text_width(s)
    local ok, sz = pcall(imgui.CalcTextSize, s)
    if ok and sz then return get_x(sz) end
    return (#s) * 7
end

-- ================= Visibility / geometry helpers =================
local force_center_frames = 0

local function get_display_size()
    local ok, io = pcall(imgui.GetIO)
    if ok and io and io.DisplaySize then
        local ds = io.DisplaySize
        local sx = get_x(ds)
        local sy = get_y(ds)
        if sx <= 0 then sx = 1920 end
        if sy <= 0 then sy = 1080 end
        return sx, sy
    end
    return 1920, 1080
end

local function is_offscreen(x, y, w, h)
    local sx, sy = get_display_size()
    local margin = 12
    if w <= 0 or h <= 0 then return true end
    if x + w < margin or y + h < margin then return true end
    if x > sx - margin or y > sy - margin then return true end
    return false
end

local function center_window_rect(key)
    local sx, sy = get_display_size()
    local r = cfg.windows[key] or {}
    local w = r.w or 420
    local h = r.h or 360
    r.x = math.max(20, math.floor((sx - w) / 2))
    r.y = math.max(20, math.floor((sy - h) / 2))
    r.w = w; r.h = h
    cfg.windows[key] = r
end

-- Only set position on first use or when we explicitly recenter.
local function apply_window_bounds(key)
    cfg.windows[key] = cfg.windows[key] or { x = 200, y = 200, w = 420, h = 360 }
    local r = cfg.windows[key]

    -- Size: first use only (lets you resize freely afterwards)
    imgui.SetNextWindowSize({ r.w, r.h }, ImGuiCond_FirstUseEver)

    -- Position:
    if force_center_frames > 0 then
        center_window_rect(key)                         -- compute fresh centered rect
        imgui.SetNextWindowPos({ r.x, r.y }, ImGuiCond_Always)  -- force just while recentering
    else
        imgui.SetNextWindowPos({ r.x, r.y }, ImGuiCond_FirstUseEver) -- only first time
    end
end


local function save_window_geom(key)
    cfg.windows = cfg.windows or {};
    cfg.windows[key] = cfg.windows[key] or { x = 200, y = 200, w = 420, h = 360 };
    local okp, pos  = pcall(imgui.GetWindowPos);
    local oks, size = pcall(imgui.GetWindowSize);
    if okp and oks and pos and size then
        local x = get_x(pos)
        local y = get_y(pos)
        local w = get_x(size)
        local h = get_y(size)
        cfg.windows[key].x = x; cfg.windows[key].y = y; cfg.windows[key].w = w; cfg.windows[key].h = h;
    end
end

-- Applies the configurable text scale to whichever window/child is currently on top of the
-- ImGui window stack. Must be called separately inside each window AND each child region,
-- since ImGui does not propagate a parent window's font scale down into its children.
local function apply_font_scale()
    pcall(function() imgui.SetWindowFontScale(cfg.font_scale or 1.0) end)
end

-- Title bar color, applied to every addon window (main, popped-out, Settings). Must be pushed
-- before imgui.Begin() (title bar draws as part of Begin) and popped after End().
local TITLEBAR_ACTIVE    = {0.16, 0.45, 0.78, 1.0}
local TITLEBAR_INACTIVE  = {0.10, 0.28, 0.48, 1.0}
local TITLEBAR_COLLAPSED = {0.10, 0.22, 0.38, 0.80}

local function push_titlebar_color()
    local pushed = 0
    if pcall(function() imgui.PushStyleColor(ImGuiCol_TitleBg, TITLEBAR_INACTIVE) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_TitleBgActive, TITLEBAR_ACTIVE) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_TitleBgCollapsed, TITLEBAR_COLLAPSED) end) then pushed = pushed + 1 end
    return pushed
end

-- ===== Text utils =====
-- FFXI's raw text is Shift-JIS (it's originally a Japanese game), which ImGui doesn't
-- understand on its own -- passed through unconverted, each byte renders as its own "?"
-- placeholder glyph regardless of which font is loaded. A handful of individual typographic
-- symbols (curly quotes, stars, a musical note, a wide tilde) are mapped to plain ASCII by
-- hand here rather than left for the general Shift-JIS -> UTF-8 conversion below: confirmed
-- via in-game screenshot that even once correctly converted to their real Unicode codepoints,
-- the loaded font's Japanese glyph range doesn't cover those general symbol/punctuation
-- blocks, so it just traded two "?"s per character for one. Plain ASCII is guaranteed to
-- render in any font. (Actual Japanese CJK text, and Latin-1 accented characters like the
-- e-acute this table used to hand-map, are covered correctly by the general conversion
-- instead -- see clean_str.)
local function fix_special_chars(str)
    str = str:gsub(string.char(0x81, 0x40), '  ')  -- full-width space
    str = str:gsub(string.char(0x81, 0xF4), '')     -- musical note (no good ASCII equivalent)
    str = str:gsub(string.char(0x81, 0x99), '*')    -- empty star
    str = str:gsub(string.char(0x81, 0x9A), '*')    -- full star
    str = str:gsub(string.char(0x81, 0x60), '~')    -- wide tilde
    str = str:gsub(string.char(0x87, 0xB2), '"')    -- left curly quote
    str = str:gsub(string.char(0x87, 0xB3), '"')    -- right curly quote
    -- Rightwards arrow (used by Checker). Must be plain ASCII, not the real Unicode glyph:
    -- everything fix_special_chars outputs gets fed into the general Shift-JIS -> UTF-8
    -- conversion that runs right after it (see clean_str), and a real UTF-8 character reinter-
    -- preted a second time AS Shift-JIS input gets corrupted into garbage -- confirmed via
    -- in-game screenshot (rendered as "? •" instead of an arrow). Same reason the e-acute
    -- mapping was removed from here earlier rather than left as a literal 'é'.
    str = str:gsub(string.char(0x81, 0xA8), '->')
    return str
end

local function clean_str(str)
    str = AshitaCore:GetChatManager():ParseAutoTranslate(str, true);
    str = str:strip_colors();
    str = str:strip_translate(true);
    str = str:gsub('[\r\n]+$', '');           -- drop trailing CR/LF in one pass
    str = str:gsub(string.char(0x07), '\n');  -- FFXI's own mid-string line-break byte
    str = fix_special_chars(str);
    -- Everything fix_special_chars didn't already consume is either plain ASCII (safe
    -- pass-through under Shift-JIS -> UTF-8 conversion, since Shift-JIS is ASCII-compatible in
    -- that range) or genuine untouched Shift-JIS bytes (Japanese text, Latin-1 accents) that
    -- need real conversion to render as anything but "?" placeholders.
    if have_encoding and encoding then
        local ok, converted = pcall(function() return encoding:ShiftJIS_To_UTF8(str) end)
        if ok and converted then str = converted end
    end
    return str;
end

local function timestamp_format_str()
    if cfg.timestamp_12h then
        return (cfg.timestamp_format == 'hm') and "[%I:%M %p]" or "[%I:%M:%S %p]"
    end
    return (cfg.timestamp_format == 'hm') and "[%H:%M]" or "[%H:%M:%S]"
end

local function get_timestamp()
    return os.date(timestamp_format_str())
end

-- Formats a stored row's raw capture time using the *current* Settings format, rather than
-- whatever format was active when the row was captured -- so switching 12h/24h or HH:MM[:SS]
-- retroactively reformats history already on screen instead of only affecting new messages.
local function format_timestamp(epoch)
    return os.date(timestamp_format_str(), epoch)
end

-- msgType mapping (defensive: 0 or 1 -> say)
local function msgtype_to_channel(mode)
    if mode == 0 or mode == 1 then return 'say'
    elseif mode == 5 then return 'linkshell'
    elseif mode == 27 then return 'linkshell2'
    elseif mode == 4 then return 'party'
    elseif mode == 3 then return 'tell'
    end
    return nil
end


-- ===== Alerts (invert-flash) =====
local function current_char_name()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0) or ''
end

-- Treat both panes as "viewed"; only alert if not visible in main-left or main-right.
local function channel_visible_in_main(channel)
    if chat.active_channel == channel and not pop[channel].popped then return true end
    if split.enabled and split.right_channel == channel and not pop[channel].popped then return true end
    return false
end

-- Triggers for both incoming AND outgoing messages.
local function mark_alert_if_needed(channel, msg, _is_incoming_unused)
    if channel_visible_in_main(channel) then return end
    if channel == 'tell' or channel == 'party' or channel == 'sys' then pop[channel].alert = true; return end
    local who = current_char_name()
    if who ~= '' and msg:lower():find(who:lower(), 1, true) then
        pop[channel].alert = true
    end
end

local function is_alerting(channel) return pop[channel].alert == true end

-- ====== De-dup cache ======
local recent_seen = {}  -- key -> last_time
local recent_order = {} -- ring buffer of keys (for cleanup)
local function dedupe_key(channel, username, msg) return channel .. '|' .. username .. '|' .. msg end
local function is_duplicate_and_mark(channel, username, msg)
    local k = dedupe_key(channel, username, msg)
    local now = os.clock()
    local last = recent_seen[k]
    local win = cfg.dedupe_sec or 1.5
    if last and (now - last) < win then return true end
    recent_seen[k] = now
    table.insert(recent_order, k)
    if #recent_order > 512 then
        for i = 1, 256 do
            local oldk = table.remove(recent_order, 1)
            if oldk then
                local t = recent_seen[oldk]
                if t and (now - t) > (win * 2.0) then recent_seen[oldk] = nil end
            end
        end
    end
    return false
end

-- Append new message (with de-dup), possibly mark alert. `text_color`, if given, overrides the
-- row's text color (used by Craft/Combat's message-type coloring -- see SYSTEM_MESSAGE_PATTERNS).
-- `uname_color`, if given, overrides the row's username color (used by Combat's enemy/player
-- coloring -- see resolve_combat_uname_color). `spans`, if given, is a list of {s, e, color}
-- char ranges within `msg`, each rendered in its own color -- used for single-span item-name
-- highlighting (see find_item_span) and Checker's multi-segment per-piece coloring (see
-- try_checker_message).
-- `no_alert`, if true, skips the alert flash entirely -- used for SYS sub-categories (like
-- auction house messages) that shouldn't trigger SYS's normal always-alert behavior.
-- `kind`, if given, is a free-form sub-category tag stored on the row and checked at display
-- time rather than at capture time -- used by Shout/Yell (see channel_row_visible) so that
-- switching the Both/Shout/Yell filter can retroactively show/hide history already captured,
-- instead of only ever affecting messages captured after the switch.
-- `no_dedupe`, if true, skips duplicate suppression -- for message types where byte-identical
-- lines close together are genuinely distinct events rather than a double-capture of one event.
-- Delivery box claims are the case (claiming a stack of the same item at the same price emits
-- several identical "Slot N:" / "The money the buyer paid..." lines within a second or two, all
-- real); safe because such messages only arrive through the single text_in path, so there's no
-- second code path that could double-capture one and legitimately need de-duping.
local function append_message(channel, username, msg, is_incoming, text_color, uname_color, spans, no_alert, kind, no_dedupe)
    if not no_dedupe and is_duplicate_and_mark(channel, username, msg) then return end
    local bucket = chat.messages[channel]
    if not bucket then return end
    bucket:push({ epoch = os.time(), username = username, message = msg, text_color = text_color, uname_color = uname_color, spans = spans, kind = kind })
    if not no_alert then
        mark_alert_if_needed(channel, msg, is_incoming)
    end
end

-- ===== In-game update checking =====
-- Reports into SYS (username "MultiChat") rather than a plain /echo, so it's visible in the
-- same history as everything else. Only an actual available update triggers SYS's normal
-- alert -- a routine "you're current" result is logged quietly (no_alert=true) since it isn't
-- something that needs your attention.
local UPDATE_REPO_RAW = 'https://raw.githubusercontent.com/sprort/xi-multichat/main/'
local UPDATE_FILES = {
    { url = UPDATE_REPO_RAW .. 'multichat.lua',         path = addon.path:append('\\multichat.lua') },
    { url = UPDATE_REPO_RAW .. 'README.md',             path = addon.path:append('\\README.md') },
    { url = UPDATE_REPO_RAW .. 'LICENSE',               path = addon.path:append('\\LICENSE') },
    { url = UPDATE_REPO_RAW .. 'gdifonts/encoding.lua', path = addon.path:append('\\gdifonts\\encoding.lua') },
    { url = UPDATE_REPO_RAW .. 'gdifonts/LICENSE',      path = addon.path:append('\\gdifonts\\LICENSE') },
}

local function ver_gt(a, b)
    local function parts(v)
        local t = {}
        for n in v:gmatch('%d+') do table.insert(t, tonumber(n)) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local ai, bi = pa[i] or 0, pb[i] or 0
        if ai ~= bi then return ai > bi end
    end
    return false
end

-- Fetches the raw multichat.lua straight from GitHub and pulls its addon.version line back out
-- via pattern match -- no separate version manifest/API needed. Cache-busted with a timestamp
-- query param so GitHub's own CDN can't serve a stale response.
local function fetch_remote_version()
    if not have_https then return nil end
    local ok, body, code = pcall(function() return https.request(UPDATE_REPO_RAW .. 'multichat.lua?t=' .. os.time()) end)
    if not ok or code ~= 200 or not body then return nil end
    return body:match("addon%.version%s*=%s*'([^']+)'") or body:match('addon%.version%s*=%s*"([^"]+)"')
end

local update_available_version = nil
local update_check_done = false

local function check_for_update()
    local remote = fetch_remote_version()
    if not remote then return end
    if ver_gt(remote, addon.version) then
        update_available_version = remote
        append_message('sys', 'MultiChat', string.format(
            'Update available: v%s -> v%s. Type /multichat update to install.', addon.version, remote), true)
    else
        append_message('sys', 'MultiChat', string.format('Up to date (v%s).', addon.version), true, nil, nil, nil, true)
    end
end

-- Downloads every file fresh and overwrites the current install, aborting on the first failure
-- (matching anglin's own approach) rather than leaving a half-updated mix of old and new files.
-- Reloads automatically on success via Ashita's own /addon reload -- the file on disk is fully
-- written and closed before that command is issued, so the reload picks up the new version
-- cleanly rather than racing the write.
local function perform_update()
    if not have_https then
        append_message('sys', 'MultiChat', 'Update failed: HTTPS library unavailable.', true, nil, nil, nil, true)
        return
    end
    local remote = fetch_remote_version()
    if not remote then
        append_message('sys', 'MultiChat', 'Update failed: could not reach GitHub.', true, nil, nil, nil, true)
        return
    end
    for _, f in ipairs(UPDATE_FILES) do
        local ok, body, code = pcall(function() return https.request(f.url .. '?t=' .. os.time()) end)
        if not ok or code ~= 200 or not body or body == '' then
            append_message('sys', 'MultiChat', string.format('Update failed downloading %s -- aborted, nothing changed.', f.url), true, nil, nil, nil, true)
            return
        end
        local dir = f.path:match('^(.*)\\[^\\]+$')
        if dir then os.execute(string.format('mkdir "%s" 2>nul', dir)) end
        local out = io.open(f.path, 'wb')
        if not out then
            append_message('sys', 'MultiChat', 'Update failed: cannot write ' .. f.path, true, nil, nil, nil, true)
            return
        end
        out:write(body)
        out:close()
    end
    update_available_version = nil
    append_message('sys', 'MultiChat', string.format('Updated to v%s. Reloading...', remote), true)
    AshitaCore:GetChatManager():QueueCommand(1, '/addon reload multichat')
end

-- Shout and Yell share one tab but are colored distinctly per-message so the two are easy to
-- tell apart at a glance even when both are shown together. Defined here (rather than beside the
-- other combat/message colors further down) so the command hook below, which mirrors your own
-- outgoing shout/yell, can reference them -- a later `local` wouldn't be in scope for it.
local SHOUT_TEXT_COLOR = {255/255, 170/255,  60/255, 1.0} -- orange: Shout
local YELL_TEXT_COLOR  = {255/255,  90/255, 200/255, 1.0} -- pink/magenta: Yell

-- ===== Commands =====
ashita.events.register('command', 'multichat_command_cb', function (e)
    local cmdline = e.command
    local lower = cmdline:lower()

    -- /multichat toggle
    if (not lower:startswith('/multichat ')) and lower == '/multichat' then
        e.blocked = true
        chat.is_open[1] = not chat.is_open[1]
        return
    end

    -- /multichat show
    if lower:startswith('/multichat show') then
        e.blocked = true
        chat.is_open[1] = true
        for k,_ in pairs(pop) do pop[k].popped = false end
        center_window_rect('main')
        force_center_frames = 8
        return
    end

    -- /multichat reset
    if lower:startswith('/multichat reset') then
        e.blocked = true
        chat.is_open[1] = true
        for k,_ in pairs(cfg.windows) do center_window_rect(k) end
        for k,_ in pairs(pop) do pop[k].popped = false end
        force_center_frames = 8
        return
    end

    -- /multichat checkupdate
    if lower:startswith('/multichat checkupdate') then
        e.blocked = true
        check_for_update()
        return
    end

    -- /multichat update
    if lower:startswith('/multichat update') then
        e.blocked = true
        perform_update()
        return
    end

    -- /multichat reload
    if lower:startswith('/multichat reload') then
        e.blocked = true
        AshitaCore:GetChatManager():QueueCommand(1, '/addon reload multichat')
        return
    end

    -- Mirror outgoing /say (/s ...)
    local say_msg = lower:match('^/s%s+(.+)$') or lower:match('^/say%s+(.+)$')
    if say_msg then
        local me = current_char_name()
        local orig = cmdline:gsub('^/%a+%s+', '', 1)
        orig = clean_str(orig)
        append_message('say', me ~= '' and me or 'Me', orig, false)
        return
    end

    -- Mirror outgoing /shout and /yell. Incoming shouts/yells are captured via text_in (modes
    -- 10/11), but your OWN outgoing ones don't arrive that way -- same reason /say and /tell are
    -- mirrored from the command here rather than relied on from the packet/text stream.
    -- Confirmed via user report: a self-yell showed in the native log but not in the Sh/Y tab.
    -- `kind` ('shout'/'yell') is set so the Both/Shout/Yell filter treats these like any other.
    local shout_msg = lower:match('^/shout%s+(.+)$') or lower:match('^/sh%s+(.+)$')
    if shout_msg then
        local me = current_char_name()
        local orig = clean_str(cmdline:gsub('^/%a+%s+', '', 1))
        append_message('shout', me ~= '' and me or 'Me', orig, false, SHOUT_TEXT_COLOR, nil, nil, false, 'shout')
        return
    end
    local yell_msg = lower:match('^/yell%s+(.+)$') or lower:match('^/y%s+(.+)$')
    if yell_msg then
        local me = current_char_name()
        local orig = clean_str(cmdline:gsub('^/%a+%s+', '', 1))
        append_message('shout', me ~= '' and me or 'Me', orig, false, YELL_TEXT_COLOR, nil, nil, false, 'yell')
        return
    end

    -- Mirror outgoing /tell (/t Name message or /tell Name message). The recipient is shown in
    -- the username itself (">>Abbynightwish") rather than a separate column or a per-message
    -- prefix, reusing FFXI's own native ">>Name :" convention for outgoing tells exactly as-is
    -- (no redundant "Sprort" prefix -- an outgoing tell already implies it's from you, the same
    -- way the native log doesn't repeat your own name either) -- confirmed via user report that
    -- scrolling back through Tell history otherwise gives no way to tell who an outgoing
    -- message actually went to, without adding much column width doing it.
    local target, tmsg = cmdline:match('^/[Tt]ell%s+(%S+)%s+(.+)$')
    if not target then target, tmsg = cmdline:match('^/t%s+(%S+)%s+(.+)$') end
    if target and tmsg then
        tmsg = clean_str(tmsg)
        append_message('tell', '>>' .. target, tmsg, false)
        return
    end
end)

-- Field offsets are dictated by packet 0x017's on-the-wire layout, not a style choice --
-- mode comes from the raw packet, name/text from Ashita's post-hook "modified" copy.
local function decode_incoming_chat(e)
    local okMode, mode = pcall(struct.unpack, 'B', e.data, 0x04 + 1)
    if not okMode then return nil end
    local okName, name = pcall(struct.unpack, 'c15', e.data_modified, 0x08 + 1)
    local okText, text = pcall(struct.unpack, 's', e.data_modified, 0x17 + 1)
    if not (okName and okText) then return nil end
    return mode, name:trimend('\x00'), text
end

-- ===== Incoming packets =====
ashita.events.register('packet_in', 'packet_in_cb', function (e)
    if (e.id ~= 0x017) then return end
    pcall(function()
        local mode, character, text = decode_incoming_chat(e)
        if not mode then return end
        local ch = msgtype_to_channel(mode)
        if not ch then return end
        -- Custom server NPCs (e.g. HorizonXI's achievement-system NPCs) send their dialogue
        -- through the same native Say packet/mode a player's own /say uses, with the NPC's own
        -- name as the packet's character-name field -- confirmed via in-game screenshot ("Lady
        -- Aurelie", "Lorekeeper Isa", "Eeko-Weeko"). A real FFXI player name can only ever be
        -- pure letters (no spaces, hyphens, digits, or punctuation), so anything else in that
        -- field is a reliable signal this isn't actually a player, without needing to hardcode
        -- specific NPC names.
        if ch == 'say' and not character:match('^%a+$') then
            ch = 'quest'
        end
        -- Matches FFXI's own native convention for incoming tells (trailing ">>", vs. the
        -- leading ">>" outgoing tells use -- see the /tell command mirror above) -- the arrow
        -- points toward whichever side actually sent it.
        local displayName = (ch == 'tell') and (character .. '>>') or character
        text = text:gsub('%%', '%%%%')
        append_message(ch, displayName, clean_str(text), true)
    end)
end)

-- ===== Outgoing packets (best effort – command mirror ensures /say & /tell) =====
local function parse_outgoing_chat(e)
    local layouts = { {0x04,0x06}, {0x0A,0x0E}, {0x0E,0x12} }
    local bufs = { e.data_modified, e.data }
    for _,buf in ipairs(bufs) do
        for _,L in ipairs(layouts) do
            local okm, mode = pcall(struct.unpack, 'B', buf, L[1] + 1)
            local okt, text = pcall(struct.unpack, 's', buf, L[2] + 1)
            if okm and okt and mode and text and text ~= '' then
                local ch = msgtype_to_channel(mode)
                if ch then return ch, text end
            end
        end
    end
    return nil, nil
end

ashita.events.register('packet_out', 'outgoing_packet', function (e)
    if (e.id == 0x0B5) then
        local ch, msg = parse_outgoing_chat(e)
        -- Say/Tell are already mirrored reliably via the command hook above;
        -- this path only needs to cover channels that hook doesn't (LS1/LS2/Party).
        if ch and msg and ch ~= 'say' and ch ~= 'tell' then
            msg = string.gsub(msg, "%%", "%%%%")
            msg = clean_str(msg)
            local me = current_char_name()
            append_message(ch, me ~= '' and me or 'Me', msg, false)
        end
    end
end)

-- ===== Craft/Combat system messages =====
-- Unlike chat (read straight off the packet), combat/craft/skill-up text is generated by the
-- client itself from a message ID + numeric parameters -- MultiChat has no access to those
-- templates. Rather than reverse-engineer that, this hooks Ashita's `text_in` event, which
-- fires once per line of text right as the client is about to add it to the chat log, already
-- fully resolved. This is the same technique the (HorizonXI-approved) FishAid addon uses to
-- detect fishing messages -- see addons/fishaid/fishaid.lua. Read-only: e.blocked/e.message are
-- never touched, so the player's native chat log is completely unaffected.
--
-- This is a starting pattern set, not an exhaustive one -- easy to extend the same way the
-- rest of MultiChat's config already is. These patterns match against already-visible game
-- text rather than private packet data, which risks a normal chat message coincidentally
-- matching one (confirmed in practice: LS/Shout banter containing the phrase "casts sulfur"
-- got misread as a combat message) -- mitigated two ways, see ORDINARY_CHAT_MODES and
-- is_plausible_actor further down: ordinary chat's mode is excluded from this matching
-- entirely, and any implausibly long "actor" capture that still gets through is rejected.
local CRAFT_SKILL_NAMES = {
    ['cooking']=true, ['fishing']=true, ['woodworking']=true, ['smithing']=true,
    ['goldsmithing']=true, ['clothcraft']=true, ['leathercraft']=true,
    ['bonecraft']=true, ['alchemy']=true, ['synergy']=true,
}

-- Single-word status ailments matched via "(.-) is (%a+)." -- an explicit allowlist rather than
-- accepting any "X is Y." sentence, since that shape is common enough in ordinary chat (which
-- also flows through text_in) that matching it unconditionally would risk misfiring on banter
-- like "loot is mine." "paralyzed"/"slowed" confirmed via in-game screenshot; the rest are a
-- best-effort list of other common FFXI ailments and may need adjusting once seen in-game.
local STATUS_AILMENT_WORDS = {
    ['paralyzed']=true, ['slowed']=true, ['silenced']=true, ['blinded']=true, ['poisoned']=true,
    ['stunned']=true, ['asleep']=true, ['confused']=true, ['charmed']=true, ['terrorized']=true,
    ['petrified']=true, ['amnesiac']=true, ['intoxicated']=true, ['weakened']=true,
    ['diseased']=true, ['bound']=true, ['doomed']=true, ['addled']=true, ['plagued']=true,
}

-- Fixed message-type text colors for Craft/Combat (not user-configurable -- see the Colors
-- section of the Settings window, which deliberately excludes these two channels).
local ABILITY_COLOR    = {255/255, 230/255,  60/255, 1.0} -- yellow: skills/abilities used
local DAMAGE_COLOR     = {255/255,  90/255,  90/255, 1.0} -- red: damage dealt/taken
local HEAL_COLOR       = {120/255, 200/255, 255/255, 1.0} -- light blue: curing/recovery
local ITEM_COLOR       = {1,       1,       1,       1.0} -- white: item drops/who received them
local EXP_COLOR        = {110/255, 220/255, 110/255, 1.0} -- green: experience points gained
local LEVEL_UP_COLOR   = EXP_COLOR                        -- green: level up
local LEVEL_DOWN_COLOR = {255/255, 150/255, 150/255, 1.0} -- light red: level down
local STATUS_COLOR     = {195/255, 130/255, 255/255, 1.0} -- purple: status effects landing (ailments and buffs)

-- Default text color for the SYS tab (general system messages/broadcasts) -- an easy-to-read
-- light purple, matching the shade FFXI's own system text traditionally uses.
local SYSTEM_TEXT_COLOR = {180/255, 150/255, 255/255, 1.0}

-- Auction House messages within SYS get their own color and don't trigger SYS's normal
-- always-alert behavior -- confirmed via in-game screenshot (the "Merchandise placed on
-- auction." confirmation sequence). Not an exhaustive list of every AH message yet (e.g.
-- successful sale/bid notifications aren't covered), just what's been seen so far.
local AH_TEXT_COLOR = ABILITY_COLOR -- yellow
local AH_MESSAGES_EXACT = {
    ['Merchandise placed on auction.'] = true,
    ["If merchandise remains unsold after 30 weeks (Vana'diel time), it will be returned to your current residence."] = true,
    ['If a successful bid is made, the proceeds from the sale will be delivered to your current residence.'] = true,
    ['Signed items will lose their signature after being purchased.'] = true,
    -- Confirmed via in-game screenshot.
    ['Failed to place merchandise on auction.'] = true,
}
local function is_auction_house_message(line)
    if AH_MESSAGES_EXACT[line] then return true end
    if line:match('^The total transaction fee for .- is %d+ gil%.$') then return true end
    -- Confirmed via in-game screenshot ("You have to pay a transaction fee of 4 gil.") --
    -- a different wording from the "total transaction fee for a set of N items" message above,
    -- not just a cropped version of it.
    if line:match('^You have to pay a transaction fee of %d+ gil%.$') then return true end
    -- Sale confirmation to the seller -- confirmed via in-game screenshot ("Your 'Moat carp'
    -- has sold to Quesogrande for 3000 gil!").
    if line:match("^Your '.-' has sold to .- for %d+ gil!$") then return true end
    -- Purchase confirmation to the buyer -- confirmed via in-game screenshot ("You buy the
    -- bottle of Yagudo drink for 1,700 gil."). The gil amount can have thousands-separator
    -- commas ("1,700"), unlike the plain-digit amounts in the other AH messages above, so this
    -- needs its own digit-or-comma pattern rather than reusing %d+.
    if line:match("^You buy the .- for [%d,]+ gil%.$") then return true end
    return false
end


-- Checker (the official, first-party Ashita addon) prints its own /check results itself via
-- print() with Ashita's chat color codes (see addons/Checker/checker.lua) rather than the game
-- sending them as ordinary chat text, so there's no packet/mode to key off of -- text matching
-- is the only option, same reasoning as Auction House messages above.
--
-- Colors below are checker.lua's own difficulty-tier colors, cross-referenced against Ashita's
-- addons/libs/chat.lua color-name table (its color1() calls use the same numeric color-table
-- indices that table names) -- Grey/LawnGreen/Coral/Salmon/Tomato/Magenta are standard CSS
-- color values. "like a decent challenge" (index 102) has no name in that table, so it's left
-- uncolored (falls back to SYS's default) rather than guessed at.
local CHECKER_TIER_COLORS = {
    { prefix = "too weak to be worthwhile", color = {128/255, 128/255, 128/255, 1.0} }, -- Grey
    { prefix = "like easy prey",            color = {124/255, 252/255,   0/255, 1.0} }, -- LawnGreen
    { prefix = "like an even match",        color = {255/255, 127/255,  80/255, 1.0} }, -- Coral
    { prefix = "very tough",                color = {255/255,  99/255,  71/255, 1.0} }, -- Tomato
    { prefix = "incredibly tough",          color = {255/255,  99/255,  71/255, 1.0} }, -- Tomato
    { prefix = "tough",                     color = {250/255, 128/255, 114/255, 1.0} }, -- Salmon
    { prefix = "Impossible to gauge!",      color = {255/255,   0/255, 255/255, 1.0} }, -- Magenta
}

local function checker_tier_color(body)
    for _, t in ipairs(CHECKER_TIER_COLORS) do
        if body:find(t.prefix, 1, true) then return t.color end
    end
    return nil
end

-- The rest of Checker's own coloring (name, arrow, level, brackets/parens, conditions),
-- likewise cross-referenced against chat.lua's color-name table. Index 106 ("cream/yellow",
-- used for the name and conditions -- also used by the conquest addon's "Unknown:" line, see
-- try_conquest_addon_message below) has no exact named value there -- only chat.message()'s own
-- doc comment describing it qualitatively -- so this is a reasonable pale-yellow approximation,
-- not a byte-exact verified color like the others.
local ASHITA_CREAM_COLOR   = {255/255, 250/255, 205/255, 1.0} -- ~cream/yellow (index 106, approximate)
local CHECKER_AQUA_COLOR   = {  0/255, 255/255, 255/255, 1.0} -- Aqua (index 82)
local CHECKER_PURPLE_COLOR = {153/255,  50/255, 204/255, 1.0} -- DarkOrchid (index 81)

-- Returns true (and appends to SYS) if this is a Checker line, false otherwise. Rebuilds the
-- message from its parsed pieces (name/level/verdict/conditions) rather than just passing the
-- raw text through, so each piece can carry its own color span -- matching the native log's
-- own per-segment coloring instead of one flat row color.
local function try_checker_message(line)
    local body = line:match("^%[checker%] (.+)$")
    if not body then return false end

    -- "-" is a Lua pattern magic character (lazy-repetition quantifier), so the literal "->"
    -- arrow needs escaping as "%->" here -- unlike the plain string literal passed to push()
    -- below, which isn't a pattern and needs no escaping.
    local name, level, rest = body:match("^(.-) %-> %(Lv%. (.-)%) (.+)$")
    if not name then
        -- Unexpected format (e.g. a future Checker update) -- fall back to showing the line
        -- as-is, uncolored, rather than silently dropping it.
        append_message('sys', 'Checker', body, true)
        return true
    end

    -- The verdict is followed by "(conditions)" only when the check actually returned any
    -- (Checker's own conditions table has an empty-string entry for "no notable conditions").
    local verdict, condition = rest:match("^(.-) %((.-)%)$")
    if not verdict then verdict = rest end

    local parts, spans, pos = {}, {}, 1
    local function push(str, color)
        table.insert(parts, str)
        if color then table.insert(spans, { s = pos, e = pos + #str - 1, color = color }) end
        pos = pos + #str
    end
    push(name, ASHITA_CREAM_COLOR)
    push(' ')
    push('->', CHECKER_AQUA_COLOR)
    push(' (Lv. ', CHECKER_PURPLE_COLOR)
    push(level, CHECKER_AQUA_COLOR)
    push(')', CHECKER_PURPLE_COLOR)
    push(' ')
    push(verdict, checker_tier_color(verdict))
    if condition and condition ~= '' then
        push(' (', CHECKER_PURPLE_COLOR)
        push(condition, ASHITA_CREAM_COLOR)
        push(')', CHECKER_PURPLE_COLOR)
    end

    append_message('sys', 'Checker', table.concat(parts), true, nil, nil, spans)
    return true
end

-- Server's own periodic "Conquest update:" broadcast (native text, not any addon's output) --
-- text matching rather than mode, same reasoning as Auction House/Checker above. Requires an
-- exact known nation name (San d'Oria/Bastok/Windurst) before "- <level>" so this can't
-- misfire on unrelated chat formatted similarly, without needing to enumerate every possible
-- influence-level word (Major/Minor/Minimal/etc.) FFXI might use.
local function is_conquest_update_line(line)
    if line == 'Conquest update:' then return true end
    if line == 'Regional influence:' then return true end
    if line:match("^This region is currently under .- control%.$") then return true end
    if line:match("^San d'Oria %- %a+$") then return true end
    if line:match("^Bastok %- %a+$") then return true end
    if line:match("^Windurst %- %a+$") then return true end
    return false
end

-- The "conquest" addon (official first-party Ashita addon, GPL-3.0, printed via /conquest or
-- /regions) prints its own results itself via print(), same as Checker -- text matching, no
-- code copied, only the message format and its own color choices referenced (see
-- addons/conquest/conquest.lua's CONTROLLERS table, which itself cites libs/chat.lua) to
-- independently write this. Colors are exact verified matches this time, not approximations --
-- San d'Oria=Tomato(76), Bastok=RoyalBlue(71), Windurst=Yellow(69), Beastmen=Lime(79); the
-- "Unknown:" bucket uses chat.message() (index 106), the same approximate cream used for
-- Checker (see ASHITA_CREAM_COLOR above).
local CONQUEST_NATION_COLORS = {
    { prefix = "San d'Oria", color = {255/255,  99/255,  71/255, 1.0} }, -- Tomato
    { prefix = "Bastok",     color = { 65/255, 105/255, 225/255, 1.0} }, -- RoyalBlue
    { prefix = "Windurst",   color = {255/255, 255/255,   0/255, 1.0} }, -- Yellow
    { prefix = "Beastmen",   color = {  0/255, 255/255,   0/255, 1.0} }, -- Lime
    { prefix = "Unknown",    color = ASHITA_CREAM_COLOR },
}

local function conquest_addon_color(body)
    for _, c in ipairs(CONQUEST_NATION_COLORS) do
        if body:find(c.prefix, 1, true) == 1 then return c.color end
    end
    return nil
end

-- Returns true (and appends to SYS) if this is the conquest addon's own output, false otherwise.
local function try_conquest_addon_message(line)
    local body = line:match("^%[conquest%] (.+)$")
    if not body then return false end
    append_message('sys', 'Conquest', body, true, conquest_addon_color(body))
    return true
end

-- Fishing bite/feel message colors -- taken directly from the approved FishAid addon's own
-- color mapping (addons/fishaid/fishaid.lua:31-45, ARGB 0x00FF00/0x999900/0x8B0000), which
-- matches the native game log's own coloring for these exact messages.
local FISH_GOOD_COLOR    = {0/255,   255/255, 0/255, 1.0} -- green: good sign
local FISH_NEUTRAL_COLOR = {153/255, 153/255, 0/255, 1.0} -- olive/yellow: neutral sign
local FISH_BAD_COLOR     = {230/255, 60/255,  60/255, 1.0} -- red: bad sign (brightened from FishAid's dark 0x8B0000 for legibility)

-- Light green used for item names within a message body (matches how the native log itself
-- highlights item names, e.g. within "obtains"/"caught"/synthesis result lines).
local ITEM_NAME_COLOR = {160/255, 255/255, 160/255, 1.0}

-- Combat username colors: your own name and party/alliance members are two distinct shades of
-- blue (so you can tell yourself apart from the group at a glance), pets/summons are light
-- green, enemies are red, and anyone else unrecognized stays white.
local PLAYER_NAME_COLOR = {1, 1, 1, 1}
local ENEMY_NAME_COLOR  = DAMAGE_COLOR
local SELF_NAME_COLOR   = {120/255, 220/255, 255/255, 1.0}
local ALLY_NAME_COLOR   = {90/255,  140/255, 230/255, 1.0}
local PET_NAME_COLOR    = ITEM_NAME_COLOR

-- Vivid orange, for achievement unlocks -- deliberately distinct from every other color in this
-- file (not a near-miss of ABILITY_COLOR's yellow) so it stands out at a glance. These get
-- broadcast to every tab (see ACHIEVEMENT_CHANNELS below), not just Craft/Combat, so this is
-- used directly rather than via a channel's default.
local ACHIEVEMENT_COLOR = {255/255, 130/255, 0/255, 1.0}

-- Kept as its own list (matching channel_order further down) rather than referencing that local
-- directly, since it's defined much later in the file than process_system_line needs it.
local ACHIEVEMENT_CHANNELS = {'linkshell','linkshell2','party','tell','say','shout','craft','combat','quest','sys'}

-- Each entry: a Lua pattern (capture group 1, if present, is the actor name) and which new
-- channel it routes to. `self_only` entries have no actor in the text itself (e.g. fishing
-- messages, which are always first-person) and are always attributed to the local player.
-- `color`, if present, overrides the row's text color (see ABILITY/DAMAGE/HEAL_COLOR above);
-- entries without one use the channel's default text color.
local SYSTEM_MESSAGE_PATTERNS = {
    -- Combat: abilities/casting are checked before the plainer hits/misses/damage patterns
    -- below, because some real game lines are a single compound sentence, e.g. "Harcyn uses
    -- High Jump, but misses the Big Leech." -- if the generic "misses" pattern were checked
    -- first, its non-greedy actor capture would swallow "Harcyn uses High Jump, but" into the
    -- username instead of stopping at "Harcyn". Checking "uses"/"casts"/"starts casting" first
    -- means the actor capture stops at the ability verb regardless of what follows "but".
    { channel = 'combat', pattern = "^(.-)'s casting is interrupted%.$",                color = ABILITY_COLOR },
    { channel = 'combat', pattern = "^(.-) readies .-%.$",                              color = ABILITY_COLOR },
    { channel = 'combat', pattern = "^(.-) starts casting .- on .-%.$",                 color = ABILITY_COLOR },
    { channel = 'combat', pattern = "^(.-) starts casting .-%.$",                       color = ABILITY_COLOR },
    { channel = 'combat', pattern = "^(.-) casts .-%.$",                                color = ABILITY_COLOR },
    -- Item use ("Sprort uses a Hi-Potion.") vs. ability/TP move use ("The Clipper uses Big
    -- Scissors.") share the identical "X uses Y." shape, with no distinct verb to key off of.
    -- The one reliable signal is grammar: consumable item names take an indefinite article
    -- ("a"/"an") since they're common nouns, while ability/TP move names are capitalized proper
    -- nouns and never do -- so this only matches the article form, checked before the plain
    -- "uses" pattern below. NOT verified against a real item-use screenshot yet; flag if wrong.
    { channel = 'combat', pattern = "^(.-) uses an? (.-)%.$",         item_capture = 2, color = ABILITY_COLOR },
    { channel = 'combat', pattern = "^(.-) uses .-%.$",                                 color = ABILITY_COLOR },

    -- Combat: damage / misses / crits / recovery / defeat
    { channel = 'combat', pattern = "^(.-) hits .- for %d+ points? of damage%.$",       color = DAMAGE_COLOR },
    { channel = 'combat', pattern = "^(.-) takes %d+ points? of damage.*%.$",           color = DAMAGE_COLOR },
    { channel = 'combat', pattern = "^(.-) misses .-%.$",                                color = ITEM_COLOR },
    { channel = 'combat', pattern = "^(.-) scores? a critical hit!?$" },
    { channel = 'combat', pattern = "^(.-) recovers %d+ HP%.$",                         color = HEAL_COLOR },
    { channel = 'combat', pattern = "^(.-) recovers %d+ MP%.$",                         color = HEAL_COLOR },
    { channel = 'combat', pattern = "^(.-) defeats .-%.$" },
    -- Passive voice for the losing side -- confirmed via in-game screenshot ("Daphodin was
    -- defeated by the Goblin Healer.").
    { channel = 'combat', pattern = "^(.-) was defeated by .-%.$" },
    { channel = 'combat', pattern = "^(.-) falls to the ground%.$" },
    { channel = 'combat', pattern = "^(.-) vanishes!?$",                                color = ITEM_COLOR },

    -- Combat: status effects landing -- "is afflicted with X." confirmed via in-game screenshot
    -- earlier this session ("The Clipper is afflicted with Flash."). Single-word ailments
    -- ("is paralyzed.", "is slowed.", etc.) are handled separately in process_system_line
    -- (see STATUS_AILMENT_WORDS) since an unqualified "(.-) is (%a+)%." pattern here would be
    -- too broad and risk matching ordinary chat sentences that happen to fit "X is Y.".
    { channel = 'combat', pattern = "^(.-) is afflicted with .-%.$",                     color = STATUS_COLOR },
    -- Buffs landing -- confirmed via in-game screenshot ("The Clipper gains the effect of Shell.").
    { channel = 'combat', pattern = "^(.-) gains the effect of .-%.$",                   color = STATUS_COLOR },

    -- Combat: item drops -- exact phrasing confirmed via in-game screenshot ("You find a slice
    -- of land crab meat on the Clipper." / "Sprort obtains a slice of land crab meat.").
    { channel = 'combat', pattern = "^You find (.-) on .-%.$",           item_capture = 1, self_only = true, color = ITEM_COLOR },
    { channel = 'combat', pattern = "^(.-) obtains (.-)%.$",             item_capture = 2, color = ITEM_COLOR },
    -- Quest/event rewards -- no actor name in the text at all (confirmed via in-game
    -- screenshot: "Obtained: Page from the Dragon Chronicles.", "Obtained: 10000 gil."). Routed
    -- to Quest, not Combat, since these are quest rewards rather than combat loot.
    { channel = 'quest', pattern = "^Obtained: (.-)%.$",                 item_capture = 1, self_only = true, color = ITEM_COLOR },

    -- Combat: experience points / level up / level down. Level up confirmed via in-game
    -- screenshot ("Twister attains level 42!", "Ramones attains level 14!") -- real wording is
    -- "attains level N!", not the originally-guessed "gains a level!". Level down likewise
    -- confirmed ("Fetters falls to level 54.") -- real wording is "falls to level N.", not the
    -- originally-guessed "loses a level!". Experience is still NOT verified and may need fixing.
    { channel = 'combat', pattern = "^(.-) gains %d+ experience points?%.$",            color = EXP_COLOR },
    { channel = 'combat', pattern = "^(.-) attains level %d+!?$",                       color = LEVEL_UP_COLOR },
    { channel = 'combat', pattern = "^(.-) falls to level %d+%.$",                      color = LEVEL_DOWN_COLOR },

    -- Craft: synthesis results -- native log shows both in plain white, not the craft tab's
    -- default orange. The "lost" wording was previously wrong ("lost the .- ingredients.",
    -- which never matches); confirmed via in-game screenshot the real text is "X lost <item>."
    -- (e.g. "Bite lost a stick of Selbina butter."), no "the ... ingredients" in it at all.
    { channel = 'craft', pattern = "^(.-) synthesized (.-)[%.!]$",       item_capture = 2, color = ITEM_COLOR },
    { channel = 'craft', pattern = "^(.-) lost (.-)%.$",                 item_capture = 2, color = ITEM_COLOR },
    { channel = 'craft', pattern = "^Synthesis failed!?$",                              self_only = true },

    -- Craft: fishing -- exact phrasing AND colors verified against addons/fishaid/fishaid.lua,
    -- which HorizonXI has already approved for detecting these same messages. Each variant is
    -- matched exactly (rather than one wildcard pattern per message family) because the native
    -- log colors each one differently based on bite/skill quality -- see FISH_GOOD/NEUTRAL/BAD.
    { channel = 'craft', pattern = "^Something caught the hook!!!$",                    self_only = true, color = FISH_GOOD_COLOR },
    { channel = 'craft', pattern = "^Something caught the hook!$",                      self_only = true, color = FISH_GOOD_COLOR },
    { channel = 'craft', pattern = "^You feel something pulling at your line%.$",       self_only = true, color = FISH_NEUTRAL_COLOR },
    { channel = 'craft', pattern = "^Something clamps onto your line ferociously!$",    self_only = true, color = FISH_BAD_COLOR },
    { channel = 'craft', pattern = "^You have a good feeling about this one!$",         self_only = true, color = FISH_GOOD_COLOR },
    { channel = 'craft', pattern = "^You have a bad feeling about this one%.$",         self_only = true, color = FISH_NEUTRAL_COLOR },
    { channel = 'craft', pattern = "^You have a terrible feeling about this one%.%.%.$",self_only = true, color = FISH_BAD_COLOR },
    { channel = 'craft', pattern = "^You don't know if you have enough skill to reel this one in%.$",           self_only = true, color = FISH_GOOD_COLOR },
    { channel = 'craft', pattern = "^You're fairly sure you don't have enough skill to reel this one in%.$",    self_only = true, color = FISH_NEUTRAL_COLOR },
    { channel = 'craft', pattern = "^You're positive you don't have enough skill to reel this one in!$",       self_only = true, color = FISH_BAD_COLOR },
    -- Giving up on a bite -- confirmed via in-game screenshot ("You give up and reel in your
    -- line."), shown in the native log's plain default color (white), not a good/bad signal.
    { channel = 'craft', pattern = "^You give up and reel in your line%.$",             self_only = true, color = ITEM_COLOR },
    -- Not self_only: confirmed via in-game screenshot that catch results are visible for
    -- other players too ("Xenruu caught a moat carp!"), not just your own ("You caught a...").
    { channel = 'craft', pattern = "^(.-) caught (.-)!$",                item_capture = 2, color = ITEM_COLOR },
    { channel = 'craft', pattern = "^The fish gets away%.?!?$",                         self_only = true },
    -- Confirmed via in-game screenshot -- neutral outcome, same treatment as "The fish gets
    -- away." above (self_only, no explicit color -- falls back to the Craft tab's default).
    { channel = 'craft', pattern = "^You didn't catch anything%.$",                     self_only = true },
    -- Confirmed via in-game screenshot -- shown in the native log's plain default color, not
    -- FISH_BAD_COLOR, despite losing the catch (same treatment as "You give up and reel in
    -- your line." above).
    { channel = 'craft', pattern = "^Your line breaks%.$",                              self_only = true, color = ITEM_COLOR },
    -- Can't-fish conditions -- confirmed via in-game screenshot ("You can't fish without bait
    -- on the hook.", "You can't fish at the moment."). Informational rather than a bite-quality
    -- signal, so the same plain white as "You give up and reel in your line." above rather than
    -- one of the good/neutral/bad fishing colors.
    { channel = 'craft', pattern = "^You can't fish without bait on the hook%.$",       self_only = true, color = ITEM_COLOR },
    { channel = 'craft', pattern = "^You can't fish at the moment%.$",                  self_only = true, color = ITEM_COLOR },
}

-- Best-effort pet/avatar/fellow name lookup for the "Me & Pets" filter. Party slot 0 is always
-- the local player; if its pet-index field is populated, whichever party slot's target index
-- matches it is the player's own pet/avatar/wyvern/automaton/fellow. Wrapped in pcall at the
-- call site since the exact pet-index API wasn't independently verified the way the rest of
-- this feature was -- if it's wrong, "Me & Pets" degrades to just "Me" rather than erroring.
local function get_my_pet_name()
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then return nil end
    local myPetIndex = party:GetMemberPetIndex(0)
    if not myPetIndex or myPetIndex == 0 then return nil end
    for i = 1, 5 do
        if party:GetMemberTargetIndex(i) == myPetIndex then
            return party:GetMemberName(i)
        end
    end
    return nil
end

local function actor_matches_filter(actor_name, filter_mode)
    if filter_mode ~= 'mine' then return true end
    local me = current_char_name()
    local is_mine = (me ~= '' and actor_name:lower() == me:lower())
    if not is_mine then
        local ok, petName = pcall(get_my_pet_name)
        if ok and petName and petName ~= '' and actor_name:lower() == petName:lower() then
            is_mine = true
        end
    end
    return is_mine
end

local function is_self(actor_name)
    if not actor_name or actor_name == '' then return false end
    local me = current_char_name()
    return me ~= '' and actor_name:lower() == me:lower()
end

-- Whether an actor is a member of your full alliance (your own party plus both linked alliance
-- parties, if any -- trusts and pets occupy slots the same way, per get_my_pet_name above), for
-- the Combat username color. Same verified technique as SimpleLog's GetPartyData/parse_party
-- (lib/functions.lua): the party memory manager exposes 3 sub-parties of up to 6 members each,
-- at slot ranges 0-5 / 6-11 / 12-17, and each sub-party's count must be checked before reading
-- its slots -- unlike is_self, querying an unpopulated slot isn't guaranteed to read back empty.
local function is_known_alliance_member(actor_name)
    if not actor_name or actor_name == '' then return false end
    local ok, party = pcall(function() return AshitaCore:GetMemoryManager():GetParty() end)
    if not ok or not party then return false end
    local subparties = {
        { mod = 0,  count_fn = 'GetAlliancePartyMemberCount1' },
        { mod = 6,  count_fn = 'GetAlliancePartyMemberCount2' },
        { mod = 12, count_fn = 'GetAlliancePartyMemberCount3' },
    }
    for _, sp in ipairs(subparties) do
        local okCount, count = pcall(function() return party[sp.count_fn](party) end)
        if okCount and count and count > 0 and count <= 6 then
            for i = 0, count - 1 do
                local okName, nm = pcall(function() return party:GetMemberName(i + sp.mod) end)
                if okName and nm and nm ~= '' and actor_name:lower() == nm:lower() then
                    return true
                end
            end
        end
    end
    return false
end

-- Whether anyone besides the player themselves currently occupies a party/alliance slot.
-- Needed specifically for the player's own emotes below -- the player's own name always
-- occupies slot 0 in the party memory block even when not partied at all (solo), which alone
-- is enough for is_known_alliance_member to report a match, so "You" resolving to a known
-- alliance member isn't by itself proof of an actual party. Confirmed via user report: a solo
-- player's own emote was showing in Party. Not a concern for other actors' names (a solo
-- player has no other slots for another name to match against in the first place).
local function has_other_party_members()
    local ok, party = pcall(function() return AshitaCore:GetMemoryManager():GetParty() end)
    if not ok or not party then return false end
    local total = 0
    for _, count_fn in ipairs({'GetAlliancePartyMemberCount1', 'GetAlliancePartyMemberCount2', 'GetAlliancePartyMemberCount3'}) do
        local okCount, count = pcall(function() return party[count_fn](party) end)
        if okCount and count and count > 0 and count <= 6 then total = total + count end
    end
    return total > 1
end

-- Wraps is_known_alliance_member with the self-when-solo correction above: for the player's
-- own name specifically, being a "known alliance member" isn't enough on its own (see
-- has_other_party_members' comment) -- for any other name, is_known_alliance_member alone is
-- already correct.
local function is_genuine_party_member(actor_name)
    if actor_name:lower() == current_char_name():lower() then
        return has_other_party_members()
    end
    return is_known_alliance_member(actor_name)
end

-- Emote text ("Kosami nods.", "You wave.", "Sprort waves to Abbynightwish.") always leads with
-- the actor's name (or "You" for your own), so the first word is enough to identify who --
-- reused here, not duplicated, since is_known_alliance_member already exists for Combat's
-- username coloring. Confirmed via user report/screenshot: a targeted emote at someone outside
-- the party/alliance was still landing in Party just because the *actor* happened to be a
-- party member -- the target matters too, not just the actor. Qualifies for Party only when
-- the actor is a party/alliance member AND (if the emote names a target at all) that target is
-- too; otherwise it's routed to Say instead of being silently dropped, matching how ordinary
-- nearby chat already behaves.
local function try_party_emote(line)
    local actor = line:match('^(%a+) ')
    if not actor then return false end
    if actor:lower() == 'you' then
        local me = current_char_name()
        if me == '' then return false end
        actor = me
    end

    local target = line:match('%sto (%a+)%.?!?$') or line:match('%sat (%a+)%.?!?$')

    local qualifies = is_genuine_party_member(actor)
    if qualifies and target then
        qualifies = is_genuine_party_member(target)
    end

    append_message(qualifies and 'party' or 'say', actor, line, true)
    return true
end

-- Looks up a currently-loaded entity by name (case-insensitive). Same technique as
-- GetEntityByServerId in the approved SimpleLog addon (lib/functions.lua), just matched by
-- name instead of server ID since text_in only gives us plain text, not IDs. 2304 is the same
-- max entity-index bound SimpleLog scans.
local function find_entity_by_name(name)
    if not name or name == '' then return nil end
    local lname = name:lower()
    local found
    -- Scans with the entity manager's direct GetName(index) accessor, which returns just the
    -- name string, rather than the global GetEntity(index), which builds a whole entity object
    -- per call -- 2304 of those per lookup was pure waste when all we need to compare is the
    -- name. The full entity is only constructed for the single match. Same accessor style the
    -- approved HXUI/luashitacast/kazenoeye addons use.
    -- One pcall around the entire scan rather than one per call, too: a pcall per iteration is
    -- real overhead that added up badly when many distinct actors show up in quick succession --
    -- e.g. idling in a busy town where lots of nearby players are casting buffs/using items,
    -- each a new combat-channel actor to resolve.
    pcall(function()
        local em = AshitaCore:GetMemoryManager():GetEntity()
        for i = 0, 2303 do
            local n = em:GetName(i)
            if n and n ~= '' and n:lower() == lname then
                found = GetEntity(i)
                return
            end
        end
    end)
    return found
end

-- Whether a found entity is an NPC/monster rather than a player. Verified bit check, taken
-- directly from SimpleLog's actionhandlers.lua:855 ("ActorIsNpc = bit.band(SpawnFlags, 0x1) == 0").
local function entity_is_npc(ent)
    local ok, flags = pcall(function() return ent.SpawnFlags end)
    if not ok or not flags then return nil end
    return bit.band(flags, 0x1) == 0
end

-- Whether an already-found entity is a pet/summon (or fellow NPC) belonging to anyone in your
-- alliance. Takes the entity directly (rather than re-looking it up by name) since the caller
-- already has it. Corrected technique, verified against SimpleLog's actionhandlers.lua:881,890:
-- each alliance member's own ENTITY object (from GetEntity(their TargetIndex), not the
-- party-memory-manager's per-slot data) exposes .PetTargetIndex / .FellowTargetIndex fields
-- giving their pet/fellow's TargetIndex, matched against the candidate entity's own TargetIndex.
-- An earlier version of this used party:GetMemberPetIndex()/GetMemberTargetIndex() instead,
-- which turned out wrong -- confirmed when a real Summoner avatar (Ifrit) wasn't detected and
-- fell through to being colored as an enemy.
local function is_known_pet_entity(candidateEnt)
    local okTgt, candidateTgt = pcall(function() return candidateEnt.TargetIndex end)
    if not okTgt or not candidateTgt then return false end

    local ok, party = pcall(function() return AshitaCore:GetMemoryManager():GetParty() end)
    if not ok or not party then return false end

    local subparties = {
        { mod = 0,  count_fn = 'GetAlliancePartyMemberCount1' },
        { mod = 6,  count_fn = 'GetAlliancePartyMemberCount2' },
        { mod = 12, count_fn = 'GetAlliancePartyMemberCount3' },
    }
    for _, sp in ipairs(subparties) do
        local okCount, count = pcall(function() return party[sp.count_fn](party) end)
        if okCount and count and count > 0 and count <= 6 then
            for i = 0, count - 1 do
                local slot = i + sp.mod
                local okTi, memberTi = pcall(function() return party:GetMemberTargetIndex(slot) end)
                if okTi and memberTi and memberTi ~= 0 then
                    local okEnt, memberEnt = pcall(GetEntity, memberTi)
                    if okEnt and memberEnt then
                        local okPet, petTi = pcall(function() return memberEnt.PetTargetIndex end)
                        if okPet and petTi and petTi ~= 0 and petTi == candidateTgt then return true end
                        local okFel, felTi = pcall(function() return memberEnt.FellowTargetIndex end)
                        if okFel and felTi and felTi ~= 0 and felTi == candidateTgt then return true end
                    end
                end
            end
        end
    end
    return false
end

-- Cache of actor-name -> resolved Combat username color, so a mob/player hit repeatedly across
-- many messages in a fight (the common case) doesn't re-scan the full entity table every time.
-- Short TTL since entities can change (a mob dies, a same-named replacement spawns later).
-- Pruned periodically (see the sweep in resolve_combat_uname_color): without it the table grew
-- without bound -- idling in a busy town where lots of distinct nearby players cast buffs/use
-- items generates combat-routed messages under ever-more names, and each left a permanent
-- entry, so the table and the GC work to walk it grew the longer you sat there, steadily
-- degrading frame time. Confirmed via user report of worsening frame drops after extended idling.
local combat_uname_color_cache = {}
local COMBAT_UNAME_CACHE_TTL = 5.0
local combat_uname_cache_inserts = 0
local COMBAT_UNAME_CACHE_PRUNE_EVERY = 128

-- SpawnFlags bit that marks an entity as a monster. Confirmed via in-game diagnostic on
-- HorizonXI: a real mob (Arid Lizard) had SpawnFlags 0x10, while pets -- a BST jug pet
-- (LullabyMelodia) and a party summoner's avatar (Garuda) -- had 0x02 (NPC), no 0x10. So the
-- monster bit, not the entity-index range (an earlier attempt using TargetIndex > 1791 wrongly
-- flagged that Arid Lizard, which sat at 1792, as a pet), is what separates an enemy from a
-- pet. Any non-player entity without this bit that turns up as a combat actor is a pet/summon.
local MONSTER_SPAWN_FLAG = 0x10

-- Resolves the Combat username color for an actor: your own name is one shade of blue and
-- party/alliance members are a different shade; pets/summons are light green; confirmed NPC/
-- monster entities are red; everything else (including a real player who isn't in your
-- alliance, or an actor whose entity can't be found at all, e.g. already despawned) defaults to
-- white. The entity lookup is done once per actor and cached (see combat_uname_color_cache
-- above) and reused for both the pet and enemy checks, rather than scanning the entity table
-- twice per message.
local function resolve_combat_uname_color(actor_name)
    if is_self(actor_name) then return SELF_NAME_COLOR end

    local lname = actor_name:lower()
    local now = os.clock()
    local cached = combat_uname_color_cache[lname]
    if cached and (now - cached.t) < COMBAT_UNAME_CACHE_TTL then
        return cached.color
    end

    local color = PLAYER_NAME_COLOR
    -- Party/alliance membership is checked first, by name against the party roster -- reliable,
    -- and it means a trust or any allied player is always the alliance shade regardless of how
    -- its entity happens to be flagged (a trust is an NPC-type entity). Only non-members fall
    -- through to entity-based classification.
    if is_known_alliance_member(actor_name) then
        color = ALLY_NAME_COLOR
    else
        local ok, ent = pcall(find_entity_by_name, actor_name)
        if ok and ent then
            if is_known_pet_entity(ent) then
                color = PET_NAME_COLOR
            elseif entity_is_npc(ent) == true then
                -- Non-player entity: a monster if it carries the monster SpawnFlag, otherwise a
                -- pet/summon (see MONSTER_SPAWN_FLAG). This is what colors other players' pets
                -- (a BST's jug pet, a party summoner's avatar) as pets rather than enemies --
                -- the per-owner linkage is_known_pet_entity relies on isn't populated
                -- client-side for anyone but yourself.
                local okSf, sf = pcall(function() return ent.SpawnFlags end)
                if okSf and sf and bit.band(sf, MONSTER_SPAWN_FLAG) ~= 0 then
                    color = ENEMY_NAME_COLOR
                else
                    color = PET_NAME_COLOR
                end
            end
        end
    end

    combat_uname_color_cache[lname] = { color = color, t = now }
    -- Sweep expired entries every so often (amortized, not every insert) so the cache stays
    -- bounded to roughly one TTL window's worth of distinct actors instead of growing forever.
    combat_uname_cache_inserts = combat_uname_cache_inserts + 1
    if combat_uname_cache_inserts >= COMBAT_UNAME_CACHE_PRUNE_EVERY then
        combat_uname_cache_inserts = 0
        for k, v in pairs(combat_uname_color_cache) do
            if (now - v.t) >= COMBAT_UNAME_CACHE_TTL then combat_uname_color_cache[k] = nil end
        end
    end
    return color
end

-- These message templates almost always start with the actor's name (e.g. "${actor}
-- synthesized..." or "${actor}'s casting is interrupted..."), which is also already shown in
-- the username column -- strip it back off the front of the message body so it isn't repeated.
-- Also eats a following possessive "'s " (e.g. "Emerly's casting is interrupted." ->
-- "casting is interrupted."), otherwise a dangling "'s " is left on the front of the body for
-- any possessive-form pattern -- the same bug already fixed once for skill-up messages.
local function strip_actor_prefix(full_text, actor)
    if not actor or actor == '' then return full_text end
    if full_text:sub(1, #actor) == actor then
        return (full_text:sub(#actor + 1):gsub("^'s%s*", ''):gsub('^%s+', ''))
    end
    return full_text
end

-- Locates an already-extracted item name within the final displayed body text, so the renderer
-- can highlight just that span (see ITEM_NAME_COLOR / draw_wrapped_colored). Plain-text find
-- (not a pattern search) since the item name is a literal substring at this point, not itself
-- a pattern to match against. Returns a single-entry spans list (see append_message), the same
-- shape append_message's `spans` parameter expects directly.
local function find_item_span(body, item_name)
    if not item_name or item_name == '' then return nil end
    local s, e = body:find(item_name, 1, true)
    if not s then return nil end
    return { { s = s, e = e, color = ITEM_NAME_COLOR } }
end

-- Delivery box messages (claiming Auction House sale proceeds from the mog house delivery box,
-- 8 numbered slots) -- text matched, not mode, same reasoning as Auction House above. Confirmed
-- via in-game screenshot ("Slot 5:", "The money the buyer paid for the bird egg you put on
-- auction, 50 gil.", "You take the 50 gil out of delivery slot 5."). Kept as its own username
-- ("Delivery") rather than folded into the Auction messages, per explicit request. No alert --
-- routine bookkeeping after a sale, not something needing attention the way the sale
-- notification itself already does. Defined here (rather than beside is_auction_house_message)
-- specifically because it calls find_item_span above -- placing it earlier resolved that as a
-- nil global and errored the whole text_in callback.
local function try_delivery_message(line)
    local item = line:match('^The money the buyer paid for the (.-) you put on auction, [%d,]+ gil%.$')
    local isDelivery = item ~= nil
        or line:match('^Slot %d+:$')
        or line:match('^You take the [%d,]+ gil out of delivery slot %d+%.$')
    if not isDelivery then return false end
    -- no_alert = true (routine bookkeeping) and no_dedupe = true (repeated identical payout
    -- lines from claiming a stack of the same item are all real, not double-captures).
    append_message('sys', 'Delivery', line, true, AH_TEXT_COLOR, nil, find_item_span(line, item), true, nil, true)
    return true
end

-- Merges the Angler ability's catch-reveal ("Your keen angler's senses tell you that this is
-- the pull of a moat carp!") into the immediately-preceding "Something caught the hook!" row
-- instead of adding a second row -- confirmed via in-game screenshot that the two always share
-- the exact same timestamp when this happens. Deliberately scoped to only that specific
-- pairing (checked by exact prior message text + matching timestamp) rather than merging on
-- every hook bite, since an ordinary hook bite with no reveal following stays its own line.
-- Returns true if merged, false if there was no matching hook line to merge into (so the
-- caller can fall back to appending the reveal as its own line instead of silently dropping it).
local function try_merge_angler_reveal(fish)
    local okBucket, bucket = pcall(function() return chat.messages.craft end)
    if not okBucket or not bucket then return false end
    local last = bucket:last()
    if not last then return false end
    if last.message ~= 'Something caught the hook!!!' and last.message ~= 'Something caught the hook!' then
        return false
    end
    if last.epoch ~= os.time() then return false end
    last.message = last.message .. " You sense it's a " .. fish .. '!'
    last.spans = find_item_span(last.message, fish)
    return true
end

-- FFXI grammatically prefixes most mob names with "The" ("The Clipper misses...", "hits the
-- Clipper for..."), but the mob's actual name has no article. Only applied to the extracted
-- actor (username column), not the message body -- body text keeps the article since it reads
-- as normal English narration there ("hits the Clipper for..."), and blindly stripping "the "
-- from message bodies would also mangle unrelated phrases ("the ingredients", "the ground").
local function strip_leading_article(name)
    if not name or name == '' then return name end
    return name:match('^[Tt]he%s+(.+)$') or name
end

-- FFXI attributes a ranged attack to a possessive phrase rather than the bare name -- "X's
-- ranged attack hits Y for N points of damage." (another entity) or "Your ranged attack hits
-- Y..." (yourself) -- so the loose "^(.-) hits ..." actor capture grabs the whole
-- "X's ranged attack" as the username. Confirmed via in-game screenshot ("Infamousgalka's
-- ranged attack: ...", "Orcish Stonechucker's ranged attack: ..."). This reduces the captured
-- actor back to just the entity (so the username resolves to a real entity for coloring, and
-- reads cleanly), returning the "ranged attack" bit to be folded into the message body instead.
-- The owner is anything before the trailing "'s ranged attack" -- not just a single word --
-- since mob names are often multiple words (e.g. "Orcish Stonechucker"); still constrained to
-- the exact "ranged attack" phrasing so it can't misfire on some other "'s ..." possessive.
local function resolve_ranged_attack_actor(actor)
    local owner = actor:match("^(.-)'s ranged attack$")
    if owner and owner ~= '' then return owner, 'ranged attack' end
    if actor:match('^[Yy]our ranged attack$') then return 'You', 'ranged attack' end
    return actor, nil
end

-- Rejects implausibly long "actor" captures from the loose SYSTEM_MESSAGE_PATTERNS entries
-- (uses/casts/hits/misses/etc.). Real actor names (players, mobs, even long-titled NMs) are a
-- handful of words at most. This was the original fix for ordinary LS/Shout chat coincidentally
-- containing a combat-shaped phrase ("...and casts sulfur..." inside a sentence about a video)
-- getting captured whole, with everything up to the verb treated as the actor name -- the
-- primary fix for that is now the ORDINARY_CHAT_MODES exclusion below (which stops chat from
-- ever reaching these patterns at all), but this stays on as a second layer of defense for
-- whatever mode that exclusion doesn't cover.
local MAX_ACTOR_WORDS = 6
local function is_plausible_actor(name)
    local n = 0
    for _ in name:gmatch('%S+') do
        n = n + 1
        if n > MAX_ACTOR_WORDS then return false end
    end
    return true
end

-- Craft has no enemies (crafting/fishing is always a player action), so it always uses the
-- default username color; only Combat needs the enemy/player resolution.
local function resolve_uname_color(channel, actor_name)
    if channel ~= 'combat' then return nil end
    local ok, color = pcall(resolve_combat_uname_color, actor_name)
    return ok and color or nil
end

-- Achievement unlocks and HorizonXI's server-wide "hardcore character" milestone announcements
-- (both confirmed via in-game screenshot) are detected by text rather than chat mode, and
-- broadcast to every tab rather than just whichever channel their mode would otherwise route
-- to, since they're notable enough to want visible regardless of which tab is active. Checked
-- before any mode-based routing (NPC/Shout-Yell/SYS/Craft-Combat) so they always get this
-- treatment no matter what mode they happen to arrive under. Returns true if this line was one
-- of these and has already been fully handled, false otherwise.
local function try_broadcast_message(msg)
    -- Username takes the same color as the message text, so the whole row reads as one
    -- broadcast regardless of which tab it turns up in (rather than picking up each channel's
    -- own username color). Passed explicitly as uname_color -- see draw_channel_messages.
    if msg:match("^Achievement Unlocked:") then
        for _, ch in ipairs(ACHIEVEMENT_CHANNELS) do
            append_message(ch, 'Achievement', msg, true, ACHIEVEMENT_COLOR, ACHIEVEMENT_COLOR)
        end
        return true
    end

    if msg:match("^★ .- has reached level %d+ on .- as a hardcore character! ★$") then
        for _, ch in ipairs(ACHIEVEMENT_CHANNELS) do
            append_message(ch, 'Hardcore', msg, true, ACHIEVEMENT_COLOR, ACHIEVEMENT_COLOR)
        end
        return true
    end

    return false
end

-- Handles exactly one real game line. Split out from the text_in callback because a single
-- text_in event can bundle more than one game line together separated by "\n" (e.g. a TP move
-- name line immediately followed by its damage line) -- and Lua patterns' "." matches newlines,
-- so matching the raw multi-line blob directly let a pattern like "^(.-) uses .-%.$" swallow
-- both lines into one garbled entry (blown-out username column, orphaned trailing fragments).
-- Most recent amount of experience the player themselves gained, for the popped-out Combat
-- window's display (see the d3d_present handler) -- not part of any message row, just a small
-- side-effect capture alongside the existing "gains N experience points." pattern below (which
-- doesn't itself capture the number, only the actor, so this needs its own check).
local last_exp_gained = nil

local function process_system_line(msg)
    if not msg or msg == '' then return end

    -- Side-effect only (doesn't return) -- the actual Combat-tab row for this message is still
    -- appended normally further down, via the generic "gains N experience points." entry in
    -- SYSTEM_MESSAGE_PATTERNS.
    local expActor, expAmount = msg:match("^(.-) gains (%d+) experience points?%.$")
    if expActor and expAmount then
        local me = current_char_name()
        if me ~= '' and expActor:lower() == me:lower() then
            last_exp_gained = tonumber(expAmount)
        end
    end

    -- Skill-ups (combat or craft, disambiguated by skill name -- both use the identical
    -- "${actor}'s ${skill} skill rises/reaches..." shape regardless of category).
    local skillActor, skillName = msg:match("^(.-)'s (.-) skill .+%.$")
    if skillActor and skillName then
        local ch = CRAFT_SKILL_NAMES[skillName:lower()] and 'craft' or 'combat'
        -- Possessive form ("Sprort's enhancing magic skill...") -- strip_actor_prefix only
        -- removes the bare name, leaving a dangling "'s " on the front of the body, so strip
        -- that separately here instead.
        local body = (msg:sub(#skillActor + 1)):gsub("^'s%s*", '')
        skillActor = strip_leading_article(skillActor)
        -- "X's skill rises N points." is an incremental skill-up (ability yellow); "X's skill
        -- reaches level N." is a skill level up, same green as attaining a character level --
        -- confirmed via in-game screenshot ("Daphodin's evasion skill reaches level 253.").
        local skill_color = body:match('reaches level %d+') and LEVEL_UP_COLOR or ABILITY_COLOR
        append_message(ch, skillActor, body, true, skill_color, resolve_uname_color(ch, skillActor))
        return
    end

    -- Angler-ability catch reveal -- confirmed via in-game screenshot ("Your keen angler's
    -- senses tell you that this is the pull of a moat carp!"). Merged into the "Something
    -- caught the hook!" row that immediately precedes it (see try_merge_angler_reveal) rather
    -- than shown as its own line, since the two always arrive together at the same instant.
    local anglerFish = msg:match("^Your keen angler's senses tell you that this is the pull of a (.-)!$")
    if anglerFish then
        if not try_merge_angler_reveal(anglerFish) then
            -- No matching hook line to merge into (shouldn't normally happen) -- fall back to
            -- showing it on its own rather than silently dropping the message.
            local me = current_char_name()
            local who = me ~= '' and me or 'You'
            append_message('craft', who, msg, true, FISH_GOOD_COLOR, nil, find_item_span(msg, anglerFish))
        end
        return
    end

    -- Single-word status ailments ("The Clipper is paralyzed.") -- checked against the explicit
    -- STATUS_AILMENT_WORDS allowlist (see its definition) rather than accepted unconditionally,
    -- to avoid misfiring on ordinary "X is Y." chat sentences that also pass through text_in.
    local statusActor, statusWord = msg:match("^(.-) is (%a+)%.$")
    if statusActor and statusWord and STATUS_AILMENT_WORDS[statusWord:lower()] then
        local body = strip_actor_prefix(msg, statusActor)
        statusActor = strip_leading_article(statusActor)
        append_message('combat', statusActor, body, true, STATUS_COLOR, resolve_uname_color('combat', statusActor))
        return
    end

    for _, entry in ipairs(SYSTEM_MESSAGE_PATTERNS) do
        if entry.self_only then
            if msg:find(entry.pattern) then
                local me = current_char_name()
                local who = me ~= '' and me or 'You'
                local spans
                if entry.item_capture then
                    local matches = { msg:match(entry.pattern) }
                    spans = find_item_span(msg, matches[entry.item_capture])
                end
                append_message(entry.channel, who, msg, true, entry.color, resolve_uname_color(entry.channel, who), spans)
                return
            end
        else
            local matches = { msg:match(entry.pattern) }
            local actor = matches[1]
            if actor and not is_plausible_actor(actor) then actor = nil end
            if actor then
                -- Strip the prefix (e.g. "You ") before normalizing "You" -> the player's real
                -- name, so the body text doesn't still start with "You" once the username
                -- column already shows the resolved name.
                local body = strip_actor_prefix(msg, actor)
                -- Ranged attacks capture as "X's ranged attack" / "Your ranged attack" -- reduce
                -- to the bare entity for the username and fold "ranged attack" back into the body
                -- (see resolve_ranged_attack_actor). body starts after the full original actor
                -- (strip_actor_prefix also removed the trailing "'s"), so re-prepend the phrase.
                local rangedOwner, rangedPhrase = resolve_ranged_attack_actor(actor)
                if rangedPhrase then
                    actor = rangedOwner
                    body = rangedPhrase .. ' ' .. body
                end
                local spans = entry.item_capture and find_item_span(body, matches[entry.item_capture])
                if actor:lower() == 'you' then
                    local me = current_char_name()
                    if me ~= '' then actor = me end
                end
                actor = strip_leading_article(actor)
                append_message(entry.channel, actor, body, true, entry.color, resolve_uname_color(entry.channel, actor), spans)
                return
            end
        end
    end
end

-- Chat mode for NPC dialogue on text_in events -- verified via the approved Balloon addon
-- (addons/balloon/defines.lua: chat_modes.message = 150), which uses this exact mode
-- unconditionally to detect NPC speech for its speech-bubble display, separate from chat_modes
-- .say (9) and every other player-chat mode. e.mode carries extra bits beyond this single byte,
-- so it's masked the same way Balloon does before comparing.
local NPC_DIALOGUE_MODE = 150
local SHOUT_MODE = 10
local YELL_MODE  = 11
-- General system messages/broadcasts (SYS tab) -- verified via the same Balloon table
-- (chat_modes.system = 151), separate from chat_modes.message (150, NPC dialogue) above.
local SYSTEM_MODE = 151
-- Emotes ("Kosami nods.") -- same Balloon table (chat_modes.emote = 15), already trusted
-- elsewhere in this file (see ORDINARY_CHAT_MODES). Reliable enough to key off directly, unlike
-- Auction House/Checker/conquest above -- there's no ambiguity like mode 121 being shared with
-- synthesis, and enumerating every possible emote verb phrasing to text-match instead would be
-- impractical (dozens of emotes, each with its own third-person sentence).
local EMOTE_MODE = 15

-- Chat modes that are always ordinary player chat, never combat/craft system text -- same
-- verified table as NPC_DIALOGUE_MODE above (addons/balloon/defines.lua chat_modes). Used to
-- exclude regular chat from ever reaching the Combat/Craft pattern-matching in
-- process_system_line, rather than an allowlist of known system-text modes: real-world evidence
-- (LS/Shout banter that happened to contain the phrase "casts sulfur" got captured as a fake
-- combat message) shows the loose text patterns alone aren't enough. An exclusion list is the
-- safer direction here since Balloon's table isn't a complete map of every mode combat/craft
-- text can arrive under -- excluding known-ordinary-chat modes can only ever remove false
-- positives, whereas an incomplete allowlist of "combat modes" could silently stop capturing
-- real messages sent under a mode not in the list. is_plausible_actor (see below) still runs as
-- a second layer of defense for whatever reaches this point. Shout/Yell (10/11) are also listed
-- here (they're ordinary chat, not combat text) even though they get their own dedicated
-- handling below rather than being silently dropped like the rest of this list.
local ORDINARY_CHAT_MODES = {
    [9]   = true, -- say
    [10]  = true, -- shout
    [11]  = true, -- yell
    [12]  = true, -- tell
    [13]  = true, -- party
    [14]  = true, -- linkshell
    [15]  = true, -- emote
    [212] = true, -- unity
    [214] = true, -- linkshell2
    [220] = true, -- assist (Japanese)
    [222] = true, -- assist (English)
}

-- Splits "Name : text" into a name + body. Same technique as the approved Balloon addon
-- (Balloon.lua:369-377): find the first ".- : " substring, and only treat it as a name prefix
-- if it starts at the very beginning of the line and ends within the first 32 characters
-- (guards against a naturally-occurring " : " deeper in the text itself being mistaken for a
-- name). Falls back to `fallback_name` if no prefix is found. NPC dialogue only -- Shout/Yell
-- uses a different native format (see parse_shout_yell_line below).
local function parse_named_line(msg, fallback_name)
    local pStart, pEnd = msg:find('.- : ')
    if pStart == 1 and pEnd and pEnd <= 32 then
        local prefix = msg:sub(pStart, pEnd)
        local name = prefix:sub(1, #prefix - 2):match('^%s*(.-)%s*$')
        local body = msg:sub(pEnd + 1)
        if name and name ~= '' and body ~= '' then
            return name, body
        end
    end
    return fallback_name, msg
end

-- NPC dialogue continuation lines (no prefix of their own) inherit whichever speaker's line
-- most recently had one -- confirmed via in-game screenshot: the native log itself groups a
-- continuation line under the very same timestamp with no new speaker shown (an NPC finishing
-- their own thought in a second sentence, not a different NPC replying) -- falling back to a
-- generic "NPC" only if there's no known speaker yet at all.
local function parse_npc_dialogue_line(msg, fallback_speaker)
    return parse_named_line(msg, fallback_speaker or 'NPC')
end

-- Splits Shout/Yell's native "Name: text" (same zone) or "Name[Zone]: text" (speaker in a
-- different zone) into a name + body -- confirmed via in-game screenshot ("Onikano[PortJeuno]:
-- ISP...", "Yrian[LowJeuno]: BRD29 LFG..."). Unlike NPC dialogue's "Name : text", there's no
-- space before the colon, so parse_named_line's pattern never matches this and always falls
-- through to 'Unknown'. Splits on the first ": " in the line rather than requiring a specific
-- bracket shape, since a player name can't itself contain a colon.
local function parse_shout_yell_line(msg, fallback_name)
    local name, body = msg:match('^(.-): (.*)$')
    if name and name ~= '' and body and body ~= '' then
        return name, body
    end
    return fallback_name, msg
end

ashita.events.register('text_in', 'multichat_text_in_cb', function (e)
    local okMsg, rawMsg = pcall(function() return e.message end)
    if not okMsg or not rawMsg or rawMsg == '' then return end

    -- Strip auto-translate/color-code control characters the same way the chat pipeline
    -- already does for LS/Party/Say/Tell -- text_in's text still carries these.
    local okClean, msg = pcall(clean_str, rawMsg)
    if not okClean or not msg or msg == '' then return end

    -- e.mode carries extra bits beyond the single-byte chat mode -- masked the same way the
    -- approved Balloon addon does before comparing (see NPC_DIALOGUE_MODE above).
    local okMode, rawMode = pcall(function() return e.mode end)
    local mode = (okMode and rawMode) and bit.band(rawMode, 0xFF) or nil

    -- Tracks the most recent named NPC speaker within THIS event's lines (see
    -- parse_npc_dialogue_line), so an unprefixed continuation line is attributed to the same
    -- speaker instead of falling back to a generic "NPC". Reset per event rather than
    -- persisted across events, since there's no reliable signal an unrelated later event's
    -- unprefixed line (if that ever happens) belongs to the same speaker.
    local npc_speaker = nil

    for line in (msg .. '\n'):gmatch('(.-)\r?\n') do
        if line ~= '' then
            if try_broadcast_message(line) then
                -- Achievement unlock / hardcore-character milestone -- already fully handled
                -- (broadcast to every tab), regardless of what mode it arrived under.
            elseif is_auction_house_message(line) then
                -- Checked by text, not mode, same as try_broadcast_message above -- unlike
                -- everything else here, we don't actually know which mode AH messages arrive
                -- under (SYSTEM_MODE was a guess that turned out wrong), and guessing again at
                -- another single mode risks the same problem in reverse: Balloon's own comment
                -- says misc_message (148) covers fishing messages too, so blindly routing that
                -- whole mode to SYS could divert real Craft fishing captures. Text matching
                -- sidesteps needing to know the mode at all.
                -- Confirmed via diagnostic print: AH messages arrive under mode 121 (Balloon's
                -- chat_modes.synth) -- the exact same mode as synthesis result messages, so a
                -- mode check can't distinguish the two. Text matching stays the correct approach
                -- here, not a workaround for an unknown mode.
                -- Labeled "Auction" rather than "System" so it's visually distinct from actual
                -- system broadcasts even though both share the SYS tab. Only a sale notification
                -- alerts like SYS normally does (see mark_alert_if_needed) -- confirmed via user
                -- feedback that a purchase (something *they* bought) shouldn't alert, only a sale
                -- (someone buying something they listed) is what they want flagged. Every other
                -- AH message (listing confirmation, fees, purchase confirmations) stays silent.
                local saleItem = line:match("^Your '(.-)' has sold to .- for %d+ gil!$")
                local buyItem = line:match("^You buy the (.-) for [%d,]+ gil%.$")
                append_message('sys', 'Auction', line, true, AH_TEXT_COLOR, nil, find_item_span(line, saleItem or buyItem), not saleItem)
            elseif try_delivery_message(line) then
                -- Already fully handled inside try_delivery_message.
            elseif try_checker_message(line) then
                -- Already fully handled inside try_checker_message.
            elseif try_conquest_addon_message(line) then
                -- Already fully handled inside try_conquest_addon_message.
            elseif is_conquest_update_line(line) then
                -- no_alert: the server's periodic conquest broadcast is routine background
                -- information (and arrives as a multi-line block), not something worth flashing
                -- the tab for, unlike a genuine system broadcast.
                append_message('sys', 'System', line, true, nil, nil, nil, true)
            elseif mode == NPC_DIALOGUE_MODE then
                local name, body = parse_npc_dialogue_line(line, npc_speaker)
                npc_speaker = name
                append_message('quest', name, body, true)
            elseif mode == SHOUT_MODE or mode == YELL_MODE then
                local kind = (mode == SHOUT_MODE) and 'shout' or 'yell'
                local name, body = parse_shout_yell_line(line, 'Unknown')
                local color = (kind == 'shout') and SHOUT_TEXT_COLOR or YELL_TEXT_COLOR
                append_message('shout', name, body, true, color, nil, nil, false, kind)
            elseif mode == SYSTEM_MODE then
                append_message('sys', 'System', line, true, SYSTEM_TEXT_COLOR)
            elseif mode == EMOTE_MODE then
                try_party_emote(line)
            elseif not (mode and ORDINARY_CHAT_MODES[mode]) then
                process_system_line(line)
            end
        end
    end
end)

-- Whether a stored row should currently be shown, given the live Settings filters. Checked at
-- display time (render + copy) rather than at capture time, so switching a filter retroactively
-- shows/hides history that's already been captured instead of only affecting new messages --
-- everything is captured unconditionally now (see append_message's `kind` param and the
-- Craft/Combat/Shout-Yell capture sites in process_system_line / the text_in handler).
local function channel_row_visible(channel, entry)
    if channel == 'craft' then return actor_matches_filter(entry.username, cfg.craft_filter)
    elseif channel == 'combat' then return actor_matches_filter(entry.username, cfg.combat_filter)
    elseif channel == 'shout' then return cfg.shoutyell_filter == 'both' or entry.kind == cfg.shoutyell_filter
    end
    return true
end

-- ===== Copy helpers =====
local function copy_all(channel)
    local out = {}
    local bucket = chat.messages[channel]
    if bucket then
        bucket:each(function (entry)
            if channel_row_visible(channel, entry) then
                table.insert(out, string.format("%s %s: %s", format_timestamp(entry.epoch), entry.username, entry.message))
            end
        end)
    end
    pcall(function() imgui.SetClipboardText(table.concat(out, '\n')) end)
end

-- ===== Brace-colored message renderer WITH STABLE WRAP =====
local braceL = {39/255, 107/255, 58/255, 1.0}   -- "{"
local braceR = {206/255, 45/255, 49/255, 1.0}   -- "}"

-- `spans`, if given, is a list of {s, e, color} char ranges within `text` -- each token that
-- falls in one is tagged `.span_color` so draw_wrapped_colored can render it in that color
-- instead of the row's default text color. Used both for single-span item-name highlighting
-- (see find_item_span) and Checker's multi-segment per-piece coloring (see try_checker_message).
-- Splits not just on spaces/braces but also at span-color boundaries, so two differently
-- colored pieces with no space between them (e.g. Checker's "24)") still end up as separate
-- tokens instead of being forced to share one color.
local function tokenize_for_wrap(text, spans)
    local tokens = {}
    local i, n = 1, #text
    local function color_at(pos)
        if not spans then return nil end
        for _, sp in ipairs(spans) do
            if pos >= sp.s and pos <= sp.e then return sp.color end
        end
        return nil
    end
    while i <= n do
        local ch = text:sub(i,i)
        if ch == '{' then
            table.insert(tokens, {type='braceL', str='{'})
            i = i + 1
        elseif ch == '}' then
            table.insert(tokens, {type='braceR', str='}'})
            i = i + 1
        elseif ch == ' ' then
            local j = i + 1
            while j <= n and text:sub(j,j) == ' ' do j = j + 1 end
            table.insert(tokens, {type='space', str=text:sub(i, j-1)})
            i = j
        else
            local startColor = color_at(i)
            local j = i + 1
            while j <= n do
                local c = text:sub(j,j)
                if c == '{' or c == '}' or c == ' ' then break end
                if color_at(j) ~= startColor then break end
                j = j + 1
            end
            table.insert(tokens, {type='text', str=text:sub(i, j-1), span_color=startColor})
            i = j
        end
    end
    return tokens
end

local function layout_tokens(tokens, maxw)
    local lines, line, curw = {}, {}, 0.0
    local function width(s) return text_width(s) end

    local i = 1
    while i <= #tokens do
        local t = tokens[i]
        local w = width(t.str)
        if (#line == 0 and t.type == 'space') then
            i = i + 1
        elseif curw + w <= maxw or #line == 0 then
            table.insert(line, t); curw = curw + w; i = i + 1
        else
            table.insert(lines, line); line = {}; curw = 0.0
        end
        if #line == 1 and curw > maxw then
            local s = line[1].str
            local was_span_color = line[1].span_color
            local k, acc = 1, 0.0
            while k <= #s do
                local ch = s:sub(k,k)
                local cw = width(ch)
                if acc + cw > maxw and acc > 0 then break end
                acc = acc + cw; k = k + 1
            end
            local head = s:sub(1, k-1)
            local tail = s:sub(k)
            line[1].str = head
            table.insert(lines, line)
            line, curw = {}, 0.0
            if #tail > 0 then
                table.insert(line, {type='text', str=tail, span_color=was_span_color})
                curw = width(tail)
            end
        end
    end
    if #line > 0 then table.insert(lines, line) end
    return lines
end

-- Resolve a configurable color (timestamp/username/text) for a channel, honoring the
-- per_channel toggle; falls back to `fallback` if the setting is missing entirely.
local function resolve_color(setting, channel, fallback)
    if not setting then return fallback end
    if setting.per_channel then
        return (setting.channels and setting.channels[channel]) or setting.all or fallback
    end
    return setting.all or fallback
end

-- `cache_entry`, if given, is the message's own stored row table -- tokenizing and word-
-- wrapping is real per-character work (CalcTextSize calls included), and redoing it for every
-- row on every single frame regardless of whether anything changed is what caused the severe
-- FPS drop after the message cap was raised to 5000 (confirmed via user report during a
-- leveling party: sustained high message throughput filled the buffer, and every frame was
-- re-tokenizing/re-measuring the entire thing). Cached lines are reused as long as both the
-- wrap width and the message text itself are unchanged since the last frame; text is part of
-- the cache key (not just width) since try_merge_angler_reveal mutates a row's message in place
-- after it's already been drawn once.
local function draw_wrapped_colored(text, text_color, spans, cache_entry)
    local ok, avail = pcall(imgui.GetContentRegionAvail)
    local availx = ok and get_x(avail) or 0
    if availx <= 20 then imgui.TextColored(text_color, text); return end

    local lines
    if cache_entry and cache_entry._wrap_w == availx and cache_entry._wrap_text == text then
        lines = cache_entry._wrap_lines
    else
        local tokens = tokenize_for_wrap(text, spans)
        lines = layout_tokens(tokens, availx)
        if cache_entry then
            cache_entry._wrap_w = availx
            cache_entry._wrap_text = text
            cache_entry._wrap_lines = lines
        end
    end

    for _, line in ipairs(lines) do
        local first = true
        for _,t in ipairs(line) do
            local function draw_token()
                if t.type == 'braceL' then      imgui.TextColored(braceL, '{')
                elseif t.type == 'braceR' then imgui.TextColored(braceR, '}')
                elseif t.span_color then       imgui.TextColored(t.span_color, t.str)
                else                            imgui.TextColored(text_color, t.str) end
            end
            if first then draw_token(); first = false else imgui.SameLine(0,0); draw_token() end
        end
    end
end

-- Splits Shout/Yell's native "Name[Zone]" username into colored parts: brackets match the
-- auto-translate brace colors (braceL/braceR), and the zone text is a dimmed version of the
-- row's own username color so it visually recedes without needing its own color setting.
-- Falls through to a single plain-colored draw for every other channel's plain "Name".
local function draw_colored_username(uname, ucolor)
    local name, zone = uname:match('^(.-)%[(.-)%]$')
    if not name or name == '' then
        imgui.TextColored(ucolor, uname .. ":")
        return
    end
    local zone_color = { ucolor[1] * 0.6, ucolor[2] * 0.6, ucolor[3] * 0.6, ucolor[4] }
    imgui.TextColored(ucolor, name)
    imgui.SameLine(0, 0); imgui.TextColored(braceL, '[')
    imgui.SameLine(0, 0); imgui.TextColored(zone_color, zone)
    imgui.SameLine(0, 0); imgui.TextColored(braceR, ']')
    imgui.SameLine(0, 0); imgui.TextColored(ucolor, ':')
end

-- Draw one row (copy on click + context)
local function draw_row(timestamp, uname, message, ucolor, ts_color, text_color, row_full, row_id, msg_col_x, spans, cache_entry)
    imgui.TextColored(ts_color, timestamp); imgui.SameLine()
    draw_colored_username(uname, ucolor); imgui.SameLine(msg_col_x)
    imgui.PushID(row_id)
    imgui.BeginGroup()
    draw_wrapped_colored(message, text_color, spans, cache_entry)
    imgui.EndGroup()
    local hovered = imgui.IsItemHovered()
    if hovered and imgui.IsMouseClicked(0) then pcall(function() imgui.SetClipboardText(row_full) end) end
    if imgui.BeginPopupContextItem('rowmenu') then
        if imgui.MenuItem('Copy line')    then pcall(function() imgui.SetClipboardText(row_full) end) end
        if imgui.MenuItem('Copy name')    then pcall(function() imgui.SetClipboardText(uname) end) end
        if imgui.MenuItem('Copy message') then pcall(function() imgui.SetClipboardText(message) end) end
        imgui.EndPopup()
    end
    imgui.PopID()
end

-- Craft/Combat don't use the user-configurable color settings -- their username/timestamp
-- always use the channel's tab color, and text color is per-message-type (see
-- SYSTEM_MESSAGE_PATTERNS' `color` field), falling back to the tab color when uncategorized.
local function is_system_channel(channel) return channel == 'craft' or channel == 'combat' or channel == 'quest' or channel == 'shout' or channel == 'sys' end

local function draw_channel_messages(channel)
    local bucket = chat.messages[channel]
    if not bucket then return end
    local system_channel = is_system_channel(channel)
    local uname_color, ts_color, text_color
    if system_channel then
        -- Overridden per-row below for Combat (enemy vs. player-ish name); Craft has no
        -- enemies, so this fallback (player white) is what actually gets used there.
        uname_color = PLAYER_NAME_COLOR
        ts_color    = {1,1,1,1}
        text_color  = channelColors[channel] or {1,1,1,1}
    else
        uname_color = resolve_color(cfg.colors.username, channel, channelColors[channel] or {1,1,1,1})
        ts_color     = resolve_color(cfg.colors.timestamp, channel, {1,1,1,1})
        text_color   = resolve_color(cfg.colors.text, channel, {1,1,1,1})
    end

    -- Only the last MAX_RENDERED_ROWS visible rows are drawn (see that constant). Count the
    -- visible rows first so we know how many older ones to skip -- a cheap O(n) pass of table
    -- lookups (no ImGui, no os.date), unlike the draw pass it's bounding.
    local visible_count = 0
    bucket:each(function (entry)
        if channel_row_visible(channel, entry) then visible_count = visible_count + 1 end
    end)
    local skip = visible_count - MAX_RENDERED_ROWS
    if skip < 0 then skip = 0 end

    -- Fixed column start for message text: measured from the current timestamp format's width
    -- plus the widest username among the rows actually being rendered (not a hypothetical
    -- worst-case, and not the whole stored history -- only what's drawn), so message text lines
    -- up across all visible rows without reserving space for names that aren't shown.
    local ts_w = text_width(get_timestamp())
    local max_name_w = 0
    -- Username width only needs recomputing when the font scale changes (CalcTextSize depends on
    -- it); a username never changes after a row is created. Cached on the entry.
    local seen_w = 0
    bucket:each(function (entry)
        if not channel_row_visible(channel, entry) then return end
        seen_w = seen_w + 1
        if seen_w <= skip then return end
        if entry._uname_w_scale ~= cfg.font_scale then
            entry._uname_w = text_width(entry.username .. ':')
            entry._uname_w_scale = cfg.font_scale
        end
        if entry._uname_w > max_name_w then max_name_w = entry._uname_w end
    end)
    local msg_col_x = ts_w + 8 + max_name_w + 8

    -- Timestamp-format signature: the formatted timestamp string and the full "ts name: msg"
    -- copy string are cached per entry and only rebuilt when this changes, rather than calling
    -- os.date + string.format for every drawn row every frame (a major allocation/GC cost at
    -- scale). Username and message never change after creation, so the timestamp format is the
    -- only thing that can invalidate them.
    local ts_sig = (cfg.timestamp_12h and '12' or '24') .. (cfg.timestamp_format or 'hms')

    local idx = 0
    local seen_d = 0
    local pushed_spacing = 0
    if pcall(function() imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {8, cfg.line_spacing or 4}) end) then pushed_spacing = 1 end
    bucket:each(function (entry)
        if not channel_row_visible(channel, entry) then return end
        seen_d = seen_d + 1
        if seen_d <= skip then return end
        idx = idx + 1
        if entry._ts_sig ~= ts_sig then
            entry._ts_str = format_timestamp(entry.epoch)
            entry._row_full = string.format("%s %s: %s", entry._ts_str, entry.username, entry.message)
            entry._ts_sig = ts_sig
        end
        -- entry.text_color is honored on every channel, not just Craft/Combat, so a broadcast
        -- message (currently just achievement unlocks) renders in the same color everywhere.
        local row_text_color = entry.text_color or text_color
        -- entry.uname_color is honored on every channel, not just Combat, so a broadcast message
        -- (achievement unlocks, hardcore milestones) keeps its own username color in whichever
        -- tab it lands in. Only rows that explicitly stored one are affected -- resolve_uname_color
        -- returns nil for every non-Combat channel, so everything else still falls back to the
        -- channel default. Combat's enemy/player color is resolved once at message-append time
        -- (see resolve_combat_uname_color) and stored on the entry, rather than re-scanning the
        -- entity table here every frame for every visible row.
        local row_uname_color = entry.uname_color or uname_color
        draw_row(entry._ts_str, entry.username, entry.message, row_uname_color, ts_color, row_text_color, entry._row_full, idx, msg_col_x, entry.spans, entry)
    end)
    if pushed_spacing > 0 then pcall(function() imgui.PopStyleVar(pushed_spacing) end) end
end

-- Button visuals
local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 else return x end end
local function shade(c, m) return { clamp01(c[1]*m), clamp01(c[2]*m), clamp01(c[3]*m), c[4] } end

-- Global accent color override for the whole addon's UI -- Ashita's default ImGui theme uses a
-- red/orange accent for the scrollbar, window resize grip, radio button/checkbox mark, and
-- slider handles; this re-themes those to match MultiChat's own blue title bar colors instead.
-- Also covers plain, unstyled imgui.Button calls (e.g. Settings' "Reset" buttons). Buttons that
-- already push their own explicit color (channel tabs, titlebar_color_button, borderless_button,
-- etc.) are unaffected -- ImGui's style stack is LIFO, so their own push simply takes priority
-- until it's popped, falling back to this one rather than being overridden by it.
local function push_accent_colors()
    local pushed = 0
    local function push(col, color)
        if pcall(function() imgui.PushStyleColor(col, color) end) then pushed = pushed + 1 end
    end
    push(ImGuiCol_CheckMark,            TITLEBAR_ACTIVE)
    push(ImGuiCol_SliderGrab,           TITLEBAR_INACTIVE)
    push(ImGuiCol_SliderGrabActive,     TITLEBAR_ACTIVE)
    push(ImGuiCol_ScrollbarGrab,        TITLEBAR_INACTIVE)
    push(ImGuiCol_ScrollbarGrabHovered, shade(TITLEBAR_INACTIVE, 1.3))
    push(ImGuiCol_ScrollbarGrabActive,  TITLEBAR_ACTIVE)
    push(ImGuiCol_ResizeGrip,           TITLEBAR_INACTIVE)
    push(ImGuiCol_ResizeGripHovered,    shade(TITLEBAR_INACTIVE, 1.3))
    push(ImGuiCol_ResizeGripActive,     TITLEBAR_ACTIVE)
    push(ImGuiCol_Button,               TITLEBAR_INACTIVE)
    push(ImGuiCol_ButtonHovered,        shade(TITLEBAR_INACTIVE, 1.3))
    push(ImGuiCol_ButtonActive,         shade(TITLEBAR_INACTIVE, 0.85))
    return pushed
end

-- Inverting flash: toggles every ~0.6s between (bg=color, text=black) and (bg=black, text=color)
local function colored_button(label, color, invert_flash)
    local phase = math.floor(os.clock() / 0.6) % 2
    local invert = invert_flash and (phase == 1)
    local bg = invert and {0,0,0,1} or color
    local text = invert and color or {0,0,0,1}
    local pushed = 0
    if pcall(function() imgui.PushStyleColor(ImGuiCol_Button,        bg) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_ButtonHovered, shade(bg, invert and 1.08 or 1.12)) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_ButtonActive,  shade(bg, 0.92)) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_Text, text) end) then pushed = pushed + 1 end
    local clicked = imgui.Button(label)
    if pushed > 0 then pcall(function() imgui.PopStyleColor(pushed) end) end
    return clicked
end

-- Colored to match the window's own (inactive) title bar
-- instead of gray -- used for the main window's Pop Out/Split/Copy row so they read as part of
-- the window chrome rather than secondary/neutral actions. Uses TITLEBAR_INACTIVE (darker)
-- rather than TITLEBAR_ACTIVE, since the brighter active shade was too close to the title bar
-- itself and didn't read as distinctly as buttons. Slightly tighter FramePadding than the
-- channel tab buttons use, so this row reads as visually smaller/secondary to them.
local function titlebar_color_button(label)
    local pushed = 0
    local pushed_vars = 0
    if pcall(function() imgui.PushStyleColor(ImGuiCol_Button,        TITLEBAR_INACTIVE) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_ButtonHovered, shade(TITLEBAR_INACTIVE, 1.3)) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_ButtonActive,  shade(TITLEBAR_INACTIVE, 0.85)) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {5, 3}) end) then pushed_vars = pushed_vars + 1 end
    local clicked = imgui.Button(label)
    if pushed > 0 then pcall(function() imgui.PopStyleColor(pushed) end) end
    if pushed_vars > 0 then pcall(function() imgui.PopStyleVar(pushed_vars) end) end
    return clicked
end

-- A real imgui.Button (same hit-testing/sizing as any other button, unlike the manual
-- draw-list icon rendering that was tried and reverted earlier for the gear icon -- that
-- approach made the icon invisible) but with its background made fully transparent, so it
-- reads as a plain icon rather than a boxed button. Still gets a faint hover/active highlight
-- so it doesn't look unresponsive when interacted with. Also zeroes out the border (both its
-- color and its size/thickness -- same style var this file already pushes elsewhere for the
-- active-channel-tab highlight, just in the opposite direction here) since a transparent fill
-- alone left a visible border outline.
local function borderless_button(label)
    local pushed = 0
    local pushed_vars = 0
    if pcall(function() imgui.PushStyleColor(ImGuiCol_Button,        {0, 0, 0, 0}) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_ButtonHovered, {1, 1, 1, 0.12}) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_ButtonActive,  {1, 1, 1, 0.20}) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleColor(ImGuiCol_Border,        {0, 0, 0, 0}) end) then pushed = pushed + 1 end
    if pcall(function() imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0) end) then pushed_vars = pushed_vars + 1 end
    local clicked = imgui.Button(label)
    if pushed > 0 then pcall(function() imgui.PopStyleColor(pushed) end) end
    if pushed_vars > 0 then pcall(function() imgui.PopStyleVar(pushed_vars) end) end
    return clicked
end

local function open_in_split_view(channel)
    split.enabled = true
    split.right_channel = channel
    pop[channel].alert = false
end

local function swap_views()
    local left = chat.active_channel
    local right = split.right_channel
    split.right_channel = left
    chat.active_channel = right
    pop[chat.active_channel].alert = false
    pop[split.right_channel].alert = false
end

local channel_order = {'linkshell','linkshell2','party','tell','say','shout','craft','combat','quest','sys'}
-- Subset of channel_order used by the Colors section -- Craft/Combat are excluded since their
-- colors are fixed/message-type-based rather than user-configurable (see is_system_channel).
local colorable_channel_order = {'linkshell','linkshell2','party','tell','say'}
local function pick_alternate_left(exclude)
    for _,c in ipairs(channel_order) do if c ~= exclude then return c end end
    return exclude
end

-- Split toggle button: click to enable/disable, right-click to choose orientation.
-- Border-highlighted (same treatment as the active channel tab) whenever split is on.
local function draw_split_toggle_button()
    local pushed_vars = 0
    local pushed_border_color = 0
    if split.enabled then
        if pcall(function() imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2) end) then pushed_vars = pushed_vars + 1 end
        if pcall(function() imgui.PushStyleColor(ImGuiCol_Border, {1,1,1,1}) end) then pushed_border_color = pushed_border_color + 1 end
    end

    if titlebar_color_button('Split') then
        if split.enabled then
            split.enabled = false
        else
            if split.right_channel == chat.active_channel then
                split.right_channel = pick_alternate_left(chat.active_channel)
            end
            split.enabled = true
        end
    end

    if pushed_border_color > 0 then pcall(function() imgui.PopStyleColor(pushed_border_color) end) end
    if pushed_vars > 0 then pcall(function() imgui.PopStyleVar(pushed_vars) end) end

    if imgui.BeginPopupContextItem('ctx_split') then
        if imgui.MenuItem('Side by Side') then split.orientation = 'horizontal' end
        if imgui.MenuItem('Stacked') then split.orientation = 'vertical' end
        imgui.EndPopup()
    end
end

local sectionHeaderColor = {1.0, 0.82, 0.35, 1.0}

-- One row (or one row per channel) of color pickers for a configurable color category.
-- `path_col_x` is the shared column position computed in draw_settings_window so every
-- section's channel rows line up with each other.
local function draw_color_setting(label, key, path_col_x)
    local setting = cfg.colors[key]
    imgui.PushID('color_' .. key)

    imgui.AlignTextToFramePadding(); imgui.Text(label)
    imgui.SameLine(path_col_x)
    local pref = { setting.per_channel or false }
    if imgui.Checkbox('Per-channel', pref) then setting.per_channel = pref[1] end
    imgui.SameLine()
    if imgui.Button('Reset') then
        local def = default_config.colors[key]
        setting.per_channel = def.per_channel
        setting.all = copy_color(def.all)
        setting.channels = setting.channels or {}
        for _, ch in ipairs(colorable_channel_order) do
            setting.channels[ch] = copy_color(def.channels[ch])
        end
    end

    if not setting.per_channel then
        imgui.SetNextItemWidth(200)
        imgui.ColorEdit4('##all', setting.all)
    else
        for _, ch in ipairs(colorable_channel_order) do
            imgui.TextColored(channelColors[ch] or {1,1,1,1}, channelLabels[ch] or ch)
            imgui.SameLine(path_col_x)
            setting.channels[ch] = setting.channels[ch] or {1,1,1,1}
            imgui.SetNextItemWidth(200)
            imgui.ColorEdit4('##' .. ch, setting.channels[ch])
        end
    end

    imgui.PopID()
end

-- Settings window: chat transparency + timestamp format + colors + craft/combat filters + split
-- view help + JP font note.
local function draw_settings_window()
    if not settings_ui.is_open[1] then return end
    imgui.SetNextWindowSize({480, 720}, ImGuiCond_FirstUseEver)
    local pushed_titlebar = push_titlebar_color()
    if imgui.Begin('MultiChat - Settings', settings_ui.is_open) then
        -- Shared column position (based on the longest channel label) so every
        -- section's per-channel rows line up with each other.
        local max_label_w = 0
        for _, ch in ipairs(colorable_channel_order) do
            local w = text_width(channelLabels[ch] or ch)
            if w > max_label_w then max_label_w = w end
        end
        local path_col_x = imgui.GetFrameHeight() + 8 + max_label_w + 12

        imgui.TextColored(sectionHeaderColor, 'Appearance')
        imgui.Separator()

        imgui.Text('Chat background transparency:')
        local aref = { math.floor(((cfg.chat_bg_alpha or 0.25) * 100) + 0.5) }
        if imgui.SliderInt('##transparency', aref, 0, 100, '%d%%') then
            cfg.chat_bg_alpha = aref[1] / 100.0
        end

        imgui.Text('Font size:')
        local fref = { math.floor(((cfg.font_scale or 1.0) * FONT_BASE_SIZE) + 0.5) }
        if imgui.SliderInt('##fontscale', fref, math.floor(FONT_BASE_SIZE * 0.5), math.floor(FONT_BASE_SIZE * 2.5), '%dpx') then
            cfg.font_scale = fref[1] / FONT_BASE_SIZE
        end

        imgui.Text('Line spacing:')
        local lref = { cfg.line_spacing or 0 }
        if imgui.SliderInt('##linespacing', lref, 0, 8, '%dpx') then
            cfg.line_spacing = lref[1]
        end

        imgui.Spacing(); imgui.Spacing()
        imgui.TextColored(sectionHeaderColor, 'Timestamps')
        imgui.Separator()

        if imgui.RadioButton('HH:MM:SS', cfg.timestamp_format == 'hms') then cfg.timestamp_format = 'hms' end
        imgui.SameLine()
        if imgui.RadioButton('HH:MM', cfg.timestamp_format == 'hm') then cfg.timestamp_format = 'hm' end

        if imgui.RadioButton('24-hour', not cfg.timestamp_12h) then cfg.timestamp_12h = false end
        imgui.SameLine()
        if imgui.RadioButton('12-hour (AM/PM)', cfg.timestamp_12h) then cfg.timestamp_12h = true end

        imgui.Spacing(); imgui.Spacing()
        imgui.TextColored(sectionHeaderColor, 'Colors')
        imgui.Separator()

        imgui.TextWrapped('Craft and Combat use fixed colors by message type (abilities, damage, healing) instead of these settings.')

        draw_color_setting('Timestamp', 'timestamp', path_col_x)
        imgui.Spacing()
        draw_color_setting('Username', 'username', path_col_x)
        imgui.Spacing()
        draw_color_setting('Chat Text', 'text', path_col_x)

        imgui.Spacing(); imgui.Spacing()
        imgui.TextColored(sectionHeaderColor, 'Craft / Combat Filters')
        imgui.Separator()

        imgui.TextWrapped('Choose who shows up in the Craft and Combat tabs. "Myself" includes your own pets/summons.')

        imgui.Text('Craft:')
        if imgui.RadioButton('Everyone##craft', cfg.craft_filter == 'all') then cfg.craft_filter = 'all' end
        if imgui.RadioButton('Myself##craft', cfg.craft_filter == 'mine') then cfg.craft_filter = 'mine' end

        imgui.Spacing()
        imgui.Text('Combat:')
        if imgui.RadioButton('Everyone##combat', cfg.combat_filter == 'all') then cfg.combat_filter = 'all' end
        if imgui.RadioButton('Myself##combat', cfg.combat_filter == 'mine') then cfg.combat_filter = 'mine' end

        imgui.Spacing(); imgui.Spacing()
        imgui.TextColored(sectionHeaderColor, 'Shout and Yell tab')
        imgui.Separator()

        imgui.TextWrapped('Choose what shows up in the Shout/Yell tab. Shout and Yell are always shown in different colors so they stay easy to tell apart.')

        if imgui.RadioButton('Both##shoutyell', cfg.shoutyell_filter == 'both') then cfg.shoutyell_filter = 'both' end
        if imgui.RadioButton('Shout##shoutyell', cfg.shoutyell_filter == 'shout') then cfg.shoutyell_filter = 'shout' end
        if imgui.RadioButton('Yell##shoutyell', cfg.shoutyell_filter == 'yell') then cfg.shoutyell_filter = 'yell' end

        imgui.Spacing(); imgui.Spacing()
        imgui.TextColored(sectionHeaderColor, 'Split View')
        imgui.Separator()

        imgui.TextWrapped('Right-click any channel tab (LS1, LS2, Party, Tell, Say, Shout/Yell, Craft, Combat, NPC, SYS) and choose "Open in Split View" to show two channels at once.')
        imgui.TextWrapped('Or click the Split button next to Pop Out in the main window to toggle it on/off. Right-click the Split button to choose Side by Side or Stacked layout.')
        imgui.TextWrapped('Drag the divider between the two panes to resize them.')

        imgui.Spacing(); imgui.Spacing()
        imgui.TextColored(sectionHeaderColor, 'Japanese / CJK Text')
        imgui.Separator()

        imgui.TextWrapped('If Japanese characters show as "?" here, that is an Ashita-wide font setting, not something this addon controls. See the "How to Add Support for Japanese Language Fonts" section of the README for setup steps.')
    end
    imgui.End()
    if pushed_titlebar > 0 then pcall(function() imgui.PopStyleColor(pushed_titlebar) end) end
end

-- Persist on unload
ashita.events.register('unload', 'unload_cb', function ()
    if have_settings and type(settings.save) == 'function' then
        pcall(settings.save)
    end
end)

-- ========= Draw =========
ashita.events.register('d3d_present', 'present_cb', function ()
    -- Don't draw anything until a character is actually logged in and loaded into the world.
    -- GetPlayerEntity() alone isn't enough -- it goes non-nil as soon as the character-select
    -- screen sets up its preview model, before you've actually logged in. Ashita's own settings
    -- library (addons/libs/settings.lua) hits this same problem and solves it by also checking
    -- GetLoginStatus() == 2, so we use the same combined check here.
    local okStatus, loginStatus = pcall(function() return AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus() end)
    if (not okStatus) or loginStatus ~= 2 or GetPlayerEntity() == nil then return end

    -- One-time auto-check, the first frame this handler runs past the login gate above (i.e.
    -- once, right after the character is confirmed loaded into the world -- same trigger this
    -- gate already exists for). https.request is a blocking call, so this causes one brief
    -- frame hitch -- same accepted tradeoff the approved anglin addon's own update checker
    -- makes, at the same point in the login sequence.
    if not update_check_done then
        update_check_done = true
        pcall(check_for_update)
    end

    if force_center_frames > 0 then force_center_frames = force_center_frames - 1 end

    -- Mirror the live popped-out state into the config so it's what gets saved. Done here, in
    -- one place, rather than at each of the several spots that toggle it (the Pop Out/Pop In
    -- buttons, the tab right-click menu, closing a popped window, /multichat show, /multichat
    -- reset) -- that way none can be missed. Ten boolean assignments a frame, no allocation.
    if type(cfg.popped) == 'table' then
        for ch, state in pairs(pop) do cfg.popped[ch] = state.popped end
    end

    local pushed_accent = push_accent_colors()

    draw_settings_window()

    -- Popped-out windows
    for channel, state in pairs(pop) do
        if state.popped and state.is_open[1] then
            local title = 'MultiChat - ' .. (channelLabels[channel] or channel)
            apply_window_bounds(channel)
            local pushed_titlebar = push_titlebar_color()
            imgui.PushStyleColor(ImGuiCol_WindowBg, {0.10, 0.10, 0.10, cfg.chat_bg_alpha or 0.25})
            if imgui.Begin(title, state.is_open) then
                apply_font_scale()
                save_window_geom(channel)
                -- ImGuiFocusedFlags_ChildWindows is required here -- the message area below is
                -- a separate BeginChild (a child window with its own focus state), and without
                -- this flag, clicking inside it doesn't count as this outer window being
                -- focused, so the alert would only clear when clicking the title bar/button row
                -- specifically. Confirmed via user report: clicking the message area didn't
                -- clear the alert, only clicking near the buttons did.
                local focused = false; pcall(function() focused = imgui.IsWindowFocused(ImGuiFocusedFlags_ChildWindows) end)
                if focused then pop[channel].alert = false end
                if titlebar_color_button('Pop In') then state.popped=false; state.is_open[1]=true; pop[channel].alert=false end
                -- Plain ASCII, not the "proper" bullet character -- same font-glyph-coverage
                -- issue as the special chat characters (see fix_special_chars): "•" renders as
                -- "?" since it's outside the loaded JP font's glyph range. Confirmed via
                -- in-game screenshot.
                imgui.SameLine(); if is_alerting(channel) then imgui.TextColored({1,0.4,0.4,1}, '!') end
                imgui.SameLine(); if titlebar_color_button('Copy') then copy_all(channel) end
                if channel == 'combat' then
                    imgui.SameLine(); imgui.TextColored(EXP_COLOR, 'Last EXP: ' .. (last_exp_gained and tostring(last_exp_gained) or '-'))
                end
                imgui.Separator()
                -- Window background already carries the tint; keep the child transparent so it
                -- doesn't double up (two stacked semi-transparent layers would look more opaque
                -- than the rest of the window).
                imgui.PushStyleColor(ImGuiCol_ChildBg, {0,0,0,0})
                if imgui.BeginChild(title .. 'Messages', {0, -imgui.GetFrameHeightWithSpacing() + 20}) then
                    apply_font_scale()
                    local atBottom=false; local okY,y = pcall(imgui.GetScrollY); local okM,my=pcall(imgui.GetScrollMaxY)
                    if okY and okM then atBottom = (y >= my - 1.0) end
                    draw_channel_messages(channel)
                    -- A few pixels of trailing space so descenders (y, g, p, q) on the last line
                    -- aren't clipped by the child's bottom edge when scrolled all the way down.
                    pcall(function() imgui.Dummy({0, 4}) end)
                    if atBottom then pcall(function() imgui.SetScrollHereY(1.0) end) end
                end
                imgui.EndChild(); imgui.PopStyleColor(1)
            end
            imgui.End(); imgui.PopStyleColor(1)
            if pushed_titlebar > 0 then pcall(function() imgui.PopStyleColor(pushed_titlebar) end) end
            if not state.is_open[1] then state.popped=false; state.is_open[1]=true end
        end
    end

    -- Main window
    if (chat.is_open[1]) then
        apply_window_bounds('main')
        local pushed_titlebar_main = push_titlebar_color()
        imgui.PushStyleColor(ImGuiCol_WindowBg, {0.10, 0.10, 0.10, cfg.chat_bg_alpha or 0.25})
        -- "###MultiChatMain" keeps the window's actual ImGui ID stable while the visible title
        -- text changes with the active channel -- without it, changing the title string would
        -- make ImGui treat this as a brand-new window each time (losing position/size/focus).
        local main_title = 'MultiChat - ' .. (channelLabels[chat.active_channel] or chat.active_channel) .. '###MultiChatMain'
        if (imgui.Begin(main_title, chat.is_open)) then
            apply_font_scale()
            save_window_geom('main')

            -- Measured before anything else is drawn, so this is the window's true full content
            -- width — not "whatever's left after the channel buttons," which is what
            -- GetContentRegionAvail() would report if called later in the row.
            local okTotalW, totalAvail = pcall(imgui.GetContentRegionAvail)
            local total_w = okTotalW and get_x(totalAvail) or 0

            -- Channel button with context menu
            local function channel_button_with_menu(chan)
                local label = channelLabels[chan]
                local is_active = (chan == chat.active_channel)

                local pushed_vars = 0
                local pushed_border_color = 0
                if is_active then
                    if pcall(function() imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2) end) then pushed_vars = pushed_vars + 1 end
                    if pcall(function() imgui.PushStyleColor(ImGuiCol_Border, {1,1,1,1}) end) then pushed_border_color = pushed_border_color + 1 end
                end

                if colored_button(label, channelColors[chan], is_alerting(chan)) then
                    chat.active_channel = chan
                    pop[chan].alert = false
                end

                if pushed_border_color > 0 then pcall(function() imgui.PopStyleColor(pushed_border_color) end) end
                if pushed_vars > 0 then pcall(function() imgui.PopStyleVar(pushed_vars) end) end
                -- Right-click context menu on the button
                if imgui.BeginPopupContextItem('ctx_' .. chan) then
                    -- Pops this specific channel out directly, without needing to first make it
                    -- the main window's active tab (which is the only way the main "Pop Out"
                    -- button can target a channel) -- this is what actually lets you pop out
                    -- more than one channel at once: pop[] already tracks state per channel and
                    -- the render loop already draws one window per popped channel, so the only
                    -- real gap was a way to pop out a channel you weren't currently viewing.
                    if imgui.MenuItem(pop[chan].popped and 'Pop In' or 'Pop Out') then
                        pop[chan].popped = not pop[chan].popped
                        pop[chan].is_open[1] = true
                        if not pop[chan].popped then pop[chan].alert = false end
                    end
                    if imgui.MenuItem('Open in Split View') then
                        if not split.enabled then
                            -- create split and show this channel in the second pane; pick another for the first
                            open_in_split_view(chan)
                            if chat.active_channel == chan then
                                chat.active_channel = pick_alternate_left(chan)
                            end
                        else
                            -- if it's already one of the panes, swap; otherwise move it into the second pane
                            if chan == chat.active_channel or chan == split.right_channel then
                                swap_views()
                            else
                                split.right_channel = chan
                                pop[chan].alert = false
                            end
                        end
                    end
                    if split.enabled then
                        if imgui.MenuItem('Swap Views') then swap_views() end
                        if imgui.MenuItem('Close Split View') then split.enabled = false end
                    end
                    imgui.EndPopup()
                end
                imgui.SameLine()
            end

            -- LEFT: channel buttons row
            channel_button_with_menu('linkshell')
            channel_button_with_menu('linkshell2')
            channel_button_with_menu('party')
            channel_button_with_menu('tell')
            channel_button_with_menu('say')
            channel_button_with_menu('shout')
            channel_button_with_menu('craft')
            channel_button_with_menu('combat')
            channel_button_with_menu('quest')
            channel_button_with_menu('sys')

            -- RIGHT (right-aligned): Pop toggle + Split toggle + Copy + Settings. The active
            -- channel is now shown in the window title bar instead of a "Viewing:" label here.
            local active = chat.active_channel
            local isPopped = pop[active].popped
            local btnLabel = isPopped and 'Pop In' or 'Pop Out'

            local cur_x = 0
            pcall(function() cur_x = get_x(imgui.GetCursorPos()) end)
            -- Hug the true right edge when there's room, but never sit further left than
            -- right after the channel tabs, so this cluster never overlaps them even in a
            -- narrow window. action_cluster_w is this frame's best estimate (last frame's
            -- actual measurement, see below), not a formula, so this ends up pixel-accurate.
            local right_x = math.max(cur_x, total_w - action_cluster_w)

            -- GetItemRectMax (used below to measure the cluster) returns absolute screen-space
            -- coordinates, while right_x/SameLine work in window-local coordinates -- mixing
            -- the two directly produced a nonsense width that collapsed the whole layout to the
            -- left edge. Converting right_x to its screen-space equivalent here (window position
            -- + local offset) keeps both measurements in the same space.
            local okWinPos, winPos = pcall(imgui.GetWindowPos)
            local right_x_screen = (okWinPos and winPos) and (get_x(winPos) + right_x) or nil

            imgui.SameLine(right_x)
            if titlebar_color_button(btnLabel) then
                pop[active].popped = not isPopped
                pop[active].is_open[1] = true
                if not pop[active].popped then pop[active].alert = false end
            end
            imgui.SameLine()
            draw_split_toggle_button()
            imgui.SameLine()
            if titlebar_color_button('Copy') then copy_all(active) end
            imgui.SameLine()
            if borderless_button(ICON_GEAR) then settings_ui.is_open[1] = true end

            -- Measure the cluster's actual rendered width (right_x_screen to the right edge of
            -- the last button just drawn, both in screen space) and feed it back in for next
            -- frame's positioning, instead of estimating button widths up front -- keeps this
            -- pixel-accurate regardless of font/DPI/padding quirks an estimate could get wrong.
            if right_x_screen then
                local okRect, rectMax = pcall(imgui.GetItemRectMax)
                if okRect and rectMax then
                    local measured = get_x(rectMax) - right_x_screen
                    if measured > 0 then action_cluster_w = measured end
                end
            end

            imgui.Separator()

            -- If viewing in main (not popped), clear any lingering alert for the left channel.
            if not pop[active].popped then pop[active].alert = false end

            -- Draw messages area(s). Window background already carries the tint; keep the
            -- children transparent so they don't double up (two stacked semi-transparent
            -- layers would look more opaque than the rest of the window).
            imgui.PushStyleColor(ImGuiCol_ChildBg, {0,0,0,0})

            if not pop[active].popped then
                if split.enabled and split.orientation == 'vertical' then
                    -- Stacked layout (top/bottom) with draggable splitter
                    local okA, avail = pcall(imgui.GetContentRegionAvail)
                    local availx = okA and get_x(avail) or 0
                    local availy = okA and get_y(avail) or 0
                    local grip  = split.grip_px or 6
                    local minh  = split.min_px or 160
                    local toph = math.max(minh, math.min(availy - minh - grip, math.floor((availy - grip) * split.ratio)))
                    local bottomh = math.max(minh, availy - toph - grip)

                    -- TOP PANE (active)
                    imgui.BeginChild('MessagesTop', {availx, toph})
                    do
                        apply_font_scale()
                        local atBottom=false; local okY,y=pcall(imgui.GetScrollY); local okM,my=pcall(imgui.GetScrollMaxY)
                        if okY and okM then atBottom = (y >= my - 1.0) end
                        draw_channel_messages(active)
                        pcall(function() imgui.Dummy({0, 4}) end)
                        if atBottom then pcall(function() imgui.SetScrollHereY(1.0) end) end
                    end
                    imgui.EndChild()

                    -- SPLITTER
                    imgui.InvisibleButton('VSplitter', {availx, grip})
                    if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
                        local delta = imgui.GetIO().MouseDelta
                        local dy = get_y(delta)
                        local new_top = toph + dy
                        new_top = math.max(minh, math.min(availy - minh - grip, new_top))
                        split.ratio = (new_top) / (availy - grip)
                    end
                    -- draw a thin visual line
                    local dl = imgui.GetWindowDrawList()
                    local pos = imgui.GetItemRectMin()
                    local pos2 = imgui.GetItemRectMax()
                    dl:AddRectFilled({get_x(pos), get_y(pos)+grip*0.5-1}, {get_x(pos2), get_y(pos2)-grip*0.5+1}, imgui.GetColorU32({1,1,1,0.12}))

                    -- BOTTOM PANE (split.right_channel)
                    local rch = split.right_channel
                    imgui.BeginChild('MessagesBottom', {availx, bottomh})
                    do
						apply_font_scale()
						-- mini header (title + copy + close view)
						imgui.TextColored(channelColors[rch] or {1,1,1,1}, channelLabels[rch] or rch)
						imgui.SameLine()
						if titlebar_color_button('Copy##right') then
							copy_all(rch)
						end
						imgui.SameLine()
						if titlebar_color_button('Close View##right') then
							split.enabled = false
						end
						imgui.Separator()

                        -- messages
                        local atBottom=false; local okY,y=pcall(imgui.GetScrollY); local okM,my=pcall(imgui.GetScrollMaxY)
                        if okY and okM then atBottom = (y >= my - 1.0) end
                        draw_channel_messages(rch)
                        pcall(function() imgui.Dummy({0, 4}) end)
                        if atBottom then pcall(function() imgui.SetScrollHereY(1.0) end) end
                    end
                    imgui.EndChild()

                    -- Since bottom pane is visible in main, clear its alert
                    pop[rch].alert = false
                elseif split.enabled then
                    -- Side-by-side layout with draggable splitter
                    local okA, avail = pcall(imgui.GetContentRegionAvail)
                    local availx = okA and get_x(avail) or 0
                    local availy = okA and get_y(avail) or 0
                    local grip  = split.grip_px or 6
                    local minw  = split.min_px or 160
                    local leftw = math.max(minw, math.min(availx - minw - grip, math.floor((availx - grip) * split.ratio)))
                    local rightw = math.max(minw, availx - leftw - grip)

                    -- LEFT PANE (active)
                    imgui.BeginChild('MessagesLeft', {leftw, availy})
                    do
                        apply_font_scale()
                        local atBottom=false; local okY,y=pcall(imgui.GetScrollY); local okM,my=pcall(imgui.GetScrollMaxY)
                        if okY and okM then atBottom = (y >= my - 1.0) end
                        draw_channel_messages(active)
                        pcall(function() imgui.Dummy({0, 4}) end)
                        if atBottom then pcall(function() imgui.SetScrollHereY(1.0) end) end
                    end
                    imgui.EndChild()

                    -- SPLITTER
                    imgui.SameLine(0,0)
                    imgui.InvisibleButton('HSplitter', {grip, availy})
                    if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
                        local delta = imgui.GetIO().MouseDelta
                        local dx = get_x(delta)
                        local new_left = leftw + dx
                        new_left = math.max(minw, math.min(availx - minw - grip, new_left))
                        split.ratio = (new_left) / (availx - grip)
                    end
                    -- draw a thin visual line
                    local dl = imgui.GetWindowDrawList()
                    local pos = imgui.GetItemRectMin()
                    local pos2 = imgui.GetItemRectMax()
                    dl:AddRectFilled({get_x(pos)+grip*0.5-1, get_y(pos)}, {get_x(pos2)-grip*0.5+1, get_y(pos2)}, imgui.GetColorU32({1,1,1,0.12}))

                    imgui.SameLine(0,0)

                    -- RIGHT PANE (split.right_channel)
                    local rch = split.right_channel
                    imgui.BeginChild('MessagesRight', {rightw, availy})
                    do
						apply_font_scale()
						-- mini header (title + copy + close view)
						imgui.TextColored(channelColors[rch] or {1,1,1,1}, channelLabels[rch] or rch)
						imgui.SameLine()
						if titlebar_color_button('Copy##right') then
							copy_all(rch)
						end
						imgui.SameLine()
						if titlebar_color_button('Close View##right') then
							split.enabled = false
						end
						imgui.Separator()

                        -- messages
                        local atBottom=false; local okY,y=pcall(imgui.GetScrollY); local okM,my=pcall(imgui.GetScrollMaxY)
                        if okY and okM then atBottom = (y >= my - 1.0) end
                        draw_channel_messages(rch)
                        pcall(function() imgui.Dummy({0, 4}) end)
                        if atBottom then pcall(function() imgui.SetScrollHereY(1.0) end) end
                    end
                    imgui.EndChild()

                    -- Since right pane is visible in main, clear its alert
                    pop[rch].alert = false
                else
                    -- Single-pane layout
                    if (imgui.BeginChild('MessagesWindow', {0, -imgui.GetFrameHeightWithSpacing() + 20})) then
                        apply_font_scale()
                        local atBottom=false; local okY,y=pcall(imgui.GetScrollY); local okM,my=pcall(imgui.GetScrollMaxY)
                        if okY and okM then atBottom = (y >= my - 1.0) end
                        draw_channel_messages(active)
                        pcall(function() imgui.Dummy({0, 4}) end)
                        if atBottom then pcall(function() imgui.SetScrollHereY(1.0) end) end
                    end
                    imgui.EndChild()
                end
              else
                imgui.TextDisabled('(This channel is popped out into its own window.)')
            end

            imgui.PopStyleColor(1)
        end
        imgui.End()
        imgui.PopStyleColor(1)
        if pushed_titlebar_main > 0 then pcall(function() imgui.PopStyleColor(pushed_titlebar_main) end) end
    end

    if pushed_accent > 0 then pcall(function() imgui.PopStyleColor(pushed_accent) end) end
end)
