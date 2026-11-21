-- Guild Hub: the /ghub window (frame, title, tab bar, saved position) and the minimap button.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

-- 1046: room for the RANK and GROUP columns; 524 = 56 title bar + tab row, 460 pages, 8 border
local WIDTH, HEIGHT = 1046, 524
local TAB_LINE = -58 -- the tabs' bottom edge: 2 px into the page's inset, so the selected tab merges with it
local PAGE_TOP = -56 -- the pages (and their insets) start here
------------------------------------------------------------------------
-- Tab registry (0.6.0-beta.3). Each page registers itself (its own file):
--   GH:RegisterTab{ key, order, label = Locale key, sub = Locale key (subtitle), feature = key (the
--     tab shows only while that feature is on), build = fn(GH, page) (once, on first show),
--     show = fn(GH, page) (every show), eager = true (built with the window), noTab = true (a page
--     without a tab: Settings, opened by the gear) }
-- At most 6 tabs (plan sec. 1); the right end of the tab row stays free (>= 200 px) for the later
-- global search. Tabs are made when the window is first made (every file has loaded by then).
------------------------------------------------------------------------
local MAX_TABS = 6
GH.TAB_MAX, GH.TAB_FREE_PX = MAX_TABS, 200
GH.TOOLBAR_H = 26 -- a page's toolbar strip (search, sort, ...) above its list; the tab row holds only tabs
GH.tabDefs, GH.tabOrder = GH.tabDefs or {}, GH.tabOrder or {}

function GH:RegisterTab(def)
	if type(def) ~= "table" or type(def.key) ~= "string" or self.tabDefs[def.key] then return false end
	if not def.noTab then
		local n = 0
		for _, k in ipairs(self.tabOrder) do if not self.tabDefs[k].noTab then n = n + 1 end end
		if n >= MAX_TABS then
			if self.Debug then self:Debug("tab %s refused: at most %d tabs", def.key, MAX_TABS) end
			return false
		end
	end
	self.tabDefs[def.key] = def
	self.tabOrder[#self.tabOrder + 1] = def.key
	table.sort(self.tabOrder, function(a, b)
		local oa, ob = self.tabDefs[a].order or 50, self.tabDefs[b].order or 50
		if oa ~= ob then return oa < ob end
		return a < b
	end)
	return true
end

-- The tabs (not the tab-less pages) in order.
function GH:TabList()
	local r = {}
	for _, k in ipairs(self.tabOrder) do
		local d = self.tabDefs[k]
		if not d.noTab then r[#r + 1] = d end
	end
	return r
end

GH:RegisterTab({ key = "status", order = 10, label = "TAB_STATUS", sub = "WIN_SUB", eager = true,
	build = function(gh, page) gh:BuildStatusTab(page) end, -- UI\StatusTab.lua (its OnUpdate stops while hidden)
	show = function(gh) if gh.mainFrame and gh.mainFrame:IsShown() then gh:RefreshBoard(true) end end })
GH:RegisterTab({ key = "settings", order = 99, sub = "WIN_SUB_SETTINGS", noTab = true,
	build = function(_, page)
		-- Settings sits in the same kind of inset as the status list, from the tab line down
		local sInset = W.Inset(page)
		sInset:SetPoint("TOPLEFT", 2, 0)
		sInset:SetPoint("BOTTOMRIGHT", -2, 2)
		page.inset = sInset
	end,
	show = function(gh, page) gh:ShowSettingsTab(page) end }) -- Options.lua

function GH:SaveWindowPos()
	local f = self.mainFrame
	if not f then return end
	local point, _, _, x, y = f:GetPoint(1)
	local w = self.db.profile.window
	-- saved in UIParent units (offset x scale), so a shrunk window (FitToScreen) keeps its place
	local s = f:GetScale() or 1
	w.point, w.x, w.y = point or "CENTER", (x or 0) * s, (y or 0) * s
end

-- The window frame: Blizzard's ButtonFrameTemplate (portrait hidden, title "Guild Hub", its own
-- close button), else our plain dark box with a title text and a close button.
local function MakeWindow()
	local f = W.FromTemplate("Frame", "GuildHubMainFrame", UIParent, "frame")
	if f then
		if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, f) end
		local portrait = W.Child(f, "PortraitContainer", "portrait")
		if portrait then portrait:Hide() end
		if f.SetTitle then f:SetTitle(L.WIN_TITLE) end
		local inset = W.Child(f, "Inset")
		if inset then inset:Hide() end -- we place our own insets
		f.closeButton = W.Child(f, "CloseButton")
		-- the subtitle sits in the title bar (on its TitleContainer so the border art doesn't cover it)
		local bar = W.Child(f, "TitleContainer") or f
		f.sub = W.Text(bar, "GameFontHighlightSmall", L.WIN_SUB) -- white: grey was hard to read on the title bar
		f.sub:SetTextColor(W.COLOR.highlight[1], W.COLOR.highlight[2], W.COLOR.highlight[3])
		f.sub:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -6)
	else
		f = CreateFrame("Frame", "GuildHubMainFrame", UIParent, "BackdropTemplate")
		W.Skin(f, 0.97)
		f:SetBackdropBorderColor(0.6, 0.48, 0.22, 1)
		local title = W.Text(f, "GameFontNormal", L.WIN_TITLE)
		title:SetPoint("TOPLEFT", 12, -8)
		f.sub = W.Text(f, "GameFontHighlightSmall", L.WIN_SUB) -- white: grey was hard to read on the title bar
		f.sub:SetTextColor(W.COLOR.highlight[1], W.COLOR.highlight[2], W.COLOR.highlight[3])
		f.sub:SetPoint("LEFT", title, "RIGHT", 10, -1)
	end
	if not f.closeButton then
		f.closeButton = W.TitleButton(f, "close")
		f.closeButton:SetPoint("TOPRIGHT", 0, 0)
	end
	return f
