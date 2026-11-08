-- Guild Hub: small shared UI parts (panels, buttons, text boxes, the alert note).
-- Only our own plain frames and built-in game textures; no secure frames, no templates
-- except BackdropTemplate and UIPanelCloseButton.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local W = {}
ns.Widgets = W

local WHITE = "Interface\\Buttons\\WHITE8x8"
local BACKDROP = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }

W.GOLD = { 0.95, 0.78, 0.35 }
W.BORDER = { 0.45, 0.36, 0.18 }
W.BORDER_ON = { 0.95, 0.78, 0.35 }

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

-- Plain button with a thin gold border. b:SetActive(true) makes the border bright (chips).
function W.Button(parent, text, width, height, font)
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
	function b:SetLabel(t) self.label:SetText(t) end
	function b:SetActive(on)
		local c = on and W.BORDER_ON or W.BORDER
		self:SetBackdropBorderColor(c[1], c[2], c[3], 1)
		if on then self:SetBackdropColor(0.3, 0.24, 0.1, 0.95) else self:SetBackdropColor(0.12, 0.1, 0.07, 0.9) end
		self.label:SetTextColor(on and 1 or 0.9, on and 0.85 or 0.88, on and 0.5 or 0.8)
	end
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

-- Text box (never takes focus by itself). hint = grey text shown while empty.
function W.EditBox(parent, width, height, maxLetters, hint)
	local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
	e:SetSize(width, height or 24)
	W.Skin(e, 0.9, 0.03, 0.03, 0.02)
	e:SetFontObject("ChatFontNormal")
	e:SetTextInsets(8, 8, 0, 0)
	e:SetAutoFocus(false)
	if maxLetters then e:SetMaxLetters(maxLetters) end
	local h = e:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	h:SetPoint("LEFT", 8, 0)
	h:SetText(hint or "")
	e.hint = h
	local function UpdateHint(self) self.hint:SetShown(self:GetText() == "" and not self:HasFocus()) end
	e:HookScript("OnEditFocusGained", UpdateHint)
	e:HookScript("OnEditFocusLost", UpdateHint)
	e:HookScript("OnTextChanged", UpdateHint)
	e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	return e
end

------------------------------------------------------------------------
-- The alert note: small, top of the screen, 10 seconds, no sound, never takes the keyboard.
------------------------------------------------------------------------
local TOAST_SECONDS = 10

function GH:ShowToast(sender, text)
	local t = self.toast
	if not t then
		t = CreateFrame("Frame", "GuildHubToast", UIParent, "BackdropTemplate")
		t:SetSize(380, 74)
		t:SetPoint("TOP", UIParent, "TOP", 0, -140)
		t:SetFrameStrata("HIGH")
		W.Skin(t, 0.94)
		t.title = W.Text(t, "GameFontNormal", L.TOAST_TITLE)
		t.title:SetPoint("TOPLEFT", 10, -8)
		t.text = W.Text(t, "GameFontHighlight")
		t.text:SetPoint("TOPLEFT", 10, -26)
		t.text:SetPoint("RIGHT", -10, 0)
		t.whisper = W.Button(t, L.BTN_WHISPER, 70, 20)
		t.whisper:SetPoint("BOTTOMLEFT", 10, 8)
		t.whisper:SetScript("OnClick", function()
			GH:WhisperMember(t.sender)
			t:Hide()
		end)
		t.mute = W.Button(t, L.BTN_MUTE, 60, 20)
		t.mute:SetPoint("LEFT", t.whisper, "RIGHT", 6, 0)
		t.mute:SetScript("OnClick", function()
			GH:Mute(t.sender)
			t:Hide()
		end)
		t.close = CreateFrame("Button", nil, t, "UIPanelCloseButton")
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
