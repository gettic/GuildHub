-- Guild Hub: raid night (1.0.1, plans\next-batch-1.0.x X2; tos: plans\next-batch-1.0.x\tos-check.md).
-- Part of the "raid" feature (Features\Raid.lua registers it; this file adds to it):
--   * the Tonight view's data: the next guild event from the game calendar, your answer (Sign up /
--     Tentative / Decline: ONE calendar call per click), sign-up counts from Blizzard's invite list
--     (read with OpenEvent at most once per view open or Refresh, >= 10 s apart, never with the
--     calendar open, in combat or in lockdown; CloseEvent after; secret = "unavailable"; nothing from
--     the list is sent or saved; names never kept)
--   * the summon queue: raid members not at the raid yet (GetRaidRosterInfo zones: display only, only
--     while in that raid, never sent, saved or logged; secret = "?")
--   * own ticks (bundle field tk): 1 need summon, 2 can click, 4 late 15 min
--   * Need a rez (Status.lua preset "rez"): cleared when alive again / after 10 min; a note only on the
--     client of a player who ticked "Rez available" (priest, paladin, shaman, druid)
--   * hearthstone location (bundle field hs, own share line, follows the position answer)
--   * the "New in 1.0.1" card (once per version, can be turned off, waits for combat / instances)
-- Never: CreateEvent, EventInvite, mass invites, moderator calls, AcceptResurrect, summons, whispers.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local band, bor, bnot = bit.band, bit.bor, bit.bnot
local floor = math.floor

local TK_SUMMON, TK_CLICK, TK_LATE = 1, 2, 4
GH.TK = { summon = TK_SUMMON, click = TK_CLICK, late = TK_LATE }
local TICK_SECONDS = 6 * 3600      -- ticks end by themselves after 6 h
local READ_COOLDOWN = 10           -- seconds between two invite-list reads (tos)
local EVENT_DAYS = 7
local INVITE_MAX = 200
local REZ_GAP = 600                -- one rez note per dead player per 10 min
local HEALERS = { PRIEST = true, PALADIN = true, SHAMAN = true, DRUID = true }
local NEWIN_KEY = "1.0.1"
GH.NEWIN_KEY = NEWIN_KEY

local function Plain(v) return v ~= nil and not U.IsSecret(v) end
local function Char() return GH.db and GH.db.char end

------------------------------------------------------------------------
-- Own ticks (char.raidTicks = { v = bits, ts = server time })
------------------------------------------------------------------------
function GH:RaidTicks()
	local c = Char()
	local t = c and c.raidTicks
	if type(t) ~= "table" or type(t.v) ~= "number" or type(t.ts) ~= "number" then return 0 end
	if U.Now() - t.ts > TICK_SECONDS then return 0 end
	return band(t.v, 7)
end

function GH:RaidTick(b) return band(self:RaidTicks(), b) ~= 0 end

function GH:SetRaidTick(b, on)
	local v = self:RaidTicks()
	v = on and bor(v, b) or band(v, bnot(b))
	Char().raidTicks = v > 0 and { v = v, ts = U.Now() } or nil
	if self.BundleChanged then self:BundleChanged("tk") end
	self.raidLastTk = v
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
	if self.UpdateOwnPanel then self:UpdateOwnPanel() end
end

------------------------------------------------------------------------
-- Dead or alive (secret-safe) and Need a rez
------------------------------------------------------------------------
function GH:PlayerDead()
	if type(UnitIsDeadOrGhost) ~= "function" then return false end
	local ok, dead = pcall(UnitIsDeadOrGhost, "player")
	return ok and Plain(dead) and dead and true or false
end

local function OwnClass()
	local ok, _, token = pcall(UnitClass, "player")
	return ok and Plain(token) and token or nil
end

function GH:CanRez() return HEALERS[OwnClass() or ""] == true end

function GH:RezAvailable()
	local c = Char()
	return c and c.rezAvail == true and self:CanRez() or false
end

