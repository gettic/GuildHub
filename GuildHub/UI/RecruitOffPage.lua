-- Guild Hub: the Recruiting tab's "Officer lists" page (Guild Recruiter R2; officers only).
-- Prospects (name, status, date, who, Invite, Remove) and Don't invite (name, date, who, Remove),
-- each with Clear (click twice). Players are added with a right-click on their name.
-- R3: a second page, "Suggestions & trials": Suggestions from members (+ Prospect, remove) and
-- Trials (end date, "ended: promote?" in orange, +7 d, end). A reminder only: nothing promotes.
-- Logic: Features\RecruitOff.lua. Nothing here sends by itself: every change is a click.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local ROW_H = 22
local ROWS = 15
local PROS_X, PROS_W = 12, 560
local DNI_X, DNI_W = 596, 250
local SUG_X, SUG_W = 12, 470     -- R3 page: Suggestions
local TRIAL_X, TRIAL_W = 506, 340 -- R3 page: Trials
local EMPTY = { p = "OFF_PROS_EMPTY", d = "OFF_DNI_EMPTY", g = "OFF_SUG_EMPTY", t = "OFF_TRIAL_EMPTY" }
local TOP = -34
local CLEAR_CONFIRM = 5 -- seconds the "Click again to clear" stays

local function SetColor(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function MakeRow(parent, x, w, y, prospect)
	local r = CreateFrame("Frame", nil, parent)
	r:SetSize(w, ROW_H)
	r:SetPoint("TOPLEFT", x, y)
	r.hl = W.RowHighlight(r)
	r.hl:SetAlpha(0.35)
	r.name = W.Text(r, "GameFontHighlight", "")
	r.name:SetPoint("LEFT", 4, 0)
	r.name:SetWidth(prospect and 190 or 130)
	r.name:SetWordWrap(false)
	if prospect then
		r.status = W.Button(r, "", 92, 20)
		r.status:SetPoint("LEFT", 198, 0)
		r.status:SetScript("OnClick", function() GH:NextProspectStatus(r.key) end)
		W.Tooltip(r.status, L.OFF_STATUS_TIP)
		r.invite = W.Button(r, L.OFF_INVITE, 70, 20)
		r.invite:SetPoint("RIGHT", -28, 0)
		r.invite:SetMotionScriptsWhileDisabled(true)
		r.invite:SetScript("OnClick", function() GH:GuildInvite(r.key) end)
		r.invite:HookScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(L.OFF_INVITE_TIP, 1, 1, 1, true)
			if self.whyOff then GameTooltip:AddLine(self.whyOff, 1, 0.5, 0.25, true) end
			GameTooltip:Show()
		end)
		r.invite:HookScript("OnLeave", function() GameTooltip:Hide() end)
	end
	r.when = W.Text(r, "GameFontDisableSmall", "")
	r.when:SetPoint("LEFT", prospect and 296 or 138, 0)
	r.when:SetWidth(prospect and 150 or 80)
	r.when:SetWordWrap(false)
	r.remove = W.TitleButton(r, "close", 20)
	r.remove:SetPoint("RIGHT", -2, 0)
	r.remove:SetScript("OnClick", function()
		if prospect then GH:RemoveProspect(r.key) else GH:SetDontInvite(r.key, false) end
	end)
	W.Tooltip(r.remove, L.OFF_REMOVE_TIP)
	return r
end

local function MakeList(_, body, l, x, w, title, rowFn)
	local box = {}
	box.l = l
	box.title = W.Text(body, "GameFontNormal", title)
	box.title:SetPoint("TOPLEFT", x, -10)
	box.inset = W.Inset(body)
	box.inset:SetPoint("TOPLEFT", x - 4, TOP + 2)
	box.inset:SetSize(w + 8, ROWS * ROW_H + 6)
	box.rows = {}
	for i = 1, ROWS do
		local y = TOP - (i - 1) * ROW_H
		box.rows[i] = rowFn and rowFn(body, x, w, y) or MakeRow(body, x, w, y, l == "p")
	end
	box.empty = W.Text(body, "GameFontDisable", L[EMPTY[l]], "CENTER")
	box.empty:SetPoint("TOP", box.inset, "TOP", 0, -40)
	box.empty:SetWidth(w - 20)
	box.more = W.Text(body, "GameFontDisableSmall", "")
	box.more:SetPoint("TOPLEFT", box.inset, "BOTTOMLEFT", 4, -4)
	box.clear = W.Button(body, L.OFF_CLEAR, 120, 22)
	box.clear:SetPoint("TOPRIGHT", box.inset, "BOTTOMRIGHT", 0, -2)
	box.clear:SetScript("OnClick", function(b)
		if b.armedAt and GetTime() - b.armedAt < CLEAR_CONFIRM then
			b.armedAt = nil
			GH:ClearOffList(l)
		else
			b.armedAt = GetTime()
			-- the countdown on the button: redraw once a second while it is armed
			for s = 1, CLEAR_CONFIRM do C_Timer.After(s, function() GH:DrawRecruitPage() end) end
		end
		GH:DrawRecruitPage()
	end)
	W.Tooltip(box.clear, L.OFF_CLEAR_TIP)
	box.offset = 0
	box.inset:EnableMouseWheel(true)
	box.inset:SetScript("OnMouseWheel", function(_, delta)
		box.offset = math.max(0, box.offset - delta * 3)
		GH:DrawOfficerPage()
	end)
	return box
