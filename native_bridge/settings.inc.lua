-----------------------------------------------------------------------------------
-- 1.2.0: REINFORCEMENTS IN NORMAL BATTLES, PER-PLAYER SETTINGS, TELEPORT COST, SETTINGS BUTTON
-----------------------------------------------------------------------------------
-- Every player decides for themselves (design: docs/DISENO_ceb_batallas_normales.md):
--   normal     also invite me to my allies' normal battles (mission battles always invite)
--   attacks    ... when my ally attacks (an army or a settlement)
--   defenses   ... when my ally is attacked
--   size_on    only when the whole enemy side has at least min_units units
--   cost       what my teleport costs in normal battles: free / low / normal / high
-- A player's choice travels as a UITrigger ("S|...") and every client stores it for every faction,
-- so the invitation list, the gold check and the gold payment are identical on every PC. The table
-- is saved in the campaign. Mission battles keep working as before and are always free.
ceb.default_settings = {normal = false, attacks = true, defenses = true, size_on = false, min_units = 20, cost = "normal"}
ceb.min_units_options = {5, 10, 15, 20}
ceb.cost_levels = {"free", "low", "normal", "high"}
ceb.cost_multiplier = {free = 0, low = 0.5, normal = 1, high = 2}
-- Gold = 250 + 2 per logical map unit between the ally and the host, capped at 4000, times the
-- level, rounded to 50. Immortal Empires: neighbour ~100 -> 450, far side of the map -> 4000.
ceb.cost_base, ceb.cost_per_unit, ceb.cost_cap = 250, 2, 4000
ceb.settings = ceb.settings or {}

function ceb:get_settings(faction_key)
    local stored = self.settings[faction_key] or {}
    local out = {}
    for k, v in pairs(self.default_settings) do
        if stored[k] ~= nil then out[k] = stored[k] else out[k] = v end
    end
    return out
end

function ceb:encode_settings(st)
    local function b(v) return v and "1" or "0" end
    return "S|" .. b(st.normal) .. "|" .. b(st.attacks) .. "|" .. b(st.defenses) .. "|" .. b(st.size_on) .. "|" ..
        tostring(st.min_units) .. "|" .. st.cost
end

-- parts = {"S", normal, attacks, defenses, size_on, min_units, cost}; anything malformed is ignored.
function ceb:apply_settings_message(faction_key, parts)
    local function flag(v) if v == "1" then return true elseif v == "0" then return false end end
    local st = {normal = flag(parts[2]), attacks = flag(parts[3]), defenses = flag(parts[4]), size_on = flag(parts[5]),
        min_units = tonumber(parts[6]), cost = parts[7]}
    if st.normal == nil or st.attacks == nil or st.defenses == nil or st.size_on == nil then return false end
    if not self:list_contains(self.min_units_options, st.min_units) or self.cost_multiplier[st.cost] == nil then return false end
    self.settings[faction_key] = st
    self:log("Settings of " .. faction_key .. ": normal=" .. tostring(st.normal) .. " attacks=" .. tostring(st.attacks) ..
        " defenses=" .. tostring(st.defenses) .. " size=" .. (st.size_on and tostring(st.min_units) or "off") .. " cost=" .. st.cost)
    if faction_key == self:local_faction_key() and self.settings_ui then
        self.settings_ui.preview = nil
        if self.settings_ui.open then self:settings_request_refresh() end
    end
    return true
end

function ceb:send_local_settings(st)
    self:send(self:encode_settings(st))
end

function ceb:any_normal_battles_enabled()
    for _, key in ipairs(cm:get_human_factions()) do
        if self:get_settings(key).normal then return true end
    end
    return false
end

