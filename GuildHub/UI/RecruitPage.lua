-- Guild Hub: the Members tab (side list; only "Recruiting" for now) and the Recruiting page,
-- the Copy box (/ghub recruit) and the join note. Logic: Features\Recruit.lua.
-- Everybody reads the page; only officers see working edit controls (others see them greyed with
-- the reason). Nothing here sends to chat: Copy only shows text, "Share in guild chat" and
-- "Say welcome" fill the chat box, the post itself is the macro (/ghub ad).
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
	local d = { need = {}, cls = {}, post = p.post and true or false }
	for _, r in ipairs(GH.RECRUIT_ROLES) do d.need[r] = (type(p.need) == "table" and p.need[r]) or 0 end
	for _, c in ipairs(GH.RECRUIT_CLASSES) do d.cls[c] = type(p.cls) == "table" and p.cls[c] or nil end
	return d
end

local function ResetDraft(t)
	local p = GH:RecruitPub()
	local need, cls = GH:RecruitNeeds()
	t.draft = CopyNeeds({ need = need, cls = cls, post = p.post })
	t.draftV = p.v or 0
	t.text:SetText(p.ad or "")
	t.dcBox:SetText(p.dc or "")
	t.dirty = false
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
		end
	end)
	t.dcShow = W.Text(area, "GameFontHighlightSmall", "")
	t.dcShow:SetPoint("LEFT", t.dcLabel, "RIGHT", 10, 0)
	t.dcShow:SetWidth(300)

	t.postTick = W.CheckButton(area, L.REC_POST_TICK, 170)
	t.postTick:SetPoint("TOPLEFT", RIGHT_X - 4, -146)
	t.postTick:SetScript("OnClick", function()
		if not IsOfficerMe() then GH:DrawRecruitPage() return end
		t.draft.post = not t.draft.post
		t.dirty = true
		GH:DrawRecruitPage()
	end)
	Tip(t.postTick, L.REC_POST_TIP)
	t.revert = W.Button(area, L.REC_REVERT, 80, 22)
	t.revert:SetPoint("TOPRIGHT", area, "TOPLEFT", RIGHT_X + TEXT_W - 132, -148)
	t.revert:SetScript("OnClick", function() ResetDraft(t); GH:DrawRecruitPage() end)
	t.share = W.Button(area, L.REC_SHARE, 128, 22)
	t.share:SetPoint("LEFT", t.revert, "RIGHT", 4, 0)
	t.share:SetScript("OnClick", function()
		local ok, why = GH:SaveRecruitPub({ need = t.draft.need, cls = t.draft.cls, post = t.draft.post,
			ad = t.text:GetText(), dc = t.dcBox:GetText() })
		if ok then
			ResetDraft(t)
			GH:Msg(L.REC_SHARED)
		else
			t.lastErr = L["REC_ERR_" .. tostring(why):upper()] or L.REC_ERR_TEXT
			GH:Msg(t.lastErr)
		end
		GH:DrawRecruitPage()
	end)
	Tip(t.share, L.REC_SHARE_TIP)
end

local function BuildButtons(t, area)
	t.copy = W.Button(area, L.REC_COPY, 90, 22)
	t.copy:SetPoint("TOPLEFT", RIGHT_X, -184)
	t.copy:SetScript("OnClick", function() GH:RecruitCopy() end)
	Tip(t.copy, L.REC_COPY_TIP)
	t.guildShare = W.Button(area, L.REC_GUILD_SHARE, 150, 22)
	t.guildShare:SetPoint("LEFT", t.copy, "RIGHT", 6, 0)
	t.guildShare:SetScript("OnClick", function() GH:ShareAdInGuild() end)
	Tip(t.guildShare, L.REC_GUILD_SHARE_TIP)
	t.finder = W.Button(area, L.REC_FINDER, 140, 22)
	t.finder:SetPoint("LEFT", t.guildShare, "RIGHT", 6, 0)
	t.finder:SetScript("OnClick", function()
		if InCombatLockdown() or type(ToggleGuildFinder) ~= "function" then return end
		pcall(ToggleGuildFinder)
	end)
	Tip(t.finder, L.REC_FINDER_TIP)

	-- the macro
	t.macroTitle = Header(area, L.MAC_TITLE, RIGHT_X, -222)
	local drag = CreateFrame("Button", nil, area)
	drag:SetSize(36, 36)
	drag:SetPoint("TOPLEFT", RIGHT_X, -246)
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
	dd:SetPoint("TOPLEFT", RIGHT_X + 48, -250)
	t.channel = dd
	Tip(dd, L.MAC_CHANNEL_TIP)

	t.icons = {}
	for i, name in ipairs(GH.RECRUIT_ICONS) do
		local b = CreateFrame("Button", nil, area)
		b:SetSize(24, 24)
		b:SetPoint("TOPLEFT", RIGHT_X + 190 + (i - 1) * 28, -250)
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

	t.make = W.Button(area, L.MAC_MAKE, 130, 22)
	t.make:SetPoint("TOPLEFT", RIGHT_X, -292)
	t.make:SetScript("OnClick", function()
		local _, msg = GH:MakeRecruitMacro("post")
		GH:Msg(msg)
	end)
	Tip(t.make, L.MAC_MAKE_TIP)
	t.makeCopy = W.Button(area, L.MAC_MAKE_COPY, 150, 22)
	t.makeCopy:SetPoint("LEFT", t.make, "RIGHT", 6, 0)
	t.makeCopy:SetScript("OnClick", function()
		local _, msg = GH:MakeRecruitMacro("copy")
		GH:Msg(msg)
	end)
	Tip(t.makeCopy, L.MAC_MAKE_COPY_TIP)
	t.slots = W.Text(area, "GameFontHighlightSmall", "")
	t.slots:SetPoint("LEFT", t.makeCopy, "RIGHT", 8, 0)
	t.slots:SetWidth(100)
	t.macroHint = W.Text(area, "GameFontDisableSmall", "")
	t.macroHint:SetPoint("TOPLEFT", RIGHT_X, -320)
	t.macroHint:SetWidth(TEXT_W)
	t.status = W.Text(area, "GameFontHighlightSmall", "")
	t.status:SetPoint("TOPLEFT", RIGHT_X, -340)
	t.status:SetWidth(TEXT_W)
	t.status:SetWordWrap(true)
	t.status:SetHeight(28)
	t.status:SetJustifyV("TOP")
	t.note = W.Text(area, "GameFontDisableSmall", "")
	t.note:SetPoint("TOPLEFT", RIGHT_X, -376)
	t.note:SetWidth(TEXT_W)
	t.note:SetWordWrap(true)
	t.note:SetHeight(40)
	t.note:SetJustifyV("TOP")
