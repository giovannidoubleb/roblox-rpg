-- CITY GRIND: social core (spec 21, 28, 29, 44, 45, 46, 47, 96, 97, 101).
-- In-game friends (requests persist offline through a DataStore inbox and reach
-- other servers live through MessagingService), privacy, block / mute, player
-- status, profiles and customization, two-person emotes and the overhead nametag.
-- Everything is decided here; clients only ask.
--
-- Saved section "Social" (string userId keys so DataStores accept them):
--   friends[uid]  = { n = displayName, u = username, t = since, lv = lastSeenLevel }
--   incoming[uid] / outgoing[uid] = { n, u, t }      pending friend requests
--   blocked[uid] / muted[uid]     = { n, u }
--   privacy = { message/invite/call/visit/follow/interact = "Everyone"|"Friends"|"Crew"|"Nobody",
--               profile = "Public"|"Friends Only"|"Private", showStatus = bool, shareLocation = bool }
--   status = SocialConfig.STATUSES id
--   profile = { banner = index, title = id, favorite = name, featured = id, bio = raw text (re-filtered on display) }
--
-- Player attribute: SocialStatus (string) - the status everyone may see ("" when hidden / none).
-- DataStore CityGrind_Social_v1, key "inbox_<userId>" = { [fromUserId] = { k = "request"|"accept"|"remove", n, u, t } }

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local SC = require(shared:WaitForChild("SocialConfig"))

local Social = {}

local SECTION = "Social"
local GYM_INTERIOR = "Gym"
do
	local gc = shared:FindFirstChild("GymConfig")
	if gc then
		local ok, cfg = pcall(require, gc)
		if ok and type(cfg) == "table" and type(cfg.INTERIOR) == "string" then
			GYM_INTERIOR = cfg.INTERIOR
		end
	end
end

local function cloneDefaults()
	return table.clone(SC.DEFAULT_PRIVACY)
end

PlayerData.registerSection(SECTION, function()
	return {
		friends = {},
		incoming = {},
		outgoing = {},
		blocked = {},
		muted = {},
		privacy = cloneDefaults(),
		status = "Auto",
		profile = { banner = 1, title = "Newcomer", favorite = "None", featured = "Level", bio = "" },
	}
end)

local SocialAction: RemoteFunction
local SocialProfile: RemoteFunction
local SocialEvent: RemoteEvent
local SocialEmote: RemoteEvent

local store: DataStore? = nil
local messagingOk = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function sec(player: Player): any
	return PlayerData.section(player, SECTION)
end

local function key(userId: number): string
	return tostring(userId)
end

local function count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function validId(id: any): boolean
	return type(id) == "number" and id == id and id % 1 == 0 and id > 0 and id < 1e15
end

local function record(player: Player)
	return { n = player.DisplayName, u = player.Name, t = os.time() }
end

local function retry(attempts: number, fn: () -> any): (boolean, any)
	local ok, result
	for attempt = 1, attempts do
		ok, result = pcall(fn)
		if ok then
			return true, result
		end
		if attempt < attempts then
			task.wait(attempt)
		end
	end
	return false, result
end

-- Lazily required sibling modules (they may not exist yet, and may require us).
local function sibling(name: string): any
	local m = script.Parent:FindFirstChild(name)
	if not m then
		return nil
	end
	local ok, mod = pcall(require, m)
	return if ok then mod else nil
end

local function crewOf(player: Player): any
	local Crews = sibling("Crews")
	if not Crews or type(Crews.crewOf) ~= "function" then
		return nil
	end
	local ok, crew = pcall(Crews.crewOf, player)
	return if ok and type(crew) == "table" then crew else nil
end

local function sameCrew(a: Player, b: Player): boolean
	local ca, cb = crewOf(a), crewOf(b)
	return ca ~= nil and cb ~= nil and ca.id == cb.id
end

-- Roblox (platform) friendship between two players in this server, cached.
local robloxFriends: { [string]: boolean } = {}
local function pairKey(a: number, b: number): string
	return if a < b then a .. ":" .. b else b .. ":" .. a
end
local function checkRobloxFriends(a: Player, b: Player)
	local k = pairKey(a.UserId, b.UserId)
	if robloxFriends[k] ~= nil then
		return
	end
	local ok, result = pcall(function()
		local anyA = a :: any
		if anyA.IsFriendsWithAsync then
			return anyA:IsFriendsWithAsync(b.UserId)
		end
		return anyA:IsFriendsWith(b.UserId)
	end)
	robloxFriends[k] = ok and result == true
end
local function isRobloxFriend(a: Player, b: Player): boolean
	return robloxFriends[pairKey(a.UserId, b.UserId)] == true
end

