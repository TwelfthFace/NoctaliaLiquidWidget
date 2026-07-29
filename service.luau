--!nonstrict

-- Headless backend for coolant/RPM telemetry and strictly validated lighting
-- writes. Telemetry prefers the corsair-cpro hwmon driver, so the normal poll
-- path performs no USB scan and needs no root privileges.

local liquidctlPath = tostring(noctalia.getConfig("liquidctl_path") or "liquidctl")
local commanderMatch = tostring(noctalia.getConfig("commander_match") or "Commander PRO")
local auraMatch = tostring(noctalia.getConfig("aura_match") or "ASUS Aura LED Controller")
local auraPick = math.floor(tonumber(noctalia.getConfig("aura_pick")) or 0)
local auraChannel = tostring(noctalia.getConfig("aura_channel") or "sync")
local temperatureSensor = math.floor(tonumber(noctalia.getConfig("temperature_sensor")) or 1)
local pollInterval = math.floor(tonumber(noctalia.getConfig("poll_interval_ms")) or 2000)
local privilegeMode = tostring(noctalia.getConfig("privilege_mode") or "direct")
local commanderLightingEnabled = noctalia.getConfig("commander_lighting_enabled") ~= false
local auraLightingEnabled = noctalia.getConfig("aura_lighting_enabled") ~= false

local telemetryInFlight = false
local fallbackAfter = 0
local lightingBusy = false

local function clamp(value, minimum, maximum)
  if value < minimum then
    return minimum
  elseif value > maximum then
    return maximum
  end
  return value
end

auraPick = clamp(auraPick, 0, 16)
temperatureSensor = clamp(temperatureSensor, 1, 4)
pollInterval = clamp(pollInterval, 1000, 30000)
noctalia.setUpdateInterval(pollInterval)

local allowedAuraChannels = {
  sync = true,
  led1 = true,
  led2 = true,
  led3 = true,
  led4 = true,
}
if not allowedAuraChannels[auraChannel] then
  auraChannel = "sync"
end

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Noctalia beta1 only gives service update() callbacks 12 ms. Reading several
-- hwmon attributes synchronously can exceed that budget because a sysfs read
-- may wait on the USB-backed kernel driver. Perform the reads in runAsync's
-- worker process and only parse the small result inside the Luau callback.
local function hwmonReadCommand()
  local sensorFile = "temp" .. tostring(temperatureSensor) .. "_input"
  return "for d in /sys/class/hwmon/hwmon*; do "
    .. "n=''; IFS= read -r n 2>/dev/null < \"$d/name\" || continue; "
    .. "case \"$n\" in "
    .. "*corsair*cpro*|*corsair*commander*) "
    .. "printf '%s' \"$d\"; "
    .. "for f in "
    .. sensorFile
    .. " fan1_input fan2_input fan3_input fan4_input; do "
    .. "v='-'; IFS= read -r v 2>/dev/null < \"$d/$f\" || v='-'; "
    .. "printf '\\t%s' \"$v\"; "
    .. "done; printf '\\n'; exit 0;; "
    .. "esac; done; exit 3"
end

local function parseHwmonStatus(stdout)
  local fields = {}
  local line = trim(stdout)
  for field in (line .. "\t"):gmatch("([^\t]+)\t") do
    table.insert(fields, field)
  end
  if #fields < 6 then
    return nil
  end

  local coolantRaw = tonumber(fields[2])
  local fan1 = tonumber(fields[3])
  local fan2 = tonumber(fields[4])
  local fan3 = tonumber(fields[5])
  local pump = tonumber(fields[6])

  local status = {
    available = true,
    source = "corsair-cpro hwmon",
    error = "",
    updated_at = os.time(),
  }

  if coolantRaw ~= nil then
    status.coolant = coolantRaw / 1000
  end
  if fan1 ~= nil then
    status.fan1 = math.floor(fan1 + 0.5)
  end
  if fan2 ~= nil then
    status.fan2 = math.floor(fan2 + 0.5)
  end
  if fan3 ~= nil then
    status.fan3 = math.floor(fan3 + 0.5)
  end
  if pump ~= nil then
    status.pump = math.floor(pump + 0.5)
  end

  if status.coolant == nil and status.fan1 == nil and status.fan2 == nil and status.fan3 == nil and status.pump == nil then
    return nil
  end

  if status.coolant == nil then
    status.error = "Coolant probe " .. tostring(temperatureSensor) .. " is unavailable"
  end
  return status
end

local function publishStatus(status)
  noctalia.state.set("cooling_status", status)
end