-- Units of the whole enemy side: primary, secondary armies and, when the host attacks a settlement,
-- its garrison. Each military force is counted once.
function ceb:enemy_side_units(pb, host)
    local seen, total = {}, 0
    local function add(mf)
        if not is_valid(mf) then return end
        local id = mf:command_queue_index()
        if seen[id] then return end
        seen[id] = true
        total = total + mf:unit_list():num_items()
    end
    local function add_char(c) if is_valid(c) and c:has_military_force() then add(c:military_force()) end end
    local host_attacks = pb:has_attacker() and pb:attacker():command_queue_index() == host:command_queue_index()
    if host_attacks then
        if pb:has_defender() then add_char(pb:defender()) end
        local sd = pb:secondary_defenders()
        for i = 0, sd:num_items() - 1 do add_char(sd:item_at(i)) end
        pcall(function() if pb:has_contested_garrison() then add(pb:contested_garrison():army()) end end)
    else
        if pb:has_attacker() then add_char(pb:attacker()) end
        local sa = pb:secondary_attackers()
        for i = 0, sa:num_items() - 1 do add_char(sa:item_at(i)) end
    end
    return total
end

function ceb:is_mission_battle(pb)
    local key = pb:set_piece_battle_key()
    if key and key ~= "" then return true end
    if self.config.include_quest_mission_battles then
        local ok, mission_key = pcall(function() return pb:quest_mission_key() end)
        if ok and mission_key and mission_key ~= "" then return true end
    end
    return false
end

-- Whether faction_key wants to be invited to this battle of host. Mission battles: always.
function ceb:wants_invite(pb, host, faction_key)
    if self:is_mission_battle(pb) then return true end
    local st = self:get_settings(faction_key)
    if not st.normal then return false end
    local host_attacks = pb:has_attacker() and pb:attacker():command_queue_index() == host:command_queue_index()
    if host_attacks and not st.attacks then return false end
    if not host_attacks and not st.defenses then return false end
    if st.size_on and self:enemy_side_units(pb, host) < st.min_units then return false end
    return true
end

-- Decided inside the PendingBattle event (or another synchronized event) while the battle is valid:
-- never keep a pending_battle object to look at it later (crash of 23-nov-2026 in the test pack:
-- the sides of an AI battle resolved in the meantime were already freed).
function ceb:is_relevant_battle(pb)
    if not pb:is_active() or pb:has_been_fought() then return false end
    if self:is_mission_battle(pb) then return true end
    if not self:any_normal_battles_enabled() then return false end
    local host = self:get_host_character(pb)
    if not host then return false end
    local host_key = host:faction():name()
    for _, key in ipairs(cm:get_human_factions()) do
        if key ~= host_key and self:wants_invite(pb, host, key) then return true end
    end
    return false
end

function ceb:garrison_faction_key(pb)
    local key
    pcall(function() if pb:has_contested_garrison() then key = pb:contested_garrison():faction():name() end end)
    return key
end

function ceb:enemy_of_host(pb, host)
    local other
    pcall(function()
        if pb:has_attacker() and pb:attacker():command_queue_index() == host:command_queue_index() then
            if pb:has_defender() then other = pb:defender() end
        elseif pb:has_attacker() then
            other = pb:attacker()
        end
    end)
    return other
end

-- Teleport cost of ally joining host's battle (0 in mission battles and on the free level).
function ceb:teleport_cost(ally, host)
    local s = self.session
    if not s or not s.normal or not ally or not host then return 0 end
    local mult = self.cost_multiplier[self:get_settings(ally:faction():name()).cost] or 1
    if mult <= 0 then return 0 end
    local dx, dy = ally:logical_position_x() - host:logical_position_x(), ally:logical_position_y() - host:logical_position_y()
    local base = math.min(self.cost_cap, self.cost_base + self.cost_per_unit * math.sqrt(dx * dx + dy * dy))
    return math.floor(base * mult / 50 + 0.5) * 50
end

function ceb:can_afford(ally, cost)
    if cost <= 0 then return true end
    local ok, treasury = pcall(function() return ally:faction():treasury() end)
    return ok and type(treasury) == "number" and treasury >= cost
end

