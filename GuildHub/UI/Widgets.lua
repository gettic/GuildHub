-- Guild Hub: small shared UI parts (panels, buttons, text boxes, lists, menus, the alert note).
-- Blizzard look first: every Blizzard template, atlas and texture is named in W.ART below and
-- used by name only (nothing copied). Each one is checked before use; a missing one falls back
-- to our own plain look, so a theme can later swap the art in one place.
-- No secure templates: these are all plain display templates.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local W = {}
ns.Widgets = W

local WHITE = "Interface\\Buttons\\WHITE8x8"
local BACKDROP = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }

------------------------------------------------------------------------
-- The theme point: all art and colours in one place
------------------------------------------------------------------------
W.ART = {
	-- templates (checked with W.HasTemplate before use)
	frame = "ButtonFrameTemplate",           -- the full window
	inset = "InsetFrameTemplate",            -- list, own-status panel, settings
	tab = "PanelTopTabButtonTemplate",       -- tabs at the top, under the title bar
	button = "UIPanelButtonTemplate",        -- red buttons
	search = "SearchBoxTemplate",
	input = "InputBoxTemplate",
	check = "UICheckButtonTemplate",
	popup = "TooltipBackdropTemplate",       -- mini window, alert note
	dropdown = "WowStyle1DropdownTemplate",  -- Sort, Dungeon
	scrollBox = "WowScrollBoxList",
	scrollBar = "MinimalScrollBar",
	-- atlases (checked with W.HasAtlas) and texture files
	divider = "Options_HorizontalDivider",   -- group header line
	rowHighlight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
	toastIcon = "Interface\\Icons\\INV_Misc_GroupNeedMore",
	card = "TooltipBackdropTemplate",         -- the card that asks (UI\Card.lua; via W.Popup)
	-- guildmates' map dots (UI\MapPins.lua): Blizzard's group-member dot (used by Forever's
	-- UnitPositionFrameTemplates), tinted in the class colour; fallback a white square masked round
	dot = { atlas = "WhiteCircle-RaidBlips", file = "Interface\\Buttons\\WHITE8X8",
		mask = "Interface\\CharacterFrame\\TempPortraitAlphaMask" },
	-- 0.6.0 "Find me" pulse: Blizzard's own minimap ping ring (used by its GroupMembersDataProvider),
	-- referenced by path (tos d); fallback = the dot art itself, growing and fading
	ping = { file = "Interface\\minimap\\UI-Minimap-Ping-Expand" },
	-- 0.6.0 dungeon labels: Blizzard's dungeon / raid map icons; fallback = text only
	dungeonIcon = { dungeon = "Dungeon", raid = "Raid" },
	-- 1.0.0-beta.1 badges (held notes): Blizzard's notification dot, by name; fallback = a white square
	-- masked round, tinted red (tos-check item 4)
	badge = { atlas = "communities-icon-notification", file = "Interface\\Buttons\\WHITE8X8",
		mask = "Interface\\CharacterFrame\\TempPortraitAlphaMask" },
}

-- Blizzard's font colours (read from the game when there, else the same values).
local function GameColor(global, r, g, b)
	local c = _G[global]
	if type(c) == "table" and type(c.r) == "number" then return { c.r, c.g, c.b } end
	return { r, g, b }
end
W.COLOR = {
	normal = GameColor("NORMAL_FONT_COLOR", 1, 0.82, 0),
	highlight = GameColor("HIGHLIGHT_FONT_COLOR", 1, 1, 1),
	gray = GameColor("GRAY_FONT_COLOR", 0.5, 0.5, 0.5),
	green = GameColor("GREEN_FONT_COLOR", 0.1, 1, 0.1),
	disabled = GameColor("DISABLED_FONT_COLOR", 0.5, 0.5, 0.5),
}

-- our own plain look (fallback)
W.GOLD = { 0.95, 0.78, 0.35 }
W.BORDER = { 0.45, 0.36, 0.18 }
W.BORDER_ON = { 0.95, 0.78, 0.35 }

function W.HasAtlas(name)
	if type(name) ~= "string" or not (C_Texture and C_Texture.GetAtlasInfo) then return false end
	local ok, info = pcall(C_Texture.GetAtlasInfo, name)
	return ok and info ~= nil
end

local templateKnown = {}
function W.HasTemplate(name)
	if type(name) ~= "string" or not (C_XMLUtil and C_XMLUtil.GetTemplateInfo) then return false end
	if templateKnown[name] == nil then
		local ok, info = pcall(C_XMLUtil.GetTemplateInfo, name)
		templateKnown[name] = (ok and info ~= nil) and true or false
	end
	return templateKnown[name]
end

-- Creates a frame from the template W.ART[artKey]; nil when the template is missing or fails
-- (the caller then builds the plain look).
function W.FromTemplate(frameType, name, parent, artKey)
	local tpl = W.ART[artKey]
	if not W.HasTemplate(tpl) then return nil end
	local ok, f = pcall(CreateFrame, frameType, name, parent, tpl)
	if not ok or type(f) ~= "table" then return nil end
	f.ghTemplate = tpl
	return f
