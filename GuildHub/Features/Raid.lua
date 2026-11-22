-- Guild Hub: raid check data (1.0.1, plans\next-batch-1.0.x; tos: plans\next-batch-1.0.x\tos-check.md and
-- plans\guild-addons-research\tos-check.md). Feature "raid" (switchable): the Boards tab's Raid page.
-- Own character only, read out of combat, shared in the bundle record (Features.lua: REC with the changed
-- fields, at most every 30 s) when a value changes; each field can be switched off (What I share > Raid
-- info). Fair trade: whoever doesn't share Raid info sees no one's (the Makeup view stays open: guild list).
--   ro  role(s) set by hand: "t", "h", "d" or two of them ("th")          (never guessed: no specs on Forever)
--   at  Onyxia attunement: faction letter + steps done ("a7", "h14")      (C_QuestLog.IsQuestFlaggedCompleted)
--   lk  raid lockouts: "" or "d.killed.bosses.resetBase36" joined by ","  (GetSavedInstanceInfo)
--   rs  resistances fire.nature.frost.shadow.arcane (character sheet)     (UnitResistance; 60 s debounce)
--   du  lowest durability in 10 % steps                                   (GetInventoryItemDurability)
--   rg  own class reagent count (cap 99; -1 = this class needs none)       (C_Item.GetItemCount; 60 s debounce)
-- Nothing here sends a whisper, invites, inspects anyone or acts by itself. LoggingCombat(true) only from
-- the "Start logging" click (A10), shown only while the game says LoggingCombat is Blizzard's normal function.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local floor = math.floor

------------------------------------------------------------------------
-- Data tables
------------------------------------------------------------------------
-- WoW Forever's raids (report-2.md): d = the GH.DUNGEONS number (sent; never changes). outside = the
-- zone(s) of the raid's entrance (summon queue); BD and Hyjal Summit are both in Mount Hyjal.
GH.RAIDS = {
	{ d = 23, key = "ony", name = "Onyxia's Lair", size = 40, outside = { "Dustwallow Marsh" } },
	{ d = 38, key = "hyjal", name = "Hyjal Summit", size = 20, outside = { "Mount Hyjal" } },
	{ d = 37, key = "bd", name = "Barrow Deeps", size = 10, outside = { "Mount Hyjal" } },
}
local RAID_BY_D, RAID_BY_NAME = {}, {}
for _, r in ipairs(GH.RAIDS) do RAID_BY_D[r.d] = r; RAID_BY_NAME[r.name] = r end
GH.RAID_BY_D, GH.RAID_BY_NAME = RAID_BY_D, RAID_BY_NAME

-- Onyxia attunement chains, in order (quest IDs checked on warcraft.wiki.gg "Onyxia's Lair attunement" and
-- the quest pages, 2026-11-22; the last one = attuned). Barrow Deeps / Hyjal Summit: not known yet (D6).
GH.ATTUNE = {
	a = { 4182, 4183, 4184, 4185, 4186, 4223, 4224, 4241, 4242, 4264, 4282, 4322, 6402, 6403, 6501, 6502 },
	h = { 4903, 4941, 4974, 6566, 6567, 6568, 6569, 6570, 6582, 6583, 6584, 6585, 6601, 6602 },
}

-- One reagent per class (D5; IDs confirmed in game by the `reag` probe). Warriors and hunters: none.
GH.REAGENTS = {
	MAGE = 17020,    -- Arcane Powder
	PRIEST = 17029,  -- Sacred Candle
	DRUID = 17026,   -- Wild Thornroot
	PALADIN = 21177, -- Symbol of Kings
	SHAMAN = 17030,  -- Ankh
	WARLOCK = 6265,  -- Soul Shard
	ROGUE = 5140,    -- Flash Powder
}

