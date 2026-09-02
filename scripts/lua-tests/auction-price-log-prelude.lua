wipe = function(tbl)
	for key in pairs(tbl) do
		tbl[key] = nil
	end
	return tbl
end
tinsert = table.insert
floor = math.floor
min = math.min
max = math.max
format = string.format
COPPER_PER_SILVER = 100
MAXIMUM_BID_PRICE = 999999999

local now = 1800000000
function time()
	now = now + 1
	return now
end

local ctx = {
	queuedPosts = 0,
	queuedCancels = 0,
}

local function NewResult(family, name)
	return setmetatable({ family = family, name = name }, {
		__eq = function(a, b) return a.family == b.family end,
		__tostring = function(value) return value.name end,
	})
end

local posting = NewResult("POSTING", "AUCTIONING_OPERATION_RESULT.POSTING")
posting.UNDERCUT = NewResult("POSTING", "AUCTIONING_OPERATION_RESULT.POSTING.UNDERCUT")
local canceling = NewResult("CANCELING", "AUCTIONING_OPERATION_RESULT.CANCELING")
canceling.UNDERCUT = NewResult("CANCELING", "AUCTIONING_OPERATION_RESULT.CANCELING.UNDERCUT")
local cancelingExcess = NewResult("CANCELING_EXCESS", "AUCTIONING_OPERATION_RESULT.CANCELING_EXCESS")
local invalid = NewResult("INVALID", "AUCTIONING_OPERATION_RESULT.INVALID")
invalid.SELLER = NewResult("INVALID", "AUCTIONING_OPERATION_RESULT.INVALID.SELLER")
invalid.ITEM_GROUP = NewResult("INVALID", "AUCTIONING_OPERATION_RESULT.INVALID.ITEM_GROUP")
invalid.ITEM_GROUP.ALT_BLACKLISTED = NewResult("INVALID", "AUCTIONING_OPERATION_RESULT.INVALID.ITEM_GROUP.ALT_BLACKLISTED")
invalid.ITEM_GROUP.BLACKLIST_WHITELIST = NewResult("INVALID", "AUCTIONING_OPERATION_RESULT.INVALID.ITEM_GROUP.BLACKLIST_WHITELIST")
invalid.ITEM_GROUP.OTHER = NewResult("INVALID", "AUCTIONING_OPERATION_RESULT.INVALID.ITEM_GROUP.OTHER")

local operation = {
	RESULT = {
		POSTING = posting,
		POSTING_NOT_NEEDED = { TOO_MANY = NewResult("POSTING_NOT_NEEDED", "AUCTIONING_OPERATION_RESULT.POSTING_NOT_NEEDED.TOO_MANY") },
		NOT_POSTING = { NOT_ENOUGH = NewResult("NOT_POSTING", "AUCTIONING_OPERATION_RESULT.NOT_POSTING.NOT_ENOUGH") },
		INVALID = invalid,
		CANCELING = canceling,
		CANCELING_EXCESS = cancelingExcess,
	},
}
function operation.GetPostQuantities()
	return 1, 1, 5
end
function operation.MakePostDecision()
	return posting.UNDERCUT, "Competitor", 11999, 12344
end
function operation.GetPostSettings()
	return 1, false
end
function operation.GetItemPrice(_, key, settings)
	return settings[key]
end
function operation.MakeCancelDecision()
	return true, canceling.UNDERCUT
end

local tempTable = {}
function tempTable.Acquire()
	return {}
end
function tempTable.Release(tbl)
	wipe(tbl)
end

local auctioningUtil = {}
function auctioningUtil.GetLowestAuction(_, _, _, result)
	result.bid = 12000
	result.buyout = 12345
	result.seller = "Competitor"
	result.isPlayer = false
	result.isBlacklist = false
	result.isWhitelist = false
	return true
end
function auctioningUtil.GetPlayerAuctionCount()
	return 0
end
function auctioningUtil.GetCancelScanResult(_, _, _, _, result)
	result.playerLowestItemBuyout = 14000
	result.playerLowestAuctionId = 7
	result.nonPlayerLowestAuctionId = 9
	result.secondLowestBuyout = 15000