local function parseLiquidctlStatus(stdout)
  local decoded = noctalia.json.decode(stdout)
  if type(decoded) ~= "table" then
    return nil, "liquidctl returned invalid JSON"
  end

  local device = decoded[1]
  if type(device) ~= "table" or type(device.status) ~= "table" then
    return nil, "Commander Pro status was not present in liquidctl output"
  end

  local status = {
    available = true,
    source = "liquidctl JSON fallback",
    error = "",
    updated_at = os.time(),
  }
  local coolantKey = "Temperature " .. tostring(temperatureSensor)

  for _, row in ipairs(device.status) do
    if type(row) == "table" then
      local value = tonumber(row.value)
      if row.key == coolantKey then
        status.coolant = value
      elseif row.key == "Fan 1 speed" then
        status.fan1 = value
      elseif row.key == "Fan 2 speed" then
        status.fan2 = value
      elseif row.key == "Fan 3 speed" then
        status.fan3 = value
      elseif row.key == "Fan 4 speed" then
        status.pump = value
      end
    end
  end

  if status.coolant == nil and status.fan1 == nil and status.fan2 == nil and status.fan3 == nil and status.pump == nil then
    return nil, "liquidctl did not report the configured coolant or RPM channels"
  end
  return status, nil
end

local function runLiquidctlFallback(forceFallback)
  local now = os.time()
  if telemetryInFlight or (not forceFallback and now < fallbackAfter) then
    return
  end

  telemetryInFlight = true
  fallbackAfter = now + 10
  local command = shellQuote(liquidctlPath)
    .. " --match "
    .. shellQuote(commanderMatch)
    .. " status --json"

  local started = noctalia.runAsync(command, function(result)
    telemetryInFlight = false
    if result.timedOut then
      publishStatus({
        available = false,
        source = "liquidctl JSON fallback",
        error = "Telemetry command timed out",
        updated_at = os.time(),
      })
      return
    end
    if result.exitCode ~= 0 then
      local detail = trim(result.stderr)
      if detail == "" then
        detail = "liquidctl exited with code " .. tostring(result.exitCode)
      end
      publishStatus({
        available = false,
        source = "liquidctl JSON fallback",
        error = detail,
        updated_at = os.time(),
      })
      return
    end

    local parsed, parseError = parseLiquidctlStatus(result.stdout)
    if parsed ~= nil then
      publishStatus(parsed)
    else
      publishStatus({
        available = false,
        source = "liquidctl JSON fallback",
        error = parseError or "Unable to parse Commander Pro telemetry",
        updated_at = os.time(),
      })
    end
  end, 10000)

  if not started then
    telemetryInFlight = false
    publishStatus({
      available = false,
      source = "liquidctl JSON fallback",
      error = "Unable to start liquidctl",
      updated_at = os.time(),
    })
  end
end

local function refreshStatus(forceFallback)
  if telemetryInFlight then
    return
  end

  telemetryInFlight = true
  local started = noctalia.runAsync(hwmonReadCommand(), function(result)
    telemetryInFlight = false
    if result.exitCode == 0 and not result.timedOut then
      local status = parseHwmonStatus(result.stdout)
      if status ~= nil then
        publishStatus(status)
        return
      end
    end
    runLiquidctlFallback(forceFallback)
  end, 5000)

  if not started then
    telemetryInFlight = false
    runLiquidctlFallback(forceFallback)
  end
end

local function normalizeColor(rawColor)
  local candidate = tostring(rawColor or ""):gsub("#", "")
  if candidate:match("^%x%x%x%x%x%x$") == nil then
    return nil
  end
  return candidate:lower()
end

local function scaleColor(color, brightness)
  local scale = clamp(tonumber(brightness) or 100, 0, 100) / 100
  local red = math.floor((tonumber(color:sub(1, 2), 16) or 0) * scale + 0.5)
  local green = math.floor((tonumber(color:sub(3, 4), 16) or 0) * scale + 0.5)
  local blue = math.floor((tonumber(color:sub(5, 6), 16) or 0) * scale + 0.5)
  return string.format("%02x%02x%02x", red, green, blue)
end

local function privilegePrefix()
  if privilegeMode == "pkexec" then
    return "pkexec "
  elseif privilegeMode == "sudo-n" then
    return "sudo -n -- "
  end
  return ""
end

local function baseCommand(match, pick)
  local command = privilegePrefix()
    .. shellQuote(liquidctlPath)
    .. " --match "
    .. shellQuote(match)
  if pick ~= nil then
    command ..= " --pick " .. tostring(pick)
  end
  return command
end

local commanderModes = {
  static = "fixed",
  pulse = "color_pulse",
  rainbow = "rainbow",
  off = "off",
}
local auraModes = {
  static = "static",
  pulse = "breathing",
  rainbow = "rainbow",
  off = "off",
}
local allowedTargets = {
  all = true,
  commander_sync = true,
  commander_led1 = true,
  commander_led2 = true,
  aura = true,
}
local allowedSpeeds = {
  slow = true,
  medium = true,
  fast = true,
}

