cm:add_saving_game_callback(function(context)
    cm:save_named_value("ceb_session_counter", ceb.session_counter, context)
    cm:save_named_value("ceb_native_teleports", ceb.teleports or {}, context)
    cm:save_named_value("ceb_native_notice_shown", ceb.native_notice_shown == true, context)
    cm:save_named_value("ceb_settings", ceb.settings or {}, context)
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
    ceb.settings = cm:load_named_value("ceb_settings", {}, context) or {}
    ceb.legacy_blocked = #ceb.legacy_loans > 0 or ceb.legacy_cap
    -- Native readiness is process-local capability evidence and is never restored from a save.
    ceb.peers = {}
    ceb.session = nil
end)

-- Battle sequence trace (1.1.4). Report 13-nov-2026: the host autoresolved a mission battle with the
-- ally's army joined and the ally's client never showed a result, waiting forever. Every client logs,
-- from a mission battle's PendingBattle until ScriptEventBattleSequenceCompleted: the battle events,
-- the panels opened/closed, the buttons clicked and, every 10 s once the battle is resolved (5 min at
-- most), the visible top-level UI. Only writes to the log.
ceb.trace_panel_limit = 30
ceb.trace_watch_seconds = 300

function ceb:trace_pending_state()
    local out = ""
    pcall(function()
        local pb = cm:model():pending_battle()
        out = " pb[active=" .. tostring(pb:is_active()) .. " autoresolved=" .. tostring(pb:is_auto_resolved()) ..
            " fought=" .. tostring(pb:has_been_fought()) .. " set_piece=" .. tostring(pb:set_piece_battle_key()) .. "]"
    end)
    return out
end

function ceb:trace_visible_ui()
    local ids = {}
    pcall(function()
        local root = core:get_ui_root()
        for i = 0, root:ChildCount() - 1 do
            local c = UIComponent(root:Find(i))
            if c:Visible() then ids[#ids + 1] = c:Id() end
            if #ids >= self.trace_panel_limit then break end
        end
    end)
    return table.concat(ids, ",")
end

function ceb:trace(msg)
    if self.battle_trace then self:log("TRACE " .. msg .. self:trace_pending_state()) end
end

function ceb:start_trace_watch()
    if self.trace_watching then return end
    self.trace_watching = true
    local ticks = 0
    cm:repeat_real_callback(function()
        ticks = ticks + 1
        if not self.battle_trace or ticks * 10 > self.trace_watch_seconds then
            cm:remove_real_callback("ceb_trace_watch")
            self.trace_watching = false
            return
        end
        self:trace("watch +" .. (ticks * 10) .. "s visible=[" .. self:trace_visible_ui() .. "]")
    end, 10000, "ceb_trace_watch")
end

function ceb:add_battle_trace()
    core:add_listener("ceb_trace_PendingBattle", "PendingBattle", true, function(context)
        local ok, relevant = pcall(function() return self:is_relevant_battle(context:pending_battle()) end)
        if ok and relevant then
            self.battle_trace = true
            self:trace("PendingBattle local=" .. tostring(self:local_faction_key()))
        end
    end, true)
    for _, ev in ipairs({"BattleBeingFought", "BattleConflictFinished", "BattleCompleted", "CharacterCompletedBattle",
        "MissionSucceeded", "MissionFailed", "PanelOpenedCampaign", "PanelClosedCampaign"}) do
        core:add_listener("ceb_trace_" .. ev, ev, function() return self.battle_trace == true end, function(context)
            local extra = ""
            pcall(function() if type(context.string) == "string" then extra = " [" .. context.string .. "]" end end)
            pcall(function()
                local c = context:character()
                extra = extra .. " char=" .. tostring(c:command_queue_index()) .. " faction=" .. tostring(c:faction():name())
            end)
            pcall(function() extra = extra .. " mission=" .. tostring(context:mission():mission_record_key()) end)
            self:trace(ev .. extra)
            if ev == "BattleConflictFinished" or ev == "BattleCompleted" then self:start_trace_watch() end
        end, true)
    end
    core:add_listener("ceb_trace_click", "ComponentLClickUp", function() return self.battle_trace == true end, function(context)
        self:trace("click [" .. tostring(context.string) .. "]")
    end, true)
    core:add_listener("ceb_trace_BattleSequenceCompleted", "ScriptEventBattleSequenceCompleted", true, function()
        if self.battle_trace then self:trace("ScriptEventBattleSequenceCompleted") end
        self.battle_trace = false
    end, true)
end

-- 1.1.6. After an autoresolve the host's client opens popup_battle_results, but the client of an
-- ally whose army joined through the bridge never does: its UI missed the pre-battle flow, and the
-- host then waits forever for that ally's choice. The ally's client checks a moment after
-- BattleConflictFinished and, if the panel is missing, asks the bridge to open it through the
-- game's own function, which applies the same conditions as the game (results ready, local faction
-- among the players who must choose, UI not loading). After a fought battle the panel is already
-- there, so nothing is done.
ceb.results_check_delay = 2000
ceb.results_check_attempts = 6

