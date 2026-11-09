-- Guild Hub: the /ghub window (frame, title, tab bar, saved position) and the minimap button.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

-- 1046: room for the RANK and GROUP columns; 524 = 56 title bar + tab row, 460 pages, 8 border
local WIDTH, HEIGHT = 1046, 524
local TAB_LINE = -58 -- the tabs' bottom edge: 2 px into the page's inset, so the selected tab merges with it
local PAGE_TOP = -56 -- the pages (and their insets) start here
-- pages: sub = Locale key of the subtitle. Settings has no tab: the gear button in the title bar.
local PAGES = {
	{ key = "status", sub = "WIN_SUB" },
	{ key = "settings", sub = "WIN_SUB_SETTINGS" },
}
-- tabs (label = Locale key), left to right from the left edge; Professions, Map ... come later
local TABS = {
	{ key = "status", label = "TAB_STATUS" },
}

function GH:SaveWindowPos()
	local f = self.mainFrame
	if not f then return end
	local point, _, _, x, y = f:GetPoint(1)
	local w = self.db.profile.window
	w.point, w.x, w.y = point or "CENTER", x or 0, y or 0
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
	-- our own anchors (after SetNumTabs, which chains every tab to the one before it)
	local prev
	for i, t in ipairs(TABS) do
		local b = f.Tabs[i]
		b:ClearAllPoints()
		if prev then
			b:SetPoint("BOTTOMLEFT", prev, "BOTTOMRIGHT", f.tabTemplate and 3 or 6, 0)
		else
			b:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 14, f.tabTemplate and TAB_LINE or TAB_LINE + 4)
		end
		prev = b
	end
	f.lastTab = prev -- the Status page's search box starts right of it
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
	for _, p in ipairs(PAGES) do
		local page = CreateFrame("Frame", nil, content)
		page:SetAllPoints(content)
		f.pages[p.key] = page
	end
	-- Settings sits in the same kind of inset as the status list, from the tab line down
	local sInset = W.Inset(f.pages.settings)
	sInset:SetPoint("TOPLEFT", 2, 0)
	sInset:SetPoint("BOTTOMRIGHT", -2, 2)
	f.pages.settings.inset = sInset
	MakeTabs(f) -- tabs on the left fill from the left (Professions, Map ... come with their steps)

	f:Hide()
	f:SetScript("OnShow", function()
		GH:RequestRoster()
		GH:RefreshBoard(true)
	end)
	f:SetScript("OnHide", function() GH:HideDungeonPicker() end)
	self.mainFrame = f
	self:BuildStatusTab(f.pages.status) -- UI\StatusTab.lua (its OnUpdate stops while the page is hidden)
	self:ShowTab("status")
	return f
end

-- Switch the window to a page ("status" or "settings" (gear)). Pages are built on first show.
function GH:ShowTab(key)
	local f = self:CreateMainFrame()
	if not f.pages[key] then key = "status" end
	f.currentTab = key
	self:HideDungeonPicker()
	for i, t in ipairs(TABS) do
		if not f.tabTemplate then
			f.tabs[t.key]:SetActive(t.key == key)
		elseif t.key == key then
			pcall(PanelTemplates_SetTab, f, i)
		elseif key == "settings" and PanelTemplates_DeselectTab then
			pcall(PanelTemplates_DeselectTab, f.Tabs[i]) -- no tab is "on" while Settings shows
		end
	end
	if key == "settings" then f.selectedTab = nil end -- next SetTab re-selects Status properly
	for _, p in ipairs(PAGES) do
		f.pages[p.key]:SetShown(p.key == key)
		if p.key == key then f.sub:SetText(L[p.sub]) end
	end
	local gear = f.gearButton
	if gear and gear.LockHighlight then
		if key == "settings" then gear:LockHighlight() else gear:UnlockHighlight() end
	end
	if key == "settings" then
		self:ShowSettingsTab(f.pages.settings) -- Options.lua
	elseif f:IsShown() then
		self:RefreshBoard(true)
	end
end

-- /ghub test ui: which art this client gave the window (for bug reports).
function GH:TestUI()
	local f = self:CreateMainFrame()
	local yes = function(v) return v and L.YES or L.NO end
	self:Msg(L.TEST_UI, tostring(f.gearButton and f.gearButton.art or "?"), yes(f.ghTemplate), yes(f.tabTemplate),
		yes(self.statusTab and self.statusTab.scrollBox), yes(self.statusTab and self.statusTab.sort and self.statusTab.sort.isDropdown))
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
