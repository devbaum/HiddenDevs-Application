-- Discord Account: dev_baum
-- Roblox Account: xXDRAGONIS_THEBEST
-- Connected Discord-GitHub

local CombatServerManager = {}

-- Services / assets

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local combatFolder = ReplicatedStorage:WaitForChild("Combat")
local animations = combatFolder:WaitForChild("Animations")
local remotes = combatFolder:WaitForChild("Remotes")
local sfx = combatFolder:WaitForChild("SFX")
local fxStorage = combatFolder:WaitForChild("Fx")
local modules = combatFolder:WaitForChild("Modules")
local configuration = combatFolder:WaitForChild("Configuration")

local ragdoll = require(modules:WaitForChild("Ragdoll"))

-- Config cache + tuning values

local BLOCK_ANGLE_THRESHOLD = 0.5
local MAX_HIT_RANGE_STUDS = 12
local HIT_DEBOUNCE_SECONDS = 0.05
local FX_LIFETIME_SECONDS = 2.0

-- Cache attributes instead of calling GetAttribute per hit
local CachedConfig = {
	M1_Damage = configuration:GetAttribute("M1_Damage"),
	Stun_Time = configuration:GetAttribute("Stun_Time"),
	Ragdoll = configuration:GetAttribute("Ragdoll"),
	Ragdoll_Duration = configuration:GetAttribute("Ragdoll_Duration"),
}

configuration.AttributeChanged:Connect(function(attributeName)
	CachedConfig[attributeName] = configuration:GetAttribute(attributeName)
end)

-- attackerId_targetId -> last hit time, so we can debounce spam hits
local recentHitPairs: { [string]: number } = {}

-- Anti-exploit

local function IsValidTarget(targetCharacter: Model?): boolean
	if not targetCharacter then
		return false
	end

	local humanoid = targetCharacter:FindFirstChild("Humanoid") :: Humanoid?
	local root = targetCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root then
		return false
	end

	if humanoid.Health <= 0 then
		return false
	end

	return true
end

-- Main exploit check
local function IsWithinStrikingRange(attackerRoot: BasePart, targetRoot: BasePart): boolean
	local distance = (attackerRoot.Position - targetRoot.Position).Magnitude
	return distance <= MAX_HIT_RANGE_STUDS
end

-- Stops the same swing being reported twice (remote spam)
local function PassesDebounce(attacker: Player, targetCharacter: Model): boolean
	local key = tostring(attacker.UserId) .. "_" .. tostring(targetCharacter)
	local lastHitTime = recentHitPairs[key]
	local now = os.clock()

	if lastHitTime and (now - lastHitTime) < HIT_DEBOUNCE_SECONDS then
		return false
	end

	recentHitPairs[key] = now
	return true
end

-- Block state

function CombatServerManager.StartBlock(character: Model?)
	if not character then
		return
	end

	if character:FindFirstChild("Block") then
		return
	end

	local blockVal = Instance.new("BoolValue")
	blockVal.Name = "Block"
	blockVal.Parent = character
end

function CombatServerManager.StopBlock(character: Model?)
	if not character then
		return
	end

	local blockVal = character:FindFirstChild("Block")
	if blockVal then
		blockVal:Destroy()
	end
end

-- Blocks the attack if the blocker is blocking and facing the person who hits them

local function HasLineOfSightBlock(attackerRoot: BasePart, targetCharacter: Model, targetRoot: BasePart): boolean
	if not targetCharacter:FindFirstChild("Block") then
		return false
	end

	local directionToAttacker = (attackerRoot.Position - targetRoot.Position).Unit
	local lookVector = targetRoot.CFrame.LookVector

	return directionToAttacker:Dot(lookVector) > BLOCK_ANGLE_THRESHOLD
end

-- helper to play anims and sounds

local function GetAnimator(humanoid: Humanoid): Animator
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator :: Animator
end

