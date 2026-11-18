-- Guild Hub: guild history recorders (0.4.0). Saved on this computer only, never sent.
-- Later versions show it (firsts, anniversaries, the online heatmap, the roster log, raid progress).
-- Rules (tos check): every list has a hard cap; online hours are guild TOTALS per hour slot (only
-- your own character gets its own hours); boss kills are read when the game reports the end of the
-- fight, secret values are skipped; the guild event log is read once per session, out of combat.
--
-- gdb.rec = {
--   v = 1, started = ts,
--   first = { [name] = ts },               first time this computer saw the member in the guild list
--   gone  = { [name] = ts },               first time they were missing (90 days later: forgotten)
--   lvl   = { [name] = { [10|20..60] = { t = ts, own = true|nil, pre = true|nil } } }
--            own = our own exact level-up; pre = already that level when we first saw them
--   hours = { all = { [slot] = { n, sum, max, a } }, weeks = { [week] = { [slot] = max } } }
--            slot = UTC weekday (0 = Sunday) x 24 + UTC hour; shown in local time later
--   names = { "Name-Realm", ... }          kill participants as indexes into this list
--   kills = { { k = key, t, e, n, i, d, s, w = { name indexes } }, ... } newest first
--            key = encounterID:instanceID:floor(t / 300) (the same kill from several computers merges later)
--   tries = { [day] = { [encounterID] = failed attempts } }  day = floor(t / 86400)
--   joins = { [name] = ts }                from the guild event log (about a day precise)
--   log   = { { t, ty, p1, p2, r }, ... }  every guild event-log entry, newest first, no doubles
--   motd  = { { t, s }, ... }              the message of the day when it changed, newest first
-- }
-- char.rec = { hours = { [slot] = samples } } (own character only)
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local MILESTONES = { 10, 20, 30, 40, 50, 60 }
local SAMPLE_SECONDS = 900          -- online counts: once per 15 minutes
local FIRST_SAMPLE = 60             -- and once a minute after the guild list is ready
local MAX = { kills = 500, log = 300, motd = 50, tryDays = 120, weeks = 8, names = 2000, who = 40 }
local FORGET_DAYS = 90
local LOG_TYPES = { invite = true, join = true, promote = true, demote = true, remove = true, quit = true }
local MOTD_MAX = 255
GH.REC_MAX = MAX

local function Now() return U.Now() end

local function NewRec()
	return { v = 1, started = Now(), first = {}, gone = {}, lvl = {}, hours = { all = {}, weeks = {} },
		names = {}, kills = {}, tries = {}, joins = {}, log = {}, motd = {} }
end
GH.NewRecorderData = NewRec

local function Rec()
	local gdb = GH:GetGuildDB()
	return gdb and gdb.rec
end

local function On() return GH.recStarted and GH:FeatureOn("rec") end

------------------------------------------------------------------------
-- Saved-data check (Store.lua GetGuildDB): types always; entries and caps once per session
------------------------------------------------------------------------
local TABLES = { "first", "gone", "lvl", "names", "kills", "tries", "joins", "log", "motd" }

local function Trim(list, n)
	for i = #list, n + 1, -1 do list[i] = nil end
end

