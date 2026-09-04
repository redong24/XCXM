import Foundation
import CoreBluetooth
import DHBleSDK

private protocol RwfitTimedModel: AnyObject {
    var isOpen: Bool { get set }
    var startHour: Int { get set }
    var startMinute: Int { get set }
    var endHour: Int { get set }
    var endMinute: Int { get set }
    var interval: Int { get set }
}

extension DHHeartRateModeSetModel: RwfitTimedModel {}
extension DHBoModeSetModel: RwfitTimedModel {}
extension DHHrvModeSetModel: RwfitTimedModel {}
extension DHStressModeSetModel: RwfitTimedModel {}
extension DHBloodSugarModeSetModel: RwfitTimedModel {}
extension DHBpModeSetModel: RwfitTimedModel {}

/// Internal mixed-source bridge. Public application types remain in interface.uts.
@objc public final class RwfitIosNativeBridge: NSObject, DHBleConnectDelegate {
    @objc public static let shared = RwfitIosNativeBridge()

    private var discovered: [String: DHPeripheralModel] = [:]
    private var functionMenu: DeviceFuncV2Model?
    private var scanning = false
    private var scanWorkItem: DispatchWorkItem?
    private let stateLock = NSLock()

    private var scanResultListener: ((String, String, NSNumber, String) -> Void)?
    private var scanFinishListener: (() -> Void)?
    private var connectStateListener: ((String, String, String, String, String) -> Void)?
    private var functionMenuListener: ((String, String, String, String) -> Void)?
    private var healthSyncResultListener: ((String, String) -> Void)?
    private var eventListener: ((String, String) -> Void)?
    private var observersRegistered = false
    private var forwardHealthSyncEvents = true

    private override init() {
        super.init()
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    private func withState<T>(_ work: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return work()
    }

    private func reconnectLog(_ message: String) {
        NSLog("[RWFIT][iOS][reconnect] %@", message)
    }

    @objc public func initializeSDK() {
        let boundUUID = DHBleCentralManager.currentBindedUUID() ?? ""
        reconnectLog("initialize begin binded=\(DHBleCentralManager.isBinded()) uuid=\(boundUUID) connected=\(DHBleCentralManager.isConnected())")
        DHBleCentralManager.setLogStatus(true)
        // initWithServiceUuids() can immediately start the native auto-reconnect
        // loop. Install the delegate first so a fast reconnect cannot lose the
        // connected/function-menu callbacks.
        DHBleCentralManager.shareInstance().connectDelegate = self
        DHBleCentralManager.initWithServiceUuids([])
        DHBleCentralManager.shareInstance().connectDelegate = self
        withState {
            discovered.removeAll()
            functionMenu = nil
        }
        forwardHealthSyncEvents = true
        registerObserversIfNeeded()
        reconnectLog("initialize end delegateInstalled=true binded=\(DHBleCentralManager.isBinded()) connected=\(DHBleCentralManager.isConnected())")
    }

    /// 0=notDetermined, 1=restricted, 2=denied, 3=allowed.
    @objc public func bluetoothAuthorizationStatus() -> NSNumber {
        if #available(iOS 13.1, *) {
            return NSNumber(value: CBManager.authorization.rawValue)
        }
        return 3
    }

    @objc public func sdkVersion() -> String {
        DHBleCommand.getSDKVersion()
    }

    @objc public func setScanResultListener(_ listener: @escaping (String, String, NSNumber, String) -> Void) {
        scanResultListener = listener
    }

    @objc public func clearScanResultListener() { scanResultListener = nil }

    @objc public func setScanFinishListener(_ listener: @escaping () -> Void) {
        scanFinishListener = listener
    }

    @objc public func clearScanFinishListener() { scanFinishListener = nil }

    @objc public func setConnectStateListener(_ listener: @escaping (String, String, String, String, String) -> Void) {
        connectStateListener = listener
        reconnectLog("connectState listener installed")
    }

    @objc public func clearConnectStateListener() { connectStateListener = nil }

    @objc public func setFunctionMenuListener(_ listener: @escaping (String, String, String, String) -> Void) {
        functionMenuListener = listener
        reconnectLog("functionMenu listener installed")
    }

    @objc public func clearFunctionMenuListener() { functionMenuListener = nil }

    @objc public func setHealthSyncResultListener(_ listener: @escaping (String, String) -> Void) {
        healthSyncResultListener = listener
    }

    @objc public func clearHealthSyncResultListener() { healthSyncResultListener = nil }

    @objc public func setEventListener(_ listener: @escaping (String, String) -> Void) {
        eventListener = listener
    }

    @objc public func clearEventListener() { eventListener = nil }

