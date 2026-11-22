-- Guild Hub: the gear panel ("View gear" in the name menu; 1.0.2, plans\next-batch-2-1.0.x X3,
-- previews\1-gear-panel.png). Opening it may ask the owner ONCE (Features\Gear.lua GearView(name, true):
-- one BREQ, skipped when a copy is younger than 10 min). Missing enchants are shown only here.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local PANEL_W, PANEL_H = 560, 470
local ROW_H = 42
local BTN = 37

local function SlotRow(p, slot, right)
	local r = CreateFrame("Frame", nil, p)
	r:SetSize(PANEL_W / 2 - 20, ROW_H)
	r.slot = slot
	r.button = W.ItemButton(r, BTN)
	r.name = W.Text(r, "GameFontHighlight", nil, right and "RIGHT" or "LEFT")
	r.sub = W.Text(r, "GameFontHighlightSmall", nil, right and "RIGHT" or "LEFT")
	if right then
		r.button:SetPoint("RIGHT", 0, 0)
		r.name:SetPoint("TOPRIGHT", r.button, "TOPLEFT", -8, -2)
		r.sub:SetPoint("BOTTOMRIGHT", r.button, "BOTTOMLEFT", -8, 2)
	else
		r.button:SetPoint("LEFT", 0, 0)
		r.name:SetPoint("TOPLEFT", r.button, "TOPRIGHT", 8, -2)
		r.sub:SetPoint("BOTTOMLEFT", r.button, "BOTTOMRIGHT", 8, 2)
	end
	r.name:SetWidth(PANEL_W / 2 - 70)
	r.sub:SetWidth(PANEL_W / 2 - 70)
	return r
end

local function BottomSlot(p, slot)
	local r = CreateFrame("Frame", nil, p)
	r:SetSize(170, 70)
	r.slot = slot
	r.button = W.ItemButton(r, BTN)
	r.button:SetPoint("TOP", 0, 0)
	r.name = W.Text(r, "GameFontHighlightSmall", nil, "CENTER")
	r.name:SetPoint("TOP", r.button, "BOTTOM", 0, -2)
	r.name:SetWidth(170)
	r.sub = W.Text(r, "GameFontDisableSmall", nil, "CENTER")
	r.sub:SetPoint("TOP", r.name, "BOTTOM", 0, -1)
	r.sub:SetWidth(170)
	return r
end