GH.RAID_FIELDS = { "at", "lk", "rs", "du", "rg" } -- the per-field switches (ro is part of Raid info too)
local DEBOUNCE = { rs = 60, rg = 60 }               -- seconds between two sends of these fields
local SCAN_SECONDS = 5
local ROLE_OK = { t = true, h = true, d = true }
local RESIST_SCHOOLS = { 2, 3, 4, 5, 6 }            -- fire, nature, frost, shadow, arcane (UnitResistance index)
local MAX_LOCKS, MAX_BOSSES = 3, 20

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function ToB36(n)
	n = floor(n)
	if n <= 0 then return "0" end
	local s = ""
	while n > 0 do
		local r = n % 36
		s = B36:sub(r + 1, r + 1) .. s
		n = floor(n / 36)
	end
	return s
end
GH.ToB36 = ToB36

local function Plain(v) return v ~= nil and not U.IsSecret(v) end

local function Safe(fn, ...)
	if type(fn) ~= "function" then return false end
	return pcall(fn, ...)
end

local function Char() return GH.db and GH.db.char end

local function ShareTable()
	local c = Char()
	if not c then return {} end
	if type(c.raidShare) ~= "table" then c.raidShare = {} end
	return c.raidShare
end

-- Raid info shared at all (the What I share line). Default: on.
function GH:SharesRaid()
	return ShareTable().all ~= false
end

-- One field shared? (Raid info on, the field not switched off.)
function GH:RaidFieldShared(field)
	if not self:SharesRaid() then return false end
	return ShareTable()[field] ~= false
end

function GH:SetRaidField(field, on)
	local t = ShareTable()
	if on then t[field] = nil else t[field] = false end -- (not on) and false or nil would always give nil
	self:RaidFieldChanged(field, true)
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
end

------------------------------------------------------------------------
-- Own values
------------------------------------------------------------------------
function GH:OwnRole()
	local c = Char()
	local r = c and c.role
	if type(r) ~= "string" then return nil end
	return self:CleanRole(r)
end

function GH:CleanRole(r)
	if type(r) ~= "string" or U.IsSecret(r) or #r < 1 or #r > 2 then return nil end
	local seen, out = {}, ""
	for ch in r:gmatch(".") do
		if not ROLE_OK[ch] or seen[ch] then return nil end
		seen[ch] = true
		out = out .. ch
	end
	return out
end

-- Toggle one role (t/h/d) on this character; at most 2 (D3).
function GH:ToggleRole(role)
	if not ROLE_OK[role] then return end
	local cur = self:OwnRole() or ""
	if cur:find(role, 1, true) then
		cur = cur:gsub(role, "")
	elseif #cur < 2 then
		cur = cur .. role
	else
		return false -- already two
	end
	Char().role = cur ~= "" and cur or nil
	self:RaidFieldChanged("ro", true)
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
	return true
end

local function Faction()
	local ok, f = Safe(UnitFactionGroup, "player")
	if not ok or not Plain(f) then return nil end
	if f == "Alliance" then return "a" elseif f == "Horde" then return "h" end
	return nil
end

