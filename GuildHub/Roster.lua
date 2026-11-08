-- Guild Hub: copy of the guild list (who is online, rank, level, class).
local _, ns = ...
local GH, U = ns.GH, ns.Util

GH.roster = {}        -- ["Name-Realm"] = { rankIndex, level, class, zone, online }
GH.rosterReady = false
GH.rosterOnline = 0

function GH:InitRoster()
	self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnRosterUpdate")
end

function GH:RequestRoster()
	if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	end
end

-- The event can fire many times in a row: rebuild at most once per 2 seconds.
function GH:OnRosterUpdate()
	if self.rosterTimer then return end
	self.rosterTimer = self:ScheduleTimer(function()
		GH.rosterTimer = nil
		GH:RebuildRoster()
	end, 2)
end

function GH:RebuildRoster()
	if not IsInGuild() then return end
	local num = GetNumGuildMembers()
	if not num or num == 0 then return end

	local roster, online = {}, 0
	local now = U.Now()
	local gdb = self:GetGuildDB()
	for i = 1, num do
		local name, _, rankIndex, level, _, zone, _, _, isOnline, status, class = GetGuildRosterInfo(i)
		name = U.FullName(name)
		if name then
			roster[name] = {
				rankIndex = rankIndex, level = level, class = class,
				zone = zone, online = isOnline and true or false, afk = status == 1,
			}
			if isOnline then
				online = online + 1
				local m = gdb and gdb.members[name]
				if m then m.lastSeen = now end
			end
		end
	end
	self.roster = roster
	self.rosterOnline = online

	if not self.rosterReady then
		self.rosterReady = true
		self:Debug("guild list loaded: %d members, %d online", num, online)
		self:OnRosterReady()
	end
end

function GH:IsGuildMember(name)
	return self.roster[name] ~= nil
end

function GH:IsOnline(name)
	local r = self.roster[name]
	return r and r.online or false
end

function GH:IsGuildMaster(name)
	local r = self.roster[name]
	return r and r.rankIndex == 0 or false
end

-- Officer check for officer-only actions. Uses OUR copy of the roster, never what the sender claims.
function GH:IsOfficer(name)
	local r = self.roster[name]
	local gdb = self:GetGuildDB()
	if not r or not gdb then return false end
	return r.rankIndex <= (gdb.cfg.officerMaxRank or 1)
end

-- Guild rank names, for the options list (rankIndex 0 = Guild Master).
function GH:GetRankNames()
	local names = {}
	local n = GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
	for i = 1, n do
		names[i - 1] = GuildControlGetRankName(i) or ("Rank " .. i)
	end
	return names
end
