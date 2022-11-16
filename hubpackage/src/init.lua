--[[
  Copyright 2021 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  HTTP Devices: execute web requests for specific device type commands

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"                 -- just for time
local socket = require "cosock.socket"          -- just for time
local http = cosock.asyncify "socket.http"
local https = cosock.asyncify "ssl.https"
http.TIMEOUT = 3
https.TIMEOUT = 3
local ltn12 = require "ltn12"
local log = require "log"

-- Module variables
local thisDriver = {}
local creator_initialized = false
local http_requests = {}
local creator_device
local clearcreatemsg_timer

-- Constants
local CREATOR_PROFILE = 'httpcreator.v2'
local CREATOR_CAPABILITY = 'partyvoice23922.createhttpdev2b'

-- Custom capabilities
local cap_createdev = capabilities[CREATOR_CAPABILITY]
local cap_httpcode = capabilities["partyvoice23922.httpcode"]


local typemeta =  {
                    ['Switch']     = { ['profile'] = 'httpswitch.v1',        ['capability'] = 'switch' },
                    ['Button']     = { ['profile'] = 'httpbutton.v1',        ['capability'] = 'momentary' },
                    ['Alarm']      = { ['profile'] = 'httpalarm.v1',         ['capability'] = 'alarm' },
                    ['Dimmer']     = { ['profile'] = 'httpdimmer.v1',        ['capability'] = 'switchLevel' },
                    ['Motion']     = { ['profile'] = 'httpmotion.v1',        ['capability'] = 'switch' },
                    ['Contact']    = { ['profile'] = 'httpcontact.v1',       ['capability'] = 'switch' },
                  }


local function create_device(driver, dtype)

  if dtype then

    local PROFILE = typemeta[dtype].profile
    if PROFILE then
    
      local MFG_NAME = 'SmartThings Community'
      local MODEL = 'httptdev_' .. dtype
      local LABEL = 'HTTP ' .. dtype
      local ID = 'HTTP_' .. dtype .. '_' .. tostring(socket.gettime())

      log.info (string.format('Creating new device: label=<%s>, id=<%s>', LABEL, ID))
      if clearcreatemsg_timer then
        driver:cancel_timer(clearcreatemsg_timer)
      end

      local create_device_msg = {
                                  type = "LAN",
                                  device_network_id = ID,
                                  label = LABEL,
                                  profile = PROFILE,
                                  manufacturer = MFG_NAME,
                                  model = MODEL,
                                  vendor_provided_label = LABEL,
                                }

      assert (driver:try_create_device(create_device_msg), "failed to create device")
    end
  end
end


local function validate_address(lanAddress)

  local valid = true
  
  local ip = lanAddress:match('^(%d.+):')
  local port = tonumber(lanAddress:match(':(%d+)$'))
  
  if ip then
    local chunks = {ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
    if #chunks == 4 then
      for _, v in pairs(chunks) do
        if tonumber(v) > 255 then 
          valid = false
          break
        end
      end
    else
      valid = false
    end
  else
    valid = false
  end
  
  if port then
    if type(port) == 'number' then
      if (port < 1) or (port > 65535) then 
        valid = false
      end
    else
      valid = false
    end
  else
    valid = false
  end
  
  if valid then
    return ip, port
  else
    return nil
  end
      
end

-- Validate provided http request string
local function validate(input, silent)

  local msg
  local method = string.upper(input:match('(%a+):'))
  local url = input:match(':(.+)')
  
  if (method == 'GET') or (method == 'POST') or (method == 'PUT') then

    local protocol = url:match('^(%a+):')
    if (protocol == 'http') or (protocol == 'https') then
    
      local skiplen
      if protocol == 'http' then; skiplen = 8; end
      if protocol == 'https' then; skiplen = 9; end
      
      local startpath = url:find('/', skiplen+1)
      local urladdr
      
      if startpath ~= nil then
        urladdr = url:sub(skiplen, startpath-1)
      else
        urladdr = url:sub(skiplen)
      end

      -- if no port given, default it to :80
      if not urladdr:match(':%d+$') then
        urladdr = urladdr .. ':80'
      end
      
      if validate_address(urladdr) then
        return method, url
      else
        msg = 'Invalid IP:Port address provided'
      end

    else
      msg = "URL does not start with 'http://' or 'https://'"
    end
  else
    msg = "Request string does not start with valid method ('GET:' or 'POST:' or 'PUT:')"
  end
  
  if not silent then; log.warn (msg); end
  return nil
  
end

local function normalize(parm)

  if parm == 'null' or parm == '--' or parm == '' then
    return nil
  else
    return parm
  end

end

local function devtype(device)

  if device.device_network_id:find('Master', 1, 'plaintext') then
    return 'Master'
  
  else
    return device.device_network_id:match('HTTP_(.+)_+')
  end

end

local function addheaders(headerlist)

  local found_accept = false
  local headers = {}

  if headerlist then
    
    local items = {}
    
    for element in string.gmatch(headerlist, '([^,]+)') do
      table.insert(items, element);
    end
    
    local i = 0
    for _, header in ipairs(items) do
      key, value = header:match('([^=]+)=([^=]+)$')
      key = key:gsub("%s+", "")
      value = value:match'^%s*(.*)'
      if key and value then
        headers[key] = value
        if string.lower(key) == 'accept' then; found_accept = true; end
      end
    end
  end
  
  if not found_accept then
    headers["Accept"] = '*/*'
  end
  
  return headers
end

-- Send http or https request and emit response, or handle errors
local function issue_request(device, req_method, req_url, sendbody, optheaders)

  local responsechunks = {}
  local body, code, headers, status
  
  local protocol = req_url:match('^(%a+):')
  
  if protocol == 'https' then
    https.TIMEOUT = device.preferences.timeout
  elseif protocol == 'http' then
    http.TIMEOUT = device.preferences.timeout
  end
  
  local sendheaders = addheaders(optheaders)
  
  if sendbody then
    sendheaders["Content-Length"] = string.len(sendbody)
  end
  
  if protocol == 'https' and sendbody then
  
    body, code, headers, status = https.request{
      method = req_method,
      url = req_url,
      headers = sendheaders,
      protocol = "any",
      options =  {"all"},
      verify = "none",
      source = ltn12.source.string(sendbody),
      sink = ltn12.sink.table(responsechunks)
     }

  elseif protocol == 'https' then
  
    body, code, headers, status = https.request{
      method = req_method,
      url = req_url,
      headers = sendheaders,
      protocol = "any",
      options =  {"all"},
      verify = "none",
      sink = ltn12.sink.table(responsechunks)
     }

  elseif protocol == 'http' and sendbody then
    body, code, headers, status = http.request{
      method = req_method,
      url = req_url,
      headers = sendheaders,
      source = ltn12.source.string(sendbody),
      sink = ltn12.sink.table(responsechunks)
     }
     
  else
    body, code, headers, status = http.request{
      method = req_method,
      url = req_url,
      headers = sendheaders,
      sink = ltn12.sink.table(responsechunks)
     }
  end

  local response = table.concat(responsechunks)
  
  log.info(string.format("response code=<%s>, status=<%s>", code, status))
  
  local returnstatus = 'unknown'
  local httpcode_str
  local httpcode_num
  
  if type(code) == 'number' then
    httpcode_num = code
  else
    httpcode_str = code
  end
  
  if httpcode_num then
    device:emit_event(cap_httpcode.httpcode(tostring(httpcode_num)))
  end

  if httpcode_num then
    if (httpcode_num >= 200) and (httpcode_num < 300) then
      returnstatus = 'OK'
      log.debug (string.format('Response:\n>>>%s<<<', response))
      
    else
      log.warn (string.format("HTTP %s request to %s failed with http code %s, status: %s", req_method, req_url, tostring(httpcode_num), status))
      returnstatus = 'Failed'
    end
  
  else
    
    if httpcode_str then
      if string.find(httpcode_str, "closed") then
        log.warn ("Socket closed unexpectedly")
        returnstatus = "No response"
      elseif string.find(httpcode_str, "refused") then
        log.warn("Connection refused: ", req_url)
        returnstatus = "Refused"
      elseif string.find(httpcode_str, "timeout") then
        log.warn("HTTP request timed out: ", req_url)
        returnstatus = "Timeout"
      else
        log.error (string.format("HTTP %s request to %s failed with code: %s, status: %s", req_method, req_url, httpcode_str, status))
        returnstatus = 'Failed'
      end
    else
      log.warn ("No response code returned")
      returnstatus = "No response code"
    end

  end

  return returnstatus
  
end

local function build_request(device, cmd)
  
  http_requests[device.id][cmd] = {}
  
  local req = device.preferences[cmd..'requesta']
  
  local method, url = validate(req, false)
  
  if url ~= nil then
    log.info (string.format('Request string is valid: %s', req))
  
    local url_b = normalize(device.preferences[cmd..'requestb'])
    if url_b then
      url = url .. url_b
    end

    local body = normalize(device.preferences[cmd..'bodya'])
    local body_b = normalize(device.preferences[cmd..'bodyb'])
    if body_b then
      body = body .. body_b
    end
    
    local headers = normalize(device.preferences[cmd..'headers'])
    
    http_requests[device.id][cmd] = {['method'] = method, ['url'] = url, ['body'] = body, ['headers'] = headers}
    
  else
    log.warn (string.format('\tInvalid "%s" HTTP request ignored: %s', cmd, req))
    http_requests[device.id][cmd] = nil
    
  end
  
end


local function build_all_requests(device)

  local capability = typemeta[devtype(device)].capability
      
  for cmd, meta in pairs(capabilities[capability].commands) do
    build_request(device, meta.NAME)
  end

end


local function insertvar(varname, varval, instring)

  if instring then
    if instring:match(varname) then
      local index = instring:find(varname)
      local str_p1 = instring:sub(1, index-1)
      local str_p2 = instring:sub(index+varname:len())
      return str_p1 .. tostring(varval) .. str_p2
    else
      return instring
    end
  end
end


local function request_setup(device, command)

  if http_requests[device.id][command.command] then
  
    local url = http_requests[device.id][command.command].url
    local body = http_requests[device.id][command.command].body
    local headers = http_requests[device.id][command.command].headers
  
    if command.command == 'setLevel' then
      url = insertvar('${level}', command.args.level, url)
      body = insertvar('${level}', command.args.level, body)
    end
    
    log.info (string.format('SEND %s COMMAND: %s', http_requests[device.id][command.command].method, url))
    log.info (string.format('\twith body: %s', body))
    log.info (string.format('\twith headers: %s', headers))
    
    device.thread:queue_event(issue_request, device, http_requests[device.id][command.command].method, url, body, headers)
  
  else
    log.warn ('HTTP request not configured for', command.command)
    device:emit_event(cap_httpcode.httpcode('(not configured)'))
  end

end

-----------------------------------------------------------------------
--										COMMAND HANDLERS
-----------------------------------------------------------------------

local function handle_createdevice(driver, device, command)

  log.debug("Device type selection: ", command.args.value)

  device:emit_event(cap_createdev.deviceType('Creating device...'))

  create_device(driver, command.args.value)

end


local function handle_switch(driver, device, command)

  log.info ('Switch triggered:', command.command)
  
  device:emit_event(capabilities.switch.switch(command.command))
  
  if devtype(device) == 'Motion' then
    local motionstate
    if command.command == 'on' then
      motionstate = 'active'
      if device.preferences.autorevert then
        driver:call_with_delay(device.preferences.revertdelay, function()
            device:emit_event(capabilities.motionSensor.motion('inactive'))
            device:emit_event(capabilities.switch.switch('off'))
            if device.preferences.sendrevert then
              request_setup(device, {['command'] = 'off'})
            end
          end)
      end
    else
      motionstate = 'inactive'
    end
    device:emit_event(capabilities.motionSensor.motion(motionstate))
    
  elseif devtype(device) == 'Contact' then
    local contactstate
    if command.command == 'on' then
      contactstate = 'open'
    else
      contactstate = 'closed'
    end
    device:emit_event(capabilities.contactSensor.contact(contactstate))
  end
  
  request_setup(device, command)
    
end

local function handle_button(driver, device, command)

  log.info ('Button pressed:', command.command)
  
  device:emit_event(capabilities.button.button.pushed({state_change = true}))
  
  request_setup(device, command)
  
end

local function handle_alarm(driver, device, command)

  log.info ('Alarm triggered:', command.command)
  
  device:emit_event(capabilities.alarm.alarm(command.command))
  
  request_setup(device, command)

end

local function handle_dimmer(driver, device, command)

  log.info ('Dimmmer value changed to ', command.args.level)
  
  device:emit_event(capabilities.switchLevel.level(command.args.level))
  
  request_setup(device, command)
  
end

------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
  log.debug(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")
  
  log.debug ('Initializing Device type:', devtype(device))
  if devtype(device) == 'Master' then
  
    device:try_update_metadata({profile=CREATOR_PROFILE})
  
    creator_device = device
    device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false } }))
    
    creator_initialized = true
  
  else
    device:emit_event(cap_httpcode.httpcode(' ', { visibility = { displayed = false } }))
    
    http_requests[device.id] = {}
    
    build_all_requests(device)

  end
