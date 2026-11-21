--- Room media for a panel: the device controls its Control4 room's media and shows what is playing.
---
--- Commands come from the device's YAML as `homeassistant.action` calls named `control4.media`, with a `command`
--- (see ROOM_COMMANDS and RoomMedia:command) and, for some, a value. What the room is doing goes back to the
--- device's `control4_media` and `control4_sources` API actions, when it declares them, whenever it changes.
---
--- The room is the Media Room property's, else the driver's own. Its state comes from the room's own variables;
--- the parts no controller documents (the media info's format, the room's source lists) are logged raw.

require("lib.utils")
require("drivers-common-public.global.handlers")
local log = require("lib.logging")

--- @class RoomMediaSource
--- @field id integer
--- @field name string
--- @field video boolean Selected with SELECT_VIDEO_DEVICE rather than SELECT_AUDIO_DEVICE.

--- @class RoomMedia
--- @field client ESPHomeClient
--- @field room integer|nil The room being watched.
--- @field sources RoomMediaSource[]
--- @field playing boolean What play_pause last asked for, as the room does not say.
--- @field sent table<string, string> What each device action was last sent this connection.
--- @field lastInfo string|nil The last raw media info logged.
local RoomMedia = {}
RoomMedia.__index = RoomMedia

--- The action the device calls, and the device's actions this calls back.
RoomMedia.COMMAND_ACTION = "control4.media"
RoomMedia.INFO_ACTION = "control4_media"
RoomMedia.SOURCES_ACTION = "control4_sources"

--- Room variables, as drivers-common-public numbers them.
RoomMedia.VAR = {
  SELECTED_DEVICE = 1000,
  POWER_STATE = 1010,
  VOLUME = 1011,
  IS_MUTED = 1018,
  MEDIA_INFO = 1031,
}

--- Commands that are one room command with no value.
local ROOM_COMMANDS = {
  volume_up = "PULSE_VOL_UP",
  volume_down = "PULSE_VOL_DOWN",
  mute_toggle = "MUTE_TOGGLE",
  mute_on = "MUTE_ON",
  mute_off = "MUTE_OFF",
  play = "PLAY",
  pause = "PAUSE",
  stop = "STOP",
  next = "SKIP_FWD",
  previous = "SKIP_REV",
  room_off = "ROOM_OFF",
}

--- @param client ESPHomeClient
--- @return RoomMedia
function RoomMedia:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  instance.room = nil
  instance.sources = {}
  instance.playing = false
  instance.sent = {}
  instance.lastInfo = nil
  return instance
end

--- The room this panel controls: the Media Room property's, else the driver's own.
--- @return integer|nil
function RoomMedia:roomId()
  local chosen = tointeger(Properties["Media Room"])
  if chosen ~= nil and chosen > 0 then
    return chosen
  end
  return tointeger(C4:RoomGetId())
end

--- @param id integer
--- @return string
local function variable(room, id)
  local value = C4:GetDeviceVariable(room, id)
  if value == nil then
    return ""
  end
  return tostring(value)
end

--- Find the first value under any of `keys` (case-insensitive) anywhere in a parsed XML table.
--- @param node any
--- @param keys table<string, boolean>
--- @param depth? integer
--- @return string|nil
local function findValue(node, keys, depth)
  depth = depth or 0
  if type(node) ~= "table" or depth > 8 then
    return nil
  end
  for k, v in pairs(node) do
    if type(k) == "string" and keys[k:lower()] then
      if type(v) == "string" or type(v) == "number" then
        return tostring(v)
      elseif type(v) == "table" and (type(v[1]) == "string" or type(v[1]) == "number") then
        return tostring(v[1])
      end
    end
  end
  for _, v in pairs(node) do
    local found = findValue(v, keys, depth + 1)
    if found ~= nil then
      return found
    end
  end
  return nil
end

local TITLE_KEYS = { title = true, songname = true, song = true, name = true }
local ARTIST_KEYS = { artist = true, subtitle = true, artistname = true }
local ALBUM_KEYS = { album = true, albumname = true }
local IMAGE_KEYS =
  { img = true, image = true, imageurl = true, image_url = true, art = true, coverart = true, cover_art = true }

--- An image URL the device can fetch: one on the controller ("/...") gets the controller's address.
--- @param url string|nil
--- @return string
local function absoluteUrl(url)
  if IsEmpty(url) then
    return ""
  end
  url = tostring(url)
  if url:match("^https?://") then
    return url
  end
  if url:sub(1, 1) == "/" then
    local host = C4:GetControllerNetworkAddress()
    if not IsEmpty(host) then
      return "http://" .. host .. url
    end
  end
  return ""