end

local function Child(f, ...) -- first template child that exists (keys differ between versions)
	for i = 1, select("#", ...) do
		local c = f[select(i, ...)]
		if type(c) == "table" then return c end
	end
end
W.Child = Child

------------------------------------------------------------------------
-- Plain look helpers
------------------------------------------------------------------------
function W.Skin(f, alpha, r, g, b)
	f:SetBackdrop(BACKDROP)
	f:SetBackdropColor(r or 0.07, g or 0.06, b or 0.04, alpha or 0.96)
	f:SetBackdropBorderColor(W.BORDER[1], W.BORDER[2], W.BORDER[3], 1)
end

function W.Text(parent, font, text, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
	fs:SetJustifyH(justify or "LEFT")
	fs:SetWordWrap(false)
	if text then fs:SetText(text) end
	return fs
end

-- A window/panel background: the template's own art, else our dark box.
function W.Popup(name, parent, alpha)
	local f = W.FromTemplate("Frame", name, parent, "popup")
	if f then return f end
	f = CreateFrame("Frame", name, parent, "BackdropTemplate")
	W.Skin(f, alpha or 0.94)
	return f
end

-- Sunken box behind a list or panel (InsetFrameTemplate), else a faint plain box.
function W.Inset(parent)
	local f = W.FromTemplate("Frame", nil, parent, "inset")
	if f then return f end
	f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	W.Skin(f, 0.5, 0.1, 0.08, 0.05)
	return f
end

------------------------------------------------------------------------
-- Buttons
------------------------------------------------------------------------
-- Plain button with a thin gold border (fallback look). b:SetActive(true) makes the border bright.
function W.PlainButton(parent, text, width, height, font)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(width or 60, height or 20)
	W.Skin(b, 0.9, 0.12, 0.1, 0.07)
	local fs = b:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	fs:SetPoint("CENTER")
	fs:SetWidth((width or 60) - 6) -- long text is cut off inside the button, never spills out
	fs:SetWordWrap(false)
	fs:SetText(text or "")
	b.label = fs
	b:SetFontString(fs)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 0.85, 0.4, 0.12)
	b.plain = true
	function b:SetLabel(t) self.label:SetText(t) end
	function b:SetActive(on)
		local c = on and W.BORDER_ON or W.BORDER
		self:SetBackdropBorderColor(c[1], c[2], c[3], 1)
		if on then self:SetBackdropColor(0.3, 0.24, 0.1, 0.95) else self:SetBackdropColor(0.12, 0.1, 0.07, 0.9) end
		self.label:SetTextColor(on and 1 or 0.9, on and 0.85 or 0.88, on and 0.5 or 0.8)
	end
	function b:SetGreyed(on) -- disabled look (the button itself is disabled by the caller)
		if on then self.label:SetTextColor(0.45, 0.45, 0.45) else self:SetActive(false) end
	end
	return b
end

local function FontObj(name) return _G[name] or name end

-- Blizzard red button (UIPanelButtonTemplate), else the plain button. Same use either way:
-- b.label, b:SetLabel(text), b:SetActive(on) (lit = LockHighlight), b:SetGreyed(on).
function W.Button(parent, text, width, height, font)
	local b = W.FromTemplate("Button", nil, parent, "button")
	if not b then return W.PlainButton(parent, text, width, height, font) end
	width = width or 60
	b:SetSize(width, height or 20)
	local small = not font or font:find("Small") ~= nil
	b:SetNormalFontObject(FontObj(small and "GameFontNormalSmall" or "GameFontNormal"))
	b:SetHighlightFontObject(FontObj(small and "GameFontHighlightSmall" or "GameFontHighlight"))
	b:SetDisabledFontObject(FontObj(small and "GameFontDisableSmall" or "GameFontDisable"))
	b:SetText(text or "")
	local fs = b:GetFontString()
	if type(fs) == "table" then
		fs:SetWidth(width - 8) -- long text is cut off inside the button
		fs:SetWordWrap(false)
	end
	b.label = fs
	function b:SetLabel(t) self:SetText(t or "") end
	function b:SetActive(on)
		self.active = on and true or false
		if on then self:LockHighlight() else self:UnlockHighlight() end
	end
	function b:SetGreyed() end -- the template's own disabled art does it
	return b
end

-- Checkbox with a label (UICheckButtonTemplate), else a plain on/off button with the same text.
-- cb:SetActive(on) sets the tick (or the bright border).
function W.CheckButton(parent, text, plainWidth)
	local cb = W.FromTemplate("CheckButton", nil, parent, "check")
	if not cb then return W.PlainButton(parent, text, plainWidth or 100, 24) end
	cb:SetSize(26, 26)
	local fs = Child(cb, "Text", "text")
	if not fs then
		fs = W.Text(cb, "GameFontNormalSmall")
		fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
	end
	fs:SetText(text or "")
	cb.label = fs
	cb:SetHitRectInsets(0, -70, 0, 0) -- the label is clickable too
	function cb:SetActive(on) self:SetChecked(on and true or false) end
	function cb:SetLabel(t) self.label:SetText(t or "") end
	return cb