end

-- Tabs at the top, just under the title bar, sitting on the page's inset: PanelTopTabButtonTemplate
-- (selected with PanelTemplates_SetTab; its OnLoad marks it isTopTab, its art sits at the bottom of
-- the button), else plain buttons. Tabs fill from the left, each chained to the one before.
-- The first tab is anchored by its BOTTOM edge to TAB_LINE, so whatever height the template has,
-- the visible tab rests on the inset and never reaches into the title bar art.
local function MakeTabs(f)
	local useTpl = PanelTemplates_SetNumTabs and PanelTemplates_SetTab and W.HasTemplate(W.ART.tab)
	f.tabs, f.Tabs = {}, {}
	local TABS = GH:TabList()
	f.tabList = TABS
	for i, t in ipairs(TABS) do
		local b = useTpl and W.FromTemplate("Button", "GuildHubMainFrameTab" .. i, f, "tab")
		if b then
			b:SetID(i)
			b:SetText(L[t.label])
			if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, b, 0) end
		else
			b = W.PlainButton(f, L[t.label], 90, 24, "GameFontNormal")
		end
		b:SetScript("OnClick", function() GH:ShowTab(t.key) end)
		f.tabs[t.key] = b
		f.Tabs[i] = b
	end
	f.tabTemplate = useTpl and f.Tabs[1] and not f.Tabs[1].plain or false
	if f.tabTemplate then pcall(PanelTemplates_SetNumTabs, f, #TABS) end
	f.lastTab = f.Tabs[#TABS]
	-- the end of the visible tabs: the Status page's search box starts right of it
	f.tabEnd = CreateFrame("Frame", nil, f)
	f.tabEnd:SetSize(4, 20) -- empty, no art: only an anchor
	GH:AnchorTabs(f)
end

-- Our own anchors (after SetNumTabs, which chains every tab to the one before it). Each tab sits
-- right of the last SHOWN one, so a hidden tab (a switched-off feature) leaves no gap.
function GH:AnchorTabs(f)
	local prev
	for i in ipairs(f.tabList) do
		local b = f.Tabs[i]
		b:ClearAllPoints()
		if prev then
			b:SetPoint("BOTTOMLEFT", prev, "BOTTOMRIGHT", f.tabTemplate and 3 or 6, 0)
		else
			b:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 14, f.tabTemplate and TAB_LINE or TAB_LINE + 4)
		end
		if b:IsShown() or not prev then prev = b end
	end
	if f.tabEnd then
		f.tabEnd:ClearAllPoints()
		f.tabEnd:SetPoint("BOTTOMLEFT", prev, "BOTTOMRIGHT", 0, 0)
	end
end

-- Settings gear in the title bar, left of the "-" button (from the right: X, -, gear).
-- Click: Settings; click again while Settings shows: back to Status.
local function MakeGear(f, mini)
	local close = f.closeButton
	local w = close:GetSize()
	local gear = W.TitleButton(f, "settings", (not mini.fallback and w and w > 0) and w or nil)
	gear:SetPoint("RIGHT", mini, "LEFT", gear.fallback and -4 or 0, 0)
	local level = close:GetFrameLevel()
	if level then gear:SetFrameLevel(level) end
	gear:SetScript("OnClick", function()
		GH:ShowTab(f.currentTab == "settings" and "status" or "settings")
	end)
	W.Tooltip(gear, L.SETTINGS_TIP)
	f.gearButton = gear
end

-- Narrow screens (4:3, 5:4) or a big UI scale: UIParent can be narrower than the window. Then the
-- whole window is scaled down to fit (layout unchanged); 1 on normal screens. Never in combat.
local MIN_SCALE, SCREEN_MARGIN = 0.7, 20
local function FitToScreen(f)
	if InCombatLockdown and InCombatLockdown() then
		GH.fitAfterCombat = true
		return
	end
	local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
	if type(sw) ~= "number" or type(sh) ~= "number" or sw <= 0 or sh <= 0 then return end
	local scale = math.min(1, (sw - SCREEN_MARGIN) / WIDTH, (sh - SCREEN_MARGIN) / HEIGHT)
	scale = math.max(MIN_SCALE, scale)
	if math.abs((f:GetScale() or 1) - scale) > 0.001 then
		f:SetScale(scale)
		-- the saved offset is in unscaled units: place it again so it stays where it was
		local pos = GH.db.profile.window
		f:ClearAllPoints()
		f:SetPoint(pos.point or "CENTER", UIParent, pos.point or "CENTER", (pos.x or 0) / scale, (pos.y or 0) / scale)
	end
end
GH.FitMainFrame = function() if GH.mainFrame then FitToScreen(GH.mainFrame) end end

function GH:CreateMainFrame()
	if self.mainFrame then return self.mainFrame end
	local f = MakeWindow()
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(s)
		s:StopMovingOrSizing()
		GH:SaveWindowPos()
	end)
	local pos = self.db.profile.window
	f:SetPoint(pos.point or "CENTER", UIParent, pos.point or "CENTER", pos.x or 0, pos.y or 0)
	tinsert(UISpecialFrames, "GuildHubMainFrame") -- Esc closes it

	-- mini mode button, just left of the close button, same size and art family (Blizzard red)
	local close = f.closeButton
	local mini = W.TitleButton(f, "condense")
	if mini.fallback then
		mini:SetPoint("RIGHT", close, "LEFT", -4, 0)
	else
		local w, h = close:GetSize()
		if w and h and w > 0 then mini:SetSize(w, h) end
		mini:SetPoint("RIGHT", close, "LEFT", 2, 0)
	end
	local level = close:GetFrameLevel() -- same layer as the close button, above the border art
	if level then mini:SetFrameLevel(level) end
	mini:SetScript("OnClick", function() GH:SetMiniMode(true) end)
	W.Tooltip(mini, L.MINI_TIP)
	f.miniButton = mini
	MakeGear(f, mini)

	-- pages: 1030 x 460 under the tab row
	local content = CreateFrame("Frame", nil, f)
	content:SetPoint("TOPLEFT", 8, PAGE_TOP)
	content:SetPoint("BOTTOMRIGHT", -8, 8)
	f.content = content
	f.pages = {}
	for _, key in ipairs(self.tabOrder) do
		local page = CreateFrame("Frame", nil, content)
		page:SetAllPoints(content)
		page:Hide()
		f.pages[key] = page
	end
	MakeTabs(f) -- tabs fill from the left, in the registry's order

	f:Hide()
	f:SetScript("OnShow", function(s)
		FitToScreen(s)
		GH:RequestRoster()
		GH:RefreshBoard(true)
	end)
	f:SetScript("OnHide", function() GH:HideDungeonPicker() end)
	-- screen size / UI scale changes and a fit that waited for combat to end (Events.lua dispatcher)
	local function OnFitEvent(ev)
		if ev == "PLAYER_REGEN_ENABLED" and not GH.fitAfterCombat then return end
		GH.fitAfterCombat = nil
		if f:IsShown() then FitToScreen(f) end
	end
	for _, ev in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED", "PLAYER_REGEN_ENABLED" }) do
		self:On("window", ev, OnFitEvent)
	end
	self.mainFrame = f
	for _, key in ipairs(self.tabOrder) do
		local d = self.tabDefs[key]
		if d.eager then self:BuildPage(key) end
	end
	self:UpdateFeatureTabs()
	self:ShowTab("status")
	return f
