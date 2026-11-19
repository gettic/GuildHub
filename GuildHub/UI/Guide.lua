-- Guild Hub: the "Getting started" card (0.4.0). A short checklist on the shared card (UI\Card.lua):
-- what to share (fair trade: each line says what you get), which profession windows to open once,
-- and setting a status. Every tick comes from the real state; nothing is sent.
-- Shown automatically at most once per character (char.guideShown, set only when it is really on
-- screen), never in combat or an instance (Card.lua waits), never when "Don't show again" is ticked
-- (profile.guideOff: the Default profile is shared by all characters). No chat lines, no reminders.
-- tos C2: if the map card was answered "Not now" (or X/Esc) this session, the guide doesn't follow it;
-- it shows at the next login instead (char.guideDeferred), as the first card, and the map card
-- skips that session (the guide's position line covers it). /ghub start always opens it.
local _, ns = ...
local GH, L = ns.GH, ns.L

local MINING = 186

-- Own professions with a recipe window (crafts, Cooking, First Aid, Mining's Smelting).
local function HasWindow(line)
	local p = GH.PROFS and GH.PROFS[line]
	return p and (p.kind == "craft" or p.kind == "second" or line == MINING) or false
end

-- Grey line for a switched-off feature: officer's guild switch or the player's own.
local function OffLine(key, text)
	local off = GH:GuildOff()
	local byGuild = type(off) == "table" and off[key]
	return { key = key, state = "off", text = text, sub = byGuild and L.GUIDE_OFF_GUILD_SUB or L.GUIDE_OFF_SUB }
end

local function ShareLine(key, doneText, doneSub, todoText, todoSub)
	if GH:Shares(key) then return { key = key, state = "done", text = doneText, sub = doneSub } end
	return { key = key, state = "todo", text = todoText, sub = todoSub }
end

-- Profession windows: "todo" with the missing names, "done", or "off" when there is nothing to open.
local function WindowLine()
	local own = GH.OwnProf and GH:OwnProf()
	local p = own and own.p or {}
	local have, missing = false, {}
	for _, line in ipairs(GH.PROF_ORDER or {}) do
		local e = p[line]
		if type(e) == "table" and HasWindow(line) then
			have = true
			if not e.scanned then missing[#missing + 1] = GH:ProfName(line) or tostring(line) end
		end
	end
	if not have then return { key = "win", state = "off", text = L.GUIDE_WIN_NONE, sub = L.GUIDE_WIN_NONE_SUB } end
	if #missing == 0 then return { key = "win", state = "done", text = L.GUIDE_WIN_DONE, sub = L.GUIDE_WIN_DONE_SUB } end
	return { key = "win", state = "todo", text = L.GUIDE_WIN_TODO, sub = L.GUIDE_WIN_TODO_SUB:format(table.concat(missing, ", ")) }
end

local function StatusDone()
	if GH.db.char.usedStatus == true then return true end
	local own = GH.GetOwnStatus and GH:GetOwnStatus()
	return own and GH:IsStatusFresh(own) or false
end

-- The checklist rows from real state: { key, state = "done"|"todo"|"off", text, sub }.
function GH:GuideLines()
	if self.cannotSend then
		return {
			{ key = "trial", state = "off", text = L.GUIDE_TRIAL_LOCKED, sub = L.GUIDE_TRIAL_LOCKED_SUB },
			{ key = "board", state = "done", text = L.GUIDE_TRIAL_BOARD, sub = L.GUIDE_TRIAL_BOARD_SUB },
		}
	end
	local r = {}
	if self:FeatureOn("map") then
		r[#r + 1] = ShareLine("pos", L.GUIDE_POS_DONE, L.GUIDE_POS_DONE_SUB, L.GUIDE_POS_TODO, L.GUIDE_POS_TODO_SUB)
	else
		r[#r + 1] = OffLine("map", L.GUIDE_OFF_MAP)
	end
	r[#r + 1] = ShareLine("group", L.GUIDE_GRP_DONE, L.GUIDE_GRP_DONE_SUB, L.GUIDE_GRP_TODO, L.GUIDE_GRP_TODO_SUB)
	if self:FeatureOn("prof") then
		r[#r + 1] = ShareLine("prof", L.GUIDE_PROF_DONE, L.GUIDE_PROF_DONE_SUB, L.GUIDE_PROF_TODO, L.GUIDE_PROF_TODO_SUB)
		r[#r + 1] = WindowLine()
	else
		r[#r + 1] = OffLine("prof", L.GUIDE_OFF_PROF)
	end
	if StatusDone() then
		r[#r + 1] = { key = "status", state = "done", text = L.GUIDE_STATUS_DONE, sub = L.GUIDE_STATUS_DONE_SUB }
	else
		r[#r + 1] = { key = "status", state = "todo", text = L.GUIDE_STATUS_TODO, sub = L.GUIDE_STATUS_TODO_SUB }
	end
	return r
end

function GH:GuideTodo(lines)
	local n = 0
	for _, l in ipairs(lines or self:GuideLines()) do if l.state == "todo" then n = n + 1 end end
	return n
end

-- Should the guide show by itself now? (once per character, not switched off, something to do)
function GH:GuideDue()
	local db = self.db
	if not (db and self.started) then return false end
	if db.char.guideShown == true or db.profile.guideOff == true then return false end
	if IsInGuild and not IsInGuild() then return false end
	return self.cannotSend and true or self:GuideTodo() > 0
end

local function OpenBoard()
	if GH.miniFrame and GH.miniFrame:IsShown() then GH.miniFrame:Hide() end
	local f = GH:CreateMainFrame()
	GH:ShowTab("status")
	f:Show()
end

-- The card spec (test = for the self-test: nothing saved, onShow not called by Card.lua).
function GH:GuideSpec(test)
	local trial = self.cannotSend and true or false
	local spec = {
		key = "guide", test = test or nil,
		title = L.GUIDE_TITLE,
		text = trial and L.GUIDE_TRIAL_BODY or L.GUIDE_BODY,
		lines = self:GuideLines(),
		note = trial and L.GUIDE_TRIAL_NOTE or L.GUIDE_NOTE,
		tick = { label = L.GUIDE_TICK, checked = self.db.profile.guideOff == true,
			fn = function(on) if not test then GH.db.profile.guideOff = on and true or false end end },
		onShow = function() GH.db.char.guideShown = true; GH.db.char.guideDeferred = false end,
		update = function(s) s.lines = GH:GuideLines() end,
	}
	if trial then
		spec.buttons = { { label = L.GUIDE_BTN_BOARD, fn = OpenBoard } }
	else
		spec.buttons = { { label = L.GUIDE_BTN_SHARE, fn = function() GH:OpenOptions() end },
			{ label = L.GUIDE_BTN_BOARD, fn = OpenBoard } }
	end
	return spec
end

-- auto = start-up (only when due; tos C2 skip after a "Not now" on the map card); else /ghub start.
function GH:ShowGuide(auto)
	if not (self.ShowCard and self.db) then return end
	if auto and not self:GuideDue() then return end
	local spec = self:GuideSpec()
	if auto then
		spec.skip = function()
			if not GH:GuideDue() then return true end
			if GH.mapAskedThisSession and not GH.guideFirst then
				GH.db.char.guideDeferred = true -- next login instead
				GH.guideDeferredNow = true      -- (not again in this session)
				return true
			end
			return false
		end
	end
	self:ShowCard(spec)
end

-- Start-up (Map.lua ShowWelcome): a guide deferred last session comes first, instead of the map card.
function GH:GuideFirstThisLogin()
	if self.db and self.db.char.guideDeferred == true and not self.guideDeferredNow and self:GuideDue() then
		self.guideFirst = true
		self.mapAskedThisSession = true -- the guide's position line asks this time
		self:ShowGuide(true)
		return true
	end
	return false
end

-- Redraws the open guide (share changed, a profession window scanned, a status set).
function GH:RefreshGuide()
	local f = self.card
	if not (f and f:IsShown() and f.spec and f.spec.key == "guide") then return end
	local old = f.spec
	local spec = self:GuideSpec(old.test)
	spec.skip = old.skip
	self:FillCard(f, spec)
end