    @objc public func startScan() {
        DHBleCentralManager.shareInstance().connectDelegate = self
        withState {
            discovered.removeAll()
            scanning = true
        }
        DHBleCentralManager.startScan()
        let item = DispatchWorkItem { [weak self] in self?.finishScanIfNeeded() }
        withState {
            scanWorkItem?.cancel()
            scanWorkItem = item
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    @objc public func stopScan() { finishScanIfNeeded() }

    @objc public func connect(name: String, mac: String, rssi: NSNumber, uuid: String,
                              completion: @escaping (NSNumber, String) -> Void) {
        finishScanIfNeeded()
        guard let model = cached(mac: mac, uuid: uuid) else {
            onMain { completion(-1, "device not in scan cache; call startScan() first, or use reconnect()") }
            return
        }
        DHBleCentralManager.shareInstance().connectDelegate = self
        emitState("connecting", model: model, reason: "")
        DHBleCentralManager.connectDevice(with: model)
        onMain { completion(0, "success") }
    }

    @objc public func reconnect() {
        DHBleCentralManager.shareInstance().connectDelegate = self
        reconnectLog("reconnect requested binded=\(DHBleCentralManager.isBinded()) uuid=\(DHBleCentralManager.currentBindedUUID() ?? "") connected=\(DHBleCentralManager.isConnected())")
        DHBleCentralManager.checkAndAutoReconnectDevice()
    }

    @objc public func disconnect() { DHBleCentralManager.disconnectDevice() }
    @objc public func isConnected() -> Bool { DHBleCentralManager.isConnected() }
    @objc public func isReady() -> Bool {
        DHBleCentralManager.isConnected() && withState { functionMenu != nil }
    }
    @objc public func setBinded(_ value: Bool) {
        DHBleCentralManager.setBindedStatus(value)
        reconnectLog("setBinded value=\(value) storedUUID=\(DHBleCentralManager.currentBindedUUID() ?? "") connected=\(DHBleCentralManager.isConnected())")
    }

    @objc public func getPower(_ completion: @escaping (NSNumber, NSNumber, String) -> Void) {
        DHBleCommand.getBattery { code, data in
            guard code == 0, let model = data as? DHBatteryInfoModel else {
                self.onMain { completion(NSNumber(value: code == 0 ? -1 : Int(code)), 0, "getPower failed") }
                return
            }
            self.onMain { completion(0, NSNumber(value: Int(model.battery)), "success") }
        }
    }

    @objc public func getFirmware(_ completion: @escaping (NSNumber, String, String, String, String) -> Void) {
        DHBleCommand.getFirmwareVersion { code, data in
            guard code == 0, let model = data as? DHFirmwareVersionModel else {
                self.onMain { completion(NSNumber(value: code == 0 ? -1 : Int(code)), "", "", "", "getFirmwareVersion failed") }
                return
            }
            // Android's legacy FirmVersionBean names the firmware-version field `deviceNo`.
            // Keep the public cross-platform mapping: deviceClazz=model, deviceNo=firmware version.
            self.onMain { completion(0, model.deviceModel, model.firmwareVersion, model.uiVersion, "success") }
        }
    }

    @objc public func getFunctionMenuJSON() -> String {
        let menu = withState { functionMenu }
        guard let menu else { return "{}" }
        return jsonString(menuDictionary(menu))
    }

    @objc public func setUserInfo(gender: NSNumber, age: NSNumber, height: NSNumber, weight: NSNumber,
                                  completion: @escaping (NSNumber, String) -> Void) {
        let model = DHUserInfoSetModel()
        model.gender = gender.intValue
        model.age = age.intValue
        model.height = Int(height.doubleValue.rounded())
        model.weight = Int((weight.doubleValue * 10).rounded())
        DHBleCommand.setUserInfo(model) { code, _ in
            self.onMain { completion(NSNumber(value: Int(code)), code == 0 ? "success" : "setUserInfo failed") }
        }
    }

    @objc public func setTimeFormat(_ format: NSNumber, completion: @escaping (NSNumber, String) -> Void) {
        DHBleCommand.ringSetTimeformat(UInt8(clamping: format.intValue)) { code, _ in
            self.onMain { completion(NSNumber(value: Int(code)), code == 0 ? "success" : "setTimeFormat failed") }
        }
    }

    @objc public func setRingName(_ name: String, completion: @escaping (NSNumber, String) -> Void) {
        DHBleCommand.setRingBtName(name) { code, _ in
            self.onMain { completion(NSNumber(value: Int(code)), code == 0 ? "success" : "setRingBtName failed") }
        }
    }

    private func payload(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    private func finish(_ completion: @escaping (NSNumber, String, String) -> Void,
                        code: Int32, value: Any = [:], action: String) {
        let message = code == 0 ? "success" : "\(action) failed"
        let json = jsonStringValue(value)
        onMain { completion(NSNumber(value: code), json, message) }
    }

    private func jsonStringValue(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func number(_ value: Any?, default fallback: Int = 0) -> Int {
        (value as? NSNumber)?.intValue ?? fallback
    }

    private func bool(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue ?? false }

    private func timedDictionary(_ model: RwfitTimedModel) -> [String: Any] {
        return [
            "isOpen": model.isOpen,
            "duration": model.interval,
            "startHour": model.startHour, "startMin": model.startMinute,
            "endHour": model.endHour, "endMin": model.endMinute
        ]
    }

    private func fillTimed(_ model: RwfitTimedModel, values: [String: Any]) {
        model.isOpen = bool(values["isOpen"])
        model.startHour = number(values["startHour"])
        model.startMinute = number(values["startMin"])
        model.endHour = number(values["endHour"])
        model.endMinute = number(values["endMin"])
        model.interval = number(values["duration"])
    }

    private func timedGet(_ kind: String, completion: @escaping (NSNumber, String, String) -> Void) {
        let reply: (Int32, Any) -> Void = { [weak self] code, data in
            guard let self else { return }
            guard code == 0, let model = data as? RwfitTimedModel else {
                self.finish(completion, code: code == 0 ? -1 : code, action: "getTimed\(kind)")
                return
            }
            self.finish(completion, code: code, value: self.timedDictionary(model), action: "getTimed\(kind)")
        }
        switch kind {
        case "heartRate": DHBleCommand.getHeartRateMode(reply)
        case "bloodOxygen": DHBleCommand.getBoMode(reply)
        case "hrv": DHBleCommand.getHrvMode(reply)
        case "stress": DHBleCommand.getStressMode(reply)
        case "bloodSugar": DHBleCommand.getBloodSugarMode(reply)
        case "bloodPressure": DHBleCommand.getBpMode(reply)
        case "temperature": DHBleCommand.getTimedBodyTemperature(reply)
        case "ppg": DHBleCommand.getPPGMode(reply)
        default: finish(completion, code: -1, action: "getTimed")
        }
    }

    private func timedSet(_ kind: String, values: [String: Any], completion: @escaping (NSNumber, String, String) -> Void) {
        let reply: (Int32, Any) -> Void = { [weak self] code, _ in self?.finish(completion, code: code, action: "setTimed\(kind)") }
        switch kind {
        case "heartRate": let m = DHHeartRateModeSetModel(); fillTimed(m, values: values); DHBleCommand.setHeartRateMode(m, block: reply)
        case "bloodOxygen": let m = DHBoModeSetModel(); fillTimed(m, values: values); DHBleCommand.setBoMode(m, block: reply)
        case "hrv": let m = DHHrvModeSetModel(); fillTimed(m, values: values); DHBleCommand.setHrvMode(m, block: reply)
        case "stress": let m = DHStressModeSetModel(); fillTimed(m, values: values); DHBleCommand.setStressMode(m, block: reply)
        case "bloodSugar": let m = DHBloodSugarModeSetModel(); fillTimed(m, values: values); DHBleCommand.setBloodSugarMode(m, block: reply)
        case "bloodPressure": let m = DHBpModeSetModel(); fillTimed(m, values: values); DHBleCommand.setBpMode(m, block: reply)
        case "temperature": let m = DHHeartRateModeSetModel(); fillTimed(m, values: values); DHBleCommand.setTimedBodyTemperature(m, block: reply)
        case "ppg": let m = DHHrvModeSetModel(); fillTimed(m, values: values); DHBleCommand.setPPGMode(m, block: reply)
        default: finish(completion, code: -1, action: "setTimed")
        }
    }

    @objc public func invoke(_ method: String, payloadJSON: String,
                             completion: @escaping (NSNumber, String, String) -> Void) {
        let values = payload(payloadJSON)
        let simple: (Int32, Any) -> Void = { [weak self] code, _ in self?.finish(completion, code: code, action: method) }
        if method.hasPrefix("getTimed:") { timedGet(String(method.dropFirst(9)), completion: completion); return }
        if method.hasPrefix("setTimed:") { timedSet(String(method.dropFirst(9)), values: values, completion: completion); return }
        switch method {
        case "startRealtimeMeasure", "stopRealtimeMeasure":
            let metric = values["metric"] as? String ?? ""
            let types = ["hr": BLE_KEY_HEART_RATE, "bloodOxy": BLE_KEY_BLOOD_OXYGEN,
                         "hrv": BLE_KEY_HRV, "pressure": BLE_KEY_STRESS,
                         "bloodSugar": BLE_KEY_BLOOD_SUGAR, "bloodPressure": BLE_KEY_BLOOD_PRESSURE]
            guard let dataType = types[metric] else { finish(completion, code: -1, action: method); return }
            DHBleCommand.controlOpen(method == "startRealtimeMeasure" ? 1 : 0, dataType: Int(dataType.rawValue), block: simple)
        case "getWorkoutState":
            DHBleCommand.getControlSport(ring: { [weak self] code, data in
                let raw = data as? [String: Any] ?? [:]
                self?.finish(completion, code: code, value: ["sportType": raw["keySportType"] ?? 0, "controlType": raw["keyControlType"] ?? -1], action: method)
            })
        case "controlWorkout":
            let controlType = WorkoutControlType(rawValue: UInt(clamping: number(values["controlType"])))
            let model = DHSportControlModel(); model.sportType = number(values["sportType"]); model.controlType = controlType
            DHBleCommand.controlSport(withRing: model, block: simple)
        case "setWorkoutRealtimeEnabled":
            DHBleCommand.setRingEnterWorkOut(bool(values["enabled"]) ? 1 : 0, block: simple)
        case "findDevice": DHBleCommand.controlFindDeviceBegin { _, _ in }; finish(completion, code: 0, action: method)
        case "powerOff": DHBleCommand.controlDevice(1) { _, _ in }; finish(completion, code: 0, action: method)
        case "factoryReset": DHBleCommand.controlDevice(2) { _, _ in }; finish(completion, code: 0, action: method)
        case "controlPhoto": DHBleCommand.controlCamera(number(values["state"]), block: simple)
        case "controlPhone": finish(completion, code: -7, action: method)
        case "getMuslimCountEnabled":
            DHBleCommand.getMuslimCountSwitch { [weak self] code, data in self?.finish(completion, code: code, value: (data as? NSNumber)?.intValue == 1, action: method) }
        case "setMuslimCountEnabled": DHBleCommand.setMuslimCountSwitch(bool(values["enabled"]) ? 1 : 0, block: simple)
        case "getHeartRateAlert":
            DHBleCommand.getHRAlert { [weak self] code, data in
                guard let m = data as? DHHRAlertModel else { self?.finish(completion, code: code == 0 ? -1 : code, action: method); return }
                var result: [String: Any] = ["isOpen": m.isOpen, "highThreshold": m.overValue]
                if m.underValue != 0xff { result["lowThreshold"] = m.underValue }
                self?.finish(completion, code: code, value: result, action: method)
            }
        case "setHeartRateAlert":
            let m = DHHRAlertModel(); m.isOpen = bool(values["isOpen"]); m.overValue = number(values["highThreshold"]); m.underValue = number(values["lowThreshold"], default: 0xff); DHBleCommand.setHRAlert(m, block: simple)
        case "getBloodOxygenAlert":
            DHBleCommand.getSP02Alert { [weak self] code, data in
                guard let m = data as? DHHRAlertModel else { self?.finish(completion, code: code == 0 ? -1 : code, action: method); return }
                self?.finish(completion, code: code, value: ["isOpen": m.isOpen, "lowThreshold": m.overValue], action: method)
            }
        case "setBloodOxygenAlert":
            let m = DHHRAlertModel(); m.isOpen = bool(values["isOpen"]); m.overValue = number(values["lowThreshold"]); m.underValue = 0xff; DHBleCommand.setSP02Alert(m, block: simple)
        default: invokeDeviceSettings(method, values: values, completion: completion)
        }
    }

    private func invokeDeviceSettings(_ method: String, values: [String: Any],
                                      completion: @escaping (NSNumber, String, String) -> Void) {
        let simple: (Int32, Any) -> Void = { [weak self] code, _ in self?.finish(completion, code: code, action: method) }
        switch method {
        case "getAlarm":
            DHBleCommand.getAlarms { [weak self] code, data in
                let alarms = (data as? [DHAlarmSetModel] ?? []).map { self?.alarmValue($0) ?? [:] }
                self?.finish(completion, code: code, value: alarms, action: method)
            }
        case "setAlarm":
            let alarms = (values["alarms"] as? [[String: Any]] ?? []).map { item -> DHAlarmSetModel in
                let m = DHAlarmSetModel(); m.isOpen = self.bool(item["isOpen"]); m.hour = self.number(item["startHour"]); m.minute = self.number(item["startMin"]); m.jlAlarmId = UInt8(clamping: self.number(item["alarmId"])); m.repeats = item["repeats"] as? [NSNumber] ?? Array(repeating: 0, count: 7).map(NSNumber.init); return m
            }
            DHBleCommand.setAlarms(alarms, block: simple)
        case "deleteAllAlarm": DHBleCommand.setAlarms([], block: simple)
        case "getRaiseBrightScreen":
            DHBleCommand.ringGetGesture { [weak self] code, data in guard let m = data as? DHGestureSetModel else { self?.finish(completion, code: code == 0 ? -1 : code, action: method); return }; self?.finish(completion, code: code, value: ["isOpen": m.isOpen, "startHour": m.startHour, "startMin": m.startMinute, "endHour": m.endHour, "endMin": m.endMinute], action: method) }
        case "setRaiseBrightScreen":
            let m = DHGestureSetModel(); m.isOpen = bool(values["isOpen"]); m.startHour = number(values["startHour"]); m.startMinute = number(values["startMin"]); m.endHour = number(values["endHour"]); m.endMinute = number(values["endMin"]); DHBleCommand.ringSetGesture(m, block: simple)
        case "getBrightScreenTime":
            DHBleCommand.getBrightTime { [weak self] code, data in self?.finish(completion, code: code, value: (data as? DHBrightTimeSetModel)?.duration ?? 0, action: method) }
        case "setBrightScreenTime":
            let m = DHBrightTimeSetModel(); m.duration = number(values["timeSecond"]); DHBleCommand.setBrightTime(m, block: simple)
        case "getBrightScreenSleepTime":
            DHBleCommand.getDisplaySleepMode { [weak self] code, data in guard let m = data as? DHBrightTimeSetModel else { self?.finish(completion, code: code == 0 ? -1 : code, action: method); return }; self?.finish(completion, code: code, value: ["isOpen": m.sleepOpen, "startHour": m.sleepStartHour, "startMin": m.sleepStartMin, "endHour": m.sleepEndHour, "endMin": m.sleepEndMin], action: method) }
        case "setBrightScreenSleepTime":
            let m = DHBrightTimeSetModel(); m.sleepOpen = bool(values["isOpen"]) ? 1 : 0; m.sleepStartHour = number(values["startHour"]); m.sleepStartMin = number(values["startMin"]); m.sleepEndHour = number(values["endHour"]); m.sleepEndMin = number(values["endMin"]); DHBleCommand.setDisplaySleepMode(m, block: simple)
        case "getRingLedLevel":
            DHBleCommand.getRingLEDLight { [weak self] code, data in guard let m = data as? DHLedLightSetModel else { self?.finish(completion, code: code == 0 ? -1 : code, action: method); return }; self?.finish(completion, code: code, value: ["isOpen": m.isOpen, "lcdLevel": m.lightLevel], action: method) }
        case "setRingLedLevel":
            let m = DHLedLightSetModel(); m.isOpen = bool(values["isOpen"]); m.lightLevel = number(values["lcdLevel"]); DHBleCommand.setRingLEDLight(m, block: simple)
        case "getVideoHid":
            DHBleCommand.getVideoHid { [weak self] code, data in self?.finish(completion, code: code, value: (data as? DHVideoHidSetModel)?.isOpen ?? 0, action: method) }
        case "setVideoHid":
            let m = DHVideoHidSetModel(); m.isOpen = Int32(clamping: number(values["hidOpen"])); DHBleCommand.setVideoHid(m, block: simple)
        case "createOrRemoveBond": finish(completion, code: -7, action: method)
        case "getRingWearDir":
            DHBleCommand.getRingWearHand { [weak self] code, data in self?.finish(completion, code: code, value: (data as? NSNumber)?.intValue == 1, action: method) }
        case "setRingWearHand": DHBleCommand.setRingWearHand(bool(values["isRight"]) ? 1 : 0, block: simple)
        case "getVibrationCount":
            DHBleCommand.getRingMotorLevel { [weak self] code, data in guard let m = data as? DHVibrationLevelModel else { self?.finish(completion, code: code == 0 ? -1 : code, action: method); return }; self?.finish(completion, code: code, value: ["count": m.vibrationNumber, "level": m.vibrationLevel], action: method) }
        case "setVibrationCount": DHBleCommand.setRingMotorLevel(number(values["level"]), motorNum: number(values["count"]), block: simple)
        case "getAlarmVibrationDuration": DHBleCommand.getAlarmVibrationDuration { [weak self] code, data in self?.finish(completion, code: code, value: (data as? NSNumber)?.intValue ?? 0, action: method) }
        case "setAlarmVibrationDuration": DHBleCommand.setAlarmVibrationDuration(UInt8(clamping: number(values["duration"])), block: simple)
        case "getVibrationInterval": DHBleCommand.getVibrationInterval { [weak self] code, data in self?.finish(completion, code: code, value: (data as? NSNumber)?.intValue ?? 0, action: method) }
        case "setVibrationInterval": DHBleCommand.setVibrationInterval(UInt16(clamping: number(values["intervalMs"])), block: simple)
        case "startHeartRateCalibration":
            var replied = false
            DHBleCommand.startFactoryTest(0x15) { [weak self] code, data in
                if let result = data as? [String: Any] { self?.emit("heartRateCalibration", result) }
                if !replied { replied = true; self?.finish(completion, code: code, action: method) }
            }
        case "getFallDetect": DHBleCommand.getFallDetect { [weak self] code, data in self?.finish(completion, code: code, value: (data as? NSNumber)?.intValue == 1, action: method) }
        case "setFallDetect": DHBleCommand.setFallDetect(bool(values["enabled"]) ? 1 : 0, block: simple)
        case "getCountReminderInterval": DHBleCommand.getCountReminderInterval { [weak self] code, data in self?.finish(completion, code: code, value: (data as? NSNumber)?.intValue ?? 0, action: method) }
        case "setCountReminderInterval": DHBleCommand.setCountReminderInterval(UInt8(clamping: number(values["intervalMinutes"])), block: simple)
        case "controlSensorRaw": DHBleCommand.ringControlSensorRaw(bool(values["enabled"]) ? 1 : 2, type: UInt8(clamping: number(values["sensorType"])), block: simple)
        case "getSensorRawHistory": getSensorHistory(completion)
        case "getWorkoutReports": getWorkoutReports(completion)
        case "syncAllHealthData": startHealthSync(completion)
        case "removeHealthDataCallback": forwardHealthSyncEvents = false; finish(completion, code: 0, action: method)
        case "ringOta": startOta(values["path"] as? String ?? "", completion: completion)
        case "unbind": DHBleCentralManager.setBindedStatus(false); DHBleCentralManager.disconnectDevice(); finish(completion, code: 0, action: method)
        case "pushMessage": finish(completion, code: -7, action: method)
        case "setNotificationSwitch": setAncs(values, completion: completion)
        case "getNotificationSwitch": getAncs(completion)
        default: finish(completion, code: -7, action: method)
        }
    }

    private func alarmValue(_ m: DHAlarmSetModel) -> [String: Any] {
        // Some firmware returns nil for `repeats` on unused alarm slots even
        // though the Objective-C header declares the property nonnull. Reading
        // m.repeats directly would then trigger Swift's implicit unwrap trap.
        // KVC preserves the actual nullable value so it can be normalized.
        let rawRepeats = m.value(forKey: "repeats")
        let values: [Any]
        if let array = rawRepeats as? [Any] { values = array }
        else if let array = rawRepeats as? NSArray { values = array.map { $0 } }
        else { values = [] }
        var repeats = values.prefix(7).map { number($0) }
        while repeats.count < 7 { repeats.append(0) }
        return ["alarmId": Int(m.jlAlarmId), "startHour": m.hour,
                "startMin": m.minute, "isOpen": m.isOpen, "repeats": repeats]
    }

    private func numericArray(_ value: Any?) -> [Any] {
        let values: [Any]
        if let array = value as? [Any] { values = array }
        else if let array = value as? NSArray { values = array.map { $0 } }
        else { values = [] }
        return values.map { measurementValue($0) }
    }

    private func sensorValue(_ raw: [String: Any]) -> [String: Any] {
        var packet: [String: Any] = [
            "type": number(raw["sensorType"] ?? raw["type"], default: -1),
            "ppg": numericArray(raw["ppgData"]),
            "acc": dictionaryItems(raw["accData"]).map {
                ["x": measurementValue($0["x"]), "y": measurementValue($0["y"]),
                 "z": measurementValue($0["z"])]
            },
            "ppgRed": numericArray(raw["ppgRedData"]),
            "ir": numericArray(raw["irData"])
        ]
        if raw["sequence"] != nil { packet["sequence"] = number(raw["sequence"]) }
        if raw["timestamp"] != nil { packet["timestampSec"] = timestampValue(raw["timestamp"]) }
        packet["sleep"] = dictionaryItems(raw["sleepData"]).map {
            ["timestampSec": timestampValue($0["timestamp"] ?? $0["timestampSec"]),
             "mode": number($0["mode"])]
        }
        return packet
    }

    private func getSensorHistory(_ completion: @escaping (NSNumber, String, String) -> Void) {
        var packets: [[String: Any]] = []; var replied = false
        DHBleCommand.ringGetHistorySensorRaw({ [weak self] code, _ in
            guard !replied else { return }; replied = true; self?.finish(completion, code: code, value: packets, action: "getSensorRawHistory")
        }, dataBlock: { [weak self] code, _, data in
            guard !replied else { return }
            if code != 0 { replied = true; self?.finish(completion, code: code, action: "getSensorRawHistory"); return }
            (data as? [[String: Any]] ?? []).forEach { if let value = self?.sensorValue($0) { packets.append(value) } }
        })
    }

    private func workoutValue(_ model: DHDailySportModel) -> [String: Any] {
        let start = Int64(model.timestamp) ?? 0
        func values(_ raw: [Any]?) -> [[String: Any]] {
            (raw ?? []).enumerated().compactMap { index, item in
                if let value = item as? [String: Any] { return ["index": value["index"] ?? index, "value": value["value"] ?? 0] }
                if let value = item as? NSNumber { return ["index": index, "value": value] }
                return nil
            }
        }
        return [
            "startTime": start, "endTime": start > 0 ? start + Int64(model.duration) : 0,
            "date": model.date.isEmpty ? dateText(Int(start)) : model.date,
            "sportType": model.type, "duration": model.duration, "step": model.step,
            "distance": model.distance, "calorie": model.calorie, "height": model.sportHeight,
            "pressure": model.sportPress, "cadence": model.sportStepFreq, "speed": Double(model.sportSpeed),
            "pace": model.pace, "averageHeartRate": model.heartAve, "maxHeartRate": model.heartMax,
            "minHeartRate": model.heartMin, "maxCadence": model.maxStepFreq, "minCadence": model.minStepFreq,
            "maxPace": model.sportMaxPace, "minPace": model.sportMinPace,
            "heartRateCount": model.sportHeartNum, "viewType": model.viewType,
            "heartRateItems": values(model.heartRateItems), "pacePerKmItems": values(model.pacePerKmItems)
        ]
    }

    private func dateText(_ timestamp: Int) -> String {
        guard timestamp > 0 else { return "" }; let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd"; return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private func getWorkoutReports(_ completion: @escaping (NSNumber, String, String) -> Void) {
        var reports: [[String: Any]] = []; var replied = false
        DHBleCommand.startRingWorkout3Syncing({ [weak self] code, _ in
            guard !replied else { return }; replied = true; self?.finish(completion, code: code, value: reports, action: "getWorkoutReports")
        }, dataBlock: { [weak self] code, _, data in
            guard !replied else { return }; if code != 0 { replied = true; self?.finish(completion, code: code, action: "getWorkoutReports"); return }
            (data as? [DHDailySportModel] ?? []).forEach { if let value = self?.workoutValue($0) { reports.append(value) } }
        })
    }

    private func dictionaryItems(_ value: Any?) -> [[String: Any]] {
        if let items = value as? [[String: Any]] { return items }
        if let items = value as? [NSDictionary] {
            return items.compactMap { $0 as? [String: Any] }
        }
        if let items = value as? NSArray {
            return items.compactMap { ($0 as? NSDictionary) as? [String: Any] }
        }
        return []
    }

    private func timestampValue(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }

    private func measurementValue(_ value: Any?) -> Any {
        if let number = value as? NSNumber { return number }
        if let text = value as? String, let number = Double(text) { return number }
        return 0
    }

    private func metricHealthValue(type: String, key: String, timestamp: Any?,
                                   date: String, items: Any?) -> (String, [String: Any]) {
        let values = dictionaryItems(items).map {
            ["time": timestampValue($0["timestamp"]), key: measurementValue($0["value"])]
        }
        return (type, ["time": timestampValue(timestamp), "date": date, "items": values])
    }

    private func modelValue(_ value: Any) -> (String, [String: Any])? {
        if let model = value as? DHDailyStepModel {
            let items = dictionaryItems(model.items).map {
                ["time": timestampValue($0["timestamp"]), "index": $0["index"] ?? 0,
                 "steps": $0["step"] ?? 0, "calorie": $0["calorie"] ?? 0,
                 "distance": $0["distance"] ?? 0]
            }
            return ("step", ["time": timestampValue(model.timestamp), "date": model.date,
                              "totalSteps": model.step, "totalCalorie": model.calorie,
                              "totalDistance": model.distance,
                              "activityDataInterval": model.activityDataInterval,
                              "items": items])
        }
        if let model = value as? DHDailySleepModel {
            let items = dictionaryItems(model.items).map {
                ["len": $0["value"] ?? 0, "sleepType": $0["status"] ?? 0]
            }
            return ("sleep", ["time": timestampValue(model.timestamp), "date": model.date,
                               "duration": model.duration, "beginTime": timestampValue(model.beginTime),
                               "endTime": timestampValue(model.endTime), "items": items])
        }
        if let model = value as? DHDailyBpModel {
            let items = dictionaryItems(model.items).map {
                ["time": timestampValue($0["timestamp"]), "systolic": $0["systolic"] ?? 0,
                 "diastolic": $0["diastolic"] ?? 0]
            }
            return ("bp", ["time": timestampValue(model.timestamp), "date": model.date, "items": items])
        }
        if let model = value as? DHDailyMuslimCountModel {
            let items = dictionaryItems(model.items).map {
                ["time": timestampValue($0["timestamp"]), "count": $0["value"] ?? 0]
            }
            return ("muslimCount", ["time": timestampValue(model.timestamp), "date": model.date,
                                     "totalCount": model.muslimcount, "items": items])
        }
        if let model = value as? DHDailyHrModel {
            return metricHealthValue(type: "hr", key: "hr", timestamp: model.timestamp,
                                     date: model.date, items: model.items)
        }
        if let model = value as? DHDailyBoModel {
            return metricHealthValue(type: "bo", key: "bloodOxy", timestamp: model.timestamp,
                                     date: model.date, items: model.items)
        }
        if let model = value as? DHDailyHrvModel {
            return metricHealthValue(type: "hrv", key: "hrv", timestamp: model.timestamp,
                                     date: model.date, items: model.items)
        }
        if let model = value as? DHDailyPressureModel {
            return metricHealthValue(type: "pressure", key: "pressure", timestamp: model.timestamp,
                                     date: model.date, items: model.items)
        }
        if let model = value as? DHDailyBloodSugarModel {
            return metricHealthValue(type: "bloodSugar", key: "bloodSugar", timestamp: model.timestamp,
                                     date: model.date, items: model.items)
        }
        if let model = value as? DHDailyTempModel {
            return metricHealthValue(type: "temp", key: "temp", timestamp: model.timestamp,
                                     date: model.date, items: model.items)
        }
        return nil
    }

    private func startHealthSync(_ completion: @escaping (NSNumber, String, String) -> Void) {
        guard isReady() else {
            finish(completion, code: -5, action: "syncAllHealthData")
            return
        }
        forwardHealthSyncEvents = true
        DHBleCommand.startDataSyncing({ [weak self] code, _ in
            guard let self, self.forwardHealthSyncEvents else { return }
            if code == 0 { self.emit("syncProgress", ["progress": 100]); self.emit("syncFinish", [:]) }
            else { self.emit("syncError", ["code": code]) }
        }, datablcok: { [weak self] code, _, data in
            guard let self, self.forwardHealthSyncEvents else { return }
            if code != 0 { self.emit("syncError", ["code": code]); return }
            let source = data as? [Any] ?? []
            var grouped: [String: [[String: Any]]] = [:]
            source.forEach { if let (type, value) = self.modelValue($0) { grouped[type, default: []].append(value) } }
            // DHBleCommand.startDataSyncing streams mixed-type batches through
            // this single callback; a health type (e.g. "step") can span more
            // than one batch. Each batch is emitted as its own syncResult, so
            // JS-side listeners must merge same-type results across a sync
            // session instead of overwriting - see onSyncResult in rwfit.js.
            grouped.forEach { type, values in
                let json = self.jsonString(values)
                self.onMain { [weak self] in self?.healthSyncResultListener?(type, json) }
            }
        })
        finish(completion, code: 0, action: "syncAllHealthData")
    }

    private func startOta(_ pathValue: String, completion: @escaping (NSNumber, String, String) -> Void) {
        let path = pathValue.hasPrefix("file://") ? URL(string: pathValue)?.path ?? "" : pathValue
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { finish(completion, code: -1, action: "ringOta"); return }
        DHBleCommand.ringOta(withFileData: data) { [weak self] code, progress, _ in
            self?.emit("otaProgress", ["progress": progress]); if code != 0 { self?.emit("otaFinish", ["success": false, "code": code]) } else if progress >= 1 { self?.emit("otaFinish", ["success": true]) }
        }
        finish(completion, code: 0, action: "ringOta")
    }

    private func setAncs(_ values: [String: Any], completion: @escaping (NSNumber, String, String) -> Void) {
        let model = DHAncsSetModel()
        model.isCall = bool(values["isCall"]); model.isSMS = bool(values["isSMS"])
        model.isQQ = bool(values["isQQ"]); model.isWechat = bool(values["isWechat"])
        model.isWhatsapp = bool(values["isWhatsapp"]); model.isMessenger = bool(values["isMessenger"])
        model.isTwitter = bool(values["isTwitter"]); model.isLinkedin = bool(values["isLinkedin"])
        model.isInstagram = bool(values["isInstagram"]); model.isFacebook = bool(values["isFacebook"])
        model.isLine = bool(values["isLine"]); model.isWechatWork = bool(values["isWechatWork"])
        model.isDingding = bool(values["isDingding"]); model.isEmail = bool(values["isEmail"])
        model.isCalendar = bool(values["isCalendar"]); model.isViber = bool(values["isViber"])
        model.isSkype = bool(values["isSkype"]); model.isKakaotalk = bool(values["isKakaotalk"])
        model.isTumblr = bool(values["isTumblr"]); model.isSnapchat = bool(values["isSnapchat"])
        model.isYoutube = bool(values["isYoutube"]); model.isPinterset = bool(values["isPinterset"])
        model.isTiktok = bool(values["isTiktok"]); model.isGmail = bool(values["isGmail"])
        model.isJLSinaWeiBo = bool(values["isJLSinaWeiBo"]); model.isJLBand = bool(values["isJLBand"])
        model.isJLTelegram = bool(values["isJLTelegram"]); model.isJLBetween = bool(values["isJLBetween"])
        model.isJLNavercafe = bool(values["isJLNavercafe"]); model.isJLNetflix = bool(values["isJLNetflix"])
        model.isMax = bool(values["isMax"]); model.isVkim = bool(values["isVkim"])
        model.isOther = bool(values["isOther"])
        DHBleCommand.ringSetAncs(model) { [weak self] code, _ in
            self?.finish(completion, code: code, action: "setNotificationSwitch")
        }
    }
    private func getAncs(_ completion: @escaping (NSNumber, String, String) -> Void) {
        DHBleCommand.ringGetAncs { [weak self] code, data in
            guard let self, let model = data as? DHAncsSetModel else {
                self?.finish(completion, code: code == 0 ? -1 : code, action: "getNotificationSwitch")
                return
            }
            let result: [String: Any] = [
                "isCall": model.isCall, "isSMS": model.isSMS, "isQQ": model.isQQ,
                "isWechat": model.isWechat, "isWhatsapp": model.isWhatsapp,
                "isMessenger": model.isMessenger, "isTwitter": model.isTwitter,
                "isLinkedin": model.isLinkedin, "isInstagram": model.isInstagram,
                "isFacebook": model.isFacebook, "isLine": model.isLine,
                "isWechatWork": model.isWechatWork, "isDingding": model.isDingding,
                "isEmail": model.isEmail, "isCalendar": model.isCalendar,
                "isViber": model.isViber, "isSkype": model.isSkype,
                "isKakaotalk": model.isKakaotalk, "isTumblr": model.isTumblr,
                "isSnapchat": model.isSnapchat, "isYoutube": model.isYoutube,
                "isPinterset": model.isPinterset, "isTiktok": model.isTiktok,
                "isGmail": model.isGmail, "isJLSinaWeiBo": model.isJLSinaWeiBo,
                "isJLBand": model.isJLBand, "isJLTelegram": model.isJLTelegram,
                "isJLBetween": model.isJLBetween, "isJLNavercafe": model.isJLNavercafe,
                "isJLNetflix": model.isJLNetflix, "isMax": model.isMax,
                "isVkim": model.isVkim, "isOther": model.isOther
            ]
            self.finish(completion, code: code, value: result, action: "getNotificationSwitch")
        }
    }

    /// Native BLE callbacks are not guaranteed to arrive on the main queue.
    /// UTS/JavaScript callbacks must be delivered on the main queue, matching
    /// the Flutter iOS bridge and avoiding concurrent access to the JS runtime.
    private func emit(_ name: String, _ value: [String: Any]) {
        let json = jsonStringValue(value)
        onMain { [weak self] in self?.eventListener?(name, json) }
    }

    private func registerObserversIfNeeded() {
        guard !observersRegistered else { return }; observersRegistered = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleMeasureValue(_:)), name: NSNotification.Name(rawValue: BluetoothNotificationHealthRingMeasureValueChange), object: nil)
        center.addObserver(self, selector: #selector(handleMeasureState(_:)), name: NSNotification.Name(rawValue: BluetoothNotificationHealthRingMeasureStateChange), object: nil)
        center.addObserver(self, selector: #selector(handleCamera(_:)), name: NSNotification.Name(rawValue: BluetoothNotificationCameraTakePicture), object: nil)
        center.addObserver(self, selector: #selector(handleWorkout(_:)), name: NSNotification.Name(rawValue: BluetoothNotificationRingRuningData), object: nil)
        center.addObserver(self, selector: #selector(handleTouch(_:)), name: NSNotification.Name(rawValue: BluetoothNotificationTouchEvent), object: nil)
        center.addObserver(self, selector: #selector(handleSensor(_:)), name: NSNotification.Name(rawValue: BluetoothNotificationSensorRawData), object: nil)
        center.addObserver(self, selector: #selector(handleSensorStop(_:)), name: NSNotification.Name(rawValue: BluetoothNotificationHealthRingSenorStopChange), object: nil)
        center.addObserver(self, selector: #selector(handleAlert(_:)), name: NSNotification.Name(rawValue: BluetoothNotificationRingHealthOverAlert), object: nil)
    }

    @objc private func handleMeasureState(_ notification: Notification) {
        if (notification.userInfo?["ringMeasure"] as? NSNumber)?.intValue == 0 { emit("realtimeMeasureComplete", [:]) }
    }
    @objc private func handleMeasureValue(_ notification: Notification) {
        let raw = notification.userInfo as? [String: Any] ?? [:]
        let native = BleKey(rawValue: UInt16(clamping: number(raw["dataType"])))
        let mapping = [BLE_KEY_APP_REAL_TIME_HR_DATA: 1, BLE_KEY_APP_REAL_TIME_BLOOD_OXYGEN_DATA: 3, BLE_KEY_APP_REAL_TIME_BP_DATA: 4, BLE_KEY_APP_REAL_TIME_STRESS_DATA: 8, BLE_KEY_APP_REAL_BLOOD_SUGAR_DATA: 9, BLE_KEY_APP_REAL_TIME_MUSLIM_COUNT: 10, BLE_KEY_APP_REAL_TIME_HRV_DATA: 13]
        guard let type = mapping[native] else { return }
        let timestamp = timestampValue(raw["timestamp"])
        var result: [String: Any] = ["dataType": type, "time": timestamp > 0 ? timestamp : Int64(Date().timeIntervalSince1970)]
        if type == 4 {
            result["dataValue"] = measurementValue(raw["systolic"])
            result["diastolic"] = measurementValue(raw["diastolic"])
        } else {
            result["dataValue"] = measurementValue(raw["dataValue"])
        }
        emit("realtimeData", result)
    }
    @objc private func handleCamera(_ notification: Notification) { emit("touchEvent", ["keyType": 0, "touchType": 0, "action": "cameraTakePicture"]) }
    @objc private func handleWorkout(_ notification: Notification) {
        let d = notification.userInfo as? [String: Any] ?? [:]
        emit("workoutRealtimeData", [
            "duration": measurementValue(d["ActivityTime"]),
            "steps": measurementValue(d["ActivitySteps"]),
            "distance": measurementValue(d["ActivityDistance"]),
            "calorie": measurementValue(d["ActivityCalorie"]),
            "heartRate": measurementValue(d["ActivityHr"]), "dataType": 0x0223
        ])
    }
    private func touchAction(_ key: Int, _ touch: Int) -> String {
        if key == 2 { return "fallDetected" }; guard key == 1 else { return "unknown" }
        return touch == 1 ? "singleTap" : touch == 2 ? "doubleTap" : touch == 3 ? "tripleTap" : touch == 4 ? "longPress" : touch == 5 ? "swing" : "unknown"
    }
    @objc private func handleTouch(_ notification: Notification) { let d = notification.userInfo as? [String: Any] ?? [:]; let key = number(d["keyType"]), touch = number(d["touchType"]); emit("touchEvent", ["keyType": key, "touchType": touch, "action": touchAction(key, touch)]) }
    @objc private func handleSensor(_ notification: Notification) { emit("sensorRawData", sensorValue(notification.userInfo as? [String: Any] ?? [:])) }
    @objc private func handleSensorStop(_ notification: Notification) { emit("sensorRawStopped", ["reason": 0]) }
    @objc private func handleAlert(_ notification: Notification) {
        let d = notification.userInfo as? [String: Any] ?? [:]
        emit("healthAlert", ["type": number(d["type"], default: -1), "value": measurementValue(d["value"])])
    }

    public func centralManagerDidDiscoverPeripheral(_ peripherals: [DHPeripheralModel]) {
        guard withState({ scanning }) else { return }
        for item in peripherals {
            cache(item)
            let name = item.name, mac = item.macAddr, rssi = NSNumber(value: -abs(Int(item.rssi))), uuid = item.uuid
            onMain { [weak self] in self?.scanResultListener?(name, mac, rssi, uuid) }
        }
    }

    public func centralManagerDidUpdateState(_ isOn: Bool) {
        reconnectLog("native bluetoothState isOn=\(isOn) binded=\(DHBleCentralManager.isBinded()) uuid=\(DHBleCentralManager.currentBindedUUID() ?? "")")
    }

    public func centralManagerDidConnect(_ peripheral: CBPeripheral) {
        reconnectLog("native didConnect uuid=\(peripheral.identifier.uuidString) connectListener=\(connectStateListener != nil)")
        withState {
            scanning = false
            scanWorkItem?.cancel()
            scanWorkItem = nil
        }
        emitState("connected", peripheral: peripheral, reason: "")
    }

    public func centralManagerDidFunctionMenu(_ model: DeviceFuncV2Model, peripheral: DHPeripheralModel) {
        reconnectLog("native didFunctionMenu uuid=\(peripheral.uuid) functionMenuListener=\(functionMenuListener != nil)")
        withState { functionMenu = model }
        let name = peripheral.name, mac = peripheral.macAddr, uuid = peripheral.uuid
        let json = jsonString(menuDictionary(model))
        onMain { [weak self] in self?.functionMenuListener?(name, mac, uuid, json) }
    }

    public func centralManagerDidDisconnect(_ peripheral: CBPeripheral) {
        reconnectLog("native didDisconnect uuid=\(peripheral.identifier.uuidString)")
        withState { functionMenu = nil }
        emitState("disconnected", peripheral: peripheral, reason: "")
    }

    public func centralManagerDidFailed(_ peripheral: CBPeripheral) {
        reconnectLog("native didFailed uuid=\(peripheral.identifier.uuidString)")
        withState { functionMenu = nil }
        emitState("failed", peripheral: peripheral, reason: "unknown")
    }

    private func finishScanIfNeeded() {
        let shouldFinish = withState { () -> Bool in
            guard scanning else { return false }
            scanning = false
            scanWorkItem?.cancel()
            scanWorkItem = nil
            return true
        }
        guard shouldFinish else { return }
        DHBleCentralManager.stopScan()
        onMain { [weak self] in self?.scanFinishListener?() }
    }

    private func cache(_ model: DHPeripheralModel) {
        withState {
            if !model.uuid.isEmpty { discovered["uuid:\(model.uuid)"] = model }
            if !model.macAddr.isEmpty { discovered["mac:\(model.macAddr.uppercased())"] = model }
        }
    }

    private func cached(mac: String, uuid: String) -> DHPeripheralModel? {
        withState {
            if !uuid.isEmpty, let value = discovered["uuid:\(uuid)"] { return value }
            if !mac.isEmpty, let value = discovered["mac:\(mac.uppercased())"] { return value }
            return nil
        }
    }

    private func cached(_ peripheral: CBPeripheral) -> DHPeripheralModel? {
        withState { discovered["uuid:\(peripheral.identifier.uuidString)"] }
    }

    private func emitState(_ state: String, model: DHPeripheralModel, reason: String) {
        let name = model.name, mac = model.macAddr, uuid = model.uuid
        onMain { [weak self] in self?.connectStateListener?(state, name, mac, uuid, reason) }
    }

    private func emitState(_ state: String, peripheral: CBPeripheral, reason: String) {
        let model = cached(peripheral)
        let name = peripheral.name ?? model?.name ?? ""
        let mac = model?.macAddr ?? "", uuid = model?.uuid ?? peripheral.identifier.uuidString
        onMain { [weak self] in self?.connectStateListener?(state, name, mac, uuid, reason) }
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func menuDictionary(_ model: DeviceFuncV2Model) -> [String: Any] {
        let interval = model.activityDataInterval > 0 ? model.activityDataInterval : 60
        let alert = model.isSupportHrSp02Alert != 0
        return [
            "isPushMsgEnableSwitch": model.isPushMsgEnableSwitch,
            "pushMsgSwitchValue": model.pushMsgSwitchValue,
            "pushMsgSwitchValue2": model.pushMsgSwitchValue2,
            "activityDataInterval": interval,
            "isAlarm": model.isAlarm,
            "isBrightScreenSleepTime": model.isBackLightSleepMode,
            "isBrightScreenTime": model.isBackLight,
            "isSupportWorkout": model.isSupportWorkout3,
            "isRememberSwitch": model.isSupportMuslimCountSwitch,
            "isSupportHrReminder": alert,
            "isSupportBoReminder": alert,
            "isSupportMotoVibrationLevel": model.isSupportMotoVibrationLevel,
            "isSupportAlarmVibrationDuration": model.isSupportAlarmVibrationDuration,
            "isSupportVibrationInterval": model.isSupportVibrationInterval,
            "isStep": model.isDataTypeActivity,
            "isSleep": model.isDataTypeSleep,
            "isHr": model.isDataTypeHeart,
            "isBloodOxy": model.isDataTypeSPO2,
            "isBloodPress": model.isDataTypeBloodPressure,
            "isBloodSugar": model.isDataTypeBloodSugar,
            "isHrv": model.isDataTypeHRV,
            "isPressure": model.isDataTypeStress,
            "isMuslimCountData": model.isDataTypeMuslimCount,
            "isBodyTemp": model.isDataTypeTemperature,
            "isSupportMuslimTimeDisplayMode": model.isSupportMuslimTimeDisplayMode,
            "isSupportSensorRawPPG": model.isSupportSensorRawPPG,
            "isSupportPPGMonitoring": model.isSupportPPGMonitoring,
            "isSupportTemperatureMonitoring": model.isSupportTemperatureMonitoring,
            "isSupportCountReminder": model.isSupportCountReminder,
            "isSupportSensorRawACC": model.isSupportSensorRawACC,
            "isSupportSensorRawPPGRed": model.isSupportSensorRawPPGRed,
            "isSupportSensorRawIR": model.isSupportSensorRawIR,
            "isSupportSensorRawSleep": model.isSupportSensorRawSleep,
            "isSupportFallDetect": model.isSupportFallDetect,
            "isSupportRecording": model.isSupportRecording,
            "isFindDevice": model.isFindDevice,
            "isTakePhoto": model.isTakePhoto,
            "isLedLight": model.isLEDLight,
            "isWearDirection": model.isWearDir,
            "isVideoHid": model.isVideoHid,
            "isVideoHidBook": model.isVideoHidBook,
            "isVideoHidMusic": model.isVideoHidMusic,
            "isRaiseBrightScreen": model.isSupportRaisescreen,
            "isPowerOff": model.isPowerOff,
            "isFactoryReset": model.isResetFactory,
            "isPushMessage": model.isPushMsg
        ]
    }
}