---------------------------------------------------------------------------
-- State push (the owner's own lists, for their phone and menus)
---------------------------------------------------------------------------
local pushQueued: { [Player]: boolean } = {}
local buildState: (Player) -> any

local function queuePush(player: Player)
	if pushQueued[player] then
		return
	end
	pushQueued[player] = true
	task.defer(function()
		pushQueued[player] = nil
		if player.Parent and sec(player) then
			SocialEvent:FireClient(player, "State", buildState(player))
		end
	end)
end

local function changed(player: Player)
	PlayerData.markChanged(player)
	queuePush(player)
end

---------------------------------------------------------------------------
-- Status (spec 47)
---------------------------------------------------------------------------
local function activityOf(player: Player): string
	if player:GetAttribute("InGame") then
		return "Playing Basketball"
	end
	local CourtGames = sibling("CourtGames")
	if CourtGames and CourtGames.gameOf then
		local ok, court = pcall(CourtGames.gameOf, player)
		if ok and court then
			return "Playing Basketball"
		end
	end
	local driving = player:GetAttribute("Driving")
	if type(driving) == "string" and driving ~= "" then
		return "Driving"
	end
	local training = player:GetAttribute("Training")
	if (type(training) == "string" and training ~= "") or player:GetAttribute("Interior") == GYM_INTERIOR then
		return "At Gym"
	end
	local job = player:GetAttribute("Job")
	if type(job) == "string" and job ~= "" then
		return "Working"
	end
	return ""
end

-- The player's own status label, ignoring privacy ("" = none).
local function statusLabel(player: Player): string
	local s = sec(player)
	if not s then
		return ""
	end
	if s.status == "Auto" then
		return activityOf(player)
	elseif s.status == "None" then
		return ""
	end
	return s.status
end

-- What another player may see as this player's status in a friends list.
local function visibleStatus(player: Player): string
	local s = sec(player)
	if not s or not s.privacy.showStatus then
		return "Online"
	end
	local label = statusLabel(player)
	return if label == "" then "Online" else label
end

---------------------------------------------------------------------------
-- Public checks used by other modules
---------------------------------------------------------------------------
function Social.isBlockedId(player: Player, otherUserId: number): boolean
	local s = sec(player)
	if s and s.blocked[key(otherUserId)] then
		return true
	end
	local other = Players:GetPlayerByUserId(otherUserId)
	local os_ = other and sec(other)
	return os_ ~= nil and os_.blocked[key(player.UserId)] ~= nil
end

function Social.isBlocked(a: Player, b: Player): boolean
	return Social.isBlockedId(a, b.UserId)
end

-- True when `viewer` muted (or blocked) the user.
function Social.isMutedBy(viewer: Player, otherUserId: number): boolean
	local s = sec(viewer)
	return s ~= nil and (s.muted[key(otherUserId)] ~= nil or s.blocked[key(otherUserId)] ~= nil)
end

function Social.areFriends(a: Player, b: Player): boolean
	local sa, sb = sec(a), sec(b)
	if not sa and not sb then
		return false
	end
	return (not sa or sa.friends[key(b.UserId)] ~= nil) and (not sb or sb.friends[key(a.UserId)] ~= nil)
end

function Social.friendIds(player: Player): { number }
	local s = sec(player)
	local ids = {}
	if s then
		for uid in s.friends do
			local n = tonumber(uid)
			if n then
				table.insert(ids, n)
			end
		end
	end
	return ids
end

local VALID_KINDS = { message = true, invite = true, call = true, visit = true, follow = true, interact = true }

-- Can `from` do `kind` to `to`? Uses the receiver's privacy, blocks and Do Not Disturb.
function Social.allows(from: Player, to: Player, kind: string): (boolean, string?)
	if from == to then
		return true, nil
	end
	if Social.isBlocked(from, to) then
		return false, "You can't interact with this player."
	end
	local s = sec(to)
	if not s then
		return false, to.DisplayName .. " is still loading in."
	end
	if not VALID_KINDS[kind] then
		return false, "That isn't allowed."
	end
	if (kind == "invite" or kind == "call") and s.status == "Do Not Disturb" then
		return false, to.DisplayName .. " has Do Not Disturb on."
	end
	local setting = s.privacy[kind] or "Everyone"
	if setting == "Everyone" then
		return true, nil
	elseif setting == "Friends" then
		if Social.areFriends(from, to) then
			return true, nil
		end
		return false, to.DisplayName .. " only allows that from friends."
	elseif setting == "Crew" then
		if sameCrew(from, to) then
			return true, nil
		end
		return false, to.DisplayName .. " only allows that from their crew."
	end
	return false, to.DisplayName .. " isn't accepting that right now."
end

-- Same check when the sender is offline or on another server (used by Messages).
function Social.allowsFromId(fromUserId: number, to: Player, kind: string): (boolean, string?)
	local fromPlayer = Players:GetPlayerByUserId(fromUserId)
	if fromPlayer then
		return Social.allows(fromPlayer, to, kind)
	end
	local s = sec(to)
	if not s then
		return false, to.DisplayName .. " is still loading in."
	end
	if s.blocked[key(fromUserId)] or not VALID_KINDS[kind] then
		return false, "You can't interact with this player."
	end
	if (kind == "invite" or kind == "call") and s.status == "Do Not Disturb" then
		return false, to.DisplayName .. " has Do Not Disturb on."
	end
	local setting = s.privacy[kind] or "Everyone"
	if setting == "Everyone" then
		return true, nil
	elseif setting == "Friends" and s.friends[key(fromUserId)] then
		return true, nil
	end
	return false, to.DisplayName .. " isn't accepting that right now."
end

-- Phone notification to every online friend in this server (who has them as a friend too).
function Social.notifyFriends(player: Player, title: string, body: string)
	for _, other in Players:GetPlayers() do
		if other ~= player and Social.areFriends(player, other) then
			Net.notify(other, title, body)
		end
	end
end

-- The status label other players see (respects "show my status").
function Social.statusOf(player: Player): string
	local s = sec(player)
	if not s or not s.privacy.showStatus then
		return ""
	end
	return statusLabel(player)
end

---------------------------------------------------------------------------
-- Offline inbox (DataStore) + cross-server delivery (MessagingService)
---------------------------------------------------------------------------
local applyInbox: (Player, { [string]: any }) -> ()

local function publish(toUserId: number)
	if not messagingOk then
		return
	end
	task.spawn(function()
		pcall(function()
			MessagingService:PublishAsync(SC.TOPIC, { to = toUserId })
		end)
	end)
end

-- Records a friend action for a player who isn't in this server. Returns false
-- when DataStores are unavailable (Studio without API access).
local function inboxWrite(toUserId: number, from: { userId: number, n: string, u: string }, kind: string): boolean
	if not store then
		return false
	end
	local ok = retry(3, function()
		return (store :: DataStore):UpdateAsync("inbox_" .. toUserId, function(old)
			old = if type(old) == "table" then old else {}
			old[key(from.userId)] = { k = kind, n = from.n, u = from.u, t = os.time() }
			-- keep the inbox small: drop the oldest entries past the cap
			while count(old) > 250 do
				local oldestKey, oldestT = nil, math.huge
				for k, v in old do
					local t = type(v) == "table" and v.t or 0
					if t < oldestT then
						oldestKey, oldestT = k, t
					end
				end
				if oldestKey == nil then
					break
				end
				old[oldestKey] = nil
			end
			return old
		end)
	end)
	if ok then
		publish(toUserId)
	end
	return ok
end

local draining: { [Player]: boolean } = {}
local function drainInbox(player: Player)
	if not store or draining[player] or not sec(player) then
		return
	end
	draining[player] = true
	local captured = nil
	local ok = retry(3, function()
		return (store :: DataStore):UpdateAsync("inbox_" .. player.UserId, function(old)
			if type(old) ~= "table" or next(old) == nil then
				captured = nil
				return nil -- nothing to do, no write
			end
			captured = old
			return {}
		end)
	end)
	draining[player] = nil
	if ok and captured and player.Parent and sec(player) then
		applyInbox(player, captured)
	end
end

-- A friend action addressed to `targetId` from `from`: applied directly when the
-- target is in this server, otherwise written to their inbox.
local function deliver(from: Player, targetId: number, kind: string): boolean
	local target = Players:GetPlayerByUserId(targetId)
	if target and sec(target) then
		applyInbox(target, { [key(from.UserId)] = { k = kind, n = from.DisplayName, u = from.Name, t = os.time() } })
		return true
	end
	return inboxWrite(targetId, { userId = from.UserId, n = from.DisplayName, u = from.Name }, kind)
end

applyInbox = function(player: Player, entries: { [string]: any })
	local s = sec(player)
	if not s then
		return
	end
	local me = { userId = player.UserId, n = player.DisplayName, u = player.Name }
	for fromKey, e in entries do
		local fromId = tonumber(fromKey)
		if not fromId or type(e) ~= "table" or type(e.k) ~= "string" then
			continue
		end
		local rec = { n = tostring(e.n or "Player"), u = tostring(e.u or ""), t = os.time() }
		if e.k == "remove" then
			if s.friends[fromKey] then
				Net.notify(player, "FRIENDS", rec.n .. " is no longer on your friends list.")
			end
			s.friends[fromKey] = nil
			s.incoming[fromKey] = nil
			s.outgoing[fromKey] = nil
		elseif e.k == "request" then
			if s.blocked[fromKey] then
				continue
			elseif s.friends[fromKey] or s.outgoing[fromKey] then
				-- they asked while we already were / wanted to be friends: make it mutual
				if count(s.friends) < SC.MAX_FRIENDS or s.friends[fromKey] then
					s.friends[fromKey] = s.friends[fromKey] or rec
					s.outgoing[fromKey] = nil
					Net.notify(player, "NEW FRIEND", "You and " .. rec.n .. " are now friends.")
					local fromPlayer = Players:GetPlayerByUserId(fromId)
					if fromPlayer then
						deliver(player, fromId, "accept")
					else
						task.spawn(inboxWrite, fromId, me, "accept")
					end
				end
			elseif count(s.incoming) < SC.MAX_INCOMING then
				s.incoming[fromKey] = rec
				Net.notify(player, "FRIEND REQUEST", rec.n .. " wants to be friends. Open Friends on your phone.")
			end
		elseif e.k == "accept" then
			if s.outgoing[fromKey] or s.friends[fromKey] then
				local isNew = s.friends[fromKey] == nil
				s.outgoing[fromKey] = nil
				s.incoming[fromKey] = nil
				if isNew and count(s.friends) >= SC.MAX_FRIENDS then
					task.spawn(inboxWrite, fromId, me, "remove")
				else
					s.friends[fromKey] = s.friends[fromKey] or rec
					if isNew then
						Net.notify(player, "NEW FRIEND", rec.n .. " accepted your friend request.")
					end
				end
			else
				-- we cancelled before their accept arrived: undo it on their side
				local fromPlayer = Players:GetPlayerByUserId(fromId)
				if fromPlayer and sec(fromPlayer) then
					local fs = sec(fromPlayer)
					fs.friends[key(player.UserId)] = nil
					changed(fromPlayer)
				else
					task.spawn(inboxWrite, fromId, me, "remove")
				end
			end
		end
	end
	changed(player)
end

---------------------------------------------------------------------------
-- Friend actions (spec 46)
---------------------------------------------------------------------------
local requestTimes: { [Player]: { number } } = {}
local function requestAllowed(player: Player): boolean
	local now = os.clock()
	local list = requestTimes[player] or {}
	requestTimes[player] = list
	while list[1] and now - list[1] > 60 do
		table.remove(list, 1)
	end
	if #list >= SC.REQUESTS_PER_MINUTE then
		return false
	end
	table.insert(list, now)
	return true
end

local acceptRequest: (Player, number) -> (boolean, string?)

local function sendRequest(player: Player, targetId: number, nameHint: string?): (boolean, string?)
	local s = sec(player)
	if not s then
		return false, "Your data is still loading."
	end
	if targetId == player.UserId then
		return false, "You can't add yourself."
	end
	local k = key(targetId)
	if s.friends[k] then
		return false, "You're already friends."
	end
	if s.blocked[k] then
		return false, "Unblock them first."
	end
	if s.incoming[k] then
		return acceptRequest(player, targetId)
	end
	if s.outgoing[k] then
		return false, "Request already sent."
	end
	if count(s.friends) >= SC.MAX_FRIENDS then
		return false, "Your friends list is full (" .. SC.MAX_FRIENDS .. ")."
	end
	if not requestAllowed(player) then
		return false, "Slow down - you can send " .. SC.REQUESTS_PER_MINUTE .. " requests a minute."
	end

	local target = Players:GetPlayerByUserId(targetId)
	if target then
		local ts = sec(target)
		if not ts then
			return false, target.DisplayName .. " is still loading in."
		end
		local allowed, reason = Social.allows(player, target, "interact")
		if not allowed then
			return false, reason
		end
		if ts.friends[key(player.UserId)] then
			-- they still have us (e.g. we removed them while they were away): restore both sides
			s.friends[k] = record(target)
			changed(player)
			return true, "You and " .. target.DisplayName .. " are friends again."
		end
		if count(ts.friends) >= SC.MAX_FRIENDS then
			return false, target.DisplayName .. "'s friends list is full."
		end
		if count(ts.incoming) >= SC.MAX_INCOMING then
			return false, target.DisplayName .. " has too many pending requests."
		end
		s.outgoing[k] = record(target)
		changed(player)
		deliver(player, targetId, "request")
		return true, "Friend request sent to " .. target.DisplayName .. "."
	end

	-- Not in this server: goes into their saved inbox.
	local name = nameHint
	if not name then
		local ok, result = pcall(function()
			return Players:GetNameFromUserIdAsync(targetId)
		end)
		if not ok then
			return false, "Couldn't find that player."
		end
		name = result
	end
	if not inboxWrite(targetId, { userId = player.UserId, n = player.DisplayName, u = player.Name }, "request") then
		return false, "They need to be in this server to get your request right now."
	end
	s.outgoing[k] = { n = name, u = name, t = os.time() }
	changed(player)
	return true, "Friend request sent to " .. tostring(name) .. ". They'll see it next time they play."
end

acceptRequest = function(player: Player, fromId: number): (boolean, string?)
	local s = sec(player)
	local k = key(fromId)
	if not s or not s.incoming[k] then
		return false, "That request is gone."
	end
	if count(s.friends) >= SC.MAX_FRIENDS then
		return false, "Your friends list is full (" .. SC.MAX_FRIENDS .. ")."
	end
	local rec = s.incoming[k]
	s.incoming[k] = nil
	local from = Players:GetPlayerByUserId(fromId)
	s.friends[k] = if from then record(from) else { n = rec.n, u = rec.u, t = os.time() }
	changed(player)
	if not deliver(player, fromId, "accept") then
		-- no DataStore and they left: they'll miss the accept, so keep it consistent
		s.friends[k] = nil
		changed(player)
		return false, "They left the server - ask them again next time."
	end
	return true, "You and " .. tostring(s.friends[k].n) .. " are now friends."
end

local function dropRelation(player: Player, otherId: number, field: string): (boolean, string?)
	local s = sec(player)
	local k = key(otherId)
	if not s or not s[field][k] then
		return false, "Nothing to remove."
	end
	local name = s[field][k].n
	s[field][k] = nil
	changed(player)
	deliver(player, otherId, "remove")
	return true, if field == "friends" then tostring(name) .. " removed from friends." else "Request removed."
end

---------------------------------------------------------------------------
-- Block / mute (spec 45, 101)
---------------------------------------------------------------------------
local pendingEmotes: { [Player]: { [Player]: { kind: string, t: number } } } = {}

local function block(player: Player, otherId: number): (boolean, string?)
	local s = sec(player)
	if not s or otherId == player.UserId then
		return false, "You can't block that player."
	end
	local k = key(otherId)
	if s.blocked[k] then
		return true, "Already blocked."
	end
	if count(s.blocked) >= SC.MAX_BLOCKED then
		return false, "Your block list is full."
	end
	local other = Players:GetPlayerByUserId(otherId)
	local rec = if other then record(other) else (s.friends[k] or s.incoming[k] or s.outgoing[k] or s.muted[k])
	if not rec then
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(otherId)
		end)
		rec = { n = if ok then name else "Player", u = if ok then name else "" }
	end
	local hadRelation = s.friends[k] or s.incoming[k] or s.outgoing[k]
	s.blocked[k] = { n = rec.n, u = rec.u }
	s.friends[k] = nil
	s.incoming[k] = nil
	s.outgoing[k] = nil
	changed(player)
	if hadRelation then
		deliver(player, otherId, "remove")
	end
	if other then
		if pendingEmotes[other] then
			pendingEmotes[other][player] = nil
		end
		if pendingEmotes[player] then
			pendingEmotes[player][other] = nil
		end
		queuePush(other) -- so their client hides our nametag too
	end
	return true, tostring(rec.n) .. " is blocked. You won't see each other's messages, invites or interactions."