-- "a7": faction + the number of steps done (counted from the end: the last done step wins, so a
-- skipped or unknown early quest doesn't hide progress).
function GH:OwnAttune()
	local fac = Faction()
	local chain = fac and self.ATTUNE[fac]
	local done = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted or IsQuestFlaggedCompleted
	if not chain or type(done) ~= "function" then return nil end
	for i = #chain, 1, -1 do
		local ok, v = pcall(done, chain[i])
		if ok and Plain(v) and v == true then return fac .. i end
	end
	return fac .. "0"
end

-- Lockouts from the game's raid info: "" (none) or entries for our 3 raids.
function GH:OwnLockouts()
	local okN, n = Safe(GetNumSavedInstances)
	if not okN or type(n) ~= "number" or not Plain(n) then return nil end
	local list, now = {}, U.Now()
	for i = 1, math.min(n, 50) do
		local ok, name, _, reset, _, locked, _, _, isRaid, _, _, numEnc, encProg, _, instId = Safe(GetSavedInstanceInfo, i)
		if ok and Plain(name) and Plain(reset) and Plain(locked) and locked and type(reset) == "number" and reset > 0 then
			local raid = (type(instId) == "number" and Plain(instId) and self.INSTANCE_BY_ID and self.INSTANCE_BY_ID[instId]
				and RAID_BY_NAME[self.INSTANCE_BY_ID[instId].name]) or RAID_BY_NAME[name]
			if raid and (isRaid == nil or not Plain(isRaid) or isRaid) and #list < MAX_LOCKS then
				local nb = type(numEnc) == "number" and Plain(numEnc) and math.max(0, math.min(MAX_BOSSES, floor(numEnc))) or 0
				local kp = type(encProg) == "number" and Plain(encProg) and math.max(0, math.min(nb, floor(encProg))) or 0
				-- rounded to 5 min: "now + seconds left" moves by a second between reads, which would make
				-- the field change (and send a REC) at every scan; raid resets fall on whole hours anyway
				local at = floor((now + reset + 150) / 300) * 300
				list[#list + 1] = ("%d.%d.%d.%s"):format(raid.d, kp, nb, ToB36(at))
			end
		end
	end
	table.sort(list)
	return table.concat(list, ",")
end

function GH:OwnResist()
	if type(UnitResistance) ~= "function" then return nil end
	local parts = {}
	for _, i in ipairs(RESIST_SCHOOLS) do
		local ok, _, total = pcall(UnitResistance, "player", i)
		if not ok or type(total) ~= "number" or not Plain(total) then return nil end
		parts[#parts + 1] = tostring(math.max(0, math.min(999, floor(total))))
	end
	return table.concat(parts, ".")
end

-- Lowest durability of the equipped items, in 10 % steps (100 = nothing damaged).
function GH:OwnDurability()
	if type(GetInventoryItemDurability) ~= "function" then return nil end
	local low, any = 100, false
	for slot = 1, 18 do
		local ok, cur, max = pcall(GetInventoryItemDurability, slot)
		if ok and type(cur) == "number" and type(max) == "number" and Plain(cur) and Plain(max) and max > 0 then
			any = true
			low = math.min(low, cur / max * 100)
		end
	end
	if not any then return 100 end
	return math.max(0, math.min(100, floor(low / 10) * 10))
end

local function ClassToken()
	local ok, _, token = Safe(UnitClass, "player")
	if ok and Plain(token) then return token end
	return nil
end

-- Own class reagent: count (cap 99), -1 = this class needs none, nil = can't read.
function GH:OwnReagents()
	local id = self.REAGENTS[ClassToken() or ""]
	if not id then return -1 end
	local count = C_Item and C_Item.GetItemCount or GetItemCount
	local ok, n = Safe(count, id)
	if not ok or type(n) ~= "number" or not Plain(n) then return nil end
	return math.max(0, math.min(99, floor(n)))
end

------------------------------------------------------------------------
-- Cleaning received values (each returns the clean value or nil)
------------------------------------------------------------------------
local Clean = {}
GH.RaidClean = Clean

Clean.ro = function(v) return GH:CleanRole(v) end

Clean.at = function(v)
	if type(v) ~= "string" or U.IsSecret(v) or #v > 3 then return nil end
	local fac, n = v:match("^([ah])(%d%d?)$")
	n = tonumber(n)
	if not fac or not n or n > #GH.ATTUNE[fac] then return nil end
	return fac .. n
end

Clean.lk = function(v)
	if type(v) ~= "string" or U.IsSecret(v) or #v > 60 then return nil end
	if v == "" then return "" end
	local out, seen = {}, {}
	for part in v:gmatch("[^,]+") do
		local d, k, n, ts = part:match("^(%d+)%.(%d+)%.(%d+)%.(%w+)$")
		d, k, n = tonumber(d), tonumber(k), tonumber(n)
		local t = ts and tonumber(ts, 36)
		if not (d and RAID_BY_D[d] and k and n and t) or seen[d] or n > MAX_BOSSES or k > n then return nil end
		if t < 1577836800 or t > U.Now() + 15 * 86400 then return nil end -- a reset more than 15 days ahead is wrong
		seen[d] = true
		out[#out + 1] = ("%d.%d.%d.%s"):format(d, k, n, ts:lower())
		if #out > MAX_LOCKS then return nil end
	end
	if #out == 0 then return nil end
	return table.concat(out, ",")
end

Clean.rs = function(v)
	if type(v) ~= "string" or U.IsSecret(v) or #v > 19 then return nil end
	local a, b, c, d, e = v:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not e then return nil end
	for _, x in ipairs({ a, b, c, d, e }) do if #x > 3 then return nil end end
	return v
end

Clean.du = function(v)
	local n = U.ValidNumber(v, 0, 100)
	if not n or n % 10 ~= 0 then return nil end
	return n
end

Clean.rg = function(v)
	local n = U.ValidNumber(v, -1, 99)
	if not n or n ~= floor(n) then return nil end
	return n
end

-- Parsed lockouts: { [d] = { k, n, reset } }
function GH:ParseLockouts(lk)
	local r = {}
	if type(lk) ~= "string" then return r end
	for part in lk:gmatch("[^,]+") do
		local d, k, n, ts = part:match("^(%d+)%.(%d+)%.(%d+)%.(%w+)$")
		d = tonumber(d)
		if d then r[d] = { k = tonumber(k), n = tonumber(n), reset = tonumber(ts, 36) } end
	end
	return r
end

function GH:ParseResist(rs)
	if type(rs) ~= "string" then return nil end
	local t = {}
	for x in rs:gmatch("%d+") do t[#t + 1] = tonumber(x) end
	if #t ~= 5 then return nil end
	t.total = t[1] + t[2] + t[3] + t[4] + t[5]
	return t
end

-- "done", steps, total / "next", step, total / "none", 0, total
function GH:AttuneState(at)
	if type(at) ~= "string" then return nil end
	local fac, n = at:match("^([ah])(%d+)$")
	n = tonumber(n)
	local chain = fac and self.ATTUNE[fac]
	if not chain or not n then return nil end
	if n >= #chain then return "done", n, #chain end
	if n == 0 then return "none", 0, #chain end
	return "next", n + 1, #chain
end

------------------------------------------------------------------------
-- Reset times seen (own and shared lockouts): gdb.raidReset[d] = server time; past ones dropped
------------------------------------------------------------------------
local function ResetTable()
	local gdb = GH:GetGuildDB()
	if not gdb then return nil end
	if type(gdb.raidReset) ~= "table" then gdb.raidReset = {} end
	return gdb.raidReset
end

function GH:NoteResets(lk)
	local t = ResetTable()
	if not t then return end
	local now = U.Now()
	for d, e in pairs(self:ParseLockouts(lk)) do
		if RAID_BY_D[d] and type(e.reset) == "number" and e.reset > now and e.reset < now + 15 * 86400 then
			if not t[d] or t[d] <= now or e.reset > t[d] then t[d] = e.reset end
		end
	end
end

-- Seconds to the next reset of raid d, or nil (not known yet).
function GH:RaidResetIn(d)
	local t = ResetTable()
	if not t then return nil end
	local now = U.Now()
	for k, v in pairs(t) do
		if not RAID_BY_D[k] or type(v) ~= "number" or v <= now then t[k] = nil end
	end
	local v = t[d]
	return v and (v - now) or nil
end

------------------------------------------------------------------------
-- Sending: values are read on events / every 5 s out of combat; a changed value goes out through
-- BundleChanged (REC, at most every 30 s); rs and rg at most every 60 s.
------------------------------------------------------------------------
local lastValue, lastSent, dirty = {}, {}, {}
GH.raidLastValue = lastValue

local READERS = {
	at = function(gh) return gh:OwnAttune() end,
	lk = function(gh) return gh:OwnLockouts() end,
	rs = function(gh) return gh:OwnResist() end,
	du = function(gh) return gh:OwnDurability() end,
	rg = function(gh) return gh:OwnReagents() end,
}

-- The bundle's get(): the last value read, only while shared.
local function Getter(field)
	return function()
		if not GH:FeatureOn("raid") or not GH:RaidFieldShared(field) then return nil end
		if field == "ro" then return GH:OwnRole() end
		return lastValue[field]
	end
end

function GH:RaidFieldChanged(field, now)
	dirty[field] = true
	if now then self:RaidScan(true) end
end

-- Reads the own values (never in combat) and shares what changed.
function GH:RaidScan(force)
	if not self:FeatureOn("raid") then return end
	if InCombatLockdown and InCombatLockdown() then return end
	local t = GetTime()
	for field, read in pairs(READERS) do
		local ok, v = pcall(read, self)
		if ok and v ~= nil and v ~= lastValue[field] then
			lastValue[field] = v
			dirty[field] = true
		end
	end
	if lastValue.lk then self:NoteResets(lastValue.lk) end
	for field in pairs(dirty) do
		local gap = DEBOUNCE[field]
		if force or not gap or not lastSent[field] or t - lastSent[field] >= gap then
			dirty[field] = nil
			lastSent[field] = t
			if self.BundleChanged then self:BundleChanged(field) end
		end
	end
end

-- Lockouts are read on login and after leaving a raid only (D: no constant checks).
local wasInRaid = false
local function OnZone()
	local ok, inInst, kind = Safe(IsInInstance)
	local inRaid = ok and Plain(inInst) and inInst and kind == "raid" or false
	if wasInRaid and not inRaid and type(RequestRaidInfo) == "function" then pcall(RequestRaidInfo) end
	wasInRaid = inRaid and true or false
	if GH.LoggerStateChanged then GH:LoggerStateChanged() end
end

-- Events only mark "read again soon"; the 5-s scan reads (never in combat) and sends what changed.
local function OnEvent()
	if GH.apiTestRunning then return end -- /ghub test api's own reads cause no send (read at the next minute)
	GH.raidScanSoon = true
end

function GH:InitRaid()
	if self.raidStarted then return end
	self.raidStarted = true
	for _, e in ipairs({ "UPDATE_INSTANCE_INFO", "QUEST_TURNED_IN", "UPDATE_INVENTORY_DURABILITY", "BAG_UPDATE_DELAYED",
		"UNIT_RESISTANCES", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_REGEN_ENABLED" }) do
		self:On("raid", e, OnEvent)
	end
	self:On("raid", "ZONE_CHANGED_NEW_AREA", OnZone)
	self:On("raid", "PLAYER_ENTERING_WORLD", OnZone)
	local lastFull = GetTime()
	self:Every("raid", "scan", SCAN_SECONDS, function()
		-- read only after an event, while a debounced field waits, or once a minute
		local t = GetTime()
		if not GH.raidScanSoon and next(dirty) == nil and t - lastFull < 60 then return end
		if InCombatLockdown and InCombatLockdown() then return end
		GH.raidScanSoon = nil
		lastFull = t
		GH:RaidScan()
	end)
	-- one raid-info read at start-up (a harmless read: plan.md sec. 5 tos list)
	self:ScheduleTimer(function()
		if GH.raidStarted and type(RequestRaidInfo) == "function" then pcall(RequestRaidInfo) end
	end, 15)
	OnZone()
	self:RaidScan()
	if self.InitRaidNight then self:InitRaidNight() end -- Features\RaidNight.lua
end

function GH:StopRaid()
	self.raidStarted = nil
	self:Off("raid")
	self:Cancel("raid")
	if self.StopRaidNight then self:StopRaidNight() end
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
end

------------------------------------------------------------------------
-- Rows for the Raid page (plain tables; the UI only draws them)
------------------------------------------------------------------------
local function MemberBundle(gh, name)
	if name == gh:MyName() then
		local b = {}
		for _, f in ipairs({ "ro", "at", "lk", "rs", "du", "rg", "tk" }) do
			local def = gh.features.raid.bundle[f]
			if def then b[f] = def.get() end
		end
		return b
	end
	local gdb = gh:GetGuildDB()
	local m = gdb and gdb.members[name]
	return m and type(m.b) == "table" and m.b or nil, m
end

local function HasRaidData(b)
	if type(b) ~= "table" then return false end
	return b.ro ~= nil or b.at ~= nil or b.lk ~= nil or b.rs ~= nil or b.du ~= nil or b.rg ~= nil or b.tk ~= nil
end

-- opts = { search, only60, hideOffline }. Rows carry the parsed fields; a nil field = not shared /
-- no data; row.state = "addon" (has raid data), "old" (Guild Hub without these fields), "none".
function GH:BuildRaidRows(opts)
	opts = opts or {}
	local q = type(opts.search) == "string" and opts.search:lower() or ""
	local me = self:MyName()
	local rows = {}
	for name, r in pairs(self.roster) do
		local lvl = (name == me and UnitLevel("player")) or r.level
		local okLvl = type(lvl) == "number" and Plain(lvl)
		local show = (not opts.only60 or (okLvl and lvl >= 60)) and (not opts.hideOffline or r.online or name == me)
		if show and (q == "" or U.ShortName(name):lower():find(q, 1, true)) then
			local b, m = MemberBundle(self, name)
			local row = { name = name, class = r.class, level = okLvl and lvl or nil, online = r.online, isSelf = name == me,
				zone = (name == me and self.LiveZone and self:LiveZone()) or (Plain(r.zone) and r.zone or nil) }
			if HasRaidData(b) or name == me then
				row.state = "addon"
				row.role = Clean.ro(b and b.ro)
				row.at = b and Clean.at(b.at)
				row.attune, row.step, row.steps = self:AttuneState(row.at)
				row.lk = b and b.lk ~= nil and self:ParseLockouts(b.lk) or nil
				row.res = b and self:ParseResist(b.rs) or nil
				row.du = b and Clean.du(b.du)
				row.rg = b and Clean.rg(b.rg)
				row.tk = b and tonumber(b.tk) or nil
			elseif m and (m.version or self:IsAddonUserOnline(name)) then
				row.state = "old"
			else
				row.state = "none"
			end
			rows[#rows + 1] = row
		end
	end
	return rows
end

-- Makeup: { [CLASS] = { t, h, d, u, total } }, totals, members counted. lvlMin 60 or 50.
GH.RAID_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
function GH:RaidMakeup(lvlMin)
	lvlMin = lvlMin or 60
	local t, all = {}, { t = 0, h = 0, d = 0, u = 0, total = 0 }
	for _, c in ipairs(self.RAID_CLASSES) do t[c] = { t = 0, h = 0, d = 0, u = 0, total = 0 } end
	local me = self:MyName()
	for name, r in pairs(self.roster) do
		local c = type(r.class) == "string" and t[r.class]
		local lvl = (name == me and UnitLevel("player")) or r.level
		if c and type(lvl) == "number" and Plain(lvl) and lvl >= lvlMin then
			local b = MemberBundle(self, name)
			local role = Clean.ro(b and b.ro)
			local k = role and role:sub(1, 1) or "u" -- the first role counts (each member once)
			c[k] = c[k] + 1
			c.total = c.total + 1
			all[k] = all[k] + 1
			all.total = all.total + 1
		end
	end
	return t, all
end

------------------------------------------------------------------------
-- A10 logger reminder: only inside a raid, only while the game's LoggingCombat is its own normal
-- function (the `logging` probe's test, read live), never after the game blocked it once.
------------------------------------------------------------------------
local loggingOn -- cached on the event (no polling: tos)
function GH:LoggerAllowed()
	if self.db and self.db.profile.loggerBlocked then return false, "blocked" end
	if type(LoggingCombat) ~= "function" then return false, "missing" end
	if type(issecurevariable) == "function" then
		local ok, sec = pcall(issecurevariable, "LoggingCombat")
		if not ok or not sec then return false, "replaced" end
	end
	if not (C_ChatInfo and type(C_ChatInfo.IsLoggingCombat) == "function") then return false, "noread" end
	return true
end

function GH:LoggerStateChanged()
	if C_ChatInfo and type(C_ChatInfo.IsLoggingCombat) == "function" then
		local ok, on = pcall(C_ChatInfo.IsLoggingCombat)
		if ok and Plain(on) then loggingOn = on and true or false end
	end
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
end

-- Show the reminder line now? (in a raid instance, allowed, logging off)
function GH:LoggerReminder()
	if not self:FeatureOn("raid") then return false end
	local ok, inInst, kind = Safe(IsInInstance)
	if not (ok and Plain(inInst) and inInst and kind == "raid") then return false end
	if not self:LoggerAllowed() then return false end
	if loggingOn == nil then self:LoggerStateChanged() end
	return loggingOn == false
end

-- The "Start logging" click (the only caller of LoggingCombat; tos A10).
function GH:StartLogging()
	if not self:LoggerAllowed() or (InCombatLockdown and InCombatLockdown()) then return false end
	self.loggerClicks = (self.loggerClicks or 0) + 1
	local blockedBefore = self.actionBlocked and self.actionBlocked.n or 0
	local ok = pcall(LoggingCombat, true)
	local blockedAfter = self.actionBlocked and self.actionBlocked.n or 0
	if not ok or blockedAfter > blockedBefore then
		self.db.profile.loggerBlocked = true -- the game said no: never offered again
		self:Msg(L.RAID_LOG_BLOCKED)
		if self.RefreshBoardsTab then self:RefreshBoardsTab() end
		return false
	end
	loggingOn = true
	self:Msg(L.RAID_LOG_STARTED)
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
	return true
end

------------------------------------------------------------------------
-- Saved data repair (Store.lua RepairSaved calls this): char.role, raidShare, raidTicks, rezAvail,
-- hearthShare; profile.raidView, raidSort, newInSeen. Broken = back to "not set" (never turns sharing on).
------------------------------------------------------------------------
function GH:RepairRaidSaved(db)
	local fixed = {}
	local c = db and db.char
	if type(c) ~= "table" then return fixed end
	local role = rawget(c, "role")
	if role ~= nil and not self:CleanRole(role) then c.role = nil; fixed[#fixed + 1] = "role" end
	for _, k in ipairs({ "rezAvail", "hearthShare" }) do
		local v = rawget(c, k)
		if v ~= nil and type(v) ~= "boolean" then c[k] = nil; fixed[#fixed + 1] = k end
	end
	local tk = rawget(c, "raidTicks")
	if tk ~= nil and (type(tk) ~= "table" or type(tk.v) ~= "number" or type(tk.ts) ~= "number" or tk.v ~= tk.v) then
		c.raidTicks = nil
		fixed[#fixed + 1] = "raidTicks"
	end
	local rs = rawget(c, "raidShare")
	if rs ~= nil then
		if type(rs) ~= "table" then
			c.raidShare = {}
			fixed[#fixed + 1] = "raidShare"
		else
			for k, v in pairs(rs) do
				if type(k) ~= "string" or v ~= false then rs[k] = nil; fixed[#fixed + 1] = "raidShare." .. tostring(k) end
			end
		end
	end
	local p = db.profile
	if type(p) == "table" then
		local okView = { ready = true, lockouts = true, resist = true, makeup = true, tonight = true }
		if p.raidView ~= nil and not okView[p.raidView] then p.raidView = "ready"; fixed[#fixed + 1] = "raidView" end
		if p.raidSort ~= nil and (type(p.raidSort) ~= "table" or type(p.raidSort.key) ~= "string") then
			p.raidSort = { key = "durability" }
			fixed[#fixed + 1] = "raidSort"
		end
		if p.newInSeen ~= nil and not U.ValidVersion(p.newInSeen) then p.newInSeen = nil; fixed[#fixed + 1] = "newInSeen" end
	end
	return fixed
end

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------
local function Field(name, prio)
	return { get = Getter(name), clean = Clean[name], prio = prio }
end

GH:RegisterFeature({
	key = "raid", name = "OPT_FEAT_RAID",
	defaults = {
		profile = { raidView = "ready", raidSort = { key = "durability" }, raidOnly60 = true, raidHideOffline = true,
			raidMakeup60 = true, newInCard = true, loggerBlocked = false },
	},
	enable = function() GH:InitRaid() end,
	disable = function() GH:StopRaid() end,
	-- bundle fields (prio: when the bundle would be too big, the lowest prio is left out first)
	bundle = {
		ro = Field("ro", 8),
		at = Field("at", 6),
		du = Field("du", 5),
		rg = Field("rg", 4),
		rs = Field("rs", 3),
		lk = { get = Getter("lk"), clean = Clean.lk, prio = 2, store = function(_, v) if v then GH:NoteResets(v) end end },
	},
	selftest = function(api) if GH.RaidSelfTest then GH:RaidSelfTest(api) end end,
})

-- Fair trade: no Raid info shared = no one's Raid info shown to you (Makeup stays: guild list).
GH:RegisterShare({
	key = "raid", order = 4, optKey = "shareRaid", feature = "raid",
	name = "OPT_SHARERAID", desc = "OPT_SHARERAID_DESC",
	get = function(gh) return gh:SharesRaid() end,
	set = function(gh, on)
		local st = ShareTable()
		if on then st.all = nil else st.all = false end
		for _, f in ipairs({ "ro", "at", "lk", "rs", "du", "rg", "tk" }) do dirty[f] = true end
		gh:RaidScan(true)
		if gh.RefreshBoardsTab then gh:RefreshBoardsTab() end
	end,
})

-- The largest values each field can have (self-test and fake tests: the bundle must stay <= BUNDLE_MAX).
function GH:RaidWorstBundle()
	local far = ToB36(U.Now() + 14 * 86400)
	return {
		ro = "th", at = "a16", du = 100, rg = 99, tk = 7, rs = "999.999.999.999.999",
		lk = ("23.19.20.%s,37.19.20.%s,38.19.20.%s"):format(far, far, far),
		hs = ("W"):rep(24),
	}
end

-- /ghub selftest (Features.lua CheckFeatures): bundle sizes, field cleaners, the info line.
function GH:RaidSelfTest(api)
	api.Count()
	local worst = self:RaidWorstBundle()
	local defs = self.BundleFields and self.BundleFields() or {}
	for f, v in pairs(worst) do
		local def = defs[f]
		if def and def.clean and def.clean(v) == nil then api.Problem("RAID", "clean." .. f, "drops its own largest value") end
	end
	local all = {}
	for f, def in pairs(defs) do
		local ok, v = pcall(def.get)
		all[f] = worst[f] ~= nil and worst[f] or (ok and v or nil)
	end
	local worstSize = #self:Serialize(all)
	if worstSize > self.BUNDLE_MAX then
		api.Problem("RAID", "bundle", ("worst case %d B > %d"):format(worstSize, self.BUNDLE_MAX))
	end
	api.Count()
	local own = self:OwnBundle()
	local size = own and #self:Serialize(own) or 0
	if size > self.BUNDLE_MAX then api.Problem("RAID", "bundle", "own bundle over the limit") end
	local fields = {}
	for f in pairs(own or {}) do fields[#fields + 1] = f end
	table.sort(fields)
	local tab = self.boardsTab
	local tbl = tab and tab.table
	local logState = (self:LoggerAllowed() and (self:LoggerReminder() and "y" or "n")) or "hidden"
	local cal = self.calStats or {}
	api.Info(("raid view=%s cols=%d rows=%d bundle=%dB worst=%dB fields=%s drop=%s logbtn=%s cal=%d/%d/%d rez=%s newin=%s"):format(
		tostring(self.db.profile.raidView), tbl and #tbl.columns or 0, tbl and #(tbl.rows or {}) or 0, size, worstSize,
		#fields > 0 and table.concat(fields, ",") or "-", self.bundleDropped and table.concat(self.bundleDropped, ",") or "-",
		logState, cal.opens or 0, cal.closes or 0, cal.answers or 0,
		self.RezAvailable and (self:RezAvailable() and "y" or "n") or "-",
		self.db.profile.newInSeen == self.NEWIN_KEY and "seen" or (self.db.profile.newInCard == false and "off" or "due")))
end

-- Test hooks (fake suites): reset the session memory.
function GH:RaidResetMemory()
	wipe(lastValue); wipe(lastSent); wipe(dirty)
	loggingOn = nil
	wasInRaid = false
end
