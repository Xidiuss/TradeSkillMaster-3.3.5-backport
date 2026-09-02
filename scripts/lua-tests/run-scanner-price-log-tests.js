// Behavioral tests for raw classic browse-row diagnostics in the real Scanner.
"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const files = {
	SCANNER_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMService", "Source", "AuctionScan", "Classes", "Scanner.lua"),
	SCANNER_PRICE_LOG_PRELUDE_SRC: path.join(__dirname, "scanner-price-log-prelude.lua"),
	SCANNER_PRICE_LOG_TEST_SRC: path.join(__dirname, "scanner-price-log-test.lua"),
};

function fail(message) {
	console.error(message);
	process.exit(1);
}

function readUtf8(filePath) {
	let content = fs.readFileSync(filePath, "utf8");
	if (content.charCodeAt(0) === 0xfeff) content = content.slice(1);
	return content;
}

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
for (const [globalName, filePath] of Object.entries(files)) {
	try {
		lua.lua_pushstring(L, to_luastring(readUtf8(filePath)));
		lua.lua_setglobal(L, to_luastring(globalName));
	} catch (e) {
		fail(`Cannot read ${filePath}: ${e.message}`);
	}
}

const source = `
	SCANNER_PRICE_LOG_CTX = assert(load(SCANNER_PRICE_LOG_PRELUDE_SRC, "scanner-price-log-prelude.lua"))()
	local passed, failures = assert(load(SCANNER_PRICE_LOG_TEST_SRC, "scanner-price-log-test.lua"))()
	return tostring(passed)..","..tostring(failures)
`;
const bytes = to_luastring(source);
let status = lauxlib.luaL_loadbuffer(L, bytes, bytes.length, to_luastring("run-scanner-price-log-tests.lua"));
if (status !== lua.LUA_OK) fail(`Syntax error: ${lua.lua_tojsstring(L, -1)}`);
status = lua.lua_pcall(L, 0, 1, 0);
if (status !== lua.LUA_OK) fail(`Runtime error: ${lua.lua_tojsstring(L, -1)}`);
const [passed, failures] = lua.lua_tojsstring(L, -1).split(",").map(Number);
console.log(`Scanner price log tests: ${passed} passed, ${failures} failed`);
process.exit(failures > 0 ? 1 : 0);