end

-- A page is built once (its registry `build`), on first show or with the window (`eager`).
function GH:BuildPage(key)
	local f = self.mainFrame
	local d = self.tabDefs[key]
	local page = f and f.pages[key]
	if not (d and page) or page.ghBuilt then return end
	page.ghBuilt = true
	if d.build then d.build(self, page) end
end

-- May this page show now? (a tab of a switched-off feature doesn't)
function GH:TabAllowed(key)
	local d = self.tabDefs[key]
	if not d then return false end
	return not d.feature or self:FeatureOn(d.feature)
end

-- Tabs of switched-off features are hidden; the tabs right of them move left (AnchorTabs).
function GH:UpdateFeatureTabs()
	local f = self.mainFrame
	if not f then return end
	for _, d in ipairs(f.tabList) do
		local on = self:TabAllowed(d.key)
		if f.tabs[d.key] then f.tabs[d.key]:SetShown(on) end
		if not on and f.currentTab == d.key then self:ShowTab("status") end
	end
	self:AnchorTabs(f)
end

-- Room left at the right end of the tab row (window px; the 1.3 global search needs TAB_FREE_PX).
function GH:TabRowFree()
	local f = self.mainFrame
	if not f then return nil end
	local last
	for _, d in ipairs(f.tabList) do
		local b = f.tabs[d.key]
		if b and b:IsShown() then last = b end
	end
	local fr = f.GetRight and f:GetRight()
	local lr = last and last.GetRight and last:GetRight()
	if type(fr) ~= "number" or type(lr) ~= "number" then return nil end
	return fr - lr
end

-- Features.lua: a feature was switched on or off.
function GH:OnFeaturesChanged()
	self:UpdateFeatureTabs()
	if self.optionsChanged then self:optionsChanged() end
end

-- Switch the window to a page ("status" or "settings" (gear)). Pages are built on first show.
function GH:ShowTab(key)
	local f = self:CreateMainFrame()
	if not f.pages[key] or not self:TabAllowed(key) then key = "status" end
	f.currentTab = key
	self:HideDungeonPicker()
	if self.HideNameMenu then self:HideNameMenu() end
	for i, t in ipairs(f.tabList) do
		if not f.tabTemplate then
			f.tabs[t.key]:SetActive(t.key == key)
		elseif t.key == key then
			pcall(PanelTemplates_SetTab, f, i)
		elseif key == "settings" and PanelTemplates_DeselectTab then
			pcall(PanelTemplates_DeselectTab, f.Tabs[i]) -- no tab is "on" while Settings shows
		end
	end
	if key == "settings" then f.selectedTab = nil end -- next SetTab re-selects Status properly
	self:BuildPage(key)
	for _, k in ipairs(self.tabOrder) do
		local pg = f.pages[k] -- a page registered after the window was made has no frame (never shown)
		if pg then pg:SetShown(k == key) end
		if k == key then f.sub:SetText(L[self.tabDefs[k].sub] or "") end
	end
	local gear = f.gearButton
	if gear and gear.LockHighlight then
		if key == "settings" then gear:LockHighlight() else gear:UnlockHighlight() end
	end
	local d = self.tabDefs[key]
	if d.show then d.show(self, f.pages[key]) end
end

-- /ghub test ui: which art this client gave the window (for bug reports).
function GH:TestUI()
	local f = self:CreateMainFrame()
	local yes = function(v) return v and L.YES or L.NO end
	self:Msg(L.TEST_UI, tostring(f.gearButton and f.gearButton.art or "?"), yes(f.ghTemplate), yes(f.tabTemplate),
		yes(self.statusTab and self.statusTab.scrollBox), yes(self.statusTab and self.statusTab.sort and self.statusTab.sort.isDropdown))
	-- 0.4.0: art and menus the next betas want (map pins, name menu, filter buttons)
	local function atlas(name)
		local ok, info = pcall(function() return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) end)
		return yes(ok and info)
	end
	local function file(path)
		if type(GetFileIDFromPath) ~= "function" then return "-" end
		local ok, id = pcall(GetFileIDFromPath, path)
		return yes(ok and type(id) == "number" and id > 0)
	end
	self:Msg(L.TEST_UI2, yes(MenuUtil and type(MenuUtil.CreateContextMenu) == "function"),
		yes(W.HasTemplate("WowStyle1FilterDropdownTemplate")), atlas("Dungeon"), atlas("Raid"), atlas("common-icon-checkmark"),
		file("Interface\\Minimap\\PartyRaidBlips"), file("Interface\\Common\\ReputationStar"),
		file("Interface\\FriendsFrame\\InformationIcon"))
