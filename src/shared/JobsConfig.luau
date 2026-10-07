-- CITY GRIND: job tuning shared by the server (which pays) and the client
-- (which shows the pay ranges). Sections 40, 68, 77, 110.
-- Every number the phone shows comes from these same functions, so the
-- "$min–$max per shift" a player reads is what the server actually pays.

local JobsConfig = {}

JobsConfig.MAX_LEVEL = 25
JobsConfig.ORDER = { "Delivery", "FoodDelivery", "Taxi", "Warehouse", "Construction", "Security" }

export type Unlock = { level: number, text: string, bonus: number?, extraSteps: number? }
export type JobDef = {
	id: string,
	name: string,
	icon: string,
	color: Color3,
	blurb: string,
	requirement: string,
	stepWord: string, -- "drops", "orders"...
	baseSteps: number,
	stepPay: number, -- average base pay per step at job level 1 (before unlock bonuses)
	stepPayMin: number, -- worst case multiplier of stepPay (short trips / cold food / no combo)
	stepPayMax: number, -- best case multiplier (long trips, tips, full combo)
	completionBonus: number,
	unlocks: { Unlock },
}

local function c(r, g, b)
	return Color3.fromRGB(r, g, b)
end

JobsConfig.JOBS = {
	Delivery = {
		id = "Delivery",
		name = "Delivery",
		icon = "📦",
		color = c(200, 140, 60),
		blurb = "Load parcels at the Depot and drop them on doorsteps around the Neighborhood.",
		requirement = "None",
		stepWord = "drops",
		baseSteps = 4,
		stepPay = 48,
		stepPayMin = 0.8,
		stepPayMax = 1.35,
		completionBonus = 40,
		unlocks = {
			{ level = 3, text = "Fragile parcels pay +10%", bonus = 0.10 },
			{ level = 6, text = "Longer route: +1 drop", extraSteps = 1 },
			{ level = 10, text = "Express clients pay +15%", bonus = 0.15 },
			{ level = 15, text = "Bulk route: +1 drop", extraSteps = 1 },
			{ level = 20, text = "Priority contracts +20%", bonus = 0.20 },
			{ level = 25, text = "Master Courier +25%", bonus = 0.25 },
		},
	},
	FoodDelivery = {
		id = "FoodDelivery",
		name = "Food Delivery",
		icon = "🍔",
		color = c(230, 80, 60),
		blurb = "Grab orders at Mama's Kitchen and deliver them hot. Faster = bigger tip. Foot or wheels.",
		requirement = "None",
		stepWord = "orders",
		baseSteps = 3,
		stepPay = 52,
		stepPayMin = 0.42, -- cold food, short trip
		stepPayMax = 1.75, -- long trip + full tip
		completionBonus = 35,
		unlocks = {
			{ level = 3, text = "Regular customers tip +10%", bonus = 0.10 },
			{ level = 7, text = "Dinner rush: +1 order", extraSteps = 1 },
			{ level = 12, text = "Premium menu pays +15%", bonus = 0.15 },
			{ level = 18, text = "Catering: +1 order", extraSteps = 1 },
			{ level = 25, text = "Five-star driver +30%", bonus = 0.30 },
		},
	},
	Taxi = {
		id = "Taxi",
		name = "Taxi",
		icon = "🚕",
		color = c(245, 200, 40),
		blurb = "Pick up passengers at the curb and drive them across town. Fare is by distance.",
		requirement = "Own a car (drive it to pick up fares)",
		stepWord = "fares",
		baseSteps = 3,
		stepPay = 85,
		stepPayMin = 0.8,
		stepPayMax = 1.4,
		completionBonus = 50,
		unlocks = {
			{ level = 4, text = "Airport rates +10%", bonus = 0.10 },
			{ level = 8, text = "Night shift: +1 fare", extraSteps = 1 },
			{ level = 14, text = "Business clients +20%", bonus = 0.20 },
			{ level = 20, text = "Limo service: +1 fare", extraSteps = 1 },
			{ level = 25, text = "VIP chauffeur +25%", bonus = 0.25 },
		},
	},
	Warehouse = {
		id = "Warehouse",
		name = "Warehouse",
		icon = "🏭",
		color = c(90, 140, 210),
		blurb = "Carry boxes from the shelves to the truck bay. Load quickly to build a combo. Trains Strength.",
		requirement = "None",
		stepWord = "boxes",
		baseSteps = 8,
		stepPay = 26,
		stepPayMin = 1.0, -- no combo
		stepPayMax = 1.5, -- max combo
		completionBonus = 40,
		unlocks = {
			{ level = 3, text = "Forklift cert: +10% per box", bonus = 0.10 },
			{ level = 6, text = "Big orders: +2 boxes", extraSteps = 2 },
			{ level = 12, text = "Shift lead +15%", bonus = 0.15 },
			{ level = 18, text = "Overtime: +2 boxes", extraSteps = 2 },
			{ level = 25, text = "Floor manager +25%", bonus = 0.25 },
		},
	},
	Construction = {
		id = "Construction",
		name = "Construction",
		icon = "🏗️",
		color = c(240, 150, 30),
		blurb = "Haul bricks, planks and beams to the highlighted spots and watch the building rise. Trains Strength.",
		requirement = "None",
		stepWord = "pieces",
		baseSteps = 5,
		stepPay = 44,
		stepPayMin = 1.0,
		stepPayMax = 1.0,
		completionBonus = 50,
		unlocks = {
			{ level = 4, text = "Union card +10%", bonus = 0.10 },
			{ level = 8, text = "Bigger jobs: +1 piece", extraSteps = 1 },
			{ level = 14, text = "Skilled trade +20%", bonus = 0.20 },
			{ level = 20, text = "Site lead: +2 pieces", extraSteps = 2 },
			{ level = 25, text = "Foreman +25%", bonus = 0.25 },
		},
	},
	Security = {
		id = "Security",
		name = "Security",
		icon = "🛡️",
		color = c(70, 90, 140),
		blurb = "Walk the patrol route on foot before time runs out and check out anything suspicious. Trains Stamina and Speed.",
		requirement = "Patrol on foot",
		stepWord = "checkpoints",
		baseSteps = 6,
		stepPay = 30,
		stepPayMin = 1.0,
		stepPayMax = 1.4, -- suspicious checks pay extra
		completionBonus = 45,
		unlocks = {
			{ level = 3, text = "Licensed guard +10%", bonus = 0.10 },
			{ level = 7, text = "Longer patrol: +1 checkpoint", extraSteps = 1 },
			{ level = 12, text = "Night watch +15%", bonus = 0.15 },
			{ level = 18, text = "Extended patrol: +2 checkpoints", extraSteps = 2 },
			{ level = 25, text = "Head of Security +25%", bonus = 0.25 },
		},
	},
} :: { [string]: JobDef }

