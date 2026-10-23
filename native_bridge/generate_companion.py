"""Build the standalone companion from the reviewed picker source, removing loans."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parent
release = json.loads((ROOT / 'VERSION.json').read_text())
version = release['version']
source = (ROOT.parent / 'coop_event_battles.lua').read_text(encoding='utf-8')
source = source[source.index('local ceb = {'):]
source = source.replace('version = "2.1.1-ui"', 'version = "__CEB_VERSION__"')
for line in source.splitlines():
    if any(key in line for key in ['max_lent_units =', 'lend_characters =', 'army_cap_during_loan =', 'loans = {},', 'cap_overridden = false,']):
        source = source.replace(line + '\n', '')
source = source.replace('trigger_prefix = "CEB|"', 'trigger_prefix = "CEBN|"')
start = source.index('function ceb:is_character_unit(')
end = source.index('-- Ordered list of eligible general cqis', start)
source = source[:start] + '''function ceb:army_unit_count(mf)
    return mf:unit_list():num_items()
end

function ceb:is_eligible_army_char(character, faction_key)
    if not is_valid(character) or character:faction():name() ~= faction_key then return false end
    if not character:has_military_force() then return false end
    local mf = character:military_force()
    if not is_valid(mf) or not mf:is_army() or mf:is_armed_citizenry() or mf:is_set_piece_battle_army() then return false end
    if not mf:has_general() or mf:general_character():command_queue_index() ~= character:command_queue_index() then return false end
    if self:army_unit_count(mf) == 0 then return false end
    local pb = cm:model():pending_battle()
    if pb:is_active() and self:char_in_pending_battle(pb, character:command_queue_index()) then return false end
    return true
end

''' + source[end:]
start = source.index('-- returns the list of units created')
end = source.index('-- UI (local only', start)
source = source[:start] + (ROOT / 'native_gameplay.inc.lua').read_text(encoding='utf-8') + '\n' + source[end:]
source = source.replace('#self:get_lendable_units(character:military_force())', 'self:army_unit_count(character:military_force())')
start = source.index('cm:add_saving_game_callback(')
source = source[:start] + (ROOT / 'lifecycle.inc.lua').read_text(encoding='utf-8')
start = source.index('function ceb:on_ui_trigger(')
end = source.index('function ceb:handle_decline(', start)
source = source[:start] + (ROOT / 'network.inc.lua').read_text(encoding='utf-8') + '\n' + source[end:]
source = source.replace('if not cm:is_multiplayer() then return end\n\tif not self:is_relevant_battle(pb)', 'if not cm:is_multiplayer() or self.legacy_blocked then return end\n\tif not self:all_peers_ready() then self:log("Invitation blocked: missing or incompatible native readiness"); return end\n\tif not self:is_relevant_battle(pb)')
source = source.replace('if not faction_key or not self:list_contains(s.invited, faction_key)', 'if not s or s.closed or not faction_key or not self:list_contains(s.invited, faction_key)')
source = source.replace('version = "__CEB_VERSION__",', 'version = "__CEB_VERSION__",\n    protocol = "1",\n    peers = {},\n    legacy_loans = {},\n    legacy_cap = false,\n    legacy_blocked = false,')
# Single-player test: the shared army picker shows its own title and text for an SP session.
source = source.replace('title:SetStateText(T.title, "")', 'title:SetStateText(s.sp and T.sp_title or T.title, "")')
source = source.replace('text:SetStateText(string.format(#candidates == 0 and T.empty or T.invite,', 'text:SetStateText(string.format(#candidates == 0 and T.empty or (s.sp and T.sp_invite or T.invite),')
source = source.replace('\t\tdecline = "Decline",\n', '\t\tdecline = "Decline",\n\t\tsp_title = "Single-player test",\n\t\tsp_invite = "%s - mission battle:\\n[[col:yellow]]%s[[/col]]\\nChoose an army to join as reinforcements.",\n')
source = source.replace('\t\tdecline = "Rechazar",\n', '\t\tdecline = "Rechazar",\n\t\tsp_title = "Prueba en un jugador",\n\t\tsp_invite = "%s - batalla de misión:\\n[[col:yellow]]%s[[/col]]\\nElegí un ejército para unirlo como refuerzo.",\n')
# Army rows use the game's red text button skin; keep them a button-like width, centred.
# Buttons are docked to the panel instead of absolute MoveTo/Resize: in game the absolute
# coordinates of these button components did not match where they were drawn (scaled UI), while
# docking is resolved by the UI engine itself. Sizes come from the layout (rows 460x40, footer 100/112x34).
source = source.replace('place(row, x, y, inner_w, L.button_h)', 'row:SetDockingPoint(2)\n\t\t\trow:SetDockOffset(0, math.floor(y - dy))')
source = source.replace("""		place(prev, x, footer_y, nav_w, L.footer_h)
		place(page, x + nav_w + 8, footer_y + 8, 54, L.footer_h - 8)
		place(next_button, x + nav_w + 68, footer_y, nav_w, L.footer_h)
		place(cancel, x + inner_w - 112, footer_y, 112, L.footer_h)""", """		local function dock(uic, point, ox, oy) uic:SetDockingPoint(point); uic:SetDockOffset(math.floor(ox), math.floor(oy)) end
		dock(prev, 7, L.margin, -L.margin)
		dock(page, 7, L.margin + 108, -L.margin - 8)
		dock(next_button, 7, L.margin + 170, -L.margin)
		dock(cancel, 9, -L.margin, -L.margin)""")
# Picker placement: correct a reported position offset once, and log the real geometry.
source = source.replace("""	uic:MoveTo(math.floor(x), math.floor(y))
end
""", """	uic:MoveTo(math.floor(x), math.floor(y))
	-- If the engine reports a different position (scaled parent, docking leftovers), correct once.
	local px, py = position(uic)
	local ex, ey = math.floor(x) - px, math.floor(y) - py
	if math.abs(ex) > 1 or math.abs(ey) > 1 then uic:MoveTo(math.floor(x + ex), math.floor(y + ey)) end
