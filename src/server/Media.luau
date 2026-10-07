-- CITY GRIND: photos (sections 30-33, 59). Server side of the Camera and Gallery apps.
--
-- A photo is a SceneSnapshot (see ReplicatedStorage.CityGrind.SceneSnapshot). The
-- client only tells us where its camera was, the zoom, the filter, who it saw and how
-- their bodies were posed; the server checks all of it against its own world (camera
-- near the photographer, people in this server and in front of the lens, poses within
-- a few studs of what the server sees) and encodes the people / vehicles itself, so a
-- saved photo can never contain made-up geometry.
--
-- Storage: photo records in DataStore "CityGrind_Photos_v1":
--   photo_<id> = { o = ownerUserId, vis = "private" | "public", t, s = snapshot }   (<= ~30 KB)
--   pub_<userId> = { profile = photoId | "", public = { photoId } }               (for offline profile lookups)
-- Saved section "media": { profilePhoto = "", photos = { { id, t, l, fl, vis, n } } newest first, taken = 0 }
-- Without DataStore access (unpublished Studio) everything lives in memory for the session.
--
-- Remotes: MediaAction (RemoteFunction) (action, a, b) -> (ok, message, data)
--            "capture" request | "list" | "get" id | "delete" id | "visibility" id vis | "profile" id
--            "groupPose" emoteId | "poseRespond" fromUserId accept | "clips"
--          MediaEvent (RemoteEvent, server -> client): "PoseRequest" (fromUserId, fromName, emoteId)
-- Player attributes: ProfilePhoto (string photo id, "" if none), PhotoCount (number)
-- Public API: Media.profilePhoto(userId) -> string?, Media.getPhoto(photoId) -> record?,
--             Media.ownsPhoto(player, photoId) -> boolean, Media.publicPhotos(userId) -> { string }

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local MediaConfig = require(shared:WaitForChild("MediaConfig"))
local SceneSnapshot = require(shared:WaitForChild("SceneSnapshot"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local Media = {}

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
PlayerData.registerSection("media", function()
	return {
		profilePhoto = "",
		photos = {}, -- { id, t, l, fl, vis, n } newest first
		taken = 0,
	}
end)

local function sec(player: Player): any
	return PlayerData.section(player, "media")
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local photoStore: DataStore? = nil
pcall(function()
	photoStore = DataStoreService:GetDataStore("CityGrind_Photos_v1")
end)

local cache: { [string]: any } = {} -- photo id -> record
local cacheOrder: { string } = {}
local pubCache: { [number]: { data: any, at: number } } = {}

local function remember(id: string, record: any)
	if not cache[id] then
		table.insert(cacheOrder, id)
	end
	cache[id] = record
	-- without a DataStore the cache IS the storage, so never evict then
	while photoStore and #cacheOrder > 300 do
		cache[table.remove(cacheOrder, 1) :: string] = nil
	end
end

local function retry<T>(fn: () -> T): (boolean, T?)
	for attempt = 1, 3 do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		task.wait(attempt)
	end
	return false, nil
end

local function validId(id: any): boolean
	return type(id) == "string" and #id >= 8 and #id <= 32 and id:match("^%w+$") ~= nil
end

local function newId(): string
	return (HttpService:GenerateGUID(false):gsub("%-", "")):sub(1, 16):lower()
end

-- Photo record by id (memory first, then DataStore). May yield.
function Media.getPhoto(photoId: string): any
	if not validId(photoId) then
		return nil
	end
	local hit = cache[photoId]
	if hit then
		return hit
	end
	if not photoStore then
		return nil
	end
	local ok, record = retry(function()
		return (photoStore :: DataStore):GetAsync("photo_" .. photoId)
	end)
	if ok and type(record) == "table" and type(record.o) == "number" and type(record.s) == "table" then
		remember(photoId, record)
		return record
	end
	return nil
end

function Media.ownsPhoto(player: Player, photoId: string): boolean
	local s = sec(player)
	if not s or not validId(photoId) then
		return false
	end
	for _, meta in s.photos do
		if meta.id == photoId then
			return true
		end
	end
	return false
end

-- Writes pub_<userId> (profile picture + public photo ids) so other servers can read it.
local function publishPublic(player: Player)
	local s = sec(player)
	if not s then
		return
	end
	local public = {}
	for _, meta in s.photos do
		if meta.vis == "public" and #public < 12 then
			table.insert(public, meta.id)
		end
	end
	local data = { profile = s.profilePhoto, public = public }
	pubCache[player.UserId] = { data = data, at = os.clock() }
	player:SetAttribute("ProfilePhoto", s.profilePhoto)
	player:SetAttribute("PhotoCount", #s.photos)
	if photoStore then
		task.spawn(retry, function()
			(photoStore :: DataStore):SetAsync("pub_" .. player.UserId, data)
		end)
	end
end

local function pubData(userId: number): any
	local online = Players:GetPlayerByUserId(userId)
	if online and sec(online) then
		local s = sec(online)
		local public = {}
		for _, meta in s.photos do
			if meta.vis == "public" and #public < 12 then
				table.insert(public, meta.id)
			end
		end
		return { profile = s.profilePhoto, public = public }
	end
	local c = pubCache[userId]
	if c and os.clock() - c.at < 60 then
		return c.data
	end
	if not photoStore then
		return nil
	end
	local ok, data = retry(function()
		return (photoStore :: DataStore):GetAsync("pub_" .. userId)
	end)
	if ok then
		data = if type(data) == "table" then data else { profile = "", public = {} }
		pubCache[userId] = { data = data, at = os.clock() }
		return data
	end
	return nil
end

-- The photo id a player chose as their profile picture (nil if none). May yield.
function Media.profilePhoto(userId: number): string?
	if type(userId) ~= "number" then
		return nil
	end
	local data = pubData(userId)
	local id = data and data.profile
	return if validId(id) then id else nil
end

-- Up to 12 photo ids the player marked Public. May yield.
function Media.publicPhotos(userId: number): { string }
	local data = type(userId) == "number" and pubData(userId)
	local out = {}
	if data and type(data.public) == "table" then
		for _, id in data.public do
			if validId(id) then
				table.insert(out, id)
			end
		end
	end
	return out
end

-- Can `viewer` see this photo record (owner, public, or someone's profile picture)?
local function canView(viewer: Player, photoId: string, record: any): boolean
	if record.o == viewer.UserId or record.vis == "public" then
		return true
	end
	return Media.profilePhoto(record.o) == photoId
end

---------------------------------------------------------------------------
-- Optional neighbours
---------------------------------------------------------------------------
local function optional(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

local function blocked(a: Player, b: Player): boolean
	local Social = optional("Social")
	if Social and Social.isBlocked then
		local ok, result = pcall(Social.isBlocked, a, b)
		return ok and result == true
	end
	return false
end

---------------------------------------------------------------------------
-- Capture: validate the client's request and build the snapshot ourselves
---------------------------------------------------------------------------
local function toOverrides(k: any): { [string]: CFrame }
	local out = {}
	if type(k) ~= "table" then
		return out
	end
	local count = 0
	for key, arr in k do
		count += 1
		if count > 80 then
			break
		end
		if type(key) == "string" and #key <= 80 and SceneSnapshot.validCf(arr, 60) then
			out[key] = SceneSnapshot.arrToCf(arr)
		end
	end
	return out
end

local function buildSnapshot(player: Player, req: any): (any, string?)
	if type(req) ~= "table" or not SceneSnapshot.validCf(req.c, 100000) then
		return nil, "Bad photo."
	end
	local fov = req.f
	if type(fov) ~= "number" or fov ~= fov or fov < MediaConfig.FOV_MIN or fov > MediaConfig.FOV_MAX then
		return nil, "Bad zoom."
	end
	if not MediaConfig.isFilter(req.fl) then
		return nil, "Unknown filter."
	end
	local camCF = SceneSnapshot.arrToCf(req.c)
	local camPos, look = camCF.Position, camCF.LookVector
	if not Net.alive(player) or Net.distance(player, camPos) > MediaConfig.CAMERA_RANGE then
		return nil, "Your camera has to be near you."
	end
	local minDot = math.cos(math.min(math.rad(fov) * 0.95, math.rad(85)))

	local people = {}
	local seen = {}
	if type(req.p) == "table" then
		for i = 1, math.min(#req.p, MediaConfig.MAX_PEOPLE) do
			local e = req.p[i]
			local uid = type(e) == "table" and e.u
			local other = type(uid) == "number" and Players:GetPlayerByUserId(uid)
			if not other or seen[other] then
				continue
			end
			local character = other.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not character or not root or not root:IsA("BasePart") then
				continue
			end
			local offset = root.Position - camPos
			if offset.Magnitude > MediaConfig.SUBJECT_RANGE or (offset.Magnitude > 3 and offset.Unit:Dot(look) < minDot) then
				continue -- not actually in frame from where the camera is
			end
			if other ~= player and blocked(player, other) then
				continue
			end
			seen[other] = true
			local rootCF = root.CFrame
			if SceneSnapshot.validCf(e.r, 100000) then
				local reported = SceneSnapshot.arrToCf(e.r)
				if (reported.Position - rootCF.Position).Magnitude <= MediaConfig.ROOT_TOLERANCE then
					rootCF = reported
				end
			end
			table.insert(people, SceneSnapshot.encodePerson(other, character, rootCF, toOverrides(e.k), MediaConfig.POSE_TOLERANCE))
		end
	end

	local vehicles = {}
	local folder = SceneSnapshot.vehicleFolder()
	if type(req.h) == "table" and folder then
		local used = {}
		for i = 1, math.min(#req.h, MediaConfig.MAX_VEHICLES) do
			local e = req.h[i]
			local model = type(e) == "table" and e.m
			if typeof(model) ~= "Instance" or not model:IsA("Model") or not model:IsDescendantOf(folder) or used[model] then
				continue
			end
			used[model] = true
			local pivot = model:GetPivot()
			if (pivot.Position - camPos).Magnitude > MediaConfig.SUBJECT_RANGE then
				continue
			end
			if SceneSnapshot.validCf(e.r, 100000) then
				local reported = SceneSnapshot.arrToCf(e.r)
				if (reported.Position - pivot.Position).Magnitude <= 10 then
					pivot = reported
				end
			end
			table.insert(vehicles, SceneSnapshot.encodeVehicle(model, pivot))
		end
	end

	local interior = player:GetAttribute("Interior")
	local snap = {
		v = 1,
		c = SceneSnapshot.cfToArr(camCF, true),
		f = math.floor(fov * 100 + 0.5) / 100,
		k = math.floor(Lighting.ClockTime * 100 + 0.5) / 100,
		fl = req.fl,
		l = if type(interior) == "string" and interior ~= "" then interior:sub(1, 40) else SceneSnapshot.nearestPlace(camPos),
		t = os.time(),
		p = people,
		h = vehicles,
	}
	SceneSnapshot.shrink(snap)
	return SceneSnapshot.sanitize(snap)
end

local function capture(player: Player, req: any): (boolean, string?, any)
	if not Net.allow(player, "MediaCapture", MediaConfig.CAPTURE_COOLDOWN) then
		return false, "Hold on, the shutter is still resetting.", nil
	end
	local s = sec(player)
	if not s then
		return false, "Your phone is still loading.", nil
	end
	if #s.photos >= MediaConfig.MAX_PHOTOS then
		return false, string.format("Gallery full (%d photos). Delete some first.", MediaConfig.MAX_PHOTOS), nil
	end
	local snap, reason = buildSnapshot(player, req)
	if not snap then
		return false, reason or "Couldn't take that photo.", nil
	end
	local id = newId()
	local record = { o = player.UserId, vis = "private", t = os.time(), s = snap }
	if photoStore then
		local ok = retry(function()
			(photoStore :: DataStore):SetAsync("photo_" .. id, record, { player.UserId })
		end)
		if not ok then
			return false, "Couldn't save the photo. Try again in a moment.", nil
		end
	end
	remember(id, record)
	s = sec(player)
	if not s then
		return false, "Your phone is still loading.", nil
	end
	local meta = { id = id, t = record.t, l = snap.l, fl = snap.fl, vis = "private", n = #snap.p }
	table.insert(s.photos, 1, meta)
	s.taken += 1
	PlayerData.markChanged(player)
	player:SetAttribute("PhotoCount", #s.photos)
	return true, "Saved to your Gallery.", { meta = table.clone(meta), snap = snap }
end

---------------------------------------------------------------------------
-- Gallery actions
---------------------------------------------------------------------------
local function findMeta(s: any, id: any): (number?, any)
	for i, meta in s.photos do
		if meta.id == id then
			return i, meta
		end
	end
	return nil, nil
end

local function deletePhoto(player: Player, id: any): (boolean, string?)
	local s = sec(player)
	local index = s and findMeta(s, id)
	if not s or not index then
		return false, "That photo isn't in your Gallery."
	end
	table.remove(s.photos, index)
	if s.profilePhoto == id then
		s.profilePhoto = ""
	end
	PlayerData.markChanged(player)
	cache[id] = nil
	if photoStore then
		task.spawn(retry, function()
			(photoStore :: DataStore):RemoveAsync("photo_" .. id)
		end)
	end
	publishPublic(player)
	return true, "Photo deleted."
end

local function setVisibility(player: Player, id: any, vis: any): (boolean, string?)
	if vis ~= "private" and vis ~= "public" then
		return false, "Pick Private or Public."
	end
	local s = sec(player)
	if not s then
		return false, "Your phone is still loading."
	end
	local _, meta = findMeta(s, id)
	if not meta then
		return false, "That photo isn't in your Gallery."
	end
	if meta.vis == vis then
		return true, nil
	end
	meta.vis = vis
	PlayerData.markChanged(player)
	local record = cache[id]
	if record then
		record.vis = vis
	end
	if photoStore then
		task.spawn(retry, function()
			(photoStore :: DataStore):UpdateAsync("photo_" .. id, function(old)
				if type(old) ~= "table" or old.o ~= player.UserId then
					return nil
				end
				old.vis = vis
				return old
			end)
		end)
	end
	publishPublic(player)
	return true, if vis == "public" then "Photo is now Public: it shows on your profile." else "Photo is now Private."
end

local function setProfile(player: Player, id: any): (boolean, string?)
	local s = sec(player)
	if not s then
		return false, "Your phone is still loading."
	end
	if id == "" then
		s.profilePhoto = ""
	else
		local _, meta = findMeta(s, id)
		if not meta then
			return false, "That photo isn't in your Gallery."
		end
		s.profilePhoto = id
	end
	PlayerData.markChanged(player)
	publishPublic(player)
	return true, if id == "" then "Profile picture removed." else "Profile picture updated. Everyone can see it on your profile."
end

---------------------------------------------------------------------------
-- Group pose (party members within 30 studs get a pose request)
---------------------------------------------------------------------------
local poseRequests: { [Player]: { from: number, emote: string, expires: number } } = {}
local MediaEvent: RemoteEvent

local function playEmote(player: Player, emoteId: string): (boolean, string?)
	local Emotes = optional("Emotes")
	if Emotes and Emotes.play then
		local ok, result, reason = pcall(Emotes.play, player, emoteId)
		if ok then
			return result == true, reason
		end
	end
	return false, "Poses aren't available right now."
end

local function groupPose(player: Player, emoteId: any): (boolean, string?)
	if type(emoteId) ~= "string" or not table.find(MediaConfig.POSES, emoteId) then
		return false, "Pick a pose first."
	end
	if not Net.allow(player, "MediaGroupPose", 6) then
		return false, "You just asked. Give them a second."
	end
	local Party = optional("Party")
	local party = Party and Party.partyOf and Party.partyOf(player)
	if not party then
		return false, "Join a party to call a group pose."
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false, "You need to be in the city."
	end
	local sent = 0
	for _, member in party.members do
		if member ~= player and member.Parent and Net.distance(member, root.Position) <= MediaConfig.GROUP_POSE_RANGE and not blocked(player, member) then
			poseRequests[member] = { from = player.UserId, emote = emoteId, expires = os.clock() + MediaConfig.POSE_REQUEST_SECONDS }
			MediaEvent:FireClient(member, "PoseRequest", player.UserId, player.DisplayName, emoteId)
			sent += 1
		end
	end
	if sent == 0 then
		return false, string.format("No party members within %d studs.", MediaConfig.GROUP_POSE_RANGE)
	end
	playEmote(player, emoteId)
	return true, string.format("Pose request sent to %d party member%s.", sent, if sent == 1 then "" else "s")
end

local function poseRespond(player: Player, fromUserId: any, accept: any): (boolean, string?)
	local req = poseRequests[player]
	if not req or req.from ~= fromUserId or os.clock() > req.expires then
		poseRequests[player] = nil
		return false, "That pose request expired."
	end
	poseRequests[player] = nil
	if accept ~= true then
		return true, nil
	end
	return playEmote(player, req.emote)
end

---------------------------------------------------------------------------
-- CityTok highlight clips (only if that module exists and exposes listClips)
---------------------------------------------------------------------------
local function listClips(player: Player): any
	local CityTok = optional("CityTok")
	if not CityTok or type(CityTok.listClips) ~= "function" then
		return nil
	end
	local ok, clips = pcall(CityTok.listClips, player)
	if not ok or type(clips) ~= "table" then
		return nil
	end
	local out = {}
	for i = 1, math.min(#clips, 30) do
		local c = clips[i]
		if type(c) == "table" then
			table.insert(out, {
				id = tostring(c.id or i),
				title = tostring(c.title or c.name or c.label or "Highlight"):sub(1, 60),
				t = tonumber(c.at or c.t or c.time) or 0,
			})
		end
	end
	return out
end

---------------------------------------------------------------------------
-- Remote
---------------------------------------------------------------------------
local function handle(player: Player, action: any, a: any, b: any): (boolean, string?, any)
	if action == "capture" then
		return capture(player, a)
	end
	if not Net.allow(player, "MediaAction", 0.12) then
		return false, "Slow down.", nil
	end
	local s = sec(player)
	if action == "list" then
		if not s then
			return false, "Your phone is still loading.", nil
		end
		local photos = {}
		for i, meta in s.photos do
			photos[i] = table.clone(meta)
		end
		return true, nil, { photos = photos, profile = s.profilePhoto, max = MediaConfig.MAX_PHOTOS }
	elseif action == "get" then
		if not validId(a) then
			return false, "Unknown photo.", nil
		end
		local record = Media.getPhoto(a)
		if not record then
			return false, "That photo is gone.", nil
		end
		if not canView(player, a, record) then
			return false, "That photo is private.", nil
		end
		return true, nil, { id = a, o = record.o, vis = record.vis, snap = record.s }
	elseif action == "delete" then
		return deletePhoto(player, a)
	elseif action == "visibility" then
		return setVisibility(player, a, b)
	elseif action == "profile" then
		return setProfile(player, a)
	elseif action == "groupPose" then
		return groupPose(player, a)
	elseif action == "poseRespond" then
		return poseRespond(player, a, b)
	elseif action == "clips" then
		return true, nil, listClips(player)
	end
	return false, "Unknown action.", nil
end

function Media.start(_city: Instance?)
	local MediaAction = Net.remote("RemoteFunction", "MediaAction")
	MediaEvent = Net.remote("RemoteEvent", "MediaEvent")
	MediaAction.OnServerInvoke = function(player: Player, action: any, a: any, b: any)
		local ok, success, message, data = pcall(handle, player, action, a, b)
		if not ok then
			warn("[CityGrind] Media action failed:", success)
			return false, "Something went wrong.", nil
		end
		return success, message, data
	end

	-- Studio without API access: GetDataStore works but every request fails, so keep
	-- photos in memory for this session instead of failing every capture.
	if photoStore and game:GetService("RunService"):IsStudio() then
		task.spawn(function()
			local ok = pcall(function()
				(photoStore :: DataStore):GetAsync("probe")
			end)
			if not ok then
				photoStore = nil
			end
		end)
	end

	PlayerData.onLoaded(function(player: Player)
		local s = sec(player)
		if s then
			player:SetAttribute("ProfilePhoto", s.profilePhoto)
			player:SetAttribute("PhotoCount", #s.photos)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		poseRequests[player] = nil
	end)
end

return Media
