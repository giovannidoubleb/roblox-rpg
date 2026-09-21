--[[
	Thin DataStore wrapper: retries transient failures with backoff, and
	holds a per-profile session lock (keyed by JobId) so two servers can't
	load and save the same player's data at once. This is a minimal
	hand-rolled version of the session-locking pattern - not a full
	ProfileService-style library.
]]

local DataStoreService = game:GetService("DataStoreService")

local PlayerProfileStore = {}

local store = DataStoreService:GetDataStore("PlayerProfile_v1")

local RETRY_COUNT = 5
local RETRY_BACKOFF_SECONDS = { 1, 2, 4, 8, 16 }
local LOCK_TIMEOUT_SECONDS = 30 * 60

local function withRetry(fn: () -> any)
	local lastError

	for attempt = 1, RETRY_COUNT do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end

		lastError = result
		if attempt < RETRY_COUNT then
			task.wait(RETRY_BACKOFF_SECONDS[attempt])
		end
	end

	return false, lastError
end

local function key(userId: number): string
	return "Player_" .. userId
end

-- Returns (profile, error). profile is nil if the load failed or another
-- live server still holds the lock.
function PlayerProfileStore.Load(userId: number, defaultData: { [string]: any })
	local ok, result = withRetry(function()
		return store:UpdateAsync(key(userId), function(existing)
			local data = existing or table.clone(defaultData)

			local lock = data.__Lock
			local now = os.time()
			if lock and lock.JobId ~= game.JobId and (now - lock.LockedAt) < LOCK_TIMEOUT_SECONDS then
				error("locked_by_other_server")
			end

			data.__Lock = { JobId = game.JobId, LockedAt = now }
			return data
		end)
	end)

	if not ok then
		return nil, result
	end

	local data = table.clone(result)
	data.__Lock = nil
	return data, nil
end

function PlayerProfileStore.Save(userId: number, data: { [string]: any })
	local toSave = table.clone(data)

	local ok, err = withRetry(function()
		store:UpdateAsync(key(userId), function(existing)
			toSave.__Lock = existing and existing.__Lock or nil
			return toSave
		end)
	end)

	return ok, err
end

function PlayerProfileStore.ReleaseLock(userId: number)
	withRetry(function()
		store:UpdateAsync(key(userId), function(existing)
			if existing and existing.__Lock and existing.__Lock.JobId == game.JobId then
				existing.__Lock = nil
			end
			return existing
		end)
	end)
end

return PlayerProfileStore
