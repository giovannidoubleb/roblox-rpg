--[[
	Thin DataStore wrapper: retries transient failures with backoff, and
	holds a per-profile session lock (keyed by JobId) so two servers can't
	load and save the same player's data at once. This is a minimal
	hand-rolled version of the session-locking pattern - not a full
	ProfileService-style library.

	DataStores are unavailable in an unpublished place opened directly in
	Studio (no "Enable Studio Access to API Services" toggle to flip yet -
	there's nothing published to flip it on), which used to throw here at
	require-time and take the whole server script down with it. Both the
	store construction and every load/save now degrade to an in-memory-only
	profile instead of erroring, so the game is always playable; only a
	genuine cross-server lock conflict still blocks a load, and every other
	failure just skips that persistence read/write for the sake of
	playability.
]]

local DataStoreService = game:GetService("DataStoreService")

local PlayerProfileStore = {}

local storeOk, storeOrError = pcall(function()
	return DataStoreService:GetDataStore("PlayerProfile_v1")
end)
local store = storeOk and storeOrError or nil
if not storeOk then
	warn(("[PlayerProfileStore] DataStore unavailable (%s); running without persistence."):format(tostring(storeOrError)))
end

local RETRY_COUNT = 5
local RETRY_BACKOFF_SECONDS = { 1, 2, 4, 8, 16 }
local LOCK_TIMEOUT_SECONDS = 30 * 60

-- "API access isn't enabled for this place" (the default for an unpublished
-- place opened directly in Studio) is permanent for this session, not a
-- transient blip - retrying it just makes every player wait up to ~31s
-- before falling back to an in-memory profile, so fail fast on it instead.
local function isApiUnavailable(err): boolean
	return typeof(err) == "string" and (err:find("API [Ss]ervices") ~= nil or err:find("must be published") ~= nil)
end

local function withRetry(fn: () -> any)
	local lastError

	for attempt = 1, RETRY_COUNT do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end

		lastError = result
		if isApiUnavailable(result) then
			break
		end
		if attempt < RETRY_COUNT then
			task.wait(RETRY_BACKOFF_SECONDS[attempt])
		end
	end

	return false, lastError
end

local function key(userId: number): string
	return "Player_" .. userId
end

-- Returns (profile, error). profile is nil only when another live server
-- still holds the lock; any other failure (including no DataStore access)
-- degrades to a fresh in-memory profile rather than blocking the player.
function PlayerProfileStore.Load(userId: number, defaultData: { [string]: any })
	if not store then
		return table.clone(defaultData), nil
	end

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
		if typeof(result) == "string" and result:find("locked_by_other_server") then
			return nil, result
		end

		warn(("[PlayerProfileStore] Load failed for %d, continuing without persistence for this session: %s"):format(userId, tostring(result)))
		return table.clone(defaultData), nil
	end

	local data = table.clone(result)
	data.__Lock = nil
	return data, nil
end

function PlayerProfileStore.Save(userId: number, data: { [string]: any })
	if not store then
		return true, nil
	end

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
	if not store then
		return
	end

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