-- Gold check runs inside validate_selection, i.e. in the synchronized J and final V events on every
-- client. The cost is remembered there, before the teleport moves the army, and paid on every
-- client when the join succeeds.
do
    local validate_selection = ceb.validate_selection
    function ceb:validate_selection(faction_key, char_cqi)
        local host, ally = validate_selection(self, faction_key, char_cqi)
        if not host then return host end
        local s = self.session
        if s and s.normal then
            local cost = self:teleport_cost(ally, host)
            if not self:can_afford(ally, cost) then
                self:log("Join rejected: " .. faction_key .. " cannot pay the teleport (" .. cost .. " gold)")
                return false
            end
            s.costs = s.costs or {}
            s.costs[faction_key] = cost
        end
        return host, ally
    end

    local finish_proposal = ceb.finish_proposal
    function ceb:finish_proposal(success, detail)
        local s = self.session
        local p = s and s.proposal
        local cost = success and p and s.costs and s.costs[p.faction] or 0
        if cost > 0 then
            cm:treasury_mod(p.faction, -cost)
            self:log("Teleport paid by " .. p.faction .. ": " .. cost .. " gold")
        end
        return finish_proposal(self, success, detail)
    end

    -- Picker rows show the cost; armies the player cannot pay for are greyed out and ignored.
    local ui_army_label = ceb.ui_army_label
    function ceb:ui_army_label(cqi)
        local label = ui_army_label(self, cqi)
        local s = self.session
        if s and s.normal then
            local ally, host = self:get_char(cqi), self:get_char(s.host_cqi)
            local cost = self:teleport_cost(ally, host)
            if cost > 0 then
                label = label .. " - " .. string.format(self:txt(self:can_afford(ally, cost) and "cost_label" or "cost_missing"), cost)
            end
        end
        return label
    end

    function ceb:candidate_unaffordable(cqi)
        local s = self.session
        if not (s and s.normal) then return false end
        local ally, host = self:get_char(cqi), self:get_char(s.host_cqi)
        return not self:can_afford(ally, self:teleport_cost(ally, host))
    end

    local ui_build_invite_dialog = ceb.ui_build_invite_dialog
    function ceb:ui_build_invite_dialog()
        ui_build_invite_dialog(self)
        pcall(function()
            for i, cqi in ipairs(self.ui.candidates or {}) do
                if self:candidate_unaffordable(cqi) then
                    local row = find_uicomponent(core:get_ui_root(), self.invite_dialog_name, "ceb_army_" .. i)
                    if row then row:SetState("inactive") end
                end
            end
        end)
    end

    local on_component_click = ceb.on_component_click
    function ceb:on_component_click(context)
        local index = type(context.string) == "string" and string.match(context.string, "^ceb_army_(%d+)$")
        if index and self.ui.open[self.invite_dialog_name] then
            local cqi = (self.ui.candidates or {})[tonumber(index)]
            if cqi and self:candidate_unaffordable(cqi) then
                self:log("Click on an army without enough gold, ignored")
                return
            end
        end
        return on_component_click(self, context)
    end

    -- Normal battles have no mission name: the picker and the host's wait dialog name the enemy.
    local battle_display_name = ceb.battle_display_name
    function ceb:battle_display_name(key)
        local s = self.session
        if (key == nil or key == "") and s and s.normal then
            return string.format(self:txt(s.host_is_attacker and "normal_attack" or "normal_defense"),
                s.enemy_faction and self:faction_display_name(s.enemy_faction) or "?")
        end
        return battle_display_name(self, key)
    end
end

-----------------------------------------------------------------------------------
-- SETTINGS BUTTON AND PANEL (local UI; every change is sent as a UITrigger)
-----------------------------------------------------------------------------------
-- The button hangs below the top-left menu bar, right of Auto Equip's button (aeq_hud_frame) when
-- that mod is installed, else where Auto Equip's would be. Same frame and template as Auto Equip.
ceb.settings_ui = {open = false, pending = false, tries = 0}
ceb.hud_frame_name = "ceb_hud_frame"
ceb.hud_button_name = "ceb_hud"
ceb.settings_root_name = "ceb_settings_root"
ceb.settings_layout = {width = 560, margin = 22, title_h = 32, text_h = 44, row_h = 44, gap = 10, footer_h = 34}
ceb.settings_templates = {
    hud = "ui/templates/round_small_button",
    text_button = "ui/templates/square_medium_text_button",
    checkbox = "ui/templates/checkbox_toggle",
}
ceb.settings_icon = "ui/skins/default/icon_options.png"

