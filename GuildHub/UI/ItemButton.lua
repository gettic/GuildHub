-- Guild Hub: the item button (1.0.2, plans\next-batch-2-1.0.x X3; previews\2-item-button-states.png).
-- Icon + quality border (Blizzard's atlas by name, else four plain colour lines), a "!" mark for a missing
-- enchant, "?" while the game loads the item, a dash for "no data", an empty-slot look. Hover = the game's
-- own item tooltip (+ one Guild Hub line); shift-click only puts the link into the chat box (never sends).
local _, ns = ...
local L, U = ns.L, ns.Util
local W = ns.Widgets

W.ART.itemBorder = { prefix = "auctionhouse-itemicon-border-",
	names = { [2] = "green", [3] = "blue", [4] = "purple", [5] = "orange", [6] = "artifact" } }
W.ART.itemMissing = { atlas = "services-icon-warning", file = "Interface\\OptionsFrame\\UI-OptionsFrame-NewFeatureIcon" }
W.ART.itemEmpty = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
local QUALITY_FALLBACK = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
	[4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 }, [6] = { 0.9, 0.8, 0.5 } }

function W.QualityColor(q)
	local c = type(ITEM_QUALITY_COLORS) == "table" and ITEM_QUALITY_COLORS[q]
	if type(c) == "table" and type(c.r) == "number" then return c.r, c.g, c.b end
	local f = QUALITY_FALLBACK[q] or QUALITY_FALLBACK[1]
	return f[1], f[2], f[3]
end

-- itemString from numbers -> link, quality, icon, name (nil while the game hasn't loaded the item)
function W.ItemFromNumbers(id, ench, suffix)
	if type(id) ~= "number" then return nil end
	local str = ("item:%d:%d:0:0:0:0:%d"):format(id, ench or 0, suffix or 0)
	local get = C_Item and C_Item.GetItemInfo or GetItemInfo
	local ok, name, link, quality, _, _, _, _, _, _, icon = pcall(get, str)
	if not ok or type(link) ~= "string" or U.IsSecret(link) or U.IsSecret(name) then
		if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
		local okI, iconOnly = pcall(C_Item and C_Item.GetItemIconByID or GetItemIcon, id)
		return nil, nil, (okI and not U.IsSecret(iconOnly)) and iconOnly or nil
	end
	return link, quality, icon, name
end

local function EdgeLines(b)
	local lines = {}
	for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
		{ "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
		local t = b:CreateTexture(nil, "OVERLAY")
		t:SetPoint(p[1])
		t:SetPoint(p[2])
		if p[3] then t:SetHeight(2) else t:SetWidth(2) end
		lines[i] = t
	end
	return lines
end

-- size: 37 (gear panel) or smaller. Returns the button; b:SetItem{...} / b:SetState(state).
function W.ItemButton(parent, size)
	size = size or 37
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size, size)
	b:RegisterForClicks("LeftButtonUp")
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.05, 0.9)
	b.bg = bg
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 2, -2)
	b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
	b.border = b:CreateTexture(nil, "OVERLAY")
	b.border:SetAllPoints()
	b.border:Hide()
	b.lines = EdgeLines(b)
	b.text = W.Text(b, "GameFontNormalLarge", nil, "CENTER")
	b.text:SetPoint("CENTER")
	b.mark = b:CreateTexture(nil, "OVERLAY", nil, 2)
	b.mark:SetSize(math.floor(size * 0.45), math.floor(size * 0.45))
	b.mark:SetPoint("BOTTOMRIGHT", 4, -4)
	b.mark:Hide()
	b.markText = W.Text(b, "GameFontNormal", "!", "CENTER")
	b.markText:SetPoint("BOTTOMRIGHT", 2, -2)
	b.markText:SetTextColor(1, 0.5, 0.1)
	b.markText:Hide()
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

	function b:SetBorder(q)
		local r, g, bl = W.QualityColor(q or 1)
		local name = W.ART.itemBorder.names[q or -1]
		local atlas = name and (W.ART.itemBorder.prefix .. name)
		local useAtlas = atlas and W.HasAtlas(atlas)
		if useAtlas then self.border:SetAtlas(atlas) end
		self.border:SetShown(useAtlas and true or false)
		local plain = not useAtlas and (q or 1) >= 2
		for _, t in ipairs(self.lines) do
			t:SetColorTexture(r, g, bl, 1)
			t:SetShown(plain)
		end
		self.borderKind = useAtlas and "atlas" or (plain and "plain" or "none")
	end

	function b:SetMissing(on)
		local a = W.ART.itemMissing
		if on and W.HasAtlas(a.atlas) then
			self.mark:SetAtlas(a.atlas); self.mark:Show(); self.markText:Hide()
		elseif on and a.file then
			self.mark:SetTexture(a.file); self.mark:Show(); self.markText:Hide()
		else
			self.mark:Hide(); self.markText:SetShown(on and true or false)
		end
		self.missing = on and true or false
	end

	-- state: "item" (with link etc.), "loading", "empty", "nodata"
	function b:SetState(state)
		self.state = state
		self.text:SetText("")
		self.icon:SetDesaturated(false)
		if state == "empty" then
			self.icon:SetTexture(W.ART.itemEmpty)
			self.icon:SetAlpha(0.35)
		elseif state == "loading" then
			self.icon:SetTexture(self.iconPath or nil)
			self.icon:SetAlpha(self.iconPath and 0.4 or 1)
			self.text:SetText("?")
		elseif state == "nodata" then
			self.icon:SetTexture(nil)
			self.text:SetText("-")
		else
			self.icon:SetAlpha(1)
		end
		if state ~= "item" then self:SetBorder(1); self:SetMissing(false) end
	end

	-- g = {id, e, x} or nil; missing = this slot is flagged
	function b:SetItem(g, missing)
		self.g, self.link = g, nil
		if not g then self.iconPath = nil; return self:SetState("empty") end
		local link, q, icon = W.ItemFromNumbers(g.id, g.e, g.x)
		self.iconPath = icon
		if not link then return self:SetState("loading") end
		self.link = link
		self.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		self:SetState("item")
		self:SetBorder(q)
		self:SetMissing(missing)
	end

	b:SetScript("OnEnter", function(self)
		if not self.link then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		pcall(GameTooltip.SetHyperlink, GameTooltip, self.link)
		if self.missing then GameTooltip:AddLine(L.GEAR_TIP_MISSING, 1, 0.5, 0.25) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- shift-click: the link into the chat box only (tos: never sent by itself)
	b:SetScript("OnClick", function(self)
		if not (self.link and IsShiftKeyDown and IsShiftKeyDown()) then return end
		W.InsertLink(self.link)
	end)
	b:SetState("empty")
	return b
end

function W.InsertLink(link)
	local fn = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
	if type(fn) ~= "function" or type(link) ~= "string" then return false end
	local ok, took = pcall(fn, link)
	return ok and took and true or false
end
