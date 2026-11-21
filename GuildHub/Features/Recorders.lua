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
--   log   = { { t, ty, p1, p2, r, u }, ... } every guild event-log entry, newest first, no doubles
--            r = rank (name or number), u = how coarse t is (seconds of the largest unit the game gave:
--            hour / day / month / year; 0.4.0-b3, missing on older entries)
--   logFix = 1                             the one-time cleanup of doubles has run (0.4.0-b3)
--   logFixed = n                           how many doubles were removed so far (self-test)
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
		names = {}, kills = {}, tries = {}, joins = {}, log = {}, motd = {}, logFix = 1 }
end
GH.NewRecorderData = NewRec

local function Rec()
	local gdb = GH:GetGuildDB()
	return gdb and gdb.rec
end

local function On() return GH.recStarted and GH:FeatureOn("rec") end

------------------------------------------------------------------------
-- Guild event log: the same entry across reads (0.4.0-b3)
-- The game gives each entry's age as years / months / days / hours "ago". For old entries only the
-- big unit moves (an entry stays "2 months ago" for weeks), so the time we work out from it can be
-- off by up to one unit; two reads of the same entry match within that unit (+ 36 h).
------------------------------------------------------------------------
local HOUR, DAY = 3600, 86400
local UNITS = { 365 * DAY, 30 * DAY, DAY, HOUR } -- year, month, day, hour
local LOG_SLACK = 36 * HOUR

-- age in seconds and its unit (the largest unit with a value; under an hour = HOUR); nil when a
-- field is secret or odd (the entry is skipped)
local function LogAge(y, mo, d, h)
	if y == nil and mo == nil and d == nil and h == nil then return nil end -- no age at all: unknown
	local v, age, unit = { y, mo, d, h }, 0, nil
	for i = 1, 4 do
		local x = v[i]
		if x == nil then x = 0 end -- Blizzard's own log treats nil as 0
		if U.IsSecret(x) or type(x) ~= "number" or x ~= x or x < 0 or x > 1e5 then return nil end
		if x > 0 and not unit then unit = UNITS[i] end
		age = age + x * UNITS[i]
	end
	return age, unit or HOUR
end

-- the unit the game would give an entry of this age (entries saved before 0.4.0-b3 have no `u`)
local function UnitForAge(age)
	for i = 1, 3 do if age >= UNITS[i] then return UNITS[i] end end
	return HOUR
end

local function LogTol(u1, u2) return math.max(u1 or 0, u2 or 0) * 1.2 + LOG_SLACK end

local function EntryUnit(e, now)
	return type(e.u) == "number" and e.u or UnitForAge(math.max(0, now - e.t))
end

local function LogKey(e) return e.ty .. "\1" .. tostring(e.p1) .. "\1" .. tostring(e.p2) .. "\1" .. tostring(e.r) end

-- Doubles in a saved log: the same type, names and rank within the unit's tolerance. Keeps the
-- oldest of each; remove = true takes the others out. Returns how many doubles there are.
local function LogDoubles(list, now, remove)
	local order = {}
	for i = 1, #list do order[#order + 1] = i end
	table.sort(order, function(a, b) return list[a].t < list[b].t end)
	local kept, drop, n = {}, {}, 0
	for _, i in ipairs(order) do
		local e = list[i]
		local k = LogKey(e)
		local same = false
		for _, o in ipairs(kept[k] or {}) do
			if math.abs(e.t - o.t) <= LogTol(EntryUnit(e, now), EntryUnit(o, now)) then same = true break end
		end
		if same then
			n = n + 1
			drop[i] = true
		else
			kept[k] = kept[k] or {}
			table.insert(kept[k], e)
		end
	end
	if remove and n > 0 then
		for i = #list, 1, -1 do if drop[i] then table.remove(list, i) end end
	end
	return n
