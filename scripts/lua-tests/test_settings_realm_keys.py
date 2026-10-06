"""Run real settings iterators in host Lua 5.1 (requires lupa.lua51)."""
from pathlib import Path
from lupa.lua51 import LuaRuntime

root = Path(__file__).resolve().parents[2]
lua = LuaRuntime(unpack_returned_tuples=True)
for name, filename in (("view_source", "View.lua"), ("db_source", "DB.lua")):
    lua.globals()[name] = (
        root / "TradeSkillMaster/LibTSMTypes/Source/Settings/Classes" / filename
    ).read_text(encoding="utf-8-sig")

lua.execute(r'''
strmatch, gsub, tinsert = string.match, string.gsub, table.insert
strjoin = function(sep, ...) return table.concat({...}, sep) end
local viewModule = {}
local dbClass = {__static = {}, __private = {}}
local temp = {Acquire = function() return {} end}
function temp.Iterator(t, stride)
    stride = stride or 1
    local index = 1 - stride
    return function()
        index = index + stride
        if index <= #t then return index, unpack(t, index, index + stride - 1) end
    end
end
local tbl = {}
function tbl.InsertMultiple(t, ...)
    for i = 1, select('#', ...) do t[#t + 1] = select(i, ...) end
end
local modules = {
    ['Settings.Types'] = {SCOPE_KEY_SEP = ' - '},
    ['Settings.Util'] = {}, ['Settings.View'] = viewModule,
    ['BaseType.TempTable'] = temp, ['Lua.Table'] = tbl,
    ['Lua.String'] = {Escape = function(s) return (s:gsub('(%W)', '%%%1')) end},
    ['Lua.Vararg'] = {}, Reactive = {},
}
local lib = {}
function lib:Init() return viewModule end
function lib:DefineClassType() return dbClass end
function lib:IncludeClassType() return {} end
function lib:Include(name) return assert(modules[name], name) end
function lib:From() return self end
assert(loadstring(view_source))(nil, {LibTSMTypes = lib})
assert(loadstring(db_source))(nil, {LibTSMTypes = lib})

local function check(realm, includePTR)
    local factionrealm = 'Horde - '..realm
    local key = 'Xidius - '..factionrealm
    local data = 'minute,copper\n29830467,101360000'
    local otherData = 'minute,copper\n29830467,20000'
    local db = {
        _tbl = {_syncOwner = {[key] = 'account'}},
        _currentScopeKeys = {factionrealm = factionrealm, char = 'Xidius - '..realm},
    }
    local values = {[key] = data}
    if includePTR then
        db._tbl._syncOwner[key..' PTR'] = 'accountPTR'
        values[key..' PTR'] = otherData
    end
    function db:HasKey() return true end
    function db:Get(_, scopeKey, _, setting)
        if setting == 'regionWide' then return false end
        return values[scopeKey]
    end
    function db:AccessibleRealmIterator() return ipairs({realm}) end
    local view = viewModule.New(db, {'Horde'})
    view:AddKey('sync', 'internalData', 'goldLog')
        :AddKey('global', 'coreOptions', 'regionWide')
    local count = 0
    for _, value, character, returnedFactionrealm in view:AccessibleValueIterator('goldLog') do
        count = count + 1
        assert(value == data and character == 'Xidius' and returnedFactionrealm == factionrealm,
            'gold log from another realm leaked into '..realm)
    end
    assert(count == 1, 'duplicate gold log for '..realm)
    count = 0
    for _, character in dbClass.__private._AccessibleCharacterIteratorHelper(db, nil, factionrealm) do
        count = count + 1
        assert(character == 'Xidius')
    end
    assert(count == 1, 'duplicate character for '..realm)
    assert(dbClass.__private._AccessibleCharacterIteratorHelper(db, nil, factionrealm, true)() == nil,
        'current character leaked into alts')
    assert(dbClass.__private._AccessibleCharacterIteratorHelper(db, 'otherAccount', factionrealm)() == nil,
        'account filter ignored')
    if includePTR then
        count = 0
        for _, character in dbClass.__private._AccessibleCharacterIteratorHelper(db, nil, factionrealm..' PTR') do
            count = count + 1
            assert(character == 'Xidius')
        end
        assert(count == 1, 'PTR character not preserved')
    end
end
check('Frostmourne', false)
check('Frostmourne', true)
check('Realm (Test).1', true)
print('PASS: settings realm keys, PTR separation, alts and account filters / '.._VERSION)
''')
