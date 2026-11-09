-- Guild Hub: the /ghub window (frame, title, tab bar, saved position) and the minimap button.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local WIDTH, HEIGHT = 1046, 540 -- 1046: room for the RANK and GROUP columns
-- tabs: label/sub are Locale keys; right = anchored at the right end of the tab bar
local TABS = {
	{ key = "status", label = "TAB_STATUS", sub = "WIN_SUB" },
	{ key = "settings", label = "TAB_SETTINGS", sub = "WIN_SUB_SETTINGS", right = true },
}

function GH:SaveWindowPos()
	local f = self.mainFrame
	if not f then return end
	local point, _, _, x, y = f:GetPoint(1)
	local w = self.db.profile.window
	w.point, w.x, w.y = point or "CENTER", x or 0, y or 0
end

function GH:CreateMainFrame()
	if self.mainFrame then return self.mainFrame end
	local f = CreateFrame("Frame", "GuildHubMainFrame", UIParent, "BackdropTemplate")
	f:SetSize(WIDTH, HEIGHT)
	W.Skin(f, 0.97)
	f:SetBackdropBorderColor(0.6, 0.48, 0.22, 1)
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

	local title = W.Text(f, "GameFontNormalLarge", L.WIN_TITLE)
	title:SetPoint("TOPLEFT", 18, -16)
	local sub = W.Text(f, "GameFontDisableSmall", L.WIN_SUB)
	sub:SetPoint("LEFT", title, "RIGHT", 10, -1)
	f.sub = sub
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	-- mini mode button, just left of the close button
	local mini = W.Button(f, "-", 22, 22, "GameFontNormal")
	mini:SetPoint("RIGHT", close, "LEFT", -4, 0)
	mini:SetScript("OnClick", function() GH:SetMiniMode(true) end)
	W.Tooltip(mini, L.MINI_TIP)
	f.miniButton = mini

	local content = CreateFrame("Frame", nil, f)
	content:SetPoint("TOPLEFT", 8, -76)
	content:SetPoint("BOTTOMRIGHT", -8, 8)
	f.content = content

	-- tab bar: tabs on the left fill from the left (Professions, Map ... come with their steps);
	-- Settings sits at the right end so later tabs never move it
	f.tabs, f.pages = {}, {}
	local x = 16
	for _, t in ipairs(TABS) do
		local b = W.Button(f, L[t.label], 90, 24, "GameFontNormal")
		if t.right then
			b:SetPoint("TOPRIGHT", -16, -44)
		else
			b:SetPoint("TOPLEFT", x, -44)
			x = x + 96
		end
		b:SetScript("OnClick", function() GH:ShowTab(t.key) end)
		f.tabs[t.key] = b
		local page = CreateFrame("Frame", nil, content)
		page:SetAllPoints(content)
		f.pages[t.key] = page
	end
	local line = f:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(W.BORDER[1], W.BORDER[2], W.BORDER[3], 1)
	line:SetHeight(1)
	line:SetPoint("TOPLEFT", 8, -70)
	line:SetPoint("TOPRIGHT", -8, -70)

	f:Hide()
	f:SetScript("OnShow", function()
		GH:RequestRoster()
		GH:RefreshBoard(true)
	end)
	f:SetScript("OnHide", function()
		if GH.dungeonPicker then GH.dungeonPicker:Hide() end
	end)
	self.mainFrame = f
	self:BuildStatusTab(f.pages.status) -- UI\StatusTab.lua (its OnUpdate stops while the page is hidden)
	self:ShowTab("status")
	return f
end

-- Switch the window to a tab ("status" or "settings"). Pages are built on first show.
function GH:ShowTab(key)
	local f = self:CreateMainFrame()
	if not f.pages[key] then key = "status" end
	f.currentTab = key
	if self.dungeonPicker then self.dungeonPicker:Hide() end
	for _, t in ipairs(TABS) do
		f.tabs[t.key]:SetActive(t.key == key)
		f.pages[t.key]:SetShown(t.key == key)
		if t.key == key then f.sub:SetText(L[t.sub]) end
	end
	if key == "settings" then
		self:ShowSettingsTab(f.pages.settings) -- Options.lua
	elseif f:IsShown() then
		self:RefreshBoard(true)
	end
end

-- /ghub, minimap click: opens the mode used last (full window or mini window), or closes it.
function GH:ToggleMainFrame()
	if self.db.profile.mini then
		local m = self:CreateMiniFrame() -- UI\MiniFrame.lua
		if m:IsShown() then m:Hide() else m:Show() end
		return
	end
	local f = self:CreateMainFrame()
	if f:IsShown() then
		f:Hide()
	else
		self:ShowTab("status")
		f:Show()
	end
end

-- Mini mode on: the small window replaces the full one (and back). Remembered in profile.mini.
function GH:SetMiniMode(on)
	self.db.profile.mini = on and true or false
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