end

------------------------------------------------------------------------
-- Title bar buttons (close, mini, back to full): Blizzard's red buttons. An atlas the game
-- doesn't have is never used (it would show a green box): then the plain button with a sign.
------------------------------------------------------------------------
W.TITLE_ART = {
	condense = { normal = "RedButton-Condense", pushed = "RedButton-Condense-pressed", disabled = "RedButton-Condense-disabled", text = "-" },
	expand = { normal = "RedButton-Expand", pushed = "RedButton-Expand-pressed", disabled = "RedButton-Expand-disabled", text = "+" },
}
W.TITLE_HIGHLIGHT = "RedButton-Highlight"
W.ART.titleButtons = W.TITLE_ART
-- Settings gear in the title bar: a plain icon (not a third red button). Tried in this order:
-- gear atlases (only if the game has them), then the classic options-button file (only if the
-- game knows the file), then a plain text button.
W.ART.gear = {
	atlases = { "QuestLog-icon-setting", "GM-icon-settings" },
	file = "Interface\\Buttons\\UI-OptionsButton",
	text = "?",
}

-- Which gear art this client can show: "atlas", name / "file", path / "text", sign.
function W.GearArt()
	local g = W.ART.gear
	for _, a in ipairs(g.atlases) do
		if W.HasAtlas(a) then return "atlas", a end
	end
	if GetFileIDFromPath then
		local ok, id = pcall(GetFileIDFromPath, g.file)
		if ok and type(id) == "number" and id > 0 then return "file", g.file end
	end
	return "text", g.text
end

-- Getting started card ticks (UI\Guide.lua through Card.lua): Blizzard's checkmark atlas, else
-- the ready-check files; "off" = the waiting mark, greyed. Last fallback: a text mark.
W.ART.guide = {
	done = { atlas = "common-icon-checkmark", file = "Interface\\RaidFrame\\ReadyCheck-Ready", text = "+" },
	todo = { file = "Interface\\RaidFrame\\ReadyCheck-Waiting", text = "?" },
	off = { file = "Interface\\RaidFrame\\ReadyCheck-Waiting", text = "-", grey = true },
	-- 0.5.0 walkthrough: optional rows get a neutral info mark, never a to-do mark (file checked
	-- at run time; not confirmed in a source, /ghub test ui reports it)
	info = { file = "Interface\\FriendsFrame\\InformationIcon", text = "i" },
}

local fileKnown = {}
local function HasFile(path)
	if fileKnown[path] == nil then
		local ok, id = false, nil
		if GetFileIDFromPath then ok, id = pcall(GetFileIDFromPath, path) end
		fileKnown[path] = ok and type(id) == "number" and id > 0 or false
	end
	return fileKnown[path]
end

-- 0.6.0: the Find me pulse ring: "file", path, or "dot" (use the dot art instead).
function W.PingArt()
	local p = W.ART.ping
	if p and p.file and HasFile(p.file) then return "file", p.file end
	return "dot"
end

-- 0.6.0: the dungeon label's icon atlas ("dungeon" / "raid"), or nil (text only).
function W.DungeonIconArt(kind)
	local a = W.ART.dungeonIcon and W.ART.dungeonIcon[kind]
	if a and W.HasAtlas(a) then return a end
	return nil
end

-- Which art a tick state gets: "atlas", name / "file", path / "text", sign.
function W.GuideArt(state)
	local g = W.ART.guide[state] or W.ART.guide.off
	if g.atlas and W.HasAtlas(g.atlas) then return "atlas", g.atlas end
	if g.file and HasFile(g.file) then return "file", g.file end
	return "text", g.text
end

-- Puts a tick state on an icon texture + its text fallback font string.
function W.SetGuideIcon(tex, mark, state)
	local kind, art = W.GuideArt(state)
	local grey = W.ART.guide[state] and W.ART.guide[state].grey
	tex:SetShown(kind ~= "text")
	mark:SetShown(kind == "text")
	if kind == "atlas" then tex:SetAtlas(art)
	elseif kind == "file" then tex:SetTexture(art) end
	if tex.SetDesaturated then tex:SetDesaturated(grey and true or false) end
	tex:SetAlpha(grey and 0.6 or 1)
	if kind == "text" then
		mark:SetText(art)
		local c = state == "done" and W.COLOR.green or (grey and W.COLOR.gray or W.COLOR.normal)
		mark:SetTextColor(c[1], c[2], c[3])
	end
	return kind
end

