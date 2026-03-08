local customGasPumps = {}
-----------------------------------------------------------------------------------------------------------------------------------------
-- ox_target Setup
-----------------------------------------------------------------------------------------------------------------------------------------

function setupGasTargets()
    local pumpModels = {}
    for _, v in pairs(Config.GasPumpProps) do
        table.insert(pumpModels, v.prop)
    end

    for _, model in ipairs(pumpModels) do
        exports.ox_target:addModel(model, {
            {
                label = Utils.translate('target.open_refuel'),
                icon = 'fas fa-gas-pump',
                iconColor = '#a42100',
                distance = 2.0,
                canInteract = function(entity)
                    return not mainUiOpen and not DoesEntityExist(fuelNozzle)
                end,
                onSelect = function(data)
                    local ped = PlayerPedId()
                    local playerCoords = GetEntityCoords(ped)
                    local pump, pumpModel = GetClosestPump(playerCoords, false)
                    if pump then
                        clientOpenUI(pump, pumpModel, false)
                    else
                        exports['lc_utils']:notify("error", Utils.translate("pump_not_found"))
                    end
                end
            },
            {
                label = Utils.translate('target.return_nozzle'),
                icon = 'fas fa-gas-pump',
                iconColor = '#a42100',
                distance = 2.0,
                canInteract = function(entity)
                    return DoesEntityExist(fuelNozzle)
                end,
                onSelect = function(data)
                    returnNozzle()
                end
            }
        })
    end
end

function createCustomPumpModelsThread()
    for _, pumpConfig in pairs(Config.CustomGasPumpLocations) do
        RequestModel(pumpConfig.prop)

        while not HasModelLoaded(pumpConfig.prop) do
            Wait(50)
        end

        local heading = pumpConfig.location.w + 180.0
        local gasPump = CreateObject(pumpConfig.prop, pumpConfig.location.x, pumpConfig.location.y, pumpConfig.location.z, false, true, true)
        SetEntityHeading(gasPump, heading)
        FreezeEntityPosition(gasPump, true)
        table.insert(customGasPumps, gasPump)
    end
end

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    deleteAllCustomGasPumps()
end)

function deleteAllCustomGasPumps()
    for k, v in ipairs(customGasPumps) do
        DeleteEntity(v)
    end
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Jerry Cans
-----------------------------------------------------------------------------------------------------------------------------------------

function setupJerryCanTarget()
    local refuelFromJerryCanLabel = Utils.translate('target.refuel_from_jerry_can')
    if not refuelFromJerryCanLabel or refuelFromJerryCanLabel == "missing_translation" then
        refuelFromJerryCanLabel = 'Refuel from Jerry Can'
    end

    exports.ox_target:addGlobalVehicle({
        {
            label = refuelFromJerryCanLabel,
            icon = 'fas fa-gas-pump',
            iconColor = '#ffa500',
            distance = 2.0,
            canInteract = function(entity)
                local ped = PlayerPedId()
                return entity and entity ~= 0
                    and not IsPedInAnyVehicle(ped, false)
                    and GetSelectedPedWeapon(ped) == JERRY_CAN_HASH
            end,
            onSelect = function(data)
                local ped = PlayerPedId()
                if not IsPedInAnyVehicle(ped, false) and GetSelectedPedWeapon(ped) == JERRY_CAN_HASH then
                    executeRefuelActionFromTarget()
                end
            end
        }
    })
end

-- Code to save jerry can ammo in any inventory
local currentWeaponData
function updateWeaponAmmo(ammo)
    ammo = math.floor(ammo) -- This is needed or some inventories will break

    if currentWeaponData and currentWeaponData.info and currentWeaponData.info.ammo then
        currentWeaponData.info.ammo = ammo
    end

    TriggerServerEvent('ox_inventory:updateWeapon', "ammo", ammo)
    TriggerServerEvent("weapons:server:UpdateWeaponAmmo", currentWeaponData, ammo)
    TriggerServerEvent("qb-weapons:server:UpdateWeaponAmmo", currentWeaponData, ammo)

    if Config.Debug then print("updateWeaponAmmo:ammo",ammo) end
    if Config.Debug then Utils.Debug.printTable("updateWeaponAmmo:currentWeaponData",currentWeaponData) end

    local ped = PlayerPedId()
    SetPedAmmo(ped, JERRY_CAN_HASH, ammo)
end

AddEventHandler('weapons:client:SetCurrentWeapon', function(data, bool)
    if bool ~= false then
        currentWeaponData = data
    else
        currentWeaponData = {}
    end
end)

AddEventHandler('qb-weapons:client:SetCurrentWeapon', function(data, bool)
    if bool ~= false then
        currentWeaponData = data
    else
        currentWeaponData = {}
    end
end)

AddEventHandler('ox_inventory:currentWeapon', function(weapon)
    if weapon then
        if weapon.metadata then
            weapon.info = weapon.metadata
        end
        currentWeaponData = weapon
    else
        currentWeaponData = {}
    end
end)

-- Get jerry can ammo by metadata
function getJerryCanAmmo()
    if currentWeaponData and currentWeaponData.info and currentWeaponData.info.ammo then
        if Config.Debug then print("getJerryCanAmmo:currentWeaponData.info.ammo", currentWeaponData.info.ammo) end
        return currentWeaponData.info.ammo
    end
    local ped = PlayerPedId()
    if Config.Debug then print("getJerryCanAmmo:GetAmmoInPedWeapon", GetAmmoInPedWeapon(ped, JERRY_CAN_HASH)) end
    return GetAmmoInPedWeapon(ped, JERRY_CAN_HASH)
end
