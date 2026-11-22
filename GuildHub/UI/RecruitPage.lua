-- Guild Hub: the Recruiting tab (internal key "members"; side list Overview / Officer lists /
-- Suggestions & trials) and its Overview page,
-- the Copy box (/ghub recruit) and the join note. Logic: Features\Recruit.lua.
-- Everybody reads the page; only officers see working edit controls (others see them greyed with
-- the reason). Copy only shows text, "Say welcome" fills the guild chat box; the only thing that
-- sends is the Post in General / Trade click (and the bar button /ghub ad), both through GH:PostAd
-- with every cap (one line per click, nothing from a timer or an event).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local SIDE_W = 160
local LEFT_X, RIGHT_X = 12, 440
local TEXT_W = 400
local ROW_H = 18
local BAR_W = 170
local JOIN_SECONDS = 15

local function IsOfficerMe() return IsInGuild() and GH:IsOfficer(GH:MyName()) end

local function SetColor(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function ClassColor(class)
	local c = C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class)
	if c and c.r then return { c.r, c.g, c.b } end
	local rc = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[class]
	if rc and rc.r then return { rc.r, rc.g, rc.b } end
	return W.COLOR.normal
end

local function ClassName(class)
	local t = type(LOCALIZED_CLASS_NAMES_MALE) == "table" and LOCALIZED_CLASS_NAMES_MALE[class]
	return t or (class:sub(1, 1) .. class:sub(2):lower())
end

local function Greyed(b, off, why)
	if off then b:Disable() else b:Enable() end
	if b.SetGreyed then b:SetGreyed(off) end
	b.whyOff = off and why or nil
end

-- tooltip that also says why a control is greyed
local function Tip(frame, text)
	frame:SetMotionScriptsWhileDisabled(true)
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(type(text) == "function" and text() or text, 1, 1, 1, true)
		if self.whyOff then GameTooltip:AddLine(self.whyOff, 1, 0.5, 0.25, true) end
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Header(parent, text, x, y)
	local fs = W.Text(parent, "GameFontNormal", text)
	fs:SetPoint("TOPLEFT", x, y)
	return fs
end

------------------------------------------------------------------------
-- The draft an officer edits (needs, classes, post switch); text boxes hold the rest
------------------------------------------------------------------------
local function CopyNeeds(p)
	local d = { need = {}, cls = {}, post = p.post and true or false, f = {} }
	for _, r in ipairs(GH.RECRUIT_ROLES) do d.need[r] = (type(p.need) == "table" and p.need[r]) or 0 end
	for _, c in ipairs(GH.RECRUIT_CLASSES) do d.cls[c] = type(p.cls) == "table" and p.cls[c] or nil end
	-- R5: the ad builder's fields (a copy; Features\RecruitAds.lua cleans them on save)
	if type(p.f) == "table" then for k, v in pairs(p.f) do d.f[k] = v end end
	return d
end

local function ResetDraft(t)
	local p = GH:RecruitPub()
	local need, cls = GH:RecruitNeeds()
	t.draft = CopyNeeds({ need = need, cls = cls, post = p.post, f = p.f })
	t.draftV = p.v or 0
	t.text:SetText(p.ad or "")
	t.dcBox:SetText(p.dc or "")
	t.dirty = false
end

-- Saves the whole draft (Overview and Ad builder pages share it). Officers only; nothing is posted.
function GH:SaveRecruitDraft()
	local t = self.recruitTab
	if not t then return false end
	local ok, why = self:SaveRecruitPub({ need = t.draft.need, cls = t.draft.cls, post = t.draft.post,
		ad = t.text:GetText(), dc = t.dcBox:GetText(), f = t.draft.f })
	if ok then
		ResetDraft(t)
		t.lastErr = nil
		self:Msg(L.REC_SHARED)
	else
		t.lastErr = L["REC_ERR_" .. tostring(why):upper()] or L.REC_ERR_TEXT
		self:Msg(t.lastErr)
	end
	self:DrawRecruitPage()
	return ok
end

-- R5 "Use this": the built ad goes into the Overview text box (a draft change, not saved yet).
function GH:UseBuiltAd(text)
	local t = self.recruitTab
	if not t or type(text) ~= "string" then return false end
	t.text:SetText(text)
	t.dirty = true
	t.lastErr = nil
	self:Msg(L.ADB_USED)
	t.side:Select("recruit")
	self:DrawRecruitPage()
	return true
end

