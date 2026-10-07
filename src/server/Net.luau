-- CITY GRIND: remotes, rate limits and notifications shared by every server system.
-- Remotes live in ReplicatedStorage.CityGrind.Remotes so clients can WaitForChild them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local remotes = shared:FindFirstChild("Remotes") or Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = shared
Net.folder = remotes

-- Creates (or reuses) a RemoteEvent / RemoteFunction by name.
function Net.remote(className: string, name: string): any
	local r = remotes:FindFirstChild(name)
	if r and r.ClassName ~= className then
		r:Destroy()
		r = nil
	end
	r = r or Instance.new(className)
	r.Name = name
	r.Parent = remotes
	return r
end

-- Per-player cooldowns so no remote can be spammed. Returns false while cooling down.
local lastCall: { [Player]: { [string]: number } } = {}
function Net.allow(player: Player, key: string, cooldown: number): boolean
	local now = os.clock()
	local calls = lastCall[player]
	if not calls then
		calls = {}
		lastCall[player] = calls
	end
	if calls[key] and now - calls[key] < cooldown then
		return false
	end
	calls[key] = now
	return true
end

-- Rolling-window budget: at most `max` calls per `window` seconds (for actions whose cost is
-- a DataStore read on an id the client picks, where a short cooldown alone still allows a flood).
local budgets: { [Player]: { [string]: { start: number, count: number } } } = {}
function Net.budget(player: Player, key: string, max: number, window: number): boolean
	local now = os.clock()
	local mine = budgets[player]
	if not mine then
		mine = {}
		budgets[player] = mine
	end
	local b = mine[key]
	if not b or now - b.start >= window then
		mine[key] = { start = now, count = 1 }
		return true
	end
	if b.count >= max then
		return false
	end
	b.count += 1
	return true
end

-- [Security] finite number check for client-sent numbers (rejects NaN and +/-inf).
function Net.isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

Players.PlayerRemoving:Connect(function(player)
	lastCall[player] = nil
	budgets[player] = nil
end)

local NotifyRemote = Net.remote("RemoteEvent", "Notify") -- server -> client (title, body)

-- Phone notification + toast for one player.
function Net.notify(player: Player, title: string, body: string)
	if player.Parent then
		NotifyRemote:FireClient(player, title, body)
	end
end

-- Distance from a player's character to a point (math.huge with no character).
function Net.distance(player: Player, position: Vector3): number
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return math.huge
	end
	return (root.Position - position).Magnitude
end

-- True when the player has a living character.
function Net.alive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and character:FindFirstChild("HumanoidRootPart") ~= nil
end

return Net