function ceb:battle_results_visible()
    local c = find_uicomponent(core:get_ui_root(), "popup_battle_results")
    return c ~= nil and c ~= false and c:Visible()
end

function ceb:check_ally_battle_results(attempt)
    if not self.results_watch then return end
    local ok, visible = pcall(function() return self:battle_results_visible() end)
    if ok and visible then
        self:log("Ally results: popup_battle_results visible (attempt " .. attempt .. ")")
        self.results_watch = nil
        return
    end
    if not self.native or type(self.native.results) ~= "function" then
        self:log("Ally results: native bridge unavailable, cannot open the results")
        self.results_watch = nil
        return
    end
    -- Mode 2 (1.1.7): if the local army is in the battle but the game left this client out of the list
    -- of players who choose the results, the bridge rebuilds that list with the game's own function.
    local call_ok, r = pcall(function() return self.native.results(2) end)
    if not call_ok or type(r) ~= "table" then r = {code = "lua_error", detail = tostring(r)} end
    self:log("Ally results attempt " .. attempt .. ": " .. tostring(r.code) .. " " .. tostring(r.detail))
    if r.opened == true or attempt >= self.results_check_attempts or r.code == "native_exception" or
        r.code == "unsupported_host" or r.code == "unexpected_campaign_ui" then
        self.results_watch = nil
        return
    end
    cm:real_callback(function() self:check_ally_battle_results(attempt + 1) end, self.results_check_delay, "ceb_ally_results")
end

-- 1.1.8. The ally's client never shows popup_pre_battle either: its army joins after PendingBattle,
-- when the game had already decided who sees that screen. Right after its own successful join the
-- ally's client asks the bridge to open it (mode 2: rebuild the chooser list when the local army is
-- in the battle but missing from it, then the game's own opener, which applies the game's
-- conditions). The host keeps deciding; the results check above stays as the fallback.
ceb.pre_battle_check_delay = 1000
ceb.pre_battle_check_attempts = 3

function ceb:pre_battle_visible()
    local c = find_uicomponent(core:get_ui_root(), "popup_pre_battle")
    return c ~= nil and c ~= false and c:Visible()
end

function ceb:start_ally_pre_battle_check()
    self.pre_battle_watch = true
    cm:remove_real_callback("ceb_ally_pre_battle")
    cm:real_callback(function() self:check_ally_pre_battle(1) end, self.pre_battle_check_delay, "ceb_ally_pre_battle")
end