-- Job XP needed to go from `level` to `level + 1`.
function JobsConfig.xpToNext(level: number): number
	return 50 + 35 * level
end

-- Pay multiplier from job level alone: 1.0 at level 1, 2.8 at level 25.
function JobsConfig.levelMult(level: number): number
	return 1 + (math.clamp(level, 1, JobsConfig.MAX_LEVEL) - 1) * 0.075
end

-- Total pay multiplier (level + unlock bonuses).
function JobsConfig.payMult(jobId: string, level: number): number
	local def = JobsConfig.JOBS[jobId]
	local bonus = 0
	for _, u in def.unlocks do
		if level >= u.level and u.bonus then
			bonus += u.bonus
		end
	end
	return JobsConfig.levelMult(level) * (1 + bonus)
end

-- Steps (drops / orders / boxes...) in one shift at this job level.
function JobsConfig.steps(jobId: string, level: number): number
	local def = JobsConfig.JOBS[jobId]
	local n = def.baseSteps
	for _, u in def.unlocks do
		if level >= u.level and u.extraSteps then
			n += u.extraSteps
		end
	end
	return n
end

-- Base pay for one step before the per-step factor (distance, tip, combo...).
function JobsConfig.stepPay(jobId: string, level: number): number
	return JobsConfig.JOBS[jobId].stepPay * JobsConfig.payMult(jobId, level)
end

function JobsConfig.completionBonus(jobId: string, level: number): number
	return math.floor(JobsConfig.JOBS[jobId].completionBonus * JobsConfig.payMult(jobId, level))
end

-- What a full shift pays at this level: (min, max).
function JobsConfig.payRange(jobId: string, level: number): (number, number)
	local def = JobsConfig.JOBS[jobId]
	local steps = JobsConfig.steps(jobId, level)
	local per = JobsConfig.stepPay(jobId, level)
	local bonus = JobsConfig.completionBonus(jobId, level)
	local low = math.floor(steps * per * def.stepPayMin + bonus)
	local high = math.floor(steps * per * def.stepPayMax + bonus)
	-- round to a tidy $5
	return math.floor(low / 5) * 5, math.ceil(high / 5) * 5
end

-- Rewards per completed step / per finished shift.
JobsConfig.JOB_XP_PER_STEP = 12
JobsConfig.JOB_XP_SHIFT_BONUS = 25
JobsConfig.PLAYER_XP_PER_STEP = 8
JobsConfig.PLAYER_XP_SHIFT_BONUS = 25
JobsConfig.REP_PER_SHIFT = 3

-- Vehicle kinds that are NOT cars (anything else that is non-empty counts as a car).
JobsConfig.NON_CAR_KINDS = { [""] = true, Bike = true, Scooter = true, Motorcycle = true }

function JobsConfig.isCarKind(kind: any): boolean
	return type(kind) == "string" and not JobsConfig.NON_CAR_KINDS[kind]
end

-- Fixed start locations (also used for the phone's GPS button).
JobsConfig.START = {
	Delivery = Vector3.new(-140, 3, 150),
	FoodDelivery = Vector3.new(86, 3, 36),
	Taxi = Vector3.new(-40, 3, -30),
	Warehouse = Vector3.new(85, 3, 150),
	Construction = Vector3.new(175, 3, 149),
	Security = Vector3.new(-40, 3, -30),
}
JobsConfig.START_NAMES = {
	Delivery = "Delivery Depot",
	FoodDelivery = "Mama's Kitchen counter",
	Taxi = "Job Center taxi rank",
	Warehouse = "Warehouse",
	Construction = "Construction Site",
	Security = "Job Center",
}
JobsConfig.JOB_CENTER = Vector3.new(-40, 0, -48)

return JobsConfig
