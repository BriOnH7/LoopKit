//
//  MockPumpManager.swift
//  LoopKit
//
//  Created by Michael Pangburn on 11/20/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import HealthKit
import LoopKit
import LoopTestingKit


public protocol MockPumpManagerStateObserver {
    func mockPumpManager(_ manager: MockPumpManager, didUpdateState state: MockPumpManagerState)
    func mockPumpManager(_ manager: MockPumpManager, didUpdateStatus status: PumpManagerStatus)
}

public struct MockPumpManagerState {
    public var reservoirUnitsRemaining: Double
    public var tempBasalEnactmentShouldError: Bool
    public var bolusEnactmentShouldError: Bool
    public var deliverySuspensionShouldError: Bool
    public var deliveryResumptionShouldError: Bool
    public var maximumBolus: Double
    public var maximumBasalRatePerHour: Double
}

private enum MockPumpManagerError: LocalizedError {
    case pumpSuspended
    case communicationFailure

    var failureReason: String? {
        switch self {
        case .pumpSuspended:
            return "Pump is suspended"
        case .communicationFailure:
            return "Unable to communicate with pump"
        }
    }
}

public final class MockPumpManager: TestingPumpManager {

    public static let managerIdentifier = "MockPumpManager"
    public static let localizedTitle = "Simulator"
    private static let device = HKDevice(
        name: MockPumpManager.managerIdentifier,
        manufacturer: nil,
        model: nil,
        hardwareVersion: nil,
        firmwareVersion: nil,
        softwareVersion: String(LoopKitVersionNumber),
        localIdentifier: nil,
        udiDeviceIdentifier: nil
    )

    private static let deliveryUnitsPerMinute = 1.5
    private static let pulsesPerUnit: Double = 20
    private static let pumpReservoirCapacity: Double = 200

