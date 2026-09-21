--[[
	Declares the RemoteEvents the game uses and creates them under
	ReplicatedStorage on first require. Server and client both require this
	module so the instances always exist before either side uses them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FOLDER_NAME = "RemoteEvents"

local EVENT_NAMES = {
	"PlayerDataUpdated",
	"RequestAttack",
	"LootReceived",
	"PlayerDied",
}

local function getOrCreateFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function getOrCreateRemoteEvent(folder: Folder, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing then
		return existing :: RemoteEvent
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local folder = getOrCreateFolder()

local Remotes = {}
for _, name in EVENT_NAMES do
	Remotes[name] = getOrCreateRemoteEvent(folder, name)
end

return Remotes
