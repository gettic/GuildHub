-- Guild Hub: Guild Recruiter, beta R5 (plans\guild-recruiter\PLAN.md section 11.1, tos-new-ideas.md 1).
-- The ad builder: officers pick from fixed lists (raid size, days, start time, time zone, loot,
-- style, level); Guild Hub writes the one-line ad for Post and a longer post for the Copy box.
-- Loaded after Features\RecruitTools.lua and before Features\Recruit.lua (which cleans `pub.f`
-- with GH:CleanAdFields when the record is saved or received).
--
-- Rules kept here (tos-new-ideas.md 1):
--  * Fixed lists only, no new free text; edited by officers only (they ride in RPUB, which only
--    officers can save and which is checked against OUR guild list on every receive).
--  * Building sends nothing and never posts: the built line goes into the officer's own text box
--    ("Use this"), is saved only through SaveRecruitPub and posted only by the capped PostAd path.
--  * The long post is only shown in the Copy box: no member names, never sent, never in the chat box.
--  * The hints ("Your ad has no raid time") stay on your own screen.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

------------------------------------------------------------------------
-- The fixed lists (append only: the values are saved and sent)
------------------------------------------------------------------------
local SIZES = { 10, 20, 40 }
local TZ = { "st", "cet", "uk", "use", "usw", "oce" }      -- nil = server time (the default)
local LOOT = { "lc", "dkp", "epgp", "sr", "msos" }
local STYLE = { "learn", "relax", "comp" }                 -- Forever's own LFG words
local LVL = { "40", "55", "60" }                           -- nil = any level
local DAYS_ALL = 127                                       -- Mon = 1, Tue = 2 ... Sun = 64
local AT_MAX = 47                                          -- start time in 30-min steps (0 = 00:00)
local DROP_ORDER = { "style", "size", "classes" }          -- left out first when the line is too long

GH.AD_FIELDS = { size = SIZES, tz = TZ, loot = LOOT, style = STYLE, lvl = LVL }
GH.AD_FIELD_LIMITS = { DAYS_ALL = DAYS_ALL, AT_MAX = AT_MAX }

local function InList(list, v)
	for _, x in ipairs(list) do if x == v then return true end end
	return false
end

-- A received or saved field set, cleaned: each value must come from its list (else dropped).
-- Returns nil when nothing is left.
function GH:CleanAdFields(f)
	if type(f) ~= "table" then return nil end
	local c, any = {}, false
	if InList(SIZES, f.size) then c.size = f.size; any = true end
	local d = U.ValidNumber(f.days, 1, DAYS_ALL)
	if d and d == math.floor(d) then c.days = d; any = true end
	local at = U.ValidNumber(f.at, 0, AT_MAX)
	if at and at == math.floor(at) then c.at = at; any = true end
	if InList(TZ, f.tz) and f.tz ~= "st" then c.tz = f.tz; any = true end
	if InList(LOOT, f.loot) then c.loot = f.loot; any = true end
	if InList(STYLE, f.style) then c.style = f.style; any = true end
	if InList(LVL, f.lvl) then c.lvl = f.lvl; any = true end
	return any and c or nil
end

------------------------------------------------------------------------
-- Words
------------------------------------------------------------------------
local function HasDay(days, i) return days and math.floor(days / 2 ^ (i - 1)) % 2 == 1 end
GH.AdHasDay = HasDay

