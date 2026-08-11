-- Discord Account: dev_baum
-- Roblox Account: xXDRAGONIS_THEBEST
-- Connected Discord-GitHub

--[=[
    =======================================================================================
    UNIFIED COMBAT SERVER FRAMEWORK
    
    Architected by: dev_baum
    Description: Consolidates the game's server-side combat systems (Hit Registration, 
                 Blocking Mechanisms, and Network Request Routing) into a single module.
                 Eliminates nested redundancies, ensures optimal thread utilization,
                 and utilizes clean object-oriented methodology.
    =======================================================================================
--]=]

local CombatServerManager = {}

--[=[
    =======================================================================================
    1. DEPENDENCIES & SERVICES
    =======================================================================================
--]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris") -- Used for reliable, leak-free object cleanup

-- Asset Repository Structures
local combatFolder = ReplicatedStorage:WaitForChild("Combat")
local animations = combatFolder:WaitForChild("Animations")
local remotes = combatFolder:WaitForChild("Remotes")
local sfx = combatFolder:WaitForChild("SFX")
local fxStorage = combatFolder:WaitForChild("Fx")
local modules = combatFolder:WaitForChild("Modules")
local configuration = combatFolder:WaitForChild("Configuration")

-- Lazy-loading external components to ensure safe script compilation bounds
local ragdoll = require(modules:WaitForChild("Ragdoll"))

--[=[
    =======================================================================================
    2. CORE SYSTEM FUNCTIONS
    =======================================================================================
--]=]

-- Handles the safe addition of a blocking state instance on a target character
function CombatServerManager.StartBlock(character: Model)
	if not character then return end
	local blockVal = Instance.new("BoolValue")
	blockVal.Name = "Block"
	blockVal.Parent = character
end

-- Safely cleans up the blocking state instance from a target character
function CombatServerManager.StopBlock(character: Model)
	if not character then return end
	local blockVal = character:FindFirstChild("Block")
	if blockVal then
		blockVal:Destroy()
	end
end

-- Processes mathematical directional blocking validation and applies hit damage/effects
function CombatServerManager.ProcessHit(attackerCharacter: Model, targetCharacter: Model, damage: number, stunTime: number, combo: number, combatState: string)
	-- Absolute validation checks to prevent runtime breaks on missing objects
	if not attackerCharacter or not targetCharacter then return end
	if not targetCharacter:FindFirstChild("Humanoid") or not targetCharacter:FindFirstChild("HumanoidRootPart") then return end
	if not attackerCharacter:FindFirstChild("HumanoidRootPart") then return end

	local targetHumanoid = targetCharacter.Humanoid
	local targetRoot = targetCharacter.HumanoidRootPart
	local attackerRoot = attackerCharacter.HumanoidRootPart

	-- If the target possesses an active Iframe status, terminate calculations early
	if targetCharacter:FindFirstChild("Iframe") then return end

	-- Directional Blocking Logic via Vector Dot Product calculations
	if targetCharacter:FindFirstChild("Block") then
		local directionToAttacker = (attackerRoot.Position - targetRoot.Position).Unit
		local lookVector = targetRoot.CFrame.LookVector

		-- Evaluates if the attacker is hitting the front-facing arc (> 0.5) of the defender
		if directionToAttacker:Dot(lookVector) > 0.5 then
			local blockAnims = animations.Block.Hit:GetChildren()
			local randomAnim = blockAnims[math.random(1, #blockAnims)]

			local load = targetHumanoid:LoadAnimation(randomAnim)
			load.Priority = Enum.AnimationPriority.Action4
			load:Play()

			local sfxClone = sfx.Block:Clone()
			sfxClone.Parent = targetRoot
			sfxClone:Play()
			Debris:AddItem(sfxClone, sfxClone.TimeLength) -- Automatically frees sound memory instances

			if combo == 4 then
				local stun = Instance.new("BoolValue")
				stun.Name = "Stun"
				stun.Parent = attackerCharacter
				Debris:AddItem(stun, stunTime)
			end
			return
		end
	end

	-- Apply Damage directly to the humanoid object
	targetHumanoid:TakeDamage(damage)

	-- Apply runtime Stun tracking attribute object
	local targetStun = Instance.new("BoolValue")
	targetStun.Name = "Stun"
	targetStun.Parent = targetCharacter
	Debris:AddItem(targetStun, stunTime)

	-- Instantiate visual sound and hit particle effects
	local sfxClone = sfx.Hit:Clone()
	sfxClone.Parent = targetRoot
	sfxClone:Play()
	Debris:AddItem(sfxClone, sfxClone.TimeLength)

	local fxClone = fxStorage.Hit:Clone()
	fxClone.Parent = workspace:WaitForChild("Fx")
	fxClone.CFrame = targetRoot.CFrame

	-- Micro-wait optimization to allow physical workspace parenting properties to finalize
	task.wait(0.01)
	for _, child in pairs(fxClone:GetDescendants()) do
		if child:IsA("ParticleEmitter") then
			child:Emit(10)
		end
	end
	Debris:AddItem(fxClone, 2.0)

	-- Create damage numbers layout overlaying the target
	local scriptSource = script:FindFirstChild("DamageIndicator")
	if scriptSource then
		local dmgIndicator = scriptSource:Clone()
		dmgIndicator.Parent = targetCharacter
		dmgIndicator.ExtentsOffset = Vector3.new((math.random(-10, 10) / 10), 0.5, 0)
		dmgIndicator.Count.Text = "- " .. tostring(damage)

		TweenService:Create(dmgIndicator, TweenInfo.new(stunTime), {ExtentsOffset = Vector3.new(dmgIndicator.ExtentsOffset.X, 1, 0)}):Play()
		Debris:AddItem(dmgIndicator, stunTime)
	end

	-- Instantiate color flashes over the model parts to improve action visibility
	local highlight = Instance.new("Highlight")
	highlight.OutlineTransparency = 1
	highlight.FillTransparency = 0
	highlight.FillColor = Color3.new(1, 0, 0)
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = targetCharacter

	TweenService:Create(highlight, TweenInfo.new(stunTime), {FillTransparency = 1}):Play()
	Debris:AddItem(highlight, stunTime)

	-- Combo completion velocity mechanics and Ragdoll executions
	if combo == 4 then
		local velocity = Instance.new("BodyVelocity")
		velocity.MaxForce = Vector3.new(1, 1, 1) * math.huge

		if combatState == "land" then
			velocity.Velocity = attackerRoot.CFrame.LookVector * 35
			velocity.Parent = targetRoot
			Debris:AddItem(velocity, 0.4)

			if configuration:GetAttribute("Ragdoll") == true then
				task.spawn(function()
					ragdoll.Start(targetCharacter, configuration:GetAttribute("Ragdoll_Duration"))
				end)
			else
				local load = targetHumanoid:LoadAnimation(animations.Dash.Back)
				load.Priority = Enum.AnimationPriority.Action4
				load:Play()
				load:AdjustSpeed(1.5)
			end

		elseif combatState == "air" then
			velocity.Velocity = (attackerRoot.CFrame.LookVector * 10) + Vector3.new(0, 35, 0)
			velocity.Parent = targetRoot
			Debris:AddItem(velocity, 0.15)

			if configuration:GetAttribute("Ragdoll") == true then
				task.spawn(function()
					ragdoll.Start(targetCharacter, configuration:GetAttribute("Ragdoll_Duration"))
				end)
			end
		else
			-- Defaults execution fallback if no airborne or landing flags match
			if configuration:GetAttribute("Ragdoll") == true then
				task.spawn(function()
					ragdoll.Start(targetCharacter, configuration:GetAttribute("Ragdoll_Duration"))
				end)
			else
				local load = targetHumanoid:LoadAnimation(animations.Dash.Back)
				load.Priority = Enum.AnimationPriority.Action4
				load:Play()
				load:AdjustSpeed(1.5)
			end
		end
	else
		-- Regular combo hit animations variations logic
		local hitAnims = animations.Hits:GetChildren()
		if #hitAnims > 0 then
			local load = targetHumanoid:LoadAnimation(hitAnims[math.random(1, #hitAnims)])
			load.Priority = Enum.AnimationPriority.Action4
			load:Play()
		end
	end
end

--[=[
    =======================================================================================
    3. NETWORK INTERFACE INITIALIZATION
    =======================================================================================
--]=]

-- Establish singular global event processing logic loop for player inputs
remotes.Combat.OnServerEvent:Connect(function(player, data)
	local character = player.Character
	if not character then return end

	if data.action == "hit" then
		if data.hits and next(data.hits) then
			-- Iterate through valid collected targets
			for _, enemyChar in pairs(data.hits) do
				CombatServerManager.ProcessHit(
					character, 
					enemyChar, 
					configuration:GetAttribute("M1_Damage"), 
					configuration:GetAttribute("Stun_Time"), 
					data.combo, 
					data.state
				)
			end
		else
			-- Apply self-punishment window if combo 4 missed cleanly
			if data.combo == 4 then
				local selfStun = Instance.new("BoolValue")
				selfStun.Name = "Stun"
				selfStun.Parent = character
				Debris:AddItem(selfStun, configuration:GetAttribute("Stun_Time"))
			end
		end

	elseif data.action == "block" then
		CombatServerManager.StartBlock(character)

	elseif data.action == "unblock" then
		CombatServerManager.StopBlock(character)

	elseif data.action == "evasive" then
		ragdoll.Stop(character)
	end
end)

return CombatServerManager