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

