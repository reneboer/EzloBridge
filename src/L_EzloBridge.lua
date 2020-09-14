ABOUT = {
  NAME          = "EzloBridge",
  VERSION       = "1.10",
  DESCRIPTION   = "EzloBridge plugin for openLuup",
  AUTHOR        = "reneboer",
  COPYRIGHT     = "(c) 2013-2020 AKBooer and reneboer",
  DOCUMENTATION = "https://github.com/reneboer/EzloBridge/wiki",
  DEBUG         = false,
  LICENSE       = [[
  Copyright 2013-2020 AK Booer, Rene Boer

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]
}
--[[

Bi-directional monitor/control link to remote Ezlo system

NB. this version ONLY works in openLuup
It plays with action calls and device creation in ways that you can't do in Vera,
in order to be able to implement ANY command action and 
also to logically group device numbers for remote machine device clones.

2020-05-30		Using VeraBridge 2020.04.30
2020.06.06b		Implement Ezlo as Hub to bridge
2020.06.23b		Added manufacturer and model if available from Ezlo.
				Updated HVAC operations
				Setup child devices correctly by setting Vera parent ID.
2020.06.26b		Fixed adding manufacturer and model if available from Ezlo.
1.01b			Added logging, variables, json and utils modules.
				Log level is a user setting.
				Remove rooms, scenes and device ID from stored mapping.
				Changes SID/device type to rboer.
				Added periodic full pull of devices and items for full status refresh.
				Display Can't Detect Device message if hub shows as unreachable.
1.02b			Handle broken device status. (Message shows as Cannot reach or broken)
				Fixed issue for unwanted State variables created for Ezlo device items we want to ignore.
				Fixed duplicate creation of CurrentTemperature.
				Display Device Broken message if hub shows as broken
1.03			Able to reconnect if VM running openLuup is restarted without needing a luup reload.
				Changed items mapping to generic sensor to item name and not all the CurrentLevel.
				Fix for SetArmed action as Ezlo changed value name.
				Fix for scalar type variables.
				Fix for action mapping functions.
				Some logging fixes.
1.04			Fix for device offset.
1.05			Better handle null return values from portal for initial logon.
1.06			Fix for numeric values on Athom
1.07			Fix for reconnect retry
1.08			Added solar meter week, month, year and life time KWh values for Ezlo-SolarMeter plugin.
1.09			kwh_reading_timestamp item.
1.10			Fix for fresh install lastFullStatusUpdate not initialized.

To do's: 
	better reconnect handler to deal with expired token (did not have it expire yet to test).
	command queue during lost connection. (is this needed?)
	better support of locks
	Make it work on Vera

Messages when hub is starting. Normally at restart the WS connections is lost and a reconnect is triggered.
{"id":"ui_broadcast","msg_subclass":"hub.gateway.updated","result":{"_id":"5ec3e5a4124c4114fb88839f","status":"starting"}}
{"id":"ui_broadcast","msg_subclass":"hub.gateway.updated","result":{"_id":"5ec3e5a4124c4114fb88839f","status":"ready"}}

]]

local devNo                      -- our device number

local chdev     = require "openLuup.chdev"
local scenes    = require "openLuup.scenes"
local userdata  = require "openLuup.userdata"
local cjson     = require "cjson"
local dkjson    = require "dkjson"

local ip					-- remote machine ip address
local local_room_index		-- bi-directional index of our rooms
local remote_room_index		-- bi-directional of remote rooms

local BuildVersion			-- ...of remote machine
local PK_AccessPoint		-- ... ditto
local LoadTime				-- ... ditto
local EzloHubUserID			-- User ID used to logon to Ezlo Hub
local RemotePort			-- port to access remote machine 
							-- "/port_3480" for newer Veras, ":3480" for older ones, and openLuup
							-- 17000 for Ezlo WebSocket
local EzloData = {}			-- to store Vera /data_request?id=user_data2 like structure as input for GetUserData
							-- we keep this for all processing & mapping
local lastFullStatusUpdate	-- periodic status request for all variables

local SID = {
	altui			= "urn:upnp-org:serviceId:altui1"  ,         -- Variables = 'DisplayLine1' and 'DisplayLine2'
	bridge			= luup.openLuup.bridge.SID,                  -- for Remote_ID variable
	gateway			= "urn:rboer-com:serviceId:EzloBridge1",
	switch_power	= "urn:upnp-org:serviceId:SwitchPower1",
	dimming			= "urn:upnp-org:serviceId:Dimming1",
	temp_setp		= "urn:upnp-org:serviceId:TemperatureSetpoint1",
	temp_setpc		= "urn:upnp-org:serviceId:TemperatureSetpoint1_Cool",
	temp_setph		= "urn:upnp-org:serviceId:TemperatureSetpoint1_Heat",
	hvac_fom		= "urn:upnp-org:serviceId:HVAC_FanOperatingMode1",
	hvac_uom		= "urn:upnp-org:serviceId:HVAC_UserOperatingMode1",
	hvac_os			= "urn:upnp-org:serviceId:HVAC_OperatingState1",
	hvac_fs			= "urn:upnp-org:serviceId:FanSpeed1",
	window_cov		= "urn:upnp-org:serviceId:WindowCovering1",
	energy			= "urn:micasaverde-com:serviceId:EnergyMetering1",
	scene_control	= "urn:micasaverde-com:serviceId:SceneController1",
	sec_sensor 		= "urn:micasaverde-com:serviceId:SecuritySensor1",
	gen_sensor		= "urn:micasaverde-com:serviceId:GenericSensor1",
	hum_sensor		= "urn:micasaverde-com:serviceId:HumiditySensor1",
	temp_sensor		= "urn:upnp-org:serviceId:TemperatureSensor1",
	light_sensor	= "urn:micasaverde-com:serviceId:LightSensor1",
	had				= "urn:micasaverde-com:serviceId:HaDevice1",
	hag				= "urn:micasaverde-com:serviceId:HomeAutomationGateway1",
	door_lock		= "urn:micasaverde-com:serviceId:DoorLock1",
	color			= "urn:micasaverde-com:serviceId:Color1"
}

local HouseModeMirror   -- flag with one of the following options
local HouseModeTime = 0 -- last time we checked
local VeraScenes, VeraRoom
local BridgeScenes, CloneRooms, ZWaveOnly, Included, Excluded
local EzloHubUserID

-- Forward declarations of API modules
local json
local log
local var
local utils
local ezlo

-- API getting and setting variables and attributes from Vera more efficient and with parameter type checks.
local function varAPI()
	local def_sid, def_dev = "", 0
	
	local function _init(sid,dev)
		def_sid = sid
		def_dev = dev
	end
	
	-- Get variable value
	local function _get(name, sid, device)
		if type(name) ~= "string" then
			luup.log("var.Get: variable name not a string.", 1)
			return false
		end	
		local value, ts = luup.variable_get(sid or def_sid, name, tonumber(device or def_dev))
		return (value or "")
	end

	-- Get variable value as string type
	local function _get_string(name, sid, device)
		local value = _get(name, sid, device)
		if type(value) ~= "string" then
			luup.log("var.GetString: wrong data type ("..type(value)..") for variable "..(name or "unknown"), 2)
			return false
		end
		return value
	end
	
	-- Get variable value as number type
	local function _get_num(name, sid, device)
		local value = _get(name, sid, device)
		local num = tonumber(value,10)
		if type(num) ~= "number" then
			luup.log("var.GetNumber: wrong data type ("..type(value)..") for variable "..(name or "unknown").." device "..tostring(device)..", value found "..tostring(num), 2)
			return false
		end
		return num
	end
	
	-- Get variable value as boolean type. Convert 0/1 to true/false
	local function _get_bool(name, sid, device)
		local value = _get(name, sid, device)
		if value ~= "0" and value ~= "1" then
			luup.log("var.GetBoolean: wrong data value ("..(value or "")..") for variable "..(name or "unknown"), 2)
			return false
		end
		return (value == "1")
	end

	-- Get variable value as JSON type. Return decoded result
	local function _get_json(name, sid, device)
		local value = _get(name, sid, device)
		if value == "" then
			luup.log("var.GetJson: empty data value for variable "..(name or "unknown"), 2)
			return {}
		end
		local res, msg = json.decode(value)
		if res then 
			return res
		else
			luup.log("var.GetJson: failed to decode json ("..(value or "")..") for variable "..(name or "unknown"), 2)
			return {}
		end
	end

	-- Get variable value as single dimension array type. Return decoded result
	local function _get_set(name, sid, device)
		local value = _get(name, sid, device)
		if value == "" then
			luup.log("var.GetSet: empty data value for variable "..(name or "unknown"), 2)
			return {}
		end
		-- given a string of numbers s = "n, m, ..." convert to a set (for easy indexing)
		local set = {}
		for a in s: gmatch "%d+" do
			local n = tonumber (a)
			if n then set[n] = true end
		end
		return set
	end

	-- Set variable value
	local function _set(name, value, sid, device)
		if type(name) ~= "string" then
			luup.log("var.Set: variable name not a string.", 1)
			return false
		end	
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local old, ts = luup.variable_get(sid, name, device) or ""
		if (tostring(value) ~= tostring(old)) then 
			luup.variable_set(sid, name, value, device)
		end
		return true
	end

	-- Set string variable value. If value type is not a string, do not set.
	local function _set_string(name, value, sid, device)
		if type(value) ~= "string" then
			luup.log("var.SetString: wrong data type ("..type(value)..") for variable "..(name or "unknown"), 2)
			return false
		end
		return _set(name, value, sid, device)
	end

	-- Set number variable value. If value type is not a number, do not set.
	local function _set_num(name, value, sid, device)
		if type(value) ~= "number" then
			luup.log("var.SetNumber: wrong data type ("..type(value)..") for variable "..(name or "unknown"), 2)
			return false
		end
		return _set(name, value, sid, device)
	end

	-- Set boolean variable value. If value is not 0/1 or true/false, do not set.
	local function _set_bool(name, value, sid, device)
		if type(value) == "number" then
			if value == 1 or value == 0 then
				return _set(name, value, sid, device)
			else	
				luup.log("var.SetBoolean: wrong value. Expect 0/1.", 2)
				return false
			end
		elseif type(value) == "boolean" then
			return _set(name, (value and 1 or 0), sid, device)
		end
		luup.log("var.SetBoolean: wrong data type ("..type(value)..") for variable "..(name or "unknown"), 2)
		return false
	end

	-- Set json variable value. If value is not array, do not set.
	local function _set_json(name, value, sid, device)
		if type(value) ~= "table" then
			luup.log("var.SetJson: wrong data type ("..type(value)..") for variable "..(name or "unknown"), 2)
			return false
		end
		local jsd = json.encode(value) or "{}"
		return _set(name, jsd, sid, device)
	end

	-- create missing variable with default value or return existing
	local function _default(name, default, sid, device)
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local value, ts = luup.variable_get(sid, name, device) 
		if (not value) then
			value = default	or ""
			luup.variable_set(sid, name, value, device)	
		end
		return value
	end
	
	-- Get an attribute value, try to return as number value if applicable
	local function _getattr(name, device)
		local value = luup.attr_get(name, tonumber(device or def_dev))
		local nv = tonumber(value,10)
		return (nv or value)
	end

	-- Set an attribute
	local function _setattr(name, value, device)
		luup.attr_set(name, value, tonumber(device or def_dev))
	end
	
	return {
		Set = _set,
		SetString = _set_string,
		SetNumber = _set_num,
		SetBoolean = _set_bool,
		SetJson = _set_json,
		Get = _get,
		GetString = _get_string,
		GetNumber = _get_num,
		GetBoolean = _get_bool,
		GetJson = _get_json,
		GetSet = _get_set,
		Default = _default,
		GetAttribute = _getattr,
		SetAttribute = _setattr,
		Initialize = _init
	}
end

-- API to handle basic logging and debug messaging
local function logAPI()
local def_level = 1
local def_prefix = ""
local def_debug = false
local def_file = false
local max_length = 100
local onOpenLuup = false
local taskHandle = -1

	local function _update(level)
		if type(level) ~= "number" then level = def_level end
		if level >= 100 then
			def_file = true
			def_debug = true
			def_level = 10
		elseif level >= 10 then
			def_debug = true
			def_file = false
			def_level = 10
		else
			def_file = false
			def_debug = false
			def_level = level
		end
	end	

	local function _init(prefix, level, onol)
		_update(level)
		def_prefix = prefix
		onOpenLuup = onol
	end	
	
	-- Build loggin string safely up to given lenght. If only one string given, then do not format because of length limitations.
	local function prot_format(ln,str,...)
		local msg = ""
		local sf = string.format
		if arg[1] then 
			_, msg = pcall(sf, str, unpack(arg))
		else 
			msg = str or "no text"
		end 
		if ln > 0 then
			return msg:sub(1,ln)
		else
			return msg
		end	
	end	
	local function _log(...) 
		if (def_level >= 10) then
			luup.log(def_prefix .. ": " .. prot_format(max_length,...), 50) 
		end	
	end	
	
	local function _info(...) 
		if (def_level >= 8) then
			luup.log(def_prefix .. "_info: " .. prot_format(max_length,...), 8) 
		end	
	end	

	local function _warning(...) 
		if (def_level >= 2) then
			luup.log(def_prefix .. "_warning: " .. prot_format(max_length,...), 2) 
		end	
	end	

	local function _error(...) 
		if (def_level >= 1) then
			luup.log(def_prefix .. "_error: " .. prot_format(max_length,...), 1) 
		end	
	end	

	local function _debug(...)
		if def_debug then
			luup.log(def_prefix .. "_debug: " .. prot_format(-1,...), 50) 
			if def_file then
				local fh = io.open("/tmp/rboer_plugin.log","a")
				local msg = os.date("%d/%m/%Y %X") .. ": " .. prot_format(-1,...)
				fh:write(msg)
				fh:write("\n")
				fh:close()
			end
		end	
	end
	
	-- Write to file for detailed analisys
	local function _logfile(...)
		if def_file then
			local fh = io.open("/tmp/rboer_plugin.log","a")
			local msg = os.date("%d/%m/%Y %X") .. ": " .. prot_format(-1,...)
			fh:write(msg)
			fh:write("\n")
			fh:close()
		end	
	end
	
	local function _devmessage(devID, status, timeout, ...)
		local message = prot_format(60,...) or ""
		-- On Vera the message must be an exact repeat to erase, on openLuup it must be empty.
		if onOpenLuup and status == -2 then
			message = ""
		end
		-- If Vera firmware is < 7.30 then use task instead.
		if not onOpenLuup and not luup.short_version then
			taskHandle = luup.task(message, status, def_prefix, taskHandle)
			if timeout ~= 0 then
				luup.call_delay("logAPI_clearTask", timeout, "", false)
			else
				taskHandle = -1
			end
		else
			luup.device_message(devID, status, message, timeout, def_prefix)
		end	
	end
	
	local function logAPI_clearTask()
		luup.task("", 4, def_prefix, taskHandle)
		taskHandle = -1
	end
	_G.logAPI_clearTask = logAPI_clearTask
	
	return {
		Initialize = _init,
		Error = _error,
		Warning = _warning,
		Info = _info,
		Log = _log,
		Debug = _debug,
		Update = _update,
		LogFile = _logfile,
		DeviceMessage = _devmessage
	}
end 

-- API to handle some Util functions
local function utilsAPI()
local floor = math.floor
local _UI5 = 5
local _UI6 = 6
local _UI7 = 7
local _UI8 = 8
local _OpenLuup = 99

	local function _init()
	end	

	local function enforceByte(r)
		if r<0 then 
			r=0 
		elseif r>255 then 
			r=255 
		end
		return r
	end

	-- See what system we are running on, some Vera or OpenLuup
	local function _getui()
		if luup.attr_get("openLuup",0) ~= nil then
			return _OpenLuup
		else
			return luup.version_major
		end
		return _UI7
	end
	
	local function _getmemoryused()
		return floor(collectgarbage "count")         -- app's own memory usage in kB
	end
	
	local function _setluupfailure(status,devID)
		if luup.version_major < 7 then status = status ~= 0 end        -- fix UI5 status type
		luup.set_failure(status,devID)
	end

	-- Luup Reload function for UI5,6 and 7
	local function _luup_reload()
		if luup.version_major < 6 then 
			luup.call_action("urn:micasaverde-com:serviceId:HomeAutomationGateway1", "Reload", {}, 0)
		else
			luup.reload()
		end
	end
	
	-- Round up or down to whole number.
	local function _round(n)
		return floor((floor(n*2) + 1)/2)
	end

	local function _split(source, deli)
		local del = deli or ","
		local elements = {}
		local pattern = "([^"..del.."]+)"
		string.gsub(source, pattern, function(value) elements[#elements + 1] = value end)
		return elements
	end
  
	local function _join(tab, deli)
		local del = deli or ","
		return table.concat(tab, del)
	end
	
	local function _rgb_to_cie(red, green, blue) -- Thanks to amg0
		-- Apply a gamma correction to the RGB values, which makes the color more vivid and more the like the color displayed on the screen of your device
		red = tonumber(red)
		green = tonumber(green)
		blue = tonumber(blue)
		red 	= (red > 0.04045) and ((red + 0.055) / (1.0 + 0.055))^2.4 or (red / 12.92)
		green 	= (green > 0.04045) and ((green + 0.055) / (1.0 + 0.055))^2.4 or (green / 12.92)
		blue 	= (blue > 0.04045) and ((blue + 0.055) / (1.0 + 0.055))^2.4 or (blue / 12.92)

		-- //RGB values to XYZ using the Wide RGB D65 conversion formula
		local X = red * 0.664511 + green * 0.154324 + blue * 0.162028
		local Y = red * 0.283881 + green * 0.668433 + blue * 0.047685
		local Z = red * 0.000088 + green * 0.072310 + blue * 0.986039

		-- //Calculate the xy values from the XYZ values
		local x1 = floor( 10000 * (X / (X + Y + Z)) )/10000  --.toFixed(4);
		local y1 = floor( 10000 * (Y / (X + Y + Z)) )/10000  --.toFixed(4);
		return x1, y1
	end	

	local function _cie_to_rgb(x, y, brightness) -- Thanks amg0
		-- //Set to maximum brightness if no custom value was given (Not the slick ECMAScript 6 way for compatibility reasons)
		-- debug(string.format("cie_to_rgb(%s,%s,%s)",x, y, brightness or ""))
		x = tonumber(x)
		y = tonumber(y)
		brightness = tonumber(brightness)
	
		if (brightness == nil) then brightness = 254 end

		local z = 1.0 - x - y
		local Y = floor( 100 * (brightness / 254)) /100	-- .toFixed(2);
		local X = (Y / y) * x
		local Z = (Y / y) * z

		-- //Convert to RGB using Wide RGB D65 conversion
		local red 	=  X * 1.656492 - Y * 0.354851 - Z * 0.255038
		local green	= -X * 0.707196 + Y * 1.655397 + Z * 0.036152
		local blue 	=  X * 0.051713 - Y * 0.121364 + Z * 1.011530

		-- //If red, green or blue is larger than 1.0 set it back to the maximum of 1.0
		if (red > blue) and (red > green) and (red > 1.0) then
			green = green / red
			blue = blue / red
			red = 1.0
		elseif (green > blue) and (green > red) and (green > 1.0) then
			red = red / green
			blue = blue / green
			green = 1.0
		elseif (blue > red) and (blue > green) and (blue > 1.0) then
			red = red / blue
			green = green / blue
			blue = 1.0
		end

		-- //Reverse gamma correction
		red 	= (red <= 0.0031308) and (12.92 * red) or (1.0 + 0.055) * (red^(1.0 / 2.4)) - 0.055
		green 	= (green <= 0.0031308) and (12.92 * green) or (1.0 + 0.055) * (green^(1.0 / 2.4)) - 0.055
		blue 	= (blue <= 0.0031308) and (12.92 * blue) or (1.0 + 0.055) * (blue^(1.0 / 2.4)) - 0.055

		-- //Convert normalized decimal to decimal
		red 	= _round(red * 255)
		green 	= _round(green * 255)
		blue 	= _round(blue * 255)
		return enforceByte(red), enforceByte(green), enforceByte(blue)
	end

	local function _hsb_to_rgb(h, s, v) -- Thanks amg0
		h = tonumber(h or 0) / 65535
		s = tonumber(s or 0) / 254
		v = tonumber(v or 0) / 254
		local r, g, b, i, f, p, q, t
		i = floor(h * 6)
		f = h * 6 - i
		p = v * (1 - s)
		q = v * (1 - f * s)
		t = v * (1 - (1 - f) * s)
		if i==0 then
			r = v
			g = t
			b = p
		elseif i==1 then
			r = q
			g = v
			b = p
		elseif i==2 then
			r = p
			g = v
			b = t
		elseif i==3 then
			r = p
			g = q
			b = v
		elseif i==4 then
			r = t
			g = p
			b = v
		elseif i==5 then
			r = v
			g = p
			b = q
		end
		return _round(r * 255), _round(g * 255), _round(b * 255)
	end

	local function _set_display_line(value, line, dev)
		local name = "DisplayLine"..(line==2 and "2" or "1")
		var.Set(name, value, SID.altui, dev)
	end		

	
	-- Make a true copy of table.
	local function _deepcopy(orig)
		local orig_type = type(orig)
		local copy
		if orig_type == 'table' then
			copy = {}
			for orig_key, orig_value in next, orig, nil do
				copy[_deepcopy(orig_key)] = _deepcopy(orig_value)
			end
			setmetatable(copy, _deepcopy(getmetatable(orig)))
		else -- number, string, boolean, etc
			copy = orig
		end
		return copy
	end
	
	-- Remove the non-nil IDs from remv from the list
	local function _purge_list(list, remv)
		local newList = {}
		for id, val in pairs(list) do
			if not remv[id] then
				newList[id] = val
			end
		end
        return newList
	end

	return {
		Initialize = _init,
		ReloadLuup = _luup_reload,
		Round = _round,
		GetMemoryUsed = _getmemoryused,
		SetLuupFailure = _setluupfailure,
		Split = _split,
		Join = _join,
		PurgeList = _purge_list,
		DeepCopy = _deepcopy,
		RgbToCie = _rgb_to_cie,
		CieToRgb = _cie_to_rgb,
		HsbToRgb = _hsb_to_rgb,
		SetDisplayLine = _set_display_line,
		GetUI = _getui,
		IsUI5 = _UI5,
		IsUI6 = _UI6,
		IsUI7 = _UI7,
		IsUI8 = _UI8,
		IsOpenLuup = _OpenLuup
	}
end 

-- Wrapper for more solid handling for cjson as it trows a bit more errors that I'd like.
local function jsonAPI()
local is_cj, is_dk

	local function _init()
		is_cj = type(cjson) == "table"
		is_dk = type(dkson) == "table"
	end
	
	local function _decode(data)
		if is_cj then
			local ok, res = pcall(cjson.decode, data)
			if ok then return res end
		end
		local res, pos, msg = dkjson.decode(data)
		return res, msg
	end
	
	local function _encode(data)
		-- No special chekcing required as we must pass valid data our selfs
		if is_cj then
			return cjson.encode(data)
		else
			return dkjson.encode(data)
		end
	end
	
	return {
		Initialize = _init,
		decode = _decode,
		encode = _encode
	}
end



--[[ Map Ezlo known device type, category and subcategory to a Vera device type
 First looked in plugins\zwave\scripts\helpers\device_info_detection\device_class_based and icon_based

  Needed for mapping in create devices step
	category_num
	device_type
	device_json
	device_file
	subcategory_num (optional)
	states

Not (fully) supported:
	- Camera is not supported
	- Door Lock, only Lock/Unlock supported. PIN code handling is not
	- HVAC not fully supported due to difference in the two platfoms
	
Look at devices in plugins\zwave\scripts\resource to see the items that go with a device.

]]
local EzloDeviceMapping = {
	dimmable_light = {
			device_type = "urn:schemas-upnp-org:device:DimmableLight:1", 
			device_file = "D_DimmableLight1.xml", 
			device_json = "D_DimmableLight1.json", 
			category_num = 2,  	
			dimmable_bulb = {subcategory_num = 1},
			dimmable_plugged = {subcategory_num = 2},
			dimmable_in_wall = {subcategory_num = 3},
			dimmable_colored = {subcategory_num = 4}
	},
	switch = {
			device_type = "urn:schemas-upnp-org:device:BinaryLight:1", 
			device_file = "D_BinaryLight1.xml", 
			device_json = "D_BinaryLight1.json", 
			category_num = 3,
			interior_plugin = {subcategory_num = 1},
--			exterior = {subcategory_num = 2},
			in_wall = {subcategory_num = 3},
--			refrigerator = {subcategory_num = 4},
			valve = {subcategory_num = 7},
			relay = {subcategory_num = 8}
	},	
	garage_door = {
			device_type = "urn:schemas-upnp-org:device:BinaryLight:1", 
			device_file = "D_BinaryLight1.xml", 
			device_json = "D_GarageDoor1.json", 
			category_num = 3,  	-- Could now be 32 with sub_cat 0 (none)?
			subcategory_num = 5
		},
	security_sensor = {
			device_type = "urn:schemas-micasaverde-com:device:GenericSensor:1", 
			device_file = "D_GenericSensor1.xml", 
			device_json = "D_GenericSensor1.json", 
			category_num = 4,
			door = {
				device_type = "urn:schemas-micasaverde-com:device:DoorSensor:1",
				device_file = "D_DoorSensor1.xml", 
				device_json = "D_DoorSensor1.json", 
				subcategory_num = 1
			},
			leak = {
				device_type = "urn:schemas-micasaverde-com:device:TempLeakSensor:1",
				device_file = "D_TempLeakSensor1.xml", 
				device_json = "D_LeakSensor1.json", 
				subcategory_num = 2
			},
			motion = {
				device_type = "urn:schemas-micasaverde-com:device:MotionSensor:1",
				device_file = "D_MotionSensor1.xml", 
				device_json = "D_MotionSensor1.json", 
				subcategory_num = 3
			},
			smoke = {
				device_type = "urn:schemas-micasaverde-com:device:SmokeSensor:1",
				device_file = "D_SmokeSensor1.xml", 
				device_json = "D_SmokeSensor1.json", 
				subcategory_num = 4
			},
			co = {
				device_type = "urn:schemas-micasaverde-com:device:SmokeSensor:1",
				device_file = "D_SmokeSensor1.xml", 
				device_json = "D_COSensor1.json", 
				subcategory_num = 5
			},
			glass = {
				device_type = "urn:schemas-micasaverde-com:device:MotionSensor:1",
				device_file = "D_MotionSensor1.xml", 
				device_json = "D_GlassBreakSensor1.json", 
				subcategory_num = 6
			},
			freeze = {
				device_type = "urn:schemas-micasaverde-com:device:FreezeSensor:1",
				device_file = "D_FreezeSensor1.xml", 
				device_json = "D_FreezeSensor1.json", 
				subcategory_num = 7
			},
			binary = {
				device_type = "urn:schemas-micasaverde-com:device:DoorSensor:1",
				device_file = "D_DoorSensor1.xml", 
				device_json = "D_DoorSensor1.json", 
				subcategory_num = 8
			},
			co2 = {	-- Not a native Vera type
				device_type = "urn:schemas-micasaverde-com:device:SmokeSensor:1",
				device_file = "D_SmokeSensor1.xml", 
				device_json = "D_COSensor1.json", 
				subcategory_num = 5
			},
			gas = {	-- Not a native Vera type
				device_type = "urn:schemas-micasaverde-com:device:SmokeSensor:1",
				device_file = "D_SmokeSensor1.xml", 
				device_json = "D_SmokeSensor1.json", 
				subcategory_num = 4
			},
			heat = {-- Not a native Vera type
				device_type = "urn:schemas-micasaverde-com:device:FreezeSensor:1",
				device_file = "D_FreezeSensor1.xml", 
				device_json = "D_FreezeSensor1.json", 
				subcategory_num = 7
			}
	},
	hvac = {
			device_type = "urn:schemas-upnp-org:device:HVAC_ZoneThermostat:1", 
			device_file = "D_HVAC_ZoneThermostat1.xml", 
			device_json = "D_HVAC_ZoneThermostat1.json", 
			category_num = 5,
			hvac = { subcategory_num = 1 },
			heater = {
				device_type = "urn:schemas-upnp-org:device:Heater:1",
				device_file = "D_Heater1.xml", 
				device_json = "D_Heater1.json", 
				subcategory_num = 2
			}
	},
	camera = nil, -- No Ezlo equivalent category_num = 6
	door_lock = { 
			device_type = "urn:schemas-micasaverde-com:device:DoorLock:1", 
			device_file = "D_DoorLock1.xml", 
			device_json = "D_DoorLock1.json", 
			category_num = 7
	},
	window_cov = {
			device_type = "urn:schemas-micasaverde-com:device:WindowCovering:1", 
			device_file = "D_WindowCovering1.xml", 
			device_json = "D_WindowCovering1.json", 
			category_num = 8,  
			window_cov = { subcategory_num = 1 }
	},
	remote_control = {
			device_type = "urn:schemas-micasaverde-com:device:RemoteControl:1", 
			device_file = "D_RemoteControl1.xml", 
			device_json = "D_SceneController1.json", 
			category_num = 9
	},
	ir_transmitter = nil, --  No Ezlo equivalent category_num = 10
	generic_io = {
			device_type = "urn:schemas-micasaverde-com:device:GenericIO:1",
			device_file = "D_GenericIO1.xml", 
			device_json = "D_GenericIO1.json", 
			category_num = 11,  
			generic_io = { subcategory_num = 1 },
			repeater = { subcategory_num = 2 }
	},
	generic_sensor = {
			device_type = "urn:schemas-micasaverde-com:device:GenericSensor:1", 
			device_file = "D_GenericSensor1.xml", 
			device_json = "D_GenericSensor1.json", 
			category_num = 12
	},
	serial_port = {
			device_type = "urn:micasaverde-org:device:SerialPort:1", 
			device_file = "D_SerialPort1.xml", 
			device_json = "generic_device.json", -- a guess.
			category_num = 13
	},
	scene_controller = {
			device_type = "urn:schemas-micasaverde-com:device:SceneController:1", 
			device_file = "D_SceneController1.xml", 
			device_json = "D_SceneController1.json", 
			category_num = 14
	},
	av = {	-- Only has a load of actions
			device_type = "urn:schemas-micasaverde-com:device:avmisc:1", 
			device_file = "D_AvMisc1.xml", 
			device_json = "generic_device.json", -- a guess. 
			category_num = 15
	},
	humidity = {
			device_type = "urn:schemas-micasaverde-com:device:HumiditySensor:1", 
			device_file = "D_HumiditySensor1.xml", 
			device_json = "D_HumiditySensor1.json", 
			category_num = 16
	},
	temperature = {
			device_type = "urn:schemas-upnp-org:service:TemperatureSensor:1", 
			device_file = "D_TemperatureSensor1.xml", 
			device_json = "D_TemperatureSensor1.json", 
			category_num = 17
	},
	light_sensor = {
			device_type = "urn:schemas-micasaverde-com:device:LightSensor:1", 
			device_file = "D_LightSensor1.xml", 
			device_json = "D_LightSensor1.json", 
			category_num = 18
	},
	z_wave_interface = nil,-- category_num = 19
	insteon_interface = nil,-- category_num = 20
	power_meter = {
			device_type = "urn:schemas-micasaverde-com:device:PowerMeter:1", 
			device_file = "D_PowerMeter1.xml", 
			device_json = "D_PowerMeter1.json", 
			category_num = 21
	},
	alarm_panel = nil,-- category_num = 22
	alarm_partition = nil,-- category_num = 23
	siren = {
			device_type = "urn:schemas-micasaverde-com:device:Siren:1", 
			device_file = "D_Siren1.xml", 
			device_json = "D_Siren1.json", 
			category_num = 24,
	},
	weather = {	-- Baromethic Pressure, map to generic sensor
			device_type = "urn:schemas-micasaverde-com:device:GenericSensor:1", 
			device_file = "D_GenericSensor1.xml", 
			device_json = "D_GenericSensor1.json", 
			category_num = 25
	},
	philips_controller = nil,-- category_num = 26
	appliance = { -- map to generic IO
			device_type = "urn:schemas-micasaverde-com:device:GenericIO:1",
			device_file = "D_GenericIO1.xml", 
			device_json = "D_GenericIO1.json", 
			category_num = 27
	},
	uv_sensor = {
			device_type = "urn:schemas-micasaverde-com:device:LightSensor:1", 
			device_file = "D_LightSensor1.xml", 
			device_json = "D_UVSensor1.json", 
			category_num = 28
	},
	mouse_trap = {
			device_type = "urn:schemas-micasaverde-com:device:MouseTrap:1", 
			device_file = "D_MouseTrap1.xml", 
			device_json = "D_MouseTrap1.json", 
			category_num = 29
	},
	doorbell = { 
			device_type = "urn:schemas-micasaverde-com:device:Doorbell:1", 
			device_file = "D_Doorbell1.xml", 
			device_json = "D_Doorbell1.json", 
			category_num = 30 
	},
	keypad = {
			states = { },
			device_type = "urn:schemas-micasaverde-com:device:Keypad:1", 
			device_file = "D_Keypad1.xml", 
			device_json = "D_Keypad1.json", 
			category_num = 31
	},
	flow_meter = {
			device_type = "urn:schemas-micasaverde-com:device:GenericSensor:1", 
			device_file = "D_GenericSensor1.xml", 
			device_json = "D_GenericSensor1.json", 
			category_num = 33
	},
	voltage_sensor = {
			device_type = "urn:schemas-micasaverde-com:device:GenericSensor:1", 
			device_file = "D_GenericSensor1.xml", 
			device_json = "D_GenericSensor1.json", 
			category_num = 34
	},
	level_sensor = {	-- Vera does not have level sensors. Map to GenericSensor.
			device_type = "urn:schemas-micasaverde-com:device:GenericSensor:1", 
			device_file = "D_GenericSensor1.xml", 
			device_json = "D_GenericSensor1.json", 
			category_num = 12,
			co = {},
			co2 = {},
			current = {},
			capacity = {},
			navigation = {},
			health = {}, -- Blood Pressure, Body Mass, BMI
			electricity = {},  -- Electrical Conductivity/restistance Sensor
			air_pollution = {},
			frequency = {},
			sound = {},
			moisture = {},
			particulate_matter = {},
			modulation = {},
			seismicity = {},
			smoke = {},
			soil = {},
			["time"] = {},
			velocity = {},
			water = {},
			capacity = {} -- Weight
	},
	state_sensor = {
			device_type = "urn:schemas-micasaverde-com:device:GenericSensor:1", 
			device_file = "D_GenericSensor1.xml", 
			device_json = "D_GenericSensor1.json", 
			category_num = 12,
			moisture = {},
			freeze = {},
			rain = {},
			power = {}
	},
	["clock"] = nil,
	unknown = {  -- If device is not recognized by Ezlo/ATHOM
			device_type = "urn:schemas-micasaverde-com:device:GenericSensor:1", 
			device_file = "D_GenericSensor1.xml", 
			device_json = "D_GenericSensor1.json", 
			category_num = 12
	}
}

-- Map Ezlo device items name to Vera. To udate device variables.
-- From plugins\zwave\scripts\model\items\default
-- If item hasGetter = true, then we can expect value updates.
-- If item hasSetter = true, then there is an action.
-- Value can be bool, string, number, enum or scalar ({value = 0, scale = "ohm_meter"})
-- Maybe we can just set exceptions like EnergyMetering and BatteryLevel items that can be on many device types
-- Although for sensors we may need to do mapping for scalar item values.
-- To ignore an item use {}
-- Undefined items will map to a Generic sensor and will write to DisplayLine1.
local EzloItemsMapping = {
	ac_state = {}, 
	acceleration_x_axis = {service = SID.gen_sensor, variable = "AccelerationXAxis"},
	acceleration_y_axis = {service = SID.gen_sensor, variable = "AccelerationYAxis"},
	acceleration_z_axis = {service = SID.gen_sensor, variable = "AccelerationZAxis"},
	air_flow = {service = SID.gen_sensor, variable = "AirFlow"},
	angle_position = {service = SID.gen_sensor, variable = "AnglePosition"},
	appliance_status = {service = SID.gen_sensor, variable = "ApplianceStatus"}, 
	armed = {service = SID.sec_sensor, variable = "Armed"}, -- Is a value at the device level, not an item.
	atmospheric_pressure = {service = SID.gen_sensor, variable = "AtmosphericPressure"},
	aux_binary = {service = SID.gen_sensor, variable = "AuxBinary"},
	barometric_pressure = {service = SID.gen_sensor, variable = "BarometricPressure"},
	barrier = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "barrier_opened"}, -- Also has Setter
	barrier_fail_events = {service = SID.gen_sensor, variable = "BarrierFailEvents"},
	barrier_problem_sensors = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "low_battery"},
	barrier_state = {},-- only has Setter.
	barrier_unattended_operation = {service = SID.gen_sensor, variable = "BarrierUnattendedOperation"},
	basal_metabolic_rate = {service = SID.gen_sensor, variable = "BasalMetabolicRate"},
	basic = {}, -- Not sure what it does, Ignoring , type boolean
	battery = { service = SID.had, variable = "BatteryLevel" },
	battery_backup = { service = SID.had, variable = "BatteryBackup"}, 
	battery_charging_state = { service = SID.had, variable = "BatteryChargingState"},
	battery_maintenance_state = { service = SID.had, variable = "BatteryMaintenanceState"}, 
	blood_pressure = {service = SID.gen_sensor, variable = "BloodPressure"}, 
	body_mass = {service = SID.gen_sensor, variable = "BodyMass"}, 
	body_mass_index = {service = SID.gen_sensor, variable = "BodyMassIndex"}, 
	boiler_water_temperature = {service = SID.temp_sensor, variable = "CurrentTemperature"}, 
	button_state = {}, -- scalar {button_number = N, buttons_state = enum {"press_1_time", "held_down", "released"})
	clock_state = {service = SID.gen_sensor, variable = "ClockState"},
	co_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "co_detected"}, 
	co_level = {service = SID.gen_sensor, variable = "CurrentLevel"},
	co2_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "co2_detected"}, 
	co2_level = {service = SID.gen_sensor, variable = "CurrentLevel"},
	current = {service = SID.gen_sensor, variable = "Current"},
	daily_user_code_intervals = {}, -- ??
	dew_point = {service = SID.gen_sensor, variable = "DewPoint"},
	digital_input_state = {}, -- ??