------------------------------------------------------------------------
-- Guild Recruiter art (UI\RecruitPage.lua): role and class icons, wanted/closed marks, bars, macro
-- icons. Each: Blizzard atlas first (only if the game has it), then a game file, then a text mark.
------------------------------------------------------------------------
W.ART.roles = {
	atlas = { t = "roleicon-tiny-tank", h = "roleicon-tiny-healer", d = "roleicon-tiny-dps" },
	file = "Interface\\LFGFrame\\UI-LFG-ICON-ROLES",
	coords = { t = { 0, 19 / 64, 22 / 64, 41 / 64 }, h = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 }, d = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 } },
	text = { t = "T", h = "H", d = "D" },
}
W.ART.classes = { atlasPrefix = "classicon-", file = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES" }
W.ART.wanted = {
	[1] = { atlas = "common-icon-checkmark", file = "Interface\\RaidFrame\\ReadyCheck-Ready", text = "+" },
	[2] = { atlas = "common-icon-redx", file = "Interface\\RaidFrame\\ReadyCheck-NotReady", text = "x" },
}
W.ART.bar = "Interface\\TargetingFrame\\UI-StatusBar"
W.ART.macroFrame = { atlas = "UI-HUD-ActionBar-IconFrame", file = "Interface\\Buttons\\UI-Quickslot2" }
W.ART.iconPath = "Interface\\Icons\\"

-- Role icon on a texture (+ text mark fallback). Returns the kind used.
function W.SetRoleIcon(tex, mark, role)
	local a = W.ART.roles
	local atlas = a.atlas[role]
	local kind = "text"
	if atlas and W.HasAtlas(atlas) then
		tex:SetAtlas(atlas); tex:SetTexCoord(0, 1, 0, 1); kind = "atlas"
	elseif HasFile(a.file) and a.coords[role] then
		local c = a.coords[role]
		local fn = GetTexCoordsForRoleSmallCircle
		local okC, l, r, t, b = false, nil, nil, nil, nil
		if type(fn) == "function" then okC, l, r, t, b = pcall(fn, ({ t = "TANK", h = "HEALER", d = "DAMAGER" })[role]) end
		tex:SetTexture(a.file)
		if okC and type(l) == "number" then tex:SetTexCoord(l, r, t, b) else tex:SetTexCoord(c[1], c[2], c[3], c[4]) end
		kind = "file"
	end
	tex:SetShown(kind ~= "text")
	if mark then
		mark:SetShown(kind == "text")
		mark:SetText(a.text[role] or "?")
	end
	return kind
end

-- Class icon on a texture (atlas classicon-<class>, else the character-create sheet + CLASS_ICON_TCOORDS).
function W.SetClassIcon(tex, class)
	local a = W.ART.classes
	local atlas = a.atlasPrefix .. tostring(class):lower()
	if W.HasAtlas(atlas) then
		tex:SetAtlas(atlas); tex:SetTexCoord(0, 1, 0, 1)
		return "atlas"
	end
	local c = type(CLASS_ICON_TCOORDS) == "table" and CLASS_ICON_TCOORDS[class]
	if c and HasFile(a.file) then
		tex:SetTexture(a.file); tex:SetTexCoord(c[1], c[2], c[3], c[4])
		return "file"
	end
	tex:SetColorTexture(0.3, 0.3, 0.3, 1)
	return "color"
end

-- Wanted (1) / closed (2) mark on a texture + text fallback; 0 / nil hides both.
function W.SetMarkIcon(tex, mark, state)
	local a = W.ART.wanted[state]
	if not a then
		tex:Hide(); if mark then mark:Hide() end
		return "none"
	end
	local kind = "text"
	if W.HasAtlas(a.atlas) then tex:SetAtlas(a.atlas); kind = "atlas"
	elseif HasFile(a.file) then tex:SetTexture(a.file); kind = "file" end
	tex:SetShown(kind ~= "text")
	if mark then
		mark:SetShown(kind == "text")
		mark:SetText(a.text)
	end
	return kind
end

-- A plain icon texture from Interface\Icons (the "?" icon when the file is missing).
function W.IconPath(name)
	local path = W.ART.iconPath .. tostring(name)
	if HasFile(path) then return path end
	return W.ART.iconPath .. "INV_Misc_QuestionMark"
end

------------------------------------------------------------------------
-- 1.0.0-beta.2 (W): art parts for 1.0.x (goals, bingo, raid roster, guild firsts). Nothing uses
-- them yet; /ghub test ui reports which kind each one got in this client (atlas / file / plain).
-- Each: a Blizzard atlas by name when the game has it, else a game file, else a plain drawing.
------------------------------------------------------------------------
W.ART.progress = { atlas = "UI-Frame-Bar-Fill-Green", file = "Interface\\TargetingFrame\\UI-StatusBar",
	color = { 0.15, 0.7, 0.2 }, bg = { 0, 0, 0, 0.6 } }
W.ART.tick = { atlas = "common-icon-checkmark", file = "Interface\\RaidFrame\\ReadyCheck-Ready", text = "+" }
W.ART.star = { atlas = "PetJournal-FavoritesIcon", file = "Interface\\Common\\ReputationStar",
	coords = { 0, 0.5, 0, 0.5 }, text = "*" }
-- folded / open group header on the Status board (Q5)
W.ART.fold = { [true] = "Interface\\Buttons\\UI-PlusButton-Up", [false] = "Interface\\Buttons\\UI-MinusButton-Up" }

-- Which art a part gets: "atlas", name / "file", path / "plain".
function W.PartArt(key)
	local a = W.ART[key]
	if type(a) ~= "table" then return "plain" end
	if a.atlas and W.HasAtlas(a.atlas) then return "atlas", a.atlas end
	if a.file and HasFile(a.file) then return "file", a.file end
	return "plain"
end

-- The +/- file for a group header, or nil (then the header shows "+ " / "- " in its text).
function W.FoldArt(folded)
	local f = W.ART.fold[folded and true or false]
	if f and HasFile(f) then return f end
	return nil
end

-- A progress bar (StatusBar): atlas fill, else the game's bar file tinted green, else a flat colour.
-- bar:SetProgress(value, max, text). Returns the bar; bar.kind = the art used.
function W.ProgressBar(parent, w, h)
	local a = W.ART.progress
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetSize(w or 200, h or 14)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	local kind, art = W.PartArt("progress")
	if kind == "atlas" and bar.SetStatusBarTexture then
		local ok = pcall(bar.SetStatusBarTexture, bar, art)
		if not ok then kind = "plain" end
	elseif kind == "file" then
		bar:SetStatusBarTexture(art)
		bar:SetStatusBarColor(a.color[1], a.color[2], a.color[3])
	end
	if kind == "plain" then
		bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
		bar:SetStatusBarColor(a.color[1], a.color[2], a.color[3])
	end
	bar.kind = kind
	bar.bg = bar:CreateTexture(nil, "BACKGROUND")
	bar.bg:SetAllPoints()
	bar.bg:SetColorTexture(a.bg[1], a.bg[2], a.bg[3], a.bg[4])
	bar.text = W.Text(bar, "GameFontHighlightSmall")
	bar.text:SetPoint("CENTER")
	function bar:SetProgress(value, max, text)
		max = (type(max) == "number" and max > 0) and max or 1
		value = type(value) == "number" and math.max(0, math.min(value, max)) or 0
		self:SetMinMaxValues(0, max)
		self:SetValue(value)
		self.text:SetText(text or "")
	end
	return bar
end

-- An icon texture of a part ("tick" / "star") + its text fallback. on = false greys it (star "off").
-- Returns the kind used.
function W.SetPartIcon(tex, mark, key, on)
	local a = W.ART[key] or {}
	local kind, art = W.PartArt(key)
	if kind == "atlas" then tex:SetAtlas(art); tex:SetTexCoord(0, 1, 0, 1)
	elseif kind == "file" then
		tex:SetTexture(art)
		local c = a.coords
		if c then tex:SetTexCoord(c[1], c[2], c[3], c[4]) else tex:SetTexCoord(0, 1, 0, 1) end
	end
	tex:SetShown(kind ~= "plain")
	if tex.SetDesaturated then tex:SetDesaturated(on == false) end
	if mark then
		mark:SetShown(kind == "plain")
		mark:SetText(a.text or "?")
		local c = on == false and W.COLOR.gray or (key == "tick" and W.COLOR.green or W.COLOR.normal)
		mark:SetTextColor(c[1], c[2], c[3])
	end
	return kind
end

-- A class icon with the plain fallback of the preview: class-colour square + short class name.
-- Returns the kind: "atlas" / "file" / "plain".
function W.SetClassPart(tex, mark, class)
	local kind = W.SetClassIcon(tex, class)
	if kind == "color" then
		local c = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[class]
		if c then tex:SetColorTexture(c.r, c.g, c.b, 1) end
		kind = "plain"
	end
	if mark then
		mark:SetShown(kind == "plain")
		local s = tostring(class or "?")
		mark:SetText(s:sub(1, 1) .. s:sub(2, 2):lower())
		mark:SetTextColor(0, 0, 0)
	end
	return kind
end

-- /ghub test ui: "bar=atlas tick=atlas class=file star=plain" (class: the warrior icon).
function W.ArtReport()
	local cls = "plain"
	if W.HasAtlas(W.ART.classes.atlasPrefix .. "warrior") then cls = "atlas"
	elseif type(CLASS_ICON_TCOORDS) == "table" and CLASS_ICON_TCOORDS.WARRIOR and HasFile(W.ART.classes.file) then cls = "file" end
	return (W.PartArt("progress")), (W.PartArt("tick")), cls, (W.PartArt("star"))
end

-- The side list of a tab (Members: Recruiting; more pages come later). items = { { key, label } }.
-- Returns the inset; inset.buttons[key]; inset:Select(key) lights one.
function W.SideList(parent, items, onPick)
	local inset = W.Inset(parent)
	inset.buttons = {}
	local y = -8
	for _, it in ipairs(items) do
		local b = CreateFrame("Button", nil, inset)
		b:SetHeight(22)
		b:SetPoint("TOPLEFT", 6, y)
		b:SetPoint("TOPRIGHT", -6, y)
		local hl = W.RowHighlight(b)
		hl:SetAlpha(0.7)
		local sel = b:CreateTexture(nil, "BACKGROUND")
		sel:SetAllPoints()
		sel:SetTexture(W.ART.rowHighlight)
		sel:SetBlendMode("ADD")
		sel:Hide()
		b.sel = sel
		local fs = W.Text(b, "GameFontNormal", it.label)
		fs:SetPoint("LEFT", 8, 0)
		fs:SetPoint("RIGHT", -4, 0)
		b.label = fs
		b:SetScript("OnClick", function() inset:Select(it.key); if onPick then onPick(it.key) end end)
		inset.buttons[it.key] = b
		y = y - 24
	end
	function inset:Select(key)
		for k, b in pairs(self.buttons) do
			b.sel:SetShown(k == key)
			local c = k == key and W.COLOR.highlight or W.COLOR.normal
			b.label:SetTextColor(c[1], c[2], c[3])
		end
		self.selected = key
	end
	return inset
end

local function GearButton(parent, size)
	local kind, art = W.GearArt()
	if kind == "text" then
		local s = size and math.min(size, 22) or 22
		local b = W.PlainButton(parent, art, s, s, "GameFontNormal")
		b.fallback, b.art = true, "text " .. art
		return b
	end
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size or 24, size or 24)
	local icon = b:CreateTexture(nil, "ARTWORK")
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	for _, t in ipairs({ icon, hl }) do
		if kind == "atlas" then t:SetAtlas(art) else t:SetTexture(art) end
		t:SetPoint("TOPLEFT", 4, -4)
		t:SetPoint("BOTTOMRIGHT", -4, 4)
	end
	hl:SetBlendMode("ADD")
	hl:SetAlpha(0.5)
	b:SetScript("OnMouseDown", function() icon:SetPoint("TOPLEFT", 5, -5); icon:SetPoint("BOTTOMRIGHT", -3, 3) end)
	b:SetScript("OnMouseUp", function() icon:SetPoint("TOPLEFT", 4, -4); icon:SetPoint("BOTTOMRIGHT", -4, 4) end)
	b.icon, b.art = icon, kind .. " " .. art
	return b
