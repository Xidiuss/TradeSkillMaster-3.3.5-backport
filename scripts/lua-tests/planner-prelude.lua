-- Minimal WoW / LibTSM runtime for behavioral tests which load the real
-- AuctionScan Query, QueryUtil, and ScanManager sources.

function wipe(tbl)
	for key in pairs(tbl) do
		tbl[key] = nil
	end
	return tbl
end

strlower = string.lower
strfind = string.find
gmatch = string.gmatch
tinsert = table.insert
tremove = table.remove
sort = table.sort
max = math.max
min = math.min
newproxy = function()
	return {}
end

local ctx = {
	addonTable = {},
	classes = {},
	modules = {},
	passed = 0,
	failures = 0,
	page = { count = 0, total = 0, firstLink = nil, lastLink = nil },
	itemInfo = {},
	scanTraceMessages = {},
}

function ctx.check(name, condition, detail)
	if condition then
		ctx.passed = ctx.passed + 1
	else
		ctx.failures = ctx.failures + 1
		print("FAIL: " .. name .. (detail and (" -> " .. tostring(detail)) or ""))
	end
end

function ctx.test(name, func)
	local ok, err = pcall(func)
	ctx.check(name, ok, err)
end

function ctx.SetPage(count, total, firstLink, lastLink)
	ctx.page.count = count
	ctx.page.total = total
	ctx.page.firstLink = firstLink
	ctx.page.lastLink = lastLink
end

function GetNumAuctionItems(listType)
	assert(listType == "list")
	return ctx.page.count, ctx.page.total
end

function GetTime()
	return 1
end

function CreateFrame()
	return {
		SetScript = function() end,
	}
end

TSMDBG = {
	Log = function() end,
	LogErr = function() end,
	Warn = function() end,
	TimeStart = function() end,
	TimeEnd = function() end,
	PriceLogTrace = function(message) table.insert(ctx.scanTraceMessages, message) end,
}

local function NewClass(name)
	local class = { __private = {} }
	-- LibTSM's class builder exposes static declarations through a proxy which
	-- lands methods on the class table. Pointing it at the class itself preserves
	-- exactly the call surface the tested sources use.
	class.__static = class
	class.__index = function(_, key)
		return class[key] or class.__private[key]
	end
	function class:__closure(methodName)
		return function(...)
			return self[methodName](self, ...)
		end
	end
	function class:_NewForTest()
		local obj = setmetatable({}, class)
		if obj.__init then
			obj:__init()
		end
		return obj
	end
	ctx.classes[name] = class
	return class
end

local objectPool = {}
function objectPool.New(_, class)
	return {
		Get = function()
			return class:_NewForTest()
		end,
		Recycle = function() end,
	}
end
ctx.classes.ObjectPool = objectPool

local tempTable = {}
function tempTable.Acquire()
	return {}
end
function tempTable.Release(tbl)
	wipe(tbl)
end
function tempTable.Iterator(tbl)
	return ipairs(tbl)
end

local itemString = {}
function itemString.GetBaseFast(value)
	return value
end
function itemString.GetBase(value)
	return value
end
function itemString.ToLevel(value)
	return value
end
function itemString.IsPet()
	return false
end
function itemString.ToId(value)
	return tonumber(string.match(value, "%d+")) or 0
end

local itemInfo = {}
function itemInfo.GetName(item)
	return ctx.itemInfo[item] and ctx.itemInfo[item].name or nil
end
function itemInfo.GetQuality(item)
	return ctx.itemInfo[item] and ctx.itemInfo[item].quality or nil
end
function itemInfo.GetMinLevel(item)
	return ctx.itemInfo[item] and ctx.itemInfo[item].level or nil
end
function itemInfo.GetClassId(item)
	return ctx.itemInfo[item] and ctx.itemInfo[item].classId or nil
end
function itemInfo.GetSubClassId(item)
	return ctx.itemInfo[item] and ctx.itemInfo[item].subClassId or nil
end
function itemInfo.CountNamesContaining(word, limit)
	local count = 0
	for _, info in pairs(ctx.itemInfo) do
		if string.find(string.lower(info.name), word, 1, true) then
			count = count + 1
			if count >= limit then
				break
			end
		end
	end
	return count
end

local clientInfo = {
	FEATURES = { C_AUCTION_HOUSE = "C_AUCTION_HOUSE" },
}
function clientInfo.HasFeature()
	return false
end
function clientInfo.IsVanillaClassic()
	return false
end
function clientInfo.IsBCClassic()
	return false
end
function clientInfo.IsWrathClassic()
	return true
end

local auctionHouse = {}
function auctionHouse.GetBrowseResult(index)
	if index == 1 then
		return nil, ctx.page.firstLink
	elseif index == ctx.page.count then
		return nil, ctx.page.lastLink
	end
	return nil, "item:middle"
end
function auctionHouse.GetNumPages()
	return math.max(1, math.ceil(ctx.page.total / 50))
end
function auctionHouse.CanSendQuery()
	return true
end

local auctionHouseWrapper = {}
function auctionHouseWrapper.SetSort()
	return true
end
function auctionHouseWrapper.SendQuery()
	return true
end
function auctionHouseWrapper.GetAndResetTotalHookedTime()
	return 0
end

local scanner = {}
function scanner.Browse()
	return true
end
function scanner.Cancel() end

local item = {}
function item.ClassCanHaveVariations()
	return false, nil
end
function item.IsUsable()
	return true
end

local threading = {}
function threading.IsThreadContext()
	return true
end
function threading.Yield() end
function threading.Sleep() end
function threading.AcquireSafeTempTable()
	return {}
end

local log = {
	Err = function() end,
	Warn = function() end,
}

local mathUtil = {
	Round = function(value)
		return value
	end,
}

local currency = {
	GetMoney = function()
		return math.huge
	end,
}

local stringUtil = {
	Escape = function(value)
		return value
	end,
}

local deps = {
	["AuctionScan.Scanner"] = scanner,
	["AuctionScan.FindThread"] = {},
	["Item.ItemInfo"] = itemInfo,
	["API.AuctionHouse"] = auctionHouse,
	["API.AuctionHouseWrapper"] = auctionHouseWrapper,
	["Util.ClientInfo"] = clientInfo,
	["API.Item"] = item,
	["API.Currency"] = currency,
	["Item.ItemString"] = itemString,
	["BaseType.TempTable"] = tempTable,
	["Lua.String"] = stringUtil,
	["Threading"] = threading,
	["Util.Log"] = log,
	["Lua.Math"] = mathUtil,
	["ObjectPool"] = objectPool,
	["BaseType.ObjectPool"] = objectPool,
}

local component = {}
function component:DefineClassType(name)
	return NewClass(name)
end
function component:IncludeClassType(name)
	return assert(ctx.classes[name], "class not loaded: " .. tostring(name))
end
function component:Init(name)
	local module = {}
	ctx.modules[name] = module
	return module
end
function component:Include(name)
	if ctx.modules[name] then
		return ctx.modules[name]
	end
	return assert(deps[name], "unexpected include: " .. tostring(name))
end
function component:From()
	return self
end

-- Query.lua includes AuctionRow at load time, but the Query contract tests do
-- not construct rows. Register only the class identity it requires.
NewClass("AuctionRow")

ctx.addonTable.LibTSMService = component
ctx.deps = deps

return ctx
