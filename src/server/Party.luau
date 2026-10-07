-- CITY GRIND: parties (section 93). Server side.
-- A party is a small group (max 6) inside one server. The leader creates it,
-- members invite friends (through the Messages app's invite cards, or a direct
-- prompt when Messages isn't installed), and the leader can kick, promote,
-- disband, set a shared GPS destination, ask everyone to travel to them, or
-- send the whole party to the nearest basketball court. Nobody is ever
-- teleported by someone else.
--
-- Remotes:  PartyAction (client -> server): ("create") ("invite", target) ("accept", partyId)
--                ("decline", partyId) ("leave") ("kick", target) ("promote", target) ("disband")
--                ("destination", mapPointName) ("travel") ("hoops")
--           PartyEvent (server -> client): ("state", snapshot?) ("invite", {partyId, fromName, fromUserId})
--                ("gps", name, position, note)
-- Player attribute: PartyId ("" when not in a party)

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local Net = require(script.Parent:WaitForChild("Net"))

local Party = {}

Party.MAX_MEMBERS = 6
local INVITE_SECONDS = 180

export type PartyRecord = {
	id: string,
	leader: Player,
	members: { Player },
	invites: { [Player]: number }, -- invitee -> expiry (os.clock)
	createdAt: number,
}

local parties: { [string]: PartyRecord } = {}
local partyOfPlayer: { [Player]: PartyRecord } = {}
local cityModel: Instance? = nil

local PartyAction = Net.remote("RemoteEvent", "PartyAction")
local PartyEvent = Net.remote("RemoteEvent", "PartyEvent")

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function lazy(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

local function snapshot(party: PartyRecord)
	local members = {}
	for _, m in party.members do
		table.insert(members, { userId = m.UserId, name = m.DisplayName, username = m.Name, leader = m == party.leader })
	end
	return { id = party.id, leaderId = party.leader.UserId, members = members, max = Party.MAX_MEMBERS }
end

local function broadcast(party: PartyRecord)
	local snap = snapshot(party)
	for _, m in party.members do
		PartyEvent:FireClient(m, "state", snap)
	end
end

local function notifyAll(party: PartyRecord, title: string, body: string, except: Player?)
	for _, m in party.members do
		if m ~= except then
			Net.notify(m, title, body)
		end
	end
end

local function setMembership(player: Player, party: PartyRecord?)
	partyOfPlayer[player] = party :: any
	if player.Parent then
		player:SetAttribute("PartyId", if party then party.id else "")
		if not party then
			PartyEvent:FireClient(player, "state", nil)
		end
	end
end

local function disband(party: PartyRecord, reason: string?)
	parties[party.id] = nil
	for _, m in party.members do
		setMembership(m, nil)
		if reason then
			Net.notify(m, "PARTY", reason)
		end
	end
	table.clear(party.members)
	table.clear(party.invites)
end

local function removeMember(party: PartyRecord, player: Player, why: string?)
	local index = table.find(party.members, player)
	if not index then
		return
	end
	table.remove(party.members, index)
	setMembership(player, nil)
	if #party.members == 0 then
		disband(party, nil)
		return
	end
	if party.leader == player then
		party.leader = party.members[1]
		notifyAll(party, "PARTY", party.leader.DisplayName .. " is now the party leader.")
	end
	if why then
		notifyAll(party, "PARTY", why)
	end
	broadcast(party)
end

local function createParty(leader: Player): PartyRecord
	local existing = partyOfPlayer[leader]
	if existing then
		return existing
	end
	local party: PartyRecord = {
		id = HttpService:GenerateGUID(false):sub(1, 8),
		leader = leader,
		members = { leader },
		invites = {},
		createdAt = os.time(),
	}
	parties[party.id] = party
	setMembership(leader, party)
	broadcast(party)
	return party
end

local function socialAllows(from: Player, to: Player, kind: string): (boolean, string?)
	local Social = lazy("Social")
	if Social and Social.allows then
		local ok, allowed, why = pcall(Social.allows, from, to, kind)
		if ok then
			return allowed == true, why
		end
	end
	return true, nil
end

local function gpsAll(party: PartyRecord, name: string, position: Vector3, note: string, except: Player?)
	for _, m in party.members do
		if m ~= except then
			PartyEvent:FireClient(m, "gps", name, position, note)
		end
	end
end

local function rootPos(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- The player's party ({id, leader, members}) or nil.
function Party.partyOf(player: Player): { id: string, leader: Player, members: { Player } }?
	local party = partyOfPlayer[player]
	if not party then
		return nil
	end
	return { id = party.id, leader = party.leader, members = table.clone(party.members) }
end

function Party.create(player: Player): (boolean, string?)
	if partyOfPlayer[player] then
		return false, "You're already in a party."
	end
	createParty(player)
	return true
end

-- Invite a player. Creates a party for the inviter when they don't have one yet.
function Party.invite(from: Player, to: Player): (boolean, string?)
	if to == from or not to.Parent then
		return false, "Pick someone else."
	end
	if not to:GetAttribute("DataLoaded") then
		return false, to.DisplayName .. " is still loading in."
	end
	local current = partyOfPlayer[from]
	if current and table.find(current.members, to) then
		return false, to.DisplayName .. " is already in your party."
	end
	if current and #current.members >= Party.MAX_MEMBERS then
		return false, "Your party is full (" .. Party.MAX_MEMBERS .. " max)."
	end
	local allowed, why = socialAllows(from, to, "invite")
	if not allowed then
		return false, why or (to.DisplayName .. " isn't taking invites right now.")
	end
	if current and current.invites[to] and os.clock() < current.invites[to] then
		return false, "You already invited " .. to.DisplayName .. "."
	end
	local party = current or createParty(from)
	party.invites[to] = os.clock() + INVITE_SECONDS

	local Messages = lazy("Messages")
	local sent = false
	if Messages and Messages.sendInvite then
		local ok, delivered, reason = pcall(Messages.sendInvite, from, to, "party", {
			partyId = party.id,
			label = from.DisplayName .. "'s party (" .. #party.members .. "/" .. Party.MAX_MEMBERS .. ")",
		})
		if ok and delivered then
			sent = true
		elseif ok and reason then
			party.invites[to] = nil
			if not current and #party.members == 1 then
				disband(party, nil)
			end
			return false, reason
		end
	end
	if not sent then
		-- no Messages app: show the invite as a direct prompt
		PartyEvent:FireClient(to, "invite", { partyId = party.id, fromName = from.DisplayName, fromUserId = from.UserId })
		Net.notify(to, "PARTY INVITE", from.DisplayName .. " invited you to their party.")
	end
	return true
end

function Party.accept(player: Player, partyId: any): (boolean, string?)
	if type(partyId) ~= "string" then
		return false, "That invite is no longer valid."
	end
	local party = parties[partyId]
	if not party then
		return false, "That party doesn't exist anymore."
	end
	local expires = party.invites[player]
	if not expires or os.clock() > expires then
		party.invites[player] = nil
		return false, "That invite expired. Ask for a new one."
	end
	if table.find(party.members, player) then
		return false, "You're already in that party."
	end
	if #party.members >= Party.MAX_MEMBERS then
		return false, "That party is full."
	end
	party.invites[player] = nil
	local old = partyOfPlayer[player]
	if old then
		removeMember(old, player, player.DisplayName .. " left the party.")
	end
	table.insert(party.members, player)
	setMembership(player, party)
	notifyAll(party, "PARTY", player.DisplayName .. " joined the party.", player)
	Net.notify(player, "PARTY", "You joined " .. party.leader.DisplayName .. "'s party.")
	broadcast(party)
	return true
end

function Party.leave(player: Player): (boolean, string?)
	local party = partyOfPlayer[player]
	if not party then
		return false, "You're not in a party."
	end
	removeMember(party, player, player.DisplayName .. " left the party.")
	Net.notify(player, "PARTY", "You left the party.")
	return true
end

---------------------------------------------------------------------------
-- Remote handling
---------------------------------------------------------------------------
local function leaderParty(player: Player): (PartyRecord?, string?)
	local party = partyOfPlayer[player]
	if not party then
		return nil, "You're not in a party."
	end
	if party.leader ~= player then
		return nil, "Only the party leader can do that."
	end
	return party
end

local function targetIn(party: PartyRecord, target: any): Player?
	if typeof(target) == "Instance" and target:IsA("Player") and table.find(party.members, target) then
		return target
	end
	return nil
end

local function nearestCourt(from: Vector3): (string?, Vector3?)
	local bestName, bestPos, bestDist = nil, nil, math.huge
	for _, model in CollectionService:GetTagged("Court") do
		local center = model:GetAttribute("CourtCenter")
		if typeof(center) == "Vector3" then
			local d = (center - from).Magnitude
			if d < bestDist then
				bestName = model:GetAttribute("DisplayName") or model.Name
				bestPos = center
				bestDist = d
			end
		end
	end
	return bestName, bestPos
end

local handlers: { [string]: (Player, any) -> (boolean, string?) } = {
	create = function(player)
		local ok, why = Party.create(player)
		if ok then
			Net.notify(player, "PARTY", "Party created. Invite people from their menu or the Party app.")
		end
		return ok, why
	end,
	invite = function(player, target)
		if typeof(target) ~= "Instance" or not target:IsA("Player") then
			return false, nil
		end
		local ok, why = Party.invite(player, target)
		if ok then
			Net.notify(player, "PARTY", "Invite sent to " .. target.DisplayName .. ".")
		end
		return ok, why
	end,
	accept = function(player, partyId)
		return Party.accept(player, partyId)
	end,
	decline = function(player, partyId)
		local party = type(partyId) == "string" and parties[partyId]
		if party and party.invites[player] then
			party.invites[player] = nil
			Net.notify(party.leader, "PARTY", player.DisplayName .. " declined the party invite.")
		end
		return true
	end,
	leave = function(player)
		return Party.leave(player)
	end,
	kick = function(player, target)
		local party, why = leaderParty(player)
		if not party then
			return false, why
		end
		local t = targetIn(party, target)
		if not t or t == player then
			return false, "Pick a party member."
		end
		Net.notify(t, "PARTY", "You were removed from the party.")
		removeMember(party, t, t.DisplayName .. " was removed from the party.")
		return true
	end,
	promote = function(player, target)
		local party, why = leaderParty(player)
		if not party then
			return false, why
		end
		local t = targetIn(party, target)
		if not t or t == player then
			return false, "Pick a party member."
		end
		party.leader = t
		notifyAll(party, "PARTY", t.DisplayName .. " is now the party leader.")
		broadcast(party)
		return true
	end,
	disband = function(player)
		local party, why = leaderParty(player)
		if not party then
			return false, why
		end
		disband(party, player.DisplayName .. " disbanded the party.")
		return true
	end,
	destination = function(player, pointName)
		local party, why = leaderParty(player)
		if not party then
			return false, why
		end
		local points = cityModel and cityModel:FindFirstChild("MapPoints")
		local point = type(pointName) == "string" and #pointName < 80 and points and points:FindFirstChild(pointName)
		if not point or not point:IsA("BasePart") then
			return false, "Pick a place from the list."
		end
		gpsAll(party, point.Name, point.Position, player.DisplayName .. " set the party destination.")
		return true
	end,
	travel = function(player)
		local party, why = leaderParty(player)
		if not party then
			return false, why
		end
		local pos = rootPos(player)
		if not pos then
			return false, "Respawn first."
		end
		if player:GetAttribute("Interior") and player:GetAttribute("Interior") ~= "" then
			return false, "Step outside first so the party can find you."
		end
		gpsAll(party, player.DisplayName, pos, "Travel together: head to your party leader.", player)
		Net.notify(player, "PARTY", "Your party is on the way to you.")
		return true
	end,
	hoops = function(player)
		local party, why = leaderParty(player)
		if not party then
			return false, why
		end
		local pos = rootPos(player)
		if not pos then
			return false, "Respawn first."
		end
		local name, center = nearestCourt(pos)
		if not name or not center then
			return false, "No court found."
		end
		gpsAll(party, name, center, "Basketball run! Teams form on the HOME and AWAY pads at " .. name .. ".")
		return true
	end,
}

local COOLDOWNS = { create = 1, invite = 1.5, accept = 0.5, decline = 0.5, leave = 1, kick = 0.5, promote = 0.5, disband = 1, destination = 3, travel = 5, hoops = 5 }

function Party.start(city: Instance?)
	cityModel = city

	PartyAction.OnServerEvent:Connect(function(player: Player, action: any, arg: any)
		local handler = type(action) == "string" and handlers[action]
		if not handler or not Net.allow(player, "Party" .. action, COOLDOWNS[action] or 1) then
			return
		end
		local ok, why = handler(player, arg)
		if not ok and why then
			Net.notify(player, "PARTY", why)
		end
	end)

	-- Accepting the invite card in the Messages app.
	task.spawn(function()
		local Messages = lazy("Messages")
		if Messages and Messages.onInvite then
			Messages.onInvite("party", function(_from: Player?, to: Player, payload: any)
				-- Messages shows the returned reason to the player
				return Party.accept(to, type(payload) == "table" and payload.partyId or nil)
			end)
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		player:SetAttribute("PartyId", "")
	end)
	for _, player in Players:GetPlayers() do
		player:SetAttribute("PartyId", "")
	end
	Players.PlayerRemoving:Connect(function(player)
		local party = partyOfPlayer[player]
		if party then
			removeMember(party, player, player.DisplayName .. " left the game.")
		end
		partyOfPlayer[player] = nil
		for _, p in parties do
			p.invites[player] = nil
		end
	end)
end

return Party