local function ui_find(parent, ...) if not parent then return nil end return find_uicomponent(parent, ...) end
local function ui_visible(uic)
    local ok, v = pcall(function() return uic:Visible(true) end)
    if ok then return v end
    ok, v = pcall(function() return uic:Visible() end)
    return ok and v
end
local function ui_place(uic, x, y, w, h)
    uic:SetDockingPoint(0)
    if w and h then
        uic:SetCanResizeWidth(true); uic:SetCanResizeHeight(true)
        uic:Resize(math.floor(w), math.floor(h))
    end
    uic:MoveTo(math.floor(x), math.floor(y))
end
local function ui_button_text(b, text)
    local t = ui_find(b, "button_txt") or b
    for _, st in ipairs({"inactive", "active"}) do pcall(function() t:SetState(st); t:SetStateText(text, "") end) end
end

function ceb:settings_later(fn)
    cm:real_callback(function()
        local ok, err = pcall(fn)
        if not ok then self:log("Settings UI error: " .. tostring(err)) end
    end, 50)
end

-- Right of Auto Equip's frame, or where Auto Equip puts its own (below the last menu bar button).
function ceb:settings_hud_position(fw)
    local r = core:get_ui_root()
    local aeq = ui_find(r, "aeq_hud_frame")
    if aeq and ui_visible(aeq) then
        local ax, ay = aeq:Position()
        local aw = aeq:Bounds()
        return ax + aw + 2, ay
    end
    local menu = ui_find(r, "menu_bar", "button_menu")
    if not menu then
        local _, sh = core:get_screen_resolution()
        return 6, math.floor((tonumber(sh) or 1080) * 0.30)
    end
    local lx, my = menu:Position()
    local lw, mh = menu:Bounds()
    local last = menu
    pcall(function()
        local row = UIComponent(menu:Parent())
        for i = 0, row:ChildCount() - 1 do
            local ch = UIComponent(row:Find(i))
            local x, y = ch:Position()
            local w = ch:Bounds()
            if ui_visible(ch) and math.abs(y - my) < mh and x + w > lx + lw then last, lx, lw = ch, x, w end
        end
    end)
    local x, y = last:Position()
    local w, h = last:Bounds()
    return x + math.floor((w - fw) / 2), y + h + 4
end

function ceb:settings_place_hud(f)
    local fw, fh = f:Bounds()
    local x, y = self:settings_hud_position(fw)
    x, y = math.max(0, math.floor(x)), math.max(0, math.floor(y))
    local cx, cy = f:Position()
    if cx ~= x or cy ~= y then f:SetDockingPoint(0); f:MoveTo(x, y) end
    local b = ui_find(f, self.hud_button_name)
    if b then
        local bw, bh = b:Bounds()
        local bx, by = x + math.floor((fw - bw) / 2), y + math.floor((fh - bh) / 2) + 2
        local ox, oy = b:Position()
        if ox ~= bx or oy ~= by then b:SetDockingPoint(0); b:MoveTo(bx, by) end
    end
end

-- Hidden with the menu bar and with the character panel, like Auto Equip's.
function ceb:settings_hud_layer(f)
    local r = core:get_ui_root()
    local bar = ui_find(r, "menu_bar")
    if bar and not self.settings_ui.prio then
        self.settings_ui.prio = pcall(function() f:PropagatePriority(bar:Priority()) end)
    end
    local cdp = ui_find(r, "character_details_panel")
    local hide = (bar and not ui_visible(bar)) or (cdp and ui_visible(cdp))
    if ui_visible(f) == (hide and true or false) then f:SetVisible(not hide) end
    return hide
end

