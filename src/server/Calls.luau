-- CITY GRIND: phone calls (sections 19, 20, 101). Server side.
-- The server owns every call: who is ringing whom, who is connected, and the
-- saved Recents list. One call per player, both players in this server.
--
-- Voice: only Roblox's own voice chat. Each client reports whether Roblox voice
-- is enabled for it (VoiceChatService, checked client-side as Roblox requires);
-- a call is a VOICE call only when both players have voice AND the audio API's
-- AudioDeviceInput exists for both. The clients then wire the other player's
-- AudioDeviceInput to a local AudioDeviceOutput. Otherwise it is a live TEXT
-- call: every line is filtered per recipient (TextService, PrivateChat), checked
-- against Roblox chat privacy, delivered once and never stored.
--
-- Remotes:  CallAction (RemoteFunction) client -> server (action, a, b) -> (ok, message?, data?)
--           CallEvent  (RemoteEvent)    server -> client (kind, payload)
--             kinds: "incoming", "state", "ended", "text", "recents"
-- Player attribute: InCall = the other player's UserId while connected, else 0.
-- Saved section "Calls": { recents = { { t, id, n, d = "in"|"out", s = status, dur } } }
--   status: "answered" | "missed" | "declined" | "noanswer" | "cancelled"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Net = require(script.Parent:WaitForChild("Net"))
local CC = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("CallsConfig"))

local Calls = {}

local SECTION = "Calls"
local IS_STUDIO = RunService:IsStudio()

PlayerData.registerSection(SECTION, function()
	return { recents = {} }
end)

type Call = {
	id: number,
	caller: Player,
	callee: Player,
	state: string, -- "ringing" | "active"
	mode: string, -- "voice" | "text"
	ringEndsAt: number, -- server time (Workspace:GetServerTimeNow)
	startedAt: number,
	muted: { [Player]: boolean },
	over: boolean,
}

local calls: { [Player]: Call } = {}
local voiceCapable: { [Player]: boolean } = {}
local nextId = 0

local CallAction: RemoteFunction
local CallEvent: RemoteEvent

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local socialModule: any = nil
local function social(): any
	if socialModule == nil then
		socialModule = false
		local module = script.Parent:FindFirstChild("Social")
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				socialModule = result
			end
		end
	end
	return socialModule or nil
end

local function allowsCall(from: Player, to: Player): (boolean, string?)
	local S = social()
	if not S or type(S.allows) ~= "function" then
		return true, nil
	end
	local ok, allowed, reason = pcall(S.allows, from, to, "call")
	if not ok then
		return false, "Calls are unavailable right now."
	end
	return allowed == true, reason
end

local function blocked(a: Player, b: Player): boolean
	local S = social()
	if not S or type(S.isBlocked) ~= "function" then
		return false
	end
	local ok, result = pcall(S.isBlocked, a, b)
	return ok and result == true
end

local function areFriends(a: Player, b: Player): boolean
	local S = social()
	if not S or type(S.areFriends) ~= "function" then
		return false
	end
	local ok, result = pcall(S.areFriends, a, b)
	return ok and result == true
end

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function voiceInput(p: Player): AudioDeviceInput?
	local input = p:FindFirstChildWhichIsA("AudioDeviceInput", true)
	return input :: AudioDeviceInput?
end

local function other(call: Call, p: Player): Player
	return if call.caller == p then call.callee else call.caller
end

local function fire(p: Player, kind: string, payload: any)
	if p.Parent == Players then
		CallEvent:FireClient(p, kind, payload)
	end
end

local chatCache: { [string]: { ok: boolean, at: number } } = {}

-- Roblox chat privacy between two users (failure = not allowed).
local function canChat(fromId: number, toId: number): boolean
	if IS_STUDIO and (fromId <= 0 or toId <= 0) then
		return true -- Studio test players have no real accounts to check
	end
	local key = fromId .. ":" .. toId
	local hit = chatCache[key]
	if hit and os.clock() - hit.at < 300 then
		return hit.ok
	end
	local ok, result = pcall(function()
		return TextChatService:CanUsersChatAsync(fromId, toId)
	end)
	local allowed = ok and result == true
	chatCache[key] = { ok = allowed, at = os.clock() }
	return allowed
end

local function cleanText(raw: any, maxLength: number): string?
	if type(raw) ~= "string" or #raw > maxLength * 4 + 32 or utf8.len(raw) == nil then
		return nil
	end
	local text = raw:gsub("%c", " "):gsub("%s+", " ")
	text = text:match("^%s*(.-)%s*$") or ""
	local length = utf8.len(text)
	if text == "" or not length or length > maxLength then
		return nil
	end
	return text
end

