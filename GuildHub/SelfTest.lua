-- Guild Hub: /ghub selftest [full]. From the wowforever-kit starter (.claude\tools\selftest\GUIDE.md).
-- The addon checks itself in the running game: every listed button and panel is shown, has a position
-- and a size, is on screen, is drawn above the window's border art and isn't covered; its art loads;
-- the saved data survives the addon's own repair (on a copy only); recipe lists decode and match their hash.
-- Safety: reads only. It shows and hides only Guild Hub's own frames and puts them back; no Blizzard
-- function is replaced or hooked; nothing protected. Every value read from a frame is checked with
-- issecretvalue before it is compared ("skipped (secret)"). In combat it waits; if combat starts
-- mid-run it stops and puts everything back. Never writes the saved data. The report has no player
-- names, realms, guilds or item links.
local ADDON_NAME, ns = ...

local ST = {}
ns.SelfTest = ST

local MAX_LIST = 8          -- skipped names listed in the report
local COVER_SHARE = 0.3     -- a part counts as covered when this much of it is under another frame
local SCREEN_SLACK = 2      -- px
local COPY_MAX = 4000       -- report length

local run                   -- the run in progress (nil when idle)

-- ---------------------------------------------------------------------------
-- Safe reads

local function IsSecret(v)
    local f = issecretvalue
    if type(f) ~= "function" then return false end
    local ok, s = pcall(f, v)
    return ok and s and true or false
end

local function Pack(...) return { n = select("#", ...), ... } end

-- obj:method(...) -> "ok", results... | "noapi" | "err" | "secret" (any result secret).
local function Read(obj, method, ...)
    if type(obj) ~= "table" then return "noapi" end
    local f = obj[method]
    if type(f) ~= "function" then return "noapi" end
    local r = Pack(pcall(f, obj, ...))
    if not r[1] then return "err" end
    for i = 2, r.n do
        if IsSecret(r[i]) then return "secret" end
    end
    return "ok", unpack(r, 2, r.n)
end

local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end
local function Short(err) return "error: " .. tostring(err):gsub("^.-:%d+: ", ""):sub(1, 80) end

-- ---------------------------------------------------------------------------
-- Results