end

local function geometry(uic)
	if not uic then return "nil" end
	local x, y = position(uic)
	local w, h = bounds(uic)
	return string.format("%d,%d %dx%d", x, y, w, h)
end
""", 1)
source = source.replace("""		self:log(string.format("Invite picker: screen %dx%d, panel %dx%d, page %d/%d, %d rows",
			sw, sh, dw, dh, self.ui.page, pages, rows))""", """		self:log(string.format("Invite picker: screen %dx%d, panel %dx%d, page %d/%d, %d rows",
			sw, sh, dw, dh, self.ui.page, pages, rows))
		self:log("Picker geometry: panel " .. geometry(panel) .. ", text " .. geometry(text) .. ", row1 " ..
			geometry(find_uicomponent(panel, "ceb_army_" .. first)) .. ", cancel " .. geometry(cancel) .. ", next " .. geometry(next_button))""", 1)
# Armies of another faction (single-player test) show their faction in the picker label.
source = source.replace("""	return string.format(self:txt("army_button"), self:char_display_name(character), self:army_unit_count(character:military_force()))""", """	local label = string.format(self:txt("army_button"), self:char_display_name(character), self:army_unit_count(character:military_force()))
	if character:faction():name() ~= self:local_faction_key() then label = label .. " (" .. self:faction_display_name(character:faction():name()) .. ")" end
	return label""", 1)
# Spacing: a gap between army buttons and a clear gap above the footer buttons.
source = source.replace("\trow_h = 44,", "\trow_h = 52,", 1)
source = source.replace("\tfooter_gap = 18,", "\tfooter_gap = 40,", 1)
source = source[:source.index('ceb.text = {')] + (ROOT / 'texts.inc.lua').read_text(encoding='utf-8') + '\n' + source[source.index('function ceb:get_lang()'):]
source = '''-- Co-op Event Battles native companion __CEB_VERSION__.
-- Real campaign army connection: no unit copies, loans or result emulation. The army is teleported\n-- beside the host (and back after the battle), like the game's quest teleport.
-- Requires the same supported native DLL and companion on every human client.
-- Release based on the pack verified by the user in single-player and multiplayer.
''' + source
source = source.replace('__CEB_VERSION__', version)
source = source.replace('protocol = "1"', 'protocol = "' + str(release['network_protocol']) + '"')
source = source.replace('title:SetStateText(s.sp and T.sp_title or T.title, "")',
    'title:SetStateText((s.sp and T.sp_title or T.title) .. " - v" .. self.version, "")')
(ROOT / 'campaign_bridge.lua').write_text(source, encoding='utf-8', newline='\n')
print('Generated campaign_bridge.lua with reviewed compact picker UI.')
