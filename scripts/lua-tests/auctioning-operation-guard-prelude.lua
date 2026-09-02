max = math.max
min = math.min
floor = math.floor
gsub = string.gsub

local ctx = {}
local module = {}

function module:OnModuleLoad()
	-- MakeCancelDecision has no module-load dependency; do not run settings setup.
end

local util = {}
function util.GetItemPrice(_, _, key, settings)
	return settings[key]
end

local enumType = {}
local enumPlaceholder = {}
function enumType.NewValue()
	return enumPlaceholder
end
function enumType.NewNested(name, values)
	local function Convert(tbl, prefix)
		for key, value in pairs(tbl) do
			local valueName = prefix.."."..key
			if value == enumPlaceholder then
				tbl[key] = setmetatable({}, { __tostring = function() return valueName end })
			else
				Convert(value, valueName)
			end
		end
		return tbl
	end
	return Convert(values, name)
end

local includes = {
	["Operation.Util"] = util,
	["Lua.Math"] = {},
	["Lua.String"] = {},
	["BaseType.EnumType"] = enumType,
	["UI.Money"] = {},
	["Operation"] = {},
	["CustomString"] = {},
}

local libTSMSystem = {}
function libTSMSystem:Init(name)
	assert(name == "AuctioningOperation")
	return module
end
function libTSMSystem:Include(name)
	return assert(includes[name])
end
function libTSMSystem:From()
	return self
end

ctx.addonTable = { LibTSMSystem = libTSMSystem }
ctx.module = module

ctx.settings = {
	cancelUndercut = true,
	cancelRepost = false,
	minPrice = 1000,
	normalPrice = 3000,
	maxPrice = 10000,
	undercut = 500,
	cancelRepostThreshold = 1000,
	priceReset = "none",
	aboveMax = "maxPrice",
}
ctx.listed = {
	auctionId = 10,
	itemBuyout = 1500,
	itemBid = 1500,
	stackSize = 1,
	duration = 2,
	hasBid = false,
	canAffordCancel = true,
}
ctx.lowest = {
	buyout = 2000,
	bid = 2000,
	seller = "Competitor",
	auctionId = 20,
	isWhitelist = false,
	isBlacklist = false,
	isPlayer = false,
	hasInvalidSeller = false,
}
ctx.scanResult = {
	isPlayerOnlySeller = false,
}

return ctx
