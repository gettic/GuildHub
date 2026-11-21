-- Guild Hub: Guild Recruiter, beta R6 (plans\guild-recruiter\PLAN.md section 11.2, tos-new-ideas.md 2).
-- Buddies for new members and the officers' "gone quiet" note. Loaded after Features\RecruitAds.lua
-- and before Features\Recruit.lua (which registers the feature with these messages).
--  * Sign-up: a member ticks "I'll be a buddy". Each click sends one RBSU on GUILD; officers' addons
--    keep the name on their Buddies list (RecruitOff.lua list "b": caught up between officers,
--    gone after 90 days without a new sign-up or when the member leaves).
--  * Pairing: an officer picks a signed-up buddy for a new member. Each click sends one RBAS on
--    GUILD; it counts only from an officer in OUR guild list and only when both are in the guild.
--    Only officers, the buddy and the new member keep it (14 days, or until one of them leaves).
--    An officer whispers a pairing once to the buddy or new member when they log in later.
--  * Who sees what: the new member "Your buddy: Mira"; the buddy "Your new guildie Tal: last online
--    3 d ago" (the guild window's own last-online data) and one chat line per login. No scores.
--  * Gone quiet (officers only): new members (joined in the last 14 days) not online for 4+ days,
--    worked out on the officer's own computer from the guild list. Never sent. A reminder only.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

------------------------------------------------------------------------
-- Fixed caps (the self-test checks these values)
------------------------------------------------------------------------
local NEW_DAYS = 14        -- a "new member" joined in the last 14 days
local QUIET_DAYS = 4       -- not online for this many days = gone quiet
local PAIR_DAYS = 14       -- a pairing lasts 14 days
local BUD_KEEP = 90        -- a sign-up lasts 90 days
local PAIRS_MAX = 50
local PAIRS_PER_MSG = 5    -- pairings in one RBAS
local LOGIN_LINE_DELAY = 60
local HELLO_ANSWER_DELAY = 4
local CATCHUP_DUP_SECONDS = 60 -- a second catch-up whisper within this is ignored
local AHEAD_OK = GH.RECRUIT_AHEAD_OK or 30 -- a received time may be this far ahead (quick edits); RecruitOff.lua

GH.RECRUIT_BUDDY_CAPS = { NEW_DAYS = NEW_DAYS, QUIET_DAYS = QUIET_DAYS, PAIR_DAYS = PAIR_DAYS, BUD_KEEP = BUD_KEEP,
	PAIRS_MAX = PAIRS_MAX, CATCHUP_DUP_SECONDS = CATCHUP_DUP_SECONDS }
GH.budStats = { rbsu = 0, rbas = 0, dropped = 0 }

local function Now() return U.Now() end
local function On() return GH:FeatureOn("recruit") end
local function HaveRoster() return type(GH.roster) == "table" and next(GH.roster) ~= nil end
local function IAmOfficer() return GH.RecruitIAmOfficer and GH.RecruitIAmOfficer() or false end
local function Key(name) return GH.RecruitNameKey(name) end
local function Refresh() if GH.DrawRecruitPage then GH:DrawRecruitPage() end end

------------------------------------------------------------------------
-- Saved data: char.recruitBuddy = {[guild] = sign-up time} (own tick), gdb.recruit.pairs =
-- {[new member] = {b = buddy (nil = no buddy / not you), ts, by = officer}}
------------------------------------------------------------------------
local function OwnSignups()
	local ch = GH.db.char
	if type(rawget(ch, "recruitBuddy")) ~= "table" then ch.recruitBuddy = {} end -- (raw: no default value)
	local cut = Now() - BUD_KEEP * 86400
	for k, t in pairs(ch.recruitBuddy) do
		if type(k) ~= "string" or type(t) ~= "number" or t ~= t or t < cut then ch.recruitBuddy[k] = nil end
	end
	return ch.recruitBuddy
end