function GH:GearPanelFrame()
	if self.gearPanel then return self.gearPanel end
	local p = W.Popup("GuildHubGearPanel", UIParent, 0.97)
	p:SetSize(PANEL_W, PANEL_H)
	p:SetPoint("CENTER", 0, 40)
	p:SetFrameStrata("DIALOG")
	p:EnableMouse(true)
	p:SetMovable(true)
	p:RegisterForDrag("LeftButton")
	p:SetScript("OnDragStart", function(s) s:StartMoving() end)
	p:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
	p.brand = W.Text(p, "GameFontNormal", L.GEAR_TITLE, "CENTER")
	p.brand:SetPoint("TOP", 0, -10)
	p.close = W.TitleButton(p, "close", 24)
	p.close:SetPoint("TOPRIGHT", -2, -2)
	p.close:SetScript("OnClick", function() p:Hide() end)
	p.who = W.Text(p, "GameFontNormalLarge")
	p.who:SetPoint("TOPLEFT", 14, -32)
	p.state = W.Text(p, "GameFontHighlightSmall", nil, "RIGHT")
	p.state:SetPoint("TOPRIGHT", -14, -36)
	p.state:SetWidth(280)
	-- summary strip ("2 enchants missing: Wrists, Feet" / "only on your screen")
	local strip = CreateFrame("Frame", nil, p)
	strip:SetPoint("TOPLEFT", 12, -56)
	strip:SetPoint("TOPRIGHT", -12, -56)
	strip:SetHeight(22)
	local sbg = strip:CreateTexture(nil, "BACKGROUND")
	sbg:SetAllPoints()
	sbg:SetColorTexture(0.45, 0.2, 0.02, 0.45)
	strip.text = W.Text(strip, "GameFontNormal")
	strip.text:SetPoint("LEFT", 8, 0)
	strip.note = W.Text(strip, "GameFontDisableSmall", L.GEAR_ONLY_YOU, "RIGHT")
	strip.note:SetPoint("RIGHT", -8, 0)
	p.summary = strip
	-- slots
	p.rows = {}
	for i, slot in ipairs(GH.GEAR_LAYOUT.left) do
		local r = SlotRow(p, slot, false)
		r:SetPoint("TOPLEFT", 14, -82 - (i - 1) * ROW_H)
		p.rows[slot] = r
	end
	for i, slot in ipairs(GH.GEAR_LAYOUT.right) do
		local r = SlotRow(p, slot, true)
		r:SetPoint("TOPRIGHT", -14, -82 - (i - 1) * ROW_H)
		p.rows[slot] = r
	end
	for i, slot in ipairs(GH.GEAR_LAYOUT.bottom) do
		local r = BottomSlot(p, slot)
		r:SetPoint("TOP", p, "TOP", (i - 2) * 175, -82 - 8 * ROW_H - 6)
		p.rows[slot] = r
	end
	-- the message for states without slots (locked / not shared / older / none)
	p.msg = W.Text(p, "GameFontHighlight", nil, "CENTER")
	p.msg:SetPoint("CENTER", 0, 10)
	p.msg:SetWidth(PANEL_W - 80)
	p.msg:SetWordWrap(true)
	p.lock = p:CreateTexture(nil, "ARTWORK")
	p.lock:SetTexture(W.ART.raidLock or "Interface\\PetBattles\\PetBattle-LockIcon")
	p.lock:SetSize(28, 28)
	p.lock:SetPoint("BOTTOM", p.msg, "TOP", 0, 10)
	p.share = W.Button(p, L.GEAR_SHARE_BTN, 160, 22)
	p.share:SetPoint("TOP", p.msg, "BOTTOM", 0, -12)
	p.share:SetScript("OnClick", function() GH:SetShare("gear", true); GH:RefreshGearPanel() end)
	p.hint = W.Text(p, "GameFontDisableSmall", L.GEAR_HINT, "CENTER")
	p.hint:SetPoint("BOTTOM", 0, 10)
	p:SetScript("OnHide", function() GH.gearPanelName = nil end)
	p:Hide()
	tinsert(UISpecialFrames, "GuildHubGearPanel")
	self.gearPanel = p
	return p
end

local STATE_TEXT = {
	self = "GEAR_ST_SELF", fresh = "GEAR_ST_FRESH", asking = "GEAR_ST_ASKING", saved = "GEAR_ST_SAVED",
	noanswer = "GEAR_ST_NOANSWER", none = "GEAR_ST_NONE", busy = "GEAR_ST_BUSY",
}
local MSG_TEXT = { locked = "GEAR_MSG_LOCKED", trial = "FAIR_TRIAL", notshared = "GEAR_MSG_NOTSHARED", older = "GEAR_MSG_OLDER",
	none = "GEAR_MSG_NONE", unknown = "GEAR_MSG_UNKNOWN", feature = "GEAR_MSG_FEATURE", busy = "GEAR_MSG_BUSY", noanswer = "GEAR_MSG_NOANSWER" }