    public var pumpReservoirCapacity: Double {
        return MockPumpManager.pumpReservoirCapacity
    }


    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        return supportedBasalRates.filter({$0 <= unitsPerHour}).max() ?? 0
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        return supportedBolusVolumes.filter({$0 <= units}).max() ?? 0
    }

    public var supportedBolusVolumes: [Double] {
        return supportedBasalRates
    }

    public var supportedBasalRates: [Double] {
        return (0...700).map { Double($0) / Double(type(of: self).pulsesPerUnit) }
    }

    public var maximumBasalScheduleEntryCount: Int {
        return 48
    }

    public var minimumBasalScheduleEntryDuration: TimeInterval {
        return .minutes(30)
    }

    public var testingDevice: HKDevice {
        return type(of: self).device
    }

    public var status: PumpManagerStatus {
        didSet {
            statusObservers.forEach { $0.pumpManager(self, didUpdate: status) }
            stateObservers.forEach { $0.mockPumpManager(self, didUpdateStatus: status) }
            pumpManagerDelegate?.pumpManager(self, didUpdate: status)
            pumpManagerDelegate?.pumpManagerDidUpdateState(self)
        }
    }

    public var state: MockPumpManagerState {
        didSet {
            stateObservers.forEach { $0.mockPumpManager(self, didUpdateState: state) }
            if state.reservoirUnitsRemaining != oldValue.reservoirUnitsRemaining {
                pumpManagerDelegate?.pumpManager(self, didReadReservoirValue: state.reservoirUnitsRemaining, at: Date()) { result in
                    // nothing to do here
                }
            }
            pumpManagerDelegate?.pumpManagerDidUpdateState(self)
        }
    }

    public var pumpManagerDelegate: PumpManagerDelegate?

    private var statusObservers = WeakSet<PumpManagerStatusObserver>()
    private var stateObservers = WeakSet<MockPumpManagerStateObserver>()

    private var pendingPumpEvents: [NewPumpEvent] = []

    public init() {
        status = PumpManagerStatus(timeZone: .current, device: MockPumpManager.device, pumpBatteryChargeRemaining: 1, basalDeliveryState: .active, bolusState: .none)
        state = MockPumpManagerState(reservoirUnitsRemaining: MockPumpManager.pumpReservoirCapacity, tempBasalEnactmentShouldError: false, bolusEnactmentShouldError: false, deliverySuspensionShouldError: false, deliveryResumptionShouldError: false, maximumBolus: 25.0, maximumBasalRatePerHour: 5.0)
    }

    public init?(rawState: RawStateValue) {
        guard let state = (rawState["state"] as? MockPumpManagerState.RawValue).flatMap(MockPumpManagerState.init(rawValue:)) else {
            return nil
        }
        let pumpBatteryChargeRemaining = rawState["pumpBatteryChargeRemaining"] as? Double ?? 1

        self.status = PumpManagerStatus(timeZone: .current, device: MockPumpManager.device, pumpBatteryChargeRemaining: pumpBatteryChargeRemaining, basalDeliveryState: .active, bolusState: .none)
        self.state = state
    }

    public var rawState: RawStateValue {
        var raw: RawStateValue = ["state": state.rawValue]
        if let pumpBatteryChargeRemaining = status.pumpBatteryChargeRemaining {
            raw["pumpBatteryChargeRemaining"] = pumpBatteryChargeRemaining
        }
        return raw
    }

    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        if case .inProgress(let dose) = status.bolusState {
            return MockDoseProgressEstimator(reportingQueue: dispatchQueue, dose: dose)
        }
        return nil
    }

    public var pumpRecordsBasalProfileStartEvents: Bool {
        return false
    }

    public func addStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.insert(observer)
    }

    public func addStateObserver(_ observer: MockPumpManagerStateObserver) {
        stateObservers.insert(observer)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.remove(observer)
    }

    public func assertCurrentPumpData() {
        pumpManagerDelegate?.pumpManager(self, didReadPumpEvents: pendingPumpEvents) { [weak self] error in
            guard let self = self else { return }
            self.pumpManagerDelegate?.pumpManagerRecommendsLoop(self)
        }

        let totalInsulinUsage = pendingPumpEvents.reduce(into: 0 as Double) { total, event in
            if let units = event.dose?.units {
                total += units
            }
        }

        DispatchQueue.main.async {
            self.state.reservoirUnitsRemaining -= totalInsulinUsage
        }

        pendingPumpEvents.removeAll()
    }

    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerResult<DoseEntry>) -> Void) {
        if state.tempBasalEnactmentShouldError {
            completion(.failure(PumpManagerError.communication(MockPumpManagerError.communicationFailure)))
        } else {
            let temp = NewPumpEvent.tempBasal(at: Date(), for: duration, unitsPerHour: unitsPerHour)
            pendingPumpEvents.append(temp)
            completion(.success(temp.dose!))
        }
    }

    public func enactBolus(units: Double, at startDate: Date, willRequest: @escaping (DoseEntry) -> Void, completion: @escaping (PumpManagerResult<DoseEntry>) -> Void) {

        if state.bolusEnactmentShouldError {
            completion(.failure(SetBolusError.certain(PumpManagerError.communication(MockPumpManagerError.communicationFailure))))
        } else {
            guard status.basalDeliveryState != .suspended else {
                completion(.failure(SetBolusError.certain(PumpManagerError.deviceState(MockPumpManagerError.pumpSuspended))))
                return
            }
            let bolus = NewPumpEvent.bolus(at: Date(), units: units, deliveryUnitsPerMinute: type(of: self).deliveryUnitsPerMinute)
            pendingPumpEvents.append(bolus)
            willRequest(bolus.dose!)
            self.status.bolusState = .inProgress(bolus.dose!)
            completion(.success(bolus.dose!))
        }
    }

    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        let oldState = self.status.bolusState
        self.status.bolusState = .canceling
        suspendDelivery { (error) in
            if let error = error {
                self.status.bolusState = oldState
                completion(.failure(error))
            } else {
                self.status.bolusState = .none
                completion(.success(nil))
            }
        }
    }

    public func roundToDeliveryIncrement(units: Double) -> Double {
        return round(units * MockPumpManager.pulsesPerUnit) / MockPumpManager.pulsesPerUnit
    }

    public func updateBLEHeartbeatPreference() {
        // nothing to do here
    }

    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        let previousState = status.basalDeliveryState
        status.basalDeliveryState = .suspending

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
            if self.state.deliverySuspensionShouldError {
                self.status.basalDeliveryState = previousState
                completion(PumpManagerError.communication(MockPumpManagerError.communicationFailure))
            } else {
                let suspend = NewPumpEvent.suspend(at: Date())
                self.pendingPumpEvents.append(suspend)
                self.status.basalDeliveryState = .suspended
                completion(nil)
            }
        }
    }

    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        let previousState = status.basalDeliveryState
        status.basalDeliveryState = .resuming

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
            if self.state.deliveryResumptionShouldError {
                self.status.basalDeliveryState = previousState
                completion(PumpManagerError.communication(MockPumpManagerError.communicationFailure))
            } else {
                let resume = NewPumpEvent.resume(at: Date())
                self.pendingPumpEvents.append(resume)
                self.status.basalDeliveryState = .active
                completion(nil)
            }
        }
    }
}