--	dimmer = {service = SID.dimming, variable = "LoadLevelStatus"},
	dimmer = {service = SID.dimming, variable = "LoadLevelTarget"},
	dimmer_down = {}, -- int (action)
	dimmer_stop = {}, -- int (action)
	dimmer_up = {}, -- int (action)
	direction = {service = SID.gen_sensor, variable = "Direction"},
	distance = {service = SID.gen_sensor, variable = "Distance"},
	domestic_hot_water_temperature = {service = SID.temp_sensor, variable = "CurrentTemperature"},
	door_lock = {}, -- unsecured, unsecured_with_timeout, unsecured_for_inside, unsecured_for_inside_with_timeout, unsecured_for_outside, unsecured_for_outside_with_timeout, unknown, secured
	dust_in_device = {service = SID.sec_sensor, variable = "DustInDevice"},
	dw_handle_state = {service = SID.sec_sensor, variable = "HandleState"},
	dw_state = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "dw_is_opened"},
	electric_meter_amper = {service = SID.energy, variable = "Amps"},
	electric_meter_factor = {service = SID.energy, variable = "Factor"},
	electric_meter_kvah = {service = SID.energy, variable = "KVAH"},
	electric_meter_kvar = {service = SID.energy, variable = "KVAR"},
	electric_meter_kvarh = {service = SID.energy, variable = "KVARH"},
	electric_meter_kwh = {service = SID.energy, variable = "KWH"},
	electric_meter_kwh_week = {service = SID.energy, variable = "WeekKWH"},
	electric_meter_kwh_month = {service = SID.energy, variable = "MonthKWH"},
	electric_meter_kwh_year = {service = SID.energy, variable = "YearKWH"},
	electric_meter_kwh_life = {service = SID.energy, variable = "LifeKWH"},
	electric_meter_pulse = {service = SID.energy, variable = "Pulse"},
	electric_meter_volt = {service = SID.energy, variable = "Volts"},
	electric_meter_watt = {service = SID.energy, variable = "Watts"},
	electrical_conductivity = {service = SID.energy, variable = "ElectricalConductivity"},
	electrical_resistance = {service = SID.energy, variable = "ElectricalResistance"},
	emergency_shutoff = {}, -- ??
	entered_code_status =  {}, -- ??
	exhaust_temperature = {service = SID.temp_sensor, variable = "CurrentTemperature"},
	fat_mass = {service = SID.gen_sensor, variable = "FatMass"},
	formaldehyde_level = {service = SID.gen_sensor, variable = "FormaldehydeLevel"},
	freeze_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "freeze_detected"}, 
	frequency = {service = SID.gen_sensor, variable = "Frequency"}, 
	gas_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "gas_detected"}, -- ??
	glass_breakage_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "glass_breakage"}, 
	goto_favorite = {}, -- Only has Setter.
	heat_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "overheat_detected"}, 
	heat_rate = {service = SID.gen_sensor, variable = "HeatRate"},
	heat_rate_lf_hf_ratio = {service = SID.gen_sensor, variable = "HeatRateLfHfRatio"},
	humidity = {service = SID.hum_sensor, variable = "Humidity"},
	hw_state = {service = SID.gen_sensor, variable = "HwState"},
	intrusion_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "intrusion"},
	keypad_state = {service = SID.door_lock, variable = "Status"},
	kwh_reading_timestamp = {service = SID.energy, variable = "KWHReading"},
	light_alarm = {service = SID.sec_sensor, variable = "Tripped"},
	light_color_transition = {service = SID.gen_sensor, variable = "LightColorTransition"},
	load_error_state = {service = SID.gen_sensor, variable = "LoadErrorState"},
	lock_operation = {service = SID.door_lock, variable = "Status"}, -- needs details
	loudness = {service = SID.gen_sensor, variable = "Loudness"},
	lux = {service = SID.light_sensor, variable = "Lux"},
	maintenance_state = {service = SID.gen_sensor, variable = "MaintenanceState"},
	master_code = {service = SID.gen_sensor, variable = "MasterCode"},
	master_code_state = {service = SID.gen_sensor, variable = "MasterCodeState"},
	master_water_valve_current_alarm = {service = SID.gen_sensor, variable = "MasterWaterValveCurrentAlarm"},
	master_water_valve_short_circuit = {service = SID.gen_sensor, variable = "MasterWaterValveShortCircuit"},
	master_water_valve_state = {service = SID.gen_sensor, variable = "MasterWaterValveState"}, -- maybe switch like. Can have Setter
	meter_reset = {}, -- Action only 
	methane_density = {service = SID.gen_sensor, variable = "MethaneDensity"},
	moisture = {service = SID.gen_sensor, variable = "Moisture"},
	moisture_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "moisture_detected"},
	motion = {service = SID.gen_sensor, variable = "Motion"},
	motion_status = {service = SID.gen_sensor, variable = "MotionStatus"},
	muscle_mass = {service = SID.gen_sensor, variable = "MuscleMass"},
	outside_temperature = {service = SID.temp_sensor, variable = "CurrentTemperature"},
	over_current_state = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "over_current_detected"},
	over_load_state = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "over_load_detected"},
	over_voltage_state = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "over_voltage_detected"},
	particulate_matter_2_dot_5 = {service = SID.gen_sensor, variable = "ParticulateMatter2Dot5"},
	particulate_matter_10 = {service = SID.gen_sensor, variable = "ParticulateMatter10"},
	pest_control = {service = SID.gen_sensor, variable = "PestControl"},
	position = {service = SID.gen_sensor, variable = "Position"},
