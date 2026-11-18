-- Guild Hub: the shared "card" (0.4.0-beta.2). One small centred window for everything that asks
-- the player a question (the welcome card now; "New in X", "While you were away" and the
-- new-member checklist later). Small notes stay toasts (Widgets.lua).
--   GH:ShowCard{ key, title, text, note, buttons = { { label, fn }, ... up to 3 }, tick = { label, fn },
--     onClose = fn }  -- X / Esc call onClose
-- One card at a time; others wait (max 3, the same key replaces). Never opens in combat or in an
-- instance: it waits for both to end. Always says "Guild Hub" at the top (tos: never mistaken for a
-- Blizzard dialog). Plain display frames only (no secure templates).
local _, ns = ...
local GH, L = ns.GH, ns.L
local W = ns.Widgets

local CARD_W = 400
local PAD = 16
local MAX_WAITING = 3
local BUTTON_H = 24

GH.cardQueue = {}

local function TextHeight(fs, fallbackLines)
	local ok, h = pcall(fs.GetStringHeight, fs)
	if ok and type(h) == "number" and h > 0 then return h end
	return 14 * (fallbackLines or 1)
end

-- Built once; also used by the self-test with test text.
function GH:CardFrame()
	if self.card then return self.card end
	local f = W.Popup("GuildHubCard", UIParent, 0.97)
	f:SetSize(CARD_W, 180)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:Hide()
	f.brand = W.Text(f, "GameFontNormalSmall", L.CARD_BRAND)
	f.brand:SetPoint("TOPLEFT", PAD, -12)
	f.title = W.Text(f, "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", f.brand, "BOTTOMLEFT", 0, -6)
	f.title:SetWidth(CARD_W - 2 * PAD - 20)
	f.title:SetWordWrap(true)
	f.body = W.Text(f, "GameFontHighlight")
	f.body:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -10)
	f.body:SetWidth(CARD_W - 2 * PAD)
	f.body:SetWordWrap(true)
	f.body:SetJustifyV("TOP")
	f.note = W.Text(f, "GameFontDisableSmall")
	f.note:SetPoint("TOPLEFT", f.body, "BOTTOMLEFT", 0, -10)
	f.note:SetWidth(CARD_W - 2 * PAD)
	f.note:SetWordWrap(true)
	f.tick = W.CheckButton(f, "", 200)
	f.tick:SetPoint("BOTTOMLEFT", PAD - 4, PAD + BUTTON_H + 6)
	f.buttons = {}
	for i = 1, 3 do
		local b = W.Button(f, "", 170, BUTTON_H, "GameFontNormal")
		b:SetScript("OnClick", function()
			local spec = f.spec
			f.answered = true
			f:Hide()
			local e = spec and spec.buttons and spec.buttons[i]
			if e and type(e.fn) == "function" then e.fn() end
		end)
		f.buttons[i] = b
	end
	f.close = W.TitleButton(f, "close", 24)
	f.close:SetPoint("TOPRIGHT", -2, -2)
	f.close:SetScript("OnClick", function() f:Hide() end)
	f:SetScript("OnHide", function()
		local spec = f.spec
		f.spec = nil
		if spec and not f.answered and not spec.test and type(spec.onClose) == "function" then spec.onClose() end
		f.answered = nil
		if not (spec and spec.test) then GH:NextCard() end
	end)
	if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "GuildHubCard") end -- Esc = X
	self.card = f
	return f
end

-- Puts a spec on the card (text, buttons, height). Doesn't show it.
function GH:FillCard(f, spec)
	f.spec = spec
	f.answered = nil
	f.title:SetText(spec.title or "")
	f.body:SetText(spec.text or "")
	f.note:SetText(spec.note or "")
	f.note:SetShown(spec.note ~= nil)
	local list = spec.buttons or {}
	local n = math.min(#list, 3)
	local gap = 8
	local bw = n > 0 and math.min(170, math.floor((CARD_W - 2 * PAD - (n - 1) * gap) / n)) or 0
	for i, b in ipairs(f.buttons) do
		local e = list[i]
		b:SetShown(i <= n)
		if i <= n then
			b:SetWidth(bw)
			if b.label and b.label.SetWidth then b.label:SetWidth(bw - 8) end
			b:SetLabel(e.label or "")
			b:ClearAllPoints()
			if i == 1 then b:SetPoint("BOTTOMLEFT", PAD, PAD)
			else b:SetPoint("LEFT", f.buttons[i - 1], "RIGHT", gap, 0) end
		end
	end
	if spec.tick then
		f.tick:SetLabel(spec.tick.label or "")
		f.tick:SetActive(false)
		f.tick:SetScript("OnClick", function(cb)
			local on = cb.GetChecked and cb:GetChecked() or false
			if spec.tick.fn then spec.tick.fn(on) end
		end)
	end
	f.tick:SetShown(spec.tick ~= nil)
	-- height from the text
	local h = 12 + 14 + 6 + TextHeight(f.title) + 10 + TextHeight(f.body, 6)
	if spec.note then h = h + 10 + TextHeight(f.note, 1) end
	if spec.tick then h = h + 30 end
	h = h + 14 + BUTTON_H + PAD
	f:SetHeight(math.floor(h + 0.5))
end

local function CanShow()
	if InCombatLockdown and InCombatLockdown() then return false end
	if IsInInstance and IsInInstance() then return false end
	return true
end

-- Shows the next waiting card if nothing is shown and the moment is right.
function GH:NextCard()
	local f = self.card
	if f and f:IsShown() then return end
	if #self.cardQueue == 0 then
		self:Off("card")
		return
	end
	if not CanShow() then
		-- wait for combat / the instance to end
		self:On("card", "PLAYER_REGEN_ENABLED", function() GH:NextCard() end)
		self:On("card", "ZONE_CHANGED_NEW_AREA", function() GH:NextCard() end)
		return
	end
	local spec = table.remove(self.cardQueue, 1)
	f = self:CardFrame()
	self:FillCard(f, spec)
	f:Show()
end

function GH:ShowCard(spec)
	if type(spec) ~= "table" then return end
	local q = self.cardQueue
	for i, s in ipairs(q) do
		if spec.key and s.key == spec.key then q[i] = spec return self:NextCard() end
	end
	local f = self.card
	if f and f:IsShown() and f.spec and spec.key and f.spec.key == spec.key then return end -- already showing
	if #q >= MAX_WAITING then table.remove(q, 1) end
	q[#q + 1] = spec
	self:NextCard()
end

-- Self-test / offline tester: the card's parts.
function GH:CardParts()
	local f = self.card or {}
	local parts = {
		{ name = "card", obj = self.card },
		{ name = "card.title", obj = f.title },
		{ name = "card.body", obj = f.body },
		{ name = "card.close", obj = f.close },
	}
	for i, b in ipairs(f.buttons or {}) do
		parts[#parts + 1] = { name = "card.button" .. i, obj = b, opt = true, shownOnly = true }
	end
	return parts
end
