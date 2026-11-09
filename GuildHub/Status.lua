-- Guild Hub: status board logic (step 2).
-- Own status (presets, note, LFG dungeon, 1-hour clear), automatic activity, the STATUS
-- message, LFG / Need help notes, and BuildStatusRows (plain row tables for the window;
-- no frames here, so it can be tested outside the game).
--
-- Notes are shown only on this computer (chat line + our own small note). Nothing here ever
-- sends chat, whispers, invites or anything else because of an incoming message.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local floor, abs, lower, find = math.floor, math.abs, string.lower, string.find

local STATUS_TTL    = 3600  -- presets and notes clear after 1 hour
local NOTE_MAX      = 80    -- bytes; the text box allows 60 letters
local ALERT_GAP     = 300   -- at most one note per player per 5 minutes
local LEVEL_RANGE   = 5     -- LFG notes only for players within 5 levels
local STICKY        = 5     -- a new activity must hold this long before it is shown and shared
local EVAL_SECONDS  = 5     -- backup check; events re-check exactly when the hold ends
-- (sending stays at most 1 STATUS per 10 s: MIN_INTERVAL.STATUS in Comm.lua merges quick changes)
local EXPIRY_SECONDS = 30   -- how often the 1-hour clear is checked
local NEW_SECONDS   = 20    -- a preset turned on this recently counts as "new" (may show a note)
local QUEST_WINDOW, XP_WINDOW, GATHER_WINDOW = 900, 600, 300

GH.STATUS_TTL = STATUS_TTL -- default; a status lasts 1, 2, 4 or 8 hours (field h)
GH.STATUS_HOURS = { 1, 2, 4, 8 }
local HOURS_OK = { [1] = true, [2] = true, [4] = true, [8] = true }
GH.NOTE_LETTERS = 60

GH.PRESETS = { "lfg", "help", "farm", "lvl", "busy", "chat" }
local PRESET_OK = {}
for _, p in ipairs(GH.PRESETS) do PRESET_OK[p] = true end
local ACT_OK = { afk = true, dng = true, raid = true, pvp = true, gath = true, fish = true, quest = true, lvl = true, town = true, inn = true }

-- Capital cities: resting here = "In town"; resting anywhere else = "At an inn" (you only get
-- rested in inns and capitals). Map IDs first (any language), zone names as backup.
-- Orgrimmar 1454 checked in game on Forever (Nov 8); the others are the Classic uiMapIDs, unconfirmed.
local CAPITAL_MAPS = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true }
local CAPITAL_NAMES = {
	["Stormwind City"] = true, ["Orgrimmar"] = true, ["Ironforge"] = true,
	["Thunder Bluff"] = true, ["Darnassus"] = true, ["Undercity"] = true,
}
GH.CAPITAL_MAPS, GH.CAPITAL_NAMES = CAPITAL_MAPS, CAPITAL_NAMES

function GH:InCapital()
	local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	if type(m) == "number" and not U.IsSecret(m) and CAPITAL_MAPS[m] then return true end
	local z = self:LiveZone()
	return z ~= nil and CAPITAL_NAMES[z] == true
end
local IMMEDIATE = { afk = true, dng = true, raid = true, pvp = true } -- shared at once, no 30-s wait

-- LFG dungeon picker. The numbers are sent in messages: never reorder, only add at the end.
GH.DUNGEONS = {
	{ name = "Ragefire Chasm", min = 13, max = 18 },
	{ name = "Wailing Caverns", min = 17, max = 24 },
	{ name = "The Deadmines", min = 17, max = 26 },
	{ name = "Shadowfang Keep", min = 22, max = 30 },
	{ name = "Blackfathom Deeps", min = 24, max = 32 },
	{ name = "The Stockade", min = 24, max = 32 },
	{ name = "Gnomeregan", min = 29, max = 38 },
	{ name = "Razorfen Kraul", min = 29, max = 38 },
	{ name = "Scarlet Monastery", min = 34, max = 45 },
	{ name = "Razorfen Downs", min = 37, max = 46 },
	{ name = "Uldaman", min = 41, max = 51 },
	{ name = "Zul'Farrak", min = 44, max = 54 },
	{ name = "Maraudon", min = 46, max = 55 },
	{ name = "Sunken Temple", min = 50, max = 56 },
	{ name = "Blackrock Depths", min = 52, max = 60 },
	{ name = "Lower Blackrock Spire", min = 55, max = 60 },
	{ name = "Upper Blackrock Spire", min = 58, max = 60 },
	{ name = "Dire Maul", min = 55, max = 60 },
	{ name = "Scholomance", min = 58, max = 60 },
	{ name = "Stratholme", min = 58, max = 60 },
	{ name = "Zul'Gurub", min = 60, max = 60, raid = true },
	{ name = "Molten Core", min = 60, max = 60, raid = true },
	{ name = "Onyxia's Lair", min = 60, max = 60, raid = true },
	{ name = "Ruins of Ahn'Qiraj", min = 60, max = 60, raid = true },
	{ name = "Blackwing Lair", min = 60, max = 60, raid = true },
	{ name = "Temple of Ahn'Qiraj", min = 60, max = 60, raid = true },
	{ name = "Naxxramas", min = 60, max = 60, raid = true },
}

