-- Behavioral tests for the REAL CustomString source cache (Sources.lua) and
-- the changed-key diff (Table.lua) that drive restock quantity accounting.
-- The restock queue reads GetValue("NumInventory", item) which is cached until
-- InvalidateCache fires with a matching key, while the item tooltip reads the
-- inventory DB directly - this suite pins down exactly that split.

local ctx = _G.TSMCTX
local Sources = assert(ctx.registry["CustomString.Sources"], "Sources.lua was not loaded")
local Table = assert(ctx.registry["Lua.Table"], "Table.lua was not loaded")
local Types = ctx.types

-- ---------------------------------------------------------------------------
-- NORMAL source caching (what NumInventory uses)
-- ---------------------------------------------------------------------------
local backing = { ["i:41591"] = 5 }
local callCount = 0
Sources.Register("Inventory", "NumInventory", "Number in Bags / Bank / AH / Mail", function(itemString)
	callCount = callCount + 1
	return backing[itemString]
end, Types.SOURCE_TYPE.NORMAL)

ctx.check("fresh read returns the backing value",
	Sources.GetValue("NumInventory", "i:41591") == 5 and callCount == 1)

backing["i:41591"] = 7
ctx.check("cached read hides the new value until invalidated (stale-cache mechanism)",
	Sources.GetValue("NumInventory", "i:41591") == 5 and callCount == 1)

Sources.InvalidateCache("numinventory", "i:41591")
ctx.check("per-item invalidation refreshes the value (source key is case-insensitive)",
	Sources.GetValue("NumInventory", "i:41591") == 7 and callCount == 2)

backing["i:41591"] = 9
Sources.InvalidateCache("NumInventory", "i:41591::1")
ctx.check("invalidation with a LEVEL key does NOT refresh the BASE key (key-form hazard)",
	Sources.GetValue("NumInventory", "i:41591") == 7 and callCount == 2)

-- The exact flow BagTracking.DelayedBagTrackingQuantityCallback performs:
-- diff quantities, then invalidate both level and base keys.
local updatedItems = {}
Table.GetChangedKeys({ ["i:41591::1"] = 1 }, { ["i:41591::1"] = 2 }, updatedItems)
local baseItemStrings = {}
for levelItemString in pairs(updatedItems) do
	baseItemStrings["i:41591"] = true
end
for k in pairs(baseItemStrings) do
	updatedItems[k] = true
end
for itemString in pairs(updatedItems) do
	Sources.InvalidateCache("NumInventory", itemString)
end
ctx.check("level+base invalidation (the addon's actual flow) refreshes the base key",
	Sources.GetValue("NumInventory", "i:41591") == 9 and callCount == 3)

backing["i:41591"] = 11
Sources.InvalidateCache("NumInventory")
ctx.check("whole-source invalidation refreshes everything",
	Sources.GetValue("NumInventory", "i:41591") == 11 and callCount == 4)

ctx.check("unknown item returns nil without error",
	Sources.GetValue("NumInventory", "i:1") == nil)

-- nil results are cached as false, so the callback is not re-run until invalidation
local nilBacking = { ["i:2"] = nil }
local nilCallCount = 0
Sources.Register("Inventory", "NilSource", "test", function(itemString)
	nilCallCount = nilCallCount + 1
	return nilBacking[itemString]
end, Types.SOURCE_TYPE.NORMAL)
ctx.check("nil source value is returned as nil",
	Sources.GetValue("NilSource", "i:2") == nil and nilCallCount == 1)
nilBacking["i:2"] = 3
ctx.check("nil result stays cached (no callback re-run)",
	Sources.GetValue("NilSource", "i:2") == nil and nilCallCount == 1)
Sources.InvalidateCache("NilSource", "i:2")
ctx.check("invalidation after nil refreshes to the new value",
	Sources.GetValue("NilSource", "i:2") == 3 and nilCallCount == 2)

-- ---------------------------------------------------------------------------
-- Table.GetChangedKeys (decides which items get their cache invalidated)
-- ---------------------------------------------------------------------------
local changed = {}
Table.GetChangedKeys({ a = 1, b = 2, c = 3 }, { a = 1, b = 5, d = 4 }, changed)
ctx.check("GetChangedKeys flags value changes and additions, not unchanged keys",
	changed.a == nil and changed.b == true and changed.c == true and changed.d == true)

local changedEmpty = {}
Table.GetChangedKeys({ x = 1 }, { x = 1 }, changedEmpty)
ctx.check("GetChangedKeys flags nothing when nothing changed",
	next(changedEmpty) == nil)

print(string.format("Lua sources tests done: %d passed, %d failed", ctx.passed, ctx.failures))