end

local clientInfo = {
	FEATURES = {
		AH_COPPER = "AH_COPPER",
		AH_STACKS = "AH_STACKS",
		C_AUCTION_HOUSE = "C_AUCTION_HOUSE",
	},
}
function clientInfo.HasFeature(feature)
	return feature == clientInfo.FEATURES.AH_COPPER or feature == clientInfo.FEATURES.AH_STACKS
end

local itemString = {}
function itemString.ToId(value)
	return tonumber(string.match(value, "%d+"))
end

local itemInfo = {}
function itemInfo.GetName()
	return "Glyph of Anti-Magic Shell"
end
function itemInfo.GetLink(value)
	return value
end

local function NewQuery()
	local query = {}
	function query:Select() return self end
	function query:Equal() return self end
	function query:Iterator()
		return function() return nil end
	end
	function query:Release() end
	return query
end

local function NewRow(onCreate)
	local row = { fields = {} }
	function row:SetField(key, value)
		self.fields[key] = value
		return self
	end
	function row:Create()
		onCreate()
	end
	return row
end

function ctx.NewQueueDB(kind)
	return {
		NewQuery = function() return NewQuery() end,
		NewRow = function()
			return NewRow(function()
				if kind == "POST" then
					ctx.queuedPosts = ctx.queuedPosts + 1
				else
					ctx.queuedCancels = ctx.queuedCancels + 1
				end
			end)
		end,
	}
end

function ctx.NewScanQuery(kind, reason)
	return {
		GetScanPlanKind = function() return kind end,
		GetEndReason = function() return reason end,
	}
end

function ctx.DecodePriceLogRow(columns, encoded)
	local values, current, escaped = {}, "", false
	for index = 1, #encoded do
		local char = string.sub(encoded, index, index)
		if escaped then
			if char == "p" then current = current.."|"
			elseif char == "n" then current = current.."\n"
			elseif char == "r" then current = current.."\r"
			else current = current..char end
			escaped = false
		elseif char == "\\" then
			escaped = true
		elseif char == "|" then
			table.insert(values, current)
			current = ""
		else
			current = current..char
		end
	end
	table.insert(values, current)
	local result, valueIndex = {}, 1
	for column in string.gmatch(columns, "[^|]+") do
		if values[valueIndex] ~= "" then
			result[column] = values[valueIndex]
		end
		valueIndex = valueIndex + 1
	end
	return result
end

ctx.operationSettings = {
	minPrice = 8000,
	normalPrice = 20000,
	maxPrice = 50000,
	undercut = 1,
	cancelRepostThreshold = 2500,
}
ctx.listedAuction = {
	auctionId = 7,
	itemBid = 13500,
	itemBuyout = 14000,
	stackSize = 1,
	duration = 2,
	hasBid = false,
	canAffordCancel = true,
}

local modules = {
	["Util.ClientInfo"] = clientInfo,
	["BaseType.TempTable"] = tempTable,
	["AuctioningOperation"] = operation,
	["Item.ItemString"] = itemString,
	["Item.ItemInfo"] = itemInfo,
	["Lua.Math"] = { Round = function(value) return value end },
	["Lua.Table"] = { InsertMultiple = function(tbl, ...)
		for index = 1, select("#", ...) do
			table.insert(tbl, (select(index, ...)))
		end
	end },
}

local function Include(_, name)
	return modules[name] or {}
end

ctx.addonTable = {
	Auctioning = {
		NewPackage = function() return {} end,
		Util = auctioningUtil,
		Log = { AddEntry = function() end, SetQueryUpdatesPaused = function() end },
	},
	LibTSMWoW = { Include = Include, IncludeClassType = Include },
	LibTSMUtil = { Include = Include, IncludeClassType = Include },
	LibTSMSystem = { Include = Include },
	LibTSMTypes = { Include = Include },
	LibTSMService = { Include = Include },
	Locale = { GetTable = function() return {} end },
}

return ctx
