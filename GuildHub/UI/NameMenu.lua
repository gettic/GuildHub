-- Guild Hub: one right-click name menu (0.6.0-beta.3, plans\next-beta; tos: plans\next-beta\tos-check.md).
-- Opened on our OWN frames only: Status rows, mini window rows, Professions crafter rows, Map tab rows
-- and the alert note. Never on map dots (they stay hover-only) and never on Blizzard's own menus.
--
-- GH:NameMenuEntries(name, ctx) builds a plain list (testable without any menu UI); GH:ShowNameMenu
-- draws it with Blizzard's MenuUtil.CreateContextMenu, else with a small plain popup. Fixed order:
--   title · Whisper · Invite · Ask to join · Waypoint · Show on map · Join me · divider ·
--   Mute / Unmute · More (Copy name, Show professions, "more" hooks) · [officer section]
-- Entries that can't be used now are greyed with the reason (tooltip), never hidden.
-- Every action runs from the entry's own click; the action re-checks its state (Features\Actions.lua).
--
-- nameMenu hook (Features.lua): a feature lists { kind = "more" | "officer", order, fn(GH, name, ctx)
--   -> list of entries } (entry = { text, ok, why, run } or { text, items = {...} } for a submenu).
--   The officer section is only built for officers and only on guild members who aren't officers:
--   this file checks that itself (tos 7), so a hook can't add officer entries for anyone else.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local MAX_TOP = 10 -- top entries before the officer section (plan sec. 1: "at most about 8"; 9 with "I can help"; 10 with View gear, 1.0.2)
GH.NAME_MENU_MAX_TOP = MAX_TOP
GH.nameMenuStats = { opened = 0, fallback = 0, clicks = 0 }

local function Why(why, secs)
	local s = (L.ACT_WHY and L.ACT_WHY[why]) or tostring(why or "?")
	return (s:gsub("%%d", tostring(secs or 0)))
end

local function Btn(key, text, ok, why, secs, run)
	return { kind = "button", key = key, text = text, ok = ok and true or false,
		why = (not ok) and Why(why, secs) or nil, run = run }
end

local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

local function WhisperState(gh, name)
	if not gh:IsOnline(name) then return false, "offline" end
	return true
end

local function InviteState(gh, name)
	if InCombat() then return false, "combat" end
	if gh:IsIgnored(name) then return false, "ignored" end
	if not gh:IsOnline(name) then return false, "offline" end
	if gh.myGroup and gh.myGroup[name] then return false, "ingroupthem" end
	return true
end

local function ProfState(gh, name)
	if not gh:FeatureOn("prof") then return false, "profoff" end
	local can, why = gh:CanUse("prof")
	if not can then return false, why == "trial" and "trial" or "profshare" end
	if not (gh.ProfLine and gh:ProfLine(name)) then return false, "noprof" end
	return true
end

