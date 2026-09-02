-- WoW 3.3.5 / Lua 5.1 environment shims plus a stub of the LibTSM module
-- system, used by run-tests.js to load the real addon sources.

-- WoW API shims (the globals the loaded addon files rely on)
function wipe(t)
	for k in pairs(t) do
		t[k] = nil
	end
	return t
end
strlower = string.lower
strupper = string.upper
tinsert = table.insert
tremove = table.remove
strmatch = string.match
strtrim = function(s)
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Minimal stub of the LibTSM component/module system. Init() returns a fresh
-- module table and records it in a registry; Include() serves the stubs the
-- tested code needs (CustomString.Types / CustomString.Utils). Anything else
-- fails loudly so an unexpected dependency can't silently change the test.
local typesStub = {
	SOURCE_TYPE = {
		PRICE_DB = { name = "PRICE_DB" },
		NORMAL = { name = "NORMAL" },
		VOLATILE = { name = "VOLATILE" },
	},
	FUNCTION_INFO = {},
}
local utilsStub = {
	SanitizeCustomString = function(_, text)
		return text
	end,
}

local ctx = {
	addonTable = {},
	registry = {},
	failures = 0,
	passed = 0,
}

local function makeComponent(registry)
	local component = {}
	function component:Init(name)
		assert(not registry[name], "module initialized twice: " .. tostring(name))
		local module = {}
		registry[name] = module
		return module
	end
	function component:Include(name)
		error("unexpected include in test: " .. tostring(name))
	end
	return component
end

local libTSMTypes = makeComponent(ctx.registry)
function libTSMTypes:Include(name)
	if name == "CustomString.Types" then
		return typesStub
	elseif name == "CustomString.Utils" then
		return utilsStub
	end
	error("unexpected LibTSMTypes include: " .. tostring(name))
end

ctx.addonTable.LibTSMTypes = libTSMTypes
ctx.addonTable.LibTSMUtil = makeComponent(ctx.registry)
ctx.types = typesStub

-- Test helpers available to the test script.
function ctx.check(name, condition, detail)
	if condition then
		ctx.passed = ctx.passed + 1
	else
		ctx.failures = ctx.failures + 1
		print("FAIL: " .. name .. (detail and (" -> " .. tostring(detail)) or ""))
	end
end

return ctx
