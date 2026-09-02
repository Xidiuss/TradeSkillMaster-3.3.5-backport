// Executable Lua 5.1 tests for the TSM restock chain, running the REAL addon
// sources (LibTSMTypes CustomString Sources.lua + LibTSMUtil Lua.Table) inside
// the fengari VM with a stubbed LibTSM module system and WoW API shims.
//
// Usage: node lua-tests/run-tests.js   (exit 0 = all tests pass)
"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const luaFiles = {
	TSM_SOURCES_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMTypes", "Source", "CustomString", "Classes", "Sources.lua"),
	TSM_TABLE_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMUtil", "Source", "Lua", "Table.lua"),
	TSM_PRELUDE_SRC: path.join(__dirname, "prelude.lua"),
	TSM_TEST_SRC: path.join(__dirname, "sources-test.lua"),
};

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function fail(message) {
	console.error(message);
	process.exit(1);
}

for (const [globalName, filePath] of Object.entries(luaFiles)) {
	let content;
	try {
		content = fs.readFileSync(filePath, "utf8");
	} catch (e) {
		fail(`Cannot read ${filePath}: ${e.message}`);
	}
	// Strip the BOM if present so load() sees clean source.
	if (content.charCodeAt(0) === 0xfeff) {
		content = content.slice(1);
	}
	lua.lua_pushstring(L, to_luastring(content));
	lua.lua_setglobal(L, to_luastring(globalName));
}

function doLua(source, chunkName) {
	const status = lauxlib.luaL_loadbuffer(L, to_luastring(source), source.length, to_luastring(chunkName));
	if (status !== lua.LUA_OK) {
		fail(`Syntax error in ${chunkName}: ${lua.lua_tojsstring(L, -1)}`);
	}
	const callStatus = lua.lua_pcall(L, 0, 1, 0);
	if (callStatus !== lua.LUA_OK) {
		fail(`Runtime error in ${chunkName}: ${lua.lua_tojsstring(L, -1)}`);
	}
	const result = lua.lua_tojsstring(L, -1);
	lua.lua_pop(L, 1);
	return result;
}

doLua("return TSM_PRELUDE_SRC", "load-prelude");
doLua(`
	local src = TSM_PRELUDE_SRC
	local chunk = assert(load(src, "prelude.lua"))
	local result = chunk()
	assert(type(result) == "table", "prelude must return the test context table")
	TSMCTX = result
`, "run-prelude");

for (const [name, srcGlobal] of [["Sources.lua", "TSM_SOURCES_SRC"], ["Table.lua", "TSM_TABLE_SRC"], ["sources-test.lua", "TSM_TEST_SRC"]]) {
	doLua(`
		local chunk = assert(load(${srcGlobal}, ${JSON.stringify(name)}))
		chunk(nil, TSMCTX.addonTable)
	`, `run-${name}`);
}

const failures = doLua("return TSMCTX.failures", "get-failures");
const passed = doLua("return TSMCTX.passed", "get-passed");
console.log(`Lua tests: ${passed} passed, ${failures} failed`);
process.exit(parseInt(failures, 10) > 0 ? 1 : 0);