function GH:CheckRecorderData(gdb, deep)
	local r = gdb.rec
	if type(r) ~= "table" then
		gdb.rec = NewRec()
		return
	end
	if type(r.started) ~= "number" then r.started = Now() end
	for _, k in ipairs(TABLES) do if type(r[k]) ~= "table" then r[k] = {} end end
	if type(r.hours) ~= "table" then r.hours = {} end
	if type(r.hours.all) ~= "table" then r.hours.all = {} end
	if type(r.hours.weeks) ~= "table" then r.hours.weeks = {} end
	if not deep then return end

	for name, t in pairs(r.first) do if type(name) ~= "string" or type(t) ~= "number" then r.first[name] = nil end end
	for name, t in pairs(r.gone) do if type(name) ~= "string" or type(t) ~= "number" then r.gone[name] = nil end end
	for name, t in pairs(r.joins) do if type(name) ~= "string" or type(t) ~= "number" then r.joins[name] = nil end end
	for name, e in pairs(r.lvl) do
		if type(name) ~= "string" or type(e) ~= "table" then r.lvl[name] = nil
		else
			for lv, x in pairs(e) do
				if type(lv) ~= "number" or type(x) ~= "table" or type(x.t) ~= "number" then e[lv] = nil end
			end
		end
	end
	-- hour slots: no usable count/sum = dropped; a damaged max / addon count = 0 (like RepairSaved)
	local function num(v) return type(v) == "number" and v == v and v >= 0 and v < 1e9 end
	for slot, s in pairs(r.hours.all) do
		if type(slot) ~= "number" or slot < 0 or slot > 167 or type(s) ~= "table" or not num(s.n) or not num(s.sum) then
			r.hours.all[slot] = nil
		else
			if not num(s.max) then s.max = 0 end
			if not num(s.a) then s.a = 0 end
		end
	end
	local weeks = {}
	for w, t in pairs(r.hours.weeks) do
		if type(w) == "number" and type(t) == "table" then
			weeks[#weeks + 1] = w
			for slot, v in pairs(t) do if type(slot) ~= "number" or not num(v) then t[slot] = nil end end
		else
			r.hours.weeks[w] = nil
		end
	end
	table.sort(weeks, function(a, b) return a > b end)
	for i = MAX.weeks + 1, #weeks do r.hours.weeks[weeks[i]] = nil end
	-- names: strings only (kill entries refer to their positions, so a bad one becomes "?")
	for i = 1, #r.names do if type(r.names[i]) ~= "string" then r.names[i] = "?" end end
	Trim(r.names, MAX.names)
	for i = #r.kills, 1, -1 do
		local k = r.kills[i]
		if type(k) ~= "table" or type(k.t) ~= "number" or type(k.e) ~= "number" or type(k.k) ~= "string" then
			table.remove(r.kills, i)
		elseif k.w ~= nil and type(k.w) ~= "table" then k.w = nil
		elseif k.w then
			for j = #k.w, 1, -1 do if type(k.w[j]) ~= "number" then table.remove(k.w, j) end end
		end
	end
	Trim(r.kills, MAX.kills)
	local days = {}
	for d, t in pairs(r.tries) do
		if type(d) == "number" and type(t) == "table" then
			days[#days + 1] = d
			for enc, n in pairs(t) do if type(enc) ~= "number" or not num(n) then t[enc] = nil end end
		else
			r.tries[d] = nil
		end
	end
	table.sort(days, function(a, b) return a > b end)
	for i = MAX.tryDays + 1, #days do r.tries[days[i]] = nil end
	for i = #r.log, 1, -1 do
		local e = r.log[i]
		if type(e) ~= "table" or type(e.t) ~= "number" or type(e.ty) ~= "string" then table.remove(r.log, i) end
	end
	Trim(r.log, MAX.log)
	for i = #r.motd, 1, -1 do
		local e = r.motd[i]
		if type(e) ~= "table" or type(e.t) ~= "number" or type(e.s) ~= "string" then table.remove(r.motd, i) end
	end
	Trim(r.motd, MAX.motd)
end

local function OwnHours()
	local c = GH.db and GH.db.char
	if not c then return nil end
	if type(c.rec) ~= "table" then c.rec = {} end
	if type(c.rec.hours) ~= "table" then c.rec.hours = {} end
	return c.rec.hours
end

------------------------------------------------------------------------
-- First seen, leavers, level milestones (from every guild list rebuild, Roster.lua)
------------------------------------------------------------------------
local function Milestones(r, name, level, pre)
	if type(level) ~= "number" or U.IsSecret(level) then return end
	local e = r.lvl[name]
	for _, m in ipairs(MILESTONES) do
		if level >= m and not (e and e[m]) then
			e = e or {}
			r.lvl[name] = e
			e[m] = { t = Now(), pre = pre or nil }
		end
	end
end

function GH:RecordRoster(roster)
	if not On() then return end
	local r = Rec()
	if not r then return end
	local now = Now()
	for name, info in pairs(roster) do
		local isNew = r.first[name] == nil
		if isNew then r.first[name] = now end
		r.gone[name] = nil
		-- a member's level when we first see them is "already", not a level-up we saw
		Milestones(r, name, info.level, isNew)
	end
	for name in pairs(r.first) do
		if not roster[name] then
			r.gone[name] = r.gone[name] or now
			if now - r.gone[name] > FORGET_DAYS * 86400 then
				r.first[name], r.gone[name], r.joins[name], r.lvl[name] = nil, nil, nil, nil
				-- also out of the event log and the kill name list (entries stay, shown as "?")
				for _, e in ipairs(r.log) do
					if e.p1 == name then e.p1 = "?" end
					if e.p2 == name then e.p2 = "?" end
				end
				for i, n in ipairs(r.names) do if n == name then r.names[i] = "?" end end
				GH.recNameIdx = nil -- the name index is rebuilt
			end
		end
	end
end

local function OnLevelUp(_, level)
	if not On() or U.IsSecret(level) or type(level) ~= "number" then return end
	local r = Rec()
	local me = GH:MyName()
	if not r or not me then return end
	for _, m in ipairs(MILESTONES) do
		if level == m then
			r.lvl[me] = r.lvl[me] or {}
			r.lvl[me][m] = { t = Now(), own = true } -- exact: our own level-up
		end
	end
end

------------------------------------------------------------------------
-- Online counts per hour (guild TOTALS; own hours only for this character)
------------------------------------------------------------------------
function GH:HourSlot(ts)
	local d = date("!*t", ts or Now())
	return (d.wday - 1) * 24 + d.hour
end

function GH:WeekKey(ts)
	-- weeks start on Monday 00:00 UTC (1970-01-01 was a Thursday)
	return math.floor(((ts or Now()) + 3 * 86400) / (7 * 86400))
end

function GH:SampleOnline()
	if not On() or not self.rosterReady then return end
	local r = Rec()
	if not r then return end
	local now = Now()
	local slot, week = self:HourSlot(now), self:WeekKey(now)
	local online = self.rosterOnline or 0
	local addon = 0
	for name in pairs(self.addonUsers) do
		if self:IsAddonUserOnline(name) then addon = addon + 1 end
	end
	local s = r.hours.all[slot]
	if not s then s = { n = 0, sum = 0, max = 0, a = 0 }; r.hours.all[slot] = s end
	s.n, s.sum, s.a = s.n + 1, s.sum + online, (s.a or 0) + addon
	if online > (s.max or 0) then s.max = online end
	local w = r.hours.weeks[week]
	if not w then
		w = {}
		r.hours.weeks[week] = w
		local keys = {}
		for k in pairs(r.hours.weeks) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return a > b end)
		for i = MAX.weeks + 1, #keys do r.hours.weeks[keys[i]] = nil end
	end
	if online > (w[slot] or 0) then w[slot] = online end
	local own = OwnHours()
	if own then own[slot] = (own[slot] or 0) + 1 end
end

------------------------------------------------------------------------
-- Boss kills and failed attempts (ENCOUNTER_END comes after the fight)
------------------------------------------------------------------------
local function NameIndex(r, name)
	GH.recNameIdx = GH.recNameIdx or {}
	local map = GH.recNameIdx[r]
	if not map then
		map = {}
		for i, n in ipairs(r.names) do map[n] = i end
		GH.recNameIdx[r] = map
	end
	local i = map[name]
	if i then return i end
	if #r.names >= MAX.names then return nil end
	r.names[#r.names + 1] = name
	map[name] = #r.names
	return #r.names
end

function GH:KillKey(encounterID, instanceID, ts)
	return ("%d:%d:%d"):format(encounterID, instanceID or 0, math.floor(ts / 300))
end

local function OnEncounterEnd(_, encounterID, encounterName, difficultyID, groupSize, success)
	if not On() then return end
	for _, v in ipairs({ encounterID, encounterName, difficultyID, groupSize, success }) do
		if U.IsSecret(v) then return end -- hidden by the game: skip
	end
	if type(encounterID) ~= "number" then return end
	local r = Rec()
	if not r then return end
	local now = Now()
	if success ~= 1 and success ~= true then
		local day = math.floor(now / 86400)
		local t = r.tries[day]
		if not t then
			t = {}
			r.tries[day] = t
			local days = {}
			for d in pairs(r.tries) do days[#days + 1] = d end
			table.sort(days, function(a, b) return a > b end)
			for i = MAX.tryDays + 1, #days do r.tries[days[i]] = nil end
		end
		t[encounterID] = (t[encounterID] or 0) + 1
		return
	end
	local inst = select(8, GetInstanceInfo())
	if U.IsSecret(inst) or type(inst) ~= "number" then inst = 0 end
	local key = GH:KillKey(encounterID, inst, now)
	for i = 1, math.min(#r.kills, 20) do
		if r.kills[i].k == key then return end -- already saved (event twice)
	end
	-- guildmates in the group (and us); kept only when 2 or more of the guild were there
	local who, seen = {}, {}
	local me = GH:MyName()
	local list = { me }
	for name in pairs(GH.myGroup or {}) do list[#list + 1] = name end
	for _, name in ipairs(list) do
		if name and not seen[name] and (name == me or GH:IsGuildMember(name)) and #who < MAX.who then
			seen[name] = true
			local idx = NameIndex(r, name)
			if idx then who[#who + 1] = idx end
		end
	end
	table.insert(r.kills, 1, {
		k = key, t = now, e = encounterID, i = inst,
		n = U.CleanText(encounterName, 40), d = type(difficultyID) == "number" and difficultyID or nil,
		s = type(groupSize) == "number" and groupSize or nil, w = #who >= 2 and who or nil,
	})
	Trim(r.kills, MAX.kills)
end

------------------------------------------------------------------------
-- Guild event log (once per session, out of combat) and the message of the day
------------------------------------------------------------------------
local function Ago(y, mo, d, h)
	local n = function(x) return (type(x) == "number" and not U.IsSecret(x)) and x or 0 end
	return n(y) * 365 * 86400 + n(mo) * 30 * 86400 + n(d) * 86400 + n(h) * 3600
end

function GH:ReadEventLog()
	if not On() then return end
	local r = Rec()
	if not r or type(GetNumGuildEvents) ~= "function" or type(GetGuildEventInfo) ~= "function" then return end
	local ok, n = pcall(GetNumGuildEvents)
	if not ok or type(n) ~= "number" or U.IsSecret(n) then return end
	local now = Now()
	local added = {}
	for i = 1, math.min(n, 500) do
		local okE, ty, p1, p2, rank, y, mo, d, h = pcall(GetGuildEventInfo, i)
		if okE and type(ty) == "string" and not U.IsSecret(ty) and LOG_TYPES[ty] then
			local t = now - Ago(y, mo, d, h)
			p1 = p1 and U.ValidName(U.FullName(p1)) or nil
			p2 = p2 and U.ValidName(U.FullName(p2)) or nil
			rank = (type(rank) == "number" and not U.IsSecret(rank)) and rank or nil
			-- the same entry seen again (the game keeps them, only the "ago" moves): same type and
			-- names within 36 hours = the same
			local dup = false
			for _, e in ipairs(r.log) do
				if e.ty == ty and e.p1 == p1 and e.p2 == p2 and e.r == rank and math.abs(e.t - t) <= 36 * 3600 then
					dup = true
					break
				end
			end
			if not dup then
				for _, e in ipairs(added) do
					if e.ty == ty and e.p1 == p1 and e.p2 == p2 and e.r == rank and math.abs(e.t - t) <= 3600 then dup = true break end
				end
			end
			if not dup then added[#added + 1] = { t = t, ty = ty, p1 = p1, p2 = p2, r = rank } end
			local joiner = (ty == "join" and p1) or (ty == "invite" and p2) or nil
			if joiner and (ty == "join" or not r.joins[joiner]) then
				if not r.joins[joiner] or t < r.joins[joiner] then r.joins[joiner] = t end
			end
		end
	end
	for _, e in ipairs(added) do r.log[#r.log + 1] = e end
	table.sort(r.log, function(a, b) return a.t > b.t end)
	Trim(r.log, MAX.log)
	self.recLogRead = true
end

function GH:QueryEventLog()
	if not On() or self.recLogAsked or type(QueryGuildEventLog) ~= "function" then return end
	if InCombatLockdown() then
		self.recLogAfterCombat = true
		return
	end
	self.recLogAsked = true
	pcall(QueryGuildEventLog) -- the answer comes as GUILD_EVENT_LOG_UPDATE
end

function GH:SaveMOTD(text)
	if not On() then return end
	if text == nil then
		local get = (C_GuildInfo and C_GuildInfo.GetMOTD) or GetGuildRosterMOTD
		if type(get) ~= "function" then return end
		local ok, s = pcall(get)
		if not ok then return end
		text = s
	end
	if type(text) ~= "string" or U.IsSecret(text) then return end
	text = U.CleanText(text, MOTD_MAX)
	if not text or text == "" then return end
	local r = Rec()
	if not r then return end
	if r.motd[1] and r.motd[1].s == text then return end
	table.insert(r.motd, 1, { t = Now(), s = text })
	Trim(r.motd, MAX.motd)
end

------------------------------------------------------------------------
-- Settings line, /ghub status, Clear
------------------------------------------------------------------------
function GH:RecorderCounts()
	local r = Rec()
	if not r then return nil end
	local c = { first = 0, hours = 0, kills = #r.kills, log = #r.log, motd = #r.motd }
	for _ in pairs(r.first) do c.first = c.first + 1 end
	for _, s in pairs(r.hours.all) do if s.n and s.n > 0 then c.hours = c.hours + 1 end end
	return c
end

function GH:ClearRecorders()
	local gdb = self:GetGuildDB()
	if not gdb then return end
	gdb.rec = NewRec()
	self.recNameIdx = nil
	local own = OwnHours()
	if own then for k in pairs(own) do own[k] = nil end end
	self:Msg(L.REC_CLEARED)
end

------------------------------------------------------------------------
-- The feature
------------------------------------------------------------------------
GH:RegisterFeature({
	key = "rec", name = "OPT_FEAT_REC",
	defaults = { char = { rec = { hours = {} } } },
	enable = function()
		GH.recStarted = true
		GH:On("rec", "ENCOUNTER_END", OnEncounterEnd)
		GH:On("rec", "PLAYER_LEVEL_UP", OnLevelUp)
		GH:On("rec", "GUILD_EVENT_LOG_UPDATE", function() GH:ReadEventLog() end)
		GH:On("rec", "GUILD_MOTD", function(_, text) GH:SaveMOTD(text) end)
		GH:On("rec", "PLAYER_REGEN_ENABLED", function()
			if GH.recLogAfterCombat then GH.recLogAfterCombat = nil; GH:QueryEventLog() end
		end)
		GH:Every("rec", "sample", SAMPLE_SECONDS, function() GH:SampleOnline() end)
		GH:ScheduleTimer(function()
			if not On() then return end
			if GH.rosterReady then GH:RecordRoster(GH.roster) end
			GH:SampleOnline()
			GH:QueryEventLog()
			GH:SaveMOTD()
		end, FIRST_SAMPLE)
	end,
	disable = function()
		GH.recStarted = nil
	end,
	selftest = function(api)
		local r = Rec()
		if not r then return api.Skip("rec", "(no guild)") end
		api.Count()
		local bad = (#r.kills > MAX.kills) or (#r.log > MAX.log) or (#r.motd > MAX.motd)
		if bad then api.Problem("DB", "history", "a list is over its cap") end
		local c = GH:RecorderCounts()
		api.Info(("history %d/%d/%d/%d"):format(c.first, c.hours, c.kills, c.log))
	end,
})
