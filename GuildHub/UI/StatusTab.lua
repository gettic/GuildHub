-- Guild Hub: the Status tab (search, Sort menu, "LFG only", member list, "Your status" panel,
-- footer) and the Whisper / Invite actions. Whisper and Invite only ever run from the player's
-- own click. Blizzard templates come through UI\Widgets.lua (each with a plain fallback).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local ROW_H = 24
local LIST_W = 778
local SORTS = { "activity", "level", "zone", "rank", "name" }
-- column x positions and widths inside a row
local COL = {
	-- one STATUS column (236 px): the time ("12 min") sits right-aligned in grey at its right end
	-- and the status text gets the room the time doesn't need; then GROUP ("Yours", "3/5",
	-- "R 18"); actions stay at the right
	name = { 8, 116 }, rank = { 128, 86 }, lvl = { 218, 30 }, zone = { 252, 120 }, status = { 376, 236 },
	-- 1.0.0-beta.1: GROUP 46 px (its widest text "31/40" needs ~30) so the 64 px action slot fits
	-- "I can help" without running into GROUP
	group = { 616, 46 }, whisper = { 666, 64 }, invite = { 734, 44 },
}
local TIME_W, TIME_GAP = 70, 6 -- widest time ("10 h 59 min") and the gap before it
local GROUP_TEXT_COLOR = { yours = { 0.45, 0.9, 0.45 }, solo = { 0.55, 0.55, 0.55 }, other = { 0.9, 0.9, 0.9 } }
GH.STATUS_COLUMNS, GH.STATUS_LIST_W, GH.STATUS_TIME_W = COL, LIST_W, TIME_W -- for the offline test

------------------------------------------------------------------------
-- Actions (clicks only)
------------------------------------------------------------------------
local function OpenChatWith(text)
	local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
	if open then pcall(open, text) end
end

-- Opens the chat box to whisper them; never sends anything by itself.
function GH:WhisperMember(name)
	if type(name) ~= "string" or self:IsMyChar(name) then return end -- never yourself or your alts
	local target = U.WhisperName(name)
	local tell = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
	if not (tell and pcall(tell, target)) then
		OpenChatWith("/w " .. target .. " ")
	end
end

-- Invites from the player's click. If the game blocks it, Guild Hub switches for good to
-- putting "/invite Name" in the chat box (the player presses Enter).
function GH:InviteMember(name)
	if type(name) ~= "string" or self:IsMyChar(name) then return end -- never yourself or your alts
	local target = U.WhisperName(name)
	if self.db.profile.inviteFallback or not (C_PartyInfo and C_PartyInfo.InviteUnit) then
		OpenChatWith("/invite " .. target)
		return
	end
	self.lastInvite = { target = target, time = GetTime() }
	if not pcall(C_PartyInfo.InviteUnit, target) then
		self:UseInviteFallback()
	end
end

function GH:UseInviteFallback()
	local first = not self.db.profile.inviteFallback
	self.db.profile.inviteFallback = true
	local li = self.lastInvite
	self.lastInvite = nil
	if first then self:Msg(L.INVITE_FALLBACK) end
	if li and GetTime() - li.time < 3 then OpenChatWith("/invite " .. li.target) end
end

-- The game reports a blocked call with ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN.
function GH:InitInviteWatch()
	if self.inviteWatch then return end
	local function OnBlocked(_, addon, func)
		if addon ~= "GuildHub" then return end
		local f = type(func) == "string" and not U.IsSecret(func) and func or nil
		-- 0.6.0-beta.3 Ask to join (Features\Actions.lua): its own fallback, never the /invite one
		if GH.lastAsk and (not f or f:find("RequestInvite")) then return GH:AskFallback() end
		if not GH.lastInvite then return end
		if f and not f:find("Invite") then return end
		GH:UseInviteFallback()
	end
	self:On("invite", "ADDON_ACTION_BLOCKED", OnBlocked)  -- Events.lua dispatcher
	self:On("invite", "ADDON_ACTION_FORBIDDEN", OnBlocked)
	self.inviteWatch = true
end

------------------------------------------------------------------------
-- Building the tab
------------------------------------------------------------------------
-- Builds the parts of one row on frame r (our own row, or a ScrollBox row frame, built once).
local function SetupRow(r)
	r.ghRow = true
	local bg = r:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	r.bg = bg
	r.hl = W.RowHighlight(r)
	local function col(key, font, justify)
		local fs = W.Text(r, font or "GameFontHighlight", nil, justify)
		fs:SetPoint("LEFT", COL[key][1], 0)
		fs:SetWidth(COL[key][2])
		return fs
	end
	r.name = col("name", "GameFontHighlight")
	r.rank = col("rank", "GameFontDisableSmall")
	r.lvl = col("lvl", "GameFontHighlight")
	r.zone = col("zone", "GameFontHighlightSmall")
	r.status = col("status", "GameFontHighlightSmall")
	-- the time: right-aligned at the right end of the STATUS column, grey
	r.time = W.Text(r, "GameFontHighlightSmall", nil, "RIGHT")
	r.time:SetPoint("RIGHT", r, "LEFT", COL.status[1] + COL.status[2], 0)
	r.time:SetWidth(TIME_W)
	r.time:SetTextColor(W.COLOR.gray[1], W.COLOR.gray[2], W.COLOR.gray[3])
	r.group = col("group", "GameFontHighlightSmall")
	-- 1.0.0-beta.2 (Q5): a +/- box before the group header; click the header to fold the group
	r.fold = r:CreateTexture(nil, "ARTWORK")
	r.fold:SetSize(14, 14)
	r.fold:SetPoint("LEFT", 6, 0)
	r.fold:Hide()
	r.header = W.Text(r, "GameFontNormal")
	r.header:SetPoint("LEFT", 24, 0)
	r.headerLine = W.HeaderLine(r, r.header)
	r:SetScript("OnClick", function(s, button)
		if button ~= "RightButton" and s.data and s.data.header then GH:ToggleFold(s.data.header) end
	end)
	r.whisper = W.Button(r, L.BTN_WHISPER, COL.whisper[2], 18)
	r.whisper:SetPoint("LEFT", COL.whisper[1], 0)
	r.whisper:SetScript("OnClick", function() GH:WhisperMember(r.member) end)
	-- 1.0.0-beta.1: "I can help" (Need-help rows), same slot and width as Whisper, small font
	r.canHelp = W.Button(r, L.BTN_CANHELP, COL.whisper[2], 18, "GameFontNormalSmall")
	r.canHelp:SetPoint("LEFT", COL.whisper[1], 0)
	if r.canHelp.SetMotionScriptsWhileDisabled then r.canHelp:SetMotionScriptsWhileDisabled(true) end
	r.canHelp:SetScript("OnClick", function() GH:CanHelp(r.member) end)
	r.canHelp:SetScript("OnEnter", function(b) GH:CanHelpTooltip(b, r.member) end)
	r.canHelp:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r.canHelp:Hide()
	r.invite = W.Button(r, L.BTN_INVITE, COL.invite[2], 18)
	r.invite:SetPoint("LEFT", COL.invite[1], 0)
	if r.invite.SetMotionScriptsWhileDisabled then r.invite:SetMotionScriptsWhileDisabled(true) end -- tooltip on the grey button
	r.invite:SetScript("OnClick", function(self)
		if self.inGroup then return end -- already in our group (button is greyed out)
		GH:InviteMember(r.member)
	end)
	r.invite:SetScript("OnEnter", function(self)
		if not self.inGroup then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L.INVITE_IN_GROUP, 1, 1, 1)
		GameTooltip:Show()
	end)
	r.invite:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnEnter", function(self) GH:MemberTooltip(self, self.data) end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- 0.6.0-beta.3: right-click = the name menu (UI\NameMenu.lua); left-click does nothing, as before
	GH:NameMenuOnRow(r, function(s) return s.data and not s.data.header and s.data.name or nil end, "status")
