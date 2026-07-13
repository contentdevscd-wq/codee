-- Discord: code_bro2 | Roblox: banbeens4seeds
-- DataService
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EconomyConfig = require(ReplicatedStorage:WaitForChild("EconomyConfig"))
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Bases = workspace:WaitForChild("Bases")
local ParticleService = require(ServerScriptService:WaitForChild("ParticleService"))
local DumplingToolService = require(ServerScriptService:WaitForChild("DumplingToolService"))
local DS = DataStoreService:GetDataStore("PlayerData_v3")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DiscoveredRemote = Remotes:WaitForChild("BrainrotDiscovered")
local CarShopService = require(ServerScriptService:WaitForChild("CarShopService"))
local EggConfig = require(script.Parent.EggConfig)
local fullyLoaded = {}
local DataService = {}
local loadedData = {}
local playerFloorCache = {}
local playerSlotCache = {}
local Tracker = require(game.ServerScriptService:WaitForChild("AnalyticsTracker"))
local alreadySaved = {}
local OfflineIncomeUpdate = Remotes:FindFirstChild("OfflineIncomeUpdate")
	or Instance.new("RemoteEvent", Remotes)
OfflineIncomeUpdate.Name = "OfflineIncomeUpdate"
local RequestOfflineIncome = Remotes:FindFirstChild("RequestOfflineIncome")
	or Instance.new("RemoteEvent", Remotes)
RequestOfflineIncome.Name = "RequestOfflineIncome"
local NotificationService = require(ReplicatedStorage:WaitForChild("NotificationService"))

local FLOOR_CONTAINERS = {
	[2] = "SecondFloor",
	[3] = "ThirdFloor",
	[4] = "FourthFloor",
}

local function migrateEconomyData(data)
	if type(data) ~= "table" then return data end
	local savedVersion = tonumber(data.EconomyVersion) or 1
	if savedVersion >= EconomyConfig.Version then
		return data
	end
	if savedVersion < 2 then
		local function migrateEntry(entry)
			if type(entry) ~= "table" or entry.Type ~= "Brainrot" then return end
			local oldIncome = tonumber(entry.Income)
			if not oldIncome then return end
			entry.Income = math.max(1, math.floor(oldIncome * EconomyConfig.LegacyIncomeScale))
			entry.Level = math.max(1, math.floor(tonumber(entry.Level) or 1))
			entry.Cost = EconomyConfig.GetDumplingUpgradeCost(entry.Level, entry.Income, entry.Cost)
		end
		for _, entry in pairs(data.PlacedSlots or {}) do
			migrateEntry(entry)
		end
		for _, entry in ipairs(data.Backpack or {}) do
			migrateEntry(entry)
		end
	end
	data.EconomyVersion = EconomyConfig.Version
	return data
end

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local function applyFloatTween(brainrot)
	if not brainrot then return end
	if brainrot:GetAttribute("FloatActive") then return end
	brainrot:SetAttribute("FloatActive", true)
	for _, p in ipairs(brainrot:GetDescendants()) do
		if p:IsA("BasePart") then p.Anchored = true end
	end
	task.spawn(function()
		local timeout = 0
		while not brainrot:IsDescendantOf(workspace) and timeout < 5 do
			task.wait(0.1); timeout += 0.1
		end
		if not brainrot:IsDescendantOf(workspace) then return end
		local baseCF = brainrot:GetPivot()
		local baseRotation = baseCF - baseCF.Position
		local t = 0

		local MAIN_SPEED = 2.0
		local MICRO_SPEED = 2.4
		local ROT_SPEED = 1
		local FLOAT_DIST = 0.5
		local ROT_STRENGTH = 0.2 -- Radians

		local connection
		connection = RunService.Heartbeat:Connect(function(deltaTime)
			if not brainrot or not brainrot.Parent then
				connection:Disconnect()
				return
			end
			t += deltaTime

			local offsetY = (math.sin(t * MAIN_SPEED) * FLOAT_DIST) + (math.sin(t * MICRO_SPEED) * 0.05)

			local rotY = (math.sin(t * ROT_SPEED) * ROT_STRENGTH) + (math.cos(t * (ROT_SPEED * 0.7)) * 0.05)
			local spinOffset = brainrot:GetAttribute("SpinOffset") or 0
			local faceOffset = brainrot:GetAttribute("DumplingFaceOffset") or brainrot:GetAttribute("FaceOffset") or 0
			if brainrot:GetAttribute("Dumpling") then
				rotY = 0
			end

			local newPos = baseCF.Position + Vector3.new(0, offsetY, 0)
			local newRot = baseRotation * CFrame.Angles(0, rotY + faceOffset + spinOffset, 0)
			brainrot:PivotTo(CFrame.new(newPos) * newRot)
		end)
	end)
end

-- Helpers
local function getBase(player)
	local assignedBase = player:GetAttribute("AssignedBase")
	if not assignedBase then return nil end
	return Bases:FindFirstChild(assignedBase)
end

local function safeGet(userId)
	local success, result = pcall(function()
		return DS:GetAsync("User_" .. tostring(userId))
	end)
	if not success then
		warn("[DataService] GetAsync FAILED for", userId, result)
		return nil, true
	end
	return result, false
end

local function safeSet(userId, data)
	if type(data) ~= "table" then
		return false
	end
	data.Cash = tonumber(data.Cash) or 0
	if data.Cash < 0 then
		data.Cash = 0
	end
	for attempt = 1, 3 do
		local success, err = pcall(function()
			DS:UpdateAsync("User_" .. tostring(userId), function(oldData)

				if not data or data.Cash == nil then return nil end -- nil = abort save
				return data
			end)
		end)
		if success then
			print("[DataService] SUCCESSFULLY wrote to Cloud for " .. userId)
			return true
		end
		warn("[DataService] UpdateAsync attempt " .. attempt .. " failed for", userId, err)
		if attempt < 3 then task.wait(1) end
	end
	return false
end

local function formatNumber(num)
	if num >= 1e15 then return string.format("%.1fQa", num/1e15):gsub("%.0","")
	elseif num >= 1e12 then return string.format("%.1fT", num/1e12):gsub("%.0","")
	elseif num >= 1e9 then return string.format("%.1fB", num/1e9):gsub("%.0","")
	elseif num >= 1e6 then return string.format("%.1fM", num/1e6):gsub("%.0","")
	elseif num >= 1000 then return string.format("%.1fK", num/1000):gsub("%.0","")
	else return tostring(math.floor(num)) end
