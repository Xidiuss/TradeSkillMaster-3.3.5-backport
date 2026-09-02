wipe = function(tbl)
	for key in pairs(tbl) do
		tbl[key] = nil
	end
	return tbl
end
tinsert = table.insert
tremove = table.remove
strlower = string.lower
strfind = string.find
max = math.max

local ctx = {
	rawRows = {},
	traceMessages = {},
	rows = {},
	names = {
		["i:42453"] = "Glyph Target",
	},
}

function debugprofilestop()
	return 0
end

local now = 100
function GetTime()
	now = now + 0.1
	return now
end

TSM_SCAN_TRACE = true
TSMDBG = {
	Log = function() end,
	TimeEnd = function() end,
	PriceLogTrace = function(message) table.insert(ctx.traceMessages, message) end,
	PriceLogRawAuction = function(values) table.insert(ctx.rawRows, values) end,
}

local auctionHouse = {}
function auctionHouse.GetBrowseResult(index)
	local row = assert(ctx.rows[index])
	return row.rawName, row.itemLink, row.stackSize, row.timeLeft, row.buyout, row.seller
end

local itemInfo = {}
function itemInfo.GetName(itemString)
	return ctx.names[itemString]
end

local itemString = {}
function itemString.Get(link)
	return link and "i:42453" or nil
end

local clientInfo = {
	FEATURES = { C_AUCTION_HOUSE = "C_AUCTION_HOUSE" },
}
function clientInfo.HasFeature()
	return false
end

local future = {}
function future.New()
	return {}
end

local includes = {
	["Item.ItemInfo"] = itemInfo,
	["AuctionScan.Util"] = {},
	["API.AuctionHouse"] = auctionHouse,
	["Service.Event"] = {},
	["UI.DefaultUI"] = {},
	["Util.ClientInfo"] = clientInfo,
	["Item.ItemString"] = itemString,
	["FSM"] = {},
	["Future"] = future,
	["Util.Log"] = {},
	["Threading"] = {},
	["DelayTimer"] = {},
}

local scanner = {}
function scanner:OnModuleLoad(callback)
	ctx.moduleLoadCallback = callback
end

local libTSMService = {}
function libTSMService:Init()
	return scanner
end
function libTSMService:Include(name)
	return assert(includes[name], name)
end
function libTSMService:IncludeClassType(name)
	return assert(includes[name], name)
end
function libTSMService:From()
	return self
end

ctx.addonTable = { LibTSMService = libTSMService }
return ctx
