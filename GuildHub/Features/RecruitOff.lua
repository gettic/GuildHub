-- Guild Hub: Guild Recruiter, beta R2 (plans\guild-recruiter\PLAN.md group B core, tos-plan.md).
-- Officers' lists about players outside the guild: Prospects and Don't invite, kept only on
-- officers' computers, shared on the OFFICER channel (ROFF) and caught up by whisper between
-- officers (RODQ / RODS). The name menu ("Guild Hub" group) adds Invite to guild, Add to
-- prospects and Don't invite for officers.
--
-- Rules kept here (tos-plan.md condition 9 and PLAN.md ground rules):
--  * Officer data: name, a fixed status word, the date and who set it. No free text. Deleted after
--    30 days. Never on GUILD: ROFF only on OFFICER, RODQ/RODS only by whisper between officers.
--    The officer rank is checked when we send (gate) and when we receive (our own guild list).
--  * Wiped from this computer when we are no longer an officer.
--  * Invite = one click = one C_GuildInfo.Invite. Caps first: 1 per player per 7 days, 10 per hour
--    (per account, failed tries count), never someone on Don't invite. Blocked by the game =
--    "/ginvite Name" in the chat box (the player presses Enter). Nothing is invited by an event.
-- R3: two more officer lists, Suggestions (rows from members' RSUG: name, who suggested, a fixed
-- class/role tag) and Trials (guild members: an end date; a reminder only, never promotes or
-- removes), same rules and channels; name menu: Start / End trial on members (officers).
-- Loaded before Features\Recruit.lua, which registers the feature with these messages.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

------------------------------------------------------------------------
-- Fixed caps (the self-test checks these values)
------------------------------------------------------------------------
local INVITE_TARGET_DAYS = 7
local INVITE_PER_HOUR = 10
local OUTSIDER_DAYS = 30
local PROS_MAX, DNI_MAX = 150, 200
local SYNC_MAX = 300       -- rows in one catch-up answer
local SYNC_CHARS = 24000   -- and at most this many characters (Comm drops > 30000)
local INVITE_WATCH = 3     -- seconds a blocked-call event still belongs to our invite
local ASK_DELAY = 20       -- seconds after the guild list is ready before we ask for the lists
local AHEAD_OK = 30        -- a received time may be this far ahead (quick edits go 1 s ahead each)
local SYNC_PAGES = 6       -- catch-up pages asked for in one session (RODQ p = 1; the answer says m = 1 when there is more)
GH.RECRUIT_AHEAD_OK = AHEAD_OK

-- R3: Suggestions (from members, RSUG) and Trials (guild members on trial: an end date and a
-- reminder; nothing is promoted or removed by the addon)
local SUG_MAX, TRIAL_MAX = 100, 50
local TRIAL_DAYS = { 7, 14, 30 }   -- the lengths an officer can pick
local TRIAL_LONGEST = 30           -- days: the end is never further than this from the change
local TRIAL_AFTER = 14             -- days an ended trial stays on the list (the reminder)

local STATUSES = { "new", "contacted", "trial", "no", "joined" }
local STATUS_OK = {}
for i, s in ipairs(STATUSES) do STATUS_OK[s] = i end
-- R6: Buddies (b): guild members who signed up themselves (RBSU, Features\RecruitBuddy.lua): name,
-- sign-up time, by = the member. Kept on officers' computers, caught up between officers by RODS,
-- dropped after 90 days without a new sign-up.
local BUD_MAX, BUD_KEEP = 100, 90
local LISTS = { p = "pros", d = "dni", g = "sug", t = "trial", b = "bud" }
local LIST_MAX = { p = PROS_MAX, d = DNI_MAX, g = SUG_MAX, t = TRIAL_MAX, b = BUD_MAX }
-- days a row is kept after its last change (a trial: the longest trial + the reminder days)
local KEEP_DAYS = { p = OUTSIDER_DAYS, d = OUTSIDER_DAYS, g = OUTSIDER_DAYS, t = TRIAL_LONGEST + TRIAL_AFTER, b = BUD_KEEP }
local CLASS_OK = {}
for _, c in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do CLASS_OK[c] = true end
local ROLE_OK = { t = true, h = true, d = true }
local MENU_TAGS = { "MENU_UNIT_PLAYER", "MENU_UNIT_FRIEND", "MENU_UNIT_CHAT_ROSTER", "MENU_UNIT_PARTY",
	"MENU_UNIT_RAID_PLAYER", "MENU_UNIT_TARGET" }

GH.RECRUIT_STATUSES = STATUSES
GH.RECRUIT_OFF_CAPS = { INVITE_TARGET_DAYS = INVITE_TARGET_DAYS, INVITE_PER_HOUR = INVITE_PER_HOUR,
	OUTSIDER_DAYS = OUTSIDER_DAYS, PROS_MAX = PROS_MAX, DNI_MAX = DNI_MAX, SYNC_MAX = SYNC_MAX,
	SUG_MAX = SUG_MAX, TRIAL_MAX = TRIAL_MAX, TRIAL_LONGEST = TRIAL_LONGEST, TRIAL_AFTER = TRIAL_AFTER,
	BUD_MAX = BUD_MAX, BUD_KEEP = BUD_KEEP, AHEAD_OK = AHEAD_OK, SYNC_PAGES = SYNC_PAGES }