end

-- /ghub, minimap left-click: always the full window (open/close). If the mini window is showing,
-- it closes and the full window opens. The mini window only opens with the "-" button.
function GH:ToggleMainFrame()
	local f = self:CreateMainFrame()
	if self.miniFrame and self.miniFrame:IsShown() then
		self:SetMiniMode(false)
	elseif f:IsShown() then
		f:Hide()
	else
		self:ShowTab("status")
		f:Show()
	end
end

-- Mini mode on: the small window replaces the full one (and back). Not remembered: /ghub
-- always opens the full window. (An old saved profile.mini from beta.2/3 is simply ignored.)
function GH:SetMiniMode(on)
	if on then
		if self.mainFrame then self.mainFrame:Hide() end
		self:CreateMiniFrame():Show()
	else
		if self.miniFrame then self.miniFrame:Hide() end
		local f = self:CreateMainFrame()
		self:ShowTab("status")
		f:Show()
	end
end

------------------------------------------------------------------------
-- Minimap button: our own small button on the minimap edge.
-- Its place is our own saved angle; the minimap's rotation is never read.
------------------------------------------------------------------------
local function PlaceMinimapButton(b, angle)
	local r = ((Minimap:GetWidth() or 140) / 2) + 10
	local rad = math.rad(angle or 200)
	b:ClearAllPoints()
	b:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * r, math.sin(rad) * r)
