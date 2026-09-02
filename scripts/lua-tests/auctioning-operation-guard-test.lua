local passed, failures = 0, 0

local function test(name, func)
	local ok, err = pcall(func)
	if ok then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAIL: "..name.." -> "..tostring(err))
	end
end

local operation = AUCTIONING_GUARD_CTX.module
local result = operation.RESULT

test("listed auction cheaper than missing-self browse competitor is not canceled", function()
	local handled, reason = operation.MakeCancelDecision(
		"i:42737",
		AUCTIONING_GUARD_CTX.settings,
		AUCTIONING_GUARD_CTX.lowest,
		AUCTIONING_GUARD_CTX.listed,
		AUCTIONING_GUARD_CTX.scanResult
	)
	assert(handled == false)
	assert(reason == result.NOT_CANCELING.NOT_UNDERCUT)
end)

test("genuinely cheaper competitor still triggers cancel", function()
	local listed = {}
	for key, value in pairs(AUCTIONING_GUARD_CTX.listed) do listed[key] = value end
	listed.itemBuyout = 2500
	listed.itemBid = 2500
	local handled, reason = operation.MakeCancelDecision(
		"i:41101",
		AUCTIONING_GUARD_CTX.settings,
		AUCTIONING_GUARD_CTX.lowest,
		listed,
		AUCTIONING_GUARD_CTX.scanResult
	)
	assert(handled == true)
	assert(reason == result.CANCELING.UNDERCUT)
end)

test("equal competitor price remains eligible for undercut cancel", function()
	local listed = {}
	for key, value in pairs(AUCTIONING_GUARD_CTX.listed) do listed[key] = value end
	listed.itemBuyout = 2000
	listed.itemBid = 2000
	local handled, reason = operation.MakeCancelDecision(
		"i:43357",
		AUCTIONING_GUARD_CTX.settings,
		AUCTIONING_GUARD_CTX.lowest,
		listed,
		AUCTIONING_GUARD_CTX.scanResult
	)
	assert(handled == true)
	assert(reason == result.CANCELING.UNDERCUT)
end)

return passed, failures
