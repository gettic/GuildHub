-- Guild Hub: the Map tab, "Who is where" (0.6.0-beta.3, plans\next-beta; tos: plans\next-beta\tos-check.md).
-- Left: online guildmates grouped by zone (Blizzard's guild list), your zone on top, a dot icon only for
-- guildmates whose exact position you can see (they share, you share too: fair trade). Left-click a row =
-- Show on map, right-click = the name menu (UI\NameMenu.lua), hover = the map dots' hover card.
-- Right: your position choice, Find me, Open world map, how many share, guildmates in dungeons, the two
-- map settings. Current online state only: nothing is saved and nothing is sent by this page.
-- The View dropdown waits for a second view (Map notes, 1.2).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local ROW_H = 20
local LIST_W = 778
local PAGE_H = 460
local PANEL_W = 220
local DUNGEON_LINES = 4
local COL = { name = { 28, 150 }, lvl = { 182, 30 }, status = { 220, 500 }, dot = { 748, 10 } }
GH.MAP_COLUMNS, GH.MAP_LIST_W = COL, LIST_W

------------------------------------------------------------------------
-- Rows (plain tables)
------------------------------------------------------------------------
local function Lower(s) return type(s) == "string" and s:lower() or "" end

local function StatusText(gh, name, r)
	local gdb = gh:GetGuildDB()
	local m = gdb and gdb.members and gdb.members[name]
	local s = m and m.status
	if s and gh:IsStatusFresh(s) then
		local t = gh:StatusLine(s, true, gh:IsMuted(name))
		if t and t ~= "" then return t, false end
	end
	if r and not U.IsSecret(r.afk) and r.afk == true then return L.MAP_ROW_AFK, true end
	return "", false
end

-- opts = { search, addonOnly } -> rows, online (not you), sharers seen
function GH:BuildMapRows(opts)
	opts = opts or {}
	local q = Lower(opts.search)
	local me = self:MyName()
	local myZone = self.roster[me] and self.roster[me].zone
	if type(myZone) ~= "string" or U.IsSecret(myZone) then myZone = nil end
	local zones, online, seen = {}, 0, 0
	for name, r in pairs(self.roster) do
		local z = r.zone
		if r.online and name ~= me and type(z) == "string" and not U.IsSecret(z) and z ~= "" then
			online = online + 1
			local dot = self:UsablePosition(name) ~= nil
			if dot then seen = seen + 1 end
			local addon = self:IsAddonUserOnline(name)
			local hit = q == "" or Lower(U.ShortName(name)):find(q, 1, true) or Lower(z):find(q, 1, true)
			if hit and (addon or not opts.addonOnly) then
				local text, afk = StatusText(self, name, r)
				local list = zones[z]
				if not list then list = {}; zones[z] = list end
				list[#list + 1] = { name = name, class = r.class, level = r.level, zone = z, status = text,
					afk = afk, dot = dot, noAddon = not addon }
			end
		end
	end
	local order = {}
	for z, list in pairs(zones) do
		table.sort(list, function(a, b) return a.name < b.name end)
		order[#order + 1] = z
	end
	table.sort(order, function(a, b)
		if a == myZone then return true elseif b == myZone then return false end
		if #zones[a] ~= #zones[b] then return #zones[a] > #zones[b] end
		return a < b
	end)
	local rows = {}
	for _, z in ipairs(order) do
		local inst = self.INSTANCE_BY_NAME[z]
		local short = inst and inst.short
		local raid = short and self.ENTRANCE_BY_SHORT and self.ENTRANCE_BY_SHORT[short] and self.ENTRANCE_BY_SHORT[short].raid or (inst and inst.raid) -- 1.0.0-beta.1: new raids have no entrance spot yet
		rows[#rows + 1] = { header = z, count = #zones[z], mine = z == myZone, inst = inst and (raid and "raid" or "dungeon") or nil }
		for _, d in ipairs(zones[z]) do rows[#rows + 1] = d end
	end
	return rows, online, seen
end

------------------------------------------------------------------------
-- Building the tab
------------------------------------------------------------------------
local function SetupRow(r)
	r.ghRow = true
	local bg = r:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	r.bg = bg
	r.hl = W.RowHighlight(r)
	local function col(c, font, justify)
		local fs = W.Text(r, font or "GameFontHighlight", nil, justify)
		fs:SetPoint("LEFT", c[1], 0)
		fs:SetWidth(c[2])
		return fs
	end
	r.name = col(COL.name)
	r.lvl = col(COL.lvl, "GameFontHighlightSmall")
	r.status = col(COL.status, "GameFontHighlightSmall")
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(16, 16)
	r.icon:SetPoint("LEFT", 6, 0)
	r.header = W.Text(r, "GameFontNormal")
	r.header:SetPoint("LEFT", 26, 0)
	r.headNote = W.Text(r, "GameFontDisableSmall", L.MAP_YOUR_ZONE)
	r.headNote:SetPoint("LEFT", r.header, "RIGHT", 8, 0)
	r.headerLine = W.HeaderLine(r, r.headNote)
	r.dot = r:CreateTexture(nil, "ARTWORK")
	r.dot:SetSize(COL.dot[2], COL.dot[2])
	r.dot:SetPoint("LEFT", COL.dot[1], 0)
	local kind, art = GH:DotArt()
	if kind == "atlas" then r.dot:SetAtlas(art) else r.dot:SetTexture(art) end
	if r.RegisterForClicks then r:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
	r:SetScript("OnClick", function(self, button)
		local d = self.data
		if button == "LeftButton" and d and not d.header then GH:ShowOnMap(d.name) end
	end)
	r:SetScript("OnEnter", function(self)
		local d = self.data
		if not d or d.header or (InCombatLockdown and InCombatLockdown()) then return end
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GH:AddHoverCard(d.name, d.dot and GH.positions[d.name] or nil)
		if d.dot then GameTooltip:AddLine(L.MAP_DOT_TIP, 0.55, 0.8, 1, true) end
		GameTooltip:AddLine(L.MAP_ROW_HINT, 0.5, 0.5, 0.5)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	GH:NameMenuOnRow(r, function(s) return s.data and not s.data.header and s.data.name or nil end, "map")
end

local function ClassRGB(class)
	local c = type(RAID_CLASS_COLORS) == "table" and class and RAID_CLASS_COLORS[class]
	if type(c) == "table" and type(c.r) == "number" then return c.r, c.g, c.b end
	return W.GOLD[1], W.GOLD[2], W.GOLD[3]
end

local function FillRow(r, d)
	r.data = d
	local isHeader = d.header ~= nil
	r.header:SetShown(isHeader)
	r.headNote:SetShown(isHeader and d.mine == true)
	if r.headerLine then r.headerLine:SetShown(isHeader) end
	r.name:SetShown(not isHeader)
	r.lvl:SetShown(not isHeader)
	r.status:SetShown(not isHeader)
	r.hl:SetShown(not isHeader)
	r.dot:SetShown(not isHeader and d.dot == true)
	if isHeader then
		r.header:SetText(L.MAP_ZONE_HEAD:format(d.header, d.count))
		r.header:SetTextColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
		local atlas = d.inst and W.DungeonIconArt(d.inst)
		if atlas then r.icon:SetAtlas(atlas) end
		r.icon:SetShown(atlas and true or false)
		r.bg:SetColorTexture(0, 0, 0, 0)
		return
	end
	r.icon:Hide()
	r.bg:SetColorTexture(1, 1, 1, 0.03)
	if d.noAddon then
		r.name:SetText(U.ShortName(d.name))
		r.name:SetTextColor(0.5, 0.5, 0.5)
	else
		r.name:SetText(U.ClassColored(d.name, d.class))
		r.name:SetTextColor(1, 1, 1)
	end
	r.lvl:SetText(tostring(d.level or "?"))
	r.status:SetText(d.status or "")
	local grey = d.afk or d.noAddon
	if grey then r.status:SetTextColor(0.55, 0.55, 0.55) else r.status:SetTextColor(1, 1, 1) end
	if d.dot then r.dot:SetVertexColor(ClassRGB(d.class)) end
end

local function MakePlainList(tab, area)
	tab.rows = {}
	local n = math.floor(tab.listHeight / ROW_H)
	for i = 1, n do
		local r = CreateFrame("Button", nil, area)
		r:SetSize(LIST_W, ROW_H - 2)
		r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
		SetupRow(r)
		tab.rows[i] = r
	end
	tab.offset = 0
	area:EnableMouseWheel(true)
	area:SetScript("OnMouseWheel", function(_, delta)
		local max = math.max(0, #(tab.data or {}) - #tab.rows)
		tab.offset = math.max(0, math.min(max, tab.offset - delta * 3))
		GH:DrawMapRows()
	end)
end

local function PanelButton(panel, text, onClick)
	local b = W.Button(panel, text, PANEL_W - 24, 22)
	if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
	b:SetScript("OnClick", onClick)
	return b
end

local function Tick(panel, text, key, after)
	local cb = W.CheckButton(panel, text, PANEL_W - 24)
	cb:SetScript("OnClick", function()
		local p = GH.db.profile
		p[key] = p[key] == false
		if key == "mapMinimap" and GH.MapRedraw then GH:MapRedraw() end
		if after then after() end
		if GH.optionsChanged then GH:optionsChanged() end
		GH:DrawMapPanel()
	end)
	return cb
end

local function BuildPanel(tab, page)
	local panel = W.Inset(page)
	panel:SetPoint("TOPLEFT", LIST_W + 26, 0)
	panel:SetPoint("BOTTOMRIGHT", -2, 24)
	tab.panel = panel
	local title = W.Text(panel, "GameFontNormalLarge", L.MAP_POS_TITLE)
	title:SetPoint("TOPLEFT", 12, -12)
	tab.posNow = W.Text(panel, "GameFontHighlightSmall")
	tab.posNow:SetPoint("TOPLEFT", 14, -36)
	tab.posNow:SetWidth(PANEL_W - 20)
	tab.posDesc = W.Text(panel, "GameFontDisableSmall")
	tab.posDesc:SetPoint("TOPLEFT", 14, -52)
	tab.posDesc:SetWidth(PANEL_W - 20)
	tab.posDesc:SetWordWrap(true)
	tab.share = PanelButton(panel, L.MAP_POS_SHARE, function() GH:SetMapShare("yes"); GH:DrawMapTab() end)
	tab.zone = PanelButton(panel, L.MAP_POS_ZONE, function() GH:SetMapShare("no"); GH:DrawMapTab() end)
	tab.trialNote = W.Text(panel, "GameFontNormalSmall", L.MAP_POS_TRIAL)
	tab.trialNote:SetTextColor(1, 0.3, 0.3)
	tab.findMe = PanelButton(panel, L.FIND_BUTTON, function() GH:FindMe(); GH:DrawMapPanel() end)
	tab.findMe:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L.FIND_BUTTON, 1, 0.82, 0)
		GameTooltip:AddLine(L.FIND_TIP, 1, 1, 1, true)
		local ok, why, left = GH:FindMeState()
		if not ok then GameTooltip:AddLine(L.FIND_TIP_NO:format((L.FIND_WHY[why] or why):format(left or 0)), 1, 0.3, 0.3, true) end
		GameTooltip:Show()
	end)
	tab.findMe:SetScript("OnLeave", function() GameTooltip:Hide() end)
	tab.openMap = PanelButton(panel, L.MAP_OPEN_MAP, function() GH:OpenTheWorldMap() end)
	W.Tooltip(tab.openMap, L.MAP_OPEN_MAP_TIP)
	tab.cover = W.Text(panel, "GameFontHighlightSmall")
	tab.cover:SetWidth(PANEL_W - 20)
	tab.cover:SetWordWrap(true)
	tab.dungTitle = W.Text(panel, "GameFontNormal", L.MAP_DUNGEONS_TITLE)
	tab.dung = {}
	for i = 1, DUNGEON_LINES do
		local fs = W.Text(panel, "GameFontHighlightSmall")
		fs:SetWidth(PANEL_W - 20)
		tab.dung[i] = fs
	end
	tab.tickAfk = Tick(panel, L.MAP_TICK_AFK, "mapHideAfk", function() if GH.PosTick then GH:PosTick() end end)
	tab.tickAfk:SetPoint("BOTTOMLEFT", 10, 10)
	tab.tickMini = Tick(panel, L.MAP_TICK_MINIMAP, "mapMinimap")
	tab.tickMini:SetPoint("BOTTOMLEFT", tab.tickAfk, "TOPLEFT", 0, 2)
end

function GH:BuildMapTab(page)
	local tab = { page = page }
	self.mapTab = tab
	-- toolbar strip (same place as the Status page's)
	local search = W.EditBox(page, 330, 22, 40, L.MAP_SEARCH_HINT, "search")
	search:SetPoint("TOPLEFT", page, "TOPLEFT", search.ghTemplate and 12 or 6, -3)
	search:HookScript("OnEnterPressed", function(s) s:ClearFocus() end)
	search:HookScript("OnEscapePressed", function(s) s:SetText(""); s:ClearFocus(); GH:DrawMapTab(true) end)
	search:HookScript("OnTextChanged", function() GH:DrawMapTab(true) end)
	tab.search = search
	tab.addonOnly = W.CheckButton(page, L.MAP_ADDON_ONLY, 150)
	tab.addonOnly:SetPoint("LEFT", search, "RIGHT", 12, 0)
	tab.addonOnly:SetScript("OnClick", function()
		local p = GH.db.profile
		p.showNoAddon = not p.showNoAddon -- the Status board's setting (ticked = only Guild Hub users)
		if GH.optionsChanged then GH:optionsChanged() end
		GH:RefreshBoard()
		GH:DrawMapTab(true)
	end)
	W.Tooltip(tab.addonOnly, L.MAP_ADDON_ONLY_TIP)

	local inset = W.Inset(page)
	inset:SetPoint("TOPLEFT", 2, -GH.TOOLBAR_H)
	inset:SetPoint("BOTTOMLEFT", 2, 24)
	inset:SetWidth(LIST_W + 20)
	tab.listInset = inset
	local area = CreateFrame("Frame", nil, inset)
	area:SetPoint("TOPLEFT", 6, -6)
	area:SetPoint("BOTTOMLEFT", 6, 4)
	area:SetWidth(LIST_W + 12)
	tab.listArea = area
	tab.listHeight = PAGE_H - GH.TOOLBAR_H - 24 - 10
	local box, bar = W.ScrollList(area, ROW_H, function(r, d)
		if not r.ghRow then SetupRow(r) end
		FillRow(r, d)
	end)
	if box then
		box:SetPoint("TOPLEFT", 0, 0)
		box:SetPoint("BOTTOMLEFT", 0, 0)
		box:SetWidth(LIST_W)
		bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
		bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
		tab.scrollBox, tab.scrollBar = box, bar
	else
		MakePlainList(tab, area)
	end
	tab.empty = W.Text(area, "GameFontDisable", L.MAP_EMPTY)
	tab.empty:SetPoint("TOP", 0, -40)
	tab.note = W.Text(page, "GameFontHighlightSmall")
	tab.note:SetPoint("BOTTOMLEFT", 8, 8)
	tab.note:SetWidth(LIST_W)
	BuildPanel(tab, page)
	-- while shown: redraw every 10 s, a fresh guild list every 15 s (like the Status page)
	page:SetScript("OnUpdate", function(_, elapsed)
		tab.tick = (tab.tick or 0) + elapsed
		tab.rosterTick = (tab.rosterTick or 0) + elapsed
		if tab.rosterTick >= 15 then tab.rosterTick = 0; GH:RequestRoster() end
		if tab.tick >= 10 then tab.tick = 0; GH:DrawMapTab() end
	end)
end

function GH:ShowMapTab(page)
	if not self.mapTab then self:BuildMapTab(page) end
	self:DrawMapTab(true)
end

-- The Map tab is shown right now?
function GH:MapTabShown()
	local f = self.mainFrame
	return f and f:IsShown() and f.currentTab == "map" and self.mapTab ~= nil or false
end

function GH:DrawMapTab(toTop)
	local tab = self.mapTab
	if not tab then return end
	local p = self.db.profile
	tab.addonOnly:SetActive(not p.showNoAddon)
	local rows, online, seen = self:BuildMapRows({ search = tab.search:GetText(), addonOnly = not p.showNoAddon })
	tab.data = rows
	tab.online, tab.seen = online, seen
	if tab.scrollBox then
		W.SetListData(tab.scrollBox, rows, not toTop)
	else
		if toTop then tab.offset = 0 end
		self:DrawMapRows()
	end
	local searching = (tab.search:GetText() or "") ~= ""
	tab.empty:SetShown(#rows == 0)
	tab.empty:SetText(searching and online > 0 and L.MAP_NO_MATCH or L.MAP_EMPTY)
	if self:CanUse("pos") and self:FeatureOn("map") then
		tab.note:SetText(L.MAP_NOTE_COUNT:format(seen, online))
	else
		tab.note:SetText(L.MAP_NOTE_SHARE)
	end
	self:DrawMapPanel()
end

function GH:DrawMapRows()
	local tab = self.mapTab
	if not (tab and tab.rows) then return end
	for i, r in ipairs(tab.rows) do
		local d = tab.data and tab.data[tab.offset + i]
		r:SetShown(d ~= nil)
		if d then FillRow(r, d) end
	end
end

local function Enable(b, on)
	b:SetEnabled(on and true or false)
	b:SetGreyed(not on)
	if b.plain then b:SetAlpha(on and 1 or 0.45) end
end

function GH:DrawMapPanel()
	local tab = self.mapTab
	if not tab then return end
	local trial = self.cannotSend and true or false
	local ans = self:MapShareAnswer()
	tab.posNow:SetText(L.MAP_POS_NOW:format(trial and L.MAP_POS_STATE.no or L.MAP_POS_STATE[ans]))
	tab.posDesc:SetText(trial and L.MAP_POS_DESC.trial or L.MAP_POS_DESC[ans])
	-- one button per state (ask: both); the click is the answer, as on the welcome card (tos 6)
	local y = -84
	local function Place(b, show)
		b:SetShown(show)
		if show then
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", 12, y)
			y = y - 28
		end
	end
	Place(tab.share, trial or ans ~= "yes")
	Place(tab.zone, not trial and ans ~= "no")
	Enable(tab.share, not trial)
	tab.trialNote:SetShown(trial)
	if trial then
		tab.trialNote:ClearAllPoints()
		tab.trialNote:SetPoint("TOPLEFT", 14, y + 2)
		y = y - 18
	end
	y = y - 6
	local mapOn = self:FeatureOn("map")
	Place(tab.findMe, mapOn)
	if mapOn then Enable(tab.findMe, (self:FindMeState())) end
	Place(tab.openMap, true)
	tab.cover:ClearAllPoints()
	tab.cover:SetPoint("TOPLEFT", 14, y - 4)
	if self:CanUse("pos") and mapOn then
		tab.cover:SetText(L.MAP_COVER_COUNT:format(tab.seen or 0, tab.online or 0))
	else
		tab.cover:SetText(L.MAP_COVER_SHARE)
	end
	y = y - 40
	tab.dungTitle:ClearAllPoints()
	tab.dungTitle:SetPoint("TOPLEFT", 12, y)
	y = y - 20
	local lines = {}
	if self.DungeonCounts and self.DungeonLabelText then
		local list = {}
		for e, c in pairs(self:DungeonCounts()) do list[#list + 1] = { e = e, c = c } end
		table.sort(list, function(a, b)
			if a.c.total ~= b.c.total then return a.c.total > b.c.total end
			return a.e.key < b.e.key
		end)
		for i = 1, math.min(DUNGEON_LINES, #list) do lines[i] = self:DungeonLabelText(list[i].e, list[i].c) end
	end
	if #lines == 0 then lines[1] = L.MAP_DUNGEONS_NONE end
	for i, fs in ipairs(tab.dung) do
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", 14, y - (i - 1) * 16)
		fs:SetText(lines[i] or "")
		fs:SetShown(lines[i] ~= nil)
	end
	local prof = self.db.profile
	tab.tickMini:SetActive(prof.mapMinimap ~= false)
	tab.tickAfk:SetActive(prof.mapHideAfk ~= false)
	tab.tickMini:SetShown(mapOn)
	tab.tickAfk:SetShown(mapOn)
end

-- Roster / positions changed: redraw while shown (Roster.lua -> MapRosterCheck -> here, debounced).
function GH:RefreshMapTab()
	if not self:MapTabShown() or self.mapTabTimer then return end
	self.mapTabTimer = self:ScheduleTimer(function()
		GH.mapTabTimer = nil
		if GH:MapTabShown() then GH:DrawMapTab() end
	end, 0.5)
end

-- Tab registry (UI\MainFrame.lua): the third tab, only while the map feature is on.
GH:RegisterTab({ key = "map", order = 30, label = "TAB_MAP", sub = "WIN_SUB_MAP", tip = "TAB_TIP_MAP", feature = "map",
	show = function(gh, page) gh:ShowMapTab(page) end })