end

local function unblock(player: Player, otherId: number): (boolean, string?)
	local s = sec(player)
	local k = key(otherId)
	if not s or not s.blocked[k] then
		return false, "They aren't blocked."
	end
	local name = s.blocked[k].n
	s.blocked[k] = nil
	changed(player)
	local other = Players:GetPlayerByUserId(otherId)
	if other then
		queuePush(other)
	end
	return true, tostring(name) .. " is unblocked."
end

local function setMuted(player: Player, otherId: number, muted: boolean): (boolean, string?)
	local s = sec(player)
	if not s or otherId == player.UserId then
		return false, "You can't mute that player."
	end
	local k = key(otherId)
	if muted then
		if count(s.muted) >= SC.MAX_BLOCKED then
			return false, "Your mute list is full."
		end
		local other = Players:GetPlayerByUserId(otherId)
		local rec = if other then record(other) else (s.friends[k] or s.blocked[k] or { n = "Player", u = "" })
		s.muted[k] = { n = rec.n, u = rec.u }
	else
		s.muted[k] = nil
	end
	changed(player)
	return true, if muted then "Muted. Their messages are hidden from you and their voice is muted for you where supported." else "Unmuted."
end

-- Voice: with Roblox's audio API each player has an AudioDeviceInput. Its Deny
-- list keeps their voice from the players who muted or blocked them.
local function refreshVoice(speaker: Player)
	local input = speaker:FindFirstChildWhichIsA("AudioDeviceInput", true)
	if not input then
		return
	end
	pcall(function()
		local adi = input :: AudioDeviceInput
		if adi.AccessType ~= Enum.AccessModifierType.Deny then
			return -- another system (calls) controls this input
		end
		local deny = {}
		for _, listener in Players:GetPlayers() do
			if listener ~= speaker and (Social.isMutedBy(listener, speaker.UserId) or Social.isBlocked(listener, speaker)) then
				table.insert(deny, listener.UserId)
			end
		end
		local current = adi:GetUserIdAccessList()
		local same = #current == #deny
		if same then
			for i, id in deny do
				if current[i] ~= id then
					same = false
					break
				end
			end
		end
		if not same then
			adi:SetUserIdAccessList(deny)
		end
	end)