------------------------------------------------------------------------
-- Building the page
------------------------------------------------------------------------
local function BuildNeeds(t, area)
	t.needTitle = Header(area, L.REC_NEED_TITLE, LEFT_X, -10)
	t.needBy = W.Text(area, "GameFontDisableSmall", "", "RIGHT")
	t.needBy:SetPoint("TOPRIGHT", area, "TOPLEFT", LEFT_X + TEXT_W, -12)
	t.needBy:SetWidth(260)
	t.roles = {}
	for i, role in ipairs(GH.RECRUIT_ROLES) do
		local x = LEFT_X + (i - 1) * 134
		local r = {}
		r.icon = area:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(16, 16)
		r.icon:SetPoint("TOPLEFT", x, -34)
		r.mark = W.Text(area, "GameFontNormalSmall", "")
		r.mark:SetPoint("CENTER", r.icon, "CENTER")
		W.SetRoleIcon(r.icon, r.mark, role)
		r.label = W.Text(area, "GameFontHighlightSmall", L["REC_ROLE_" .. role:upper()])
		r.label:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
		r.count = W.Text(area, "GameFontNormal", "0")
		r.count:SetPoint("LEFT", r.icon, "RIGHT", 52, 0)
		r.minus = W.Button(area, "-", 22, 20)
		r.minus:SetPoint("LEFT", r.icon, "RIGHT", 70, 0)
		r.plus = W.Button(area, "+", 22, 20)
		r.plus:SetPoint("LEFT", r.minus, "RIGHT", 2, 0)
		for _, b in ipairs({ r.minus, r.plus }) do
			local step = b == r.plus and 1 or -1
			b:SetScript("OnClick", function()
				local d = t.draft
				d.need[role] = math.max(0, math.min(9, (d.need[role] or 0) + step))
				t.dirty = true
				GH:DrawRecruitPage()
			end)
			Tip(b, L.REC_ROLE_TIP)
		end
		t.roles[role] = r
	end
	t.classes = {}
	for i, class in ipairs(GH.RECRUIT_CLASSES) do
		local b = CreateFrame("Button", nil, area)
		b:SetSize(32, 32)
		b:SetPoint("TOPLEFT", LEFT_X + (i - 1) * 43, -62)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		W.SetClassIcon(b.icon, class)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.15)
		b.markTex = b:CreateTexture(nil, "OVERLAY")
		b.markTex:SetSize(14, 14)
		b.markTex:SetPoint("BOTTOMRIGHT", 3, -3)
		b.markText = W.Text(b, "GameFontNormal", "")
		b.markText:SetPoint("BOTTOMRIGHT", 2, -2)
		b.word = W.Text(area, "GameFontHighlightSmall", "", "CENTER")
		b.word:SetPoint("TOP", b, "BOTTOM", 0, -2)
		b.word:SetWidth(42)
		b:SetScript("OnClick", function()
			if not IsOfficerMe() then return end
			local d = t.draft
			d.cls[class] = ((d.cls[class] or 0) + 1) % 3
			if d.cls[class] == 0 then d.cls[class] = nil end
			t.dirty = true
			GH:DrawRecruitPage()
		end)
		Tip(b, function() return ClassName(class) .. (IsOfficerMe() and ("\n" .. L.REC_CLASS_TIP) or "") end)
		b:SetMotionScriptsWhileDisabled(true)
		t.classes[class] = b
	end
	t.classHint = W.Text(area, "GameFontDisableSmall", "")
	t.classHint:SetPoint("TOPLEFT", LEFT_X, -112)
	t.classHint:SetWidth(TEXT_W)
end

