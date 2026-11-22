-- Guild Hub: one queue for every pop-up note, the quiet rules, the note budget and the badges
-- (1.0.0-beta.1, plans\next-beta-2; tos: plans\next-beta-2\tos-check.md item 4).
-- Everything here is local: nothing is sent, and it only ever LOWERS what pops up. A note that may
-- not show becomes a badge count on its tab (and on the minimap button); its chat line was already
-- printed by the caller. Only the pause time is saved (profile.alertsPauseUntil, server time).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local LOGIN_QUIET = 60     -- no notes in the first minute after login / reload
local BUDGET_N = 3         -- at most 3 notes ...
local BUDGET_WINDOW = 600  -- ... per 10 minutes
local QUEUE_MAX = 10       -- more waiting than this: held as a badge instead
local PAUSE_SECONDS = 3600
GH.TOAST_RULES = { quiet = LOGIN_QUIET, n = BUDGET_N, window = BUDGET_WINDOW, queue = QUEUE_MAX, pause = PAUSE_SECONDS }

GH.toastQueue = {}
GH.toastStats = { shown = 0, held = 0, dropped = 0, queued = 0 }
GH.badges = {}             -- [tabKey] = count of held notes
local shownAt = {}         -- GetTime() of the notes shown in the last 10 minutes
GH.toastShownAt = shownAt

-- The moment this session started (Core.lua OnEnable sets it; a file load is the fallback).
GH.loginAt = GH.loginAt or GetTime()

------------------------------------------------------------------------
-- Quiet rules
------------------------------------------------------------------------
local function Trim(now)
	for i = #shownAt, 1, -1 do
		if now - shownAt[i] >= BUDGET_WINDOW then table.remove(shownAt, i) end
	end
end

function GH:AlertsPausedLeft()
	local p = self.db and self.db.profile.alertsPauseUntil
	if type(p) ~= "number" then return 0 end
	return math.max(0, p - U.Now())
end

function GH:PauseAlerts(seconds)
	self.db.profile.alertsPauseUntil = U.Now() + (seconds or PAUSE_SECONDS)
	self:Msg(L.PAUSE_ON)
	self:AlertsChanged()
end

function GH:ResumeAlerts()
	self.db.profile.alertsPauseUntil = 0
	self:Msg(L.PAUSE_OFF)
	self:AlertsChanged()
end

function GH:TogglePauseAlerts()
	if self:AlertsPausedLeft() > 0 then self:ResumeAlerts() else self:PauseAlerts() end
end

-- My status, the minimap tooltip and the settings follow a pause / resume.
function GH:AlertsChanged()
	if self.UpdateOwnPanel then self:UpdateOwnPanel() end
	if self.optionsChanged then self:optionsChanged() end
	self:DrawBadges()
end

-- May a note pop up now? quiet (true = hold it), why.
function GH:AlertsQuiet()
	local now = GetTime()
	if now - (self.loginAt or 0) < LOGIN_QUIET then return true, "login" end
	if InCombatLockdown() then return true, "combat" end
	local okI, inInst = pcall(IsInInstance)
	if okI and not U.IsSecret(inInst) and inInst then return true, "instance" end
	local n, raid = self:GroupInfo()
	if n and ((not raid and n >= 5) or n >= 40) then return true, "fullgroup" end
	local own = self:GetOwnStatus()
	if own and self:IsStatusFresh(own) and own.p == "busy" then return true, "busy" end
	if self.PlayerAFK and self:PlayerAFK() then return true, "afk" end
	if self:AlertsPausedLeft() > 0 then return true, "paused" end
	if self.db.profile.toastBudget ~= false then
		Trim(now)
		if #shownAt >= BUDGET_N then return true, "budget" end
	end
	return false
end

------------------------------------------------------------------------
-- The queue
------------------------------------------------------------------------
local function Hold(gh, e, why)
	gh.toastStats.held = gh.toastStats.held + 1
	gh.lastHeldWhy = why
	gh:AddBadge(e.tab or "status", 1)
end

local function Showing(gh)
	return (gh.toast and gh.toast:IsShown()) or (gh.joinToast and gh.joinToast:IsShown()) or false
end