end

---------------------------------------------------------------------------
-- Profiles (spec 28, 29, 97)
---------------------------------------------------------------------------
local filteredBios: { [number]: { raw: string, text: string } } = {}

-- Bio text as everyone may see it (filtered for broadcast; "" if filtering fails).
local function publicBio(owner: Player): string
	local s = sec(owner)
	local raw = s and s.profile.bio or ""
	if raw == "" then
		return ""
	end
	local cached = filteredBios[owner.UserId]
	if cached and cached.raw == raw then
		return cached.text
	end
	local ok, text = pcall(function()
		local result = TextService:FilterStringAsync(raw, owner.UserId, Enum.TextFilterContext.PublicChat)
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		return ""
	end
	filteredBios[owner.UserId] = { raw = raw, text = text }
	return text
end

local function titlesFor(player: Player): { string }
	local data = PlayerData.get(player)
	if not data then
		return { "Newcomer" }
	end
	return SC.unlockedTitles(data.level, data.reputation, data.basketball.wins, data.basketball.points)
end

local function featuredValue(player: Player, id: string): string
	local data = PlayerData.get(player)
	if not data then
		return "-"
	end
	local bb = data.basketball
	local values = {
		Level = data.level,
		Reputation = data.reputation,
		Fame = data.fame,
		Wins = bb.wins,
		Points = bb.points,
		Threes = bb.threes,
		Dunks = bb.dunks,
	}
	local v = values[id] or data.stats[id]
	return if v ~= nil then tostring(v) else "-"
end

local function relationOf(viewer: Player, targetId: number): string
	local s = sec(viewer)
	if not s then
		return "none"
	end
	local k = key(targetId)
	if s.friends[k] then
		return "friends"
	elseif s.incoming[k] then
		return "incoming"
	elseif s.outgoing[k] then
		return "outgoing"
	end
	return "none"
end

local function profileSnapshot(viewer: Player, targetId: number): any
	local vs = sec(viewer)
	local target = Players:GetPlayerByUserId(targetId)
	local k = key(targetId)
	local base = {
		userId = targetId,
		self = targetId == viewer.UserId,
		relation = relationOf(viewer, targetId),
		blocked = vs ~= nil and vs.blocked[k] ~= nil,
		muted = vs ~= nil and vs.muted[k] ~= nil,
	}
	if not target then
		local rec = vs and (vs.friends[k] or vs.incoming[k] or vs.outgoing[k] or vs.blocked[k])
		if rec then
			base.name = rec.n
			base.username = rec.u
			base.level = rec.lv
		else
			local ok, name = pcall(function()
				return Players:GetNameFromUserIdAsync(targetId)
			end)
			if not ok then
				return nil
			end
			base.name = name
			base.username = name
		end
		base.online = false
		base.note = "Not in this city right now."
		return base
	end

	local ts = sec(target)
	local data = PlayerData.get(target)
	base.name = target.DisplayName
	base.username = target.Name
	base.online = true
	base.level = target:GetAttribute("Level") or 1
	base.robloxFriend = target ~= viewer and isRobloxFriend(viewer, target)
	if not ts or not data then
		base.limited = true
		base.note = "Still loading in."
		return base
	end
	if Social.isBlocked(viewer, target) and target ~= viewer then
		base.limited = true
		base.note = "You can't view this profile."
		return base
	end
	local vis = ts.privacy.profile
	local friends = Social.areFriends(viewer, target)
	if target ~= viewer and (vis == "Private" or (vis == "Friends Only" and not friends)) then
		base.limited = true
		base.note = if vis == "Private" then "This profile is private." else "Only friends can see this profile."
		return base
	end
	local crew = crewOf(target)
	local featured = SC.FEATURED_BY_ID[ts.profile.featured] or SC.FEATURED[1]
	base.rank = data and Config.reputationRank(data.reputation) or "Nobody"
	base.reputation = data.reputation
	base.fame = data.fame
	base.basketball = {
		wins = data.basketball.wins,
		losses = data.basketball.losses,
		points = data.basketball.points,
		threes = data.basketball.threes,
		dunks = data.basketball.dunks,
	}
	base.crew = if crew then { name = tostring(crew.name), tag = tostring(crew.tag), color = crew.color, role = tostring(crew.role or "") } else nil
	base.homeTier = target:GetAttribute("HomeTier") or "Starter Apartment"
	base.favorite = ts.profile.favorite
	base.title = ts.profile.title
	base.banner = ts.profile.banner
	base.featured = { label = featured.label, value = featuredValue(target, featured.id) }
	base.status = Social.statusOf(target)
	base.friendCount = count(ts.friends)
	base.bio = publicBio(target)
	return base
end

---------------------------------------------------------------------------
-- State for the owner
---------------------------------------------------------------------------
local function list(dict: { [string]: any }): { any }
	local out = {}
	for uid, rec in dict do
		local id = tonumber(uid)
		if id then
			table.insert(out, { userId = id, name = rec.n, username = rec.u, t = rec.t })
		end
	end
	table.sort(out, function(a, b)
		return (a.t or 0) > (b.t or 0)
	end)
	return out
end

buildState = function(player: Player)
	local s = sec(player)
	local friends = {}
	for uid, rec in s.friends do
		local id = tonumber(uid)
		if not id then
			continue
		end
		local other = Players:GetPlayerByUserId(id)
		local entry = { userId = id, name = rec.n, username = rec.u, since = rec.t, level = rec.lv, online = false, status = "Not in this server" }
		if other and sec(other) then
			rec.n, rec.u = other.DisplayName, other.Name
			rec.lv = other:GetAttribute("Level") or rec.lv
			entry.name, entry.level = rec.n, rec.lv
			entry.online = true
			entry.status = visibleStatus(other)
			entry.canLocate = sec(other).privacy.shareLocation == true and Social.areFriends(player, other)
			entry.robloxFriend = isRobloxFriend(player, other)
		end
		table.insert(friends, entry)
	end
	table.sort(friends, function(a, b)
		if a.online ~= b.online then
			return a.online
		end
		return tostring(a.name):lower() < tostring(b.name):lower()
	end)
	-- Roblox friends here, and players here who blocked us (ids only, to hide them).
	local robloxHere, hiddenIds = {}, {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			if isRobloxFriend(player, other) then
				table.insert(robloxHere, other.UserId)
			end
			local os_ = sec(other)
			if os_ and os_.blocked[key(player.UserId)] then
				table.insert(hiddenIds, other.UserId)
			end
		end
	end
	return {
		friends = friends,
		incoming = list(s.incoming),
		outgoing = list(s.outgoing),
		blocked = list(s.blocked),
		muted = list(s.muted),
		privacy = table.clone(s.privacy),
		status = s.status,
		profile = table.clone(s.profile),
		titles = titlesFor(player),
		robloxHere = robloxHere,
		hiddenIds = hiddenIds,
		maxFriends = SC.MAX_FRIENDS,
		crossServer = store ~= nil,
	}
end

---------------------------------------------------------------------------
-- Overhead nametag (server-built so everyone sees it)
---------------------------------------------------------------------------
local tagCache: { [Player]: string } = {}

local function hex(c: Color3): string
	return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function escape(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

local function buildTag(player: Player, character: Model)
	local head = character:WaitForChild("Head", 10)
	if not head or not head:IsA("BasePart") or character.Parent == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	local old = head:FindFirstChild("CityGrindTag")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "CityGrindTag"
	gui.Size = UDim2.fromOffset(240, 66)
	gui.StudsOffset = Vector3.new(0, 2.7, 0)
	gui.MaxDistance = 90
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.PlayerToHideFrom = player -- you don't need your own name over your head
	gui.Adornee = head

	local function line(name: string, y: number, h: number, size: number, font: Enum.Font, color: Color3)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.Position = UDim2.fromOffset(0, y)
		l.Size = UDim2.new(1, 0, 0, h)
		l.Font = font
		l.TextSize = size
		l.TextColor3 = color
		l.TextStrokeTransparency = 0.35
		l.RichText = true
		l.Text = ""
		l.Parent = gui
		return l
	end
	line("StatusLine", 0, 16, 13, Enum.Font.GothamMedium, Color3.fromRGB(230, 230, 240))
	line("NameLine", 16, 24, 20, Enum.Font.GothamBlack, Color3.new(1, 1, 1))
	line("InfoLine", 40, 18, 14, Enum.Font.GothamBold, Color3.fromRGB(200, 200, 210))
	gui.Parent = head
	tagCache[player] = nil
end

local function refreshTag(player: Player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local gui = head and head:FindFirstChild("CityGrindTag")
	if not gui then
		return
	end
	local crew = crewOf(player)
	local rank = tostring(player:GetAttribute("Rank") or "Nobody")
	local rankColor = SC.RANK_COLORS[rank] or Color3.new(1, 1, 1)
	local status = Social.statusOf(player)
	local s = sec(player)
	local title = s and s.profile.title or ""
	local nameText = escape(player.DisplayName)
	if crew and crew.tag and crew.tag ~= "" then
		local c = if typeof(crew.color) == "Color3" then crew.color else Color3.new(1, 1, 1)
		nameText = string.format('<font color="%s">[%s]</font> %s', hex(c), escape(tostring(crew.tag)), nameText)
	end
	local info = string.format('LV %d  ·  <font color="%s">%s</font>', tonumber(player:GetAttribute("Level")) or 1, hex(rankColor), escape(rank))
	if title ~= "" and title ~= rank then
		info ..= "  ·  " .. escape(title)
	end
	local statusText = if status ~= "" then ((SC.STATUS_ICONS[status] or "") .. " " .. escape(status)) else ""
	local signature = nameText .. "|" .. info .. "|" .. statusText
	if tagCache[player] == signature then
		return
	end
	tagCache[player] = signature
	local nameLine = gui:FindFirstChild("NameLine") :: TextLabel?
	local infoLine = gui:FindFirstChild("InfoLine") :: TextLabel?
	local statusLine = gui:FindFirstChild("StatusLine") :: TextLabel?
	if nameLine and infoLine and statusLine then
		nameLine.Text = nameText
		infoLine.Text = info
		statusLine.Text = statusText
	end
end

---------------------------------------------------------------------------
-- Emotes (spec 21, 96): wave, plus two-person emotes the other must accept
---------------------------------------------------------------------------
local armBusy: { [Motor6D]: boolean } = {}

local function shoulderOf(character: Model): (Motor6D?, boolean)
	local upper = character:FindFirstChild("RightUpperArm")
	local m = upper and upper:FindFirstChild("RightShoulder")
	if m and m:IsA("Motor6D") then
		return m, true
	end
	local torso = character:FindFirstChild("Torso")
	m = torso and torso:FindFirstChild("Right Shoulder")
	if m and m:IsA("Motor6D") then
		return m, false
	end
	return nil, false
end

-- Used only when no server Emotes module exists: raises the right arm on the
-- server (Motor6D C0) so everyone sees it.
local ARM_POSES = { Wave = 165, HighFive = 160, FistBump = 85, Handshake = 70 }
local function fallbackArm(player: Player, kind: string)
	local character = player.Character
	if not character then
		return
	end
	local motor, r15 = shoulderOf(character)
	if not motor or armBusy[motor] then
		return
	end
	armBusy[motor] = true
	local original = motor.C0
	local function pose(deg: number): CFrame
		local a = math.rad(deg)
		return original * (if r15 then CFrame.Angles(a, 0, 0) else CFrame.Angles(0, 0, a))
	end
	local info = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local target = ARM_POSES[kind] or 90
	TweenService:Create(motor, info, { C0 = pose(target) }):Play()
	task.spawn(function()
		task.wait(0.25)
		if kind == "Wave" or kind == "Handshake" then
			local swing = if kind == "Wave" then 20 else 15
			for i = 1, 4 do
				if not motor.Parent then
					break
				end
				TweenService:Create(motor, TweenInfo.new(0.16), { C0 = pose(target + (if i % 2 == 1 then -swing else 0)) }):Play()
				task.wait(0.17)
			end
		else
			task.wait(0.7)
		end
		if motor.Parent then
			local back = TweenService:Create(motor, info, { C0 = original })
			back:Play()
			back.Completed:Wait()
		end
		armBusy[motor] = nil
	end)
end

-- Server Emotes (if present) does the real animation; otherwise the arm fallback.
local function playEmote(players: { Player }, kind: string): (boolean, string?)
	local Emotes = sibling("Emotes")
	if Emotes then
		local ok, played, reason
		if #players == 2 and type(Emotes.playPaired) == "function" then
			ok, played, reason = pcall(Emotes.playPaired, players[1], players[2], kind)
		elseif #players == 1 and type(Emotes.play) == "function" then
			ok, played, reason = pcall(Emotes.play, players[1], kind)
		end
		if ok then
			return played == true, reason
		end
	end
	for _, p in players do
		fallbackArm(p, kind)
	end
	return true, nil
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function seated(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.SeatPart ~= nil
end

local function closeEnough(a: Player, b: Player, range: number): boolean
	local ra, rb = rootOf(a), rootOf(b)
	return ra ~= nil and rb ~= nil and (ra.Position - rb.Position).Magnitude <= range
end

local function faceEachOther(a: Player, b: Player)
	local ra, rb = rootOf(a), rootOf(b)
	if not ra or not rb then
		return
	end
	for _, pair in { { a, ra, rb }, { b, rb, ra } } do
		local p, me, other = pair[1], pair[2], pair[3]
		if not seated(p) then
			local look = Vector3.new(other.Position.X, me.Position.Y, other.Position.Z)
			if (look - me.Position).Magnitude > 0.5 then
				me.CFrame = CFrame.lookAt(me.Position, look)
			end
		end
	end
end

local function onEmote(player: Player, action: any, arg1: any, arg2: any)
	if type(action) ~= "string" then
		return
	end
	if action == "solo" then
		local kind = arg1
		if type(kind) ~= "string" or not SC.EMOTES[kind] or not SC.EMOTES[kind].solo then
			return
		end
		if not Net.allow(player, "SocialSolo", 2) or not Net.alive(player) then
			return
		end
		local played, why = playEmote({ player }, kind)
		if not played and why then
			Net.notify(player, "EMOTE", why)
		end
	elseif action == "request" then
		local target = validId(arg1) and Players:GetPlayerByUserId(arg1)
		local kind = arg2
		if not target or target == player or type(kind) ~= "string" or not SC.EMOTES[kind] or SC.EMOTES[kind].solo then
			return
		end
		if not Net.allow(player, "SocialEmoteReq", 3) then
			Net.notify(player, "SLOW DOWN", "Wait a moment before asking again.")
			return
		end
		local allowed, reason = Social.allows(player, target, "interact")
		if not allowed then
			Net.notify(player, "CAN'T DO THAT", reason or "Not allowed.")
			return
		end
		if not Net.alive(player) or not Net.alive(target) or not closeEnough(player, target, SC.EMOTE_RANGE) then
			Net.notify(player, "GET CLOSER", "Stand next to " .. target.DisplayName .. " first.")
			return
		end
		pendingEmotes[target] = pendingEmotes[target] or {}
		pendingEmotes[target][player] = { kind = kind, t = os.clock() }
		SocialEvent:FireClient(target, "EmoteRequest", player.UserId, kind, player.DisplayName)
		Net.notify(player, SC.EMOTES[kind].label, "Waiting for " .. target.DisplayName .. " to accept...")
	elseif action == "respond" then
		local from = validId(arg1) and Players:GetPlayerByUserId(arg1)
		local accept = arg2 == true
		local pending = from and pendingEmotes[player] and pendingEmotes[player][from]
		if not from or not pending then
			return
		end
		pendingEmotes[player][from] = nil
		local label = SC.EMOTES[pending.kind].label
		if not accept then
			Net.notify(from, label, player.DisplayName .. " passed this time.")
			return
		end
		if os.clock() - pending.t > SC.EMOTE_REQUEST_SECONDS then
			Net.notify(player, label, "That request expired.")
			return
		end
		if Social.isBlocked(player, from) or not Net.alive(player) or not Net.alive(from) then
			return
		end
		if not closeEnough(player, from, SC.EMOTE_RANGE) then
			Net.notify(player, "GET CLOSER", "You moved too far from " .. from.DisplayName .. ".")
			Net.notify(from, "GET CLOSER", "You moved too far from " .. player.DisplayName .. ".")
			return
		end
		if not sibling("Emotes") then
			faceEachOther(player, from)
		end
		local played, why = playEmote({ from, player }, pending.kind)
		if not played then
			Net.notify(player, label, why or "Couldn't do that right now.")
			Net.notify(from, label, why or "Couldn't do that right now.")
		end
	end
end

---------------------------------------------------------------------------
-- Remote: SocialAction(action, ...) -> (ok, message, extra?)
---------------------------------------------------------------------------
local function setPrivacy(player: Player, k: any, value: any): (boolean, string?)
	local s = sec(player)
	if not s or type(k) ~= "string" then
		return false, "Not loaded."
	end
	if VALID_KINDS[k] then
		if not table.find(SC.PRIVACY_VALUES, value) then
			return false, "Invalid setting."
		end
	elseif k == "profile" then
		if not table.find(SC.PROFILE_VISIBILITY, value) then
			return false, "Invalid setting."
		end
	elseif k == "showStatus" or k == "shareLocation" then
		if type(value) ~= "boolean" then
			return false, "Invalid setting."
		end
	else
		return false, "Invalid setting."
	end
	s.privacy[k] = value
	changed(player)
	return true, nil
end

local function cleanBio(text: string): string
	text = text:gsub("[%c]", " "):gsub("%s+", " ")
	text = text:match("^%s*(.-)%s*$") or ""
	return text
end

local function setProfileField(player: Player, field: string, value: any): (boolean, string?)
	local s = sec(player)
	if not s then
		return false, "Not loaded."
	end
	if field == "banner" then
		if type(value) ~= "number" or value % 1 ~= 0 or not SC.BANNERS[value] then
			return false, "Invalid colour."
		end
	elseif field == "title" then
		if type(value) ~= "string" or not table.find(titlesFor(player), value) then
			return false, "You haven't unlocked that title yet."
		end
	elseif field == "favorite" then
		if not table.find(SC.FAVORITES, value) then
			return false, "Invalid activity."
		end
	elseif field == "featured" then
		if type(value) ~= "string" or not SC.FEATURED_BY_ID[value] then
			return false, "Invalid stat."
		end
	elseif field == "bio" then
		if type(value) ~= "string" then
			return false, "Invalid bio."
		end
		value = cleanBio(value)
		local len = utf8.len(value)
		if not len or len > SC.BIO_MAX then
			return false, "Bios are up to " .. SC.BIO_MAX .. " characters."
		end
		if value ~= "" then
			local ok, filtered = pcall(function()
				local result = TextService:FilterStringAsync(value, player.UserId, Enum.TextFilterContext.PublicChat)
				return result:GetNonChatStringForBroadcastAsync()
			end)
			if not ok then
				return false, "Couldn't check that bio right now. Try again soon."
			end
			filteredBios[player.UserId] = { raw = value, text = filtered }
		end
	else
		return false, "Invalid field."
	end
	s.profile[field] = value
	changed(player)
	tagCache[player] = nil
	return true, nil
end

local ACTIONS: { [string]: (Player, any, any) -> (boolean, string?, any) } = {}

ACTIONS.request = function(player, id)
	return sendRequest(player, id, nil)
end
ACTIONS.accept = function(player, id)
	return acceptRequest(player, id)
end
ACTIONS.decline = function(player, id)
	return dropRelation(player, id, "incoming")
end
ACTIONS.cancel = function(player, id)
	return dropRelation(player, id, "outgoing")
end
ACTIONS.remove = function(player, id)
	return dropRelation(player, id, "friends")
end
ACTIONS.block = block
ACTIONS.unblock = unblock
ACTIONS.mute = function(player, id)
	return setMuted(player, id, true)
end
ACTIONS.unmute = function(player, id)
	return setMuted(player, id, false)
end

-- Where a friend in this server is, if they share their location with friends.
ACTIONS.locate = function(player, id)
	local other = Players:GetPlayerByUserId(id)
	local os_ = other and sec(other)
	if not other or not os_ then
		return false, "They aren't in this server."
	end
	if not Social.areFriends(player, other) or Social.isBlocked(player, other) then
		return false, "Only friends can find each other."
	end
	if not os_.privacy.shareLocation then
		return false, other.DisplayName .. " doesn't share their location."
	end
	local root = rootOf(other)
	if not root then
		return false, other.DisplayName .. " is respawning."
	end
	if (other:GetAttribute("Interior") or "") ~= "" then
		return false, other.DisplayName .. " is inside somewhere. Try again when they're outside."
	end
	return true, nil, { name = other.DisplayName, position = root.Position }
end

-- What the interaction menu needs about a target.
ACTIONS.query = function(player, id)
	local other = Players:GetPlayerByUserId(id)
	if not other or other == player then
		return false, "They left."
	end
	local s = sec(player)
	local allowed, reason = Social.allows(player, other, "interact")
	return true, nil, {
		relation = relationOf(player, id),
		robloxFriend = isRobloxFriend(player, other),
		blocked = s ~= nil and s.blocked[key(id)] ~= nil,
		muted = s ~= nil and s.muted[key(id)] ~= nil,
		canInteract = allowed,
		reason = reason,
		level = other:GetAttribute("Level") or 1,
		status = Social.statusOf(other),
	}
end

local STRING_ACTIONS: { [string]: (Player, any, any) -> (boolean, string?, any) } = {
	privacy = setPrivacy,
	status = function(player, choice)
		local s = sec(player)
		if not s then
			return false, "Not loaded."
		end
		for _, st in SC.STATUSES do
			if st.id == choice then
				s.status = choice
				changed(player)
				return true, nil
			end
		end
		return false, "Invalid status."
	end,
	profile = function(player, field, value)
		if type(field) ~= "string" then
			return false, "Invalid field."
		end
		return setProfileField(player, field, value)
	end,
	addByName = function(player, username)
		if type(username) ~= "string" or #username < 3 or #username > 20 or not username:match("^[%w_]+$") then
			return false, "Enter a Roblox username (letters, numbers, _)."
		end
		if not Net.allow(player, "SocialLookup", 3) then
			return false, "Wait a moment before searching again."
		end
		local ok, userId = pcall(function()
			return Players:GetUserIdFromNameAsync(username)
		end)
		if not ok or not validId(userId) then
			return false, "No player called " .. username .. "."
		end
		return sendRequest(player, userId, username)
	end,
}

local function onAction(player: Player, action: any, a: any, b: any)
	if type(action) ~= "string" or not Net.allow(player, "SocialAction", 0.2) then
		return false, "Slow down."
	end
	if not sec(player) then
		return false, "Your data is still loading."
	end
	local id_fn = ACTIONS[action]
	if id_fn then
		if not validId(a) then
			return false, "Invalid player."
		end
		return id_fn(player, a, b)
	end
	local fn = STRING_ACTIONS[action]
	if fn then
		return fn(player, a, b)
	end
	if action == "state" then
		return true, nil, buildState(player)
	end
	return false, "Unknown action."
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
local function onCharacter(player: Player, character: Model)
	task.spawn(function()
		buildTag(player, character)
		refreshTag(player)
	end)
end

local function onPlayerAdded(player: Player)
	player:SetAttribute("SocialStatus", "")
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		onCharacter(player, player.Character)
	end
	-- Roblox friendships with everyone already here
	task.spawn(function()
		for _, other in Players:GetPlayers() do
			if other ~= player and player.Parent then
				checkRobloxFriends(player, other)
				queuePush(other)
			end
		end
		queuePush(player)
	end)
end

local function onLoaded(player: Player)
	drainInbox(player)
	local s = sec(player)
	if not s or not player.Parent then
		return
	end
	-- a title that is no longer unlocked (shouldn't happen) falls back
	if not table.find(titlesFor(player), s.profile.title) then
		s.profile.title = "Newcomer"
	end
	queuePush(player)
	for _, other in Players:GetPlayers() do
		if other ~= player and sec(other) and Social.areFriends(player, other) then
			if s.privacy.showStatus then
				Net.notify(other, "FRIEND ONLINE", player.DisplayName .. " is in the city.")
			end
			queuePush(other)
		end
	end
end

local function onPlayerRemoving(player: Player)
	for _, other in Players:GetPlayers() do
		if other ~= player then
			robloxFriends[pairKey(player.UserId, other.UserId)] = nil
			if pendingEmotes[other] then
				pendingEmotes[other][player] = nil
			end
			local os_ = sec(other)
			if os_ and os_.friends[key(player.UserId)] then
				queuePush(other)
			end
		end
	end
	pendingEmotes[player] = nil
	requestTimes[player] = nil
	tagCache[player] = nil
	draining[player] = nil
	pushQueued[player] = nil
end

function Social.start(_city: Instance)
	SocialAction = Net.remote("RemoteFunction", "SocialAction")
	SocialProfile = Net.remote("RemoteFunction", "SocialProfile")
	SocialEvent = Net.remote("RemoteEvent", "SocialEvent")
	SocialEmote = Net.remote("RemoteEvent", "SocialEmote")

	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(SC.DATASTORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[CityGrind] Social DataStore unavailable; friend requests reach this server only:", result)
	end

	task.spawn(function()
		local subscribed = pcall(function()
			MessagingService:SubscribeAsync(SC.TOPIC, function(message)
				local data = message and message.Data
				local to = type(data) == "table" and data.to
				local target = validId(to) and Players:GetPlayerByUserId(to)
				if target and sec(target) then
					task.spawn(drainInbox, target)
				end
			end)
		end)
		messagingOk = subscribed
	end)

	SocialAction.OnServerInvoke = function(player: Player, action: any, a: any, b: any)
		local okCall, r1, r2, r3 = pcall(onAction, player, action, a, b)
		if not okCall then
			warn("[CityGrind] SocialAction failed:", r1)
			return false, "Something went wrong."
		end
		return r1, r2, r3
	end

	SocialProfile.OnServerInvoke = function(player: Player, userId: any)
		if not validId(userId) or not Net.allow(player, "SocialProfile", 0.3) then
			return nil
		end
		local okCall, snap = pcall(profileSnapshot, player, userId)
		return if okCall then snap else nil
	end

	SocialEmote.OnServerEvent:Connect(onEmote)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	PlayerData.onLoaded(onLoaded)

	-- Status attribute, nametag and voice mutes stay current.
	-- Without MessagingService, check inboxes now and then for cross-server requests.
	task.spawn(function()
		while true do
			task.wait(90)
			if store and not messagingOk then
				for _, player in Players:GetPlayers() do
					task.spawn(drainInbox, player)
					task.wait(1)
				end
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1.5)
			for _, player in Players:GetPlayers() do
				if sec(player) then
					local status = Social.statusOf(player)
					if player:GetAttribute("SocialStatus") ~= status then
						player:SetAttribute("SocialStatus", status)
					end
					refreshTag(player)
					refreshVoice(player)
				end
			end
			-- expire stale emote requests
			local now = os.clock()
			for _, map in pendingEmotes do
				for from, p in map do
					if now - p.t > SC.EMOTE_REQUEST_SECONDS then
						map[from] = nil
					end
				end
			end
		end
	end)
end

return Social