--	power = {service = SID.energy, variable = "Watts"},
	power = {}, -- Ignore for now. Seems dup for electric_meter_watt
	power_state = {service = SID.gen_sensor, variable = "PowerState"},
	power_surge_state = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "power_surge_detected"}, -- Is a guessed value
	product_moving_status = {service = SID.gen_sensor, variable = "ProductMovingStatus"},
	program_failures = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "failed"},
	program_status = {service = SID.gen_sensor, variable = "ProgramStatus"},
	radon_concentration = {service = SID.gen_sensor, variable = "RadonConcentration"},
	rain_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "rain"},
	rain_rate = {service = SID.gen_sensor, variable = "RainRate"},
	relative_modulation_level = {service = SID.gen_sensor, variable = "RelativeModulationLevel"}, 
	remaining_time = {service = SID.gen_sensor, variable = "RemainingTime"},
	respiratory_rate = {service = SID.gen_sensor, variable = "RespiratoryRate"}, 
	rf_signal_strength = {service = SID.gen_sensor, variable = "RfSignalStrength"}, 
	rgb_color = {service = SID.color, variable = "CurrentColor"}, -- rgb variable handled in code.
	rotation = {service = SID.gen_sensor, variable = "Rotation"}, 
	security_threat = {}, -- Not sure what to do with this. Is on security sensors.
	seismic_intensity = {service = SID.gen_sensor, variable = "SeismicIntensity"}, 
	seismic_magnitude = {service = SID.gen_sensor, variable = "SeismicMagnitude"}, 
	sensor_binary = {}, -- ?? need to see as there is no items code.
	shutter_commands = {}, -- Actions only, for installation or so.
	shutter_states = {service = SID.gen_sensor, variable = "ShutterStates"}, -- Bit odd values, for installation or so.
	siren_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "siren"},
	sleep_apnea = {service = SID.gen_sensor, variable = "SleepApnea"}, 
	sleep_stage = {service = SID.gen_sensor, variable = "SleepStage"}, 
	smoke_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "smoke_detected"},
	smoke_density = {service = SID.gen_sensor, variable = "SmokeDensity"}, 
	soil_humidity = {service = SID.gen_sensor, variable = "SoilHumidity"}, 
	soil_reactivity = {service = SID.gen_sensor, variable = "SoilReactivity"}, 
	soil_salinity = {service = SID.gen_sensor, variable = "SoilSalinity"}, 
	soil_temperature = {service = SID.temp_sensor, variable = "CurrentTemperature"}, 
	solar_radiation = {service = SID.gen_sensor, variable = "SolarRadiation"}, 
	sound_list = {service = SID.gen_sensor, variable = "SoundList"}, 
	sound_playback = {service = SID.gen_sensor, variable = "SoundPlayback"}, 
	sound_select = {service = SID.gen_sensor, variable = "SoundSelect"}, 
	sound_volume = {service = SID.gen_sensor, variable = "SoundVolume"}, 
	sounding_mode = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "audible"}, 
	sw_state = {service = SID.gen_sensor, variable = "SwState"}, 
	switch = {service = SID.switch_power, variable = "Status"}, 
	tampering_cover_alarm = {service = SID.sec_sensor, variable = "TamperAlarm", convert=function(value) return value == "no_tampering_cover" and 1 or 0 end}, 
	tampering_impact_alarm = {service = SID.sec_sensor, variable = "TamperImpactAlarm", convert=function(value) return value == "impact_detected" and 1 or 0 end}, 
	tampering_invalid_code_alarm = {service = SID.sec_sensor, variable = "TamperCodeAlarm", convert=function(value) return value == "invalid_code" and 1 or 0 end}, 
	tampering_move_alarm = {service = SID.sec_sensor, variable = "TamperMoveAlarm", convert=function(value) return value == "product_moved" and 1 or 0 end}, 
	tank_capacity = {service = SID.gen_sensor, variable = "TankCapacity"}, 
	target_temperature = {service = SID.temp_sensor, variable = "TargetTemperature"},
	temp = {service = SID.temp_sensor, variable = "CurrentTemperature"}, 
	temperature_changes = {service = SID.gen_sensor, variable = "TemperatureChanges"}, 
	test_state = {service = SID.gen_sensor, variable = "TestState"}, 
	thermostat_fan_mode = {service = SID.hvac_fom, variable = "Mode", convert=function(value, devID) 
			-- from Centralite_3157100: "fanmode_on", "fanmode_on_auto" ?
			-- Ezlo thermostat_fan_mode Enums (get/set): 
			-- "auto_low", "low", "auto_high", "high", "auto_medium", "medium", "circulation", "humidity_circulation", "left_and_right"
			-- "up_and_down", "quiet"
			-- Vera Mode allowedValues :
			--	"Auto", "ContinuousOn", "PeriodicOn"
			-- Should low/med/high values be mapped to Vera fanSpeed (0-100)?
			if value == "auto_low" or value == "auto_high" or value == "auto_medium" or value == "fanmode_on_auto" then
				return "Auto"
			elseif value == "low"  or value == "high"  or value == "medium" or value == "fanmode_on" then
				return "ContinuousOn"
			elseif value == 99 then	
				return "PeriodicOn" -- Does not seem supported on Ezlo
			end
			-- There are more options, Vera does not seem to support.
			return "Auto"
		end}, 
	thermostat_fan_state = {service = SID.hvac_fom, variable = "FanStatus", convert=function(value, devID)
			-- Ezlo thermostat_fan_state Enums (get): 
			-- "idle_off", "running_low", "running_high", "running_medium", "circulation_mode", "humidity_circulation_mode"
			-- "right_left_circulation_mode", "up_down_circulation_mode", "quiet_circulation_mode"
			-- Vera FanStatus allowedValues :
			--	"On", "Off"
			-- Should low/med/high values be mapped to Vera fanSpeed (0-100)?
			if value == "idle_off" then
				return "Off"
			else
				return "On" -- Not fully functional. Would need to look at FanSpeedStatus as well
			end	
		end},
	thermostat_mode = {service = SID.hvac_uom, variable = "ModeStatus", convert=function(value, devID)
			-- Ezlo thermostat_mode Enums (get/set): 
			--	"off", "heat", "cool", "aux", "resume", "fan_only", "furnace", "dry_air", "moist_air", "auto_change_over", 
			--	"energy_saving_heat", "energy_saving_cool", "away", "reserved", "full_power"
			-- Vera ModeStatus allowedValues :
			--	"Off", "HeatOn", "CoolOn", "AutoChangeOver", "AuxHeatOn", "EconomyHeatOn", "EmergencyHeatOn", "AuxCoolOn"
			-- 	"EconomyCoolOn", "BuildingProtection", "EnergySavingsMode"
			-- Vera EnergyModeTarget allowed values:
			--	"Normal", "EnergySavingsMode"
			if value == "off" then
				return "Off"
			elseif value == "heat" then
				return "HeatOn"
			elseif value == "energy_saving_heat" then
				return "EconomyHeatOn"
			elseif value == "cool" then
				return "CoolOn"
			elseif value == "energy_saving_cool" then
				return "EconomyCoolOn"
			elseif value == "auto_change_over" or value == "auto" then
				return "AutoChangeOver"
			end
			-- There are more options, Vera does not seem to support.
			return "Off"
		end}, 
	thermostat_operating_state = {service = SID.hvac_os, variable = "ModeState", convert=function(value, devID) 
			-- Ezlo thermostat_operating_state (get) Enums: 
			--	"idle", "heating", "cooling", "fan_only", "pending_heat", "pending_cool", "vent_economizer", "aux_heating"
			--	"2nd_stage_heating", "2nd_stage_cooling", "2nd_stage_aux_heat", "3rd_stage_aux_heat"
			-- Vera ModeStatus Allowed values:
			--	"Idle", "Heating", "Cooling", "FanOnly", "PendingHeat", "PendingCool", "Vent"
			if value == "idle" then
				return "Idle"
			elseif value == "fan_only" then
				return "FanOnly"
			elseif value == "pending_heat" then
				return "PendingHeat"
			elseif value == "pending_cool" then
				return "PendingCool"
			elseif value == "vent_economizer" then
				return "Vent"
			elseif value == "heating" or value == "2nd_stage_heating" or value == "aux_heating" or value == "2nd_stage_aux_heat" or value == "3rd_stage_aux_heat" then
				return "Heating"
			elseif value == "cooling" or value == "2nd_stage_cooling" then
				return "Cooling"
			end
			return "Idle"
		end},
	thermostat_setpoint = {service = SID.temp_setp, variable = "CurrentSetpoint"}, 
	thermostat_setpoint_cooling = {service = SID.temp_setpc, variable = "CurrentSetpoint"}, 
	thermostat_setpoint_heating = {service = SID.temp_setph, variable = "CurrentSetpoint"}, 
	tide_level = {service = SID.gen_sensor, variable = "TideLevel"}, 
	tilt = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "tilt"}, 
	time_period = {service = SID.gen_sensor, variable = "TimePeriod"}, 
	total_body_water = {service = SID.gen_sensor, variable = "TotalBodyWater"}, 
	ultraviolet = {service = SID.light_sensor, variable = "CurrentLevel"}, 
	user_code_operation = {service = SID.gen_sensor, variable = "UserCodeOperation"}, 
	user_codes = {service = SID.gen_sensor, variable = "UserCodes"}, 
	user_codes_scan_progress = {service = SID.gen_sensor, variable = "UserCodesScanProgress"}, 
	user_lock_operation = {service = SID.gen_sensor, variable = "UserLockOperation"}, 
	velocity = {service = SID.gen_sensor, variable = "Velocity"}, 
	voc_level_status = {service = SID.gen_sensor, variable = "VocLevelStatus"}, 
	volatile_organic_compound_level = {service = SID.gen_sensor, variable = "VolatileOrganicCompoundLevel"}, 
	voltage = {service = SID.gen_sensor, variable = "Voltage"}, 
	voltage_drop_drift_state = {service = SID.gen_sensor, variable = "VoltageDropDriftState"}, 
	water_acidity = {service = SID.gen_sensor, variable = "WaterAcidity"}, 
	water_chlorine_level = {service = SID.gen_sensor, variable = "WaterChlorineLevel"}, 
	water_filter_replacement_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "????"}, 
	water_flow = {service = SID.gen_sensor, variable = "WaterFlow"}, 
	water_flow_alarm = {service = SID.sec_sensor, variable = "Tripped","????"}, 
	water_leak_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "water_leak_detected"}, 
	water_level_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "????"}, 
	water_oxidation_reduction_potential = {service = SID.gen_sensor, variable = "WaterOxidationReductionPotential"}, 
	water_pressure = {service = SID.gen_sensor, variable = "WaterPressure"}, 
	water_pressure_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "????"}, 
	water_pump_state = {service = SID.gen_sensor, variable = "WaterPumpState"}, 
	water_temperature = {service = SID.temp_sensor, variable = "CurrentTemperature"}, 
	water_temperature_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "????"}, 
	water_valve_current_alarm = {service = SID.sec_sensor, variable = "Tripped", tripvalue = "????"}, 
	water_valve_short_circuit = {service = SID.gen_sensor, variable = "WaterValveShortCircuit"}, 
	water_valve_state = {service = SID.gen_sensor, variable = "WaterValveState"}, -- Might be switch like and can have Setter
	weekly_user_code_intervals = {service = SID.gen_sensor, variable = "WeeklyUserCodeIntervals"}, 
	weight = {service = SID.gen_sensor, variable = "Weight"}
}