local function BuildMakeup(t, area)
	t.makeupTitle = Header(area, L.REC_MAKEUP_TITLE, LEFT_X, -134)
	t.makeupSub = W.Text(area, "GameFontDisableSmall", L.REC_MAKEUP_SUB)
	t.makeupSub:SetPoint("LEFT", t.makeupTitle, "RIGHT", 8, 0)
	t.rows = {}
	for i, class in ipairs(GH.RECRUIT_CLASSES) do
		local y = -156 - (i - 1) * ROW_H
		local r = {}
		r.icon = area:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(14, 14)
		r.icon:SetPoint("TOPLEFT", LEFT_X, y - 2)
		W.SetClassIcon(r.icon, class)
		r.name = W.Text(area, "GameFontHighlightSmall", ClassName(class))
		r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
		r.name:SetWidth(84)
		SetColor(r.name, ClassColor(class))
		local c = ClassColor(class)
		r.bg = area:CreateTexture(nil, "BACKGROUND")
		r.bg:SetColorTexture(0, 0, 0, 0.35)
		r.bg:SetSize(BAR_W, 12)
		r.bg:SetPoint("LEFT", r.icon, "RIGHT", 96, 0)
		r.bar50 = area:CreateTexture(nil, "BORDER")
		r.bar50:SetTexture(W.ART.bar)
		r.bar50:SetVertexColor(c[1], c[2], c[3], 0.35)
		r.bar50:SetHeight(12)
		r.bar50:SetPoint("LEFT", r.bg, "LEFT")
		r.bar60 = area:CreateTexture(nil, "ARTWORK")
		r.bar60:SetTexture(W.ART.bar)
		r.bar60:SetVertexColor(c[1], c[2], c[3], 0.95)
		r.bar60:SetHeight(12)
		r.bar60:SetPoint("LEFT", r.bg, "LEFT")
		r.count = W.Text(area, "GameFontHighlightSmall", "0 / 0")
		r.count:SetPoint("LEFT", r.bg, "RIGHT", 8, 0)
		r.count:SetWidth(60)
		t.rows[class] = r
	end
	t.makeupTotal = W.Text(area, "GameFontDisableSmall", "")
	t.makeupTotal:SetPoint("TOPLEFT", LEFT_X, -156 - #GH.RECRUIT_CLASSES * ROW_H - 6)
	t.makeupTotal:SetWidth(TEXT_W)
end

local function BuildText(t, area)
	t.textTitle = Header(area, L.REC_TEXT_TITLE, RIGHT_X, -10)
	t.textBy = W.Text(area, "GameFontDisableSmall", "", "RIGHT")
	t.textBy:SetPoint("TOPRIGHT", area, "TOPLEFT", RIGHT_X + TEXT_W, -12)
	t.textBy:SetWidth(260)
	local bg = W.Inset(area)
	bg:SetPoint("TOPLEFT", RIGHT_X, -30)
	bg:SetSize(TEXT_W, 66)
	t.textBg = bg
	local e = CreateFrame("EditBox", nil, bg)
	e:SetMultiLine(true)
	e:SetAutoFocus(false)
	e:SetFontObject("ChatFontNormal")
	e:SetMaxLetters(GH.RECRUIT_CAPS.AD_MAX) -- letters (the 255-byte chat limit is checked by CleanAd)
	if e.SetMaxBytes then e:SetMaxBytes(256) end -- 255 bytes + the end byte
	e:SetPoint("TOPLEFT", 8, -6)
	e:SetPoint("BOTTOMRIGHT", -8, 6)
	e:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
	e:SetScript("OnTextChanged", function(s, user)
		if user then
			if not IsOfficerMe() then s:SetText(GH:RecruitPub().ad or "") return end
			t.dirty = true
		end
		GH:UpdateRecruitCounter()
	end)
	t.text = e
	t.counter = W.Text(area, "GameFontHighlightSmall", "", "RIGHT")
	t.counter:SetPoint("TOPRIGHT", bg, "BOTTOMRIGHT", 0, -3)
	t.counter:SetWidth(90)
	t.textErr = W.Text(area, "GameFontHighlightSmall", "")
	t.textErr:SetPoint("TOPLEFT", bg, "BOTTOMLEFT", 0, -3)
	t.textErr:SetWidth(TEXT_W - 96)
	t.textErr:SetTextColor(1, 0.4, 0.3)

	t.dcLabel = W.Text(area, "GameFontNormalSmall", L.REC_DC_LABEL)
	t.dcLabel:SetPoint("TOPLEFT", RIGHT_X, -122)
	t.dcBox = W.EditBox(area, 230, 20, 72, L.REC_DC_HINT)
	t.dcBox:SetPoint("LEFT", t.dcLabel, "RIGHT", 10, 0)
	t.dcBox:HookScript("OnTextChanged", function(s, user)
		if user then
			if not IsOfficerMe() then s:SetText(GH:RecruitPub().dc or "") return end
			t.dirty = true
			if t.unsaved then t.unsaved:Show() end
		end
	end)
	t.dcShow = W.Text(area, "GameFontHighlightSmall", "")
	t.dcShow:SetPoint("LEFT", t.dcLabel, "RIGHT", 10, 0)
	t.dcShow:SetWidth(300)

	t.postTick = W.CheckButton(area, L.REC_POST_TICK, 200)
	t.postTick:SetPoint("TOPLEFT", RIGHT_X - 4, -146)
	t.postTick:SetScript("OnClick", function()
		if not IsOfficerMe() then GH:DrawRecruitPage() return end
		t.draft.post = not t.draft.post
		t.dirty = true
		GH:DrawRecruitPage()
	end)
	Tip(t.postTick, L.REC_POST_TIP)
	t.revert = W.Button(area, L.REC_REVERT, 64, 22)
	t.revert:SetPoint("TOPRIGHT", area, "TOPLEFT", RIGHT_X + TEXT_W - 132, -148)
	t.revert:SetScript("OnClick", function() ResetDraft(t); GH:DrawRecruitPage() end)
	t.share = W.Button(area, L.REC_SHARE, 128, 22)
	t.share:SetPoint("LEFT", t.revert, "RIGHT", 4, 0)
	t.share:SetScript("OnClick", function() GH:SaveRecruitDraft() end)
	Tip(t.share, L.REC_SHARE_TIP)
	-- R5: what the ad is missing (own screen only; officers), on the error line's place
	t.adHint = W.Text(area, "GameFontNormalSmall", "")
	t.adHint:SetPoint("TOPLEFT", bg, "BOTTOMLEFT", 0, -3)
	t.adHint:SetWidth(TEXT_W - 96)
	t.adHint:SetWordWrap(true)
	t.adHint:SetHeight(22)
	t.adHint:SetJustifyV("TOP")
end

-- "Where the ad goes" (the user's rework, 2026-11-19): General / Trade first (Post buttons, the
-- preview, the optional post button for the bar), then Discord / forums (Copy, Guild Finder).
-- Place labels in the colour of that chat (W.ChatColor). Nothing goes to guild chat.
local function BuildButtons(t, area)
	t.whereTitle = Header(area, L.REC_WHERE_TITLE, RIGHT_X, -180)
	t.whereLine = W.Divider(area, 200)
	t.whereLine:SetPoint("LEFT", t.whereTitle, "RIGHT", 8, 0)
	t.unsaved = W.Text(area, "GameFontNormalSmall", L.REC_UNSAVED, "RIGHT")
	t.unsaved:SetPoint("TOPRIGHT", area, "TOPLEFT", RIGHT_X + TEXT_W, -170)
	t.unsaved:SetWidth(150)
	-- General / Trade
	t.whereChannel = W.Text(area, "GameFontNormalSmall", L.REC_WHERE_CHANNEL)
	t.whereChannel:SetPoint("TOPLEFT", RIGHT_X, -200)
	t.whereChannel:SetWidth(TEXT_W)
	t.preview = W.Text(area, "GameFontHighlightSmall", "")
	t.preview:SetPoint("TOPLEFT", RIGHT_X + 8, -216)
	t.preview:SetWidth(TEXT_W - 8)
	t.preview:SetWordWrap(true)
	t.preview:SetHeight(30)
	t.preview:SetJustifyV("TOP")
	t.post = {}
	for i, kind in ipairs({ "general", "trade" }) do
		local b = W.Button(area, kind == "general" and L.REC_POST_GENERAL or L.REC_POST_TRADE, 124, 22)
		b:SetPoint("TOPLEFT", RIGHT_X + (i - 1) * 128, -250)
		-- the send runs inside this click (one click = at most one line; PostAd checks every cap)
		b:SetScript("OnClick", function() GH:PostAd(kind); GH:DrawRecruitPage() end)
		Tip(b, L.REC_POST_BTN_TIP:format(GH.RECRUIT_CHANNELS[kind]))
		t.post[kind] = b
	end
	t.postState = W.Text(area, "GameFontHighlightSmall", "")
	t.postState:SetPoint("LEFT", t.post.trade, "RIGHT", 8, 0)
	t.postState:SetWidth(TEXT_W - 264)
	t.postState:SetWordWrap(true)
	t.postStateHover = CreateFrame("Frame", nil, area)
	t.postStateHover:SetAllPoints(t.postState)
	t.postStateHover:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(GH:AdStatusText(), 1, 1, 1, true)
		GameTooltip:Show()
	end)
	t.postStateHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
	t.postOff = W.Text(area, "GameFontDisableSmall", L.REC_POST_OFF_LINE)
	t.postOff:SetPoint("TOPLEFT", RIGHT_X, -282)
	t.postOff:SetWidth(TEXT_W)

	-- the optional post button for the bar (hidden while posting is off)
	t.macroTitle = W.Text(area, "GameFontNormalSmall", L.MAC_TITLE)
	t.macroTitle:SetPoint("TOPLEFT", RIGHT_X, -282)
	local drag = CreateFrame("Button", nil, area)
	drag:SetSize(30, 30)
	drag:SetPoint("TOPLEFT", RIGHT_X + 2, -300)
	drag.icon = drag:CreateTexture(nil, "ARTWORK")
	drag.icon:SetAllPoints()
	drag.frame = drag:CreateTexture(nil, "OVERLAY")
	drag.frame:SetPoint("TOPLEFT", -4, 4)
	drag.frame:SetPoint("BOTTOMRIGHT", 4, -4)
	if W.HasAtlas(W.ART.macroFrame.atlas) then drag.frame:SetAtlas(W.ART.macroFrame.atlas) else drag.frame:Hide() end
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function() GH:PickupRecruitMacro("post") end)
	drag:SetScript("OnClick", function() GH:PickupRecruitMacro("post") end)
	Tip(drag, L.MAC_DRAG_TIP)
	t.drag = drag

	local function SetChannel(kind)
		GH:RecruitMacroSet().channel = kind
		GH:DrawRecruitPage()
	end
	local dd = W.Dropdown(area, 130)
	if dd then
		dd:SetupMenu(function(_, root)
			for _, kind in ipairs(GH.RECRUIT_KINDS) do
				root:CreateRadio(GH.RECRUIT_CHANNELS[kind], function() return GH:RecruitMacroSet().channel == kind end,
					function() SetChannel(kind) end)
			end
		end)
	else
		dd = W.Button(area, "", 130, 22)
		dd:SetScript("OnClick", function()
			local cur = GH:RecruitMacroSet().channel
			SetChannel(cur == "trade" and "general" or "trade")
		end)
	end
	dd:SetPoint("TOPLEFT", RIGHT_X + 42, -304)
	t.channel = dd
	Tip(dd, L.MAC_CHANNEL_TIP)
	t.make = W.Button(area, L.MAC_MAKE, 140, 22)
	t.make:SetPoint("TOPLEFT", RIGHT_X + 180, -304)
	t.make:SetScript("OnClick", function()
		local _, msg = GH:MakeRecruitMacro("post")
		GH:Msg(msg)
	end)
	Tip(t.make, L.MAC_MAKE_TIP)
	t.slots = W.Text(area, "GameFontHighlightSmall", "")
	t.slots:SetPoint("LEFT", t.make, "RIGHT", 6, 0)
	t.slots:SetWidth(TEXT_W - 326)
	t.slots:SetWordWrap(true)

	t.icons = {}
	for i, name in ipairs(GH.RECRUIT_ICONS) do
		local b = CreateFrame("Button", nil, area)
		b:SetSize(22, 22)
		b:SetPoint("TOPLEFT", RIGHT_X + (i - 1) * 26, -338)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		b.icon:SetTexture(W.IconPath(name))
		b.check = b:CreateTexture(nil, "OVERLAY")
		b.check:SetSize(12, 12)
		b.check:SetPoint("BOTTOMRIGHT", 3, -3)
		b.checkText = W.Text(b, "GameFontNormalSmall", "")
		b.checkText:SetPoint("BOTTOMRIGHT", 2, -2)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.2)
		b:SetScript("OnClick", function()
			GH:RecruitMacroSet().icon = i
			GH:DrawRecruitPage()
		end)
		t.icons[i] = b
	end
	t.macroHint = W.Text(area, "GameFontDisableSmall", "")
	t.macroHint:SetPoint("TOPLEFT", RIGHT_X + 164, -336)
	t.macroHint:SetWidth(TEXT_W - 164)
	t.macroHint:SetWordWrap(true)
	t.macroHint:SetHeight(26)
	t.macroHint:SetJustifyV("TOP")

	-- Discord / forums
	t.whereOutside = W.Text(area, "GameFontNormalSmall", L.REC_WHERE_OUTSIDE)
	t.whereOutside:SetPoint("TOPLEFT", RIGHT_X, -368)
	t.whereOutside:SetWidth(TEXT_W)
	t.copy = W.Button(area, L.REC_COPY, 90, 22)
	t.copy:SetPoint("TOPLEFT", RIGHT_X, -384)
	t.copy:SetScript("OnClick", function() GH:RecruitCopy() end)
	Tip(t.copy, L.REC_COPY_TIP)
	t.finder = W.Button(area, L.REC_FINDER, 140, 22)
	t.finder:SetPoint("LEFT", t.copy, "RIGHT", 6, 0)
	t.finder:SetScript("OnClick", function()
		if InCombatLockdown() or type(ToggleGuildFinder) ~= "function" then return end
		pcall(ToggleGuildFinder)
	end)
	Tip(t.finder, L.REC_FINDER_TIP)
	-- the post status in words (kept for the self-test / tooltip readers) and the 1-2-3 note
	t.status = t.postState
	t.note = W.Text(area, "GameFontDisableSmall", "")
	t.note:SetPoint("TOPLEFT", RIGHT_X, -412)
	t.note:SetWidth(TEXT_W)
	t.note:SetWordWrap(true)
	t.note:SetHeight(28)
	t.note:SetJustifyV("TOP")