end


-- Called when device was just created in SmartThings
local function device_added (driver, device)

  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")

  local dtype = devtype(device)

  if dtype ~= 'Master' then

    if dtype == 'Switch' or dtype == 'Motion' or dtype == 'Contact' then
      device:emit_event(capabilities.switch.switch('off'))
    end
    
    if dtype == 'Dimmer' then
      device:emit_event(capabilities.switchLevel.level(0))
    elseif dtype == 'Button' then
      local supported_values =  {
                                  capabilities.button.button.pushed.NAME,
                                }
      device:emit_event(capabilities.button.supportedButtonValues(supported_values))
    elseif dtype == 'Alarm' then
      device:emit_event(capabilities.alarm.alarm('off'))
    elseif dtype == 'Motion' then
      device:emit_event(capabilities.motionSensor.motion('inactive'))
    elseif dtype == 'Contact' then
      device:emit_event(capabilities.contactSensor.contact('closed'))
    end
    
    creator_device:emit_event(cap_createdev.deviceType('Device created'))
    clearcreatemsg_timer = driver:call_with_delay(10, function()
        clearcreatemsg_timer = nil
        creator_device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false }}))
      end
    )

  end
  
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  -- Nothing to do here!

end


-- Called when device was deleted via mobile app
local function device_removed(_, device)
  
  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")
  
  if devtype(device) == 'Master' then
    creator_initialized = false
  end
  
