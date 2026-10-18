--from https://github.com/mt-mods/digistuff

local BASENAME = "digilines:touchscreen"

local unpack = table.unpack or unpack

local formspec_elements = dofile(minetest.get_modpath("digilines").."/formspec_elements.lua")

local formspec_version = 6

-- Track which players have touchscreen UI currently open, with two-way lookup
digilines.opened_touchscreens = digilines.opened_touchscreens or {}
digilines.opened_touchscreens_players = digilines.opened_touchscreens_players or {}
digilines.touchscreen_formspec_cache = digilines.touchscreen_formspec_cache or {}
digilines.touchscreen_formspec_cache_size = digilines.touchscreen_formspec_cache_size or 0
digilines.touchscreen_rate_limits = digilines.touchscreen_rate_limits or {}

local function create_element_string(element, values)
	if type(element) == "function" then
		return element(values)
	end
	local new_values = {}
	for i,name in ipairs(element[2]) do
		local value = element[4][i](values[name], element[3][i])
		table.insert(new_values, value)
	end
	return string.format(element[1], unpack(new_values))
end

local function modify_element_string(old, values)
	local e = string.match(old, "^(.-)%[[^[]*%]$")
	local element = formspec_elements[e]
	if type(element) ~= "table" then
		return old  -- No-op for special elements, as there is no format string
	end
	local old_values = {string.match(old, element[5])}
	local new_values = {}
	for i,name in ipairs(element[2]) do
		local value = element[4][i](values[name], old_values[i] or element[3][i])
		table.insert(new_values, value)
	end
	return string.format(element[1], unpack(new_values))
end

local function check_old_command(msg)
	local cmd = msg.command
	if cmd == "lock" then
		return {command = "set", locked = true}
	end
	if cmd == "unlock" then
		return {command = "set", locked = false}
	end
	if cmd == "realcoordinates" then
		return {command = "set", real_coordinates = msg.enabled}
	end
	if string.match(cmd, "^add%a+") then
		msg.element = string.sub(cmd, 4)
		msg.command = "add"
	end
	return msg
end

local function process_command(meta, data, msg)
	msg = check_old_command(msg)
	local cmd = msg.command

	if cmd == "clear" then
		data = {}

	elseif cmd == "add" then
		local element = formspec_elements[msg.element]
		if element then
			local str = create_element_string(element, msg)
			table.insert(data, str)
		end

	elseif cmd == "insert" then
		local element = formspec_elements[msg.element]
		local index = tonumber(msg.index)
		if element and index and index > 0 then
			local str = create_element_string(element, msg)
			table.insert(data, index, str)
		end

	elseif cmd == "replace" then
		local element = formspec_elements[msg.element]
		local index = tonumber(msg.index)
		if element and index and data[index] then
			local str = create_element_string(element, msg)
			data[index] = str
		end

	elseif cmd == "modify" then
		local index = tonumber(msg.index)
		if index and data[index] then
			local str = modify_element_string(data[index], msg)
			data[index] = str
		end

	elseif cmd == "remove" then
		local index = tonumber(msg.index)
		if index and data[index] then
			table.remove(data, index)
		end

	elseif cmd == "delete" then
		local index = tonumber(msg.index)
		if index and data[index] then
			data[index] = nil
		end

	elseif cmd == "set" then
		if msg.locked ~= nil then
			meta:set_int("locked", msg.locked == false and 0 or 1)
		end
		if msg.no_prepend ~= nil then
			meta:set_int("no_prepend", msg.no_prepend == false and 0 or 1)
		end
		if msg.real_coordinates ~= nil then
			meta:set_int("real_coordinates", msg.real_coordinates == false and 0 or 1)
		end
		if msg.fixed_size ~= nil then
			meta:set_int("fixed_size", msg.fixed_size == false and 0 or 1)
		end
		if type(msg.width) == "number" then
			local value = math.max(1, math.min(100, msg.width))
			meta:set_string("width", string.format("%.4g", value))
		end
		if type(msg.height) == "number" then
			local value = math.max(1, math.min(100, msg.height))
			meta:set_string("height", string.format("%.4g", value))
		end
		if type(msg.focus) == "string" then
			meta:set_string("focus", minetest.formspec_escape(msg.focus))
		end
	end

	return data
end

