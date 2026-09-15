// Verifies that the real Wrath bootstrap supplies the repair sound key without
// replacing WoW's global PlaySound API (which taints secure FrameXML handlers).
"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const files = {
	WRATH_BOOTSTRAP_SRC: path.join(projectRoot, "TradeSkillMaster", "Compat", "WrathBootstrap.lua"),
	WRATH_BOOTSTRAP_TEST_SRC: path.join(__dirname, "wrath-bootstrap-taint-test.lua"),
};

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function fail(message) {
	console.error(message);
	process.exit(1);
}

for (const [globalName, filePath] of Object.entries(files)) {
	let content;
	try {
		content = fs.readFileSync(filePath, "utf8");
	} catch (e) {
		fail(`Cannot read ${filePath}: ${e.message}`);
	}
	if (content.charCodeAt(0) === 0xfeff) {
		content = content.slice(1);
	}
	lua.lua_pushstring(L, to_luastring(content));
	lua.lua_setglobal(L, to_luastring(globalName));
}

const source = `
	local chunk = assert(load(WRATH_BOOTSTRAP_TEST_SRC, "wrath-bootstrap-taint-test.lua"))
	return chunk()
`;
const bytes = to_luastring(source);
let status = lauxlib.luaL_loadbuffer(L, bytes, bytes.length, to_luastring("run-wrath-bootstrap-taint-tests"));
if (status !== lua.LUA_OK) {
	fail(`Syntax error: ${lua.lua_tojsstring(L, -1)}`);
}
status = lua.lua_pcall(L, 0, 1, 0);
if (status !== lua.LUA_OK) {
	fail(`Runtime error: ${lua.lua_tojsstring(L, -1)}`);
}

const failures = lua.lua_tointeger(L, -1);
console.log(`Wrath bootstrap taint tests: ${failures} failed`);
process.exit(failures > 0 ? 1 : 0);