end

-- kind: "close" (UIPanelCloseButton), "condense" (mini mode), "expand" (back to full),
-- "settings" (gear icon, see W.ART.gear; b.art = the art used).
-- size: optional square size; atlas buttons default to 32 (like the close button).
-- Returns the button; b.fallback = true when the plain button was used.
function W.TitleButton(parent, kind, size)
	if kind == "settings" then return GearButton(parent, size) end
	if kind == "close" then
		local b = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
		if size then b:SetSize(size, size) end
		return b
	end
	local art = W.TITLE_ART[kind]
	if art and W.HasAtlas(art.normal) then
		local b = CreateFrame("Button", nil, parent)
		b:SetSize(size or 32, size or 32)
		b:SetNormalAtlas(art.normal)
		if W.HasAtlas(art.pushed) then b:SetPushedAtlas(art.pushed) end
		if W.HasAtlas(art.disabled) then b:SetDisabledAtlas(art.disabled) end
		if W.HasAtlas(W.TITLE_HIGHLIGHT) then b:SetHighlightAtlas(W.TITLE_HIGHLIGHT, "ADD") end
		b.atlas = art.normal
		return b
	end
	local s = size and math.min(size, 22) or 22
	local b = W.PlainButton(parent, art and art.text or "?", s, s, "GameFontNormal")
	b.fallback = true
	return b
