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

-- A player name we accept from a message: letters (incl. accented), a dash and realm, no pipes/spaces.
function U.ValidName(name)
	if type(name) ~= "string" or #name < 2 or #name > 64 then return nil end
	if strfind(name, "[%s|%c]") then return nil end
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