end

local function MakeRow(parent)
	local r = CreateFrame("Button", nil, parent)
	r:SetSize(LIST_W, ROW_H - 2)
	SetupRow(r)
	return r
end

-- Row tooltip (status board and mini window). hint = optional last grey line.
function GH:MemberTooltip(owner, d, hint)
	if not d or d.header then return end
	GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
	GameTooltip:AddLine(U.ClassColored(d.name, d.class))
	if d.rank and d.rank ~= "" then GameTooltip:AddLine(d.rank, 0.8, 0.8, 0.8) end
	GameTooltip:AddLine(L.TIP_LEVEL_ZONE:format(tostring(d.level or "?"), d.zone ~= "" and d.zone or "?"), 1, 1, 1)
	if d.noAddon then
		GameTooltip:AddLine(L.NO_ADDON_ROW, 0.6, 0.6, 0.6)
	elseif d.status ~= "" then
		GameTooltip:AddLine(d.status, 1, 0.9, 0.6, true) -- cleaned text (no codes)
	end
	if d.instFull and d.instFull ~= d.instShort then GameTooltip:AddLine(d.instFull, 0.75, 0.55, 1) end
	local _, _, grpTip = GH:GroupText(d)
	if grpTip then GameTooltip:AddLine(grpTip, 0.6, 0.85, 1) end
	local profLine = GH.ProfLine and GH:ProfLine(d.name) -- Professions.lua
	if profLine then GameTooltip:AddLine(profLine, 0.55, 0.8, 1, true) end
	if not d.noAddon and d.since then
		if d.left then
			GameTooltip:AddLine(L.TIP_FOR_CLEARS:format(U.Duration(d.since), U.Duration(d.left)), 0.7, 0.7, 0.7)
		else
			GameTooltip:AddLine(L.FOR_FMT:format(U.Duration(d.since)), 0.7, 0.7, 0.7)
		end
	end
	if hint then GameTooltip:AddLine(hint, 0.5, 0.5, 0.5) end
	GameTooltip:Show()
end

local function FillRow(r, d)
	r.data = d
	r.member = d.name
	local isHeader = d.header ~= nil
	r.header:SetShown(isHeader)
	for _, k in ipairs({ "name", "rank", "lvl", "zone", "status", "time", "group" }) do r[k]:SetShown(not isHeader) end
	local mine = d.isSelf or (not isHeader and GH:IsMyChar(d.name)) -- yourself or your alt (Alts.lua)
	-- 1.0.0-beta.1: on a Need-help row "I can help" takes the Whisper button's slot
	local helpRow = not isHeader and not mine and not d.noAddon and d.preset == "help"
	r.whisper:SetShown(not isHeader and not mine and not helpRow)
	r.canHelp:SetShown(helpRow)
	if helpRow then
		local ok = GH:CanHelpState(d.name)
		r.canHelp:SetEnabled(ok and true or false)
		r.canHelp:SetGreyed(not ok)
	end
	r.invite:SetShown(not isHeader and not mine)
	r.hl:SetShown(not isHeader)
	if r.headerLine then r.headerLine:SetShown(isHeader) end
	r.fold:SetShown(isHeader)
	if isHeader then
		local c = GH.GROUP_COLOR[d.header] or W.GOLD
		local art = W.FoldArt(d.folded)
		local sign = ""
		if art then r.fold:SetTexture(art) else sign = d.folded and "+ " or "- "; r.fold:Hide() end
		r.header:SetText(("%s%s (%d)"):format(sign, L.GROUP[d.header] or d.header, d.count))
		r.header:SetTextColor(c[1], c[2], c[3])
		r.bg:SetColorTexture(0, 0, 0, 0)
		return
	end
	r.bg:SetColorTexture(1, 1, 1, d.isSelf and 0.07 or 0.03)
	if d.noAddon then
		r.name:SetText(d.short)
		r.name:SetTextColor(0.5, 0.5, 0.5)
	else
		r.name:SetText(U.ClassColored(d.name, d.class))
		r.name:SetTextColor(1, 1, 1)
	end
	local grey = d.noAddon and 0.5 or 1
	r.rank:SetText(d.rank or "")
	r.rank:SetTextColor(grey * 0.75, grey * 0.75, grey * 0.75)
	r.lvl:SetText(tostring(d.level or "?"))
	r.lvl:SetTextColor(grey, grey, grey)
	r.zone:SetText(d.zone)
	r.zone:SetTextColor(grey * 0.85, grey * 0.8, grey * 0.65)
	r.status:SetText(d.status) -- cleaned text from others, never contains | codes
	-- short time ("12 min") at the right end; the status text gets the rest of the column
	local t = d.since and U.Duration(d.since) or ""
	r.time:SetText(t)
	local tw = 0
	if t ~= "" then
		local sw = r.time:GetStringWidth()
		tw = math.min(TIME_W, math.ceil(tonumber(sw) or TIME_W)) + TIME_GAP
	end
	r.status:SetWidth(COL.status[2] - tw)
	local gText, gKind = GH:GroupText(d)
	local gc = GROUP_TEXT_COLOR[gKind] or GROUP_TEXT_COLOR.other
	r.group:SetText(gText)
	r.group:SetTextColor(gc[1], gc[2], gc[3])
	-- Invite greyed out (and does nothing) for players already in our group
	local inGroup = d.inMyGroup == true
	r.invite.inGroup = inGroup
	r.invite:SetEnabled(not inGroup)
	r.invite:SetGreyed(inGroup)
end

