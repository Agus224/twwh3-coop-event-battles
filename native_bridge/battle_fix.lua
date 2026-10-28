-- Co-op Event Battles: battle-side fix (script/battle/mod/coop_event_battles_battle.lua).
--
-- When the ally's real army joins a quest battle, the player's alliance holds two campaign
-- armies whose units have no script name. Many CA quest scripts fetch the player's army with
-- gb:get_army(gb:get_player_alliance_num()) or gb:get_player_army(), which look for the single
-- army without a script name. With two of them CA's get_army reports an error and returns
-- false, so the script dies; if the intro had faded the screen out (Arbaal, Thanquol, Aislinn...)
-- the battle stays black for both players.
--
-- Battle mods load inside load_script_libraries(), after lib_generated_battle and before the
-- quest script creates its generated_battle, so get_army can be wrapped here. Only the case
-- that would otherwise fail changes: it returns the first unnamed army of the alliance (the
-- host's; the ally's army is appended after it). Both clients see the same alliances, so the
-- choice is the same on both machines and the battle stays in sync.

do
	local log_file = "coop_event_battles_log.txt"
	local log_max = 512 * 1024
	local log_keep = 128 * 1024

	-- Same size policy as the campaign log (512 KB, trimmed to the last 128 KB).
	local function trim_log()
		local f = io.open(log_file, "rb")
		if not f then return end
		local size = f:seek("end") or 0
		if size <= log_max then f:close(); return end
		f:seek("set", size - log_keep)
		local tail = f:read("*a") or ""
		f:close()
		local nl = string.find(tail, "\n")
		if nl then tail = string.sub(tail, nl + 1) end
		f = io.open(log_file, "wb")
		if not f then return end
		f:write("---- older lines removed (log limit " .. math.floor(log_max / 1024) .. " KB) ----\n" .. tail)
		f:close()
	end

	local trimmed = false
	local function log(msg)
		msg = "[CoopEventBattles] [battle] " .. tostring(msg)
		pcall(function() if bm then bm:out(msg) end end)
		pcall(function()
			if not trimmed then trimmed = true; trim_log() end
			local f = io.open(log_file, "a")
			if f then
				f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
				f:close()
			end
		end)
	end

	local function army_faction(alliance_index, army_index)
		local ok, key = pcall(function()
			return bm:alliances():item(alliance_index):armies():item(army_index):faction_key()
		end)
		return ok and tostring(key) or "?"
	end

	if type(generated_battle) ~= "table" or type(generated_battle.get_army) ~= "function" then
		log("generated_battle not loaded; get_army fix not installed")
	elseif not generated_battle.ceb_get_army_fixed then
		local original_get_army = generated_battle.get_army
		generated_battle.ceb_get_army_fixed = true

		function generated_battle:get_army(alliance_index, second_param, third_param)
			if type(alliance_index) == "number" and (second_param == nil or second_param == "") and third_param == nil
				and type(self.generated_armies) == "table" and type(self.generated_armies[alliance_index]) == "table" then
				local alliance = self.generated_armies[alliance_index]
				local matches = {}
				for i = 1, #alliance do
					for j = 1, #alliance[i] do
						if alliance[i][j].script_name == "" then
							table.insert(matches, i)
							break
						end
					end
				end
				if #matches > 1 then
					local factions = {}
					for k = 1, #matches do
						table.insert(factions, matches[k] .. "=" .. army_faction(alliance_index, matches[k]))
					end
					log("get_army: alliance " .. alliance_index .. " has " .. #matches .. " unnamed armies (" ..
						table.concat(factions, ", ") .. "); using army " .. matches[1])
					return self:get_army_by_alliance_army_and_script_name(alliance_index, matches[1], "")
				end
			end
			return original_get_army(self, alliance_index, second_param, third_param)
		end

		log("battle fix loaded (get_army with several unnamed armies)")
	end
end
