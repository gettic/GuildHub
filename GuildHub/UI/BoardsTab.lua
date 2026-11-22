-- Guild Hub: the Boards tab (1.0.1, plans\next-batch-1.0.x X1 + X2; previews in plans\next-batch-1.0.x\previews).
-- Left: the side list of boards (only built ones: Raid now; Offers, Needs ... arrive in 1.1).
-- Raid page, one View dropdown: Ready, Lockouts, Resistances, Makeup (guild list, open to all) and
-- Tonight (game calendar + summon queue). Fair trade: who doesn't share Raid info sees a locked note
-- on Ready / Lockouts / Resistances, and a field you switch off is a column you don't see.
-- Plain display frames only; nothing here sends anything except the calendar answer clicks
-- (Features\RaidNight.lua AnswerEvent: one calendar call per click) and the logger click (A10).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local SIDE_W = 160
local X0 = SIDE_W + 10           -- content left edge on the page
local CONTENT_W = 1030 - X0 - 2  -- 858
local TABLE_W = CONTENT_W - 30
local ROW_H = 20
local VIEWS = { "ready", "lockouts", "resist", "makeup", "tonight" }
local LOCKED_VIEWS = { ready = true, lockouts = true, resist = true }
GH.BOARD_VIEWS = VIEWS

W.ART.raidDone = "Interface\\RaidFrame\\ReadyCheck-Ready"
W.ART.raidLock = "Interface\\PetBattles\\PetBattle-LockIcon"
W.ART.calendar = "Interface\\Icons\\INV_Misc_PocketWatch_01"

local RED, ORANGE, YELLOW, GREEN, GREY = { 1, 0.3, 0.25 }, { 1, 0.55, 0.15 }, { 1, 0.85, 0.2 }, { 0.3, 0.95, 0.3 }, { 0.55, 0.55, 0.55 }
GH.RAID_COLORS = { red = RED, orange = ORANGE, yellow = YELLOW, green = GREEN, grey = GREY }

------------------------------------------------------------------------
-- Cell fills (plain functions; the fake tests call them through the column tables)
------------------------------------------------------------------------
local function NotShared(c, row)
	if row.state == "none" then W.CellText(c, L.RAID_NOADDON, GREY)
	elseif row.state == "old" then W.CellText(c, L.RAID_OLDADDON, GREY)
	else W.CellText(c, L.RAID_NOTSHARED, GREY) end
end

function GH:DurabilityColor(du)
	if du <= 30 then return RED elseif du <= 50 then return ORANGE elseif du <= 70 then return YELLOW end
	return GREEN
end

local function NameFill(c, row)
	if row.state == "none" then W.CellText(c, U.ShortName(row.name), GREY)
	else c.fs:SetText(U.ClassColored(row.name, row.class)) end
end

local function ItemName(id)
	local get = C_Item and C_Item.GetItemNameByID or GetItemInfo
	local ok, name = pcall(get, id)
	if ok and type(name) == "string" and not U.IsSecret(name) then return name end
	return nil
end

local COLS = {}
COLS.name = { key = "name", label = L.RAID_COL_NAME, w = 150, fill = NameFill,
	sort = function(r) return U.ShortName(r.name):lower() end }
COLS.role = { key = "role", label = L.RAID_COL_ROLE, w = 50, fill = function(c, r) W.CellRoles(c, r.role) end,
	sort = function(r) return r.role end }
COLS.lvl = { key = "level", label = L.RAID_COL_LVL, w = 36, align = "CENTER",
	fill = function(c, r) W.CellText(c, r.level and tostring(r.level) or "?") end, sort = function(r) return r.level end }
COLS.attune = { key = "attune", label = L.RAID_COL_ATTUNE, w = 180, field = "at",
	fill = function(c, r)
		if not r.attune then return NotShared(c, r) end
		if r.attune == "done" then W.CellText(c, "|T" .. W.ART.raidDone .. ":12:12|t " .. L.RAID_ATT_DONE, GREEN)
		elseif r.attune == "none" then W.CellText(c, L.RAID_ATT_NONE, GREY)
		else W.CellText(c, L.RAID_ATT_NEXT:format(r.step, r.steps), ORANGE) end
	end,
	sort = function(r)
		if r.attune == "done" then return 1000 end
		return r.attune and (r.step or 0) or nil
	end }
COLS.dura = { key = "durability", label = L.RAID_COL_DURA, w = 86, align = "CENTER", field = "du",
	fill = function(c, r)
		if not r.du then return NotShared(c, r) end
		W.CellText(c, r.du .. " %", GH:DurabilityColor(r.du))
	end,
	sort = function(r) return r.du end }
COLS.reag = { key = "reagents", label = L.RAID_COL_REAG, w = 150, field = "rg",
	fill = function(c, r)
		if r.rg == nil then return NotShared(c, r) end
		if r.rg < 0 then return W.CellText(c, L.RAID_REAG_NONE, GREY) end
		local id = GH.REAGENTS[r.class or ""]
		local name = id and ItemName(id)
		W.CellText(c, name and ("%d %s"):format(r.rg, name) or tostring(r.rg), r.rg == 0 and RED or nil)
	end,
	sort = function(r) return r.rg ~= nil and r.rg >= 0 and r.rg or nil end }
