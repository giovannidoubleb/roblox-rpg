-- CITY GRIND: bank + player transfers tuning (sections 39, 49). Shared by server and client.

local BankConfig = {}

BankConfig.MIN_TRANSFER = 1
BankConfig.MAX_TRANSFER = 1_000_000
BankConfig.DAILY_SEND_LIMIT = 250_000
BankConfig.DAILY_RECEIVE_LIMIT = 500_000
BankConfig.TRANSFER_COOLDOWN = 10 -- seconds between transfers from one player
BankConfig.MIN_LEVEL_TO_SEND = 5 -- stops fresh alt accounts from farming cash
BankConfig.MIN_ACCOUNT_AGE_DAYS = 3 -- Roblox account age to send (skipped in Studio)
BankConfig.BIG_TRANSFER = 10_000 -- amounts at or above this need a second confirmation
BankConfig.NOTE_MAX = 40 -- characters in an optional transfer note
BankConfig.LEDGER_HOURS = 168 -- hourly income/expense buckets kept (7 days)

return BankConfig
