-- Guild Hub: the Status tab (search, sort, compact, member list, "Your status" panel, footer)
-- and the Whisper / Invite actions. Whisper and Invite only ever run from the player's own click.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local ROW_H = 24
local LIST_W = 722
local SORTS = { "activity", "level", "zone", "rank", "name" }
-- column x positions and widths inside a row
local COL = {
	-- status 140 px with the time right after it ("for 1 h 10 min" needs ~90 px); actions stay at the right
	name = { 8, 116 }, rank = { 128, 86 }, lvl = { 218, 30 }, zone = { 252, 120 }, status = { 376, 140 },
	time = { 520, 92 }, whisper = { 616, 58 }, invite = { 678, 44 },
}
GH.STATUS_COLUMNS, GH.STATUS_LIST_W = COL, LIST_W -- for the offline test

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
local function MakeRow(parent)
	local r = CreateFrame("Button", nil, parent)
	r:SetSize(LIST_W, ROW_H - 2)
	local bg = r:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	r.bg = bg
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 0.85, 0.4, 0.06)
	r.hl = hl
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
	r.time = col("time", "GameFontDisableSmall")
	r.header = W.Text(r, "GameFontNormal")
	r.header:SetPoint("LEFT", 8, 0)
	r.whisper = W.Button(r, L.BTN_WHISPER, COL.whisper[2], 18)
	r.whisper:SetPoint("LEFT", COL.whisper[1], 0)
	r.whisper:SetScript("OnClick", function() GH:WhisperMember(r.member) end)
	r.invite = W.Button(r, L.BTN_INVITE, COL.invite[2], 18)
	r.invite:SetPoint("LEFT", COL.invite[1], 0)
	r.invite:SetScript("OnClick", function() GH:InviteMember(r.member) end)
	r:SetScript("OnEnter", function(self)
		local d = self.data
		if not d or d.header then return end
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:AddLine(U.ClassColored(d.name, d.class))
		if d.rank and d.rank ~= "" then GameTooltip:AddLine(d.rank, 0.8, 0.8, 0.8) end
		GameTooltip:AddLine(L.TIP_LEVEL_ZONE:format(tostring(d.level or "?"), d.zone ~= "" and d.zone or "?"), 1, 1, 1)
		if d.noAddon then
			GameTooltip:AddLine(L.NO_ADDON_ROW, 0.6, 0.6, 0.6)
		elseif d.status ~= "" then
			GameTooltip:AddLine(d.status, 1, 0.9, 0.6, true) -- cleaned text (no codes)
		end
		if not d.noAddon and d.since then
			if d.left then
				GameTooltip:AddLine(L.TIP_FOR_CLEARS:format(U.Duration(d.since), U.Duration(d.left)), 0.7, 0.7, 0.7)
			else
				GameTooltip:AddLine(L.FOR_FMT:format(U.Duration(d.since)), 0.7, 0.7, 0.7)
			end
		end
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return r
end

local function FillRow(r, d)
	r.data = d
	r.member = d.name
	local isHeader = d.header ~= nil
	r.header:SetShown(isHeader)
	for _, k in ipairs({ "name", "rank", "lvl", "zone", "status", "time" }) do r[k]:SetShown(not isHeader) end
	r.whisper:SetShown(not isHeader and not d.isSelf)
	r.invite:SetShown(not isHeader and not d.isSelf)
	r.hl:SetShown(not isHeader)
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
	r.time:SetText(d.since and L.FOR_FMT:format(U.Duration(d.since)) or "")
end

function GH:BuildStatusTab(parent)
	local tab = {}
	self.statusTab = tab
	tab.offset = 0
	local db = self.db.profile

	-- top bar: search, sort, compact
	local search = W.EditBox(parent, 330, 24, 40, L.SEARCH_HINT)
	search:SetPoint("TOPLEFT", 8, -6)
	search:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
	search:SetScript("OnEscapePressed", function(s) -- Esc empties the search and shows everyone again
		s:SetText("")
		s:ClearFocus()
		tab.offset = 0
		GH:DrawStatusTab()
	end)
	search:HookScript("OnTextChanged", function() tab.offset = 0; GH:DrawStatusTab() end)
	tab.search = search

	local sort = W.Button(parent, "", 130, 24)
	sort:SetPoint("LEFT", search, "RIGHT", 10, 0)
	sort:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	sort:SetScript("OnClick", function(_, button)
		local i = 1
		for k, v in ipairs(SORTS) do if v == db.sort then i = k end end
		local step = button == "RightButton" and -1 or 1
		db.sort = SORTS[(i - 1 + step) % #SORTS + 1]
		GH:DrawStatusTab()
	end)
	W.Tooltip(sort, L.SORT_TIP)
	tab.sort = sort

	local compact = W.Button(parent, L.COMPACT, 140, 24)
	compact:SetPoint("LEFT", sort, "RIGHT", 10, 0)
	compact:SetScript("OnClick", function()
		db.compact = not db.compact
		tab.offset = 0
		GH:DrawStatusTab()
	end)
	W.Tooltip(compact, L.COMPACT_TIP)
	tab.compact = compact

	-- column titles
	local heads = {
		{ "name", L.COL_NAME }, { "rank", L.COL_RANK }, { "lvl", L.COL_LVL }, { "zone", L.COL_ZONE }, { "status", L.COL_STATUS },
		{ "time", L.COL_TIME }, { "whisper", L.COL_ACTIONS },
	}
	for _, h in ipairs(heads) do
		local fs = W.Text(parent, "GameFontDisableSmall", h[2])
		fs:SetPoint("TOPLEFT", 8 + COL[h[1]][1], -40)
	end

	-- the list
	local list = CreateFrame("Frame", nil, parent)
	list:SetPoint("TOPLEFT", 8, -56)
	list:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 8, 30)
	list:SetWidth(LIST_W + 12)
	list:EnableMouseWheel(true)
	tab.list = list
	tab.rows = {}
	local visible = math.floor((456 - 56 - 30) / ROW_H)
	for i = 1, visible do
		local r = MakeRow(list)
		r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
		tab.rows[i] = r
	end
	tab.visible = visible
	tab.empty = W.Text(list, "GameFontDisable", L.EMPTY_LIST)
	tab.empty:SetPoint("TOP", 0, -40)

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

	-- footer
	tab.footer = W.Text(parent, "GameFontDisableSmall")
	tab.footer:SetPoint("BOTTOMLEFT", 8, 8)
	local fr = W.Text(parent, "GameFontDisableSmall", L.FOOTER_RIGHT, "RIGHT")
	fr:SetPoint("BOTTOMLEFT", LIST_W - 200, 8)
	fr:SetWidth(208)

	-- while the window is open: times and "Clears in" every 10 s, a fresh guild list every 15 s
	-- (zones, levels, who is online). OnUpdate only runs while the window is shown.
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
	local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	panel:SetPoint("TOPLEFT", LIST_W + 22, -2)
	panel:SetPoint("BOTTOMRIGHT", -2, 2)
	W.Skin(panel, 0.5, 0.1, 0.08, 0.05)
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
			if GH.dungeonPicker then GH.dungeonPicker:Hide() end
			tab.note:ClearFocus()
			GH:SetPreset(p)
			GH:UpdateOwnPanel(true) -- the note box follows (cleared when switching presets)
		end)
		tab.chips[p] = b
	end

	local dung = W.Button(panel, "", 206, 22)
	dung:SetPoint("TOPLEFT", 12, -124)
	dung:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	dung:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			if GH.dungeonPicker then GH.dungeonPicker:Hide() end
		else
			GH:ToggleDungeonPicker(dung)
		end
	end)
	tab.dungeon = dung

	local note = W.EditBox(panel, 206, 24, self.NOTE_LETTERS, L.NOTE_HINT)
	note:SetPoint("TOPLEFT", 12, -152)
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

	local lasts = W.Button(panel, "", 100, 20)
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

	local clear = W.Button(panel, L.BTN_CLEAR, 60, 20)
	clear:SetPoint("TOPRIGHT", panel, "TOPLEFT", 216, -212)
	clear:SetScript("OnClick", function()
		tab.note:SetText("")
		GH:ClearStatus()
		GH:UpdateOwnPanel(true)
	end)
	tab.clear = clear

	tab.autoAct = W.Text(panel, "GameFontHighlightSmall")
	tab.autoAct:SetPoint("TOPLEFT", 14, -244)
	tab.autoAct:SetWidth(206)
