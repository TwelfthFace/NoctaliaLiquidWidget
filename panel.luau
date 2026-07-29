--!nonstrict

local TARGET_OPTIONS = {
  "All lighting devices",
  "Commander Pro — both LED channels",
  "Commander Pro — LED 1",
  "Commander Pro — LED 2",
  "ASUS Aura waterblock",
}
local TARGET_VALUES = {
  "all",
  "commander_sync",
  "commander_led1",
  "commander_led2",
  "aura",
}
local MODE_OPTIONS = {
  "Static",
  "Pulse / breathing",
  "Rainbow",
  "Off",
}
local MODE_VALUES = {
  "static",
  "pulse",
  "rainbow",
  "off",
}
local SPEED_OPTIONS = {
  "Slow",
  "Medium",
  "Fast",
}
local SPEED_VALUES = {
  "slow",
  "medium",
  "fast",
}

local status = noctalia.state.get("cooling_status")
local lightingResult = noctalia.state.get("lighting_result")
local panelOpen = false
local targetIndex = 0
local modeIndex = 0
local speedIndex = 1
local color = "8B5CF6"
local brightness = 100
local colorInputVersion = 0
local nonce = 0

local function clampIndex(value, count)
  local index = math.floor(tonumber(value) or 0)
  if index < 0 then
    return 0
  elseif index >= count then
    return count - 1
  end
  return index
end

local function rpmText(value)
  if type(value) ~= "number" then
    return "—"
  end
  return tostring(math.floor(value + 0.5)) .. " rpm"
end

local function temperatureText(value)
  if type(value) ~= "number" then
    return "—"
  end
  return string.format("%.1f°C", value)
end

local function validColor(value)
  local normalized = tostring(value or ""):gsub("#", ""):upper()
  if normalized:match("^%x%x%x%x%x%x$") == nil then
    return nil
  end
  return normalized
end

local function sectionTitle(text, glyph)
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = glyph, size = 18, color = "primary" }),
    ui.label({ text = text, fontSize = 15, fontWeight = "bold", color = "on_surface" }),
  })
end