end
GH.RecLogDoubles = LogDoubles

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
		if type(e) ~= "table" or type(e.t) ~= "number" or type(e.ty) ~= "string" then table.remove(r.log, i)
		elseif e.u ~= nil and (type(e.u) ~= "number" or e.u < 0) then e.u = nil end
	end
	-- 0.4.0-b3: once, take out the doubles older versions could save (keeps the oldest of each)
	if r.logFix ~= 1 then
		local n = LogDoubles(r.log, Now(), true)
		r.logFixed = (type(r.logFixed) == "number" and r.logFixed or 0) + n
		r.logFix = 1
	end
	if r.logFixed ~= nil and type(r.logFixed) ~= "number" then r.logFixed = nil end
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
local LOG_READ_MAX = 500

local function LogName(p)
	if p == nil or U.IsSecret(p) then return nil end
	return U.ValidName(U.FullName(p))
end

local function LogRank(rank)
	if rank == nil or U.IsSecret(rank) then return nil end
	if type(rank) == "number" then return rank end
	if type(rank) == "string" then return U.CleanText(rank, 32) end -- Blizzard's log shows it as a rank name
	return nil
end

-- a name the event should have is missing (0.5.0-b3)
local TWO_NAMES = { invite = true, promote = true, demote = true, remove = true }
local function Nameless(e) return e.p1 == nil or (TWO_NAMES[e.ty] and e.p2 == nil) or false end

-- the same event? (unknown names / rank match anything; the game may not know an old name yet)
local function SameEvent(e, x)
	return e.ty == x.ty and (e.p1 == x.p1 or e.p1 == nil or x.p1 == nil)
		and (e.p2 == x.p2 or e.p2 == nil or x.p2 == nil) and (e.r == x.r or e.r == nil or x.r == nil)
end