end

-- Simple hover tooltip (keeps any OnEnter/OnLeave already set).
function W.Tooltip(frame, text)
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

------------------------------------------------------------------------
-- Text boxes
------------------------------------------------------------------------
-- Text box (never takes focus by itself). hint = grey text shown while empty.
-- kind "search" = SearchBoxTemplate (magnifier, clear button; its own scripts stay, so callers
-- use HookScript), otherwise InputBoxTemplate. Fallback: our plain dark box.
function W.EditBox(parent, width, height, maxLetters, hint, kind)
	local e = W.FromTemplate("EditBox", nil, parent, kind == "search" and "search" or "input")
	if e then
		e:SetSize(width, 20)
		e:SetAutoFocus(false)
		if maxLetters then e:SetMaxLetters(maxLetters) end
		local instr = kind == "search" and Child(e, "Instructions")
		if instr then
			instr:SetText(hint or "")
			e.hint = instr
			return e
		end
		if kind ~= "search" then e:SetTextInsets(0, 4, 0, 0) end
	else
		e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
		e:SetSize(width, height or 24)
		W.Skin(e, 0.9, 0.03, 0.03, 0.02)
		e:SetFontObject("ChatFontNormal")
		e:SetTextInsets(8, 8, 0, 0)
		e:SetAutoFocus(false)
		if maxLetters then e:SetMaxLetters(maxLetters) end
		e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	end
	local h = e:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	h:SetPoint("LEFT", e.ghTemplate and 2 or 8, 0)
	h:SetText(hint or "")
	e.hint = h
	local function UpdateHint(self) self.hint:SetShown(self:GetText() == "" and not self:HasFocus()) end
	e:HookScript("OnEditFocusGained", UpdateHint)
	e:HookScript("OnEditFocusLost", UpdateHint)
	e:HookScript("OnTextChanged", UpdateHint)
	return e
