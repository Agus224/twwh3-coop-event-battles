"""Runs CA's real lib_generated_battle.get_army with and without battle_fix.lua in Lua 5.1.
A player alliance with two unnamed campaign armies (host + ally) must return the host's army
instead of false; every other lookup must behave exactly as CA's original."""
from pathlib import Path
import os, tempfile, unittest
from lupa.lua51 import LuaRuntime

BASE = Path(__file__).resolve().parent
LIB = BASE.parent / 'research/scripts/script/_lib/lib_generated_battle.lua'

SETUP = r'''
errors = {}
function script_error(msg) table.insert(errors, msg) end
function is_number(x) return type(x) == "number" end
function is_string(x) return type(x) == "string" end
function is_table(x) return type(x) == "table" end
function is_function(x) return type(x) == "function" end
function is_nil(x) return x == nil end
function set_class_custom_type_and_tostring() end
function set_class_custom_type() end
function set_class_tostring() end
function ga(name, tag) return {script_name = name, tag = tag} end
function faction_army(key) return {faction_key = function() return key end} end
bm = {out = function() end, alliances = function() return {item = function(_, a) return {armies = function()
  return {item = function(_, i) return faction_army(a .. "_" .. i) end} end} end} end}
'''

BATTLE = r'''
function new_gb(armies) return setmetatable({generated_armies = armies}, {__index = generated_battle}) end
coop = new_gb({
  { {ga("", "host")}, {ga("", "ally")}, {ga("player_reinforce", "reinf")} },
  { {ga("vmp_main", "enemy")}, {ga("", "enemy_campaign")} },
})
solo = new_gb({ { {ga("", "host")}, {ga("player_reinforce", "reinf")} }, { {ga("", "enemy")} } })
'''


# CA's library is not redistributed (it lives only in the local research folder).
@unittest.skipUnless(LIB.exists(), 'CA lib_generated_battle.lua not found in research/')
class BattleFixTest(unittest.TestCase):
    def runtime(self, with_fix):
        lua = LuaRuntime()
        lua.execute(SETUP)
        lua.execute(LIB.read_text(encoding='utf-8', errors='replace'))
        if with_fix:
            # Like the game's mod loader: the mod runs in its own environment that falls back to _G.
            lua.globals().fix_src = (BASE / 'battle_fix.lua').read_text(encoding='utf-8')
            lua.execute('local f = assert(loadstring(fix_src)); setfenv(f, setmetatable({}, {__index = _G})); f()')
        lua.execute(BATTLE)
        return lua

    def setUp(self):
        self.cwd = os.getcwd()
        os.chdir(tempfile.mkdtemp())  # the fix writes coop_event_battles_log.txt in the cwd

    def tearDown(self):
        os.chdir(self.cwd)

    def test_original_fails_with_two_unnamed_armies(self):
        lua = self.runtime(False)
        self.assertFalse(lua.eval('coop:get_army(1)'))
        self.assertIn('more than one army', lua.eval('errors[1]'))

    def test_fix_returns_host_army(self):
        lua = self.runtime(True)
        self.assertEqual(lua.eval('coop:get_army(1).tag'), 'host')
        self.assertEqual(lua.eval('coop:get_army(1, "").tag'), 'host')
        lua.execute('coop.player_alliance_id = 1')
        self.assertEqual(lua.eval('coop:get_player_army().tag'), 'host')
        self.assertEqual(lua.eval('#errors'), 0)
        log = Path('coop_event_battles_log.txt').read_text()
        self.assertIn('2 unnamed armies (1=1_1, 2=1_2); using army 1', log)

    def test_other_lookups_unchanged(self):
        lua = self.runtime(True)
        self.assertEqual(lua.eval('coop:get_army(1, "player_reinforce").tag'), 'reinf')
        self.assertEqual(lua.eval('coop:get_army(1, 2).tag'), 'ally')
        self.assertEqual(lua.eval('coop:get_army(1, 1, "").tag'), 'host')
        self.assertEqual(lua.eval('coop:get_army(2, "vmp_main").tag'), 'enemy')
        self.assertEqual(lua.eval('coop:get_army(2).tag'), 'enemy_campaign')
        self.assertEqual(lua.eval('solo:get_army(1).tag'), 'host')
        self.assertEqual(lua.eval('#errors'), 0)
        self.assertFalse(lua.eval('coop:get_army(1, "missing")'))
        self.assertEqual(lua.eval('#errors'), 1)


if __name__ == '__main__':
    unittest.main()