function ceb:settings_ensure_hud()
    local r = core:get_ui_root()
    if not r then return end
    local f = ui_find(r, self.hud_frame_name)
    if f then
        if not self:settings_hud_layer(f) then self:settings_place_hud(f) end
        return
    end
    if self.settings_ui.tries >= 5 then return end
    self.settings_ui.tries = self.settings_ui.tries + 1
    f = UIComponent(r:CreateComponent(self.hud_frame_name, "UI/Common UI/ceb_hud"))
    pcall(function() f:SetInteractive(false) end)
    local b = UIComponent(f:CreateComponent(self.hud_button_name, self.settings_templates.hud))
    b:SetVisible(true)
    pcall(function() b:SetImagePath(self.settings_icon, 0) end)
    b:SetTooltipText(self:txt("cfg_hud_tooltip"), true)
    self.settings_ui.prio = nil
    if not self:settings_hud_layer(f) then self:settings_place_hud(f) end
end

function ceb:settings_start()
    self:settings_ensure_hud()
    cm:repeat_real_callback(function()
        local ok, err = pcall(function() self:settings_ensure_hud() end)
        if not ok then self:log("Settings button error: " .. tostring(err)) end
    end, 250, "ceb_settings_hud")
    core:add_listener("ceb_settings_click", "ComponentLClickUp", function(context)
        local id = context.string
        return type(id) == "string" and (id == self.hud_button_name or string.sub(id, 1, 8) == "ceb_cfg_")
    end, function(context)
        local ok, err = pcall(function() self:settings_on_click(context.string) end)
        if not ok then self:log("Settings click error: " .. tostring(err)) end
    end, true)
end

function ceb:settings_request_refresh()
    if self.settings_ui.pending then return end
    self.settings_ui.pending = true
    self:settings_later(function()
        self.settings_ui.pending = false
        self:settings_rebuild()
    end)
end

function ceb:settings_destroy()
    local p = ui_find(core:get_ui_root(), self.settings_root_name)
    if p then pcall(function() p:RemoveTopMost() end); p:Destroy() end
end