-- Alive again (or released and resurrected): our own Need a rez clears itself. Always on (the preset
-- is part of the status board, which can't be switched off).
local function OnAlive()
	if GH:PlayerDead() then return end
	local own = GH.GetOwnStatus and GH:GetOwnStatus()
	if own and own.p == "rez" and GH:IsStatusFresh(own) then
		GH:ClearStatus()
		if GH.UpdateOwnPanel then GH:UpdateOwnPanel(true) end
	end
end
GH:On("rez", "PLAYER_ALIVE", OnAlive)
GH:On("rez", "PLAYER_UNGHOST", OnAlive)

-- Status.lua MaybeAlert: someone just set Need a rez. Only a healer who ticked Rez available gets a
-- note, at most one per dead player per 10 min, through the toast queue (quiet rules: never in combat).
GH.lastRezAlert = {}
GH.rezStats = { notes = 0, skipped = 0 }
function GH:MaybeRezAlert(sender, st)
	if not self:FeatureOn("raid") or not self:RezAvailable() or not self:IsStatusFresh(st) then
		self.rezStats.skipped = self.rezStats.skipped + 1
		return
	end
	if self:IsMuted(sender) or not self:IsOnline(sender) then return end
	local now = GetTime()
	if self.lastRezAlert[sender] and now - self.lastRezAlert[sender] < REZ_GAP then return end
	self.lastRezAlert[sender] = now
	local r = self.roster[sender]
	local zone = r and Plain(r.zone) and U.CleanText(r.zone, 40) or nil
	local mine = self.LiveZone and self:LiveZone()
	local text = zone and L.REZ_TEXT_ZONE:format(U.ShortName(sender), zone) or U.ShortName(sender)
	if zone and mine and zone == mine then text = text .. "  |cff40ff40" .. L.REZ_SAME_ZONE .. "|r" end
	self:Msg(L.REZ_CHAT, U.ShortName(sender), zone or "?")
	self.rezStats.notes = self.rezStats.notes + 1
	if self.QueueToast then
		self:QueueToast({ kind = "rez", sender = sender, text = text, tab = "status", title = L.REZ_TOAST_TITLE })
	end
end

------------------------------------------------------------------------
-- Hearthstone location (bundle field hs)
------------------------------------------------------------------------
-- Shared? The own switch if set; otherwise it follows the position answer ("yes" only: tos).
function GH:SharesHearth()
	local c = Char()
	if not c then return false end
	if c.hearthShare == true or c.hearthShare == false then return c.hearthShare end
	return self.MapShareAnswer and self:MapShareAnswer() == "yes" or false
end

function GH:OwnHearth()
	if type(GetBindLocation) ~= "function" then return nil end
	local ok, s = pcall(GetBindLocation)
	if not ok or not Plain(s) then return nil end
	return U.CleanText(s, 24)
end

local function CleanHearth(v)
	if type(v) ~= "string" or U.IsSecret(v) or #v > 60 then return nil end
	return U.CleanText(v, 24)
end

------------------------------------------------------------------------
-- Calendar: the next guild event (within 7 days)
------------------------------------------------------------------------
local CAL = C_Calendar
local GUILD_TYPES = { GUILD_EVENT = true, GUILD_ANNOUNCEMENT = true }
local SIGNUP_STATUS = { [1] = "yes", [3] = "yes", [6] = "yes", [8] = "maybe", [2] = "no", [4] = "no", [5] = "standby" }
local RSVP_OK = { [0] = true, [1] = true, [2] = true, [6] = true, [7] = true, [8] = true }
GH.CAL_STATUS = SIGNUP_STATUS

-- Whole server-time stamp of a calendar time table (local maths, plain numbers only).
local function StampOf(t)
	if type(t) ~= "table" then return nil end
	local y, m, d, h, mi = t.year, t.month, t.monthDay, t.hour, t.minute
	for _, v in ipairs({ y, m, d, h, mi }) do if type(v) ~= "number" or not Plain(v) then return nil end end
	return time({ year = y, month = m, day = d, hour = h, min = mi, sec = 0 })
end

local function CalNow()
	local get = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime
	if type(get) ~= "function" then return nil end
	local ok, t = pcall(get)
	if not ok or type(t) ~= "table" then return nil end
	return t
end

-- Month offset of (year, month) from the calendar's month 0.
local function MonthOffset(y, m)
	if not (CAL and type(CAL.GetMonthInfo) == "function") then return nil end
	local ok, info = pcall(CAL.GetMonthInfo, 0)
	if not ok or type(info) ~= "table" or not Plain(info.year) or not Plain(info.month) then return nil end
	return (y - info.year) * 12 + (m - info.month)
end

-- The raid an event is for, guessed from its title (D8); nil = not guessed (the dropdown picks).
function GH:RaidFromTitle(title)
	if type(title) ~= "string" then return nil end
	local t = title:lower()
	if t:find("ony", 1, true) then return 23 end
	if t:find("hyjal", 1, true) then return 38 end
	if t:find("barrow", 1, true) or t:find("%f[%w]bd%f[%W]") then return 37 end
	return nil
end

-- Returns the event table or nil, why ("nocal" / "none").
function GH:FindTonightEvent()
	if not (CAL and type(CAL.GetNumDayEvents) == "function" and type(CAL.GetDayEvent) == "function") then
		return nil, "nocal"
	end
	local now = CalNow()
	local base = now and StampOf(now)
	if not base then return nil, "nocal" end
	local today = time({ year = now.year, month = now.month, day = now.monthDay, hour = 12 })
	for k = 0, EVENT_DAYS do
		local day = date("*t", today + k * 86400)
		local off = MonthOffset(day.year, day.month)
		if off then
			local okN, n = pcall(CAL.GetNumDayEvents, off, day.day)
			if okN and type(n) == "number" and Plain(n) then
				local best
				for i = 1, math.min(n, 30) do
					local okE, e = pcall(CAL.GetDayEvent, off, day.day, i)
					if okE and type(e) == "table" and Plain(e.calendarType) and GUILD_TYPES[e.calendarType] then
						local start = StampOf(e.startTime)
						-- started up to 3 h ago still counts as tonight
						if start and start >= base - 3 * 3600 and (not best or start < best.start) then
							best = {
								offset = off, day = day.day, index = i, start = start,
								eventID = Plain(e.eventID) and e.eventID or nil,
								title = Plain(e.title) and U.CleanText(e.title, 60) or L.TN_NOTITLE,
								calendarType = e.calendarType,
								inviteType = Plain(e.inviteType) and e.inviteType or nil,
								inviteStatus = Plain(e.inviteStatus) and e.inviteStatus or nil,
								modStatus = Plain(e.modStatus) and e.modStatus or nil,
								locked = Plain(e.isLocked) and e.isLocked or false,
								creator = Plain(e.invitedBy) and U.CleanText(e.invitedBy, 40) or nil,
							}
						end
					end
				end
				if best then
					best.untilStart = best.start - base
					best.raid = self:RaidFromTitle(best.title)
					return best
				end
			end
		end
	end
	return nil, "none"
end

-- Which answer buttons work: "signup" (a sign-up event), "invite" (an invited event) or nil, why.
function GH:EventAnswerKind(ev)
	if not ev then return nil, "noevent" end
	if ev.calendarType ~= "GUILD_EVENT" then return nil, "announce" end
	if ev.modStatus == "CREATOR" then return nil, "creator" end
	if ev.locked then return nil, "locked" end
	if (ev.untilStart or 0) < -3600 then return nil, "past" end
	if ev.inviteType == 1 then return "signup" end -- Enum.CalendarInviteType.Signup
	if ev.inviteStatus ~= nil and RSVP_OK[ev.inviteStatus] then return "invite" end
	return nil, "cant"
end

-- The answer click (one calendar call per click; tos). kind = "yes" / "maybe" / "no".
GH.calStats = { answers = 0, opens = 0, closes = 0, readsSkipped = 0, secret = 0 }
function GH:AnswerEvent(kind)
	if InCombatLockdown and InCombatLockdown() then return false end
	local ev = self:FindTonightEvent() -- fresh index at the moment of the click
	local akind = self:EventAnswerKind(ev)
	if not akind or not (CAL and type(CAL.ContextMenuSelectEvent) == "function") then return false end
	if self.tonight and self.tonight.event and self.tonight.event.eventID and ev.eventID
		and self.tonight.event.eventID ~= ev.eventID then
		self:RefreshTonight("changed") -- a different event now: show it first, no answer sent
		return false
	end
	local fn
	if kind == "yes" then fn = akind == "signup" and CAL.ContextMenuEventSignUp or CAL.ContextMenuInviteAvailable
	elseif kind == "maybe" then fn = CAL.ContextMenuInviteTentative
	elseif kind == "no" then fn = CAL.ContextMenuInviteDecline end
	if type(fn) ~= "function" then return false end
	local okS = pcall(CAL.ContextMenuSelectEvent, ev.offset, ev.day, ev.index)
	if not okS then return false end
	local ok = pcall(fn)
	self.calStats.answers = self.calStats.answers + 1
	if ok then
		self.tonight = self.tonight or {}
		self.tonight.answered = kind
		self:Msg(L.TN_ANSWERED, L["TN_ANS_" .. kind:upper()] or kind)
	end
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
	return ok
end

-- Invite list counts: at most one OpenEvent per view open / Refresh, >= 10 s apart (tos).
GH.tonight = { counts = nil, readAt = nil }
local pendingOpen
local function CalendarShown()
	local cf = _G.CalendarFrame
	return type(cf) == "table" and cf.IsShown and cf:IsShown() and true or false
end

-- Every way out of ReadInviteList after a successful OpenEvent closes the event again (tos).
local function CloseOpenedEvent()
	if CAL and type(CAL.CloseEvent) == "function" then
		pcall(CAL.CloseEvent)
		GH.calStats.closes = GH.calStats.closes + 1
	end
	if GH.RefreshBoardsTab then GH:RefreshBoardsTab() end
end

local function ReadInviteList()
	local t = GH.tonight
	if not pendingOpen then return end
	pendingOpen = nil
	if CalendarShown() then
		-- the player opened Blizzard's calendar within the wait: the open event may now be theirs, so we
		-- neither read nor close it. Blizzard's calendar closes the event itself when it hides
		-- (CalendarFrame_OnHide -> CalendarFrame_CloseEvent -> C_Calendar.CloseEvent, Blizzard_Calendar.lua).
		GH.calStats.readsSkipped = GH.calStats.readsSkipped + 1
		if GH.RefreshBoardsTab then GH:RefreshBoardsTab() end
		return
	end
	if not (CAL and type(CAL.GetNumInvites) == "function" and type(CAL.EventGetInvite) == "function") then
		t.counts = { unavailable = "nocal" }
		CloseOpenedEvent()
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		-- a fight started after the open: no reading now, keep the last counts, still close
		GH.calStats.readsSkipped = GH.calStats.readsSkipped + 1
		CloseOpenedEvent()
		return
	end
	local counts = { yes = 0, maybe = 0, no = 0, standby = 0, invited = 0, byRole = { t = 0, h = 0, d = 0, u = 0 } }
	local okN, n = pcall(CAL.GetNumInvites)
	if not okN or type(n) ~= "number" or not Plain(n) then
		t.counts = { unavailable = "secret" }
		GH.calStats.secret = GH.calStats.secret + 1
	else
		local roles = GH:RoleLookup()
		for i = 1, math.min(n, INVITE_MAX) do
			local ok, inv = pcall(CAL.EventGetInvite, i)
			if not ok or type(inv) ~= "table" or not Plain(inv.inviteStatus) or not Plain(inv.name) then
				counts = { unavailable = "secret" }
				GH.calStats.secret = GH.calStats.secret + 1
				break
			end
			local s = SIGNUP_STATUS[inv.inviteStatus]
			if s then counts[s] = counts[s] + 1 else counts.invited = counts.invited + 1 end
			if s == "yes" then
				-- the name is used here only, for the role, and not kept (tos)
				local role = roles[U.FullName(inv.name) or ""]
				local k = role and role:sub(1, 1) or "u"
				counts.byRole[k] = counts.byRole[k] + 1
			end
		end
		t.counts = counts
	end
	t.readAt = GetTime()
	CloseOpenedEvent()
end

-- Addon users' first role, by name (local, for the counts only).
function GH:RoleLookup()
	local r = {}
	local gdb = self:GetGuildDB()
	if gdb then
		for name, m in pairs(gdb.members) do
			local role = type(m.b) == "table" and self.RaidClean.ro(m.b.ro)
			if role then r[name] = role end
		end
	end
	local mine = self:OwnRole()
	if mine and self:MyName() then r[self:MyName()] = mine end
	return r
end

-- reason = "open" (the view was opened) or "refresh" (the button). Returns true if a read started.
function GH:RefreshTonight(reason)
	local t = self.tonight
	t.event, t.why = self:FindTonightEvent()
	if t.event and t.event.raid and not t.raidPicked then t.raid = t.event.raid end
	if reason ~= "open" and reason ~= "refresh" then
		if self.RefreshBoardsTab then self:RefreshBoardsTab() end
		return false
	end
	if CAL and type(CAL.OpenCalendar) == "function" and (not t.calAskedAt or GetTime() - t.calAskedAt >= 60) then
		t.calAskedAt = GetTime()
		pcall(CAL.OpenCalendar) -- asks the server for the calendar (as Blizzard's calendar button does)
	end
	local ev = t.event
	local blocked = not ev or CalendarShown() or (InCombatLockdown and InCombatLockdown())
		or (self.InLockdown and self:InLockdown()) or (t.lastOpen and GetTime() - t.lastOpen < READ_COOLDOWN)
		or not CAL or type(CAL.OpenEvent) ~= "function"
	if blocked then
		self.calStats.readsSkipped = self.calStats.readsSkipped + 1
		if self.RefreshBoardsTab then self:RefreshBoardsTab() end
		return false
	end
	t.lastOpen = GetTime()
	pendingOpen = true
	self.calStats.opens = self.calStats.opens + 1
	local ok = pcall(CAL.OpenEvent, ev.offset, ev.day, ev.index)
	if not ok then
		pendingOpen = nil
	elseif CAL.IsEventOpen and select(2, pcall(CAL.IsEventOpen)) == true and type(CAL.GetNumInvites) == "function" then
		-- some versions open it at once; otherwise CALENDAR_OPEN_EVENT follows
		self:ScheduleTimer(ReadInviteList, 0.5)
	end
	self:ScheduleTimer(function() if pendingOpen then ReadInviteList() end end, 4)
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
	return ok
end

-- Seconds until Refresh may read again (0 = now).
function GH:TonightCooldown()
	local t = self.tonight
	if not t.lastOpen then return 0 end
	return math.max(0, READ_COOLDOWN - (GetTime() - t.lastOpen))
end

GH:On("calendar", "CALENDAR_OPEN_EVENT", function() if pendingOpen then ReadInviteList() end end)

-- Addon users with the Late tick (the counts' "Late").
function GH:LateCount()
	local n = 0
	local gdb = self:GetGuildDB()
	if gdb then
		for name, m in pairs(gdb.members) do
			if name ~= self:MyName() and type(m.b) == "table" and type(m.b.tk) == "number" and band(m.b.tk, TK_LATE) ~= 0 then
				n = n + 1
			end
		end
	end
	if self:RaidTick(TK_LATE) then n = n + 1 end
	return n
end

------------------------------------------------------------------------
-- Summon queue (display only; zones of raid members live only in these rows)
------------------------------------------------------------------------
function GH:TonightRaid()
	local t = self.tonight
	return self.RAID_BY_D[t.raid or 0] or self.RAIDS[1]
end

function GH:PickTonightRaid(d)
	if not self.RAID_BY_D[d] then return end
	self.tonight.raid = d
	self.tonight.raidPicked = true
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
end

local function AtRaid(raid, zone)
	if zone == raid.name then return true end
	for _, z in ipairs(raid.outside) do if zone == z then return true end end
	return false
end

-- Returns rows (with header rows { header = key, count }) and the "not here" count; nil when not in a raid.
function GH:BuildSummonRows()
	if not (IsInRaid and IsInRaid()) or type(GetRaidRosterInfo) ~= "function" then return nil, 0 end
	local raid = self:TonightRaid()
	local gdb = self:GetGuildDB()
	local me = self:MyName()
	local locks, away, click = {}, {}, {}
	local okN, n = pcall(GetNumGroupMembers)
	n = okN and Plain(n) and n or 0
	for i = 1, math.min(n, 40) do
		local ok, name, _, _, _, _, fileName, zone, online = pcall(GetRaidRosterInfo, i)
		if ok and Plain(name) and type(name) == "string" then
			local full = U.FullName(name)
			local m = full and gdb and gdb.members[full]
			local b = (full == me) and { tk = self:RaidTicks(), ro = self:OwnRole() } or (m and type(m.b) == "table" and m.b) or nil
			local hasAddon = full == me or (full and self:IsAddonUserOnline(full)) or false
			local tk = b and tonumber(b.tk) or 0
			local z = Plain(zone) and type(zone) == "string" and U.CleanText(zone, 40) or nil
			local row = {
				name = full or name, class = Plain(fileName) and fileName or nil, zone = z or "?",
				online = Plain(online) and online or false, addon = hasAddon,
				role = b and self.RaidClean.ro(b.ro) or nil,
				need = hasAddon and band(tk, TK_SUMMON) ~= 0 or nil,
				click = hasAddon and band(tk, TK_CLICK) ~= 0 or nil,
				late = hasAddon and band(tk, TK_LATE) ~= 0 or nil,
				here = z ~= nil and AtRaid(raid, z),
			}
			if row.class == "WARLOCK" then locks[#locks + 1] = row
			elseif row.click then click[#click + 1] = row
			elseif not row.here then away[#away + 1] = row end
		end
	end
	local function byName(a, b) return a.name < b.name end
	table.sort(locks, byName); table.sort(click, byName)
	table.sort(away, function(a, b)
		if (a.need and 1 or 0) ~= (b.need and 1 or 0) then return a.need and true or false end
		return a.name < b.name
	end)
	local rows = {}
	local function add(key, list)
		if #list == 0 then return end
		rows[#rows + 1] = { header = key, count = #list }
		for _, r in ipairs(list) do rows[#rows + 1] = r end
	end
	add("locks", locks); add("away", away); add("click", click)
	return rows, #away
end

------------------------------------------------------------------------
-- "New in 1.0.1" card: once per version, existing users only, can be turned off
------------------------------------------------------------------------
function GH:MaybeNewInCard(force)
	local p = self.db and self.db.profile
	if not p then return false end
	if not force then
		if p.newInCard == false or p.newInSeen == NEWIN_KEY then return false end
		-- a new user (never answered the position question) gets the welcome card instead
		if self.MapShareAnswer and self:MapShareAnswer() == "ask" and not self.db.char.usedStatus then
			p.newInSeen = NEWIN_KEY
			return false
		end
	end
	local lines = {}
	for i = 1, 5 do
		local text = L["NEWIN_L" .. i]
		if text then lines[#lines + 1] = { state = "done", text = text, sub = L["NEWIN_S" .. i] } end
	end
	self:ShowCard({
		key = "newin", title = L.NEWIN_TITLE:format(NEWIN_KEY), lines = lines, note = L.NEWIN_NOTE,
		skip = function() return not force and (p.newInCard == false or p.newInSeen == NEWIN_KEY) end,
		onShow = function() p.newInSeen = NEWIN_KEY end,
		buttons = {
			{ label = L.NEWIN_SHOW, fn = function()
				p.newInSeen = NEWIN_KEY
				if GH.OpenBoards then GH:OpenBoards("raid") end
			end },
			{ label = L.BTN_CLOSE or CLOSE or "Close", fn = function() p.newInSeen = NEWIN_KEY end },
		},
		onClose = function() p.newInSeen = NEWIN_KEY end,
	})
	return true
end

------------------------------------------------------------------------
-- Additions to the "raid" feature (Features\Raid.lua): bundle fields, ticks, hover line, share line
------------------------------------------------------------------------
local feat = GH.features.raid
feat.bundle.tk = { prio = 7, clean = function(v)
	local n = U.ValidNumber(v, 1, 7)
	return n and n == floor(n) and n or nil
end, get = function()
	if not GH:FeatureOn("raid") or not GH:SharesRaid() then return nil end
	local v = GH:RaidTicks()
	return v > 0 and v or nil
end }
feat.bundle.hs = { prio = 1, clean = CleanHearth, get = function()
	if not GH:FeatureOn("raid") or not GH:SharesHearth() or GH.cannotSend then return nil end
	return GH:OwnHearth()
end }

local function InRaidGroup() return IsInRaid and IsInRaid() and true or false end
local function InAnyGroup() return (IsInGroup and IsInGroup()) and true or false end
local function EventSoon()
	local ev = GH.tonight and GH.tonight.event
	return ev and (ev.untilStart or 0) < 12 * 3600 and (ev.untilStart or 0) > -3 * 3600 or false
end

feat.myStatus = {
	{ key = "summon", text = L.TICK_SUMMON, why = L.TICK_SUMMON_TIP,
		get = function(gh) return gh:RaidTick(TK_SUMMON) end, set = function(gh, on) gh:SetRaidTick(TK_SUMMON, on) end,
		shown = InRaidGroup },
	{ key = "click", text = L.TICK_CLICK, why = L.TICK_CLICK_TIP,
		get = function(gh) return gh:RaidTick(TK_CLICK) end, set = function(gh, on) gh:SetRaidTick(TK_CLICK, on) end,
		shown = InRaidGroup },
	{ key = "late", text = L.TICK_LATE, why = L.TICK_LATE_TIP,
		get = function(gh) return gh:RaidTick(TK_LATE) end, set = function(gh, on) gh:SetRaidTick(TK_LATE, on) end,
		shown = EventSoon },
	{ key = "rezAvail", text = L.TICK_REZ, why = L.TICK_REZ_TIP,
		get = function(gh) return gh:RezAvailable() end,
		set = function(gh, on) Char().rezAvail = on and gh:CanRez() or nil end,
		shown = function(gh) return gh:CanRez() and InAnyGroup() end },
}

feat.hoverLines = {
	{ fn = function(gh, name)
		if not gh:CanUse("hearth") then return nil end -- fair trade
		local hs
		if name == gh:MyName() then hs = gh:OwnHearth()
		else
			local gdb = gh:GetGuildDB()
			local m = gdb and gdb.members[name]
			hs = m and type(m.b) == "table" and CleanHearth(m.b.hs)
		end
		if hs then return L.HOVER_HEARTH:format(hs), 0.8, 0.8, 0.8 end
	end },
}

GH:RegisterShare({
	key = "hearth", order = 5, optKey = "shareHearth", feature = "raid",
	name = "OPT_SHAREHEARTH", desc = "OPT_SHAREHEARTH_DESC",
	get = function(gh) return gh:SharesHearth() end,
	set = function(gh, on)
		Char().hearthShare = on and true or false
		if gh.BundleChanged then gh:BundleChanged("hs") end
	end,
})

-- Start-up parts (called from the raid feature's enable through InitRaidNight).
function GH:InitRaidNight()
	if self.raidNightStarted then return end
	self.raidNightStarted = true
	self.raidLastTk = self:RaidTicks()
	self.raidLastHs = feat.bundle.hs.get()
	-- ticks that ran out, the hearth that moved, summon ticks after leaving the raid: one REC each
	self:Every("raidnight", "ticks", 60, function()
		local v = GH:RaidTicks()
		if v ~= GH.raidLastTk then GH.raidLastTk = v; GH:BundleChanged("tk") end
		local hs = feat.bundle.hs.get()
		if hs ~= GH.raidLastHs then GH.raidLastHs = hs; GH:BundleChanged("hs") end
	end)
	self:On("raidnight", "GROUP_ROSTER_UPDATE", function()
		if not InRaidGroup() and band(GH:RaidTicks(), TK_SUMMON + TK_CLICK) ~= 0 then
			GH:SetRaidTick(TK_SUMMON + TK_CLICK, false)
		end
	end)
	self:On("raidnight", "CALENDAR_UPDATE_EVENT_LIST", function()
		if GH.BoardsTabShown and GH:BoardsTabShown() then GH:RefreshTonight() end
	end)
	-- the New-in card after the 60-s login quiet (the card itself waits for combat / instances)
	self:ScheduleTimer(function() if GH.raidNightStarted then GH:MaybeNewInCard() end end, 65)
end

function GH:StopRaidNight()
	self.raidNightStarted = nil
	self:Off("raidnight")
	self:Cancel("raidnight")
end
