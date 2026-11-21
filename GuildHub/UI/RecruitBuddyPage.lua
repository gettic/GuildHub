-- Guild Hub: the Recruiting tab's "New members" page (Guild Recruiter R6; everyone).
-- Left: the buddy sign-up tick (one RBSU per click), "Your buddy", "Your new guildies" with their
-- last online. Right (officers only): new members of the last 14 days, gone-quiet ones first (worked
-- out on this computer, never sent), each with a buddy pick (one RBAS per click).
-- Logic: Features\RecruitBuddy.lua.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local LEFT_X, RIGHT_X = 12, 440
local TEXT_W = 400
local ROW_H, ROWS = 24, 12
local TOP = -34
local GUILDIES_MAX = 5

local function SetColor(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end
local function IAmOfficer() return GH.RecruitIAmOfficer and GH.RecruitIAmOfficer() or false end

local function ClassColor(class)
	local c = class and C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class)
	if c and c.r then return { c.r, c.g, c.b } end
	return W.COLOR.highlight
end

local ORANGE = { 1, 0.6, 0.2 }

-- One new-member row: name, joined, last online (orange when gone quiet), buddy pick.
local function MakeRow(body, y)
	local r = CreateFrame("Frame", nil, body)
	r:SetSize(TEXT_W, ROW_H)
	r:SetPoint("TOPLEFT", RIGHT_X, y)
	r.hl = W.RowHighlight(r)
	r.hl:SetAlpha(0.35)
	r.name = W.Text(r, "GameFontHighlight", "")
	r.name:SetPoint("LEFT", 4, 0)
	r.name:SetWidth(110)
	r.name:SetWordWrap(false)
	r.joined = W.Text(r, "GameFontDisableSmall", "")
	r.joined:SetPoint("LEFT", 116, 0)
	r.joined:SetWidth(76)
	r.joined:SetWordWrap(false)
	r.last = W.Text(r, "GameFontHighlightSmall", "")
	r.last:SetPoint("LEFT", 194, 0)
	r.last:SetWidth(76)
	r.last:SetWordWrap(false)
	local dd = W.Dropdown(r, 126)
	if dd then
		dd:SetupMenu(function(_, root)
			local n = r.key
			if not n then return end
			root:CreateRadio(L.BUD_PICK_NONE, function() return r.buddy == nil end, function() GH:AssignBuddy(n, nil) end)
			local list = GH:BuddyList()
			if #list == 0 and root.CreateTitle then root:CreateTitle(L.BUD_NO_BUDDIES) end
			for _, b in ipairs(list) do
				if b.name ~= n then
					local label = U.ShortName(b.name) .. (b.online and (" (" .. L.BUD_ONLINE .. ")") or "")
					root:CreateRadio(label, function() return r.buddy == b.name end, function() GH:AssignBuddy(n, b.name) end)
				end
			end
		end)
	else
		dd = W.Button(r, L.BUD_PICK, 126, 20)
		dd:Disable()
		if dd.SetGreyed then dd:SetGreyed(true) end
		dd.noMenu = true
	end
	dd:SetPoint("RIGHT", -2, 0)
	W.Tooltip(dd, dd.noMenu and L.BUD_NO_MENU or L.BUD_PICK_TIP)
	r.pick = dd
	return r
end

function GH:BuildBuddyPage(t, area)
	local body = CreateFrame("Frame", nil, area)
	body:SetAllPoints(area)
	body:Hide()
	t.budBody = body
	local b = { rows = {}, offset = 0 }
	t.bud = b
	-- left: buddies
	b.title = W.Text(body, "GameFontNormal", L.BUD_TITLE)
	b.title:SetPoint("TOPLEFT", LEFT_X, -10)
	b.about = W.Text(body, "GameFontHighlightSmall", L.BUD_ABOUT)
	b.about:SetPoint("TOPLEFT", LEFT_X, -32)
	b.about:SetWidth(TEXT_W)
	b.about:SetWordWrap(true)
	b.about:SetHeight(30)
	b.about:SetJustifyV("TOP")
	b.tick = W.CheckButton(body, L.BUD_TICK, 240)
	b.tick:SetPoint("TOPLEFT", LEFT_X - 4, -70)
	b.tick:SetScript("OnClick", function()
		local ok, why = GH:SetBuddySignup(not GH:BuddySignedUp())
		if not ok and why then GH:Msg(why) end
		GH:DrawRecruitPage()
	end)
	W.Tooltip(b.tick, L.BUD_TICK_TIP)
	b.state = W.Text(body, "GameFontDisableSmall", "")
	b.state:SetPoint("TOPLEFT", LEFT_X, -100)
	b.state:SetWidth(TEXT_W)
	b.mine = W.Text(body, "GameFontHighlight", "")
	b.mine:SetPoint("TOPLEFT", LEFT_X, -126)
	b.mine:SetWidth(TEXT_W)
	b.guildiesTitle = W.Text(body, "GameFontNormal", L.BUD_GUILDIES)
	b.guildiesTitle:SetPoint("TOPLEFT", LEFT_X, -156)
	b.guildies = W.Text(body, "GameFontHighlightSmall", "")
	b.guildies:SetPoint("TOPLEFT", LEFT_X, -176)
	b.guildies:SetWidth(TEXT_W)
	b.guildies:SetWordWrap(true)
	b.guildies:SetHeight(90)
	b.guildies:SetJustifyV("TOP")

	-- right: new members (officers)
	b.newTitle = W.Text(body, "GameFontNormal", L.BUD_NEW_TITLE)
	b.newTitle:SetPoint("TOPLEFT", RIGHT_X, -10)
	b.quiet = W.Text(body, "GameFontNormalSmall", "", "RIGHT")
	b.quiet:SetPoint("TOPRIGHT", body, "TOPLEFT", RIGHT_X + TEXT_W, -12)
	b.quiet:SetWidth(140)
	SetColor(b.quiet, ORANGE)
	b.inset = W.Inset(body)
	b.inset:SetPoint("TOPLEFT", RIGHT_X - 4, TOP + 2)
	b.inset:SetSize(TEXT_W + 8, ROWS * ROW_H + 6)
	for i = 1, ROWS do b.rows[i] = MakeRow(body, TOP - (i - 1) * ROW_H) end
	b.empty = W.Text(body, "GameFontDisable", L.BUD_NEW_EMPTY, "CENTER")
	b.empty:SetPoint("TOP", b.inset, "TOP", 0, -40)
	b.empty:SetWidth(TEXT_W - 20)
	b.more = W.Text(body, "GameFontDisableSmall", "")
	b.more:SetPoint("TOPLEFT", b.inset, "BOTTOMLEFT", 4, -4)
	b.count = W.Text(body, "GameFontHighlightSmall", "", "RIGHT")
	b.count:SetPoint("TOPRIGHT", b.inset, "BOTTOMRIGHT", -4, -4)
	b.count:SetWidth(200)
	b.hint = W.Text(body, "GameFontDisableSmall", L.BUD_OFF_HINT)
	b.hint:SetPoint("TOPLEFT", b.inset, "BOTTOMLEFT", 4, -22)
	b.hint:SetWidth(TEXT_W)
	b.hint:SetWordWrap(true)
	b.hint:SetHeight(40)
	b.hint:SetJustifyV("TOP")
	b.inset:EnableMouseWheel(true)
	b.inset:SetScript("OnMouseWheel", function(_, delta)
		b.offset = math.max(0, b.offset - delta * 3)
		GH:DrawBuddyPage()
	end)
	b.memberHint = W.Text(body, "GameFontDisableSmall", L.BUD_MEMBER_HINT)
	b.memberHint:SetPoint("TOPLEFT", RIGHT_X, -34)
	b.memberHint:SetWidth(TEXT_W)
	b.memberHint:SetWordWrap(true)
