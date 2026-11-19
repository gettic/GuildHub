-- Guild Hub: the "Getting started" walkthrough (0.4.0 card, 0.5.0 pages). Short pages on the shared
-- card (UI\Card.lua) with Back / Next: 1 overview, 2 professions (Needed), 3 map position and group
-- size (Needed), 4 the status board (Optional), 5 the Recruiting tab (Optional, only when the
-- recruiter is on). Optional pages never show a to-do mark. Every tick comes from the real state.
-- The guide itself sends nothing: only the player's own click on "Turn on" changes ONE share
-- setting, through GH:SetShare (the same path as Settings > What I share; tos D3).
-- Shown automatically at most once per character (char.guideShown, set only when it is really on
-- screen) and only while a Needed item is still open, never in combat or an instance (Card.lua
-- waits), never when "Don't show again" is ticked (profile.guideOff: shared by all characters).
-- tos C2: if the map card was answered "Not now" (or X/Esc) this session, the guide doesn't follow it;
-- it shows at the next login instead (char.guideDeferred), as the first card, and the map card
-- skips that session (the guide's position row covers it). /ghub start always opens it on page 1.
local _, ns = ...
local GH, L = ns.GH, ns.L

local MINING = 186
local GUIDE_W = 460
local NAV_W = 100

GH.guidePage = 1 -- the page on screen (memory only)

-- Own professions with a recipe window (crafts, Cooking, First Aid, Mining's Smelting).
local function HasWindow(line)
	local p = GH.PROFS and GH.PROFS[line]
	return p and (p.kind == "craft" or p.kind == "second" or line == MINING) or false
end

local function OpenBoard()
	if GH.miniFrame and GH.miniFrame:IsShown() then GH.miniFrame:Hide() end
	local f = GH:CreateMainFrame()
	GH:ShowTab("status")
	f:Show()
end

local function OpenRecruiting()
	if GH.miniFrame and GH.miniFrame:IsShown() then GH.miniFrame:Hide() end
	local f = GH:CreateMainFrame()
	f:Show()
	GH:ShowTab((f.tabs and f.tabs.members) and "members" or "status")
end

local function MembersOn()
	if not GH:FeatureOn("recruit") then return false end
	if IsInGuild and not IsInGuild() then return false end
	return true
end

-- "Turn on" for one share item: only on the player's click, one setting, through GH:SetShare.
-- (test = the self-test's spec: the button does nothing)
local function TurnOn(key, test)
	return { label = L.GUIDE_BTN_ON, keep = true, fn = function()
		if test or GH:Shares(key) then return end
		GH:SetShare(key, true)
	end }
end

-- Grey row for a switched-off feature: the officer's guild switch (no button) or the player's own
-- (a Settings button; the card closes, Settings opens).
local function OffRow(key, text)
	local off = GH:GuildOff()
	local byGuild = type(off) == "table" and off[key]
	local r = { key = key, state = "off", text = text, sub = byGuild and L.GUIDE_OFF_GUILD_SUB or L.GUIDE_OFF_SUB }
	if not byGuild then r.button = { label = L.GUIDE_BTN_SETTINGS, fn = function() GH:OpenOptions() end } end
	return r
end

-- Profession windows: one row per profession with a window (read with its recipe count, or not
-- read yet), one grey row naming the gathering ones, or "No professions yet".
local function WindowRows()
	local own = GH.OwnProf and GH:OwnProf()
	local p = own and own.p or {}
	local rows, gather = {}, {}
	for _, line in ipairs(GH.PROF_ORDER or {}) do
		local e = p[line]
		if type(e) == "table" then
			local name = GH:ProfName(line) or tostring(line)
			if HasWindow(line) then
				if e.scanned then
					rows[#rows + 1] = { key = "win:" .. line, state = "done", text = name,
						sub = L.GUIDE_WIN_READ:format(tonumber(e.n) or 0) }
				else
					rows[#rows + 1] = { key = "win:" .. line, state = "todo", text = name, sub = L.GUIDE_WIN_UNREAD }
				end
			else
				gather[#gather + 1] = name
			end
		end
	end
	if #rows == 0 then rows[1] = { key = "win", state = "off", text = L.GUIDE_WIN_NONE, sub = L.GUIDE_WIN_NONE_SUB } end
	if #gather > 0 then
		rows[#rows + 1] = { key = "gather", state = "off", text = L.GUIDE_WIN_GATHER:format(table.concat(gather, ", ")) }
	end
	return rows
end

local function ShareRow(key, text, todoSub, doneSub, test)
	if GH:Shares(key) then return { key = key, state = "done", text = text, sub = doneSub } end
	return { key = key, state = "todo", text = text, sub = todoSub, button = TurnOn(key, test) }
end

local function ProfShareRow(test)
	return ShareRow("prof", L.GUIDE_PROF_ROW, L.GUIDE_PROF_ROW_TODO, L.GUIDE_PROF_ROW_DONE, test)
end

local function PosRow(test)
	if not GH:FeatureOn("map") then return OffRow("map", L.GUIDE_OFF_MAP) end
	return ShareRow("pos", L.GUIDE_POS_ROW, L.GUIDE_POS_ROW_SUB, L.GUIDE_POS_ROW_SUB, test)
end

local function GroupRow(test)
	return ShareRow("group", L.GUIDE_GRP_ROW, L.GUIDE_GRP_ROW_SUB, L.GUIDE_GRP_ROW_SUB, test)
end

-- The Needed rows from real state: { key, state = "done"|"todo"|"off", text, sub[, button] }.
-- Keys: prof (or the off row), win:<skillLine> / win / gather, pos (or map), group; trial: trial, board.
function GH:GuideLines(test)
	if self.cannotSend then
		return {
			{ key = "trial", state = "off", text = L.GUIDE_TRIAL_LOCKED, sub = L.GUIDE_TRIAL_LOCKED_SUB },
			{ key = "board", state = "done", text = L.GUIDE_TRIAL_BOARD, sub = L.GUIDE_TRIAL_BOARD_SUB },
		}
	end
	local r = {}
	if self:FeatureOn("prof") then
		r[#r + 1] = ProfShareRow(test)
		for _, w in ipairs(WindowRows()) do r[#r + 1] = w end
	else
		r[#r + 1] = OffRow("prof", L.GUIDE_OFF_PROF)
	end
	r[#r + 1] = PosRow(test)
	r[#r + 1] = GroupRow(test)
	return r
end

function GH:GuideTodo(lines)
	local n = 0
	for _, l in ipairs(lines or self:GuideLines()) do if l.state == "todo" then n = n + 1 end end
	return n
end

-- Should the guide show by itself now? (once per character, not switched off, a Needed item open)
function GH:GuideDue()
	local db = self.db
	if not (db and self.started) then return false end
	if db.char.guideShown == true or db.profile.guideOff == true then return false end
	if IsInGuild and not IsInGuild() then return false end
	return self.cannotSend and true or self:GuideTodo() > 0
end

local function Info(text, sub, button)
	return { state = "info", text = text, sub = sub, button = button }
end

local function Head(text) return { state = "head", text = text } end

-- The pages: { tag = "start"|"needed"|"optional", title, text, lines, note }.
function GH:GuidePages(test)
	local needed = self:GuideLines(test)
	local profState, posState, grpState = "done", "done", "done"
	for _, l in ipairs(needed) do
		local k = l.key or ""
		if k == "prof" or k:find("^win") then
			if l.state == "todo" then profState = "todo"
			elseif l.state == "off" and k == "prof" then profState = "off" end
		elseif k == "pos" or k == "map" then posState = l.state
		elseif k == "group" then grpState = l.state end
	end
	local members = MembersOn()
	local overview = { Head(L.GUIDE_HEAD_NEEDED),
		{ key = "sum:prof", state = profState, text = L.GUIDE_SUM_PROF },
		{ key = "sum:pos", state = posState, text = L.GUIDE_SUM_POS },
		{ key = "sum:group", state = grpState, text = L.GUIDE_SUM_GRP },
		Head(L.GUIDE_HEAD_OPTIONAL),
		Info(L.GUIDE_SUM_BOARD) }
	if members then overview[#overview + 1] = Info(L.GUIDE_SUM_MEMBERS) end

	local profLines
	if self:FeatureOn("prof") then
		profLines = { ProfShareRow(test), Head(L.GUIDE_HEAD_WINDOWS) }
		for _, w in ipairs(WindowRows()) do profLines[#profLines + 1] = w end
	else
		profLines = { OffRow("prof", L.GUIDE_OFF_PROF) }
	end

	local pages = {
		{ key = "start", tag = "start", title = L.GUIDE_TITLE, text = L.GUIDE_INTRO, lines = overview, note = L.GUIDE_AGAIN },
		{ key = "prof", tag = "needed", title = L.GUIDE_PROF_TITLE, text = L.GUIDE_PROF_BODY, lines = profLines, note = L.GUIDE_PROF_NOTE },
		{ key = "map", tag = "needed", title = L.GUIDE_MAP_TITLE, text = L.GUIDE_MAP_BODY,
			lines = { PosRow(test), GroupRow(test) }, note = L.GUIDE_MAP_NOTE },
		{ key = "board", tag = "optional", title = L.GUIDE_BOARD_TITLE, text = L.GUIDE_OPTIONAL_BODY, lines = {
			Info(L.GUIDE_BOARD_1, nil, { label = L.GUIDE_BTN_OPENBOARD, fn = OpenBoard }),
			Info(L.GUIDE_BOARD_2, L.GUIDE_BOARD_2_SUB),
			Info(L.GUIDE_BOARD_3),
			Info(L.GUIDE_BOARD_4) } },
	}
	if members then
		local lines = {
			Info(L.GUIDE_MEM_1, nil, { label = L.GUIDE_BTN_OPENTAB, fn = OpenRecruiting }),
			Info(L.GUIDE_MEM_2, L.GUIDE_MEM_2_SUB),
			Info(L.GUIDE_MEM_3, L.GUIDE_MEM_3_SUB),
		}
		if GH.RecruitIAmOfficer and GH.RecruitIAmOfficer() then lines[#lines + 1] = Info(L.GUIDE_MEM_4, L.GUIDE_MEM_4_SUB) end
		pages[#pages + 1] = { key = "members", tag = "optional", title = L.GUIDE_MEM_TITLE, text = L.GUIDE_OPTIONAL_BODY, lines = lines }
	end
	pages[#pages].note = L.GUIDE_DONE_NOTE
	return pages
end

local TAGS = { start = "GUIDE_TAG_START", needed = "GUIDE_TAG_NEEDED", optional = "GUIDE_TAG_OPTIONAL" }

-- The card fields of one page (no height).
local function PageContent(pages, n)
	local p = pages[n]
	local last = #pages
	return {
		title = p.title, text = p.text, lines = p.lines, note = p.note,
		step = L.GUIDE_STEP:format(L[TAGS[p.tag]] or "", n, last), stepGray = p.tag == "optional",
		width = GUIDE_W, spread = true,
		buttons = {
			{ label = L.GUIDE_BTN_BACK, keep = true, greyed = n == 1, width = NAV_W,
				fn = function() GH.guidePage = math.max(1, n - 1) end },
			n < last and { label = L.GUIDE_BTN_NEXT, keep = true, width = NAV_W, fn = function() GH.guidePage = n + 1 end }
				or { label = L.GUIDE_BTN_DONE, width = NAV_W },
		},
	}
end

-- The tallest page's height, so Back / Next stay in place (D8). Measured on the card frame only
-- when it is hidden or showing this very spec (it is filled again right after).
local function Measure(spec, pages)
	local f = GH.CardFrame and GH:CardFrame()
	if not f then return nil end
	local shown = f:IsShown()
	if shown and f.spec ~= spec then return nil end
	local h = 0
	for i = 1, #pages do
		local c = PageContent(pages, i)
		c.key, c.test, c.tick = "guide", true, spec.tick
		h = math.max(h, GH:FillCard(f, c) or 0)
	end
	f.spec = shown and spec or nil
	return h
end

-- Puts page n (else the current page) on a spec table; trial accounts get the one-page card.
local function Fill(spec, page)
	local test = spec.test
	for _, k in ipairs({ "step", "stepGray", "width", "spread", "minHeight" }) do spec[k] = nil end
	if GH.cannotSend then
		spec.page = 1
		spec.title, spec.text = L.GUIDE_TITLE, L.GUIDE_TRIAL_BODY
		spec.lines, spec.note = GH:GuideLines(test), L.GUIDE_TRIAL_NOTE
		spec.buttons = { { label = L.GUIDE_BTN_BOARD, fn = OpenBoard } }
		spec.pages = 1
		return spec
	end
	local pages = GH:GuidePages(test)
	local n = math.max(1, math.min(tonumber(page) or 1, #pages))
	if not test then GH.guidePage = n end
	for k, v in pairs(PageContent(pages, n)) do spec[k] = v end
	spec.page, spec.pages = n, #pages
	spec.minHeight = Measure(spec, pages)
	return spec
end

-- The card spec (test = for the self-test: nothing saved, onShow not called, buttons do nothing;
-- page = which page, default the current one).
function GH:GuideSpec(test, page)
	local spec = {
		key = "guide", test = test or nil,
		tick = { label = L.GUIDE_TICK, checked = self.db.profile.guideOff == true,
			fn = function(on) if not test then GH.db.profile.guideOff = on and true or false end end },
		onShow = function() GH.db.char.guideShown = true; GH.db.char.guideDeferred = false end,
		update = function(s) Fill(s, s.test and s.page or GH.guidePage) end,
		refresh = function() GH:RefreshGuide() end,
	}
	return Fill(spec, page or self.guidePage)
end

-- auto = start-up (only when due; tos C2 skip after a "Not now" on the map card); else /ghub start.
function GH:ShowGuide(auto)
	if not (self.ShowCard and self.db) then return end
	if auto and not self:GuideDue() then return end
	self.guidePage = 1
	local f = self.card
	if f and f:IsShown() and f.spec and f.spec.key == "guide" then return self:RefreshGuide() end
	local spec = self:GuideSpec(nil, 1)
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
		self.mapAskedThisSession = true -- the guide's position row asks this time
		self:ShowGuide(true)
		return true
	end
	return false
end

-- Redraws the open guide on its page (Back / Next, share changed, a profession window scanned).
function GH:RefreshGuide()
	local f = self.card
	if not (f and f:IsShown() and f.spec and f.spec.key == "guide") then return end
	local spec = f.spec
	Fill(spec, spec.test and spec.page or self.guidePage)
	self:FillCard(f, spec)
end
