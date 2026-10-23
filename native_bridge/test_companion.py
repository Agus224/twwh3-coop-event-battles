"""Exercise the real campaign companion in Lua 5.1 with deterministic model/native fakes."""
from pathlib import Path
import json
import unittest
from lupa.lua51 import LuaRuntime as _LuaRuntime

BASE = Path(__file__).resolve().parent
VERSION = json.loads((BASE / 'VERSION.json').read_text())['version']
class LuaRuntime:
    def __init__(self, **kwargs): self.runtime = _LuaRuntime(**kwargs)
    def execute(self, code, *args): return self.runtime.execute(code.replace('__CEB_RELEASE__', VERSION), *args)
    def eval(self, code, *args): return self.runtime.eval(code.replace('__CEB_RELEASE__', VERSION), *args)
    def __getattr__(self, name): return getattr(self.runtime, name)
MOCK = r'''
saved, listeners, sent = {}, {}, {}
function list(t) return {num_items=function() return #t end,item_at=function(_,i) return t[i+1] end} end
function faction(key,cqi)
 return {name=function() return key end,command_queue_index=function() return cqi end,
 is_null_interface=function() return false end,is_human=function() return true end,
 is_dead=function() return false end,at_war_with=function() return false end}
end
fa,fb,fc=faction('host',1),faction('ally',2),faction('third',3)
function character(cqi,f)
 local mf={is_null_interface=function() return false end,is_army=function() return true end,
 is_armed_citizenry=function() return false end,is_set_piece_battle_army=function() return false end,
 has_general=function() return true end,command_queue_index=function() return cqi+60 end,
 unit_list=function() return list({{}, {}}) end}
 local c={is_null_interface=function() return false end,faction=function() return f end,
 logical_position_x=function() return cqi*10 end,logical_position_y=function() return cqi*10 end,
 command_queue_index=function() return cqi end,has_military_force=function() return true end,
 military_force=function() return mf end}
 mf.general_character=function() return c end
 return c
end
host,ally,third=character(10,fa),character(20,fb),character(30,fc)
pb={is_active=function() return true end,has_been_fought=function() return false end,
 set_piece_battle_key=function() return 'test_mission_battle' end,quest_mission_key=function() return 'test_mission' end,
 has_attacker=function() return true end,attacker=function() return host end,
 has_defender=function() return false end,secondary_attackers=function() return list({}) end,
 secondary_defenders=function() return list({}) end}
local model={pending_battle=function() return pb end,turn_number=function() return 7 end,
 character_for_command_queue_index=function(_,cqi) return ({[10]=host,[20]=ally,[30]=third})[cqi] end,
 faction_for_command_queue_index=function(_,cqi) return ({fa,fb,fc})[cqi] end,
 world=function() return {faction_list=function() return list({fa,fb,fc}) end} end}
cm={game_interface={},is_multiplayer=function() return true end,model=function() return model end,
 get_human_factions=function() return {'host','ally'} end,
 get_faction=function(_,key) return ({host=fa,ally=fb,third=fc})[key] end,
 get_local_faction=function() return fa end,get_local_faction_name=function() return 'host' end,
 add_saving_game_callback=function(_,f) save_cb=f end,add_loading_game_callback=function(_,f) load_cb=f end,
 add_first_tick_callback=function(_,f) tick_cb=f end,
 save_named_value=function(_,k,v) saved[k]=v end,
 load_named_value=function(_,k,default) local v=saved[k]; if v==nil then return default end;return v end,
 remove_real_callback=function() end,
 update_pending_battle=function() updates=(updates or 0)+1 end,
 char_lookup_str=function(_,cqi) return 'character_cqi:'..cqi end,
 find_valid_spawn_location_for_character_from_character=function(_,faction,host_str,same_region,distance) return 101,102 end,
 teleport_to=function(_,who,x,y) table.insert(teleports,who..'@'..x..','..y..'#'..(calls.join or 0)) end}
teleports={}
core={add_listener=function(_,name,event,condition,callback) listeners[name]={event=event,callback=callback} end}
CampaignUI={TriggerCampaignScriptEvent=function(cqi,t) table.insert(sent,{cqi,t}) end}
common={get_localised_string=function(key) return key end,set_context_value=function() end}
out=function() end
io={open=function() return nil end}
calls={inspect=0,join=0}
fake_native={status=function() return {supported=true,version='__CEB_RELEASE__'} end,
 inspect=function(gi,h,a) assert(gi==cm.game_interface and h==70 and a==80);calls.inspect=calls.inspect+1;
 return {ok=not inspect_reject,code='inspection',host_force_cqi=70,ally_force_cqi=80,participants_before=2,participants_after=2} end,
 join=function(gi,h,a) assert(gi==cm.game_interface and h==70 and a==80);calls.join=calls.join+1;
 return {ok=true,code='joined',host_force_cqi=70,ally_force_cqi=80,participants_before=2,participants_after=3} end}
package.loadlib=function(path,symbol)
 assert(path=='ceb_native_bridge.dll' and symbol=='luaopen_ceb_native_bridge')
 return function() return fake_native end
end
function event(cqi,payload)
 coop_event_battles:on_ui_trigger({faction_cqi=function() return cqi end,trigger=function() return 'CEBN|'..payload end})
end
function ack(cqi,ready,host_force,ally_force,count,fatal,code)
 local s=coop_event_battles.session
 event(cqi,'V|'..s.id..'|'..s.proposal.id..'|'..(ready or '1')..'|'..(host_force or '70')..'|'..
 (ally_force or '80')..'|'..(count or '2')..'|'..(fatal or '0')..'|'..(code or 'inspection'))
end
'''


class CompanionTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCK)
        self.lua.execute((BASE / 'campaign_bridge.lua').read_text(encoding='utf-8'))
        self.lua.execute('''
        ceb=coop_event_battles
        ceb.config.debug=false
        original_extract_native_dll=ceb.extract_native_dll
        ceb.extract_native_dll=function(self) self.build="a1b2c3d4"; return true,"mock verified extraction" end
        ceb:load_native()
        ceb.ui_on_session_started=function() session_ui=(session_ui or 0)+1 end
        ceb.ui_close_host_wait=function() end
        ceb.ui_close_invite=function() end
        ceb.ui_notify_participants=function() notices=(notices or 0)+1 end
        ceb.ui_show_info=function() end
        ''')

    def ready(self):
        self.lua.execute("event(1,'R|1|__CEB_RELEASE__|1'); event(2,'R|1|__CEB_RELEASE__|1')")

    def test_missing_or_incompatible_peer_blocks_invitation_and_join(self):
        self.lua.execute("ceb:on_pending_battle(pb); assert(ceb.session==nil); event(1,'R|1|__CEB_RELEASE__|1'); assert(ceb.session==nil)")
        self.lua.execute("event(2,'R|1|another-build|1'); assert(not ceb:all_peers_ready() and ceb.session==nil)")
        self.lua.execute("event(2,'R|3|__CEB_RELEASE__|1|a1b2c3d4'); assert(ceb.session==nil)")
        self.assertEqual(self.lua.eval('calls.join'), 0)






    def test_success_only_after_all_readiness_then_reject_duplicate(self):
        self.ready()
        self.lua.execute("assert(ceb.session~=nil); event(2,'J|'..ceb.session.id..'|20'); event(2,'J|'..ceb.session.id..'|20')")
        self.assertEqual(self.lua.eval('calls.join'), 0)
        self.lua.execute("ack(1); ack(2); event(2,'J|'..ceb.session.id..'|20')")
        self.assertEqual(self.lua.eval('calls.inspect'), 1)
        self.assertEqual(self.lua.eval('calls.join'), 1)
        self.assertEqual(self.lua.eval('updates'), 1)
        self.assertTrue(self.lua.eval('ceb.session.closed'))
        self.assertEqual(self.lua.eval('teleports[1]'), 'character_cqi:20@101,102#0')

    def test_wrong_owner_uninvited_sender_and_stale_session_never_reach_native(self):
        self.ready()
        self.lua.execute("event(2,'J|stale|20'); event(2,'J|'..ceb.session.id..'|10'); event(3,'J|'..ceb.session.id..'|30')")
        self.assertEqual(self.lua.eval('calls.inspect'), 0)
        self.assertEqual(self.lua.eval('#ceb.session.responded'), 0)

    def test_changed_mission_rejects_selection(self):
        self.ready()
        self.lua.execute("pb.quest_mission_key=function() return 'new_mission' end; event(2,'J|'..ceb.session.id..'|20')")
        self.assertEqual(self.lua.eval('calls.inspect'), 0)

    def test_failed_native_inspection_does_not_join_or_refresh(self):
        self.ready()
        self.lua.execute("inspect_reject=true; event(2,'J|'..ceb.session.id..'|20')")
        self.lua.execute("assert(sent[1][2]:find('|0|0|0|0|0|inspection',1,true)); event(sent[1][1],sent[1][2]:sub(6))")
        self.assertEqual(self.lua.eval('calls.inspect'), 1)
        self.assertEqual(self.lua.eval('calls.join'), 0)
        self.assertIsNone(self.lua.eval('updates'))
        self.assertTrue(self.lua.eval('ceb.session.closed'))

    def test_missing_ack_and_duplicate_ack_never_commit(self):
        self.ready()
        self.lua.execute("event(2,'J|'..ceb.session.id..'|20'); ack(1); ack(1)")
        self.assertEqual(self.lua.eval('calls.join'), 0)
        self.assertIsNotNone(self.lua.eval('ceb.session.proposal'))

    def test_negative_ack_aborts_without_native_mutation(self):
        self.ready()
        self.lua.execute("event(2,'J|'..ceb.session.id..'|20'); ack(1); ack(2,'0','0','0','0','0','wrong_stage')")
        self.assertEqual(self.lua.eval('calls.join'), 0)
        self.assertIsNone(self.lua.eval('ceb.session.proposal'))

    def test_mismatched_participant_count_and_force_signature_abort(self):
        for field in ('count', 'force'):
            with self.subTest(field=field):
                self.setUp()
                self.ready()
                self.lua.execute("event(2,'J|'..ceb.session.id..'|20'); ack(1)")
                self.lua.execute("ack(2,'1','70','80','3')" if field == 'count' else "ack(2,'1','70','81','2')")
                self.assertEqual(self.lua.eval('calls.join'), 0)
                self.assertIsNone(self.lua.eval('ceb.session.proposal'))

    def test_wrong_session_proposal_and_uninvolved_sender_ack_ignored(self):
        self.ready()
        self.lua.execute("""
        event(2,'J|'..ceb.session.id..'|20')
        local p=ceb.session.proposal
        event(3,'V|'..ceb.session.id..'|'..p.id..'|1|70|80|2|0|inspection')
        event(2,'V|stale|'..p.id..'|1|70|80|2|0|inspection')
        event(2,'V|'..ceb.session.id..'|forged_proposal|1|70|80|2|0|inspection')
        ack(1)
        """)
        self.assertEqual(self.lua.eval('calls.join'), 0)
        self.assertIsNone(self.lua.eval("ceb.session.proposal.acknowledgements['ally']"))

    def test_host_cancel_clears_proposal_and_rejects_late_ack(self):
        self.ready()
        self.lua.execute("""
        event(2,'J|'..ceb.session.id..'|20'); ack(1)
        local late='V|'..ceb.session.id..'|'..ceb.session.proposal.id..'|1|70|80|2|0|inspection'
        event(2,'C|'..ceb.session.id); assert(ceb.session.proposal~=nil)
        event(1,'C|'..ceb.session.id); event(2,late)
        """)
        self.assertEqual(self.lua.eval('calls.join'), 0)
        self.assertIsNone(self.lua.eval('ceb.session.proposal'))
        self.assertTrue(self.lua.eval('ceb.session.closed'))

    def test_fatal_preflight_and_commit_error_require_reload_without_fallback(self):
        self.ready()
        self.lua.execute("event(2,'J|'..ceb.session.id..'|20'); ack(2,'0','0','0','0','1','native_exception')")
        self.assertTrue(self.lua.eval('ceb.reload_required'))
        self.assertEqual(self.lua.eval('calls.join'), 0)
        self.setUp()
        self.ready()
        self.lua.execute("""
        fake_native.join=function() calls.join=calls.join+1;return {ok=false,code='ownership_mismatch'} end
        event(2,'J|'..ceb.session.id..'|20'); ack(1);ack(2)
        assert(sent[#sent][2]:find('CEBN|F|',1,true)==1)
        """)
        self.assertTrue(self.lua.eval('ceb.reload_required'))
        self.assertEqual(self.lua.eval('calls.join'), 1)
        self.assertIsNone(self.lua.eval('updates'))

    def test_postcommit_peer_failure_requires_reload_even_after_session_closed(self):
        self.ready()
        self.lua.execute("""
        event(2,'J|'..ceb.session.id..'|20'); local p=ceb.session.proposal.id; ack(1);ack(2)
        event(2,'F|'..ceb.session.id..'|forged|native_exception'); assert(not ceb.reload_required)
        event(2,'F|'..ceb.session.id..'|'..p..'|native_exception')
        """)
        self.assertTrue(self.lua.eval('ceb.reload_required'))
        self.assertEqual(self.lua.eval('calls.join'), 1)

    def test_two_clients_commit_on_same_last_ack_event(self):
        first = self.lua
        self.setUp()
        second = self.lua
        second.execute("cm.get_local_faction=function() return fb end; cm.get_local_faction_name=function() return 'ally' end")
        for client in (first, second):
            client.execute("event(1,'R|1|__CEB_RELEASE__|1');event(2,'R|1|__CEB_RELEASE__|1');event(2,'J|'..ceb.session.id..'|20')")
            self.assertEqual(client.eval('calls.join'), 0)
        # Relay actual native inspection broadcasts from each independent Lua VM.
        for source in (first, second):
            sender = source.eval('sent[1][1]')
            payload = source.eval('sent[1][2]')[5:]
            for target in (first, second):
                target.eval('event')(sender, payload)
            expected = 0 if source is first else 1
            for target in (first, second):
                self.assertEqual(target.eval('calls.join'), expected)
        self.assertEqual(first.eval('updates'), 1)
        self.assertEqual(second.eval('updates'), 1)

    def test_two_clients_one_negative_preflight_prevents_both_commits(self):
        first = self.lua
        self.setUp()
        second = self.lua
        second.execute("cm.get_local_faction=function() return fb end;inspect_reject=true")
        for client in (first, second):
            client.execute("event(1,'R|1|__CEB_RELEASE__|1');event(2,'R|1|__CEB_RELEASE__|1');event(2,'J|'..ceb.session.id..'|20')")
        for source in (first, second):
            sender = source.eval('sent[1][1]')
            payload = source.eval('sent[1][2]')[5:]
            for target in (first, second):
                target.eval('event')(sender, payload)
        for target in (first, second):
            self.assertEqual(target.eval('calls.join'), 0)
            self.assertTrue(target.eval('ceb.session.closed'))

    def test_concurrent_join_waits_in_queue_until_previous_proposal_finishes(self):
        self.lua.execute("""
        cm.get_human_factions=function() return {'host','ally','third'} end
        fake_native.inspect=function(_,h,a) calls.inspect=calls.inspect+1;return {ok=true,code='inspection',host_force_cqi=h,ally_force_cqi=a,participants_before=2+(calls.join or 0)} end
        fake_native.join=function(_,h,a) calls.join=calls.join+1;return {ok=true,code='joined'} end
        event(1,'R|1|__CEB_RELEASE__|1');event(2,'R|1|__CEB_RELEASE__|1');event(3,'R|1|__CEB_RELEASE__|1')
        event(2,'J|'..ceb.session.id..'|20');event(3,'J|'..ceb.session.id..'|30');event(3,'J|'..ceb.session.id..'|30')
        assert(calls.inspect==1 and #ceb.session.pending_join_queue==1 and calls.join==0)
        ack(1);ack(2);ack(3)
        assert(calls.join==1 and calls.inspect==2 and ceb.session.proposal.ally_force==90)
        ack(1,'1','70','90','3');ack(2,'1','70','90','3');assert(calls.join==1)
        ack(3,'1','70','90','3');assert(calls.join==2 and ceb.session.closed)
        """)

    def test_capability_withdrawal_closes_session(self):
        self.ready()
        self.lua.execute("local id=ceb.session.id; event(2,'R|1|__CEB_RELEASE__|0'); assert(ceb.session==nil); event(2,'J|'..id..'|20')")
        self.assertEqual(self.lua.eval('calls.join'), 0)

    def test_readiness_request_recovers_late_listener_without_echo_loop(self):
        self.lua.execute("event(2,'Q'); assert(#sent==1 and sent[1][2]=='CEBN|R|1|__CEB_RELEASE__|1'); event(1,'R|1|__CEB_RELEASE__|1'); assert(#sent==1)")

    def test_old_save_blocked_preserving_records_without_settlement(self):
        self.lua.execute("saved.ceb_loans={{ally_cqi=20,items={{orig_cqi=2,copy_cqi=4}}}}; saved.ceb_cap_overridden=true; load_cb({})")
        self.ready()
        self.lua.execute("assert(ceb.legacy_blocked and ceb.session==nil); save_cb({}); assert(saved.ceb_loans[1].items[1].copy_cqi==4)")
        self.assertEqual(self.lua.eval('calls.join'), 0)

    def test_no_troop_mutation_or_result_emulation_api_in_companion(self):
        text = (BASE / 'campaign_bridge.lua').read_text(encoding='utf-8')
        for api in ('grant_unit_to_character', 'remove_unit_from', 'set_unit_hp_to', 'add_experience_to_unit',
                    'override_human_player_max_units', 'settle_loans', 'gift_units', 'kill_character'):
            self.assertNotIn(api, text)
        # The only teleport is the army move beside the host (and back), like the quest teleport.
        self.assertEqual(text.count('cm:teleport_to('), 2)

    def test_host_gets_reinforcement_note_with_unit_count_and_it_closes_with_pre_battle(self):
        self.lua.execute("notes_built=0; ceb.ui_build_reinforcement_note=function() notes_built=notes_built+1 end; ceb.ui_close_reinforcement_note_orig=ceb.ui_close_reinforcement_note")
        self.lua.execute("ceb:add_note_listeners()")
        self.ready()
        self.lua.execute("event(2,'J|'..ceb.session.id..'|20'); ack(1); ack(2)")
        self.assertEqual(self.lua.eval('calls.join'), 1)
        self.assertEqual(self.lua.eval('#ceb.reinforcement_notes'), 1)
        self.assertEqual(self.lua.eval('ceb.reinforcement_notes[1].units'), 2)
        self.assertEqual(self.lua.eval('ceb.reinforcement_notes[1].cqi'), 20)
        self.assertEqual(self.lua.eval('notes_built'), 1)
        self.lua.execute("ceb.ui_close_reinforcement_note=function() ceb.reinforcement_notes={} end")
        self.lua.execute("listeners.ceb_note_PanelClosed.callback({string='popup_pre_battle'})")
        self.assertEqual(self.lua.eval('#ceb.reinforcement_notes'), 0)

    def test_ally_client_gets_no_reinforcement_note(self):
        self.lua.execute("cm.get_local_faction_name=function() return 'ally' end; cm.get_local_faction=function() return fb end")
        self.lua.execute("ceb.ui_build_reinforcement_note=function() error('must not build on ally') end")
        self.lua.execute("ceb:ui_add_reinforcement_note('host', 20)")
        self.assertEqual(self.lua.eval('ceb.reinforcement_notes == nil or #ceb.reinforcement_notes == 0'), True)

    def test_single_player_is_disabled_by_default(self):
        self.lua.execute("""
        cm.is_multiplayer=function() return false end
        cm.real_callback=function(_,f) f() end
        shown={}; ceb.ui_show_info=function(_,t) table.insert(shown,t) end
        ceb.native=nil; listeners={}; loads=0
        package.loadlib=function() loads=loads+1; return nil,'x' end
        tick_cb()""")
        self.assertTrue(self.lua.eval('ceb.singleplayer_test == false and loads == 0 and #shown == 0'))
        self.assertTrue(self.lua.eval('next(listeners) == nil'))

    def test_dll_loaded_notice_only_once_per_campaign(self):
        self.lua.execute("""
        cm.real_callback=function(_,f) f() end
        shown={}; ceb.ui_show_info=function(_,t) table.insert(shown,t) end
        load_cb({}); tick_cb()""")
        self.assertEqual(self.lua.eval('#shown'), 1)
        self.assertTrue(self.lua.eval('string.find(shown[1], string.format(ceb:txt("native_ok"), "__CEB_RELEASE__", tostring(ceb.build)), 1, true) == 1'))
        # saved, then loaded again (e.g. back from the battle): no second notice
        self.lua.execute("save_cb({}); load_cb({}); tick_cb()")
        self.assertEqual(self.lua.eval('saved.ceb_native_notice_shown'), True)
        self.assertEqual(self.lua.eval('#shown'), 1)

    def test_dll_failure_is_reported_on_every_load(self):
        self.lua.execute("""
        cm.real_callback=function(_,f) f() end
        shown={}; ceb.ui_show_info=function(_,t) table.insert(shown,t) end
        package.loadlib=function() return nil,'module not found' end
        saved.ceb_native_notice_shown=true; load_cb({}); tick_cb(); load_cb({}); tick_cb()""")
        self.assertEqual(self.lua.eval('#shown'), 2)
        self.assertTrue(self.lua.eval('string.find(shown[1], "module not found", 1, true) ~= nil'))

    def single_player(self, second_army=True):
        self.lua.execute('''
        cm.is_multiplayer=function() return false end
        ceb.singleplayer_test=true
        cm.callback=function(_,f) f() end
        cm.real_callback=function(_,f) f() end
        shown={}; picker=0; native_calls={}
        ceb.ui_show_info=function(_,text) table.insert(shown,text) end
        ceb.ui_build_invite_dialog=function() picker=picker+1 end
        ceb.ui_close_invite=function() end
        ceb.native=nil; ceb.native_status=nil; listeners={}; sent={}
        own_second=character(20,fa)
        local m=cm:model(); local previous=m.character_for_command_queue_index
        m.character_for_command_queue_index=function(self,cqi) if cqi==20 then return own_second end return previous(self,cqi) end
        fa.military_force_list=function() return list(SECOND and {host:military_force(),own_second:military_force()} or {host:military_force()}) end
        sp_inspect_code='ready'
        fake_native.inspect=function(gi,h,a,flags) assert(gi==cm.game_interface and h==70 and (a==80 or a==90));calls.inspect=calls.inspect+1;
          table.insert(native_calls,'inspect:'..tostring(flags))
          return {ok=sp_inspect_code=='ready',code=sp_inspect_code,detail='x',host_force_cqi=70,ally_force_cqi=80,participants_before=2,participants_after=2} end
        fake_native.join=function(gi,h,a,flags) assert(gi==cm.game_interface and h==70 and (a==80 or a==90));calls.join=calls.join+1;
          table.insert(native_calls,'join:'..tostring(flags))
          return {ok=true,changed=true,code='joined',host_force_cqi=70,ally_force_cqi=80,participants_before=2,participants_after=3} end
        '''.replace('SECOND', 'true' if second_army else 'false'))
        self.lua.execute('tick_cb()')

    def fire_sp_battle(self):
        self.lua.execute('listeners.ceb_sp_PendingBattle.callback({pending_battle=function() return pb end})')

    def test_single_player_extracts_loads_and_reports_without_mp_listeners(self):
        self.single_player()
        self.assertTrue(self.lua.eval('ceb.native ~= nil and ceb.native_status.supported == true'))
        self.assertTrue(self.lua.eval('listeners.ceb_PendingBattle == nil and listeners.ceb_UITrigger == nil and #sent == 0'))
        self.assertTrue(self.lua.eval('listeners.ceb_sp_PendingBattle ~= nil and listeners.ceb_sp_ComponentLClickUp ~= nil'))
        self.assertTrue(self.lua.eval('#shown == 1 and shown[1] == string.format(ceb:txt("sp_native_ok"), "__CEB_RELEASE__, build " .. tostring(ceb.build))'))

    def test_single_player_offers_own_armies_and_joins_in_same_faction_mode(self):
        self.single_player()
        self.fire_sp_battle()
        self.assertEqual(self.lua.eval('picker'), 1)
        # other factions are human in this fixture, so only the own army is offered
        self.assertTrue(self.lua.eval('ceb.session.sp and #ceb.ui.candidates == 1 and ceb.ui.candidates[1] == 20'))
        self.assertEqual(self.lua.eval('calls.inspect + calls.join'), 0)
        self.lua.execute('ceb:sp_join(20)')
        self.assertEqual(self.lua.eval('table.concat(native_calls, ",")'), 'inspect:3,join:3')
        # teleported beside the host before the native join (#0 = no join yet)
        self.assertEqual(self.lua.eval('teleports[1]'), 'character_cqi:20@101,102#0')
        self.assertEqual(self.lua.eval('updates'), 1)
        self.assertTrue(self.lua.eval('#sent == 0 and ceb.session == nil and ceb.sp_joined ~= nil'))
        self.assertTrue(self.lua.eval('string.find(shown[2], "sp_joined", 1, true) ~= nil or shown[2] == string.format(ceb:txt("sp_joined"), ceb:char_display_name(own_second))'))
        # the refresh raises PendingBattle again for the same battle: no second offer
        self.fire_sp_battle()
        self.assertEqual(self.lua.eval('picker'), 1)
        # after the battle a new mission battle can be offered again
        self.lua.execute('listeners.ceb_sp_BattleSequenceCompleted.callback()')
        self.assertEqual(self.lua.eval('teleports[2]'), 'character_cqi:20@200,200#1')
        self.assertEqual(self.lua.eval('#ceb.teleports'), 0)
        self.fire_sp_battle()
        self.assertEqual(self.lua.eval('picker'), 2)

    def test_single_player_other_faction_army_simulates_ally(self):
        self.single_player()
        # 'third' becomes an AI faction (like Reikland): its army is offered after the own ones
        self.lua.execute("fc.is_human=function() return false end; fc.military_force_list=function() return list({third:military_force()}) end")
        self.fire_sp_battle()
        self.assertTrue(self.lua.eval('#ceb.ui.candidates == 2 and ceb.ui.candidates[1] == 20 and ceb.ui.candidates[2] == 30'))
        self.lua.execute('ceb:sp_join(30)')
        self.assertEqual(self.lua.eval('table.concat(native_calls, ",")'), 'inspect:4,join:4')
        self.assertEqual(self.lua.eval('teleports[1]'), 'character_cqi:30@101,102#0')
        self.assertEqual(self.lua.eval('updates'), 1)

    def test_single_player_inspect_rejection_never_joins(self):
        self.single_player()
        self.fire_sp_battle()
        self.lua.execute("sp_inspect_code='faction_already_present'; ceb:sp_join(20)")
        self.assertEqual(self.lua.eval('calls.join'), 0)
        self.assertEqual(self.lua.eval('updates'), None)
        self.assertTrue(self.lua.eval('string.find(shown[2], "faction_already_present", 1, true) ~= nil and ceb.session == nil'))

    def test_single_player_join_without_session_or_changed_battle_is_refused(self):
        self.single_player()
        self.assertFalse(self.lua.eval('ceb:sp_join(20)'))
        self.fire_sp_battle()
        self.lua.execute("pb.quest_mission_key=function() return 'other' end")
        self.assertFalse(self.lua.eval('ceb:sp_join(20)'))
        self.assertEqual(self.lua.eval('calls.inspect + calls.join'), 0)

    def test_single_player_without_second_army_shows_notice(self):
        self.single_player(second_army=False)
        self.fire_sp_battle()
        self.assertEqual(self.lua.eval('picker'), 0)
        self.assertTrue(self.lua.eval('shown[2] == ceb:txt("sp_inspect_no_army")'))

    def test_single_player_load_failure_reports_reason_and_adds_no_listener(self):
        self.lua.execute("package.loadlib=function() return nil, 'module not found' end")
        self.single_player()
        self.assertTrue(self.lua.eval('ceb.native == nil and listeners.ceb_sp_PendingBattle == nil'))
        self.assertTrue(self.lua.eval('string.find(shown[1], "module not found", 1, true) ~= nil'))

if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CompanionTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    (BASE / 'companion_validation.json').write_text(json.dumps({
        'lua_runtime': 'Lua 5.1 via lupa.lua51', 'tests_run': result.testsRun,
        'failures': len(result.failures), 'errors': len(result.errors), 'success': result.wasSuccessful(),
        'live_game_tested': False, 'native_dll_mocked': True,
        'limitations': ['Does not execute the DLL or render the UI.', 'Does not establish multiplayer control, battle loading or native casualty/XP behavior.']
    }, indent=2) + '\n', encoding='utf-8')
    raise SystemExit(not result.wasSuccessful())
