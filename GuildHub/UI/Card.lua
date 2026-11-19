-- Guild Hub: the shared "card" (0.4.0-beta.2). One small centred window for everything that asks
-- the player a question (the welcome card now; "New in X", "While you were away" and the
-- new-member checklist later). Small notes stay toasts (Widgets.lua).
--   GH:ShowCard{ key, title, text, note, buttons = { { label, fn }, ... up to 3 }, tick = { label, fn },
--     onClose = fn }  -- X / Esc call onClose
--   0.4.0: lines = { { state = "done"|"todo"|"off", text, sub }, ... up to MAX_LINES } (a checklist
--     under the text), onShow = fn (after it is really on screen; never for test cards),
--     skip = fn -> true (checked when its turn comes: true drops it unseen), update = fn(spec)
--     (refreshes the spec's text right before it shows)
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
local MAX_LINES = 6
local ICON = 16

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
	-- checklist rows (placed in FillCard)
	f.lines = {}
	for i = 1, MAX_LINES do
		local r = CreateFrame("Frame", nil, f)
		r:SetSize(CARD_W - 2 * PAD, 20)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(ICON, ICON)
		r.icon:SetPoint("TOPLEFT", 0, 0)
		r.mark = W.Text(r, "GameFontNormal")
		r.mark:SetPoint("TOP", r.icon, "TOP", 0, 0)
		r.text = W.Text(r, "GameFontNormal")
		r.text:SetPoint("TOPLEFT", ICON + 6, -1)
		r.text:SetWidth(CARD_W - 2 * PAD - ICON - 6)
		r.text:SetWordWrap(true)
		r.sub = W.Text(r, "GameFontHighlightSmall")
		r.sub:SetPoint("TOPLEFT", r.text, "BOTTOMLEFT", 0, -2)
		r.sub:SetWidth(CARD_W - 2 * PAD - ICON - 6)
		r.sub:SetWordWrap(true)
		r:Hide()
		f.lines[i] = r
	end
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
			-- the answer first, then hide: the next waiting card (shown from OnHide) sees it
			local e = spec and spec.buttons and spec.buttons[i]
			local ok, err = true, nil
			if e and type(e.fn) == "function" then ok, err = pcall(e.fn) end
			f:Hide()
			if not ok then geterrorhandler()(err) end
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
	-- checklist rows under the body; the note goes under the last one
	local rows = type(spec.lines) == "table" and spec.lines or {}
	local nLines = math.min(#rows, MAX_LINES)
	local linesH, above = 0, f.body
	for i, r in ipairs(f.lines) do
		local e = rows[i]
		r:SetShown(i <= nLines)
		if i <= nLines then
			W.SetGuideIcon(r.icon, r.mark, e.state)
			r.text:SetText(e.text or "")
			r.sub:SetText(e.sub or "")
			r.sub:SetShown(e.sub ~= nil and e.sub ~= "")
			local c = e.state == "off" and W.COLOR.gray or W.COLOR.normal
			r.text:SetTextColor(c[1], c[2], c[3])
			local rh = math.max(ICON, 1 + TextHeight(r.text) + (r.sub:IsShown() and 2 + TextHeight(r.sub) or 0))
			r:SetHeight(math.floor(rh + 0.5))
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, i == 1 and -10 or -6)
			linesH = linesH + rh + (i == 1 and 10 or 6)
			above = r
		end
	end
	f.note:ClearAllPoints()
	f.note:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -10)
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
		f.tick:SetActive(spec.tick.checked and true or false)
		f.tick:SetScript("OnClick", function(cb)
			-- real template: the box has already flipped itself; fallback button: flip our own flag
			local on
			if cb.GetChecked then on = cb:GetChecked() and true or false
			else on = not spec.tick.checked end
			spec.tick.checked = on
			if spec.tick.fn then spec.tick.fn(on) end
			if cb.SetChecked then cb:SetChecked(on) elseif cb.SetActive then cb:SetActive(on) end
		end)
	end
	f.tick:SetShown(spec.tick ~= nil)
	-- height from the text
	local h = 12 + 14 + 6 + TextHeight(f.title) + 10 + TextHeight(f.body, 6) + linesH
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
	if type(spec.skip) == "function" and spec.skip() then return self:NextCard() end -- dropped unseen
	if type(spec.update) == "function" then spec.update(spec) end -- fresh text at the moment it shows
	f = self:CardFrame()
	self:FillCard(f, spec)
	f:Show()
	if not spec.test and type(spec.onShow) == "function" then spec.onShow() end
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
function GH:CardParts(withLines)
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
	for i, r in ipairs(withLines and f.lines or {}) do -- checklist rows (the Getting started card)
		parts[#parts + 1] = { name = "card.line" .. i, obj = r, opt = true, shownOnly = true }
	end
	return parts
end
