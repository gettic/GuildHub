-- Guild Hub: Guild Recruiter, beta R1 (plans\guild-recruiter\PLAN.md, tos-strict.md, tos-plan.md).
-- Officers set what the guild needs (roles, classes) and one recruitment text; everybody sees the
-- guild makeup and can Copy the text (/ghub recruit) or post it in General / Trade with the page's
-- Post buttons or the macro /ghub ad <channel> (both go through PostAd with every cap).
--
-- Rules kept here (tos, the user's words in PLAN.md):
--  * PostAd (/ghub ad and the page's Post buttons) is the ONLY place that sends to a public channel:
--    one post per key press or click (the send runs inside it), General or
--    Trade only, never in combat / an instance / chat lockdown, never from a timer, event or message,
--    no retry, nothing put in the chat box when the game refuses it.
--  * Fixed caps (constants, not settings): 1 try per player per hour (all channels; failed tries
--    count), 2 posts per hour for the whole guild, 20 min between two posts in the same channel.
--  * The text: officers only (checked in OUR guild list on every receive), 200 characters, no links,
--    web addresses, "Blizzard"/"GM"/"[Official]" or gold words; cleaned again on receive.
--  * The Discord invite is shown only in the Copy box: never sent in chat or put in the chat box.
--  * Ad post times (RADP) can only stop posting, never start it; kept in memory only.
--  * "Say welcome" fills the guild chat box; the player presses Enter. ("Share in guild chat" was
--    removed, the user's choice 2026-11-19.)
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

------------------------------------------------------------------------
-- Fixed caps (the self-test checks these values, tos condition 11)
------------------------------------------------------------------------
local NEED_DAYS = 14          -- "We need" and the class marks expire unless renewed
local AD_MAX = 200            -- characters of recruitment text
local DC_MAX = 60             -- characters of the Discord invite
local AD_OWN_GAP = 3600       -- one try per player per hour, all channels together (failed tries count)
local AD_GUILD_PER_HOUR = 2   -- posts per hour for the whole guild together
local AD_GUILD_GAP = 1200     -- seconds between two guild posts in the same channel (and zone)
local AD_WINDOW = 3600        -- how long post times are kept (memory only)
local ECHO_WAIT = 3           -- seconds to wait for our own post to come back
local ECHO_LATE = 15          -- no echo by then: still listening for a late one until here
local ROLE_MAX = 9
local JOIN_BURST = 3          -- more new names at once = a guild-list hiccup, not joins
local POSTS_MAX = 20          -- post times kept / sent
local WELCOME_KEEP = 30 * 86400
local OWN_JOIN_RECENT = 2 * 86400

-- channels the ad may go to: kind -> the first word of the game's channel name (tos: no LFG, no
-- custom channels, no SAY/YELL/whispers)
local AD_CHANNELS = { trade = "Trade", general = "General" }
local AD_KINDS = { "trade", "general" }
local TEST_CHANNEL = "ghtest" -- /ghub test post only: a private channel the user joined

local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local ROLES = { "t", "h", "d" }
local MACRO_POST, MACRO_COPY, MACRO_TEST = "GH Recruit", "GH Ad Copy", "GH Test Post"
local MARKER = "#guildhub" -- first line of every macro we make ("#" lines do nothing in a macro)
local ICONS = { "INV_Scroll_03", "INV_Letter_15", "INV_Misc_Note_01", "INV_Misc_GroupNeedMore", "INV_Banner_02", "INV_Misc_QuestionMark" }

-- words that make a text unusable (any case, whole words); tos: no Blizzard/GM/official look, no gold
local BANNED = { "blizzard", "gm", "gms", "game master", "official", "gold", "boost", "boosts", "boosting",
	"paypal", "usd", "cash", "real money", "wts" }
local BANNED_CHARS = { "$", "\226\130\172", "\194\163" } -- $, euro, pound
local TLDS = { "com", "net", "org", "gg", "io", "tv", "eu", "de", "uk", "me", "co", "ly", "be", "info", "xyz", "fr", "nl", "ru" }

GH.RECRUIT_CLASSES, GH.RECRUIT_ROLES, GH.RECRUIT_ICONS = CLASSES, ROLES, ICONS
GH.RECRUIT_KINDS, GH.RECRUIT_CHANNELS = AD_KINDS, AD_CHANNELS
GH.RECRUIT_CAPS = {
	NEED_DAYS = NEED_DAYS, AD_MAX = AD_MAX, DC_MAX = DC_MAX, AD_OWN_GAP = AD_OWN_GAP,
	AD_GUILD_PER_HOUR = AD_GUILD_PER_HOUR, AD_GUILD_GAP = AD_GUILD_GAP, ECHO_WAIT = ECHO_WAIT, ECHO_LATE = ECHO_LATE,
}
GH.RECRUIT_MACROS = { post = MACRO_POST, copy = MACRO_COPY, test = MACRO_TEST, marker = MARKER }

GH.adPosts = {}          -- { { b = name, k = kind, z = zone, t = time } } last hour, memory only
GH.adStats = { radp = 0, rads = 0, dropped = 0 } -- self-test: post times heard / caught up / refused

local function Now() return U.Now() end
local function On() return GH:FeatureOn("recruit") end

------------------------------------------------------------------------
-- Saved data: gdb.recruit (per guild) and global.recruitCaps (per account)
------------------------------------------------------------------------
local function Data()
	local gdb = GH.db and GH:GetGuildDB()
	if not gdb then return nil end
	local r = gdb.recruit
	if type(r) ~= "table" then r = {}; gdb.recruit = r end
	if type(r.pub) ~= "table" then r.pub = {} end
	if type(r.welcomed) ~= "table" then r.welcomed = {} end
	GH:CheckRecruitData(r) -- once per session per guild table
	return r
end
GH.RecruitData = function() return Data() end

-- Damaged saved data: the text record is cleaned like a received one (bad parts dropped), old
-- welcome marks forgotten. Runs once per session per guild.
function GH:CheckRecruitData(r)
	self.recruitChecked = self.recruitChecked or {}
	if self.recruitChecked[r] then return end
	self.recruitChecked[r] = true
	local p = r.pub
	if next(p) ~= nil then
		local clean = self:CleanRecruitPub(p)
		r.pub = clean or {}
	end
	local cut = Now() - WELCOME_KEEP
	for name, t in pairs(r.welcomed) do
		if type(name) ~= "string" or type(t) ~= "number" or t < cut then r.welcomed[name] = nil end
	end
end

-- The per-account caps. A damaged entry counts as "just used" (strict: a broken file never allows
-- an extra post).
local function Caps()
	local g = GH.db.global
	local c = g.recruitCaps
	if type(c) ~= "table" then c = {}; g.recruitCaps = c end
	local now = Now()
	if c.adTries ~= nil and type(c.adTries) ~= "table" then c.adTries = { now } end
	c.adTries = c.adTries or {}
	for i = #c.adTries, 1, -1 do
		local t = c.adTries[i]
		if type(t) ~= "number" or t ~= t or t > now then c.adTries[i] = now
		elseif t < now - AD_WINDOW then table.remove(c.adTries, i) end
	end
	c.share = nil -- the old "Share in guild chat" time (the button is gone)
	if c.noteSeen ~= nil and type(c.noteSeen) ~= "boolean" then c.noteSeen = nil end
	if c.testPost ~= nil and type(c.testPost) ~= "string" then c.testPost = nil end
	return c
end
GH.RecruitCaps = function() return Caps() end

local function MacroSet()
	local ch = GH.db.char
	local m = ch.recruitMacro
	if type(m) ~= "table" then m = {}; ch.recruitMacro = m end
	if not AD_CHANNELS[m.channel] then m.channel = "general" end -- General works in every zone, Trade only in cities
	if type(m.icon) ~= "number" or not ICONS[m.icon] then m.icon = 3 end
	if type(m.made) ~= "table" then m.made = {} end
	return m
end
GH.RecruitMacroSet = function() return MacroSet() end

------------------------------------------------------------------------
-- Cleaning the text and the Discord invite
------------------------------------------------------------------------
-- Letters, not bytes (UTF-8: continuation bytes 0x80-0xBF don't start a letter).
local CHAT_BYTES = 255 -- the game's limit for one chat line
local function Letters(s)
	if type(s) ~= "string" then return 0 end
	local n = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 0x80 or b >= 0xC0 then n = n + 1 end
	end
	return n
end
GH.AdLetters = Letters

-- Returns the clean text, or nil and why ("empty", "link", "long", "web", "word").
-- Long = over AD_MAX letters, or over the chat line's 255 bytes.
function GH:CleanAd(s)
	if type(s) ~= "string" or U.IsSecret(s) then return nil, "empty" end
	if s:find("|H", 1, true) or s:find("|h", 1, true) then return nil, "link" end
	s = s:gsub("[\r\n\t]", " ")
	s = U.CleanText(s, 2000)
	if not s then return nil, "empty" end
	s = s:gsub("%s+", " ")
	if Letters(s) > AD_MAX or #s > CHAT_BYTES then return nil, "long" end
	local low = s:lower()
	if low:find("://", 1, true) or low:find("www.", 1, true) then return nil, "web" end
	for _, tld in ipairs(TLDS) do
		if low:find("[%w%-]%." .. tld .. "%f[^%w]") then return nil, "web" end
	end
	for _, w in ipairs(BANNED) do
		if low:find("%f[%w]" .. w .. "%f[^%w]") then return nil, "word" end
	end
	for _, c in ipairs(BANNED_CHARS) do
		if low:find(c, 1, true) then return nil, "word" end
	end
	return s
end

-- Only "discord.gg/<code>" or "discord.com/invite/<code>" (https:// and www. allowed in front).
-- Returns the short form or nil.
function GH:CleanDiscord(s)
	if type(s) ~= "string" or U.IsSecret(s) then return nil end
	s = s:match("^%s*(.-)%s*$")
	if #s > DC_MAX + 12 then return nil end
	local low = s:lower()
	local start = 1
	local a, b = low:find("^https?://")
	if a then start = b + 1 end
	if low:sub(start, start + 3) == "www." then start = start + 4 end
	local rest, restLow = s:sub(start), low:sub(start)
	local code
	if restLow:sub(1, 11) == "discord.gg/" then code = rest:sub(12)
	elseif restLow:sub(1, 19) == "discord.com/invite/" then code = rest:sub(20) end
	if not code or code == "" or #code > 32 or code:find("[^%w%-]") then return nil end
	local short = (restLow:sub(1, 11) == "discord.gg/" and "discord.gg/" or "discord.com/invite/") .. code
	if #short > DC_MAX then return nil end
	return short
end

-- A received or saved text record, cleaned. Officer checks happen in MergeRecruitPub (they need
-- the guild list). Returns nil when the record itself is unusable.
function GH:CleanRecruitPub(d)
	if type(d) ~= "table" then return nil end
	local by, ts = U.ValidName(d.by), U.ValidTime(d.ts)
	local v = U.ValidNumber(d.v, 0, 1e9)
	if not by or not ts or not v then return nil end
	local p = { by = by, ts = ts, v = math.floor(v), post = d.post == true or nil }
	if type(d.need) == "table" then
		p.need = {}
		for _, r in ipairs(ROLES) do
			local n = U.ValidNumber(d.need[r], 0, ROLE_MAX)
			p.need[r] = n and math.floor(n) or 0
		end
	end
	if type(d.cls) == "table" then
		p.cls = {}
		for _, c in ipairs(CLASSES) do
			local x = d.cls[c]
			if x == 1 or x == 2 then p.cls[c] = x end
		end
	end
	p.exp = U.ValidNumber(d.exp, 0, Now() + NEED_DAYS * 86400 + 3600)
	if d.ad ~= nil then p.ad = self:CleanAd(d.ad) end -- a bad text is dropped, the rest kept
	if d.dc ~= nil then
		local dc, dcBy, dcTs = self:CleanDiscord(d.dc), U.ValidName(d.dcBy), U.ValidTime(d.dcTs)
		if dc and dcBy and dcTs then p.dc, p.dcBy, p.dcTs = dc, dcBy, dcTs end
	end
	return p
end

-- The guild's record (read-only view; nil fields when nothing is set).
function GH:RecruitPub()
	local r = Data()
	return r and r.pub or {}
end

-- What officers asked for, if it hasn't expired: need table, cls table, set by, set at.
function GH:RecruitNeeds()
	local p = self:RecruitPub()
	if not p.by or not p.exp or p.exp < Now() then return nil end
	return p.need, p.cls, p.by, p.ts
end

------------------------------------------------------------------------
-- RPUB: the officers' record (needs + text + Discord + post switch)
------------------------------------------------------------------------
function GH:RefreshRecruit()
	if self.DrawRecruitPage then self:DrawRecruitPage() end
end

-- Received (or answered after a HELLO): only from an officer, made by an officer, newer than ours.
function GH:MergeRecruitPub(data, sender)
	if not self.rosterReady then return false end
	if not self:IsOfficer(sender) then
		self:Debug("ignored recruiting text from %s (not an officer)", U.ShortName(sender))
		return false
	end
	local p = self:CleanRecruitPub(data)
	if not p or not self:IsOfficer(p.by) then
		self:Debug("ignored recruiting text (bad data or not made by an officer)")
		return false
	end
	if p.dc and not self:IsOfficer(p.dcBy) then p.dc, p.dcBy, p.dcTs = nil, nil, nil end
	local r = Data()
	if not r then return false end
	local cur = r.pub
	local cv, cts = cur.v or 0, cur.ts or 0
	if p.v < cv or (p.v == cv and p.ts <= cts) then return false end
	r.pub = p
	self:Debug("recruiting text v%d from %s", p.v, U.ShortName(p.by))
	self:RefreshRecruit()
	return true
end

-- Officer: save and share. draft = { need, cls, ad, dc, post }. Returns ok, why.
function GH:SaveRecruitPub(draft)
	local me = self:MyName()
	if not IsInGuild() or not self:IsOfficer(me) then return false, "officer" end
	local r = Data()
	if not r then return false, "guild" end
	draft = type(draft) == "table" and draft or {}
	local ad, why
	if type(draft.ad) == "string" and draft.ad:match("%S") then
		ad, why = self:CleanAd(draft.ad)
		if not ad then return false, why end
	end
	local dc
	if type(draft.dc) == "string" and draft.dc:match("%S") then
		dc = self:CleanDiscord(draft.dc)
		if not dc then return false, "discord" end
	end
	local cur, now = r.pub, Now()
	local p = { by = me, ts = math.max(now, (cur.ts or 0) + 1), v = (cur.v or 0) + 1,
		post = draft.post and true or nil, ad = ad, exp = now + NEED_DAYS * 86400, need = {}, cls = {} }
	for _, role in ipairs(ROLES) do
		local n = type(draft.need) == "table" and U.ValidNumber(draft.need[role], 0, ROLE_MAX)
		p.need[role] = n and math.floor(n) or 0
	end
	for _, c in ipairs(CLASSES) do
		local x = type(draft.cls) == "table" and draft.cls[c]
		if x == 1 or x == 2 then p.cls[c] = x end
	end
	if dc then
		if dc == cur.dc and cur.dcBy and self:IsOfficer(cur.dcBy) then
			p.dc, p.dcBy, p.dcTs = dc, cur.dcBy, cur.dcTs
		else
			p.dc, p.dcBy, p.dcTs = dc, me, now
		end
	end
	r.pub = p
	self:SendMsg("RPUB", p)
	self:RefreshRecruit()
	return true
end

local function HandlePub(self, sender, data, distribution, isSelf)
	if distribution ~= "GUILD" then return end
	self.rpubSeen = GetTime() -- somebody answered (also our own echo): the others stay quiet
	if isSelf then return end
	self:MergeRecruitPub(data, sender)
end

------------------------------------------------------------------------
-- Ad post times: RADP (one post, from the member who posted) and RADS (the last hour, answering
-- a HELLO). They can only STOP posting (tos condition 10).
------------------------------------------------------------------------
local function ValidKind(k) return type(k) == "string" and AD_CHANNELS[k] and k or nil end

-- Adds one post time; returns true when it was new. The time is clamped to now; older than an
-- hour = dropped.
function GH:AddAdPost(by, kind, zone, t)
	kind = ValidKind(kind)
	if not kind or type(by) ~= "string" then GH.adStats.dropped = GH.adStats.dropped + 1 return false end
	local now = Now()
	t = U.ValidNumber(t, 0, math.huge) or now
	if t > now then t = now end
	if t < now - AD_WINDOW then return false end
	zone = (type(zone) == "string" and U.CleanText(zone, 40)) or ""
	for _, e in ipairs(self.adPosts) do
		if e.b == by and e.k == kind and math.abs(e.t - t) < 30 then return false end
	end
	table.insert(self.adPosts, { b = by, k = kind, z = zone, t = t })
	table.sort(self.adPosts, function(a, b) return a.t > b.t end)
	while #self.adPosts > POSTS_MAX do table.remove(self.adPosts) end
	self:RefreshRecruit()
	return true
end

function GH:RecentAdPosts()
	local cut = Now() - AD_WINDOW
	for i = #self.adPosts, 1, -1 do
		if self.adPosts[i].t < cut then table.remove(self.adPosts, i) end
	end
	return self.adPosts
end

local function HandleADP(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" or type(data) ~= "table" then return end
	if self:AddAdPost(sender, data.k, data.z, data.t) then self.adStats.radp = self.adStats.radp + 1 end
end

-- The catch-up answer: post times of the last hour (any guild member may answer; the names in it
-- must be guild members).
function GH:MergeAdPosts(list)
	if type(list) ~= "table" then return 0 end
	local n, added = 0, 0
	for _, e in ipairs(list) do
		n = n + 1
		if n > POSTS_MAX then break end
		local by = type(e) == "table" and U.ValidName(e.b)
		if by and self:IsGuildMember(by) and self:AddAdPost(by, e.k, e.z, e.t) then added = added + 1
		else self.adStats.dropped = self.adStats.dropped + 1 end
	end
	return added
end

local function HandleADS(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "WHISPER" or type(data) ~= "table" then return end
	local added = self:MergeAdPosts(data.p)
	self.adStats.rads = self.adStats.rads + 1
	self.adPostsHeard = true -- the guild's recent post times are here: posting may go on
	self:Debug("ad post times from %s: %d new", U.ShortName(sender), added)
end

local function PostsPayload()
	local p = {}
	for _, e in ipairs(GH:RecentAdPosts()) do
		p[#p + 1] = { b = e.b, k = e.k, z = e.z ~= "" and e.z or nil, t = e.t }
		if #p >= POSTS_MAX then break end
	end
	return p
end

-- Sync.lua: somebody logged in. 1) Online officers with Guild Hub answer with the text record
-- if it may be news to them (the first in name order after 2 s; the next only if nobody answered).
-- 2) The first three sync responders whisper the ad post times of the last hour, so the guild's
-- 2-per-hour limit holds after a login.
function GH:RecruitOnHello(sender, data)
	if not On() or type(data) ~= "table" then return end
	local r = Data()
	if not r then return end
	local me = self:MyName()
	local since = U.ValidTime(data.since) or 0
	local helloAt = GetTime()
	if (r.pub.ts or 0) > since and self:IsOfficer(me) then
		local list = { me }
		for name in pairs(self.addonUsers) do
			if name ~= me and name ~= sender and self:IsOfficer(name) and self:IsAddonUserOnline(name) then list[#list + 1] = name end
		end
		table.sort(list)
		local rank
		for i, name in ipairs(list) do if name == me then rank = i break end end
		local delay = ({ 2, 6, 12 })[rank or 99]
		if delay then
			self:ScheduleTimer(function()
				if (GH.rpubSeen or -1) >= helloAt or not On() then return end
				local rr = Data()
				if rr and rr.pub.by then GH:SendMsg("RPUB", rr.pub) end
			end, delay)
		end
	end
	if data.inst ~= true then self:AnswerAdPosts(sender) end
end

-- The first three sync responders whisper the last hour's post times to the asker (HELLO or RADQ).
function GH:AnswerAdPosts(asker)
	if #self:RecentAdPosts() == 0 then return end
	local me, rank = self:MyName(), nil
	for i, name in ipairs(self:ResponderList(asker)) do
		if name == me then rank = i break end
	end
	local delay = ({ 3, 7, 11 })[rank or 99]
	if not delay then return end
	self:ScheduleTimer(function()
		if not On() or not GH:IsOnline(asker) then return end
		local p = PostsPayload()
		if #p > 0 then GH:SendMsg("RADS", { p = p }, asker) end
	end, delay)
end

-- RADQ: "I just left an instance, which post times did I miss?" (GUILD, no data)
local function HandleADQ(self, sender, _, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" or not On() then return end
	self:AnswerAdPosts(sender)
end

-- The login / /reload gap: post times live in memory only, so posting waits until the guild's
-- answer (RADS) arrived or CHECK_WAIT seconds after our HELLO / RADQ went out. Returns the seconds
-- still to wait (0 = done).
local CHECK_WAIT = 20
function GH:AdCheckWait()
	if self.adPostsHeard then return 0 end
	local from = self.adCheckFrom
	if not from then return CHECK_WAIT end -- our HELLO hasn't gone out yet
	return math.max(0, CHECK_WAIT - (GetTime() - from))
end

-- Sync.lua SendHello: start the wait (also after a re-HELLO).
function GH:RecruitHelloSent()
	self.adCheckFrom = GetTime()
	self.adPostsHeard = false
end

-- Leaving an instance (where addon messages are limited): ask once for the post times we missed.
local function OnWorld()
	local inInst = IsInInstance()
	if GH.recruitInInst and not inInst and IsInGuild() then
		GH.adCheckFrom, GH.adPostsHeard = GetTime(), false
		GH:SendMsg("RADQ", {})
	end
	GH.recruitInInst = inInst and true or false
end

------------------------------------------------------------------------
-- Guild makeup (from the guild list only)
------------------------------------------------------------------------
-- { [CLASS] = { n60, n50 } }, total members counted.
function GH:RecruitMakeup()
	local t, total = {}, 0
	for _, c in ipairs(CLASSES) do t[c] = { 0, 0 } end
	for _, m in pairs(self.roster) do
		local c = type(m.class) == "string" and t[m.class]
		if c and type(m.level) == "number" and not U.IsSecret(m.level) then
			total = total + 1
			if m.level >= 60 then c[1] = c[1] + 1 end
			if m.level >= 50 then c[2] = c[2] + 1 end
		end
	end
	return t, total
end

------------------------------------------------------------------------
-- /ghub ad <general|trade>: the post (one per key press)
------------------------------------------------------------------------
local function Minutes(sec) return math.max(1, math.ceil(sec / 60)) end

-- The game's channel for this kind: number and full name, or nil. Checked with GetChannelName
-- (tos condition 1): the name must start with the channel's word. kind nil = the test channel
-- (any name starting with "ghtest", e.g. "ghtestqzpw").
function GH:FindAdChannel(kind, word)
	local anyEnd = kind == nil
	word = word or AD_CHANNELS[kind]
	if not word or type(GetChannelName) ~= "function" then return nil end
	local w = word:lower()
	for i = 1, 20 do
		local ok, id, name = pcall(GetChannelName, i)
		if ok and type(id) == "number" and id > 0 and type(name) == "string" and not U.IsSecret(name) then
			local low = name:lower()
			local nextChar = low:sub(#w + 1, #w + 1)
			if low:sub(1, #w) == w and (anyEnd or nextChar == "" or nextChar == " " or nextChar == "(") then
				return id, name
			end
		end
	end
	return nil
end

local function ZoneOf(kind, name)
	if kind ~= "general" or type(name) ~= "string" then return "" end
	return U.CleanText(name:match("%-%s*(.+)$") or "", 40) or ""
end

-- Why posting is not possible right now (nil = it is). Returns text, plus the channel number/name.
-- Order: switches and text, channel, combat/instance/lockdown, one-time note, own cap, guild caps.
function GH:AdBlockReason(kind)
	if not On() then return L.AD_FEATURE_OFF end
	if not IsInGuild() then return L.NOT_IN_GUILD end
	local p = self:RecruitPub()
	if not p.post then return L.AD_POST_OFF end
	if not p.ad then return L.AD_NO_TEXT end
	if not ValidKind(kind) then return L.AD_BAD_CHANNEL end
	local id, name = self:FindAdChannel(kind)
	if not id then return L.AD_NOT_JOINED:format(AD_CHANNELS[kind]) end
	if InCombatLockdown() then return L.AD_COMBAT end
	if IsInInstance() then return L.AD_INSTANCE end
	if self:InLockdown() or (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()) then
		return L.AD_LOCKDOWN
	end
	if type(C_ChatInfo) ~= "table" or type(C_ChatInfo.SendChatMessage) ~= "function" then return L.AD_NO_API end
	local caps = Caps()
	if not caps.noteSeen then return nil, id, name, "note" end
	local now = Now()
	local last = 0
	for _, t in ipairs(caps.adTries) do last = math.max(last, t) end
	if now - last < AD_OWN_GAP then return L.AD_OWN_WAIT:format(Minutes(AD_OWN_GAP - (now - last))) end
	local wait = self:AdCheckWait()
	if wait > 0 then return L.AD_CHECKING:format(math.ceil(wait)) end
	local posts = self:RecentAdPosts()
	if #posts >= AD_GUILD_PER_HOUR then
		local oldest = posts[AD_GUILD_PER_HOUR] -- newest first: the 2nd newest frees a slot first
		return L.AD_GUILD_HOUR:format(AD_GUILD_PER_HOUR, Minutes(AD_WINDOW - (now - oldest.t)))
	end
	local zone = ZoneOf(kind, name)
	for _, e in ipairs(posts) do
		if e.k == kind and (kind ~= "general" or e.z == zone) and now - e.t < AD_GUILD_GAP then
			return L.AD_GUILD_GAP:format(U.ShortName(e.b), AD_CHANNELS[kind], Minutes(now - e.t), Minutes(AD_GUILD_GAP - (now - e.t)))
		end
	end
	if self.adPending then return L.AD_PENDING end
	return nil, id, name
end

local function EndPending()
	GH:Off("adpost")
	if GH.adPendingTimer then GH:CancelTimer(GH.adPendingTimer) end
	GH.adPendingTimer = nil
	local p = GH.adPending
	GH.adPending = nil
	return p
end

-- The post counts for the guild: kept here and told to the guild (RADP) once per post.
local function RecordPost(p)
	if p.recorded then return end
	p.recorded = true
	local now = Now()
	GH:AddAdPost(GH:MyName(), p.kind, p.zone, now)
	GH:SendMsg("RADP", { k = p.kind, z = p.zone ~= "" and p.zone or nil, t = now })
end

-- Our own line came back in the channel (also a late echo after "couldn't confirm").
local function PostConfirmed()
	local p = EndPending()
	if not p then return end
	local late = p.recorded
	RecordPost(p)
	GH.adLastResult = "sent"
	if not late then GH:Msg(L.AD_POSTED, AD_CHANNELS[p.kind]) else GH:Msg(L.AD_POSTED_LATE, AD_CHANNELS[p.kind]) end
end

-- The game refused it (blocked event or the send call failed): nothing was sent.
local function PostRefused()
	if not EndPending() then return end
	GH.adLastResult = "refused"
	GH:Msg(L.AD_REFUSED) -- nothing in the chat box, no retry (tos)
end

-- No echo after ECHO_WAIT s, but the send call worked and nothing was blocked: it probably went
-- out (a slow server), so it counts for the caps. Keep listening for a late echo until ECHO_LATE.
local function PostUnconfirmed()
	local p = GH.adPending
	if not p then return end
	RecordPost(p)
	GH.adLastResult = "unconfirmed"
	GH:Msg(L.AD_UNCONFIRMED)
	GH.adPendingTimer = GH:ScheduleTimer(function()
		GH.adPendingTimer = nil
		EndPending()
	end, ECHO_LATE - ECHO_WAIT)
end

-- The note the first press shows (nothing is sent; the next press posts).
function GH:ShowAdNote()
	local function Seen() Caps().noteSeen = true end
	self:Msg(L.AD_NOTE)
	if self.ShowCard then
		self:ShowCard({ key = "adnote", title = L.AD_NOTE_TITLE, text = L.AD_NOTE, note = L.AD_NOTE_NEXT,
			buttons = { { label = L.AD_NOTE_OK, fn = Seen } }, onClose = Seen })
	else
		Seen()
	end
end

-- The slash command (macro key press). Exactly one send, or a line saying why not.
function GH:PostAd(arg)
	-- the whole first word, exactly "trade" or "general" (any case): "trade5" or "generalchat" are refused
	local kind = type(arg) == "string" and arg:match("^%s*(%S+)") or nil
	kind = kind and kind:lower() or nil
	if kind == nil or kind == "" then
		return self:Msg(L.AD_USAGE)
	end
	local why, id, name, note = self:AdBlockReason(kind)
	if why then return self:Msg(why) end
	if note then return self:ShowAdNote() end
	local text = self:RecruitPub().ad
	-- the try counts before the send: failed tries count too (tos: no spamming failing presses)
	local caps = Caps()
	caps.adTries[#caps.adTries + 1] = Now()
	local me = U.ShortName(self:MyName())
	self.adPending = { kind = kind, zone = ZoneOf(kind, name), text = text, id = id }
	self:On("adpost", "CHAT_MSG_CHANNEL", function(_, msg, author, _, _, _, _, _, chanIndex)
		local p = GH.adPending
		if not p or U.IsSecret(msg) or U.IsSecret(author) then return end
		if msg == p.text and U.ShortName(author) == me and (chanIndex == nil or U.IsSecret(chanIndex) or chanIndex == p.id) then
			PostConfirmed()
		end
	end)
	local function Blocked(_, addon)
		if addon ~= "GuildHub" then return end
		GH.chatPostBlockedAt = GetTime() -- MapPins' taint counter: an expected refusal, not taint
		local p = GH.adPending
		if p and not p.recorded then PostRefused() end
	end
	self:On("adpost", "ADDON_ACTION_BLOCKED", Blocked)
	self:On("adpost", "ADDON_ACTION_FORBIDDEN", Blocked)
	self.adPendingTimer = self:ScheduleTimer(PostUnconfirmed, ECHO_WAIT)
	local ok = pcall(C_ChatInfo.SendChatMessage, text, "CHANNEL", nil, id)
	if not ok then PostRefused() end
end

------------------------------------------------------------------------
-- Copy, the chat-box helper (Say welcome) and the post status
------------------------------------------------------------------------
local function OpenChatWith(text)
	local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
	if open then return pcall(open, text) end
	return false
end

-- /ghub recruit: the Copy box (UI\RecruitPage.lua draws it). Works with posting switched off.
function GH:RecruitCopy()
	if not On() then return self:Msg(L.AD_FEATURE_OFF) end
	if not IsInGuild() then return self:Msg(L.NOT_IN_GUILD) end
	if self.ShowRecruitCopyBox then self:ShowRecruitCopyBox() end
end

-- The short line next to the page's Post buttons: "Ready" / "Post again in N min" / "Posting is
-- off (officers)" / "Checking..." / "Not now". "Ready" uses AdBlockReason, like the buttons;
-- the channel-specific reasons (not joined, guild spacing) show on each button's tooltip.
function GH:AdShortStatus()
	local p = self:RecruitPub()
	if not On() or not IsInGuild() then return L.AD_FEATURE_OFF, false end
	if not p.post then return L.AD_STATUS_OFF, false end
	if not p.ad then return L.AD_NO_TEXT, false end
	local caps, now = Caps(), Now()
	local last = 0
	for _, t in ipairs(caps.adTries) do last = math.max(last, t) end
	local wait = (last > 0 and now - last < AD_OWN_GAP) and (AD_OWN_GAP - (now - last)) or 0
	local posts = self:RecentAdPosts()
	if #posts >= AD_GUILD_PER_HOUR then
		wait = math.max(wait, AD_WINDOW - (now - posts[AD_GUILD_PER_HOUR].t))
	end
	if wait > 0 then return L.AD_STATUS_WAIT:format(Minutes(wait)), false end
	if InCombatLockdown() or IsInInstance() then return L.AD_STATUS_LATER, false end
	local check = self:AdCheckWait()
	if check > 0 then return L.AD_STATUS_CHECKING:format(math.ceil(check)), false end
	-- "Ready" only when a button really is (same checks as the buttons: channel, guild spacing)
	for kind in pairs(AD_CHANNELS) do
		local why, _, _, note = self:AdBlockReason(kind)
		if why == nil or note then return L.AD_STATUS_READY, true end
	end
	return L.AD_STATUS_BUTTONS, false
end

-- The longer status (tooltip): own wait, the guild's last post.
function GH:AdStatusText()
	local p = self:RecruitPub()
	if not p.post then return L.AD_STATUS_OFF end
	local caps, now = Caps(), Now()
	local last = 0
	for _, t in ipairs(caps.adTries) do last = math.max(last, t) end
	local own = (now - last < AD_OWN_GAP) and L.AD_STATUS_WAIT:format(Minutes(AD_OWN_GAP - (now - last))) or L.AD_STATUS_READY
	local posts = self:RecentAdPosts()
	local e = posts[1]
	local guild = e and L.AD_STATUS_GUILD:format(#posts, AD_GUILD_PER_HOUR, U.ShortName(e.b), AD_CHANNELS[e.k] or "?", U.Ago(now - e.t))
		or L.AD_STATUS_NONE
	return own .. "  " .. guild
end

------------------------------------------------------------------------
-- Macros: "GH Recruit" (/ghub ad <channel>) and "GH Ad Copy" (/ghub recruit), character macros
-- made only on a click, out of combat, never over a macro of the player's own.
------------------------------------------------------------------------
function GH:RecruitMacroBody(which, channel)
	if which == "copy" then return MARKER .. "\n/ghub recruit" end
	if which == "test" then return MARKER .. "\n/ghub test post run" end
	return MARKER .. "\n/ghub ad " .. (AD_CHANNELS[channel] and channel or "trade")
end

-- index, ours (made by us), body; nil when there is no macro with that name.
function GH:FindRecruitMacro(name)
	if type(GetMacroIndexByName) ~= "function" or type(GetMacroInfo) ~= "function" then return nil end
	local ok, idx = pcall(GetMacroIndexByName, name)
	if not ok or type(idx) ~= "number" or idx <= 0 then return nil end
	local okI, _, _, body = pcall(GetMacroInfo, idx)
	if not okI then return nil end
	return idx, type(body) == "string" and body:sub(1, #MARKER) == MARKER, body
end

-- Used / free character macro slots (nil when the game doesn't tell).
function GH:MacroSlots()
	if type(GetNumMacros) ~= "function" then return nil end
	local ok, _, numChar = pcall(GetNumMacros)
	if not ok or type(numChar) ~= "number" then return nil end
	local max = Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_CHARACTER_MACROS
	if type(max) ~= "number" then max = 18 end
	return numChar, max
end

-- Our macro's name for "post"/"copy": the base name, or "<base> 2" when the player has a macro of
-- their own with the base name. Returns name, index (or nil), taken (both names are the player's).
function GH:RecruitMacroName(which)
	local base = which == "copy" and MACRO_COPY or (which == "test" and MACRO_TEST or MACRO_POST)
	local idx, ours = self:FindRecruitMacro(base)
	if not idx or ours then return base, idx end
	local alt = base .. " 2"
	local idx2, ours2 = self:FindRecruitMacro(alt)
	if not idx2 or ours2 then return alt, idx2 end
	return nil, nil, true
end

-- State for the page: exists, needsUpdate, name, index.
function GH:RecruitMacroState(which)
	local name, idx, taken = self:RecruitMacroName(which)
	if taken then return { taken = true } end
	local set = MacroSet()
	local st = { name = name, index = idx, exists = idx ~= nil }
	if idx then
		local _, _, body = self:FindRecruitMacro(name)
		local made = set.made[which]
		st.needsUpdate = body ~= self:RecruitMacroBody(which, set.channel)
			or type(made) ~= "table" or made.icon ~= set.icon
	end
	return st
end

-- The click: make or update. Returns ok, message.
function GH:MakeRecruitMacro(which)
	which = which == "copy" and "copy" or (which == "test" and "test" or "post")
	if InCombatLockdown() then return false, L.MAC_COMBAT end
	if type(CreateMacro) ~= "function" or type(EditMacro) ~= "function" then return false, L.MAC_NOAPI end
	local set = MacroSet()
	local name, idx, taken = self:RecruitMacroName(which)
	if taken then return false, L.MAC_TAKEN end
	local body = self:RecruitMacroBody(which, set.channel)
	local icon = ICONS[which == "test" and 6 or set.icon] or ICONS[6]
	if idx then
		local ok = pcall(EditMacro, idx, name, icon, body)
		if not ok then return false, L.MAC_FAILED end
		if which ~= "test" then set.made[which] = { icon = set.icon, channel = set.channel } end
		self:RefreshRecruit()
		return true, L.MAC_UPDATED:format(name)
	end
	local used, max = self:MacroSlots()
	if used and used >= max then return false, L.MAC_FULL:format(used, max) end
	local ok, newIdx = pcall(CreateMacro, name, icon, body, true)
	if not ok or type(newIdx) ~= "number" then return false, L.MAC_FAILED end
	if which ~= "test" then set.made[which] = { icon = set.icon, channel = set.channel } end
	self:RefreshRecruit()
	return true, L.MAC_MADE:format(name)
end

-- Drag to the action bar (out of combat).
function GH:PickupRecruitMacro(which)
	if InCombatLockdown() or type(PickupMacro) ~= "function" then return false end
	local name, idx = self:RecruitMacroName(which)
	if not (name and idx) then return false end
	return pcall(PickupMacro, name)
end

------------------------------------------------------------------------
-- /ghub test post: proves that a macro key press counts as the hardware event on Forever.
-- Sends "Guild Hub test" ONLY to a channel whose name starts with "ghtest" (a private channel the
-- user joined). "timer" = the control without a key press (should be refused by the game).
------------------------------------------------------------------------
local TEST_TEXT = "Guild Hub test"

function GH:TestPostRun(mode)
	if InCombatLockdown() then return self:Msg(L.AD_COMBAT) end
	if IsInInstance() then return self:Msg(L.AD_INSTANCE) end
	if self.testPosting then return end
	local id = self:FindAdChannel(nil, TEST_CHANNEL)
	if not id then return self:Msg(L.TPOST_JOIN) end
	local st = { mode = mode == "timer" and "timer" or "key", sent = "-", echo = "n", blocked = "n" }
	self.testPosting = st
	local me = U.ShortName(self:MyName())
	self:On("testpost", "CHAT_MSG_CHANNEL", function(_, msg, author)
		if not U.IsSecret(msg) and not U.IsSecret(author) and msg == TEST_TEXT and U.ShortName(author) == me then st.echo = "y" end
	end)
	local function Blocked(_, addon) if addon == "GuildHub" then st.blocked = "y"; GH.chatPostBlockedAt = GetTime() end end
	self:On("testpost", "ADDON_ACTION_BLOCKED", Blocked)
	self:On("testpost", "ADDON_ACTION_FORBIDDEN", Blocked)
	local fn = C_ChatInfo and C_ChatInfo.SendChatMessage
	if type(fn) == "function" then
		local ok = pcall(fn, TEST_TEXT, "CHANNEL", nil, id)
		st.sent = ok and "sent" or "err"
	end
	C_Timer.After(ECHO_WAIT, function()
		GH:Off("testpost")
		GH.testPosting = nil
		local line = ("post=%s:%s,echo:%s,blocked:%s"):format(st.mode, st.sent, st.echo, st.blocked)
		Caps().testPost = line
		GH.lastTestPost = line
		GH:Msg(L.TPOST_RESULT, line)
		if st.mode == "key" then
			GH:Msg(st.echo == "y" and L.TPOST_WORKS or L.TPOST_FAILED)
		else
			GH:Msg((st.echo == "n") and L.TPOST_CONTROL_OK or L.TPOST_CONTROL_ODD)
		end
	end)
end

function GH:TestPost(sub)
	sub = type(sub) == "string" and sub:match("^%s*(%a*)") or ""
	if sub == "run" then return self:TestPostRun("key") end
	if sub == "timer" then
		return C_Timer.After(0.1, function() GH:TestPostRun("timer") end)
	end
	if sub == "remove" then
		if InCombatLockdown() then return self:Msg(L.MAC_COMBAT) end
		local idx, ours = self:FindRecruitMacro(MACRO_TEST)
		if idx and ours and type(DeleteMacro) == "function" and pcall(DeleteMacro, idx) then return self:Msg(L.TPOST_REMOVED) end
		return self:Msg(L.TPOST_NONE)
	end
	local ok, msg = self:MakeRecruitMacro("test")
	self:Msg(msg)
	if ok then
		for _, line in ipairs({ L.TPOST_STEP1, L.TPOST_STEP2, L.TPOST_STEP3, L.TPOST_STEP4 }) do
			DEFAULT_CHAT_FRAME:AddMessage(line)
		end
	end
end

------------------------------------------------------------------------
-- Joins: a note for guildmates ("Bob joined, thanks to Mira" + Say welcome) and a welcome card for
-- the new member. Only shown; nothing is sent.
------------------------------------------------------------------------
-- Who invited them, from the game's guild event log (read only; asked once per join).
local function FindInviter(joiner)
	if type(GetNumGuildEvents) ~= "function" or type(GetGuildEventInfo) ~= "function" then return nil end
	local ok, n = pcall(GetNumGuildEvents)
	if not ok or type(n) ~= "number" or U.IsSecret(n) then return nil end
	local short = U.ShortName(joiner)
	for i = 1, math.min(n, 50) do
		local okE, ty, p1, p2, _, y, mo, d = pcall(GetGuildEventInfo, i)
		if okE and ty == "invite" and not U.IsSecret(p2) and type(p2) == "string" and U.ShortName(p2) == short
			and (y or 0) == 0 and (mo or 0) == 0 and (d or 0) <= 1 and type(p1) == "string" and not U.IsSecret(p1) then
			return U.ShortName(p1)
		end
	end
	return nil
end

function GH:OnGuildJoin(name)
	local r = Data()
	if not r then return end
	self.recentJoins = self.recentJoins or {}
	self.recentJoins[name] = { t = Now() }
	if self.db.profile.recruitToasts ~= false and self.ShowJoinToast then self:ShowJoinToast(name) end
	-- "thanks to": ask the game for its log once (a harmless read), then look for the invite
	if type(QueryGuildEventLog) == "function" and not InCombatLockdown() then
		self:On("recruit", "GUILD_EVENT_LOG_UPDATE", function()
			for who, j in pairs(GH.recentJoins or {}) do
				if not j.by then j.by = FindInviter(who) end
			end
			if GH.UpdateJoinToast then GH:UpdateJoinToast() end
		end)
		pcall(QueryGuildEventLog)
	end
end

-- Say welcome: fills the guild chat box once per join (then greys out).
function GH:CanSayWelcome(name)
	local r = Data()
	return r ~= nil and type(name) == "string" and not r.welcomed[name]
end

function GH:SayWelcome(name)
	local r = Data()
	if not r or not self:CanSayWelcome(name) then return false end
	r.welcomed[name] = Now()
	OpenChatWith("/g " .. L.WELCOME_SAY:format(U.ShortName(name)))
	return true
end

-- Roster.lua after every guild-list rebuild: names that weren't there before = joins.
function GH:RecruitRosterCheck(roster)
	if self.RecruitOffRosterCheck then self:RecruitOffRosterCheck() end -- officer lists: ask / wipe
	local known = self.recruitKnown
	if not known then
		known = {}
		for name in pairs(roster) do known[name] = true end
		self.recruitKnown = known
		return
	end
	local new = {}
	for name in pairs(roster) do
		if not known[name] then new[#new + 1] = name; known[name] = true end
	end
	if #new == 0 or #new > JOIN_BURST or not On() then return end
	local me = self:MyName()
	for _, name in ipairs(new) do
		if name ~= me then self:OnGuildJoin(name) end
	end
	self:RefreshRecruit()
end

-- The new member's own welcome card: when the game's guild log (read by the guild history) shows
-- our own join in the last two days, once per guild and character.
function GH:RecruitWelcomeCheck()
	if not On() or not IsInGuild() then return end
	local gdb = self:GetGuildDB()
	local key = self:GuildKey()
	local ch = self.db.char
	if type(ch.recruitWelcome) ~= "table" then ch.recruitWelcome = {} end
	if not gdb or not key or ch.recruitWelcome[key] then return end
	local joins = type(gdb.rec) == "table" and type(gdb.rec.joins) == "table" and gdb.rec.joins
	local t = joins and joins[self:MyName()]
	if type(t) ~= "number" then return end
	ch.recruitWelcome[key] = true
	if Now() - t > OWN_JOIN_RECENT then return end
	if self.ShowCard then self:ShowCard(self:RecruitWelcomeSpec()) end
end

function GH:RecruitWelcomeSpec()
	local officers = {}
	for name, m in pairs(self.roster) do
		if m.online and self:IsOfficer(name) and name ~= self:MyName() then officers[#officers + 1] = U.ShortName(name) end
	end
	table.sort(officers)
	while #officers > 3 do table.remove(officers) end
	local guild = GetGuildInfo and GetGuildInfo("player")
	local text = L.WELCOME_CARD_BODY
	local ad = self:RecruitPub().ad
	if ad then text = text .. "\n\n" .. ad end
	return {
		key = "welcome-guild", title = L.WELCOME_CARD_TITLE:format(U.CleanText(guild, 40) or L.WELCOME_GUILD),
		text = text,
		note = #officers > 0 and L.WELCOME_CARD_ASK:format(table.concat(officers, ", ")) or nil,
		buttons = {
			{ label = L.WELCOME_CARD_TOUR, fn = function() if GH.ShowGuide then GH:ShowGuide() end end },
			{ label = L.WELCOME_CARD_CLOSE },
		},
	}
end

------------------------------------------------------------------------
-- The feature
------------------------------------------------------------------------
local function OfficerGate(gh) return gh:IsOfficer(gh:MyName()) end

local EXPECT = { NEED_DAYS = 14, AD_MAX = 200, DC_MAX = 60, AD_OWN_GAP = 3600, AD_GUILD_PER_HOUR = 2,
	AD_GUILD_GAP = 1200, ECHO_WAIT = 3, ECHO_LATE = 15 }
local ALLOWED_BODIES = { ["/ghub ad trade"] = true, ["/ghub ad general"] = true, ["/ghub recruit"] = true,
	["/ghub test post run"] = true }

-- Self-test part (tos condition 11 and the guild hour limit's catch-up).
local function SelfTest(api)
	api.Count()
	for k, v in pairs(EXPECT) do
		if GH.RECRUIT_CAPS[k] ~= v then api.Problem("RECRUIT", "caps", k .. " is " .. tostring(GH.RECRUIT_CAPS[k])) end
	end
	api.Count()
	local kinds = {}
	for k in pairs(AD_CHANNELS) do kinds[#kinds + 1] = k end
	table.sort(kinds)
	if table.concat(kinds, ",") ~= "general,trade" then api.Problem("RECRUIT", "channels", table.concat(kinds, ",")) end
	-- our macros: the marker and only allowed commands
	local found = {}
	for _, which in ipairs({ "post", "copy", "test" }) do
		api.Count()
		local name = GH:RecruitMacroName(which)
		local idx, ours, body
		if name then idx, ours, body = GH:FindRecruitMacro(name) end
		if idx and ours then
			found[#found + 1] = which
			for line in (body or ""):gmatch("[^\n]+") do
				if line ~= MARKER and not ALLOWED_BODIES[line] then api.Problem("RECRUIT", "macro", which .. " has another command") end
			end
		end
	end
	-- the record we hold passes the checks again
	api.Count()
	local p = GH:RecruitPub()
	if p.ad and GH:CleanAd(p.ad) ~= p.ad then api.Problem("RECRUIT", "text", "the saved text doesn't pass the checks") end
	if p.dc and GH:CleanDiscord(p.dc) ~= p.dc then api.Problem("RECRUIT", "discord", "the saved invite has a wrong shape") end
	-- post times: none in the future, none older than an hour, only allowed channels
	api.Count()
	local now = Now()
	for _, e in ipairs(GH:RecentAdPosts()) do
		if e.t > now then api.Problem("RECRUIT", "posts", "a post time in the future") break end
		if not AD_CHANNELS[e.k] then api.Problem("RECRUIT", "posts", "a post in another channel") break end
	end
	-- the catch-up merge on a copy: a future time is clamped, an old one and a bad channel dropped
	api.Count()
	local saved, savedStats = GH.adPosts, GH.adStats
	GH.adPosts, GH.adStats = {}, { radp = 0, rads = 0, dropped = 0 }
	local me = GH:MyName()
	local okM, added = pcall(GH.MergeAdPosts, GH, {
		{ b = me, k = "trade", t = now + 500 }, { b = me, k = "general", t = now - AD_WINDOW - 10 },
		{ b = me, k = "lfg", t = now }, { b = "x", k = "trade", t = now } })
	local copy = GH.adPosts
	GH.adPosts, GH.adStats = saved, savedStats
	if not okM then api.Problem("RECRUIT", "catch-up", "merge failed")
	elseif GH:IsGuildMember(me) and (added ~= 1 or #copy ~= 1 or copy[1].t > now) then
		api.Problem("RECRUIT", "catch-up", "merge kept " .. tostring(added))
	end
	-- the caps table reads strict
	api.Count()
	local caps = Caps()
	for _, t in ipairs(caps.adTries) do
		if type(t) ~= "number" or t > now then api.Problem("RECRUIT", "caps", "a damaged try time") break end
	end
	local used, max = GH:MacroSlots()
	local st = GH.adStats
	api.Info(("recruit ad v=%s post=%s text=%s dc=%s mac=%s slots=%s posts1h=%d heard=%d/%d lastpost=%s"):format(
		tostring(p.v or 0), p.post and "on" or "off", p.ad and "y" or "n", p.dc and "y" or "n",
		#found > 0 and table.concat(found, "+") or "n", used and (used .. "/" .. max .. " used") or "-",
		#GH:RecentAdPosts(), st.radp, st.rads, tostring(caps.testPost or "-")))
	if GH.RecruitOffSelfTest then GH:RecruitOffSelfTest(api) end -- R2 officer lists (own info line)
	if GH.RecruitToolsSelfTest then GH:RecruitToolsSelfTest(api) end -- R3 suggest, spotter, totals (own info line)
end

local MESSAGES = {
	RPUB = { class = "normal", min = 10, latest = true, gate = OfficerGate },
	RADP = { class = "normal", min = 1, latest = true },
	RADS = { class = "normal", min = 1 },
	RADQ = { class = "normal", min = 30, latest = true }, -- left an instance: ask for missed post times
}
for k, v in pairs(GH.RECRUIT_OFF_MESSAGES or {}) do MESSAGES[k] = v end -- R2 officer lists (Features\RecruitOff.lua)

GH:RegisterFeature({
	key = "recruit", name = "OPT_FEAT_RECRUIT",
	defaults = { profile = { recruitToasts = true, recruitSpot = false } },
	messages = MESSAGES,
	enable = function(gh)
		gh.recruitInInst = IsInInstance() and true or false
		gh:On("recruit", "PLAYER_ENTERING_WORLD", OnWorld)
		gh:On("recruit", "ZONE_CHANGED_NEW_AREA", OnWorld)
		if gh.RecruitOffEnable then gh:RecruitOffEnable() end
		if gh.RecruitToolsEnable then gh:RecruitToolsEnable() end
		gh:Every("recruit", "tidy", 30, function()
			GH:RecentAdPosts()
			GH:RecruitWelcomeCheck()
		end)
	end,
	disable = function(gh)
		gh:Off("adpost")
		gh:Off("testpost")
		gh.adPending, gh.testPosting = nil, nil
		if gh.RecruitOffDisable then gh:RecruitOffDisable() end
		if gh.RecruitToolsDisable then gh:RecruitToolsDisable() end
		if gh.HideJoinToast then gh:HideJoinToast() end
		gh:RefreshRecruit()
	end,
	selftest = SelfTest,
})
GH.handlers.RPUB = HandlePub
GH.handlers.RADP = HandleADP
GH.handlers.RADS = HandleADS
GH.handlers.RADQ = HandleADQ
