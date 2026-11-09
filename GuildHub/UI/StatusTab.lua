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
	group = { 616, 52 }, whisper = { 672, 58 }, invite = { 734, 44 },
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
	if type(name) ~= "string" then return end
	local target = U.WhisperName(name)
	local tell = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
	if not (tell and pcall(tell, target)) then
		OpenChatWith("/w " .. target .. " ")
	end
end

-- Invites from the player's click. If the game blocks it, Guild Hub switches for good to
-- putting "/invite Name" in the chat box (the player presses Enter).
function GH:InviteMember(name)
	if type(name) ~= "string" then return end
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
	local f = CreateFrame("Frame")
	f:RegisterEvent("ADDON_ACTION_BLOCKED")
	f:RegisterEvent("ADDON_ACTION_FORBIDDEN")
	f:SetScript("OnEvent", function(_, _, addon, func)
		if addon ~= "GuildHub" or not GH.lastInvite then return end
		if type(func) == "string" and not U.IsSecret(func) and not func:find("Invite") then return end
		GH:UseInviteFallback()
	end)
	self.inviteWatch = f
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
	r.header = W.Text(r, "GameFontNormal")
	r.header:SetPoint("LEFT", 8, 0)
	r.headerLine = W.HeaderLine(r, r.header)
	r.whisper = W.Button(r, L.BTN_WHISPER, COL.whisper[2], 18)
	r.whisper:SetPoint("LEFT", COL.whisper[1], 0)
	r.whisper:SetScript("OnClick", function() GH:WhisperMember(r.member) end)
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
	r.whisper:SetShown(not isHeader and not d.isSelf)
	r.invite:SetShown(not isHeader and not d.isSelf)
	r.hl:SetShown(not isHeader)
	if r.headerLine then r.headerLine:SetShown(isHeader) end
	if isHeader then
		local c = GH.GROUP_COLOR[d.header] or W.GOLD
		r.header:SetText(("%s (%d)"):format(L.GROUP[d.header] or d.header, d.count))
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

	-- top bar: search, sort, "LFG only"
	local search = W.EditBox(parent, 330, 22, 40, L.SEARCH_HINT, "search")
	-- the toolbar sits in the tab row, right of the last tab (MainFrame `f.lastTab`)
	local lastTab = self.mainFrame and self.mainFrame.lastTab
	if lastTab then
		search:SetPoint("BOTTOMLEFT", lastTab, "BOTTOMRIGHT", 24, 4)
	else
		search:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", 120, 4)
	end
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
	inset:SetPoint("TOPLEFT", 2, 0) -- from the tab line: the selected tab merges into its top edge
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
	tab.listHeight = 460 - 24 - 22 - 4 -- page height minus footer, column titles and margin (17 rows)

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

	-- footer
	-- footer on the window's own background: white count, gold note (grey was hard to read there)
	tab.footer = W.Text(parent, "GameFontHighlightSmall")
	tab.footer:SetTextColor(W.COLOR.highlight[1], W.COLOR.highlight[2], W.COLOR.highlight[3])
	tab.footer:SetPoint("BOTTOMLEFT", 8, 8)
	local fr = W.Text(parent, "GameFontNormalSmall", L.FOOTER_RIGHT, "RIGHT")
	fr:SetTextColor(W.COLOR.normal[1], W.COLOR.normal[2], W.COLOR.normal[3])
	-- right-aligned to the list's right edge, 400 px wide (the text needs ~230 px; the left footer
	-- "N online · M with Guild Hub" ends well before x 330, so they never overlap)
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
-- Right side: "Your status"
------------------------------------------------------------------------
function GH:BuildOwnPanel(parent)
	local tab = self.statusTab
	local panel = W.Inset(parent)
	panel:SetPoint("TOPLEFT", LIST_W + 26, 0)
	panel:SetPoint("BOTTOMRIGHT", -2, 24)
	tab.panel = panel

	local title = W.Text(panel, "GameFontNormalLarge", L.YOUR_STATUS)
	title:SetPoint("TOPLEFT", 12, -12)

	tab.chips = {}
	for i, p in ipairs(self.PRESETS) do
		-- two per row, 100 px each, so "Open to chat" fits
		local b = W.Button(panel, L.PRESET[p], 100, 22)
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		b:SetPoint("TOPLEFT", 12 + col * 104, -40 - row * 26)
		b:SetScript("OnClick", function()
			GH:HideDungeonPicker()
			tab.note:ClearFocus()
			GH:SetPreset(p)
			GH:UpdateOwnPanel(true) -- the note box follows (cleared when switching presets)
		end)
		tab.chips[p] = b
	end

	tab.dungeon = self:MakeDungeonPicker(panel)
	tab.dungeon:SetPoint("TOPLEFT", 12, -124)

	local note = W.EditBox(panel, 206, 24, self.NOTE_LETTERS, L.NOTE_HINT)
	if note.ghTemplate then -- the input box art reaches 5 px past its left edge
		note:SetWidth(198)
		note:SetPoint("TOPLEFT", 18, -154)
	else
		note:SetPoint("TOPLEFT", 12, -152)
	end
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
	tab.noteHint:SetPoint("TOPLEFT", 14, -179)
	tab.noteHint:Hide()

	tab.clearsIn = W.Text(panel, "GameFontDisableSmall")
	tab.clearsIn:SetPoint("TOPLEFT", 14, -194)
	tab.clearsIn:SetWidth(204)

	local lasts = W.Button(panel, "", 100, 22)
	lasts:SetPoint("TOPLEFT", 12, -212)
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
	tab.lasts = lasts

	local clear = W.Button(panel, L.BTN_CLEAR, 64, 22)
	clear:SetPoint("TOPRIGHT", panel, "TOPLEFT", 216, -212)
	clear:SetScript("OnClick", function()
		tab.note:SetText("")
		GH:ClearStatus()
		GH:UpdateOwnPanel(true)
	end)
	tab.clear = clear

	tab.autoAct = W.Text(panel, "GameFontHighlightSmall")
	tab.autoAct:SetPoint("TOPLEFT", 14, -246)
	tab.autoAct:SetWidth(206)
