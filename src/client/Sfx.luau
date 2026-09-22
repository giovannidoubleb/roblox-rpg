--[[
	Tiny SFX helper: plays one of Roblox's built-in rbxasset:// sounds, which
	ship with the engine and always work with no owned asset id needed - so
	hit/loot/level-up feedback works before any real SFX are made.
]]

local SoundService = game:GetService("SoundService")

local Sfx = {}

Sfx.Ids = {
	Hit = "rbxasset://sounds/impact_water.mp3",
	Loot = "rbxasset://sounds/electronicpingshort.wav",
	LevelUp = "rbxasset://sounds/bell.wav",
	QuestComplete = "rbxasset://sounds/bell.wav",
	UltimateReady = "rbxasset://sounds/switch.wav",
	Click = "rbxasset://sounds/button.wav",
	Death = "rbxasset://sounds/snap.mp3",
}

function Sfx.Play(soundId: string, volume: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 0.5
	sound.Parent = SoundService
	sound:Play()

	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	task.delay(5, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

return Sfx