local function get_data(meta)
    local data_s = meta:get("data")
    if data_s == nil then return nil end

	local data = minetest.deserialize(data_s)
	if data and type(data[1]) == "table" then
		-- Old data, convert to new format
		for i,v in ipairs(data) do
			local element = formspec_elements[v.type]
			data[i] = create_element_string(element, v)
		end
	end
	return data
end

-- Tries to prevent rightlick and form submission spam DOS from modified clients
-- Should not trip during normal gameplay
-- "Token bucket" approach
local RATE_LIMIT_BUCKET_SIZE = 50.0
local RATE_LIMIT_BUCKET_RATE = 4.0 -- 250ms per click continuously for 12.5s, you really really have to try
local function rate_limit(player, cost)
	cost = cost or 1.0
	local lim = digilines.touchscreen_rate_limits[player] or {}
	local clock = minetest.get_us_time() / 1e6 -- clock is in float seconds
	local ct = clock - (lim.lastclick or clock - 1.0) -- time since previous click
	lim.lastclick = clock
	local bucket = lim.bucket or RATE_LIMIT_BUCKET_SIZE
	local rate = lim.rate or RATE_LIMIT_BUCKET_RATE
	-- Regenerate the bucket
	bucket = math.min(RATE_LIMIT_BUCKET_SIZE, math.max(0.0, bucket) + ct * rate)
	local tripped = false
	if bucket < cost then
		tripped = true
		lim.tripped = (lim.tripped or 0) + 1
		if lim.tripped < 100 then
			minetest.chat_send_player(player, "Your interaction with the Touchscreen was rate limited ("..tostring(lim.tripped)..").")
		elseif lim.tripped % 100 == 1 then
			minetest.chat_send_player(player, "You are interacting with the Touchscreen way too fast. Please take a break.")
			minetest.log("warning", "Touchscreen interaction limit tripped "..tostring(lim.tripped).." times by: "..player)
			-- Reduce the rate even more for persistent players
			lim.rate = math.max(0.2, rate / 2.0)
		end
		-- Make spam clicking completely useless
		bucket = bucket - math.min(1.0, cost)
	else
		-- Clear the reduced rate if the player actually stopped
		if (lim.rate and bucket > RATE_LIMIT_BUCKET_SIZE * 0.5) then lim.rate = nil end
		-- Clear the counter for players who have not interacted with a touchscreen for 10 minutes
		if (lim.tripped and ct > 600.0) then lim.tripped = nil end
		-- Subtract from the bucket
		bucket = bucket - cost
	end
	lim.bucket = bucket
	digilines.touchscreen_rate_limits[player] = lim
	return tripped
end

local function formspec_opened_unchecked(name, pos_str)
	digilines.opened_touchscreens_players[name] = pos_str
	if digilines.opened_touchscreens[pos_str] == nil then
		digilines.opened_touchscreens[pos_str] = {}
	end
	digilines.opened_touchscreens[pos_str][name] = true
end

local function formspec_closed_unchecked(name, pos_str)
	digilines.opened_touchscreens[pos_str][name] = nil
	if next(digilines.opened_touchscreens[pos_str]) == nil then
		digilines.opened_touchscreens[pos_str] = nil
	end
	digilines.opened_touchscreens_players[name] = nil
end

local function formspec_opened(name, pos)
	if (name == nil or name == "" or not pos) then return end
	local pos_str = vector.to_string(pos)
	if not pos_str then return end
	formspec_opened_unchecked(name, pos_str)
end

local function formspec_closed(name)
	if (name == nil or name == "") then return end
	local pos_str = digilines.opened_touchscreens_players[name]
	if not pos_str then 
		digilines.opened_touchscreens_players[name] = nil
		return
	end
	formspec_closed_unchecked(name, pos_str)
end

local function clear_opened_formspecs(pos)
	local pos_str = vector.to_string(pos)
	local pkey = minetest.hash_node_position(pos)
	if not pos_str then return end
	for player,_ in pairs(digilines.opened_touchscreens[pos_str] or {}) do
		minetest.close_formspec(player, BASENAME)
		digilines.opened_touchscreens_players[player] = nil
	end
	digilines.opened_touchscreens[pos_str] = nil
	-- Also clear the cache associated with this controller
	if digilines.touchscreen_formspec_cache[pkey] ~= nil then
		digilines.touchscreen_formspec_cache[pkey] = nil
		if digilines.touchscreen_formspec_cache_size > 0 then
			digilines.touchscreen_formspec_cache_size = digilines.touchscreen_formspec_cache_size - 1
		end
	end
