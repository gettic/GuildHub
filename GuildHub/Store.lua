-- Guild Hub: saved data (GuildHubDB), merging "newer wins", 90-day pruning.
local _, ns = ...
local GH, U = ns.GH, ns.Util

local SCHEMA = 2

local defaults = {
	global = {
		-- no "schema" here: AceDB never saves a value equal to its default, so MigrateStore sets it
		guilds = {},
	},
	profile = {
		debug = false,
		features = {},       -- 0.4.0: [featureKey] = false when the player switched it off (Features.lua)
		-- step 2: status board
		window = { point = "CENTER", x = 0, y = 0 },
		sort = "activity",
		compact = false,
		showNoAddon = true,
		minimap = { hide = false, angle = 200 },
		alerts = { lfg = true, help = true, muted = {} },
		autoActivity = true,
		inviteFallback = false, -- set for good if the game blocks InviteUnit from the addon
		-- (beta.2/3 saved `mini` here; it is no longer read and does no harm)
		miniWindow = { point = "TOPRIGHT", x = -220, y = -220 },
		-- step 3: professions
		shareProf = true,    -- "Share my professions" (off: an empty PROF tells others to drop the data)
		profTooltip = true,  -- "crafted by" line in item tooltips
		profMats = true,     -- request whisper says "I'll bring the mats"
		profFilter = "all",
		profOnline = false,
		guideOff = false,    -- "Don't show this by itself again" on the Getting started card (all characters)
	},
	char = {
		trialNoticeShown = false,
		guideShown = false,  -- the Getting started card showed by itself on this character
		usedStatus = false,  -- this character has set a status at least once (Getting started tick)
		guideDeferred = false, -- the guide was skipped after a map "Not now" (tos C2): it shows next login
	},
}

function GH:InitStore()
	self:MergeFeatureDefaults(defaults) -- each feature's own defaults (Features.lua)
	self.db = LibStub("AceDB-3.0"):New("GuildHubDB", defaults, true)
	self:MigrateStore()
	self:RepairSaved()
	if self.db.RegisterCallback then
		self.db.RegisterCallback(self, "OnProfileChanged", "RepairSaved")
		self.db.RegisterCallback(self, "OnProfileCopied", "RepairSaved")
		self.db.RegisterCallback(self, "OnProfileReset", "RepairSaved")
	end
end

------------------------------------------------------------------------
-- Repair: a saved value with the wrong type (e.g. a damaged SavedVariables file) is reset
-- to its default. Only that one field; correct data is never changed.
------------------------------------------------------------------------
local ANCHORS = { CENTER = true, TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
	TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true }
-- the Status board's sorts (same list as StatusTab.lua SORTS)
local SORT_KEYS = { activity = true, level = true, zone = true, rank = true, name = true }

