-- Guild Hub: saved data (GuildHubDB), merging "newer wins", 90-day pruning.
local _, ns = ...
local GH, U = ns.GH, ns.Util

local SCHEMA = 1

local defaults = {
	global = {
		schema = SCHEMA,
		guilds = {},
	},
	profile = {
		debug = false,
	},
	char = {
		trialNoticeShown = false,
	},
}

function GH:InitStore()
	self.db = LibStub("AceDB-3.0"):New("GuildHubDB", defaults, true)
	self:MigrateStore()
end

-- Convert older saved data to the current layout. Never throws data away.
function GH:MigrateStore()
	local g = self.db.global
	g.schema = g.schema or SCHEMA
	-- (future: if g.schema < 2 then ... convert ... g.schema = 2 end)
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
	local gdb = guilds[key]
	if not gdb then
		gdb = { cfg = { officerMaxRank = 1, ts = 0 }, members = {}, feed = {}, lastOnline = 0 }
		guilds[key] = gdb
	end
	gdb.cfg = gdb.cfg or { officerMaxRank = 1, ts = 0 }
	gdb.members = gdb.members or {}
	gdb.feed = gdb.feed or {}
	return gdb
end

------------------------------------------------------------------------
-- Member records
-- members["Name-Realm"] = { class, level, version, lastSeen, ts, (status, prof in later steps) }
-- ts = when the owner last changed the data; lastSeen = when anyone last saw them online.
------------------------------------------------------------------------

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
	for name, m in pairs(gdb.members) do
		if name ~= me and (m.lastSeen or m.ts or 0) < cutoff then
			gdb.members[name] = nil
			removed = removed + 1
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
