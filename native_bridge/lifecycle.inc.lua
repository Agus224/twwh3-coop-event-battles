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
