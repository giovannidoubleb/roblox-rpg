-- CITY GRIND: highlights + CityTok (spec 22-26, 34, 35, 37, 85, 120).
--
-- Recording: a rolling ~10 s buffer at 12 Hz of every character (root + joint angles),
-- every basketball and every spawned vehicle. When a highlight happens (dunk, three,
-- long shot, perfect release, block, steal, 10-point game, game winner, top-speed run,
-- big air, or a manual "clip that") the last ~6 s + 2 s after are frozen into a compact
-- replay clip (shared/Replay) for the player and saved (max 20) in DataStore
-- "CityGrind_Clips_v1" (key user_<id>), with an in-memory fallback in Studio.
-- The client gets "HIGHLIGHT SAVED" with WATCH / EDIT / POST / DELETE.
--
-- CityTok: posts live in DataStore "CityGrind_TokPosts_v1" (post_<id> = meta + stats,
-- clip_<id> = clip + edit, "recent" = newest index) and OrderedDataStore
-- "CityGrind_TokTrend_v1" (trend score). New posts / stat changes / awards go to
-- other servers over MessagingService "CityTok_v1". Likes, views, comments and shares
-- count once per distinct real player (never the creator). Trending/viral posts give the
-- creator reputation (capped per day) and fame — never cash.
--
-- Remotes: CityTokRequest (RemoteFunction: action, payload) -> (ok, message, data)
--          CityTokEvent   (RemoteEvent, server -> client): "Highlight" (clipSummary) | "Inbox" | "Clips"
-- Saved section "citytok": { posts = {postId}, favs = {postId}, inbox = {{i, f, t}}, repDay, repToday }
-- Public API:
--   CityTok.listClips(player) -> {{id, kind, title, at}}
--   CityTok.saveClip(player, clip) -> (ok, err?)
--   CityTok.highlight(player, tagKey, at?) -- tagKey from CityTokConfig.TAGS
--   CityTok.sanitizeEdit(player, raw, duration) -> (edit?, err?)

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")
local Lighting = game:GetService("Lighting")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Cfg = require(shared:WaitForChild("CityTokConfig"))
local Replay = require(shared:WaitForChild("Replay"))
local VC = require(shared:WaitForChild("VehiclesConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Basketball = require(script.Parent:WaitForChild("Basketball"))

local IS_STUDIO = RunService:IsStudio()
local TOPIC = "CityTok_v1"

local CityTok = {}

PlayerData.registerSection("citytok", function()
	return { posts = {}, favs = {}, inbox = {}, repDay = "", repToday = 0, fameToday = 0 }
end)

local city: Instance? = nil
local RequestRemote: RemoteFunction
local EventRemote: RemoteEvent

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local lazyCache: { [string]: any } = {}
-- Optional sibling modules (CityGram, Messages, Social, Vehicles), required on first use.
local function lazy(name: string): any
	if lazyCache[name] == nil then
		local m = script.Parent:FindFirstChild(name)
		local ok, mod = false, nil
		if m and m:IsA("ModuleScript") then
			ok, mod = pcall(require, m)
		end
		lazyCache[name] = if ok and type(mod) == "table" then mod else false
	end
	return lazyCache[name] or nil
end

local function newId(): string
	return (HttpService:GenerateGUID(false):gsub("-", ""):sub(1, 14):lower())
end

local function round(n: number, places: number): number
	local m = 10 ^ places
	return math.floor(n * m + 0.5) / m
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function key(userId: number): string
	return tostring(userId)
end

local function num(v: any): number?
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		return v
	end
	return nil
end

local function cleanText(raw: any, maxLength: number, allowEmpty: boolean?): string?
	if type(raw) ~= "string" or #raw > maxLength * 4 + 32 or utf8.len(raw) == nil then
		return nil
	end
	local text = raw:gsub("%c", " "):gsub("%s+", " ")
	text = text:match("^%s*(.-)%s*$") or ""
	local length = utf8.len(text)
	if not length or length > maxLength or (text == "" and not allowEmpty) then
		return nil
	end
	return text
end

-- Can this account use text at all? (cached a few minutes)
local chatCache: { [number]: { ok: boolean, at: number } } = {}
local function canUseText(player: Player): boolean
	if IS_STUDIO and player.UserId <= 0 then
		return true
	end
	local c = chatCache[player.UserId]
	if c and os.clock() - c.at < 300 then
		return c.ok
	end
	local ok, result = pcall(function()
		return TextChatService:CanUserChatAsync(player.UserId)
	end)
	local allowed = ok and result == true
	chatCache[player.UserId] = { ok = allowed, at = os.clock() }
	return allowed
end

-- Public (broadcast) filtering. Returns nil when the text can't be checked.
local function filterPublic(player: Player, text: string): string?
	if text == "" then
		return ""
	end
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
	end)
	if ok and result then
		local ok2, filtered = pcall(function()
			return result:GetNonChatStringForBroadcastAsync()
		end)
		if ok2 and type(filtered) == "string" then
			return filtered
		end
	end
	-- Studio test players (negative ids) can't be filtered; their text passes in Studio only.
	if IS_STUDIO and player.UserId <= 0 then
		return text
	end
	return nil
end

local function socialBlocked(viewer: Player, otherUserId: number): boolean
	local Social = lazy("Social")
	if not Social then
		return false
	end
	local ok, blocked = pcall(function()
		if Social.isBlockedId and Social.isBlockedId(viewer, otherUserId) then
			return true
		end
		local other = Players:GetPlayerByUserId(otherUserId)
		return other ~= nil and Social.isBlocked(viewer, other)
	end)
	return ok and blocked == true
end

local function socialMuted(viewer: Player, otherUserId: number): boolean
	local Social = lazy("Social")
	if not Social or not Social.isMutedBy then
		return false
	end
	local ok, muted = pcall(Social.isMutedBy, viewer, otherUserId)
	return ok and muted == true
end

local function cityGram(): any
	local CG = lazy("CityGram")
	if CG and type(CG.follow) == "function" and type(CG.isFollowing) == "function" then
		return CG
	end
	return nil
end

local function isFollowing(aId: number, bId: number): boolean
	local CG = cityGram()
	if not CG or aId == bId then
		return false
	end
	local ok, result = pcall(CG.isFollowing, aId, bId)
	return ok and result == true
end

---------------------------------------------------------------------------
-- Key-value storage with a Studio fallback.
-- mode "ds": real DataStores; "memory": unpublished Studio / no API access.
---------------------------------------------------------------------------
local PostsDS: DataStore? = nil
local TrendDS: OrderedDataStore? = nil
local ClipsDS: DataStore? = nil
pcall(function()
	PostsDS = DataStoreService:GetDataStore("CityGrind_TokPosts_v1")
	TrendDS = DataStoreService:GetOrderedDataStore("CityGrind_TokTrend_v1")
	ClipsDS = DataStoreService:GetDataStore("CityGrind_Clips_v1")
end)

local mode = "pending"
local memKV: { [string]: any } = {}

-- The memory store hands out copies, like a real DataStore would.
local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

local function waitMode()
	local deadline = os.clock() + 15
	while mode == "pending" and os.clock() < deadline do
		task.wait(0.2)
	end
	if mode == "pending" then
		mode = "memory"
	end
end

local function kvGet(k: string): (boolean, any)
	waitMode()
	if mode == "ds" and PostsDS then
		for attempt = 1, 3 do
			local ok, value = pcall(function()
				return (PostsDS :: DataStore):GetAsync(k)
			end)
			if ok then
				return true, value
			end
			task.wait(attempt)
		end
		return false, nil
	end
	return true, deepCopy(memKV[k])
end

local function kvSet(k: string, value: any): boolean
	waitMode()
	if mode == "ds" and PostsDS then
		for attempt = 1, 3 do
			local ok = pcall(function()
				(PostsDS :: DataStore):SetAsync(k, value)
			end)
			if ok then
				return true
			end
			task.wait(attempt)
		end
		return false
	end
	memKV[k] = deepCopy(value)
	return true
end

local function kvRemove(k: string)
	waitMode()
	if mode == "ds" and PostsDS then
		pcall(function()
			(PostsDS :: DataStore):RemoveAsync(k)
		end)
	else
		memKV[k] = nil
	end
end

-- transform(old) returns the new value, or nil to cancel. It must not yield.
local function kvUpdate(k: string, transform: (any) -> any): (boolean, any)
	waitMode()
	if mode == "ds" and PostsDS then
		for attempt = 1, 3 do
			local ok, result = pcall(function()
				return (PostsDS :: DataStore):UpdateAsync(k, function(old)
					return transform(old)
				end)
			end)
			if ok then
				return true, result
			end
			task.wait(attempt)
		end
		return false, nil
	end
	local result = transform(deepCopy(memKV[k]))
	if result ~= nil then
		memKV[k] = result
	end
	return true, deepCopy(memKV[k])
end

local function trendSet(id: string, score: number)
	if mode == "ds" and TrendDS then
		pcall(function()
			(TrendDS :: OrderedDataStore):SetAsync(id, math.floor(score * 1000))
		end)
	end
end

local function trendRemove(id: string)
	if mode == "ds" and TrendDS then
		pcall(function()
			(TrendDS :: OrderedDataStore):RemoveAsync(id)
		end)
	end
end

local function publish(message: { [string]: any })
	if mode ~= "ds" then
		return
	end
	message.s = game.JobId
	task.spawn(pcall, function()
		MessagingService:PublishAsync(TOPIC, message)
	end)
end

---------------------------------------------------------------------------
-- Clip storage per player
---------------------------------------------------------------------------
type ClipStore = { clips: { any }, loaded: boolean, canSave: boolean, dirty: boolean, saving: boolean }
local clipStores: { [number]: ClipStore } = {}

local function storeOf(player: Player): ClipStore
	local s = clipStores[player.UserId]
	if not s then
		s = { clips = {}, loaded = false, canSave = false, dirty = false, saving = false }
		clipStores[player.UserId] = s
	end
	return s
end

local function saveClips(userId: number)
	local s = clipStores[userId]
	if not s or not s.dirty or not s.canSave or s.saving or not ClipsDS or mode ~= "ds" then
		return
	end
	s.saving = true
	s.dirty = false
	local payload = { v = 1, clips = s.clips }
	local ok = false
	for attempt = 1, 3 do
		ok = pcall(function()
			(ClipsDS :: DataStore):SetAsync("user_" .. userId, payload)
		end)
		if ok then
			break
		end
		task.wait(attempt)
	end
	if not ok then
		s.dirty = true
	end
	s.saving = false
end

local function markClipsDirty(player: Player)
	local s = storeOf(player)
	if s.dirty then
		return
	end
	s.dirty = true
	task.delay(8, saveClips, player.UserId)
end

local function loadClips(player: Player)
	local s = storeOf(player)
	if s.loaded then
		return -- memory store kept from earlier in this server
	end
	waitMode()
	if mode ~= "ds" or not ClipsDS then
		s.loaded = true
		return
	end
	local ok, data = false, nil
	for attempt = 1, 3 do
		ok, data = pcall(function()
			return (ClipsDS :: DataStore):GetAsync("user_" .. player.UserId)
		end)
		if ok then
			break
		end
		task.wait(attempt)
	end
	s.loaded = true
	if not ok then
		-- Don't overwrite a save we couldn't read; new clips stay in memory this session.
		s.canSave = false
		return
	end
	s.canSave = true
	local saved = type(data) == "table" and type(data.clips) == "table" and data.clips or {}
	local seen = {}
	for _, c in s.clips do
		seen[c.id] = true
	end
	for _, c in saved do
		if type(c) == "table" and type(c.id) == "string" and not seen[c.id] then
			table.insert(s.clips, c)
		end
	end
	while #s.clips > Cfg.MAX_CLIPS do
		table.remove(s.clips)
	end
	if #s.clips > #saved then
		markClipsDirty(player)
	end
end

local function findClip(player: Player, id: any): (any, number?)
	if type(id) ~= "string" then
		return nil, nil
	end
	for i, c in storeOf(player).clips do
		if c.id == id then
			return c, i
		end
	end
	return nil, nil
end

local function clipSummary(c: any): { [string]: any }
	return {
		id = c.id,
		kind = c.kind,
		tag = c.tag,
		title = c.title,
		at = c.at,
		loc = c.loc,
		dur = c.dur,
		posted = c.posted,
		edited = c.edit ~= nil,
		actors = if type(c.p) == "table" then #c.p else 0,
	}
end

function CityTok.listClips(player: Player): { { [string]: any } }
	local out = {}
	for _, c in storeOf(player).clips do
		table.insert(out, { id = c.id, kind = c.kind, title = c.title, at = c.at })
	end
	return out
end

local VALID_KINDS = { basketball = true, driving = true, gym = true, city = true }

-- Stores a finished clip (from this module or another server system).
function CityTok.saveClip(player: Player, clip: any): (boolean, string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or type(clip) ~= "table" then
		return false, "Invalid clip."
	end
	if type(clip.id) ~= "string" or #clip.id > 40 then
		clip.id = newId()
	end
	if not VALID_KINDS[clip.kind] or type(clip.p) ~= "table" or not num(clip.n) or not num(clip.hz) then
		return false, "Invalid clip."
	end
	clip.title = if type(clip.title) == "string" then clip.title:sub(1, 40) else "CLIP"
	local ok, json = pcall(HttpService.JSONEncode, HttpService, clip)
	if not ok or #json > Cfg.MAX_CLIP_BYTES then
		return false, "Clip is too large."
	end
	local s = storeOf(player)
	local _, existing = findClip(player, clip.id)
	if existing then
		table.remove(s.clips, existing)
	end
	table.insert(s.clips, 1, clip)
	while #s.clips > Cfg.MAX_CLIPS do
		table.remove(s.clips)
	end
	markClipsDirty(player)
	return true, nil
end

---------------------------------------------------------------------------
-- Recorder
---------------------------------------------------------------------------
type PlayerSample = { pos: Vector3, yaw: number, j: { number } }
type Frame = {
	t: number,
	p: { [number]: PlayerSample },
	b: { [number]: Vector3 },
	v: { [Model]: CFrame },
}
local frames: { Frame } = {}
local ballIds: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
local nextBallId = 0
local callouts: { { t: number, x: string, users: { [number]: boolean } } } = {}

local function ballId(ball: any): number
	local id = ballIds[ball]
	if not id then
		nextBallId += 1
		id = nextBallId
		ballIds[ball] = id
	end
	return id
end

local function sampleFrame(now: number)
	local frame: Frame = { t = now, p = {}, b = {}, v = {} }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local s = Replay.samplePlayer(character)
			if s then
				frame.p[player.UserId] = s
			end
		end
	end
	for ball in Basketball.balls() do
		if ball.part and ball.part.Parent then
			frame.b[ballId(ball)] = ball.part.Position
		end
	end
	for _, model in CollectionService:GetTagged("CityVehicle") do
		if model:IsA("Model") and model:GetAttribute("Owner") and model.PrimaryPart and model:IsDescendantOf(workspace) then
			frame.v[model] = model.PrimaryPart.CFrame
		end
	end
	table.insert(frames, frame)
	while frames[1] and now - frames[1].t > Cfg.BUFFER_SECONDS do
		table.remove(frames, 1)
	end
	while callouts[1] and now - callouts[1].t > Cfg.BUFFER_SECONDS + 3 do
		table.remove(callouts, 1)
	end
end

-- Mirror CourtGames / Basketball callouts into the buffer so clips show them.
local function hookCallouts()
	local original = Basketball.announce
	Basketball.announce = function(players: { Player }, text: string)
		original(players, text)
		local users = {}
		for _, p in players do
			users[p.UserId] = true
		end
		table.insert(callouts, { t = os.clock(), x = tostring(text):sub(1, 40), users = users })
	end
end

local function courtNear(pos: Vector3): Model?
	for _, court in CollectionService:GetTagged("Court") do
		local center = court:GetAttribute("CourtCenter")
		if typeof(center) == "Vector3" and (flat(center - pos)).Magnitude < 60 and math.abs(center.Y - pos.Y) < 40 then
			return court
		end
	end
	return nil
end

local function locationOf(player: Player, pos: Vector3): string
	local interior = player:GetAttribute("Interior")
	if type(interior) == "string" and interior ~= "" then
		return interior
	end
	local court = courtNear(pos)
	if court then
		return tostring(court:GetAttribute("DisplayName") or court.Name)
	end
	local points = city and city:FindFirstChild("MapPoints")
	local best, bestDist = nil, 90
	if points then
		for _, p in points:GetChildren() do
			if p:IsA("BasePart") then
				local d = (flat(p.Position - pos)).Magnitude
				if d < bestDist then
					best, bestDist = p.Name, d
				end
			end
		end
	end
	return best or "The Neighborhood"
end

local function vehicleDriver(model: Model): number
	local Vehicles = lazy("Vehicles")
	if Vehicles and Vehicles.drivingVehicle then
		for _, p in Players:GetPlayers() do
			local ok, m = pcall(Vehicles.drivingVehicle, p)
			if ok and m == model then
				return p.UserId
			end
		end
	end
	return 0
end

type ClipInfo = { kind: string, tag: string, title: string, at: number, tags: { string } }

-- Freezes buffered frames [startT, endT] around `focus` into a clip table.
local function buildClip(focus: Player, startT: number, endT: number, info: ClipInfo): any
	local list = {}
	for _, fr in frames do
		if fr.t >= startT - 0.001 and fr.t <= endT + 0.001 then
			table.insert(list, fr)
		end
	end
	local uid = focus.UserId
	-- star position each frame (for "who is near the action")
	local starAt: { Vector3? } = {}
	local starAny: Vector3? = nil
	local eventPos: Vector3? = nil
	local bestDt = math.huge
	for i, fr in list do
		local s = fr.p[uid]
		starAt[i] = s and s.pos
		if s then
			starAny = starAny or s.pos
			local dt = math.abs(fr.t - info.at)
			if dt < bestDt then
				bestDt, eventPos = dt, s.pos
			end
		end
	end
	if #list < 6 or not starAny then
		return nil
	end
	eventPos = eventPos or starAny
	local court = if info.kind == "basketball" then courtNear(eventPos :: Vector3) else nil
	local originV = if court then court:GetAttribute("CourtCenter") :: Vector3 else eventPos :: Vector3
	local origin = Vector3.new(math.floor(originV.X + 0.5), math.floor(originV.Y + 0.5), math.floor(originV.Z + 0.5))

	local function minDistance(get: (Frame) -> Vector3?): number
		local best = math.huge
		for i, fr in list do
			local pos = get(fr)
			local star = starAt[i]
			if pos and star then
				best = math.min(best, (pos - star).Magnitude)
			end
		end
		return best
	end

	-- actors
	local actorIds: { [number]: number } = {}
	for _, fr in list do
		for id in fr.p do
			actorIds[id] = actorIds[id] or 0
		end
	end
	local actors = {}
	for id in actorIds do
		local d = if id == uid then -1 else minDistance(function(fr)
			local s = fr.p[id]
			return s and s.pos
		end)
		if d <= Cfg.ACTION_RADIUS then
			table.insert(actors, { id = id, d = d })
		end
	end
	table.sort(actors, function(a, b)
		return a.d < b.d
	end)

	local ballList = {}
	local ballSeen: { [number]: boolean } = {}
	for _, fr in list do
		for id in fr.b do
			ballSeen[id] = true
		end
	end
	for id in ballSeen do
		local d = minDistance(function(fr)
			return fr.b[id]
		end)
		if d <= Cfg.ACTION_RADIUS then
			table.insert(ballList, { id = id, d = d })
		end
	end
	table.sort(ballList, function(a, b)
		return a.d < b.d
	end)

	local vehicleList = {}
	local vehicleSeen: { [Model]: boolean } = {}
	for _, fr in list do
		for m in fr.v do
			vehicleSeen[m] = true
		end
	end
	local vRadius = if info.kind == "driving" then Cfg.VEHICLE_RADIUS else Cfg.ACTION_RADIUS
	for m in vehicleSeen do
		local d = minDistance(function(fr)
			local cf = fr.v[m]
			return cf and cf.Position
		end)
		if d <= vRadius then
			table.insert(vehicleList, { m = m, d = d })
		end
	end
	table.sort(vehicleList, function(a, b)
		return a.d < b.d
	end)

	-- side axis for the broadcast camera
	local ax = 0
	if not court then
		local first, last = nil, nil
		for i = 1, #list do
			first = first or starAt[i]
			last = starAt[i] or last
		end
		local disp = if first and last then flat(last - first) else Vector3.zero
		if disp.Magnitude > 5 then
			local dir = disp.Unit
			ax = math.atan2(dir.X, -dir.Z)
		else
			local s = list[#list].p[uid] or list[1].p[uid]
			ax = if s then -s.yaw else 0
		end
	end

	-- encode tracks
	local p = {}
	for i = 1, math.min(#actors, Cfg.MAX_ACTORS) do
		local id = actors[i].id
		local parts = table.create(#list, "")
		local animated = 0
		for k, fr in list do
			local s = fr.p[id]
			parts[k] = Replay.encodePlayerFrame(s, origin)
			if s and animated == 0 then
				for j = 1, 12 do
					if math.abs(s.j[j]) > 0.2 then
						animated = 1
						break
					end
				end
			end
		end
		local plr = Players:GetPlayerByUserId(id)
		table.insert(p, {
			u = id,
			n = if plr then plr.DisplayName else "Player",
			c = Replay.bodyColors(plr and plr.Character),
			a = animated,
			f = table.concat(parts),
		})
	end
	local b = {}
	for i = 1, math.min(#ballList, Cfg.MAX_BALLS) do
		local id = ballList[i].id
		local parts = table.create(#list, "")
		for k, fr in list do
			parts[k] = Replay.encodeBallFrame(fr.b[id], origin)
		end
		table.insert(b, { f = table.concat(parts) })
	end
	local vh = {}
	for i = 1, math.min(#vehicleList, Cfg.MAX_VEHICLES) do
		local m = vehicleList[i].m
		local parts = table.create(#list, "")
		for k, fr in list do
			parts[k] = Replay.encodeVehicleFrame(fr.v[m], origin)
		end
		local paint = VC.PAINTS[tonumber(m:GetAttribute("Paint")) or 1] or VC.PAINTS[1]
		local size = if m.PrimaryPart then m.PrimaryPart.Size else Vector3.new(6, 4, 12)
		table.insert(vh, {
			u = vehicleDriver(m),
			k = tostring(m:GetAttribute("Kind") or "Car"),
			c = paint.color:ToHex(),
			s = { round(size.X, 1), round(size.Y, 1), round(size.Z, 1) },
			f = table.concat(parts),
		})
	end

	-- callouts heard by anyone in the clip + the highlight itself
	local inClip: { [number]: boolean } = {}
	for _, a in p do
		inClip[a.u] = true
	end
	local t0 = list[1].t
	local e = {}
	for _, c in callouts do
		if c.t >= t0 and c.t <= list[#list].t then
			for id in c.users do
				if inClip[id] then
					table.insert(e, { t = round(c.t - t0, 2), x = c.x })
					break
				end
			end
		end
	end
	if info.tag ~= "manual" then
		local covered = false
		for _, ev in e do
			if math.abs(ev.t - (info.at - t0)) < 1 then
				covered = true
			end
		end
		if not covered then
			table.insert(e, { t = round(math.max(0, info.at - t0), 2), x = info.title })
		end
	end

	return {
		v = 1,
		id = newId(),
		kind = info.kind,
		tag = info.tag,
		tags = info.tags,
		title = info.title,
		at = os.time(),
		loc = locationOf(focus, eventPos :: Vector3),
		hz = Cfg.HZ,
		n = #list,
		dur = round((#list - 1) / Cfg.HZ, 2),
		o = { origin.X, origin.Y, origin.Z },
		ax = round(ax, 3),
		ck = round(Lighting.ClockTime, 1),
		focus = uid,
		p = p,
		b = b,
		vh = vh,
		e = e,
	}
end

-- Builds the clip, shrinking it (fewer far actors, then shorter) until it fits the size cap.
local function buildFittingClip(focus: Player, startT: number, endT: number, info: ClipInfo): any
	for _ = 1, 8 do
		local clip = buildClip(focus, startT, endT, info)
		if not clip then
			return nil
		end
		local ok, json = pcall(HttpService.JSONEncode, HttpService, clip)
		if ok and #json <= Cfg.MAX_CLIP_BYTES then
			return clip
		end
		-- too big: drop the farthest extras first, then trim the start
		while #clip.p > 2 or #clip.vh > 1 do
			if #clip.p > 2 then
				table.remove(clip.p)
			else
				table.remove(clip.vh)
			end
			ok, json = pcall(HttpService.JSONEncode, HttpService, clip)
			if ok and #json <= Cfg.MAX_CLIP_BYTES then
				return clip
			end
		end
		startT += 1
	end
	return nil
end

---------------------------------------------------------------------------
-- Highlights
---------------------------------------------------------------------------
type PendingHL = { first: number, last: number, at: number, best: string, tags: { string }, kind: string }
local pendingHL: { [Player]: PendingHL } = {}
local tagCooldown: { [Player]: { [string]: number } } = {}

local function manualKind(player: Player): string
	local driving = player:GetAttribute("Driving")
	if type(driving) == "string" and driving ~= "" then
		return "driving"
	end
	local training = player:GetAttribute("Training")
	if type(training) == "string" and training ~= "" then
		return "gym"
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and courtNear(root.Position) then
		return "basketball"
	end
	return "city"
end

function CityTok.highlight(player: Player, tag: string, at: number?)
	local def = Cfg.TAGS[tag]
	if not def or not player.Parent then
		return
	end
	local now = at or os.clock()
	if tag ~= "gamewinner" and tag ~= "manual" then
		local cds = tagCooldown[player]
		if not cds then
			cds = {}
			tagCooldown[player] = cds
		end
		if cds[tag] and now - cds[tag] < Cfg.TAG_COOLDOWN then
			return
		end
		cds[tag] = now
	end
	local p = pendingHL[player]
	if p then
		if not table.find(p.tags, tag) then
			table.insert(p.tags, tag)
		end
		p.last = math.max(p.last, now)
		if def.priority > Cfg.TAGS[p.best].priority then
			p.best, p.at = tag, now
			if def.kind ~= "city" then
				p.kind = def.kind
			end
		end
		return
	end
	pendingHL[player] = {
		first = now,
		last = now,
		at = now,
		best = tag,
		tags = { tag },
		kind = if tag == "manual" then manualKind(player) else def.kind,
	}
end

local function finalize(player: Player, p: PendingHL)
	local endT = p.last + Cfg.POST_SECONDS
	local startT = math.max(p.first - Cfg.PRE_SECONDS, endT - Cfg.MAX_CLIP_SECONDS)
	local def = Cfg.TAGS[p.best]
	local title = def.title
	if p.best == "manual" then
		title = string.upper(Cfg.KIND_CATEGORY[p.kind] or "City") .. " CLIP"
	end
	local clip = buildFittingClip(player, startT, endT, {
		kind = p.kind,
		tag = p.best,
		title = title,
		at = p.at,
		tags = p.tags,
	})
	if not clip then
		if p.best == "manual" then
			Net.notify(player, "CityTok", "Nothing to clip yet. Try again in a few seconds.")
		end
		return
	end
	local ok = CityTok.saveClip(player, clip)
	if ok then
		EventRemote:FireClient(player, "Highlight", clipSummary(clip))
	end
end

local function connectBasketball()
	-- per-court game points for the 10-point streak, reset when a new game starts
	local gamePoints: { [Model]: { pts: { [Player]: number }, done: { [Player]: boolean } } } = {}
	local function watchCourt(court: Instance)
		if not court:IsA("Model") then
			return
		end
		gamePoints[court] = { pts = {}, done = {} }
		court:GetAttributeChangedSignal("State"):Connect(function()
			if court:GetAttribute("State") == "Playing" then
				gamePoints[court] = { pts = {}, done = {} }
			end
		end)
	end
	for _, court in CollectionService:GetTagged("Court") do
		watchCourt(court)
	end
	CollectionService:GetInstanceAddedSignal("Court"):Connect(watchCourt)

	Basketball.scored.connect(function(ball, hoop, shot)
		if not shot or not shot.shooter or not shot.shooter.Parent then
			return
		end
		local shooter: Player = shot.shooter
		local now = os.clock()
		if shot.kind == "dunk" then
			CityTok.highlight(shooter, "dunk", now)
		end
		if shot.kind == "deep" then
			CityTok.highlight(shooter, "logo", now)
		elseif shot.points == 3 then
			CityTok.highlight(shooter, "three", now)
		end
		if shot.perfect then
			CityTok.highlight(shooter, "perfect", now)
		end

		local gc = ball.gameCourt
		if gc and gc:GetAttribute("State") == "Playing" then
			local team = if hoop.side == "North" then "Home" else "Away"
			if shooter:GetAttribute("Team") ~= team then
				return
			end
			local g = gamePoints[gc]
			if g then
				g.pts[shooter] = (g.pts[shooter] or 0) + shot.points
				if g.pts[shooter] >= 10 and not g.done[shooter] then
					g.done[shooter] = true
					CityTok.highlight(shooter, "tenpoints", now)
				end
			end
			-- CourtGames ends the game ~1.2 s after the winning basket.
			task.delay(1.5, function()
				if gc:GetAttribute("State") == "Ended" and shooter.Parent then
					CityTok.highlight(shooter, "gamewinner", now)
				end
			end)
		end
	end)
	Basketball.blocked.connect(function(_ball, blocker, _shooter)
		if blocker and blocker.Parent then
			CityTok.highlight(blocker, "block")
		end
	end)
	Basketball.stolen.connect(function(_ball, stealer, _victim)
		if stealer and stealer.Parent then
			CityTok.highlight(stealer, "steal")
		end
	end)
end

-- Driving: sustained top speed and big air (checked every recorder tick).
type DriveState = { fastSince: number?, fastDone: boolean, airSince: number? }
local driveStates: { [Player]: DriveState } = {}
-- selene: allow(undefined_variable)
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function checkDriving(now: number)
	local Vehicles = lazy("Vehicles")
	if not Vehicles or not Vehicles.drivingVehicle then
		return
	end
	local characters = {}
	for _, plr in Players:GetPlayers() do
		if plr.Character then
			table.insert(characters, plr.Character)
		end
	end
	for _, plr in Players:GetPlayers() do
		local ok, model = pcall(Vehicles.drivingVehicle, plr)
		local chassis = ok and model and model.PrimaryPart
		if not chassis then
			driveStates[plr] = nil
			continue
		end
		local st = driveStates[plr]
		if not st then
			st = { fastSince = nil, fastDone = false, airSince = nil }
			driveStates[plr] = st
		end
		local spec = VC.byId[model:GetAttribute("VehicleId")]
		local speed = (flat(chassis.AssemblyLinearVelocity)).Magnitude
		if spec and speed >= spec.topSpeed * Cfg.TOP_SPEED_FRACTION then
			st.fastSince = st.fastSince or now
			if not st.fastDone and now - (st.fastSince :: number) >= Cfg.TOP_SPEED_SECONDS then
				st.fastDone = true
				CityTok.highlight(plr, "topspeed", now)
			end
		else
			st.fastSince = nil
			st.fastDone = false
		end
		local filter = table.clone(characters)
		table.insert(filter, model)
		rayParams.FilterDescendantsInstances = filter
		local hit = workspace:Raycast(chassis.Position, Vector3.new(0, -(chassis.Size.Y / 2 + 3.5), 0), rayParams)
		if not hit then
			st.airSince = st.airSince or now
		else
			if st.airSince and now - st.airSince >= Cfg.AIR_SECONDS then
				CityTok.highlight(plr, "bigair", st.airSince + (now - st.airSince) / 2)
				local p = pendingHL[plr]
				if p then
					p.last = math.max(p.last, now)
				end
			end
			st.airSince = nil
		end
	end
end

---------------------------------------------------------------------------
-- Posts
---------------------------------------------------------------------------
type Meta = { [string]: any }
local metaCache: { [string]: { meta: Meta?, at: number } } = {}
local clipCache: { [string]: { data: any, at: number } } = {}
local recentCache: { list: { any }, at: number } = { list = {}, at = -math.huge }
local trendCache: { ids: { string }, at: number } = { ids = {}, at = -math.huge }
local pending: { [string]: any } = {}
local opened: { [Player]: { [string]: number } } = {}
local viewed: { [Player]: { [string]: boolean } } = {}

local function engagementOf(m: Meta): number
	return Cfg.engagement(m.nl or 0, m.nc or 0, m.ns or 0, m.nv or 0)
end

local function scoreOf(m: Meta): number
	return Cfg.trendScore(engagementOf(m), os.time() - (m.t or os.time()))
end

local function getMeta(id: string, maxAge: number?): Meta?
	-- [Security] post ids are short alphanumerics (newId); anything else would cost a DataStore read per call
	if type(id) ~= "string" or #id == 0 or #id > 32 or not id:match("^%w+$") then
		return nil
	end
	local c = metaCache[id]
	if c and os.clock() - c.at < (maxAge or 45) then
		return c.meta
	end
	local ok, value = kvGet("post_" .. id)
	if not ok then
		return c and c.meta -- keep stale data on a failed read
	end
	local meta = if type(value) == "table" and not value.del then value else nil
	metaCache[id] = { meta = meta, at = os.clock() }
	return meta
end

-- Fetches several metas in parallel.
local function getMetas(ids: { string }): { [string]: Meta }
	local out: { [string]: Meta } = {}
	local remaining = #ids
	if remaining == 0 then
		return out
	end
	local thread = coroutine.running()
	local waiting = false
	for _, id in ids do
		task.spawn(function()
			local m = getMeta(id)
			if m then
				out[id] = m
			end
			remaining -= 1
			if remaining == 0 and waiting then
				task.spawn(thread)
			end
		end)
	end
	if remaining > 0 then
		waiting = true
		coroutine.yield()
	end
	return out
end

local function getRecent(): { any }
	if os.clock() - recentCache.at < 30 then
		return recentCache.list
	end
	local ok, value = kvGet("recent")
	if ok then
		recentCache.list = if type(value) == "table" and type(value.list) == "table" then value.list else {}
		recentCache.at = os.clock()
	end
	return recentCache.list
end

local function addRecentLocal(entry: any)
	for i, e in recentCache.list do
		if e.id == entry.id then
			table.remove(recentCache.list, i)
			break
		end
	end
	table.insert(recentCache.list, 1, entry)
end

local function removeRecentLocal(id: string)
	for i, e in recentCache.list do
		if e.id == id then
			table.remove(recentCache.list, i)
			break
		end
	end
end

local function getTrendingIds(): { string }
	if os.clock() - trendCache.at < 60 then
		return trendCache.ids
	end
	local ids = {}
	if mode == "ds" and TrendDS then
		local ok, pages = pcall(function()
			return (TrendDS :: OrderedDataStore):GetSortedAsync(false, 60)
		end)
		if ok and pages then
			for _, entry in pages:GetCurrentPage() do
				table.insert(ids, entry.key)
			end
		else
			return trendCache.ids
		end
	else
		local scored = {}
		for k, v in memKV do
			if k:sub(1, 5) == "post_" and type(v) == "table" and not v.del then
				table.insert(scored, { id = v.id, s = scoreOf(v) })
			end
		end
		table.sort(scored, function(a, b)
			return a.s > b.s
		end)
		for i = 1, math.min(60, #scored) do
			table.insert(ids, scored[i].id)
		end
	end
	trendCache.ids, trendCache.at = ids, os.clock()
	return ids
end

local function section(player: Player): any
	return PlayerData.section(player, "citytok")
end

local function summary(m: Meta, viewer: Player): { [string]: any }
	local sec = section(viewer)
	local uid = key(viewer.UserId)
	return {
		id = m.id,
		by = m.by,
		name = m.name,
		cat = m.cat,
		kind = m.kind,
		title = m.title,
		cap = m.cap,
		loc = m.loc,
		t = m.t,
		dur = m.dur,
		likes = m.nl or 0,
		views = m.nv or 0,
		comments = m.ncom or 0,
		shares = m.ns or 0,
		liked = type(m.likes) == "table" and m.likes[uid] ~= nil,
		faved = sec ~= nil and table.find(sec.favs, m.id) ~= nil,
		following = isFollowing(viewer.UserId, m.by),
		mine = m.by == viewer.UserId,
		trending = type(m.aw) == "table" and m.aw.trending ~= nil,
		viral = type(m.aw) == "table" and m.aw.viral ~= nil,
	}
end

local function visibleTo(m: Meta?, viewer: Player): boolean
	return m ~= nil and not m.del and not socialBlocked(viewer, m.by)
end

-- Applies queued engagement to a meta (both to the cached copy and inside UpdateAsync).
local function applyDelta(m: Meta, d: any)
	m.likes = m.likes or {}
	m.views = m.views or {}
	m.shares = m.shares or {}
	m.commenters = m.commenters or {}
	m.com = m.com or {}
	for uid, on in d.like do
		if on and not m.likes[uid] then
			m.likes[uid] = 1
			m.nl = (m.nl or 0) + 1
		elseif not on and m.likes[uid] then
			m.likes[uid] = nil
			m.nl = math.max(0, (m.nl or 0) - 1)
		end
	end
	for uid in d.views do
		if not m.views[uid] then
			if (m.nv or 0) < 5000 then
				m.views[uid] = 1
			end
			m.nv = (m.nv or 0) + 1
		end
	end
	for uid in d.shares do
		if not m.shares[uid] then
			m.shares[uid] = 1
			m.ns = (m.ns or 0) + 1
		end
	end
	for _, c in d.comments do
		table.insert(m.com, c)
		m.ncom = (m.ncom or 0) + 1
		local uid = key(c.u)
		if c.u ~= m.by and not m.commenters[uid] then
			m.commenters[uid] = 1
			m.nc = (m.nc or 0) + 1
		end
	end
	while #m.com > Cfg.MAX_COMMENTS do
		table.remove(m.com, 1)
	end
end

local function queue(id: string): any
	local d = pending[id]
	if not d then
		d = { like = {}, views = {}, shares = {}, comments = {} }
		pending[id] = d
	end
	return d
end

-- Applies one queued change to the cached meta right away (so this server sees it).
local function applyLocal(id: string, change: any)
	local c = metaCache[id]
	if c and c.meta then
		applyDelta(c.meta, change)
	end
end

local function emptyDelta(): any
	return { like = {}, views = {}, shares = {}, comments = {} }
end

---------------------------------------------------------------------------
-- Rewards (spec 26, 35): reputation (daily cap) + fame. Never cash.
---------------------------------------------------------------------------
local function reward(player: Player, kind: string)
	local r = if kind == "viral" then Cfg.VIRAL_REWARD else Cfg.TRENDING_REWARD
	local sec = section(player)
	local rep, fame = 0, 0
	if sec then
		local day = os.date("!%Y-%m-%d")
		if sec.repDay ~= day then
			sec.repDay = day
			sec.repToday = 0
			sec.fameToday = 0
		end
		rep = math.max(0, math.min(r.rep, Cfg.DAILY_REP_CAP - (sec.repToday or 0)))
		sec.repToday = (sec.repToday or 0) + rep
		fame = math.max(0, math.min(r.fame, Cfg.DAILY_FAME_CAP - (sec.fameToday or 0)))
		sec.fameToday = (sec.fameToday or 0) + fame
		PlayerData.markChanged(player)
	end
	if rep > 0 then
		PlayerData.addReputation(player, rep)
	end
	if fame > 0 then
		PlayerData.addFame(player, fame)
	end
	if kind == "viral" then
		Net.notify(player, "CityTok", "Your video went viral! +" .. rep .. " rep, +" .. fame .. " fame.")
	else
		Net.notify(player, "CityTok", "Your video is trending. +" .. rep .. " rep, +" .. fame .. " fame.")
	end
end

-- Claims pending ("p") awards on a post atomically, then rewards the creator.
local function grantAwards(player: Player, id: string)
	local granted: { string } = {}
	local ok, result = kvUpdate("post_" .. id, function(old)
		granted = {}
		if type(old) ~= "table" or old.by ~= player.UserId or type(old.aw) ~= "table" then
			return nil
		end
		for _, k in { "trending", "viral" } do
			if old.aw[k] == "p" then
				old.aw[k] = true
				table.insert(granted, k)
			end
		end
		return if #granted > 0 then old else nil
	end)
	if ok and type(result) == "table" then
		metaCache[id] = { meta = if result.del then nil else result, at = os.clock() }
	end
	if ok and player.Parent then
		for _, k in granted do
			reward(player, k)
		end
	end
end

local function checkOwnAwards(player: Player)
	local sec = section(player)
	if not sec then
		return
	end
	for i = 1, math.min(15, #sec.posts) do
		local m = getMeta(sec.posts[i], 5)
		if m and type(m.aw) == "table" and (m.aw.trending == "p" or m.aw.viral == "p") then
			grantAwards(player, m.id)
		end
	end
end

-- Writes queued engagement to the store, marks thresholds crossed, updates trend score.
local function flush()
	local batch = pending
	pending = {}
	for id, d in batch do
		local ok, result = kvUpdate("post_" .. id, function(old)
			if type(old) ~= "table" or old.del then
				return nil
			end
			applyDelta(old, d)
			old.aw = old.aw or {}
			local eng = engagementOf(old)
			if eng >= Cfg.TRENDING_AT and old.aw.trending == nil then
				old.aw.trending = "p"
			end
			if eng >= Cfg.VIRAL_AT and old.aw.viral == nil then
				old.aw.viral = "p"
			end
			return old
		end)
		if not ok then
			-- put it back for the next flush
			local q = queue(id)
			for uid, on in d.like do
				if q.like[uid] == nil then
					q.like[uid] = on
				end
			end
			for uid in d.views do
				q.views[uid] = true
			end
			for uid in d.shares do
				q.shares[uid] = true
			end
			for i, c in d.comments do
				table.insert(q.comments, i, c)
			end
		elseif type(result) == "table" then
			metaCache[id] = { meta = result, at = os.clock() }
			trendSet(id, scoreOf(result))
			publish({ op = "stat", id = id })
			if type(result.aw) == "table" and (result.aw.trending == "p" or result.aw.viral == "p") then
				local creator = Players:GetPlayerByUserId(result.by)
				if creator then
					task.spawn(grantAwards, creator, id)
				else
					publish({ op = "award", id = id, by = result.by })
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Edit parameters (the editor only stores these, never new frames)
---------------------------------------------------------------------------
function CityTok.sanitizeEdit(player: Player, raw: any, duration: number): (any, string?)
	if type(raw) ~= "table" then
		return nil, "Invalid edit."
	end
	local dur = math.max(0, duration)
	local e: { [string]: any } = {}
	local ts = math.clamp(num(raw.ts) or 0, 0, math.max(0, dur - 1))
	local te = math.clamp(num(raw.te) or dur, math.min(dur, ts + 1), dur)
	e.ts, e.te = round(ts, 2), round(te, 2)
	if type(raw.sm) == "table" then
		local a, b, r = num(raw.sm[1]), num(raw.sm[2]), num(raw.sm[3])
		if a and b and r and table.find(Cfg.SLOWMO_RATES, r) then
			a = math.clamp(a, ts, te)
			b = math.clamp(b, a, te)
			if b - a >= 0.2 then
				e.sm = { round(a, 2), round(b, 2), r }
			end
		end
	end
	e.fov = math.floor(math.clamp(num(raw.fov) or Cfg.FOV_DEFAULT, Cfg.FOV_MIN, Cfg.FOV_MAX) + 0.5)
	e.cam = if type(raw.cam) == "string" and table.find(Cfg.CAMERAS, raw.cam) then raw.cam else "broadcast"
	e.fl = if type(raw.fl) == "string" and Cfg.FILTER_BY_ID[raw.fl] then raw.fl else "none"
	if type(raw.st) == "table" then
		local stickers = {}
		for _, s in raw.st do
			if #stickers >= Cfg.MAX_STICKERS then
				break
			end
			if type(s) == "table" then
				local idx, x, y = num(s.e), num(s.x), num(s.y)
				if idx and x and y and idx == math.floor(idx) and Cfg.STICKERS[idx] then
					table.insert(stickers, { e = idx, x = round(math.clamp(x, 0, 1), 3), y = round(math.clamp(y, 0, 1), 3) })
				end
			end
		end
		if #stickers > 0 then
			e.st = stickers
		end
	end
	if raw.tx ~= nil and raw.tx ~= "" then
		local text = cleanText(raw.tx, Cfg.OVERLAY_MAX)
		if not text then
			return nil, "Overlay text is 1-" .. Cfg.OVERLAY_MAX .. " characters."
		end
		if not canUseText(player) then
			return nil, "Your account settings don't allow text."
		end
		local filtered = filterPublic(player, text)
		if not filtered then
			return nil, "Your text couldn't be checked right now. Try again."
		end
		e.tx = filtered
		e.ty = round(math.clamp(num(raw.ty) or 0.8, 0.08, 0.92), 2)
	end
	if type(raw.mu) == "string" or type(raw.mu) == "number" then
		local id = tostring(raw.mu)
		if #id <= 40 and id:match("^[%w_%-]+$") then
			e.mu = id
		end
	end
	return e, nil
end

---------------------------------------------------------------------------
-- Request handlers
---------------------------------------------------------------------------
local handlers: { [string]: (Player, any) -> (boolean, string?, any) } = {}

handlers.Caps = function(_player)
	return true, nil, { follow = cityGram() ~= nil, share = lazy("Messages") ~= nil and lazy("Social") ~= nil }
end

handlers.MyClips = function(player)
	local list = {}
	for _, c in storeOf(player).clips do
		table.insert(list, clipSummary(c))
	end
	return true, nil, list
end

handlers.GetClip = function(player, id)
	local clip = findClip(player, id)
	if not clip then
		return false, "That clip is gone."
	end
	return true, nil, clip
end

handlers.DeleteClip = function(player, id)
	local _, index = findClip(player, id)
	if not index then
		return false, "That clip is gone."
	end
	table.remove(storeOf(player).clips, index)
	markClipsDirty(player)
	return true, "Clip deleted."
end

handlers.SaveEdit = function(player, payload)
	if type(payload) ~= "table" or not Net.allow(player, "TokEdit", 1) then
		return false, "Slow down."
	end
	local clip = findClip(player, payload.id)
	if not clip then
		return false, "That clip is gone."
	end
	local edit, err = CityTok.sanitizeEdit(player, payload.edit, clip.dur or 0)
	if not edit then
		return false, err
	end
	clip.edit = edit
	markClipsDirty(player)
	return true, "Edit saved.", edit
end

handlers.ClipNow = function(player)
	if not Net.allow(player, "TokClipNow", Cfg.MANUAL_COOLDOWN) then
		return false, "You just clipped. Try again in a few seconds."
	end
	if not Net.alive(player) then
		return false, "Nothing to clip right now."
	end
	-- the last ~8 seconds, frozen right now
	local now = os.clock()
	CityTok.highlight(player, "manual", now - Cfg.POST_SECONDS)
	return true, "Clipping the last " .. (Cfg.PRE_SECONDS + Cfg.POST_SECONDS) .. " seconds..."
end

handlers.Post = function(player, payload)
	if type(payload) ~= "table" then
		return false, "Invalid post."
	end
	local clip = findClip(player, payload.id)
	if not clip then
		return false, "That clip is gone."
	end
	if clip.posted then
		return false, "You already posted this clip."
	end
	local sec = section(player)
	if not sec then
		return false, "Your profile is still loading."
	end
	local category = payload.cat
	if type(category) ~= "string" or not table.find(Cfg.CATEGORIES, category) then
		category = Cfg.KIND_CATEGORY[clip.kind] or "City Life"
	end
	local caption = cleanText(payload.cap or "", Cfg.CAPTION_MAX, true)
	if not caption then
		return false, "Captions are up to " .. Cfg.CAPTION_MAX .. " characters."
	end
	if caption ~= "" then
		if not canUseText(player) then
			return false, "Your account settings don't allow text. Post without a caption."
		end
		caption = filterPublic(player, caption)
		if not caption then
			return false, "Your caption couldn't be checked right now. Try again."
		end
	end
	if not Net.allow(player, "TokPost", 20) then
		return false, "You just posted. Wait a few seconds."
	end
	local edit = clip.edit
	if payload.edit ~= nil then
		local e, err = CityTok.sanitizeEdit(player, payload.edit, clip.dur or 0)
		if not e then
			return false, err
		end
		edit = e
		clip.edit = e
	end

	local id = newId()
	local clipCopy = table.clone(clip)
	clipCopy.edit = nil
	clipCopy.posted = nil
	if not kvSet("clip_" .. id, { clip = clipCopy, edit = edit }) then
		return false, "CityTok is busy. Try again."
	end
	local meta: Meta = {
		id = id,
		by = player.UserId,
		name = player.DisplayName,
		cat = category,
		kind = clip.kind,
		title = clip.title,
		cap = caption,
		loc = clip.loc,
		t = os.time(),
		dur = clip.dur,
		nl = 0,
		nv = 0,
		ns = 0,
		nc = 0,
		ncom = 0,
		likes = {},
		views = {},
		shares = {},
		commenters = {},
		com = {},
		aw = {},
	}
	if not kvSet("post_" .. id, meta) then
		kvRemove("clip_" .. id)
		return false, "CityTok is busy. Try again."
	end
	local entry = { id = id, by = player.UserId, cat = category, t = meta.t }
	kvUpdate("recent", function(old)
		local list = if type(old) == "table" and type(old.list) == "table" then old.list else {}
		table.insert(list, 1, entry)
		while #list > Cfg.RECENT_INDEX do
			table.remove(list)
		end
		return { list = list }
	end)
	addRecentLocal(entry)
	trendSet(id, 0)
	trendCache.at = -math.huge
	metaCache[id] = { meta = meta, at = os.clock() }
	publish({ op = "new", e = entry })

	clip.posted = id
	markClipsDirty(player)
	table.insert(sec.posts, 1, id)
	while #sec.posts > Cfg.MAX_POSTS_KEPT do
		table.remove(sec.posts)
	end
	PlayerData.markChanged(player)

	-- followers in this server hear about it
	for _, other in Players:GetPlayers() do
		if other ~= player and isFollowing(other.UserId, player.UserId) and not socialBlocked(other, player.UserId) then
			Net.notify(other, "CityTok", player.DisplayName .. " posted a new video.")
		end
	end
	return true, "Posted to CityTok!", summary(meta, player)
end

handlers.DeletePost = function(player, id)
	if type(id) ~= "string" or not Net.allow(player, "TokDelete", 1) then
		return false, "Invalid post."
	end
	local sec = section(player)
	local current = getMeta(id, 0)
	if not current or current.by ~= player.UserId then
		return false, "That isn't your post."
	end
	local ok = kvUpdate("post_" .. id, function(old)
		if type(old) ~= "table" or old.by ~= player.UserId or old.del then
			return nil
		end
		old.del = true
		old.com = {}
		return old
	end)
	if not ok then
		return false, "CityTok is busy. Try again."
	end
	metaCache[id] = { meta = nil, at = os.clock() }
	kvUpdate("recent", function(old)
		if type(old) ~= "table" or type(old.list) ~= "table" then
			return nil
		end
		for i, e in old.list do
			if e.id == id and e.by == player.UserId then
				table.remove(old.list, i)
				return old
			end
		end
		return nil
	end)
	removeRecentLocal(id)
	trendRemove(id)
	trendCache.at = -math.huge
	kvRemove("clip_" .. id)
	clipCache[id] = nil
	publish({ op = "del", id = id })
	if sec then
		local i = table.find(sec.posts, id)
		if i then
			table.remove(sec.posts, i)
			PlayerData.markChanged(player)
		end
	end
	for _, c in storeOf(player).clips do
		if c.posted == id then
			c.posted = nil
			markClipsDirty(player)
		end
	end
	return true, "Post deleted."
end

local function pageOf(player: Player, ids: { string }, offset: number, sortFn: ((Meta, Meta) -> boolean)?): { any }
	local metas = getMetas(ids)
	local list = {}
	for _, id in ids do
		local m = metas[id]
		if visibleTo(m, player) then
			table.insert(list, m)
		end
	end
	if sortFn then
		table.sort(list, sortFn)
	end
	local out = {}
	for i = offset + 1, math.min(#list, offset + Cfg.PAGE_SIZE) do
		table.insert(out, summary(list[i], player))
	end
	return out
end

handlers.Feed = function(player, payload)
	if type(payload) ~= "table" or not Net.allow(player, "TokFeed", 0.5) then
		return false, "Slow down."
	end
	local tab = payload.tab
	local offset = math.clamp(math.floor(num(payload.offset) or 0), 0, 400)
	if type(tab) ~= "string" or not table.find(Cfg.TABS, tab) then
		return false, "Unknown feed."
	end
	local recent = getRecent()
	if tab == "Trending" then
		local ids = getTrendingIds()
		local metas = getMetas(ids)
		local scores = {}
		for id, m in metas do
			scores[id] = scoreOf(m)
		end
		return true, nil, pageOf(player, ids, offset, function(a, b)
			return (scores[a.id] or 0) > (scores[b.id] or 0)
		end)
	elseif tab == "Following" then
		if not cityGram() then
			return true, nil, {}
		end
		local ids = {}
		for _, e in recent do
			if #ids >= offset + Cfg.PAGE_SIZE then
				break
			end
			if isFollowing(player.UserId, e.by) then
				table.insert(ids, e.id)
			end
		end
		return true, nil, pageOf(player, ids, offset, nil)
	elseif tab == "Recommended" then
		local seen, ids = {}, {}
		for _, id in getTrendingIds() do
			if #ids >= 30 then
				break
			end
			seen[id] = true
			table.insert(ids, id)
		end
		for i = 1, math.min(#recent, 60) do
			local id = recent[i].id
			if not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
		local metas = getMetas(ids)
		local rank = {}
		for id, m in metas do
			local ageHours = math.max(0, os.time() - (m.t or os.time())) / 3600
			local s = scoreOf(m) + 3 / (ageHours + 1)
			if isFollowing(player.UserId, m.by) then
				s += 4
			end
			if m.by == player.UserId then
				s *= 0.3
			end
			rank[id] = s
		end
		return true, nil, pageOf(player, ids, offset, function(a, b)
			return (rank[a.id] or 0) > (rank[b.id] or 0)
		end)
	end
	-- category tab: newest first
	local ids = {}
	for _, e in recent do
		if #ids >= offset + Cfg.PAGE_SIZE then
			break
		end
		if e.cat == tab then
			table.insert(ids, e.id)
		end
	end
	return true, nil, pageOf(player, ids, offset, nil)
end

local function listByIds(player: Player, ids: { string }): { any }
	local metas = getMetas(ids)
	local out = {}
	for _, id in ids do
		local m = metas[id]
		if visibleTo(m, player) then
			table.insert(out, summary(m :: Meta, player))
		end
	end
	return out
end

handlers.MyPosts = function(player)
	local sec = section(player)
	if not sec then
		return false, "Your profile is still loading."
	end
	return true, nil, listByIds(player, table.move(sec.posts, 1, math.min(#sec.posts, 30), 1, {}))
end

handlers.Favs = function(player)
	local sec = section(player)
	if not sec then
		return false, "Your profile is still loading."
	end
	return true, nil, listByIds(player, sec.favs)
end

handlers.Inbox = function(player)
	local sec = section(player)
	if not sec then
		return false, "Your profile is still loading."
	end
	local ids, from = {}, {}
	for _, item in sec.inbox do
		table.insert(ids, item.i)
		from[item.i] = item
	end
	local list = listByIds(player, ids)
	for _, s in list do
		local item = from[s.id]
		s.sharedBy = item and item.f
		s.sharedAt = item and item.t
	end
	return true, nil, list
end

handlers.GetPost = function(player, id)
	if type(id) ~= "string" or #id > 40 or not Net.allow(player, "TokGetPost", 0.25) then
		return false, "Slow down."
	end
	local m = getMeta(id)
	if not visibleTo(m, player) then
		return false, "This video isn't available."
	end
	local c = clipCache[id]
	if not c then
		local ok, value = kvGet("clip_" .. id)
		if not ok then
			return false, "CityTok is busy. Try again."
		end
		if type(value) ~= "table" or type(value.clip) ~= "table" then
			return false, "This video isn't available."
		end
		c = { data = value, at = os.clock() }
		clipCache[id] = c
		-- keep the cache small
		local count, oldestId, oldestAt = 0, nil, math.huge
		for cid, entry in clipCache do
			count += 1
			if entry.at < oldestAt then
				oldestId, oldestAt = cid, entry.at
			end
		end
		if count > 40 and oldestId then
			clipCache[oldestId] = nil
		end
	end
	c.at = os.clock()
	local o = opened[player]
	if not o then
		o = {}
		opened[player] = o
	end
	o[id] = os.clock()
	return true, nil, { post = summary(m :: Meta, player), clip = c.data.clip, edit = c.data.edit }
end

handlers.View = function(player, id)
	if type(id) ~= "string" or not Net.allow(player, "TokView", 0.5) then
		return false
	end
	local o = opened[player]
	local at = o and o[id]
	if not at or os.clock() - at < Cfg.MIN_WATCH_FOR_VIEW then
		return false
	end
	local v = viewed[player]
	if not v then
		v = {}
		viewed[player] = v
	end
	if v[id] then
		return true
	end
	v[id] = true
	local m = getMeta(id)
	if not m or m.by == player.UserId then
		return true
	end
	local uid = key(player.UserId)
	if type(m.views) == "table" and m.views[uid] then
		return true
	end
	queue(id).views[uid] = true
	local change = emptyDelta()
	change.views[uid] = true
	applyLocal(id, change)
	return true
end

handlers.Like = function(player, payload)
	if type(payload) ~= "table" or type(payload.id) ~= "string" or type(payload.on) ~= "boolean" then
		return false, "Invalid."
	end
	if not Net.allow(player, "TokLike", 0.4) then
		return false, "Slow down."
	end
	local m = getMeta(payload.id)
	if not visibleTo(m, player) then
		return false, "This video isn't available."
	end
	if (m :: Meta).by == player.UserId then
		return false, "You can't like your own video."
	end
	local uid = key(player.UserId)
	queue(payload.id).like[uid] = payload.on
	local change = emptyDelta()
	change.like[uid] = payload.on
	applyLocal(payload.id, change)
	local cached = metaCache[payload.id]
	local likes = if cached and cached.meta then cached.meta.nl else (m :: Meta).nl
	return true, nil, { likes = likes or 0 }
end

handlers.Comments = function(player, id)
	if type(id) ~= "string" or not Net.allow(player, "TokComments", 0.4) then
		return false, "Slow down."
	end
	local m = getMeta(id, 15)
	if not visibleTo(m, player) then
		return false, "This video isn't available."
	end
	local out = {}
	for _, c in (m :: Meta).com or {} do
		if not socialBlocked(player, c.u) and not socialMuted(player, c.u) then
			table.insert(out, { u = c.u, n = c.n, x = c.x, t = c.t })
		end
	end
	return true, nil, out
end

handlers.Comment = function(player, payload)
	if type(payload) ~= "table" or type(payload.id) ~= "string" then
		return false, "Invalid."
	end
	local text = cleanText(payload.text, Cfg.COMMENT_MAX)
	if not text then
		return false, "Comments are 1-" .. Cfg.COMMENT_MAX .. " characters."
	end
	if not Net.allow(player, "TokComment", 5) then
		return false, "Wait a few seconds between comments."
	end
	local m = getMeta(payload.id)
	if not visibleTo(m, player) then
		return false, "This video isn't available."
	end
	if not canUseText(player) then
		return false, "Your account settings don't allow comments."
	end
	local filtered = filterPublic(player, text)
	if not filtered then
		return false, "Your comment couldn't be checked right now. Try again."
	end
	local c = { u = player.UserId, n = player.DisplayName, x = filtered, t = os.time() }
	table.insert(queue(payload.id).comments, c)
	local change = emptyDelta()
	table.insert(change.comments, c)
	applyLocal(payload.id, change)
	local creator = Players:GetPlayerByUserId((m :: Meta).by)
	if creator and creator ~= player and not socialBlocked(creator, player.UserId) then
		Net.notify(creator, "CityTok", player.DisplayName .. " commented on your video.")
	end
	return true, nil, c
end

handlers.Share = function(player, payload)
	if type(payload) ~= "table" or type(payload.id) ~= "string" or type(payload.to) ~= "number" then
		return false, "Invalid."
	end
	local Messages, Social = lazy("Messages"), lazy("Social")
	if not Messages or not Social then
		return false, "Sharing isn't available."
	end
	local target = Players:GetPlayerByUserId(payload.to)
	if not target or target == player then
		return false, "They're not in this server."
	end
	if not Net.allow(player, "TokShare", 3) then
		return false, "Slow down."
	end
	local okSocial, reason = Social.allows(player, target, "message")
	if not okSocial then
		return false, reason or "You can't message this player."
	end
	local m = getMeta(payload.id)
	if not visibleTo(m, player) or socialBlocked(target, (m :: Meta).by) then
		return false, "This video isn't available to them."
	end
	local tsec = section(target)
	if not tsec then
		return false, target.DisplayName .. " is still loading in."
	end
	for i, item in tsec.inbox do
		if item.i == payload.id then
			table.remove(tsec.inbox, i)
			break
		end
	end
	table.insert(tsec.inbox, 1, { i = payload.id, f = player.DisplayName, t = os.time() })
	while #tsec.inbox > Cfg.MAX_INBOX do
		table.remove(tsec.inbox)
	end
	PlayerData.markChanged(target)
	pcall(Messages.sendSystem, target, "CityTok", player.DisplayName .. " shared a CityTok video with you. Open CityTok > Library > Inbox to watch it.")
	Net.notify(target, "CityTok", player.DisplayName .. " shared a video with you.")
	EventRemote:FireClient(target, "Inbox")
	if (m :: Meta).by ~= player.UserId then
		local uid = key(player.UserId)
		queue(payload.id).shares[uid] = true
		local change = emptyDelta()
		change.shares[uid] = true
		applyLocal(payload.id, change)
	end
	return true, "Shared with " .. target.DisplayName .. "."
end

handlers.Fav = function(player, payload)
	if type(payload) ~= "table" or type(payload.id) ~= "string" or type(payload.on) ~= "boolean" then
		return false, "Invalid."
	end
	local sec = section(player)
	if not sec or not Net.allow(player, "TokFav", 0.3) then
		return false, "Try again in a moment."
	end
	local i = table.find(sec.favs, payload.id)
	if payload.on and not i then
		if not visibleTo(getMeta(payload.id), player) then
			return false, "This video isn't available."
		end
		table.insert(sec.favs, 1, payload.id)
		while #sec.favs > Cfg.MAX_FAVS do
			table.remove(sec.favs)
		end
	elseif not payload.on and i then
		table.remove(sec.favs, i)
	end
	PlayerData.markChanged(player)
	return true, if payload.on then "Saved to favourites." else "Removed from favourites."
end

handlers.Follow = function(player, payload)
	local CG = cityGram()
	if not CG then
		return false, "Following isn't available."
	end
	if type(payload) ~= "table" or type(payload.to) ~= "number" or type(payload.on) ~= "boolean" then
		return false, "Invalid."
	end
	local target = payload.to
	if target == player.UserId or not Net.allow(player, "TokFollow", 1) then
		return false, "Invalid."
	end
	local fn = if payload.on then CG.follow else CG.unfollow
	if type(fn) ~= "function" then
		return false, "Following isn't available."
	end
	local ok, result, message = pcall(fn, player, target)
	if not ok or result ~= true then
		return false, if ok and type(message) == "string" then message else "Couldn't change that right now."
	end
	return true, if type(message) == "string" then message else nil, { following = isFollowing(player.UserId, target) }
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function CityTok.start(cityModel: Instance)
	city = cityModel
	RequestRemote = Net.remote("RemoteFunction", "CityTokRequest")
	EventRemote = Net.remote("RemoteEvent", "CityTokEvent")

	RequestRemote.OnServerInvoke = function(player: Player, action: any, payload: any)
		if type(action) ~= "string" then
			return false, "Invalid request."
		end
		local handler = handlers[action]
		if not handler or not Net.allow(player, "TokReq" .. action, 0.1) then
			return false, "Invalid request."
		end
		local ok, success, message, data = pcall(handler, player, payload)
		if not ok then
			warn("[CityTok] " .. action .. " failed:", success)
			return false, "Something went wrong. Try again."
		end
		return success, message, data
	end

	hookCallouts()
	connectBasketball()

	-- Decide storage mode once (unpublished Studio has no DataStore access).
	task.spawn(function()
		local ok = PostsDS ~= nil and pcall(function()
			(PostsDS :: DataStore):GetAsync("probe")
		end)
		mode = if ok then "ds" else "memory"
		if mode == "ds" then
			pcall(function()
				MessagingService:SubscribeAsync(TOPIC, function(message)
					local data = message.Data
					if type(data) ~= "table" or data.s == game.JobId then
						return
					end
					if data.op == "new" and type(data.e) == "table" and type(data.e.id) == "string" then
						addRecentLocal(data.e)
					elseif data.op == "stat" and type(data.id) == "string" then
						local c = metaCache[data.id]
						if c then
							c.at = -math.huge
						end
					elseif data.op == "del" and type(data.id) == "string" then
						metaCache[data.id] = { meta = nil, at = os.clock() }
						clipCache[data.id] = nil
						removeRecentLocal(data.id)
					elseif data.op == "award" and type(data.by) == "number" and type(data.id) == "string" then
						local creator = Players:GetPlayerByUserId(data.by)
						if creator then
							grantAwards(creator, data.id)
						end
					end
				end)
			end)
		end
	end)

	-- Recorder + highlight freezer + driving checks
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 1 / Cfg.HZ then
			return
		end
		accumulator = math.min(accumulator - 1 / Cfg.HZ, 1 / Cfg.HZ)
		local now = os.clock()
		sampleFrame(now)
		checkDriving(now)
		for player, p in pendingHL do
			if not player.Parent then
				pendingHL[player] = nil
			elseif now >= p.last + Cfg.POST_SECONDS then
				pendingHL[player] = nil
				task.spawn(finalize, player, p)
			end
		end
	end)

	-- Engagement flush
	task.spawn(function()
		while true do
			task.wait(15)
			local ok, err = pcall(flush)
			if not ok then
				warn("[CityTok] flush failed:", err)
			end
		end
	end)

	local function onPlayerAdded(player: Player)
		task.spawn(loadClips, player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	PlayerData.onLoaded(function(player)
		task.delay(5, function()
			if player.Parent then
				checkOwnAwards(player)
			end
		end)
	end)
	Players.PlayerRemoving:Connect(function(player)
		pendingHL[player] = nil
		tagCooldown[player] = nil
		driveStates[player] = nil
		opened[player] = nil
		viewed[player] = nil
		local userId = player.UserId
		task.spawn(function()
			saveClips(userId)
			-- with real DataStores the copy in memory is no longer needed
			local s = clipStores[userId]
			if mode == "ds" and s and s.canSave and not s.dirty and not Players:GetPlayerByUserId(userId) then
				clipStores[userId] = nil
			end
		end)
	end)
	game:BindToClose(function()
		pcall(flush)
		for userId in clipStores do
			saveClips(userId)
		end
	end)
end

return CityTok