-- Draws the panel for name; ask = may send ONE request (only from the click that opened it).
function GH:DrawGearPanel(name, ask)
	local p = self:GearPanelFrame()
	local v = self:GearView(name, ask)
	p.view = v
	local r = self.roster[name]
	p.who:SetText(U.ClassColored(name, v.class) .. (r and r.level and ("  |cffbbbbbb" .. L.GEAR_LEVEL:format(r.level) .. "|r") or ""))
	local st = STATE_TEXT[v.state]
	local age = v.ts and U.Ago(U.Now() - v.ts) or ""
	p.state:SetText(st and (L[st]):format(age) or "")
	local slots = v.s
	local showSlots = slots ~= nil and (v.state ~= "none")
	for _, row in pairs(p.rows) do row:SetShown(showSlots) end
	p.msg:SetShown(not showSlots)
	p.lock:SetShown(not showSlots and (v.state == "locked" or v.state == "notshared" or v.state == "trial"))
	p.share:SetShown(not showSlots and v.state == "locked")
	p.summary:SetShown(showSlots)
	p.hint:SetShown(showSlots)
	if not showSlots then
		local key = MSG_TEXT[v.state] or (v.state == "asking" and "GEAR_ST_ASKING") or "GEAR_MSG_NONE"
		local text = L[key] or ""
		if v.state == "notshared" then text = text:format(U.ShortName(name)) end
		if v.state == "asking" then text = text:format("") end
		p.msg:SetText(text)
		return p
	end
	local miss = {}
	local marks = self.db.profile.gearMarks ~= false
	for _, slot in ipairs(v.miss or {}) do miss[slot] = true end
	local loading = false
	for slot, row in pairs(p.rows) do
		local g = slots[slot]
		row.button:SetItem(g, marks and miss[slot])
		if row.button.state == "loading" then loading = true end
		local q, iname
		if g then
			local _
			_, q, _, iname = W.ItemFromNumbers(g.id, g.e, g.x)
		end
		if g and iname then
			row.name:SetText(iname)
			row.name:SetTextColor(W.QualityColor(q or 1))
		elseif g then
			row.name:SetText("?")
			row.name:SetTextColor(0.6, 0.6, 0.6)
		else
			row.name:SetText("")
		end
		local sub = self:GearSlotName(slot)
		if not g then
			sub = L.GEAR_EMPTY:format(sub)
			row.sub:SetTextColor(0.5, 0.5, 0.5)
		elseif marks and miss[slot] then
			sub = L.GEAR_NOENCH:format(sub)
			row.sub:SetTextColor(1, 0.55, 0.15)
		elseif (g.e or 0) > 0 then
			sub = L.GEAR_ENCH:format(sub)
			row.sub:SetTextColor(0.4, 0.9, 0.4)
		else
			row.sub:SetTextColor(0.7, 0.7, 0.7)
		end
		row.sub:SetText(sub)
	end
	local n = v.miss and #v.miss or 0
	if marks and n > 0 then
		p.summary.text:SetText(L.GEAR_SUMMARY_MISSING:format(n, self:GearMissingText(v.miss)))
		p.summary.text:SetTextColor(1, 0.7, 0.3)
	else
		p.summary.text:SetText(L.GEAR_SUMMARY_OK)
		p.summary.text:SetTextColor(0.5, 0.9, 0.5)
	end
	-- item data still loading: draw again shortly (at most 10 times)
	if loading and (p.loadTries or 0) < 10 then
		p.loadTries = (p.loadTries or 0) + 1
		self:ScheduleTimer(function() if GH.gearPanelName == name and p:IsShown() then GH:DrawGearPanel(name) end end, 0.5)
	elseif not loading then
		p.loadTries = 0
	end
	return p
end

-- "View gear": opens the panel; the ONE click that may ask the owner.
function GH:ShowGearPanel(name)
	if type(name) ~= "string" or name == "" then return end
	local p = self:GearPanelFrame()
	self.gearPanelName = name
	p.loadTries = 0
	p:Show()
	self:DrawGearPanel(name, true)
end

function GH:RefreshGearPanel(name)
	local p = self.gearPanel
	if not (p and p:IsShown() and self.gearPanelName) then return end
	if name and name ~= self.gearPanelName then return end
	self:DrawGearPanel(self.gearPanelName, false)
end

function GH:HideGearPanel()
	if self.gearPanel then self.gearPanel:Hide() end
end

-- self-test parts
function GH:GearPanelParts()
	local p = self:GearPanelFrame()
	local parts = { ["gear.panel"] = p, ["gear.close"] = p.close, ["gear.summary"] = p.summary }
	for slot, row in pairs(p.rows) do parts["gear.slot" .. slot] = row.button end
	return parts
end