end

-- R3: a Suggestions row (name in class colour, class/role, "N ago · from X", + Prospect, X)
local function MakeSugRow(parent, x, w, y)
	local r = CreateFrame("Frame", nil, parent)
	r:SetSize(w, ROW_H)
	r:SetPoint("TOPLEFT", x, y)
	r.hl = W.RowHighlight(r)
	r.hl:SetAlpha(0.35)
	r.name = W.Text(r, "GameFontHighlight", "")
	r.name:SetPoint("LEFT", 4, 0)
	r.name:SetWidth(140)
	r.name:SetWordWrap(false)
	r.tag = W.Text(r, "GameFontHighlightSmall", "")
	r.tag:SetPoint("LEFT", 150, 0)
	r.tag:SetWidth(96)
	r.tag:SetWordWrap(false)
	r.when = W.Text(r, "GameFontDisableSmall", "")
	r.when:SetPoint("LEFT", 250, 0)
	r.when:SetWidth(104)
	r.when:SetWordWrap(false)
	r.pros = W.Button(r, L.OFF_SUG_PROS, 84, 20)
	r.pros:SetPoint("RIGHT", -28, 0)
	r.pros:SetScript("OnClick", function() GH:SuggestionToProspect(r.key) end)
	W.Tooltip(r.pros, L.OFF_SUG_PROS_TIP)
	r.remove = W.TitleButton(r, "close", 20)
	r.remove:SetPoint("RIGHT", -2, 0)
	r.remove:SetScript("OnClick", function() GH:RemoveSuggestion(r.key) end)
	W.Tooltip(r.remove, L.OFF_REMOVE_TIP)
	return r
end

-- R3: a Trials row (name, "ends in 5 d" / "ended 2 d ago: promote?", +7 d, X)
local function MakeTrialRow(parent, x, w, y)
	local r = CreateFrame("Frame", nil, parent)
	r:SetSize(w, ROW_H)
	r:SetPoint("TOPLEFT", x, y)
	r.hl = W.RowHighlight(r)
	r.hl:SetAlpha(0.35)
	r.name = W.Text(r, "GameFontHighlight", "")
	r.name:SetPoint("LEFT", 4, 0)
	r.name:SetWidth(110)
	r.name:SetWordWrap(false)
	r.when = W.Text(r, "GameFontHighlightSmall", "")
	r.when:SetPoint("LEFT", 118, 0)
	r.when:SetWidth(150)
	r.when:SetWordWrap(false)
	r.extend = W.Button(r, L.OFF_TRIAL_EXTEND, 44, 20)
	r.extend:SetPoint("RIGHT", -28, 0)
	r.extend:SetScript("OnClick", function() GH:SetTrial(r.key, 7, true) end)
	W.Tooltip(r.extend, L.OFF_TRIAL_EXTEND_TIP)
	r.remove = W.TitleButton(r, "close", 20)
	r.remove:SetPoint("RIGHT", -2, 0)
	r.remove:SetScript("OnClick", function() GH:EndTrial(r.key) end)
	W.Tooltip(r.remove, L.OFF_TRIAL_END_TIP)
	return r
end

local function Hint(body, w)
	local h = W.Text(body, "GameFontDisableSmall", "")
	h:SetPoint("TOPLEFT", PROS_X, TOP - ROWS * ROW_H - 34)
	h:SetWidth(w)
	h:SetWordWrap(true)
	h:SetJustifyV("TOP")
	h:SetHeight(44)
	return h
end

function GH:BuildOfficerPage(t, area)
	local body = CreateFrame("Frame", nil, area)
	body:SetAllPoints(area)
	body:Hide()
	t.offBody = body
	t.pros = MakeList(t, body, "p", PROS_X, PROS_W, L.OFF_PROS_TITLE)
	t.dni = MakeList(t, body, "d", DNI_X, DNI_W, L.OFF_DNI_TITLE)
	t.offHint = Hint(body, DNI_X + DNI_W - PROS_X)
	-- R3: the second officer page, Suggestions & trials
	local body2 = CreateFrame("Frame", nil, area)
	body2:SetAllPoints(area)
	body2:Hide()
	t.off2Body = body2
	t.sug = MakeList(t, body2, "g", SUG_X, SUG_W, L.OFF_SUG_TITLE, MakeSugRow)
	t.trial = MakeList(t, body2, "t", TRIAL_X, TRIAL_W, L.OFF_TRIAL_TITLE, MakeTrialRow)
	t.off2Hint = Hint(body2, TRIAL_X + TRIAL_W - SUG_X)
