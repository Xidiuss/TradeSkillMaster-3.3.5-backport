// Behavioral tests for the real lightweight SavedVariables price logger.
"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const loggerPath = path.join(projectRoot, "TradeSkillMaster", "Compat", "TSMDebug.lua");
const testPath = path.join(__dirname, "price-log-test.lua");
const postAddonPath = path.join(projectRoot, "TSM_PostScan", "Core.lua");
const cancelAddonPath = path.join(projectRoot, "TSM_CancelScan", "Core.lua");

function fail(message) {
	console.error(message);
	process.exit(1);
}

function readUtf8(filePath) {
	let content = fs.readFileSync(filePath, "utf8");
	if (content.charCodeAt(0) === 0xfeff) {
		content = content.slice(1);
	}
	return content;
}

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

for (const [globalName, filePath] of Object.entries({
	TSM_PRICE_LOG_SRC: loggerPath,
	TSM_PRICE_LOG_TEST_SRC: testPath,
	TSM_POST_SCAN_ADDON_SRC: postAddonPath,
	TSM_CANCEL_SCAN_ADDON_SRC: cancelAddonPath,
})) {
	let content;
	try {
		content = readUtf8(filePath);
	} catch (e) {
		fail(`Cannot read ${filePath}: ${e.message}`);
	}
	lua.lua_pushstring(L, to_luastring(content));
	lua.lua_setglobal(L, to_luastring(globalName));
}

const source = `
	local chunk = assert(load(TSM_PRICE_LOG_TEST_SRC, "price-log-test.lua"))
	local passed, failures = chunk()
	return tostring(passed)..","..tostring(failures)
`;
const bytes = to_luastring(source);
let status = lauxlib.luaL_loadbuffer(L, bytes, bytes.length, to_luastring("run-price-log-test.lua"));
if (status !== lua.LUA_OK) {
	fail(`Syntax error: ${lua.lua_tojsstring(L, -1)}`);
}
status = lua.lua_pcall(L, 0, 1, 0);
if (status !== lua.LUA_OK) {
	fail(`Runtime error: ${lua.lua_tojsstring(L, -1)}`);
}
const result = lua.lua_tojsstring(L, -1);
const [passed, failures] = result.split(",").map(Number);
console.log(`Price log Lua tests: ${passed} passed, ${failures} failed`);
process.exit(failures > 0 ? 1 : 0);