GH.RECRUIT_TRIAL_DAYS = TRIAL_DAYS
GH.RECRUIT_CLASS_OK, GH.RECRUIT_ROLE_OK = CLASS_OK, ROLE_OK
GH.RECRUIT_MENU_TAGS = MENU_TAGS
GH.offStats = { roff = 0, rods = 0, dropped = 0, menuHooks = 0, invites = 0, fallback = 0 }

local function Now() return U.Now() end
local function On() return GH:FeatureOn("recruit") end
local function KeepFrom(l) return Now() - (KEEP_DAYS[l] or OUTSIDER_DAYS) * 86400 end

-- Officer by OUR guild list (never what a sender claims). Unknown before the list is read.
local function HaveRoster() return type(GH.roster) == "table" and next(GH.roster) ~= nil end
local function IAmOfficer()
	return IsInGuild() and HaveRoster() and GH:IsOfficer(GH:MyName()) or false
end
GH.RecruitIAmOfficer = IAmOfficer

-- May our rank write in officer chat? (an OFFICER send that the game refuses would pause the
-- message budget). Missing API = assume yes.
local function CanOfficerChat()
	local fn = C_GuildInfo and C_GuildInfo.CanSpeakInOfficerChat
	if type(fn) ~= "function" then return true end
	local ok, v = pcall(fn)
	if not ok or U.IsSecret(v) then return true end
	return v ~= false
end
GH.RecruitCanOfficerChat = CanOfficerChat

------------------------------------------------------------------------
-- The officer data: gdb.recruit.off = { pros = {[name] = {s, ts, by}}, dni = {[name] = {ts, by}},
-- sug = {[name] = {ts, by, fr, k, ro}} (R3: fr = the member who suggested, k = class word, ro = t/h/d),
-- trial = {[name] = {e, ts, by}} (R3: e = trial end),
-- del = {["p:Name"] = ts}, cut = {p = ts, d = ts, ...} (a list cleared at ts) }
------------------------------------------------------------------------
local function CleanRow(l, n, row, cut)
	if type(row) ~= "table" or not U.ValidName(n) then return nil end
	local ts, by = U.ValidTime(row.ts), U.ValidName(row.by)
	if not ts or not by or ts < cut then return nil end
	if l == "p" then
		if not STATUS_OK[row.s] then return nil end
		return { s = row.s, ts = ts, by = by }
	elseif l == "g" then
		local fr = U.ValidName(row.fr)
		if not fr then return nil end
		return { ts = ts, by = by, fr = fr, k = CLASS_OK[row.k] and row.k or nil, ro = ROLE_OK[row.ro] and row.ro or nil }
	elseif l == "t" then
		local e = row.e
		if type(e) ~= "number" or e ~= e or e < ts or e > ts + TRIAL_LONGEST * 86400 + 120 then return nil end
		if e < Now() - TRIAL_AFTER * 86400 then return nil end -- ended long ago
		return { e = math.floor(e), ts = ts, by = by }
	elseif l == "b" then
		if by ~= n then return nil end -- R6: only a member's own sign-up
	end
	return { ts = ts, by = by }
end

-- Trims a list to its max (the oldest go first).
local function Trim(list, max)
	local n = 0
	for _ in pairs(list) do n = n + 1 end
	while n > max do
		local oldName, oldTs
		for name, row in pairs(list) do
			if not oldTs or row.ts < oldTs then oldName, oldTs = name, row.ts end
		end
		list[oldName] = nil
		n = n - 1
	end
end

-- Repairs and prunes (rows older than 30 days, damaged rows, deletion marks).
function GH:CleanOffData(off)
	if type(off.cut) ~= "table" then off.cut = {} end
	for l in pairs(LISTS) do
		local c = U.ValidTime(off.cut[l])
		off.cut[l] = (c and c >= KeepFrom(l)) and c or nil
	end
	for k in pairs(off.cut) do if not LISTS[k] then off.cut[k] = nil end end
	for l, key in pairs(LISTS) do
		local src = type(off[key]) == "table" and off[key] or {}
		local dst = {}
		local cut = math.max(KeepFrom(l), off.cut[l] or 0)
		for n, row in pairs(src) do
			local r = CleanRow(l, n, row, cut)
			if r then dst[n] = r end
		end
		Trim(dst, LIST_MAX[l])
		off[key] = dst
	end
	local del = type(off.del) == "table" and off.del or {}
	off.del = {}
	for k, ts in pairs(del) do
		ts = U.ValidTime(ts)
		local l = type(k) == "string" and k:sub(1, 1)
		if l and LISTS[l] and k:sub(2, 2) == ":" and U.ValidName(k:sub(3)) and ts and ts >= KeepFrom(l) then
			off.del[k] = ts
		end
	end
	local known = { del = true, cut = true }
	for _, key in pairs(LISTS) do known[key] = true end
	for k in pairs(off) do
		if not known[k] then off[k] = nil end
	end