end

-- R3: Guild totals (everyone), the rejoined note (officers) and "Suggest from your group" (members)
local GROUP_PICK = 4
local function BuildTotals(t, area)
	t.totalsTitle = Header(area, L.REC_TOTALS_TITLE, LEFT_X, -344)
	t.totals = W.Text(area, "GameFontHighlightSmall", "")
	t.totals:SetPoint("TOPLEFT", LEFT_X, -364)
	t.totals:SetWidth(TEXT_W)
	t.totals:SetWordWrap(true)
	t.totals:SetHeight(28)
	t.totals:SetJustifyV("TOP")
	t.rejoined = W.Text(area, "GameFontDisableSmall", "")
	t.rejoined:SetPoint("TOPLEFT", LEFT_X, -394)
	t.rejoined:SetWidth(TEXT_W)
	t.rejoined:SetWordWrap(true)
	t.rejoined:SetHeight(36)
	t.rejoined:SetJustifyV("TOP")
	t.groupTitle = W.Text(area, "GameFontNormalSmall", L.SUG_GROUP_TITLE)
	t.groupTitle:SetPoint("TOPLEFT", LEFT_X, -394)
	t.groupNone = W.Text(area, "GameFontDisableSmall", L.SUG_GROUP_NONE)
	t.groupNone:SetPoint("TOPLEFT", LEFT_X, -410)
	t.groupNone:SetWidth(TEXT_W)
	t.groupNone:SetWordWrap(true)
	t.groupNone:SetHeight(28)
	t.groupNone:SetJustifyV("TOP")
	t.group = {}
	for i = 1, GROUP_PICK do
		local b = W.Button(area, "", 96, 20)
		b:SetPoint("TOPLEFT", LEFT_X + (i - 1) * 100, -410)
		b:SetScript("OnClick", function(self)
			if self.pick then GH:SuggestToOfficers(self.pick.name, self.pick.k, self.pick.ro) end
		end)
		Tip(b, L.SUG_GROUP_TIP)
		t.group[i] = b
	end
