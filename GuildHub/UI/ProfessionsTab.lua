-- Guild Hub: the Professions tab (step 3). Built on first show. Data and rules: Professions.lua.
-- Left: directory (crafters per profession) or, while searching, one row per matching recipe.
-- Right: your professions and the rare-recipe feed. Request opens a small list of crafters; clicking an
-- online one fills your chat box with a ready whisper (you press Enter).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local ROW_H = 24
local LIST_W = 778
local PAGE_H = 460
-- directory columns
local COL = {
	name = { 8, 150 }, prof = { 162, 120 }, skill = { 286, 70 }, spec = { 360, 140 }, recipes = { 504, 60 },
	seen = { 568, 100 }, whisper = { 672, 58 },
}
-- recipe (search) columns
local RCOL = { icon = { 8, 18 }, rname = { 30, 220 }, prof = { 254, 110 }, crafters = { 368, 300 }, request = { 672, 90 } }
local PANEL_LINES = 8
GH.PROF_COLUMNS, GH.PROF_RCOLUMNS = COL, RCOL

------------------------------------------------------------------------
-- Rows (one frame type for both modes)
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
	r.prof = col(COL.prof, "GameFontHighlightSmall")
	r.skill = col(COL.skill)
	r.spec = col(COL.spec, "GameFontHighlightSmall")
	r.recipes = col(COL.recipes, "GameFontHighlightSmall")
	r.seen = col(COL.seen, "GameFontHighlightSmall")
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(RCOL.icon[2], RCOL.icon[2])
	r.icon:SetPoint("LEFT", RCOL.icon[1], 0)
	r.rname = col(RCOL.rname)
	r.rprof = col(RCOL.prof, "GameFontHighlightSmall")
	r.crafters = col(RCOL.crafters, "GameFontHighlightSmall")
	r.header = W.Text(r, "GameFontNormal")
	r.header:SetPoint("LEFT", 8, 0)
	r.headerLine = W.HeaderLine(r, r.header)
	r.whisper = W.Button(r, L.BTN_WHISPER, COL.whisper[2], 18)
	r.whisper:SetPoint("LEFT", COL.whisper[1], 0)
	r.whisper:SetScript("OnClick", function() if r.data and r.data.name then GH:WhisperMember(r.data.name) end end)
	r.request = W.Button(r, L.BTN_REQUEST, RCOL.request[2], 18)
	r.request:SetPoint("LEFT", RCOL.request[1], 0)
	r.request:SetScript("OnClick", function(self) if r.data and r.data.recipe then GH:ShowRequestPopup(r.data, self) end end)
	-- 1.0.0-beta.2 (Q8): a greyed Request says why
	if r.request.SetMotionScriptsWhileDisabled then r.request:SetMotionScriptsWhileDisabled(true) end
	r.request:SetScript("OnEnter", function(self)
		if self:IsEnabled() then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L.REQ_NONE_ONLINE, 1, 0.5, 0.25, true)
		GameTooltip:Show()
	end)
	r.request:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnEnter", function(self) GH:ProfRowTooltip(self, self.data) end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- 0.6.0-beta.3: right-click a crafter (directory row) = the name menu (UI\NameMenu.lua)
	GH:NameMenuOnRow(r, function(s)
		local d = s.data
		return d and not d.header and not d.recipe and d.name or nil
	end, "prof")
	-- 1.0.0-beta.2 (Q3): shift-click puts the recipe link (or the crafter's name) into the open chat box
	r:HookScript("OnMouseUp", function(s, button)
		if button == "LeftButton" and IsShiftKeyDown and IsShiftKeyDown() then GH:ProfShiftClick(s.data) end
	end)
end

-- The text a shift-click inserts: the recipe's spell link, or "Name (Profession 300/300)".
function GH:ProfLinkText(d)
	if type(d) ~= "table" or d.header then return nil end
	if d.recipe then
		local link
		if C_Spell and C_Spell.GetSpellLink then
			local ok, l = pcall(C_Spell.GetSpellLink, d.recipe)
			if ok and not U.IsSecret(l) then link = l end
		end
		if type(link) ~= "string" and GetSpellLink then
			local ok, l = pcall(GetSpellLink, d.recipe)
			if ok and not U.IsSecret(l) then link = l end
		end
		if type(link) == "string" and link ~= "" then return link end
		return d.rname
	end
	if not d.name then return nil end
	local skill = d.rank and d.max and (" %d/%d"):format(d.rank, d.max) or ""
	return ("%s (%s%s)"):format(U.ShortName(d.name), self:ProfName(d.line), skill)
end

-- Only into the chat box (or the macro / search box the game picks); nothing is sent (tos Q3).
-- Returns true when the game took the text.
function GH:ProfShiftClick(d)
	local text = self:ProfLinkText(d)
	if not text then return false end
	local fn = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
	if type(fn) ~= "function" then return false end
	local ok, took = pcall(fn, text)
	return ok and took and true or false
end

local DIR_PARTS = { "name", "prof", "skill", "spec", "recipes", "seen" }
local REC_PARTS = { "icon", "rname", "rprof", "crafters" }

local function Show(r, list, on) for _, k in ipairs(list) do r[k]:SetShown(on) end end

local function CraftersText(cs)
	local parts = {}
	for i = 1, math.min(3, #cs) do
		local c = cs[i]
		local s = U.ShortName(c.name)
		if c.mine then
			parts[i] = "|cffffd100" .. GH:MineLabel(c) .. "|r" -- your own character: gold, never "online" green
		else
			parts[i] = c.online and ("|cff40ff40" .. s .. "|r") or ("|cff999999" .. s .. "|r")
		end
	end
	local t = table.concat(parts, ", ")
	if #cs > 3 then t = t .. L.TIP_MORE:format(#cs - 3) end
	return t
end

local function FillRow(r, d)
	r.data = d
	local isHeader = d.header ~= nil
	local isRecipe = d.recipe ~= nil
	r.header:SetShown(isHeader)
	if r.headerLine then r.headerLine:SetShown(isHeader) end
	r.hl:SetShown(not isHeader)
	Show(r, DIR_PARTS, not isHeader and not isRecipe)
	Show(r, REC_PARTS, isRecipe)
	r.whisper:SetShown(not isHeader and not isRecipe and not d.isSelf and not d.mine) -- never yourself / your alts
	r.request:SetShown(isRecipe)
	if isHeader then
		r.header:SetText(("%s (%d)"):format(GH:ProfName(d.header), d.count))
		r.header:SetTextColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
		r.bg:SetColorTexture(0, 0, 0, 0)
		return
	end
	r.bg:SetColorTexture(1, 1, 1, (d.isSelf or d.mine) and 0.07 or 0.03)
	if isRecipe then
		local icon
		if C_Spell and C_Spell.GetSpellTexture then icon = C_Spell.GetSpellTexture(d.recipe) end
		r.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		r.rname:SetText(d.rname)
		r.rprof:SetText(GH:ProfName(d.line))
		r.crafters:SetText(CraftersText(d.crafters))
		local anyOnline = d.onlineCount > 0
		r.request:SetEnabled(anyOnline)
		r.request:SetGreyed(not anyOnline)
		return
	end
	local shown = U.ClassColored(d.name, d.class)
	if d.mine == "self" then shown = L.PROF_YOU:format(shown)
	elseif d.mine == "alt" then shown = L.PROF_YOU_ALT:format(shown) end
	r.name:SetText(shown)
	r.prof:SetText(GH:ProfName(d.line))
	r.skill:SetText(d.rank and d.max and ("%d/%d"):format(d.rank, d.max) or tostring(d.rank or "-"))
	r.spec:SetText(d.spec or "-")
	r.recipes:SetText(d.recipes > 0 and tostring(d.recipes) or "-")
	if d.mine == "alt" then
		r.seen:SetText(L.PROF_ALT_HINT) -- your alt: log in on it to craft (nobody to whisper)
		r.seen:SetTextColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
	elseif d.online then
		r.seen:SetText(L.PROF_ONLINE)
		r.seen:SetTextColor(0.45, 0.9, 0.45)
	else
		r.seen:SetText(d.lastSeen and L.AGO:format(U.Ago(U.Now() - d.lastSeen)) or "-")
		r.seen:SetTextColor(W.COLOR.gray[1], W.COLOR.gray[2], W.COLOR.gray[3])
	end
end

-- Recipe or crafter tooltip. The game's own item/spell tooltip first, then our lines (added only).
function GH:ProfRowTooltip(owner, d)
	if not d or d.header then return end
	GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
	if d.recipe then
		local T = C_TradeSkillUI
		local shown = false
		if T and T.GetRecipeOutputItemData then
			local ok, out = pcall(T.GetRecipeOutputItemData, d.recipe)
			if ok and type(out) == "table" and type(out.hyperlink) == "string" and not U.IsSecret(out.hyperlink) then
				shown = pcall(GameTooltip.SetHyperlink, GameTooltip, out.hyperlink)
			end
		end
		if not shown and GameTooltip.SetSpellByID then shown = pcall(GameTooltip.SetSpellByID, GameTooltip, d.recipe) end
		if not shown then GameTooltip:AddLine(d.rname, 1, 1, 1) end
		local mats = self:RecipeMaterials(d.recipe)
		if mats then GameTooltip:AddLine(L.PROF_MATS:format(mats), 0.8, 0.8, 0.8, true) end
		GameTooltip:AddLine(L.PROF_CAN_MAKE, W.GOLD[1], W.GOLD[2], W.GOLD[3])
		for i, c in ipairs(d.crafters) do
			if i > 12 then GameTooltip:AddLine(L.TIP_MORE:format(#d.crafters - 12), 0.6, 0.6, 0.6) break end
			if c.mine then -- your own character: gold, with how to craft it
				GameTooltip:AddDoubleLine(self:MineLabel(c), (c.mine == "alt" and L.PROF_ALT_HINT or "") .. "  " .. tostring(c.rank or ""),
					W.GOLD[1], W.GOLD[2], W.GOLD[3], W.GOLD[1], W.GOLD[2], W.GOLD[3])
			else
				local g = c.online and 1 or 0.6
				GameTooltip:AddDoubleLine(U.ShortName(c.name), (c.online and L.PROF_ONLINE or "") .. "  " .. tostring(c.rank or ""),
					g, g, g, c.online and 0.45 or 0.6, c.online and 0.9 or 0.6, c.online and 0.45 or 0.6)
			end
		end
	else
		GameTooltip:AddLine(U.ClassColored(d.name, d.class))
		local line = self:ProfLine(d.name)
		if line then GameTooltip:AddLine(line, 1, 1, 1, true) end
		if d.old then GameTooltip:AddLine(L.PROF_UPDATING, 0.6, 0.6, 0.6) end
	end
	GameTooltip:Show()
end

-- "1 x Thorium Bar, 1 x Arcane Crystal" when the game gives the recipe's materials (else nil).
function GH:RecipeMaterials(recipeID)
	local T = C_TradeSkillUI
	if not (T and T.GetRecipeSchematic) then return nil end
	local ok, s = pcall(T.GetRecipeSchematic, recipeID, false)
	if not ok or type(s) ~= "table" or type(s.reagentSlotSchematics) ~= "table" then return nil end
	local parts = {}
	for _, slot in ipairs(s.reagentSlotSchematics) do
		local r = type(slot) == "table" and type(slot.reagents) == "table" and slot.reagents[1]
		local item = r and (r.itemID or (type(r.reagent) == "table" and r.reagent.itemID))
		if type(item) == "number" and not U.IsSecret(item) then
			local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(item)) or ("#" .. item)
			parts[#parts + 1] = ("%d x %s"):format(tonumber(slot.quantityRequired) or 1, name)
		end
	end
	return #parts > 0 and table.concat(parts, ", ") or nil
end

------------------------------------------------------------------------
-- Request popup
------------------------------------------------------------------------
local POP_W, POP_ROWS = 280, 8

function GH:ShowRequestPopup(d, anchor)
	local tab = self.profTab
	local p = tab.popup
	if not p then
		p = W.Popup("GuildHubRequestPopup", self.mainFrame, 0.97)
		p:SetSize(POP_W, 92 + POP_ROWS * 22)
		p:SetFrameStrata("DIALOG")
		p:EnableMouse(true)
		p.title = W.Text(p, "GameFontNormal")
		p.title:SetPoint("TOPLEFT", 12, -12)
		p.title:SetWidth(POP_W - 50)
		p.hint = W.Text(p, "GameFontHighlightSmall", L.REQ_HINT)
		p.hint:SetPoint("TOPLEFT", 12, -32)
		p.hint:SetWidth(POP_W - 24)
		p.close = W.TitleButton(p, "close", 24)
		p.close:SetPoint("TOPRIGHT", -2, -2)
		p.close:SetScript("OnClick", function() p:Hide() end)
		p.buttons = {}
		for i = 1, POP_ROWS do
			local b = W.Button(p, "", POP_W - 24, 20)
			b:SetPoint("TOPLEFT", 12, -50 - (i - 1) * 22)
			if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
			b:SetScript("OnClick", function(btn)
				if btn.crafter and GH:RequestCraft(p.recipe, btn.crafter) then p:Hide() end
			end)
			p.buttons[i] = b
		end
		p.mats = W.CheckButton(p, L.REQ_MATS_CHECK, 160)
		p.mats:SetPoint("BOTTOMLEFT", 10, 8)
		p.mats:SetScript("OnClick", function()
			GH.db.profile.profMats = not GH.db.profile.profMats
			p.mats:SetActive(GH.db.profile.profMats)
		end)
		tinsert(UISpecialFrames, "GuildHubRequestPopup")
		tab.popup = p
	end
	p.recipe = d.recipe
	p.title:SetText(d.rname)
	for i, b in ipairs(p.buttons) do
		local c = d.crafters[i]
		b:SetShown(c ~= nil)
		if c and c.mine then -- yourself / your alt (listed last): never a request, greyed
			b.crafter = nil
			b:SetLabel(c.mine == "self" and L.REQ_SELF or L.REQ_ALT:format(U.ShortName(c.name)))
			b:SetEnabled(false)
			b:SetGreyed(true)
		elseif c then
			local online = c.online and GH:IsOnline(c.name)
			b.crafter = online and c.name or nil -- offline: the button does nothing (greyed)
			b:SetLabel(("%s  (%s)"):format(U.ShortName(c.name), online and L.PROF_ONLINE or L.PROF_OFFLINE))
			b:SetEnabled(online and true or false)
			b:SetGreyed(not online)
		end
	end
	p.mats:SetActive(self.db.profile.profMats)
	p:ClearAllPoints()
	p:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
	p:Show()
end

------------------------------------------------------------------------
-- Building the tab
------------------------------------------------------------------------
local function MakeFilter(parent, db)
	local function label() return L.PROF_FILTER_FMT:format(L.PROF_FILTER[db.profFilter] or L.PROF_FILTER.all) end
	local dd = W.Dropdown(parent, 170)
	if dd then
		dd:SetupMenu(function(_, root)
			for _, key in ipairs(GH.PROF_FILTERS) do
				root:CreateRadio(L.PROF_FILTER[key] or key, function() return db.profFilter == key end, function()
					db.profFilter = key
					GH:DrawProfessionsTab(true)
				end)
			end
		end)
		dd.labelFn = label
		return dd
	end
	local b = W.Button(parent, "", 170, 24)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnClick", function(_, button)
		local list, i = GH.PROF_FILTERS, 1
		for k, v in ipairs(list) do if v == db.profFilter then i = k end end
		db.profFilter = list[(i - 1 + (button == "RightButton" and -1 or 1)) % #list + 1]
		GH:DrawProfessionsTab(true)
	end)
	b.labelFn = label
	return b
end

-- Plain rows (when the ScrollBox templates are missing): mouse wheel scrolls.
local function MakePlainList(tab, area)
	tab.rows, tab.offset = {}, 0
	local n = math.floor(tab.listHeight / ROW_H)
	for i = 1, n do
		local r = CreateFrame("Button", nil, area)
		r:SetSize(LIST_W, ROW_H - 2)
		r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
		SetupRow(r)
		tab.rows[i] = r
	end
	area:EnableMouseWheel(true)
	area:SetScript("OnMouseWheel", function(_, delta)
		local max = math.max(0, #(tab.data or {}) - #tab.rows)
		tab.offset = math.max(0, math.min(max, tab.offset - delta * 3))
		GH:DrawProfRows()
	end)
end

function GH:BuildProfessionsTab(page)
	local tab = { page = page }
	self.profTab = tab
	local db = self.db.profile

	-- toolbar strip at the top of the page, above the list (0.6.0-beta.3: out of the tab row)
	local search = W.EditBox(page, 260, 22, 40, L.PROF_SEARCH_HINT, "search")
	search:SetPoint("TOPLEFT", page, "TOPLEFT", search.ghTemplate and 12 or 6, -3)
	search:HookScript("OnEnterPressed", function(s) s:ClearFocus() end)
	search:HookScript("OnEscapePressed", function(s) s:SetText(""); s:ClearFocus(); GH:DrawProfessionsTab(true) end)
	search:HookScript("OnTextChanged", function() GH:WantRecipeLists(); GH:DrawProfessionsTab(true) end)
	tab.search = search

	tab.filter = MakeFilter(page, db)
	tab.filter:SetPoint("LEFT", search, "RIGHT", 12, 0)
	W.Tooltip(tab.filter, L.PROF_FILTER_TIP)

	tab.online = W.CheckButton(page, L.PROF_ONLINE_ONLY, 110)
	tab.online:SetPoint("LEFT", tab.filter, "RIGHT", 12, 0)
	tab.online:SetScript("OnClick", function()
		db.profOnline = not db.profOnline
		GH:DrawProfessionsTab(true)
	end)

	-- list inset with column titles
	local inset = W.Inset(page)
	inset:SetPoint("TOPLEFT", 2, -GH.TOOLBAR_H)
	inset:SetPoint("BOTTOMLEFT", 2, 24)
	inset:SetWidth(LIST_W + 20)
	tab.listInset = inset
	local headBar = CreateFrame("Frame", nil, inset)
	headBar:SetAllPoints(inset)
	tab.heads, tab.rheads = {}, {}
	for _, h in ipairs({ { "name", L.PCOL_CRAFTER }, { "prof", L.PCOL_PROF }, { "skill", L.PCOL_SKILL },
		{ "spec", L.PCOL_SPEC }, { "recipes", L.PCOL_RECIPES }, { "seen", L.PCOL_SEEN } }) do
		local fs = W.Text(headBar, "GameFontDisableSmall", h[2])
		fs:SetPoint("TOPLEFT", inset, "TOPLEFT", 6 + COL[h[1]][1], -6)
		tab.heads[#tab.heads + 1] = fs
	end
	for _, h in ipairs({ { "rname", L.PCOL_RECIPE }, { "prof", L.PCOL_PROF }, { "crafters", L.PCOL_CRAFTERS } }) do
		local fs = W.Text(headBar, "GameFontDisableSmall", h[2])
		fs:SetPoint("TOPLEFT", inset, "TOPLEFT", 6 + RCOL[h[1]][1], -6)
		tab.rheads[#tab.rheads + 1] = fs
	end

	local area = CreateFrame("Frame", nil, inset)
	area:SetPoint("TOPLEFT", 6, -22)
	area:SetPoint("BOTTOMLEFT", 6, 4)
	area:SetWidth(LIST_W + 12)
	tab.listArea = area
	tab.listHeight = PAGE_H - GH.TOOLBAR_H - 24 - 22 - 4
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
	tab.empty = W.Text(area, "GameFontDisable", L.PROF_EMPTY)
	tab.empty:SetPoint("TOP", 0, -40)
	tab.empty:SetWidth(LIST_W - 40)
	tab.empty:SetWordWrap(true)

	-- right panel: your professions + rare recipes
	local panel = W.Inset(page)
	panel:SetPoint("TOPLEFT", LIST_W + 26, 0)
	panel:SetPoint("BOTTOMRIGHT", -2, 24)
	tab.panel = panel
	local t1 = W.Text(panel, "GameFontNormalLarge", L.PROF_YOURS)
	t1:SetPoint("TOPLEFT", 12, -12)
	tab.own = {}
	for i = 1, 6 do
		local fs = W.Text(panel, "GameFontHighlightSmall")
		fs:SetPoint("TOPLEFT", 14, -36 - (i - 1) * 28)
		fs:SetWidth(200)
		fs:SetWordWrap(true)
		fs:SetHeight(26)
		fs:SetJustifyV("TOP")
		tab.own[i] = fs
	end
	local t2 = W.Text(panel, "GameFontNormalLarge", L.PROF_FEED)
	t2:SetPoint("TOPLEFT", 12, -212)
	tab.feed = {}
	for i = 1, PANEL_LINES do
		local fs = W.Text(panel, "GameFontHighlightSmall")
		fs:SetPoint("TOPLEFT", 14, -236 - (i - 1) * 24)
		fs:SetWidth(200)
		fs:SetWordWrap(true)
		fs:SetHeight(22)
		fs:SetJustifyV("TOP")
		tab.feed[i] = fs
	end

	-- footer
	tab.footer = W.Text(page, "GameFontHighlightSmall")
	tab.footer:SetPoint("BOTTOMLEFT", 8, 8)
	local fr = W.Text(page, "GameFontNormalSmall", L.PROF_FOOTER_RIGHT, "RIGHT")
	fr:SetPoint("BOTTOMRIGHT", page, "BOTTOMLEFT", 8 + LIST_W, 8)
	fr:SetWidth(400)
	tab.footerRight = fr

	-- fair trade (Features.lua): not sharing your professions = only this note, with a Share button
	local lock = W.Inset(page)
	lock:SetPoint("TOPLEFT", 2, 0)
	lock:SetPoint("BOTTOMRIGHT", -2, 24)
	lock.text = W.Text(lock, "GameFontHighlight")
	lock.text:SetPoint("TOP", 0, -150)
	lock.text:SetWidth(520)
	lock.text:SetWordWrap(true)
	lock.text:SetJustifyH("CENTER")
	lock.button = W.Button(lock, L.FAIR_PROF_BUTTON, 200, 26, "GameFontNormal")
	lock.button:SetPoint("TOP", lock.text, "BOTTOM", 0, -16)
	lock.button:SetScript("OnClick", function()
		GH:SetShare("prof", true)
		GH:WantRecipeLists()
		GH:DrawProfessionsTab(true)
	end)
	lock:Hide()
	tab.lock = lock

	page:HookScript("OnHide", function() if tab.popup then tab.popup:Hide() end end)
	-- while shown: online states and "x ago" every 15 s
	page:SetScript("OnUpdate", function(_, elapsed)
		tab.tick = (tab.tick or 0) + elapsed
		if tab.tick >= 15 then
			tab.tick = 0
			GH:DrawProfessionsTab()
		end
	end)
end

-- Tab registry (UI\MainFrame.lua): the second tab, only while the professions feature is on.
GH:RegisterTab({ key = "professions", order = 20, label = "TAB_PROF", sub = "WIN_SUB_PROF", tip = "TAB_TIP_PROF", feature = "prof",
	show = function(gh, page) gh:ShowProfessionsTab(page) end })

-- MainFrame ShowTab("professions"): build once, then draw. First use starts fetching lists.
function GH:ShowProfessionsTab(page)
	if not self.profTab then self:BuildProfessionsTab(page) end
	self:WantRecipeLists()
	self:DrawProfessionsTab(true)
end

function GH:DrawProfessionsTab(toTop)
	local tab = self.profTab
	if not tab then return end
	-- fair trade: locked = only the note (trial accounts get their own reason, and no button)
	local can, why = self:CanUse("prof")
	for _, part in ipairs({ tab.search, tab.filter, tab.online, tab.listInset, tab.panel, tab.footer, tab.footerRight }) do
		part:SetShown(can)
	end
	if tab.lock then
		tab.lock:SetShown(not can)
		if not can then
			tab.lock.text:SetText(self:LockedText("prof", L.FAIR_PROF_LOCKED))
			tab.lock.button:SetShown(why == "off")
			if tab.popup then tab.popup:Hide() end
			return
		end
	end
	local db = self.db.profile
	local filter = db.profFilter
	local valid = false
	for _, k in ipairs(self.PROF_FILTERS) do if k == filter then valid = true end end
	if not valid then filter = "all"; db.profFilter = "all" end
	tab.filter:SetLabel(tab.filter.labelFn())
	tab.online:SetActive(db.profOnline)
	local text = tab.search:GetText() or ""
	local searching = #text >= 2
	local rows
	if searching then
		rows = self:BuildRecipeRows({ search = text, filter = filter, online = db.profOnline })
	else
		rows = self:BuildProfRows({ filter = filter, online = db.profOnline })
	end
	for _, fs in ipairs(tab.heads) do fs:SetShown(not searching) end
	for _, fs in ipairs(tab.rheads) do fs:SetShown(searching) end
	tab.data = rows
	if tab.scrollBox then
		W.SetListData(tab.scrollBox, rows, not toTop)
	else
		if toTop then tab.offset = 0 end
		self:DrawProfRows()
	end
	tab.empty:SetShown(#rows == 0)
	tab.empty:SetText(searching and L.PROF_NO_MATCH or L.PROF_EMPTY)

	local idx = self:ProfIndex()
	local _, all = self:BuildProfRows({}) -- footer counts the whole guild, not the filter
	tab.footer:SetText(L.PROF_FOOTER:format(all, idx.recipes))
	self:DrawProfPanel()
end

function GH:DrawProfRows()
	local tab = self.profTab
	if not (tab and tab.rows) then return end
	for i, r in ipairs(tab.rows) do
		local d = tab.data and tab.data[tab.offset + i]
		r:SetShown(d ~= nil)
		if d then FillRow(r, d) end
	end
end

function GH:DrawProfPanel()
	local tab = self.profTab
	local own = self:OwnProf()
	local i = 0
	if own then
		for _, line in ipairs(self.PROF_ORDER) do
			local e = own.p[line]
			if e and i < #tab.own then
				i = i + 1
				local head = ("%s %s"):format(self:ProfName(line), e.r and (e.m and ("%d/%d"):format(e.r, e.m) or tostring(e.r)) or "")
				local sub
				local kind = self.PROFS[line].kind
				if kind == "gather" or kind == "fish" then
					sub = L.PROF_GATHER
				elseif e.scanned then
					sub = L.PROF_SHARED:format(e.n or 0, U.Ago(U.Now() - e.scanned))
				else
					sub = L.PROF_OPEN_WINDOW
				end
				tab.own[i]:SetText(head .. "\n|cff999999" .. sub .. "|r")
			end
		end
	end
	if i == 0 then
		i = 1
		tab.own[1]:SetText("|cff999999" .. L.PROF_NONE_OWN .. "|r")
	end
	if not self:SharesProfessions() and i < #tab.own then
		i = i + 1
		tab.own[i]:SetText("|cffff9933" .. L.PROF_NOT_SHARING .. "|r")
	end
	for k = i + 1, #tab.own do tab.own[k]:SetText("") end

	local feed = self:FeedLines(#tab.feed)
	for k, fs in ipairs(tab.feed) do
		local e = feed[k]
		if e then
			fs:SetText(L.PROF_FEED_LINE:format(U.ShortName(e.who), self:RecipeName(e.r) or ("#" .. e.r), U.Ago(U.Now() - (e.ts or 0))))
		else
			fs:SetText(k == 1 and ("|cff999999" .. L.PROF_FEED_NONE .. "|r") or "")
		end
	end
end