end

-- The officer tables (nil when we are not an officer; wiped then). create: make them if missing.
function GH:RecruitOff(create)
	local r = self.RecruitData and self.RecruitData()
	if not r or not HaveRoster() then return nil end
	if not IAmOfficer() then
		if r.off ~= nil then r.off = nil; self:Debug("officer lists removed (no longer an officer)") end
		return nil
	end
	if type(r.off) ~= "table" then
		if not create then return nil end
		r.off = {}
	end
	self.offChecked = self.offChecked or {}
	if not self.offChecked[r.off] then
		self.offChecked[r.off] = true
		self:CleanOffData(r.off)
	end
	return r.off
end

-- Applies one row (ours, ROFF or RODS). row = { l = "p"|"d", n = name, s = status, ts, by,
-- x = true (removed), c = true (whole list cleared) }. Returns true when something changed.
-- own = our own edit (its time may be a second or two ahead, to order quick edits); a received
-- time is clamped to now.
function GH:ApplyOffRow(off, row, own)
	if type(row) ~= "table" or not LISTS[row.l] then return false end
	local l, list = row.l, off[LISTS[row.l]]
	local now = Now()
	local ts = U.ValidTime(row.ts)
	local by = U.ValidName(row.by)
	if not ts or not by then return false end
	local shift = 0
	-- beta.4 test: a quick second edit is sent 1 s ahead (Edit); a received time up to AHEAD_OK ahead
	-- is kept as it is, so the later edit wins everywhere (old clients still clamp: no harm)
	if ts > now + (own and 120 or AHEAD_OK) then shift = ts - now; ts = now end
	if ts < KeepFrom(l) then return false end
	local cut = off.cut[l] or 0
	if row.c == true then
		if ts <= cut then return false end
		off.cut[l] = ts
		for n, r in pairs(list) do if r.ts <= ts then list[n] = nil end end
		return true
	end
	local n = U.ValidName(row.n)
	if not n or ts <= cut then return false end
	local key = l .. ":" .. n
	local cur = list[n]
	if row.x == true then
		if (off.del[key] or 0) >= ts or (cur and cur.ts >= ts) then return false end
		off.del[key] = ts
		list[n] = nil
		return true
	end
	if (off.del[key] or 0) >= ts or (cur and cur.ts >= ts) then return false end
	local e = row.e
	if l == "t" and type(e) == "number" then e = e - shift end -- a clamped time moves the end with it
	local new = CleanRow(l, n, { s = row.s, ts = ts, by = by, fr = row.fr, k = row.k, ro = row.ro, e = e }, 0)
	if not new then return false end
	list[n] = new
	off.del[key] = nil
	Trim(list, LIST_MAX[l])
	return true
end

function GH:RefreshOfficerLists()
	if self.DrawRecruitPage then self:DrawRecruitPage() end
end

-- Our own edit: applied here, then sent on OFFICER (only officers; the gate checks again).
local function Edit(row)
	if not On() or not IAmOfficer() then return false, "officer" end
	local off = GH:RecruitOff(true)
	if not off then return false, "officer" end
	local list = off[LISTS[row.l]]
	local cur = row.n and list[row.n]
	local ts = Now()
	if cur and cur.ts >= ts then ts = cur.ts + 1 end
	local del = row.n and off.del[row.l .. ":" .. row.n]
	if del and del >= ts then ts = del + 1 end
	if row.c and (off.cut[row.l] or 0) >= ts then ts = off.cut[row.l] + 1 end
	row.ts, row.by = ts, GH:MyName()
	if not GH:ApplyOffRow(off, row, true) then return false, "same" end
	GH:SendMsg("ROFF", row)
	GH:RefreshOfficerLists()
	return true
end

local function Key(name) return U.ValidName(U.FullName(name)) end
GH.RecruitNameKey = Key

function GH:SetProspect(name, status)
	local n = Key(name)
	if not n or not STATUS_OK[status or "new"] then return false, "name" end
	return Edit({ l = "p", n = n, s = status or "new" })
end

function GH:RemoveProspect(name)
	local n = Key(name)
	if not n then return false, "name" end
	return Edit({ l = "p", n = n, x = true })
end

-- Don't invite: also takes them off Prospects.
function GH:SetDontInvite(name, on)
	local n = Key(name)
	if not n then return false, "name" end
	if on then
		local off = self:RecruitOff()
		if off and off.pros[n] then self:RemoveProspect(n) end
		if off and off.sug and off.sug[n] then self:RemoveSuggestion(n) end
		return Edit({ l = "d", n = n })
	end
	return Edit({ l = "d", n = n, x = true })
end

function GH:ClearOffList(l)
	if not LISTS[l] then return false end
	return Edit({ l = l, c = true })
end