end

local function BuildMembers(page)
	local t = {}
	GH.recruitTab = t
	-- everyone: Overview, New members (R6); officers: Ad builder (R5), Officer lists (R2), Suggestions & trials (R3)
	t.side = W.SideList(page, { { key = "recruit", label = L.REC_SIDE_RECRUIT }, { key = "newmem", label = L.REC_SIDE_NEWMEM },
		{ key = "adbuild", label = L.REC_SIDE_ADBUILD }, { key = "officer", label = L.REC_SIDE_OFFICER },
		{ key = "trials", label = L.REC_SIDE_TRIALS } },
		function() GH:DrawRecruitPage() end)
	t.side:SetPoint("TOPLEFT", 2, 0)
	t.side:SetPoint("BOTTOMLEFT", 2, 2)
	t.side:SetWidth(SIDE_W)
	t.side:Select("recruit")
	local area = W.Inset(page)
	area:SetPoint("TOPLEFT", t.side, "TOPRIGHT", 4, 0)
	area:SetPoint("BOTTOMRIGHT", -2, 2)
	t.area = area
	-- everything of the page sits on one frame, hidden as a whole when the page can't be used
	local body = CreateFrame("Frame", nil, area)
	body:SetAllPoints(area)
	t.body = body
	BuildNeeds(t, body)
	BuildMakeup(t, body)
	BuildText(t, body)
	BuildButtons(t, body)
	BuildTotals(t, body)
	-- R2: the officers' lists (UI\RecruitOffPage.lua), a second body on the same area
	if GH.BuildOfficerPage then GH:BuildOfficerPage(t, area) end
	-- R5 / R6: the Ad builder (UI\RecruitAdPage.lua) and New members (UI\RecruitBuddyPage.lua)
	if GH.BuildAdPage then GH:BuildAdPage(t, area) end
	if GH.BuildBuddyPage then GH:BuildBuddyPage(t, area) end
	t.lock = W.Text(area, "GameFontNormal", "", "CENTER")
	t.lock:SetPoint("CENTER")
	t.lock:SetWidth(500)
	t.lock:SetWordWrap(true)
	ResetDraft(t)
	-- the post status and wait times change by themselves: redraw every 15 s while shown
	local since = 0
	page:SetScript("OnUpdate", function(_, elapsed)
		since = since + elapsed
		if since >= 15 then
			since = 0
			GH:DrawRecruitPage()
		end
	end)
	page.built = true
	return t
end