-- Map a Vera action to the device or item we need to update on the Ezlo Hub.
-- We map by SID and action
local VeraActionMapping = {
	[SID.sec_sensor] = {
			["SetArmed"] = { fn = function(dev, params) return {{i="armed", m="hub.device.armed.set", p="armed", v=(params.newArmedValue == "1")}} end }
		},
	[SID.hvac_uom] = {
			-- ModeTarget Allowed values:
			--	"Off", "HeatOn", "CoolOn", "AutoChangeOver", "AuxHeatOn", "EconomyHeatOn", "EmergencyHeatOn", "AuxCoolOn"
			-- 	"EconomyCoolOn", "BuildingProtection", "EnergySavingsMode"
			-- EnergyModeTarget allowed values:
			--	"Normal", "EnergySavingsMode"
			-- SID.hvac_os ModeState allowed values:
			--	"Idle", "Heating", "Cooling", "FanOnly", "PendingHeat", "PendingCool", "Vent"
			
			-- Ezlo thermostat_mode Enums (get/set): 
			--	"off", "heat", "cool", "aux", "resume", "fan_only", "furnace", "dry_air", "moist_air", "auto_change_over", 
			--	"energy_saving_heat", "energy_saving_cool", "away", "reserved", "full_power"
			["SetModeTarget"] = { fn = function(dev, params)
									-- look at EnergyMode to see if that is on or not
									local eMode = var.GetString("EnergyModeStatus", SID.hvac_uom, dev) or "Normal"
									local mode
									if params.NewModeTarget == "Off" then
										mode = "off"
									elseif params.NewModeTarget == "CoolOn" or params.NewModeTarget == "EconomyCoolOn" then
										if eMode == "EnergySavingsMode" then
											mode = "energy_saving_cool" 
										else
											mode = "cool" 
										end
									elseif params.NewModeTarget == "HeatOn" or params.NewModeTarget == "EconomyHeatOn" then
										if eMode == "EnergySavingsMode" then
											mode = "energy_saving_heat" 
										else
											mode = "heat" 
										end
									elseif params.NewModeTarget == "AutoChangeOver" then
										mode = "auto_change_over"
									end
									local ret_t = {}
									local ti = table.insert
									ti(ret_t, {i="thermostat_mode", v=mode})
									-- Can have more parameters, return table?
									if params.NewHeatSetpoint then
										ti(ret_t, {i="thermostat_setpoint_heating", v=tonumber(params.NewHeatSetpoint) or 0})
									end
									if params.NewCoolSetpoint then
										ti(ret_t, {i="thermostat_setpoint_cooling", v=tonumber(params.NewCoolSetpoint) or 0})
									end
									return ret_t
								end 
				},
			["SetEnergyModeTarget"] = { fn = function(dev, params)
									-- look at Mode to see if that is on or not
									local ms = var.GetString("ModeStatus", SID.hvac_uom, dev) or "Off"
									local mode
									if ms == "CoolOn" then
										if params.NewModeTarget == "EnergySavingsMode" then
											mode = "energy_saving_cool" 
										else
											mode = "cool" 
										end
									elseif ms == "HeatOn" then
										if params.NewModeTarget == "EnergySavingsMode" then
											mode = "energy_saving_heat" 
										else
											mode = "heat" 
										end
									else
										mode = "off"
									end
									return {{i="thermostat_mode", v=mode}}
								end 
				}
		},
	[SID.hvac_fom] = {
			-- from Centralite_3157100: "fanmode_on", "fanmode_on_auto" ?
			-- Ezlo thermostat_fan_mode Enums (get/set): 
			-- "auto_low", "low", "auto_high", "high", "auto_medium", "medium", "circulation", "humidity_circulation", "left_and_right"
			-- "up_and_down", "quiet"
			-- Vera Mode allowedValues :
			--	"Auto", "ContinuousOn", "PeriodicOn"
			-- look at fanspeed for low/med/high values
			["SetMode"] = { fn = function(dev, params)
									local fs = var.GetNumber("FanSpeedStatus", SID.hvac_fs, dev)
									if fs == false then fs = 0 end
									local mode = "auto_low" -- is auto_low
									if params.NewMode == "Auto" then
										if fs < 31 then
											mode = "auto_low"
										elseif fs > 69 then
											mode = "auto_high"
										else
											mode = "auto_medium"
										end
									elseif params.NewMode == "ContinuousOn" then
										if fs < 31 then
											mode = "low"
										elseif fs > 69 then
											mode = "high"
										else
											mode = "medium"
										end
									elseif params.NewMode == "PeriodicOn" then
									end
									return {{i="thermostat_fan_mode", v=mode}}
								end 
				}
		},
	[SID.hvac_fs] = {
			-- from Centralite_3157100: "fanmode_on", "fanmode_on_auto" ?
			-- Ezlo thermostat_fan_mode Enums (get/set): 
			-- "auto_low", "low", "auto_high", "high", "auto_medium", "medium", "circulation", "humidity_circulation", "left_and_right"
			-- "up_and_down", "quiet"
			-- Vera Mode allowedValues :
			--	"Auto", "ContinuousOn", "PeriodicOn"
			-- look at fanspeed for low/med/high values
			["SetFanSpeed"] = { fn = function(dev, params)
									local fm = var.GetString("FanStatus", SID.hvac_fom, dev) or "Auto"
									local fs = tonumber(params.NewFanSpeedTarget) or 0
									local mode = "auto_low" -- is auto_low
									if fm == "Auto" then
										if fs < 31 then
											mode = "auto_low"
										elseif fs > 69 then
											mode = "auto_high"
										else
											mode = "auto_medium"
										end
									elseif fm == "ContinuousOn" then
										if fs < 31 then
											mode = "low"
										elseif fs > 69 then
											mode = "high"
										else
											mode = "medium"
										end
									elseif fm == "PeriodicOn" then
									end
									return {{i="thermostat_fan_mode", v=mode}}
								end 
				},
			["SetFanDirection"] = { fn = function(dev, params)
									-- no equivalent.
									local dt = tonumber(params.NewDirectionTarget) or 0
									return nil
								end 
				}
		},
	[SID.temp_setph] = {
			["SetCurrentSetpoint"] = { fn = function(dev, params)
									return {{i="thermostat_setpoint_heating", v=tonumber(params.NewCurrentSetpoint) or 0}}
								end 
				}
		},
	[SID.temp_setpc] = {
			["SetCurrentSetpoint"] = { fn = function(dev, params) 
									return {{i="thermostat_setpoint_cooling", v=tonumber(params.NewCurrentSetpoint) or 0}}
								end 
				}
		},
	[SID.temp_setp] = {
			["SetCurrentSetpoint"] = { fn = function(dev, params) 
									return {{i="thermostat_setpoint", v=tonumber(params.NewCurrentSetpoint) or 0}}
								end 
				}
		},
	[SID.door_lock] = {
			["SetTarget"] = { fn = function(dev, params) 
									return {{i="door_lock", v=(params.newTargetValue == "1" and "lock" or "unlock")}}
								end 
				},
			["SetPin"] = { fn = function(dev, params)
									--[[ Need to set: door_??
									params.UserCodeName
									params.newPin
									params.user
									params.purge
									params.json
									params.SetPinValidityDate 
									params.SetPinValidityWeekly 
									]]
									return nil
								end 
				},
			["SetPinValidityDate"] = { fn = function(dev, params)
									--[[ Need to set: door_??
									params.UserCode
									params.StartDate
									params.StopDate
									params.Replace
									]]
									return nil
								end 
				},
			["SetPinValidityWeekly"] = { fn = function(dev, params)
									--[[ Need to set: door_??
									params.UserCode
									params.DayOfWeek
									params.StartHour
									params.StartMinute
									params.StopHour
									params.StopMinute
									params.Replace
									]]
									return nil
								end 
				},
			["ClearPinValidity"] = { fn = function(dev, params)
									--[[ Need to set: door_??
									params.UserCode
									params.slotID
									]]
									return nil
								end 
				},
			["ClearPin"] = { fn = function(dev, params)
									--[[ Need to set: door_??
									params.UserCode
									]]
									return nil
								end 
				}
		},
	[SID.window_cov] = {
			["Up"]		= { fn = function(dev, params) return {{i="dimmer_up", v=true}} end },
			["Down"]	= { fn = function(dev, params) return {{i="dimmer_down", v=true}} end },
			["Stop"]	= { fn = function(dev, params) return {{i="dimmer_stop", v=true}} end }
		},
	[SID.switch_power] = {
			["SetTarget"] = { fn = function(dev, params) return {{i="switch", v=(params.newTargetValue == "1")}} end }
		},
	[SID.energy] = {
			["ResetKWH"] = { fn = function(dev, params) return {{i="meter_reset", v=true}} end }
		},
	[SID.dimming] = {
			["SetLoadLevelTarget"] = { fn = function(dev, params) 
									return {{i="dimmer", v=(tonumber(params.newLoadlevelTarget) or 0)} }
								end 
				}
		},
	[SID.color] = {
			["SetColor"] = { fn = function(dev, params)
									return nil --, "rgb_color", params.newColorTarget
								end 
				},
			["SetColorRGB"] = { fn = function(dev, params) return {{i="rgb_color", v=params.newColorRGBTarget}} end },
			["SetColorTemp"] = { fn = function(dev, params)
									return nil  --, "rgb_color", params.newColorTempTarget
								end 
				}
		}
}

