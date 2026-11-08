-- Guild Hub: small helpers (names, text cleaning, checks on received values, time).
local _, ns = ...
local L = ns.L

local U = {}
ns.Util = U

local type, tonumber, tostring = type, tonumber, tostring
local floor = math.floor
local strmatch, strgsub, strsub, strfind = string.match, string.gsub, string.sub, string.find

-- Secret values (Midnight restrictions): treat as "can't use".
local issecret = issecretvalue or function() return false end
U.IsSecret = function(v) return issecret(v) end

function U.Now()
	return GetServerTime()
end

-- Own realm without spaces, as used in "Name-Realm".
function U.MyRealm()
	return GetNormalizedRealmName and GetNormalizedRealmName() or nil
end

-- Always "Name-Realm".
function U.FullName(name)
	if type(name) ~= "string" or name == "" then return nil end
	if strfind(name, "-", 1, true) then return name end
	local realm = U.MyRealm()
	if not realm then return nil end
	return name .. "-" .. realm
end

function U.ShortName(full)
	if type(full) ~= "string" then return "?" end
	return (strmatch(full, "^([^%-]+)")) or full
end

-- Name to whisper: our own realm is dropped ("Mira Ashford-Realm" -> "Mira Ashford"), because
-- WoW Forever names ("Name Suffix", with a space) don't work with "-Realm". Other realms stay.
function U.WhisperName(key)
	if type(key) ~= "string" then return key end
	local realm = U.MyRealm()
	if realm then
		local suffix = "-" .. realm
		if #key > #suffix and strsub(key, -#suffix) == suffix then
			return strsub(key, 1, #key - #suffix)
		end
	end
	return key
end

-- A player name we accept from a message, always "Name-Realm" (see FullName).
-- WoW Forever names have one space inside ("Mira Ashford"), so single inner spaces are allowed;
-- no pipes, control characters, other whitespace, double/leading/trailing spaces.
function U.ValidName(name)
	if type(name) ~= "string" or issecret(name) or #name < 2 or #name > 64 then return nil end
	if strfind(name, "[|%c]") then return nil end
	if strfind(name, "[^ %S]") then return nil end -- whitespace other than a plain space
	if strfind(name, "  ", 1, true) or strfind(name, "^ ") or strfind(name, " $") then return nil end
	if strfind(name, " -", 1, true) or strfind(name, "- ", 1, true) then return nil end
	if not strfind(name, "-", 1, true) then return nil end
	return name
end

-- Remove colour codes, links, textures and any other "|" escape from text someone else sent,
-- remove control characters and cap the length. Returns nil if nothing usable is left.
function U.CleanText(s, maxLen)
	if type(s) ~= "string" or issecret(s) then return nil end
	s = strgsub(s, "|c%x%x%x%x%x%x%x%x", "")
	s = strgsub(s, "|cn[^:]*:", "")
	s = strgsub(s, "|r", "")
	s = strgsub(s, "|H.-|h(.-)|h", "%1")
	s = strgsub(s, "|T.-|t", "")
	s = strgsub(s, "|A.-|a", "")
	s = strgsub(s, "|K.-|k", "")
	s = strgsub(s, "|", "")
	s = strgsub(s, "%c", " ")
	maxLen = maxLen or 100
	if #s > maxLen then
		s = strsub(s, 1, maxLen)
		-- don't leave half a UTF-8 character at the end
		s = strgsub(s, "[\192-\255][\128-\191]*$", "")
	end
	s = strmatch(s, "^%s*(.-)%s*$")
	if s == "" then return nil end
	return s
end

function U.ValidVersion(v)
	if type(v) ~= "string" or #v > 16 then return nil end
	if not strmatch(v, "^%d+%.%d+%.%d+$") then return nil end
	return v
end

-- -1 if a < b, 0 if equal, 1 if a > b
function U.CompareVersions(a, b)
	local a1, a2, a3 = strmatch(a or "", "^(%d+)%.(%d+)%.(%d+)$")
	local b1, b2, b3 = strmatch(b or "", "^(%d+)%.(%d+)%.(%d+)$")
	if not a1 or not b1 then return 0 end
	local x = { tonumber(a1), tonumber(a2), tonumber(a3) }
	local y = { tonumber(b1), tonumber(b2), tonumber(b3) }
	for i = 1, 3 do
		if x[i] < y[i] then return -1 elseif x[i] > y[i] then return 1 end
	end
	return 0
end

function U.ValidNumber(n, lo, hi)
	if type(n) ~= "number" or issecret(n) or n ~= n then return nil end
	if n < lo or n > hi then return nil end
	return n
end

-- A server time we believe: after 2020 and not more than an hour in the future.
function U.ValidTime(t)
	return U.ValidNumber(t, 1577836800, U.Now() + 3600)
end

function U.ValidClass(c)
	if type(c) ~= "string" or #c > 20 or not strmatch(c, "^[A-Z]+$") then return nil end
	return c
end

function U.ClassColored(name, class)
	local short = U.ShortName(name)
	local color = class and C_ClassColor and C_ClassColor.GetClassColor(class)
	if color then
		return color:WrapTextInColorCode(short)
	end
	return short
end

function U.Ago(seconds)
	seconds = seconds or 0
	if seconds < 60 then return L.T_JUSTNOW end
	if seconds < 3600 then return L.T_MINUTES:format(floor(seconds / 60)) end
	if seconds < 86400 then return L.T_HOURS:format(floor(seconds / 3600)) end
	return L.T_DAYS:format(floor(seconds / 86400))
end

-- Board "time" column: "<1 min", "12 min", "1 h 10 min".
function U.Duration(seconds)
	seconds = seconds or 0
	if seconds < 60 then return L.T_LESS_MIN end
	local m = floor(seconds / 60)
	if m < 60 then return L.T_MINUTES:format(m) end
	local h = floor(m / 60)
	m = m % 60
	if m == 0 then return L.T_HOURS:format(h) end
	return L.T_HOURS_MIN:format(h, m)
end

-- Simple checksum for the splitting test.
function U.Checksum(s)
	local sum = 0
	for i = 1, #s do
		sum = (sum * 31 + s:byte(i)) % 2147483647
	end
	return sum
end

function U.Count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end