end

local function DungeonLabel(i)
	local e = GH.DUNGEONS[i]
	if not e then return L.LFG_ANY end
	if e.min == e.max then return ("%s (%d)"):format(e.name, e.min) end
	return ("%s (%d-%d)"):format(e.name, e.min, e.max)
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
			for i = 0, #GH.DUNGEONS do
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
		local n = #self.DUNGEONS + 1
		local perCol = math.ceil(n / 2)
		pick:SetSize(2 * 196 + 12, perCol * 18 + 12)
		for i = 0, #self.DUNGEONS do
			local b = W.PlainButton(pick, DungeonLabel(i), 192, 17)
			b:SetBackdropBorderColor(0, 0, 0, 0)
			b.label:ClearAllPoints()
			b.label:SetPoint("LEFT", 6, 0)
			local col, row = math.floor(i / perCol), i % perCol
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

function GH:UpdateOwnPanel(resetNote)
	local tab = self.statusTab
	if not tab then return end
	local own = self:GetOwnStatus() or {}
	local fresh = self:IsStatusFresh(own)
	for p, b in pairs(tab.chips) do b:SetActive(fresh and own.p == p) end
	local lfg = fresh and own.p == "lfg"
	if not lfg then self:HideDungeonPicker() end
	tab.dungeon:SetShown(lfg)
	if lfg then tab.dungeon:SetLabel(L.DUNGEON_FMT:format(self:DungeonName(own.d))) end
	-- Refresh the box only if the player hasn't typed something unsent into it (the regular redraws
	-- must never wipe typing; the "Press Enter to share" hint covers that case).
	local typed = tab.note:GetText()
	if resetNote or (not tab.note:HasFocus() and typed == (tab.noteShown or "")) then
		tab.noteShown = fresh and own.t or ""
		tab.note:SetText(tab.noteShown)
	end
	self:UpdateNoteHint()
	tab.lasts:SetLabel(L.LASTS_FMT:format(self:OwnHours()))
	tab.lasts:SetEnabled(fresh) -- nothing to apply it to without a status
	if tab.lasts.plain then tab.lasts:SetAlpha(fresh and 1 or 0.45) end -- the red button greys itself
	if fresh and own.st then
		tab.clearsIn:SetText(L.CLEARS_IN:format(U.Duration(math.max(0, self:StatusDuration(own) - (U.Now() - own.st)))))
	else
		tab.clearsIn:SetText(L.NO_STATUS)
	end
	tab.clear:SetShown(fresh)
	if not self.db.profile.autoActivity then
		tab.autoAct:SetText(L.AUTO_ACT_OFF)
	else
		tab.autoAct:SetText(L.AUTO_ACT_FMT:format(own.a and L.ACT[own.a] or L.AUTO_ACT_NONE))
	end
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
	local rows, online, withAddon = self:BuildStatusRows({
		search = tab.search:GetText(), sort = db.sort, compact = db.compact, showNoAddon = db.showNoAddon,
	})
	tab.data = rows
	tab.footer:SetText(L.FOOTER:format(online, withAddon))
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
