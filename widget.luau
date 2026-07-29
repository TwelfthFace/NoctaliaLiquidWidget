--!nonstrict

local displayMode = tostring(barWidget.getConfig("display_mode") or "full")
local status = noctalia.state.get("cooling_status")

local function temperatureText(value)
  if type(value) ~= "number" then
    return "—"
  end
  return string.format("%.1f°C", value)
end

local function rpmText(value)
  if type(value) ~= "number" then
    return "—"
  end
  return tostring(math.floor(value + 0.5))
end

local function render()
  barWidget.setGlyph("droplet")

  if type(status) ~= "table" or status.available ~= true then
    barWidget.setText("Cooling —")
    barWidget.setColor("error")
    barWidget.setGlyphColor("error")
    local reason = type(status) == "table" and tostring(status.error or "Telemetry unavailable") or "Waiting for telemetry"
    barWidget.setTooltip(reason)
    return
  end

  local coolant = temperatureText(status.coolant)
  local pump = rpmText(status.pump)
  local vertical = barWidget.isVertical()
  if vertical then
    barWidget.setText(coolant)
  elseif displayMode == "compact" then
    barWidget.setText(coolant .. " · P " .. pump)
  else
    barWidget.setText(
      coolant
        .. " · F "
        .. rpmText(status.fan1)
        .. "/"
        .. rpmText(status.fan2)
        .. "/"
        .. rpmText(status.fan3)
        .. " · P "
        .. pump
    )
  end

  barWidget.setColor("on_surface")
  barWidget.setGlyphColor("primary")
  barWidget.setTooltip({
    { key = "Coolant", value = coolant },
    { key = "Radiator fan 1", value = rpmText(status.fan1) .. " rpm" },
    { key = "Radiator fan 2", value = rpmText(status.fan2) .. " rpm" },
    { key = "Radiator fan 3", value = rpmText(status.fan3) .. " rpm" },
    { key = "Pump", value = pump .. " rpm" },
    { key = "Source", value = tostring(status.source or "unknown") },
  })
end

noctalia.state.watch("cooling_status", function(value)
  status = value
  render()
end)

function update()
  noctalia.setUpdateInterval(60000)
  render()
end

function onClick()
  noctalia.togglePanel("danta/liquidctl-control:panel")
end

render()
