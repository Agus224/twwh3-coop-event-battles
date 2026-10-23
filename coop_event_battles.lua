--[[
=====================================================================================
	CO-OP EVENT BATTLES  (Total War: WARHAMMER III - campaign mod)  v2
	-------------------------------------------------------------------------------
	UI review build: this does NOT implement a second human campaign army.
	Teleport + update_pending_battle failed in the tested quest battle. No exposed
	API to bind another campaign army to a scripted ally slot has been established.
	The existing gameplay below still LENDS
	the ally's troops to the host for that battle:

	  1. Player 1 teleports to a mission battle with the native "Teleport" button.
	  2. Every other human player (not at war with player 1) gets a popup with the
	     list of their armies and picks one with a single click (or declines).
	  3. The units of that army (up to 20, lords and heroes stay home) are copied
	     into player 1's army for this battle - same unit type, health and rank -
	     and the army size limit is raised (40 by default) so they fit.
	  4. After the battle the copies are removed and the result goes back to the
	     ally's real units: casualties, experience gained, or the unit is lost if
	     it was wiped out.

	All model changes run from UITrigger / model events, so they are identical on
	every machine (multiplayer safe). The popup is local UI only.
	The mod also ships a small edit of the "another player is in a pending action"
	blocking panel so it steps aside while our popup is open (otherwise it swallows
	every click on the invited player's screen).
=====================================================================================
]]

local ceb = {
	version = "2.1.1-ui",

	-- ======================= CONFIG =======================
	config = {
		invite_timeout_seconds = 60,     -- time an invited ally has to answer
		host_wait_timeout_seconds = 75,  -- host safety net (should be > invite timeout)
		max_lent_units = 20,             -- max units lent by one ally (a full army)
		lend_characters = true,          -- also copy the lord and heroes (as units) - experimental
		army_cap_during_loan = 40,       -- army size limit while troops are lent
		include_quest_mission_battles = true,
		debug = true,                    -- writes coop_event_battles_log.txt
	},

	trigger_prefix = "CEB|",
	invite_dialog_name = "ceb_invite_dialog",
	host_dialog_name = "ceb_host_dialog",
	info_dialog_name = "ceb_info_dialog",
	dialog_layout = "UI/Common UI/dialogue_box",

	-- ======================= MODEL STATE (identical on every client) =======================
	session = nil,
	session_counter = 0,
	loans = {},          -- list of active loans, see ceb:handle_join()
	cap_overridden = false,

	-- ======================= LOCAL UI STATE (per client) =======================
	ui = {
		candidates = {},
		page = 1,
		host_override_active = false,
		open = {},
		watchdog_running = false,
	},

	lang = nil,
}

-----------------------------------------------------------------------------------
-- LOGGING
-----------------------------------------------------------------------------------

function ceb:log(msg)
	msg = "[CoopEventBattles] " .. tostring(msg)
	if out then out(msg) end
	if self.config.debug then
		pcall(function()
			local f = io.open("coop_event_battles_log.txt", "a")
			if f then
				f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
				f:close()
			end
		end)
	end
end

-----------------------------------------------------------------------------------
-- TEXT (Spanish / English, chosen from the game's language.txt - local only)
-----------------------------------------------------------------------------------

ceb.text = {
	EN = {
		invite_list = "Your ally [[col:yellow]]%s[[/col]] teleported to the mission battle [[col:yellow]]%s[[/col]].\n\nClick an army to send it to the battle (lord, heroes and units). You will control it in battle. Casualties and experience go back to your army afterwards.",
		no_armies = "Your ally [[col:yellow]]%s[[/col]] teleported to the mission battle [[col:yellow]]%s[[/col]].\n\nYou have no army with troops that can be lent right now.",
		army_button = "%s - %d units",
		more_armies = "More armies (%d/%d)",
		accept_tooltip = "Send this army to the battle",
		decline_tooltip = "Don't help",
		host_wait = "Mission battle: [[col:yellow]]%s[[/col]]\n\nWaiting for your allies to decide whether they lend you troops...\n\n[[col:grey]]Press X to stop waiting and fight alone.[[/col]]",
		host_wait_tooltip = "Stop waiting",
		joined = "[[col:yellow]]%s[[/col]] lends [[col:yellow]]%d[[/col]] units to [[col:yellow]]%s[[/col]] for this battle!",
		joined_host = "[[col:yellow]]%s[[/col]] sent their army: [[col:yellow]]%d[[/col]] units were added at the END of your army.\n\nIn battle, select those last %d units and press [[col:yellow]]Gift units[[/col]] so your ally controls them.",
		joined_ally = "Your army ([[col:yellow]]%d[[/col]] units) joins the battle inside your ally's army.\n\nOn the pre-battle screen choose [[col:yellow]]%s[[/col]] (not Spectate). In battle your ally will gift you control of your troops.",
		support_attacker = "Support Attacker",
		support_defender = "Support Defender",
		declined = "[[col:yellow]]%s[[/col]] will not lend troops for this battle.",
		join_failed = "The troops of [[col:yellow]]%s[[/col]] could not be added to the battle.",
		returned = "Your troops are back: %d returned, %d lost in battle.",
		unknown_battle = "Mission battle",
	},
	SP = {
		invite_list = "Tu aliado [[col:yellow]]%s[[/col]] se teletransportó a la batalla de misión [[col:yellow]]%s[[/col]].\n\nHacé clic en un ejército para mandarlo a la batalla (lord, héroes y unidades). Lo vas a controlar vos en la batalla. Las bajas y la experiencia vuelven a tu ejército al terminar.",
		no_armies = "Tu aliado [[col:yellow]]%s[[/col]] se teletransportó a la batalla de misión [[col:yellow]]%s[[/col]].\n\nAhora mismo no tenés ningún ejército con tropas para prestar.",
		army_button = "%s - %d unidades",
		more_armies = "Más ejércitos (%d/%d)",
		accept_tooltip = "Mandar este ejército a la batalla",
		decline_tooltip = "No ayudar",
		host_wait = "Batalla de misión: [[col:yellow]]%s[[/col]]\n\nEsperando a que tus aliados decidan si te prestan tropas...\n\n[[col:grey]]Pulsá X para dejar de esperar y combatir solo.[[/col]]",
		host_wait_tooltip = "Dejar de esperar",
		joined = "¡[[col:yellow]]%s[[/col]] le presta [[col:yellow]]%d[[/col]] unidades a [[col:yellow]]%s[[/col]] para esta batalla!",
		joined_host = "[[col:yellow]]%s[[/col]] mandó su ejército: se sumaron [[col:yellow]]%d[[/col]] unidades al FINAL de tu ejército.\n\nEn la batalla, seleccioná esas últimas %d unidades y pulsá [[col:yellow]]Regalar unidades[[/col]] para que las controle tu aliado.",
		joined_ally = "Tu ejército ([[col:yellow]]%d[[/col]] unidades) entra a la batalla dentro del ejército de tu aliado.\n\nEn la pantalla previa a la batalla elegí [[col:yellow]]%s[[/col]] (no Espectar). En la batalla tu aliado te va a regalar el control de tus tropas.",
		support_attacker = "Apoyar al atacante",
		support_defender = "Apoyar al defensor",
		declined = "[[col:yellow]]%s[[/col]] no va a prestar tropas para esta batalla.",
		join_failed = "No se pudieron sumar las tropas de [[col:yellow]]%s[[/col]] a la batalla.",
		returned = "Tus tropas volvieron: %d regresaron, %d se perdieron en la batalla.",
		unknown_battle = "Batalla de misión",
	},
}

function ceb:get_lang()
	if self.lang then return self.lang end
	local lang = "EN"
	pcall(function()
		local f = io.open("data/language.txt", "r")
		if f then
			local code = f:read("*l")
			f:close()
			if code then
				code = string.upper(string.gsub(code, "%s", ""))
				if code == "SP" or code == "ES" or code == "BR" then
					lang = "SP"
				end
			end
		end
	end)
	self.lang = lang
	return lang
end

function ceb:txt(key)
	local t = self.text[self:get_lang()] or self.text.EN
	return t[key] or self.text.EN[key] or key
end

-----------------------------------------------------------------------------------
-- MODEL HELPERS (read only)
-----------------------------------------------------------------------------------

local function is_valid(obj)
	return obj and not obj:is_null_interface()
end

function ceb:get_char(cqi)
	if not cqi then return false end
	local character = cm:model():character_for_command_queue_index(cqi)
	if is_valid(character) then return character end
	return false
end

function ceb:faction_display_name(faction_key)
	local name = common.get_localised_string("factions_screen_name_" .. faction_key)
	if not name or name == "" then name = faction_key end
	return name
end

function ceb:char_display_name(character)
	local name = ""
	pcall(function()
		local fk, sk = character:get_forename(), character:get_surname()
		local forename = (fk and fk ~= "") and common.get_localised_string(fk) or ""
		local surname = (sk and sk ~= "") and common.get_localised_string(sk) or ""
		name = forename or ""
		if surname and surname ~= "" then name = name .. " " .. surname end
	end)
	if name == "" then name = "#" .. tostring(character:command_queue_index()) end
	return name
end

function ceb:battle_display_name(battle_key)
	if battle_key and battle_key ~= "" then
		local name = common.get_localised_string("battle_set_pieces_localised_name_" .. battle_key)
		if name and name ~= "" then return name end
	end
	return self:txt("unknown_battle")
end

function ceb:pending_battle_participants(pb)
	local list = {}
	if pb:has_attacker() then table.insert(list, pb:attacker()) end
	if pb:has_defender() then table.insert(list, pb:defender()) end
	local sa = pb:secondary_attackers()
	for i = 0, sa:num_items() - 1 do table.insert(list, sa:item_at(i)) end
	local sd = pb:secondary_defenders()
	for i = 0, sd:num_items() - 1 do table.insert(list, sd:item_at(i)) end
	return list
end

function ceb:faction_in_pending_battle(pb, faction_key)
	for _, character in ipairs(self:pending_battle_participants(pb)) do
		if is_valid(character) and character:faction():name() == faction_key then return true end
	end
	return false
end

function ceb:char_in_pending_battle(pb, cqi)
	for _, character in ipairs(self:pending_battle_participants(pb)) do
		if is_valid(character) and character:command_queue_index() == cqi then return true end
	end
	return false
end

function ceb:is_character_unit(unit)
	local is_char = false
	pcall(function()
		if unit:has_unit_commander() then is_char = true end
		local caste = unit:unit_caste()
		if caste == "lord" or caste == "hero" then is_char = true end
	end)
	return is_char
end

-- Units of a force that can be lent: the whole army (lord and heroes included when
-- config.lend_characters is on)
function ceb:get_lendable_units(mf)
	local result = {}
	local unit_list = mf:unit_list()
	for i = 0, unit_list:num_items() - 1 do
		local unit = unit_list:item_at(i)
		if self.config.lend_characters or not self:is_character_unit(unit) then
			table.insert(result, unit)
		end
		if #result >= self.config.max_lent_units then break end
	end
	return result
end

function ceb:find_unit_in_force(mf, unit_cqi)
	if not is_valid(mf) then return false end
	local unit_list = mf:unit_list()
	for i = 0, unit_list:num_items() - 1 do
		local unit = unit_list:item_at(i)
		if unit:command_queue_index() == unit_cqi then return unit end
	end
	return false
end

function ceb:is_eligible_army_char(character, faction_key)
	if not is_valid(character) then return false end
	if character:faction():name() ~= faction_key then return false end
	if not character:has_military_force() then return false end
	local mf = character:military_force()
	if not is_valid(mf) then return false end
	if mf:is_armed_citizenry() or mf:is_set_piece_battle_army() then return false end
	if not mf:is_army() then return false end
	if #self:get_lendable_units(mf) == 0 then return false end
	local pb = cm:model():pending_battle()
	if pb:is_active() and self:char_in_pending_battle(pb, character:command_queue_index()) then return false end
	-- an army that is already lent cannot be lent twice
	for _, loan in ipairs(self.loans) do
		if loan.ally_cqi == character:command_queue_index() then return false end
	end
	return true
end

-- Ordered list of eligible general cqis (strongest first)
function ceb:get_eligible_army_cqis(faction_key)
	local faction = cm:get_faction(faction_key)
	if not faction then return {} end
	local entries = {}
	local mf_list = faction:military_force_list()
	for i = 0, mf_list:num_items() - 1 do
		local mf = mf_list:item_at(i)
		if mf:has_general() then
			local general = mf:general_character()
			if self:is_eligible_army_char(general, faction_key) then
				local strength = 0
				pcall(function() strength = mf:strength() end)
				table.insert(entries, { cqi = general:command_queue_index(), strength = strength })
			end
		end
	end
	table.sort(entries, function(a, b)
		if a.strength ~= b.strength then return a.strength > b.strength end
		return a.cqi < b.cqi
	end)
	local result = {}
	for _, e in ipairs(entries) do table.insert(result, e.cqi) end
	return result
end

-----------------------------------------------------------------------------------
-- SESSION (model state)
-----------------------------------------------------------------------------------

function ceb:is_relevant_battle(pb)
	if not pb:is_active() or pb:has_been_fought() then return false end
	local key = pb:set_piece_battle_key()
	if key and key ~= "" then return true end
	if self.config.include_quest_mission_battles then
		local ok, mission_key = pcall(function() return pb:quest_mission_key() end)
		if ok and mission_key and mission_key ~= "" then return true end
	end
	return false
end

function ceb:get_host_character(pb)
	if pb:has_attacker() then
		local attacker = pb:attacker()
		if is_valid(attacker) and attacker:faction():is_human() then return attacker end
	end
	if pb:has_defender() then
		local defender = pb:defender()
		if is_valid(defender) and defender:faction():is_human() then return defender end
	end
	return false
end

function ceb:list_contains(list, value)
	for _, v in ipairs(list) do
		if v == value then return true end
	end
	return false
end

function ceb:on_pending_battle(pb)
	if not cm:is_multiplayer() then return end
	if not self:is_relevant_battle(pb) then return end

	local host = self:get_host_character(pb)
	if not host then return end

	local host_faction_key = host:faction():name()
	local host_cqi = host:command_queue_index()
	local battle_key = pb:set_piece_battle_key() or ""
	local mission_key = ""
	pcall(function() mission_key = pb:quest_mission_key() or "" end)

	if self.session then
		if self.session.host_cqi == host_cqi and self.session.battle_key == battle_key and self.session.mission_key == mission_key then
			self:log("PendingBattle re-fired for the active session " .. self.session.id .. ", ignoring")
			return
		end
		self:log("Closing stale session " .. self.session.id)
		self:end_session()
	end

	local invited = {}
	local host_faction = host:faction()
	for _, faction_key in ipairs(cm:get_human_factions()) do
		if faction_key ~= host_faction_key then
			local faction = cm:get_faction(faction_key)
			if faction and not faction:is_dead() and not faction:at_war_with(host_faction) then
				table.insert(invited, faction_key)
			end
		end
	end

	if #invited == 0 then
		self:log("Mission battle " .. battle_key .. " by " .. host_faction_key .. ": nobody to invite")
		return
	end

	self.session_counter = self.session_counter + 1
	self.session = {
		id = tostring(cm:model():turn_number()) .. "_" .. tostring(host_cqi) .. "_" .. tostring(self.session_counter),
		battle_key = battle_key,
		mission_key = mission_key,
		host_faction = host_faction_key,
		host_cqi = host_cqi,
		host_is_attacker = pb:has_attacker() and pb:attacker():command_queue_index() == host_cqi,
		invited = invited,
		responded = {},
		closed = false,
	}
	self:log("Session " .. self.session.id .. " started. battle=[" .. battle_key .. "] mission=[" .. mission_key .. "] host=[" .. host_faction_key .. "] invited=[" .. table.concat(invited, ",") .. "]")

	self:ui_on_session_started()
end

function ceb:all_responded()
	local s = self.session
	if not s or s.closed then return true end
	for _, faction_key in ipairs(s.invited) do
		if not self:list_contains(s.responded, faction_key) then return false end
	end
	return true
end

function ceb:check_session_complete()
	if self:all_responded() then
		if self.session then self.session.closed = true end
		self:ui_close_host_wait()
		self:ui_close_invite()
	end
end

function ceb:end_session()
	self.session = nil
	self:ui_close_host_wait()
	self:ui_close_invite()
end

-----------------------------------------------------------------------------------
-- NETWORK MESSAGES (UITrigger - received identically by every client)
-----------------------------------------------------------------------------------

function ceb:send(msg)
	local faction_cqi = 0
	pcall(function()
		local local_faction = cm:get_local_faction(true)
		if local_faction then faction_cqi = local_faction:command_queue_index() end
	end)
	self:log("Sending " .. self.trigger_prefix .. msg)
	CampaignUI.TriggerCampaignScriptEvent(faction_cqi, self.trigger_prefix .. msg)
end

local function split(str, sep)
	local result = {}
	for part in string.gmatch(str, "([^" .. sep .. "]+)") do table.insert(result, part) end
	return result
end

function ceb:on_ui_trigger(context)
	local trigger = context:trigger()
	local parts = split(string.sub(trigger, #self.trigger_prefix + 1), "|")
	local action, session_id = parts[1], parts[2]

	local sender_faction_key = false
	local sender_faction = cm:model():faction_for_command_queue_index(context:faction_cqi())
	if is_valid(sender_faction) then sender_faction_key = sender_faction:name() end

	self:log("Received " .. trigger .. " from " .. tostring(sender_faction_key))

	local s = self.session
	if not s or s.id ~= session_id then
		self:log("  ignoring: no matching session (active: " .. tostring(s and s.id) .. ")")
		return
	end

	if action == "J" then
		self:handle_join(sender_faction_key, tonumber(parts[3]))
	elseif action == "D" then
		self:handle_decline(sender_faction_key)
	elseif action == "C" and sender_faction_key == s.host_faction then
		for _, faction_key in ipairs(s.invited) do
			if not self:list_contains(s.responded, faction_key) then table.insert(s.responded, faction_key) end
		end
		s.closed = true
		self:check_session_complete()
	end
end

function ceb:handle_decline(faction_key)
	local s = self.session
	if not faction_key or not self:list_contains(s.invited, faction_key) or self:list_contains(s.responded, faction_key) then return end
	table.insert(s.responded, faction_key)
	self:ui_notify_participants(string.format(self:txt("declined"), self:faction_display_name(faction_key)), faction_key)
	self:check_session_complete()
end

-- returns the list of units created by grant_unit_to_character, whatever its return type
function ceb:grant_unit(host_lookup, host_mf, unit_key)
	local before = {}
	local list = host_mf:unit_list()
	for i = 0, list:num_items() - 1 do before[list:item_at(i):command_queue_index()] = true end

	local function find_new()
		local l = host_mf:unit_list()
		for i = l:num_items() - 1, 0, -1 do
			local unit = l:item_at(i)
			if not before[unit:command_queue_index()] and unit:unit_key() == unit_key then
				return unit
			end
		end
		return false
	end

	-- same call CA uses in wh3_campaign_caravans_core.lua; plain 2-argument form as fallback
	pcall(function() cm:grant_unit_to_character(host_lookup, unit_key, true, 1) end)
	local unit = find_new()
	if not unit then
		pcall(function() cm:grant_unit_to_character(host_lookup, unit_key) end)
		unit = find_new()
	end
	return unit
end

function ceb:set_army_cap(cap)
	if cap and cap > 0 then
		cm:override_human_player_max_units(cap)
		self.cap_overridden = true
	else
		cm:override_human_player_max_units(0)
		self.cap_overridden = false
	end
end

function ceb:handle_join(faction_key, char_cqi)
	local s = self.session
	if s.closed or not faction_key or not self:list_contains(s.invited, faction_key) or self:list_contains(s.responded, faction_key) then
		self:log("  join rejected: session closed or faction not invited / already answered")
		return
	end
	table.insert(s.responded, faction_key)

	local pb = cm:model():pending_battle()
	local host = self:get_char(s.host_cqi)
	local ally = self:get_char(char_cqi)

	if not pb:is_active() or pb:has_been_fought() or not host or not host:has_military_force() then
		self:log("  join rejected: pending battle no longer active")
		self:check_session_complete()
		return
	end
	if not self:is_eligible_army_char(ally, faction_key) then
		self:log("  join rejected: character " .. tostring(char_cqi) .. " is not an eligible army of " .. faction_key)
		self:ui_notify_participants(string.format(self:txt("join_failed"), self:faction_display_name(faction_key)), nil)
		self:check_session_complete()
		return
	end

	local host_mf = host:military_force()
	local host_lookup = cm:char_lookup_str(host)
	local lendable = self:get_lendable_units(ally:military_force())
	local host_units_before = host_mf:unit_list():num_items()

	-- make room: raise the army size limit while the loan lasts
	local cap = math.max(self.config.army_cap_during_loan, host_units_before + #lendable + self:units_already_lent_to(s.host_cqi))
	self:set_army_cap(cap)

	local loan = {
		session_id = s.id,
		host_cqi = s.host_cqi,
		host_faction = s.host_faction,
		ally_cqi = char_cqi,
		ally_faction = faction_key,
		items = {},
	}

	local chars_added, chars_refused = 0, 0
	for _, unit in ipairs(lendable) do
		local key = unit:unit_key()
		local is_char = self:is_character_unit(unit)
		local hp = unit:percentage_proportion_of_full_strength() / 100
		local level = unit:experience_level()
		local copy = self:grant_unit(host_lookup, host_mf, key)
		if copy then
			pcall(function() cm:set_unit_hp_to_unary_of_maximum(copy, math.max(0.05, hp)) end)
			if not is_char then
				local diff = level - copy:experience_level()
				if diff > 0 then pcall(function() cm:add_experience_to_unit(copy, diff) end) end
			end
			table.insert(loan.items, {
				key = key,
				is_char = is_char,
				orig_cqi = unit:command_queue_index(),
				copy_cqi = copy:command_queue_index(),
				orig_level = level,
			})
			if is_char then
				chars_added = chars_added + 1
				self:log("  character unit " .. key .. " added")
			end
		else
			if is_char then
				chars_refused = chars_refused + 1
				self:log("  character unit " .. key .. " refused by the game")
			else
				self:log("  could not add unit " .. key .. " to the host army")
			end
		end
	end
	loan.chars_added = chars_added

	if #loan.items == 0 then
		self:log("  join failed: no unit could be added")
		self:release_cap_if_unused()
		self:ui_notify_participants(string.format(self:txt("join_failed"), self:faction_display_name(faction_key)), nil)
		self:check_session_complete()
		return
	end

	table.insert(self.loans, loan)

	-- rebuild the pending battle so the battle uses the bigger army
	cm:update_pending_battle()

	self:log("  lent " .. #loan.items .. " units from " .. faction_key .. " (cqi " .. char_cqi .. ") to host cqi " .. s.host_cqi ..
		". Host army: " .. host_units_before .. " -> " .. host_mf:unit_list():num_items() .. " units (cap " .. cap .. ")")

	self:check_session_complete()

	-- local instructions: how the ally gets control of the troops in battle
	local local_key = self:local_faction_key()
	local side = s.host_is_attacker and self:txt("support_attacker") or self:txt("support_defender")
	if local_key == s.host_faction then
		self:ui_show_info(string.format(self:txt("joined_host"), self:faction_display_name(faction_key), #loan.items, #loan.items), 20000)
	elseif local_key == faction_key then
		self:ui_show_info(string.format(self:txt("joined_ally"), #loan.items, side), 20000)
	elseif self:list_contains(s.invited, local_key) then
		self:ui_show_info(string.format(self:txt("joined"), self:faction_display_name(faction_key), #loan.items, self:faction_display_name(s.host_faction)))
	end
end

function ceb:units_already_lent_to(host_cqi)
	local n = 0
	for _, loan in ipairs(self.loans) do
		if loan.host_cqi == host_cqi then n = n + #loan.items end
	end
	return n
end

function ceb:release_cap_if_unused()
	if #self.loans == 0 and self.cap_overridden then
		self:set_army_cap(0)
		self:log("Army size limit restored")
	end
end

-----------------------------------------------------------------------------------
-- GIVE THE TROOPS BACK (model, all clients)
-----------------------------------------------------------------------------------

function ceb:settle_loans()
	if #self.loans == 0 then return end
	if cm:model():pending_battle():is_active() then
		self:log("Loan settlement postponed: a pending battle is active")
		return
	end

	for _, loan in ipairs(self.loans) do
		local host = self:get_char(loan.host_cqi)
		local ally = self:get_char(loan.ally_cqi)
		local host_mf = (host and host:has_military_force()) and host:military_force() or false
		local ally_mf = (ally and ally:has_military_force()) and ally:military_force() or false
		local returned, lost = 0, 0

		for _, item in ipairs(loan.items) do
			local copy = host_mf and self:find_unit_in_force(host_mf, item.copy_cqi) or false
			local orig = ally_mf and self:find_unit_in_force(ally_mf, item.orig_cqi) or false

			if item.is_char then
				-- lord / hero copies: the real character is never touched
				if copy then pcall(function() cm:remove_unit_by_cqi(item.copy_cqi) end) end
				returned = returned + 1
			elseif copy then
				local hp = copy:percentage_proportion_of_full_strength() / 100
				local level = copy:experience_level()
				if orig then
					pcall(function() cm:set_unit_hp_to_unary_of_maximum(orig, math.max(0.01, hp)) end)
					local diff = level - orig:experience_level()
					if diff > 0 then pcall(function() cm:add_experience_to_unit(orig, diff) end) end
				end
				pcall(function() cm:remove_unit_by_cqi(item.copy_cqi) end)
				returned = returned + 1
			else
				-- the lent unit was wiped out in battle (or the host army was destroyed)
				if orig then pcall(function() cm:remove_unit_by_cqi(item.orig_cqi) end) end
				lost = lost + 1
			end
		end

		self:log("Loan settled: " .. loan.ally_faction .. " -> " .. loan.host_faction .. ": " .. returned .. " returned, " .. lost .. " lost")
		if self:local_faction_key() == loan.ally_faction then
			self:ui_show_info(string.format(self:txt("returned"), returned, lost))
		end
	end

	self.loans = {}
	self:release_cap_if_unused()
end

-----------------------------------------------------------------------------------
-- UI (local only - never changes the model)
-----------------------------------------------------------------------------------

function ceb:local_faction_key()
	local ok, key = pcall(function() return cm:get_local_faction_name(true) end)
	if ok then return key end
	return false
end

ceb.dialog_priority = 3000

-- The mod's copy of mp_pending_action_blocking_msg hides itself and stops locking
-- input while the UI context value "ceb_ui_open" is 1.
function ceb:update_blocker_override()
	local any_open = false
	for _, v in pairs(self.ui.open or {}) do
		if v then any_open = true end
	end
	pcall(function() common.set_context_value("ceb_ui_open", any_open and 1 or 0) end)
end

function ceb:create_dialog(name, lock, layout)
	local root = core:get_ui_root()
	local existing = find_uicomponent(root, name)
	if existing then
		pcall(function() existing:RemoveTopMost() end)
		pcall(function() existing:UnLockPriority() end)
		existing:Destroy()
	end

	self.ui.open[name] = true
	self:update_blocker_override()

	local dialog = UIComponent(root:CreateComponent(name, layout or self.dialog_layout))
	dialog:PropagatePriority(self.dialog_priority)
	if lock ~= false then pcall(function() dialog:LockPriority() end) end
	pcall(function() dialog:RegisterTopMost() end)

	self:start_dialog_watchdog()
	return dialog
end

function ceb:destroy_dialog(name)
	self.ui.open[name] = nil
	self:update_blocker_override()
	pcall(function()
		local dialog = find_uicomponent(core:get_ui_root(), name)
		if dialog then
			pcall(function() dialog:RemoveTopMost() end)
			pcall(function() dialog:UnLockPriority() end)
			dialog:Destroy()
		end
	end)
end

-- Once per second while a dialog is open: rebuild it if something destroyed it.
function ceb:start_dialog_watchdog()
	if self.ui.watchdog_running then return end
	self.ui.watchdog_running = true

	cm:repeat_real_callback(function()
		local ok, err = pcall(function()
			local any_open = false
			local root = core:get_ui_root()
			for _, name in ipairs({ self.invite_dialog_name, self.host_dialog_name, self.info_dialog_name }) do
				if self.ui.open[name] then
					any_open = true
					if not find_uicomponent(root, name) then
						self.ui.open[name] = nil
						if name == self.invite_dialog_name and self.session then
							self:log("Invite dialog disappeared, rebuilding it")
							self:ui_build_invite_dialog()
						elseif name == self.host_dialog_name and self.session then
							self:log("Host dialog disappeared, rebuilding it")
							self:ui_build_host_dialog()
						end
					end
				end
			end
			self:update_blocker_override()
			if not any_open then
				cm:remove_real_callback("ceb_dialog_watchdog")
				self.ui.watchdog_running = false
			end
		end)
		if not ok then self:log("UI watchdog error: " .. tostring(err)) end
	end, 1000, "ceb_dialog_watchdog")
end

function ceb:set_dialog_text(dialog, text)
	local uic_text = find_uicomponent(dialog, "DY_text")
	if uic_text then uic_text:SetStateText(text, "") end
end

function ceb:ui_on_session_started()
	local s = self.session
	local local_key = self:local_faction_key()
	if not s or not local_key then return end
	if local_key == s.host_faction then
		self:ui_show_host_wait()
	elseif self:list_contains(s.invited, local_key) then
		self:ui_show_invite()
	end
end

-- HOST ----------------------------------------------------------------------------

function ceb:ui_build_host_dialog()
	local s = self.session
	if not s then return end
	local ok, err = pcall(function()
		local dialog = self:create_dialog(self.host_dialog_name)
		self:set_dialog_text(dialog, string.format(self:txt("host_wait"), self:battle_display_name(s.battle_key)))
		local tick = find_uicomponent(dialog, "both_group", "button_tick")
		if tick then tick:SetVisible(false) end
		local cancel = find_uicomponent(dialog, "both_group", "button_cancel")
		if cancel then cancel:SetTooltipText(self:txt("host_wait_tooltip"), true) end
	end)
	if not ok then self:log("UI error (host wait): " .. tostring(err)) end
end

function ceb:ui_show_host_wait()
	local s = self.session
	pcall(function()
		cm:override_ui("disable_prebattle_attack", true)
		self.ui.host_override_active = true
	end)
	self:ui_build_host_dialog()

	local session_id = s.id
	cm:remove_real_callback("ceb_host_timeout")
	cm:real_callback(function()
		if self.session and self.session.id == session_id and not self:all_responded() then
			self:log("Host wait timed out locally, sending stop-waiting")
			self:send("C|" .. session_id)
		end
		self:ui_close_host_wait()
	end, self.config.host_wait_timeout_seconds * 1000, "ceb_host_timeout")
end

function ceb:ui_close_host_wait()
	cm:remove_real_callback("ceb_host_timeout")
	if self.ui.host_override_active then
		pcall(function() cm:override_ui("disable_prebattle_attack", false) end)
		self.ui.host_override_active = false
	end
	self:destroy_dialog(self.host_dialog_name)
end

-- INVITED ALLY: list of armies -------------------------------------------------

function ceb:ui_show_invite()
	local s = self.session
	if not s then return end
	self.ui.candidates = self:get_eligible_army_cqis(self:local_faction_key())
	self.ui.page = 1
	self:ui_build_invite_dialog()

	local session_id = s.id
	cm:remove_real_callback("ceb_invite_timeout")
	cm:real_callback(function()
		if self.session and self.session.id == session_id and self.ui.open[self.invite_dialog_name] then
			self:log("Invite timed out, declining")
			self:ui_close_invite()
			self:send("D|" .. session_id)
		end
	end, self.config.invite_timeout_seconds * 1000, "ceb_invite_timeout")
end

function ceb:ui_army_label(cqi)
	local character = self:get_char(cqi)
	if not character or not character:has_military_force() then return "?" end
	return string.format(self:txt("army_button"), self:char_display_name(character), #self:get_lendable_units(character:military_force()))
end

local function bounds(uic)
	local ok, w, h = pcall(function() return uic:Bounds() end)
	if ok then return w, h end
	return 0, 0
end

local function position(uic)
	local ok, x, y = pcall(function() return uic:Position() end)
	if ok then return x, y end
	return 0, 0
end

-- Every picker component has a plain, non-layout-managed parent. The vanilla
-- DialogueBoxCC/List/min_text_height callbacks must not manage these components.
local function place(uic, x, y, w, h)
	uic:SetDockingPoint(0)
	if w and h then
		uic:SetCanResizeWidth(true)
		uic:SetCanResizeHeight(true)
		uic:Resize(math.floor(w), math.floor(h))
	end
	uic:MoveTo(math.floor(x), math.floor(y))
end

local function button_text(uic, text)
	for _, state in ipairs({ "active", "hover", "down", "down_off", "inactive" }) do
		uic:SetState(state)
		uic:SetStateText(text, "")
	end
	uic:SetState("active")
end

ceb.ui_layout = {
	width = 600,
	margin = 24,
	title_h = 28,
	text_h = 78,
	row_h = 44,
	button_h = 40,
	footer_h = 34,
	footer_gap = 18,
	rows_per_page = 5,
}

-- Kept beside the local UI so the campaign/battle messages can evolve separately.
ceb.picker_text = {
	EN = {
		title = "Support your ally",
		invite = "%s requests support for:\n[[col:yellow]]%s[[/col]]\nChoose the army you want to send.",
		empty = "%s requests support for:\n[[col:yellow]]%s[[/col]]\nYou have no available armies.",
		previous = "Previous",
		next = "Next",
		decline = "Decline",
	},
	SP = {
		title = "Ayudá a tu aliado",
		invite = "%s solicita apoyo para:\n[[col:yellow]]%s[[/col]]\nElegí el ejército que querés enviar.",
		empty = "%s solicita apoyo para:\n[[col:yellow]]%s[[/col]]\nNo tenés ejércitos disponibles.",
		previous = "Anterior",
		next = "Siguiente",
		decline = "Rechazar",
	},
}

function ceb:ui_build_invite_dialog()
	local s = self.session
	if not s then return end

	local ok, err = pcall(function()
		local L = self.ui_layout
		local T = self.picker_text[self:get_lang()] or self.picker_text.EN
		local dialog = self:create_dialog(self.invite_dialog_name, true, "UI/Common UI/ceb_army_picker")
		-- Some UI loaders retain the XML root wrapper; position the painted panel.
		local panel = find_uicomponent(dialog, "ceb_picker") or dialog
		local candidates = self.ui.candidates or {}
		local sw, sh = core:get_screen_resolution()
		local width = math.min(L.width, sw - 48)
		local fixed_h = L.margin * 2 + L.title_h + 8 + L.text_h + 12 + L.footer_gap + L.footer_h
		local per_page = math.max(1, math.min(L.rows_per_page, math.floor((sh - 48 - fixed_h) / L.row_h)))
		self.ui.rows_per_page = per_page
		local pages = math.max(1, math.ceil(#candidates / per_page))
		self.ui.page = math.max(1, math.min(self.ui.page or 1, pages))
		local first = (self.ui.page - 1) * per_page + 1
		local last = math.min(#candidates, first + per_page - 1)
		local rows = math.max(0, last - first + 1)
		local height = fixed_h + rows * L.row_h
		place(panel, (sw - width) / 2, (sh - height) / 2, width, height)
		local dx, dy = position(panel)
		local dw, dh = bounds(panel)
		local inner_w = dw - 2 * L.margin
		local x = dx + L.margin
		local y = dy + L.margin

		local title = find_uicomponent(panel, "ceb_title")
		assert(title, "army picker title missing; install the dedicated UI layout")
		title:SetStateText(T.title, "")
		place(title, x, y, inner_w, L.title_h)
		y = y + L.title_h + 8
		local text = find_uicomponent(panel, "DY_text")
		assert(text, "army picker description missing")
		text:SetStateText(string.format(#candidates == 0 and T.empty or T.invite,
			self:faction_display_name(s.host_faction), self:battle_display_name(s.battle_key)), "")
		place(text, x, y, inner_w, L.text_h)
		y = y + L.text_h + 12

		local template = find_uicomponent(panel, "ceb_row_template")
		assert(template, "army picker row template missing")
		template:SetVisible(false)
		for i = first, last do
			local row = UIComponent(template:CopyComponent("ceb_army_" .. i))
			panel:Adopt(row:Address())
			row:SetVisible(true)
			row:SetState("active")
			button_text(row, self:ui_army_label(candidates[i]))
			row:SetTooltipText(self:ui_army_label(candidates[i]) .. "\n" .. self:txt("accept_tooltip"), true)
			place(row, x, y, inner_w, L.button_h)
			y = y + L.row_h
		end

		-- A dedicated footer is below the list, with a visible gap. Its controls
		-- never share the list's row template positions or count as an army.
		local footer_y = dy + dh - L.margin - L.footer_h
		local nav_w = math.min(100, math.floor((inner_w - 160) / 2))
		local prev = find_uicomponent(panel, "ceb_army_prev")
		local next_button = find_uicomponent(panel, "ceb_army_more")
		local page = find_uicomponent(panel, "ceb_page")
		local cancel = find_uicomponent(panel, "button_cancel")
		assert(prev and next_button and page and cancel, "army picker footer missing")
		prev:SetVisible(pages > 1)
		next_button:SetVisible(pages > 1)
		page:SetVisible(pages > 1)
		button_text(prev, T.previous)
		button_text(next_button, T.next)
		prev:SetState(self.ui.page > 1 and "active" or "inactive")
		next_button:SetState(self.ui.page < pages and "active" or "inactive")
		page:SetStateText(string.format("%d / %d", self.ui.page, pages), "")
		button_text(cancel, T.decline)
		cancel:SetTooltipText(self:txt("decline_tooltip"), true)
		place(prev, x, footer_y, nav_w, L.footer_h)
		place(page, x + nav_w + 8, footer_y + 8, 54, L.footer_h - 8)
		place(next_button, x + nav_w + 68, footer_y, nav_w, L.footer_h)
		place(cancel, x + inner_w - 112, footer_y, 112, L.footer_h)
		self:log(string.format("Invite picker: screen %dx%d, panel %dx%d, page %d/%d, %d rows",
			sw, sh, dw, dh, self.ui.page, pages, rows))
	end)
	if not ok then self:log("UI error (invite): " .. tostring(err)) end
end


function ceb:ui_close_invite()
	cm:remove_real_callback("ceb_invite_timeout")
	self:destroy_dialog(self.invite_dialog_name)
end

function ceb:is_our_click(uic, dialog_name)
	if not find_uicomponent(core:get_ui_root(), dialog_name) then return false end
	local ok, res = pcall(function() return uicomponent_descended_from(uic, dialog_name) end)
	return ok and res
end

function ceb:on_component_click(context)
	local uic = UIComponent(context.component)
	local id = context.string
	local s = self.session

	if self:is_our_click(uic, self.invite_dialog_name) then
		self:log("Click on " .. tostring(id))
		local army_index = string.match(id, "^ceb_army_(%d+)$")
		if army_index then
			local cqi = self.ui.candidates[tonumber(army_index)]
			self:ui_close_invite()
			if s and cqi then self:send("J|" .. s.id .. "|" .. tostring(cqi)) end
		elseif id == "ceb_army_more" or id == "ceb_army_prev" then
			local per_page = self.ui.rows_per_page or self.ui_layout.rows_per_page
			local pages = math.max(1, math.ceil(#self.ui.candidates / per_page))
			local step = id == "ceb_army_prev" and -1 or 1
			local page = math.max(1, math.min(pages, self.ui.page + step))
			if page ~= self.ui.page then
				self.ui.page = page
				self:ui_build_invite_dialog()
			end
		elseif id == "button_cancel" then
			self:ui_close_invite()
			if s then self:send("D|" .. s.id) end
		end
		return
	end

	if self:is_our_click(uic, self.host_dialog_name) then
		self:log("Click on " .. tostring(id))
		if id == "button_cancel" then
			self:ui_close_host_wait()
			if s then self:send("C|" .. s.id) end
		end
		return
	end

	if self:is_our_click(uic, self.info_dialog_name) then
		if id == "button_tick" or id == "button_cancel" then
			self:destroy_dialog(self.info_dialog_name)
		end
	end
end

function ceb:ui_show_info(text, duration_ms)
	local ok, err = pcall(function()
		local dialog = self:create_dialog(self.info_dialog_name, false)
		self:set_dialog_text(dialog, text)
		local both_group = find_uicomponent(dialog, "both_group")
		if both_group then both_group:SetVisible(false) end
		local ok_group = find_uicomponent(dialog, "ok_group")
		if ok_group then ok_group:SetVisible(true) end
	end)
	if not ok then self:log("UI error (info): " .. tostring(err)) end

	cm:remove_real_callback("ceb_info_autoclose")
	cm:real_callback(function() self:destroy_dialog(self.info_dialog_name) end, duration_ms or 8000, "ceb_info_autoclose")
end

function ceb:ui_notify_participants(text, skip_faction)
	local s = self.session
	local local_key = self:local_faction_key()
	if not s or not local_key or local_key == skip_faction then return end
	if local_key == s.host_faction or self:list_contains(s.invited, local_key) then
		self:ui_show_info(text)
	end
end

-----------------------------------------------------------------------------------
-- SAVE / LOAD
-----------------------------------------------------------------------------------

cm:add_saving_game_callback(
	function(context)
		cm:save_named_value("ceb_loans", ceb.loans, context)
		cm:save_named_value("ceb_session_counter", ceb.session_counter, context)
		cm:save_named_value("ceb_cap_overridden", ceb.cap_overridden, context)
	end
)

cm:add_loading_game_callback(
	function(context)
		ceb.loans = cm:load_named_value("ceb_loans", {}, context) or {}
		ceb.session_counter = cm:load_named_value("ceb_session_counter", 0, context) or 0
		ceb.cap_overridden = cm:load_named_value("ceb_cap_overridden", false, context) or false
	end
)

-----------------------------------------------------------------------------------
-- LISTENERS
-----------------------------------------------------------------------------------

function ceb:add_listeners()
	core:add_listener(
		"ceb_PendingBattle",
		"PendingBattle",
		true,
		function(context)
			local ok, err = pcall(function() self:on_pending_battle(context:pending_battle()) end)
			if not ok then self:log("ERROR in PendingBattle: " .. tostring(err)) end
		end,
		true
	)

	core:add_listener(
		"ceb_UITrigger",
		"UITrigger",
		function(context)
			local t = context:trigger()
			return is_string(t) and string.sub(t, 1, #self.trigger_prefix) == self.trigger_prefix
		end,
		function(context)
			local ok, err = pcall(function() self:on_ui_trigger(context) end)
			if not ok then self:log("ERROR in UITrigger: " .. tostring(err)) end
		end,
		true
	)

	-- battle over (fought, withdrawn or cancelled): give the troops back
	core:add_listener(
		"ceb_BattleSequenceCompleted",
		"ScriptEventBattleSequenceCompleted",
		true,
		function(context)
			local ok, err = pcall(function()
				if self.session then
					self:log("Battle sequence completed for session " .. self.session.id)
					self:end_session()
				end
				if #self.loans > 0 then
					cm:callback(function()
						local ok2, err2 = pcall(function() self:settle_loans() end)
						if not ok2 then self:log("ERROR settling loans: " .. tostring(err2)) end
					end, 0.5)
				end
			end)
			if not ok then self:log("ERROR in BattleSequenceCompleted: " .. tostring(err)) end
		end,
		true
	)

	-- fallback: settle at any turn start if something was missed (e.g. after loading a save)
	core:add_listener(
		"ceb_FactionTurnStart",
		"FactionTurnStart",
		function(context)
			return (#self.loans > 0 or self.cap_overridden) and context:faction():is_human()
		end,
		function(context)
			local ok, err = pcall(function()
				if self.session and not cm:model():pending_battle():is_active() then self:end_session() end
				self:settle_loans()
				self:release_cap_if_unused()
			end)
			if not ok then self:log("ERROR in FactionTurnStart: " .. tostring(err)) end
		end,
		true
	)

	core:add_listener(
		"ceb_ComponentLClickUp",
		"ComponentLClickUp",
		function(context)
			local id = context.string
			return id == "button_tick" or id == "button_cancel" or (is_string(id) and string.sub(id, 1, 9) == "ceb_army_")
		end,
		function(context)
			local ok, err = pcall(function() self:on_component_click(context) end)
			if not ok then self:log("ERROR in click handler: " .. tostring(err)) end
		end,
		true
	)
end

cm:add_first_tick_callback(
	function()
		ceb:log("v" .. ceb.version .. " loaded. Multiplayer: " .. tostring(cm:is_multiplayer()))
		if not cm:is_multiplayer() then return end
		pcall(function() common.set_context_value("ceb_ui_open", 0) end)
		ceb:add_listeners()
	end
)

_G.coop_event_battles = ceb