-- Short names for the board row ("In a dungeon: RFC"). Keyed by instanceID, the 8th return of
-- GetInstanceInfo (IDs from warcraft.wiki.gg "InstanceID"; not all seen on Forever yet, so
-- Scarlet Monastery and Scholomance also list the modern IDs). Names are the English zone names
-- from the guild list, for senders on v0.1.2 that don't send the ID. "BRS" becomes LBRS / UBRS
-- by activity (party / raid). Only these short names or the game's own zone text are shown,
-- never text from a message.
local INSTANCES = {
	{ "RFC", { 389 }, { "Ragefire Chasm" } },
	{ "WC", { 43 }, { "Wailing Caverns" } },
	{ "DM", { 36 }, { "The Deadmines", "Deadmines" } },
	{ "SFK", { 33 }, { "Shadowfang Keep" } },
	{ "BFD", { 48 }, { "Blackfathom Deeps" } },
	{ "Stocks", { 34 }, { "The Stockade", "Stormwind Stockade" } },
	{ "Gnomer", { 90 }, { "Gnomeregan" } },
	{ "RFK", { 47 }, { "Razorfen Kraul" } },
	{ "SM", { 189, 1004, 1001 }, { "Scarlet Monastery", "Scarlet Halls" } },
	{ "RFD", { 129 }, { "Razorfen Downs" } },
	{ "Ulda", { 70 }, { "Uldaman" } },
	{ "ZF", { 209 }, { "Zul'Farrak" } },
	{ "Mara", { 349 }, { "Maraudon" } },
	{ "ST", { 109 }, { "Sunken Temple", "The Temple of Atal'Hakkar", "Temple of Atal'Hakkar" } },
	{ "BRD", { 230 }, { "Blackrock Depths" } },
	{ "BRS", { 229 }, { "Blackrock Spire", "Lower Blackrock Spire", "Upper Blackrock Spire" } },
	{ "Dire Maul", { 429 }, { "Dire Maul" } },
	{ "Scholo", { 289, 1007 }, { "Scholomance" } },
	{ "Strat", { 329 }, { "Stratholme" } },
	{ "MC", { 409 }, { "Molten Core" } },
	{ "Ony", { 249 }, { "Onyxia's Lair" } },
	{ "BWL", { 469 }, { "Blackwing Lair" } },
	{ "ZG", { 309 }, { "Zul'Gurub" } },
	{ "AQ20", { 509 }, { "Ruins of Ahn'Qiraj" } },
	{ "AQ40", { 531 }, { "Temple of Ahn'Qiraj", "Ahn'Qiraj Temple" } },
	{ "Naxx", { 533 }, { "Naxxramas" } },
}
local INST_BY_ID, INST_BY_NAME = {}, {}
for _, e in ipairs(INSTANCES) do
	local entry = { short = e[1], name = e[3][1] }
	for _, id in ipairs(e[2]) do INST_BY_ID[id] = entry end
	for _, n in ipairs(e[3]) do INST_BY_NAME[n] = entry end
end
GH.INSTANCE_BY_ID, GH.INSTANCE_BY_NAME = INST_BY_ID, INST_BY_NAME
local INSTANCE_ID_MAX = 100000

-- Gathering casts (classic spell IDs; /ghub test activity shows the last ID seen, to check on Forever).
local GATHER_SPELLS = {
	[2366] = true, [2368] = true, [3570] = true, [11993] = true,   -- Herb Gathering
	[2575] = true, [2576] = true, [3564] = true, [10248] = true,   -- Mining
	[8613] = true, [8617] = true, [8618] = true, [10768] = true,   -- Skinning
}
local FISH_SPELLS = { [7620] = true, [7731] = true, [7732] = true, [18248] = true }

local NEVER = -1e9
GH.activity = { quest = NEVER, xp = NEVER, gath = NEVER, fish = NEVER }
GH.lastAlert = {} -- [name] = GetTime() of the last note shown for them (memory only)

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
function GH:DungeonName(d)
	local e = d and self.DUNGEONS[d]
	return e and e.name or L.LFG_ANY
end

-- How long a status lasts (its own h field; anything unknown counts as 1 hour).
function GH:StatusDuration(s)
	local h = type(s) == "table" and s.h
	return (HOURS_OK[h] and h or 1) * 3600
end