local function Count(n) run.checks = run.checks + (n or 1) end
local function Problem(code, name, text) run.problems[#run.problems + 1] = code .. " " .. name .. ": " .. text end
local function Skip(name, why) run.skips[#run.skips + 1] = name .. " " .. why end
local function Info(text) run.info[#run.info + 1] = text end

-- Runs fn in pcall; a throw becomes one "ERR" line.
local function Guard(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Problem("ERR", label, Short(err)) end
    return ok
end

-- ---------------------------------------------------------------------------
-- Frame geometry (screen pixels, so frames with other scales compare)

local function ScreenRect(o)
    local st, l, b, w, h = Read(o, "GetRect")
    if st == "secret" then return "secret" end
    if st ~= "ok" or l == nil or b == nil or w == nil or h == nil then return nil end
    local s2, es = Read(o, "GetEffectiveScale")
    if s2 == "secret" then return "secret" end
    if s2 ~= "ok" or type(es) ~= "number" then es = 1 end
    return { l = l * es, b = b * es, r = (l + w) * es, t = (b + h) * es, w = w, h = h }
end

local function Overlap(a, b)
    local w = math.min(a.r, b.r) - math.max(a.l, b.l)
    local h = math.min(a.t, b.t) - math.max(a.b, b.b)
    if w <= 0 or h <= 0 then return 0 end
    return w * h
end

-- Frame level of a frame, or of a texture's / font string's frame. nil = can't tell, "secret".
local function Level(o)
    local st, lv = Read(o, "GetFrameLevel")
    if st == "secret" then return "secret" end
    if st == "ok" and type(lv) == "number" then return lv end
    local s2, p = Read(o, "GetParent")
    if s2 == "secret" then return "secret" end
    st, lv = Read(p, "GetFrameLevel")
    if st == "secret" then return "secret" end
    return st == "ok" and type(lv) == "number" and lv or nil
end

local STRATA = { WORLD = 0, BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
    FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local function Strata(o)
    local st, s = Read(o, "GetFrameStrata")
    if st == "noapi" then st, s = Read(select(2, Read(o, "GetParent")), "GetFrameStrata") end
    if st == "secret" then return "secret" end
    return st == "ok" and STRATA[s] or nil
end

-- true when a is b or one is inside the other (parent chain); nil = can't tell.
local function Related(a, b)
    for _, pair in ipairs({ { a, b }, { b, a } }) do
        local p, n = pair[1], 0
        while p and n < 25 do
            if p == pair[2] then return true end
            local st, q = Read(p, "GetParent")
            if st ~= "ok" then return nil end
            p, n = q, n + 1
        end
    end
    return false
end

-- nil = the texture's art loads; else a short reason.
local function ArtMissing(tex)
    if type(tex) ~= "table" then return "missing" end
    local st, atlas = Read(tex, "GetAtlas")
    if st == "secret" then return "secret" end
    if st == "ok" and type(atlas) == "string" and atlas ~= "" then
        local get = C_Texture and C_Texture.GetAtlasInfo
        if type(get) ~= "function" then return nil end
        local ok, info = pcall(get, atlas)
        if not ok or type(info) ~= "table" then return "atlas " .. atlas .. " gone" end
        return nil
    end
    local id
    st, id = Read(tex, "GetTextureFileID")
    if st == "secret" then return "secret" end
    if st ~= "ok" or id == nil then
        st, id = Read(tex, "GetTexture")
        if st == "secret" then return "secret" end
    end
    if id == nil or id == 0 or id == "" then return "no file" end
    return nil
end

-- ---------------------------------------------------------------------------
-- UI parts

-- The window template's parts that hold its border/title/portrait art (ButtonFrameTemplate,
-- PortraitFrameTemplate ...). Missing ones are ignored.
local TEMPLATE_PARTS = { "NineSlice", "PortraitContainer", "TitleContainer", "CloseButton" }

local function ArtTop(win)
    local top, name
    for _, key in ipairs(TEMPLATE_PARTS) do
        local lv = Level(win[key])
        if lv == "secret" then return "secret" end
        if type(lv) == "number" and (top == nil or lv > top) then top, name = lv, key end
    end
    return top, name
end

-- Frames that may draw over a part: the template's portrait/title/X plus the group's other parts.
local function Coverers(win, parts)
    local list = {}
    for _, key in ipairs({ "PortraitContainer", "TitleContainer", "CloseButton" }) do
        if win and win[key] then list[#list + 1] = { name = key, obj = win[key] } end
    end
    for _, p in ipairs(parts) do if p.obj then list[#list + 1] = p end end
    return list
end

-- One part = { name = "settings", obj = <frame>, top = true (must be above the border art),
--   opt = true (may be missing), shownOnly = true (only checked while shown), thin = true (a line),
--   art = { "Icon" } (texture keys whose art must load), artSelf = true (obj is a texture) }.
-- At most one problem line per part: the first check that fails.
local function CheckPart(p, win, coverers)
    local o = p.obj
    Count()
    if o == nil then
        if p.opt then return end
        return Problem("UI", p.name, "missing")
    end
    local st, shown = Read(o, "IsShown")
    if st == "secret" then return Skip(p.name, "(secret)") end
    if st ~= "ok" then return Problem("UI", p.name, "can't read (" .. st .. ")") end
    if not shown then
        if p.shownOnly then return end
        return Problem("UI", p.name, "hidden")
    end
    local vis
    st, vis = Read(o, "IsVisible")
    if st == "secret" then return Skip(p.name, "(secret)") end
    if st == "ok" and not vis then return Problem("UI", p.name, "shown but its parent is hidden") end

    Count()
    local valid
    st, valid = Read(o, "IsRectValid")
    if st == "secret" then return Skip(p.name, "(secret)") end
    if st == "ok" and valid == false then return Problem("UI", p.name, "no position") end
    local rect = ScreenRect(o)
    if rect == "secret" then return Skip(p.name, "(secret)") end
    if rect == nil then return Problem("UI", p.name, "no position") end

    Count()
    if not (rect.w > 1 and rect.h > 1) and not p.thin then
        return Problem("UI", p.name, ("size %dx%d"):format(math.floor(rect.w), math.floor(rect.h)))
    end

    Count()
    local screen = ScreenRect(UIParent)
    if type(screen) == "table" and (rect.l < screen.l - SCREEN_SLACK or rect.b < screen.b - SCREEN_SLACK
        or rect.r > screen.r + SCREEN_SLACK or rect.t > screen.t + SCREEN_SLACK) then
        return Problem("UI", p.name, "off screen")
    end

    Count()
    local alpha
    st, alpha = Read(o, "GetEffectiveAlpha")
    if st == "secret" then return Skip(p.name, "(secret)") end
    if st == "ok" and type(alpha) == "number" and alpha < 0.05 then
        return Problem("UI", p.name, ("invisible (alpha %.2f)"):format(alpha))
    end

    local lv, ss = Level(o), Strata(o)
    if lv == "secret" or ss == "secret" then return Skip(p.name, "(secret)") end

    -- Above the window's border/title/portrait art.
    if p.top and win then
        Count()
        local top, topName = ArtTop(win)
        local ws = Strata(win)
        if top == "secret" or ws == "secret" then return Skip(p.name, "(secret)") end
        local higherStrata = ss and ws and ss > ws
        -- titleBar parts sit on the same level as Blizzard's own close button (= TitleContainer): equal is fine
        local under = type(lv) == "number" and type(top) == "number" and (lv < top or (lv == top and not p.titleBar))
        if under and not higherStrata then
            return Problem("UI", p.name, ("under art %d<=%d (%s)"):format(lv, top, topName))
        end
    end

    -- Not under another frame that covers a good part of it.
    if type(lv) == "number" then
        Count()
        for _, c in ipairs(coverers or {}) do
            if c.obj ~= o and Related(o, c.obj) == false and select(2, Read(c.obj, "IsVisible")) == true then
                local clv, cs = Level(c.obj), Strata(c.obj)
                if clv == "secret" or cs == "secret" then
                    Skip(p.name, "cover (secret)")
                elseif type(clv) == "number" and clv > lv and (cs == nil or ss == nil or cs == ss) then
                    local cr = ScreenRect(c.obj)
                    local area = (rect.r - rect.l) * (rect.t - rect.b)
                    if type(cr) == "table" and area > 0 and Overlap(rect, cr) / area >= COVER_SHARE then
                        return Problem("UI", p.name, ("covered by %s (%d>%d)"):format(c.name, clv, lv))
                    end
                end
            end
        end
    end

    -- Its art really loads.
    for _, key in ipairs(p.art or {}) do
        Count()
        local miss = ArtMissing(o[key])
        if miss == "secret" then Skip(p.name .. "." .. key, "(secret)")
        elseif miss then return Problem("TEX", p.name .. "." .. key, miss) end
    end
    if p.artSelf then
        Count()
        local miss = ArtMissing(o)
        if miss == "secret" then Skip(p.name, "art (secret)")
        elseif miss then return Problem("TEX", p.name, miss) end
    end

    -- Button label cut off.
    local fs = select(2, Read(o, "GetFontString"))
    if fs then
        Count()
        local s2, cut = Read(fs, "IsTruncated")
        if s2 == "ok" and cut then return Problem("UI", p.name, "text cut") end
    end
end

local function CheckGroup(parts, win)
    local cov = Coverers(win, parts)
    for _, p in ipairs(parts) do Guard("UI " .. p.name, CheckPart, p, win, cov) end
end

-- ---------------------------------------------------------------------------
-- Guild Hub's parts

local GH = ns.GH
local function Win() return GH.mainFrame end

function ST.MainParts()
    local f = GH.mainFrame or {}
    local t = GH.statusTab or {}
    local tabs = f.tabs or {}
    return {
        { name = "window", obj = f },
        { name = "close", obj = f.closeButton, top = true, titleBar = true },
        { name = "mini", obj = f.miniButton, top = true, titleBar = true },
        { name = "settings", obj = f.gearButton, top = true, titleBar = true, art = f.gearButton and f.gearButton.icon and { "icon" } or nil },
        { name = "tab.status", obj = tabs.status },
        { name = "tab.prof", obj = tabs.professions, opt = not GH:FeatureOn("prof"), shownOnly = not GH:FeatureOn("prof") },
        { name = "tab.members", obj = tabs.members, opt = not GH:FeatureOn("recruit"), shownOnly = not GH:FeatureOn("recruit") },
        -- 0.6.0-beta.3: the Map tab (hidden while the map feature is off)
        { name = "tab.map", obj = tabs.map, opt = not GH:FeatureOn("map"), shownOnly = not GH:FeatureOn("map") },
        { name = "status.search", obj = t.search },
        { name = "status.sort", obj = t.sort },
        { name = "status.lfgOnly", obj = t.compact },
        { name = "status.list", obj = t.listInset },
        { name = "status.panel", obj = t.panel },
        -- 0.6.0 Find me (hidden while the map feature is off)
        { name = "status.findMe", obj = t.findMe, opt = not GH:FeatureOn("map"), shownOnly = not GH:FeatureOn("map") },
    }
end

function ST.ProfParts()
    local t = GH.profTab or {}
    -- fair trade: not sharing professions = only the locked note (trial accounts: no button)
    if GH.CanUse and not GH:CanUse("prof") then
        local lock = t.lock or {}
        local _, why = GH:CanUse("prof")
        return {
            { name = "prof.lock", obj = t.lock },
            { name = "prof.lockButton", obj = lock.button, opt = why ~= "off", shownOnly = why ~= "off" },
        }
    end
    return {
        { name = "prof.search", obj = t.search },
        { name = "prof.filter", obj = t.filter },
        { name = "prof.online", obj = t.online },
        { name = "prof.list", obj = t.listInset },
        { name = "prof.panel", obj = t.panel },
        { name = "prof.footer", obj = t.footer },
        { name = "prof.popup", obj = t.popup, opt = true, shownOnly = true },
    }
end

-- 1.0.0-beta.1: the My status panel (parts by state; the highlighted button and news strip only when
-- they apply)
function ST.MyStatusParts()
    local t = GH.statusTab or {}
    local mapOn = GH:FeatureOn("map")
    local parts = {
        { name = "my.title", obj = t.title },
        { name = "my.state", obj = t.state },
        { name = "my.note", obj = t.note },
        { name = "my.lasts", obj = t.lasts },
        { name = "my.clear", obj = t.clear, opt = true, shownOnly = true },
        { name = "my.highlight", obj = t.highlight, opt = true, shownOnly = true },
        { name = "my.news", obj = t.news, opt = true, shownOnly = true },
        { name = "my.dungeon", obj = t.dungeon, opt = true, shownOnly = true },
        { name = "my.pause", obj = t.pause, opt = true, shownOnly = true },
        { name = "my.resume", obj = t.resume, opt = true, shownOnly = true },
        { name = "my.findMe", obj = t.findMe, opt = not mapOn, shownOnly = not mapOn },
    }
    if t.preset then
        parts[#parts + 1] = { name = "my.preset", obj = t.preset }
    else
        for p, b in pairs(t.chips or {}) do parts[#parts + 1] = { name = "my.chip." .. p, obj = b } end
    end
    return parts
end

-- 1.0.0-beta.1: the panel fits, a badge never changes the tab's size, the quoted note is cleaned,
-- and the note queue's numbers. A badge drawn here is put back in the same frame (nothing shows).
local function CheckMyStatus()
    local t = GH.statusTab
    if not (t and t.panel) then return Skip("mystatus", "(no panel)") end
    Count()
    local ph = Read(t.panel, "GetHeight")
    if type(ph) == "number" and not IsSecret(ph) and type(t.layoutBottom) == "number" and -t.layoutBottom + 20 > ph then
        Problem("MY", "panel", ("parts need %d px, the panel has %d"):format(-t.layoutBottom + 20, ph))
    end
    Count()
    local tabB = GH.mainFrame and GH.mainFrame.tabs and GH.mainFrame.tabs.status
    if tabB and GH.SetBadge then
        local before = GH:BadgeCount("status")
        local w0 = Read(tabB, "GetWidth")
        GH:SetBadge("status", 3)
        local w1 = Read(tabB, "GetWidth")
        local b = GH.mainFrame.badgeParts and GH.mainFrame.badgeParts.status
        local bw = b and Read(b, "GetWidth")
        GH:SetBadge("status", before)
        if w0 ~= w1 then Problem("MY", "badge", "the tab changed size with a badge") end
        if type(bw) == "number" and not IsSecret(bw) and bw > 16 then Problem("MY", "badge", ("badge %d px wide"):format(bw)) end
        run.state.badgeArt = b and b.art
    end
    Count()
    local clean = GH.StripCodes and GH.StripCodes("|cffff0000red|r |Hitem:1|h[Sword]|h |TInterface\\Icons\\x:0|t end|")
    if clean ~= "red [Sword] end" then Problem("MY", "strip", "the quoted note keeps codes: " .. tostring(clean)) end
    local long = GH.CutBytes and GH.CutBytes(("\195\169"):rep(200), 255)
    if not long or #long > 255 or #long % 2 ~= 0 then Problem("MY", "cut", "the line cut splits a letter") end
    local st = GH.toastStats or {}
    local quiet, why = false, nil
    if GH.AlertsQuiet then quiet, why = GH:AlertsQuiet() end
    Info(("toasts shown=%d held=%d queued=%d dropped=%d budget=%s quiet=%s paused=%s badge=%s preset=%s hi=%s news=%d"):format(
        st.shown or 0, st.held or 0, st.queued or 0, st.dropped or 0, GH.db.profile.toastBudget ~= false and "y" or "n",
        quiet and tostring(why) or "n", (GH.AlertsPausedLeft and GH:AlertsPausedLeft() > 0) and "y" or "n",
        tostring(run.state.badgeArt or "-"), t.preset and "dd" or "chips", tostring(t.highlightKind or "-"), t.newsCount or 0))
    -- 1.0.0-beta.1: WoW Forever's dungeon list: 38 entries, the picker shows the 3 Forever raids only
    -- (classic ones hidden), sorted by level with raids last; an old number still reads as its name.
    Count()
    local list, order = GH.DUNGEONS or {}, GH.DUNGEON_ORDER or {}
    local raids, hiddenIn, sorted, lastMin, seenRaid = 0, 0, true, 0, false
    for pos = 2, #order do
        local e = list[order[pos]]
        if not e then sorted = false
        elseif e.hidden then hiddenIn = hiddenIn + 1
        elseif e.raid then raids, seenRaid = raids + 1, true
        else
            if seenRaid or e.min < lastMin then sorted = false end
            lastMin = e.min
        end
    end
    if #list < 38 then Problem("MY", "dungeons", ("%d dungeon entries, want 38"):format(#list)) end
    if raids ~= 3 or hiddenIn > 0 then Problem("MY", "dungeons", ("picker raids %d (want 3), hidden ones shown %d"):format(raids, hiddenIn)) end
    if order[1] ~= 0 or not sorted then Problem("MY", "dungeons", "the picker is not 'any' then by level, raids last") end
    if not (list[22] and list[22].name == "Molten Core") then Problem("MY", "dungeons", "an old raid number no longer reads right") end
    Info(("dungeons %d picker=%d newdng=%s"):format(#list, #order, GH.NewDungeonText and GH:NewDungeonText(true) or "?"))
end

-- 0.6.0-beta.3: the Map tab ("Who is where"): toolbar, list, panel (buttons by state)
function ST.MapParts()
    local t = GH.mapTab or {}
    local mapOn = GH:FeatureOn("map")
    return {
        { name = "map.search", obj = t.search },
        { name = "map.addonOnly", obj = t.addonOnly },
        { name = "map.list", obj = t.listInset },
        { name = "map.panel", obj = t.panel },
        { name = "map.note", obj = t.note },
        { name = "map.share", obj = t.share, opt = true, shownOnly = true },
        { name = "map.zone", obj = t.zone, opt = true, shownOnly = true },
        { name = "map.findMe", obj = t.findMe, opt = not mapOn, shownOnly = not mapOn },
        { name = "map.openMap", obj = t.openMap },
        { name = "map.tickMini", obj = t.tickMini, opt = not mapOn, shownOnly = not mapOn },
        { name = "map.tickAfk", obj = t.tickAfk, opt = not mapOn, shownOnly = not mapOn },
    }
end

-- 0.6.0-beta.3: no toolbar part overlaps a tab, and the tab row keeps its right end free (>= 200 px)
local function CheckTabRow()
    local f = GH.mainFrame
    if not f or not f.tabs then return end
    Count()
    local free = GH.TabRowFree and GH:TabRowFree()
    if type(free) == "number" and not IsSecret(free) and free < (GH.TAB_FREE_PX or 200) then
        Problem("TABS", "free", ("%d px free at the right end (want %d)"):format(free, GH.TAB_FREE_PX or 200))
    end
    Count()
    local bars = {}
    local st, pt = GH.statusTab or {}, GH.profTab or {}
    for _, o in ipairs({ st.search, st.sort, st.compact, pt.search, pt.filter, pt.online,
        GH.mapTab and GH.mapTab.search, GH.mapTab and GH.mapTab.addonOnly }) do
        if o and o.IsShown and o:IsShown() then bars[#bars + 1] = o end
    end
    for key, b in pairs(f.tabs) do
        local rb = b:IsShown() and ScreenRect(b)
        if type(rb) == "table" then
            for _, o in ipairs(bars) do
                local ro = ScreenRect(o)
                if type(ro) == "table" and Overlap(ro, rb) > 4 then Problem("TABS", key, "a toolbar part overlaps the tab") end
            end
        end
    end
    if type(free) == "number" and not IsSecret(free) then Info(("tab row free %d px"):format(free)) end
end

-- 0.6.0-beta.3: the name menu's entries (built, never opened: nothing pops up) on yourself and on one
-- online guildmate; the action APIs only checked with type() (nothing is called).
local MENU_ORDER = { whisper = 1, canhelp = 1.5, invite = 2, ask = 3, waypoint = 4, showmap = 5, joinme = 6, mute = 7, more = 8 }
local function CheckMenuEntries(list, who)
    Count()
    local last, greyed = 0, 0
    for _, e in ipairs(list) do
        if e.kind == "head" then break end
        local pos = e.key and MENU_ORDER[e.key]
        if pos then
            if pos < last then Problem("MENU", who, "entries out of order at " .. e.key) end
            last = pos
        end
        if (e.kind == "button" or e.kind == "submenu") and not e.ok then
            greyed = greyed + 1
            if type(e.why) ~= "string" or e.why == "" then Problem("MENU", who, (e.key or "?") .. " greyed without a reason") end
        end
    end
    if GH:NameMenuTopCount(list) > (GH.NAME_MENU_MAX_TOP or 8) then Problem("MENU", who, "too many top entries") end
    return greyed
end

local function CheckNameMenu()
    if not GH.NameMenuEntries then return Skip("menu", "(not loaded)") end
    local me = GH:MyName()
    local own = GH:NameMenuEntries(me, "selftest")
    CheckMenuEntries(own, "self")
    local other
    for name, r in pairs(GH.roster or {}) do
        if r.online and not GH:IsMyChar(name) then other = name break end
    end
    local items, greyed, hooks = #own, 0, #GH:Hooks("nameMenu")
    if other then
        local list = GH:NameMenuEntries(other, "selftest")
        greyed = CheckMenuEntries(list, "guildmate")
        items = #list
    else
        Skip("menu.guildmate", "(nobody else online)")
    end
    Count()
    local rinv = type(_G.SLASH_REQUESTINVITE1) == "string" and _G.SLASH_REQUESTINVITE1 ~= ""
    if not rinv then Problem("ACT", "requestinvite", "SLASH_REQUESTINVITE1 is missing (Ask to join's fallback)") end
    local function y(v) return v and "y" or "n" end
    Info(("menu items=%d greyed=%d hook=%d mu=%s | wp api=%s ask api=%s openmap=%s rinv=%s"):format(items, greyed, hooks,
        y(MenuUtil and type(MenuUtil.CreateContextMenu) == "function"),
        y(C_Map and type(C_Map.SetUserWaypoint) == "function" and UiMapPoint and type(UiMapPoint.CreateFromCoordinates) == "function"),
        y(C_PartyInfo and type(C_PartyInfo.RequestInviteFromUnit) == "function"), y(type(_G.OpenWorldMap) == "function"), y(rinv)))
end

-- 1.0.0-beta.2: quick menu entries (built, never opened), a fold toggled and put back, tab tips,
-- Promote/Demote/Remove only for officers, the new art parts, key bindings, the live subtitle.
local QM_NAME_KEYS = { whisper = true, invite = true, ask = true, waypoint = true, showmap = true, joinme = true,
    mute = true, promote = true, demote = true, remove = true }
local function CheckQoL()
    local function y(v) return v and "y" or "n" end
    -- quick menu
    Count()
    local qm = GH.QuickMenuEntries and GH:QuickMenuEntries() or {}
    local radios, ticked = 0, 0
    for _, e in ipairs(qm) do
        if e.kind == "radio" then
            radios = radios + 1
            if e.checked and e.checked() then ticked = ticked + 1 end
        end
        if e.key and QM_NAME_KEYS[e.key] then Problem("QM", e.key, "a name action in the quick menu") end
        if (e.kind == "button" or e.kind == "radio") and type(e.run) ~= "function" then Problem("QM", e.key or "?", "entry without an action") end
    end
    if #qm == 0 or qm[1].kind ~= "title" or qm[#qm].key ~= "settings" then Problem("QM", "order", "title first and Settings last") end
    if radios ~= #GH.PRESETS + 1 or ticked ~= 1 then Problem("QM", "status", ("%d status choices (%d ticked)"):format(radios, ticked)) end
    -- fold: toggle one group and put it back (one frame, nothing is left changed)
    Count()
    local fold = "-"
    local folded = GH.db.profile.folded
    if GH.statusTab and GH.ToggleFold and type(folded) == "table" then
        local before = folded.other
        GH:ToggleFold("other")
        local mid = folded.other
        GH:ToggleFold("other")
        if folded.other ~= before or mid == before then Problem("FOLD", "toggle", "a header click didn't fold / unfold") end
        fold = "ok"
    end
    -- tab tips
    Count()
    local f = GH.mainFrame
    local tips, tabs = 0, 0
    for _, d in ipairs(f and f.tabList or {}) do
        tabs = tabs + 1
        local b = f.tabs[d.key]
        if b and type(b.ghTip) == "string" and b.ghTip ~= "" then tips = tips + 1
        else Problem("TIPS", d.key, "tab without a tooltip") end
    end
    -- Promote / Demote / Remove: only in an officer's menu on a non-officer member; Remove last
    Count()
    local n6 = "off"
    local me = GH:MyName()
    for _, e in ipairs(GH.NameMenuEntries and GH:NameMenuEntries(me, "selftest") or {}) do
        if e.key == "promote" or e.key == "demote" or e.key == "remove" then Problem("N6", "self", "rank entries on yourself") end
    end
    for name, r in pairs(GH.roster or {}) do
        if r.online and not GH:IsMyChar(name) and not GH:IsOfficer(name) then
            local list = GH:NameMenuEntries(name, "selftest")
            local found, lastKey = 0, nil
            for _, e in ipairs(list) do
                if e.key == "promote" or e.key == "demote" or e.key == "remove" then
                    found = found + 1
                    if not e.ok and (type(e.why) ~= "string" or e.why == "") then Problem("N6", e.key, "greyed without a reason") end
                end
                if e.key then lastKey = e.key end
            end
            local officer = IsInGuild() and GH:IsOfficer(me)
            if not officer and found > 0 then Problem("N6", "member", "rank entries for a non-officer") end
            if officer and (found ~= 3 or lastKey ~= "remove") then Problem("N6", "officer", ("%d rank entries, last %s"):format(found, tostring(lastKey))) end
            n6 = officer and tostring(found) or "off"
            break
        end
    end
    -- art parts, bindings, subtitle
    local bar, tick, cls, star = "?", "?", "?", "?"
    if ns.Widgets.ArtReport then bar, tick, cls, star = ns.Widgets.ArtReport() end
    local bind = "-"
    if type(GetBindingKey) == "function" then
        local ok, k = pcall(GetBindingKey, "GUILDHUB_TOGGLE")
        bind = ok and (IsSecret(k) and "s" or (k and "set" or "unbound")) or "!"
    end
    Count()
    if type(_G.BINDING_NAME_GUILDHUB_TOGGLE) ~= "string" then Problem("BIND", "names", "key binding names missing") end
    local sub = f and f.sub and f.sub.GetText and f.sub:GetText()
    Info(("qol qm=%d fold=%s tips=%d/%d n6=%s art bar=%s tick=%s class=%s star=%s bind=%s sub=%s"):format(#qm, fold, tips, tabs, n6,
        bar, tick, cls, star, bind, y(type(sub) == "string" and not IsSecret(sub) and sub:find("%d") ~= nil)))
end

-- Guild Recruiter R1: the Recruiting tab's Overview page (officer controls only for officers)
function ST.RecruitParts()
    local t = GH.recruitTab or {}
    local officer = IsInGuild() and GH:IsOfficer(GH:MyName())
    local parts = {
        { name = "rec.side", obj = t.side },
        { name = "rec.area", obj = t.area },
        { name = "rec.needTitle", obj = t.needTitle },
        { name = "rec.class1", obj = t.classes and t.classes.WARRIOR, art = { "icon" } },
        { name = "rec.makeup", obj = t.rows and t.rows.WARRIOR and t.rows.WARRIOR.name },
        { name = "rec.text", obj = t.textBg },
        { name = "rec.copy", obj = t.copy },
        { name = "rec.postGeneral", obj = t.post and t.post.general },
        { name = "rec.postTrade", obj = t.post and t.post.trade },
        { name = "rec.preview", obj = t.preview },
        { name = "rec.channel", obj = t.channel, opt = true, shownOnly = true },
        { name = "rec.make", obj = t.make, opt = true, shownOnly = true },
        { name = "rec.drag", obj = t.drag, art = { "icon" }, opt = true, shownOnly = true },
        { name = "rec.status", obj = t.status },
        { name = "rec.finder", obj = t.finder, opt = true, shownOnly = true },
        { name = "rec.totals", obj = t.totals },
    }
    if not officer then
        parts[#parts + 1] = { name = "rec.groupTitle", obj = t.groupTitle }
        parts[#parts + 1] = { name = "rec.group1", obj = t.group and t.group[1], opt = true, shownOnly = true }
    end
    if officer then
        parts[#parts + 1] = { name = "rec.share", obj = t.share }
        parts[#parts + 1] = { name = "rec.postTick", obj = t.postTick }
        parts[#parts + 1] = { name = "rec.dcBox", obj = t.dcBox }
        parts[#parts + 1] = { name = "rec.plusT", obj = t.roles and t.roles.t and t.roles.t.plus }
        parts[#parts + 1] = { name = "rec.adHint", obj = t.adHint, opt = true, shownOnly = true } -- R5
    end
    return parts
end

-- ---------------------------------------------------------------------------
-- Saved data (on a copy only: the real SavedVariables are never written)

local function DeepCopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local c = {}
    seen[v] = c
    for k, x in pairs(v) do c[DeepCopy(k, seen)] = DeepCopy(x, seen) end
    return c
end

-- Store.lua's repair, run on a fake addon object that holds a copy.
local function RepairOn(profile, global)
    local fake = { db = { profile = profile, global = global }, Debug = function() end }
    return GH.RepairSaved(fake)
end

local function CheckSaved()
    local db = GH.db
    if not (db and GH.RepairSaved) then return Skip("db", "(not loaded)") end
    Count()
    local ok, fixed = pcall(RepairOn, DeepCopy(db.profile), DeepCopy(db.global))
    if not ok then return Problem("DB", "current", Short(fixed)) end
    if type(fixed) == "table" and #fixed > 0 then Info("saved settings that need repair: " .. #fixed) end
    Count()
    ok, fixed = pcall(RepairOn, { window = 5, minimap = "x", alerts = 3, sort = {}, shareProf = "y" }, { guilds = 7 })
    if not ok then Problem("DB", "broken", Short(fixed)) end
    -- own characters (Alts.lua): a damaged list is repaired and keeps its good entries (copy only)
    if GH.AltSelfTest then
        Count()
        local acct = { chars = { [5] = {}, ["Bad Name"] = {}, ["Good One-Realm"] = { ts = 1 }, ["Odd One-Realm"] = "x",
            ["Two Bits-Realm"] = { ts = "y", g = 3 } } }
        local okA, errA = pcall(RepairOn, {}, { guilds = {}, account = acct })
        local c = acct.chars
        if not okA then Problem("DB", "alts repair", Short(errA))
        elseif not (c["Good One-Realm"] and c["Two Bits-Realm"] and c["Two Bits-Realm"].ts == 0 and c[5] == nil
            and c["Bad Name"] == nil and c["Odd One-Realm"] == nil) then
            Problem("DB", "alts repair", "wrong result")
        end
        Count()
        local okT, probs, line = pcall(GH.AltSelfTest, GH)
        if not okT then Problem("ERR", "alts", Short(probs))
        else
            for _, p in ipairs(probs) do Problem("ALT", "own chars", p) end
            Info(line)
        end
    end
    -- professions: every saved recipe list decodes and matches its hash (copy only)
    local gdb = GH:GetGuildDB()
    if not gdb then return end
    local lists, bad = 0, 0
    for _, m in pairs(DeepCopy(gdb.members)) do
        local prof = type(m) == "table" and type(m.prof) == "table" and type(m.prof.p) == "table" and m.prof
        for _, e in pairs(prof and prof.p or {}) do
            if type(e) == "table" and e.l and not e.old then
                lists = lists + 1
                local ids = GH:DecodeRecipes(e.l)
                if not ids or GH:RecipeHash(GH:EncodeRecipes(ids)) ~= e.h then bad = bad + 1 end
            end
        end
    end
    Count()
    if bad > 0 then Problem("DB", "recipes", bad .. " of " .. lists .. " lists don't match") end
    Count()
    local okIdx, err = pcall(GH.ProfIndex, GH)
    if not okIdx then Problem("ERR", "prof index", Short(err)) end
    Info(("prof lists %d, feed %d"):format(lists, #gdb.feed))
    -- 0.4.0: guild history repair on a broken copy (must not throw, must keep the good entries)
    if GH.CheckRecorderData then
        Count()
        local copy = { rec = { first = { ["A-B"] = 5, [3] = "x" }, kills = { 7, { k = "1:2:3", t = 1, e = 1 } },
            hours = { all = { [200] = {} }, weeks = 4 }, log = "x", motd = { { t = 1, s = "hi" } } } }
        local okR, errR = pcall(GH.CheckRecorderData, GH, copy, true)
        if not okR then Problem("DB", "history repair", Short(errR))
        elseif copy.rec.first["A-B"] ~= 5 or #copy.rec.kills ~= 1 or #copy.rec.motd ~= 1 then
            Problem("DB", "history repair", "lost good entries")
        end
    end
end

-- 0.4.0: feature registry, event dispatcher, ticker, budget, guild history caps
local function CheckFeatures()
    if not GH.features then return Skip("features", "(not loaded)") end
    -- 0.4.0-b3: run the ignore check once first, so the map line shows the real ignore mode
    -- (it is only set the first time the check runs); a failure is reported by the map part
    if GH.IsIgnored and GH.MyName then pcall(GH.IsIgnored, GH, GH:MyName()) end
    local on, off = 0, 0
    for _, key in ipairs(GH.featureOrder) do
        Count()
        local running = GH.featureRunning and GH.featureRunning[key] or false
        if GH:FeatureOn(key) then on = on + 1 else off = off + 1 end
        -- a feature that is off must not listen to events or run jobs
        if not GH:FeatureOn(key) and (GH:EventCount(key) > 0 or GH:JobCount(key) > 0) then
            Problem("FEAT", key, "is off but still listens")
        end
        if GH.started and GH:FeatureOn(key) and not running then Problem("FEAT", key, "is on but didn't start") end
        local f = GH.features[key]
        if type(f.selftest) == "function" then
            local ok, err = pcall(f.selftest, { Count = Count, Problem = Problem, Skip = Skip, Info = Info })
            if not ok then Problem("ERR", "feature " .. key, Short(err)) end
        end
    end
    -- no handler twice for one owner and event
    Count()
    for ev, list in pairs(GH.eventHandlers or {}) do
        local seen = {}
        for _, h in ipairs(list) do
            if seen[h.owner] then Problem("EV", ev, "registered twice by " .. tostring(h.owner)) end
            seen[h.owner] = true
        end
    end
    -- the budget: tokens in range, nothing waiting for ages
    Count()
    local b = GH.budget
    if b then
        local free = GH:BudgetFree("guild")
        if free > 10.001 then Problem("BUD", "tokens", "more than 10") end
        local oldest = 0
        -- live and normal messages (bulk sync answers may queue longer after many logins at once)
        for _, q in ipairs(GH.sendQueue or {}) do
            if q.class ~= "bulk" then oldest = math.max(oldest, GetTime() - (q.t or GetTime())) end
        end
        if oldest > 300 then Problem("BUD", "queue", "a message waited over 5 min") end
        Info(("features %d on/%d off, jobs %d, queue %d, sent 10min %d"):format(on, off, GH:JobCount(),
            #(GH.sendQueue or {}), GH:BudgetSent(600, "guild")))
    end
    if GH.lastApiLine then Info("api line taken") end
    -- fair trade: which sharing items are on (y/n, trial = t)
    if GH.shareOrder then
        local s = {}
        for _, key in ipairs(GH.shareOrder) do
            local ok, why = GH:CanUse(key)
            s[#s + 1] = key .. "=" .. (ok and "y" or (why == "trial" and "t" or "n"))
        end
        Info("shares " .. table.concat(s, ","))
    end
end


-- ---------------------------------------------------------------------------
-- Steps (each runs some frames later, so the UI has laid out; combat stops the run)

local Finish

local function Later(frames, fn)
    local function Tick()
        if not run then return end
        frames = frames - 1
        if frames > 0 then return C_Timer.After(0, Tick) end
        if InCombat() then
            run.stopped = true
            return Finish()
        end
        local ok, err = pcall(fn)
        if not ok then
            Problem("ERR", "step", Short(err))
            Finish()
        end
    end
    C_Timer.After(0, Tick)
end

-- Guild Recruiter R2: the officers' lists page (officers only)
function ST.RecruitOffParts()
    local t = GH.recruitTab or {}
    local pros, dni = t.pros or {}, t.dni or {}
    local row1 = pros.rows and pros.rows[1]
    return {
        { name = "rec.side.officer", obj = t.side and t.side.buttons and t.side.buttons.officer },
        { name = "off.prosTitle", obj = pros.title },
        { name = "off.prosList", obj = pros.inset },
        { name = "off.prosClear", obj = pros.clear },
        { name = "off.prosRow1", obj = row1, opt = true, shownOnly = true },
        -- only while its row shows (an empty list hides the row, the button stays "shown" inside it)
        { name = "off.prosInvite1", obj = row1 and row1:IsShown() and row1.invite or nil, opt = true, shownOnly = true },
        { name = "off.dniTitle", obj = dni.title },
        { name = "off.dniList", obj = dni.inset },
        { name = "off.dniClear", obj = dni.clear },
        { name = "off.hint", obj = t.offHint },
    }
end

-- Guild Recruiter R3: the "Suggestions & trials" page (officers only)
function ST.RecruitTrialParts()
    local t = GH.recruitTab or {}
    local sug, trial = t.sug or {}, t.trial or {}
    return {
        { name = "rec.side.trials", obj = t.side and t.side.buttons and t.side.buttons.trials },
        { name = "off.sugTitle", obj = sug.title },
        { name = "off.sugList", obj = sug.inset },
        { name = "off.sugClear", obj = sug.clear },
        { name = "off.sugRow1", obj = sug.rows and sug.rows[1], opt = true, shownOnly = true },
        { name = "off.trialTitle", obj = trial.title },
        { name = "off.trialList", obj = trial.inset },
        { name = "off.trialClear", obj = trial.clear },
        { name = "off.trialRow1", obj = trial.rows and trial.rows[1], opt = true, shownOnly = true },
        { name = "off.hint2", obj = t.off2Hint },
    }
end

-- Guild Recruiter R5: the "Ad builder" page (officers only)
function ST.RecruitAdParts()
    local t = GH.recruitTab or {}
    local a = t.adb or {}
    local ch = a.choices or {}
    return {
        { name = "rec.side.adbuild", obj = t.side and t.side.buttons and t.side.buttons.adbuild },
        { name = "adb.title", obj = a.title },
        { name = "adb.size1", obj = a.sizes and a.sizes[1] },
        { name = "adb.day1", obj = a.days and a.days[1] },
        { name = "adb.day7", obj = a.days and a.days[7] },
        { name = "adb.at", obj = ch.at },
        { name = "adb.tz", obj = ch.tz },
        { name = "adb.loot", obj = ch.loot },
        { name = "adb.style", obj = ch.style },
        { name = "adb.lvl", obj = ch.lvl },
        { name = "adb.built", obj = a.builtBg },
        { name = "adb.use", obj = a.use },
        { name = "adb.save", obj = a.save },
        { name = "adb.long", obj = a.longBg },
        { name = "adb.hint", obj = a.hint },
    }
end

-- Guild Recruiter R6: the "New members" page (everyone; the officers' half only for officers)
function ST.RecruitBuddyParts()
    local t = GH.recruitTab or {}
    local b = t.bud or {}
    local officer = GH.RecruitIAmOfficer and GH.RecruitIAmOfficer()
    local row1 = b.rows and b.rows[1]
    local parts = {
        { name = "rec.side.newmem", obj = t.side and t.side.buttons and t.side.buttons.newmem },
        { name = "bud.title", obj = b.title },
        { name = "bud.tick", obj = b.tick },
        { name = "bud.state", obj = b.state },
        { name = "bud.guildiesTitle", obj = b.guildiesTitle },
    }
    if officer then
        parts[#parts + 1] = { name = "bud.newTitle", obj = b.newTitle }
        parts[#parts + 1] = { name = "bud.list", obj = b.inset }
        parts[#parts + 1] = { name = "bud.row1", obj = row1, opt = true, shownOnly = true }
        parts[#parts + 1] = { name = "bud.pick1", obj = row1 and row1:IsShown() and row1.pick or nil, opt = true, shownOnly = true }
        parts[#parts + 1] = { name = "bud.hint", obj = b.hint }
    else
        parts[#parts + 1] = { name = "bud.memberHint", obj = b.memberHint }
    end
    return parts
end

local function BackToOverview()
    local t = GH.recruitTab
    if t and t.side then t.side:Select("recruit"); GH:DrawRecruitPage() end
    Finish()
end

local function StepAdBuild()
    CheckGroup(ST.RecruitAdParts(), Win())
    BackToOverview()
end

local function StepTrials()
    CheckGroup(ST.RecruitTrialParts(), Win())
    local t = GH.recruitTab
    if t and t.side and t.adBody then
        t.side:Select("adbuild")
        GH:DrawRecruitPage()
        return Later(1, StepAdBuild)
    end
    BackToOverview()
end

local function StepOfficer()
    CheckGroup(ST.RecruitOffParts(), Win())
    local t = GH.recruitTab
    if t and t.side and t.off2Body then
        t.side:Select("trials")
        GH:DrawRecruitPage()
        return Later(1, StepTrials)
    end
    if t and t.side then t.side:Select("recruit"); GH:DrawRecruitPage() end
    Finish()
end

-- R6: New members (everyone), then the officers' pages
local function StepBuddy()
    CheckGroup(ST.RecruitBuddyParts(), Win())
    local t = GH.recruitTab
    if GH.RecruitIAmOfficer and GH.RecruitIAmOfficer() and t and t.side and t.offBody then
        t.side:Select("officer")
        GH:DrawRecruitPage()
        return Later(1, StepOfficer)
    end
    BackToOverview()
end

local function StepMembers()
    CheckGroup(ST.RecruitParts(), Win())
    local t = GH.recruitTab
    if t and t.side and t.budBody then
        t.side:Select("newmem")
        GH:DrawRecruitPage()
        return Later(1, StepBuddy)
    end
    if GH.RecruitIAmOfficer and GH.RecruitIAmOfficer() and t and t.side and t.offBody then
        t.side:Select("officer")
        GH:DrawRecruitPage()
        return Later(1, StepOfficer)
    end
    Finish()
end

-- full mode: the Recruiting tab after Professions (only when the recruiter is on and we're in a guild)
local function NextMembers()
    if run.mode == "full" and GH:FeatureOn("recruit") and IsInGuild() and GH.mainFrame.tabs.members then
        run.state.prevTab = run.state.prevTab or GH.mainFrame.currentTab
        GH:ShowTab("members")
        return Later(2, StepMembers)
    end
    Finish()
end

-- 1.0.1: the Boards tab (full mode): every Raid view, the locked note, Tonight's buttons; sort toggled
-- and put back. Then the Recruiting tab. No calendar read happens here (tos: only on a real open / Refresh).
function ST.BoardsParts()
    local t = GH.boardsTab or {}
    local view = GH.db.profile.raidView
    local parts = {
        { name = "brd.side", obj = t.side },
        { name = "brd.side.raid", obj = t.side and t.side.buttons and t.side.buttons.raid },
        { name = "brd.view", obj = t.view },
        { name = "brd.footer", obj = t.footer, opt = true, shownOnly = true },
        { name = "brd.locked", obj = t.locked, opt = true, shownOnly = true },
        { name = "brd.logStrip", obj = t.logStrip, opt = true, shownOnly = true },
        { name = "brd.checkEnch", obj = t.checkEnch, opt = true, shownOnly = true }, -- 1.0.2 officers
    }
    if view == "tonight" then
        local f = t.tonight or {}
        parts[#parts + 1] = { name = "tn.card", obj = f.card }
        parts[#parts + 1] = { name = "tn.yes", obj = f.yes }
        parts[#parts + 1] = { name = "tn.maybe", obj = f.maybe }
        parts[#parts + 1] = { name = "tn.no", obj = f.no }
        parts[#parts + 1] = { name = "tn.counts", obj = f.counts }
        parts[#parts + 1] = { name = "tn.queueHead", obj = f.queue and f.queue.head }
        parts[#parts + 1] = { name = "tn.summon", obj = f.tSummon }
        parts[#parts + 1] = { name = "tn.refresh", obj = t.refresh }
    elseif t.table and t.table.frame:IsShown() then
        parts[#parts + 1] = { name = "brd.head", obj = t.table.head }
        parts[#parts + 1] = { name = "brd.head1", obj = t.table.headButtons[1] }
        parts[#parts + 1] = { name = "brd.list", obj = t.table.scrollBox or t.table.area }
    end
    return parts
end

local BOARD_STEPS = { "ready", "lockouts", "resist", "makeup", "tonight" }
local function StepBoards()
    local t = GH.boardsTab
    local i = run.state.boardStep or 1
    local view = BOARD_STEPS[i]
    CheckGroup(ST.BoardsParts(), Win())
    Count()
    if t and view == "tonight" and not GH.tonight.event then
        -- no event: all three answer buttons greyed, with a reason
        for _, k in ipairs({ "yes", "maybe", "no" }) do
            local b = t.tonight[k]
            if b and b:IsEnabled() then Problem("BRD", "tn." .. k, "clickable without an event") end
        end
        if (t.tonight.why:GetText() or "") == "" then Problem("BRD", "tn.why", "no reason shown") end
    end
    if t and view == "ready" and t.table.frame:IsShown() then
        -- sort toggled twice on the first header and put back
        Count()
        local saved = GH.db.profile.raidSort
        local before = type(saved) == "table" and { key = saved.key, rev = saved.rev } or nil
        local b = t.table.headButtons[1]
        if b and b.col and b.col.sort then
            local click = b:GetScript("OnClick") -- the header's own handler, twice (sort, then reverse)
            if click then click(b, "LeftButton"); click(b, "LeftButton") end
            if t.table.sortKey ~= b.col.key or not t.table.sortRev then Problem("BRD", "sort", "header click didn't sort / reverse") end
        end
        GH.db.profile.raidSort = before or { key = "durability" }
    end
    i = i + 1
    run.state.boardStep = i
    if BOARD_STEPS[i] then
        GH.db.profile.raidView = BOARD_STEPS[i]
        GH:DrawBoardsTab()
        return Later(1, StepBoards)
    end
    GH.db.profile.raidView = run.state.prevRaidView or "ready"
    GH:DrawBoardsTab()
    if GH.ShowGearPanel and GH:FeatureOn("gear") then
        -- 1.0.2: your own gear panel (read live, nothing asked or sent), then the settings tree
        GH:ShowGearPanel(GH:MyName())
        return Later(1, function()
            local list = {}
            for name, obj in pairs(GH:GearPanelParts()) do list[#list + 1] = { name = name, obj = obj, opt = name:find("slot") ~= nil } end
            table.sort(list, function(a, b) return a.name < b.name end)
            CheckGroup(list, GH.gearPanel)
            Count()
            if (GH.blobStats.asked or 0) ~= (run.state.blobAsked or 0) then Problem("GEAR", "asked", "your own panel sent a request") end
            GH:HideGearPanel()
            ST.CheckSettingsTree()
            NextMembers()
        end)
    end
    NextMembers()
end

-- 1.0.2: the Settings tree: 9 groups, every older option key still there (saved settings unchanged).
function ST.CheckSettingsTree()
    if not (GH.FlatOptions and GH.OPTION_GROUPS) then return end
    Count()
    local ok, flat = pcall(GH.FlatOptions, GH)
    if not ok or type(flat) ~= "table" then return Problem("OPT", "tree", "options table did not build") end
    for _, key in ipairs({ "debug", "autoActivity", "alertLfg", "profTooltip", "recipeLearnLine", "mapMinimap", "raidRole",
        "shareGroup", "shareProf", "gearShare", "gearMarks", "gearTooltip", "officerRank", "minimapHide" }) do
        if not flat[key] then Problem("OPT", key, "missing from the settings tree") end
    end
    local n = 0
    for _ in pairs(flat) do n = n + 1 end
    Info(("settings tree groups=%d options=%d"):format(#GH.OPTION_GROUPS, n))
end

local function NextBoards()
    if run.mode == "full" and not run.state.boardsDone and GH:FeatureOn("raid") and GH.mainFrame.tabs.boards then
        run.state.boardsDone = true
        run.state.prevTab = run.state.prevTab or GH.mainFrame.currentTab
        run.state.prevRaidView = GH.db.profile.raidView
        run.state.boardStep = 1
        run.state.blobAsked = GH.blobStats and GH.blobStats.asked or 0
        GH:ShowTab("boards")
        GH.db.profile.raidView = BOARD_STEPS[1]
        GH:DrawBoardsTab()
        return Later(2, StepBoards)
    end
    NextMembers()
end

-- 0.6.0-beta.3: the Map tab (full mode). Opening it must not add to the taint counter.
local function StepMap()
    CheckGroup(ST.MapParts(), Win())
    Guard("tabrow", CheckTabRow)
    Count()
    local before = run.state.taintBefore or 0
    local now = GH.actionBlocked and GH.actionBlocked.n or 0
    if now > before then Problem("TAINT", "maptab", (now - before) .. " blocked action(s) after the Map tab") end
    NextBoards()
end

local function NextMap()
    if run.mode == "full" and GH:FeatureOn("map") and GH.mainFrame.tabs.map then
        run.state.prevTab = run.state.prevTab or GH.mainFrame.currentTab
        run.state.taintBefore = GH.actionBlocked and GH.actionBlocked.n or 0
        GH:ShowTab("map")
        return Later(2, StepMap)
    end
    NextBoards()
end

local function StepProf()
    CheckGroup(ST.ProfParts(), Win())
    Guard("tabrow", CheckTabRow)
    NextMap()
end

-- 0.4.0-b2: the card that asks. A real card on screen is checked as it is; else a test card with
-- test text is shown, checked and hidden again (no answer is saved, onClose is not called).
local function CheckCard()
    if not GH.CardFrame then return Skip("card", "(not loaded)") end
    local f = GH.card
    if f and f:IsShown() then return CheckGroup(GH:CardParts(), nil) end
    f = GH:CardFrame()
    GH:FillCard(f, { test = true, title = "Self-test card", text = "This card is a self-test. It closes by itself.",
        -- 0.6.0: three buttons, laid out like the map card's (Share / Zone only / Not now)
        note = "Nothing is saved.", buttons = { { label = "First button", width = 140 }, { label = "Second", width = 106 },
            { label = "Third", width = 106 } } })
    f:Show()
    local ok, err = pcall(CheckGroup, GH:CardParts(), nil)
    f:Hide()
    if not ok then Problem("ERR", "card", Short(err)) end
end

-- 0.4.0 / 0.5.0: the Getting started walkthrough. Every page's rows are checked (text, state, 1-8
-- rows, no to-do on an Optional page, a button on every Needed to-do that can be turned on, step
-- label, Back greyed on page 1, Done on the last page), then each page is shown on the card as a test
-- (nothing saved, onShow not called, its buttons do nothing) unless another card is on screen; the
-- real guide is checked as it is. The height must be the same on every page; the saved "shown"
-- flag, the page on screen and the send queue must not change (the guide sends nothing).
local GUIDE_STATES = { done = true, todo = true, off = true, info = true, head = true }
local function CheckGuidePage(spec, n, total)
    local lines = spec.lines or {}
    local where = "page" .. n
    if #lines < 1 or #lines > 8 then Problem("GUIDE", where, #lines .. " rows") end
    local optional = spec.stepGray == true
    for i, l in ipairs(lines) do
        if type(l.text) ~= "string" or l.text == "" then Problem("GUIDE", where .. ".line" .. i, "no text") end
        if not GUIDE_STATES[l.state] then Problem("GUIDE", where .. ".line" .. i, "state " .. tostring(l.state)) end
        if optional and l.state == "todo" then Problem("GUIDE", where .. ".line" .. i, "to-do on an Optional page") end
        if l.state == "todo" and n > 1 and (l.key == "prof" or l.key == "pos" or l.key == "group")
            and not (l.button and l.button.label) then
            Problem("GUIDE", where .. ".line" .. i, "to-do without a Turn on button")
        end
    end
    if GH.cannotSend then return end
    if type(spec.step) ~= "string" or not spec.step:find(n .. "", 1, true) then Problem("GUIDE", where, "step label") end
    local b = spec.buttons or {}
    if n == 1 and not (b[1] and b[1].greyed) then Problem("GUIDE", where, "Back not greyed") end
    if n == total and not (b[2] and b[2].label == ns.L.GUIDE_BTN_DONE) then Problem("GUIDE", where, "no Done") end
end

local function CheckGuide()
    if not (GH.GuideSpec and GH.CardFrame) then return Skip("guide", "(not loaded)") end
    local before, pageBefore = GH.db.char.guideShown, GH.guidePage
    local queued = #(GH.sendQueue or {})
    local first = GH:GuideSpec(true, 1)
    local total = first.pages or 1
    if not GH.cannotSend and (total < 4 or total > 5) then Problem("GUIDE", "pages", total .. " pages") end
    local specs = { first }
    for n = 2, total do specs[n] = GH:GuideSpec(true, n) end
    for n, spec in ipairs(specs) do CheckGuidePage(spec, n, total) end
    local f = GH.card
    if f and f:IsShown() then
        if f.spec and f.spec.key == "guide" then CheckGroup(GH:CardParts(true), nil) end
    else
        f = GH:CardFrame()
        local h, seen = nil, {}
        for n, spec in ipairs(specs) do
            GH:FillCard(f, spec)
            f:Show()
            -- each part once (on the first page that shows it), so one problem isn't listed 5 times
            local parts = {}
            for _, p in ipairs(GH:CardParts(true)) do
                local shown = p.obj and p.obj.IsShown and p.obj:IsShown()
                if not seen[p.name] and (shown or not p.shownOnly) then
                    parts[#parts + 1] = p
                    if shown then seen[p.name] = true end
                end
            end
            local ok, err = pcall(CheckGroup, parts, nil)
            local fh = f:GetHeight()
            if h and math.abs(fh - h) > 1 then Problem("GUIDE", "page" .. n, ("height %d, page 1 %d"):format(fh, h)) end
            h = h or fh
            f:Hide()
            if not ok then Problem("ERR", "guide", Short(err)) end
        end
    end
    if GH.db.char.guideShown ~= before then Problem("GUIDE", "saved", "self-test changed guideShown") end
    if GH.guidePage ~= pageBefore then Problem("GUIDE", "page", "self-test changed the page") end
    if #(GH.sendQueue or {}) > queued then Problem("GUIDE", "sent", "the guide queued a message") end
    Info(("guide shown=%s off=%s todo=%d pages=%d"):format(GH.db.char.guideShown and "y" or "n",
        GH.db.profile.guideOff and "y" or "n", GH:GuideTodo(), total))
end

local function StepMain()
    CheckGroup(ST.MainParts(), Win())
    CheckGroup(ST.MyStatusParts(), Win())
    Guard("mystatus", CheckMyStatus)
    Guard("tabrow", CheckTabRow)
    Guard("card", CheckCard)
    Guard("guide", CheckGuide)
    Guard("menu", CheckNameMenu)
    Guard("qol", CheckQoL)
    if run.mode == "full" and GH:FeatureOn("prof") then
        -- the Professions tab (built on first show); Restore goes back to the page that was open
        run.state.prevTab = run.state.prevTab or GH.mainFrame.currentTab
        GH:ShowTab("professions")
        return Later(2, StepProf)
    end
    NextMap()
end

-- ---------------------------------------------------------------------------
-- Restore and output

local function Try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and run then Problem("ERR", "restore " .. label, Short(err)) end
end

-- Puts back everything the run opened (only what it opened), whatever happened.
local function Restore()
    local s = run.state
    local w = Win()
    if s.prevTab and w then Try("tab", GH.ShowTab, GH, s.prevTab) end
    if s.miniWasShown and GH.miniFrame then Try("mini", GH.SetMiniMode, GH, true) end
    if s.openedWindow and w then Try("window", w.Hide, w) end
end

-- The report: header, one line per problem, skips, info. No names, realms, guilds or links.
function ST.Text(r)
    r = r or run
    local okB, ver, build = false
    if GetBuildInfo then okB, ver, build = pcall(GetBuildInfo) end
    local head = ("%s selftest %s | game %s (%s) | %s | %d checks, %d problems"):format(ADDON_NAME, tostring(GH.VERSION),
        okB and tostring(ver) or "?", okB and tostring(build) or "?", r.mode, r.checks, #r.problems)
    if r.stopped then head = head .. " | stopped: combat" end
    local parts = { head }
    for _, p in ipairs(r.problems) do parts[#parts + 1] = p end
    if #r.skips > 0 then
        parts[#parts + 1] = ("skipped %d: %s"):format(#r.skips, table.concat(r.skips, ", ", 1, math.min(#r.skips, MAX_LIST)))
    end
    for _, i in ipairs(r.info) do parts[#parts + 1] = i end
    local text = table.concat(parts, " | ")
    if #text > COPY_MAX then text = text:sub(1, COPY_MAX - 3) .. "..." end
    return text
end

-- A small copy box (select all + Ctrl+C).
local box
local function ShowCopyBox(text)
    if not box then
        box = CreateFrame("Frame", "GuildHubSelfTestBox", UIParent, "BasicFrameTemplateWithInset")
        box:SetSize(520, 160)
        box:SetPoint("CENTER")
        box:SetFrameStrata("DIALOG")
        box:SetMovable(true); box:EnableMouse(true)
        box:RegisterForDrag("LeftButton")
        box:SetScript("OnDragStart", box.StartMoving)
        box:SetScript("OnDragStop", box.StopMovingOrSizing)
        local sf = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -30); sf:SetPoint("BOTTOMRIGHT", -30, 10)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true); eb:SetAutoFocus(true); eb:SetFontObject(ChatFontNormal); eb:SetWidth(470); eb:SetHeight(120)
        eb:SetScript("OnEscapePressed", function() box:Hide() end)
        sf:SetScrollChild(eb)
        box.edit = eb
    end
    box.edit:SetText(text)
    box.edit:HighlightText()
    box:Show()
    box.edit:SetFocus()
end
ST.ShowCopyBox = ShowCopyBox -- also used by /ghub test api (ApiTest.lua)

Finish = function()
    if not run then return end
    local ok, err = pcall(Restore)
    if not ok then Problem("ERR", "restore", Short(err)) end
    local r = run
    run = nil
    if r.stopped then
        GH:Msg(ns.L.SELFTEST_STOPPED)
    elseif #r.problems == 0 then
        GH:Msg(ns.L.SELFTEST_OK, r.checks)
    else
        GH:Msg(ns.L.SELFTEST_PROBLEMS, #r.problems, r.checks)
    end
    pcall(ShowCopyBox, ST.Text(r))
    ST.last = r
end

-- ---------------------------------------------------------------------------
-- Start

local waiter
local function AfterCombat(mode)
    if not waiter then waiter = CreateFrame("Frame") end
    waiter.mode = mode
    waiter:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        self:SetScript("OnEvent", nil)
        ST:Start(self.mode)
    end)
    waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
end

function ST.NewRun(mode)
    return { mode = mode or "quick", checks = 0, problems = {}, skips = {}, info = {}, state = {} }
end

-- mode: "quick" (the main window, Status tab) or "full" (also the Professions tab).
function ST:Start(mode)
    if run then return GH:Msg(ns.L.SELFTEST_RUNNING) end
    if InCombat() then
        GH:Msg(ns.L.SELFTEST_WAIT)
        return AfterCombat(mode)
    end
    run = ST.NewRun(mode)
    Guard("db", CheckSaved)
    Guard("features", CheckFeatures)
    Count()
    if GH.profTooltipHooked then Info("tooltip hook on") else Info("tooltip hook off") end
    local ok, err = pcall(function()
        local w = GH:CreateMainFrame()
        if GH.miniFrame and GH.miniFrame:IsShown() then
            run.state.miniWasShown = true
            GH:SetMiniMode(false)
        end
        if w and not w:IsShown() then
            run.state.openedWindow = true
            w:Show()
        end
        if w.currentTab ~= "status" then
            run.state.prevTab = run.state.prevTab or w.currentTab
            GH:ShowTab("status")
        end
    end)
    if not ok then
        Problem("ERR", "window", Short(err))
        return Finish()
    end
    Later(2, StepMain)
end