end

local function BuildMembers(page)
	local t = {}
	GH.recruitTab = t
	t.side = W.SideList(page, { { key = "recruit", label = L.REC_SIDE_RECRUIT } }, function() GH:DrawRecruitPage() end)
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
	t.textOk = not err
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

local function DrawButtons(t)
	local p = GH:RecruitPub()
	local has = p.ad ~= nil
	Greyed(t.copy, not has, L.AD_NO_TEXT)
	local wait = GH:GuildShareWait()
	Greyed(t.guildShare, (not has) or wait > 0, (not has) and L.AD_NO_TEXT or L.AD_SHARE_WAIT:format(math.ceil(wait / 60)))
	local finder = false
	if C_ClubFinder and type(C_ClubFinder.IsEnabled) == "function" and type(ToggleGuildFinder) == "function" then
		local ok, on = pcall(C_ClubFinder.IsEnabled)
		finder = ok and on == true
	end
	t.finder:SetShown(finder)
	Greyed(t.finder, InCombatLockdown(), L.MAC_COMBAT)

	-- the macro
	local set = GH:RecruitMacroSet()
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
	local cst = GH:RecruitMacroState("copy")
	t.makeCopy:SetLabel(cst.exists and (cst.needsUpdate and L.MAC_UPDATE_COPY or L.MAC_READY_COPY) or L.MAC_MAKE_COPY)
	Greyed(t.makeCopy, combat or cst.taken or (cst.exists and not cst.needsUpdate) or (not cst.exists and full),
		combat and L.MAC_COMBAT or (cst.taken and L.MAC_TAKEN) or (cst.exists and L.MAC_READY_TIP) or L.MAC_FULL:format(used or 0, max or 0))
	t.drag:SetAlpha(st.exists and 1 or 0.4)
	if t.drag.icon.SetDesaturated then t.drag.icon:SetDesaturated(not st.exists) end
	t.slots:SetText(used and L.MAC_SLOTS:format(max - used, max) or "")
	t.macroHint:SetText(L.MAC_HINT:format(set.channel))
	t.status:SetText(GH:AdStatusText())
	t.note:SetText(IsOfficerMe() and L.REC_NOTE_OFFICER or L.REC_NOTE_MEMBER)
end

-- Redraws the page if it is on screen.
function GH:DrawRecruitPage()
	local t = self.recruitTab
	local f = self.mainFrame
	if not t or not f or not f.pages.members:IsShown() then return end
	local on = self:FeatureOn("recruit") and IsInGuild()
	t.lock:SetShown(not on)
	t.lock:SetText(on and "" or (IsInGuild() and L.AD_FEATURE_OFF or L.NOT_IN_GUILD))
	t.body:SetShown(on)
	if not on then return end
	local officer = IsOfficerMe()
	if officer and (t.draftV or 0) < (self:RecruitPub().v or 0) and not t.dirty then ResetDraft(t) end
	DrawNeeds(t, officer)
	DrawMakeup(t)
	DrawText(t, officer)
	DrawButtons(t)
end

function GH:ShowMembersTab(page)
	if not page.built then BuildMembers(page) end
	if self.RequestRoster then self:RequestRoster() end
	self:DrawRecruitPage()
end

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
		f:SetSize(460, 210)
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
		t.close = W.TitleButton(t, "close")
		t.close:SetPoint("TOPRIGHT", 2, 2)
		t.close:SetScript("OnClick", function() t:Hide() end)
		t:SetScript("OnUpdate", function(s, elapsed)
			s.left = (s.left or 0) - elapsed
			if s.left <= 0 then s:Hide() end
		end)
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
end

function GH:HideJoinToast()
	if self.joinToast then self.joinToast:Hide() end
end