-- Cleans the pairs: damaged or older than 14 days dropped; with the guild list: members who left
-- dropped; not an officer: only our own pairings kept. Returns the table.
local function CleanPairs(r)
	if type(r.pairs) ~= "table" then r.pairs = {} end
	local now = Now()
	local cut = now - PAIR_DAYS * 86400
	local me = GH:MyName()
	local roster = HaveRoster()
	local officer = IAmOfficer()
	local n = 0
	for name, e in pairs(r.pairs) do
		local ok = U.ValidName(name) and type(e) == "table" and type(e.ts) == "number" and e.ts == e.ts
			and e.ts >= cut and e.ts <= now + 3600 and U.ValidName(e.by) ~= nil
			and (e.b == nil or U.ValidName(e.b) ~= nil)
		if ok and roster then
			ok = GH:IsGuildMember(name) and (e.b == nil or GH:IsGuildMember(e.b))
			if ok and not officer and name ~= me and e.b ~= me then ok = false end
		end
		if ok then n = n + 1 else r.pairs[name] = nil end
	end
	while n > PAIRS_MAX do -- the oldest go first
		local oldName, oldTs
		for name, e in pairs(r.pairs) do if not oldTs or e.ts < oldTs then oldName, oldTs = name, e.ts end end
		r.pairs[oldName] = nil
		n = n - 1
	end
	return r.pairs
end

local function Pairs()
	local r = GH.RecruitData and GH.RecruitData()
	if not r then return nil end
	if type(r.pairs) ~= "table" then r.pairs = {} end
	GH.budChecked = GH.budChecked or {}
	if not GH.budChecked[r.pairs] then
		GH.budChecked[r.pairs] = true
		CleanPairs(r)
	end
	return r.pairs
end
GH.RecruitPairs = Pairs

------------------------------------------------------------------------
-- Sign-up (members; one RBSU per click)
------------------------------------------------------------------------
-- Our own sign-up time in this guild, or nil (not signed up / older than 90 days).
function GH:BuddySignedUp()
	local key = self:GuildKey()
	if not key or not self.db then return nil end
	return OwnSignups()[key]
end

function GH:SetBuddySignup(on)
	if not On() then return false, L.AD_FEATURE_OFF end
	if not IsInGuild() or not HaveRoster() then return false, L.NOT_IN_GUILD end
	local key = self:GuildKey()
	if not key then return false, L.NOT_IN_GUILD end
	local me, now = self:MyName(), Now()
	local ts = now
	-- officers keep their own sign-up on their Buddies list at once (ordered after earlier changes)
	local off = IAmOfficer() and self:RecruitOff(true)
	if off then
		local cur, del = off.bud[me], off.del["b:" .. me]
		if cur and cur.ts >= ts then ts = cur.ts + 1 end
		if del and del >= ts then ts = del + 1 end
		self:ApplyOffRow(off, { l = "b", n = me, ts = ts, by = me, x = (not on) or nil }, true)
	end
	OwnSignups()[key] = on and now or nil
	self:SendMsg("RBSU", { on = on and true or nil, ts = ts })
	Refresh()
	return true
end

local function Drop(self, why)
	self.budStats.dropped = self.budStats.dropped + 1
	self:Debug("buddy message dropped: %s", why)
end

-- RBSU (GUILD): only officers keep it, only from a guild member about themselves.
local function HandleSignup(self, sender, data, distribution, isSelf)
	if isSelf or not On() then return end
	if distribution ~= "GUILD" or type(data) ~= "table" then return Drop(self, "not on GUILD") end
	if not IAmOfficer() then return end -- members don't keep the list
	if not self:IsGuildMember(sender) then return Drop(self, "not a guild member") end
	local off = self:RecruitOff(true)
	if not off then return end
	local ts = U.ValidTime(data.ts) or Now()
	if self:ApplyOffRow(off, { l = "b", n = sender, ts = ts, by = sender, x = (data.on ~= true) or nil }) then
		self.budStats.rbsu = self.budStats.rbsu + 1
		Refresh()
	end
end