function ceb:check_ally_pre_battle(attempt)
    if not self.pre_battle_watch then return end
    local ok, visible = pcall(function() return self:pre_battle_visible() end)
    if ok and visible then
        self:log("Ally pre-battle: popup_pre_battle visible (attempt " .. attempt .. ")")
        self.pre_battle_watch = nil
        return
    end
    if not self.native or type(self.native.prebattle) ~= "function" then
        self:log("Ally pre-battle: native bridge unavailable")
        self.pre_battle_watch = nil
        return
    end
    local call_ok, r = pcall(function() return self.native.prebattle(2) end)
    if not call_ok or type(r) ~= "table" then r = {code = "lua_error", detail = tostring(r)} end
    self:log("Ally pre-battle attempt " .. attempt .. ": " .. tostring(r.code) .. " " .. tostring(r.detail))
    if r.opened == true then self:focus_camera_on_host() end
    if r.opened == true or attempt >= self.pre_battle_check_attempts or r.code == "not_pre_battle" or
        r.code == "native_exception" or r.code == "unsupported_host" or r.code == "unexpected_campaign_ui" or
        r.code == "local_not_in_battle" then
        self.pre_battle_watch = nil
        return
    end
    cm:real_callback(function() self:check_ally_pre_battle(attempt + 1) end, self.pre_battle_check_delay, "ceb_ally_pre_battle")
end

-- 1.1.9. The game opens popup_pre_battle with the camera on the battle; on the ally's client the
-- bridge opens it later, so the camera stays where it was. Same scroll CA's
-- scroll_camera_to_character uses, keeping zoom and angle.
function ceb:focus_camera_on_host()
    local ok, err = pcall(function()
        local s = self.session
        local host = s and self:get_char(s.host_cqi)
        if not host then return end
        local x, y, d, b, h = cm:get_camera_position()
        cm:scroll_camera_from_current(false, 1, {host:display_position_x(), host:display_position_y(), d, b, h})
        self:log("Ally pre-battle: camera moved to the host")
    end)
    if not ok then self:log("Camera focus error: " .. tostring(err)) end
end

-- 1.1.9. The host's popup_pre_battle was built before the ally's army joined and does not list it
-- until the battle is resolved. After the join the host's client closes it and reopens it with the
-- game's own opener, which builds it again from the updated pending battle. If the reopen fails the
-- check below retries; the opener only acts while the battle is still pending.
ceb.pre_battle_refresh_delay = 500
ceb.pre_battle_refresh_attempts = 4

function ceb:start_host_pre_battle_refresh()
    if not self.native or type(self.native.prebattle) ~= "function" then return end
    cm:remove_real_callback("ceb_host_pre_battle")
    cm:real_callback(function()
        -- 1.1.10: the ally's client rebuilds the chooser list when it opens its panel; the host must
        -- end with the same list or a manual battle desyncs at launch.
        local sync_ok, sr = pcall(function() return self.native.prebattle(3) end)
        if not sync_ok or type(sr) ~= "table" then sr = {code = "lua_error", detail = tostring(sr)} end
        self:log("Host chooser sync: " .. tostring(sr.code) .. " " .. tostring(sr.detail))
        local ok, visible = pcall(function() return self:pre_battle_visible() end)
        if not ok or not visible then
            self:log("Host pre-battle refresh: panel not open, nothing to refresh")
            return
        end
        self.pre_battle_refreshing = true
        local closed, err = pcall(function() CampaignUI.ClosePanel("popup_pre_battle") end)
        self:log("Host pre-battle refresh: closing the panel ok=" .. tostring(closed) .. (closed and "" or " " .. tostring(err)))
        cm:real_callback(function() self:reopen_host_pre_battle(1) end, self.pre_battle_refresh_delay, "ceb_host_pre_battle")
    end, self.pre_battle_refresh_delay, "ceb_host_pre_battle")
end

function ceb:reopen_host_pre_battle(attempt)
    local ok, visible = pcall(function() return self:pre_battle_visible() end)
    local r = {code = "already_visible", detail = ""}
    if not (ok and visible) then
        local call_ok, res = pcall(function() return self.native.prebattle(2) end)
        r = (call_ok and type(res) == "table") and res or {code = "lua_error", detail = tostring(res)}
    end
    self:log("Host pre-battle reopen attempt " .. attempt .. ": " .. tostring(r.code) .. " " .. tostring(r.detail))
    if r.opened == true or r.code == "already_visible" or r.code == "not_pre_battle" or attempt >= self.pre_battle_refresh_attempts then
        self.pre_battle_refreshing = nil
        if r.opened == true or r.code == "already_visible" then self:ui_build_reinforcement_note() end
        return
    end
    cm:real_callback(function() self:reopen_host_pre_battle(attempt + 1) end, self.pre_battle_refresh_delay, "ceb_host_pre_battle")
