-- Guild Hub: the Recruiting tab's "Ad builder" page (Guild Recruiter R5; officers only).
-- Fixed lists (raid size, days, start time, time zone, loot, style, level) on the left; the built
-- one-line ad, "Use this" and "Save for the guild" on the right, with the long post for the Copy
-- box under it. Logic: Features\RecruitAds.lua. Nothing here sends or posts: "Use this" only fills
-- the Overview text box, "Save for the guild" is the same save as on the Overview page (RPUB).
local _, ns = ...
local GH, L = ns.GH, ns.L
local W = ns.Widgets

local LEFT_X, RIGHT_X = 12, 440
local LABEL_W, CTRL_X = 92, 108
local TEXT_W = 400
local ROW_Y = { size = -40, days = -74, at = -108, tz = -142, loot = -176, style = -210, lvl = -244 }

local function SetColor(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function Changed(t)
	t.dirty = true
	GH:DrawRecruitPage()
end

-- The words a field value shows.
local function ValueText(key, v)
	if key == "size" then return v and L.ADB_SIZE_V:format(v) or L.ADB_NOT_SET end
	if key == "at" then return v and GH:AdTimeText(v) or L.ADB_NOT_SET end
	if key == "tz" then return L.ADB_TZ_V[v or "st"] end
	if key == "loot" then return v and L.ADB_LOOT_V[v] or L.ADB_NOT_SET end
	if key == "style" then return v and L.ADB_STYLE_V[v] or L.ADB_NOT_SET end
	if key == "lvl" then return v and L.ADB_LVL_V[v] or L.ADB_ANY_LVL end
	return tostring(v)
end

local function Values(key)
	if key == "at" then
		local out = {}
		for i = 0, GH.AD_FIELD_LIMITS.AT_MAX do out[#out + 1] = i end
		return out
	end
	return GH.AD_FIELDS[key]
end

-- A dropdown for one field (radio list with "Not set" / the default first); the old cycling
-- button when the game has no dropdown template.
local function Choice(t, body, key, label)
	local y = ROW_Y[key]
	local lbl = W.Text(body, "GameFontNormalSmall", label)
	lbl:SetPoint("TOPLEFT", LEFT_X, y - 4)
	lbl:SetWidth(LABEL_W)
	local function Set(v)
		if key == "tz" and v == "st" then v = nil end -- server time is the default (saved as nothing)
		t.draft.f[key] = v
		Changed(t)
	end
	local list = Values(key)
	local dd = W.Dropdown(body, 160)
	if dd then
		dd:SetupMenu(function(_, root)
			if key == "at" then -- 48 times: 4 columns when the menu can, else a scrolling list
				local grid = root.SetGridMode and MenuConstants and MenuConstants.VerticalGridDirection
				if not (grid and pcall(root.SetGridMode, root, MenuConstants.VerticalGridDirection, 4)) then
					if root.SetScrollMode then pcall(root.SetScrollMode, root, 400) end
				end
			end
			if key ~= "tz" then
				root:CreateRadio(ValueText(key, nil), function() return t.draft.f[key] == nil end, function() Set(nil) end)
			end
			for _, v in ipairs(list) do
				root:CreateRadio(ValueText(key, v), function()
					return t.draft.f[key] == v or (key == "tz" and v == "st" and t.draft.f.tz == nil)
				end, function() Set(v) end)
			end
		end)
	else
		dd = W.Button(body, "", 160, 22)
		dd:SetScript("OnClick", function()
			local cur, nextV = t.draft.f[key], nil
			if key == "tz" and cur == nil then cur = "st" end
			if cur == nil then nextV = list[1]
			else
				for i, v in ipairs(list) do if v == cur then nextV = list[i + 1] end end
				if nextV == nil and key == "tz" then nextV = list[1] end
			end
			Set(nextV)
		end)
	end
	dd:SetPoint("TOPLEFT", CTRL_X, y)
	t.adb.choices[key] = dd
	return dd
end

function GH:BuildAdPage(t, area)
	local body = CreateFrame("Frame", nil, area)
	body:SetAllPoints(area)
	body:Hide()
	t.adBody = body
	local a = { choices = {}, sizes = {}, days = {} }
	t.adb = a
	a.title = W.Text(body, "GameFontNormal", L.ADB_TITLE)
	a.title:SetPoint("TOPLEFT", LEFT_X, -10)
	a.sub = W.Text(body, "GameFontDisableSmall", L.ADB_SUB)
	a.sub:SetPoint("LEFT", a.title, "RIGHT", 8, 0)

	-- raid size: three buttons (click the lit one again = not set)
	local lbl = W.Text(body, "GameFontNormalSmall", L.ADB_SIZE)
	lbl:SetPoint("TOPLEFT", LEFT_X, ROW_Y.size - 4)
	lbl:SetWidth(LABEL_W)
	for i, n in ipairs(GH.AD_FIELDS.size) do
		local b = W.Button(body, L.ADB_SIZE_V:format(n), 76, 22)
		b:SetPoint("TOPLEFT", CTRL_X + (i - 1) * 80, ROW_Y.size)
		b:SetScript("OnClick", function()
			t.draft.f.size = (t.draft.f.size ~= n) and n or nil
			Changed(t)
		end)
		a.sizes[i] = b
	end
	-- raid days: seven toggles
	lbl = W.Text(body, "GameFontNormalSmall", L.ADB_DAYS)
	lbl:SetPoint("TOPLEFT", LEFT_X, ROW_Y.days - 4)
	lbl:SetWidth(LABEL_W)
	for i = 1, 7 do
		local b = W.Button(body, L.ADB_DAY[i], 40, 22)
		b:SetPoint("TOPLEFT", CTRL_X + (i - 1) * 42, ROW_Y.days)
		b:SetScript("OnClick", function()
			local d = t.draft.f.days or 0
			local bit = 2 ^ (i - 1)
			d = GH.AdHasDay(d, i) and (d - bit) or (d + bit)
			t.draft.f.days = d > 0 and d or nil
			Changed(t)
		end)
		a.days[i] = b
	end
	Choice(t, body, "at", L.ADB_AT)
	Choice(t, body, "tz", L.ADB_TZ)
	Choice(t, body, "loot", L.ADB_LOOT)
	Choice(t, body, "style", L.ADB_STYLE)
	Choice(t, body, "lvl", L.ADB_LVL)
	a.hint = W.Text(body, "GameFontDisableSmall", L.ADB_HINT)
	a.hint:SetPoint("TOPLEFT", LEFT_X, -284)
	a.hint:SetWidth(TEXT_W)
	a.hint:SetWordWrap(true)
	a.hint:SetHeight(40)
	a.hint:SetJustifyV("TOP")

	-- the built ad (as it reads in chat), Use this / Save for the guild
	a.builtTitle = W.Text(body, "GameFontNormal", L.ADB_BUILT_TITLE)
	a.builtTitle:SetPoint("TOPLEFT", RIGHT_X, -10)
	a.count = W.Text(body, "GameFontHighlightSmall", "", "RIGHT")
	a.count:SetPoint("TOPRIGHT", body, "TOPLEFT", RIGHT_X + TEXT_W, -12)
	a.count:SetWidth(120)
	local bg = W.Inset(body)
	bg:SetPoint("TOPLEFT", RIGHT_X, -30)
	bg:SetSize(TEXT_W, 66)
	a.builtBg = bg
	a.built = W.Text(bg, "ChatFontNormal", "")
	a.built:SetPoint("TOPLEFT", 8, -6)
	a.built:SetPoint("BOTTOMRIGHT", -8, 6)
	a.built:SetWordWrap(true)
	a.built:SetJustifyV("TOP")
	a.note = W.Text(body, "GameFontHighlightSmall", "")
	a.note:SetPoint("TOPLEFT", bg, "BOTTOMLEFT", 0, -3)
	a.note:SetWidth(TEXT_W)
	a.use = W.Button(body, L.ADB_USE, 100, 22)
	a.use:SetPoint("TOPLEFT", RIGHT_X, -122)
	a.use:SetScript("OnClick", function(btn) if btn.text then GH:UseBuiltAd(btn.text) end end)
	W.Tooltip(a.use, L.ADB_USE_TIP)
	a.save = W.Button(body, L.REC_SHARE, 128, 22)
	a.save:SetPoint("LEFT", a.use, "RIGHT", 6, 0)
	a.save:SetScript("OnClick", function() GH:SaveRecruitDraft() end)
	W.Tooltip(a.save, L.ADB_SAVE_TIP)
	a.unsaved = W.Text(body, "GameFontNormalSmall", L.REC_UNSAVED, "RIGHT")
	a.unsaved:SetPoint("TOPRIGHT", body, "TOPLEFT", RIGHT_X + TEXT_W, -127)
	a.unsaved:SetWidth(150)

	-- the long post (Copy box only)
	a.longTitle = W.Text(body, "GameFontNormalSmall", L.ADB_LONG_TITLE)
	a.longTitle:SetPoint("TOPLEFT", RIGHT_X, -160)
	local lbg = W.Inset(body)
	lbg:SetPoint("TOPLEFT", RIGHT_X, -176)
	lbg:SetSize(TEXT_W, 250)
	a.longBg = lbg
	a.long = W.Text(lbg, "GameFontHighlightSmall", "")
	a.long:SetPoint("TOPLEFT", 8, -6)
	a.long:SetPoint("BOTTOMRIGHT", -8, 6)
	a.long:SetWordWrap(true)
	a.long:SetJustifyV("TOP")
end

-- Draws the page (officers; DrawRecruitPage sends members back to the Overview).
function GH:DrawAdPage()
	local t = self.recruitTab
	local a = t and t.adb
	if not a or not t.draft then return end
	local f = t.draft.f
	for i, b in ipairs(a.sizes) do
		b.isOn = f.size == self.AD_FIELDS.size[i]
		b:SetActive(b.isOn)
	end
	for i, b in ipairs(a.days) do
		b.isOn = self.AdHasDay(f.days, i) and true or false
		b:SetActive(b.isOn)
	end
	for key, dd in pairs(a.choices) do
		dd:SetLabel(ValueText(key, f[key]))
	end
	local text, why, left = self:BuildAdLine(f, t.draft.need, t.draft.cls)
	local chan = W.ChatColor("CHANNEL1")
	if text then
		a.built:SetText(text)
		SetColor(a.built, chan)
		a.count:SetText(L.ADB_COUNT:format(self.AdLetters(text), self.RECRUIT_CAPS.AD_MAX))
		a.note:SetText(#left > 0 and L.ADB_DROPPED:format(table.concat(left, ", ")) or "")
		SetColor(a.note, W.COLOR.gray)
	else
		a.built:SetText("")
		a.count:SetText("")
		a.note:SetText(L.ADB_ERR:format(L["REC_ERR_" .. tostring(why):upper()] or L.REC_ERR_TEXT))
		a.note:SetTextColor(1, 0.4, 0.3)
	end
	a.use.text = text
	if text then a.use:Enable() else a.use:Disable() end
	if a.use.SetGreyed then a.use:SetGreyed(text == nil) end
	a.save:SetActive(t.dirty == true)
	a.unsaved:SetShown(t.dirty == true)
	-- the long post as the Copy box will show it once saved (the draft's fields and needs)
	a.long:SetText(self:BuildLongPost({ f = f, need = t.draft.need, cls = t.draft.cls,
		ad = (self:CleanAd(t.text:GetText() or "")), dc = self:CleanDiscord(t.dcBox:GetText() or "") }))
end
