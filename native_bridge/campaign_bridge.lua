-- Co-op Event Battles native companion 1.1.2.
-- Real campaign army connection: no unit copies, loans or result emulation. The army is teleported
-- beside the host (and back after the battle), like the game's quest teleport.
-- Requires the same supported native DLL and companion on every human client.
-- Release based on the pack verified by the user in single-player and multiplayer.
local ceb = {
	version = "1.1.2",
    protocol = "1",
    peers = {},
    legacy_loans = {},
    legacy_cap = false,
    legacy_blocked = false,

	-- ======================= CONFIG =======================
	config = {
		invite_timeout_seconds = 60,     -- time an invited ally has to answer
		host_wait_timeout_seconds = 75,  -- host safety net (should be > invite timeout)
		include_quest_mission_battles = true,
		debug = true,                    -- writes coop_event_battles_log.txt
	},

	trigger_prefix = "CEBN|",
	invite_dialog_name = "ceb_invite_dialog",
	host_dialog_name = "ceb_host_dialog",
	info_dialog_name = "ceb_info_dialog",
	dialog_layout = "UI/Common UI/dialogue_box",

	-- ======================= MODEL STATE (identical on every client) =======================
	session = nil,
	session_counter = 0,

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

-- Keeps a log file small: when it passes max_bytes it is cut down to its last keep_bytes
-- (starting at a whole line), so the most recent history stays for bug reports.
function ceb.trim_log(path, max_bytes, keep_bytes)
	local f = io.open(path, "rb")
	if not f then return 0 end
	local size = f:seek("end") or 0
	if size <= max_bytes then f:close(); return size end
	f:seek("set", size - keep_bytes)
	local tail = f:read("*a") or ""
	f:close()
	local nl = string.find(tail, "\n")
	if nl then tail = string.sub(tail, nl + 1) end
	tail = "---- older lines removed (log limit " .. math.floor(max_bytes / 1024) .. " KB) ----\n" .. tail
	f = io.open(path, "wb")
	if not f then return size end
	f:write(tail)
	f:close()
	return #tail
end

ceb.log_file = "coop_event_battles_log.txt"
ceb.log_max = 512 * 1024   -- the log never grows past ~512 KB
ceb.log_keep = 128 * 1024  -- when trimmed, the last ~128 KB are kept

function ceb:log(msg)
	msg = "[CoopEventBattles] " .. tostring(msg)
	if out then out(msg) end
	if self.config.debug then
		pcall(function()
			local line = os.date("%H:%M:%S") .. " " .. msg .. "\n"
			if not self.log_size or self.log_size > self.log_max then
				local first = self.log_size == nil
				self.log_size = ceb.trim_log(self.log_file, self.log_max, self.log_keep)
				if first then
					line = os.date("\n==== %Y-%m-%d %H:%M:%S ") .. "Co-op Event Battles " .. tostring(self.version) .. " ====\n" .. line
				end
			end
			local f = io.open(self.log_file, "a")
			if f then
				f:write(line)
				f:close()
				self.log_size = self.log_size + #line
			end
		end)
	end
end

-----------------------------------------------------------------------------------
-- TEXT (Spanish / English, chosen from the game's language.txt - local only)
-----------------------------------------------------------------------------------

ceb.text = {
    EN = {
        army_button = "%s - %d units", accept_tooltip = "Connect this real army to the mission battle",
        decline_tooltip = "Decline support", host_wait_tooltip = "Stop waiting",
        host_wait = "Mission battle: [[col:yellow]]%s[[/col]]\n\nWaiting for your allies to select their real armies.\n\nPress X to stop waiting.",
        declined = "[[col:yellow]]%s[[/col]] declined support.",
        join_failed = "Could not connect the army of [[col:yellow]]%s[[/col]]. See coop_event_battles_log.txt. No units were copied.",
        joined = "The real army of [[col:yellow]]%s[[/col]] was added to the mission participants. Check the pre-battle participant list before starting.",
        unknown_battle = "Mission battle",
        legacy = "This save contains troops borrowed by an older mod version. Native support is disabled for this save. Use a save from before that loan; this build cannot settle it.",
        native_unavailable = "Native army support is unavailable. Every human player needs the same companion and supported DLL. See coop_event_battles_log.txt.",
        reload_required = "The native connection reported a serious error. Stop this test and reload the previous save on every client. Do not save the current campaign. See coop_event_battles_log.txt.",
        sp_native_ok = "Co-op Event Battles - single-player test\n\nThe native DLL was created and loaded correctly (version %s).\n\nOpen a mission battle while you have another army with a lord: you can connect it as reinforcements to test the mod.",
        sp_native_fail = "Co-op Event Battles - single-player check\n\nThe native DLL could not be loaded:\n[[col:yellow]]%s[[/col]]\n\nSee coop_event_battles_log.txt.",
        native_ok = "Co-op Event Battles\n\nThe native DLL was loaded correctly (version %s, build %s). Your ally can now bring a real army into mission battles.\n\nThis message is shown only once per campaign.",
        native_fail = "Co-op Event Battles\n\nThe native DLL could not be loaded:\n[[col:yellow]]%s[[/col]]\n\nArmies cannot join mission battles. See coop_event_battles_log.txt.",
        note_title = "Reinforcements on the way",
        note_line = "%s (%s) - %d units",
        note_footer = "They join during the battle.",
        sp_inspect_no_army = "Single-player test: you need another army with a lord, not already in this battle, to test joining it as reinforcements.",
        sp_joined = "Single-player test: the real army of [[col:yellow]]%s[[/col]] was connected to this mission battle.\n\nCheck the pre-battle screen: it should appear as reinforcements. Play the battle and check its casualties and experience afterwards. Test on a copy of your save.",
        sp_join_failed = "Single-player test: the army could not be connected.\n[[col:yellow]]%s[[/col]]\n\nNothing was changed. See coop_event_battles_log.txt.",
    },
    SP = {
        army_button = "%s - %d unidades", accept_tooltip = "Conectar este ejército real a la batalla de misión",
        decline_tooltip = "Rechazar apoyo", host_wait_tooltip = "Dejar de esperar",
        host_wait = "Batalla de misión: [[col:yellow]]%s[[/col]]\n\nEsperando a que tus aliados elijan sus ejércitos reales.\n\nPulsá X para dejar de esperar.",
        declined = "[[col:yellow]]%s[[/col]] rechazó el apoyo.",
        join_failed = "No se pudo conectar el ejército de [[col:yellow]]%s[[/col]]. Revisá coop_event_battles_log.txt. No se copiaron unidades.",
        joined = "El ejército real de [[col:yellow]]%s[[/col]] se agregó a los participantes de la misión. Comprobá la lista previa al combate antes de iniciarlo.",
        unknown_battle = "Batalla de misión",
        legacy = "Esta partida contiene tropas prestadas por una versión anterior del mod. El apoyo nativo queda desactivado para esta partida. Usá un guardado anterior al préstamo; esta versión no lo puede liquidar.",
        native_unavailable = "El apoyo nativo no está disponible. Todos los jugadores humanos necesitan el mismo complemento y una DLL compatible. Revisá coop_event_battles_log.txt.",
        reload_required = "La conexión nativa informó un error grave. Detené esta prueba y recargá el guardado anterior en todos los equipos. No guardes la campaña actual. Revisá coop_event_battles_log.txt.",
        sp_native_ok = "Co-op Event Battles - prueba en un jugador\n\nLa DLL nativa se creó y cargó correctamente (versión %s).\n\nAbrí una batalla de misión teniendo otro ejército con lord: vas a poder conectarlo como refuerzo para probar el mod.",
        sp_native_fail = "Co-op Event Battles - prueba en un jugador\n\nNo se pudo cargar la DLL nativa:\n[[col:yellow]]%s[[/col]]\n\nRevisá coop_event_battles_log.txt.",
        native_ok = "Co-op Event Battles\n\nLa DLL nativa se cargó correctamente (versión %s, build %s). Tu aliado ya puede llevar un ejército real a las batallas de misión.\n\nEste mensaje se muestra una sola vez por campaña.",
        native_fail = "Co-op Event Battles\n\nNo se pudo cargar la DLL nativa:\n[[col:yellow]]%s[[/col]]\n\nLos ejércitos no pueden unirse a batallas de misión. Revisá coop_event_battles_log.txt.",
        note_title = "Refuerzos en camino",
        note_line = "%s (%s) - %d unidades",
        note_footer = "Entran durante la batalla.",
        sp_inspect_no_army = "Prueba en un jugador: necesitás otro ejército con lord, que no esté ya en esta batalla, para probar unirlo como refuerzo.",
        sp_joined = "Prueba en un jugador: el ejército real de [[col:yellow]]%s[[/col]] se conectó a esta batalla de misión.\n\nMirá la pantalla previa: debería figurar como refuerzo. Jugá la batalla y revisá después sus bajas y su experiencia. Probalo en una copia de tu partida.",
        sp_join_failed = "Prueba en un jugador: no se pudo conectar el ejército.\n[[col:yellow]]%s[[/col]]\n\nNo se modificó nada. Revisá coop_event_battles_log.txt.",
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

function ceb:army_unit_count(mf)
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
	if not cm:is_multiplayer() or self.legacy_blocked then return end
	if not self:all_peers_ready() then self:log("Invitation blocked: missing or incompatible native readiness"); return end
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

-- The DLL travels inside the .pack as escaped Lua strings (coop_event_battles_native_blob.lua,
-- generated by build_pack.cjs). On each campaign load it is written next to Warhammer3.exe
-- (the working directory, same place as the logs) only if missing or different.
ceb.native_dll_name = "ceb_native_bridge.dll"

function ceb:extract_native_dll()
    -- Campaign mod files run inside the script environment (setfenv to core:get_env()), not in
    -- _G, so the blob global lives there. Look it up as a plain global first, then in _G.
    local blob = ceb_native_dll_blob
    if blob == nil and type(_G) == "table" then blob = _G.ceb_native_dll_blob end
    ceb_native_dll_blob = nil
    if type(_G) == "table" then _G.ceb_native_dll_blob = nil end
    if type(blob) ~= "table" or type(blob.chunks) ~= "table" then return false, "no embedded DLL in the pack" end
    self.build = type(blob.build) == "string" and blob.build or "?"
    if blob.version ~= self.version then return false, "embedded DLL version " .. tostring(blob.version) .. " differs from script " .. self.version end
    local data = table.concat(blob.chunks)
    if #data ~= blob.size then return false, "embedded DLL is truncated (" .. #data .. "/" .. tostring(blob.size) .. " bytes)" end
    local existing_file = io.open(self.native_dll_name, "rb")
    if existing_file then
        local existing = existing_file:read("*a")
        existing_file:close()
        if existing == data then return true, "DLL already up to date" end
    end
    local out_file, err = io.open(self.native_dll_name, "wb")
    if not out_file then return false, "cannot write " .. self.native_dll_name .. ": " .. tostring(err) end
    out_file:write(data)
    out_file:close()
    local check_file = io.open(self.native_dll_name, "rb")
    local written = check_file and check_file:read("*a")
    if check_file then check_file:close() end
    if written ~= data then return false, "written DLL differs (file in use or blocked by antivirus?)" end
    return true, "DLL extracted (" .. #data .. " bytes)"
end

function ceb:load_native()
    -- The DLL appends to coop_event_battles_native_log.txt; keep that file small as well.
    pcall(ceb.trim_log, "coop_event_battles_native_log.txt", 256 * 1024, 64 * 1024)
    local pcall_ok, extracted, detail = pcall(function() return self:extract_native_dll() end)
    if pcall_ok then
        self:log("Native DLL extraction ok=" .. tostring(extracted) .. " build=" .. tostring(self.build) .. " detail=" .. tostring(detail))
    else
        self:log("Native DLL extraction error: " .. tostring(extracted))
    end
    local ok, result = pcall(function()
        assert(package and type(package.loadlib) == "function", "Lua package.loadlib unavailable")
        local loader, err = package.loadlib("ceb_native_bridge.dll", "luaopen_ceb_native_bridge")
        assert(loader, err or "DLL loader unavailable")
        local module = loader()
        assert(type(module) == "table" and type(module.status) == "function", "Native module has no status API")
        assert(type(module.inspect) == "function" and type(module.join) == "function", "Native module has no army connection API")
        local status = module.status()
        assert(type(status) == "table", "Native status is not a table")
        self.native = module
        return status
    end)
    self.native_status = ok and result or {supported = false, version = self.version, reason = tostring(result)}
    self:log("Native status supported=" .. tostring(self.native_status.supported) .. " version=" .. tostring(self.native_status.version) .. " reason=" .. tostring(self.native_status.reason))
end

function ceb:announce_native()
    local status = self.native_status or {}
    local ready = status.supported == true and status.version == self.version and not self.legacy_blocked
    self:send("R|" .. self.protocol .. "|" .. self.version .. "|" .. (ready and "1" or "0"))
end

function ceb:all_peers_ready()
    if self.legacy_blocked or self.reload_required then return false end
    local humans = cm:get_human_factions()
    if #humans < 2 then return false end
    for _, key in ipairs(humans) do
        local peer = self.peers[key]
        if not peer or not peer.ready or peer.protocol ~= self.protocol or peer.version ~= self.version then return false end
    end
    return true
end

function ceb:on_ui_trigger(context)
    local trigger = context:trigger()
    local parts = split(string.sub(trigger, #self.trigger_prefix + 1), "|")
    local action, session_id = parts[1], parts[2]
    local sender = cm:model():faction_for_command_queue_index(context:faction_cqi())
    if not is_valid(sender) or not sender:is_human() then return end
    local faction_key = sender:name()
    if not self:list_contains(cm:get_human_factions(), faction_key) then return end
    self:log("Received " .. trigger .. " from " .. faction_key)
    if action == "Q" and #parts == 1 then
        -- Q only elicits R, never another Q. A late listener can recover the first readiness broadcast.
        self:announce_native()
        return
    elseif action == "R" and #parts == 4 then
        self.peers[faction_key] = {protocol = parts[2], version = parts[3], ready = parts[4] == "1"}
        if not self:all_peers_ready() then
            if self.session then self:end_session() end
            return
        end
        -- Every peer handles the same synchronized readiness event before creating a session.
        local pb = cm:model():pending_battle()
        if self:is_relevant_battle(pb) then self:on_pending_battle(pb) end
        return
    end
    local s = self.session
    if action == "F" and #parts == 4 then
        if s and s.id == session_id and s.commit_ids and s.commit_ids[parts[3]] then
            self:latch_native_failure("commit failed on " .. faction_key .. ": " .. parts[4])
            s.proposal = nil
            s.pending_join_queue = {}
            s.closed = true
            self:check_session_complete()
        end
        return
    end
    if not s or s.closed or s.id ~= session_id then
        self:log("Ignoring stale or closed session action")
        return
    end
    if action == "V" and #parts == 9 then
        self:handle_inspect_ack(faction_key, parts)
    elseif action == "J" and #parts == 3 then
        local cqi = tonumber(parts[3])
        if cqi and cqi > 0 and cqi == math.floor(cqi) then self:handle_join(faction_key, cqi) end
    elseif action == "D" and #parts == 2 then
        self:handle_decline(faction_key)
    elseif action == "C" and #parts == 2 and faction_key == s.host_faction then
        s.proposal = nil
        s.pending_join_queue = {}
        for _, key in ipairs(s.invited) do
            if not self:list_contains(s.responded, key) then table.insert(s.responded, key) end
        end
        s.closed = true
        self:check_session_complete()
    end
end

function ceb:handle_decline(faction_key)
	local s = self.session
	if not s or s.closed or not faction_key or not self:list_contains(s.invited, faction_key) or self:list_contains(s.responded, faction_key) then return end
	table.insert(s.responded, faction_key)
	self:ui_notify_participants(string.format(self:txt("declined"), self:faction_display_name(faction_key)), faction_key)
	self:check_session_complete()
end

-- Before connecting, the ally's army is teleported beside the host army, like the game's own quest
-- teleport. The engine decides per participant whether it deploys with the main army or arrives as a
-- reinforcement from the map edge (cohort initializer 0x14269af00 -> 0x1426b70ac), and a far-away army
-- became an off-map reinforcement that this mission map cannot place (the battle stopped in its
-- Startup phase). Next to the host it deploys at the start, as in a normal battle. After the battle
-- the army goes back to where it was. Runs on every client inside the same synchronized event.
ceb.teleport_distances = {2, 4, 7}

function ceb:teleport_beside_host(host, ally)
    local ally_cqi = ally:command_queue_index()
    local ox, oy = ally:logical_position_x(), ally:logical_position_y()
    local hx, hy = host:logical_position_x(), host:logical_position_y()
    if (ox - hx) * (ox - hx) + (oy - hy) * (oy - hy) <= 9 then
        self:log("Teleport skipped: army " .. ally_cqi .. " is already beside the host")
        return true
    end
    local x, y = -1, -1
    for _, distance in ipairs(self.teleport_distances) do
        x, y = cm:find_valid_spawn_location_for_character_from_character(ally:faction():name(),
            cm:char_lookup_str(host:command_queue_index()), true, distance)
        if type(x) == "number" and x > 0 then break end
    end
    if type(x) ~= "number" or x <= 0 then
        self:log("Teleport failed: no free position beside the host for army " .. ally_cqi)
        return false
    end
    cm:teleport_to(cm:char_lookup_str(ally_cqi), x, y)
    self.teleports = self.teleports or {}
    table.insert(self.teleports, {cqi = ally_cqi, x = ox, y = oy})
    self:log(string.format("Teleported army %d from [%d, %d] to [%d, %d] beside host %d", ally_cqi, ox, oy, x, y, host:command_queue_index()))
    return true
end

function ceb:return_teleported_armies()
    local list = self.teleports or {}
    self.teleports = {}
    for _, t in ipairs(list) do
        local character = self:get_char(t.cqi)
        if character and character:has_military_force() then
            cm:teleport_to(cm:char_lookup_str(t.cqi), t.x, t.y)
            self:log(string.format("Returned army %d to [%d, %d]", t.cqi, t.x, t.y))
        else
            self:log("Army " .. tostring(t.cqi) .. " did not survive the battle; nothing to return")
        end
    end
end

-- Reinforcement note: the pre-battle panel draws its army lists once when it opens (no context
-- bindings in pre_battle_post_battle.twui.xml), so a connected army is not listed there. Shown
-- only to the host: a passive note at the top of the screen with every connected army and its
-- unit count. Closed with the pre-battle panel or when the battle sequence ends.
ceb.note_name = "ceb_reinforcement_note"

function ceb:ui_add_reinforcement_note(host_faction_key, char_cqi)
    if self:local_faction_key() ~= host_faction_key then return end
    local character = self:get_char(char_cqi)
    if not character or not character:has_military_force() then return end
    self.reinforcement_notes = self.reinforcement_notes or {}
    for _, entry in ipairs(self.reinforcement_notes) do if entry.cqi == char_cqi then return end end
    table.insert(self.reinforcement_notes, {
        cqi = char_cqi, name = self:char_display_name(character),
        faction = self:faction_display_name(character:faction():name()),
        units = self:army_unit_count(character:military_force()),
    })
    self:ui_build_reinforcement_note()
end

function ceb:ui_close_reinforcement_note()
    self.reinforcement_notes = {}
    pcall(function()
        local note = find_uicomponent(core:get_ui_root(), self.note_name)
        if note then pcall(function() note:RemoveTopMost() end); note:Destroy() end
    end)
end

function ceb:ui_build_reinforcement_note()
    local ok, err = pcall(function()
        local notes = self.reinforcement_notes or {}
        if #notes == 0 then return end
        local root = core:get_ui_root()
        local old = find_uicomponent(root, self.note_name)
        if old then pcall(function() old:RemoveTopMost() end); old:Destroy() end
        local lines = {}
        for _, n in ipairs(notes) do
            table.insert(lines, string.format(self:txt("note_line"), n.name, n.faction, n.units))
        end
        local note = UIComponent(root:CreateComponent(self.note_name, "UI/Common UI/ceb_army_picker"))
        local panel = find_uicomponent(note, "ceb_picker") or note
        for _, id in ipairs({"ceb_row_template", "ceb_army_prev", "ceb_army_more", "ceb_page", "button_cancel"}) do
            local c = find_uicomponent(panel, id)
            if c then c:SetVisible(false) end
        end
        -- Above the pre-battle panel, but never takes clicks or locks priority.
        pcall(function() note:PropagatePriority(self.dialog_priority) end)
        pcall(function() note:RegisterTopMost() end)
        pcall(function() note:SetInteractive(false) end)
        pcall(function() panel:SetInteractive(false) end)
        local sw = core:get_screen_resolution()
        local width, margin, title_h, line_h = 460, 20, 26, 22
        local text_h = (#lines + 1) * line_h
        local height = margin * 2 + title_h + 6 + text_h
        panel:SetDockingPoint(0)
        panel:SetCanResizeWidth(true)
        panel:SetCanResizeHeight(true)
        panel:Resize(width, height)
        panel:MoveTo(math.floor((sw - width) / 2), 70)
        local px, py = panel:Position()
        local title = find_uicomponent(panel, "ceb_title")
        if title then
            title:SetStateText(self:txt("note_title"), "")
            title:SetDockingPoint(0); title:Resize(width - 2 * margin, title_h); title:MoveTo(px + margin, py + margin)
        end
        local text = find_uicomponent(panel, "DY_text")
        if text then
            text:SetStateText(table.concat(lines, "\n") .. "\n" .. self:txt("note_footer"), "")
            text:SetDockingPoint(0); text:Resize(width - 2 * margin, text_h); text:MoveTo(px + margin, py + margin + title_h + 6)
        end
        self:log("Reinforcement note shown: " .. table.concat(lines, " | "))
    end)
    if not ok then self:log("UI error (reinforcement note): " .. tostring(err)) end
end

function ceb:add_note_listeners()
    core:add_listener("ceb_note_PanelClosed", "PanelClosedCampaign", function(context)
        return context.string == "popup_pre_battle"
    end, function() self:ui_close_reinforcement_note() end, true)
    core:add_listener("ceb_note_BattleCompleted", "ScriptEventBattleSequenceCompleted", true, function()
        self:ui_close_reinforcement_note()
    end, true)
end

function ceb:native_result(label, result)
    self:log(label .. " ok=" .. tostring(result.ok) .. " code=" .. tostring(result.code) .. " detail=" .. tostring(result.detail) ..
        " host_force=" .. tostring(result.host_force_cqi) .. " ally_force=" .. tostring(result.ally_force_cqi) ..
        " participants=" .. tostring(result.participants_before) .. "->" .. tostring(result.participants_after) ..
        " model_source=" .. tostring(result.model_source))
end

local function integer(value, minimum)
    return type(value) == "number" and value >= minimum and value == math.floor(value)
end

local function fatal_result(result)
    local code = string.lower(tostring(result.code or ""))
    return result.fatal == true or code == "native_exception" or code == "ownershipmismatch" or code == "ownership_mismatch"
end

function ceb:latch_native_failure(detail)
    self.reload_required = true
    self:log("RELOAD REQUIRED: " .. tostring(detail))
    self:ui_notify_participants(self:txt("reload_required"))
end

function ceb:validate_selection(faction_key, char_cqi)
    local s = self.session
    if not s or s.closed or self.reload_required or not faction_key or not self:list_contains(s.invited, faction_key) or self:list_contains(s.responded, faction_key) then return false end
    if not self:all_peers_ready() then self:log("Join blocked: missing or incompatible native readiness"); return false end
    local pb = cm:model():pending_battle()
    local host, ally = self:get_char(s.host_cqi), self:get_char(char_cqi)
    if not self:is_relevant_battle(pb) or not host or not host:has_military_force() then return false end
    if host:faction():name() ~= s.host_faction or pb:set_piece_battle_key() ~= s.battle_key then return false end
    local mission_key = ""
    pcall(function() mission_key = pb:quest_mission_key() or "" end)
    if mission_key ~= s.mission_key then return false end
    local pending_host = self:get_host_character(pb)
    if not pending_host or pending_host:command_queue_index() ~= s.host_cqi then return false end
    if not self:is_eligible_army_char(ally, faction_key) then self:log("Join rejected: invalid selected army ownership or eligibility"); return false end
    if ally:faction():at_war_with(host:faction()) then return false end

    return host, ally
end

function ceb:finish_proposal(success, detail)
    local s = self.session
    local p = s and s.proposal
    if not p then return end
    s.proposal = nil
    if not self:list_contains(s.responded, p.faction) then table.insert(s.responded, p.faction) end
    self:log("Proposal " .. p.id .. " completed success=" .. tostring(success) .. " detail=" .. tostring(detail))
    if not self.reload_required then
        self:ui_notify_participants(string.format(self:txt(success and "joined" or "join_failed"), self:faction_display_name(p.faction)))
    end
    self:check_session_complete()
    if not s.closed and not self.reload_required and s.pending_join_queue and #s.pending_join_queue > 0 then
        local next_join = table.remove(s.pending_join_queue, 1)
        self:handle_join(next_join.faction, next_join.char_cqi)
    end
end

function ceb:handle_join(faction_key, char_cqi)
    local host, ally = self:validate_selection(faction_key, char_cqi)
    if not host then return false end
    local s = self.session
    if s.proposal then
        if s.proposal.faction == faction_key then return false end
        s.pending_join_queue = s.pending_join_queue or {}
        for _, queued in ipairs(s.pending_join_queue) do if queued.faction == faction_key then return false end end
        table.insert(s.pending_join_queue, {faction = faction_key, char_cqi = char_cqi})
        self:log("Queued join for " .. faction_key .. "; another proposal is awaiting acknowledgements")
        return false
    end
    s.proposal_counter = (s.proposal_counter or 0) + 1
    local p = {
        id = s.id .. "_" .. tostring(s.proposal_counter) .. "_" .. tostring(char_cqi), faction = faction_key,
        char_cqi = char_cqi, host_force = host:military_force():command_queue_index(),
        ally_force = ally:military_force():command_queue_index(), acknowledgements = {},
    }
    s.proposal = p
    local ok, result = pcall(function()
        assert(self.native and type(self.native.inspect) == "function" and type(self.native.join) == "function", "Native bridge unavailable")
        return self.native.inspect(cm.game_interface, p.host_force, p.ally_force)
    end)
    if not ok or type(result) ~= "table" then result = {ok = false, fatal = true, code = "lua_native_error", detail = tostring(result)} end
    self:native_result("Native inspect proposal=" .. p.id, result)
    local valid = result.ok == true and integer(result.host_force_cqi, 1) and integer(result.ally_force_cqi, 1) and
        integer(result.participants_before, 0) and result.host_force_cqi == p.host_force and result.ally_force_cqi == p.ally_force
    local code = string.gsub(tostring(result.code or "unspecified"), "[^%w_-]", "_")
    if code == "" then code = "unspecified" end
    if #code > 80 then code = string.sub(code, 1, 80) end
    -- Inspect is read-only. Only synchronized V events decide whether any client may call join.
    self:send("V|" .. s.id .. "|" .. p.id .. "|" .. (valid and "1" or "0") .. "|" ..
        tostring(valid and result.host_force_cqi or 0) .. "|" .. tostring(valid and result.ally_force_cqi or 0) .. "|" ..
        tostring(valid and result.participants_before or 0) .. "|" .. (fatal_result(result) and "1" or "0") .. "|" .. code)
    return false
end

function ceb:handle_inspect_ack(faction_key, parts)
    local s = self.session
    local p = s and s.proposal
    if not p or s.closed or self.reload_required or parts[2] ~= s.id or parts[3] ~= p.id or not self:all_peers_ready() then return end
    if p.acknowledgements[faction_key] then return end
    local host_force, ally_force, count = tonumber(parts[5]), tonumber(parts[6]), tonumber(parts[7])
    if parts[4] ~= "1" or parts[8] == "1" then
        if parts[8] == "1" then self:latch_native_failure("preflight " .. faction_key .. ": " .. parts[9]) end
        self:finish_proposal(false, "preflight rejected by " .. faction_key .. ": " .. parts[9])
        return
    end
    if not integer(host_force, 1) or not integer(ally_force, 1) or not integer(count, 0) or host_force ~= p.host_force or ally_force ~= p.ally_force or
        (p.participants_before ~= nil and p.participants_before ~= count) or (p.inspect_code ~= nil and p.inspect_code ~= parts[9]) then
        self:finish_proposal(false, "preflight signature mismatch from " .. faction_key)
        return
    end
    p.participants_before = count
    p.inspect_code = parts[9]
    p.acknowledgements[faction_key] = true
    for _, key in ipairs(cm:get_human_factions()) do if not p.acknowledgements[key] then return end end
    local host, ally = self:validate_selection(p.faction, p.char_cqi)
    if not host or host:military_force():command_queue_index() ~= p.host_force or ally:military_force():command_queue_index() ~= p.ally_force then
        self:finish_proposal(false, "selection changed while awaiting acknowledgements")
        return
    end
    -- Reached by the same final synchronized V event on every client. No extra local inspection.
    self:teleport_beside_host(host, ally)
    p.committing = true
    s.commit_ids = s.commit_ids or {}
    s.commit_ids[p.id] = true
    local ok, result = pcall(function() return self.native.join(cm.game_interface, p.host_force, p.ally_force) end)
    if not ok or type(result) ~= "table" then result = {ok = false, fatal = true, code = "lua_native_error", detail = tostring(result)} end
    self:native_result("Native join proposal=" .. p.id, result)
    if result.ok ~= true or fatal_result(result) then
        -- Another client may already have committed. Never attempt a local rollback or fallback.
        self:latch_native_failure("commit " .. tostring(result.code) .. ": " .. tostring(result.detail))
        local code = string.gsub(tostring(result.code or "native_failure"), "[^%w_-]", "_")
        if code == "" then code = "native_failure" end
        self:send("F|" .. s.id .. "|" .. p.id .. "|" .. string.sub(code, 1, 80))
        self:finish_proposal(false, result.code)
        return
    end
    cm:update_pending_battle()
    self:ui_add_reinforcement_note(s.host_faction, p.char_cqi)
    self:finish_proposal(true, result.code)
end


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
	local label = string.format(self:txt("army_button"), self:char_display_name(character), self:army_unit_count(character:military_force()))
	if character:faction():name() ~= self:local_faction_key() then label = label .. " (" .. self:faction_display_name(character:faction():name()) .. ")" end
	return label
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
	row_h = 52,
	button_h = 40,
	footer_h = 34,
	footer_gap = 40,
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
		sp_title = "Single-player test",
		sp_invite = "%s - mission battle:\n[[col:yellow]]%s[[/col]]\nChoose an army to join as reinforcements.",
	},
	SP = {
		title = "Ayudá a tu aliado",
		invite = "%s solicita apoyo para:\n[[col:yellow]]%s[[/col]]\nElegí el ejército que querés enviar.",
		empty = "%s solicita apoyo para:\n[[col:yellow]]%s[[/col]]\nNo tenés ejércitos disponibles.",
		previous = "Anterior",
		next = "Siguiente",
		decline = "Rechazar",
		sp_title = "Prueba en un jugador",
		sp_invite = "%s - batalla de misión:\n[[col:yellow]]%s[[/col]]\nElegí un ejército para unirlo como refuerzo.",
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
		title:SetStateText((s.sp and T.sp_title or T.title) .. " - v" .. self.version, "")
		place(title, x, y, inner_w, L.title_h)
		y = y + L.title_h + 8
		local text = find_uicomponent(panel, "DY_text")
		assert(text, "army picker description missing")
		text:SetStateText(string.format(#candidates == 0 and T.empty or (s.sp and T.sp_invite or T.invite),
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
			row:SetDockingPoint(2)
			row:SetDockOffset(0, math.floor(y - dy))
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
		local function dock(uic, point, ox, oy) uic:SetDockingPoint(point); uic:SetDockOffset(math.floor(ox), math.floor(oy)) end
		dock(prev, 7, L.margin, -L.margin)
		dock(page, 7, L.margin + 108, -L.margin - 8)
		dock(next_button, 7, L.margin + 170, -L.margin)
		dock(cancel, 9, -L.margin, -L.margin)
		self:log(string.format("Invite picker: screen %dx%d, panel %dx%d, page %d/%d, %d rows",
			sw, sh, dw, dh, self.ui.page, pages, rows))
		self:log("Picker geometry: panel " .. geometry(panel) .. ", text " .. geometry(text) .. ", row1 " ..
			geometry(find_uicomponent(panel, "ceb_army_" .. first)) .. ", cancel " .. geometry(cancel) .. ", next " .. geometry(next_button))
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

cm:add_saving_game_callback(function(context)
    cm:save_named_value("ceb_session_counter", ceb.session_counter, context)
    cm:save_named_value("ceb_native_teleports", ceb.teleports or {}, context)
    cm:save_named_value("ceb_native_notice_shown", ceb.native_notice_shown == true, context)
    -- Retain legacy metadata so returning to the previous version does not lose its records.
    cm:save_named_value("ceb_loans", ceb.legacy_loans, context)
    cm:save_named_value("ceb_cap_overridden", ceb.legacy_cap, context)
end)

cm:add_loading_game_callback(function(context)
    ceb.legacy_loans = cm:load_named_value("ceb_loans", {}, context) or {}
    ceb.legacy_cap = cm:load_named_value("ceb_cap_overridden", false, context) or false
    ceb.session_counter = cm:load_named_value("ceb_session_counter", 0, context) or 0
    ceb.teleports = cm:load_named_value("ceb_native_teleports", {}, context) or {}
    ceb.native_notice_shown = cm:load_named_value("ceb_native_notice_shown", false, context) == true
    ceb.legacy_blocked = #ceb.legacy_loans > 0 or ceb.legacy_cap
    -- Native readiness is process-local capability evidence and is never restored from a save.
    ceb.peers = {}
    ceb.session = nil
end)

function ceb:add_listeners()
    core:add_listener("ceb_PendingBattle", "PendingBattle", true, function(context)
        local ok, err = pcall(function()
            self:on_pending_battle(context:pending_battle())
            if not self:all_peers_ready() and self:get_host_character(context:pending_battle()) and
                self:get_host_character(context:pending_battle()):faction():name() == self:local_faction_key() and
                self:is_relevant_battle(context:pending_battle()) then self:ui_show_info(self:txt("native_unavailable")) end
        end)
        if not ok then self:log("PendingBattle error: " .. tostring(err)) end
    end, true)
    core:add_listener("ceb_UITrigger", "UITrigger", function(context)
        local t = context:trigger()
        return type(t) == "string" and string.sub(t, 1, #self.trigger_prefix) == self.trigger_prefix
    end, function(context)
        local ok, err = pcall(function() self:on_ui_trigger(context) end)
        if not ok then self:log("UITrigger error: " .. tostring(err)) end
    end, true)
    core:add_listener("ceb_BattleSequenceCompleted", "ScriptEventBattleSequenceCompleted", true, function()
        self:end_session()
        local ok, err = pcall(function() self:return_teleported_armies() end)
        if not ok then self:log("Return error: " .. tostring(err)) end
        -- Campaign combat applies results to the original force. No manual casualties or XP.
    end, true)
    core:add_listener("ceb_ComponentLClickUp", "ComponentLClickUp", function(context)
        local id = context.string
        return id == "button_tick" or id == "button_cancel" or (type(id) == "string" and string.sub(id, 1, 9) == "ceb_army_")
    end, function(context)
        local ok, err = pcall(function() self:on_component_click(context) end)
        if not ok then self:log("Click handler error: " .. tostring(err)) end
    end, true)
end

-- Single player test mode. Extracts and loads the DLL and reports the result. On a mission battle
-- it offers the player's other armies; the chosen one is connected with the same native join used in
-- co-op, in same-faction mode (CEB_FLAG_SAME_FACTION = 1), then cm:update_pending_battle() refreshes
-- the pre-battle screen. Nothing is sent over the network and no co-op listener is added.
ceb.sp_join_flags = 3        -- CEB_FLAG_SAME_FACTION | CEB_FLAG_ATTACH: own army joins the host cohort
ceb.sp_other_join_flags = 4  -- CEB_FLAG_OTHER_FACTION_TEST: another faction's army in its own cohort, the co-op path
ceb.sp_other_faction_limit = 12

function ceb:singleplayer_diagnostics()
    self:load_native()
    local st = self.native_status or {}
    local ready = st.supported == true and self.native ~= nil
    -- Shown a few seconds after the first tick: a dialog created during the loading fade is lost.
    cm:real_callback(function()
        if ready then
            self:ui_show_info(string.format(self:txt("sp_native_ok"), tostring(st.version) .. ", build " .. tostring(self.build)), 20000)
        else
            self:ui_show_info(string.format(self:txt("sp_native_fail"), tostring(st.reason)), 30000)
        end
    end, 4000, "ceb_sp_status")
    if not ready then return end
    core:add_listener("ceb_sp_PendingBattle", "PendingBattle", true, function(context)
        local pb = context:pending_battle()
        cm:callback(function()
            local ok, err = pcall(function() self:sp_offer_armies(pb) end)
            if not ok then self:log("SP offer error: " .. tostring(err)) end
        end, 0.5)
    end, true)
    self:add_note_listeners()
    core:add_listener("ceb_sp_BattleSequenceCompleted", "ScriptEventBattleSequenceCompleted", true, function()
        self.session = nil
        self.sp_joined = nil
        local ok, err = pcall(function() self:return_teleported_armies() end)
        if not ok then self:log("Return error: " .. tostring(err)) end
    end, true)
    core:add_listener("ceb_sp_ComponentLClickUp", "ComponentLClickUp", function(context)
        local id = context.string
        return id == "button_tick" or id == "button_cancel" or (type(id) == "string" and string.sub(id, 1, 9) == "ceb_army_")
    end, function(context)
        local ok, err = pcall(function() self:sp_on_click(context) end)
        if not ok then self:log("SP click error: " .. tostring(err)) end
    end, true)
end

function ceb:sp_battle_signature(pb, host)
    local mission_key = ""
    pcall(function() mission_key = pb:quest_mission_key() or "" end)
    return tostring(host:command_queue_index()) .. "|" .. tostring(pb:set_piece_battle_key()) .. "|" .. mission_key
end

function ceb:sp_offer_armies(pb)
    if self.reload_required or not self:is_relevant_battle(pb) then return end
    local host = self:get_host_character(pb)
    if not host or host:faction():name() ~= self:local_faction_key() or not host:has_military_force() then return end
    local signature = self:sp_battle_signature(pb, host)
    -- update_pending_battle can raise PendingBattle again for the same battle after a join.
    if self.sp_joined == signature then return end
    if self.ui.open[self.invite_dialog_name] then return end
    local candidates = self:get_eligible_army_cqis(self:local_faction_key())
    local own = #candidates
    for _, cqi in ipairs(self:sp_other_faction_army_cqis(host)) do table.insert(candidates, cqi) end
    self:log("SP mission battle " .. signature .. ": " .. own .. " own armies, " .. (#candidates - own) .. " armies of other factions")
    if #candidates == 0 then
        self:ui_show_info(self:txt("sp_inspect_no_army"), 15000)
        return
    end
    self.session = {
        id = "sp", sp = true, signature = signature, host_cqi = host:command_queue_index(),
        host_faction = host:faction():name(), battle_key = pb:set_piece_battle_key(),
        invited = {}, responded = {},
    }
    self.ui.candidates = candidates
    self.ui.page = 1
    self:ui_build_invite_dialog()
end

-- Test helper: the nearest armies of other (non-human) factions, to simulate a co-op ally.
-- They join in their own cohort (flags 4), exactly the co-op path.
function ceb:sp_other_faction_army_cqis(host)
    local hx, hy = host:logical_position_x(), host:logical_position_y()
    local local_key = self:local_faction_key()
    local entries = {}
    local factions = cm:model():world():faction_list()
    for i = 0, factions:num_items() - 1 do
        local faction = factions:item_at(i)
        local key = faction:name()
        if key ~= local_key and key ~= "rebels" and not faction:is_dead() and not faction:is_human() then
            local forces = faction:military_force_list()
            for j = 0, forces:num_items() - 1 do
                local mf = forces:item_at(j)
                if mf:has_general() then
                    local general = mf:general_character()
                    if self:is_eligible_army_char(general, key) then
                        local dx, dy = general:logical_position_x() - hx, general:logical_position_y() - hy
                        local war = faction:at_war_with(host:faction()) and 1 or 0
                        table.insert(entries, {cqi = general:command_queue_index(), d = dx * dx + dy * dy, war = war})
                    end
                end
            end
        end
    end
    -- Factions at peace with the player first (closest to a real co-op ally), then the rest.
    table.sort(entries, function(a, b)
        if a.war ~= b.war then return a.war < b.war end
        if a.d ~= b.d then return a.d < b.d end
        return a.cqi < b.cqi
    end)
    local result = {}
    for i = 1, math.min(#entries, self.sp_other_faction_limit) do table.insert(result, entries[i].cqi) end
    return result
end

function ceb:sp_on_click(context)
    local uic = UIComponent(context.component)
    local id = context.string
    local s = self.session
    if not (s and s.sp) or not self:is_our_click(uic, self.invite_dialog_name) then
        -- Info dialog close buttons and anything else use the shared handler.
        if not self:is_our_click(uic, self.invite_dialog_name) then self:on_component_click(context) end
        return
    end
    self:log("SP click on " .. tostring(id))
    local army_index = string.match(id, "^ceb_army_(%d+)$")
    if army_index then
        local cqi = self.ui.candidates[tonumber(army_index)]
        self:ui_close_invite()
        if cqi then self:sp_join(cqi) end
    elseif id == "ceb_army_more" or id == "ceb_army_prev" then
        local per_page = self.ui.rows_per_page or self.ui_layout.rows_per_page
        local pages = math.max(1, math.ceil(#self.ui.candidates / per_page))
        local page = math.max(1, math.min(pages, self.ui.page + (id == "ceb_army_prev" and -1 or 1)))
        if page ~= self.ui.page then self.ui.page = page; self:ui_build_invite_dialog() end
    elseif id == "button_cancel" then
        self:ui_close_invite()
        self.session = nil
    end
end

function ceb:sp_join(char_cqi)
    local s = self.session
    if not (s and s.sp) then return false end
    local pb = cm:model():pending_battle()
    local host = self:get_host_character(pb)
    local ally = self:get_char(char_cqi)
    local function refuse(detail)
        self:log("SP join refused: " .. detail)
        self:ui_show_info(string.format(self:txt("sp_join_failed"), detail), 30000)
        self.session = nil
        return false
    end
    if not self:is_relevant_battle(pb) or not host or host:command_queue_index() ~= s.host_cqi or self:sp_battle_signature(pb, host) ~= s.signature then
        return refuse("the mission battle changed")
    end
    if not ally or not self:is_eligible_army_char(ally, ally:faction():name()) then return refuse("the selected army is no longer available") end
    local flags = ally:faction():name() == s.host_faction and self.sp_join_flags or self.sp_other_join_flags
    local host_force = host:military_force():command_queue_index()
    local ally_force = ally:military_force():command_queue_index()
    self:teleport_beside_host(host, ally)
    local ok, result = pcall(function() return self.native.inspect(cm.game_interface, host_force, ally_force, flags) end)
    if not ok or type(result) ~= "table" then result = {ok = false, code = "lua_native_error", detail = tostring(result)} end
    self:native_result("SP inspect", result)
    if result.ok ~= true or result.code ~= "ready" then
        return refuse(tostring(result.code) .. ": " .. tostring(result.detail))
    end
    ok, result = pcall(function() return self.native.join(cm.game_interface, host_force, ally_force, flags) end)
    if not ok or type(result) ~= "table" then result = {ok = false, fatal = true, code = "lua_native_error", detail = tostring(result)} end
    self:native_result("SP join", result)
    if result.ok ~= true or result.fatal == true then
        if result.fatal == true or result.changed == true then
            self.reload_required = true
            self:log("RELOAD REQUIRED: " .. tostring(result.code) .. ": " .. tostring(result.detail))
            self:ui_show_info(self:txt("reload_required"), 60000)
            self.session = nil
            return false
        end
        return refuse(tostring(result.code) .. ": " .. tostring(result.detail))
    end
    self.sp_joined = s.signature
    cm:update_pending_battle()
    local included = self:char_in_pending_battle(cm:model():pending_battle(), char_cqi)
    self:log("SP join done: " .. tostring(result.code) .. "; script reports army in pending battle: " .. tostring(included))
    self:ui_add_reinforcement_note(s.host_faction, char_cqi)
    self:ui_show_info(string.format(self:txt("sp_joined"), self:char_display_name(ally)), 30000)
    self.session = nil
    return true
end

-- The "DLL loaded" confirmation is shown once per campaign: the flag is set on every client on the
-- first load (identical model state on all clients) and saved, so returning from a battle or
-- loading later never shows it again. A failure is reported on every load.
function ceb:show_native_status_once()
    local st = self.native_status or {}
    local ready = st.supported == true and self.native ~= nil
    local first = not self.native_notice_shown
    self.native_notice_shown = true
    if ready and not first then return end
    cm:real_callback(function()
        if ready then
            self:ui_show_info(string.format(self:txt("native_ok"), tostring(st.version), tostring(self.build)), 20000)
        else
            self:ui_show_info(string.format(self:txt("native_fail"), tostring(st.reason)), 30000)
        end
    end, 4000, "ceb_native_status")
end

-- Single-player test mode (own or AI armies into mission battles). Disabled for release; set to
-- true only for local testing.
ceb.singleplayer_test = false

cm:add_first_tick_callback(function()
    ceb:log("v" .. ceb.version .. " native companion loaded; multiplayer=" .. tostring(cm:is_multiplayer()))
    if not cm:is_multiplayer() then
        if not ceb.singleplayer_test then return end
        pcall(function() common.set_context_value("ceb_ui_open", 0) end)
        local ok, err = pcall(function() ceb:singleplayer_diagnostics() end)
        if not ok then ceb:log("SP diagnostics error: " .. tostring(err)) end
        return
    end
    pcall(function() common.set_context_value("ceb_ui_open", 0) end)
    ceb:load_native()
    ceb:show_native_status_once()
    ceb:add_listeners()
    ceb:add_note_listeners()
    if ceb.legacy_blocked then ceb:log("Legacy loan save blocked; no settlement performed"); ceb:ui_show_info(ceb:txt("legacy"), 20000) end
    ceb:send("Q")
    ceb:announce_native()
end)

_G.coop_event_battles = ceb
