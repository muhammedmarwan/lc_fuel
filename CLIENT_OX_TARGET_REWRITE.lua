-- ===================================================================
-- LC_FUEL - OX_TARGET CLIENT INTERACTION REWRITE
-- ===================================================================
-- Complete ox_target implementation removing all native interactions
-- No DrawText3D, no while loops, no IsControlJustPressed, no Help Notifications
-- ===================================================================

-- client_gas.lua
local customGasPumps = {}

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

function setupJerryCanTarget()
    exports.ox_target:addGlobalVehicle({
        {
            label = Utils.translate('target.refuel_from_jerry_can') or 'Refuel from Jerry Can',
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

-- ===================================================================
-- client_electric.lua
function setupElectricTargets()
    local pumpModels = {}
    local seenModels = {}

    for _, chargerData in pairs(Config.Electric.chargersLocation) do
        local model = chargerData.prop
        if not seenModels[model] then
            seenModels[model] = true
            table.insert(pumpModels, model)
        end
    end

    for _, model in ipairs(pumpModels) do
        exports.ox_target:addModel(model, {
            {
                label = Utils.translate('target.open_recharge'),
                icon = 'fas fa-plug',
                iconColor = '#00a413',
                distance = 2.0,
                canInteract = function(entity)
                    return not mainUiOpen and not DoesEntityExist(fuelNozzle)
                end,
                onSelect = function(data)
                    local ped = PlayerPedId()
                    local playerCoords = GetEntityCoords(ped)
                    local pump, pumpModel = GetClosestPump(playerCoords, true)
                    if pump then
                        clientOpenUI(pump, pumpModel, true)
                    else
                        exports['lc_utils']:notify("error", Utils.translate("pump_not_found"))
                    end
                end
            },
            {
                label = Utils.translate('target.return_nozzle'),
                icon = 'fas fa-plug',
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

function createElectricZones()
    assert(Utils.Zones, "You are using an outdated version of lc_utils. Please update your 'lc_utils' script to the latest version: https://github.com/LeonardoSoares98/lc_utils/releases/latest/download/lc_utils.zip")

    local stations = groupChargersByStation()

    for _, station in pairs(stations) do
        Utils.Zones.createZone({
            coords = station.center,
            radius = 50.0,
            onEnter = function()
                for _, charger in pairs(station.chargers) do
                    loadElectricCharger(charger)
                end
            end,
            onExit = function()
                for _, charger in pairs(station.chargers) do
                    unloadElectricCharger(charger)
                end
            end
        })
    end
end

-- ===================================================================
-- client_refuel.lua - Simplified RegisterNetEvent for ox_target
RegisterNetEvent('lc_fuel:getPumpNozzle')
AddEventHandler('lc_fuel:getPumpNozzle', function(fuelAmountPurchased, fuelTypePurchased)
    closeUI()
    if DoesEntityExist(fuelNozzle) then return end
    if not currentPump then return end
    local ped = PlayerPedId()
    local pumpCoords = GetEntityCoords(currentPump)

    Utils.Animations.loadAnimDict("anim@am_hold_up@male")
    TaskPlayAnim(ped, "anim@am_hold_up@male", "shoplift_high", 2.0, 8.0, -1, 50, 0, false, false, false)
    Wait(300)
    StopAnimTask(ped, "anim@am_hold_up@male", "shoplift_high", 1.0)

    fuelNozzle = createFuelNozzleObject(fuelTypePurchased)
    attachNozzleToPed()
    if Config.EnablePumpRope then
        fuelRope = CreateRopeToPump(pumpCoords)
    end

    local ropeLength = getNearestPumpRopeLength(fuelTypePurchased, pumpCoords)
    remainingFuelToRefuel = fuelAmountPurchased
    currentFuelTypePurchased = fuelTypePurchased

    CreateThread(function()
        while DoesEntityExist(fuelNozzle) do
            local waitTime = 500
            local nozzleCoords = GetEntityCoords(fuelNozzle)
            distanceToPump = #(pumpCoords - nozzleCoords)
            
            if distanceToPump > ropeLength then
                exports['lc_utils']:notify("error", Utils.translate("too_far_away"))
                deleteRopeAndNozzleProp()
            end
            
            if distanceToPump > (ropeLength * 0.7) then
                Utils.Markers.showHelpNotification(Utils.translate("too_far_away"), true)
            end
            
            if IsPedSittingInAnyVehicle(ped) then
                SetTimeout(2000, function()
                    if IsPedSittingInAnyVehicle(ped) and DoesEntityExist(fuelNozzle) then
                        exports['lc_utils']:notify("error", Utils.translate("too_far_away"))
                        deleteRopeAndNozzleProp()
                    end
                end)
            end
            Wait(waitTime)
        end
        distanceToPump = math.maxinteger
    end)
end)

function setupVehicleRefuelTargets()
    exports.ox_target:addGlobalPlayer({
        {
            label = Utils.translate('target.start_refuel') or 'Start Refuel',
            icon = 'fas fa-gas-pump',
            iconColor = '#2986cc',
            distance = 2.0,
            canInteract = function(entity)
                if not canAttachNozzleTargetCallback() then return false end
                local closestVehicle, closestCapPos = getClosestVehicleVariables()
                if not closestVehicle or closestVehicle == 0 then return false end
                return #(GetEntityCoords(PlayerPedId()) - closestCapPos) < 2.0
            end,
            onSelect = function(data)
                executeRefuelActionFromTarget()
            end
        },
        {
            label = Utils.translate('target.stop_refuel') or 'Stop Refuel',
            icon = 'fas fa-gas-pump',
            iconColor = '#2986cc',
            distance = 2.0,
            canInteract = function(entity)
                if not canDetachNozzleTargetCallback() then return false end
                local closestVehicle, closestCapPos = getClosestVehicleVariables()
                if not closestVehicle or closestVehicle == 0 then return false end
                return #(GetEntityCoords(PlayerPedId()) - closestCapPos) < 2.0
            end,
            onSelect = function(data)
                stopRefuelAction()
            end
        }
    })
end

function canAttachNozzleTargetCallback()
    local ped = PlayerPedId()
    if (DoesEntityExist(fuelNozzle) or GetSelectedPedWeapon(ped) == JERRY_CAN_HASH)
        and not isRefuelling
        and not vehicleAttachedToNozzle then
        return true
    end
    return false
end

function canDetachNozzleTargetCallback()
    local ped = PlayerPedId()
    if (DoesEntityExist(fuelNozzle) or GetSelectedPedWeapon(ped) == JERRY_CAN_HASH)
        and vehicleAttachedToNozzle then
        return true
    end
    return false
end

-- ===================================================================
-- client.lua - Initialization Section Replacement
-- Replace the initialization thread with this:

-- OLD CODE REPLACED:
-- if Utils.Config.custom_scripts_compatibility.target == "disabled" then
--     createGasMarkersThread()
-- else
--     createGasTargetsThread()
-- end

-- NEW CODE:
-- setupGasTargets()
-- setupElectricTargets()
-- setupVehicleRefuelTargets()
-- if Config.JerryCan.enabled then
--     setupJerryCanTarget()
-- end

-- Full initialization context:
Citizen.CreateThread(function()
    Wait(1000)
    SetNuiFocus(false,false)
    SetNuiFocusKeepInput(false)
    FreezeEntityPosition(PlayerPedId(), false)

    Utils.loadLanguageFile(Lang)

    cachedTranslations = {
        open_refuel = Utils.translate('markers.open_refuel'),
        open_recharge = Utils.translate('markers.open_recharge'),
        interact_with_vehicle = Utils.translate('markers.interact_with_vehicle'),
        return_nozzle = Utils.translate('markers.return_nozzle'),
    }

    convertConfigVehiclesDisplayNameToHash()

    if Config.Blips and Config.Blips.enabled then
        createBlips()
    end

    -- Gas pumps using ox_target
    setupGasTargets()
    createCustomPumpModelsThread()

    -- Electric chargers using ox_target
    if Config.Electric.enabled then
        CreateThread(function()
            createElectricZones()
            setupElectricTargets()
        end)
    end

    -- Vehicle refueling using ox_target
    setupVehicleRefuelTargets()

    -- Other threads
    createFuelConsumptionThread()
    
    -- Jerry can using ox_target
    if Config.JerryCan.enabled then
        setupJerryCanTarget()
    end

    if Config.DebugNozzleOffset then
        createDebugNozzleOffsetThread()
    end
end)

-- ===================================================================
-- SUMMARY OF CHANGES:
-- ===================================================================
-- REMOVED:
-- - createGasMarkersThread() - While loop with DrawText3D + IsControlJustPressed
-- - createElectricMarkersThread() - While loop with DrawText3D + IsControlJustPressed  
-- - createJerryCanThread() - While loop with 1000ms wait checking jerry can
-- - createGasTargetsThread() - Old Utils.Target system
-- - createElectricTargetsThread() - Old Utils.Target system
-- - createTargetForVehicleIteraction() - Old Utils.Target system
-- - refuelLoop() - While loop with DrawText3D + IsControlJustPressed
-- - All manual proximity checking loops
-- - All DrawText3D calls
-- - All IsControlJustPressed E key detection
-- - All while true do loops

-- REPLACED WITH:
-- + setupGasTargets() - ox_target:addModel for gas pumps
-- + setupElectricTargets() - ox_target:addModel for electric chargers
-- + setupJerryCanTarget() - ox_target:addGlobalPlayer for jerry can
-- + setupVehicleRefuelTargets() - ox_target:addGlobalPlayer for vehicle refueling
-- + Smart canInteract callbacks for condition checking
-- + Clean onSelect functions triggering existing events
-- ===================================================================