end

-- Cache API
function DataService.CacheFloor(player, floorNum, unlockedPods)
	local uid = player.UserId
	if not playerFloorCache[uid] then
		playerFloorCache[uid] = { HasSecondFloor = false, HasThirdFloor = false, HasFourthFloor = false, UnlockedPods = {} }
	end
	if floorNum == 2 then playerFloorCache[uid].HasSecondFloor = true end
	if floorNum == 3 then playerFloorCache[uid].HasThirdFloor = true end
	if floorNum == 4 then playerFloorCache[uid].HasFourthFloor = true end
	playerFloorCache[uid].UnlockedPods = unlockedPods or {}
end

function DataService.CacheSlot(player, slotName, entryOrNil)
	local uid = player.UserId
	if not playerSlotCache[uid] then playerSlotCache[uid] = {} end
	if entryOrNil then
		playerSlotCache[uid][slotName] = entryOrNil
	else
		playerSlotCache[uid][slotName] = nil
	end
	local totalIncome = 0
	for _, entry in pairs(playerSlotCache[uid]) do
		if entry.Type == "Brainrot" and entry.Income then
			totalIncome += entry.Income
		end
	end
	OfflineIncomeUpdate:FireClient(player, math.floor(totalIncome * 86400 * 0.005))
end

-- Collect
local function collectBackpack(player)
	local saved = {}
	local backpack = player:FindFirstChild("Backpack")
	local character = player.Character
	local allTools = {}
	if backpack then
		for _, t in ipairs(backpack:GetChildren()) do
			if t:IsA("Tool") then table.insert(allTools, t) end
		end
	end
	if character then
		local held = character:FindFirstChildOfClass("Tool")
		if held then table.insert(allTools, held) end
	end
	for _, tool in ipairs(allTools) do
		local entry = {}
		local eggName = tool:GetAttribute("EggName")
		if eggName then
			entry.Type = "Egg"
			entry.Name = tool.Name
			entry.EggName = eggName
		else
			entry.Type = "Brainrot"
			entry.Name = tool.Name
			entry.Material = tool:GetAttribute("Material") or "Normal"
			entry.Rarity = tool:GetAttribute("Rarity")
			entry.Level = tool:GetAttribute("Level")
			entry.Income = tool:GetAttribute("Income")
			entry.Cost = tool:GetAttribute("Cost")
			entry.IsPlacedBrainrot = tool:GetAttribute("IsPlacedBrainrot") or false
			entry.Mutation = tool:GetAttribute("Mutation")
		end
		entry.SlotNumber = tool:GetAttribute("SlotNumber")
		entry.InInventory = tool:GetAttribute("InInventory") or false
		table.insert(saved, entry)
	end
	return saved
end

local function collectSlots(player)
	local uid = player.UserId
	local base = getBase(player)
	if not base then
		return playerSlotCache[uid] or {}
	end
	local saved = {}
	local function scanSlotFolder(folder)
		if not folder then return end
		for _, slot in ipairs(folder:GetChildren()) do
			if not slot.Name:find("Slot") then continue end
			local itemData = nil
			for _, child in ipairs(slot:GetChildren()) do
				if child:IsA("Model") and child:GetAttribute("IsPlacedBrainrot") then
					itemData = {
						Type = "Brainrot",
						Name = child.Name,
						Material = child:GetAttribute("Material"),
						Rarity = child:GetAttribute("Rarity"),
						Level = child:GetAttribute("Level"),
						Income = child:GetAttribute("Income"),
						Cost = child:GetAttribute("Cost"),
						Mutation = child:GetAttribute("Mutation"),
					}
					break
				end
			end
			if not itemData then
				for _, child in ipairs(slot:GetChildren()) do
					if child:IsA("Model") and child:GetAttribute("Rarity") then
						itemData = {
							Type = "Egg",
							Name = child.Name,
							EggName = child:GetAttribute("Rarity"),
							Mutation = child:GetAttribute("Mutation"),
							TotalDuration = child:GetAttribute("TotalDuration"),
							HatchReady = child:GetAttribute("HatchReady") or false,
							RemainingTime = math.max(0, (child:GetAttribute("EndTime") or workspace:GetServerTimeNow()) - workspace:GetServerTimeNow()),
						}
						break
					end
				end
			end
			if itemData then
				saved[slot.Name] = itemData
			end
		end
	end
	local eggSlots = base:FindFirstChild("EggSlots")
	if eggSlots then scanSlotFolder(eggSlots) end
	for _, containerName in pairs(FLOOR_CONTAINERS) do
		local container = base:FindFirstChild(containerName)
		if container then scanSlotFolder(container) end
	end
	if next(saved) == nil and playerSlotCache[uid] and next(playerSlotCache[uid]) ~= nil then
		return playerSlotCache[uid]
	end
	playerSlotCache[uid] = saved
	return saved
end

local function collectFloor(player)
	local uid = player.UserId
	local cached = playerFloorCache[uid]
	local base = getBase(player)
	if not base then
		if cached then
			return cached.HasFloor or {}, cached.UnlockedPods or {}
		end
		return {}, {}
	end
	local hasFloor = {}
	local unlockedPods = {}
	for floorNum, containerName in pairs(FLOOR_CONTAINERS) do
		local container = base:FindFirstChild(containerName)
		if container then
			hasFloor[floorNum] = true
			for _, child in ipairs(container:GetChildren()) do
				local num = tonumber(child.Name:match("Slot_(%d+)"))
				if num and num >= 11 then
					table.insert(unlockedPods, num)
				end
			end
		end
	end
	if next(hasFloor) == nil and cached and (cached.HasSecondFloor or cached.HasThirdFloor or cached.HasFourthFloor) then
		local rebuilt = {}
		if cached.HasSecondFloor then rebuilt[2] = true end
		if cached.HasThirdFloor then rebuilt[3] = true end
		if cached.HasFourthFloor then rebuilt[4] = true end
		return rebuilt, cached.UnlockedPods or {}
	end
	playerFloorCache[uid] = {
		HasSecondFloor = hasFloor[2] or false,
		HasThirdFloor = hasFloor[3] or false,
		HasFourthFloor = hasFloor[4] or false,
		UnlockedPods = unlockedPods,
	}
	return hasFloor, unlockedPods