-- Never rebuild inside the click: every change waits 50 ms (engine lesson 1).
function ceb:settings_on_click(id)
    self:log("Settings click " .. tostring(id))
    if id == self.hud_button_name then
        self.settings_ui.open = not self.settings_ui.open
        if self.settings_ui.open then self:settings_request_refresh() else self:settings_later(function() self:settings_destroy() end) end
        return
    end
    if not self.settings_ui.open then return end
    if id == "ceb_cfg_close" then
        self.settings_ui.open = false
        self:settings_later(function() self:settings_destroy() end)
        return
    end
    local st = {}
    for k, v in pairs(self.settings_ui.preview or self:get_settings(self:local_faction_key())) do st[k] = v end
    if id == "ceb_cfg_normal" then st.normal = not st.normal
    elseif id == "ceb_cfg_attacks" then st.attacks = not st.attacks
    elseif id == "ceb_cfg_defenses" then st.defenses = not st.defenses
    elseif id == "ceb_cfg_size" then st.size_on = not st.size_on
    elseif id == "ceb_cfg_units" then
        local i = 1
        for k, v in ipairs(self.min_units_options) do if v == st.min_units then i = k end end
        st.min_units = self.min_units_options[i % #self.min_units_options + 1]
    elseif id == "ceb_cfg_cost" then
        local i = 1
        for k, v in ipairs(self.cost_levels) do if v == st.cost then i = k end end
        st.cost = self.cost_levels[i % #self.cost_levels + 1]
    else
        return
    end
    -- Shown at once from the sent values; every client stores them when the UITrigger arrives.
    self.settings_ui.preview = st
    self:send_local_settings(st)
    self:settings_request_refresh()
end

function ceb:settings_rebuild()
    self:settings_destroy()
    if not self.settings_ui.open then return end
    local r = core:get_ui_root()
    local L = self.settings_layout
    -- Until the UITrigger comes back, the panel shows the values just sent.
    local st = self.settings_ui.preview or self:get_settings(self:local_faction_key())
    local dialog = UIComponent(r:CreateComponent(self.settings_root_name, "UI/Common UI/ceb_settings"))
    local panel = ui_find(dialog, "ceb_settings") or dialog
    local rows = {
        {id = "ceb_cfg_normal", on = st.normal, text = "cfg_normal", tip = "cfg_normal_tip"},
    }
    if st.normal then
        table.insert(rows, {id = "ceb_cfg_attacks", on = st.attacks, text = "cfg_attacks", tip = "cfg_attacks_tip", indent = true})
        table.insert(rows, {id = "ceb_cfg_defenses", on = st.defenses, text = "cfg_defenses", tip = "cfg_defenses_tip", indent = true})
        table.insert(rows, {id = "ceb_cfg_size", on = st.size_on, text = "cfg_size", tip = "cfg_size_tip", indent = true,
            value = {id = "ceb_cfg_units", text = string.format(self:txt("cfg_units"), st.min_units), enabled = st.size_on}})
        table.insert(rows, {id = nil, text = "cfg_cost", tip = "cfg_cost_tip", indent = true,
            value = {id = "ceb_cfg_cost", text = self:txt("cfg_cost_" .. st.cost), enabled = true}})
    end
    local sw, sh = core:get_screen_resolution()
    sw, sh = tonumber(sw) or 1920, tonumber(sh) or 1080
    local width = math.min(L.width, sw - 40)
    local height = L.margin * 2 + L.title_h + L.text_h + L.gap + #rows * L.row_h + L.gap + L.footer_h
    ui_place(panel, (sw - width) / 2, (sh - height) / 2, width, height)
    local px, py = panel:Position()
    local inner = width - 2 * L.margin
    local x0, y = px + L.margin, py + L.margin
    local title = ui_find(panel, "ceb_cfg_title")
    title:SetStateText(self:txt("cfg_title"), "")
    ui_place(title, x0, y, inner, L.title_h)
    y = y + L.title_h
    local intro = ui_find(panel, "ceb_cfg_intro")
    intro:SetStateText(self:txt("cfg_intro"), "")
    ui_place(intro, x0, y, inner, L.text_h)
    y = y + L.text_h + L.gap
    local template = ui_find(panel, "ceb_cfg_row_tx")
    template:SetVisible(false)
    for i, row in ipairs(rows) do
        local x = x0 + (row.indent and 28 or 0)
        if row.id then
            local cb = UIComponent(panel:CreateComponent(row.id, self.settings_templates.checkbox))
            cb:SetVisible(true)
            cb:SetDockingPoint(0)
            cb:MoveTo(math.floor(x), math.floor(y + (L.row_h - 32) / 2))
            pcall(function() cb:SetState(row.on and "selected" or "active") end)
            cb:SetTooltipText(self:txt(row.tip), true)
        end
        local label = UIComponent(template:CopyComponent("ceb_cfg_label_" .. i))
        panel:Adopt(label:Address())
        label:SetVisible(true)
        label:SetStateText(self:txt(row.text), "")
        label:SetTooltipText(self:txt(row.tip), true)
        local value_w = row.value and 170 or 0
        ui_place(label, x + 40, y + 6, inner - (x - x0) - 40 - value_w - 8, L.row_h - 12)
        if row.value then
            local b = UIComponent(panel:CreateComponent(row.value.id, self.settings_templates.text_button))
            b:SetVisible(true)
            ui_place(b, x0 + inner - value_w, y + 5, value_w, L.row_h - 10)
            ui_button_text(b, row.value.text)
            b:SetTooltipText(self:txt(row.tip), true)
            pcall(function() b:SetState(row.value.enabled and "active" or "inactive") end)
        end
        y = y + L.row_h
    end
    local close = UIComponent(panel:CreateComponent("ceb_cfg_close", self.settings_templates.text_button))
    close:SetVisible(true)
    ui_place(close, x0 + inner - 160, py + height - L.margin - L.footer_h, 160, L.footer_h)
    ui_button_text(close, self:txt("cfg_close"))
    pcall(function() dialog:RegisterTopMost() end)
end