-- Status cycle for the page: new -> contacted -> trial -> no -> joined -> new.
function GH:NextProspectStatus(name)
	local off = self:RecruitOff()
	local row = off and off.pros[name]
	if not row then return false end
	local i = STATUS_OK[row.s] or 0
	return self:SetProspect(name, STATUSES[i % #STATUSES + 1])
end

-- R3 Suggestions: kept by the officer who got the RSUG (by = that officer), shared like the others.
function GH:AddSuggestion(name, from, class, role)
	local n, fr = Key(name), U.ValidName(from)
	if not n or not fr then return false, "name" end
	return Edit({ l = "g", n = n, fr = fr, k = CLASS_OK[class] and class or nil, ro = ROLE_OK[role] and role or nil })
end

function GH:RemoveSuggestion(name)
	local n = Key(name)
	if not n then return false, "name" end
	return Edit({ l = "g", n = n, x = true })
end

-- "+ Prospect" on a suggestion: a new prospect, and the suggestion goes.
function GH:SuggestionToProspect(name)
	local n = Key(name)
	if not n then return false, "name" end
	if self:IsDontInvite(n) then return false, "dni" end
	local ok, why = self:SetProspect(n, "new")
	if ok or why == "same" then self:RemoveSuggestion(n) end
	return ok, why
end

-- R3 Trials: guild members (not officers) on trial. The addon only reminds; it never promotes or
-- removes anyone. days = one of TRIAL_DAYS (from now); extend = the end moves out by `days` (at
-- most TRIAL_LONGEST days from now).
local function TrialOk(gh, n)
	return n and n ~= gh:MyName() and gh:IsGuildMember(n) and not gh:IsOfficer(n)
end

function GH:SetTrial(name, days, extend)
	local n = Key(name)
	local okDays = false
	for _, d in ipairs(TRIAL_DAYS) do if d == days then okDays = true end end
	if not okDays or not TrialOk(self, n) then return false, "name" end
	local now = Now()
	local e = now + days * 86400
	if extend then
		local off = self:RecruitOff()
		local cur = off and off.trial[n]
		if cur then e = math.max(cur.e, now) + days * 86400 end
	end
	e = math.min(e, now + TRIAL_LONGEST * 86400)
	return Edit({ l = "t", n = n, e = e })
end

function GH:EndTrial(name)
	local n = Key(name)
	if not n then return false, "name" end
	return Edit({ l = "t", n = n, x = true })
end

function GH:OnTrial(name)
	local off = self:RecruitOff()
	local n = Key(name)
	return off ~= nil and n ~= nil and off.trial[n] ~= nil
end

-- Trials that ended or end within a day, members still in the guild (for the reminder line).
function GH:TrialsDue()
	local out = {}
	local now = Now()
	for _, r in ipairs(self:OffRows("t")) do
		if r.e <= now + 86400 and self:IsGuildMember(r.name) then out[#out + 1] = r end
	end
	table.sort(out, function(a, b) return a.e < b.e end)
	return out
end

-- Sorted rows for the page: { name, s, ts, by, fr, k, ro, e }, newest first (trials: soonest end first).
function GH:OffRows(l)
	local off = self:RecruitOff()
	local out = {}
	if not off or not LISTS[l] then return out end
	for n, r in pairs(off[LISTS[l]] or {}) do
		out[#out + 1] = { name = n, s = r.s, ts = r.ts, by = r.by, fr = r.fr, k = r.k, ro = r.ro, e = r.e }
	end
	if l == "t" then
		table.sort(out, function(a, b) if a.e ~= b.e then return a.e < b.e end return a.name < b.name end)
	else
		table.sort(out, function(a, b) if a.ts ~= b.ts then return a.ts > b.ts end return a.name < b.name end)
	end
	return out
end

function GH:IsDontInvite(name)
	local off = self:RecruitOff()
	local n = Key(name)
	return off ~= nil and n ~= nil and off.dni[n] ~= nil
end

------------------------------------------------------------------------
-- Messages: ROFF (OFFICER), RODQ / RODS (whisper, officer to officer)
------------------------------------------------------------------------
local function HandleOff(self, sender, data, distribution, isSelf)
	if isSelf then return end
	-- Comm.lua already drops ROFF that isn't on OFFICER; checked again here
	if distribution ~= "OFFICER" or not IAmOfficer() or not self:IsOfficer(sender) or type(data) ~= "table" then
		self.offStats.dropped = self.offStats.dropped + 1
		return
	end
	if data.by ~= sender then self.offStats.dropped = self.offStats.dropped + 1 return end -- own rows only
	if data.l == "b" then self.offStats.dropped = self.offStats.dropped + 1 return end -- R6: buddies sign up themselves (RBSU)
	local off = self:RecruitOff(true)
	if off and self:ApplyOffRow(off, data) then
		self.offStats.roff = self.offStats.roff + 1
		self:RefreshOfficerLists()
	end
end

-- The rows another officer may be missing (changed after `since`), capped; sent oldest first.
-- Old ask (no paging): the newest rows. paged (beta.4 test fix): the OLDEST rows after `since`, and
-- more = true when rows were left out (the asker then asks again from the last row's time).
function GH:OffSyncRows(since, paged)
	local off = self:RecruitOff()
	local rows = {}
	if not off then return rows, false end
	since = U.ValidTime(since) or 0
	for l, key in pairs(LISTS) do
		if (off.cut[l] or 0) > since then rows[#rows + 1] = { l = l, c = true, ts = off.cut[l], by = self:MyName() } end
		for n, r in pairs(off[key]) do
			if r.ts > since then
				rows[#rows + 1] = { l = l, n = n, s = r.s, ts = r.ts, by = r.by, fr = r.fr, k = r.k, ro = r.ro, e = r.e }
			end
		end
	end
	for k, ts in pairs(off.del) do
		if ts > since then rows[#rows + 1] = { l = k:sub(1, 1), n = k:sub(3), x = true, ts = ts, by = self:MyName() } end
	end
	if paged then
		table.sort(rows, function(a, b) return a.ts < b.ts end)
	else
		table.sort(rows, function(a, b) return a.ts > b.ts end)
	end
	local out, chars = {}, 0
	for _, r in ipairs(rows) do
		chars = chars + 50 + #(r.n or "") + #(r.by or "") + #(r.fr or "")
		if #out >= SYNC_MAX or chars > SYNC_CHARS then break end
		out[#out + 1] = r
	end
	local more = #out < #rows
	if paged then return out, more end
	-- oldest first on the other side, so a later deletion wins over an earlier row
	local rev = {}
	for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
	return rev, more
end

local function HandleAsk(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "WHISPER" or not On() then return end
	if not IAmOfficer() or not self:IsOfficer(sender) then self.offStats.dropped = self.offStats.dropped + 1 return end
	local paged = type(data) == "table" and data.p == 1
	local rows, more = self:OffSyncRows(type(data) == "table" and data.since, paged)
	if #rows > 0 then self:SendMsg("RODS", { r = rows, m = (paged and more) and 1 or nil }, sender) end
end

-- The next page of a catch-up: only from the ONE officer we asked, only while it says there is more,
-- at most SYNC_PAGES asks per session (RODQ keeps its 60 s gap per officer).
local function AskNextPage(self, sender, rows)
	local pg = self.offPaging
	if not pg or pg.to ~= sender or pg.n >= SYNC_PAGES then return end
	local last = 0
	for _, row in ipairs(rows) do
		local ts = type(row) == "table" and U.ValidTime(row.ts)
		if ts and ts > last then last = ts end
	end
	-- from the last row's second again (rows of that second may be cut; doubles change nothing)
	local since = last - 1
	if since <= pg.since then self.offPaging = nil return end -- no progress: stop
	pg.since, pg.n = since, pg.n + 1
	self:SendMsg("RODQ", { since = since, p = 1 }, sender)
end

local function HandleSync(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "WHISPER" or type(data) ~= "table" or type(data.r) ~= "table" then return end
	if not IAmOfficer() or not self:IsOfficer(sender) then self.offStats.dropped = self.offStats.dropped + 1 return end
	local off = self:RecruitOff(true)
	if not off then return end
	local n, changed = 0, 0
	for _, row in ipairs(data.r) do
		n = n + 1
		if n > SYNC_MAX then break end
		if self:ApplyOffRow(off, row) then changed = changed + 1 end
	end
	self.offStats.rods = self.offStats.rods + 1
	self:Debug("officer lists from %s: %d changed", U.ShortName(sender), changed)
	if changed > 0 then self:RefreshOfficerLists() end
	if data.m == 1 then AskNextPage(self, sender, data.r) else self.offPaging = nil end
end

-- Once per session, after the guild list: ask ONE online officer with Guild Hub (the first by
-- name) for the rows changed since our newest one.
function GH:AskOfficerLists()
	if self.offAsked or not On() or not IAmOfficer() then return end
	local me, list = self:MyName(), {}
	for name in pairs(self.addonUsers) do
		if name ~= me and self:IsOfficer(name) and self:IsAddonUserOnline(name) then list[#list + 1] = name end
	end
	if #list == 0 then return end
	table.sort(list)
	self.offAsked = true
	local off = self:RecruitOff(true)
	local since = 0
	for l, key in pairs(LISTS) do
		since = math.max(since, off.cut[l] or 0)
		for _, r in pairs(off[key]) do since = math.max(since, r.ts) end
	end
	for _, ts in pairs(off.del) do since = math.max(since, ts) end
	since = since > 0 and since - 60 or 0
	self.offPaging = { to = list[1], since = since - 1, n = 1 } -- p = 1: the answer comes oldest first, in pages
	self:SendMsg("RODQ", { since = since, p = 1 }, list[1])
end

-- Message gates (checked when asked and again right before the real send)
local function OffGate(gh) return IAmOfficer() and CanOfficerChat() and gh:FeatureOn("recruit") end
local function WhisperGate(gh, _, target) return IAmOfficer() and type(target) == "string" and gh:IsOfficer(target) end

GH.RECRUIT_OFF_MESSAGES = {
	ROFF = { class = "normal", min = 0, officer = true, gate = OffGate }, -- every edit goes (no "latest")
	RODQ = { class = "normal", min = 60, gate = WhisperGate },
	RODS = { class = "bulk", min = 0, gate = WhisperGate },
}

------------------------------------------------------------------------
-- Invite to guild (one click, caps first)
------------------------------------------------------------------------
-- The per-account caps: inv = {[name] = ts}, invHour = {ts...}. A damaged entry = "just used".
function GH:InviteCaps()
	local c = self.RecruitCaps()
	local now = Now()
	-- A damaged per-player list can't tell who was invited: read it strict by filling the hourly
	-- list to the limit (no invites for an hour). The hourly list's own entries are kept, and a
	-- good per-player list is never emptied here.
	local lockHour = false
	if c.inv ~= nil and type(c.inv) ~= "table" then c.inv = {}; lockHour = true end
	c.inv = c.inv or {}
	for n, ts in pairs(c.inv) do
		if type(n) ~= "string" then c.inv[n] = nil
		elseif type(ts) ~= "number" or ts ~= ts or ts > now then c.inv[n] = now
		elseif ts < now - INVITE_TARGET_DAYS * 86400 then c.inv[n] = nil end
	end
	if c.invHour ~= nil and type(c.invHour) ~= "table" then c.invHour = {} for _ = 1, INVITE_PER_HOUR do c.invHour[#c.invHour + 1] = now end end
	c.invHour = c.invHour or {}
	for i = #c.invHour, 1, -1 do
		local t = c.invHour[i]
		if type(t) ~= "number" or t ~= t or t > now then c.invHour[i] = now
		elseif t < now - 3600 then table.remove(c.invHour, i) end
	end
	if lockHour then
		while #c.invHour < INVITE_PER_HOUR do c.invHour[#c.invHour + 1] = now end
	end
	return c
end

local function Minutes(sec) return math.max(1, math.ceil(sec / 60)) end

-- Why we can't invite this player now (nil = we can). Officers only: they hold Don't invite.
function GH:GuildInviteBlock(name)
	if not On() then return L.AD_FEATURE_OFF end
	if not IsInGuild() then return L.NOT_IN_GUILD end
	local n = Key(name)
	if not n then return L.INV_BAD_NAME end
	if n == self:MyName() or self:IsGuildMember(n) then return L.INV_IN_GUILD end
	if not IAmOfficer() then return L.INV_OFFICERS end
	if type(CanGuildInvite) ~= "function" or not (C_GuildInfo and type(C_GuildInfo.Invite) == "function") then return L.INV_NO_API end
	local okC, can = pcall(CanGuildInvite)
	if not okC or can ~= true then return L.INV_NO_RIGHT end
	if InCombatLockdown() then return L.MAC_COMBAT end
	if self:IsDontInvite(n) then return L.INV_DNI end
	local c, now = self:InviteCaps(), Now()
	local last = c.inv[n]
	if last then return L.INV_TARGET_WAIT:format(math.ceil((INVITE_TARGET_DAYS * 86400 - (now - last)) / 86400)) end
	if #c.invHour >= INVITE_PER_HOUR then
		local oldest = now
		for _, t in ipairs(c.invHour) do oldest = math.min(oldest, t) end
		return L.INV_HOUR_WAIT:format(INVITE_PER_HOUR, Minutes(3600 - (now - oldest)))
	end
	return nil
end

local function OpenChatWith(text)
	local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
	if open then return pcall(open, text) end
	return false
end

local function Fallback(p)
	if not p or p.done then return end
	p.done = true
	GH.offStats.fallback = GH.offStats.fallback + 1
	GH:Msg(L.INV_FALLBACK)
	OpenChatWith("/ginvite " .. U.WhisperName(p.name))
end

-- The click. Exactly one C_GuildInfo.Invite (or the chat-box fallback), or a line saying why not.
function GH:GuildInvite(name)
	local why = self:GuildInviteBlock(name)
	if why then self:Msg(why) return false end
	local n = Key(name)
	local c, now = self:InviteCaps(), Now()
	c.inv[n] = now -- counts before the call: a failed try counts too
	c.invHour[#c.invHour + 1] = now
	local p = { name = n, t = GetTime() }
	self.guildInvitePending = p
	local function Blocked(_, addon)
		if addon ~= "GuildHub" or GH.guildInvitePending ~= p then return end
		GH.chatPostBlockedAt = GetTime() -- MapPins: an expected refusal, not taint
		Fallback(p)
	end
	self:On("ginvite", "ADDON_ACTION_BLOCKED", Blocked)
	self:On("ginvite", "ADDON_ACTION_FORBIDDEN", Blocked)
	C_Timer.After(INVITE_WATCH, function()
		if GH.guildInvitePending == p then
			GH.guildInvitePending = nil
			GH:Off("ginvite")
		end
	end)
	self.offStats.invites = self.offStats.invites + 1
	local ok = pcall(C_GuildInfo.Invite, U.WhisperName(n))
	if not ok then Fallback(p) elseif not p.done then self:Msg(L.INV_SENT, U.ShortName(n)) end
	-- a prospect that was "new" is now "contacted"
	local off = self:RecruitOff()
	if off and off.pros[n] and off.pros[n].s == "new" then self:SetProspect(n, "contacted") end
	self:RefreshOfficerLists()
	return true
end

------------------------------------------------------------------------
-- The name menu: one "Guild Hub" group for officers, on players outside the guild
------------------------------------------------------------------------
local function MenuName(ctx)
	if type(ctx) ~= "table" then return nil end
	local full
	local util = UnitPopupSharedUtil
	if type(util) == "table" and type(util.GetFullPlayerName) == "function" then
		local ok, v = pcall(util.GetFullPlayerName, ctx)
		if ok and type(v) == "string" and not U.IsSecret(v) then full = v end
	end
	if not full and type(ctx.name) == "string" and not U.IsSecret(ctx.name) then full = ctx.name end
	if not full or full == "" then return nil end
	return full
end

local function Disable(elem, why)
	if not elem then return end
	if elem.SetEnabled then pcall(elem.SetEnabled, elem, false) end
	if why and elem.SetTooltip then
		pcall(elem.SetTooltip, elem, function(tooltip) tooltip:AddLine(why, 1, 0.5, 0.25, true) end)
	end
end

local function Group(root)
	if root.CreateDivider then root:CreateDivider() end
	if root.CreateTitle then root:CreateTitle(L.MENU_TITLE) end
end

-- R3: officers on a guild member's name (not an officer): Start trial (7 / 14 / 30 days) or End trial.
function GH:TrialMenu(root, n)
	Group(root)
	local why = (not CanOfficerChat()) and L.OFF_NO_OCHAT_SHORT or nil
	local b
	if self:OnTrial(n) then
		b = root:CreateButton(L.MENU_TRIAL_END, function() GH:EndTrial(n) end)
	else
		b = root:CreateButton(L.MENU_TRIAL_START)
		if b and b.CreateButton then
			for _, d in ipairs(TRIAL_DAYS) do
				local sub = b:CreateButton(L.MENU_TRIAL_DAYS:format(d), function() GH:SetTrial(n, d) end)
				if why then Disable(sub, why) end
			end
		end
	end
	if why then Disable(b, why) end
	return 1
end

-- Fills the group (also used by the tests with a fake description). Returns the number of entries.
-- Officers: outsiders get Invite / Prospects / Don't invite, members (not officers) get Trials.
-- Members (R3): outsiders get Suggest to officers (Features\RecruitTools.lua).
function GH:RecruitMenu(root, ctx)
	if not On() or not IsInGuild() or not HaveRoster() or type(root) ~= "table" then return 0 end
	local full = MenuName(ctx)
	local n = full and Key(full)
	if not n or n == self:MyName() then return 0 end
	local officer = IAmOfficer()
	if self:IsGuildMember(n) then
		if officer and not self:IsOfficer(n) then return self:TrialMenu(root, n) end
		return 0
	end
	if not officer then
		if self.SuggestMenu then return self:SuggestMenu(root, n, ctx) end
		return 0
	end
	Group(root)
	local why = self:GuildInviteBlock(n)
	local b = root:CreateButton(L.MENU_INVITE, function() GH:GuildInvite(n) end)
	if why then Disable(b, why) end
	local off = self:RecruitOff(true)
	local inPros = off and off.pros[n] ~= nil
	local inDni = off and off.dni[n] ~= nil
	local canEdit = CanOfficerChat() and nil or L.OFF_NO_OCHAT_SHORT
	local p
	if inPros then
		p = root:CreateButton(L.MENU_PROS_REMOVE, function() GH:RemoveProspect(n) end)
	else
		p = root:CreateButton(L.MENU_PROS_ADD, function() GH:SetProspect(n, "new") end)
		if inDni then Disable(p, L.INV_DNI) end
	end
	local d = root:CreateButton(inDni and L.MENU_DNI_REMOVE or L.MENU_DNI_ADD, function() GH:SetDontInvite(n, not inDni) end)
	if canEdit then Disable(p, canEdit); Disable(d, canEdit) end
	return 3
end

-- Installed once per session; the callback checks the feature switch itself (it can't be removed).
function GH:InitRecruitMenu()
	if self.recruitMenuHooked then return end
	if not (Menu and type(Menu.ModifyMenu) == "function") then return end
	self.recruitMenuHooked = true
	for _, tag in ipairs(MENU_TAGS) do
		local ok = pcall(Menu.ModifyMenu, tag, function(_, root, ctx)
			local okM, err = pcall(GH.RecruitMenu, GH, root, ctx)
			if not okM then GH:Debug("name menu: %s", U.CleanText(tostring(err), 120) or "?") end
		end)
		if ok then self.offStats.menuHooks = self.offStats.menuHooks + 1 end
	end
end

------------------------------------------------------------------------
-- Feature hooks (called from Features\Recruit.lua)
------------------------------------------------------------------------
function GH:RecruitOffEnable()
	self:InitRecruitMenu()
	self:Every("recruit", "offtidy", 600, function()
		local r = GH.RecruitData and GH.RecruitData()
		if r and r.off then GH.offChecked = nil; GH:RecruitOff() end -- re-prune (30 days)
	end)
	if self.rosterReady then self:ScheduleTimer(function() GH:AskOfficerLists() end, ASK_DELAY) end
end

function GH:RecruitOffDisable()
	self:Off("ginvite")
	self.guildInvitePending = nil
end

-- R3: one chat line per session for officers when a trial ended or ends within a day. Only a
-- reminder: promoting (or not) is the officer's own click in the game's guild window.
function GH:TrialReminder()
	if self.trialReminded or not On() or not IAmOfficer() then return end
	self.trialReminded = true
	local due = self:TrialsDue()
	if #due == 0 then return end
	local now, parts = Now(), {}
	for i = 1, math.min(3, #due) do
		local r = due[i]
		local left = r.e - now
		parts[#parts + 1] = left > 0 and L.TRIAL_ENDS_IN:format(U.ShortName(r.name), U.Ago(left))
			or L.TRIAL_ENDED_AGO:format(U.ShortName(r.name), U.Ago(-left))
	end
	if #due > 3 then parts[#parts + 1] = L.TRIAL_MORE:format(#due - 3) end
	self:Msg(L.TRIAL_REMIND, table.concat(parts, ", "))
end

-- Roster.lua (through RecruitRosterCheck): first list → ask later; no longer officer → wipe.
function GH:RecruitOffRosterCheck()
	if not self.offRosterSeen then
		self.offRosterSeen = true
		if On() then
			self:ScheduleTimer(function() GH:AskOfficerLists() end, ASK_DELAY)
			self:ScheduleTimer(function() GH:TrialReminder() end, ASK_DELAY + 40) -- after the catch-up
		end
	end
	self:RecruitOff() -- wipes when we are no longer an officer
end

-- Self-test part (called by the recruit feature's selftest).
local EXPECT = { INVITE_TARGET_DAYS = 7, INVITE_PER_HOUR = 10, OUTSIDER_DAYS = 30, PROS_MAX = 150, DNI_MAX = 200, SYNC_MAX = 300,
	SUG_MAX = 100, TRIAL_MAX = 50, TRIAL_LONGEST = 30, TRIAL_AFTER = 14, AHEAD_OK = 30, SYNC_PAGES = 6 }
function GH:RecruitOffSelfTest(api)
	api.Count()
	for k, v in pairs(EXPECT) do
		if self.RECRUIT_OFF_CAPS[k] ~= v then api.Problem("RECRUIT", "offcaps", k .. " is " .. tostring(self.RECRUIT_OFF_CAPS[k])) end
	end
	api.Count()
	local r = self.RecruitData and self.RecruitData()
	if r and r.off ~= nil and self.rosterReady and not IAmOfficer() then
		api.Problem("RECRUIT", "offdata", "officer lists on a non-officer's computer")
	end
	api.Count()
	local off = self:RecruitOff()
	local keep, nP, nD, nG, nT = KeepFrom("p"), 0, 0, 0, 0
	if off then
		for _, row in pairs(off.pros) do nP = nP + 1; if row.ts < keep then api.Problem("RECRUIT", "offdata", "a prospect older than 30 days") break end end
		for _, row in pairs(off.dni) do nD = nD + 1; if row.ts < keep then api.Problem("RECRUIT", "offdata", "a don't-invite row older than 30 days") break end end
		api.Count()
		for _, row in pairs(off.sug) do
			nG = nG + 1
			if row.ts < keep then api.Problem("RECRUIT", "offdata", "a suggestion older than 30 days") break end
		end
		api.Count()
		for _, row in pairs(off.trial) do
			nT = nT + 1
			if row.e > row.ts + TRIAL_LONGEST * 86400 + 120 then api.Problem("RECRUIT", "trial", "a trial longer than 30 days") break end
		end
	end
	api.Count()
	local m = self.RECRUIT_OFF_MESSAGES
	if not (self.msgTypes.ROFF and self.msgTypes.ROFF.officer and m.ROFF.gate) then api.Problem("RECRUIT", "offchannel", "ROFF is not an officer-channel type") end
	api.Count()
	if self.recruitMenuHooked and self.offStats.menuHooks > #MENU_TAGS then api.Problem("RECRUIT", "menu", "menu hooked twice") end
	local c = self:InviteCaps()
	api.Info(("recruit off officer=%s pros=%d dni=%d sug=%d trial=%d inv=%d/%dh menu=%d ochat=%s heard=%d/%d"):format(
		IAmOfficer() and "y" or "n", nP, nD, nG, nT, #c.invHour, INVITE_PER_HOUR, self.offStats.menuHooks,
		CanOfficerChat() and "y" or "n", self.offStats.roff, self.offStats.rods))
end

GH.handlers.ROFF = HandleOff
GH.handlers.RODQ = HandleAsk
GH.handlers.RODS = HandleSync