------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------
function GH:UpdateRecruitCounter()
	local t = self.recruitTab
	if not t then return end
	local s = t.text:GetText() or ""
	local max = self.RECRUIT_CAPS.AD_MAX
	t.counter:SetText(("%d / %d"):format(self.AdLetters(s), max)) -- letters, not bytes
	local err
	if s:match("%S") then
		local ok, why = self:CleanAd(s)
		if not ok then err = L["REC_ERR_" .. tostring(why):upper()] or L.REC_ERR_TEXT end
	end
	t.textErr:SetText(err or t.lastErr or "")
	if t.unsaved then t.unsaved:SetShown(t.dirty == true and IsOfficerMe()) end
	t.textOk = not err
	-- R5: hints for officers while the error line is empty (own screen only, nothing is sent)
	if t.adHint then
		local miss = (IsOfficerMe() and not err and not t.lastErr and self.AdHints and t.draft) and self:AdHints(t.draft.f) or {}
		t.adHint:SetText(#miss > 0 and L.ADB_HINTS:format(table.concat(miss, ", ")) or "")
		t.adHint:SetShown(#miss > 0)
	end
end

local function DrawNeeds(t, officer)
	local p = GH:RecruitPub()
	local need, cls, by, ts = GH:RecruitNeeds()
	local d = officer and t.draft or CopyNeeds({ need = need, cls = cls })
	if by then
		local left = math.max(0, (p.exp or 0) - U.Now())
		t.needBy:SetText(L.REC_SET_BY:format(U.ShortName(by), U.Ago(U.Now() - (ts or 0)), math.ceil(left / 86400)))
	else
		t.needBy:SetText(L.REC_NOT_SET)
	end
	for _, role in ipairs(GH.RECRUIT_ROLES) do
		local r = t.roles[role]
		local n = d.need[role] or 0
		r.count:SetText(tostring(n))
		if n > 0 then SetColor(r.count, W.COLOR.green) else SetColor(r.count, W.COLOR.gray) end
		r.minus:SetShown(officer)
		r.plus:SetShown(officer)
	end
	for _, class in ipairs(GH.RECRUIT_CLASSES) do
		local b = t.classes[class]
		local state = d.cls[class]
		W.SetMarkIcon(b.markTex, b.markText, state)
		b.word:SetText(state == 1 and L.REC_WANTED or (state == 2 and L.REC_CLOSED or ""))
		if state == 1 then SetColor(b.word, W.COLOR.green) elseif state == 2 then b.word:SetTextColor(1, 0.4, 0.3) end
		if b.icon.SetDesaturated then b.icon:SetDesaturated(state == 2) end
	end
	t.classHint:SetText(officer and L.REC_CLASS_HINT or "")
end

local function DrawMakeup(t)
	local m, total = GH:RecruitMakeup()
	local max = 1
	for _, c in ipairs(GH.RECRUIT_CLASSES) do max = math.max(max, m[c][2]) end
	for _, class in ipairs(GH.RECRUIT_CLASSES) do
		local r, v = t.rows[class], m[class]
		local w50 = math.floor(BAR_W * v[2] / max + 0.5)
		local w60 = math.floor(BAR_W * v[1] / max + 0.5)
		r.bar50:SetWidth(math.max(1, w50))
		r.bar50:SetShown(w50 > 0)
		r.bar60:SetWidth(math.max(1, w60))
		r.bar60:SetShown(w60 > 0)
		r.count:SetText(("%d / %d"):format(v[1], v[2]))
	end
	t.makeupTotal:SetText(L.REC_MAKEUP_TOTAL:format(total))
end

local function DrawText(t, officer)
	local p = GH:RecruitPub()
	if not t.text:HasFocus() and not t.dirty then
		t.text:SetText(p.ad or "")
		t.dcBox:SetText(p.dc or "")
	end
	if p.by and p.v then
		t.textBy:SetText(L.REC_TEXT_BY:format(p.v, U.ShortName(p.by), U.Ago(U.Now() - (p.ts or 0))))
	else
		t.textBy:SetText("")
	end
	t.text:EnableMouse(officer)
	if not officer then t.text:ClearFocus() end
	t.dcBox:SetShown(officer)
	t.dcShow:SetShown(not officer)
	t.dcShow:SetText(p.dc and L.REC_DC_SET or L.REC_DC_NONE)
	GH:UpdateRecruitCounter()
	t.counter:SetShown(officer)
	if not officer then t.textErr:SetText("") end
	t.postTick:SetActive((officer and t.draft.post) or (not officer and p.post) or false)
	Greyed(t.postTick, not officer, L.REC_OFFICERS_ONLY)
	t.revert:SetShown(officer)
	t.share:SetShown(officer)
	Greyed(t.share, t.textOk == false, L.REC_ERR_TEXT)
	if t.dirty then t.share:SetActive(true) else t.share:SetActive(false) end
end

local function SetColorT(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function DrawButtons(t, officer)
	local p = GH:RecruitPub()
	local has = p.ad ~= nil
	local chan = W.ChatColor("CHANNEL1")
	SetColorT(t.whereChannel, chan)
	SetColorT(t.whereOutside, W.COLOR.highlight)
	-- preview: how the line reads in chat
	local set = GH:RecruitMacroSet()
	t.preview:SetText(has and L.REC_PREVIEW:format(GH.RECRUIT_CHANNELS[set.channel], U.ShortName(GH:MyName()), p.ad) or L.REC_PREVIEW_NONE)
	SetColorT(t.preview, has and chan or W.COLOR.gray)
	t.unsaved:SetShown(officer and t.dirty == true)

	-- Post buttons: greyed with the reason while capped (PostAd checks everything again on the click)
	local state, ready = GH:AdShortStatus()
	t.postState:SetText(state)
	if ready then SetColorT(t.postState, W.COLOR.green) else SetColorT(t.postState, W.COLOR.normal) end
	for kind, b in pairs(t.post) do
		local why, _, _, note = GH:AdBlockReason(kind)
		if note then why = nil end -- the first click shows the one-time note
		Greyed(b, why ~= nil, why and (why:sub(1, 1):upper() .. why:sub(2)))
	end

	-- the optional post button for the bar: only while posting is on
	local postOn = p.post and true or false
	t.postOff:SetShown(not postOn)
	for _, f in ipairs({ t.macroTitle, t.drag, t.channel, t.make, t.slots, t.macroHint }) do f:SetShown(postOn) end
	for _, b in ipairs(t.icons) do b:SetShown(postOn) end
	if postOn then
		t.drag.icon:SetTexture(W.IconPath(GH.RECRUIT_ICONS[set.icon]))
		t.channel:SetLabel(L.MAC_CHANNEL:format(GH.RECRUIT_CHANNELS[set.channel]))
		for i, b in ipairs(t.icons) do
			W.SetMarkIcon(b.check, b.checkText, i == set.icon and 1 or nil)
		end
		local st = GH:RecruitMacroState("post")
		local combat = InCombatLockdown()
		local used, max = GH:MacroSlots()
		local full = used and max and used >= max
		if st.taken then
			t.make:SetLabel(L.MAC_MAKE)
			Greyed(t.make, true, L.MAC_TAKEN)
		elseif st.exists then
			t.make:SetLabel(st.needsUpdate and L.MAC_UPDATE or L.MAC_READY)
			Greyed(t.make, combat or not st.needsUpdate, combat and L.MAC_COMBAT or L.MAC_READY_TIP)
		else
			t.make:SetLabel(L.MAC_MAKE)
			Greyed(t.make, combat or full, combat and L.MAC_COMBAT or L.MAC_FULL:format(used or 0, max or 0))
		end
		t.drag:SetAlpha(st.exists and 1 or 0.4)
		if t.drag.icon.SetDesaturated then t.drag.icon:SetDesaturated(not st.exists) end
		t.slots:SetText(used and L.MAC_SLOTS:format(max - used, max) or "")
		t.macroHint:SetText(L.MAC_HINT:format(set.channel))
	end

	-- Discord / forums
	Greyed(t.copy, not has, L.AD_NO_TEXT)
	local finder = false
	if C_ClubFinder and type(C_ClubFinder.IsEnabled) == "function" and type(ToggleGuildFinder) == "function" then
		local ok, on = pcall(C_ClubFinder.IsEnabled)
		finder = ok and on == true
	end
	t.finder:SetShown(finder)
	Greyed(t.finder, InCombatLockdown(), L.MAC_COMBAT)
	t.note:SetText(officer and L.REC_NOTE_OFFICER or L.REC_NOTE_MEMBER)
end

-- R3: totals for everyone; officers see who came back, members get the group pick.
local function DrawTotals(t, officer)
	local s = GH:RecruitTotals()
	if s.joined or s.avg then
		t.totals:SetText(L.REC_TOTALS:format(tostring(s.joined or "?"), tostring(s.stay or "?"),
			s.avg and ("%.1f"):format(s.avg) or "?"))
	else
		t.totals:SetText(L.REC_TOTALS_OFF)
	end
	t.rejoined:SetShown(officer)
	if officer then
		local lines = {}
		for _, r in ipairs(GH:RecruitRejoins()) do
			lines[#lines + 1] = L.REC_REJOINED:format(U.ShortName(r.name), date("%d %b", r.left))
		end
		t.rejoined:SetText(table.concat(lines, "  "))
	end
	local picks = officer and {} or GH:GroupPickNames()
	t.groupTitle:SetShown(not officer)
	t.groupNone:SetShown(not officer and #picks == 0)
	for i, b in ipairs(t.group) do
		local p = picks[i]
		b.pick = p
		b:SetShown(p ~= nil)
		if p then
			b:SetLabel(U.ShortName(p.name))
			Greyed(b, GH:SuggestBlock(p.name) ~= nil, GH:SuggestBlock(p.name))
		end
	end
end

-- Redraws the page if it is on screen.
function GH:DrawRecruitPage()
	local t = self.recruitTab
	local f = self.mainFrame
	if not t or not f or not f.pages.members:IsShown() then return end
	local on = self:FeatureOn("recruit") and IsInGuild()
	t.lock:SetShown(not on)
	t.lock:SetText(on and "" or (IsInGuild() and L.AD_FEATURE_OFF or L.NOT_IN_GUILD))
	local officer = IsOfficerMe()
	-- R2: the side list's "Officer lists" only for officers
	-- R3: and "Suggestions & trials"; R5: and "Ad builder". R6: "New members" for everyone.
	for _, key in ipairs({ "officer", "trials", "adbuild" }) do
		if t.side.buttons[key] then t.side.buttons[key]:SetShown(on and officer) end
		if t.side.selected == key and not (on and officer) then t.side:Select("recruit") end
	end
	if t.side.buttons.newmem then t.side.buttons.newmem:SetShown(on) end
	local sel = t.side.selected
	local offPage = on and (sel == "officer" or sel == "trials")
	local adPage = on and sel == "adbuild" and t.adBody ~= nil
	local budPage = on and sel == "newmem" and t.budBody ~= nil
	t.body:SetShown(on and not offPage and not adPage and not budPage)
	if t.offBody then t.offBody:SetShown(offPage) end
	if t.off2Body and not offPage then t.off2Body:Hide() end
	if t.adBody then t.adBody:SetShown(adPage) end
	if t.budBody then t.budBody:SetShown(budPage) end
	if on and officer and (t.draftV or 0) < (self:RecruitPub().v or 0) and not t.dirty then ResetDraft(t) end
	if offPage then return self:DrawOfficerPage() end
	if adPage then return self:DrawAdPage() end
	if budPage then return self:DrawBuddyPage() end
	if not on then return end
	DrawNeeds(t, officer)
	DrawMakeup(t)
	DrawText(t, officer)
	DrawButtons(t, officer)
	DrawTotals(t, officer)
end

function GH:ShowMembersTab(page)
	if not page.built then BuildMembers(page) end
	if self.RequestRoster then self:RequestRoster() end
	self:DrawRecruitPage()
end

-- Tab registry (UI\MainFrame.lua): the Recruiting tab (key "members"), after the Map tab.
GH:RegisterTab({ key = "members", order = 40, label = "TAB_MEMBERS", sub = "WIN_SUB_MEMBERS", tip = "TAB_TIP_MEMBERS", feature = "recruit",
	show = function(gh, page) gh:ShowMembersTab(page) end })

------------------------------------------------------------------------
-- The Copy box (/ghub recruit): the text, and the Discord invite with who set it. Read-only.
------------------------------------------------------------------------
local function ReadOnly(e, get)
	e:HookScript("OnTextChanged", function(s, user)
		if user then s:SetText(get() or ""); s:HighlightText() end
	end)
	e:HookScript("OnEscapePressed", function() GH.recruitCopyBox:Hide() end)
	e:HookScript("OnEditFocusGained", function(s) s:HighlightText() end)
end

function GH:ShowRecruitCopyBox()
	local f = self.recruitCopyBox
	if not f then
		f = W.Popup("GuildHubRecruitCopy", UIParent, 0.97)
		f:SetSize(460, 400)
		f:SetPoint("CENTER", 0, 80)
		f:SetFrameStrata("DIALOG")
		f:EnableMouse(true)
		f:SetMovable(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		tinsert(UISpecialFrames, "GuildHubRecruitCopy")
		f.title = W.Text(f, "GameFontNormal", L.COPY_TITLE)
		f.title:SetPoint("TOPLEFT", 14, -12)
		f.close = W.TitleButton(f, "close")
		f.close:SetPoint("TOPRIGHT", 2, 2)
		f.close:SetScript("OnClick", function() f:Hide() end)
		local bg = W.Inset(f)
		bg:SetPoint("TOPLEFT", 12, -34)
		bg:SetPoint("TOPRIGHT", -12, -34)
		bg:SetHeight(76)
		f.textBg = bg
		local e = CreateFrame("EditBox", nil, bg)
		e:SetMultiLine(true)
		e:SetAutoFocus(false)
		e:SetFontObject("ChatFontNormal")
		e:SetPoint("TOPLEFT", 8, -6)
		e:SetPoint("BOTTOMRIGHT", -8, 6)
		ReadOnly(e, function() return GH:RecruitPub().ad end)
		f.text = e
		f.hint = W.Text(f, "GameFontHighlightSmall", L.COPY_HINT)
		f.hint:SetPoint("TOPLEFT", bg, "BOTTOMLEFT", 2, -4)
		f.dcLabel = W.Text(f, "GameFontNormalSmall", L.REC_DC_LABEL)
		f.dcLabel:SetPoint("TOPLEFT", bg, "BOTTOMLEFT", 2, -26)
		f.dc = W.EditBox(f, 250, 20, 80)
		f.dc:SetPoint("LEFT", f.dcLabel, "RIGHT", 10, 0)
		ReadOnly(f.dc, function() return GH:RecruitPub().dc end)
		f.dcBy = W.Text(f, "GameFontDisableSmall", "")
		f.dcBy:SetPoint("TOPLEFT", f.dcLabel, "BOTTOMLEFT", 0, -8)
		f.dcBy:SetWidth(420)
		-- R5: the long post (fields, We need, the ad, the Discord invite; no member names). Read-only.
		f.longTitle = W.Text(f, "GameFontNormalSmall", L.COPY_LONG)
		f.longTitle:SetPoint("TOPLEFT", 14, -184)
		local lbg = W.Inset(f)
		lbg:SetPoint("TOPLEFT", 12, -200)
		lbg:SetPoint("TOPRIGHT", -12, -200)
		lbg:SetHeight(160)
		f.longBg = lbg
		-- a long post can be taller than the box: the mouse wheel scrolls it
		local sf = CreateFrame("ScrollFrame", nil, lbg)
		sf:SetPoint("TOPLEFT", 8, -6)
		sf:SetPoint("BOTTOMRIGHT", -8, 6)
		sf:EnableMouseWheel(true)
		sf:SetScript("OnMouseWheel", function(s, delta)
			local range = s:GetVerticalScrollRange() or 0
			s:SetVerticalScroll(math.max(0, math.min(range, (s:GetVerticalScroll() or 0) - delta * 28)))
		end)
		f.longScroll = sf
		local le = CreateFrame("EditBox", nil, sf)
		le:SetMultiLine(true)
		le:SetAutoFocus(false)
		le:SetFontObject("ChatFontNormal")
		le:SetWidth(420)
		le:SetHeight(150)
		sf:SetScrollChild(le)
		ReadOnly(le, function() return GH.BuildLongPost and GH:BuildLongPost() or "" end)
		f.long = le
		f.ok = W.Button(f, L.COPY_CLOSE, 90, 22)
		f.ok:SetPoint("BOTTOMRIGHT", -12, 10)
		f.ok:SetScript("OnClick", function() f:Hide() end)
		self.recruitCopyBox = f
	end
	local p = self:RecruitPub()
	f.text:SetText(p.ad or L.AD_NO_TEXT)
	f.dc:SetText(p.dc or "")
	f.dc:SetShown(p.dc ~= nil)
	f.dcBy:SetText(p.dc and L.COPY_DC_BY:format(U.ShortName(p.dcBy), U.Ago(U.Now() - (p.dcTs or 0))) or L.REC_DC_NONE)
	f.long:SetText(self.BuildLongPost and self:BuildLongPost() or "")
	f:Show()
	f.text:SetFocus()
	f.text:HighlightText()
end

------------------------------------------------------------------------
-- The join note: "Bob joined the guild. Thanks to Mira." + Say welcome (fills the guild chat box
-- once per join). 15 s, no sound, never takes the keyboard.
------------------------------------------------------------------------
function GH:ShowJoinToast(name)
	local t = self.joinToast
	if not t then
		t = W.Popup("GuildHubJoinToast", UIParent, 0.94)
		t:SetSize(380, 74)
		t:SetPoint("TOP", UIParent, "TOP", 0, -220)
		t:SetFrameStrata("DIALOG") -- above the main window (HIGH)
		local icon = t:CreateTexture(nil, "ARTWORK")
		icon:SetTexture(W.ART.toastIcon)
		icon:SetSize(16, 16)
		icon:SetPoint("TOPLEFT", 10, -8)
		t.icon = icon
		t.title = W.Text(t, "GameFontNormal", L.JOIN_TITLE)
		t.title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
		t.text = W.Text(t, "GameFontHighlight")
		t.text:SetPoint("TOPLEFT", 10, -28)
		t.text:SetPoint("RIGHT", -10, 0)
		t.welcome = W.Button(t, L.JOIN_SAY, 110, 22)
		t.welcome:SetPoint("BOTTOMLEFT", 10, 8)
		t.welcome:SetScript("OnClick", function()
			GH:SayWelcome(t.name)
			GH:UpdateJoinToast()
		end)
		-- R6 (officers): opens Recruiting > New members, where the buddy is picked (nothing sent here)
		t.buddy = W.Button(t, L.JOIN_BUDDY, 110, 22)
		t.buddy:SetPoint("LEFT", t.welcome, "RIGHT", 6, 0)
		t.buddy:SetScript("OnClick", function()
			t:Hide()
			GH:OpenRecruitPage("newmem")
		end)
		W.Tooltip(t.buddy, L.JOIN_BUDDY_TIP)
		t.close = W.TitleButton(t, "close")
		t.close:SetPoint("TOPRIGHT", 2, 2)
		t.close:SetScript("OnClick", function() t:Hide() end)
		t:SetScript("OnUpdate", function(s, elapsed)
			s.left = (s.left or 0) - elapsed
			if s.left <= 0 then s:Hide() end
		end)
		-- 1.0.0-beta.1: drawn by the one queue (UI\Toasts.lua); closing it shows the next note
		t:SetScript("OnHide", function() if GH.ToastNext then GH:ToastNext() end end)
		self.joinToast = t
	end
	t.name = name
	t.left = JOIN_SECONDS
	self:UpdateJoinToast()
	t:Show()
end

function GH:UpdateJoinToast()
	local t = self.joinToast
	if not t or not t.name then return end
	local j = self.recentJoins and self.recentJoins[t.name]
	local text = L.JOIN_TEXT:format(U.ShortName(t.name))
	if j and j.by then text = text .. " " .. L.JOIN_THANKS:format(j.by) end
	t.text:SetText(text)
	local can = self:CanSayWelcome(t.name)
	if can then t.welcome:Enable() else t.welcome:Disable() end
	if t.welcome.SetGreyed then t.welcome:SetGreyed(not can) end
	if t.buddy then t.buddy:SetShown(IsOfficerMe() and InCombatLockdown() ~= true) end
end

-- Opens the main window on the Recruiting tab at one side page (a click; nothing is sent).
function GH:OpenRecruitPage(key)
	if InCombatLockdown() then return end
	if self.miniFrame and self.miniFrame:IsShown() then self.miniFrame:Hide() end
	local f = self:CreateMainFrame()
	if not (f.tabs and f.tabs.members) then return end
	f:Show()
	self:ShowTab("members")
	local t = self.recruitTab
	if t and t.side and key then
		t.side:Select(key)
		self:DrawRecruitPage()
	end
end

function GH:HideJoinToast()
	if self.joinToast then self.joinToast:Hide() end
end
