local refuelingThread = nil
local isRefuelling = false
local inCooldown = false
local vehicleAttachedToNozzle = nil
local remainingFuelToRefuel = 0
local currentFuelTypePurchased = nil
local distanceToCap, distanceToPump = math.maxinteger, math.maxinteger
local litersDeductedEachTick = 0.5

-----------------------------------------------------------------------------------------------------------------------------------------
-- Refuelling
-----------------------------------------------------------------------------------------------------------------------------------------

RegisterNetEvent('lc_fuel:getPumpNozzle')
AddEventHandler('lc_fuel:getPumpNozzle', function(fuelAmountPurchased, fuelTypePurchased)
    closeUI()
    if DoesEntityExist(fuelNozzle) then return end
    if not currentPump then return end
    local ped = PlayerPedId()
    local pumpCoords = GetEntityCoords(currentPump)

    -- Animate the ped to grab the nozzle
    Utils.Animations.loadAnimDict("anim@am_hold_up@male")
    TaskPlayAnim(ped, "anim@am_hold_up@male", "shoplift_high", 2.0, 8.0, -1, 50, 0, false, false, false)
    Wait(300)
    StopAnimTask(ped, "anim@am_hold_up@male", "shoplift_high", 1.0)

    -- Spawn the nozzle
    fuelNozzle = createFuelNozzleObject(fuelTypePurchased)

    -- Attach the nozzle
    attachNozzleToPed()
    if Config.EnablePumpRope then
        fuelRope = CreateRopeToPump(pumpCoords)
    end

    -- Get the max distance the player can go with the nozzle
    local ropeLength = getNearestPumpRopeLength(fuelTypePurchased, pumpCoords)

    -- Set the fuel purchased and type for refueling
    remainingFuelToRefuel = fuelAmountPurchased
    currentFuelTypePurchased = fuelTypePurchased

    -- Thread to handle fuel nozzle limits
    CreateThread(function()
        while DoesEntityExist(fuelNozzle) do
            local waitTime = 500
            local nozzleCoords = GetEntityCoords(fuelNozzle)
            distanceToPump = #(pumpCoords - nozzleCoords)
            -- If player reach the distance limit delete the nozzle
            if distanceToPump > ropeLength then
                exports['lc_utils']:notify("error", Utils.translate("too_far_away"))
                deleteRopeAndNozzleProp()
            end
            -- If player is near the distance limit, show a notification
            if distanceToPump > (ropeLength * 0.7) then
                Utils.Markers.showHelpNotification(Utils.translate("too_far_away"), true)
            end
            -- Check if ped entered a vehicle
            if IsPedSittingInAnyVehicle(ped) then
                -- Gives him 2 seconds to leave before clearing the nozzle
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

function returnNozzle()
    local ped = PlayerPedId()

    if not isRefuelling then
        Utils.Animations.loadAnimDict("anim@am_hold_up@male")
        TaskPlayAnim(ped, "anim@am_hold_up@male", "shoplift_high", 2.0, 8.0, -1, 50, 0, false, false, false)
        Wait(300)
        StopAnimTask(ped, "anim@am_hold_up@male", "shoplift_high", 1.0)
        deleteRopeAndNozzleProp()

        if Config.ReturnNozzleRefund then
            local isElectric = Utils.Table.contains({"electricnormal", "electricfast"}, currentFuelTypePurchased)
            TriggerServerEvent('lc_fuel:returnNozzle', remainingFuelToRefuel, isElectric)
        end
    end
end

function executeRefuelAction(isFromJerryCan, closestVehicle, closestCapPos, closestVehicleHash, customVehicleParameters)
    if Config.Debug then print("executeRefuelAction:p", isFromJerryCan, closestVehicle, closestCapPos, closestVehicleHash, customVehicleParameters) end
    local ped = PlayerPedId()
    local refuelTick = Config.RefuelTick
    local isElectric = false
    local fuelTypePurchased = currentFuelTypePurchased

    -- Change the fuel tick if its electric charging
    if fuelTypePurchased == "electricfast" then
        isElectric = true
        refuelTick = Config.Electric.chargeTypes.fast.time * 1000 / 2 -- Divide by 2 because each tick adds 0.5kWh.
    end
    if fuelTypePurchased == "electricnormal" then
        isElectric = true
        refuelTick = Config.Electric.chargeTypes.normal.time * 1000 / 2
    end

    local animationDuration = 1000 -- 1 sec
    if isFromJerryCan then
        -- Keep this finite to avoid getting movement-locked if refuel gets interrupted.
        animationDuration = 1000
    end

    if IsVehicleEngineOn(closestVehicle) then
        exports['lc_utils']:notify("error", Utils.translate("turn_off_engine"))
        stopRefuelAction()
        return
    end

    -- Do not allow user mix electric and petrol fuel/vehicles
    if (isElectric and Config.Electric.vehiclesListHash[closestVehicleHash]) or (not isElectric and not Config.Electric.vehiclesListHash[closestVehicleHash]) then
        if not isRefuelling and not vehicleAttachedToNozzle then
            if remainingFuelToRefuel > 0 then
                -- Reset the vehicle fuel to 0 when refueling with a different fuel type
                if not isFromJerryCan and not isElectric then
                    local fuelType = getVehicleFuelTypeFromServer(closestVehicle)
                    if fuelTypePurchased ~= fuelType then
                        changeVehicleFuelType(closestVehicle, fuelTypePurchased)
                    end
                end
                isRefuelling = true

                -- Animate the ped
                TaskTurnPedToFaceCoord(ped, closestCapPos.x, closestCapPos.y, closestCapPos.z, animationDuration)
                Utils.Animations.loadAnimDict("weapons@misc@jerrycan@")
                TaskPlayAnim(ped, "weapons@misc@jerrycan@", "fire", 2.0, 8.0, animationDuration, 50, 0, false, false, false)

                -- Plug the nozzle in the car
                attachNozzleToVehicle(closestVehicle, customVehicleParameters)

                -- Refuel the vehicle
                refuelingThread = CreateThread(function()
                    local vehicleToRefuel = closestVehicle
                    local startingFuel = GetFuel(vehicleToRefuel) -- Get vehicle fuel level
                    local vehicleTankSize = getVehicleTankSize(vehicleToRefuel)

                    local currentFuel = startingFuel
                    -- Loop keep happening while the player has not canceled, while the fuelNozzle exists and while the ped still has jerry can in hands
                    while isRefuelling and (DoesEntityExist(fuelNozzle) or (isFromJerryCan and GetSelectedPedWeapon(ped) == JERRY_CAN_HASH)) do
                        -- Stop refuel if the vehicle engine is on
                        if IsVehicleEngineOn(vehicleToRefuel) then
                            exports['lc_utils']:notify("error", Utils.translate("turn_off_engine"))
                            stopRefuelAction()
                            break
                        end
                        currentFuel = GetFuel(vehicleToRefuel)
                        local percentageOfFuelToAdd = calculateFuelToAddPercentage(vehicleTankSize) -- Add 0.5L each tick, but the % is proportional to the vehicle tank
                        if currentFuel + percentageOfFuelToAdd > 100 then
                            -- Increase the vehicle fuel level
                            percentageOfFuelToAdd = 100 - currentFuel
                        end
                        if remainingFuelToRefuel < litersDeductedEachTick then
                            -- Break when the user has used all the fuel he paid for
                            break
                        end
                        if percentageOfFuelToAdd <= 0.01 then
                            -- Break when the vehicle tank is full
                            exports['lc_utils']:notify("info", Utils.translate("vehicle_tank_full"))
                            break
                        end
                        -- Decrease the purchased fuel amount and increase the vehicle fuel level
                        remainingFuelToRefuel = remainingFuelToRefuel - litersDeductedEachTick
                        currentFuel = currentFuel + percentageOfFuelToAdd
                        SetFuel(vehicleToRefuel, currentFuel)
                        SendNUIMessage({
                            showRefuelDisplay = true,
                            remainingFuelAmount = remainingFuelToRefuel,
                            currentVehicleTankSize = vehicleTankSize,
                            currentDisplayFuelAmount = getVehicleDisplayFuelAmount(currentFuel, vehicleTankSize),
                            isElectric = isElectric,
                            fuelTypePurchased = fuelTypePurchased
                        })
                        if Config.Debug then print("executeRefuelAction:remainingFuelToRefuel", remainingFuelToRefuel) end

                        -- Update the jerry can ammo every tick
                        if isFromJerryCan then
                            updateWeaponAmmo(remainingFuelToRefuel - (litersDeductedEachTick * 3)) -- "-litersDeductedEachTick" to deduct the next 3 ticks and avoid user suddently holstering the gas can
                        end

                        Wait(refuelTick)
                    end
                    if isFromJerryCan then
                        -- Clear the vehicle attached to the can
                        vehicleAttachedToNozzle = nil
                        updateWeaponAmmo(remainingFuelToRefuel) -- Set the ammo again if the user is still holstering it
                    end
                    if isElectric then
                        exports['lc_utils']:notify("success", Utils.translate("vehicle_recharged"):format(Utils.Math.round(getVehicleDisplayFuelAmount(currentFuel, vehicleTankSize) - getVehicleDisplayFuelAmount(startingFuel, vehicleTankSize), 1)))
                    else
                        exports['lc_utils']:notify("success", Utils.translate("vehicle_refueled"):format(Utils.Math.round(getVehicleDisplayFuelAmount(currentFuel, vehicleTankSize) - getVehicleDisplayFuelAmount(startingFuel, vehicleTankSize), 1)))
                    end

                    -- Stop refuelling
                    stopRefuelAnimation()
                    SendNUIMessage({ hideRefuelDisplay = true })
                    isRefuelling = false
                end)
            else
                exports['lc_utils']:notify("error", Utils.translate("not_enough_refuel"))
            end
        else
            -- Terminate refuelling
            stopRefuelAction()
            -- Cooldown to prevent the user to spam E and glitch things
            inCooldown = true
            SetTimeout(refuelTick + 1,function()
                inCooldown = false
            end)
        end
    else
        exports['lc_utils']:notify("error", Utils.translate("incompatible_fuel"))
    end
end

function calculateFuelToAddPercentage(totalVolumeLiters)
    local percentage = (litersDeductedEachTick / totalVolumeLiters) * 100
    return percentage
end


-----------------------------------------------------------------------------------------------------------------------------------------
-- Target
-----------------------------------------------------------------------------------------------------------------------------------------

local refuelCapZoneId = nil

function setupVehicleRefuelTargets()
    CreateThread(function()
        while true do
            Wait(100)
            
            if DoesEntityExist(fuelNozzle) then
                local ped = PlayerPedId()
                local closestVehicle, closestCapPos = getClosestVehicleVariables()
                
                if closestVehicle and closestVehicle ~= 0 and closestCapPos then
                    local pedCoords = GetEntityCoords(ped)
                    local distToCapPos = #(pedCoords - closestCapPos)
                    
                    if distToCapPos < 3.0 then
                        if not refuelCapZoneId then
                            local startRefuelOption = {
                                label = Utils.translate('target.start_refuel') or 'Start Refuel',
                                icon = 'fas fa-gas-pump',
                                iconColor = '#2986cc',
                                distance = 2.0,
                                canInteract = function()
                                    return not isRefuelling and not vehicleAttachedToNozzle
                                end,
                                onSelect = function(data)
                                    local closestVeh, closestCap, closestHash, customParams = getClosestVehicleVariables()
                                    if closestVeh and closestVeh ~= 0 then
                                        executeRefuelAction(false, closestVeh, closestCap, closestHash, customParams)
                                    end
                                end
                            }
                            
                            local stopRefuelOption = {
                                label = Utils.translate('target.stop_refuel') or 'Stop Refuel',
                                icon = 'fas fa-gas-pump',
                                iconColor = '#2986cc',
                                distance = 2.0,
                                canInteract = function()
                                    return vehicleAttachedToNozzle ~= nil
                                end,
                                onSelect = function(data)
                                    stopRefuelAction()
                                end
                            }
                            
                            refuelCapZoneId = exports.ox_target:addBoxZone({
                                coords = closestCapPos,
                                size = vec3(1.5, 1.5, 1.5),
                                rotation = 0,
                                options = { startRefuelOption, stopRefuelOption }
                            })
                        end
                    else
                        if refuelCapZoneId then
                            exports.ox_target:removeZone(refuelCapZoneId)
                            refuelCapZoneId = nil
                        end
                    end
                else
                    if refuelCapZoneId then
                        exports.ox_target:removeZone(refuelCapZoneId)
                        refuelCapZoneId = nil
                    end
                end
            else
                if refuelCapZoneId then
                    exports.ox_target:removeZone(refuelCapZoneId)
                    refuelCapZoneId = nil
                end
            end
        end
    end)
end

function executeRefuelActionFromTarget()
    -- Load variables to open te UI
    loadNuiVariables()

    local ped = PlayerPedId()

    -- Calculate if player is holding a jerry can
    local isFromJerryCan = false
    if not IsPedInAnyVehicle(ped, false) and GetSelectedPedWeapon(ped) == JERRY_CAN_HASH then
        isFromJerryCan = true
        remainingFuelToRefuel = getJerryCanAmmo()
        if Config.Debug then print("executeRefuelActionFromTarget:remainingFuelToRefuel",remainingFuelToRefuel) end
    end

    local closestVehicle, closestCapPos, closestVehicleHash, customVehicleParameters = getClosestVehicleVariables()
    executeRefuelAction(isFromJerryCan, closestVehicle, closestCapPos, closestVehicleHash, customVehicleParameters)
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

function canOpenPumpUiTargetCallback()
    return not DoesEntityExist(fuelNozzle)
end

function canReturnNozzleTargetCallback()
    return DoesEntityExist(fuelNozzle)
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Utils
-----------------------------------------------------------------------------------------------------------------------------------------

function getClosestVehicleVariables()
    -- Get the closest vehicle and its cap pos
    local closestVehicle = GetClosestVehicle()
    local closestCapPos = GetVehicleCapPos(closestVehicle)
    local closestVehicleHash = GetEntityModel(closestVehicle)
    local customVehicleParameters = (Config.CustomVehicleParametersHash[closestVehicleHash] or Config.CustomVehicleParametersHash.default or { distance = 1.2, nozzleOffset = { forward = 0.0, right = -0.15, up = 0.5 }, nozzleRotation = { x = 0, y = 0, z = 0} })
    if not closestCapPos then
        print("Cap not found for vehicle")
    end

    local finalWorldPos = getWorldPosFromOffset(closestVehicle, customVehicleParameters.nozzleOffset)

    return closestVehicle, finalWorldPos, closestVehicleHash, customVehicleParameters
end

function getWorldPosFromOffset(vehicle, offset)
    local closestCapPos = GetVehicleCapPos(vehicle)
    local forwardVector, rightVector, upVector, _ = GetEntityMatrix(vehicle)

    -- Adjust the offsets
    local forwardOffset = forwardVector * offset.forward
    local rightoffset = rightVector * offset.right
    local upOffset = upVector * offset.up

    -- Final world position of the nozzle point
    return vector3(
        closestCapPos.x + forwardOffset.x + rightoffset.x + upOffset.x,
        closestCapPos.y + forwardOffset.y + rightoffset.y + upOffset.y,
        closestCapPos.z + forwardOffset.z + rightoffset.z + upOffset.z
    )
end

function terminateRefuelThread()
    -- Stop the refueling process
    if refuelingThread and IsThreadActive(refuelingThread) then
        TerminateThread(refuelingThread)
        refuelingThread = nil
    end
end

function stopRefuelAnimation()
    local ped = PlayerPedId()

    StopAnimTask(ped, "weapons@misc@jerrycan@", "fire", 1.0)
    ClearPedSecondaryTask(ped)
    ClearPedTasksImmediately(ped)
    FreezeEntityPosition(ped, false)

    RemoveAnimDict("weapons@misc@jerrycan@")
end

function stopRefuelAction()
    -- Stop refuelling
    stopRefuelAnimation()
    SendNUIMessage({ hideRefuelDisplay = true })
    attachNozzleToPed()
    isRefuelling = false
end

function attachNozzleToVehicle(closestVehicle, customVehicleParameters)
    if not DoesEntityExist(fuelNozzle) then
        -- Jerry can flow has no physical nozzle prop but still needs this state.
        vehicleAttachedToNozzle = closestVehicle
        return
    end

    requestNozzleOwnership()
    DetachEntity(fuelNozzle, true, true)

    -- Find the appropriate bone for the fuel cap
    local tankBones = vehicleCapBoneList()
    local boneIndex = -1

    for _, boneName in ipairs(tankBones) do
        boneIndex = GetEntityBoneIndexByName(closestVehicle, boneName)
        if boneIndex ~= -1 then
            break
        end
    end

    if boneIndex ~= -1 then
        local vehicleRotation = GetEntityRotation(closestVehicle)
        local forwardVector, rightVector, upVector, _ = GetEntityMatrix(closestVehicle)

        -- Adjust the offsets
        local forwardOffset = forwardVector * customVehicleParameters.nozzleOffset.forward
        local rightoffset = rightVector * customVehicleParameters.nozzleOffset.right
        local upOffset = upVector * customVehicleParameters.nozzleOffset.up
        local finalOffset = forwardOffset + rightoffset + upOffset

        -- Adjust the rotation
        local nozzleRotation = customVehicleParameters.nozzleRotation or { x = 0, y = 0, z = 0 }
        local finalRotationX = vehicleRotation.x + nozzleRotation.x
        local finalRotationY = vehicleRotation.y + nozzleRotation.y
        local finalRotationZ = vehicleRotation.z + nozzleRotation.z

        -- Attach the nozzle to the vehicle's fuel cap bone with the calculated rotation
        AttachEntityToEntity(fuelNozzle, closestVehicle, boneIndex, finalOffset.x, finalOffset.y, finalOffset.z, finalRotationX - 45, finalRotationY, finalRotationZ - 90, false, false, false, false, 2, false)
    else
        print("No valid fuel cap bone found on the vehicle.")
    end

    -- Set the global variable to indicate the vehicle attached to nozzle
    vehicleAttachedToNozzle = closestVehicle
end

function attachNozzleToPed()
    if not DoesEntityExist(fuelNozzle) then
        vehicleAttachedToNozzle = nil
        return
    end

    requestNozzleOwnership()
    DetachEntity(fuelNozzle, true, true)

    local ped = PlayerPedId()
    local pedBone = GetPedBoneIndex(ped, 18905)
    AttachEntityToEntity(fuelNozzle, ped, pedBone, 0.13, 0.04, 0.01, -42.0, -115.0, -63.42, false, true, false, true, 0, true)

    vehicleAttachedToNozzle = nil
end

function getNearestPumpRopeLength(fuelTypePurchased, pumpCoords)
    local distanceToFindPump = 10
    local ropeLength = Config.DefaultRopeLength
    if fuelTypePurchased == "electricfast" or fuelTypePurchased == "electricnormal" then
        for _, pumpConfig in pairs(Config.Electric.chargersLocation) do
            local distance = #(vector3(pumpConfig.location.x, pumpConfig.location.y, pumpConfig.location.z) - pumpCoords)
            if distance < distanceToFindPump then
                ropeLength = pumpConfig.ropeLength
                break
            end
        end
    else
        for _, pumpConfig in pairs(Config.CustomGasPumpLocations) do
            local distance = #(vector3(pumpConfig.location.x, pumpConfig.location.y, pumpConfig.location.z) - pumpCoords)
            if distance < distanceToFindPump then
                ropeLength = pumpConfig.ropeLength
                break
            end
        end
    end
    return ropeLength
end

function createFuelNozzleObject(fuelTypePurchased)
    local nozzle_prop_label = Config.NozzleProps.gas
    -- Change the nozzle prop to electric
    if fuelTypePurchased == "electricfast" or fuelTypePurchased == "electricnormal" then
        nozzle_prop_label = Config.NozzleProps.electric
    end

    RequestModel(nozzle_prop_label)
    while not HasModelLoaded(nozzle_prop_label) do
        Wait(50)
    end

    return CreateObject(joaat(nozzle_prop_label), 1.0, 1.0, 1.0, true, true, false)
end