end

--- Read the room's CURRENT_MEDIA_INFO: XML whose tags vary by source, so the usual tag names are looked for.
--- @param raw string
--- @return string title, string artist, string album, string imageUrl
function RoomMedia.parseMediaInfo(raw)
  if IsEmpty(raw) then
    return "", "", "", ""
  end
  local ok, parsed = pcall(ParseXml, raw)
  if not ok or type(parsed) ~= "table" then
    return "", "", "", ""
  end
  return findValue(parsed, TITLE_KEYS) or "",
    findValue(parsed, ARTIST_KEYS) or "",
    findValue(parsed, ALBUM_KEYS) or "",
    absoluteUrl(findValue(parsed, IMAGE_KEYS))
end

--- The device connected: take its commands, watch its room and show it the room's state.
function RoomMedia:connected()
  self.sent = {}
  if not self:wanted() then
    return
  end
  self.client:subscribeActions(function(action, data)
    self:action(action, data)
  end)
  self:watch()
  self:loadSources()
  self:push()
end

--- The device is gone: whatever it was shown is no longer known.
function RoomMedia:disconnected()
  self.sent = {}
end

--- The Media Room or Media Sources property changed.
function RoomMedia:settingsChanged()
  self.sent = {}
  if not self.client:isConnected() or not self:wanted() then
    return
  end
  self:watch()
  self:loadSources()
  self:push()
end

--- Whether the device wants any of this: it declares one of the room media actions.
--- @return boolean
function RoomMedia:wanted()
  return self.client:hasService(self.INFO_ACTION) or self.client:hasService(self.SOURCES_ACTION)
end

--- Watch the room's variables, moving the listeners when the room changed.
function RoomMedia:watch()
  local room = self:roomId()
  if room == self.room then
    return
  end
  if self.room ~= nil then
    for _, id in pairs(self.VAR) do
      UnregisterVariableListener(self.room, id)
    end
  end
  self.room = room
  if room == nil then
    log:warn("Room media: no room to watch; set Media Room")
    return
  end
  log:info("Room media: watching room %s (%s)", room, C4:GetDeviceDisplayName(room))
  for _, id in pairs(self.VAR) do
    RegisterVariableListener(room, id, function()
      self:push()
    end)
  end
end

--- Read a room source list (listen or watch) from a UI request's XML reply.
--- @param room integer
--- @param request string
--- @param video boolean
--- @param into RoomMediaSource[]
--- @param seen table<integer, boolean>
local function readSourceList(room, request, video, into, seen)
  local ok, reply = pcall(C4.SendUIRequest, C4, room, request, {})
  log:info("Room media: %s for room %s returned %s", request, room, ok and reply or ("an error: " .. tostring(reply)))
  if not ok or IsEmpty(reply) then
    return
  end
  local parsedOk, parsed = pcall(ParseXml, tostring(reply))
  if not parsedOk or type(parsed) ~= "table" then
    return
  end
  -- Collect every element with a device id: <device><id>..</id><name>..</name></device> or attributes.
  local function walk(node, depth)
    if type(node) ~= "table" or depth > 8 then
      return
    end
    local id = tointeger(node.id or node.deviceid or (node._attr and (node._attr.id or node._attr.deviceid)))
    if id ~= nil and id > 0 and not seen[id] then
      seen[id] = true
      local name = node.name or (node._attr and node._attr.name) or C4:GetDeviceDisplayName(id) or ("Device " .. id)
      table.insert(into, { id = id, name = tostring(name), video = video })
    end
    for _, child in pairs(node) do
      if type(child) == "table" then
        walk(child, depth + 1)
      end
    end
  end
  walk(parsed, 0)
end