end

function ceb:add_ally_results_listeners()
    core:add_listener("ceb_ally_results_BattleConflictFinished", "BattleConflictFinished", function()
        local key = self:local_faction_key()
        return self.joined_allies ~= nil and key ~= nil and self.joined_allies[key] == true
    end, function()
        self.pre_battle_watch = nil
        cm:remove_real_callback("ceb_ally_pre_battle")
        self.pre_battle_refreshing = nil
        cm:remove_real_callback("ceb_host_pre_battle")
        self:log("Ally results: battle finished, checking the results panel")
        self.results_watch = true
        cm:remove_real_callback("ceb_ally_results")
        cm:real_callback(function() self:check_ally_battle_results(1) end, self.results_check_delay, "ceb_ally_results")
    end, true)
    -- Diagnosis only (1.1.7): the host's client logs the same lists, read-only, to compare both PCs.
    core:add_listener("ceb_host_results_BattleConflictFinished", "BattleConflictFinished", function()
        local s = self.session
        return self.joined_allies ~= nil and s ~= nil and s.host_faction == self:local_faction_key()
    end, function()
        cm:real_callback(function()
            if not self.native or type(self.native.results) ~= "function" then return end
            local ok, r = pcall(function() return self.native.results(0) end)
            if ok and type(r) == "table" then self:log("Host results state: " .. tostring(r.code) .. " " .. tostring(r.detail)) end
        end, self.results_check_delay, "ceb_host_results")
    end, true)
    core:add_listener("ceb_ally_results_BattleSequenceCompleted", "ScriptEventBattleSequenceCompleted", true, function()
        self.joined_allies = nil
        self.results_watch = nil
        self.pre_battle_watch = nil
        cm:remove_real_callback("ceb_ally_pre_battle")
        self.pre_battle_refreshing = nil
        cm:remove_real_callback("ceb_host_pre_battle")
        cm:remove_real_callback("ceb_ally_results")
    end, true)
end

function ceb:add_listeners()
    self:add_ally_results_listeners()
    self:add_battle_trace()
    -- Remembers a click while the host's wait dialog is open; the dialog watchdog reads it (1.1.4).
    core:add_listener("ceb_host_dialog_click", "ComponentLClickUp", function()
        return self.ui.open[self.host_dialog_name] == true
    end, function(context)
        self.ui.host_dialog_clicked = tostring(context.string)
    end, true)
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
    -- Decide inside the event and re-read the model's pending battle later: a kept pending_battle of
    -- an AI battle resolved in the meantime crashed the game (23-nov-2026).
    core:add_listener("ceb_sp_PendingBattle", "PendingBattle", true, function(context)
        local mine = false
        pcall(function()
            local host = self:get_host_character(context:pending_battle())
            mine = host and host:faction():name() == self:local_faction_key() or false
        end)
        if not mine then return end
        cm:callback(function()
            local ok, err = pcall(function()
                local pb = cm:model():pending_battle()
                if pb:is_active() and not pb:has_been_fought() then self:sp_offer_armies(pb) end
            end)
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
    local enemy = ""
    pcall(function() local e = self:enemy_of_host(pb, host); enemy = e and tostring(e:command_queue_index()) or "" end)
    return tostring(host:command_queue_index()) .. "|" .. tostring(pb:set_piece_battle_key()) .. "|" .. mission_key ..
        "|t" .. tostring(cm:model():turn_number()) .. "|e" .. enemy
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
    -- The pre-battle screen was built before the join: refresh it as the co-op host does.
    pcall(function() self:start_host_pre_battle_refresh() end)
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
    local settings_ok, settings_err = pcall(function() ceb:settings_start() end)
    if not settings_ok then ceb:log("Settings button error: " .. tostring(settings_err)) end
    if ceb.legacy_blocked then ceb:log("Legacy loan save blocked; no settlement performed"); ceb:ui_show_info(ceb:txt("legacy"), 20000) end
    ceb:send("Q")
    ceb:announce_native()
end)

_G.coop_event_battles = ceb
