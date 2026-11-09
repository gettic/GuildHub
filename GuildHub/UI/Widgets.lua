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

-- kind: "close" (UIPanelCloseButton), "condense" (mini mode), "expand" (back to full).
-- size: optional square size; atlas buttons default to 32 (like the close button).
-- Returns the button; b.fallback = true when the plain button was used.
function W.TitleButton(parent, kind, size)
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
-- The alert note: small, top of the screen, 10 seconds, no sound, never takes the keyboard.
------------------------------------------------------------------------
local TOAST_SECONDS = 10

function GH:ShowToast(sender, text)
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
		t:SetScript("OnUpdate", function(self, elapsed)
			self.left = (self.left or 0) - elapsed
			if self.left <= 0 then self:Hide() end
		end)
		self.toast = t
	end
	t.sender = sender
	t.text:SetText(text) -- already cleaned (no colour, link or texture codes)
	t.left = TOAST_SECONDS
	t:Show()
end
