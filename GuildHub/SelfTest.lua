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
        { name = "tab.prof", obj = tabs.professions },
        { name = "status.search", obj = t.search },
        { name = "status.sort", obj = t.sort },
        { name = "status.lfgOnly", obj = t.compact },
        { name = "status.list", obj = t.listInset },
        { name = "status.panel", obj = t.panel },
    }
end

function ST.ProfParts()
    local t = GH.profTab or {}
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

local function StepProf()
    CheckGroup(ST.ProfParts(), Win())
    Finish()
end

local function StepMain()
    CheckGroup(ST.MainParts(), Win())
    if run.mode == "full" and GH:FeatureOn("prof") then
        -- the Professions tab (built on first show); Restore goes back to the page that was open
        run.state.prevTab = run.state.prevTab or GH.mainFrame.currentTab
        GH:ShowTab("professions")
        return Later(2, StepProf)
    end
    Finish()
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