end

local function ClassColor(class)
	local c = class and C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class)
	if c and c.r then return { c.r, c.g, c.b } end
	return W.COLOR.highlight
end

-- R3 rows: a suggestion or a trial
local function DrawExtra(box, r, e, inGuild)
	local now = U.Now()
	if box.l == "g" then
		SetColor(r.name, inGuild and W.COLOR.green or ClassColor(e.k))
		r.tag:SetText((GH:SuggestTagText(e.k, e.ro):gsub("^ %((.*)%)$", "%1")))
		r.when:SetText(L.OFF_SUG_FROM:format(U.Ago(now - e.ts), U.ShortName(e.fr)))
		local dni = GH:IsDontInvite(e.name)
		if dni or inGuild then r.pros:Disable() else r.pros:Enable() end
		if r.pros.SetGreyed then r.pros:SetGreyed(dni or inGuild) end
	else
		SetColor(r.name, W.COLOR.highlight)
		if not inGuild then
			r.when:SetText(L.OFF_TRIAL_GONE)
			SetColor(r.when, W.COLOR.gray)
		elseif e.e > now then
			r.when:SetText(L.OFF_TRIAL_LEFT:format(U.Ago(e.e - now)))
			SetColor(r.when, W.COLOR.highlight)
		else
			r.when:SetText(L.OFF_TRIAL_DUE:format(U.Ago(now - e.e)))
			r.when:SetTextColor(1, 0.6, 0.2) -- orange: a reminder (word + colour)
		end
	end
end

local function DrawList(box, rows, prospect)
	local n = #rows
	box.offset = math.max(0, math.min(box.offset, n - ROWS))
	for i, r in ipairs(box.rows) do
		local e = rows[i + box.offset]
		r:SetShown(e ~= nil)
		if e then
			r.key = e.name
			local inGuild = GH:IsGuildMember(e.name)
			r.name:SetText(U.ShortName(e.name))
			if box.l == "g" or box.l == "t" then
				DrawExtra(box, r, e, inGuild)
			else
				if inGuild then SetColor(r.name, W.COLOR.green) else SetColor(r.name, W.COLOR.highlight) end
				r.when:SetText(L.OFF_WHEN:format(U.Ago(U.Now() - e.ts), U.ShortName(e.by)))
			end
			if prospect then
				r.status:SetLabel(L["OFF_ST_" .. tostring(e.s):upper()] or tostring(e.s))
				local why = inGuild and L.INV_IN_GUILD or GH:GuildInviteBlock(e.name)
				if why then r.invite:Disable() else r.invite:Enable() end
				if r.invite.SetGreyed then r.invite:SetGreyed(why ~= nil) end
				r.invite.whyOff = why
			end
		end
	end
	box.empty:SetShown(n == 0)
	box.more:SetText(n > ROWS and L.OFF_MORE:format(n, box.offset + 1, math.min(n, box.offset + ROWS)) or (n > 0 and L.OFF_COUNT:format(n) or ""))
	local left = box.clear.armedAt and CLEAR_CONFIRM - (GetTime() - box.clear.armedAt)
	local armed = left and left > 0
	box.clear:SetLabel(armed and L.OFF_CLEAR_AGAIN:format(math.ceil(left)) or L.OFF_CLEAR)
	if n == 0 then box.clear:Disable() else box.clear:Enable() end
end

-- Draws the officer page that is chosen in the side list ("officer" or R3 "trials").
function GH:DrawOfficerPage()
	local t = self.recruitTab
	if not t or not t.offBody then return end
	local second = t.side and t.side.selected == "trials" and t.off2Body ~= nil
	t.offBody:SetShown(not second)
	if t.off2Body then t.off2Body:SetShown(second) end
	local noChat = self.RecruitCanOfficerChat and not self.RecruitCanOfficerChat()
	if second then
		DrawList(t.sug, self:OffRows("g"), false)
		DrawList(t.trial, self:OffRows("t"), false)
		t.off2Hint:SetText(L.OFF_HINT2 .. (noChat and ("\n" .. L.OFF_NO_OCHAT) or ""))
		return
	end
	DrawList(t.pros, self:OffRows("p"), true)
	DrawList(t.dni, self:OffRows("d"), false)
	t.offHint:SetText(L.OFF_HINT .. (noChat and ("\n" .. L.OFF_NO_OCHAT) or ""))
end
