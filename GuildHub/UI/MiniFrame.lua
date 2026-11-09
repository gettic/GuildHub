-- Guild Hub: the mini window (mini mode). A small, movable list of what guildmates with
-- Guild Hub are doing. Only our own plain frames; a row click only opens the whisper box.
-- Esc does not close it (it is meant to stay on screen); [+] goes back to the full window.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local MINI_W, MINI_H = 320, 250
local ROW_H = 18
local TOP, BOTTOM = 30, 20 -- space for the title bar and the "scroll for more" line
local ROW_W = MINI_W - 16
-- column x positions and widths inside a row
local MCOL = { name = { 4, 84 }, lvl = { 90, 20 }, status = { 112, 124 }, time = { 240, 60 } }
GH.MINI_SIZE = { MINI_W, MINI_H } -- for the offline test

function GH:SaveMiniPos()
	local f = self.miniFrame
	if not f then return end
	local point, _, _, x, y = f:GetPoint(1)
	local w = self.db.profile.miniWindow
	w.point, w.x, w.y = point or "CENTER", x or 0, y or 0
end

local function MakeMiniRow(parent)
	local r = CreateFrame("Button", nil, parent)
	r:SetSize(ROW_W, ROW_H)
	r:RegisterForClicks("LeftButtonUp")
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 0.85, 0.4, 0.08)
	r.hl = hl
	local function col(key, font, justify)
		local fs = W.Text(r, font, nil, justify)
		fs:SetPoint("LEFT", MCOL[key][1], 0)
		fs:SetWidth(MCOL[key][2])
		return fs
	end
	r.name = col("name", "GameFontHighlightSmall")
	r.lvl = col("lvl", "GameFontHighlightSmall")
	r.status = col("status", "GameFontHighlightSmall")
	r.time = col("time", "GameFontDisableSmall", "RIGHT")
	r.header = W.Text(r, "GameFontNormalSmall")
	r.header:SetPoint("LEFT", 4, 0)
	-- the player's own click only: opens the chat box to whisper, never sends anything
	r:SetScript("OnClick", function(self)
		local d = self.data
		if d and not d.header then GH:WhisperMember(d.name) end
	end)
	r:SetScript("OnEnter", function(self) GH:MemberTooltip(self, self.data, L.MINI_CLICK) end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return r
end

local function FillMiniRow(r, d)
	r.data = d
	local isHeader = d.header ~= nil
	r.header:SetShown(isHeader)
	for _, k in ipairs({ "name", "lvl", "status", "time" }) do r[k]:SetShown(not isHeader) end
	r.hl:SetShown(not isHeader)
	if isHeader then
		local c = GH.GROUP_COLOR[d.header] or W.GOLD
		r.header:SetText(("%s (%d)"):format(L.GROUP[d.header] or d.header, d.count))
		r.header:SetTextColor(c[1], c[2], c[3])
		return
	end
	r.name:SetText(U.ClassColored(d.name, d.class))
	r.lvl:SetText(tostring(d.level or "?"))
	r.status:SetText(d.status) -- cleaned text from others, never contains | codes
	r.time:SetText(d.since and U.Duration(d.since) or "")
end

function GH:CreateMiniFrame()
	if self.miniFrame then return self.miniFrame end
	local f = CreateFrame("Frame", "GuildHubMiniFrame", UIParent, "BackdropTemplate")
	f:SetSize(MINI_W, MINI_H)
	W.Skin(f, 0.9)
	f:SetFrameStrata("MEDIUM")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(s)
		s:StopMovingOrSizing()
		GH:SaveMiniPos()
	end)
	local pos = self.db.profile.miniWindow
	f:SetPoint(pos.point or "CENTER", UIParent, pos.point or "CENTER", pos.x or 0, pos.y or 0)
	-- not in UISpecialFrames: Esc leaves it open (close with X or /ghub)

	local title = W.Text(f, "GameFontNormal", L.WIN_TITLE)
	title:SetPoint("TOPLEFT", 10, -9)
	f.count = W.Text(f, "GameFontDisableSmall")
	f.count:SetPoint("LEFT", title, "RIGHT", 8, 0)
	-- Blizzard's red title buttons, 22 px so they fit the 30 px title bar
	local close = W.TitleButton(f, "close", 22)
	close:SetPoint("TOPRIGHT", -3, -3)
	close:SetScript("OnClick", function() f:Hide() end)
	local full = W.TitleButton(f, "expand", 22)
	full:SetPoint("RIGHT", close, "LEFT", full.fallback and -2 or 2, 0)
	full:SetScript("OnClick", function() GH:SetMiniMode(false) end)
	W.Tooltip(full, L.MINI_BACK_TIP)
	f.fullButton, f.closeButton = full, close

	local list = CreateFrame("Frame", nil, f)
	list:SetPoint("TOPLEFT", 8, -TOP)
	list:SetPoint("BOTTOMRIGHT", -8, BOTTOM)
	list:EnableMouseWheel(true)
	f.rows = {}
	f.visible = math.floor((MINI_H - TOP - BOTTOM) / ROW_H)
	for i = 1, f.visible do
		local r = MakeMiniRow(list)
		r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
		f.rows[i] = r
	end
	f.offset = 0
	list:SetScript("OnMouseWheel", function(_, delta)
		local max = math.max(0, #(f.data or {}) - f.visible)
		f.offset = math.max(0, math.min(max, f.offset - delta * 2))
		GH:DrawMiniRows()
	end)
	f.list = list
	f.empty = W.Text(list, "GameFontDisableSmall", L.MINI_EMPTY)
	f.empty:SetPoint("TOP", 0, -30)
	f.more = W.Text(f, "GameFontDisableSmall")
	f.more:SetPoint("BOTTOMLEFT", 12, 6)

	-- while shown: times every 10 s, a fresh guild list every 15 s (stops when hidden)
	f:SetScript("OnUpdate", function(_, elapsed)
		f.tick = (f.tick or 0) + elapsed
		f.rosterTick = (f.rosterTick or 0) + elapsed
		if f.rosterTick >= 15 then
			f.rosterTick = 0
			GH:RequestRoster()
		end
		if f.tick >= 10 then
			f.tick = 0
			GH:DrawMini()
		end
	end)
	f:SetScript("OnShow", function()
		GH:RequestRoster()
		GH:DrawMini()
	end)
	f:Hide()
	self.miniFrame = f
	return f
end

-- Only online guildmates with Guild Hub, own row left out, grouped by activity (LFG first).
function GH:DrawMini()
	local f = self.miniFrame
	if not f then return end
	local rows = self:BuildStatusRows({ sort = "activity", showNoAddon = false, skipSelf = true })
	local people = 0
	for _, r in ipairs(rows) do if not r.header then people = people + 1 end end
	f.data = rows
	f.count:SetText(L.MINI_ONLINE:format(people))
	local max = math.max(0, #rows - f.visible)
	if f.offset > max then f.offset = max end
	self:DrawMiniRows()
end

function GH:DrawMiniRows()
	local f = self.miniFrame
	local rows = f.data or {}
	for i, r in ipairs(f.rows) do
		local d = rows[i + f.offset]
		if d then
			FillMiniRow(r, d)
			r:Show()
		else
			r:Hide()
		end
	end
	f.empty:SetShown(#rows == 0)
	local below = #rows - f.offset - f.visible
	f.more:SetText(below > 0 and L.MINI_MORE:format(below) or "")
end