local function colorArgument(mode, color)
  if mode == "static" or mode == "pulse" then
    return " " .. color
  end
  return ""
end

local function appendCommanderCommands(commands, channel, mode, color, speed)
  if not commanderLightingEnabled then
    return
  end

  local base = baseCommand(commanderMatch, nil)
  if mode ~= "off" then
    table.insert(commands, {
      label = "Commander Pro effect reset",
      command = base .. " set sync color clear",
    })
  end
  table.insert(commands, {
    label = "Commander Pro " .. channel,
    command = base
      .. " set "
      .. channel
      .. " color "
      .. commanderModes[mode]
      .. colorArgument(mode, color)
      .. " --speed "
      .. speed,
  })
end

local function appendAuraCommand(commands, mode, color)
  if not auraLightingEnabled then
    return
  end

  table.insert(commands, {
    label = "ASUS Aura " .. auraChannel,
    command = baseCommand(auraMatch, auraPick)
      .. " set "
      .. auraChannel
      .. " color "
      .. auraModes[mode]
      .. colorArgument(mode, color),
  })
end

local function shortError(result)
  if result.timedOut then
    return "timed out"
  end
  local detail = trim(result.stderr)
  if detail == "" then
    detail = trim(result.stdout)
  end
  if detail == "" then
    detail = "exit code " .. tostring(result.exitCode)
  end
  if #detail > 260 then
    detail = detail:sub(1, 257) .. "..."
  end
  return detail
end

local function publishLightingResult(ok, busy, message, nonce)
  noctalia.state.set("lighting_result", {
    ok = ok,
    busy = busy,
    message = message,
    nonce = nonce,
    updated_at = os.time(),
  })
end

local function runLightingCommands(commands, nonce)
  local commandParts = {}
  local labels = {}
  for _, item in ipairs(commands) do
    table.insert(commandParts, "(" .. item.command .. ")")
    table.insert(labels, item.label)
  end

  -- Run the whole ordered operation in one worker. Besides keeping `clear`
  -- before `set`, this avoids starting another worker thread from each 25 ms
  -- async callback in Noctalia beta1.
  local command = table.concat(commandParts, " && ")
  local started = noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      lightingBusy = false
      publishLightingResult(false, false, table.concat(labels, " → ") .. ": " .. shortError(result), nonce)
      return
    end
    lightingBusy = false
    publishLightingResult(true, false, "Lighting applied successfully", nonce)
  end, 60000)

  if not started then
    lightingBusy = false
    publishLightingResult(false, false, "Unable to start the lighting operation", nonce)
  end
end

local function handleLightingCommand(request)
  if type(request) ~= "table" or request.action ~= "apply" then
    return
  end

  local nonce = tonumber(request.nonce) or 0
  if lightingBusy then
    publishLightingResult(false, true, "A lighting update is already running", nonce)
    return
  end

  local target = tostring(request.target or "")
  local mode = tostring(request.mode or "")
  local speed = tostring(request.speed or "")
  if not allowedTargets[target] then
    publishLightingResult(false, false, "Invalid lighting target", nonce)
    return
  end
  if commanderModes[mode] == nil or auraModes[mode] == nil then
    publishLightingResult(false, false, "Invalid lighting mode", nonce)
    return
  end
  if not allowedSpeeds[speed] then
    publishLightingResult(false, false, "Invalid lighting speed", nonce)
    return
  end

  local color = normalizeColor(request.color)
  if (mode == "static" or mode == "pulse") and color == nil then
    publishLightingResult(false, false, "Color must contain exactly six hexadecimal digits", nonce)
    return
  end
  color = scaleColor(color or "000000", request.brightness)

  local commands = {}
  if target == "all" then
    appendCommanderCommands(commands, "sync", mode, color, speed)
    appendAuraCommand(commands, mode, color)
  elseif target == "commander_sync" then
    appendCommanderCommands(commands, "sync", mode, color, speed)
  elseif target == "commander_led1" then
    appendCommanderCommands(commands, "led1", mode, color, speed)
  elseif target == "commander_led2" then
    appendCommanderCommands(commands, "led2", mode, color, speed)
  elseif target == "aura" then
    appendAuraCommand(commands, mode, color)
  end

  if #commands == 0 then
    publishLightingResult(false, false, "No matching lighting devices are enabled in plugin settings", nonce)
    return
  end

  lightingBusy = true
  publishLightingResult(true, true, "Applying lighting...", nonce)
  runLightingCommands(commands, nonce)
end

noctalia.state.watch("lighting_command", handleLightingCommand)
noctalia.state.watch("status_refresh", function(_request)
  refreshStatus(true)
end)

if noctalia.state.get("lighting_result") == nil then
  publishLightingResult(true, false, "Ready", 0)
end

function update()
  refreshStatus(false)
end

refreshStatus(false)