end

function GH:ToggleDungeonPicker(anchor)
	local pick = self.dungeonPicker
	if not pick then
		pick = CreateFrame("Frame", nil, self.mainFrame, "BackdropTemplate")
		W.Skin(pick, 0.98)
		pick:SetFrameStrata("DIALOG")
		local n = #self.DUNGEONS + 1
		local perCol = math.ceil(n / 2)
		pick:SetSize(2 * 196 + 12, perCol * 18 + 12)
		for i = 0, #self.DUNGEONS do
			local e = self.DUNGEONS[i]
			local label = e and ("%s (%d-%d)"):format(e.name, e.min, e.max) or L.LFG_ANY
			if e and e.min == e.max then label = ("%s (%d)"):format(e.name, e.min) end
			local b = W.Button(pick, label, 192, 17)
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
	tab.dungeon:SetShown(lfg)
	if lfg then tab.dungeon:SetLabel(L.DUNGEON_FMT:format(self:DungeonName(own.d))) end
	if not lfg and self.dungeonPicker then self.dungeonPicker:Hide() end
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
	tab.lasts:SetAlpha(fresh and 1 or 0.45)
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
	local max = math.max(0, #rows - tab.visible)
	if tab.offset > max then tab.offset = max end
	tab.bar:SetMinMaxValues(0, max)
	tab.bar:SetValue(tab.offset)
	tab.bar:SetShown(max > 0)
	self:DrawRows()
	self:UpdateOwnPanel()
end

function GH:DrawRows()
	local tab = self.statusTab
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