local function Draw(gh, e)
	local now = GetTime()
	Trim(now) -- also while the note budget is off, so the list never keeps growing
	shownAt[#shownAt + 1] = now
	gh.toastStats.shown = gh.toastStats.shown + 1
	gh.toastOnScreen = e
	if e.kind == "join" and gh.ShowJoinToast then
		gh:ShowJoinToast(e.sender)
	else
		gh:ShowToast(e.sender, e.text, e)
	end
end

-- e = { kind = "lfg"|"help"|"join"|"test", sender, text, tab }. Returns "shown", "queued", "held" or "dropped".
function GH:QueueToast(e)
	if type(e) ~= "table" then return "dropped" end
	if e.sender and e.kind ~= "test" and (self:IsMuted(e.sender) or (self.IsIgnored and self:IsIgnored(e.sender))) then
		self.toastStats.dropped = self.toastStats.dropped + 1
		return "dropped"
	end
	local quiet, why = self:AlertsQuiet()
	if quiet then
		Hold(self, e, why)
		return "held"
	end
	if Showing(self) then
		if #self.toastQueue >= QUEUE_MAX then
			Hold(self, e, "queue")
			return "held"
		end
		self.toastQueue[#self.toastQueue + 1] = e
		self.toastStats.queued = self.toastStats.queued + 1
		return "queued"
	end
	Draw(self, e)
	return "shown"
end

-- A note closed (or timed out): the next one, if it may show now; else the rest become badges.
function GH:ToastNext()
	self.toastOnScreen = nil
	if Showing(self) then return end
	local e = table.remove(self.toastQueue, 1)
	if not e then return end
	if e.sender and e.kind ~= "test" and (self:IsMuted(e.sender) or (self.IsIgnored and self:IsIgnored(e.sender))) then
		self.toastStats.dropped = self.toastStats.dropped + 1
		return self:ToastNext()
	end
	local quiet, why = self:AlertsQuiet()
	if quiet then
		Hold(self, e, why)
		for _, rest in ipairs(self.toastQueue) do Hold(self, rest, why) end
		wipe(self.toastQueue)
		return
	end
	Draw(self, e)
end

------------------------------------------------------------------------
-- Badges: a 14 px overlay on a tab's top-right corner and on the minimap button. The tab's text and
-- width never change (ui round 2, row 9).
------------------------------------------------------------------------
function GH:AddBadge(key, n)
	self.badges[key] = math.max(0, (self.badges[key] or 0) + (n or 1))
	self:DrawBadges()
end

function GH:SetBadge(key, n)
	self.badges[key] = math.max(0, n or 0)
	self:DrawBadges()
end

function GH:BadgeCount(key)
	if key then return self.badges[key] or 0 end
	local total = 0
	for _, n in pairs(self.badges) do total = total + n end
	return total
end

local function PlaceBadge(owner, parent, b)
	if not b then
		b = W.Badge(parent or owner)
		b:SetPoint("CENTER", owner, "TOPRIGHT", -6, -4)
		local lvl = owner.GetFrameLevel and owner:GetFrameLevel()
		-- above the window's border art too (the tab's corner reaches into it)
		local border = parent and parent.NineSlice
		local bl = type(border) == "table" and border.GetFrameLevel and border:GetFrameLevel()
		if type(lvl) == "number" then
			if type(bl) == "number" and bl >= lvl then lvl = bl end
			b:SetFrameLevel(lvl + 5)
		end
	end
	return b
end

function GH:DrawBadges()
	local f = self.mainFrame
	if f and f.tabs then
		f.badgeParts = f.badgeParts or {}
		for key, tabButton in pairs(f.tabs) do
			local n = self.badges[key] or 0
			local b = f.badgeParts[key]
			if n > 0 and not b then
				b = PlaceBadge(tabButton, f)
				f.badgeParts[key] = b
			end
			if b then
				b:SetCount(n)
				b:SetShown(n > 0 and tabButton:IsShown())
			end
		end
	end
	local mm = self.minimapButton
	if mm then
		local n = self:BadgeCount()
		local show = n > 0 and not (f and f:IsShown())
		if show and not mm.badge then mm.badge = PlaceBadge(mm, mm) end
		if mm.badge then
			mm.badge:SetCount(n)
			mm.badge:SetShown(show)
		end
	end
end

-- Opening a tab clears its badge (MainFrame ShowTab).
function GH:ClearBadge(key)
	if (self.badges[key] or 0) == 0 then return end
	self.badges[key] = 0
	self:DrawBadges()
end

------------------------------------------------------------------------
-- /ghub test toast: 5 local test notes through the queue (nothing is sent)
------------------------------------------------------------------------
function GH:TestToasts()
	local shown, held = 0, 0
	for i = 1, 5 do
		local r = self:QueueToast({ kind = "test", text = L.TEST_TOAST:format(i), tab = "status" })
		if r == "held" then held = held + 1 else shown = shown + 1 end
	end
	self:Msg(L.TEST_TOAST_DONE, shown, held)
end