-- API for Ezlo Communications
local function ezloAPI()
	local ltn12 	= require("ltn12")
	local https     = require("ssl.https")
	local bit 		= require("bit")
	local nixio = nil
	if pcall(require, "nixio") then
		-- On Vera, use nixio crypto and b64decode module
		nixio = require("nixio")
	end
	local luaws 	= require "L_EzloBridge_LuaWs"

	local ezloPort = "17000"
	local maxReconnectRetries = 30	-- Allow for 15 minute reconnect retry. Should be plenty for reboot.
	local reconnectRetryInterval = 30
	local wssToken = nil
	local wssUser = nil
	local STAT = {
		CONNECT_FAILED = -4,
		BAD_PASSWORD = -3,
		TOKEN_EXPIRED = -2,
		NO_CONNECTION = -1,
		CONNECTING = 0,
		CONNECTED = 2,
		IDLE = 3,
		BUSY = 4
	}
	local connectionsStatus = STAT.NO_CONNECTION
	local wsconn = nil
	local hubIp = nil
	local methodCallbacks = {}
	local broadcastCallbacks = {}
	local errorCallbacks = {}
	local pingCounter = 0
	local pingCommand = nil	-- Send this data instead of Ping
	
	-- Calculates SHA1 for a string, returns it encoded as 40 hexadecimal digits.
	local function sha1(str)
		if nixio then
			-- Vera 
			local crypto = nixio.crypto.hash ("sha1")
			crypto = crypto.update(crypto, str)
			local hex, buf = crypto.final(crypto)
			return hex
		else
			-- Other
			local brol = bit.rol
			local band = bit.band
			local bor = bit.bor
			local bxor = bit.bxor
			local uint32_lrot = brol
			local uint32_xor_3 = bxor
			local uint32_xor_4 = bxor
			local sbyte = string.byte
			local schar = string.char
			local sformat = string.format
			local srep = string.rep

			local function uint32_ternary(a, b, c)
				-- c ~ (a & (b ~ c)) has less bitwise operations than (a & b) | (~a & c).
				return bxor(c, band(a, bxor(b, c)))
			end

			local function uint32_majority(a, b, c)
				-- (a & (b | c)) | (b & c) has less bitwise operations than (a & b) | (a & c) | (b & c).
				return bor(band(a, bor(b, c)), band(b, c))
			end

			-- Merges four bytes into a uint32 number.
			local function bytes_to_uint32(a, b, c, d)
				return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
			end

			-- Splits a uint32 number into four bytes.
			local function uint32_to_bytes(a)
				local a4 = a % 256
				a = (a - a4) / 256
				local a3 = a % 256
				a = (a - a3) / 256
				local a2 = a % 256
				local a1 = (a - a2) / 256
				return a1, a2, a3, a4
			end

			local function hex_to_binary(hex)
				return (hex:gsub("..", function(hexval)
					return schar(tonumber(hexval, 16))
				end))
			end

			-- Input preprocessing.
			-- First, append a `1` bit and seven `0` bits.
			local first_append = schar(0x80)

			-- Next, append some zero bytes to make the length of the final message a multiple of 64.
			-- Eight more bytes will be added next.
			local non_zero_message_bytes = #str + 1 + 8
			local second_append = srep(schar(0), -non_zero_message_bytes % 64)

			-- Finally, append the length of the original message in bits as a 64-bit number.
			-- Assume that it fits into the lower 32 bits.
			local third_append = schar(0, 0, 0, 0, uint32_to_bytes(#str * 8))
			str = str .. first_append .. second_append .. third_append
			assert(#str % 64 == 0)

			-- Initialize hash value.
			local h0 = 0x67452301
			local h1 = 0xEFCDAB89
			local h2 = 0x98BADCFE
			local h3 = 0x10325476
			local h4 = 0xC3D2E1F0
			local w = {}

			-- Process the input in successive 64-byte chunks.
			for chunk_start = 1, #str, 64 do
				-- Load the chunk into W[0..15] as uint32 numbers.
				local uint32_start = chunk_start
				for i = 0, 15 do
					w[i] = bytes_to_uint32(sbyte(str, uint32_start, uint32_start + 3))
					uint32_start = uint32_start + 4
				end
				-- Extend the input vector.
				for i = 16, 79 do
					w[i] = uint32_lrot(uint32_xor_4(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
				end
				-- Initialize hash value for this chunk.
				local a = h0
				local b = h1
				local c = h2
				local d = h3
				local e = h4
				-- Main loop.
				for i = 0, 79 do
					local f
					local k
					if i <= 19 then
						f = uint32_ternary(b, c, d)
						k = 0x5A827999
					elseif i <= 39 then
						f = uint32_xor_3(b, c, d)
						k = 0x6ED9EBA1
					elseif i <= 59 then
						f = uint32_majority(b, c, d)
						k = 0x8F1BBCDC
					else
						f = uint32_xor_3(b, c, d)
						k = 0xCA62C1D6
					end
					local temp = (uint32_lrot(a, 5) + f + e + k + w[i]) % 4294967296
					e = d
					d = c
					c = uint32_lrot(b, 30)
					b = a
					a = temp
				end
				-- Add this chunk's hash to result so far.
				h0 = (h0 + a) % 4294967296
				h1 = (h1 + b) % 4294967296
				h2 = (h2 + c) % 4294967296
				h3 = (h3 + d) % 4294967296
				h4 = (h4 + e) % 4294967296
			end
			return sformat("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
		end
	end
	
	-- Generate a (semi) random UUID
	local function uuid()
		local random = math.random
		local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
		return string.gsub(template, '[xy]', function (c)
			local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
			return string.format('%x', v)
		end)
	end

	-- Base 64 decoding
	-- Can be replaced with mine.unb64 
	local function b64decode(data)
		if nixio then
			return nixio.bin.b64decode(data)
		else
			local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
			data = string.gsub(data, '[^'..b..'=]', '')
			return (data:gsub('.', function(x)
				if (x == '=') then return '' end
				local r,f='',(b:find(x)-1)
				for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
				return r;
				end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
					if (#x ~= 8) then return '' end
					local c=0
					for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
					return string.char(c)
				end))
		end
	end
	
	-- Generate a semi random message ID value
	local function generateID(prefix)
		local prefix = prefix or ""
		local random = math.random
		local template ='xxxxxxxxxxxxxx'
		return prefix..string.gsub(template, '[xy]', function (c)
			local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
			return string.format('%x', v)
		end)
	end	
	-- Close connection to Hub
	local function Close()
		luaws.wsclose(wsconn)
		wsconn = nil
		connectionsStatus = STAT.NO_CONNECTION
	end


	-- Handle WebSocket incomming messages
	local function MessageHandler(conn, opcode, data, ...)
log.Debug("MessageHandler %s, %s",tostring(opcode),tostring(data))
--		pingCounter = 0
		if opcode == 0x01 then
			-- Received text data, should be json to decode
			local js, msg = json.decode(data)
			-- Check for error table to be present (cannot test for nil as cjson returns userdata type)
			if type(js.error) == "table" then
				log.Debug("MessageHandler, response has error : %s, %s ", tostring(js.error.code or 0), (js.error.message or ""))
				local func = errorCallbacks[js.method] or errorCallbacks["*"]
				if func then
					-- Call the registered handler
					local stat, msg = pcall(func, js.method, js.error, js.result)
					if not stat then
						log.Debug("Error in error callback for method %s, %s", tostring(js.method or ""), (msg or ""))
					end
				else
					-- No call back
					log.Debug("No error callback for method %s", tostring(js.method or "" ))
				end	
			elseif js.method ~= nil then
				-- look at method to handle. The Hub replies the method sent in the response
				if js.method == "hub.offline.login.ui" then
					-- Local logon completed, flag it
					log.Debug("MessageHandler, logon complete. Ready for commands.")
					connectionsStatus = STAT.CONNECTED
				end
				local func = methodCallbacks[js.method] or methodCallbacks["*"]
				if func then
					-- Call the registered handler
					local stat, msg = pcall (func, js.method, js.result)
					if not stat then 
						log.Debug("Error in method callback for method %s, %s", tostring(js.method or ""), (msg or ""))
					end
				else
					-- No call back
					log.Debug("No method callback for method %s", tostring(js.msg_subclass or ""))
				end	
			elseif js.id == "ui_broadcast" and js.msg_subclass ~= nil then
				local func = broadcastCallbacks[js.msg_subclass] or broadcastCallbacks["*"]
				if func then
					-- Call the registered handler
					local stat, msg = pcall(func, js.msg_subclass, js.result)
					if not stat then
						log.Debug("Error in broadcast callback for message %s, %s", tostring(js.msg_subclass or ""), (msg or ""))
					end
				else
					-- No call back
					log.Debug("No broadcast callback for message %s", tostring(js.msg_subclass or ""))
				end	
			else
				log.Debug("MessageHandler, response has no method. Cannot process.")
			end
		elseif opcode == 0x02 then
			-- Received binary data. Not expecting this.
			log.Debug("MessageHandler, received binary data. Cannot process.")
		elseif opcode == 0x09 then
			-- Received ping (should be handled by luaws)
			log.Debug("MessageHandler, received ping.")
		elseif opcode == 0x0a then
			-- Received pong (should not be possible)
			log.Debug("MessageHandler, received pong.")
		elseif opcode == 0x08 then
			-- Close by peer
			log.Debug("MessageHandler, Connection is closed by Hub.")
			Close()
		elseif opcode == false then
			log.Debug("MessageHandler, opcode = false? %s", tostring(data or ""))
		else
			log.Debug("MessageHandler, Unknown opcode.")
			--connectionsStatus = STAT.NO_CONNECTION
		end
	end
	
	-- Logon to Ezlo portal and return 
	local function PortalLogin(user_id, password, serial)
		local Ezlo_MMS_salt = "oZ7QE6LcLJp6fiWzdqZc"
		local authentication_url = "https://vera-us-oem-autha11.mios.com/autha/auth/username/%s?SHA1Password=%s&PK_Oem=1&TokenVersion=2"
		local get_token_url = "https://cloud.ezlo.com/mca-router/token/exchange/legacy-to-cloud/"
		local sync_token_url = "https://api-cloud.ezlo.com/v1/request"

		-- Do https request. For json requests and response data only.
		local function https_request(mthd, strURL, headers, PostData)
--log.Debug("URL %s", strURL)
			local result = {}
			local request_body = nil
			if PostData then
				request_body=json.encode(PostData)
				headers["content-length"] = string.len(request_body)
			else
				headers["content-length"] = "0"
			end
			local bdy,cde,hdrs,stts = https.request{
				url = strURL, 
				method = mthd,
				sink = ltn12.sink.table(result),
				source = ltn12.source.string(request_body),
				protocol = "any",
				options =  {"all", "no_sslv2", "no_sslv3"},
				verify = "none",
				headers = headers
			}
			if bdy == 1 then
				if cde ~= 200 then
					return false, cde, nil, stts
				else
--log.Debug(table.concat(result))		
					return true, cde, json.decode(table.concat(result)), "OK"
				end
			else
				-- Bad request
				return false, 400, nil, "HTTP/1.1 400 BAD REQUEST"
			end
		end	

		-- Get Tokens
		local request_headers = {
			["access-control-allow-origin"] = "*",
			["user-agent"] = "RB Ezlo Bridge 1.0",
			["accept"] = "application/json",
			["content-type"] = "application/json; charset=UTF-8"
		}
		local SHA1pwd = sha1(string.lower(user_id)..password..Ezlo_MMS_salt)
		local stat, cde, response, msg = https_request("GET", authentication_url:format(user_id,SHA1pwd), request_headers)
		if not stat then
			return false, "Could not login to portal. "..tostring(cde or 0)..", "..tostring(msg or "")
		end	
		local MMSAuth = response.Identity
		local MMSAuthSig = response.IdentitySignature
		-- Identity has base64 encoded account details.
		local js_Ident = json.decode(b64decode(MMSAuth))
		token_expires = js_Ident.Expires -- Need to logon again when token has expired.
		request_headers["MMSAuth"] = MMSAuth
		request_headers["MMSAuthSig"] = MMSAuthSig
		stat, cde, response, msg = https_request("GET", get_token_url, request_headers)
		if not stat then
			return false, "Could not get token. "..tostring(cde or 0)..", "..tostring(msg or "")
		end	
	
		-- Get controller keys (user & token)
		local post_headers = {
			["authorization"] = "Bearer "..response.token,
			["access-control-allow-origin"] = "*",
			["user-agent"] = "RB Ezlo Bridge 1.0",
			["accept"] = "application/json",
			["content-type"] = "application/json; charset=UTF-8"
		}
		local post_data = {
			["call"] = "access_keys_sync",
			["version"] = "1",
			["params"] = {
				["version"] = 53, 
				["entity"] = "controller",
				["uuid"] = uuid()
			}
		}
		local stat, cde, response, msg = https_request("POST",sync_token_url, post_headers, post_data)
		if not stat then
			return false, "Could not sync controller keys. "..tostring(cde or 0)..", "..tostring(msg or "")
		end
		-- Get user and token from response.
		data = response.data
log.Debug("Sync keys response "..json.encode(data))		
		local wss_user = ''
		local wss_token = ''
		local contr_uuid = ''
		-- Look up uuid for controller based on serial#
		for _, key_data in pairs(data.keys) do
			if key_data.meta then
				if key_data.meta.entity then
					if key_data.meta.entity.id then
						if key_data.meta.entity.id == serial then
							contr_uuid = key_data.meta.entity.uuid
						end
					end
				end
			end
		end
		if contr_uuid == '' then
			return false, "Controller serial not found"
		end
		for _, key_data in pairs(data.keys) do
			if type(key_data.data) == "table" and wss_user == '' and wss_token == '' then
				if type(key_data.data.string) == "string" then
					if key_data.meta.target.uuid == contr_uuid then
						wss_token = key_data.data.string
						wss_user = key_data.meta.entity.uuid
					end
				end
			end
		end
		if wss_user ~= '' and wss_token ~= '' then
			return true, wss_token, wss_user, token_expires
		else
			return false, "Could not obtain token data."
		end
	end

	-- Send text data to Hub. Cannot do simple json encode as with no params that will generate "params":[] and the G150 does not like that.
	local function Send(data)
		if connectionsStatus ~= STAT.CONNECTING and connectionsStatus ~= STAT.CONNECTED then
			log.Debug("No connection when trying to call Send()")
			return false, "No connection"
		end
		local id = generateID()
		local params = "{}"
		if data.params then params = json.encode(data.params) end
		local cmd = '{"method":"%s","id":"%s","params":%s}'
		return luaws.wssend(wsconn, 0x01, cmd:format(data.method, id, params))
	end

	-- Non-blocking Read from Hub. Responses will be handled by MessageHandler
	local function Receive()
		if connectionsStatus ~= STAT.CONNECTING and connectionsStatus ~= STAT.CONNECTED then
			log.Debug("No connection when trying to call Receive()")
			return false, "No connection"
		end
		return luaws.wsreceive(wsconn)
	end

	-- Send ping to Hub.
	local function Ping()
		return luaws.wssend(wsconn, 0x09, "")
	end

	-- open web socket connection
	local function Connect(controller_ip, wss_token, wss_user)
		wsconn, msg = luaws.wsopen('wss://' .. controller_ip .. ':' .. ezloPort, MessageHandler)
		if wsconn == false then
			log.Debug("Could not open WebSocket. %s", tostring(msg or ""))
			return false, "Could not open WebSocket. " .. tostring(msg or "")
		end	
		connectionsStatus = STAT.CONNECTING
		hubIp = controller_ip
		wssToken = wss_token
		wssUser = wss_user
		-- Send local login command
		return Send({method="hub.offline.login.ui", params = {user = wss_user, token = wss_token}})
	end	

	local function SetTokensFromStore(token, uuid, expires)
		wssToken = token
		wssUser = uuid
		token_expires = expires
	end
	
	-- Add a specific handler for a given method
	local function RegisterMethodHandler(method, handler)
		if (type(handler) == "function") then
			methodCallbacks[method] = handler 
			return true
		end
		return false, "Handler is not a function"
	end
	local function RegisterBroadcastHandler(message, handler)
		if (type(handler) == "function") then
			broadcastCallbacks[message] = handler 
			return true
		end
		return false, "Handler is not a function"
	end
	local function RegisterErrorHandler(method, handler)
		if (type(handler) == "function") then
			errorCallbacks[method] = handler 
			return true
		end
		return false, "Handler is not a function"
	end
	
	-- Return current connection status
	local function GetConnectionStatus()
		return connectionsStatus
	end
	
	-- See if we can make use of openLuup.scheduler. However, this maybe needs to be done in luaws module.
	local function StartPoller()
		local R1NAME = "EzloBridge_Async_WebSocket_Reciever"
		local RCNAME = "EzloBridge_Async_WebSocket_Reconnect"
		local POLL_RATE = 1
    
		local function check_for_data ()
			if connectionsStatus ~= STAT.CONNECTING and connectionsStatus ~= STAT.CONNECTED then
				luup.log("No connection checking for data",2)
				return
			end
			local lp_ts = luaws.wslastping(wsconn)
			local res, more, nb = nil, nil, nil
			if os.difftime(os.time(), lp_ts) > 90 then
				log.Debug("No ping received for %d seconds", os.difftime(os.time(), lp_ts))
			else
				res, more, nb = pcall(luaws.wsreceive, wsconn)
				-- Get data, if more is true, immediately read next chunk.
				while res and more do
					log.Debug("%s, More chunks to receive", R1NAME)
					res, more, nb = pcall(luaws.wsreceive, wsconn)
				end
				if not res then
					log.Error("%s. Error receiving data from Hub, %s", R1NAME, tostring(more or ""))
				end
			end	
			-- If more is nil the connection to the Hub is lost. Close and retry.
			if more == nil then
				log.Warning("%s. Lost connection to Hub, %s. Try reconnect in %d seconds.", R1NAME, tostring(nb or "reason unknown"), reconnectRetryInterval)
				Close()
				luup.call_delay(RCNAME, reconnectRetryInterval, "1")
			else
				-- See if we need to send a command to check House mode.
				if pingCommand then
					if pingCounter >= 20 then
						Send(pingCommand)
						pingCounter = 0
					else
						pingCounter = pingCounter + 1
					end
				end
				luup.call_delay (R1NAME, POLL_RATE, '')
			end	
		end

		_G[R1NAME] = check_for_data
		_G[RCNAME] = Reconnect
		check_for_data()
		return true
	end

	-- Reconnect to Hub, with up to five retries.
	function Reconnect(retry)
		local retry = tonumber(retry) or 1
		log.Debug("Try to Reconnect, attempt %d.", retry)
		if retry < maxReconnectRetries then
			local res, msg = Connect(hubIp, wssToken, wssUser)
			if res then
				-- Connected again, resume polling.
				log.Debug("Connection reopened, login")
				StartPoller()
			else
				local RCNAME = "EzloBridge_Async_WebSocket_Reconnect" -- Is this function
				log.Debug("Could not reconnect, retrying in %d seconds.", reconnectRetryInterval)
				luup.call_delay (RCNAME, reconnectRetryInterval, tostring(retry + 1))
			end
		else
			log.Debug("Could not reconnect after %d retries.", maxReconnectRetries)
			connectionsStatus = STAT.CONNECT_FAILED
		end
	end
	
	-- If a ping command string is set then that is send rather than a ping command
	-- Userfull for Athom that does not like ping, or getting the house mode.
	local function SetPingCommand(cmd)
		if type (cmd) == "table" then
			pingCommand = cmd
		else
			pingCommand = nil
		end
	end
	
	-- Initialize module
	local function Initialize(dbg)
		luaws.wsinit(dbg)
		connectionsStatus = STAT.NO_CONNECTION
	end

	return {
		Initialize = Initialize,
		StartPoller = StartPoller,
		PortalLogin = PortalLogin,
		Connect = Connect,
		SetTokensFromStore = SetTokensFromStore,
		GetConnectionStatus = GetConnectionStatus,
		BAD_PASSWORD = STAT.BAD_PASSWORD,
		TOKEN_EXPIRED = STAT.TOKEN_EXPIRED,
		NO_CONNECTION = STAT.NO_CONNECTION,
		CONNECT_FAILED = STAT.CONNECT_FAILED,
		CONNECTING = STAT.CONNECTING,
		CONNECTED = STAT.CONNECTED,
		IDLE = STAT.IDLE,
		BUSY = STAT.BUSY,
		Send = Send,
		Receive = Receive,
		Ping = Ping,
		SetPingCommand = SetPingCommand,
		Close = Close,
		RegisterMethodHandler = RegisterMethodHandler,
		RegisterBroadcastHandler = RegisterBroadcastHandler,
		RegisterErrorHandler = RegisterErrorHandler
	}
end

-----------
-- mapping between remote and local device IDs

local OFFSET                      -- offset to base of new device numbering scheme
local BLOCKSIZE = luup.openLuup.bridge.BLOCKSIZE  -- size of each block of device and scene IDs allocated
local Zwave = {}                  -- list of Zwave Controller IDs to map without device number translation

local function local_by_remote_id (id) 
	return Zwave[id] or id + OFFSET
end

local function remote_by_local_id (id)
	if id == devNo then return 0 end  -- point to remote Vera device 0
	return Zwave[id] or id - OFFSET
end

-- change parent of given device, and ensure that it handles child actions
local function set_parent_and_handle_children (devNo, newParent)
	local dev = luup.devices[devNo]
	if dev then
		dev.handle_children = true              -- handle Zwave actions
		dev:set_parent (newParent)              -- parent resides in two places under different names !!
	end
end
 
-- create bi-directional indices of rooms: room name <--> room number
local function index_rooms (rooms)
	local room_index = {}
	for number, name in pairs (rooms) do
		local roomNo = tonumber (number)      -- user_data may return string, not number
		room_index[roomNo] = name
		room_index[name] = roomNo
	end
	return room_index
end

-- create bi-directional indices of REMOTE rooms: room name <--> room number
local function index_remote_rooms (rooms)    --<-- different structure
	local room_index = {}
	for _, room in pairs (rooms) do
		local number, name = room.id, room.name
		local roomNo = tonumber (number)      -- user_data may return string, not number
		room_index[roomNo] = name
		room_index[name] = roomNo
	end
	return room_index
end

-- Set a device as reachable or not
local function set_device_reachable_status(reachable, devID)
	local msg = ""
	local status = -1
	if type(reachable) == "string" then
		if reachable == "broken" then
			msg = "Device broken."
			status = 2
		end	
	elseif not reachable then
		msg = "Can't Detect Device"
		status = 2
	end
	var.SetAttribute("status", status, devID)
	luup.device_message(devID, status, msg, 0, ABOUT.NAME)
	return status
end

-- create a new device, cloning the remote one
local function create_new (cloneId, dev, room)
	local d = chdev.create {
		category_num    = dev.category_num,
		devNo           = cloneId, 
		device_type     = dev.device_type,
		internal_id     = tostring(dev.altid or ''),
		invisible       = dev.invisible == "1",		-- might be invisible, eg. Zwave and Scene controllers
		json_file       = dev.device_json,
		description     = dev.name,
		upnp_file       = dev.device_file,
		upnp_impl       = 'X',              -- override device file's implementation definition... musn't run here!
		parent          = devNo,
		password        = dev.password,
		room            = room, 
		manufacturer    = dev.manufacturer, 
		model           = dev.model, 
		statevariables  = dev.states,
		subcategory_num = dev.subcategory_num,
		username        = dev.username,
		ip              = dev.ip, 
		mac             = dev.mac, 
	}  

	local attr = d.attributes
	local extras = {"onDashboard"}        -- 2018.04.17  add other specific attributes
	for _,name in ipairs (extras) do 
		attr[name] = dev[name]
	end
	d.status = dev.status	-- Flag is devices cannot be reached so we can show on GUI.
	attr.host = "Ezlo"
	luup.devices[cloneId] = d   -- remember to put into the devices table! (chdev.create doesn't do that)
end

-- ensure that all the parent/child relationships are correct
local function build_families (devices)
	for _, dev in pairs (devices) do   -- once again, this 'devices' table is from the 'user_data' request
		local cloneId  = local_by_remote_id (dev.id)
		local parentId = local_by_remote_id (tonumber (dev.id_parent) or 0)
		if parentId == OFFSET then parentId = devNo end      -- the bridge is the "device 0" surrogate
		local clone  = luup.devices[cloneId]
		local parent = luup.devices[parentId]
		if clone and parent then
			set_parent_and_handle_children (cloneId, parentId)
		end
	end
end

-- return true if device is to be cloned
-- note: these are REMOTE devices from the Vera status request
-- consider: ZWaveOnly, Included, Excluded (...takes precedence over the first two)
-- and Mirrored, a sequence of "remote = local" device IDs for 'reverse bridging'

-- plus @explorer modification
-- see: http://forum.micasaverde.com/index.php/topic,37753.msg282098.html#msg282098

local function is_to_be_cloned (dev)
	local d = tonumber (dev.id)
	local p = tonumber (dev.id_parent)
	local zwave = p == 1 or d == 1
	if ZWaveOnly and p then -- see if it's a child of the remote zwave device
		local i = local_by_remote_id(p)
		if i and luup.devices[i] then zwave = true end
	end
	return  not (Excluded[d]) and (Included[d] or (not ZWaveOnly) or (ZWaveOnly and zwave) )
end

-- create the child devices managed by the bridge
local function create_children (devices, room_0)
	local N = 0
	local list = {}           -- list of created or deleted devices (for logging)
	local something_changed = false
 --[[
 -- make a list of parent's existing children, counting grand-children, etc.!!!
function bridge_utilities.all_descendants (parent)
  
  local idx = {}
  for child, dev in pairs (luup.devices) do   -- index all devices by parent id
    local num = dev.device_num_parent
    local children = idx[num] or {}
    children[#children+1] = child
    idx[num] = children
  end

  local c = {}
  local function children_of (d)      -- recursively find all children
    for _, child in ipairs (idx[d] or {}) do
      c[child] = luup.devices[child]
      children_of (child)
    end
  end
  children_of (parent)
  return c
end
 ]]
	local current = luup.openLuup.bridge.all_descendants (devNo)
	for _, dev in ipairs (devices) do   -- this 'devices' table is from the 'user_data' request
		dev.id = tonumber(dev.id)
		if is_to_be_cloned (dev) then
			N = N + 1
			local room = room_0
			local cloneId = local_by_remote_id (dev.id)
			if not current[cloneId] then 
				something_changed = true
			else
				local new_room
				local remote_room = tonumber(dev.room)
				if CloneRooms then    -- force openLuup to use the same room as Vera
					new_room = local_room_index[remote_room_index[remote_room]] or 0
				else
					new_room = luup.devices[cloneId].room_num
				end
				room = (new_room ~= 0) and new_room or room_0   -- use room number
			end
			create_new (cloneId, dev, room) -- recreate the device anyway to set current attributes and variables
			list[#list+1] = cloneId
			current[cloneId] = nil
		end
	end
	if #list > 0 then luup.log ("creating device numbers: " .. json.encode(list)) end
  
	list = {}
	for n in pairs (current) do
--    luup.devices[n] = nil       -- remove entirely!
--    something_changed = true
--    list[#list+1] = n
-- 2020.02.05, put into Room 101, instead of deleting, in order to retain information in scene triggers and actions
		if not luup.rooms[101] then luup.rooms.create ("Room 101", 101) end 
		local dev = luup.devices[n]
		dev:rename (nil, 101)            -- move to Room 101
		var.SetAttribute("disabled", 1, n)     -- and make sure it doesn't run (shouldn't anyway, because it is a child device)
--
--
	end
	if #list > 0 then luup.log ("deleting device numbers: " .. json.encode(list)) end
	build_families (devices)
	if something_changed then luup.reload() end
	-- If device is not reachable, show that status
	current = luup.openLuup.bridge.all_descendants (devNo)
	for n in pairs (current) do
		local dev = luup.devices[n]
		if dev.status == 2 then
			set_device_reachable_status(false, n)
		end
	end
	return N
end

-- remove old scenes within our allocated block
local function remove_old_scenes ()
	local min, max = OFFSET, OFFSET + BLOCKSIZE
	for n in pairs (luup.scenes) do
		if (min < n) and (n < max) then
			luup.scenes[n] = nil            -- nuke it!
		end
	end
end

-- create a link to remote scenes
local function create_scenes (remote_scenes, room)
	local N,M = 0,0

	if not BridgeScenes then        -- 2017.02.12
		remove_old_scenes ()
		luup.log "remote scenes not linked"
		return 0
	end
  
	luup.log "linking to remote scenes..."
	local call = 'luup.call_action("%s", "RunRemoteScene", {["SceneNum"] = %d}, %d)'  -- 2020.05.30e
	for _, s in pairs (remote_scenes) do
		local id = s.id + OFFSET             -- retain old number, but just offset it
		if not s.notification_only then
			if luup.scenes[id] then  -- don't overwrite existing
				M = M + 1
			else
				local new = {
					id = id,
					name = s.name,
					room = room,
					lua = call:format (SID.gateway, s.id, devNo)   -- trigger the remote scene action -- 2020.05.30e
				}
				luup.scenes[new.id] = scenes.create (new)
				log.Log("scene [%d] %s", new.id, new.name)
				N = N + 1
			end
		end
	end
	log.Log("scenes: existing= %d, new= %d",M,N)
	return N+M
end


local function GetUserData ()
	local loadtime    -- 2019.05.03
	local Ndev, Nscn = 0, 0
	local version, PK_AccessPoint
	local Vera = EzloData.Vera	-- We build the user_data like structure with initial calls to Ezlo Hub.
	if Vera then 
		log.Log("Hub info received!")
		loadtime = Vera.LoadTime
		local t = "users"
		if Vera.devices then
			PK_AccessPoint = Vera.PK_AccessPoint: gsub ("%c",'')      -- stray control chars removed!!
			local new_room_name = "Ezlo-" .. PK_AccessPoint 
			userdata.attributes [t] = userdata.attributes [t] or Vera[t]
			log.Log(new_room_name)
			luup.rooms.create (new_room_name)     -- 2018.03.24  use luup.rooms.create metatable method
			remote_room_index = index_remote_rooms (Vera.rooms or {})
			local_room_index  = index_rooms (luup.rooms or {})
			log.Log("new room number: %s.", (local_room_index[new_room_name] or '?'))
			if CloneRooms then    -- check individual rooms too...
				for room_name in pairs (remote_room_index) do
					if type(room_name) == "string" then
						if not local_room_index[room_name] then 
							log.Log("creating room: %s.", room_name)
							local new = luup.rooms.create (room_name)     -- 2018.03.24  use luup.rooms.create metatable method
							local_room_index[new] = room_name
							local_room_index[room_name] = new
						end
					end
				end
			end
 
			log.Log("PK_AccessPoint = %s.", PK_AccessPoint)
            version = Vera.BuildVersion
			log.Log("BuildVersion = %s.", version)
			
			Ndev = #Vera.devices
			log.Log("number of remote devices = %d.", Ndev)
     
			local roomNo = local_room_index[new_room_name] or 0
			Ndev = create_children (Vera.devices, roomNo)
			Nscn = create_scenes (Vera.scenes, roomNo)
			do      -- 2017.07.19
				VeraScenes = Vera.scenes
				VeraRoom = roomNo
				var.SetString("Model", (Vera.model or ""))
				var.SetString("Build Version", (Vera.BuildVersion or ""))
			end
		end
	end	
	return Ndev, Nscn, version, PK_AccessPoint, loadtime
end


-- update HouseMode variable and, possibly, the actual openLuup Mode

local function UpdateHouseMode (Mode)
	local displayLine = "%s [%s]"
	local modeName = {"Home", "Away", "Night", "Vacation"}
	
	Mode = tonumber(Mode)
	if not Mode then return end   -- 2018.02.21  bail out if no Mode (eg. UI5)
	local status = modeName[Mode] or '?'
	Mode = tostring(Mode)
	var.SetString("HouseMode", Mode)
	utils.SetDisplayLine(displayLine:format(ip, status), 2)   -- 2018.02.20
  
	local current = userdata.attributes.Mode
	if current ~= Mode then 
		if HouseModeMirror == '1' then
			luup.call_action (SID.hag, "SetHouseMode", {Mode = Mode, Now=1})    -- 2018.03.02  with immediate effect 

		elseif HouseModeMirror == '2' then
			local now = os.time()
			log.Log("remote HouseMode differs from that set...")
			if now > HouseModeTime + 60 then        -- ensure a long delay between retries (Vera is slow to change)
				log.Log("remote HouseMode update, was: %s, switching to: %s.", Mode, current)
				HouseModeTime = now
				ezlo.Send({method = "hub.modes.switch", params = { modeId = current }})
			end
		end
	end
end

-- Refresh all data every so often incase we missed some broadcast message
function EzloBridge_async_watchdog (timeout)
	if (lastFullStatusUpdate + timeout) < os.time() then
		log.Debug("Doing full data refresh")
		ezlo.Send({ method = "hub.devices.list" })	-- device list will trigger item list once processed,
	end
	luup.call_delay ("EzloBridge_async_watchdog", timeout, timeout)
end


--
-- Bridge ACTION handler(s)
--

-- Called when scene on bridged hub so we can run on Vera and Ezlo hub -- 2020.05.30e
function RunRemoteScene (params)
	local escnId
	local vscnId = tonumber(params.SceneNum or 0)
	for i, id in pairs(EzloData.sceneMap) do
		if id == vscnId then 
			escnId = i 
			break
		end
	end
	if escnId then
		ezlo.Send({ method = "hub.scenes.run", params = { sceneId = escnId }})
	else
		log.Log("RunRemoteScene, SceneNum : %s does not map to a Ezlo Hub Scene.", (params.SceneNum or "??"))
	end	
end


function SetHouseMode (p)         -- 2018.05.15
	if tonumber (p.Mode) then
		ezlo.Send({ method = "hub.modes.switch", params = { modeId = p.Mode}})
	end
end

function Restart (p)
	-- If asked to Authenticate erase tokens and force full login.
	if p.Authenticate == "1" then 
		var.SetString("HubToken", "")
    	var.SetString("WssUserID", "")
    	var.SetString("WssToken", "")
	end
	luup.reload()
end

--
-- GENERIC ACTION HANDLER
--
-- called with serviceId and name of undefined action
-- returns action tag object with possible run/job/incoming/timeout functions
--
local function generic_action (serviceId, name)

  local function job (lul_device, lul_settings)
    local devNo = remote_by_local_id (lul_device)
	
    if not devNo then return end        -- not a device we have cloned
    if devNo == 0 and serviceId ~= SID.hag then  -- 2018.02.17  only pass on hag requests to device #0
      return 
    end
  
	if not EzloData.is_ready then
		-- Connection is not ready yet.
		return 3,0
	end
	local eaction = VeraActionMapping[serviceId]
	local edevID = EzloData.reverseDeviceMap[devNo].id
log.Debug("Action %s:%s for Ezlo device : %s.",serviceId,(name or "no action name"),(edevID or "not found!"))		
	if eaction then 
		eaction = eaction[name]
		if eaction then
			local methods = eaction.fn(lul_device, lul_settings)
log.Debug("number of methods to send %d.",(#methods or 0))
			if methods then
				for _,v in ipairs(methods) do
					local method = v.m or "hub.item.value.set"
					local iname, value = v.i, v.v
log.Debug("Method : %s, name : %s, value : %s", tostring(method), tostring(iname or "nil"), tostring(value))
					local item = EzloItemsMapping[iname]
					if item then
						local params = {}
						if item.hasSetter and method == "hub.item.value.set" then
							-- Get the Id of the item of the device
							params._id = EzloData.reverseDeviceMap[devNo].items[iname]
						else
							params._id = edevID
						end
						if item.scale then
							-- It is a scalar value
							params.value = value
							params.scale = item.scale
						else
							if v.p then
								-- Parameter has other name than value for its value.
								params[v.p] = value
							else
								params.value = value
							end	
						end
log.Debug("Action command "..json.encode({method=method, params=params}))
						ezlo.Send({method=method, params=params})
					else
						log.Warning("Unknown item type : %s.",(iname or "nil"))
					end
				end	
			else
				log.Warning("Actions not supported for ServiceID : %s, Action : %s.", serviceId, name)
			end
		else
			log.Info("No actions found for ServiceID : %s, Action : %s.", serviceId, name)
		end
	else
		log.Info ("No actions found for ServiceID : %s.", serviceId)
	end
    return 4,0
  end
  
  -- This action call to ANY child device of this bridge:
  -- luup.call_action ("urn:akbooer-com:serviceId:EzloBridge1","remote_ip",{},10123)
  -- will return something like: 
  -- {IP = "172.16.42.14"}

  if serviceId == SID.gateway and name == "remote_ip" then     -- 2017.02.22  add remote_ip request
    return {serviceId = serviceId, name = name, extra_returns = {IP = ip} }
  end
    
  return {job = job}    -- 2019.01.20
end

--------------
--
-- Ezlo incomming messages handlers
--
-- Map an Ezlo item to an Vera Service Variable.
local function mapItem(eitem, vdevID)
	local v = EzloItemsMapping[eitem.name]
	if not v then
		-- If we do not have any definition, map to generic sensor
		v = {}
		v.service = SID.gen_sensor 
		v.variable = "CurrentLevel"
		v.hasSetter = false
		v.hasGetter = true
	else
		-- Collect extra information of items so we do not need to keep in EzloItemsMapping code.
		if not v.valueType then
			log.Debug("Setting variable details for item name %s, value type %s, scale %s. ",(eitem.name or "") ,eitem.valueType , (eitem.scale or "no scale"))
			v.valueType = eitem.valueType or "string"
			v.scale = eitem.scale
			v.hasSetter = eitem.hasSetter or false
			v.hasGetter = eitem.hasGetter or false
		end
	end
	-- See if we have a convert function for the name
	local value = eitem.value
	if v.convert then
		value = v.convert(eitem.value, vdevID)
	elseif v.variable == "Tripped" and v.tripvalue then
		-- Handle sensor tripping
		value = (eitem.value == v.tripvalue and "1" or "0")
	elseif eitem.valueType == "bool" then
		value = eitem.value and "1" or "0"
	elseif eitem.valueType == "rgb" then
		--[[ convert to Vera rgb value
			To-do; other values than just RGB.
			"valueType" : "rgb" ,
			"value" : {
			"wwhite" : 10 ,
			"cwhite" : 10 ,
			"red" : 10 .
			"green" : 10 ,
			"blue" : 10 ,
			"amber" : 10 ,
			"cyan" : 10 ,
			"purple" : 10 ,
			"indexed" : 10
			}
		]]
		local w,d,r,g,b=0,0,0,0,0
		if type(eitem.value) == "table" then	-- value can be null.
			r = eitem.value.red
			g = eitem.value.green
			b = eitem.value.blue
		end	
		value = string.format("0=%s,1=%s,2=%s,3=%s,4=%s",w,d,r,g,b)
	elseif type(eitem.value) == "table" then
		value = "??table??"
	else
		-- As default we take the formatted value (not there for Athom)
		if eitem.valueFormatted then
			value = eitem.valueFormatted
		elseif type(eitem.value) == "number" then
			-- For Athom format a number to two digits
			value = string.format("%.2f" , eitem.value)
		else
			-- For other Athom values, try to make it a string.
			value = tostring(eitem.value or "??")
		end
	end
	v.value = value
	return v
end

-- Error handling for specific methods
local function ErrorHandler(method, err, result)
	if method == "hub.offline.login.ui" then
		-- Login error, close connection
-- To-dos: 
--		look for bad password and avoid login until uid or pwd or ip are changed
--		look for expired token message
		utils.SetDisplayLine("Unable to login locally: "..(err.message or "??"), 1)
		if err.data == "user.login.badpassword" then
			-- Erase stored data from new attempt.
			var.SetString("HubToken", "")
			var.SetString("WssToken", "")
			var.SetString("WssUserID", "")
		end	
		log.Error("Hub login error, closing.")
		ezlo.Close()
	else
		log.Error("Error from hub for method %s.", tostring(method or ""))
		log.Error("     Error info %s", tostring(json.encode(err) or ""))
		if result then
			log.Error ("     Error result %s", tostring(json.encode(result) or ""))
		end
	end
	return true
end

-- Handling for UI_broadcasts for specific messages
local function BroadcastHandler(msg_subclass, result)
	if EzloData.is_ready then
		if msg_subclass == "hub.item.updated" then
--log.Debug ("Result " .. tostring(json.encode(result) or""))
			if result.deviceId then
				local deviceMap = EzloData.deviceMap
				-- See if we know the device
				local vdevID = deviceMap[result.deviceId]
				if vdevID then
					vdevID = vdevID + OFFSET	-- Map to local ID
--log.Debug("Existing device %s mapping to %d.", (result.deviceId or "??"), vdevID)
					local v = mapItem(result, vdevID)
					if v.variable then
--log.Debug("Updating variable %s, value %s.", (v.variable or "??"), (v.value or ""))					
						luup.variable_set (v.service, v.variable, v.value or "", vdevID)
						if v.variable == "Tripped" and v.tripvalue then
							-- Handle sensor tripping
							if v.value == "1" then
								local armed = var.GetBoolean("Armed", SID.sec_sensor, vdevID)
								var.SetNumber("ArmedTripped", (armed and 1 or 0), SID.sec_sensor, vdevID)
								var.SetNumber("LastTrip", os.time(), SID.sec_sensor, vdevID)
							else
								var.SetNumber("ArmedTripped", 0, SID.sec_sensor, vdevID)
							end
						elseif v.service == SID.gen_sensor and v.variable == "CurrentLevel" then
							-- We have many state types that do not map to Vera so we use a generic sensor CurrentLevel
							-- Put some extra info in DisplayLine1 for the user.
							local line = result.name
							line = string.upper(line:sub(1,1))..line:sub(2)
							line = line:gsub("_"," ") .. " : " .. result.valueFormatted .. " " .. (result.scale or "")
							utils.SetDisplayLine(line or "",1, vdevID)
						end
					else
						-- item for unknown variable?
						log.Error("Item %s has unmapped name %s.", result._id, result.name)
					end
				else
					-- item for unknown device?
					log.Error("Item %s has unknown deviceId %s.", result._id, (result.deviceId or "??"))
				end	
			end
		elseif msg_subclass == "hub.device.updated" then
			if result._id then
				local deviceMap = EzloData.deviceMap
				-- See if we know the device
				local vdevID = deviceMap[result._id]
				if vdevID then
					vdevID = vdevID + OFFSET	-- Map to local ID
					if result.armed ~= nil then
						-- A device gets armed or disarmed
						var.SetBoolean("Armed", result.armed, SID.sec_sensor, vdevID)
					elseif result.reachable ~= nil then
					--"result":{"_id":"5eec9729124c4111c7e4d113","reachable":false,"serviceNotification":false,"syncNotification":false}
--log.Debug ("Device %s [%d] reachable: Result %s", result._id, vdevID , tostring(result.reachable) or "")
						set_device_reachable_status(result.reachable, vdevID)
					elseif result.status ~= nil then
						set_device_reachable_status(result.status, vdevID)
					else
--log.Debug ("Device Updated: Result " .. tostring(json.encode(result) or""))
					end
				else
					-- item for unknown device?
					log.Error("Device %s is not mapped to Vera device.", result._id)
				end	
			end
		elseif msg_subclass == "hub.modes.switched" then
			-- See if mode change is done initiated by Hub, then we update here.
			if result.status == "done" then
				-- Currently house modes map identical between Vera and Ezlo FW.
				UpdateHouseMode (result.to)
			elseif result.status == "begin" then
				-- Ignore for now.
			else
--log.Debug ("Hub Mode Switch Result " .. tostring(json.encode(result) or""))
			end
		elseif msg_subclass == "hub.device.removed" then
			-- A device got removed from Hub, restart sync?
			local autoStart = var.GetBoolean("AutoStartOnChange")
			if autoStart then
			-- to-do, 
			end
		elseif msg_subclass == "hub.device.added" then
			-- A device got added to Hub, restart to sync?
			if result.plugin == "zwave" and result.event == "include_finished" then
				local autoStart = var.GetBoolean("AutoStartOnChange")
				if autoStart then
				-- to-do, 
				end
			end
		else
			-- other message we do not yet handle or need to
			log.Debug ("Hub broadcast for message %s.", tostring(msg_subclass or ""))
			log.Debug ("      Result %s", tostring(json.encode(result) or""))
		end	
	else
		log.Log("Hub broadcast message ignored, device not yet ready.")
	end
	return true
end

-- Handlers for method responses
local function MethodHandler(method,result)
	if method == "hub.offline.login.ui" then
		log.Debug ("logged on to hub locally.")
		if EzloData.is_ready then
			-- Reconnect, so skip to rooms.
			log.Debug("Send list room")
			ezlo.Send({ method = "hub.room.list" })
		else
			-- Ask for hub information at startup
			log.Debug("Send get hub info")
			ezlo.Send({ method = "hub.info.get" })
		end	
	elseif method == "hub.info.get" then
		-- Hub info received, start building user_data like structure.
		EzloData.Vera = {}
		EzloData.Vera.PK_AccessPoint = result.serial
		EzloData.Vera.BuildVersion = result.firmware
		EzloData.Vera.model = result.model

		-- Set user ID like structure usind login user ID.
		EzloData.Vera.users = { id = 111111, Name = EzloHubUserID, Level = 1, IsGuest = 0 }

		-- Ask for rooms list for next step. Maybe skip when CloneRooms is false?
		log.Debug("Send list room")
		ezlo.Send({ method = "hub.room.list" })
	elseif method == "hub.room.list" then
		-- Rooms list received. See if we need to clone rooms.
		EzloData.Vera.rooms = {}
		-- Determine next Vera stype room number to assign.
		local Room_Num_Next = 1
		local roomMap = var.GetJson("Ezlo_roomMap")
		local roomsToRemove = var.GetJson("Ezlo_roomMap")
		if roomMap.Room_Num_Next then
			Room_Num_Next = roomMap.Room_Num_Next
		end
		-- Loop over Ezlo devices and create Vera like structure.
		for _, erm in pairs(result) do
			-- See if we know the device
			local vroomID = roomMap[erm._id]
			if vroomID then
			else
				vroomID = Room_Num_Next
				roomMap[erm._id] = vroomID
				Room_Num_Next = Room_Num_Next + 1
			end
			-- Make Vera like room structure
			local room = {}
			room.id = vroomID
			room.name = erm.name
			room.section = 1
			room.posx = 0
			room.posy = 0
			room.width = 4
			room.height = 4
			-- Add to list
			table.insert(EzloData.Vera.rooms, room)
			roomsToRemove[erm._id] = nil
		end
		roomMap = utils.PurgeList(roomMap, roomsToRemove)
		roomMap.Room_Num_Next = Room_Num_Next
		EzloData.roomMap = roomMap
--log.Debug("Number of rooms mapped to Vera "..#EzloData.Vera.rooms)
--log.Debug("EzloData.Vera.rooms"..json.encode(EzloData.Vera.rooms))
		var.SetJson("Ezlo_roomMap",roomMap)

		-- Request scenes for next step
		log.Debug("Send list scenes")
		ezlo.Send({ method = "hub.scenes.list" })
	elseif method == "hub.scenes.list" then
		-- Scenes list received, create local scenes
		EzloData.Vera.scenes = {}
		local roomMap = EzloData.roomMap
		-- Determine next Vera type scene number to assign.
		local Scene_Num_Next = 1
		local sceneMap = var.GetJson("Ezlo_sceneMap")
		local scenesToRemove = var.GetJson("Ezlo_sceneMap")
		if sceneMap.Scene_Num_Next then
			Scene_Num_Next = sceneMap.Scene_Num_Next
		end
		-- Loop over Ezlo devices and create Vera like structure.
		for _, escn in pairs(result.scenes) do
			-- See if we know the device
			local vscnID = sceneMap[escn._id]
			if vscnID then
			else
				vscnID = Scene_Num_Next
				sceneMap[escn._id] = vscnID
				Scene_Num_Next = Scene_Num_Next + 1
			end
			-- Make Vera like scene structure
			local scene = {}
			scene.id = vscnID
			scene.name = escn.name
			scene.room = tostring(roomMap[escn.parent_id] or 0)
			scene.groups = {}  -- Is action
			scene.triggers = {}
			scene.onDashboard = 0
			--scene.last_run = 
			--scene.Timestamp = 
			-- Add to list
			table.insert(EzloData.Vera.scenes, scene)
			-- Remove existing scene from to remove list
			scenesToRemove[escn._id] = nil
		end
		sceneMap = utils.PurgeList(sceneMap, scenesToRemove)
		sceneMap.Scene_Num_Next = Scene_Num_Next
		EzloData.sceneMap = sceneMap
--log.Debug("Number of scenes mapped to Vera "..#EzloData.Vera.scenes)
--log.Debug("EzloData.Vera.scenes"..json.encode(EzloData.Vera.scenes))
		var.SetJson("Ezlo_sceneMap", sceneMap)

		-- Ask for house mode as next step. 
		log.Debug("Send get house mode")
		ezlo.Send({ method = "hub.modes.get" })
	elseif method == "hub.modes.get" then
		-- House mode received. Currently maps like for like to Vera mode number.
		local mode = "1"
		if result then
			mode = result.current or "1"
		end	
		EzloData.Vera.Mode = tostring(mode)
		
		-- Ask for Devices list
		log.Debug("Send list devices")
		ezlo.Send({ method = "hub.devices.list" })
	elseif method == "hub.devices.list" then
		-- Device list received
		if EzloData.is_ready then
			-- Refresh device status details
			local deviceMap = var.GetJson("Ezlo_deviceMap")
			for _, edev in pairs(result.devices) do
				-- Do we have wrong _id data key? Seen one log where this is the case
				if edev._id == nil and edev.id then edev._id = edev.id end
				-- See if we know the device
				local vdevID = deviceMap[edev._id]
				if vdevID then
					vdevID = vdevID + OFFSET
					-- Look for status updates we might have missed.
					if edev.status == "broken" then
						set_device_reachable_status("broken", vdevID)
					elseif edev.reachable ~= nil then
						set_device_reachable_status(edev.reachable, vdevID)
					end
					if edev.armed ~= nil then
						var.SetBoolean("Armed", edev.armed, SID.sec_sensor, vdevID)
					end
					if var.GetAttribute("name", vdevID) ~= edev.name then
						var.SetAttribute("name", edev.name, vdevID)
					end
				else
					log.Warning("New device on hub not shown. _id %s, name %s", edev._id, edev.name)
				end
			end
		else
			-- Build Vera like devices structure.
			EzloData.Vera.devices = {}
			local roomMap = EzloData.roomMap
			-- Determine next Vera stype device number to assign. We start at 4.
			local deviceMap = var.GetJson("Ezlo_deviceMap")
			local devicesToRemove = var.GetJson("Ezlo_deviceMap")
			local Device_Num_Next = 4
			if deviceMap.Device_Num_Next then
				Device_Num_Next = deviceMap.Device_Num_Next
			end
			local reverseDeviceMap = {}
			-- Loop over Ezlo devices and create Vera like structure.
--log.Debug(json.encode(result.devices))
			for _, edev in pairs(result.devices) do
				-- Do we have wrong _id data key? Seen one log where this is the case
				if edev._id == nil and edev.id then edev._id = edev.id end
				-- See if we know the device
				local vdevID = deviceMap[edev._id]
				if vdevID then
				else
					vdevID = Device_Num_Next
					deviceMap[edev._id] = vdevID
					Device_Num_Next = Device_Num_Next + 1
				end
				-- Capture device, and later the items with a Setter to use in actions.
				reverseDeviceMap[vdevID] = {}
				reverseDeviceMap[vdevID].id = edev._id
				reverseDeviceMap[vdevID].items = {}
				local cmap = EzloDeviceMapping[edev.category]
				if cmap then
					local map = {}
					if cmap.device_type	then map.device_type = cmap.device_type end
					if cmap.device_json	then map.device_json = cmap.device_json end
					if cmap.device_file	then map.device_file = cmap.device_file end
					if cmap.subcategory_num	then map.subcategory_num = cmap.subcategory_num end
					if edev.subcategory ~= "" then
						-- If we have subcategory definition overrule on base map.
						local smap = cmap[edev.subcategory]
						if smap then
							if smap.device_type	then map.device_type = smap.device_type end
							if smap.device_json	then map.device_json = smap.device_json end
							if smap.device_file	then map.device_file = smap.device_file end
							if smap.subcategory_num	then map.subcategory_num = smap.subcategory_num end
						end
					end	
					-- Build Vera like device structure
					local vdev = {}
					local parentId = edev.parentDeviceId == "" and 1 or 1 -- Later to see if can have other parent.
					vdev.id = vdevID
					vdev.category_num = map.category_num
					vdev.device_type = map.device_type
					vdev.internal_id = edev._id
					vdev.invisible = false
					vdev.device_json = map.device_json
					vdev.name = edev.name
					vdev.device_file = map.device_file
					vdev.impl_file = '' -- Not used
					vdev.id_parent = parentId
					vdev.room = tostring(roomMap[edev.roomId] or 0)
					vdev.states = {}
					vdev.subcategory_num = map.subcategory_num or 0
					-- Armed is set here and not as item, so add that state if needed
					if edev.armed ~= nil then
						local val = edev.armed and "1" or "0"
						vdev.states = {{ id = 1, service = SID.sec_sensor, variable = "Armed", value = val }}
					end
					-- See if we have device info (only Linux, not on RTOS)
					if type(edev.info) == "table" then
						vdev.manufacturer = edev.info.manufacturer
						vdev.model = edev.info.model
					end
					-- See if device is reachable, we add our onw flag as status cannot be used.
					vdev.status = -1
					if edev.status == "broken" then
						vdev.status = 2
					elseif edev.reachable ~= nil then
						vdev.status = (edev.reachable and -1 or 2)
					end
					-- Add to list
					table.insert(EzloData.Vera.devices, vdev)
				else
					log.Log("No Vera device definition found for Ezlo category %s, subcategory %s.", (edev.category or ""), (edev.subcategory or ""))
				end
				devicesToRemove[edev._id] = nil
			end
			-- Loop over devices again to look for child devices. 
			for _, edev in pairs(result.devices) do
				-- We must know the device
				if edev.parentDeviceId ~= "" then
					-- Do we have wrong _id data key? Seen one log where this is the case
					if edev._id == nil and edev.id then edev._id = edev.id end
					local vdevID = deviceMap[edev._id]
					if vdevID then
						local parent_id = deviceMap[edev.parentDeviceId]
						if parent_id then
							-- look up Vera device details
							for _, dev in pairs(EzloData.Vera.devices) do
								if dev.id == vdevID then
									dev.id_parent = parent_id
									break
								end
							end
						else
							log.Log("Unknown Ezlo parent device %s.", edev.parentDeviceId)
						end
					else	
						-- unknown device?
						log.Error("Unknown Ezlo device %s.", edev._id,2)
					end
				end
			end	
			deviceMap = utils.PurgeList(deviceMap, devicesToRemove)
			EzloData.Vera.Device_Num_Next = Device_Num_Next
			EzloData.deviceMap = deviceMap
			EzloData.reverseDeviceMap = reverseDeviceMap
			deviceMap.Device_Num_Next = Device_Num_Next
--log.Debug("Number of devices mapped to Vera %d.",#EzloData.Vera.devices)
--log.Debug("EzloData.Vera.devices "..(json.encode(EzloData.Vera.devices) or "cannot encode"))
			var.SetJson("Ezlo_deviceMap", deviceMap)
		end
		-- Ask for items list for device variables
		log.Debug("Send list items")
		ezlo.Send({ method = "hub.items.list" })
	elseif method == "hub.items.list" then
		-- Items list received, update device variable values.
		local deviceMap = EzloData.deviceMap
		-- Loop over Ezlo devices and create Vera like structure.
		for _, eitem in pairs(result.items) do
			-- We are only looking for items with 'Getters' that return a value, or Setters that set a value as result of a Vera device action.
			if eitem.hasGetter or eitem.hasSetter then
				-- See if we know the device
				local vdevID = deviceMap[eitem.deviceId]
				if vdevID then
--log.Debug("Existing device "..eitem.deviceId.. " mapping to "..vdevID)
					-- Get the device details to add states to.
					local device = nil
					for _, dev in pairs(EzloData.Vera.devices) do
						if dev.id == vdevID then
							device = dev
							break
						end
					end
					if device then
						local state = {}
						-- Map Ezlo item to Vera service Variable.
						local vstate = mapItem(eitem, vdevID)
--log.Debug("Item: %s",json.encode(eitem))						
--log.Debug("Mapped State: %s",json.encode(vstate))						
						-- If item has getter we should read the value to a Vera state variable.
						if eitem.hasGetter then
							if vstate then
								if vstate.service then
									-- Only add if there is a service.
									state.id = #device.states + 1
									state.service = vstate.service
									state.variable = vstate.variable
									state.value = vstate.value
									if EzloData.is_ready then
										-- Refresh values
										var.SetString(state.variable, state.value, state.service, vdevID + OFFSET)
									else
										table.insert(device.states, state)
									end	
									if vstate.variable == "Tripped" and vstate.tripvalue then
										-- Handle sensor tripped item. Add the ArmedTripped and LastTrip states
										local at = "0"
--										local lt = 0	-- We do not know LastTrip time, so wait on event to set.
										if vstate.value == "1" then
											-- We have added Armed as first state to the device.
											--	vdev.states = {{ id = 1, service = SID.sec_sensor, variable = "Armed", value = val }}
											local at = device.states[1].value or "0"
--											lt = os.time()
										end
										local ts = {}
										ts.id = #device.states + 1
										ts.service = vstate.service
										ts.variable = "ArmedTripped"
										ts.value = at
										if EzloData.is_ready then
											-- Refresh values
											var.SetString(state.variable, state.value, state.service, vdevID + OFFSET)
										else
											table.insert(device.states, ts)
										end	
--										ts.id = #device.states + 1
--										ts.variable = "LastTrip"
--										ts.value = lt
--										table.insert(device.states, ts)
									end
								else
									log.Info("No service mapping for device %s, name %s. Ignoring.", eitem.deviceId, eitem.name)
								end
							else
								-- We don't know what it is, make generic sensor (we can use this rather then defining all items)
								state.id = #device.states + 1
								state.service = SID.gen_sensor 
								state.variable = "CurrentLevel"
								state.value = eitem.valueFormatted or "??"
								if EzloData.is_ready then
									-- Refresh values
									var.SetString(state.variable, state.value, state.service, vdevID + OFFSET)
								else
									table.insert(device.states, state)
								end	
							end
							-- We have many state types that do not map to Vera so we use a generic sensor CurrentLevel
							-- Put some extra info in DisplayLine1 for the user.
							if state.service == SID.gen_sensor and state.variable == "CurrentLevel" then
								local state = {}
								state.id = #device.states + 1
								state.service = SID.altui
								state.variable = "DisplayLine1"
								local line = eitem.name
								line = string.upper(line:sub(1,1))..line:sub(2)
								state.value = line:gsub("_"," ") .. " : " .. (eitem.valueFormatted or "") .. " " .. (eitem.scale or "")
								if EzloData.is_ready then
									-- Refresh values
									var.SetString(state.variable, state.value, state.service, vdevID + OFFSET)
								else
									table.insert(device.states, state)
								end	
							end
						end	
						-- item Setter (action)
						if eitem.hasSetter and not EzloData.is_ready then
							-- Capture name to deviceId map for action use.
							if EzloData.reverseDeviceMap[vdevID] then
								EzloData.reverseDeviceMap[vdevID].items[eitem.name] = eitem._id
							end	
						end
					else
						-- No device with deviceID found? (should not happen)
						log.Error("No device found for device id %d.", vdevID)
					end	
				else
					-- item for unknown device?
					log.Error("Item %s has unknown deviceId %s.", eitem._id, eitem.deviceId)
				end	
			else	
				-- item has no getter or setter. Should not happen.
				log.Error("Item %s has no Getter or Setter, name %s.", (eitem._id or "unknown"), (eitem.name or ""))
			end
		end -- for
--log.Debug("EzloData"..json.encode(EzloData))
--log.Debug("EzloData.reverseDeviceMap "..(json.encode(EzloData.reverseDeviceMap) or "cannot encode"))
		if not EzloData.is_ready then
			-- We have all data to create Ezlo mirror.
			local Ndev, Nscn
			Ndev, Nscn, BuildVersion, PK_AccessPoint, LoadTime = GetUserData ()
			if PK_AccessPoint then
				if HouseModeMirror == '2' then
					ezlo.SetPingCommand({ method = "hub.modes.current.get" })
				end	
				var.SetString("PK_AccessPoint", PK_AccessPoint)
				var.SetString("Remote_ID", PK_AccessPoint, SID.bridge)
				var.SetNumber("LoadTime", LoadTime or 0)
				utils.SetDisplayLine(Ndev.." devices, " .. Nscn .. " scenes", 1)
				UpdateHouseMode (EzloData.Vera.Mode)
				if Ndev > 0 or Nscn > 0 then
					-- Say we are ready to start processing incoming messages
log.Debug("Flag that connection is ready")
					EzloData.is_ready = true
				end
			else
				utils.SetDisplayLine("No valid Ezlo Hub", 2)
			end
		else
			log.Debug("Get current house mode")
			ezlo.Send({ method = "hub.modes.current.get" })
		end
		-- Keep last update time
		lastFullStatusUpdate = os.time()
	elseif method == "hub.modes.switch"then
		-- Response when sending command to Hub.
		log.Debug ("Hub Mode Switch Result " .. tostring(json.encode(result) or""))
	elseif method == "hub.modes.current.get" then
		-- if HouseModeMirror == 2 then see if local changed and we need to update remote
		if HouseModeMirror == '2' then
			-- House mode received. Currently maps like for like to Vera mode number.
			local mode = 1
			if result then
				mode = result.modeId or 1
			end
			UpdateHouseMode (mode)
		end	
	else
		log.Debug("EzloMessageHandler, unhandled response has method %s.", tostring(method or "")) 
		log.Debug("     Result " .. tostring(json.encode(result) or""))
	end
	return true
end

-- Create the device varaibles at first run
local function CreateDeviceVariables()
	var.Default ("BridgeScenes", 1)		-- if set to 1 then create scenes that will run the scenes on remote.
	var.Default ("CloneRooms", 0)		-- if set to 0 then clone rooms and place devices there
	var.Default ("ZWaveOnly", 1)		-- if set to 1 then only Z-Wave devices are considered by EzloBridge.
	var.Default ("IncludeDevices", "")	-- list of devices to include even if ZWaveOnly is set to true.
	var.Default ("ExcludeDevices", "")	-- list of devices to exclude from synchronization by EzloBridge, 
															-- ...takes precedence over the first two.
	var.Default ("AutoStartOnChange", 0)-- if set to 1 then adding or removing a device from teh hub will trigger a luup reload.
	var.Default ("RemotePort", 17000)
	var.Default ("CheckAllEveryNth", 600)-- periodic request for ALL variables to check status
	var.Default ("HouseModeMirror", 0)
    var.Default ("UserID", "")			-- UserID to logon to portal for this Ezlo
    var.Default ("Password", "")		-- Password
    var.Default ("HubSerial", "")		-- Ezlo Serial #
    var.Default ("HubToken", "")		-- Will hold Token after logon
    var.Default ("TokenExpires", 0)		-- Will hold Token expiration timestamp
    var.Default ("WssUserID", "")		-- Will hold wss userID after logon     
    var.Default ("WssToken", "")		-- Will hold wss Token after logon
end

-- plugin startup
function init (lul_device)
	devNo = lul_device
	EzloData.is_ready = false		-- Flag not to process incoming UI.broadcast or send messages until ready. I.e. Scenes & Devices created.
	-- start Utility API's
	json = jsonAPI()
	log = logAPI()
	var = varAPI()
	utils = utilsAPI()
	ezlo = ezloAPI()
	json.Initialize()
	var.Initialize(SID.gateway, devNo)
	utils.Initialize()
	var.Default("LogLevel", 1)
	lastFullStatusUpdate = 0
	log.Initialize(ABOUT.NAME, var.GetNumber("LogLevel"),(utils.GetUI() == utils.IsOpenLuup))
	log.Log("%s device #%s is initializing!", ABOUT.NAME, devNo)
	var.SetString("Version", ABOUT.VERSION)
	log.Log("Version %s.", ABOUT.VERSION)
	-- See if we are running on openLuup.
	if (utils.GetUI() == utils.IsOpenLuup) then
		log.Log("We are running on openLuup.")
	else	
		log.Log("We are running on Vera UI%s.",utils.GetUI())
--		if utils.GetUI() < utils.IsUI7 then
			local status_msg = "Vera is not supported."
			log.Error(status_msg)
			utils.SetDisplayLine(status_msg, 1)
			utils.SetDisplayLine("", 2)
			luup.set_failure (0)
			return false, status_msg, ABOUT.NAME
--		end	
		-- Do not need to check on openLuup as it will not run code if device is disabled.
--		if var.GetAttribute("disabled", devNo) == 1 then
--			local status_msg = "Disabled in attributes."
--			log.Warning(status_msg)
--			utils.SetDisplayLine(status_msg, 1)
--			utils.SetDisplayLine("", 2)
--			luup.set_failure (0)
--			return false, status_msg, ABOUT.NAME
--		end
	end
 
	ip = var.GetAttribute("ip", devNo)
	log.Log("Bridging to %s", ip)
	ezlo.Initialize(var.GetNumber("LogLevel")>=10)
	-------
	-- 2020.02.12 use existing Bridge offset, if defined.
	-- this way, it doesn't matter if other bridges get deleted, we keep the same value
	-- see: https://community.getvera.com/t/openluup-suggestions/189405/199
--[[
	-- establish next base device number for child devices 
	note: does not work correctly if there is a bridge w/o devices, it will create a duplicate
	function bridge_utilities.nextIdBlock ()
		-- 2020.02.12 simply calculate the next higher free block
		local maxId = 0
		for i in pairs (luup.devices) do maxId = (i > maxId) and i or maxId end     -- max device id
		local maxBlock = math.floor (maxId / BLOCKSIZE)                             -- max block
		return (maxBlock + 1) * BLOCKSIZE                                           -- new block offset
	end
]]
	OFFSET = var.GetNumber("Offset")
	if not OFFSET then
		-- Indication of first run, create variables
		CreateDeviceVariables()
		OFFSET = luup.openLuup.bridge.nextIdBlock()
		var.SetNumber("Offset", OFFSET)
	end
	log.Info("device clone numbering starts at %d.", OFFSET)

	-- User configuration parameters
	BridgeScenes		= var.GetBoolean("BridgeScenes")
	CloneRooms	 		= var.GetBoolean("CloneRooms")
	ZWaveOnly			= var.GetBoolean("ZWaveOnly")
	Included			= var.GetSet("IncludeDevices")
	Excluded			= var.GetSet("ExcludeDevices")
	RemotePort			= var.GetNumber("RemotePort")
	CheckAllEveryNth	= var.GetNumber("CheckAllEveryNth")
	HouseModeMirror		= var.GetNumber("HouseModeMirror")
    EzloHubUserID		= var.GetString("UserID")
    local Password		= var.GetString("Password")
    local Serial		= var.GetString("HubSerial")
    local HubToken		= var.GetString("HubToken")
    local TokenExpires	= var.GetNumber("TokenExpires")
    local WssUserID		= var.GetString("WssUserID")
    local WssToken		= var.GetString("WssToken")
  
	-- map remote Zwave controller device if we are the primary VeraBridge 
	if OFFSET == BLOCKSIZE then 
		Zwave = {1}                                 -- device IDs for mapping (same value on local and remote)
		set_parent_and_handle_children (1, devNo)   -- ensure Zwave controller is an existing child 
		log.Log("EzloBridge maps remote Zwave controller")
	end
	luup.devices[devNo].action_callback(generic_action)     -- catch all undefined action calls
	local status = true
	local status_msg = "OK"
  
--	ZWaveOnly = true
--	var.SetBoolean ("ZWaveOnly", true)
	
	-- Make sure we have user credentials and Hub IP
	if EzloHubUserID ~= "" and Password ~= "" and Serial ~= "" and ip ~= "" then
		-- Logon to Ezlo hub and kick off messaging
		utils.SetDisplayLine("Connecting to Ezlo Hub...", 1)
		-- Register incoming message handlers
		-- Examples of specific handlers
		--	ezlo.RegisterMethodHandler("hub.info.get", MethodHandler)
		--	ezlo.RegisterMethodHandler("hub.devices.list", MethodHandler)
		--	ezlo.RegisterMethodHandler("hub.items.list", MethodHandler)
		--	ezlo.RegisterMethodHandler("hub.room.list", MethodHandler)
		--	ezlo.RegisterMethodHandler("hub.scenes.list", MethodHandler)
		-- Set generic handlers
		ezlo.RegisterMethodHandler("*", MethodHandler)
		ezlo.RegisterErrorHandler("*", ErrorHandler)
		ezlo.RegisterBroadcastHandler("*", BroadcastHandler)
	
		-- No token stored, so logon to portal to obtain and sync with hub
		if WssToken == '' or WssUserID == '' or TokenExpires == 0 then
			utils.SetDisplayLine("Getting tokens from Ezlo Portal", 2)
			local stat
			stat, WssToken, WssUserID, TokenExpires = ezlo.PortalLogin (EzloHubUserID, Password, Serial)
			if not stat then
				log.Error("Unable to logon to portal %s.", WssToken)
				status_msg = "Unable to logon to Ezlo portal"
				utils.SetDisplayLine(status_msg, 2)
				luup.set_failure (2)                          -- say it's an authentication error
				return false, status_msg, ABOUT.NAME
			end	
			-- Store keys for reuse untill error or token expires
			var.SetString("WssUserID", WssUserID)
			var.SetString("WssToken", WssToken)
			var.SetNumber("TokenExpires", TokenExpires)
		else
			log.Debug("Using stored credentials.")
		end
		log.Debug(os.date("Token expires : %c", TokenExpires))

		-- Open web socket connection
		utils.SetDisplayLine("Opening web-socket to Hub.", 2)
		local res, msg = ezlo.Connect (ip, WssToken, WssUserID)
		if not res then
			log.Error("Could not connect to Hub, %s.", (msg or ""))
			-- Erase stored keys
			var.SetString("WssUserID", "")
			var.SetString("WssToken", "")
			var.SetNumber("TokenExpires", 0)
			status_msg = "Unable to connect to Hub"
			utils.SetDisplayLine(status_msg, 2)
			luup.set_failure (2)                          -- say it's an authentication error
			return false, status_msg, ABOUT.NAME
		end
		-- The Hub login response from the Hub will trigger the rest of the processing
		utils.SetDisplayLine("Getting devices and scenes...", 1)
		utils.SetDisplayLine(ip, 2)

		-- Kick off message scheduler (poll each second for incoming data)
		res, msg = ezlo.StartPoller()
		-- Start watch dog that will do a full status pull on scheduled interval.
		luup.call_delay("EzloBridge_async_watchdog", CheckAllEveryNth, CheckAllEveryNth)
		
		luup.set_failure (0)                        -- all's well with the world
	else
		luup.set_failure (2)                        -- say it's an authentication error
		status = false
		status_msg = "No Ezlo, check uid, pwd, ip."
		utils.SetDisplayLine(status_msg, 2)
	end
	return status, status_msg, ABOUT.NAME
end