end

local function DrawRight(b)
	local officer = IAmOfficer()
	for _, f in ipairs({ b.newTitle, b.quiet, b.inset, b.empty, b.more, b.count, b.hint }) do f:SetShown(officer) end
	b.memberHint:SetShown(not officer)
	if not officer then
		for _, r in ipairs(b.rows) do r:Hide() end
		return
	end
	local rows = GH:NewMembers()
	local n, quiet = #rows, 0
	for _, e in ipairs(rows) do if e.quiet then quiet = quiet + 1 end end
	b.offset = math.max(0, math.min(b.offset, n - ROWS))
	local now = U.Now()
	for i, r in ipairs(b.rows) do
		local e = rows[i + b.offset]
		r:SetShown(e ~= nil)
		if e then
			r.key, r.buddy = e.name, e.buddy
			r.name:SetText(U.ShortName(e.name))
			SetColor(r.name, ClassColor(e.class))
			r.joined:SetText(L.BUD_JOINED:format(U.Ago(now - e.joined)))
			if e.quiet then
				r.last:SetText(L.BUD_QUIET:format(U.Ago(e.last)))
				SetColor(r.last, ORANGE) -- word + colour
			elseif e.last == 0 then
				r.last:SetText(L.BUD_ONLINE)
				SetColor(r.last, W.COLOR.green)
			else
				r.last:SetText(e.last and U.Ago(e.last) or "?")
				SetColor(r.last, W.COLOR.highlight)
			end
			if r.pick.SetLabel then
				r.pick:SetLabel(e.buddy and L.BUD_PICKED:format(U.ShortName(e.buddy)) or L.BUD_PICK)
			end
		end
	end
	b.empty:SetShown(n == 0)
	b.quiet:SetText(quiet > 0 and L.BUD_QUIET_COUNT:format(quiet) or "")
	b.more:SetText(n > ROWS and L.OFF_MORE:format(n, b.offset + 1, math.min(n, b.offset + ROWS)) or (n > 0 and L.OFF_COUNT:format(n) or ""))
	b.count:SetText(L.BUD_COUNT:format(#GH:BuddyList()))
end

function GH:DrawBuddyPage()
	local t = self.recruitTab
	local b = t and t.bud
	if not b then return end
	local signed = self:BuddySignedUp()
	b.tick:SetActive(signed ~= nil)
	b.state:SetText(signed and L.BUD_SIGNED:format(U.Ago(U.Now() - signed)) or L.BUD_NOT_SIGNED)
	local mine = self:MyBuddy()
	b.mine:SetShown(mine ~= nil)
	if mine then b.mine:SetText(L.BUD_YOURS:format(U.ShortName(mine), self:BuddyLastText(self:LastOnline(mine)))) end
	local list = self:MyNewGuildies()
	local lines = {}
	for i = 1, math.min(GUILDIES_MAX, #list) do
		lines[#lines + 1] = L.BUD_GUILDIE_LINE:format(U.ShortName(list[i].name), self:BuddyLastText(list[i].last))
	end
	b.guildies:SetText(#lines > 0 and table.concat(lines, "\n") or L.BUD_NONE_YET)
	if #lines > 0 then SetColor(b.guildies, W.COLOR.highlight) else SetColor(b.guildies, W.COLOR.gray) end
	DrawRight(b)
end