end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked ***')

end

local function shutdown_handler(driver, event)

  log.info ('*** Driver being shut down ***')


end




local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')

  -- Did preferences change?
  if args.old_st_store.preferences then
  
    if devtype(device) ~= Master then
  
      -- Go ahead and rebuild all current preferences
  
      build_all_requests(device)
      
      device:emit_event(cap_httpcode.httpcode(' ', { visibility = { displayed = false } }))
  
    end
  else
    log.warn ('Old preferences missing')
  end  
     
end


-- Create Primary Creator Device
local function discovery_handler(driver, _, should_continue)

  if not creator_initialized then

    log.info("Creating HTTP Creator device")

    local MFG_NAME = 'SmartThings Community'
    local MODEL = 'HTTPCreatorV1'
    local VEND_LABEL = 'HTTP Device Creator V1' --update; change for testing
    local ID = 'HTTPDev_Masterv1'               --change for testing; must include 'Master'
    local PROFILE = CREATOR_PROFILE             --update; change for testing

    -- Create master creator device

    local create_device_msg = {
                                type = "LAN",
                                device_network_id = ID,
                                label = VEND_LABEL,
                                profile = PROFILE,
                                manufacturer = MFG_NAME,
                                model = MODEL,
                                vendor_provided_label = VEND_LABEL,
                              }

    assert (driver:try_create_device(create_device_msg), "failed to create creator device")

    log.debug("Exiting device creation")

  else
    log.info ('HTTP Creator device already created')
  end
end


-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
thisDriver = Driver("thisDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  driver_lifecycle = shutdown_handler,
  capability_handlers = {
    [cap_createdev.ID] = {
      [cap_createdev.commands.setDeviceType.NAME] = handle_createdevice,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch,
      [capabilities.switch.commands.off.NAME] = handle_switch,
    },
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = handle_button,
    },
    [capabilities.alarm.ID] = {
      [capabilities.alarm.commands.off.NAME] = handle_alarm,
      [capabilities.alarm.commands.siren.NAME] = handle_alarm,
      [capabilities.alarm.commands.strobe.NAME] = handle_alarm,
      [capabilities.alarm.commands.both.NAME] = handle_alarm,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_dimmer,
    },
  }
})

log.info ('HTTP Devices v1.1 Started')

thisDriver:run()