end

function GH:UpdateMinimapButton()
	local b = self.minimapButton
	if not b then return end
	if self.db.profile.minimap.hide then b:Hide() else b:Show() end
end

function GH:InitMinimapButton()
	if self.minimapButton or not Minimap then return end
	local b = CreateFrame("Button", "GuildHubMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetSize(20, 20)
	bg:SetPoint("TOPLEFT", 7, -5)
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
	icon:SetSize(17, 17)
	icon:SetPoint("TOPLEFT", 7, -6)
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then GH:OpenOptions() else GH:ToggleMainFrame() end
	end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function(s)
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			if not (mx and px and scale and scale > 0) then return end
			local angle = math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
			GH.db.profile.minimap.angle = angle
			PlaceMinimapButton(s, angle)
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(L.WIN_TITLE)
		local rows, online, withAddon = GH:BuildStatusRows({ showNoAddon = true, sort = "name" })
		GameTooltip:AddLine(L.FOOTER:format(online, withAddon), 1, 1, 1)
		local lfg, help = 0, 0
		for _, r in ipairs(rows) do
			if r.isSelf then -- only guildmates
			elseif r.preset == "lfg" then lfg = lfg + 1 elseif r.preset == "help" then help = help + 1 end
		end
		if lfg + help > 0 then
			GameTooltip:AddLine(L.MM_TIP_LFG:format(lfg) .. " · " .. (help == 1 and L.MM_TIP_HELP1 or L.MM_TIP_HELPN):format(help), 1, 0.85, 0.5)
		end
		GameTooltip:AddLine(L.MM_TIP_CLICK, 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	self.minimapButton = b
	PlaceMinimapButton(b, self.db.profile.minimap.angle)
	self:UpdateMinimapButton()
end