-- What one participant's phone shows about the call.
local function snapshot(call: Call, viewer: Player)
	local o = other(call, viewer)
	return {
		id = call.id,
		state = call.state,
		mode = call.mode,
		outgoing = call.caller == viewer,
		otherId = o.UserId,
		otherName = o.DisplayName,
		otherUsername = o.Name,
		ringEndsAt = call.ringEndsAt,
		startedAt = call.startedAt,
		otherMuted = call.muted[o] == true,
	}
end

local function pushState(call: Call)
	fire(call.caller, "state", snapshot(call, call.caller))
	fire(call.callee, "state", snapshot(call, call.callee))
end

local function recentsOf(p: Player): { any }?
	local s = PlayerData.section(p, SECTION)
	return s and s.recents
end

local function addRecent(p: Player, o: Player, direction: string, status: string, duration: number)
	if p.Parent ~= Players then
		return
	end
	local list = recentsOf(p)
	if not list then
		return
	end
	table.insert(list, 1, { t = os.time(), id = o.UserId, n = o.DisplayName, d = direction, s = status, dur = math.floor(duration) })
	while #list > CC.MAX_RECENTS do
		table.remove(list)
	end
	PlayerData.markChanged(p)
	fire(p, "recents", table.clone(list))
end

local function setServerMute(p: Player, muted: boolean)
	local input = voiceInput(p)
	if input then
		pcall(function()
			(input :: AudioDeviceInput).Muted = muted
		end)
	end
end

---------------------------------------------------------------------------
-- Call lifecycle
---------------------------------------------------------------------------
-- reason: "timeout" | "cancelled" | "declined" | "ended" | "left" | "blocked"
local function finish(call: Call, reason: string, by: Player?)
	if call.over then
		return
	end
	call.over = true
	local caller, callee = call.caller, call.callee
	for _, p in { caller, callee } do
		if calls[p] == call then
			calls[p] = nil
		end
		if p.Parent == Players then
			p:SetAttribute("InCall", 0)
		end
		if call.muted[p] then
			setServerMute(p, false)
		end
	end

	local duration = if call.state == "active" then math.max(0, now() - call.startedAt) else 0
	if call.state == "ringing" then
		local callerGone = by == caller and reason == "left"
		if reason == "declined" then
			addRecent(caller, callee, "out", "declined", 0)
			addRecent(callee, caller, "in", "declined", 0)
			Net.notify(caller, "CALL DECLINED", callee.DisplayName .. " can't talk right now.")
		elseif reason == "timeout" or reason == "cancelled" or callerGone then
			addRecent(caller, callee, "out", if reason == "timeout" then "noanswer" else "cancelled", 0)
			addRecent(callee, caller, "in", "missed", 0)
			Net.notify(callee, "MISSED CALL", caller.DisplayName .. " tried to call you.")
			if reason == "timeout" then
				Net.notify(caller, "NO ANSWER", callee.DisplayName .. " didn't pick up.")
			end
		else -- callee left / got blocked while ringing
			addRecent(caller, callee, "out", "noanswer", 0)
			Net.notify(caller, "CALL FAILED", callee.DisplayName .. " is unavailable.")
		end
	else
		addRecent(caller, callee, "out", "answered", duration)
		addRecent(callee, caller, "in", "answered", duration)
	end

	for _, p in { caller, callee } do
		local o = other(call, p)
		fire(p, "ended", {
			id = call.id,
			reason = reason,
			byMe = by == p,
			otherName = o.DisplayName,
			duration = math.floor(duration),
			wasActive = call.state == "active",
		})
	end
end

local function modeFor(a: Player, b: Player): string
	if voiceCapable[a] and voiceCapable[b] and voiceInput(a) and voiceInput(b) then
		return "voice"
	end
	return "text"
end

local function startCall(player: Player, targetId: any): (boolean, string?)
	if type(targetId) ~= "number" or targetId ~= targetId or targetId % 1 ~= 0 then
		return false, "Pick someone to call."
	end
	local target = Players:GetPlayerByUserId(targetId)
	if not target then
		return false, "That player isn't in this server."
	end
	if target == player then
		return false, "You can't call yourself."
	end
	if not PlayerData.isLoaded(player) or not PlayerData.isLoaded(target) then
		return false, "Still loading in. Try again in a moment."
	end
	if calls[player] then
		return false, "You're already on a call."
	end
	local allowed, reason = allowsCall(player, target)
	if not allowed then
		return false, reason or "You can't call this player."
	end
	if calls[target] then
		return false, target.DisplayName .. " is on another call."
	end
	if not Net.allow(player, "CallStart", CC.START_COOLDOWN) then
		return false, "Wait a few seconds before calling again."
	end

	local mode = modeFor(player, target)
	if mode == "text" then
		-- a text call is player-to-player chat, so Roblox chat privacy must allow it both ways
		if not canChat(player.UserId, target.UserId) or not canChat(target.UserId, player.UserId) then
			return false, "You can't call this player."
		end
		-- canChat may have yielded: re-check everything that could have changed
		if player.Parent ~= Players or target.Parent ~= Players then
			return false, "That player isn't in this server."
		end
		if calls[player] then
			return false, "You're already on a call."
		end
		if calls[target] then
			return false, target.DisplayName .. " is on another call."
		end
	end

	nextId += 1
	local call: Call = {
		id = nextId,
		caller = player,
		callee = target,
		state = "ringing",
		mode = mode,
		ringEndsAt = now() + CC.RING_SECONDS,
		startedAt = 0,
		muted = {},
		over = false,
	}
	calls[player] = call
	calls[target] = call
	fire(target, "incoming", snapshot(call, target))
	fire(player, "state", snapshot(call, player))

	task.delay(CC.RING_SECONDS, function()
		if not call.over and call.state == "ringing" then
			finish(call, "timeout", nil)
		end
	end)
	return true, "Calling " .. target.DisplayName .. "..."