end

local function create_formspec(meta, data)
	local fs = "formspec_version["..formspec_version.."]"
	local width = tonumber(meta:get_string("width")) or 10
	local height = tonumber(meta:get_string("height")) or 8
	if meta:get_int("fixed_size") == 1 then
		fs = fs.."size["..width..","..height..",true]"
	else
		fs = fs.."size["..width..","..height.."]"
	end
	if meta:get_int("no_prepend") == 1 then
		fs = fs.."no_prepend[]"
	end
	if (meta:get("real_coordinates") or meta:get("realcoordinates")) ~= "1" then
		fs = fs.."real_coordinates[false]"
	end
	local focus = meta:get("focus")
	if focus then
		fs = fs.."set_focus["..focus.."]"
	end
	local data_size = 0
	for i in pairs(data) do
		if i > data_size then
			data_size = i
		end
	end
	for i=1, data_size do
		if data[i] then
			fs = fs..data[i]
		end
	end
	return fs
end

-- Digilines message is limited to 50000 characters, resulting in formspec size of ~50KB
-- Worst case scenario for the entire cache is < 30MB
-- In norml use will be magnitudes less even when full
local MAX_FORMSPEC_CACHE_SIZE = digilines.setting("max_formspec_cache_size", 500)

local function update_formspec(pos, meta, refresh, data)
	local pos_str = vector.to_string(pos)
	local pkey = minetest.hash_node_position(pos)
	local opened = digilines.opened_touchscreens[pos_str]
	if opened == nil then
		 -- No players are viewing the formspec, evict the old cache instead of refreshing and exit
		if (refresh and digilines.touchscreen_formspec_cache[pkey] ~= nil) then
			digilines.touchscreen_formspec_cache[pkey] = nil
			if digilines.touchscreen_formspec_cache_size > 0 then
				digilines.touchscreen_formspec_cache_size = digilines.touchscreen_formspec_cache_size - 1
			end
		end
		return
	end
	local cache = digilines.touchscreen_formspec_cache[pkey]
	local legacy = meta:get_string("formspec")
	local formspec
	if (refresh or (cache == nil and legacy == "")) then
		if not meta:get("init") then
			formspec = "field[channel;Channel;]"
		else
			data = data or get_data(meta)
			if not data then
				formspec = "size[10,8]"
			else
				formspec = create_formspec(meta, data)
			end
		end
		-- Clear the cache if it got too large before adding to it
		if digilines.touchscreen_formspec_cache_size > MAX_FORMSPEC_CACHE_SIZE then
			digilines.touchscreen_formspec_cache = {}
			digilines.touchscreen_formspec_cache_size = 0
		end
		digilines.touchscreen_formspec_cache[pkey] = formspec
		digilines.touchscreen_formspec_cache_size = digilines.touchscreen_formspec_cache_size + 1
		-- Delete formspec from old controllers
		if legacy ~= "" then meta:set_string("formspec", "") end
	elseif legacy ~= "" then
		-- Display old formspec still stored in meta to preserve the errmsg
		formspec = legacy
	else
		formspec = cache
	end
	for player,_ in pairs(opened) do
		if (digilines.opened_touchscreens_players[player] ~= nil) then
			minetest.show_formspec(player, BASENAME, formspec)
		else
			-- This should not have happened, close UI and clear inconsistent record
			minetest.close_formspec(player, BASENAME)
			formspec_closed_unchecked(player, pos_str)
		end
	end
end

local function on_digiline(pos, node, channel, msg)
	if type(msg) ~= "table" then
		return
	end
	local meta = minetest.get_meta(pos)
	if channel ~= meta:get_string("channel") then
		return
	end
	local data = get_data(meta) or {}
	if type(msg.command) == "string" then
		data = process_command(meta, data, msg)
	else
		for _,v in ipairs(msg) do
			if type(v) == "table" and type(v.command) == "string" then
				data = process_command(meta, data, v)
			end
		end
	end
	meta:set_string("data", minetest.serialize(data))
	update_formspec(pos, meta, true, data)
end

