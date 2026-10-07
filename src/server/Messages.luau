-- CITY GRIND: phone messaging, group chats and invites (spec sections 17, 18, 36, 48, 109).
--
-- Direct messages: player -> player text. Same server = delivered instantly,
-- filtered for that recipient (GetChatForUserAsync). Offline / other server =
-- filtered for broadcast and written to the recipient's mailbox in DataStore
-- "CityGrind_Mail_v1" (drained when they join, or live through MessagingService
-- if they're online somewhere else). Never delivers text that failed filtering.
-- Group chats: up to 20 members, persisted in "CityGrind_Groups_v1" (members,
-- name, icon, last messages), synced across servers with MessagingService.
-- Without DataStore/MessagingService (unpublished Studio) everything still works
-- in memory for players in the same server.
-- Invites: cards in the chat with ACCEPT / DECLINE (10 minutes). Other systems
-- call Messages.sendInvite / Messages.onInvite (Party, Crews register their own kinds).
-- Coach Ray: two welcome texts on a player's very first join (saved flag).
--
-- Remotes:  MessagesRequest (RemoteFunction, client -> server: action, payload) -> (ok, message, data)
--           MessagesEvent   (RemoteEvent, server -> client):
--             "Msg" (summary, msg) | "Summary" (summary) | "InviteState" (convId, msgId, state)
--             "Removed" (convId) | "Gps" (name, position)
-- Saved section "messages": { coachRay, convos = { [convId] = { kind, with, title, msgs, read, updated } },
--   groups = { [groupId] = true }, groupRead = { [groupId] = time }, muted = { [groupId] = true } }
-- Conversation ids: "d<userId>" direct, "s<Name>" system/NPC, "g<guid>" group.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")
local UserService = game:GetService("UserService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Cfg = require(shared:WaitForChild("MessagesConfig"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Net = require(script.Parent:WaitForChild("Net"))

local Messages = {}

local SERVER_ID = if game.JobId ~= "" then game.JobId else "studio"
local IS_STUDIO = RunService:IsStudio()

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
PlayerData.registerSection("messages", function()
	return {
		coachRay = false, -- Coach Ray's welcome was sent
		convos = {}, -- DMs + system threads, keyed by conversation id
		groups = {}, -- group ids this player belongs to
		groupRead = {}, -- group id -> last read time
		muted = {}, -- group id -> true (no notifications)
	}
end)

local function data(player: Player): any
	return PlayerData.section(player, "messages")
end

---------------------------------------------------------------------------
-- Services that may be unavailable (Studio without API access)
---------------------------------------------------------------------------
local function getStore(name: string): DataStore?
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	return if ok then result else nil
end
local mailStore = getStore("CityGrind_Mail_v1")
local groupStore = getStore("CityGrind_Groups_v1")

local presence: MemoryStoreSortedMap? = nil
pcall(function()
	presence = MemoryStoreService:GetSortedMap("CityGrind_Presence_v1")
end)

local function retry(fn: () -> ()): boolean
	for attempt = 1, 3 do
		if pcall(fn) then
			return true
		end
		task.wait(attempt)
	end
	return false
end

-- Publishes to MessagingService; quietly does nothing where it isn't available.
local function publish(topic: string, message: any)
	task.spawn(pcall, function()
		MessagingService:PublishAsync(topic, message)
	end)
end

local function now(): number
	return Workspace:GetServerTimeNow() -- unix seconds, same clock on every server
end

local function newId(prefix: string): string
	return prefix .. (HttpService:GenerateGUID(false):gsub("-", "")):sub(1, 16)
end

---------------------------------------------------------------------------
-- Other modules (loaded lazily: they may start after us)
---------------------------------------------------------------------------
local moduleCache: { [string]: any } = {}
local function sibling(name: string): any?
	local cached = moduleCache[name]
	if cached ~= nil then
		return cached or nil
	end
	local m = script.Parent:FindFirstChild(name)
	if not m then
		return nil
	end
	local ok, result = pcall(require, m)
	moduleCache[name] = if ok then result else false
	return if ok then result else nil
end

-- Social.allows with a safe fallback (no Social module = only Roblox's own checks).
local function socialAllows(from: Player, to: Player, kind: string): (boolean, string?)
	local Social = sibling("Social")
	if not Social or type(Social.allows) ~= "function" then
		return true, nil
	end
	local ok, allowed, reason = pcall(Social.allows, from, to, kind)
	if not ok then
		return false, "Try again in a moment."
	end
	return allowed == true, reason
end

-- True if `player` and `otherId` blocked each other (either way) in game.
local function blockedId(player: Player, otherId: number): boolean
	local Social = sibling("Social")
	if not Social then
		return false
	end
	local other = Players:GetPlayerByUserId(otherId)
	if other and type(Social.isBlocked) == "function" then
		local ok, result = pcall(Social.isBlocked, player, other)
		return not ok or result == true
	end
	if type(Social.isBlockedId) == "function" then
		local ok, result = pcall(Social.isBlockedId, player, otherId)
		return not ok or result == true
	end
	return false
end

-- Recipient-side check for mail from someone not in this server.
local function allowsFromId(fromId: number, to: Player, kind: string): boolean
	if blockedId(to, fromId) then
		return false
	end
	local Social = sibling("Social")
	if Social and type(Social.allowsFromId) == "function" then
		local ok, allowed = pcall(Social.allowsFromId, fromId, to, kind)
		return ok and allowed == true
	end
	return true
end

local function friendIds(player: Player): { number }
	local Social = sibling("Social")
	if Social and type(Social.friendIds) == "function" then
		local ok, ids = pcall(Social.friendIds, player)
		if ok and type(ids) == "table" then
			return ids
		end
	end
	return {}
end

local function isFriendId(player: Player, userId: number): boolean
	for _, id in friendIds(player) do
		if id == userId then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Roblox chat privacy + text filtering (sections 20, 44, 45, 101)
---------------------------------------------------------------------------
local chatCache: { [string]: { ok: boolean, at: number } } = {}

-- Can `fromId` send text to `toId`? Uses Roblox's privacy settings; failure = no.
local function canChat(fromId: number, toId: number, direct: boolean): boolean
	if fromId == toId then
		return true
	end
	if IS_STUDIO and (fromId <= 0 or toId <= 0) then
		return true -- Studio test players have no real accounts to check
	end
	local key = fromId .. ":" .. toId .. (if direct then "d" else "g")
	local hit = chatCache[key]
	if hit and os.clock() - hit.at < 300 then
		return hit.ok
	end
	local allowed = false
	local ok, result = pcall(function()
		if direct then
			return TextChatService:CanUsersDirectChatAsync(fromId, { toId })
		end
		return TextChatService:CanUsersChatAsync(fromId, toId)
	end)
	if ok and direct and type(result) == "table" then
		allowed = table.find(result, toId) ~= nil
	elseif ok and not direct then
		allowed = result == true
	elseif not ok and direct then
		local ok2, result2 = pcall(function()
			return TextChatService:CanUsersChatAsync(fromId, toId)
		end)
		allowed = ok2 and result2 == true
	end
	chatCache[key] = { ok = allowed, at = os.clock() }
	return allowed
end

-- Trims, collapses whitespace and rejects anything too long or not valid UTF-8.
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

local function filterResult(text: string, fromId: number, context: Enum.TextFilterContext): TextFilterResult?
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, fromId, context)
	end)
	return if ok then result else nil
end

local function forUser(result: TextFilterResult, toId: number): string?
	local ok, text = pcall(function()
		return result:GetChatForUserAsync(toId)
	end)
	return if ok and type(text) == "string" then text else nil
end

-- Studio test players (negative ids) can't be filtered; their text passes through
-- in Studio only. A live game never delivers text that failed filtering.
local function studioPass(fromId: number): boolean
	return IS_STUDIO and fromId <= 0
end

local function forBroadcast(result: TextFilterResult): string?
	local ok, text = pcall(function()
		return result:GetNonChatStringForBroadcastAsync()
	end)
	return if ok and type(text) == "string" then text else nil
end

-- Sliding-window limit: one message per MIN_GAP and MAX_PER_MINUTE per minute.
local sentTimes: { [Player]: { number } } = {}
local function rateOk(player: Player): (boolean, string?)
	local t = os.clock()
	local list = sentTimes[player] or {}
	sentTimes[player] = list
	while list[1] and t - list[1] > 60 do
		table.remove(list, 1)
	end
	local last = list[#list]
	if last and t - last < Cfg.MIN_GAP then
		return false, "Slow down a little."
	end
	if #list >= Cfg.MAX_PER_MINUTE then
		return false, "You're sending too many messages. Wait a minute."
	end
	table.insert(list, t)
	return true, nil
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------
local nameCache: { [number]: string } = {}
local function nameOf(userId: number): string
	local p = Players:GetPlayerByUserId(userId)
	if p then
		nameCache[userId] = p.DisplayName
		return p.DisplayName
	end
	if nameCache[userId] then
		return nameCache[userId]
	end
	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync({ userId })
	end)
	if ok and type(infos) == "table" and infos[1] and type(infos[1].DisplayName) == "string" then
		nameCache[userId] = infos[1].DisplayName
		return infos[1].DisplayName
	end
	local ok2, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok2 and type(name) == "string" then
		nameCache[userId] = name
		return name
	end
	return "Player"
end

-- Batch lookup for contact lists.
local function namesOf(ids: { number }): { [number]: string }
	local out, missing = {}, {}
	for _, id in ids do
		local p = Players:GetPlayerByUserId(id)
		if p then
			out[id] = p.DisplayName
		elseif nameCache[id] then
			out[id] = nameCache[id]
		else
			table.insert(missing, id)
		end
	end
	for i = 1, #missing, 100 do
		local chunk = table.move(missing, i, math.min(i + 99, #missing), 1, {})
		local ok, infos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(chunk)
		end)
		if ok and type(infos) == "table" then
			for _, info in infos do
				if type(info.Id) == "number" and type(info.DisplayName) == "string" then
					nameCache[info.Id] = info.DisplayName
					out[info.Id] = info.DisplayName
				end
			end
		end
	end
	for _, id in missing do
		out[id] = out[id] or "Player"
	end
	return out
end

---------------------------------------------------------------------------
-- Remotes and pushing to clients
---------------------------------------------------------------------------
local Event: RemoteEvent

local function fire(player: Player, ...)
	if Event and player.Parent then
		Event:FireClient(player, ...)
	end
end

local function preview(msg: any): string
	if msg.kind == "invite" and msg.invite then
		return msg.invite.icon .. " " .. msg.invite.title
	end
	local text = tostring(msg.text or "")
	if utf8.len(text) and (utf8.len(text) :: number) > 40 then
		text = text:sub(1, (utf8.offset(text, 41) or 41) - 1) .. "…"
	end
	return text
end

-- What a client sees for one message.
local function publicMsg(msg: any): any
	return {
		id = msg.id,
		from = msg.from,
		name = msg.name,
		text = msg.text,
		t = msg.t,
		kind = msg.kind,
		invite = if msg.invite then table.clone(msg.invite) else nil,
	}
end

---------------------------------------------------------------------------
-- Groups: cache + write-behind persistence
---------------------------------------------------------------------------
type GroupRecord = {
	id: string,
	name: string,
	icon: number,
	color: number,
	owner: number,
	admins: { [string]: boolean },
	members: { [string]: string }, -- tostring(userId) -> display name
	msgs: { any },
	deleted: boolean?,
}

local groupCache: { [string]: GroupRecord } = {}
local groupPending: { [string]: { any } } = {} -- ops not yet written to the store
local groupLoading: { [string]: boolean } = {}

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

local function memberCount(rec: GroupRecord): number
	local n = 0
	for _ in rec.members do
		n += 1
	end
	return n
end

local function roleOf(rec: GroupRecord, userId: number): string?
	local key = tostring(userId)
	if not rec.members[key] then
		return nil
	end
	if rec.owner == userId then
		return "owner"
	end
	return if rec.admins[key] then "admin" else "member"
end

-- Applies one change to a group record (used on the cache and inside UpdateAsync).
local function applyOp(rec: GroupRecord, op: any)
	if op.op == "msg" then
		for _, m in rec.msgs do
			if m.id == op.m.id then
				return
			end
		end
		table.insert(rec.msgs, op.m)
		while #rec.msgs > Cfg.GROUP_HISTORY do
			table.remove(rec.msgs, 1)
		end
	elseif op.op == "add" then
		if not rec.members[op.k] and memberCount(rec) < Cfg.GROUP_MAX_MEMBERS then
			rec.members[op.k] = op.name
		end
	elseif op.op == "remove" then
		rec.members[op.k] = nil
		rec.admins[op.k] = nil
		if tostring(rec.owner) == op.k then
			-- ownership passes to an admin, else the longest-standing member id
			local nextOwner: string? = nil
			for k in rec.admins do
				if rec.members[k] and (not nextOwner or k < nextOwner) then
					nextOwner = k
				end
			end
			if not nextOwner then
				for k in rec.members do
					if not nextOwner or k < nextOwner then
						nextOwner = k
					end
				end
			end
			if nextOwner then
				rec.owner = tonumber(nextOwner) or 0
				rec.admins[nextOwner] = nil
			else
				rec.deleted = true
			end
		end
	elseif op.op == "admin" then
		if rec.members[op.k] and tostring(rec.owner) ~= op.k then
			rec.admins[op.k] = if op.on then true else nil :: any
		end
	elseif op.op == "meta" then
		if op.name then
			rec.name = op.name
		end
		if op.icon then
			rec.icon = op.icon
		end
		if op.color then
			rec.color = op.color
		end
	end
end

local function queueOp(gid: string, op: any)
	local rec = groupCache[gid]
	if rec then
		applyOp(rec, op)
	end
	if groupStore then
		groupPending[gid] = groupPending[gid] or {}
		table.insert(groupPending[gid], op)
	end
end

-- Reads a key without DataStore's read cache (UpdateAsync that cancels itself).
local function freshRead(store: DataStore, key: string): (boolean, any)
	local value = nil
	local ok = retry(function()
		store:UpdateAsync(key, function(old)
			value = old
			return nil
		end)
	end)
	return ok, value
end

-- The group (cached unless `fresh`), with our unsaved changes on top.
local function getGroup(gid: string, fresh: boolean?): GroupRecord?
	if type(gid) ~= "string" or #gid > 40 then
		return nil
	end
	local cached = groupCache[gid]
	if cached and not fresh then
		return if cached.deleted then nil else cached
	end
	if not groupStore then
		return if cached and not cached.deleted then cached else nil
	end
	while groupLoading[gid] do
		task.wait(0.1)
	end
	if not fresh and groupCache[gid] then
		return groupCache[gid]
	end
	groupLoading[gid] = true
	local ok, value = freshRead(groupStore, "group_" .. gid)
	groupLoading[gid] = nil
	if ok and type(value) == "table" then
		local rec = value :: GroupRecord
		rec.admins = rec.admins or {}
		rec.members = rec.members or {}
		rec.msgs = rec.msgs or {}
		for _, op in groupPending[gid] or {} do
			applyOp(rec, op)
		end
		groupCache[gid] = rec
	end
	local rec = groupCache[gid]
	return if rec and not rec.deleted then rec else nil
end

local function flushGroup(gid: string)
	local ops = groupPending[gid]
	if not ops or not groupStore then
		return
	end
	groupPending[gid] = nil
	local result = nil
	local store = groupStore :: DataStore
	local ok = retry(function()
		store:UpdateAsync("group_" .. gid, function(old)
			local rec = old
			for _, op in ops do
				if op.op == "create" then
					rec = rec or deepCopy(op.rec)
				elseif rec then
					applyOp(rec, op)
				end
			end
			result = rec
			return rec
		end)
	end)
	if not ok then
		-- put them back in front of anything queued meanwhile; try again next flush
		for _, op in groupPending[gid] or {} do
			table.insert(ops, op)
		end
		groupPending[gid] = ops
		return
	end
	if type(result) == "table" then
		local rec = result :: GroupRecord
		for _, op in groupPending[gid] or {} do
			applyOp(rec, op)
		end
		groupCache[gid] = rec
	end
	publish("CGGroup", { g = gid, s = SERVER_ID })
end

---------------------------------------------------------------------------
-- Mailbox (offline / other-server delivery)
---------------------------------------------------------------------------
local mailPending: { [number]: { any } } = {}

local function queueMail(toId: number, item: any)
	if not mailStore then
		return false
	end
	mailPending[toId] = mailPending[toId] or {}
	table.insert(mailPending[toId], item)
	-- live push to the server they're on (if any); the mailbox copy dedupes by id
	local okEncode, encoded = pcall(HttpService.JSONEncode, HttpService, { to = toId, item = item })
	if okEncode and #encoded < 900 then
		publish("CGMail", { to = toId, item = item })
	end
	return true
end

local function flushMail(toId: number)
	local items = mailPending[toId]
	if not items or not mailStore then
		return
	end
	mailPending[toId] = nil
	local store = mailStore :: DataStore
	local ok = retry(function()
		store:UpdateAsync("inbox_" .. toId, function(old)
			local box = if type(old) == "table" then old else {}
			for _, item in items do
				table.insert(box, item)
			end
			while #box > Cfg.MAILBOX_MAX do
				table.remove(box, 1)
			end
			return box
		end)
	end)
	if ok then
		publish("CGMail", { to = toId })
	else
		for _, item in mailPending[toId] or {} do
			table.insert(items, item)
		end
		mailPending[toId] = items
	end
end

---------------------------------------------------------------------------
-- Conversations (DMs + system threads, stored in the player's own save)
---------------------------------------------------------------------------
local function convoTitle(convo: any): string
	return convo.title or "Chat"
end

local function unreadIn(msgs: { any }, read: number, me: number): number
	local n = 0
	for i = #msgs, 1, -1 do
		local m = msgs[i]
		if m.t <= read then
			break
		end
		if m.from ~= me then
			n += 1
		end
	end
	return n
end

local function summaryOf(player: Player, convId: string): any?
	local sec = data(player)
	if not sec then
		return nil
	end
	if convId:sub(1, 1) == "g" then
		local rec = groupCache[convId]
		if not rec or rec.deleted or not sec.groups[convId] then
			return nil
		end
		local last = rec.msgs[#rec.msgs]
		return {
			id = convId,
			kind = "group",
			title = rec.name,
			icon = Cfg.GROUP_ICONS[rec.icon] or Cfg.GROUP_ICONS[1],
			color = Cfg.GROUP_COLORS[rec.color] or Cfg.GROUP_COLORS[1],
			preview = if last then (if last.kind == "text" then last.name .. ": " else "") .. preview(last) else "Group created",
			t = if last then last.t else 0,
			unread = unreadIn(rec.msgs, sec.groupRead[convId] or 0, player.UserId),
			muted = sec.muted[convId] == true,
			canReply = true,
			role = roleOf(rec, player.UserId),
			members = memberCount(rec),
		}
	end
	local convo = sec.convos[convId]
	if not convo then
		return nil
	end
	local last = convo.msgs[#convo.msgs]
	local isSystem = convo.kind == "system"
	return {
		id = convId,
		kind = convo.kind,
		title = convoTitle(convo),
		icon = if isSystem then (Cfg.SYSTEM_ICONS[convo.title] or "📣") else "👤",
		color = if isSystem then Color3.fromRGB(255, 140, 50) else Color3.fromRGB(90, 170, 255),
		preview = if last then (if last.from == player.UserId then "You: " else "") .. preview(last) else "",
		t = convo.updated or 0,
		unread = unreadIn(convo.msgs, convo.read or 0, player.UserId),
		muted = false,
		canReply = not isSystem,
		with = convo.with,
	}
end

local function pushSummary(player: Player, convId: string)
	local summary = summaryOf(player, convId)
	if summary then
		fire(player, "Summary", summary)
	end
end

-- Drops the stalest DM/system threads past the cap (never `keep`).
local function trimConvos(sec: any, keep: string)
	local count = 0
	for _ in sec.convos do
		count += 1
	end
	while count > Cfg.MAX_CONVERSATIONS do
		local oldestId, oldestT = nil, math.huge
		for id, c in sec.convos do
			if id ~= keep and (c.updated or 0) < oldestT then
				oldestId, oldestT = id, c.updated or 0
			end
		end
		if not oldestId then
			break
		end
		sec.convos[oldestId] = nil
		count -= 1
	end
end

-- Adds a message to a player's DM/system thread, saves, and pushes it. Returns false if not loaded.
local function addToConvo(player: Player, convId: string, msg: any, meta: { kind: string, with: number?, title: string }): boolean
	local sec = data(player)
	if not sec then
		return false
	end
	local convo = sec.convos[convId]
	if not convo then
		convo = { kind = meta.kind, with = meta.with, title = meta.title, msgs = {}, read = 0, updated = 0 }
		sec.convos[convId] = convo
	end
	for _, m in convo.msgs do
		if m.id == msg.id then
			return true -- already delivered (mailbox + live push)
		end
	end
	convo.title = meta.title
	table.insert(convo.msgs, msg)
	while #convo.msgs > Cfg.DM_HISTORY do
		table.remove(convo.msgs, 1)
	end
	convo.updated = math.max(convo.updated or 0, msg.t)
	if msg.from == player.UserId then
		convo.read = math.max(convo.read or 0, msg.t)
	end
	trimConvos(sec, convId)
	PlayerData.markChanged(player)
	fire(player, "Msg", summaryOf(player, convId), publicMsg(msg))
	return true
end

-- Finds a message by id in a player's thread and changes its invite state.
local function setInviteState(player: Player?, convId: string, msgId: string, state: string)
	local sec = player and data(player)
	local convo = sec and sec.convos[convId]
	if not convo then
		return
	end
	for _, m in convo.msgs do
		if m.id == msgId and m.invite then
			m.invite.state = state
			PlayerData.markChanged(player :: Player)
			fire(player :: Player, "InviteState", convId, msgId, state)
			pushSummary(player :: Player, convId)
			return
		end
	end
end

---------------------------------------------------------------------------
-- System messages (Coach Ray and other NPCs)
---------------------------------------------------------------------------
function Messages.sendSystem(to: Player, fromName: string, text: string)
	local convId = "s" .. fromName:gsub("[^%w]", "")
	local msg = { id = newId("m"), from = 0, name = fromName, text = text, t = now(), kind = "system" }
	if not addToConvo(to, convId, msg, { kind = "system", title = fromName }) then
		-- save not loaded yet: deliver once it is
		task.spawn(function()
			local deadline = os.clock() + 60
			while to.Parent and not data(to) and os.clock() < deadline do
				task.wait(1)
			end
			if to.Parent then
				addToConvo(to, convId, msg, { kind = "system", title = fromName })
			end
		end)
	end
end

---------------------------------------------------------------------------
-- Direct messages
---------------------------------------------------------------------------
-- Has `fromId` ever written to `player` (so a reply to them is always allowed)?
local function hasThreadFrom(player: Player, fromId: number): boolean
	local sec = data(player)
	local convo = sec and sec.convos["d" .. fromId]
	if not convo then
		return false
	end
	for _, m in convo.msgs do
		if m.from == fromId then
			return true
		end
	end
	return false
end

local function sendDirect(sender: Player, toId: number, raw: any): (boolean, string?)
	if toId == sender.UserId then
		return false, "You can't text yourself."
	end
	local text = cleanText(raw, Cfg.MAX_LENGTH)
	if not text then
		return false, "Messages are 1-" .. Cfg.MAX_LENGTH .. " characters."
	end
	local target = Players:GetPlayerByUserId(toId)
	if target then
		local ok, reason = socialAllows(sender, target, "message")
		if not ok then
			return false, reason or "You can't message this player."
		end
	else
		if blockedId(sender, toId) then
			return false, "You can't message this player."
		end
		if not isFriendId(sender, toId) and not hasThreadFrom(sender, toId) then
			return false, "They're not in this server. Add them as a friend to text them anywhere."
		end
	end
	local okRate, why = rateOk(sender)
	if not okRate then
		return false, why
	end
	if not canChat(sender.UserId, toId, true) then
		return false, "You can't message this player."
	end
	local result = filterResult(text, sender.UserId, Enum.TextFilterContext.PrivateChat)
	local filtered = result and (if target then forUser(result, toId) else forBroadcast(result))
	if not filtered and studioPass(sender.UserId) then
		filtered = text
	end
	if not filtered then
		return false, "Your message couldn't be sent right now. Try again."
	end
	local msg = { id = newId("m"), from = sender.UserId, name = sender.DisplayName, text = filtered, t = now(), kind = "text" }
	local toName = if target then target.DisplayName else nameOf(toId)

	if target and data(target) then
		addToConvo(target, "d" .. sender.UserId, msg, { kind = "dm", with = sender.UserId, title = sender.DisplayName })
	elseif target then
		return false, toName .. " is still loading in. Try again in a moment."
	elseif not queueMail(toId, { type = "dm", msg = msg }) then
		return false, toName .. " isn't in this server, and offline mail is unavailable here."
	end
	addToConvo(sender, "d" .. toId, msg, { kind = "dm", with = toId, title = toName })
	return true, nil
end

-- Mail arriving for a player in this server (from their mailbox or a live push).
local function receiveMail(player: Player, item: any)
	local sec = data(player)
	if not sec or type(item) ~= "table" then
		return
	end
	if item.type == "dm" and type(item.msg) == "table" then
		local msg = item.msg
		if type(msg.from) ~= "number" or type(msg.text) ~= "string" or type(msg.id) ~= "string" then
			return
		end
		if not allowsFromId(msg.from, player, "message") then
			return
		end
		msg.kind = "text"
		msg.name = tostring(msg.name or "Player")
		msg.t = tonumber(msg.t) or now()
		msg.invite = nil
		addToConvo(player, "d" .. msg.from, msg, { kind = "dm", with = msg.from, title = msg.name })
	elseif item.type == "group" and type(item.g) == "string" then
		if sec.groups[item.g] then
			return
		end
		local rec = getGroup(item.g, true)
		if rec and rec.members[tostring(player.UserId)] then
			sec.groups[item.g] = true
			PlayerData.markChanged(player)
			pushSummary(player, item.g)
			Net.notify(player, "NEW GROUP", (tostring(item.by or "Someone")) .. " added you to " .. rec.name .. ".")
		end
	end
end

local function drainMailbox(player: Player)
	if not mailStore or not data(player) then
		return
	end
	local taken = nil
	local store = mailStore :: DataStore
	local ok = retry(function()
		store:UpdateAsync("inbox_" .. player.UserId, function(old)
			taken = old
			if type(old) ~= "table" or #old == 0 then
				return nil
			end
			return {}
		end)
	end)
	if ok and type(taken) == "table" and player.Parent then
		for _, item in taken do
			receiveMail(player, item)
		end
	end
end

---------------------------------------------------------------------------
-- Group chats
---------------------------------------------------------------------------
local function groupCountOf(sec: any): number
	local n = 0
	for _ in sec.groups do
		n += 1
	end
	return n
end

-- Delivers a group message to members in this server who may see it.
local function deliverGroupMsg(rec: GroupRecord, msg: any)
	for key in rec.members do
		local p = Players:GetPlayerByUserId(tonumber(key) or 0)
		local sec = p and data(p)
		if p and sec and sec.groups[rec.id] then
			task.spawn(function()
				if msg.from ~= p.UserId and msg.kind == "text" then
					if blockedId(p, msg.from) or not canChat(msg.from, p.UserId, false) then
						return
					end
				end
				if msg.from == p.UserId then
					sec.groupRead[rec.id] = math.max(sec.groupRead[rec.id] or 0, msg.t)
					PlayerData.markChanged(p)
				end
				fire(p, "Msg", summaryOf(p, rec.id), publicMsg(msg))
			end)
		end
	end
end

local function groupNotice(rec: GroupRecord, text: string)
	local msg = { id = newId("m"), from = 0, name = rec.name, text = text, t = now(), kind = "system" }
	queueOp(rec.id, { op = "msg", m = msg })
	deliverGroupMsg(rec, msg)
	publish("CGGroup", { g = rec.id, m = msg, s = SERVER_ID })
end

-- Re-checks a present player's group list against the records (removed while away, deleted...).
local function syncPlayerGroup(player: Player, gid: string)
	local sec = data(player)
	if not sec or not sec.groups[gid] then
		return
	end
	local rec = groupCache[gid]
	if not rec then
		return
	end
	if rec.deleted or not rec.members[tostring(player.UserId)] then
		sec.groups[gid] = nil
		sec.groupRead[gid] = nil
		sec.muted[gid] = nil
		PlayerData.markChanged(player)
		fire(player, "Removed", gid)
	else
		pushSummary(player, gid)
	end
end

local function sendGroup(sender: Player, gid: string, raw: any): (boolean, string?)
	local sec = data(sender)
	local rec = sec and sec.groups[gid] and getGroup(gid) -- [Security] membership before any DataStore read
	if not sec or not rec or not rec.members[tostring(sender.UserId)] then
		return false, "You're not in that group."
	end
	local text = cleanText(raw, Cfg.MAX_LENGTH)
	if not text then
		return false, "Messages are 1-" .. Cfg.MAX_LENGTH .. " characters."
	end
	local okRate, why = rateOk(sender)
	if not okRate then
		return false, why
	end
	local okChat = IS_STUDIO and sender.UserId <= 0
	if not okChat then
		local ok, result = pcall(function()
			return TextChatService:CanUserChatAsync(sender.UserId)
		end)
		okChat = ok and result == true
	end
	if not okChat then
		return false, "Your account settings don't allow chat."
	end
	local result = filterResult(text, sender.UserId, Enum.TextFilterContext.PrivateChat)
	local filtered = result and forBroadcast(result)
	if not filtered and studioPass(sender.UserId) then
		filtered = text
	end
	if not filtered then
		return false, "Your message couldn't be sent right now. Try again."
	end
	local msg = { id = newId("m"), from = sender.UserId, name = sender.DisplayName, text = filtered, t = now(), kind = "text" }
	queueOp(gid, { op = "msg", m = msg })
	deliverGroupMsg(rec, msg)
	publish("CGGroup", { g = gid, m = msg, s = SERVER_ID })
	return true, nil
end

-- Can `adder` put `userId` in a group? Same-server players need their invite privacy; others must be friends.
local function canAddMember(adder: Player, userId: number): (boolean, string?)
	if userId == adder.UserId then
		return false, nil
	end
	local target = Players:GetPlayerByUserId(userId)
	if target then
		local ok, reason = socialAllows(adder, target, "invite")
		if not ok then
			return false, reason or (target.DisplayName .. " can't be added.")
		end
		local sec = data(target)
		if not sec then
			return false, target.DisplayName .. " is still loading in."
		end
		if groupCountOf(sec) >= Cfg.MAX_GROUPS then
			return false, target.DisplayName .. " is in too many groups."
		end
		return true, nil
	end
	if blockedId(adder, userId) or not isFriendId(adder, userId) then
		return false, "You can only add friends or players in this server."
	end
	if not mailStore then
		return false, "Players outside this server can't be added here."
	end
	return true, nil
end

local function addMember(rec: GroupRecord, adder: Player, userId: number)
	local name = nameOf(userId)
	queueOp(rec.id, { op = "add", k = tostring(userId), name = name })
	local target = Players:GetPlayerByUserId(userId)
	local sec = target and data(target)
	if target and sec then
		sec.groups[rec.id] = true
		sec.groupRead[rec.id] = now()
		PlayerData.markChanged(target)
		pushSummary(target, rec.id)
		Net.notify(target, "NEW GROUP", adder.DisplayName .. " added you to " .. rec.name .. ".")
	else
		queueMail(userId, { type = "group", g = rec.id, by = adder.DisplayName })
	end
	return name
end

local function readUserIds(list: any, max: number): { number }?
	if type(list) ~= "table" or #list > max then
		return nil
	end
	local out = {}
	for _, id in list do
		if type(id) ~= "number" or id ~= math.floor(id) or table.find(out, id) then
			return nil
		end
		table.insert(out, id)
	end
	return out
end

local function filterGroupName(player: Player, raw: any): (string?, string?)
	local name = cleanText(raw, Cfg.GROUP_NAME_MAX)
	if not name then
		return nil, "Group names are 1-" .. Cfg.GROUP_NAME_MAX .. " characters."
	end
	local result = filterResult(name, player.UserId, Enum.TextFilterContext.PublicChat)
	local filtered = result and forBroadcast(result)
	if not filtered and studioPass(player.UserId) then
		filtered = name
	end
	if not filtered then
		return nil, "That name couldn't be checked right now. Try again."
	end
	return filtered, nil
end

local function validIndex(value: any, list: { any }): number?
	return if type(value) == "number" and list[value] then value else nil
end

---------------------------------------------------------------------------
-- Invites
---------------------------------------------------------------------------
type Invite = {
	id: string,
	kind: string,
	from: number,
	to: number,
	payload: { [string]: any },
	expires: number,
	state: string,
	msgId: string,
}
local invites: { [string]: Invite } = {}
local inviteHandlers: { [string]: (Player?, Player, { [string]: any }) -> (boolean?, string?) } = {}

function Messages.onInvite(kind: string, handler: (Player?, Player, { [string]: any }) -> (boolean?, string?))
	inviteHandlers[kind] = handler
end

local function endInvite(inv: Invite, state: string)
	inv.state = state
	setInviteState(Players:GetPlayerByUserId(inv.to), "d" .. inv.from, inv.msgId, state)
	setInviteState(Players:GetPlayerByUserId(inv.from), "d" .. inv.to, inv.msgId, state)
	invites[inv.id] = nil
end

-- payload.label / payload.place (optional) must be game text or text the caller already filtered.
function Messages.sendInvite(from: Player, to: Player, inviteKind: string, payload: { [string]: any }): (boolean, string?)
	if typeof(from) ~= "Instance" or typeof(to) ~= "Instance" or not from:IsA("Player") or not to:IsA("Player") then
		return false, "Invalid player."
	end
	if from == to then
		return false, "You can't invite yourself."
	end
	if not to.Parent or not from.Parent then
		return false, "They're not in this server."
	end
	local style = Cfg.INVITE_STYLE[inviteKind]
	if not style or not inviteHandlers[inviteKind] then
		return false, "Unknown invite."
	end
	if not data(from) or not data(to) then
		return false, "Try again in a moment."
	end
	local okSocial, reason = socialAllows(from, to, "invite")
	if not okSocial then
		return false, reason or "You can't invite this player."
	end
	if not Net.allow(from, "MsgInvite" .. to.UserId .. inviteKind, 4) then
		return false, "You just invited them."
	end
	payload = if type(payload) == "table" then payload else {}
	-- one pending invite of each kind per pair: a new one replaces the old
	for _, old in invites do
		if old.from == from.UserId and old.to == to.UserId and old.kind == inviteKind then
			endInvite(old, "expired")
		end
	end
	local sub = payload.place or payload.label
	sub = if type(sub) == "string" then sub:sub(1, 60) else nil
	local inv: Invite = {
		id = newId("i"),
		kind = inviteKind,
		from = from.UserId,
		to = to.UserId,
		payload = payload,
		expires = os.time() + Cfg.INVITE_SECONDS,
		state = "pending",
		msgId = newId("m"),
	}
	invites[inv.id] = inv
	local card = { id = inv.id, kind = inviteKind, icon = style.icon, title = style.title, sub = sub, expires = inv.expires, state = "pending", to = to.UserId }
	local msg = { id = inv.msgId, from = from.UserId, name = from.DisplayName, text = "", t = now(), kind = "invite", invite = card }
	addToConvo(to, "d" .. from.UserId, msg, { kind = "dm", with = from.UserId, title = from.DisplayName })
	addToConvo(from, "d" .. to.UserId, deepCopy(msg), { kind = "dm", with = to.UserId, title = to.DisplayName })
	return true, nil
end

local function respond(player: Player, inviteId: any, accept: boolean): (boolean, string?)
	local inv = type(inviteId) == "string" and invites[inviteId]
	if not inv then
		-- server restarted or it was already answered: make sure the card doesn't stay clickable
		local sec = data(player)
		if sec and type(inviteId) == "string" then
			for convId, convo in sec.convos do
				for _, m in convo.msgs do
					if m.invite and m.invite.id == inviteId and m.invite.state == "pending" then
						setInviteState(player, convId, m.id, "expired")
					end
				end
			end
		end
		return false, "That invite isn't open anymore."
	end
	if inv.to ~= player.UserId then
		return false, "That invite isn't for you."
	end
	if os.time() > inv.expires then
		endInvite(inv, "expired")
		return false, "That invite expired."
	end
	local from = Players:GetPlayerByUserId(inv.from)
	if not accept then
		endInvite(inv, "declined")
		if from then
			Net.notify(from, "INVITE DECLINED", player.DisplayName .. " passed on your invite.")
		end
		return true, "Declined."
	end
	local handler = inviteHandlers[inv.kind]
	local ok, result, reason = pcall(handler, from, player, inv.payload)
	if not ok then
		warn("[CityGrind] invite handler failed:", inv.kind, result)
		return false, "That didn't work. Try again."
	end
	if result == false then
		return false, reason or "That can't happen right now." -- stays pending so they can try again
	end
	endInvite(inv, "accepted")
	if from then
		Net.notify(from, "INVITE ACCEPTED", player.DisplayName .. " accepted your invite.")
	end
	return true, reason or "Accepted."
end

-- Courts: the one the player is playing on, else the nearest one.
local function courtFor(player: Player): (string?, Vector3?)
	local CourtGames = sibling("CourtGames")
	local playing = nil
	if CourtGames and type(CourtGames.gameOf) == "function" then
		local ok, name = pcall(CourtGames.gameOf, player)
		playing = if ok then name else nil
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local origin = if root and root:IsA("BasePart") then root.Position else Vector3.zero
	local bestName, bestPos, bestDist = nil, nil, math.huge
	for _, court in CollectionService:GetTagged("Court") do
		local center = court:GetAttribute("CourtCenter")
		if typeof(center) == "Vector3" then
			local display = court:GetAttribute("DisplayName")
			local label = if type(display) == "string" then display else court.Name
			local dist = if playing and (court.Name == playing or label == playing) then -1 else (center - origin).Magnitude
			if dist < bestDist then
				bestName, bestPos, bestDist = label, center, dist
			end
		end
	end
	return bestName, bestPos
end

local function registerBuiltInInvites()
	Messages.onInvite("apartment", function(owner: Player?, guest: Player, _payload)
		if not owner or not owner.Parent then
			return false, "They're not in this server anymore."
		end
		local Apartments = sibling("Apartments")
		if not Apartments or type(Apartments.visit) ~= "function" then
			return false, "Apartments aren't open right now."
		end
		Apartments.setGuestAllowed(owner, guest.UserId, true)
		local ok, reason = Apartments.visit(guest, owner)
		if not ok then
			return false, reason
		end
		return true, "Heading to " .. owner.DisplayName .. "'s place."
	end)

	Messages.onInvite("basketball", function(from: Player?, to: Player, payload)
		local name, pos = nil, nil
		if from and from.Parent then
			name, pos = courtFor(from)
		end
		if not pos and typeof(payload.position) == "Vector3" then
			name, pos = payload.place, payload.position
		end
		if not pos then
			return false, "Couldn't find the court."
		end
		local label = if type(name) == "string" then name else "Court"
		fire(to, "Gps", label, pos)
		if from and from.Parent then
			fire(from, "Gps", label, pos)
			Net.notify(from, "ON THE WAY", to.DisplayName .. " is heading to " .. label .. ".")
		end
		return true, "GPS set to " .. label .. "."
	end)

	Messages.onInvite("event", function(_from, to: Player, payload)
		if typeof(payload.position) == "Vector3" then
			fire(to, "Gps", if type(payload.label) == "string" then payload.label:sub(1, 40) else "Event", payload.position)
			return true, "GPS set."
		end
		return true, "See you there."
	end)
end

---------------------------------------------------------------------------
-- Contacts + presence (section 46)
---------------------------------------------------------------------------
local function setPresence(player: Player, online: boolean)
	if not presence then
		return
	end
	task.spawn(pcall, function()
		if online then
			(presence :: MemoryStoreSortedMap):SetAsync(tostring(player.UserId), SERVER_ID, 150)
		else
			(presence :: MemoryStoreSortedMap):RemoveAsync(tostring(player.UserId))
		end
	end)
end

local presenceCache: { [number]: { on: boolean, at: number } } = {}
local function isOnline(userId: number): boolean
	if Players:GetPlayerByUserId(userId) then
		return true
	end
	if not presence then
		return false
	end
	local hit = presenceCache[userId]
	if hit and os.clock() - hit.at < 30 then
		return hit.on
	end
	local ok, value = pcall(function()
		return (presence :: MemoryStoreSortedMap):GetAsync(tostring(userId))
	end)
	local on = ok and value ~= nil
	presenceCache[userId] = { on = on, at = os.clock() }
	return on
end

local function contactsFor(player: Player): { any }
	local ids = table.clone(friendIds(player))
	if #ids > 60 then
		ids = table.move(ids, 1, 60, 1, {})
	end
	local names = namesOf(ids)
	local list = {}
	for _, id in ids do
		local here = Players:GetPlayerByUserId(id) ~= nil
		table.insert(list, {
			id = id,
			name = names[id],
			status = if here then "here" elseif isOnline(id) then "online" else "offline",
			friend = true,
		})
	end
	return list
end

-- People you can start a chat with / add to a group: friends + players here.
local function pickList(player: Player): { any }
	local list = contactsFor(player)
	local seen = {}
	for _, c in list do
		seen[c.id] = true
	end
	for _, p in Players:GetPlayers() do
		if p ~= player and not seen[p.UserId] and not blockedId(player, p.UserId) then
			table.insert(list, { id = p.UserId, name = p.DisplayName, status = "here", friend = false })
		end
	end
	return list
end

---------------------------------------------------------------------------
-- Requests from the client
---------------------------------------------------------------------------
local function stateFor(player: Player): any
	local sec = data(player)
	if not sec then
		return nil
	end
	local list = {}
	for convId in sec.convos do
		table.insert(list, summaryOf(player, convId))
	end
	for gid in sec.groups do
		local s = summaryOf(player, gid)
		if s then
			table.insert(list, s)
		end
	end
	return list
end

local function groupInfo(player: Player, rec: GroupRecord): any
	local members = {}
	for key, name in rec.members do
		local id = tonumber(key) or 0
		table.insert(members, { id = id, name = name, role = roleOf(rec, id), here = Players:GetPlayerByUserId(id) ~= nil })
	end
	local sec = data(player)
	return {
		id = rec.id,
		name = rec.name,
		icon = rec.icon,
		color = rec.color,
		members = members,
		myRole = roleOf(rec, player.UserId),
		muted = sec and sec.muted[rec.id] == true,
	}
end

local function isAdmin(rec: GroupRecord, userId: number): boolean
	local role = roleOf(rec, userId)
	return role == "owner" or role == "admin"
end

local handlers: { [string]: (Player, any, any) -> (boolean, string?, any) } = {}

handlers.GetState = function(player)
	return true, nil, stateFor(player)
end

-- Opens a thread: returns its messages and marks it read.
handlers.Open = function(player, sec, convId)
	if type(convId) ~= "string" then
		return false, nil, nil
	end
	if convId:sub(1, 1) == "g" then
		-- [Security] membership first: an arbitrary group id would otherwise cost a DataStore read
		local rec = sec.groups[convId] and getGroup(convId)
		if not rec then
			return false, "That group is gone.", nil
		end
		local msgs = {}
		for _, m in rec.msgs do
			if m.kind ~= "text" or m.from == player.UserId or (not blockedId(player, m.from) and canChat(m.from, player.UserId, false)) then
				table.insert(msgs, publicMsg(m))
			end
		end
		sec.groupRead[convId] = now()
		PlayerData.markChanged(player)
		return true, nil, { summary = summaryOf(player, convId), msgs = msgs, info = groupInfo(player, rec) }
	end
	local convo = sec.convos[convId]
	if not convo then
		local id = tonumber(convId:match("^d(%-?%d+)$"))
		if not id or id == player.UserId or id ~= id or math.abs(id) >= 1e13 then
			return false, nil, nil
		end
		-- new thread: nothing saved until the first message
		return true, nil, {
			summary = { id = convId, kind = "dm", title = nameOf(id), icon = "👤", color = Color3.fromRGB(90, 170, 255), preview = "", t = 0, unread = 0, muted = false, canReply = true, with = id },
			msgs = {},
		}
	end
	local t = os.time()
	for _, m in convo.msgs do
		if m.invite and m.invite.state == "pending" and t > m.invite.expires then
			m.invite.state = "expired"
		end
	end
	convo.read = now()
	PlayerData.markChanged(player)
	local msgs = {}
	for _, m in convo.msgs do
		table.insert(msgs, publicMsg(m))
	end
	return true, nil, { summary = summaryOf(player, convId), msgs = msgs }
end

handlers.Read = function(player, sec, convId)
	if type(convId) ~= "string" then
		return false, nil, nil
	end
	if sec.groups[convId] then
		sec.groupRead[convId] = now()
	elseif sec.convos[convId] then
		sec.convos[convId].read = now()
	else
		return false, nil, nil
	end
	PlayerData.markChanged(player)
	return true, nil, summaryOf(player, convId)
end

handlers.Send = function(player, _sec, payload)
	if type(payload) ~= "table" or type(payload.to) ~= "string" then
		return false, nil, nil
	end
	local convId = payload.to
	if convId:sub(1, 1) == "g" then
		return sendGroup(player, convId, payload.text)
	end
	local id = tonumber(convId:match("^d(%-?%d+)$"))
	if not id then
		return false, "You can't reply to this thread.", nil
	end
	return sendDirect(player, id, payload.text)
end

handlers.Respond = function(player, _sec, payload)
	if type(payload) ~= "table" then
		return false, nil, nil
	end
	return respond(player, payload.id, payload.accept == true)
end

-- Invites from the interaction menu ("basketball" / "apartment").
handlers.Invite = function(player, _sec, payload)
	if type(payload) ~= "table" or type(payload.userId) ~= "number" then
		return false, nil, nil
	end
	local target = Players:GetPlayerByUserId(payload.userId)
	if not target then
		return false, "They're not in this server.", nil
	end
	if payload.kind == "basketball" then
		local name, pos = courtFor(player)
		if not pos then
			return false, "There's no court to invite them to.", nil
		end
		local ok, reason = Messages.sendInvite(player, target, "basketball", { place = name, position = pos })
		return ok, if ok then "Invite sent to " .. target.DisplayName .. "." else reason, nil
	elseif payload.kind == "apartment" then
		local ok, reason = Messages.sendInvite(player, target, "apartment", { place = tostring(player:GetAttribute("HomeTier") or "My place") })
		return ok, if ok then "Invite sent. Be home when they accept!" else reason, nil
	end
	return false, nil, nil
end

handlers.Delete = function(player, sec, convId)
	if type(convId) ~= "string" or not sec.convos[convId] then
		return false, nil, nil
	end
	sec.convos[convId] = nil
	PlayerData.markChanged(player)
	fire(player, "Removed", convId)
	return true, nil, nil
end

handlers.Contacts = function(player)
	return true, nil, contactsFor(player)
end

handlers.Pick = function(player)
	return true, nil, pickList(player)
end

handlers.CreateGroup = function(player, sec, payload)
	if type(payload) ~= "table" then
		return false, nil, nil
	end
	if groupCountOf(sec) >= Cfg.MAX_GROUPS then
		return false, "You're in " .. Cfg.MAX_GROUPS .. " groups already. Leave one first.", nil
	end
	local icon = validIndex(payload.icon, Cfg.GROUP_ICONS) or 1
	local color = validIndex(payload.color, Cfg.GROUP_COLORS) or 1
	local ids = readUserIds(payload.members, Cfg.GROUP_MAX_MEMBERS - 1)
	if not ids or #ids == 0 then
		return false, "Pick at least one person.", nil
	end
	for _, id in ids do
		local ok, reason = canAddMember(player, id)
		if not ok then
			return false, reason or "Someone on that list can't be added.", nil
		end
	end
	local name, err = filterGroupName(player, payload.name)
	if not name then
		return false, err, nil
	end
	local gid = newId("g")
	local rec: GroupRecord = {
		id = gid,
		name = name,
		icon = icon,
		color = color,
		owner = player.UserId,
		admins = {},
		members = { [tostring(player.UserId)] = player.DisplayName },
		msgs = {},
	}
	groupCache[gid] = rec
	if groupStore then
		groupPending[gid] = { { op = "create", rec = deepCopy(rec) } }
	end
	sec.groups[gid] = true
	sec.groupRead[gid] = now()
	PlayerData.markChanged(player)
	local names = {}
	for _, id in ids do
		table.insert(names, addMember(rec, player, id))
	end
	groupNotice(rec, player.DisplayName .. " created the group with " .. table.concat(names, ", ") .. ".")
	return true, "Group created.", summaryOf(player, gid)
end

-- Group management: everything goes through one action with a sub-command.
handlers.Group = function(player, sec, payload)
	if type(payload) ~= "table" or type(payload.id) ~= "string" then
		return false, nil, nil
	end
	local rec = sec.groups[payload.id] and getGroup(payload.id) -- [Security] membership before any DataStore read
	if not rec or not rec.members[tostring(player.UserId)] then
		return false, "You're not in that group.", nil
	end
	local gid = rec.id
	local cmd = payload.cmd
	local admin = isAdmin(rec, player.UserId)

	if cmd == "Info" then
		return true, nil, groupInfo(player, rec)
	elseif cmd == "Mute" then
		sec.muted[gid] = if payload.on == true then true else nil
		PlayerData.markChanged(player)
		pushSummary(player, gid)
		return true, if payload.on then "Group muted." else "Notifications on.", groupInfo(player, rec)
	elseif cmd == "Leave" then
		queueOp(gid, { op = "remove", k = tostring(player.UserId) })
		sec.groups[gid] = nil
		sec.groupRead[gid] = nil
		sec.muted[gid] = nil
		PlayerData.markChanged(player)
		fire(player, "Removed", gid)
		if not rec.deleted then
			groupNotice(rec, player.DisplayName .. " left the group.")
		end
		return true, "You left " .. rec.name .. ".", nil
	end

	if not admin then
		return false, "Only the group's admins can do that.", nil
	end
	if cmd == "Rename" then
		local name, err = filterGroupName(player, payload.name)
		if not name then
			return false, err, nil
		end
		queueOp(gid, { op = "meta", name = name })
		groupNotice(rec, player.DisplayName .. " renamed the group to " .. name .. ".")
	elseif cmd == "Style" then
		local icon = validIndex(payload.icon, Cfg.GROUP_ICONS)
		local color = validIndex(payload.color, Cfg.GROUP_COLORS)
		if not icon and not color then
			return false, nil, nil
		end
		queueOp(gid, { op = "meta", icon = icon, color = color })
		for key in rec.members do
			local p = Players:GetPlayerByUserId(tonumber(key) or 0)
			if p then
				pushSummary(p, gid)
			end
		end
		publish("CGGroup", { g = gid, s = SERVER_ID, meta = true })
	elseif cmd == "Add" then
		local ids = readUserIds(payload.userIds, Cfg.GROUP_MAX_MEMBERS)
		if not ids or #ids == 0 then
			return false, nil, nil
		end
		local fresh = {}
		for _, id in ids do
			if not rec.members[tostring(id)] then
				table.insert(fresh, id)
			end
		end
		if memberCount(rec) + #fresh > Cfg.GROUP_MAX_MEMBERS then
			return false, "Groups hold up to " .. Cfg.GROUP_MAX_MEMBERS .. " people.", nil
		end
		for _, id in fresh do
			local ok, reason = canAddMember(player, id)
			if not ok then
				return false, reason or "Someone on that list can't be added.", nil
			end
		end
		local names = {}
		for _, id in fresh do
			table.insert(names, addMember(rec, player, id))
		end
		if #names > 0 then
			groupNotice(rec, player.DisplayName .. " added " .. table.concat(names, ", ") .. ".")
		end
	elseif cmd == "Remove" then
		local id = payload.userId
		local key = tostring(id)
		if type(id) ~= "number" or not rec.members[key] or id == player.UserId then
			return false, nil, nil
		end
		if id == rec.owner or (rec.admins[key] and rec.owner ~= player.UserId) then
			return false, "Only the owner can remove an admin.", nil
		end
		local name = rec.members[key]
		queueOp(gid, { op = "remove", k = key })
		local target = Players:GetPlayerByUserId(id)
		if target then
			syncPlayerGroup(target, gid)
		end
		groupNotice(rec, player.DisplayName .. " removed " .. name .. ".")
	elseif cmd == "Admin" then
		local id = payload.userId
		if rec.owner ~= player.UserId then
			return false, "Only the owner can pick admins.", nil
		end
		if type(id) ~= "number" or not rec.members[tostring(id)] or id == player.UserId then
			return false, nil, nil
		end
		queueOp(gid, { op = "admin", k = tostring(id), on = payload.on == true })
		publish("CGGroup", { g = gid, s = SERVER_ID, meta = true })
	else
		return false, nil, nil
	end
	return true, nil, groupInfo(player, rec)
end

local COOLDOWNS = {
	GetState = 0.5,
	Open = 0.15,
	Read = 0.15,
	Send = 0.2, -- the real limit is rateOk
	Respond = 0.5,
	Invite = 1.5,
	Delete = 0.3,
	Contacts = 2,
	Pick = 2,
	CreateGroup = 3,
	Group = 0.4,
}

---------------------------------------------------------------------------
-- Cross-server
---------------------------------------------------------------------------
local function onMailTopic(message: any)
	local body = type(message) == "table" and message.Data
	if type(body) ~= "table" or type(body.to) ~= "number" then
		return
	end
	local player = Players:GetPlayerByUserId(body.to)
	if not player or not data(player) then
		return
	end
	if body.item then
		receiveMail(player, body.item)
	else
		drainMailbox(player)
	end
end

local function onGroupTopic(message: any)
	local body = type(message) == "table" and message.Data
	if type(body) ~= "table" or type(body.g) ~= "string" or body.s == SERVER_ID then
		return
	end
	local gid = body.g
	if not groupCache[gid] then
		return -- nobody here is in it
	end
	if type(body.m) == "table" and type(body.m.id) == "string" then
		local rec = groupCache[gid]
		applyOp(rec, { op = "msg", m = body.m })
		deliverGroupMsg(rec, body.m)
		return
	end
	-- full sync after another server saved: reload, then deliver messages we never saw live
	local known = {}
	for _, m in groupCache[gid].msgs do
		known[m.id] = true
	end
	getGroup(gid, true)
	local found = groupCache[gid]
	if found then
		for key in found.members do
			local p = Players:GetPlayerByUserId(tonumber(key) or 0)
			if p then
				syncPlayerGroup(p, gid)
			end
		end
		if not found.deleted then
			for _, m in found.msgs do
				if not known[m.id] then
					deliverGroupMsg(found, m)
				end
			end
		end
	end
	-- also catch players here who were just removed
	for _, p in Players:GetPlayers() do
		local sec = data(p)
		if sec and sec.groups[gid] then
			syncPlayerGroup(p, gid)
		end
	end
end

---------------------------------------------------------------------------
-- Player lifecycle
---------------------------------------------------------------------------
local function onLoaded(player: Player)
	local sec = data(player)
	if not sec then
		return
	end
	setPresence(player, true)
	-- groups: load and drop any we were removed from while away
	for gid in table.clone(sec.groups) do
		getGroup(gid)
		local rec = groupCache[gid] -- nil only if the read failed (kept) or there's no store
		if (rec and (rec.deleted or not rec.members[tostring(player.UserId)])) or (not rec and not groupStore) then
			sec.groups[gid] = nil
			sec.groupRead[gid] = nil
			sec.muted[gid] = nil
			PlayerData.markChanged(player)
		end
	end
	drainMailbox(player)
	if player.Parent then
		fire(player, "State", stateFor(player))
	end
	-- Coach Ray (section 109): once per save
	if not sec.coachRay then
		sec.coachRay = true
		PlayerData.markChanged(player)
		task.delay(8, function()
			if player.Parent then
				Messages.sendSystem(player, Cfg.COACH_RAY, Cfg.COACH_RAY_LINES[1])
				task.wait(4)
				if player.Parent then
					Messages.sendSystem(player, Cfg.COACH_RAY, Cfg.COACH_RAY_LINES[2])
				end
			end
		end)
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Messages.start(_city: Instance?)
	Event = Net.remote("RemoteEvent", "MessagesEvent")
	local Request = Net.remote("RemoteFunction", "MessagesRequest")

	Request.OnServerInvoke = function(player: Player, action: any, payload: any)
		if type(action) ~= "string" or not handlers[action] then
			return false, "Unknown request.", nil
		end
		if not Net.allow(player, "Msg" .. action, COOLDOWNS[action] or 0.3) then
			return false, nil, nil
		end
		local sec = data(player)
		if not sec then
			return false, "Your phone is still loading.", nil
		end
		-- [Security] errors come back as a failure instead of being thrown into the client
		local pok, ok, message, result = pcall(handlers[action], player, sec, payload)
		if not pok then
			warn("[Security] MessagesRequest failed:", action, ok)
			return false, "Something went wrong.", nil
		end
		return ok, message, result
	end

	registerBuiltInInvites()

	-- Studio without API access: GetDataStore works but every request fails, so
	-- fall back to same-server, in-memory messaging instead of retrying forever.
	if IS_STUDIO and (mailStore or groupStore) then
		task.spawn(function()
			local ok = pcall(function()
				((mailStore or groupStore) :: DataStore):GetAsync("probe")
			end)
			if not ok then
				mailStore, groupStore, presence = nil, nil, nil
				table.clear(groupPending)
				table.clear(mailPending)
			end
		end)
	end

	-- SubscribeAsync yields; don't hold up the modules that start after us.
	task.spawn(function()
		pcall(function()
			MessagingService:SubscribeAsync("CGMail", onMailTopic)
		end)
		pcall(function()
			MessagingService:SubscribeAsync("CGGroup", onGroupTopic)
		end)
	end)

	PlayerData.onLoaded(onLoaded)
	Players.PlayerRemoving:Connect(function(player)
		sentTimes[player] = nil
		setPresence(player, false)
	end)

	-- write-behind loop: groups first (so mailed group adds see the member), then mail
	task.spawn(function()
		local tick = 0
		while true do
			task.wait(7)
			tick += 1
			for gid in table.clone(groupPending) do
				flushGroup(gid)
			end
			for toId in table.clone(mailPending) do
				flushMail(toId)
			end
			-- expire invites, refresh presence, and re-check mailboxes every minute
			local t = os.time()
			for _, inv in table.clone(invites) do
				if t > inv.expires then
					endInvite(inv, "expired")
				end
			end
			if tick % 8 == 0 then
				for _, p in Players:GetPlayers() do
					if data(p) then
						setPresence(p, true)
						task.spawn(drainMailbox, p)
					end
				end
			end
		end
	end)

	game:BindToClose(function()
		for gid in table.clone(groupPending) do
			flushGroup(gid)
		end
		for toId in table.clone(mailPending) do
			flushMail(toId)
		end
	end)
end

return Messages
