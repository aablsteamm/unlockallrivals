--[[
	ARNZ Rivals - Unlock All Cosmetics (client side)   core module, v0.2

	1. Adds every Skin / Wrap / Charm / Finisher to the local CosmeticInventory for the weapons you own,
	   so the game's own Equipment screen shows them unlocked (CosmeticLibrary:OwnsCosmetic reads that table).
	2. Intercepts Remotes.Data.EquipCosmetic:FireServer(weapon, type, name, options). Items you really own are sent
	   normally. Items you only own locally are equipped locally (WeaponInventory[weapon][type] = { Name, Inverted,
	   OnlyUseFavorites }) and nothing is sent to the server. Wrap invert and Only Use Favorites also work locally.
	3. Saves local choices to ARNZ_Rivals/cosmetics.json and restores them next run.

	Client side only. Emotes are not touched. Refuses to enable if another script already patched the inventory.
	Unload: getgenv().ARNZ_COSMETICS.Unload()      Last equip calls: getgenv().ARNZ_COSMETICS.State.Log
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local previous = getgenv().ARNZ_COSMETICS
if previous and previous.Unload then pcall(previous.Unload) end

local FOLDER = "ARNZ_Rivals"
local FILE = FOLDER .. "/cosmetics.json"
local TYPES = { "Skin", "Wrap", "Charm", "Finisher" }

local LocalPlayer = Players.LocalPlayer
local PlayerDataController = require(LocalPlayer.PlayerScripts.Controllers.PlayerDataController)
local CosmeticLibrary = require(ReplicatedStorage.Modules.CosmeticLibrary)
local EquipRemote = ReplicatedStorage.Remotes.Data.EquipCosmetic

local State = {
	Enabled = false,
	Unloaded = false,
	Refused = false,
	Connections = {},
	Applying = false,
	RealInventory = nil, -- deep copy of what the server says you own
	Local = {}, -- Local[weapon][type] = { Name, Inverted, OnlyUseFavorites }
	SavedReal = {}, -- SavedReal[weapon][type] = the server's equipped entry, or false when empty
	Log = {}, -- last equip calls seen by the hook
}

local function deepClone(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = deepClone(x) end
	return c
end

local function isCosmeticType(t)
	return t == "Skin" or t == "Wrap" or t == "Charm" or t == "Finisher"
end

local function inventory() return PlayerDataController:Get("CosmeticInventory") end
local function weaponInventory() return PlayerDataController:Get("WeaponInventory") end

local function weaponEntry(weapon)
	for _, w in pairs(weaponInventory()) do
		if w.Name == weapon then return w end
	end
	return nil
end

local function ownedWeapons()
	local list = {}
	for _, w in pairs(weaponInventory()) do list[#list + 1] = w.Name end
	return list
end

local function fire(key)
	local signal = PlayerDataController:GetDataChangedSignal(key)
	if signal then pcall(function() signal:Fire() end) end
end

-- ---- ownership patch
local function applyInventory()
	State.Applying = true
	local inv = inventory()
	local weapons = ownedWeapons()
	local added = 0
	for name, c in pairs(CosmeticLibrary.Cosmetics) do
		local t = c.Type
		if isCosmeticType(t) then
			local slot = inv[name]
			if type(slot) ~= "table" then
				slot = {}
				inv[name] = slot
			end
			if not slot.IsUniversal then
				if t == "Skin" then
					if c.ItemName and not slot[c.ItemName] then
						for _, w in ipairs(weapons) do
							if w == c.ItemName then
								slot[w] = true
								added += 1
								break
							end
						end
					end
				else
					for _, w in ipairs(weapons) do
						if not slot[w] then
							slot[w] = true
							added += 1
						end
					end
				end
			end
		end
	end
	State.Applying = false
	return added
end

local function restoreInventory()
	local inv = inventory()
	if not inv or not State.RealInventory then return end
	State.Applying = true
	for k in pairs(inv) do inv[k] = nil end
	for k, v in pairs(State.RealInventory) do inv[k] = deepClone(v) end
	State.Applying = false
end

-- ---- persistence
local function saveLocal()
	if not (writefile and makefolder and isfolder) then return end
	local data = {}
	for weapon, byType in pairs(State.Local) do
		for typ, e in pairs(byType) do
			data[weapon] = data[weapon] or {}
			data[weapon][typ] = { Name = e.Name, Inverted = e.Inverted, OnlyUseFavorites = e.OnlyUseFavorites }
		end
	end
	pcall(function()
		if not isfolder(FOLDER) then makefolder(FOLDER) end
		writefile(FILE, HttpService:JSONEncode({ schema = 2, equipped = data }))
	end)
end

local function loadLocal()
	if not (readfile and isfile) then return end
	local ok, raw = pcall(function() if isfile(FILE) then return readfile(FILE) end end)
	if not ok or type(raw) ~= "string" then return end
	local okJson, data = pcall(function() return HttpService:JSONDecode(raw) end)
	if not okJson or type(data) ~= "table" or type(data.equipped) ~= "table" then return end
	for weapon, byType in pairs(data.equipped) do
		if type(weapon) == "string" and type(byType) == "table" then
			for _, typ in ipairs(TYPES) do
				local e = byType[typ]
				if type(e) == "table" and type(e.Name) == "string" and CosmeticLibrary.Cosmetics[e.Name] then
					State.Local[weapon] = State.Local[weapon] or {}
					State.Local[weapon][typ] = {
						Name = e.Name,
						Inverted = e.Inverted == true or nil,
						OnlyUseFavorites = e.OnlyUseFavorites == true or nil,
					}
				end
			end
		end
	end
end

-- ---- local equip
local function sameEntry(cur, want)
	return type(cur) == "table" and cur.Name == want.Name and cur.Inverted == want.Inverted
		and cur.OnlyUseFavorites == want.OnlyUseFavorites
end

local function writeEquipped(weapon, typ)
	local entry = weaponEntry(weapon)
	if not entry then return false end
	State.SavedReal[weapon] = State.SavedReal[weapon] or {}
	local want = State.Local[weapon] and State.Local[weapon][typ]
	if State.SavedReal[weapon][typ] == nil then
		local cur = entry[typ]
		-- never record our own entry as the server's
		State.SavedReal[weapon][typ] = (type(cur) == "table" and not (want and sameEntry(cur, want))) and deepClone(cur) or false
	end
	if want and not sameEntry(entry[typ], want) then
		entry[typ] = { Name = want.Name, Inverted = want.Inverted, OnlyUseFavorites = want.OnlyUseFavorites }
		return true
	end
	return false
end

local function applyEquipped()
	local changed = false
	for weapon, byType in pairs(State.Local) do
		for typ in pairs(byType) do
			if writeEquipped(weapon, typ) then changed = true end
		end
	end
	if changed then fire("WeaponInventory") end
	return changed
end

local function ownsReally(name, weapon)
	return CosmeticLibrary:OwnsCosmetic(State.RealInventory, name, weapon)
end

local function randomFor(weapon, typ)
	local pool = {}
	for name, c in pairs(CosmeticLibrary.Cosmetics) do
		if c.Type == typ and (typ ~= "Skin" or c.ItemName == weapon) and not c.Hidden then pool[#pool + 1] = name end
	end
	table.sort(pool)
	return pool[#pool > 0 and math.random(1, #pool) or 1]
end

-- Returns true when the equip was handled locally (the remote must then not be sent).
local function handleEquip(weapon, typ, name, opts)
	if type(weapon) ~= "string" or not isCosmeticType(typ) or not weaponEntry(weapon) then return false end

	if name == nil then -- "None": drop our override and let the server clear its own
		if State.Local[weapon] and State.Local[weapon][typ] then
			State.Local[weapon][typ] = nil
			local saved = State.SavedReal[weapon] and State.SavedReal[weapon][typ]
			local entry = weaponEntry(weapon)
			if entry then entry[typ] = saved or nil end
			saveLocal()
			fire("WeaponInventory")
		end
		return false
	end

	if name == "RANDOM_COSMETIC" then name = randomFor(weapon, typ) end
	if type(name) ~= "string" or not CosmeticLibrary.Cosmetics[name] then return false end

	if ownsReally(name, weapon) then -- really yours: the server handles it, so ours steps aside
		if State.Local[weapon] and State.Local[weapon][typ] then
			State.Local[weapon][typ] = nil
			saveLocal()
		end
		return false
	end

	local existing = State.Local[weapon] and State.Local[weapon][typ]
	local entry = { Name = name }
	if existing and existing.Name == name then
		entry.Inverted = existing.Inverted
		entry.OnlyUseFavorites = existing.OnlyUseFavorites
	end
	if type(opts) == "table" then
		if opts.IsInverted ~= nil then entry.Inverted = opts.IsInverted == true or nil end
		if opts.OnlyUseFavorites ~= nil then entry.OnlyUseFavorites = opts.OnlyUseFavorites == true or nil end
	end
	State.Local[weapon] = State.Local[weapon] or {}
	State.Local[weapon][typ] = entry
	writeEquipped(weapon, typ)
	saveLocal()
	fire("WeaponInventory")
	return true
end

-- ---- public api
local Api = { State = State }

function Api.Equip(weapon, typ, name, options) return handleEquip(weapon, typ, name, options) end
function Api.GetEquipped(weapon, typ) local e = weaponEntry(weapon) return e and e[typ] end
function Api.IsReallyOwned(name, weapon) return ownsReally(name, weapon) end

-- The game never stores an empty slot. Empty slots mean another script already patched the inventory, so the
-- "really owned" snapshot would be wrong and unowned equips would be sent to the server.
local function looksPatched(inv)
	for _, slot in pairs(inv) do
		if type(slot) == "table" and next(slot) == nil then return true end
	end
	return false
end

function Api.Enable()
	if State.Enabled or State.Unloaded then return end
	local snapshot = deepClone(inventory())
	if looksPatched(snapshot) then
		State.Refused = true
		warn("[ARNZ] CosmeticInventory is already patched by another script. Rejoin the game, then run this alone.")
		return false
	end
	State.Refused = false
	State.RealInventory = snapshot
	State.Enabled = true
	applyInventory()
	applyEquipped()
	fire("CosmeticInventory")
	return true
end

function Api.Disable()
	if not State.Enabled then return end
	State.Enabled = false
	restoreInventory()
	for weapon, byType in pairs(State.SavedReal) do
		local entry = weaponEntry(weapon)
		if entry then
			for typ, real in pairs(byType) do entry[typ] = real or nil end
		end
	end
	fire("CosmeticInventory")
	fire("WeaponInventory")
end

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
	if self == EquipRemote and getnamecallmethod() == "FireServer" and not State.Unloaded then
		local a1, a2, a3, a4 = ...
		local handled, ok = false, true
		if State.Enabled then
			ok, handled = pcall(handleEquip, ...)
		end
		local log = State.Log
		log[#log + 1] = { weapon = a1, type = a2, name = a3, enabled = State.Enabled, ok = ok, handled = handled == true }
		if #log > 20 then table.remove(log, 1) end
		if ok and handled then return end
	end
	return oldNamecall(self, ...)
end))

function Api.Unload()
	if State.Unloaded then return end
	Api.Disable()
	State.Unloaded = true
	pcall(function() hookmetamethod(game, "__namecall", oldNamecall) end)
	for _, c in ipairs(State.Connections) do pcall(function() c:Disconnect() end) end
	if getgenv().ARNZ_COSMETICS == Api then getgenv().ARNZ_COSMETICS = nil end
end

-- the server replaced CosmeticInventory: take its data as the new truth and patch it again
State.Connections[#State.Connections + 1] = PlayerDataController:GetDataChangedSignal("CosmeticInventory"):Connect(function()
	if State.Applying or not State.Enabled or State.Unloaded then return end
	local inv = inventory()
	if looksPatched(inv) then return end -- our own patch (or an in-place update): keep the clean snapshot
	State.RealInventory = deepClone(inv)
	applyInventory()
end)

-- keep local equips alive if the server rewrites a weapon entry
local acc = 0
State.Connections[#State.Connections + 1] = RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 1 or not State.Enabled then return end
	acc = 0
	applyEquipped()
end)

-- ---- in-game viewmodel override (first person)
-- The viewmodel is a ReplicatedClass whose replicated Name is the skin name (ItemLibrary.ViewModels and
-- PlayerScripts.Assets.ViewModels are keyed by skin name). Wrap and Charm are read with Get("Wrap") / Get("Charm").
-- We wrap ReplicatedClass.Get and only change answers for the local player's own viewmodels.
-- A viewmodel that is already built keeps its look: respawn, or start the next round, so it is rebuilt.
local ReplicatedClass = require(ReplicatedStorage.Modules.ReplicatedClass)
local ItemLibrary = require(ReplicatedStorage.Modules.ItemLibrary)
local AssetViewModels = LocalPlayer.PlayerScripts:FindFirstChild("Assets") and LocalPlayer.PlayerScripts.Assets:FindFirstChild("ViewModels")
local origGet = rawget(ReplicatedClass, "Get")

local function viewModelExists(name)
	if type(name) ~= "string" then return false end
	if not rawget(ItemLibrary.ViewModels, name) then return false end
	return AssetViewModels ~= nil and AssetViewModels:FindFirstChild(name, true) ~= nil
end

local function localWeaponOfViewModel(self)
	local item = rawget(self, "ClientItem")
	if type(item) ~= "table" then return nil end
	local fighter = rawget(item, "ClientFighter")
	if type(fighter) ~= "table" then return nil end
	if rawget(fighter, "IsLocalPlayer") ~= true and rawget(fighter, "Player") ~= LocalPlayer then return nil end
	local weapon = origGet(item, "Name")
	if type(weapon) ~= "string" then weapon = rawget(item, "Name") end
	return type(weapon) == "string" and weapon or nil
end

local function hookedGet(self, key)
	local value = origGet(self, key)
	if (key ~= "Name" and key ~= "Wrap" and key ~= "Charm") or not State.Enabled or State.Unloaded then return value end
	local weapon = localWeaponOfViewModel(self)
	local mine = weapon and State.Local[weapon]
	if not mine then return value end
	local e = mine[key == "Name" and "Skin" or key]
	if not e then return value end
	if key == "Name" then
		if viewModelExists(e.Name) then return e.Name end
		return value
	end
	return { Name = e.Name, Inverted = e.Inverted, OnlyUseFavorites = e.OnlyUseFavorites }
end

if type(origGet) == "function" then
	rawset(ReplicatedClass, "Get", hookedGet)
else
	warn("[ARNZ] ReplicatedClass.Get not found: in-game override disabled")
end

function Api.HookActive() return rawget(ReplicatedClass, "Get") == hookedGet end

local baseUnload = Api.Unload
function Api.Unload()
	if rawget(ReplicatedClass, "Get") == hookedGet and type(origGet) == "function" then
		rawset(ReplicatedClass, "Get", origGet)
	end
	baseUnload()
end

loadLocal()
getgenv().ARNZ_COSMETICS = Api
Api.Enable()
return true