local function PlayRandomAnimation(humanoid: Humanoid, animFolder: Instance, speed: number?)
	local candidates = animFolder:GetChildren()
	if #candidates == 0 then
		return
	end

	local chosen = candidates[math.random(1, #candidates)]
	local animator = GetAnimator(humanoid)

	local success, track = pcall(function()
		local loaded = animator:LoadAnimation(chosen :: Animation)
		loaded.Priority = Enum.AnimationPriority.Action4
		loaded:Play()
		if speed then
			loaded:AdjustSpeed(speed)
		end
		return loaded
	end)

	if not success then
		warn("[CombatServerManager] Failed to play animation:", track)
	end
end

local function PlaySound(soundTemplate: Sound, parent: Instance)
	local success, clone = pcall(function()
		local s = soundTemplate:Clone()
		s.Parent = parent
		s:Play()
		return s
	end)

	if success and clone then
		Debris:AddItem(clone, (clone :: Sound).TimeLength)
	end
end

-- Hit / block reactions

local function ApplyBlockReaction(attackerCharacter: Model, targetHumanoid: Humanoid, targetRoot: BasePart, combo: number)
	PlayRandomAnimation(targetHumanoid, animations.Block.Hit)
	PlaySound(sfx.Block, targetRoot)

	-- Punish a blocked combo finisher so people cant just spam it
	if combo == 4 then
		local stun = Instance.new("BoolValue")
		stun.Name = "Stun"
		stun.Parent = attackerCharacter
		Debris:AddItem(stun, CachedConfig.Stun_Time)
	end
end

local function SpawnHitEffects(targetRoot: BasePart)
	local fxClone = fxStorage.Hit:Clone()
	fxClone.Parent = workspace:WaitForChild("Fx")
	fxClone.CFrame = targetRoot.CFrame

	task.wait(0.01) -- Wait for the clone to replicate

	for _, child in pairs(fxClone:GetDescendants()) do
		if child:IsA("ParticleEmitter") then
			child:Emit(10)
		end
	end

	Debris:AddItem(fxClone, FX_LIFETIME_SECONDS)
end

local function SpawnDamageIndicator(targetCharacter: Model, damage: number, stunTime: number)
	local scriptSource = script:FindFirstChild("DamageIndicator")
	if not scriptSource then
		return
	end

	local dmgIndicator = scriptSource:Clone()
	dmgIndicator.Parent = targetCharacter
	dmgIndicator.ExtentsOffset = Vector3.new((math.random(-10, 10) / 10), 0.5, 0)
	dmgIndicator.Count.Text = "- " .. tostring(damage)

	TweenService:Create(
		dmgIndicator,
		TweenInfo.new(stunTime),
		{ ExtentsOffset = Vector3.new(dmgIndicator.ExtentsOffset.X, 1, 0) }
	):Play()

	Debris:AddItem(dmgIndicator, stunTime)
end

local function SpawnHitHighlight(targetCharacter: Model, stunTime: number)
	local highlight = Instance.new("Highlight")
	highlight.OutlineTransparency = 1
	highlight.FillTransparency = 0
	highlight.FillColor = Color3.new(1, 0, 0)
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = targetCharacter

	TweenService:Create(highlight, TweenInfo.new(stunTime), { FillTransparency = 1 }):Play()
	Debris:AddItem(highlight, stunTime)
end

local function ApplyKnockback(attackerRoot: BasePart, targetCharacter: Model, targetHumanoid: Humanoid, targetRoot: BasePart, combatState: string)
	local velocity = Instance.new("BodyVelocity")
	velocity.MaxForce = Vector3.new(1, 1, 1) * math.huge

	local function ragdollOrFallbackAnimation()
		if CachedConfig.Ragdoll == true then
			task.spawn(function()
				ragdoll.Start(targetCharacter, CachedConfig.Ragdoll_Duration)
			end)
		else
			PlayRandomAnimation(targetHumanoid, animations.Dash.Back, 1.5)
		end
	end

	if combatState == "land" then
		velocity.Velocity = attackerRoot.CFrame.LookVector * 35
		velocity.Parent = targetRoot
		Debris:AddItem(velocity, 0.4)
		ragdollOrFallbackAnimation()
	elseif combatState == "air" then
		velocity.Velocity = (attackerRoot.CFrame.LookVector * 10) + Vector3.new(0, 35, 0)
		velocity.Parent = targetRoot
		Debris:AddItem(velocity, 0.15)

		if CachedConfig.Ragdoll == true then
			task.spawn(function()
				ragdoll.Start(targetCharacter, CachedConfig.Ragdoll_Duration)
			end)
		else
			velocity:Destroy()
		end
	else
		velocity:Destroy()
		ragdollOrFallbackAnimation()
	end
end

local function ApplyDamageReaction(attackerCharacter: Model, attackerRoot: BasePart, targetCharacter: Model, targetHumanoid: Humanoid, targetRoot: BasePart, damage: number, stunTime: number, combo: number, combatState: string)
	targetHumanoid:TakeDamage(damage)

	local targetStun = Instance.new("BoolValue")
	targetStun.Name = "Stun"
	targetStun.Parent = targetCharacter
	Debris:AddItem(targetStun, stunTime)

	PlaySound(sfx.Hit, targetRoot)
	SpawnHitEffects(targetRoot)
	SpawnDamageIndicator(targetCharacter, damage, stunTime)
	SpawnHitHighlight(targetCharacter, stunTime)

	if combo == 4 then
		ApplyKnockback(attackerRoot, targetCharacter, targetHumanoid, targetRoot, combatState)
	else
		PlayRandomAnimation(targetHumanoid, animations.Hits)
	end
end


function CombatServerManager.ProcessHit(
	attacker: Player,
	attackerCharacter: Model,
	targetCharacter: Model,
	damage: number,
	stunTime: number,
	combo: number,
	combatState: string
)
	if not attackerCharacter or not targetCharacter then
		return
	end

	if not attackerCharacter:FindFirstChild("HumanoidRootPart") then
		return
	end

	if not IsValidTarget(targetCharacter) then
		return
	end

	local targetHumanoid = targetCharacter.Humanoid :: Humanoid
	local targetRoot = targetCharacter.HumanoidRootPart :: BasePart
	local attackerRoot = attackerCharacter.HumanoidRootPart :: BasePart

	if targetCharacter:FindFirstChild("Iframe") then
		return
	end

	if not IsWithinStrikingRange(attackerRoot, targetRoot) then
		return
	end

	if not PassesDebounce(attacker, targetCharacter) then
		return
	end

	if HasLineOfSightBlock(attackerRoot, targetCharacter, targetRoot) then
		ApplyBlockReaction(attackerCharacter, targetHumanoid, targetRoot, combo)
		return
	end

	ApplyDamageReaction(attackerCharacter, attackerRoot, targetCharacter, targetHumanoid, targetRoot, damage, stunTime, combo, combatState)
end

local function HandleHitAction(player: Player, character: Model, data: { [string]: any })
	if data.hits and next(data.hits) then
		for _, enemyChar in pairs(data.hits) do
			CombatServerManager.ProcessHit(
				player,
				character,
				enemyChar,
				CachedConfig.M1_Damage,
				CachedConfig.Stun_Time,
				data.combo,
				data.state
			)
		end
	else
		-- Self stun if Missed
		if data.combo == 4 then
			local selfStun = Instance.new("BoolValue")
			selfStun.Name = "Stun"
			selfStun.Parent = character
			Debris:AddItem(selfStun, CachedConfig.Stun_Time)
		end
	end
end

remotes.Combat.OnServerEvent:Connect(function(player: Player, data: { [string]: any })
	local character = player.Character
	if not character then
		return
	end

	if typeof(data) ~= "table" or typeof(data.action) ~= "string" then
		return
	end

	if data.action == "hit" then
		HandleHitAction(player, character, data)
	elseif data.action == "block" then
		CombatServerManager.StartBlock(character)
	elseif data.action == "unblock" then
		CombatServerManager.StopBlock(character)
	elseif data.action == "evasive" then
		ragdoll.Stop(character)
	end
end)

-- Memory Cleanup

game:GetService("Players").PlayerRemoving:Connect(function(player: Player)
	for key in pairs(recentHitPairs) do
		if key:match("^" .. tostring(player.UserId) .. "_") then
			recentHitPairs[key] = nil
		end
	end
end)

return CombatServerManager