-- Sort: a WowStyle1Dropdown menu (pick one), else the old button (left-click next, right-click back).
local function MakeSort(parent, tab, db)
	local dd = W.Dropdown(parent, 150)
	if dd then
		dd:SetupMenu(function(_, root)
			for _, key in ipairs(SORTS) do
				root:CreateRadio(L.SORT[key] or key, function() return db.sort == key end, function()
					db.sort = key
					GH:DrawStatusTab()
				end)
			end
		end)
		return dd
	end
	local sort = W.Button(parent, "", 130, 24)
	sort:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	sort:SetScript("OnClick", function(_, button)
		local i = 1
		for k, v in ipairs(SORTS) do if v == db.sort then i = k end end
		local step = button == "RightButton" and -1 or 1
		db.sort = SORTS[(i - 1 + step) % #SORTS + 1]
		GH:DrawStatusTab()
	end)
	W.Tooltip(sort, L.SORT_TIP)
	return sort
end

-- The old list: our own rows and slider (used when the ScrollBox templates are missing).
local function MakePlainList(tab, listArea)
	local list = CreateFrame("Frame", nil, listArea)
	list:SetAllPoints(listArea)
	list:EnableMouseWheel(true)
	tab.list = list
	tab.rows = {}
	local visible = math.floor(tab.listHeight / ROW_H)
	for i = 1, visible do
		local r = MakeRow(list)
		r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
		tab.rows[i] = r
	end
	tab.visible = visible
	local bar = CreateFrame("Slider", nil, list)
	bar:SetOrientation("VERTICAL")
	bar:SetWidth(8)
	bar:SetPoint("TOPRIGHT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", 0, 0)
	local track = bar:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	track:SetColorTexture(1, 1, 1, 0.04)
	local thumb = bar:CreateTexture(nil, "OVERLAY")
	thumb:SetColorTexture(W.GOLD[1], W.GOLD[2], W.GOLD[3], 0.6)
	thumb:SetSize(8, 30)
	bar:SetThumbTexture(thumb)
	bar:SetValueStep(1)
	bar:SetMinMaxValues(0, 0)
	bar:SetScript("OnValueChanged", function(_, v)
		v = math.floor(v + 0.5)
		if v ~= tab.offset then
			tab.offset = v
			GH:DrawRows()
		end
	end)
	tab.bar = bar
	list:SetScript("OnMouseWheel", function(_, delta)
		local _, max = bar:GetMinMaxValues()
		bar:SetValue(math.max(0, math.min(max, tab.offset - delta * 3)))
	end)
end

function GH:BuildStatusTab(parent)
	local tab = {}
	self.statusTab = tab
	tab.offset = 0
	local db = self.db.profile

	-- toolbar strip at the top of the page, above the list (0.6.0-beta.3: out of the tab row, so the
	-- row holds only tabs and keeps its right end free): search, Sort, "LFG only"
	local search = W.EditBox(parent, 330, 22, 40, L.SEARCH_HINT, "search")
	search:SetPoint("TOPLEFT", parent, "TOPLEFT", search.ghTemplate and 12 or 6, -3)
	tab.toolbarH = GH.TOOLBAR_H
	-- the search box template has its own scripts (clear button, hint): ours are hooked on
	search:HookScript("OnEnterPressed", function(s) s:ClearFocus() end)
	search:HookScript("OnEscapePressed", function(s) -- Esc empties the search and shows everyone again
		s:SetText("")
		s:ClearFocus()
		tab.offset, tab.toTop = 0, true
		GH:DrawStatusTab()
	end)
	search:HookScript("OnTextChanged", function() tab.offset, tab.toTop = 0, true; GH:DrawStatusTab() end)
	tab.search = search

	local sort = MakeSort(parent, tab, db)
	sort:SetPoint("LEFT", search, "RIGHT", 12, 0)
	tab.sort = sort

	local compact = W.CheckButton(parent, L.LFG_ONLY, 100)
	compact:SetPoint("LEFT", sort, "RIGHT", 12, 0)
	compact:SetScript("OnClick", function()
		db.compact = not db.compact
		tab.offset, tab.toTop = 0, true
		GH:DrawStatusTab()
	end)
	W.Tooltip(compact, L.COMPACT_TIP)
	tab.compact = compact

	-- the list sits in an inset with the column titles at its top
	local inset = W.Inset(parent)
	inset:SetPoint("TOPLEFT", 2, -GH.TOOLBAR_H) -- under the toolbar strip
	inset:SetPoint("BOTTOMLEFT", 2, 24)
	inset:SetWidth(LIST_W + 20)
	tab.listInset = inset
	local heads = {
		{ "name", L.COL_NAME }, { "rank", L.COL_RANK }, { "lvl", L.COL_LVL }, { "zone", L.COL_ZONE }, { "status", L.COL_STATUS },
		{ "group", L.COL_GROUP }, { "whisper", L.COL_ACTIONS },
	}
	local headBar = CreateFrame("Frame", nil, inset) -- own frame: above the inset's border art
	headBar:SetAllPoints(inset)
	for _, h in ipairs(heads) do
		local fs = W.Text(headBar, "GameFontDisableSmall", h[2])
		fs:SetPoint("TOPLEFT", inset, "TOPLEFT", 6 + COL[h[1]][1], -6)
	end
	local timeHead = W.Text(headBar, "GameFontDisableSmall", L.COL_TIME, "RIGHT")
	timeHead:SetPoint("TOPRIGHT", inset, "TOPLEFT", 6 + COL.status[1] + COL.status[2], -6)

	local listArea = CreateFrame("Frame", nil, inset)
	listArea:SetPoint("TOPLEFT", 6, -22)
	listArea:SetPoint("BOTTOMLEFT", 6, 4)
	listArea:SetWidth(LIST_W + 12)
	tab.listArea = listArea
	tab.listHeight = 460 - GH.TOOLBAR_H - 24 - 22 - 4 -- page height minus toolbar, footer, column titles and margin (16 rows)

	-- Blizzard's ScrollBox list (rows are reused while scrolling), else our own rows + slider
	local box, sbar = W.ScrollList(listArea, ROW_H, function(r, d)
		if not r.ghRow then SetupRow(r) end
		FillRow(r, d)
	end)
	if box then
		box:SetPoint("TOPLEFT", 0, 0)
		box:SetPoint("BOTTOMLEFT", 0, 0)
		box:SetWidth(LIST_W)
		sbar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
		sbar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
		tab.scrollBox, tab.scrollBar = box, sbar
		tab.list = box
	else
		MakePlainList(tab, listArea)
	end
	tab.empty = W.Text(listArea, "GameFontDisable", L.EMPTY_LIST)
	tab.empty:SetPoint("TOP", 0, -40)

	-- footer note on the window's own background, gold (grey was hard to read there). The left count
	-- "N online · M with Guild Hub" was removed in 1.0.0-beta.2: the title bar shows the same numbers.
	local fr = W.Text(parent, "GameFontNormalSmall", L.FOOTER_RIGHT, "RIGHT")
	fr:SetTextColor(W.COLOR.normal[1], W.COLOR.normal[2], W.COLOR.normal[3])
	-- right-aligned to the list's right edge, 400 px wide (the text needs ~230 px)
	fr:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", 8 + LIST_W, 8)
	fr:SetWidth(400)
	tab.footerRight = fr

	-- while the Status tab is open: times and "Clears in" every 10 s, a fresh guild list every 15 s
	-- (zones, levels, who is online). OnUpdate only runs while this page is shown.
	parent:SetScript("OnUpdate", function(_, elapsed)
		tab.tick = (tab.tick or 0) + elapsed
		tab.rosterTick = (tab.rosterTick or 0) + elapsed
		if tab.rosterTick >= 15 then
			tab.rosterTick = 0
			GH:RequestRoster()
		end
		if tab.tick >= 10 then
			tab.tick = 0
			GH:RefreshBoard(true)
		end
	end)

	self:BuildOwnPanel(parent)
end

------------------------------------------------------------------------
-- Right side: "My status" (1.0.0-beta.1, plans\next-beta-2 part 1.1). The parts are placed top to
-- bottom by UpdateOwnPanel (a y-cursor), so hidden parts leave no gaps:
--   title, state line, news strip (0-2 lines), Status (preset dropdown, or the 6 buttons without the
--   dropdown template), Dungeon (LFG only), note box, the one highlighted button (only when it
--   applies), Lasts + Clear all, ticks from features (myStatus hook), Find me, Pause alerts.
------------------------------------------------------------------------
local PANEL_X, PANEL_W, LABEL_W = 12, 206, 54
local HOURS = { 1, 2, 4, 8 }

local function HoursText(h) return h == 1 and L.MY_HOURS1 or L.MY_HOURSN:format(h) end

-- A one-line text button (the news strip lines, "Pause alerts 1 h"): no art, highlight on hover.
local function LineButton(parent, font, width)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(width, 16)
	local fs = b:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
	fs:SetPoint("LEFT", 4, 0)
	fs:SetWidth(width - 8)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	b.label = fs
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 0.85, 0.4, 0.12)
	function b:SetLabel(t) self.label:SetText(t or "") end
	return b