COLS.resist = { key = "resist", label = L.RAID_COL_RESIST, w = 60, align = "CENTER", field = "rs",
	fill = function(c, r)
		if not r.res then return NotShared(c, r) end
		W.CellText(c, tostring(r.res.total))
	end,
	sort = function(r) return r.res and r.res.total end }
COLS.zone = { key = "zone", label = L.RAID_COL_ZONE, w = 118,
	fill = function(c, r) W.CellText(c, r.zone or "", { 0.8, 0.8, 0.8 }) end,
	sort = function(r) return r.zone end }

local SCHOOLS = { "fire", "nature", "frost", "shadow", "arcane" }
for i, s in ipairs(SCHOOLS) do
	COLS["res_" .. s] = { key = "res_" .. s, label = L["RAID_RES_" .. s:upper()], w = 80, align = "CENTER", field = "rs",
		fill = function(c, r) if not r.res then return NotShared(c, r) end W.CellText(c, tostring(r.res[i])) end,
		sort = function(r) return r.res and r.res[i] end }
end
COLS.res_total = { key = "resist", label = L.RAID_COL_TOTAL, w = 80, align = "CENTER", field = "rs",
	fill = function(c, r) if not r.res then return NotShared(c, r) end W.CellText(c, tostring(r.res.total)) end,
	sort = function(r) return r.res and r.res.total end }

local function LockColumn(raid)
	return { key = "lock_" .. raid.key, w = 190, align = "CENTER", field = "lk", raid = raid,
		fill = function(c, r)
			if r.state == "none" then return W.CellText(c, L.RAID_LOCK_UNKNOWN, GREY) end
			if not r.lk then return NotShared(c, r) end
			local e = r.lk[raid.d]
			if e then W.CellText(c, L.RAID_LOCK_SAVED:format(e.k, e.n), RED) else W.CellText(c, "") end
		end,
		sort = function(r) local e = r.lk and r.lk[raid.d]; return e and e.k or (r.lk and -1) or nil end }
end

-- Makeup rows (class x role)
local function MakeupCol(key, label)
	return { key = "mk_" .. key, label = label, w = 110, align = "CENTER",
		fill = function(c, r) W.CellText(c, tostring(r[key] or 0), (r[key] or 0) == 0 and GREY or nil) end,
		sort = function(r) return r[key] end }
end
COLS.mkClass = { key = "mk_class", label = L.RAID_COL_CLASS, w = 200,
	fill = function(c, r)
		if r.all then return W.CellText(c, L.RAID_MK_ALL, W.GOLD) end
		c.fs:SetText(U.ClassColored(r.label, r.class))
	end,
	sort = function(r) return r.label end }

