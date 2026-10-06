"""Run the existing integration suite in host Lua 5.1 (requires lupa.lua51)."""
import json
import re
from pathlib import Path
from lupa.lua51 import LuaRuntime

root = Path(__file__).resolve().parents[2]
runner = (root / "scripts/lua-tests/run-runtime-integration-tests.js").read_text(
    encoding="utf-8-sig"
)
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("load = loadstring")
# Reuse the JS runner's source manifest so both runtimes load the same files.
sources = re.findall(r"(R_[A-Z_]+):\s*(\[[^\n]+\])", runner)
assert sources, "integration source manifest not found"
for name, parts in sources:
    lua.globals()[name] = root.joinpath(*json.loads(parts)).read_text(
        encoding="utf-8-sig"
    )
failures = lua.execute('return assert(load(R_TEST, "runtime-integration-test.lua"))()')
print("Native host Lua 5.1 integration failures:", failures)
raise SystemExit(1 if failures else 0)