end

local function RowLabel(panel, text)
	local fs = W.Text(panel, "GameFontNormalSmall", text)
	fs:SetWidth(LABEL_W - 4)
	return fs
end

function GH:BuildOwnPanel(parent)
	local tab = self.statusTab
	local panel = W.Inset(parent)
	panel:SetPoint("TOPLEFT", LIST_W + 26, 0)
	panel:SetPoint("BOTTOMRIGHT", -2, 24)
	tab.panel = panel

	tab.title = W.Text(panel, "GameFontNormalLarge", L.MY_STATUS)
	tab.title:SetPoint("TOPLEFT", PANEL_X, -12)

	-- state line: "LFG: Scholomance · clears in 1 h 40" (old tests know it as clearsIn)
	tab.state = W.Text(panel, "GameFontNormalSmall")
	tab.state:SetWidth(PANEL_W)
	tab.clearsIn = tab.state

	-- news strip: a gold box with up to 2 clickable lines (LFG match first, then the news hook)
	local news = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	W.Skin(news, 0.6, 0.18, 0.14, 0.04)
	news:SetBackdropBorderColor(W.BORDER_ON[1], W.BORDER_ON[2], W.BORDER_ON[3], 1)
	news:SetWidth(PANEL_W)
	news.lines = {}
	for i = 1, 2 do
		local b = LineButton(news, "GameFontNormalSmall", PANEL_W - 6)
		b:SetPoint("TOPLEFT", 3, -3 - (i - 1) * 17)
		b:SetScript("OnClick", function(s) if s.onClick then s.onClick(GH) end end)
		b:SetScript("OnEnter", function(s)
			if not s.tip then return end
			GameTooltip:SetOwner(s, "ANCHOR_LEFT")
			GameTooltip:AddLine(s.tip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		news.lines[i] = b
	end
	news:Hide()
	tab.news = news

	-- Status: one preset dropdown, else the six buttons (2 per row)
	tab.lblStatus = RowLabel(panel, L.MY_LBL_STATUS)
	tab.chips = {}
	local preset = W.Dropdown(panel, PANEL_W - LABEL_W)
	if preset then
		preset:SetupMenu(function(_, root)
			root:CreateRadio(L.MY_PRESET_NONE, function()
				local own = GH:GetOwnStatus() or {}
				return not (GH:IsStatusFresh(own) and own.p)
			end, function() GH:PickPreset(nil) end)
			for _, p in ipairs(GH.PRESETS) do
				root:CreateRadio(L.PRESET[p], function()
					local own = GH:GetOwnStatus() or {}
					return GH:IsStatusFresh(own) and own.p == p
				end, function() GH:PickPreset(p) end)
			end
		end)
		tab.preset = preset
	else
		for _, p in ipairs(self.PRESETS) do
			local b = W.Button(panel, L.PRESET[p], 100, 22)
			b:SetScript("OnClick", function()
				GH:HideDungeonPicker()
				tab.note:ClearFocus()
				GH:SetPreset(p)
				GH:UpdateOwnPanel(true) -- the note box follows (cleared when switching presets)
			end)
			tab.chips[p] = b
		end
	end

	tab.lblDungeon = RowLabel(panel, L.MY_LBL_DUNGEON)
	tab.dungeon = self:MakeDungeonPicker(panel)
	if tab.dungeon.isDropdown then tab.dungeon:SetWidth(PANEL_W - LABEL_W) end

	local note = W.EditBox(panel, PANEL_W, 24, self.NOTE_LETTERS, L.NOTE_HINT)
	if note.ghTemplate then note:SetWidth(PANEL_W - 8) end -- the input box art reaches 5 px past its left edge
	note:SetScript("OnEnterPressed", function(s)
		GH:SetStatusText(s:GetText())
		s:ClearFocus()
		GH:UpdateOwnPanel(true) -- the box now shows the shared (cleaned) note; hint goes away
	end)
	note:SetScript("OnEscapePressed", function(s)
		s:ClearFocus()
		GH:UpdateOwnPanel(true)
	end)
	-- nothing is shared when the box loses focus: only Enter shares (the hint says so)
	note:HookScript("OnTextChanged", function() GH:UpdateNoteHint() end)
	tab.note = note

	tab.noteHint = W.Text(panel, "GameFontNormalSmall", L.NOTE_UNSENT)
	tab.noteHint:Hide()

	-- the one highlighted button: "Found a group? Clear LFG" / "Got help? Clear Need help" /
	-- "LFG again: X". It only ever acts on its own click (tos-check item 1).
	local hi = W.Button(panel, "", PANEL_W, 24, "GameFontNormalSmall")
	hi:SetScript("OnClick", function() GH:OwnHighlightClick() end)
	hi:SetScript("OnEnter", function(s)
		if not s.tip then return end
		GameTooltip:SetOwner(s, "ANCHOR_LEFT")
		GameTooltip:AddLine(s.tip, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	hi:SetScript("OnLeave", function() GameTooltip:Hide() end)
	hi:Hide()
	tab.highlight = hi

	-- Lasts: a 1/2/4/8 h dropdown, else the old cycling button
	tab.lblLasts = RowLabel(panel, L.MY_LBL_LASTS)
	local lasts = W.Dropdown(panel, 90)
	if lasts then
		lasts:SetupMenu(function(_, root)
			for _, h in ipairs(HOURS) do
				root:CreateRadio(HoursText(h), function() return GH:OwnHours() == h end, function()
					GH:SetStatusHours(h)
					GH:UpdateOwnPanel()
				end)
			end
		end)
		W.Tooltip(lasts, L.MY_LASTS_TIP)
	else
		lasts = W.Button(panel, "", 100, 22)
		lasts:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		lasts:SetScript("OnClick", function(_, button)
			GH:CycleStatusHours(button == "RightButton" and -1 or 1)
			GH:UpdateOwnPanel() -- label and "Clears in" change at once (the list follows 0.3 s later)
		end)
		lasts:SetScript("OnEnter", function(s)
			GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
			GameTooltip:AddLine(L.LASTS_TIP, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		lasts:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	tab.lasts = lasts

	-- Clear all: the preset, the note and any ticks
	local clear = W.Button(panel, L.BTN_CLEAR_ALL, 76, 22, "GameFontNormalSmall")
	clear:SetScript("OnClick", function() GH:ClearAllOwn() end)
	W.Tooltip(clear, L.MY_CLEAR_ALL_TIP)
	tab.clear = clear

	tab.ticks = {} -- myStatus hook ticks, made when a feature first adds one

	-- 0.6.0 "Find me" (Features\Map.lua): click only; greyed with the reason in its tooltip
	local find = W.Button(panel, L.FIND_BUTTON, PANEL_W, 22)
	if find.SetMotionScriptsWhileDisabled then find:SetMotionScriptsWhileDisabled(true) end
	find:SetScript("OnClick", function() GH:FindMe() end)
	find:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L.FIND_BUTTON, 1, 0.82, 0)
		GameTooltip:AddLine(L.FIND_TIP, 1, 1, 1, true)
		local ok, why, left = GH:FindMeState()
		if not ok then GameTooltip:AddLine(L.FIND_TIP_NO:format((L.FIND_WHY[why] or why):format(left or 0)), 1, 0.3, 0.3, true) end
		GameTooltip:Show()
	end)
	find:SetScript("OnLeave", function() GameTooltip:Hide() end)
	tab.findMe = find

	-- "... Pause alerts 1 h", or "Alerts paused · 42 min left" + Resume
	local pause = LineButton(panel, "GameFontNormalSmall", PANEL_W)
	pause:SetLabel("... " .. L.MY_PAUSE)
	pause:SetScript("OnClick", function() GH:PauseAlerts() end)
	W.Tooltip(pause, L.MY_PAUSE_TIP)
	tab.pause = pause
	tab.paused = W.Text(panel, "GameFontHighlightSmall")
	tab.paused:SetWidth(PANEL_W - 70)
	local resume = W.Button(panel, L.MY_RESUME, 64, 20, "GameFontNormalSmall")
	resume:SetScript("OnClick", function() GH:ResumeAlerts() end)
	tab.resume = resume

	tab.autoAct = W.Text(panel, "GameFontDisableSmall")
	tab.autoAct:SetPoint("BOTTOMLEFT", PANEL_X + 2, 10)
	tab.autoAct:SetWidth(PANEL_W)

	self:UpdateFindButton()
end

-- The preset dropdown's pick: nil = "No status" (the current preset off); the current one = nothing.
function GH:PickPreset(p)
	local own = self:GetOwnStatus() or {}
	local cur = self:IsStatusFresh(own) and own.p or nil
	if p == cur then return end
	self:HideDungeonPicker()
	if self.statusTab and self.statusTab.note then self.statusTab.note:ClearFocus() end
	self:SetPreset(p or cur)
	self:UpdateOwnPanel(true)
end

-- Clear all (a click only): status, note and every myStatus tick.
function GH:ClearAllOwn()
	local tab = self.statusTab
	if tab and tab.note then tab.note:SetText("") end
	self:ClearStatus()
	for _, e in ipairs(self:Hooks("myStatus")) do
		if type(e.set) == "function" and type(e.get) == "function" and e.get(self) then pcall(e.set, self, false) end
	end
	self:UpdateOwnPanel(true)
end

-- Which highlighted button applies now: "found_lfg", "found_help", "again" or nil (and the label).
function GH:OwnHighlight()
	local kind = self:FoundGroupKind()
	if kind == "lfg" then return "found_lfg", L.MY_FOUND_LFG end
	if kind == "help" then return "found_help", L.MY_FOUND_HELP end
	local own = self:GetOwnStatus() or {}
	if not (self:IsStatusFresh(own) and own.p) then
		local l = self:LastLfg()
		if l then
			return "again", L.MY_LFG_AGAIN:format(l.d > 0 and self:DungeonName(l.d) or L.LFG_ANY), L.MY_LFG_AGAIN_TIP
		end
	end
	return nil
end

-- The highlighted button's click: the state is checked again here, then one action.
function GH:OwnHighlightClick()
	local which = self:OwnHighlight()
	if which == "found_lfg" or which == "found_help" then
		self:ClearFoundGroup()
	elseif which == "again" then
		self:LfgAgain()
	end
	self:UpdateOwnPanel(true)
end

-- The news strip's lines: the LFG match first, then features' news hook entries (by order). At most 2.
function GH:NewsLines()
	local lines = {}
	local list, d = self:LfgMatches()
	if d and #list > 0 then
		local dn = self:DungeonName(d)
		lines[1] = { text = #list == 1 and L.NEWS_MATCH1:format(dn) or L.NEWS_MATCHN:format(#list, dn),
			tip = L.NEWS_MATCH_TIP, onClick = function(gh) gh:ShowLfgMatch() end }
	end
	local hooked = self:Hooks("news")
	table.sort(hooked, function(a, b) return (tonumber(a.order) or 99) < (tonumber(b.order) or 99) end)
	for _, e in ipairs(hooked) do
		if #lines >= 2 then break end
		local ok, text = pcall(e.fn, self)
		if ok and type(text) == "string" and not U.IsSecret(text) and text ~= "" then
			lines[#lines + 1] = { text = U.CleanText(text, 60), tip = e.tip, onClick = e.onClick }
		end
	end
	return lines
end

-- The Find me button: hidden while the map feature is off, greyed while it can't be used.
function GH:UpdateFindButton()
	local tab = self.statusTab
	local b = tab and tab.findMe
	if not b then return end
	b:SetShown(self:FeatureOn("map"))
	local ok = self:FindMeState()
	b:SetEnabled(ok and true or false)
	b:SetGreyed(not ok)
	if b.plain then b:SetAlpha(ok and 1 or 0.45) end
end

local function DungeonLabel(i)
	local e = GH.DUNGEONS[i]
	if not e then return L.LFG_ANY end
	if e.min == e.max then return ("%s (%d)"):format(e.name, e.min) end
	return ("%s (%d-%d)"):format(e.name, e.min, e.max)
end

-- 1.0.0-beta.1: the picker's entries in order (any, dungeons by level, raids last; hidden raids left out).
local function DungeonOrder()
	return GH.DUNGEON_ORDER or {}
end

-- The Dungeon picker: a WowStyle1Dropdown menu (2 columns when this client's menus can do a grid,
-- else one list that scrolls), or the old button + our own 2-column list.
function GH:MakeDungeonPicker(panel)
	local dd = W.Dropdown(panel, 206)
	if dd then
		dd:SetupMenu(function(_, root)
			local grid = root.SetGridMode and MenuConstants and MenuConstants.VerticalGridDirection
			if not (grid and pcall(root.SetGridMode, root, MenuConstants.VerticalGridDirection, 2)) then
				if root.SetScrollMode then pcall(root.SetScrollMode, root, 400) end
			end
			for _, i in ipairs(DungeonOrder()) do
				root:CreateRadio(DungeonLabel(i), function()
					local own = GH:GetOwnStatus() or {}
					return (own.d or 0) == i
				end, function()
					GH:SetLfgDungeon(i)
					GH:UpdateOwnPanel()
				end)
			end
		end)
		return dd
	end
	local dung = W.Button(panel, "", 206, 22)
	dung:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	dung:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			GH:HideDungeonPicker()
		else
			GH:ToggleDungeonPicker(dung)
		end
	end)
	return dung
end

-- Closes the dungeon list (our own list, or the dropdown's menu).
function GH:HideDungeonPicker()
	if self.dungeonPicker then self.dungeonPicker:Hide() end
	local dd = self.statusTab and self.statusTab.dungeon
	if dd and dd.isDropdown then pcall(dd.CloseMenuIfOpen, dd) end
end

function GH:ToggleDungeonPicker(anchor)
	if anchor and anchor.isDropdown then -- the dropdown opens its own menu
		if anchor:IsMenuOpen() then anchor:CloseMenu() else anchor:OpenMenu() end
		return
	end
	local pick = self.dungeonPicker
	if not pick then
		pick = CreateFrame("Frame", nil, self.mainFrame, "BackdropTemplate")
		W.Skin(pick, 0.98)
		pick:SetFrameStrata("DIALOG")
		local order = DungeonOrder()
		local perCol = math.ceil(#order / 2)
		pick:SetSize(2 * 196 + 12, perCol * 18 + 12)
		for pos, i in ipairs(order) do
			local b = W.PlainButton(pick, DungeonLabel(i), 192, 17)
			b:SetBackdropBorderColor(0, 0, 0, 0)
			b.label:ClearAllPoints()
			b.label:SetPoint("LEFT", 6, 0)
			local col, row = math.floor((pos - 1) / perCol), (pos - 1) % perCol
			b:SetPoint("TOPLEFT", 6 + col * 196, -6 - row * 18)
			b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			b:SetScript("OnClick", function(_, button)
				if button == "RightButton" then pick:Hide() return end -- right-click closes the list
				GH:SetLfgDungeon(i)
				GH:UpdateOwnPanel()
				pick:Hide()
			end)
		end
		pick:EnableMouse(true)
		pick:SetScript("OnMouseUp", function(_, button) if button == "RightButton" then pick:Hide() end end)
		pick:Hide() -- new frames start shown; without this the first click only "closed" it
		self.dungeonPicker = pick
	end
	if pick:IsShown() then pick:Hide() return end
	pick:ClearAllPoints()
	pick:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
	pick:Show()
end

-- Places one part at the cursor (x from the panel's left) and moves the cursor down.
local function Place(panel, part, x, y)
	part:ClearAllPoints()
	part:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
end

function GH:UpdateOwnPanel(resetNote)
	local tab = self.statusTab
	if not tab then return end
	local panel = tab.panel
	local own = self:GetOwnStatus() or {}
	local fresh = self:IsStatusFresh(own)
	local p = fresh and own.p or nil
	local y = -34

	-- state line
	if p and own.st then
		local head = L.PRESET[p] or p
		if p == "lfg" and own.d and own.d > 0 then head = head .. ": " .. self:DungeonName(own.d) end
		local left = U.Duration(math.max(0, self:StatusDuration(own) - (U.Now() - own.st)))
		tab.state:SetText(L.MY_STATE:format(head, left))
		local c = self.GROUP_COLOR[p] or self.GROUP_COLOR.other
		tab.state:SetTextColor(c[1], c[2], c[3])
	elseif fresh and own.t and own.st then
		tab.state:SetText(L.CLEARS_IN:format(U.Duration(math.max(0, self:StatusDuration(own) - (U.Now() - own.st)))))
		tab.state:SetTextColor(0.85, 0.85, 0.85)
	else
		tab.state:SetText(L.NO_STATUS)
		tab.state:SetTextColor(0.6, 0.6, 0.6)
	end
	Place(panel, tab.state, PANEL_X + 2, y)
	y = y - 18

	-- news strip
	local lines = self:NewsLines()
	tab.newsCount = #lines
	for i, b in ipairs(tab.news.lines) do
		local e = lines[i]
		b:SetShown(e ~= nil)
		if e then
			b:SetLabel(e.text)
			b.onClick, b.tip = e.onClick, e.tip
		end
	end
	tab.news:SetShown(#lines > 0)
	if #lines > 0 then
		tab.news:SetHeight(6 + 17 * #lines)
		Place(panel, tab.news, PANEL_X, y)
		y = y - (6 + 17 * #lines) - 8
	end

	-- Status
	if tab.preset then
		Place(panel, tab.lblStatus, PANEL_X, y - 6)
		Place(panel, tab.preset, PANEL_X + LABEL_W, y)
		tab.preset:SetLabel(p and L.PRESET[p] or L.MY_PRESET_NONE)
		tab.lblStatus:Show()
		y = y - 28
	else
		tab.lblStatus:Hide()
		for i, pk in ipairs(self.PRESETS) do
			local b = tab.chips[pk]
			local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
			Place(panel, b, PANEL_X + col * 104, y - row * 26)
			b:SetActive(p == pk)
		end
		y = y - 3 * 26 - 4
	end

	-- Dungeon (LFG only)
	local lfg = p == "lfg"
	if not lfg then self:HideDungeonPicker() end
	tab.dungeon:SetShown(lfg)
	tab.lblDungeon:SetShown(lfg and tab.dungeon.isDropdown or false)
	if lfg then
		if tab.dungeon.isDropdown then
			Place(panel, tab.lblDungeon, PANEL_X, y - 6)
			Place(panel, tab.dungeon, PANEL_X + LABEL_W, y)
			tab.dungeon:SetLabel(self:DungeonName(own.d))
		else
			Place(panel, tab.dungeon, PANEL_X, y)
			tab.dungeon:SetLabel(L.DUNGEON_FMT:format(self:DungeonName(own.d)))
		end
		y = y - 28
	end

	-- note box. Refresh it only if the player hasn't typed something unsent into it (the regular
	-- redraws must never wipe typing; the "Press Enter to share" hint covers that case).
	Place(panel, tab.note, tab.note.ghTemplate and PANEL_X + 6 or PANEL_X, y)
	y = y - 28
	local typed = tab.note:GetText()
	if resetNote or (not tab.note:HasFocus() and typed == (tab.noteShown or "")) then
		tab.noteShown = fresh and own.t or ""
		tab.note:SetText(tab.noteShown)
	end
	Place(panel, tab.noteHint, PANEL_X + 2, y + 2)
	self:UpdateNoteHint()
	if tab.noteHint:IsShown() then y = y - 14 end

	-- the highlighted button (only when it applies)
	local which, label, tip = self:OwnHighlight()
	tab.highlightKind = which
	tab.highlight:SetShown(which ~= nil)
	if which then
		tab.highlight:SetLabel(label)
		tab.highlight.tip = tip
		tab.highlight:SetActive(true)
		Place(panel, tab.highlight, PANEL_X, y - 2)
		y = y - 32
	end

	-- Lasts + Clear all
	local hasTick = false
	for _, e in ipairs(self:Hooks("myStatus")) do
		if type(e.get) == "function" then
			local ok, on = pcall(e.get, self)
			if ok and on then hasTick = true end
		end
	end
	if tab.lasts.isDropdown then
		Place(panel, tab.lblLasts, PANEL_X, y - 6)
		Place(panel, tab.lasts, PANEL_X + LABEL_W - 14, y)
		tab.lblLasts:Show()
		tab.lasts:SetLabel(HoursText(self:OwnHours()))
	else
		tab.lblLasts:Hide()
		Place(panel, tab.lasts, PANEL_X, y)
		tab.lasts:SetLabel(L.LASTS_FMT:format(self:OwnHours()))
	end
	tab.lasts:SetEnabled(fresh) -- nothing to apply it to without a status
	if tab.lasts.plain then tab.lasts:SetAlpha(fresh and 1 or 0.45) end -- the red button greys itself
	tab.clear:ClearAllPoints()
	tab.clear:SetPoint("TOPRIGHT", panel, "TOPLEFT", PANEL_X + PANEL_W, y)
	tab.clear:SetShown(fresh or hasTick)
	y = y - 30

	-- ticks from features (myStatus hook): { key, text, get, set, why }
	local n = 0
	for _, e in ipairs(self:Hooks("myStatus")) do
		if type(e.text) == "string" and type(e.get) == "function" and type(e.set) == "function" then
			n = n + 1
			local cb = tab.ticks[n]
			if not cb then
				cb = W.CheckButton(panel, "", PANEL_W)
				cb:SetScript("OnClick", function(s)
					local entry = s.entry
					if not entry then return end
					local okG, on = pcall(entry.get, GH)
					pcall(entry.set, GH, not (okG and on))
					GH:UpdateOwnPanel()
				end)
				cb:SetScript("OnEnter", function(s)
					local why = s.entry and s.entry.why
					if type(why) ~= "string" then return end
					GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
					GameTooltip:AddLine(why, 1, 1, 1, true)
					GameTooltip:Show()
				end)
				cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
				tab.ticks[n] = cb
			end
			cb.entry = e
			if cb.label then cb.label:SetText(e.text) end
			local okG, on = pcall(e.get, self)
			cb:SetActive(okG and on and true or false)
			Place(panel, cb, PANEL_X, y)
			cb:Show()
			y = y - 26
		end
	end
	for i = n + 1, #tab.ticks do tab.ticks[i]:Hide() end

	-- Find me
	Place(panel, tab.findMe, PANEL_X, y - 4)
	y = y - 32

	-- Pause alerts / paused + Resume
	local left = self.AlertsPausedLeft and self:AlertsPausedLeft() or 0
	tab.pause:SetShown(left <= 0)
	tab.paused:SetShown(left > 0)
	tab.resume:SetShown(left > 0)
	if left > 0 then
		tab.paused:SetText(L.MY_PAUSED:format(U.Duration(left)))
		Place(panel, tab.paused, PANEL_X + 2, y - 4)
		tab.resume:ClearAllPoints()
		tab.resume:SetPoint("TOPRIGHT", panel, "TOPLEFT", PANEL_X + PANEL_W, y + 1)
	else
		Place(panel, tab.pause, PANEL_X, y)
	end
	tab.layoutBottom = y - 20

	if not self.db.profile.autoActivity then
		tab.autoAct:SetText(L.AUTO_ACT_OFF)
	else
		tab.autoAct:SetText(L.AUTO_ACT_FMT:format(own.a and L.ACT[own.a] or L.AUTO_ACT_NONE))
	end
	self:UpdateFindButton()
	if self.lfgMatch and self.lfgMatch:IsShown() then self:FillLfgMatch() end
end

------------------------------------------------------------------------
-- 1.0.0-beta.1 LFG match pop-up: who else wants the same dungeon, one Invite per row
-- (tos-check item 2: one InviteUnit per click, from the click only; greyed in combat, for ignored or
-- muted players, and for players already in your group or in a full group).
------------------------------------------------------------------------
local MATCH_ROWS = 8
local MATCH_W = 320

function GH:ShowLfgMatch()
	local f = self.lfgMatch
	if not f then
		f = W.Popup("GuildHubLfgMatch", self.mainFrame or UIParent)
		f:SetSize(MATCH_W, 60 + MATCH_ROWS * 22)
		f:SetFrameStrata("DIALOG")
		f:SetToplevel(true)
		f:EnableMouse(true)
		f.title = W.Text(f, "GameFontNormal")
		f.title:SetPoint("TOPLEFT", 14, -12)
		f.title:SetWidth(MATCH_W - 50)
		local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -2, -2)
		f.closeButton = close
		f.hint = W.Text(f, "GameFontDisableSmall", L.MATCH_HINT)
		f.hint:SetPoint("BOTTOMLEFT", 14, 10)
		f.rows = {}
		for i = 1, MATCH_ROWS do
			local r = CreateFrame("Button", nil, f)
			r:SetSize(MATCH_W - 24, 20)
			r:SetPoint("TOPLEFT", 12, -34 - (i - 1) * 22)
			r:RegisterForClicks("RightButtonUp")
			local hl = r:CreateTexture(nil, "HIGHLIGHT")
			hl:SetAllPoints()
			hl:SetColorTexture(1, 1, 1, 0.06)
			r.name = W.Text(r, "GameFontHighlightSmall")
			r.name:SetPoint("LEFT", 2, 0)
			r.name:SetWidth(90)
			r.lvl = W.Text(r, "GameFontHighlightSmall", nil, "RIGHT")
			r.lvl:SetPoint("LEFT", 92, 0)
			r.lvl:SetWidth(20)
			r.note = W.Text(r, "GameFontDisableSmall")
			r.note:SetPoint("LEFT", 120, 0)
			r.note:SetWidth(MATCH_W - 24 - 120 - 64)
			r.invite = W.Button(r, L.BTN_INVITE, 56, 18, "GameFontNormalSmall")
			r.invite:SetPoint("RIGHT", 0, 0)
			if r.invite.SetMotionScriptsWhileDisabled then r.invite:SetMotionScriptsWhileDisabled(true) end
			r.invite:SetScript("OnClick", function()
				if r.member and GH:InviteMatch(r.member) then GH:FillLfgMatch() end
			end)
			r.invite:SetScript("OnEnter", function(s)
				local ok, why = GH:LfgMatchState(r.member)
				if ok then return end
				GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
				GameTooltip:AddLine(L.BTN_INVITE, 1, 0.82, 0)
				local text = why == "ingroupthem" and L.INVITE_IN_GROUP or L.ACT_WHY[why] or why
				GameTooltip:AddLine((text:gsub("%%d", "0")), 1, 0.3, 0.3, true)
				GameTooltip:Show()
			end)
			r.invite:SetScript("OnLeave", function() GameTooltip:Hide() end)
			r:SetScript("OnClick", function(s, button)
				if button == "RightButton" and s.member and GH.ShowNameMenu then GH:ShowNameMenu(s, s.member, "match") end
			end)
			f.rows[i] = r
		end
		f:SetScript("OnHide", function() GameTooltip:Hide() end)
		self.lfgMatch = f
	end
	f:ClearAllPoints()
	local panel = self.statusTab and self.statusTab.panel
	if panel and panel:IsVisible() then
		f:SetPoint("TOPRIGHT", panel, "TOPLEFT", -6, 0)
	else
		f:SetPoint("CENTER")
	end
	self:FillLfgMatch()
	f:Show()
end

function GH:FillLfgMatch()
	local f = self.lfgMatch
	if not f then return end
	local list, d = self:LfgMatches()
	if not d or #list == 0 then f:Hide() return end
	local dn = self:DungeonName(d)
	f.title:SetText(#list == 1 and L.NEWS_MATCH1:format(dn) or L.NEWS_MATCHN:format(#list, dn))
	for i, r in ipairs(f.rows) do
		local m = list[i]
		r.member = m and m.name
		r:SetShown(m ~= nil)
		if m then
			r.name:SetText(U.ClassColored(m.name, m.class))
			r.lvl:SetText(tostring(m.level or "?"))
			r.note:SetText(m.note or L.MATCH_NONOTE) -- cleaned when received, never holds | codes
			local ok = self:LfgMatchState(m.name)
			r.invite:SetEnabled(ok and true or false)
			r.invite:SetGreyed(not ok)
		end
	end
	f:SetHeight(60 + math.min(#list, MATCH_ROWS) * 22)
end

-- "Press Enter to share" while the note box holds text that isn't shared yet.
function GH:UpdateNoteHint()
	local tab = self.statusTab
	if not tab or not tab.noteHint then return end
	local own = self:GetOwnStatus() or {}
	local shared = self:IsStatusFresh(own) and own.t or nil
	local typed = U.CleanText(tab.note:GetText(), 80)
	tab.noteHint:SetShown(typed ~= shared)
end

------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------
function GH:DrawStatusTab()
	local tab = self.statusTab
	if not tab then return end
	local db = self.db.profile
	tab.sort:SetLabel(L.SORT_FMT:format(L.SORT[db.sort] or db.sort))
	tab.compact:SetActive(db.compact)
	local rows, online = self:BuildStatusRows({
		search = tab.search:GetText(), sort = db.sort, compact = db.compact, showNoAddon = db.showNoAddon,
		folded = db.folded,
	})
	tab.data = rows
	-- 1.0.0-beta.2 (Q8): the empty list says why
	local searching = (tab.search:GetText() or "") ~= ""
	tab.empty:SetText((not self.rosterReady and L.EMPTY_WAIT) or (searching and L.EMPTY_SEARCH)
		or (db.compact and L.EMPTY_LFG) or (not db.showNoAddon and online > 0 and L.EMPTY_NOADDON) or L.EMPTY_LIST)
	if tab.scrollBox then
		-- the ScrollBox reuses its row frames; stay in place unless the search/filter changed
		W.SetListData(tab.scrollBox, rows, not tab.toTop)
		tab.toTop = nil
		tab.empty:SetShown(#rows == 0)
	else
		tab.toTop = nil
		local max = math.max(0, #rows - tab.visible)
		if tab.offset > max then tab.offset = max end
		tab.bar:SetMinMaxValues(0, max)
		tab.bar:SetValue(tab.offset)
		tab.bar:SetShown(max > 0)
		self:DrawRows()
	end
	self:UpdateOwnPanel()
end

-- 1.0.0-beta.2 (Q5): fold / open one group of the board (saved per profile, local only).
function GH:ToggleFold(group)
	if type(group) ~= "string" or not (self.GROUP_COLOR and self.GROUP_COLOR[group]) then return end
	local db = self.db.profile
	if type(db.folded) ~= "table" then db.folded = {} end
	db.folded[group] = (not db.folded[group]) or nil
	self:DrawStatusTab()
end

-- Our own rows (only when the ScrollBox list isn't available).
function GH:DrawRows()
	local tab = self.statusTab
	if not tab.rows then return end
	local rows = tab.data or {}
	for i, r in ipairs(tab.rows) do
		local d = rows[i + tab.offset]
		if d then
			FillRow(r, d)
			r:Show()
		else
			r:Hide()
		end
	end
	tab.empty:SetShown(#rows == 0)
end