-- Officers: signed-up buddies still in the guild, online first, then by name. { {name, ts, online} }
function GH:BuddyList()
	local out = {}
	if not IAmOfficer() then return out end
	for _, r in ipairs(self:OffRows("b")) do
		if self:IsGuildMember(r.name) then out[#out + 1] = { name = r.name, ts = r.ts, online = self:IsOnline(r.name) } end
	end
	table.sort(out, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return out
end

function GH:IsSignedUpBuddy(name)
	local off = IAmOfficer() and self:RecruitOff()
	local n = Key(name)
	return off ~= nil and off ~= false and n ~= nil and off.bud[n] ~= nil
end

------------------------------------------------------------------------
-- Pairing (officers; one RBAS per click)
------------------------------------------------------------------------
-- newName = a guild member; buddy = a signed-up buddy, or nil to remove the pairing.
function GH:AssignBuddy(newName, buddy)
	if not On() then return false, L.AD_FEATURE_OFF end
	if not IAmOfficer() then return false, L.BUD_ERR_OFFICER end
	local n = Key(newName)
	local b = buddy ~= nil and Key(buddy) or nil
	if not n or not self:IsGuildMember(n) or (buddy ~= nil and (not b or b == n or not self:IsGuildMember(b))) then
		return false, L.BUD_ERR_NAME
	end
	if b and not self:IsSignedUpBuddy(b) then return false, L.BUD_ERR_SIGNUP:format(U.ShortName(b)) end
	local p = Pairs()
	if not p then return false, L.NOT_IN_GUILD end
	local cur = p[n]
	local ts = Now()
	if cur and cur.ts >= ts then ts = cur.ts + 1 end
	p[n] = { b = b, ts = ts, by = self:MyName() }
	self:SendMsg("RBAS", { p = { { n = n, b = b, ts = ts } } })
	if b then self:Msg(L.BUD_ASSIGNED, U.ShortName(b), U.ShortName(n)) else self:Msg(L.BUD_UNASSIGNED, U.ShortName(n)) end
	Refresh()
	return true
end

-- RBAS (GUILD from a click, or WHISPER as the login catch-up): only from an officer in OUR list,
-- both names in the guild. Kept only by officers, the buddy and the new member.
local function HandleAssign(self, sender, data, distribution, isSelf)
	if isSelf or not On() then return end
	if (distribution ~= "GUILD" and distribution ~= "WHISPER") or type(data) ~= "table" or type(data.p) ~= "table" then
		return Drop(self, "bad pairing")
	end
	if not HaveRoster() or not self:IsOfficer(sender) then return Drop(self, "not from an officer") end
	local p = Pairs()
	if not p then return end
	local me, now = self:MyName(), Now()
	-- tos (tos-r5r6-build.md d): two officers may both answer our HELLO; a second catch-up whisper
	-- within 60 s is ignored (memory only; GUILD pairings from a click always count)
	if distribution == "WHISPER" then
		if self.budCatchupAt and now - self.budCatchupAt < CATCHUP_DUP_SECONDS then
			return Drop(self, "catch-up again")
		end
		self.budCatchupAt = now
	end
	local officer = IAmOfficer()
	local changed = false
	for i, e in ipairs(data.p) do
		if i > PAIRS_PER_MSG then break end
		local n = type(e) == "table" and Key(e.n)
		local b = type(e) == "table" and e.b ~= nil and Key(e.b) or nil
		local ts = type(e) == "table" and U.ValidTime(e.ts)
		local okNames = n and self:IsGuildMember(n) and (e.b == nil or (b and b ~= n and self:IsGuildMember(b)))
		if not okNames or not ts or ts < now - PAIR_DAYS * 86400 then
			Drop(self, "pairing names / time")
		else
			-- a quick second click is sent 1 s ahead (AssignBuddy); a time up to AHEAD_OK ahead is kept,
			-- so the later pairing wins here too (beta.4 test); further ahead = clamped to now
			if ts > now + AHEAD_OK then ts = now end
			local cur = p[n]
			if not cur or ts > cur.ts then
				local wasMine = cur and cur.b == me
				if officer or n == me or b == me then
					p[n] = { b = b, ts = ts, by = sender }
					changed = true
					if n == me and b and not (cur and cur.b == b) then self:Msg(L.BUD_YOU_ARE, U.ShortName(b)) end
					if b == me and not wasMine then self:Msg(L.BUD_YOU_HELP, U.ShortName(n)) end
				elseif wasMine then
					p[n] = { ts = ts, by = sender } -- not our pairing any more (and we don't keep who it is now)
					changed = true
				end
			end
		end
	end
	if changed then
		self.budStats.rbas = self.budStats.rbas + 1
		Refresh()
	end
end

-- Sync.lua HELLO (through RecruitOnHello): the first online officer with Guild Hub (by name)
-- whispers the pairings of the player who logged in, once per session per player.
function GH:BuddyOnHello(sender)
	if not On() or not IAmOfficer() or type(sender) ~= "string" then return end
	self.budAnswered = self.budAnswered or {}
	if self.budAnswered[sender] then return end
	local p = Pairs()
	if not p then return end
	local list = {}
	for n, e in pairs(p) do
		if e.b and (n == sender or e.b == sender) and #list < PAIRS_PER_MSG then list[#list + 1] = { n = n, b = e.b, ts = e.ts } end
	end
	if #list == 0 then return end
	local me = self:MyName()
	local officers = { me }
	for name in pairs(self.addonUsers or {}) do
		if name ~= me and name ~= sender and self:IsOfficer(name) and self:IsAddonUserOnline(name) then officers[#officers + 1] = name end
	end
	table.sort(officers)
	if officers[1] ~= me then return end
	self.budAnswered[sender] = true
	self:ScheduleTimer(function()
		if On() and IAmOfficer() and GH:IsOnline(sender) then GH:SendMsg("RBAS", { p = list }, sender) end
	end, HELLO_ANSWER_DELAY)
end

------------------------------------------------------------------------
-- What each one sees
------------------------------------------------------------------------
-- Seconds since the member was last online (0 = online now), from the guild window's own data;
-- nil when unknown (not in the list, hidden value, no API).
function GH:LastOnline(name)
	local m = self.roster and self.roster[name]
	if not m then return nil end
	if m.online then return 0 end
	if type(GetGuildRosterLastOnline) ~= "function" or type(m.idx) ~= "number" then return nil end
	local okI, rn = pcall(GetGuildRosterInfo, m.idx) -- the index must still point at this name
	if not okI or type(rn) ~= "string" or U.IsSecret(rn) or U.FullName(rn) ~= name then return nil end
	local ok, y, mo, d, h = pcall(GetGuildRosterLastOnline, m.idx)
	if not ok then return nil end
	local parts = { y, mo, d, h }
	for i = 1, 4 do
		local v = parts[i]
		if U.IsSecret(v) then return nil end
		parts[i] = (type(v) == "number" and v == v and v >= 0) and v or 0
	end
	return (((parts[1] * 365 + parts[2] * 30 + parts[3]) * 24) + parts[4]) * 3600
end

function GH:BuddyLastText(secs)
	if secs == nil then return L.BUD_LAST_UNKNOWN end
	if secs <= 0 then return L.BUD_ONLINE end
	return L.BUD_LAST:format(U.Ago(secs))
end

-- The new member's buddy (a name), or nil.
function GH:MyBuddy()
	local p = Pairs()
	local e = p and p[self:MyName()]
	if e and e.b and (not HaveRoster() or self:IsGuildMember(e.b)) then return e.b end
	return nil
end

-- The buddy's new guildies: { {name, last, ts} }, newest pairing first.
function GH:MyNewGuildies()
	local out = {}
	local p = Pairs()
	if not p then return out end
	local me = self:MyName()
	for n, e in pairs(p) do
		if e.b == me and (not HaveRoster() or self:IsGuildMember(n)) then
			out[#out + 1] = { name = n, last = self:LastOnline(n), ts = e.ts }
		end
	end
	table.sort(out, function(a, b) return a.ts > b.ts end)
	return out
end

-- When a member joined (in the last 14 days), or nil: the guild history's newest join, else its
-- joins table, else "first seen" when that came after the history started, else this session.
function GH:JoinedAt(name)
	local cut = Now() - NEW_DAYS * 86400
	local gdb = self:GetGuildDB()
	local rec = gdb and type(gdb.rec) == "table" and gdb.rec or nil
	local best
	if rec and type(rec.log) == "table" then
		for _, e in ipairs(rec.log) do
			if type(e) == "table" and e.ty == "join" and e.p1 == name and type(e.t) == "number" and e.t >= cut then
				if not best or e.t > best then best = e.t end
			end
		end
	end
	if not best and rec and type(rec.joins) == "table" and type(rec.joins[name]) == "number" and rec.joins[name] >= cut then
		best = rec.joins[name]
	end
	if not best and rec and type(rec.first) == "table" and type(rec.first[name]) == "number" and type(rec.started) == "number"
		and rec.first[name] > rec.started + 86400 and rec.first[name] >= cut then
		best = rec.first[name] -- not in the guild list the day the history started: a real newcomer
	end
	if not best and self.recentJoins and type(self.recentJoins[name]) == "table" then best = self.recentJoins[name].t end
	return best
end

-- Officers only (worked out here, never sent): new members with their last online and buddy.
-- { {name, class, joined, last, online, quiet, buddy} }, gone quiet first, then the newest.
function GH:NewMembers()
	local out = {}
	if not On() or not IAmOfficer() then return out end
	local p = Pairs() or {}
	local me = self:MyName()
	for name, m in pairs(self.roster) do
		local j = name ~= me and self:JoinedAt(name)
		if j then
			local last = self:LastOnline(name)
			local e = p[name]
			out[#out + 1] = { name = name, class = m.class, joined = j, last = last, online = m.online == true,
				quiet = last ~= nil and last >= QUIET_DAYS * 86400, buddy = e and e.b or nil }
		end
	end
	table.sort(out, function(a, b)
		if a.quiet ~= b.quiet then return a.quiet end
		if a.joined ~= b.joined then return a.joined > b.joined end
		return a.name < b.name
	end)
	return out
end

-- One chat line per login for a buddy while a pairing lasts.
function GH:BuddyLoginLine()
	if self.budLoginShown or not On() then return end
	self.budLoginShown = true
	local rows = self:MyNewGuildies()
	if #rows == 0 then return end
	local parts = {}
	for i = 1, math.min(3, #rows) do
		parts[#parts + 1] = L.BUD_GUILDIE_LINE:format(U.ShortName(rows[i].name), self:BuddyLastText(rows[i].last))
	end
	self:Msg(L.BUD_LOGIN, table.concat(parts, ", "))
end

-- Roster.lua (through RecruitRosterCheck): pairs of members who left go; a member's computer keeps
-- only its own pairings; the buddy's login line after the first guild list.
function GH:BuddyRosterCheck()
	if not On() then return end
	local r = self.RecruitData and self.RecruitData()
	if not r then return end
	Pairs()
	CleanPairs(r)
	if not self.budLoginPlanned then
		self.budLoginPlanned = true
		self:ScheduleTimer(function() GH:BuddyLoginLine() end, LOGIN_LINE_DELAY)
	end
end

------------------------------------------------------------------------
-- Messages, hooks and the self-test part
------------------------------------------------------------------------
local function SignupGate(gh) return gh:FeatureOn("recruit") and IsInGuild() end
local function AssignGate(gh, _, target)
	if not gh:FeatureOn("recruit") or not IAmOfficer() then return false end
	return target == nil or gh:IsGuildMember(target)
end
if GH.RECRUIT_OFF_MESSAGES then
	GH.RECRUIT_OFF_MESSAGES.RBSU = { class = "normal", min = 30, latest = true, gate = SignupGate }
	GH.RECRUIT_OFF_MESSAGES.RBAS = { class = "normal", min = 0, gate = AssignGate }
end
GH.handlers.RBSU = HandleSignup
GH.handlers.RBAS = HandleAssign

function GH:RecruitBuddyEnable()
	if self.rosterReady then self:BuddyRosterCheck() end
end

local EXPECT = { NEW_DAYS = 14, QUIET_DAYS = 4, PAIR_DAYS = 14, BUD_KEEP = 90 }
function GH:RecruitBuddySelfTest(api)
	api.Count()
	for k, v in pairs(EXPECT) do
		if self.RECRUIT_BUDDY_CAPS[k] ~= v then api.Problem("RECRUIT", "budcaps", k .. " is " .. tostring(self.RECRUIT_BUDDY_CAPS[k])) end
	end
	api.Count()
	local m = self.msgTypes.RBAS
	if not (m and m.gate and not m.officer) then api.Problem("RECRUIT", "buddy", "RBAS is not a gated type") end
	-- pairings: none older than 14 days; on a member's computer only their own
	api.Count()
	local p = Pairs() or {}
	local me, now, officer = self:MyName(), Now(), IAmOfficer()
	local nP, mine = 0, 0
	for n, e in pairs(p) do
		nP = nP + 1
		if e.ts < now - PAIR_DAYS * 86400 - 60 then api.Problem("RECRUIT", "buddy", "a pairing older than 14 days") break end
		if HaveRoster() and not officer and e.b ~= nil and n ~= me and e.b ~= me then api.Problem("RECRUIT", "buddy", "someone else's pairing on a member's computer") break end
		if e.b == me or n == me then mine = mine + 1 end
	end
	-- the quiet list: officers only
	api.Count()
	local newRows = self:NewMembers()
	if HaveRoster() and not officer and #newRows > 0 then api.Problem("RECRUIT", "quiet", "new-member list on a member's computer") end
	local quiet = 0
	for _, r in ipairs(newRows) do if r.quiet then quiet = quiet + 1 end end
	local buddies = #self:BuddyList()
	api.Info(("recruit buddy signed=%s buddies=%d pairs=%d mine=%d new=%d quiet=%d heard=%d/%d"):format(
		self:BuddySignedUp() and "y" or "n", buddies, nP, mine, #newRows, quiet, self.budStats.rbsu, self.budStats.rbas))
end