-- Hook entries of one kind, sorted by order; each fn runs in pcall (a broken hook never breaks the menu).
local function HookEntries(gh, kind, name, ctx)
	local list = {}
	for _, h in ipairs(gh:Hooks("nameMenu")) do
		if type(h) == "table" and h.kind == kind and type(h.fn) == "function" then list[#list + 1] = h end
	end
	table.sort(list, function(a, b) return (a.order or 50) < (b.order or 50) end)
	local r = {}
	for _, h in ipairs(list) do
		local ok, items = pcall(h.fn, gh, name, ctx)
		if ok and type(items) == "table" then
			for _, e in ipairs(items) do
				if type(e) == "table" and type(e.text) == "string" then
					if e.items then
						r[#r + 1] = { kind = "submenu", key = e.key, text = e.text, ok = e.ok ~= false, why = e.why, items = e.items }
					else
						r[#r + 1] = { kind = "button", key = e.key, text = e.text, ok = e.ok ~= false, why = e.why, run = e.run,
							red = e.red and true or nil }
					end
				end
			end
		end
	end
	return r
end

-- The menu for one guildmate (or one of your own characters) as a plain list.
function GH:NameMenuEntries(name, ctx)
	local e = {}
	if type(name) ~= "string" or name == "" then return e end
	local short = U.ShortName(name)
	local r = self.roster[name]
	local mine = self:IsMyChar(name)
	local title = U.ClassColored(name, r and r.class)
	if mine then title = title .. " " .. (name == self:MyName() and L.MENU_YOU or L.MENU_YOUR_ALT) end
	e[#e + 1] = { kind = "title", text = title }
	if not mine then
		local ok, why, s = WhisperState(self, name)
		e[#e + 1] = Btn("whisper", L.MENU_WHISPER, ok, why, s, function() GH:WhisperMember(name) end)
		-- 1.0.0-beta.1: "I can help" right after Whisper, only while their status is Need help
		if self.NeedsHelpStatus and self:NeedsHelpStatus(name) then
			ok, why, s = self:CanHelpState(name)
			e[#e + 1] = Btn("canhelp", L.MENU_CANHELP, ok, why, s, function() GH:CanHelp(name) end)
		end
		ok, why, s = InviteState(self, name)
		e[#e + 1] = Btn("invite", L.MENU_INVITE_GROUP, ok, why, s, function()
			if InviteState(GH, name) then GH:InviteMember(name) end
		end)
		ok, why, s = self:AskToJoinState(name)
		e[#e + 1] = Btn("ask", L.MENU_ASK, ok, why, s, function() GH:AskToJoin(name) end)
		ok, why, s = self:WaypointState(name)
		e[#e + 1] = Btn("waypoint", L.MENU_WAYPOINT, ok, why, s, function() GH:WaypointTo(name) end)
	end
	local ok, why, s = self:ShowOnMapState(name)
	e[#e + 1] = Btn("showmap", L.MENU_SHOWMAP, ok, why, s, function() GH:ShowOnMap(name) end)
	-- 1.0.2: "top" hooks (View gear) right after Show on map, also on your own characters
	for _, h in ipairs(HookEntries(self, "top", name, ctx)) do e[#e + 1] = h end
	if not mine then
		ok, why, s = self:JoinMeState(name)
		e[#e + 1] = Btn("joinme", L.MENU_JOINME, ok, why, s, function() GH:JoinMe(name) end)
		e[#e + 1] = { kind = "divider" }
		if self:IsMuted(name) then
			e[#e + 1] = Btn("mute", L.MENU_UNMUTE:format(short), true, nil, nil, function() GH:Unmute(name) end)
		else
			e[#e + 1] = Btn("mute", L.MENU_MUTE:format(short), true, nil, nil, function() GH:Mute(name) end)
		end
	end
	-- More: Copy name, Show professions, then the "more" hooks
	local more = { Btn("copy", L.MENU_COPY, true, nil, nil, function() GH:ShowNameCopyBox(name) end) }
	ok, why, s = ProfState(self, name)
	more[#more + 1] = Btn("prof", L.MENU_PROF, ok, why, s, function()
		local line = ProfState(GH, name) and GH:ProfLine(name)
		if line then GH:Msg(L.MENU_PROF_LINE, short, line) end
	end)
	for _, h in ipairs(HookEntries(self, "more", name, ctx)) do more[#more + 1] = h end
	e[#e + 1] = { kind = "submenu", key = "more", text = L.MENU_MORE, ok = true, items = more }
	-- officer section: only for officers, only on guild members who aren't officers (checked HERE, tos 7)
	local me = self:MyName()
	if not mine and self.rosterReady and self:IsOfficer(me) and self:IsGuildMember(name) and not self:IsOfficer(name) then
		local off = HookEntries(self, "officer", name, ctx)
		if #off > 0 then
			e[#e + 1] = { kind = "divider" }
			e[#e + 1] = { kind = "head", text = L.MENU_OFFICER }
			for _, x in ipairs(off) do e[#e + 1] = x end
		end
	end
	return e
end

-- Top entries before the officer section (title, dividers and heads not counted).
function GH:NameMenuTopCount(entries)
	local n = 0
	for _, x in ipairs(entries) do
		if x.kind == "head" then break end
		if x.kind == "button" or x.kind == "submenu" then n = n + 1 end
	end
	return n
end

------------------------------------------------------------------------
-- Drawing: Blizzard's context menu
------------------------------------------------------------------------
local function Click(run)
	return function()
		GH.nameMenuStats.clicks = GH.nameMenuStats.clicks + 1
		if type(run) == "function" then
			local ok, err = pcall(run)
			if not ok then GH:Debug("name menu: %s", U.CleanText(tostring(err), 120) or "?") end
		end
	end
end

local function Grey(elem, why)
	if not elem then return end
	if elem.SetEnabled then pcall(elem.SetEnabled, elem, false) end
	if why and elem.SetTooltip then
		pcall(elem.SetTooltip, elem, function(tooltip) tooltip:AddLine(why, 1, 0.5, 0.25, true) end)
	end
end

-- 1.0.0-beta.2: a `red` entry (Remove from guild) is drawn red while it can be used; greyed stays grey.
local RED = "|cffff4040%s|r"
function GH.MenuText(x)
	if x.red and x.ok then return RED:format(x.text) end
	return x.text
end

local function Fill(root, entries)
	for _, x in ipairs(entries) do
		if x.kind == "radio" then
			-- 1.0.0-beta.2 quick menu: a ticked choice (checked() read when drawn); one click = one run
			local run = Click(x.run)
			local b
			if root.CreateRadio then
				b = root:CreateRadio(x.text, function() return x.checked and x.checked() and true or false end, function()
					run()
					return MenuResponse and MenuResponse.Close
				end)
			else
				b = root:CreateButton(x.text, run)
			end
			if not x.ok then Grey(b, x.why) end
		elseif x.kind == "title" or x.kind == "head" then
			if root.CreateTitle then root:CreateTitle(x.text) end
		elseif x.kind == "divider" then
			if root.CreateDivider then root:CreateDivider() end
		elseif x.kind == "submenu" then
			local b = root:CreateButton(x.text)
			if b and type(x.items) == "table" and b.CreateButton then Fill(b, x.items) end
			if not x.ok then Grey(b, x.why) end
		else
			local b = root:CreateButton(GH.MenuText(x), Click(x.run))
			if not x.ok then Grey(b, x.why) end
		end
	end
end
GH.FillNameMenu = Fill -- tests

------------------------------------------------------------------------
-- Drawing: the plain popup (no MenuUtil in this client)
------------------------------------------------------------------------
local POP_W, POP_ROW = 200, 20

local function Popup()
	local p = GH.nameMenuPopup
	if p then return p end
	p = W.Popup("GuildHubNameMenu", UIParent, 0.97)
	p:SetFrameStrata("DIALOG")
	p:SetClampedToScreen(true)
	p:EnableMouse(true)
	p.rows = {}
	p:Hide()
	tinsert(UISpecialFrames, "GuildHubNameMenu") -- Esc closes it
	GH.nameMenuPopup = p
	return p
end

local function PopupRow(p, i)
	local b = p.rows[i]
	if not b then
		b = W.PlainButton(p, "", POP_W - 12, POP_ROW - 2, "GameFontHighlightSmall")
		b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * POP_ROW)
		if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
		b:SetScript("OnEnter", function(s)
			if not s.why then return end
			GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
			GameTooltip:AddLine(s.why, 1, 0.5, 0.25, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		p.rows[i] = b
	end
	return b
end

local function ShowPopup(owner, entries)
	local p = Popup()
	local flat = {}
	for _, x in ipairs(entries) do
		if x.kind == "submenu" then
			flat[#flat + 1] = { kind = "head", text = x.text }
			for _, y in ipairs(x.items or {}) do flat[#flat + 1] = y end
		elseif x.kind ~= "divider" then
			flat[#flat + 1] = x
		end
	end
	for i, x in ipairs(flat) do
		local b = PopupRow(p, i)
		local isBtn = x.kind == "button" or x.kind == "radio"
		local label = GH.MenuText(x)
		if x.kind == "radio" and x.checked and x.checked() then label = L.QM_TICKED:format(label) end
		b:SetLabel(label)
		b.why = x.why
		local active = isBtn and x.ok
		b:SetEnabled(active and true or false)
		if b.SetGreyed then b:SetGreyed(isBtn and not x.ok) end
		b:SetScript("OnClick", function()
			if isBtn and x.ok then
				p:Hide()
				Click(x.run)()
			end
		end)
		b:Show()
	end
	for i = #flat + 1, #p.rows do p.rows[i]:Hide() end
	p:SetSize(POP_W, 12 + #flat * POP_ROW)
	p:ClearAllPoints()
	local x, y = GetCursorPosition()
	local s = UIParent:GetEffectiveScale() or 1
	if type(x) == "number" and type(y) == "number" and s > 0 then
		p:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, y / s)
	else
		p:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, 0)
	end
	p:Show()
	return p
end

------------------------------------------------------------------------
-- Open / close
------------------------------------------------------------------------
-- owner = the row (or note) that was right-clicked; ctx = where ("status", "mini", "prof", "map", "toast").
function GH:ShowNameMenu(owner, name, ctx)
	if type(name) ~= "string" or name == "" then return false end
	if InCombat() then return false end -- every feature runs out of combat
	local entries = self:NameMenuEntries(name, ctx)
	self.nameMenuStats.opened = self.nameMenuStats.opened + 1
	local _, fallback = self:ShowEntryMenu(owner, entries)
	if fallback then self.nameMenuStats.fallback = self.nameMenuStats.fallback + 1 end
	return true
end

-- Any entry list (name menu, 1.0.0-beta.2 minimap quick menu): MenuUtil context menu, else the
-- plain popup. Returns true, usedFallback.
function GH:ShowEntryMenu(owner, entries)
	self:HideNameMenu()
	if MenuUtil and type(MenuUtil.CreateContextMenu) == "function" then
		local ok, menu = pcall(MenuUtil.CreateContextMenu, owner, function(_, root) Fill(root, entries) end)
		if ok then self.nameMenuOpen = menu return true, false end
	end
	ShowPopup(owner, entries)
	return true, true
end

function GH:HideNameMenu()
	local m = self.nameMenuOpen
	self.nameMenuOpen = nil
	if m and m.Close then pcall(m.Close, m) end
	if self.nameMenuPopup and self.nameMenuPopup:IsShown() then self.nameMenuPopup:Hide() end
end

-- Right-click on a row: hooks the row's OnMouseUp (the row keeps its own scripts). getName(row) -> name.
function GH:NameMenuOnRow(row, getName, ctx)
	if not row or row.ghNameMenu then return end
	row.ghNameMenu = true
	if row.RegisterForClicks then row:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
	row:HookScript("OnMouseUp", function(r, button)
		if button ~= "RightButton" then return end
		local name = getName(r)
		if name then GH:ShowNameMenu(r, name, ctx) end
	end)
end

------------------------------------------------------------------------
-- More > Copy name: a small read-only box (Ctrl+C)
------------------------------------------------------------------------
function GH:ShowNameCopyBox(name)
	local b = self.nameCopyBox
	if not b then
		b = W.Popup("GuildHubNameCopy", UIParent, 0.97)
		b:SetSize(280, 78)
		b:SetPoint("CENTER", 0, 120)
		b:SetFrameStrata("DIALOG")
		b:EnableMouse(true)
		b.title = W.Text(b, "GameFontNormal", L.MENU_COPY_TITLE)
		b.title:SetPoint("TOPLEFT", 12, -10)
		b.edit = W.EditBox(b, 250, 22, 60)
		b.edit:SetPoint("TOPLEFT", 16, -32)
		b.edit:HookScript("OnTextChanged", function(s, user)
			if user then s:SetText(b.name or ""); s:HighlightText() end
		end)
		b.edit:HookScript("OnEscapePressed", function() b:Hide() end)
		b.edit:HookScript("OnEnterPressed", function() b:Hide() end)
		b.close = W.TitleButton(b, "close")
		b.close:SetPoint("TOPRIGHT", 2, 2)
		b.hint = W.Text(b, "GameFontDisableSmall", L.MENU_COPY_HINT)
		b.hint:SetPoint("BOTTOMLEFT", 12, 8)
		tinsert(UISpecialFrames, "GuildHubNameCopy")
		self.nameCopyBox = b
	end
	b.name = U.WhisperName(name)
	b:Show()
	b.edit:SetText(b.name)
	b.edit:SetFocus()
	b.edit:HighlightText()
end