end

------------------------------------------------------------------------
-- Menus (Sort, Dungeon): WowStyle1DropdownTemplate filled by its own SetupMenu (MenuUtil).
-- Returns nil when the template or the menu system is missing (the caller keeps its old button).
------------------------------------------------------------------------
function W.Dropdown(parent, width)
	local dd = W.FromTemplate("DropdownButton", nil, parent, "dropdown")
	if not dd then return nil end
	if not (dd.SetupMenu and dd.GenerateMenu) then
		dd:Hide()
		return nil
	end
	dd:SetWidth(width)
	function dd:SetLabel(t) -- our own text ("Sort: Activity"), not the picked entry's
		if self.OverrideText then self:OverrideText(t) else self:SetText(t) end
	end
	function dd:SetActive() end
	function dd:CloseMenuIfOpen()
		if self.IsMenuOpen and self.CloseMenu and self:IsMenuOpen() then self:CloseMenu() end
	end
	dd.isDropdown = true
	return dd
end

------------------------------------------------------------------------
-- Scrolling lists: WowScrollBoxList + MinimalScrollBar + a linear view, else nil (the caller
-- keeps its own rows and slider). init(rowFrame, rowData) fills a row; rows are reused.
------------------------------------------------------------------------
function W.ScrollList(parent, extent, init)
	if not (CreateScrollBoxListLinearView and CreateDataProvider and ScrollUtil and ScrollUtil.InitScrollBoxListWithScrollBar) then return nil end
	local box = W.FromTemplate("Frame", nil, parent, "scrollBox")
	if not box then return nil end
	local bar = W.FromTemplate("EventFrame", nil, parent, "scrollBar")
	if not bar then box:Hide() return nil end
	local ok = pcall(function()
		local view = CreateScrollBoxListLinearView()
		view:SetElementExtent(extent)
		view:SetElementInitializer("Button", init)
		ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
	end)
	if not ok then
		box:Hide(); bar:Hide()
		return nil
	end
	return box, bar
end

-- Puts the rows into a ScrollBox list. keepPlace = stay at the same scroll position.
function W.SetListData(box, rows, keepPlace)
	local keep = keepPlace and (ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition or true) or nil
	box:SetDataProvider(CreateDataProvider(rows), keep)
end

-- Row parts shared by the full list and the mini window.
function W.RowHighlight(r)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture(W.ART.rowHighlight)
	hl:SetBlendMode("ADD")
	return hl
end

-- The colour a chat type has in the player's chat (Blizzard's ChatTypeInfo, filled by the chat
-- settings; Blizzard_ChatFrameBase\Shared\ChatTypeInfoConstants.lua), else a fixed fallback.
W.CHAT_FALLBACK = { CHANNEL1 = { 1, 0.75, 0.75 }, GUILD = { 0.25, 1, 0.25 } }
function W.ChatColor(kind)
	local info = type(ChatTypeInfo) == "table" and ChatTypeInfo[kind]
	if type(info) == "table" and type(info.r) == "number" and type(info.g) == "number" and type(info.b) == "number" then
		return { info.r, info.g, info.b }
	end
	return W.CHAT_FALLBACK[kind] or W.COLOR.highlight
end

-- A horizontal divider w wide (the divider atlas, else a thin grey line). Caller sets the point.
function W.Divider(parent, w)
	local line = parent:CreateTexture(nil, "ARTWORK")
	if W.HasAtlas(W.ART.divider) then
		line:SetAtlas(W.ART.divider)
		line:SetSize(w, 4)
	else
		line:SetColorTexture(0.6, 0.6, 0.6, 0.4)
		line:SetSize(w, 1)
	end
	return line
end

-- Thin line to the right of a group header text (only if the atlas exists).
function W.HeaderLine(r, header)
	if not W.HasAtlas(W.ART.divider) then return nil end
	local line = r:CreateTexture(nil, "ARTWORK")
	line:SetAtlas(W.ART.divider, true)
	line:SetPoint("LEFT", header, "RIGHT", 8, 0)
	line:SetPoint("RIGHT", r, "RIGHT", -8, 0)
	return line
end