extension MockPumpManager {
    public var debugDescription: String {
        return """
        ## MockPumpManager
        status: \(status)
        state: \(status)
        pendingPumpEvents: \(pendingPumpEvents)
        """
    }
}

private extension NewPumpEvent {
    static func bolus(at date: Date, units: Double, deliveryUnitsPerMinute: Double) -> NewPumpEvent {
        let dose = DoseEntry(
            type: .bolus,
            startDate: date,
            endDate: date.addingTimeInterval(.minutes(units / deliveryUnitsPerMinute)),
            value: units,
            unit: .units
        )
        return NewPumpEvent(date: date, dose: dose, isMutable: false, raw: newDataIdentifier(), title: "Bolus", type: .bolus)
    }

    static func tempBasal(at date: Date, for duration: TimeInterval, unitsPerHour: Double) -> NewPumpEvent {
        let dose = DoseEntry(
            type: .basal,
            startDate: date,
            endDate: date.addingTimeInterval(duration),
            value: unitsPerHour,
            unit: .unitsPerHour
        )
        return NewPumpEvent(date: date, dose: dose, isMutable: false, raw: newDataIdentifier(), title: "Temp Basal", type: .tempBasal)
    }

    static func suspend(at date: Date) -> NewPumpEvent {
        let dose = DoseEntry(suspendDate: date)
        return NewPumpEvent(date: date, dose: dose, isMutable: false, raw: newDataIdentifier(), title: "Suspend", type: .suspend)
    }

    static func resume(at date: Date) -> NewPumpEvent {
        let dose = DoseEntry(resumeDate: date)
        return NewPumpEvent(date: date, dose: dose, isMutable: false, raw: newDataIdentifier(), title: "Resume", type: .resume)
    }

    private static func newDataIdentifier() -> Data {
        return UUID().uuidString.data(using: .utf8)!
    }
}

extension MockPumpManagerState: RawRepresentable {
    public typealias RawValue = [String: Any]

    public init?(rawValue: RawValue) {
        guard let reservoirUnitsRemaining = rawValue["reservoirUnitsRemaining"] as? Double else {
            return nil
        }

        self.reservoirUnitsRemaining = reservoirUnitsRemaining
        self.tempBasalEnactmentShouldError = rawValue["tempBasalEnactmentShouldError"] as? Bool ?? false
        self.bolusEnactmentShouldError = rawValue["bolusEnactmentShouldError"] as? Bool ?? false
        self.deliverySuspensionShouldError = rawValue["deliverySuspensionShouldError"] as? Bool ?? false
        self.deliveryResumptionShouldError = rawValue["deliveryResumptionShouldError"] as? Bool ?? false
        self.maximumBolus = rawValue["maximumBolus"] as? Double ?? 25.0
        self.maximumBasalRatePerHour = rawValue["maximumBasalRatePerHour"] as? Double ?? 5.0
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "reservoirUnitsRemaining": reservoirUnitsRemaining
        ]

        if tempBasalEnactmentShouldError {
            raw["tempBasalEnactmentShouldError"] = true
        }

        if bolusEnactmentShouldError {
            raw["bolusEnactmentShouldError"] = true
        }

        if deliverySuspensionShouldError {
            raw["deliverySuspensionShouldError"] = true
        }

        if deliveryResumptionShouldError {
            raw["deliveryResumptionShouldError"] = true
        }

        raw["maximumBolus"] = maximumBolus
        raw["maximumBasalRatePerHour"] = maximumBasalRatePerHour

        return raw
    }
}

extension MockPumpManagerState: CustomDebugStringConvertible {
    public var debugDescription: String {
        return """
        ## MockPumpManagerState
        * reservoirUnitsRemaining: \(reservoirUnitsRemaining)
        * tempBasalEnactmentShouldError: \(tempBasalEnactmentShouldError)
        * bolusEnactmentShouldError: \(bolusEnactmentShouldError)
        * deliverySuspensionShouldError: \(deliverySuspensionShouldError)
        * deliveryResumptionShouldError: \(deliveryResumptionShouldError)
        * maximumBolus: \(maximumBolus)
        * maximumBasalRatePerHour: \(maximumBasalRatePerHour)
        """
    }
}