-- Reads the game's log. Each entry of this read matches at most one saved entry (the closest, exact
-- names first), so two real events that look alike both stay. A complete read also takes out saved
-- copies the game doesn't list inside the time it covers (doubles with a wrong time), but only of
-- events the game does list: a saved entry is never the last of its kind to go.
function GH:ReadEventLog()
	if not On() then return end
	local r = Rec()
	if not r or type(GetNumGuildEvents) ~= "function" or type(GetGuildEventInfo) ~= "function" then return end
	local ok, n = pcall(GetNumGuildEvents)
	if not ok or U.IsSecret(n) or type(n) ~= "number" then return end
	local now = Now()
	local read, complete = {}, n <= LOG_READ_MAX
	for i = 1, math.min(n, LOG_READ_MAX) do
		local okE, ty, p1, p2, rank, y, mo, d, h = pcall(GetGuildEventInfo, i)
		if not okE or U.IsSecret(ty) then
			complete = false
		elseif type(ty) == "string" and LOG_TYPES[ty] then
			local age, unit = LogAge(y, mo, d, h)
			if not age then
				complete = false
			else
				read[#read + 1] = { t = now - age, u = unit, ty = ty, p1 = LogName(p1), p2 = LogName(p2), r = LogRank(rank) }
			end
		end
	end
	local used, added, matched = {}, {}, {}
	-- 0.5.0-b3: two passes. Pass 1: every read entry takes only its exact copy (same names and rank),
	-- the closest in time. Pass 2: the rest (a name missing on one side) take the closest look-alike.
	-- So an entry whose name the game doesn't know yet can't take another event's copy.
	for pass = 1, 2 do
		for i, x in ipairs(read) do
			if not matched[i] then
				local best, bestD
				for _, e in ipairs(r.log) do
					if not used[e] and SameEvent(e, x)
						and (pass == 2 or (e.p1 == x.p1 and e.p2 == x.p2 and e.r == x.r)) then
						local dd = math.abs(e.t - x.t)
						if dd <= LogTol(EntryUnit(e, now), x.u) and (not best or dd < bestD) then best, bestD = e, dd end
					end
				end
				if best then
					matched[i] = best
					used[best] = true
					best.p1, best.p2, best.r = best.p1 or x.p1, best.p2 or x.p2, best.r or x.r
					-- the older time wins: a time worked out from "N months ago" is never too old, only too
					-- new (and an age of 0 from a log that wasn't loaded yet is the newest of all)
					if x.t < best.t then best.t, best.u = x.t, x.u end
					if not best.u then best.u = x.u end
				end
			end
		end
	end
	for i, x in ipairs(read) do
		if not matched[i] then added[#added + 1] = x end
		local joiner = (x.ty == "join" and x.p1) or (x.ty == "invite" and x.p2) or nil
		if joiner and (x.ty == "join" or not r.joins[joiner]) then
			if not r.joins[joiner] or x.t < r.joins[joiner] then r.joins[joiner] = x.t end
		end
	end
	local removed = 0
	if complete and #read > 0 then
		local oldest = read[1]
		for _, x in ipairs(read) do if x.t < oldest.t then oldest = x end end
		local from = oldest.t + LogTol(oldest.u)
		local listed = {}
		for _, x in ipairs(read) do listed[LogKey(x)] = true end
		for i = #r.log, 1, -1 do
			local e = r.log[i]
			-- 0.5.0-b3: also a copy saved without a name, next to a fully named read entry of that event
			local leftover = false
			if not used[e] and e.t >= from and not listed[LogKey(e)] and Nameless(e) then
				for _, x in ipairs(read) do
					if not Nameless(x) and SameEvent(e, x) and math.abs(e.t - x.t) <= LogTol(EntryUnit(e, now), x.u) then
						leftover = true
						break
					end
				end
			end
			if not used[e] and e.t >= from and (listed[LogKey(e)] or leftover) then
				table.remove(r.log, i)
				removed = removed + 1
			end
		end
	end
	if removed > 0 then r.logFixed = (type(r.logFixed) == "number" and r.logFixed or 0) + removed end
	for _, e in ipairs(added) do r.log[#r.log + 1] = e end
	table.sort(r.log, function(a, b) return a.t > b.t end)
	Trim(r.log, MAX.log)
	self.recLogRead = true
	self.recLogGame = n -- self-test: how many entries the game has
	self.recLogAlike = LogDoubles(read, now, false) -- self-test: real look-alike events the game itself lists
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
	-- text comes only from the GUILD_MOTD event (Core.lua). No C_GuildInfo.GetMOTD /
	-- GetGuildRosterMOTD here: restricted, the game blocks it (ADDON_ACTION_BLOCKED).
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
		GH:On("rec", "PLAYER_REGEN_ENABLED", function()
			if GH.recLogAfterCombat then GH.recLogAfterCombat = nil; GH:QueryEventLog() end
		end)
		GH:Every("rec", "sample", SAMPLE_SECONDS, function() GH:SampleOnline() end)
		GH:ScheduleTimer(function()
			if not On() then return end
			if GH.rosterReady then GH:RecordRoster(GH.roster) end
			GH:SampleOnline()
			GH:QueryEventLog()
			GH:SaveMOTD(GH.lastMOTD) -- the login GUILD_MOTD came before this feature started
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
		-- 0.4.0-b3: doubles left in the guild log (should be 0), doubles removed so far, the game's count
		api.Count()
		local okD, doubles = pcall(LogDoubles, r.log, Now(), false)
		-- (info only: two real events can look alike, e.g. the same player invited twice in a day)
		if not okD then api.Problem("DB", "history", "log check failed") doubles = "!" end
		-- 0.5.0-b3: look-alikes the game itself lists (e.g. a member who left and came back) are not doubles
		local alike = type(GH.recLogAlike) == "number" and GH.recLogAlike or 0
		if type(doubles) == "number" then doubles = math.max(0, doubles - alike) end
		api.Info(("history %d/%d/%d/%d, log doubles %s, alike %d, removed %d, game %s"):format(c.first, c.hours, c.kills, c.log,
			tostring(doubles), alike, type(r.logFixed) == "number" and r.logFixed or 0, tostring(GH.recLogGame or "-")))
		-- 0.4.0-b3: message of the day only from the GUILD_MOTD event (seen this session y/n, saved count)
		api.Info(("motd seen %s, saved %d"):format(type(GH.lastMOTD) == "string" and "y" or "n", c.motd))
	end,
})