end

local function collectDiscovered(player)
	local list = {}
	for key, val in pairs(player:GetAttributes()) do
		if key:sub(1, 5) == "Disc_" and val == true then
			local brainrotName = key:sub(6)
			table.insert(list, brainrotName)
		end
	end
	return list
end

local function collectUnlockedZones(player)
	local zones = {}
	for key, val in pairs(player:GetAttributes()) do
		if key:sub(1, 13) == "UnlockedZone_" and val == true then
			table.insert(zones, key:sub(14))
		end
	end
	return zones
end

-- Save
function DataService.Save(player)
	local uid = player.UserId
	if not fullyLoaded[uid] then
		-- Player left before full load
		local data = loadedData[uid]
		if data then
			local cachedSlots = playerSlotCache[uid]
			local cachedFloor = playerFloorCache[uid]
			if cachedSlots and next(cachedSlots) ~= nil then
				data.PlacedSlots = cachedSlots
			end
			Tracker.LogReturningPlayer(player)
			if cachedFloor then
				data.HasSecondFloor = cachedFloor.HasSecondFloor or false
				data.HasThirdFloor = cachedFloor.HasThirdFloor or false
				data.HasFourthFloor = cachedFloor.HasFourthFloor or false
				data.UnlockedPods = cachedFloor.UnlockedPods or {}
			end
			data.LastSaveTime = os.time()
			safeSet(uid, data)
			print("[DataService] Early-exit save written for", player.Name)
		else
			print("[DataService] No loadedData for", player.Name, "- skipping save entirely (fresh join)")
		end
		return
	end

	local base = getBase(player)
	if not base then
		warn("[DataService] Save aborted for", player.Name, "- base not found")
		return
	end
	if not player:GetAttribute("AssignedBase") then
		warn("[DataService] Save aborted for", player.Name, "- no AssignedBase")
		return
	end

	local userId = player.UserId
	local cash = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Cash")
	local rebirths = DataService.GetRebirths(player)
	local hasFloor, unlockedPods = collectFloor(player)
	local placedSlots = collectSlots(player)
	local discoveredList = collectDiscovered(player)

	hasFloor = hasFloor or {}
	unlockedPods = unlockedPods or {}
	placedSlots = placedSlots or {}
	discoveredList = discoveredList or {}

	local cached = playerFloorCache[userId]
	local f2 = hasFloor[2] or false
	local f3 = hasFloor[3] or false
	local f4 = hasFloor[4] or false
	if cached then
		f2 = f2 or cached.HasSecondFloor or false
		f3 = f3 or cached.HasThirdFloor or false
		f4 = f4 or cached.HasFourthFloor or false
		if #unlockedPods == 0 and cached.UnlockedPods then
			unlockedPods = cached.UnlockedPods
		end
	end

	local cachedSlots = playerSlotCache[userId]
	if next(placedSlots) == nil and cachedSlots and next(cachedSlots) ~= nil then
		placedSlots = cachedSlots
	end

	f2 = f2 and true or false
	f3 = f3 and true or false
	f4 = f4 and true or false

	playerFloorCache[userId] = {
		HasSecondFloor = f2,
		HasThirdFloor = f3,
		HasFourthFloor = f4,
		UnlockedPods = unlockedPods,
	}
	playerSlotCache[userId] = placedSlots

	local data = {
		EconomyVersion = EconomyConfig.Version,
		Cash = cash and cash.Value or 0,
		Rebirths = rebirths,
		MaxFuel = player:GetAttribute("MaxFuel") or EconomyConfig.BaseEnergy,
		FuelUpgradeCount = player:GetAttribute("FuelUpgradeCount") or 0,
		FuelUpgrade_Small = player:GetAttribute("FuelUpgrade_Small") or 0,
		FuelUpgrade_Medium = player:GetAttribute("FuelUpgrade_Medium") or 0,
		FuelUpgrade_Large = player:GetAttribute("FuelUpgrade_Large") or 0,
		CarTier = player:GetAttribute("CarTier") or 1,
		MaxEggs = player:GetAttribute("MaxEggs") or 1,
		UnlockedZones = collectUnlockedZones(player),
		CarShop = CarShopService.GetSaveData(player),
		HasSecondFloor = f2,
		HasThirdFloor = f3,
		HasFourthFloor = f4,
		UnlockedPods = unlockedPods,
		Backpack = collectBackpack(player),
		PlacedSlots = placedSlots,
		Discovered = discoveredList,
		LastSaveTime = os.time(),
	}

	safeSet(userId, data)

	local slotCount = 0
	for _ in pairs(placedSlots) do slotCount += 1 end
	print(string.format("[DataService] Saved %s | F2:%s F3:%s F4:%s | Slots:%d | Disc:%d",
		player.Name, tostring(f2), tostring(f3), tostring(f4), slotCount, #discoveredList))
end

local RARITY_COLORS = {
	Common = Color3.fromRGB(255, 255, 255),
	Uncommon = Color3.fromRGB(85, 255, 127),
	Rare = Color3.fromRGB(85, 170, 255),
	Mythic = Color3.fromRGB(255, 0, 221),
	Secret = Color3.fromRGB(255, 215, 0),
}

local function applyRarityColor(billboard, eggName)
	local color = RARITY_COLORS[eggName]
	if not color then return end
	local label = billboard:FindFirstChildOfClass("TextLabel")
	if label then
		label.TextColor3 = color
	end
end

local function restoreFloor(player, data)
	local base = getBase(player)
	if not base then return end
	local hasFloor = {}
	if data.HasSecondFloor then hasFloor[2] = true end
	if data.HasThirdFloor then hasFloor[3] = true end
	if data.HasFourthFloor then hasFloor[4] = true end
	if not next(hasFloor) then return end

	if hasFloor[2] and not base:FindFirstChild("SecondFloor") then
		local template = ReplicatedStorage:WaitForChild("SecondFloor", 5)
		if template then
			local floor = template:Clone()
			floor.Name = "SecondFloor"
			local spawnPart = base:FindFirstChild("FloorSpawn_2") or base:FindFirstChild("FloorSpawn")
			if spawnPart then floor:PivotTo(spawnPart.CFrame) end
			floor.Parent = base
			local fu = base:FindFirstChild("FloorUpgrade")
			if fu then fu:Destroy() end
		end
	end

	if hasFloor[3] and not base:FindFirstChild("ThirdFloor") then
		local template = ReplicatedStorage:WaitForChild("ThirdFloor", 5)
		if template then
			local floor = template:Clone()
			floor.Name = "ThirdFloor"
			local spawnPart = base:FindFirstChild("FloorSpawn_3")
			if spawnPart then floor:PivotTo(spawnPart.CFrame) end
			floor.Parent = base
			local sf = base:FindFirstChild("SecondFloor")
			local fu3 = sf and sf:FindFirstChild("FloorUpgrade_3")
			if fu3 then fu3:Destroy() end
		end
	end

	if hasFloor[4] and not base:FindFirstChild("FourthFloor") then
		local template = ReplicatedStorage:WaitForChild("FourthFloor", 5)
		if template then
			local floor = template:Clone()
			floor.Name = "FourthFloor"
			local spawnPart = base:FindFirstChild("FloorSpawn_4")
			if spawnPart then floor:PivotTo(spawnPart.CFrame) end
			floor.Parent = base
			local tf = base:FindFirstChild("ThirdFloor")
			local fu4 = tf and tf:FindFirstChild("FloorUpgrade_4")
			if fu4 then fu4:Destroy() end
		end
	end

	local podsToRestore = data.UnlockedPods or {}
	playerFloorCache[player.UserId] = {
		HasSecondFloor = hasFloor[2] or false,
		HasThirdFloor = hasFloor[3] or false,
		HasFourthFloor = hasFloor[4] or false,
		UnlockedPods = podsToRestore,
	}

	task.delay(0.5, function()
		local RestoreFloorEvent = ReplicatedStorage:FindFirstChild("RestoreFloor")
		if RestoreFloorEvent then
			print("[RESTORE] Firing RestoreFloor for " .. player.Name .. " with " .. #podsToRestore .. " pods.")
			RestoreFloorEvent:Fire(base, podsToRestore)
		else
			warn("[RESTORE] Could not find RestoreFloor BindableEvent!")
		end
	end)
end

-- restoreBackpack
local function restoreBackpack(player, backpackData)
	if not backpackData then return end
	local backpack = player:WaitForChild("Backpack", 10)
	if not backpack then return end
	for _, entry in ipairs(backpackData) do
		if entry.Type == "Egg" then
			local tool = Instance.new("Tool")
			tool.Name = entry.Name
			tool.RequiresHandle = true
			tool.CanBeDropped = false
			tool:SetAttribute("EggName", entry.EggName)
			if entry.Mutation then tool:SetAttribute("Mutation", entry.Mutation) end
			if entry.SlotNumber then tool:SetAttribute("SlotNumber", entry.SlotNumber) end
			if entry.InInventory then tool:SetAttribute("InInventory", true) end
			local eggModels = ReplicatedStorage:FindFirstChild("Eggs")
			local rarityFolder = eggModels and eggModels:FindFirstChild(entry.EggName)
			local eggModelFolder = rarityFolder and rarityFolder:FindFirstChild("EggModel")
			if eggModelFolder then
				local handle, biggestVol = nil, 0
				for _, p in ipairs(eggModelFolder:GetChildren()) do
					if p:IsA("BasePart") then
						local vol = p.Size.X * p.Size.Y * p.Size.Z
						if vol > biggestVol then biggestVol = vol; handle = p end
					end
				end
				if handle then
					local otherParts = {}
					for _, p in ipairs(eggModelFolder:GetChildren()) do
						if p:IsA("BasePart") and p ~= handle then
							table.insert(otherParts, p)
						end
					end
					local handleClone = handle:Clone()
					handleClone.Name = "Handle"
					handleClone.Anchored = false
					handleClone.CanCollide = false
					handleClone.Massless = true
					handleClone.Parent = tool
					for _, p in ipairs(otherParts) do
						local clone = p:Clone()
						clone.Anchored = false
						clone.CanCollide = false
						clone.Massless = true
						local weld = Instance.new("WeldConstraint")
						weld.Part0 = handleClone
						weld.Part1 = clone
						weld.Parent = handleClone
						clone.Parent = tool
					end
				end
			end
			tool.RequiresHandle = true
			tool.Parent = backpack
		elseif entry.Type == "Brainrot" then
			local brainrotFolder = ReplicatedStorage:FindFirstChild("Brainrots")
			if not brainrotFolder then continue end
			local materialFolder = brainrotFolder:FindFirstChild(entry.Material or "Normal")
				or brainrotFolder:FindFirstChild("Normal")
			local template = nil
			if materialFolder then
				for _, rarityFolder in ipairs(materialFolder:GetChildren()) do
					local found = rarityFolder:FindFirstChild(entry.Name)
					if found then template = found; break end
				end
			end
			if not template then
				warn("[RESTORE BACKPACK] Could not find:", entry.Name, "material:", entry.Material)
				continue
			end
			local tool = Instance.new("Tool")
			tool.Name = entry.Name
			tool.RequiresHandle = false
			tool.CanBeDropped = false
			tool:SetAttribute("Material", entry.Material)
			tool:SetAttribute("Rarity", entry.Rarity)
			tool:SetAttribute("Level", entry.Level)
			tool:SetAttribute("Income", entry.Income)
			tool:SetAttribute("Cost", entry.Cost)
			tool:SetAttribute("IsPlacedBrainrot", entry.IsPlacedBrainrot or false)
			if entry.SlotNumber then tool:SetAttribute("SlotNumber", entry.SlotNumber) end
			if entry.InInventory then tool:SetAttribute("InInventory", true) end
			local clone = template:Clone()
			for _, p in ipairs(clone:GetDescendants()) do
				if p:IsA("BasePart") then
					p.Anchored = false
					p.CanCollide = false
					p.Massless = true
				elseif p:IsA("Script") or p:IsA("LocalScript") then
					p.Disabled = true
				elseif p:IsA("ParticleEmitter") or p:IsA("SurfaceGui") or p:IsA("PointLight") then
					p:Destroy()
				end
			end
			for _, child in ipairs(clone:GetChildren()) do
				child.Parent = tool
			end
			clone:Destroy()
			tool.Parent = backpack
		end
	end
end

-- restorePlacedSlots
local function restorePlacedSlots(player, placedData, data)
	if not placedData then return end
	local base = getBase(player)
	if not base then return end
	local eggSlots = base:FindFirstChild("EggSlots")
	if not eggSlots then return end
	local timeAway = os.time() - (data and data.LastSaveTime or os.time())

	local function findSlot(slotName)
		local s = eggSlots:FindFirstChild(slotName)
		if s then return s end
		for _, containerName in pairs(FLOOR_CONTAINERS) do
			local container = base:FindFirstChild(containerName)
			if container then
				s = container:FindFirstChild(slotName)
				if s then return s end
			end
		end
		return nil
	end

	local expectedSlots = {}
	for slotName in pairs(placedData) do table.insert(expectedSlots, slotName) end
	if #expectedSlots > 0 then
		local waited = 0
		while waited < 10 do
			local allFound = true
			for _, slotName in ipairs(expectedSlots) do
				if not findSlot(slotName) then allFound = false; break end
			end
			if allFound then break end
			task.wait(0.5)
			waited += 0.5
		end
	end

	local EggService = require(ServerScriptService:WaitForChild("EggService"))
	local HatchService = require(ServerScriptService:WaitForChild("HatchService"))

	for slotName, entry in pairs(placedData) do
		local slot = findSlot(slotName)
		if not slot then
			print("[RESTORE] Slot not found:", slotName)
			continue
		end
		slot:SetAttribute("IsRestored", true)

		if entry.Type == "Brainrot" then
			local brainrotFolder = ReplicatedStorage:FindFirstChild("Brainrots")
			if not brainrotFolder then continue end
			local materialName = entry.Material or "Normal"
			local materialFolder = brainrotFolder:FindFirstChild(materialName)
				or brainrotFolder:FindFirstChild("Normal")
			local template = materialFolder and materialFolder:FindFirstChild(entry.Name, true)
			if not template then
				template = brainrotFolder:FindFirstChild(entry.Name, true)
			end
			if not template then
				print("[RESTORE] Could not find model:", entry.Name, "in material:", materialName)
				continue
			end
			local brainrot = template:Clone()
			brainrot.Name = entry.Name
			brainrot:SetAttribute("Material", entry.Material)
			brainrot:SetAttribute("Rarity", entry.Rarity)
			brainrot:SetAttribute("Level", entry.Level)
			brainrot:SetAttribute("Income", entry.Income)
			brainrot:SetAttribute("Cost", entry.Cost)
			brainrot:SetAttribute("IsPlacedBrainrot", true)
			if entry.Mutation then brainrot:SetAttribute("Mutation", entry.Mutation) end

			for _, p in ipairs(brainrot:GetDescendants()) do
				if p:IsA("BasePart") then
					p.Anchored = true
					p.CanCollide = false
					p.Massless = false
				end
				if p:IsA("Script") or p:IsA("LocalScript") then p.Disabled = true end
			end
			local hitbox = slot:FindFirstChild("Hitbox")
			if hitbox then
				local _, ry, _ = hitbox.CFrame:ToEulerAnglesYXZ()
				brainrot:PivotTo(CFrame.new(hitbox.Position) * CFrame.Angles(0, ry, 0) * CFrame.new(0, 0.3, 0))
			end
			brainrot.Parent = slot

			task.defer(function()
				local timeout = 0
				while not brainrot:IsDescendantOf(workspace) and timeout < 2 do
					task.wait(0.1); timeout += 0.1
				end
				if not brainrot or not brainrot.Parent then return end
				applyFloatTween(brainrot)
				task.wait(.1)
				local mutation = entry.Mutation
				local MutationService = require(ServerScriptService:WaitForChild("MutationService"))
				if mutation then
					MutationService.ApplyMutationParticle(brainrot, mutation)
					MutationService.ApplyMutationBillboard(brainrot, mutation)
				else
					ParticleService.ApplyParticle(brainrot)
				end
			end)

			slot:SetAttribute("HasBrainrot", true)
			slot:SetAttribute("Income", entry.Income)
			DataService.CacheSlot(player, slotName, entry)

			local hitboxPrompt = hitbox and hitbox:FindFirstChildOfClass("ProximityPrompt")
			if hitboxPrompt then hitboxPrompt.Enabled = false end

			local root = brainrot:FindFirstChildWhichIsA("BasePart", true)
			if root then
				local pickupP = Instance.new("ProximityPrompt")
				pickupP.Name = "PickupPrompt"
				pickupP.ActionText = "Pick Up"
				pickupP.ObjectText = brainrot.Name
				pickupP.RequiresLineOfSight = false
				pickupP.HoldDuration = 1
				pickupP.Style = Enum.ProximityPromptStyle.Custom
				pickupP.MaxActivationDistance = 10
				pickupP.Parent = root

				pickupP.Triggered:Connect(function(plr)
					local ownerVal = base:FindFirstChild("Owner")
					if not ownerVal or ownerVal.Value ~= plr then return end
					if not brainrot or not brainrot.Parent then return end
					pickupP.Enabled = false
					for _, p in ipairs(brainrot:GetDescendants()) do
						if p:IsA("BasePart") then p.Anchored = false; p.CanCollide = false; p.Massless = true end
						if p:IsA("Script") or p:IsA("LocalScript") then p.Disabled = true end
					end
					local t2 = Instance.new("Tool")
					t2.Name = brainrot.Name; t2.RequiresHandle = true; t2.CanBeDropped = false
					for k, v in pairs(brainrot:GetAttributes()) do t2:SetAttribute(k, v) end
					t2:SetAttribute("IsPlacedBrainrot", true)
					for _, child in ipairs(brainrot:GetChildren()) do child.Parent = t2 end
					t2.Parent = plr.Backpack
					DumplingToolService.Prepare(plr, t2)
					brainrot:Destroy()
					slot:SetAttribute("HasBrainrot", false)
					slot:SetAttribute("Income", 0)
					if hitboxPrompt then hitboxPrompt.Enabled = true end
					DataService.CacheSlot(plr, slotName, nil)
					NotificationService.Notify(plr, "Picked up " .. t2.Name .. "!", Color3.fromRGB(255, 255, 255))
				end)
			end

		elseif entry.Type == "Egg" then
			local eggModels = ReplicatedStorage:FindFirstChild("Eggs")
			local rarityFolder = eggModels and eggModels:FindFirstChild(entry.EggName)
			if not rarityFolder then print("[RESTORE] No egg rarity folder for:", entry.EggName); continue end
			local eggModel = rarityFolder:FindFirstChild("EggModel")
			if not eggModel then print("[RESTORE] No EggModel for:", entry.EggName); continue end
			eggModel = eggModel:Clone()
			for _, v in ipairs(eggModel:GetDescendants()) do
				if v:IsA("ParticleEmitter") or v:IsA("SurfaceGui")
					or v:IsA("PointLight") or v:IsA("Attachment") then
					v:Destroy()
				end
			end
			if not eggModel.PrimaryPart then
				local biggest, biggestVol = nil, 0
				for _, v in ipairs(eggModel:GetDescendants()) do
					if v:IsA("BasePart") then
						local vol = v.Size.X * v.Size.Y * v.Size.Z
						if vol > biggestVol then biggestVol = vol; biggest = v end
					end
				end
				eggModel.PrimaryPart = biggest
			end
			if not eggModel.PrimaryPart then continue end
			for _, v in ipairs(eggModel:GetDescendants()) do
				if v:IsA("BasePart") then v.Anchored = true end
			end
			eggModel:SetAttribute("Rarity", entry.EggName)
			if entry.Mutation then eggModel:SetAttribute("Mutation", entry.Mutation) end

			local eggAttachment = Instance.new("Attachment")
			eggAttachment.Name = "EggAttachment"
			eggAttachment.Parent = eggModel.PrimaryPart

			local billboardTemplate = ReplicatedStorage:FindFirstChild("EggAttachment")
				and ReplicatedStorage.EggAttachment:FindFirstChild("BillboardGui")
			if billboardTemplate then
				local billboard = billboardTemplate:Clone()
				applyRarityColor(billboard, entry.EggName)
				billboard.Parent = eggAttachment
			end

			eggModel.Parent = workspace
			local hitbox = slot:FindFirstChild("Hitbox")
			if hitbox then
				local _, size = eggModel:GetBoundingBox()
				local _, slotRy, _ = hitbox.CFrame:ToEulerAnglesYXZ()
				local sourceCF = eggModel.PrimaryPart.CFrame
				local rx, ry, rz = sourceCF:ToEulerAnglesYXZ()
				eggModel:PivotTo(
					CFrame.new(hitbox.Position.X, hitbox.Position.Y + size.Y/2 + 0.3, hitbox.Position.Z)
						* CFrame.Angles(rx, slotRy + ry, rz)
						* CFrame.Angles(math.rad(90), 0, 0)
				)
				local _, attachSize = eggModel:GetBoundingBox()
				eggAttachment.Position = Vector3.new(0, attachSize.Y/2 + 3, 0)
				local hitboxPrompt = hitbox:FindFirstChildOfClass("ProximityPrompt")
				if hitboxPrompt then hitboxPrompt.Enabled = false end
			end
			eggModel.Parent = slot

			if entry.Mutation then
				local MutationService = require(ServerScriptService:WaitForChild("MutationService"))
				MutationService.ApplyMutationBillboard(eggModel, entry.Mutation)
				task.defer(function()
					if eggModel and eggModel.Parent then
						MutationService.ApplyMutationParticle(eggModel, entry.Mutation)
					end
				end)
			end

			slot:SetAttribute("HasBrainrot", true)
			slot:SetAttribute("Income", 0)
			DataService.CacheSlot(player, slotName, entry)

			local remaining = math.max(0, (entry.RemainingTime or entry.TotalDuration or 30) - timeAway)
			local hatchReady = entry.HatchReady or (remaining <= 0)

			if hatchReady then
				eggModel:SetAttribute("HatchReady", true)
				eggModel:SetAttribute("TotalDuration", entry.TotalDuration)
				eggModel:SetAttribute("EndTime", workspace:GetServerTimeNow())
			else
				eggModel:SetAttribute("TotalDuration", entry.TotalDuration)
				eggModel:SetAttribute("EndTime", workspace:GetServerTimeNow() + remaining)
				eggModel:SetAttribute("HatchReady", false)
				EggService.ResumeHatchTimer(player, eggModel, remaining)
			end

			local root = eggModel:FindFirstChildWhichIsA("BasePart", true)
			if root then
				local hatch = Instance.new("ProximityPrompt")
				hatch.ActionText = "Hatch"
				hatch.HoldDuration = 1
				hatch.Style = Enum.ProximityPromptStyle.Custom
				hatch.MaxActivationDistance = 15
				hatch.RequiresLineOfSight = false
				hatch.Enabled = hatchReady
				hatch.Parent = root

				if entry.HatchReady then
					hatch.Enabled = true
					local EggReady = Remotes:FindFirstChild("EggReady")
					if EggReady then EggReady:FireClient(player, eggModel) end
				else
					eggModel:GetAttributeChangedSignal("HatchReady"):Connect(function()
						if not eggModel:GetAttribute("HatchReady") then return end
						hatch.Enabled = true
						local EggReady = Remotes:FindFirstChild("EggReady")
						if EggReady then EggReady:FireClient(player, eggModel) end
					end)
				end

				local eggNameForHatch = entry.EggName
				local slotRef = slot
				local promptRef = slot:FindFirstChild("Hitbox") and slot.Hitbox:FindFirstChildOfClass("ProximityPrompt")

				hatch.Triggered:Connect(function(plr)
					local ownerVal = base:FindFirstChild("Owner")
					if not ownerVal or ownerVal.Value ~= plr then return end
					if not eggModel or not eggModel.Parent then return end
					if not eggModel:GetAttribute("HatchReady") then return end
					hatch:Destroy()
					local QMEffect = Remotes:FindFirstChild("QMEffect") or Instance.new("RemoteEvent", Remotes)
					QMEffect.Name = "QMEffect"
					QMEffect:FireClient(plr, eggModel:GetPivot())
					local tierTable = EggConfig.ZoneEggChances[eggNameForHatch]
					local brainrot, eggToDestroy = HatchService.HatchEgg(plr, eggModel, tierTable)
					if not brainrot then
						warn("[HATCH] Failed to generate brainrot model. Resetting slot.")
						slotRef:SetAttribute("HasBrainrot", false)
						slotRef:SetAttribute("Income", 0)
						if promptRef then promptRef.Enabled = true end
						DataService.CacheSlot(plr, slotName, nil)
						if eggModel then eggModel:Destroy() end
						return
					end
					task.delay(0.1, function()
						if eggToDestroy and eggToDestroy.Parent then eggToDestroy:Destroy() end
					end)
					local material = brainrot:GetAttribute("Material") or "Normal"
					local income = brainrot:GetAttribute("Income") or 0
					local rarity = brainrot:GetAttribute("Rarity") or "Common"
					local hitboxRef = slotRef:FindFirstChild("Hitbox")

					task.delay(6.5, function()
						if not plr or not plr.Parent or not brainrot then return end
						for _, p in ipairs(brainrot:GetDescendants()) do
							if p:IsA("BasePart") then
								p.Anchored = true
								p.CanCollide = false
							end
						end
						brainrot.Parent = slotRef
						task.wait()
						if hitboxRef then
							local _, ry, _ = hitboxRef.CFrame:ToEulerAnglesYXZ()
							brainrot:PivotTo(CFrame.new(hitboxRef.Position) * CFrame.Angles(0, ry, 0) * CFrame.new(0, 0.3, 0))
						end
						NotificationService.Notify(plr, "You hatched " .. brainrot.Name .. "!", RARITY_COLORS[rarity] or Color3.fromRGB(255, 255, 255))
						brainrot:SetAttribute("IsPlacedBrainrot", true)
						slotRef:SetAttribute("Income", income)
						slotRef:SetAttribute("HasBrainrot", true)
						applyFloatTween(brainrot)
						task.wait(.1)
						local mutation = brainrot:GetAttribute("Mutation")
						local MutationService = require(ServerScriptService:WaitForChild("MutationService"))
						local MUTATION_MULTIS = { Smoke=1.25, Windy=1.5, Rocky=1.75, Fire=2.0, Snowy=2.5 }
						if mutation then
							local multi = MUTATION_MULTIS[mutation] or 1
							income = math.floor(income * multi)
							brainrot:SetAttribute("Income", income)
							slotRef:SetAttribute("Income", income)
							MutationService.ApplyMutationParticle(brainrot, mutation)
							MutationService.ApplyMutationBillboard(brainrot, mutation)
						else
							ParticleService.ApplyParticle(brainrot)
						end
						DataService.CacheSlot(plr, slotName, {
							Type = "Brainrot",
							Name = brainrot.Name,
							Material = material,
							Rarity = rarity,
							Level = brainrot:GetAttribute("Level") or 1,
							Income = income,
							Cost = brainrot:GetAttribute("Cost") or 0,
						})
						local root2 = brainrot:FindFirstChildWhichIsA("BasePart", true)
						if root2 then
							local pickupP = Instance.new("ProximityPrompt")
							pickupP.Name = "PickupPrompt"
							pickupP.ActionText = "Pick Up"
							pickupP.ObjectText = brainrot.Name
							pickupP.RequiresLineOfSight = false
							pickupP.HoldDuration = 1
							pickupP.Style = Enum.ProximityPromptStyle.Custom
							pickupP.MaxActivationDistance = 10
							pickupP.Parent = root2
							pickupP.Triggered:Connect(function(p2)
								local ov = base:FindFirstChild("Owner")
								if not ov or ov.Value ~= p2 then return end
								if not brainrot or not brainrot.Parent then return end
								pickupP.Enabled = false
								local t2 = Instance.new("Tool")
								t2.Name = brainrot.Name; t2.RequiresHandle = true; t2.CanBeDropped = false
								for k, v in pairs(brainrot:GetAttributes()) do t2:SetAttribute(k, v) end
								t2:SetAttribute("IsPlacedBrainrot", true)
								for _, child in ipairs(brainrot:GetChildren()) do
									if not child:IsA("ProximityPrompt") then child.Parent = t2 end
								end
								t2.Parent = p2.Backpack
								DumplingToolService.Prepare(p2, t2)
								brainrot:Destroy()
								slotRef:SetAttribute("HasBrainrot", false)
								slotRef:SetAttribute("Income", 0)
								if promptRef then promptRef.Enabled = true end
								DataService.CacheSlot(p2, slotName, nil)
								NotificationService.Notify(p2, "Picked up " .. brainrot.Name .. "!", Color3.fromRGB(255, 255, 255))
							end)
						end
					end)
				end)
			end
		end
	end
end

local function restoreDiscovered(player, discoveredList)
	if not discoveredList or #discoveredList == 0 then
		print("[DataService] No discovery data found for " .. player.Name)
		return
	end
	print("[DataService] Restoring " .. #discoveredList .. " discoveries for " .. player.Name)
	for _, brainrotName in ipairs(discoveredList) do
		player:SetAttribute("Disc_" .. brainrotName, true)
	end
end

local function calcOfflineIncome(player, data)
	if not data.LastSaveTime then return end
	local timeAway = os.time() - data.LastSaveTime
	if timeAway < 300 then
		print("[DataService] Player away for less than 5m, no offline income.")
		task.delay(2, function()
			NotificationService.Notify(player, "No offline income yet. Come back soon to receive your income! 💰", Color3.fromRGB(255, 75, 75))
		end)
		return
	end

	local elapsed = math.min(timeAway, 86400)
	local totalIncome = 0
	if data.PlacedSlots then
		for _, entry in pairs(data.PlacedSlots) do
			if entry.Type == "Brainrot" and entry.Income then
				totalIncome += entry.Income
			end
		end
	end

	local earned = math.floor(totalIncome * elapsed * 0.005)
	if earned <= 0 then return end

	local cash = player.leaderstats and player.leaderstats:FindFirstChild("Cash")
	if cash then
		cash.Value += earned
		task.delay(2, function()
			NotificationService.Notify(player, "Welcome back! $" .. formatNumber(earned) .. " added to balance from offline earnings!", Color3.fromRGB(85, 255, 127))
		end)
	end
end

function DataService.Load(player)
	local userId = player.UserId
	local data, errored = safeGet(userId)
	if errored then
		player:Kick("DataStore error — please try again. Your data is safe, don't worry!")
		return
	end

	data = migrateEconomyData(data)
	loadedData[userId] = data or {}

	if not data then
		local FuelService = require(game.ServerScriptService:WaitForChild("FuelService"))
		FuelService.InitPlayer(player)
		return
	end

	print("[DataService] Loading data for", player.Name)

	local leaderstats = player:WaitForChild("leaderstats", 10)
	local cash = leaderstats and leaderstats:WaitForChild("Cash", 5)
	if cash and data.Cash then cash.Value = data.Cash end

	if data.Rebirths then
		DataService.SetRebirths(player, data.Rebirths)
		player:SetAttribute("CashMultiplier", EconomyConfig.GetCashMultiplier(data.Rebirths))
	end

	player:SetAttribute("FuelUpgradeCount", data.FuelUpgradeCount or 0)
	player:SetAttribute("FuelUpgrade_Small", data.FuelUpgrade_Small or 0)
	player:SetAttribute("FuelUpgrade_Medium", data.FuelUpgrade_Medium or 0)
	player:SetAttribute("FuelUpgrade_Large", data.FuelUpgrade_Large or 0)
	player:SetAttribute("MaxFuel", data.MaxFuel or EconomyConfig.BaseEnergy)
	player:SetAttribute("CarTier", data.CarTier or 1)
	player:SetAttribute("MaxEggs", data.MaxEggs or 1)

	playerFloorCache[userId] = {
		HasFloor = {
			[2] = data.HasSecondFloor or false,
			[3] = data.HasThirdFloor or false,
			[4] = data.HasFourthFloor or false,
		},
		UnlockedPods = data.UnlockedPods or {},
	}
	playerSlotCache[userId] = data.PlacedSlots or {}

	local FuelService = require(game.ServerScriptService:WaitForChild("FuelService"))

	task.spawn(function()
		if data.Discovered then
			restoreDiscovered(player, data.Discovered)
		end

		if data.UnlockedZones then
			for _, zoneKey in ipairs(data.UnlockedZones) do
				player:SetAttribute("UnlockedZone_" .. zoneKey, true)
			end
		end
		player:SetAttribute("UnlockedZone_1x_Luck", true)

		local attempts = 0
		while not player:GetAttribute("AssignedBase") and attempts < 500 do
			task.wait(0.5); attempts += 1
		end

		local base = getBase(player)
		if not base then
			warn("[DataService] Base not found for restoration: " .. player.Name)
			return
		end

		restoreFloor(player, data)
		task.wait(2.5)

		if data.Backpack then restoreBackpack(player, data.Backpack) end
		if data.PlacedSlots then restorePlacedSlots(player, data.PlacedSlots, data) end

		local CarShopService = require(ServerScriptService:WaitForChild("CarShopService"))
		CarShopService.LoadSaveData(player, data.CarShop)

		calcOfflineIncome(player, data)

		local RemotesRef = game.ReplicatedStorage:FindFirstChild("Remotes")
		local RefreshIndex = RemotesRef and RemotesRef:FindFirstChild("RefreshIndex")
		if RefreshIndex then RefreshIndex:FireClient(player) end

		local RebirthDataUpdate = RemotesRef and RemotesRef:FindFirstChild("RebirthDataUpdate")
		local MaxFuelUpdate = RemotesRef and RemotesRef:FindFirstChild("MaxFuelUpdate")

		if RebirthDataUpdate then
			local rebirths = DataService.GetRebirths(player)
			local function getRequiredFuel(r) return EconomyConfig.GetRequiredEnergy(r) end
			local function getCashMultiplier(r) return EconomyConfig.GetCashMultiplier(r) end
			RebirthDataUpdate:FireClient(player, {
				rebirths = rebirths,
				requiredFuel = getRequiredFuel(rebirths),
				cashMultiplier = getCashMultiplier(rebirths),
				nextCashMultiplier = getCashMultiplier(rebirths + 1),
			})
		end

		if MaxFuelUpdate then
			local maxFuel = player:GetAttribute("MaxFuel") or EconomyConfig.BaseEnergy
			FuelService.InitPlayer(player)
			local actualMax = player:GetAttribute("Has2xFuel") and maxFuel * 2 or maxFuel
			MaxFuelUpdate:FireClient(player, actualMax)
		end

		fullyLoaded[player.UserId] = true
		print("[DataService] Full restoration complete for " .. player.Name)
	end)
end

local rebirthCounts = {}

function DataService.GetRebirths(player)
	return rebirthCounts[player.UserId] or 0
end

function DataService.SetRebirths(player, count)
	rebirthCounts[player.UserId] = count
end

function DataService.SetCash(player, amount)
	local cash = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Cash")
	if cash then
		cash.Value = amount
	end
end

function DataService.CleanupPlayer(player)
	loadedData[player.UserId] = nil
	rebirthCounts[player.UserId] = nil
	playerFloorCache[player.UserId] = nil
	playerSlotCache[player.UserId] = nil
	fullyLoaded[player.UserId] = nil
	CarShopService.CleanupPlayer(player)
end

function DataService.MarkDiscovered(player, brainrotName, material)
	local key = "Disc_" .. material .. "_" .. brainrotName:gsub(" ", "")
	if player:GetAttribute(key) then return end
	player:SetAttribute(key, true)
end

RequestOfflineIncome.OnServerEvent:Connect(function(player)
	local data = loadedData[player.UserId]
	if not data then return end
	local totalIncome = 0
	if data.PlacedSlots then
		for _, entry in pairs(data.PlacedSlots) do
			if entry.Type == "Brainrot" and entry.Income then totalIncome += entry.Income end
		end
	end
	OfflineIncomeUpdate:FireClient(player, math.floor(totalIncome * 86400 * 0.005))
end)

local shuttingDown = false

Players.PlayerAdded:Connect(function(player)
	DataService.Load(player)
	Tracker.LogJoined(player)
end)

Players.PlayerRemoving:Connect(function(player)
	DataService.Save(player)
	if fullyLoaded[player.UserId] then
		alreadySaved[player.UserId] = true
	end
	task.delay(1, function() DataService.CleanupPlayer(player) end)
end)

task.spawn(function()
	while true do
		task.wait(300)
		if shuttingDown then return end
		for _, player in ipairs(Players:GetPlayers()) do
			if fullyLoaded[player.UserId] then
				DataService.Save(player)
			end
		end
	end
end)

game:BindToClose(function()
	shuttingDown = true
	for _, player in ipairs(Players:GetPlayers()) do
		if not alreadySaved[player.UserId] then
			DataService.Save(player)
		end
	end
	task.wait(3)
end)

return DataService