local function receive_fields(player, formname, fields)
	if formname ~= BASENAME then return false end
	local name = player and player:get_player_name() or ""
	if name == "" then return true end
	local pos_str = digilines.opened_touchscreens_players[name]
	if not pos_str then return true end
	local pos = vector.from_string(pos_str)
	if not pos then return true end
	if rate_limit(name) then
		-- Register formspec close even when rate limited, this operation is not expensive
		if fields.quit == true then
			formspec_closed_unchecked(name, pos_str)
		end
		return true
	end
	-- Prevent interaction across the map on player being teleported, etc
	local player_pos = player:get_pos()
	if (not player_pos or vector.distance(player_pos, pos) > 25.0) then
		formspec_closed_unchecked(name, pos_str)
		minetest.close_formspec(name, BASENAME)
		minetest.chat_send_player(name, "The Touchscreen is too far away!")
	end
	-- Check if the touchscreen still exists and loaded
	local node_name = minetest.get_node(pos).name
	if (not node_name or node_name:sub(1, #BASENAME) ~= BASENAME) then
		clear_opened_formspecs(pos)
		minetest.chat_send_player(name, "The Touchscreen could not be found.")
		-- Log because this should not normally happen
		-- on_destruct should have already closed everything for all players and distance check stopping unloaded interaction
		minetest.log("warning", name.." tried to interact with an unloaded or non-existent Touchscreen at "..pos_str)
		return true
	end
	-- Handle player closing the formspec
	if fields.quit == true then
		formspec_closed_unchecked(name, pos_str)
	end
	local meta = minetest.get_meta(pos)
	if meta:get_int("locked") == 1 and minetest.is_protected(pos, name) then
		minetest.chat_send_player(name, "You are not authorized to use this screen.")
		return true
	end
	if not meta:get("init") and fields.channel then
		meta:set_string("channel", fields.channel)
		meta:set_int("init", 1)
		update_formspec(pos, meta, true)
	else
		local channel = meta:get_string("channel")
		fields.clicker = name
		digilines.receptor_send(pos, digilines.rules.default, channel, fields)
	end
	return true
end

minetest.register_on_player_receive_fields(receive_fields)

-- No longer send formspec updates to player who dies or logs off
core.register_on_dieplayer(function(ref, reason)
	local name = ref and ref:get_player_name() or ""
	formspec_closed(name)
end)

core.register_on_leaveplayer(function(ref, timed_out)
	local name = ref and ref:get_player_name() or ""
	formspec_closed(name)
	digilines.touchscreen_rate_limits[name] = nil
end)

-- Clear currently opened touchscreen for a player that just joined in case this somehow was still set
core.register_on_joinplayer(function(ref, last_login)
	local name = ref and ref:get_player_name() or ""
	formspec_closed(name)
end)

-- Show formspec UI to player when they click the controller
local function on_rightclick(pos, node, clicker, itemstack, pointed_thing)
	local name = clicker and clicker:get_player_name() or ""
	if (name ~= "" and not rate_limit(name)) then
		local meta = minetest.get_meta(pos)
		formspec_opened(name, pos)
		update_formspec(pos, meta, false)
	end
	return itemstack
end

minetest.register_node(BASENAME, {
	description = "Digilines Touchscreen",
	groups = {cracky = 3, not_blocking_trains = 1},
	is_ground_content = false,
	tiles = {
		"digistuff_panel_back.png",
		"digistuff_panel_back.png",
		"digistuff_panel_back.png",
		"digistuff_panel_back.png",
		"digistuff_panel_back.png",
		"digistuff_ts_front.png"
	},
	drawtype = "nodebox",
	paramtype = "light",
	paramtype2 = "facedir",
	node_box = {
		type = "fixed",
		fixed = {
			{-0.5, -0.5, 0.4, 0.5, 0.5, 0.5}
		}
	},
	on_rightclick = on_rightclick,
	on_destruct = function(pos)
		clear_opened_formspecs(pos)
	end,
	digilines = {
		receptor = {},
		effector = {
			action = on_digiline
		}
	},
	_digistuff_channelcopier_fieldname = "channel",
	_digistuff_channelcopier_onset = function(pos)
		local meta = minetest.get_meta(pos)
		meta:set_int("init", 1)
		update_formspec(pos, meta, true)
	end,
})

minetest.register_craft({
	output = BASENAME,
	recipe = {
		{"mesecons_luacontroller:luacontroller0000", "default:glass", "default:glass"},
		{"default:glass", "digilines:lcd", "default:glass"},
		{"default:glass", "default:glass", "default:glass"}
	}
})