local function CopyDefault(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, x in pairs(v) do t[k] = CopyDefault(x) end
	return t
end

local function Finite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Compare t with its defaults d (one level into tables); returns the repaired field names.
local function RepairTable(t, d, path, fixed)
	for k, dv in pairs(d) do
		local v = rawget(t, k)
		if v ~= nil and type(v) ~= type(dv) then
			t[k] = CopyDefault(dv)
			fixed[#fixed + 1] = path .. k
		elseif v == nil and type(dv) == "table" then
			t[k] = CopyDefault(dv)
		elseif type(v) == "number" and not Finite(v) then
			t[k] = dv
			fixed[#fixed + 1] = path .. k
		elseif type(v) == "table" and type(dv) == "table" and next(dv) ~= nil then
			RepairTable(v, dv, path .. k .. ".", fixed)
		end
	end
end

function GH:RepairSaved()
	local db = self.db
	if not db then return end
	local fixed = {}
	local p = db.profile
	if type(p) == "table" then
		RepairTable(p, defaults.profile, "", fixed)
		for _, key in ipairs({ "window", "miniWindow" }) do
			local w = p[key]
			if not ANCHORS[w.point] then
				w.point = defaults.profile[key].point
				fixed[#fixed + 1] = key .. ".point"
			end
		end
		if not SORT_KEYS[p.sort] then
			p.sort = defaults.profile.sort
			fixed[#fixed + 1] = "sort"
		end
		local muted, badMuted = p.alerts.muted, false
		for k, v in pairs(muted) do
			if type(k) ~= "string" or v ~= true then
				muted[k] = nil -- clearing a field during pairs() is allowed in Lua
				badMuted = true
			end
		end
		if badMuted then fixed[#fixed + 1] = "alerts.muted" end
		if p.shareGroup ~= nil and type(p.shareGroup) ~= "boolean" then
			p.shareGroup = nil
			fixed[#fixed + 1] = "shareGroup"
		end
		-- feature switches: only "false" (switched off) is stored; anything else is dropped
		local badFeat = false
		for k, v in pairs(p.features) do
			if type(k) ~= "string" or v ~= false then
				p.features[k] = nil
				badFeat = true
			end
		end
		if badFeat then fixed[#fixed + 1] = "features" end
	end
	-- 0.4.0-b2: the map answer (per character). Anything odd becomes "ask": a repair never turns
	-- position sharing on.
	local c = db.char
	if type(c) == "table" then
		local v = rawget(c, "mapShare")
		if v ~= nil and v ~= "ask" and v ~= "yes" and v ~= "no" then
			c.mapShare = "ask"
			fixed[#fixed + 1] = "mapShare"
		end
		-- Getting started flags: booleans only (a broken one becomes "not yet")
		for _, k in ipairs({ "guideShown", "usedStatus", "guideDeferred" }) do
			local f = rawget(c, k)
			if f ~= nil and type(f) ~= "boolean" then
				c[k] = false -- (AceDB copies plain defaults in at load: nil would stay nil)
				fixed[#fixed + 1] = k
			end
		end
	end
	local g = db.global
	if type(g) == "table" and type(g.guilds) ~= "table" then
		g.guilds = {}
		fixed[#fixed + 1] = "guilds"
	end
	for _, name in ipairs(fixed) do
		self:Debug("repaired saved setting %s", name)
	end
	return fixed
end

-- Convert older saved data to the current layout, one step after the other. Never throws data away;
-- a step only adds or converts. Running it again changes nothing.
-- global.schema is NOT in the AceDB defaults (a value equal to its default is never saved), so it is
-- stored for real from 0.4.0 on. A file without a schema is from before 0.4.0 (where the default was 1
-- and so never saved) or brand new: both read as 1, so every step must also be safe on empty data.
local MIGRATIONS = {
	-- 2 (0.4.0): feature switches + guild history. Everything new is created when first used
	-- (profile.features by the defaults, gdb.featOff / gdb.rec by GetGuildDB), so nothing to convert.
	[2] = function() end,
}

-- target / steps: only for tests (default: SCHEMA / MIGRATIONS).
function GH:MigrateStore(target, steps)
	local g = self.db.global
	target, steps = target or SCHEMA, steps or MIGRATIONS
	if type(g.schema) ~= "number" or g.schema ~= g.schema or g.schema < 1 then g.schema = 1 end
	for n = math.floor(g.schema) + 1, target do
		if steps[n] then steps[n](self, g) end
		g.schema = n
	end
	if g.schema < target then g.schema = target end
end

-- "<GuildName>-<Realm>", or nil while the game hasn't told us the guild yet.
function GH:GuildKey()
	if not IsInGuild() then return nil end
	local guildName, _, _, guildRealm = GetGuildInfo("player")
	if not guildName then return nil end
	guildRealm = guildRealm or U.MyRealm()
	if not guildRealm then return nil end
	return guildName .. "-" .. guildRealm
end

function GH:GetGuildDB()
	local key = self:GuildKey()
	if not key then return nil end
	local guilds = self.db.global.guilds
	if type(guilds) ~= "table" then
		guilds = {}
		self.db.global.guilds = guilds
	end
	local gdb = guilds[key]
	if type(gdb) ~= "table" then
		gdb = { cfg = { officerMaxRank = 1, ts = 0 }, members = {}, feed = {}, lastOnline = 0 }
		guilds[key] = gdb
	end
	-- wrong types (damaged saved file) are replaced; good data is kept
	if type(gdb.cfg) ~= "table" then gdb.cfg = { officerMaxRank = 1, ts = 0 } end
	if type(gdb.cfg.officerMaxRank) ~= "number" then gdb.cfg.officerMaxRank = 1 end
	if gdb.cfg.ts ~= nil and type(gdb.cfg.ts) ~= "number" then gdb.cfg.ts = 0 end
	if type(gdb.members) ~= "table" then gdb.members = {} end
	if type(gdb.feed) ~= "table" then gdb.feed = {} end
	if gdb.lastOnline ~= nil and type(gdb.lastOnline) ~= "number" then gdb.lastOnline = 0 end
	-- 0.4.0: officers' guild feature switch, and the guild history kept on this computer
	if type(gdb.featOff) ~= "table" or type(gdb.featOff.off) ~= "table" then gdb.featOff = { off = {}, ts = 0 } end
	if type(gdb.featOff.ts) ~= "number" then gdb.featOff.ts = 0 end
	if gdb.featOff.by ~= nil and type(gdb.featOff.by) ~= "string" then gdb.featOff.by = nil end
	if self.CheckRecorderData then self:CheckRecorderData(gdb) end
	if not (self.checkedGuilds and self.checkedGuilds[key]) then
		-- once per session: drop member entries that aren't tables, and non-table statuses
		for name, m in pairs(gdb.members) do
			if type(name) ~= "string" or type(m) ~= "table" then
				gdb.members[name] = nil
			else
				if m.status ~= nil and type(m.status) ~= "table" then m.status = nil end
				if m.prof ~= nil then self:CleanSavedProf(m) end
			end
		end
		-- feed lines (step 3): { ts, who, r, k }; anything else is dropped
		for i = #gdb.feed, 1, -1 do
			local e = gdb.feed[i]
			if type(e) ~= "table" or type(e.ts) ~= "number" or type(e.who) ~= "string" or type(e.r) ~= "number" then
				table.remove(gdb.feed, i)
			end
		end
		if self.CheckRecorderData then self:CheckRecorderData(gdb, true) end -- broken history entries dropped, caps
		self.checkedGuilds = self.checkedGuilds or {}
		self.checkedGuilds[key] = true
	end
	return gdb
end

------------------------------------------------------------------------
-- Member records
-- members["Name-Realm"] = { class, level, version, lastSeen, ts, status, (prof in step 3) }
-- status = { p, t, d, a, as, st, ts } is merged separately by its own ts (Status.lua).
-- ts = when the owner last changed the data; lastSeen = when anyone last saw them online.
------------------------------------------------------------------------

-- Saved professions of one member (step 3): broken parts are dropped, a bad recipe list is marked
-- for a new fetch. { ts, p = { [skillLine] = { r, m, s, n, h, l, old, scanned } }, off, offTs }
function GH:CleanSavedProf(m)
	local prof = m.prof
	if type(prof) ~= "table" or type(prof.p) ~= "table" or type(prof.ts) ~= "number" then
		m.prof = nil
		return
	end
	for line, e in pairs(prof.p) do
		if type(line) ~= "number" or type(e) ~= "table" or type(e.h) ~= "number" then
			prof.p[line] = nil
		else
			for _, k in ipairs({ "r", "m", "s", "n", "scanned", "sentR" }) do
				if e[k] ~= nil and type(e[k]) ~= "number" then e[k] = nil end
			end
			e.n = e.n or 0
			if e.l ~= nil and (type(e.l) ~= "string" or e.l:find("[^0-9a-z,]")) then e.l, e.old = nil, true end
		end
	end
end

-- Check and copy a record that came from someone else. Unknown fields are dropped.
function GH:CleanRecord(rec)
	if type(rec) ~= "table" then return nil end
	local ts = U.ValidTime(rec.ts)
	if not ts then return nil end
	return {
		ts       = ts,
		class    = U.ValidClass(rec.class),
		level    = U.ValidNumber(rec.level, 1, 100),
		version  = U.ValidVersion(rec.version),
		lastSeen = U.ValidTime(rec.lastSeen),
	}
end

-- Merge a cleaned record. Newer ts wins for the data; lastSeen takes the latest.
-- Our own record is never overwritten by others.
function GH:MergeMember(name, rec)
	local gdb = self:GetGuildDB()
	if not gdb or not rec or name == self:MyName() then return false end
	local m = gdb.members[name]
	if not m then
		gdb.members[name] = rec
		return true
	end
	local changed = false
	if rec.lastSeen and rec.lastSeen > (m.lastSeen or 0) then
		m.lastSeen = rec.lastSeen
	end
	if rec.ts > (m.ts or 0) then
		m.ts = rec.ts
		m.class = rec.class or m.class
		m.level = rec.level or m.level
		m.version = rec.version or m.version
		changed = true
	end
	return changed
end

-- Our own record, kept up to date before every HELLO/HB.
function GH:UpdateSelf()
	local gdb = self:GetGuildDB()
	local me = self:MyName()
	if not gdb or not me then return nil end
	local m = gdb.members[me]
	if not m then
		m = {}
		gdb.members[me] = m
	end
	local _, class = UnitClass("player")
	local level = UnitLevel("player")
	local now = U.Now()
	if m.class ~= class or m.level ~= level or m.version ~= self.VERSION then
		m.class, m.level, m.version = class, level, self.VERSION
		m.ts = now
	end
	m.ts = m.ts or now
	m.lastSeen = now
	return m
end

-- v0.1.0 stored our own record under "UnitName-Realm" ("Mira-Realm" on WoW Forever, where the
-- real name is "Mira Ashford"). Move it to the right key; nothing is thrown away: if both exist,
-- the newer one wins and empty fields are filled from the other.
function GH:MigrateOwnKey()
	local gdb = self:GetGuildDB()
	local me = self:MyName()
	local old = U.FullName(UnitName("player"))
	if not gdb or not me or not old or old == me then return end
	local oldRec = gdb.members[old]
	if type(oldRec) ~= "table" then return end
	local cur = gdb.members[me]
	if type(cur) ~= "table" then
		gdb.members[me] = oldRec
	else
		local main, other = cur, oldRec
		if (oldRec.ts or 0) > (cur.ts or 0) then main, other = oldRec, cur end
		for k, v in pairs(other) do
			if main[k] == nil then main[k] = v end
		end
		if (other.lastSeen or 0) > (main.lastSeen or 0) then main.lastSeen = other.lastSeen end
		gdb.members[me] = main
	end
	gdb.members[old] = nil
	self:Debug("moved your saved record from %s to %s", old, me)
end

function GH:TouchMember(name)
	local gdb = self:GetGuildDB()
	local m = gdb and gdb.members[name]
	if m then m.lastSeen = U.Now() end
end

------------------------------------------------------------------------
-- Pruning: members not seen for 90 days are deleted (never our own character).
------------------------------------------------------------------------
function GH:Prune()
	local gdb = self:GetGuildDB()
	if not gdb then return end
	local cutoff = U.Now() - self.PRUNE_DAYS * 86400
	local me = self:MyName()
	local removed = 0
	local statusCutoff = U.Now() - 86400
	for name, m in pairs(gdb.members) do
		if name ~= me and (m.lastSeen or m.ts or 0) < cutoff then
			gdb.members[name] = nil
			removed = removed + 1
		elseif name ~= me and type(m.status) == "table" and (m.status.ts or 0) < statusCutoff then
			m.status = nil -- statuses are only shown for 1 hour; the member record itself stays
		end
	end
	for i = #gdb.feed, 1, -1 do
		local e = gdb.feed[i]
		if type(e) ~= "table" or (e.ts or 0) < cutoff then
			table.remove(gdb.feed, i)
		end
	end
	if removed > 0 then
		self:Debug("pruned %d members not seen for %d days", removed, self.PRUNE_DAYS)
	end
end
