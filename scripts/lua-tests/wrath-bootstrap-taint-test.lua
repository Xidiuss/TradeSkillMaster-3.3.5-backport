local failures = 0

local function check(name, condition)
	if condition then
		print("PASS: "..name)
	else
		failures = failures + 1
		print("FAIL: "..name)
	end
end

local nativePlaySound = function() end
PlaySound = nativePlaySound
SOUNDKIT = {}

local frame = {}
function frame:CreateAnimationGroup()
	return setmetatable({}, { __index = {} })
end
function frame:RegisterEvent() end
function frame:SetScript() end
CreateFrame = function()
	return frame
end

local chunk, err = load(WRATH_BOOTSTRAP_SRC, "WrathBootstrap.lua")
assert(chunk, err)
chunk()

check("Wrath bootstrap preserves the native PlaySound function", rawequal(PlaySound, nativePlaySound))
check("Wrath bootstrap provides the 3.3.5 repair sound key", SOUNDKIT.ITEM_REPAIR == "ITEM_REPAIR")

print(string.format("Wrath bootstrap taint tests: %d failed", failures))
return failures