------------------------------------------------------------------------
-- 1.0.0-beta.1 badge: a 14 px circle with a count; never changes the size of what it sits on.
------------------------------------------------------------------------
function W.Badge(parent)
	local b = CreateFrame("Frame", nil, parent)
	b:SetSize(14, 14)
	local tex = b:CreateTexture(nil, "OVERLAY")
	tex:SetAllPoints()
	local art = W.ART.badge
	if W.HasAtlas(art.atlas) then
		tex:SetAtlas(art.atlas)
		b.art = "atlas"
	else
		tex:SetTexture(art.file)
		tex:SetVertexColor(0.85, 0.1, 0.1)
		if tex.SetMask then pcall(tex.SetMask, tex, art.mask) end
		b.art = "file"
	end
	b.tex = tex
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("CENTER", 0, 0)
	b.text = fs
	function b:SetCount(n) self.text:SetText(n > 9 and "9+" or tostring(n)) end
	b:Hide()
	return b
end

------------------------------------------------------------------------
-- The alert note: small, top of the screen, 10 seconds, no sound, never takes the keyboard.
-- 1.0.0-beta.1: drawn by the queue (UI\Toasts.lua); when it closes the queue shows the next one.
------------------------------------------------------------------------
local TOAST_SECONDS = 10

function GH:ShowToast(sender, text, e)
	local t = self.toast
	if not t then
		t = W.Popup("GuildHubToast", UIParent, 0.94)
		t:SetSize(380, 74)
		t:SetPoint("TOP", UIParent, "TOP", 0, -140)
		t:SetFrameStrata("HIGH")
		local icon = t:CreateTexture(nil, "ARTWORK")
		icon:SetTexture(W.ART.toastIcon)
		icon:SetSize(16, 16)
		icon:SetPoint("TOPLEFT", 10, -8)
		t.icon = icon
		t.title = W.Text(t, "GameFontNormal", L.TOAST_TITLE)
		t.title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
		t.text = W.Text(t, "GameFontHighlight")
		t.text:SetPoint("TOPLEFT", 10, -28)
		t.text:SetPoint("RIGHT", -10, 0)
		-- 1.0.0-beta.1 "I can help" on a Need-help note (fills a whisper; Features\Actions.lua)
		t.canHelp = W.Button(t, L.BTN_CANHELP, 84, 22)
		t.canHelp:SetPoint("BOTTOMLEFT", 10, 8)
		if t.canHelp.SetMotionScriptsWhileDisabled then t.canHelp:SetMotionScriptsWhileDisabled(true) end
		t.canHelp:SetScript("OnClick", function()
			if GH.CanHelp and GH:CanHelp(t.sender) then t:Hide() end
		end)
		t.canHelp:SetScript("OnEnter", function(b) if GH.CanHelpTooltip then GH:CanHelpTooltip(b, t.sender) end end)
		t.canHelp:SetScript("OnLeave", function() GameTooltip:Hide() end)
		t.whisper = W.Button(t, L.BTN_WHISPER, 76, 22)
		t.whisper:SetPoint("BOTTOMLEFT", 10, 8)
		t.whisper:SetScript("OnClick", function()
			GH:WhisperMember(t.sender)
			t:Hide()
		end)
		t.mute = W.Button(t, L.BTN_MUTE, 64, 22)
		t.mute:SetPoint("LEFT", t.whisper, "RIGHT", 6, 0)
		t.mute:SetScript("OnClick", function()
			GH:Mute(t.sender)
			t:Hide()
		end)
		t.close = W.TitleButton(t, "close")
		t.close:SetPoint("TOPRIGHT", 2, 2)
		-- 0.6.0-beta.3: right-click the note = the name menu for its sender (UI\NameMenu.lua)
		t:EnableMouse(true)
		t:SetScript("OnMouseUp", function(note, button)
			if button == "RightButton" and note.sender and GH.ShowNameMenu then GH:ShowNameMenu(note, note.sender, "toast") end
		end)
		t:SetScript("OnUpdate", function(self, elapsed)
			self.left = (self.left or 0) - elapsed
			if self.left <= 0 then self:Hide() end
		end)
		t:SetScript("OnHide", function() if GH.ToastNext then GH:ToastNext() end end)
		self.toast = t
	end
	t.sender = sender
	t.kind = e and e.kind
	-- 1.0.1: the title follows the kind ("Need a rez"); a plain FontString, no secure button anywhere
	t.title:SetText((e and type(e.title) == "string" and e.title) or L.TOAST_TITLE)
	t.text:SetText(text) -- already cleaned (no colour, link or texture codes)
	local person = sender ~= nil and t.kind ~= "test"
	local help = person and t.kind == "help"
	t.canHelp:SetShown(help)
	if help then
		local ok = GH.CanHelpState and GH:CanHelpState(sender)
		t.canHelp:SetEnabled(ok and true or false)
		t.canHelp:SetGreyed(not ok)
	end
	t.whisper:ClearAllPoints()
	if help then t.whisper:SetPoint("LEFT", t.canHelp, "RIGHT", 6, 0) else t.whisper:SetPoint("BOTTOMLEFT", 10, 8) end
	t.whisper:SetShown(person)
	t.mute:SetShown(person)
	t.left = TOAST_SECONDS
	t:Show()
end