--- The room's sources: the Media Sources property's device IDs (`123` listen, `456:video` watch), else the
--- room's own listen and watch lists.
function RoomMedia:loadSources()
  local sources, seen = {}, {}
  local listed = tostring(Properties["Media Sources"] or "")
  for item in listed:gmatch("[^,%s]+") do
    local id, kind = item:match("^(%d+):?(%a*)$")
    id = tointeger(id)
    if id ~= nil and not seen[id] then
      seen[id] = true
      local name = C4:GetDeviceDisplayName(id) or ("Device " .. id)
      table.insert(sources, { id = id, name = tostring(name), video = kind:lower() == "video" })
    end
  end
  if #sources == 0 and self.room ~= nil then
    readSourceList(self.room, "GET_LISTEN_DEVICES", false, sources, seen)
    readSourceList(self.room, "GET_WATCH_DEVICES", true, sources, seen)
  end
  self.sources = sources
  log:info("Room media: %d sources: %s", #sources, sources)
end

--- Call a device action with only what changed since it was last called.
--- @param action string
--- @param args table<string, any>
--- @param signature string
function RoomMedia:send(action, args, signature)
  if not self.client:hasService(action) or self.sent[action] == signature then
    return
  end
  self.sent[action] = signature
  self.client:executeServiceWithArgs(action, args):next(nil, function(error)
    self.sent[action] = nil
    log:warn("Room media: could not call '%s'; %s", action, error)
  end)
end

--- Show the device what the room is doing.
function RoomMedia:push()
  local room = self.room
  if room == nil or not self.client:isConnected() then
    return
  end
  local selected = tointeger(variable(room, self.VAR.SELECTED_DEVICE)) or 0
  local on = toboolean(variable(room, self.VAR.POWER_STATE)) or selected > 0
  local source = selected > 0 and (C4:GetDeviceDisplayName(selected) or "") or ""
  local volume = math.floor((tonumber(variable(room, self.VAR.VOLUME)) or 0) + 0.5)
  local muted = toboolean(variable(room, self.VAR.IS_MUTED)) or false
  local raw = variable(room, self.VAR.MEDIA_INFO)
  if raw ~= self.lastInfo then
    self.lastInfo = raw
    log:info("Room media: media info for room %s: %s", room, raw)
  end
  local title, artist, album, image = self.parseMediaInfo(raw)
  if not on then
    title, artist, album, image = "", "", "", ""
    self.playing = false
  end

  self:send(
    self.INFO_ACTION,
    {
      room_on = on,
      source = source,
      title = title,
      artist = artist,
      album = album,
      image_url = image,
      volume = volume,
      muted = muted,
      playing = self.playing,
    },
    table.concat(
      { tostring(on), source, title, artist, album, image, volume, tostring(muted), tostring(self.playing) },
      "|"
    )
  )

  local names, index = {}, -1
  for i, item in ipairs(self.sources) do
    names[#names + 1] = (item.name:gsub("\n", " "))
    if item.id == selected then
      index = i - 1
    end
  end
  local list = table.concat(names, "\n")
  self:send(self.SOURCES_ACTION, { sources = list, selected = index }, list .. "|" .. index)
end

--- Send a command to the room.
--- @param command string
--- @param params? table<string, any>
function RoomMedia:roomCommand(command, params)
  if self.room == nil then
    log:warn("Room media: no room for %s", command)
    return
  end
  log:info("Room media: room %s <- %s %s", self.room, command, params or {})
  C4:SendToDevice(self.room, command, params or {})
end

--- A `homeassistant.action` call from the device.
--- @param action string
--- @param data table<string, string>
function RoomMedia:action(action, data)
  if action ~= self.COMMAND_ACTION then
    log:debug("Room media: ignoring action %s", action)
    return
  end
  self:command(tostring(data.command or ""), data)
end

--- Carry out one command from the device.
--- @param command string
--- @param data table<string, string>
function RoomMedia:command(command, data)
  local roomCommand = ROOM_COMMANDS[command]
  if roomCommand ~= nil then
    self:roomCommand(roomCommand)
    if command == "play" then
      self.playing = true
    elseif command == "pause" or command == "stop" or command == "room_off" then
      self.playing = false
    end
  elseif command == "play_pause" then
    -- The room says nothing about whether it is playing, so this alternates, starting with play.
    self.playing = not self.playing
    self:roomCommand(self.playing and "PLAY" or "PAUSE")
  elseif command == "set_volume" then
    local level = tonumber(data.level)
    if level == nil then
      log:warn("Room media: set_volume needs a level")
      return
    end
    self:roomCommand("SET_VOLUME_LEVEL", { LEVEL = math.max(0, math.min(100, math.floor(level + 0.5))) })
  elseif command == "select_source" then
    local source = self.sources[(tointeger(data.index) or -1) + 1]
    if source == nil then
      log:warn("Room media: no source %s (have %d)", data.index, #self.sources)
      return
    end
    self:roomCommand(source.video and "SELECT_VIDEO_DEVICE" or "SELECT_AUDIO_DEVICE", { deviceid = source.id })
  elseif command == "room_command" and not IsEmpty(data.name) then
    -- Any other room command, by its Control4 name, for what this does not cover.
    local params = {}
    for k, v in pairs(data) do
      if k ~= "command" and k ~= "name" then
        params[k] = v
      end
    end
    self:roomCommand(tostring(data.name), params)
  else
    log:warn("Room media: unknown command '%s'", command)
    return
  end
  self:push()
end

return RoomMedia