end

local function accept(player: Player, callId: any): (boolean, string?)
	local call = calls[player]
	if not call or call.callee ~= player or call.state ~= "ringing" or (callId ~= nil and callId ~= call.id) then
		return false, "That call is no longer ringing."
	end
	local caller = call.caller
	if caller.Parent ~= Players then
		finish(call, "left", caller)
		return false, "The caller hung up."
	end
	call.state = "active"
	call.startedAt = now()
	player:SetAttribute("InCall", caller.UserId)
	caller:SetAttribute("InCall", player.UserId)
	pushState(call)
	return true, nil
end

local function decline(player: Player, callId: any): (boolean, string?)
	local call = calls[player]
	if not call or call.callee ~= player or call.state ~= "ringing" or (callId ~= nil and callId ~= call.id) then
		return false, "That call is no longer ringing."
	end
	finish(call, "declined", player)
	return true, nil
end

local function hangUp(player: Player): (boolean, string?)
	local call = calls[player]
	if not call then
		return false, "You're not on a call."
	end
	if call.state == "ringing" then
		finish(call, if call.caller == player then "cancelled" else "declined", player)
	else
		finish(call, "ended", player)
	end
	return true, nil
end

local function setMuted(player: Player, muted: any): (boolean, string?)
	local call = calls[player]
	if not call or call.state ~= "active" or call.mode ~= "voice" or type(muted) ~= "boolean" then
		return false, "Nothing to mute."
	end
	if not Net.allow(player, "CallMute", 0.3) then
		return false, nil
	end
	call.muted[player] = muted or nil
	setServerMute(player, muted)
	pushState(call)
	return true, nil
end

-- One line of a text call: privacy check, filter per recipient, deliver, forget.
local function sendText(player: Player, raw: any): (boolean, string?)
	local call = calls[player]
	if not call or call.state ~= "active" or call.mode ~= "text" then
		return false, "You're not on a text call."
	end
	local text = cleanText(raw, CC.TEXT_MAX)
	if not text then
		return false, "Messages are 1-" .. CC.TEXT_MAX .. " characters."
	end
	if not Net.allow(player, "CallText", CC.TEXT_COOLDOWN) then
		return false, "Slow down a little."
	end
	local o = other(call, player)
	if not canChat(player.UserId, o.UserId) then
		return false, "You can't message this player."
	end
	local okFilter, result = pcall(function()
		return TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PrivateChat)
	end)
	local forOther, forSelf
	if okFilter and result then
		local ok1, t1 = pcall(function()
			return result:GetChatForUserAsync(o.UserId)
		end)
		local ok2, t2 = pcall(function()
			return result:GetChatForUserAsync(player.UserId)
		end)
		forOther = if ok1 and type(t1) == "string" then t1 else nil
		forSelf = if ok2 and type(t2) == "string" then t2 else nil
	end
	if not forOther and IS_STUDIO and player.UserId <= 0 then
		forOther, forSelf = text, text -- Studio test players can't be filtered
	end
	if not forOther then
		return false, "Your message couldn't be sent right now."
	end
	-- the filter yields; make sure the call is still the same live call
	if call.over or calls[player] ~= call then
		return false, "The call ended."
	end
	local t = now()
	fire(o, "text", { callId = call.id, fromId = player.UserId, name = player.DisplayName, text = forOther, t = t })
	fire(player, "text", { callId = call.id, fromId = player.UserId, name = player.DisplayName, text = forSelf or forOther, t = t })
	return true, nil
end