local function metricCard(glyph, label, value)
  return ui.column({
    flexGrow = 1,
    minWidth = 94,
    fill = "surface_variant",
    radius = 10,
    padding = 10,
    gap = 5,
  }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.glyph({ name = glyph, size = 15, color = "primary" }),
      ui.label({ text = label, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.label({ text = value, fontSize = 15, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
  })
end

local function telemetrySection()
  if type(status) ~= "table" or status.available ~= true then
    local reason = type(status) == "table" and tostring(status.error or "Telemetry unavailable") or "Waiting for telemetry"
    return ui.column({ gap = 10 }, {
      sectionTitle("Cooling", "droplet"),
      ui.column({ fill = "surface_variant", radius = 10, padding = 12, gap = 5 }, {
        ui.label({ text = "Telemetry unavailable", fontWeight = "semibold", color = "error" }),
        ui.label({ text = reason, color = "on_surface_variant", maxLines = 3 }),
      }),
    })
  end

  local errorNote = tostring(status.error or "")
  local children = {
    sectionTitle("Cooling", "droplet"),
    ui.row({ gap = 8 }, {
      metricCard("thermometer", "Coolant", temperatureText(status.coolant)),
      metricCard("propeller", "Fan 1", rpmText(status.fan1)),
      metricCard("propeller", "Fan 2", rpmText(status.fan2)),
      metricCard("propeller", "Fan 3", rpmText(status.fan3)),
    }),
    ui.row({ gap = 8, align = "center" }, {
      metricCard("gauge", "Pump", rpmText(status.pump)),
      ui.column({ flexGrow = 1, gap = 4, paddingH = 4 }, {
        ui.label({ text = "Source", fontSize = 12, color = "on_surface_variant" }),
        ui.label({
          text = tostring(status.source or "unknown"),
          fontSize = 12,
          color = "on_surface",
          maxLines = 2,
        }),
      }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshStatus" }),
    }),
  }
  if errorNote ~= "" then
    table.insert(children, ui.label({ text = errorNote, fontSize = 12, color = "error", maxLines = 2 }))
  end
  return ui.column({ gap = 10 }, children)
end

local function presetSwatch(hex, callback)
  return ui.box({
    width = 38,
    height = 28,
    fill = "#" .. hex,
    radius = 8,
    border = color == hex and "on_surface" or "outline",
    borderWidth = color == hex and 2 or 1,
    onClick = callback,
  })
end

local function lightingFeedback()
  if type(lightingResult) ~= "table" then
    return ui.label({ text = "Ready", color = "on_surface_variant" })
  end

  local feedbackColor = "on_surface_variant"
  if lightingResult.busy == true then
    feedbackColor = "primary"
  elseif lightingResult.ok == true then
    feedbackColor = "tertiary"
  else
    feedbackColor = "error"
  end
  return ui.label({
    text = tostring(lightingResult.message or "Ready"),
    color = feedbackColor,
    maxLines = 3,
  })
end

local function lightingSection()
  local mode = MODE_VALUES[modeIndex + 1]
  local needsColor = mode == "static" or mode == "pulse"
  local animated = mode == "pulse" or mode == "rainbow"
  local preview = validColor(color)
  local busy = type(lightingResult) == "table" and lightingResult.busy == true

  return ui.column({ gap = 12 }, {
    sectionTitle("Lighting", "bulb"),

    ui.column({ gap = 6 }, {
      ui.label({ text = "Target", fontSize = 12, color = "on_surface_variant" }),
      ui.select({
        options = TARGET_OPTIONS,
        selectedIndex = targetIndex,
        onChange = "onTargetChanged",
        enabled = not busy,
      }),
    }),

    ui.row({ gap = 10 }, {
      ui.column({ flexGrow = 1, gap = 6 }, {
        ui.label({ text = "Effect", fontSize = 12, color = "on_surface_variant" }),
        ui.select({
          options = MODE_OPTIONS,
          selectedIndex = modeIndex,
          onChange = "onModeChanged",
          enabled = not busy,
        }),
      }),
      ui.column({ flexGrow = 1, gap = 6 }, {
        ui.label({ text = "Speed", fontSize = 12, color = "on_surface_variant" }),
        ui.select({
          options = SPEED_OPTIONS,
          selectedIndex = speedIndex,
          onChange = "onSpeedChanged",
          enabled = animated and not busy,
        }),
      }),
    }),

    ui.column({ gap = 7 }, {
      ui.label({ text = "Color", fontSize = 12, color = "on_surface_variant" }),
      ui.row({ gap = 8, align = "center" }, {
        ui.box({
          width = 42,
          height = 34,
          fill = preview ~= nil and ("#" .. preview) or "surface_variant",
          radius = 8,
          border = preview ~= nil and "outline" or "error",
          borderWidth = 1,
        }),
        ui.input({
          key = "color-input-" .. tostring(colorInputVersion),
          value = color,
          placeholder = "RRGGBB",
          flexGrow = 1,
          enabled = needsColor and not busy,
          onChange = "onColorChanged",
        }),
      }),
      ui.row({ gap = 8 }, {
        presetSwatch("FF3B30", "onPresetRed"),
        presetSwatch("34C759", "onPresetGreen"),
        presetSwatch("0A84FF", "onPresetBlue"),
        presetSwatch("8B5CF6", "onPresetPurple"),
        presetSwatch("FF2D95", "onPresetPink"),
        presetSwatch("FFFFFF", "onPresetWhite"),
      }),
    }),

    ui.column({ gap = 6 }, {
      ui.row({ justify = "space_between", align = "center" }, {
        ui.label({ text = "Brightness", fontSize = 12, color = "on_surface_variant" }),
        ui.label({ text = tostring(brightness) .. "%", fontSize = 12, color = "on_surface" }),
      }),
      ui.slider({
        min = 0,
        max = 100,
        step = 1,
        value = brightness,
        enabled = needsColor and not busy,
        onChange = "onBrightnessChanged",
      }),
    }),

    lightingFeedback(),

    ui.row({ gap = 10 }, {
      ui.button({
        text = busy and "Applying..." or "Apply",
        glyph = "sparkles",
        variant = "primary",
        flexGrow = 1,
        enabled = not busy,
        onClick = "onApplyLighting",
      }),
      ui.button({
        text = "All off",
        glyph = "power",
        variant = "destructive",
        enabled = not busy,
        onClick = "onAllOff",
      }),
    }),
  })
end

local function render()
  if not panelOpen then
    return
  end

  panel.render(ui.column({ flexGrow = 1, gap = 14 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 9, flexGrow = 1 }, {
        ui.glyph({ name = "droplet", size = 21, color = "primary" }),
        ui.label({
          text = "Liquidctl Control",
          fontSize = 17,
          fontWeight = "bold",
          color = "on_surface",
          flexGrow = 1,
        }),
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        tooltip = "Plugin settings",
        onClick = "onOpenSettingsClicked",
      }),
      ui.button({
        glyph = "close",
        variant = "ghost",
        tooltip = "Close",
        onClick = "onCloseClicked",
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 16 }, {
      telemetrySection(),
      ui.separator({ color = "outline", spacing = 2 }),
      lightingSection(),
    }),
  }))
end

local function choosePreset(hex)
  color = hex
  colorInputVersion += 1
  render()
end

local function sendLighting(target, mode)
  nonce += 1
  noctalia.state.set("lighting_command", {
    action = "apply",
    target = target,
    mode = mode,
    color = color,
    brightness = brightness,
    speed = SPEED_VALUES[speedIndex + 1],
    nonce = nonce,
  })
end

noctalia.state.watch("cooling_status", function(value)
  status = value
  render()
end)

noctalia.state.watch("lighting_result", function(value)
  lightingResult = value
  render()
end)

function onOpen(_context)
  panelOpen = true
  render()
end

function onClose()
  panelOpen = false
end

function onCloseClicked()
  panel.close()
end

function onOpenSettingsClicked()
  local started = noctalia.runAsync("noctalia msg settings-open plugins", function(result)
    if result.timedOut == true or tonumber(result.exitCode) ~= 0 then
      noctalia.notifyError("Liquidctl Control", "Unable to open Noctalia plugin settings")
    end
  end, 5000)
  if not started then
    noctalia.notifyError("Liquidctl Control", "Unable to open Noctalia plugin settings")
  end
end

function onRefreshStatus()
  nonce += 1
  noctalia.state.set("status_refresh", { nonce = nonce })
end

function onTargetChanged(index, _text)
  targetIndex = clampIndex(index, #TARGET_OPTIONS)
  render()
end

function onModeChanged(index, _text)
  modeIndex = clampIndex(index, #MODE_OPTIONS)
  render()
end

function onSpeedChanged(index, _text)
  speedIndex = clampIndex(index, #SPEED_OPTIONS)
  render()
end

function onColorChanged(value)
  color = tostring(value or ""):gsub("#", ""):upper()
  render()
end

function onBrightnessChanged(value)
  brightness = math.floor(tonumber(value) or 100)
  if brightness < 0 then
    brightness = 0
  elseif brightness > 100 then
    brightness = 100
  end
  render()
end

function onPresetRed()
  choosePreset("FF3B30")
end

function onPresetGreen()
  choosePreset("34C759")
end

function onPresetBlue()
  choosePreset("0A84FF")
end

function onPresetPurple()
  choosePreset("8B5CF6")
end

function onPresetPink()
  choosePreset("FF2D95")
end

function onPresetWhite()
  choosePreset("FFFFFF")
end

function onApplyLighting()
  sendLighting(TARGET_VALUES[targetIndex + 1], MODE_VALUES[modeIndex + 1])
end

function onAllOff()
  sendLighting("all", "off")
end