-- The columns of a view; fields you don't share are columns you don't see (fair trade).
function GH:RaidColumns(view)
	local cols
	if view == "ready" then
		cols = { COLS.name, COLS.role, COLS.lvl, COLS.attune, COLS.dura, COLS.reag, COLS.resist, COLS.zone }
	elseif view == "lockouts" then
		cols = { COLS.name, COLS.role, COLS.lvl }
		for _, raid in ipairs(self.RAIDS) do
			local col = LockColumn(raid)
			local left = self:RaidResetIn(raid.d)
			col.label = left and L.RAID_LOCK_HEAD_RESET:format(raid.name, raid.size, U.Duration(left))
				or L.RAID_LOCK_HEAD:format(raid.name, raid.size)
			cols[#cols + 1] = col
		end
	elseif view == "resist" then
		cols = { COLS.name, COLS.role, COLS.lvl }
		for _, s in ipairs(SCHOOLS) do cols[#cols + 1] = COLS["res_" .. s] end
		cols[#cols + 1] = COLS.res_total
	elseif view == "makeup" then
		return { COLS.mkClass, MakeupCol("t", L.RAID_COL_TANK), MakeupCol("h", L.RAID_COL_HEALER),
			MakeupCol("d", L.RAID_COL_DAMAGE), MakeupCol("u", L.RAID_COL_UNKNOWN), MakeupCol("total", L.RAID_COL_TOTAL) }
	else
		return {}
	end
	local out = {}
	for _, c in ipairs(cols) do
		if not c.field or self:RaidFieldShared(c.field) then out[#out + 1] = c end
	end
	return out
end

function GH:MakeupRows(lvlMin)
	local t, all = self:RaidMakeup(lvlMin)
	local rows = {}
	for _, class in ipairs(self.RAID_CLASSES) do
		local c = t[class]
		local label = type(LOCALIZED_CLASS_NAMES_MALE) == "table" and LOCALIZED_CLASS_NAMES_MALE[class] or class
		rows[#rows + 1] = { class = class, label = label, name = label, t = c.t, h = c.h, d = c.d, u = c.u, total = c.total }
	end
	return rows, { all = true, label = L.RAID_MK_ALL, name = "~", t = all.t, h = all.h, d = all.d, u = all.u, total = all.total }
end

-- Recruiting line (the officers' needs, Features\Recruit.lua; no new data)
function GH:RaidRecruitLine()
	if not self.RecruitNeeds then return nil end
	local need, cls = self:RecruitNeeds()
	if type(need) ~= "table" then return nil end
	local parts = {}
	for _, k in ipairs({ "t", "h", "d" }) do
		local n = tonumber(need[k])
		if n and n > 0 then parts[#parts + 1] = L.RAID_RECRUIT_ROLE:format(L["ROLE_" .. k:upper()], n) end
	end
	local classes = {}
	if type(cls) == "table" then
		for _, c in ipairs(self.RAID_CLASSES) do
			if cls[c] == 1 then
				classes[#classes + 1] = type(LOCALIZED_CLASS_NAMES_MALE) == "table" and LOCALIZED_CLASS_NAMES_MALE[c] or c
			end
		end
	end
	if #parts == 0 and #classes == 0 then return nil end
	local s = table.concat(parts, " · ")
	if #classes > 0 then s = s .. (s ~= "" and " " or "") .. "(" .. table.concat(classes, ", ") .. ")" end
	return s
end

------------------------------------------------------------------------
-- Building the tab
------------------------------------------------------------------------
local function Btn(parent, text, w, onClick)
	local b = W.Button(parent, text, w, 22)
	if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
	b:SetScript("OnClick", onClick)
	return b
end

local function Enable(b, on)
	b:SetEnabled(on and true or false)
	if b.SetGreyed then b:SetGreyed(not on) end
	if b.plain then b:SetAlpha(on and 1 or 0.45) end
end

local function ViewLabel(v) return L.RAID_VIEW_FMT:format(L["RAID_VIEW_" .. v:upper()] or v) end

local function BuildToolbar(tab, page)
	local bar = CreateFrame("Frame", nil, page)
	bar:SetPoint("TOPLEFT", X0, 0)
	bar:SetSize(CONTENT_W, GH.TOOLBAR_H)
	tab.toolbar = bar
	-- View
	local view = W.Dropdown(bar, 150)
	if view then
		view:SetupMenu(function(_, root)
			for _, v in ipairs(VIEWS) do
				root:CreateRadio(L["RAID_VIEW_" .. v:upper()], function() return GH.db.profile.raidView == v end,
					function() GH:SetRaidView(v) end)
			end
		end)
	else
		view = Btn(bar, "", 150, function()
			local cur = GH.db.profile.raidView
			local idx = 1
			for i, v in ipairs(VIEWS) do if v == cur then idx = i end end
			GH:SetRaidView(VIEWS[idx % #VIEWS + 1])
		end)
	end
	view:SetPoint("LEFT", 4, 0)
	tab.view = view
	-- My role (up to 2)
	tab.roleLabel = W.Text(bar, "GameFontNormalSmall", L.RAID_MYROLE)
	tab.roleLabel:SetPoint("LEFT", view, "RIGHT", 12, 0)
	local role = W.Dropdown(bar, 120)
	if role then
		role:SetupMenu(function(_, root)
			for _, k in ipairs({ "t", "h", "d" }) do
				root:CreateCheckbox(L["ROLE_" .. k:upper()], function() return (GH:OwnRole() or ""):find(k, 1, true) ~= nil end,
					function() GH:ToggleRole(k) end)
			end
		end)
		role:SetPoint("LEFT", tab.roleLabel, "RIGHT", 6, 0)
		tab.role = role
	else
		tab.roleChips = {}
		local prev = tab.roleLabel
		for _, k in ipairs({ "t", "h", "d" }) do
			local b = Btn(bar, L["ROLE_" .. k:upper()], 58, function() GH:ToggleRole(k) end)
			b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
			tab.roleChips[k] = b
			prev = b
		end
		tab.role = prev
	end
	-- search
	local search = W.EditBox(bar, 150, 22, 40, L.RAID_SEARCH_HINT, "search")
	search:SetPoint("LEFT", tab.role, "RIGHT", 14, 0)
	search:HookScript("OnEnterPressed", function(s) s:ClearFocus() end)
	search:HookScript("OnEscapePressed", function(s) s:SetText(""); s:ClearFocus() end)
	search:HookScript("OnTextChanged", function() GH:DrawBoardsTab() end)
	tab.search = search
	local function Tick(text, key)
		local cb = W.CheckButton(bar, text, 100)
		cb:SetScript("OnClick", function()
			GH.db.profile[key] = not GH.db.profile[key]
			GH:DrawBoardsTab()
		end)
		return cb
	end
	tab.only60 = Tick(L.RAID_ONLY60, "raidOnly60")
	tab.only60:SetPoint("LEFT", search, "RIGHT", 10, 0)
	tab.hideOff = Tick(L.RAID_HIDEOFF, "raidHideOffline")
	tab.hideOff:SetPoint("LEFT", tab.only60, "RIGHT", 90, 0)
	tab.shareText = W.Text(bar, "GameFontHighlightSmall", nil, "RIGHT")
	tab.shareText:SetPoint("RIGHT", -6, 0)
	-- Makeup: level switch
	tab.lvl60 = Btn(bar, L.RAID_MK_60, 90, function() GH.db.profile.raidMakeup60 = true; GH:DrawBoardsTab() end)
	tab.lvl60:SetPoint("LEFT", view, "RIGHT", 12, 0)
	tab.lvl50 = Btn(bar, L.RAID_MK_50, 90, function() GH.db.profile.raidMakeup60 = false; GH:DrawBoardsTab() end)
	tab.lvl50:SetPoint("LEFT", tab.lvl60, "RIGHT", 4, 0)
	tab.mkCount = W.Text(bar, "GameFontHighlightSmall")
	tab.mkCount:SetPoint("LEFT", tab.lvl50, "RIGHT", 12, 0)
	-- Tonight: raid, Open calendar, Refresh
	local raidDD = W.Dropdown(bar, 190)
	if raidDD then
		raidDD:SetupMenu(function(_, root)
			for _, r in ipairs(GH.RAIDS) do
				root:CreateRadio(r.name, function() return GH:TonightRaid().d == r.d end, function() GH:PickTonightRaid(r.d) end)
			end
		end)
	else
		raidDD = Btn(bar, "", 190, function()
			local cur, idx = GH:TonightRaid().d, 1
			for i, r in ipairs(GH.RAIDS) do if r.d == cur then idx = i end end
			GH:PickTonightRaid(GH.RAIDS[idx % #GH.RAIDS + 1].d)
		end)
	end
	raidDD:SetPoint("LEFT", view, "RIGHT", 12, 0)
	tab.raidDD = raidDD
	tab.openCal = Btn(bar, L.TN_OPEN_CAL, 120, function()
		if InCombatLockdown and InCombatLockdown() then return end
		if type(ToggleCalendar) == "function" then pcall(ToggleCalendar)
		elseif C_AddOns and C_AddOns.LoadAddOn then
			pcall(C_AddOns.LoadAddOn, "Blizzard_Calendar")
			if type(Calendar_Toggle) == "function" then pcall(Calendar_Toggle) end
		end
	end)
	tab.openCal:SetPoint("LEFT", raidDD, "RIGHT", 10, 0)
	tab.refresh = Btn(bar, L.TN_REFRESH, 90, function() GH:RefreshTonight("refresh"); GH:DrawBoardsTab() end)
	tab.refresh:SetPoint("LEFT", tab.openCal, "RIGHT", 6, 0)
	tab.refresh:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L.TN_REFRESH_TIP, 1, 1, 1, true)
		local left = GH:TonightCooldown()
		if left > 0 then GameTooltip:AddLine(L.TN_REFRESH_WAIT:format(math.ceil(left)), 1, 0.3, 0.3) end
		GameTooltip:Show()
	end)
	tab.refresh:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function RowEnter(r, d)
	GameTooltip:SetOwner(r, "ANCHOR_CURSOR")
	if d.class and not d.label and d.name and GH.roster[d.name] then
		GH:AddHoverCard(d.name, nil)
	elseif d.name then
		GameTooltip:AddLine(U.ShortName(d.name), 1, 1, 1)
	end
	if d.res then
		GameTooltip:AddLine(L.RAID_RES_TIP:format(d.res[1], d.res[2], d.res[3], d.res[4], d.res[5]), 0.8, 0.8, 0.8, true)
	end
	if d.note then GameTooltip:AddLine(d.note, 0.6, 0.6, 0.6, true) end
	GameTooltip:Show()
end

local function BuildRaidPage(tab, page)
	local inset = W.Inset(page)
	inset:SetPoint("TOPLEFT", X0, -GH.TOOLBAR_H)
	inset:SetPoint("BOTTOMRIGHT", -2, 24)
	tab.inset = inset
	local tbl = W.Table(inset, {
		width = TABLE_W, rowH = ROW_H, height = 360,
		onSort = function(key, rev)
			GH.db.profile.raidSort = { key = key, rev = rev or nil }
			GH:DrawBoardsTab(true)
		end,
		onEnter = RowEnter,
		setupRow = function(r)
			GH:NameMenuOnRow(r, function(s) return s.data and not s.data.header and not s.data.label and s.data.name or nil end, "boards")
		end,
	})
	tbl.frame:SetPoint("TOPLEFT", 8, -6)
	tbl.frame:SetPoint("BOTTOMRIGHT", -8, 4)
	tab.table = tbl
	-- the logger reminder strip (A10; only in a raid, only while allowed)
	local strip = CreateFrame("Frame", nil, inset)
	strip:SetPoint("BOTTOMLEFT", 6, 4)
	strip:SetPoint("BOTTOMRIGHT", -6, 4)
	strip:SetHeight(26)
	local sbg = strip:CreateTexture(nil, "BACKGROUND")
	sbg:SetAllPoints()
	sbg:SetColorTexture(0.5, 0.05, 0.05, 0.35)
	strip.text = W.Text(strip, "GameFontHighlightSmall", L.RAID_LOG_OFF)
	strip.text:SetPoint("LEFT", 10, 0)
	strip.button = Btn(strip, L.RAID_LOG_START, 120, function() GH:StartLogging() end)
	strip.button:SetPoint("RIGHT", -6, 0)
	W.Tooltip(strip.button, L.RAID_LOG_TIP)
	strip:Hide()
	tab.logStrip = strip
	-- the Makeup recruiting box
	local rec = W.Text(inset, "GameFontHighlightSmall")
	rec:SetPoint("BOTTOMLEFT", 12, 8)
	rec:SetWidth(TABLE_W)
	rec:Hide()
	tab.recruitLine = rec
	-- locked note (fair trade)
	local lock = CreateFrame("Frame", nil, inset)
	lock:SetAllPoints()
	local lvl = inset.GetFrameLevel and inset:GetFrameLevel()
	lock:SetFrameLevel((type(lvl) == "number" and lvl or 1) + 10)
	local lbg = lock:CreateTexture(nil, "BACKGROUND")
	lbg:SetAllPoints()
	lbg:SetColorTexture(0, 0, 0, 0.6)
	lock.icon = lock:CreateTexture(nil, "ARTWORK")
	lock.icon:SetTexture(W.ART.raidLock)
	lock.icon:SetSize(32, 32)
	lock.icon:SetPoint("CENTER", 0, 50)
	lock.text = W.Text(lock, "GameFontHighlight", nil, "CENTER")
	lock.text:SetPoint("TOP", lock.icon, "BOTTOM", 0, -10)
	lock.text:SetWidth(460)
	lock.text:SetWordWrap(true)
	lock.button = Btn(lock, L.RAID_LOCK_OPEN, 140, function() GH:OpenOptions() end)
	lock.button:SetPoint("TOP", lock.text, "BOTTOM", 0, -12)
	lock:EnableMouse(true)
	lock:Hide()
	tab.locked = lock
	tab.footer = W.Text(page, "GameFontHighlightSmall")
	tab.footer:SetPoint("BOTTOMLEFT", X0 + 6, 8)
	tab.footer:SetWidth(CONTENT_W - 10)
end

local function BuildTonight(tab, page)
	local f = CreateFrame("Frame", nil, tab.inset)
	f:SetAllPoints()
	tab.tonight = f
	-- event card (left)
	local card = W.Inset(f)
	card:SetPoint("TOPLEFT", 8, -8)
	card:SetSize(520, 132)
	f.card = card
	f.icon = card:CreateTexture(nil, "ARTWORK")
	f.icon:SetTexture(W.ART.calendar)
	f.icon:SetSize(40, 40)
	f.icon:SetPoint("TOPLEFT", 10, -10)
	f.title = W.Text(card, "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, 0)
	f.title:SetWidth(450)
	f.when = W.Text(card, "GameFontHighlightSmall")
	f.when:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
	f.by = W.Text(card, "GameFontDisableSmall")
	f.by:SetPoint("TOPLEFT", f.when, "BOTTOMLEFT", 0, -3)
	f.answer = W.Text(card, "GameFontNormal")
	f.answer:SetPoint("TOPLEFT", 12, -78)
	f.yes = Btn(card, L.TN_SIGNUP, 100, function() GH:AnswerEvent("yes") end)
	f.yes:SetPoint("BOTTOMLEFT", 12, 10)
	f.maybe = Btn(card, L.TN_TENTATIVE, 100, function() GH:AnswerEvent("maybe") end)
	f.maybe:SetPoint("LEFT", f.yes, "RIGHT", 6, 0)
	f.no = Btn(card, L.TN_DECLINE, 100, function() GH:AnswerEvent("no") end)
	f.no:SetPoint("LEFT", f.maybe, "RIGHT", 6, 0)
	f.why = W.Text(card, "GameFontDisableSmall")
	f.why:SetPoint("LEFT", f.no, "RIGHT", 10, 0)
	f.why:SetWidth(180)
	f.why:SetWordWrap(true)
	-- counts (right)
	local counts = W.Inset(f)
	counts:SetPoint("TOPLEFT", card, "TOPRIGHT", 8, 0)
	counts:SetPoint("BOTTOMLEFT", card, "BOTTOMRIGHT", 8, 0)
	counts:SetPoint("RIGHT", -8, 0)
	f.counts = counts
	f.countText = W.Text(counts, "GameFontHighlightSmall")
	f.countText:SetPoint("TOPLEFT", 10, -10)
	f.countText:SetWidth(270)
	f.countText:SetWordWrap(true)
	f.countNote = W.Text(counts, "GameFontDisableSmall")
	f.countNote:SetPoint("BOTTOMLEFT", 10, 8)
	f.countNote:SetWidth(270)
	f.countNote:SetWordWrap(true)
	-- summon queue
	f.queueHead = W.Text(f, "GameFontNormal")
	f.queueHead:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 2, -8)
	local q = W.Table(f, { width = TABLE_W, rowH = ROW_H, height = 170, onEnter = RowEnter,
		setupRow = function(r)
			GH:NameMenuOnRow(r, function(s) return s.data and not s.data.header and s.data.name or nil end, "boards")
		end })
	q.frame:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -28)
	q.frame:SetPoint("BOTTOMRIGHT", -8, 40)
	q:SetColumns({
		{ key = "name", label = L.RAID_COL_NAME, w = 160, fill = NameFill },
		{ key = "role", label = L.RAID_COL_ROLE, w = 50, fill = function(c, r) W.CellRoles(c, r.role) end },
		{ key = "zone", label = L.RAID_COL_ZONE, w = 190, fill = function(c, r) W.CellText(c, r.zone or "?", { 0.8, 0.8, 0.8 }) end },
		{ key = "need", label = L.TN_COL_NEED, w = 110, align = "CENTER",
			fill = function(c, r) if r.need then W.CellText(c, L.TN_YES, ORANGE) elseif not r.addon then W.CellText(c, "-", GREY) end end },
		{ key = "click", label = L.TN_COL_CLICK, w = 100, align = "CENTER",
			fill = function(c, r) if r.click then W.CellText(c, L.TN_YES, GREEN) elseif not r.addon then W.CellText(c, "-", GREY) end end },
		{ key = "note", label = L.TN_COL_NOTE, w = 210,
			fill = function(c, r)
				if not r.addon then W.CellText(c, L.TN_NOTE_NOADDON, GREY)
				elseif r.late then W.CellText(c, L.TN_NOTE_LATE, YELLOW) end
			end },
	})
	f.queue = q
	-- Me: ticks
	local me = CreateFrame("Frame", nil, f)
	me:SetPoint("BOTTOMLEFT", 8, 6)
	me:SetPoint("BOTTOMRIGHT", -8, 6)
	me:SetHeight(28)
	f.me = me
	local lbl = W.Text(me, "GameFontNormal", L.TN_ME)
	lbl:SetPoint("LEFT", 4, 0)
	local function Tick(text, bitv, prev, w)
		local cb = W.CheckButton(me, text, w)
		cb:SetPoint("LEFT", prev, "RIGHT", 10, 0)
		cb:SetScript("OnClick", function() GH:SetRaidTick(bitv, not GH:RaidTick(bitv)) end)
		return cb
	end
	f.tSummon = Tick(L.TICK_SUMMON, GH.TK.summon, lbl, 110)
	f.tClick = Tick(L.TICK_CLICK, GH.TK.click, f.tSummon, 170)
	f.tLate = Tick(L.TICK_LATE, GH.TK.late, f.tClick, 100)
	W.Tooltip(f.tSummon, L.TICK_SUMMON_TIP)
	W.Tooltip(f.tClick, L.TICK_CLICK_TIP)
	W.Tooltip(f.tLate, L.TICK_LATE_TIP)
	f.meNote = W.Text(me, "GameFontDisableSmall", L.TN_ME_NOTE)
	f.meNote:SetPoint("RIGHT", -4, 0)
	f.meNote:SetWidth(260)
	f.meNote:SetWordWrap(true)
	f:Hide()
end

function GH:BuildBoardsTab(page)
	local tab = { page = page }
	self.boardsTab = tab
	tab.side = W.SideList(page, { { key = "raid", label = L.BOARDS_RAID } }, function(key) GH:ShowBoard(key) end)
	tab.side:SetPoint("TOPLEFT", 2, 0)
	tab.side:SetPoint("BOTTOMLEFT", 2, 24)
	tab.side:SetWidth(SIDE_W)
	tab.more = W.Text(tab.side, "GameFontDisableSmall", L.BOARDS_MORE)
	tab.more:SetPoint("TOPLEFT", 12, -44)
	tab.more:SetWidth(SIDE_W - 20)
	tab.more:SetWordWrap(true)
	BuildToolbar(tab, page)
	BuildRaidPage(tab, page)
	BuildTonight(tab, page)
	-- while shown: redraw every 10 s (lockout timers, durability); the guild list every 15 s
	page:SetScript("OnUpdate", function(_, elapsed)
		tab.tick = (tab.tick or 0) + elapsed
		tab.rosterTick = (tab.rosterTick or 0) + elapsed
		if tab.rosterTick >= 15 then tab.rosterTick = 0; GH:RequestRoster() end
		if tab.tick >= 10 then tab.tick = 0; GH:DrawBoardsTab(true) end
	end)
end

------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------
function GH:BoardsTabShown()
	local f = self.mainFrame
	return f and f:IsShown() and f.currentTab == "boards" and self.boardsTab ~= nil or false
end

function GH:ShowBoard(key)
	local tab = self.boardsTab
	if not tab then return end
	tab.side:Select(key or "raid")
	if self.db.profile.raidView == "tonight" then self:RefreshTonight("open") end
	self:DrawBoardsTab()
end

function GH:SetRaidView(v)
	local ok = false
	for _, x in ipairs(VIEWS) do if x == v then ok = true end end
	if not ok then return end
	self.db.profile.raidView = v
	if v == "tonight" then self:RefreshTonight("open") end
	self:DrawBoardsTab()
end

-- Opens the window on a board ("raid").
function GH:OpenBoards(key)
	if self.miniFrame and self.miniFrame:IsShown() then self.miniFrame:Hide() end
	local f = self:CreateMainFrame()
	f:Show()
	self:ShowTab("boards")
	if key then self:ShowBoard(key) end
end

-- Data changed (bundle fields, ticks, calendar): redraw soon while shown.
function GH:RefreshBoardsTab()
	if not self:BoardsTabShown() or self.boardsTimer then return end
	self.boardsTimer = self:ScheduleTimer(function()
		GH.boardsTimer = nil
		if GH:BoardsTabShown() then GH:DrawBoardsTab(true) end
	end, 0.3)
end

local function SortName(key)
	local map = { name = L.RAID_COL_NAME, role = L.RAID_COL_ROLE, level = L.RAID_COL_LVL, attune = L.RAID_COL_ATTUNE,
		durability = L.RAID_COL_DURA, reagents = L.RAID_COL_REAG, resist = L.RAID_COL_RESIST, zone = L.RAID_COL_ZONE }
	local s = map[key] or tostring(key)
	return s:sub(1, 1) .. s:sub(2):lower() -- "Durability"
end

local function DrawToolbar(gh, tab, view)
	local p = gh.db.profile
	local member = LOCKED_VIEWS[view] and true or false
	tab.view:SetLabel(ViewLabel(view))
	tab.roleLabel:SetShown(member)
	if tab.roleChips then
		local cur = gh:OwnRole() or ""
		for k, b in pairs(tab.roleChips) do b:SetShown(member); b:SetActive(cur:find(k, 1, true) ~= nil) end
	else
		tab.role:SetShown(member)
		local cur = gh:OwnRole()
		local names = {}
		for ch in (cur or ""):gmatch(".") do names[#names + 1] = L["ROLE_" .. ch:upper()] end
		tab.role:SetLabel(#names > 0 and table.concat(names, " + ") or L.RAID_ROLE_NONE)
	end
	tab.search:SetShown(member)
	tab.only60:SetShown(member)
	tab.hideOff:SetShown(member)
	tab.only60:SetActive(p.raidOnly60 ~= false)
	tab.hideOff:SetActive(p.raidHideOffline ~= false)
	tab.shareText:SetShown(member)
	if gh:CanUse("raid") then
		tab.shareText:SetText(L.RAID_SHARED)
		tab.shareText:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
	else
		tab.shareText:SetText(L.RAID_NOTSHARED_TB)
		tab.shareText:SetTextColor(GREY[1], GREY[2], GREY[3])
	end
	local mk = view == "makeup"
	tab.lvl60:SetShown(mk); tab.lvl50:SetShown(mk); tab.mkCount:SetShown(mk)
	if mk then
		tab.lvl60:SetActive(p.raidMakeup60 ~= false)
		tab.lvl50:SetActive(p.raidMakeup60 == false)
	end
	local tn = view == "tonight"
	tab.raidDD:SetShown(tn); tab.openCal:SetShown(tn); tab.refresh:SetShown(tn)
	if tn then
		tab.raidDD:SetLabel(L.TN_RAID_FMT:format(gh:TonightRaid().name))
		Enable(tab.refresh, gh:TonightCooldown() <= 0)
	end
end

local function DrawTonight(gh, tab)
	local f = tab.tonight
	local t = gh.tonight
	local ev = t.event
	if ev then
		f.title:SetText(ev.title)
		local when = date("%a %d %b · %H:%M", ev.start)
		local rel = ev.untilStart >= 0 and L.TN_STARTS_IN:format(U.Duration(ev.untilStart))
			or L.TN_STARTED:format(U.Duration(-ev.untilStart))
		f.when:SetText(L.TN_WHEN:format(when, rel))
		local kindText = ev.inviteType == 1 and L.TN_KIND_SIGNUP or (ev.calendarType == "GUILD_ANNOUNCEMENT" and L.TN_KIND_ANNOUNCE or L.TN_KIND_INVITE)
		f.by:SetText(ev.creator and L.TN_BY:format(ev.creator, kindText) or kindText)
	else
		f.title:SetText(t.why == "nocal" and L.TN_NOCAL or L.TN_NONE)
		f.when:SetText(t.why == "nocal" and "" or L.TN_NONE_SUB)
		f.by:SetText("")
	end
	local kind, why = gh:EventAnswerKind(ev)
	local cur = ev and gh.CAL_STATUS[ev.inviteStatus or -1]
	if t.answered then cur = t.answered end
	f.answer:SetText(L.TN_YOUR_ANSWER:format(cur and L["TN_ANS_" .. cur:upper()] or L.TN_ANS_NONE))
	for _, k in ipairs({ "yes", "maybe", "no" }) do
		local b = f[k]
		local can = kind ~= nil and (k == "yes" or kind == "signup" or kind == "invite")
		Enable(b, can)
		b:SetActive(cur == k)
	end
	f.why:SetText(kind and "" or (L.TN_WHY[why or "noevent"] or ""))
	-- counts
	local c = t.counts
	local lines = {}
	if not ev then
		lines[1] = ""
	elseif not c then
		lines[1] = L.TN_COUNTS_WAIT
	elseif c.unavailable then
		lines[1] = L.TN_COUNTS_UNAVAILABLE
	else
		lines[1] = L.TN_COUNTS:format(c.yes, c.maybe, c.no, c.standby, gh:LateCount())
		lines[2] = L.TN_BYROLE:format(c.byRole.t, c.byRole.h, c.byRole.d, c.byRole.u)
	end
	f.countText:SetText(table.concat(lines, "\n"))
	f.countNote:SetText(ev and L.TN_COUNTS_NOTE or "")
	-- summon queue
	local rows, away = gh:BuildSummonRows()
	local raid = gh:TonightRaid()
	if rows then
		for _, r in ipairs(rows) do
			if r.header then r.header = L["TN_GROUP_" .. r.header:upper()] or r.header end
			if not gh:CanUse("raid") and not r.header and r.name ~= gh:MyName() then r.need, r.click, r.late, r.role = nil, nil, nil, nil end
		end
		f.queueHead:SetText(away > 0 and L.TN_QUEUE_HEAD:format(away, raid.name) or L.TN_QUEUE_ALL:format(raid.name))
		f.queue:SetRows(rows, true)
		f.queue:SetEmpty(#rows == 0 and L.TN_QUEUE_EMPTY or nil)
	else
		f.queueHead:SetText(L.TN_QUEUE_TITLE)
		f.queue:SetRows({}, true)
		f.queue:SetEmpty(L.TN_NORAID)
	end
	f.tSummon:SetActive(gh:RaidTick(gh.TK.summon))
	f.tClick:SetActive(gh:RaidTick(gh.TK.click))
	f.tLate:SetActive(gh:RaidTick(gh.TK.late))
end

function GH:DrawBoardsTab(keepPlace)
	local tab = self.boardsTab
	if not tab then return end
	local p = self.db.profile
	local view = p.raidView
	local okView = false
	for _, v in ipairs(VIEWS) do if v == view then okView = true end end
	if not okView then view = "ready"; p.raidView = view end
	if not tab.side.selected then tab.side:Select("raid") end
	DrawToolbar(self, tab, view)
	local on = self:FeatureOn("raid")
	local locked = LOCKED_VIEWS[view] and not self:CanUse("raid")
	tab.locked:SetShown(locked)
	if locked then tab.locked.text:SetText(self:LockedText("raid", L.RAID_LOCKED)) end
	local tn = view == "tonight"
	tab.tonight:SetShown(tn)
	tab.table.frame:SetShown(not tn and not locked)
	tab.recruitLine:SetShown(view == "makeup")
	local logger = on and not tn and self:LoggerReminder()
	tab.logStrip:SetShown(logger and true or false)
	tab.table.frame:SetPoint("BOTTOMRIGHT", -8, (logger and 32 or 4) + (view == "makeup" and 24 or 0))
	if tn then
		DrawTonight(self, tab)
		tab.footer:SetText(L.TN_FOOTER)
		return
	end
	if locked then
		tab.footer:SetText("")
		return
	end
	local tbl = tab.table
	local cols = self:RaidColumns(view)
	if tbl.viewKey ~= view or tbl.colCount ~= #cols then
		tbl:SetColumns(cols)
		tbl.viewKey, tbl.colCount = view, #cols
	else
		tbl:SetColumns(cols) -- labels (reset timers) may change
	end
	if view == "makeup" then
		local lvl = p.raidMakeup60 ~= false and 60 or 50
		local rows, all = self:MakeupRows(lvl)
		tbl:SetSort(p.raidSort and p.raidSort.key, p.raidSort and p.raidSort.rev)
		if not tbl:Column(tbl.sortKey) then tbl:SetSort("mk_class", false) end
		W.SortRows(rows, tbl:Column(tbl.sortKey), tbl.sortRev)
		rows[#rows + 1] = all
		tbl:SetRows(rows, true)
		tbl:SetEmpty(nil)
		tab.mkCount:SetText(L.RAID_MK_COUNT:format(all.total, lvl == 60 and L.RAID_MK_60 or L.RAID_MK_50))
		local rec = self:RaidRecruitLine()
		tab.recruitLine:SetText(rec and L.RAID_RECRUIT_LINE:format(rec) or L.RAID_RECRUIT_NONE)
		tab.footer:SetText(L.RAID_MK_FOOTER)
		return
	end
	local rows = self:BuildRaidRows({ search = tab.search:GetText(), only60 = p.raidOnly60 ~= false,
		hideOffline = p.raidHideOffline ~= false })
	local sk = p.raidSort and p.raidSort.key
	if not tbl:Column(sk) then sk = view == "ready" and "durability" or "name" end
	tbl:SetSort(sk, p.raidSort and p.raidSort.key == sk and p.raidSort.rev)
	tbl:SetRows(rows, false, keepPlace)
	local withAddon = 0
	for _, r in ipairs(rows) do if r.state == "addon" then withAddon = withAddon + 1 end end
	tbl:SetEmpty(#rows == 0 and L.RAID_EMPTY or nil)
	local how = view == "lockouts" and L.RAID_FOOT_LOCK or L.RAID_FOOT_HINT
	tab.footer:SetText(L.RAID_FOOTER:format(#rows, withAddon, SortName(tbl.sortKey),
		tbl.sortRev and L.RAID_SORT_HIGH or L.RAID_SORT_LOW, how))
end

-- Tab registry (UI\MainFrame.lua): the fifth tab, while the raid feature is on.
GH:RegisterTab({ key = "boards", order = 50, label = "TAB_BOARDS", sub = "WIN_SUB_BOARDS", tip = "TAB_TIP_BOARDS",
	feature = "raid",
	build = function(gh, page) gh:BuildBoardsTab(page) end,
	show = function(gh) gh:ShowBoard(gh.boardsTab and gh.boardsTab.side.selected or "raid") end })