-- Everyone you can see in the Contacts tab: players here, then in-game friends elsewhere.
local function contacts(player: Player)
	local list = {}
	local seen = {}
	for _, p in Players:GetPlayers() do
		if p ~= player then
			seen[p.UserId] = true
			local ok, reason = allowsCall(player, p)
			if blocked(player, p) then
				continue -- blocked players don't show up as contacts at all
			end
			table.insert(list, {
				userId = p.UserId,
				name = p.DisplayName,
				username = p.Name,
				here = true,
				friend = areFriends(player, p),
				canCall = ok,
				reason = reason,
				busy = calls[p] ~= nil,
			})
		end
	end
	local S = social()
	if S and type(S.friendIds) == "function" then
		local okIds, ids = pcall(S.friendIds, player)
		local socialSec = PlayerData.section(player, "Social")
		if okIds and type(ids) == "table" then
			for _, id in ids do
				if not seen[id] then
					local rec = socialSec and socialSec.friends and socialSec.friends[tostring(id)]
					table.insert(list, {
						userId = id,
						name = if type(rec) == "table" and type(rec.n) == "string" then rec.n else "Friend",
						username = if type(rec) == "table" and type(rec.u) == "string" then rec.u else "",
						here = false,
						friend = true,
						canCall = false,
						reason = "Not in this server",
						busy = false,
					})
				end
			end
		end
	end
	table.sort(list, function(a, b)
		local ra = (if a.here then 0 else 2) + (if a.friend then 0 else 1)
		local rb = (if b.here then 0 else 2) + (if b.friend then 0 else 1)
		if ra ~= rb then
			return ra < rb
		end
		return a.name:lower() < b.name:lower()
	end)
	return list
end

---------------------------------------------------------------------------
-- Remote handler
---------------------------------------------------------------------------
local function onAction(player: Player, action: any, a: any): (boolean, string?, any)
	if type(action) ~= "string" then
		return false, nil, nil
	end
	if action == "voice" then
		if Net.allow(player, "CallVoiceCap", 1) then
			voiceCapable[player] = a == true
		end
		return true, nil, nil
	elseif action == "call" then
		return startCall(player, a)
	elseif action == "accept" then
		if not Net.allow(player, "CallAnswer", 0.3) then
			return false, nil, nil
		end
		return accept(player, a)
	elseif action == "decline" then
		if not Net.allow(player, "CallAnswer", 0.3) then
			return false, nil, nil
		end
		return decline(player, a)
	elseif action == "end" then
		if not Net.allow(player, "CallEnd", 0.3) then
			return false, nil, nil
		end
		return hangUp(player)
	elseif action == "mute" then
		return setMuted(player, a)
	elseif action == "text" then
		return sendText(player, a)
	elseif action == "recents" then
		if not Net.allow(player, "CallRecents", 0.4) then
			return false, nil, nil
		end
		local list = recentsOf(player)
		return list ~= nil, nil, if list then table.clone(list) else nil
	elseif action == "contacts" then
		if not Net.allow(player, "CallContacts", 0.4) then
			return false, nil, nil
		end
		return true, nil, contacts(player)
	elseif action == "current" then
		local call = calls[player]
		return true, nil, if call then snapshot(call, player) else nil
	elseif action == "clearRecents" then
		if not Net.allow(player, "CallClear", 1) then
			return false, nil, nil
		end
		local list = recentsOf(player)
		if list then
			table.clear(list)
			PlayerData.markChanged(player)
		end
		return true, nil, {}
	end
	return false, nil, nil
end

---------------------------------------------------------------------------
-- Public API (other server systems)
---------------------------------------------------------------------------
-- The other player on `player`'s connected call, if any.
function Calls.partnerOf(player: Player): Player?
	local call = calls[player]
	return if call and call.state == "active" then other(call, player) else nil
end

-- Ends whatever call (ringing or live) the player is part of.
function Calls.hangUp(player: Player)
	local call = calls[player]
	if call then
		finish(call, "ended", player)
	end
end

function Calls.start(_city: Instance)
	CallAction = Net.remote("RemoteFunction", "CallAction")
	CallEvent = Net.remote("RemoteEvent", "CallEvent")

	CallAction.OnServerInvoke = function(player: Player, action: any, a: any)
		local ok, okResult, message, data = pcall(onAction, player, action, a)
		if not ok then
			warn("[CityGrind] Calls action failed:", okResult)
			return false, "Something went wrong.", nil
		end
		return okResult, message, data
	end

	local function onPlayerAdded(p: Player)
		p:SetAttribute("InCall", 0)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end

	Players.PlayerRemoving:Connect(function(p)
		local call = calls[p]
		if call then
			finish(call, "left", p)
		end
		voiceCapable[p] = nil
	end)

	-- A block (or a privacy change to "Nobody") mid-call ends the call.
	task.spawn(function()
		while true do
			task.wait(2)
			local checked = {}
			for _, call in calls do
				if not checked[call] then
					checked[call] = true
					if blocked(call.caller, call.callee) then
						finish(call, "blocked", nil)
					end
				end
			end
		end
	end)
end

return Calls
