local log = require("log");
local server = require("server");
local timer = require("timer");

local LOOP_INTERVAL = 5000;  -- 5 seconds

local btdevices_cache;
local list_items;
local timer_id;

-- https://stackoverflow.com/a/27028488
function dump(o)
  local k, v;
  if type(o) == 'table' then
     local s = '{'
     for k,v in pairs(o) do
        if type(k) ~= 'number' then k = '"'..k..'"' end
        s = s .. '['..k..'] = ' .. dump(v) .. ','
     end
     return s .. '} '
  else
     return tostring(o)
  end
end

function runcmd(cmd)
  local pout = "";
  local presult = 0;
  local perr = "";

  log.trace(string.format("running cmd: %q", cmd));
  local success, ex = pcall(function()
    pout, perr, presult = libs.script.shell(cmd);
  end);

  return success, pout, perr, presult, ex;
end

function split_lines(str)
  local lines = {};
  -- match everything except newlines
  for s in str:gmatch("[^\n]+") do
    table.insert(lines, s);
  end
  return lines;
end

function parse_device_line(line)
  local mac_addr, device_name = line:match("Device ([0-9A-Za-z:]+) (.*)");
  return mac_addr, device_name;
end

function bluetoothctl_devices()
  local success, pout, presult, perr, ex = runcmd("bluetoothctl devices");

  if not success then
    log.error("failed to get bluetooth devices: ");
    log.error(perr);
    return {}, false;
  end

  local i;
  local lines = split_lines(pout);
  local devices = {};
  for i = 1, #lines do
    local mac_addr, device_name = parse_device_line(lines[i]);
    if mac_addr ~= nil and device_name ~= nil then
      table.insert(devices, {
        mac_addr = mac_addr,
        device_name = device_name,
      });
    end
  end

  return devices;
end

function bluetoothctl_is_connected(mac)
  local info_cmd = string.format("bluetoothctl info %q", mac);
  local success, pout, presult, perr, ex = runcmd(info_cmd);
  if not success then
    log.error(string.format("failed running info cmd: %s", perr));
    return false;
  end
  local connected = pout:match("Connected: ([^\n]+)");
  if not connected then
    return false
  end
  return connected == "yes";
end

function bluetoothctl_connect(mac)
  local connect_cmd = string.format("bluetoothctl connect %q", mac);
  local success, pout, presult, perr, ex = runcmd(connect_cmd);

  if not success then
    log.error(string.format("failed to connect to device with mac address %q", mac));
    log.error(perr);
    return false;
  end

  return true;
end

function bluetoothctl_disconnect(mac)
  local disconnect_cmd = string.format("bluetoothctl disconnect %q", mac);
  local success, pout, presult, perr, ex = runcmd(disconnect_cmd);

  if not success then
    log.error(string.format("failed to disconnect from device with mac address %q", mac));
    log.error(perr);
    return false;
  end

  return true;
end

function list_devices()
  local devices = bluetoothctl_devices();
  if not devices then
    return false;
  end

  local i;
  for i = 1, #devices do
    devices[i].connected = bluetoothctl_is_connected(devices[i].mac_addr);
  end
  return devices;
end

function update_device_list()
  log.trace("updating device list");
  btdevices_cache = {};
  list_items = {};

  local i;

  local devices = list_devices();
  log.trace(dump(devices));
  for i = 1, #devices do
    table.insert(btdevices_cache, devices[i]);
    local icon = "off";
    if devices[i].connected then
      icon = "select";
    end
    table.insert(list_items, {
      type = "item",
      text = string.format("%s (%s)", devices[i].device_name, devices[i].mac_addr),
      icon = icon,
    });
  end

  server.update({id = "btdevices_list", children = list_items});
end

-- Repeatedly update the device list every LOOP_INTERVAL seconds.
function start_update_device_list_loop()
  update_device_list();
  -- This is implemented using a recursive timeout() rather than
  -- timer.interval() just in case it takes longer than LOOP_INTERVAL for this
  -- to run.
  timer_id = timer.timeout(start_update_device_list_loop, LOOP_INTERVAL);
end

function cancel_device_list_loop()
  timer.cancel(timer_id);
end

events.focus = function()
  start_update_device_list_loop();
end

events.blur = function()
  cancel_device_list_loop();
end

actions.tap = function(index, ntries)
  -- There's a weird race condition where sometimes btdevices_cache is nil. To
  -- handle this, we retry a few times in hopes that it won't be nil for too long.
  ntries = ntries or 0;
  if ntries > 10 then
    log.error("actions.tap: btdevices_cache was nil - unable to handle tap after 10 retries");
    return
  end

  if not btdevices_cache then
    log.warn("actions.tap: btdevices_cache was nil - unable to handle tap");
    timer.timeout(function() actions.tap(index); end, 5, ntries + 1);
    return
  end

  if not index then
    log.error("actions.tap: index was nil - unable to handle tap");
    return
  end

  -- get the cached device from the list
  local device = btdevices_cache[index+1];
  log.info("tapped on device:" .. dump(device));

  -- TODO: add timeout in case connecting hangs
  if not device.connected then
    bluetoothctl_connect(device.mac_addr);
  else
    bluetoothctl_disconnect(device.mac_addr);
  end
  update_device_list();
end