-- "Wed/Sun" (sep "/") or "Wed, Sun"; all seven = "daily"
function GH:AdDaysText(days, sep)
	if type(days) ~= "number" then return nil end
	if days == DAYS_ALL then return L.ADB_DAILY end
	local out = {}
	for i = 1, 7 do if HasDay(days, i) then out[#out + 1] = L.ADB_DAY[i] end end
	if #out == 0 then return nil end
	return table.concat(out, sep or "/")
end

function GH:AdTimeText(at)
	if type(at) ~= "number" then return nil end
	return ("%02d:%02d"):format(math.floor(at / 2), (at % 2) * 30)
end

local function ClassName(class)
	local t = type(LOCALIZED_CLASS_NAMES_MALE) == "table" and LOCALIZED_CLASS_NAMES_MALE[class]
	return t or (class:sub(1, 1) .. class:sub(2):lower())
end

-- The guild's name and the faction from the game (never typed).
local function GuildName()
	local ok, name = pcall(GetGuildInfo, "player")
	if ok and type(name) == "string" and not U.IsSecret(name) then return U.CleanText(name, 40) end
	return nil
end

local function Faction()
	if type(UnitFactionGroup) ~= "function" then return nil end
	local ok, eng, loc = pcall(UnitFactionGroup, "player")
	if not ok then return nil end
	local f = (type(loc) == "string" and not U.IsSecret(loc) and loc ~= "") and loc or eng
	if type(f) ~= "string" or U.IsSecret(f) or f == "" or f == "Neutral" then return nil end
	return U.CleanText(f, 20)
end

-- Roles with a count above 0 and wanted classes, in the fixed order.
local function NeedWords(need, cls)
	local roles, classes = {}, {}
	for _, r in ipairs(GH.RECRUIT_ROLES or { "t", "h", "d" }) do
		if type(need) == "table" and type(need[r]) == "number" and need[r] > 0 then roles[#roles + 1] = L.ADB_ROLE[r] end
	end
	for _, c in ipairs(GH.RECRUIT_CLASSES or {}) do
		if type(cls) == "table" and cls[c] == 1 then classes[#classes + 1] = ClassName(c) end
	end
	return roles, classes
end

------------------------------------------------------------------------
-- The one-liner (for Post). Returns text, nil, left-out parts | nil, why.
------------------------------------------------------------------------
local function Line(f, roles, classes, guild, faction, drop)
	local parts = {}
	local head = guild and ("<" .. guild .. ">") or nil
	if head and faction then head = head .. " (" .. faction .. ")" elseif not head then head = faction end
	local lf = {}
	for _, w in ipairs(roles) do lf[#lf + 1] = w end
	if not drop.classes then for _, w in ipairs(classes) do lf[#lf + 1] = w end end
	local want = #lf > 0 and L.ADB_LF:format(table.concat(lf, ", ")) or L.ADB_RECRUITING
	parts[#parts + 1] = head and (head .. " " .. want) or want -- "<Dawn> (Alliance) LF Healer, Priest"
	if f.lvl then parts[#parts + 1] = L.ADB_LEVEL:format(L.ADB_LVL_V[f.lvl]) end
	local days = GH:AdDaysText(f.days, "/")
	local at = GH:AdTimeText(f.at)
	if days or at then
		local when = {}
		if days then when[#when + 1] = days end
		if at then when[#when + 1] = at .. " " .. L.ADB_TZ_SHORT[f.tz or "st"] end
		parts[#parts + 1] = L.ADB_RAIDS:format(table.concat(when, " "))
	end
	if f.size and not drop.size then parts[#parts + 1] = L.ADB_SIZE_V:format(f.size) end
	if f.loot then parts[#parts + 1] = L.ADB_LOOT_V[f.loot] end
	if f.style and not drop.style then parts[#parts + 1] = L.ADB_STYLE_V[f.style] end
	parts[#parts + 1] = L.ADB_WHISPER
	return table.concat(parts, L.ADB_SEP)
end

-- f = the fields, need / cls = We need (a draft or the saved record). Nothing is sent.
function GH:BuildAdLine(f, need, cls)
	f = self:CleanAdFields(f) or {}
	local roles, classes = NeedWords(need, cls)
	local guild, faction = GuildName(), Faction()
	local drop, left = {}, {}
	local i = 0
	while true do
		local text, why = self:CleanAd(Line(f, roles, classes, guild, faction, drop))
		if text then return text, nil, left end
		if why ~= "long" then return nil, why end
		-- too long: leave out the least important part that is there
		local cut
		repeat
			i = i + 1
			local k = DROP_ORDER[i]
			if k == nil then return nil, "long" end
			local present = (k == "classes" and #classes > 0) or (k ~= "classes" and f[k] ~= nil)
			if present then cut = k end
		until cut
		drop[cut] = true
		left[#left + 1] = L.ADB_DROP[cut]
	end
end

------------------------------------------------------------------------
-- The long post (Copy box only; no member names, never sent)
------------------------------------------------------------------------
-- p = nil: the saved record (We need only while it hasn't expired); or a draft view
-- { f, need, cls, ad, dc } (the Ad builder page's preview).
function GH:BuildLongPost(p)
	local need, cls
	if type(p) == "table" then
		need, cls = p.need, p.cls
	else
		p = self:RecruitPub()
		need, cls = self:RecruitNeeds()
	end
	local f = self:CleanAdFields(p.f) or {}
	local lines = {}
	local guild, faction = GuildName(), Faction()
	if guild then lines[#lines + 1] = faction and L.ADB_L_HEAD:format(guild, faction) or ("<" .. guild .. ">") end
	local days = self:AdDaysText(f.days, ", ")
	if days then lines[#lines + 1] = L.ADB_L_RAIDS:format(days) end
	if f.at then lines[#lines + 1] = L.ADB_L_AT:format(self:AdTimeText(f.at), L.ADB_TZ_V[f.tz or "st"]) end
	if f.size then lines[#lines + 1] = L.ADB_L_SIZE:format(f.size) end
	if f.loot then lines[#lines + 1] = L.ADB_L_LOOT:format(L.ADB_LOOT_V[f.loot]) end
	if f.style then lines[#lines + 1] = L.ADB_L_STYLE:format(L.ADB_STYLE_V[f.style]) end
	if f.lvl then lines[#lines + 1] = L.ADB_L_LVL:format(L.ADB_LVL_V[f.lvl]) end
	if type(need) == "table" then
		local roles = {}
		for _, r in ipairs(self.RECRUIT_ROLES) do
			if (need[r] or 0) > 0 then roles[#roles + 1] = need[r] .. " " .. L.ADB_ROLE[r] end
		end
		if #roles > 0 then lines[#lines + 1] = L.ADB_L_NEED:format(table.concat(roles, ", ")) end
		local wanted, closed = {}, {}
		for _, c in ipairs(self.RECRUIT_CLASSES) do
			if type(cls) == "table" and cls[c] == 1 then wanted[#wanted + 1] = ClassName(c) end
			if type(cls) == "table" and cls[c] == 2 then closed[#closed + 1] = ClassName(c) end
		end
		if #wanted > 0 then lines[#lines + 1] = L.ADB_L_WANTED:format(table.concat(wanted, ", ")) end
		if #closed > 0 then lines[#lines + 1] = L.ADB_L_CLOSED:format(table.concat(closed, ", ")) end
	end
	if p.ad then
		lines[#lines + 1] = ""
		lines[#lines + 1] = p.ad
	end
	if p.dc then
		lines[#lines + 1] = ""
		lines[#lines + 1] = L.ADB_L_DC:format(p.dc)
	end
	return table.concat(lines, "\n")
end

-- What the ad is missing (own screen only): a list of words, empty when nothing is missing.
function GH:AdHints(f)
	f = self:CleanAdFields(f) or {}
	local miss = {}
	if not f.days then miss[#miss + 1] = L.ADB_HINT_DAYS end
	if not f.at then miss[#miss + 1] = L.ADB_HINT_TIME end
	if not f.loot then miss[#miss + 1] = L.ADB_HINT_LOOT end
	return miss
end

------------------------------------------------------------------------
-- Self-test part (called by the recruit feature's selftest)
------------------------------------------------------------------------
function GH:RecruitAdsSelfTest(api)
	-- the saved fields pass their lists
	api.Count()
	local p = self:RecruitPub()
	if p.f ~= nil then
		local c = self:CleanAdFields(p.f)
		for k, v in pairs(p.f) do
			if not c or c[k] ~= v then api.Problem("RECRUIT", "adfields", "saved field " .. tostring(k) .. " isn't on its list") break end
		end
	end
	-- every field at its longest, every role and class: the built line still passes the ad checks
	api.Count()
	local long = { size = 40, days = 127 - 64, at = 47, tz = "usw", loot = "lc", style = "comp", lvl = "55" }
	local need, cls = { t = 9, h = 9, d = 9 }, {}
	for _, c in ipairs(self.RECRUIT_CLASSES) do cls[c] = 1 end
	local text, why = self:BuildAdLine(long, need, cls)
	if not text or self:CleanAd(text) ~= text then api.Problem("RECRUIT", "adbuild", "longest ad doesn't pass: " .. tostring(why)) end
	-- the current fields build a usable line too
	api.Count()
	local cur, whyCur = self:BuildAdLine(p.f, self:RecruitNeeds())
	if not cur and whyCur ~= "word" then api.Problem("RECRUIT", "adbuild", "the saved fields don't build: " .. tostring(whyCur)) end
	-- the long post holds no guild member's name
	api.Count()
	local post = self:BuildLongPost()
	local guild = GuildName()
	for name in pairs(self.roster or {}) do
		local short = U.ShortName(name)
		if #short >= 4 and post:find(short, 1, true) and not (guild and guild:find(short, 1, true)) and not (p.ad and p.ad:find(short, 1, true)) then
			api.Problem("RECRUIT", "longpost", "a member's name in the long post") break
		end
	end
	local n = 0
	for _ in pairs(self:CleanAdFields(p.f) or {}) do n = n + 1 end
	api.Info(("recruit adb fields=%d longest=%s letters=%d hints=%d"):format(n, text and "ok" or "no",
		text and self.AdLetters(text) or 0, #self:AdHints(p.f)))
end