-- A preset/note is shown while it is younger than its duration.
function GH:IsStatusFresh(s)
	return type(s) == "table" and s.st ~= nil and (U.Now() - s.st) < self:StatusDuration(s) and (s.p ~= nil or s.t ~= nil)
end

-- Hours of our current status (1 when there is none). The duration lives only on the status:
-- every new status starts at 1 h. (The old profile.statusHours setting is no longer read.)
function GH:OwnHours()
	local own = self:GetOwnStatus()
	if own and self:IsStatusFresh(own) and HOURS_OK[own.h] then return own.h end
	return 1
end

-- Start (or restart) the clock of our own status. newStatus = true: back to 1 h;
-- otherwise (note edit, dungeon change) the duration is kept.
function GH:StampStatus(own, newStatus)
	if own.p or own.t then
		own.st = U.Now()
		if newStatus or not HOURS_OK[own.h] then own.h = 1 end
	else
		own.st, own.h = nil, nil
	end
end

-- "Lasts" button: step = 1 (left-click: 1 > 2 > 4 > 8 > 1) or -1 (right-click: 8 > 4 > 2 > 1 > 8).
-- Only works while a status is set.
function GH:CycleStatusHours(step)
	local own = self:GetOwnStatus()
	if not own or not self:IsStatusFresh(own) then return end
	local list, cur = self.STATUS_HOURS, self:OwnHours()
	local idx = 1
	for i, h in ipairs(list) do if h == cur then idx = i end end
	own.h = list[(idx - 1 + (step == -1 and -1 or 1)) % #list + 1]
	if self:IsStatusFresh(own) then
		own.ts = U.Now()
		self:SendStatus()
	else
		self:CheckExpiry() -- made shorter than its age: it ends now
	end
	self:RefreshBoard()
end

function GH:IsMuted(name)
	local muted = self.db and self.db.profile.alerts.muted
	return muted and muted[name] and true or false
end

function GH:Mute(name)
	if not name then return end
	self.db.profile.alerts.muted[name] = true
	self:Msg(L.MUTED, U.ShortName(name))
	self:RefreshBoard()
end

------------------------------------------------------------------------
-- Own status
------------------------------------------------------------------------
function GH:GetOwnStatus()
	local gdb = self:GetGuildDB()
	local me = self:MyName()
	if not gdb or not me then return nil end
	if type(gdb.members[me]) ~= "table" then self:UpdateSelf() end
	local m = gdb.members[me]
	if not m then return nil end
	if type(m.status) ~= "table" then m.status = { ts = 0 } end
	return m.status
end

-- Turn a preset on; clicking the active one again turns it off.
function GH:SetPreset(p)
	if p ~= nil and not PRESET_OK[p] then return end
	local own = self:GetOwnStatus()
	if not own then return end
	local fresh = self:IsStatusFresh(own)
	if own.p == p and fresh then p = nil end
	local now = U.Now()
	if not fresh then own.t = nil end -- an old note doesn't come back
	-- switching to another preset or turning it off clears the old note;
	-- a note typed before any preset stays and goes with the new preset
	if fresh and own.p and own.p ~= p then own.t = nil end
	own.p = p
	if p == "lfg" then own.d = own.d or 0 else own.d = nil end
	self:StampStatus(own, p ~= nil) -- a newly picked preset starts at 1 h
	own.pt = (p == "lfg" or p == "help") and now or nil
	own.ts = now
	self:SendStatus()
	self:RefreshBoard()
end

function GH:SetStatusText(text)
	local own = self:GetOwnStatus()
	if not own then return end
	local t = U.CleanText(text, NOTE_MAX)
	local wasFresh = self:IsStatusFresh(own)
	if not wasFresh then own.p, own.d = nil, nil end
	if t == own.t then return end
	local now = U.Now()
	own.t = t
	self:StampStatus(own, not wasFresh) -- a note with no status yet starts at 1 h; editing keeps it
	own.ts = now
	self:SendStatus()
	self:RefreshBoard()
end

function GH:SetLfgDungeon(d)
	if type(d) ~= "number" or d < 0 or d > #self.DUNGEONS or d ~= floor(d) then return end
	local own = self:GetOwnStatus()
	if not own then return end
	local newStatus = own.p ~= "lfg" or not self:IsStatusFresh(own)
	if newStatus then
		own.p, own.pt = "lfg", U.Now()
		if not self:IsStatusFresh(own) then own.t = nil end
	end
	own.d = d
	self:StampStatus(own, newStatus) -- dungeon-only change keeps the duration
	own.ts = U.Now()
	self:SendStatus()
	self:RefreshBoard()
end

function GH:ClearStatus()
	local own = self:GetOwnStatus()
	if not own then return end
	own.p, own.t, own.d, own.st, own.pt, own.h = nil, nil, nil, nil, nil, nil
	own.ts = U.Now()
	self:SendStatus()
	self:RefreshBoard()
end

-- Every 30 s: clear our own preset/note when its time is up (one "empty" STATUS goes out).
function GH:CheckExpiry()
	local own = self:GetOwnStatus()
	if own and own.st and (U.Now() - own.st) >= self:StatusDuration(own) then
		self:ClearStatus()
		self:Msg(L.STATUS_EXPIRED)
	end
end

------------------------------------------------------------------------
-- STATUS message
------------------------------------------------------------------------
-- What others get to see of a status (preset and note only while fresh).
function GH:StatusPayload(s)
	if type(s) ~= "table" then return nil end
	local fresh = self:IsStatusFresh(s)
	return {
		p = fresh and s.p or nil, t = fresh and s.t or nil, d = fresh and s.d or nil,
		st = fresh and s.st or nil, h = fresh and HOURS_OK[s.h] and s.h ~= 1 and s.h or nil,
		a = s.a, as = s.a and s.as or nil, ts = s.ts,
		i = (s.a == "dng" or s.a == "raid") and s.i or nil, -- instanceID (v0.1.2 clients ignore it)
	}
end

function GH:HasStatusToShare()
	local own = self:GetOwnStatus()
	return own ~= nil and (self:IsStatusFresh(own) or own.a ~= nil)
end

function GH:SendStatus()
	if not self.started then return end
	local own = self:GetOwnStatus()
	if not own then return end
	local data = self:StatusPayload(own)
	if (data.ts or 0) == 0 then data.ts = U.Now() end
	data.l = UnitLevel("player")
	if own.pt and data.p and (U.Now() - own.pt) < NEW_SECONDS then data.n = true end
	self:SendMsg("STATUS", data)
end

-- Check a status that came from someone else. Unknown fields are dropped; text is cleaned.
function GH:CleanStatus(data)
	if type(data) ~= "table" then return nil end
	local ts = U.ValidTime(data.ts)
	if not ts then return nil end
	local p = type(data.p) == "string" and PRESET_OK[data.p] and data.p or nil
	local a = type(data.a) == "string" and ACT_OK[data.a] and data.a or nil
	local d = U.ValidNumber(data.d, 0, #self.DUNGEONS)
	if d and d ~= floor(d) then d = nil end
	local i = U.ValidNumber(data.i, 1, INSTANCE_ID_MAX)
	if i and i ~= floor(i) then i = nil end
	return {
		i = (a == "dng" or a == "raid") and i or nil,
		p = p,
		t = U.CleanText(data.t, NOTE_MAX),
		d = (p == "lfg") and d or nil,
		a = a,
		as = a and U.ValidTime(data.as) or nil,
		st = U.ValidTime(data.st),
		h = HOURS_OK[data.h] and data.h or nil,
		l = U.ValidNumber(data.l, 1, 100),
		ts = ts,
	}
end

-- Store a cleaned status; newer ts wins; our own is never overwritten. Returns true if stored.
function GH:MergeStatus(name, st)
	local gdb = self:GetGuildDB()
	if not gdb or not st or not name or name == self:MyName() then return false end
	local m = gdb.members[name]
	if type(m) ~= "table" then
		m = { ts = 0, lastSeen = U.Now() }
		gdb.members[name] = m
	end
	local old = m.status
	if type(old) == "table" and (old.ts or 0) >= st.ts then return false end
	local level = st.l
	st.l = nil
	m.status = st
	if level then m.level = level end
	return true
end

GH.handlers.STATUS = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" then return end
	local st = self:CleanStatus(data)
	if not st then return end
	local gdb = self:GetGuildDB()
	local prev = gdb and gdb.members[sender] and gdb.members[sender].status
	local prevP = type(prev) == "table" and self:IsStatusFresh(prev) and prev.p or nil
	local level = st.l
	if self:MergeStatus(sender, st) then
		if data.n == true then self:MaybeAlert(sender, st, prevP, level) end
		self:RefreshBoard()
	end
end

------------------------------------------------------------------------
-- Notes (LFG within 5 levels, Need help): local only, limited, can be muted
------------------------------------------------------------------------
function GH:MaybeAlert(sender, st, prevP, level)
	local p = st.p
	if (p ~= "lfg" and p ~= "help") or p == prevP or not self:IsStatusFresh(st) then return end
	local al = self.db.profile.alerts
	if (p == "lfg" and not al.lfg) or (p == "help" and not al.help) then return end
	if self:IsMuted(sender) or not self:IsOnline(sender) then return end
	local now = GetTime()
	if self.lastAlert[sender] and now - self.lastAlert[sender] < ALERT_GAP then return end
	local their = level or (self.roster[sender] and self.roster[sender].level)
	if p == "lfg" then
		local mine = UnitLevel("player")
		if type(their) ~= "number" or type(mine) ~= "number" or abs(their - mine) > LEVEL_RANGE then return end
	end
	self.lastAlert[sender] = now

	local who = U.ShortName(sender)
	local note = U.CleanText(st.t, NOTE_MAX)
	local text
	if p == "lfg" then
		local what = self:DungeonName(st.d)
		if note then what = what .. " - " .. note end
		text = L.ALERT_LFG:format(who, tostring(their), what)
	else
		text = note and L.ALERT_HELP:format(who, note) or L.ALERT_HELP_PLAIN:format(who)
	end
	self:Msg("%s", text) -- our own chat frame only, never sent anywhere
	if not InCombatLockdown() and self.ShowToast then
		self:ShowToast(sender, text)
	end
end

------------------------------------------------------------------------
-- Automatic activity (own character only; nothing is read in combat)
------------------------------------------------------------------------
function GH:DetectActivity()
	if not self.db.profile.autoActivity then return nil end
	if UnitIsAFK("player") then return "afk" end
	local inInst, itype = IsInInstance()
	if inInst then
		if itype == "raid" then return "raid" end
		if itype == "pvp" or itype == "arena" then return "pvp" end
		if itype == "party" or itype == "scenario" then return "dng" end
	end
	local a, now = self.activity, GetTime()
	local fish = now - a.fish < GATHER_WINDOW
	local gath = now - a.gath < GATHER_WINDOW
	if fish and (not gath or a.fish >= a.gath) then return "fish" end
	if gath then return "gath" end
	if now - a.quest < QUEST_WINDOW then return "quest" end
	if now - a.xp < XP_WINDOW then return "lvl" end
	if IsResting() then return self:InCapital() and "town" or "inn" end
	return nil
end

-- Our instance right now: instanceID (8th return of GetInstanceInfo) or nil. Secret values skipped.
function GH:CurrentInstance()
	if not GetInstanceInfo then return nil end
	local id = select(8, GetInstanceInfo())
	if type(id) ~= "number" or U.IsSecret(id) or id ~= floor(id) or id < 1 or id > INSTANCE_ID_MAX then return nil end
	return id
end

-- Short and full name of the instance a status is in: from the ID table, else from the zone name
-- (guild list / own live zone). The raw zone text is used only when we know they are in some
-- instance by ID (new clients) or for our own row; v0.1.2 senders get table names only.
function GH:InstanceLabel(s, zone, isSelf)
	local a = type(s) == "table" and s.a
	if a ~= "dng" and a ~= "raid" then return nil end
	local id = s.i
	local e = id and INST_BY_ID[id]
	if not e and type(zone) == "string" and not U.IsSecret(zone) and zone ~= "" then
		e = INST_BY_NAME[zone]
		if not e and (id or isSelf) then
			local z = U.CleanText(zone, 30)
			if z and z ~= "" then return z, z end
		end
	end
	if not e then return nil end
	local short = e.short
	if short == "BRS" then short = (a == "raid") and "UBRS" or "LBRS" end
	return short, e.name
end

function GH:EvalActivity(force)
	if not self.started or InCombatLockdown() then return end
	local own = self:GetOwnStatus()
	if not own then return end
	local cand = self:DetectActivity()
	local candI = (cand == "dng" or cand == "raid") and self:CurrentInstance() or nil
	if cand == own.a and candI == own.i then
		self.pendingAct = nil
		return
	end
	local key = cand or "none"
	local now = GetTime()
	if not force and not IMMEDIATE[cand] and not IMMEDIATE[own.a] then
		if self.pendingAct ~= key then
			self.pendingAct, self.pendingSince = key, now
			-- re-check exactly when the hold ends (one timer at a time)
			if self.pendingTimer then self:CancelTimer(self.pendingTimer) end
			self.pendingTimer = self:ScheduleTimer(function()
				GH.pendingTimer = nil
				GH:EvalActivity()
			end, STICKY + 0.1)
			return
		end
		if now - self.pendingSince < STICKY then return end
	end
	self.pendingAct = nil
	if cand ~= own.a then own.as = cand and U.Now() or nil end -- another instance keeps "for X min"
	own.a = cand
	own.i = candI
	own.ts = U.Now()
	self:SendStatus()
	self:RefreshBoard()
end

local function IsUsable(...)
	for i = 1, select("#", ...) do
		if U.IsSecret((select(i, ...))) then return false end
	end
	return true
end

-- Event frame for the activity (own frame, so it doesn't clash with the AceEvent handlers in Core).
local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event, ...)
	if not GH.started then return end
	if event == "GROUP_ROSTER_UPDATE" then
		GH:OnGroupChanged()
		return
	end
	if event == "PLAYER_REGEN_ENABLED" and GH.groupPending then GH:SendGroup() end
	if not IsUsable(...) then return end -- secret value: leave the activity as it is
	local a, now = GH.activity, GetTime()
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		if InCombatLockdown() then return end
		local unit, _, spellID = ...
		if unit ~= "player" or type(spellID) ~= "number" then return end
		GH.lastSpellID = spellID
		if FISH_SPELLS[spellID] then a.fish = now
		elseif GATHER_SPELLS[spellID] then a.gath = now
		else return end
	elseif event == "QUEST_TURNED_IN" then
		a.quest = now
	elseif event == "PLAYER_XP_UPDATE" or event == "PLAYER_LEVEL_UP" then
		local xp = UnitXP("player")
		if U.IsSecret(xp) then return end
		if event == "PLAYER_LEVEL_UP" or (GH.lastXP and type(xp) == "number" and xp > GH.lastXP) then a.xp = now end
		GH.lastXP = xp
	elseif event == "PLAYER_FLAGS_CHANGED" then
		local unit = ...
		if unit ~= "player" then return end
	end
	GH:EvalActivity()
	if event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
		GH:RefreshBoard() -- own row zone is read live
	end
end)

function GH:InitStatus()
	if self.statusStarted then return end
	self.statusStarted = true
	ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
	for _, e in ipairs({ "QUEST_TURNED_IN", "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "PLAYER_FLAGS_CHANGED",
		"PLAYER_UPDATE_RESTING", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
		"GROUP_ROSTER_UPDATE" }) do
		ev:RegisterEvent(e)
	end
	self:ScanMyGroup()
	local xp = UnitXP("player")
	if not U.IsSecret(xp) then self.lastXP = xp end
	self:ScheduleRepeatingTimer("EvalActivity", EVAL_SECONDS)
	self:ScheduleRepeatingTimer("CheckExpiry", EXPIRY_SECONDS)
	self:CheckExpiry()
	self:EvalActivity()
end

-- Turning automatic activity on/off in the settings takes effect at once.
function GH:SetAutoActivity(on)
	self.db.profile.autoActivity = on and true or false
	self:EvalActivity(true)
end

------------------------------------------------------------------------
-- /ghub test activity, /ghub test expire (only ever run by hand)
------------------------------------------------------------------------
function GH:TestActivity()
	local a, now = self.activity, GetTime()
	local function ago(t) return (t > NEVER) and L.AGO:format(U.Duration(now - t)) or L.NEVER end
	local cur = self:DetectActivity()
	local inInst, itype = IsInInstance()
	local id = self:CurrentInstance()
	local short = id and INST_BY_ID[id] and INST_BY_ID[id].short
	self:Msg(L.TEST_ACTIVITY, cur and L.ACT[cur] or L.AUTO_ACT_NONE,
		self.db.profile.autoActivity and L.YES or L.NO, tostring(self.lastSpellID or "-"),
		ago(a.quest), ago(a.xp), IsResting() and L.YES or L.NO, inInst and tostring(itype) or L.NO,
		id and (short and ("%d (%s)"):format(id, short) or tostring(id)) or "-")
end

function GH:TestExpire()
	local own = self:GetOwnStatus()
	if not own or not self:IsStatusFresh(own) then return self:Msg(L.TEST_EXPIRE_NONE) end
	own.st = U.Now() - self:StatusDuration(own) - 60
	self:Msg(L.TEST_EXPIRE)
end

------------------------------------------------------------------------
-- Groups (GROUP column). Who is in OUR group is read locally (works for everyone, addon or not);
-- the size of other players' groups comes from their GRP message (and HELLO/HB). Display only:
-- nothing is ever invited, accepted or whispered because a GRP message arrived.
------------------------------------------------------------------------
local GROUP_QUIET = 2 -- seconds without roster changes before we share our group size
GH.myGroup = {}       -- ["Name-Realm"] = true for everyone in our party/raid (memory only)

function GH:SharesGroup()
	return self.db.profile.shareGroup ~= false -- on unless turned off in the settings
end

function GH:SetShareGroup(on)
	self.db.profile.shareGroup = on and true or false
	self:SendGroup()
end

-- Our own group: size (0-40) and raid flag, or nil if the game hides it.
function GH:GroupInfo()
	local n = GetNumGroupMembers and GetNumGroupMembers()
	if type(n) ~= "number" or U.IsSecret(n) or n ~= n then return nil end
	n = math.max(0, math.min(40, floor(n)))
	local raid = IsInRaid and IsInRaid()
	if U.IsSecret(raid) then raid = false end
	return n, (n > 0 and raid) and true or false
end

-- Names of everyone in our group, in the same form as the guild list keys ("Name Suffix-Realm").
function GH:ScanMyGroup()
	local set = {}
	local n, raid = self:GroupInfo()
	if n and n > 0 and GetUnitName then
		local prefix, count = "party", 4
		if raid then prefix, count = "raid", 40 end
		for i = 1, count do
			local unit = prefix .. i
			if not UnitExists or UnitExists(unit) then
				local nm = GetUnitName(unit, true)
				if type(nm) == "string" and not U.IsSecret(nm) and nm ~= "" then
					local k = U.FullName(nm)
					if k then set[k] = true end
				end
			end
		end
	end
	self.myGroup = set
end

-- What we share: g, r, and a key to see if it changed ("off" when sharing is turned off).
function GH:OwnGroupShare()
	if not self:SharesGroup() then return nil, nil, "off" end
	local g, r = self:GroupInfo()
	if not g then return nil end
	return g, r, g .. (r and "r" or "")
end

-- GROUP_ROSTER_UPDATE: update our list at once, share the size after 2 s of quiet.
function GH:OnGroupChanged()
	self:ScanMyGroup()
	self:RefreshBoard()
	if self.groupTimer then self:CancelTimer(self.groupTimer) end
	self.groupTimer = self:ScheduleTimer(function()
		GH.groupTimer = nil
		GH:SendGroup()
	end, GROUP_QUIET)
end

-- Sends GRP only when the shared value changed; waits for the end of combat.
-- (SendMsg adds the 15-s gap per type and keeps only the newest held message.)
function GH:SendGroup()
	if not self.started then return end
	if InCombatLockdown() then
		self.groupPending = true
		return
	end
	self.groupPending = nil
	local g, r, k = self:OwnGroupShare()
	if not k or k == self.lastGroupKey then return end
	self.lastGroupKey = k
	self:SendMsg("GRP", { g = g, r = r and 1 or nil })
end

-- Received group info: g clamped to 0-40 (whole number), r only 1 = raid. No g = not shared.
function GH:CleanGroup(data)
	if type(data) ~= "table" then return nil end
	local g = data.g
	if type(g) ~= "number" or U.IsSecret(g) or g ~= g then return nil end
	g = math.max(0, math.min(40, floor(g)))
	return { g = g, r = (g > 0 and data.r == 1) or nil }
end

GH.handlers.GRP = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" then return end
	local u = self.addonUsers[sender]
	if not u then return end
	u.grp = self:CleanGroup(data)
	self:RefreshBoard()
end

-- Text for the GROUP column, a colour kind ("yours", "solo", "other") and the tooltip line.
function GH:GroupText(d)
	local g = d.grp
	local size
	if g and g.g > 0 then size = (g.r and L.GRP_RAID or L.GRP_PARTY):format(g.g) end
	if d.inMyGroup then
		return L.GRP_YOURS, "yours", size and L.TIP_GRP_YOURS:format(size) or L.TIP_GRP_YOURS_PLAIN
	end
	if not g then return "", nil, nil end
	if g.g == 0 then return "-", "solo", L.TIP_GRP_SOLO end
	return size, "other", (g.r and L.TIP_GRP_RAID or L.TIP_GRP_PARTY):format(g.g)
end

------------------------------------------------------------------------
-- Board rows (plain tables; the window only draws them)
------------------------------------------------------------------------
local GROUP_ORDER = { "lfg", "help", "dungeon", "farm", "town", "busy", "other", "noaddon" }
local GROUP_COLOR = {
	lfg = { 0.45, 0.85, 0.45 }, help = { 1, 0.55, 0.35 }, dungeon = { 0.75, 0.55, 1 }, farm = { 1, 0.82, 0.3 },
	town = { 0.6, 0.8, 1 }, busy = { 0.7, 0.7, 0.7 }, other = { 0.85, 0.85, 0.85 }, noaddon = { 0.5, 0.5, 0.5 },
}
GH.GROUP_ORDER, GH.GROUP_COLOR = GROUP_ORDER, GROUP_COLOR

local function GroupOf(s, fresh)
	local p = fresh and s.p
	if p == "lfg" then return "lfg" end
	if p == "help" then return "help" end
	local a = s.a
	if a == "dng" or a == "raid" or a == "pvp" then return "dungeon" end
	if p == "busy" or a == "afk" then return "busy" end
	if p == "farm" or p == "lvl" or a == "gath" or a == "fish" or a == "quest" or a == "lvl" then return "farm" end
	if a == "town" or a == "inn" then return "town" end
	return "other"
end

function GH:StatusLine(s, fresh, muted, instShort)
	-- preset (+ dungeon) first, then the note: "LFG Scarlet Monastery: need tank", "Busy: back in 10";
	-- with neither, the activity, plus the instance short name: "In a dungeon: RFC"
	local text
	if fresh then
		local head
		if s.p == "lfg" then
			head = (s.d and s.d > 0) and (L.PRESET.lfg .. " " .. self:DungeonName(s.d)) or L.PRESET.lfg
		elseif s.p then
			head = L.PRESET[s.p]
		end
		local note = not muted and s.t or nil
		if head and note then
			text = head .. ": " .. note
		else
			text = head or note
		end
	end
	if not text and s.a then
		text = L.ACT[s.a]
		if text and instShort and (s.a == "dng" or s.a == "raid") then text = L.ACT_IN_FMT:format(text, instShort) end
	end
	return text or ""
end

-- Our own zone right now (the guild list only refreshes every 15-60 s).
function GH:LiveZone()
	local z = GetRealZoneText and GetRealZoneText()
	if type(z) ~= "string" or U.IsSecret(z) or z == "" then return nil end
	return z
end

-- opts: { search = "text", sort = "activity"|"level"|"zone"|"rank"|"name", compact = bool, showNoAddon = bool }
-- Returns rows, onlineCount, withAddonCount. Header rows: { header = group, count = n }.
function GH:BuildStatusRows(opts)
	opts = opts or {}
	local gdb = self:GetGuildDB()
	local me = self:MyName()
	local now = U.Now()
	local search = opts.search and opts.search ~= "" and lower(opts.search) or nil
	local list, online, withAddon = {}, 0, 0

	for name, r in pairs(self.roster) do
		if r.online then
			online = online + 1
			local hasAddon = self:IsAddonUserOnline(name)
			if hasAddon then withAddon = withAddon + 1 end
			local m = gdb and gdb.members[name]
			local row = {
				name = name, short = U.ShortName(name), class = r.class or (m and m.class),
				level = (name == me and UnitLevel("player")) or r.level or (m and m.level),
				zone = (name == me and self:LiveZone()) or r.zone or "", isSelf = name == me, noAddon = not hasAddon,
				rank = r.rankName or "", rankIndex = type(r.rankIndex) == "number" and r.rankIndex or 99,
			}
			if hasAddon then
				local s = (m and type(m.status) == "table") and m.status or {}
				local fresh = self:IsStatusFresh(s)
				row.muted = self:IsMuted(name)
				row.group = GroupOf(s, fresh)
				row.instShort, row.instFull = self:InstanceLabel(s, row.zone, row.isSelf)
				row.status = self:StatusLine(s, fresh, row.muted, row.instShort)
				row.preset = fresh and s.p or nil
				row.act = s.a
				if fresh and s.st then row.left = math.max(0, self:StatusDuration(s) - (now - s.st)) end
				if fresh and s.st then row.since = now - s.st
				elseif s.a and s.as then row.since = now - s.as end
			else
				row.group, row.status = "noaddon", ""
			end
			-- group column: our own group is read locally; others' size comes from their GRP/HB
			if row.isSelf or self.myGroup[name] then
				row.inMyGroup = not row.isSelf or nil
				local g, r = self:GroupInfo()
				if g then row.grp = { g = g, r = r or nil } end
			elseif hasAddon then
				local u = self.addonUsers[name]
				row.grp = u and u.grp
			end
			local keep = true
			if row.noAddon and not opts.showNoAddon then keep = false end
			if opts.compact and row.group ~= "lfg" then keep = false end
			if keep and search then
				keep = find(lower(row.short), search, 1, true) or find(lower(row.zone), search, 1, true)
					or find(lower(row.status), search, 1, true) or find(lower(row.rank), search, 1, true)
			end
			if keep then list[#list + 1] = row end
		end
	end

	local sort = opts.sort or "activity"
	local rank = {}
	for i, g in ipairs(GROUP_ORDER) do rank[g] = i end
	table.sort(list, function(a, b)
		if a.noAddon ~= b.noAddon then return b.noAddon end
		if sort == "activity" and a.group ~= b.group then return rank[a.group] < rank[b.group] end
		if sort == "level" and a.level ~= b.level then return (a.level or 0) > (b.level or 0) end
		if sort == "zone" and a.zone ~= b.zone then return a.zone < b.zone end
		if sort == "rank" and a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
		return a.short < b.short
	end)

	if sort ~= "activity" then return list, online, withAddon end
	local rows, i = {}, 1
	while i <= #list do
		local g, n = list[i].group, 0
		for j = i, #list do
			if list[j].group == g then n = n + 1 else break end
		end
		rows[#rows + 1] = { header = g, count = n }
		for j = i, i + n - 1 do rows[#rows + 1] = list[j] end
		i = i + n
	end
	return rows, online, withAddon
end

------------------------------------------------------------------------
-- Redraw the board soon (many updates in a row cause one redraw)
------------------------------------------------------------------------
function GH:RefreshBoard(now)
	if not (self.mainFrame and self.mainFrame:IsShown() and self.DrawStatusTab) then return end
	if now then
		self:DrawStatusTab()
		return
	end
	if self.boardTimer then return end
	self.boardTimer = self:ScheduleTimer(function()
		GH.boardTimer = nil
		if GH.mainFrame and GH.mainFrame:IsShown() then GH:DrawStatusTab() end
	end, 0.3)
end
