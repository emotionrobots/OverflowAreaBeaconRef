//
//  FusedBeaconManager.swift
//  OverflowAreaBeaconRef
//
//  Created by David G. Young on 9/9/20.
//  Copyright © 2020 davidgyoungtech. All rights reserved.
//

import CoreBluetooth
import CoreLocation
import UIKit

@objc
class FusedBeaconManager: NSObject, CLLocationManagerDelegate, CBCentralManagerDelegate, CBPeripheralManagerDelegate {
    static let shared = FusedBeaconManager()
    
    // Create background manager instance
    private let backgroundBeaconManager = BackgroundBeaconManager.shared
    
    // Create location manager instance
    private var _locationManager: CLLocationManager?
    public var locationManager: CLLocationManager {
        get {
            if let l = _locationManager {
                return l
            }
            else {
                let l = CLLocationManager()
                l.delegate = self
                _locationManager = l
                return l
            }
        }
    }
    
    // Peripheral manager and Central Manager variables and work queues
    private var peripheralManager: CBPeripheralManager? = nil
    private var centralManager: CBCentralManager? = nil
    private let centralQueue = DispatchQueue.global(qos: .userInitiated)
    private let peripheralQueue = DispatchQueue.global(qos: .userInitiated)
    
    // Beacon info
    private var beaconUuid: UUID? = nil
    private var beaconMajor: UInt16? = nil
    private var beaconMinor: UInt16? = nil
    private var measuredPower: Int8? = nil
    public var errors: Set<String> = []
    private var delegate: BeaconDetectDelegate?
    private var active = true
    private var initialized = false
    private var txEnabled = false
    private var txStarted = false
    private var scanningEnabled = false
    private var scanningStarted = false

    //==========================================================================================
    // Configure beacon
    //==========================================================================================
    @objc
    public func configure(iBeaconUuid: UUID, overflowMatchingByte: UInt8, major: UInt16, minor: UInt16, measuredPower: Int8) {
        self.backgroundBeaconManager.matchingByte = 0xaa
        self.beaconUuid = iBeaconUuid
        self.beaconMajor = major
        self.beaconMinor = minor
        self.measuredPower = measuredPower
    }
        
    //==========================================================================================
    // Start advertisement - must be called on main thread
    //==========================================================================================
    @objc
    public func startTx() -> Bool {
        txEnabled = true
        if (!initialized) {
            initialize()
        }
        if !active {
            return false
        }
        if self.peripheralManager?.state == CBManagerState.poweredOn {
            if let major = self.beaconMajor, let minor = self.beaconMinor, let uuid = self.beaconUuid, let power = self.measuredPower {
                self.backgroundBeaconManager.stopAdvertising()
                // Always set up to advertise overflow (even when we are in the foreground), because we are blocked from
                // doing so when we are in the background.
                let overflowBytes = [UInt8(major >> 8), UInt8(major & 0xff), UInt8(minor >> 8), UInt8(minor & 0xff)]
                self.backgroundBeaconManager.startAdvertising(beaconBytes: overflowBytes)
                txStarted = true
                
                /*
                // In the foreground we will immediately overrwrite this advert with iBeacon
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now()+0.1) {
                    self.peripheralManager?.stopAdvertising()
                    // We are in the foreground.  Advertise iBeacon.  But wait a bit before we do or it does not take effect
                    let peripheralData = CLBeaconRegion(uuid: uuid, major: major, minor: minor, identifier: "dummy").peripheralData(withMeasuredPower: power as NSNumber)
                    self.peripheralManager?.startAdvertising(peripheralData as? [String: Any])
                }
                */
                
                return true
                
            }
            else {
              NSLog("Configure not called.  Cannot transmit")
                return false
            }
        }
        else {
            NSLog("Cannot start transmitting without bluetooth powered off")
            return false
        }
    }
    
    //==========================================================================================
    //  Start scanning for beacons
    //==========================================================================================
    public func startScanning(delegate: BeaconDetectDelegate) -> Bool {
        scanningEnabled = true;
        self.delegate = delegate
        if (!initialized) {
            initialize()
        }
        if centralManager?.state == CBManagerState.poweredOn {
            locationManager.startRangingBeacons(satisfying: CLBeaconIdentityConstraint(uuid: beaconUuid!))
            centralManager?.scanForPeripherals(withServices: OverflowAreaUtils.allOverflowServiceUuids(), options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scanningStarted = true
            return true
        }
        else {
            NSLog("Cannot start scanning yet... peripheral is not powered on")
            scanningStarted = false
            return false
        }
    }

    //==========================================================================================
    //  Stop scanning
    //==========================================================================================
    @objc
    public func stopScanning() {
        scanningEnabled = false
        scanningStarted = false
        if (!initialized) {
            initialize()
        }
        centralManager?.stopScan()
        for constraint in locationManager.rangedBeaconConstraints {
            locationManager.stopRangingBeacons(satisfying: constraint)
        }
    }
    
    //==========================================================================================
    //  Stop advertising
    //==========================================================================================
    @objc
    public func stopTx() -> Bool {
        txEnabled = false
        if active {
            txStarted = false
            if (!initialized) {
                initialize()
            }
            self.backgroundBeaconManager.stopAdvertising()
            return true
        }
        else {
            return false
        }
    }
    
    //==========================================================================================
    // Initialize FuseBeaconManager
    //==========================================================================================
    private func initialize() {
        if (initialized) {
            return
        }
        
        // Add notification alert observer - namely start advertisement when woken and
        // set active flag to false when entering background
        DispatchQueue.main.async {
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                self.active = true
                if (self.txEnabled && !self.txStarted) {
                    _ = self.startTx()
                }
            }
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                self.active = false
            }
        }
        
        initialized = true
        
        // Create central manager to listen for beacons
        self.centralManager = CBCentralManager(delegate: self, queue: centralQueue)

        // Create peripheral manager to advertising beacons
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: peripheralQueue, options: [:])
        BackgroundBeaconManager.shared.peripheralManager = self.peripheralManager!
                
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = 3000.0
        
        if #available(iOS 9.0, *) {
          locationManager.allowsBackgroundLocationUpdates = true
        } else {
          // not needed on earlier versions
        }
        // start updating location at beginning just to give us unlimited background running time
        self.locationManager.startUpdatingLocation()
        
        periodicallySendScreenOnNotifications()
        extendBackgroundRunningTime()
    }

    
    //==========================================================================================
    // Start a periodic wake to send notification every 30 seconds
    //==========================================================================================
    private func periodicallySendScreenOnNotifications() {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now()+30.0) {
            self.sendNotification()
            self.periodicallySendScreenOnNotifications()
        }
    }

    //==========================================================================================
    // Send a notification alert to wake the app with display ON; sound turned off
    //==========================================================================================
    private func sendNotification() {
        DispatchQueue.main.async {
            let center = UNUserNotificationCenter.current()
            center.removeAllDeliveredNotifications()
            let content = UNMutableNotificationContent()
            content.title = "Scanning OverflowArea beacons"
            content.body = ""
            content.categoryIdentifier = "low-priority"
            //let soundName = UNNotificationSoundName("silence.mp3")
            //content.sound = UNNotificationSound(named: soundName)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
    
    //==========================================================================================
    // Central Manager callback when a state has been updated. State is Bluetooth powered ON
    // or OFF. If ON, start scanning
    //==========================================================================================
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == CBManagerState.poweredOn {
            DispatchQueue.main.async {
                if self.scanningEnabled && !self.scanningStarted {
                    if let delegate = self.delegate {
                        _ = self.startScanning(delegate: delegate)
                    }
                }
                self.errors.remove("Bluetooth off")
                BeaconStateModel.shared.error = self.errors.first
            }
        }
        if central.state == CBManagerState.poweredOff {
            DispatchQueue.main.async {
                self.errors.insert("Bluetooth off")
                BeaconStateModel.shared.error = self.errors.first
            }
        }
    }
    
    //==========================================================================================
    // Central Manager callback when a periperal has been discovered
    //==========================================================================================
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let beaconBytes = BackgroundBeaconManager.shared.extractBeaconBytes(peripheral: peripheral, advertisementData: advertisementData, countToExtract: 4) {
            let major = UInt16(beaconBytes[0]) << 8 + UInt16(beaconBytes[1])
            let minor = UInt16(beaconBytes[2]) << 8 + UInt16(beaconBytes[3])
            NSLog("I just read overflow area advert with major: \(major) minor: \(minor)")
            delegate?.didDetectBeacon(type: "OverflowArea", major: major, minor: minor, rssi: RSSI.intValue, proximityUuid: nil, distance: nil)
        }
    }
    
    //==========================================================================================
    // Peripheral Manager callback when state has been updated
    //==========================================================================================
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == CBManagerState.poweredOn {
            DispatchQueue.main.async {
                self.errors.remove("Bluetooth off")
                BeaconStateModel.shared.error = self.errors.first
                if (self.txEnabled && !self.txStarted) {
                    _ = self.startTx()
                }
            }
        }
        else{
        }
        NSLog("Bluetooth power state changed to \(peripheral.state)")
    }

    //==========================================================================================
    // Peripheral manager callback when advertisement starts
    //==========================================================================================
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    }
    
    private var backgroundTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var threadStarted = false
    private var threadShouldExit = false
    
    //==========================================================================================
    // Extend the background running time by creating a dummy task
    //==========================================================================================
    private func extendBackgroundRunningTime() {
      if (threadStarted) {
        // if we are in here, that means the background task is already running.
        // don't restart it.
        return
      }
      threadStarted = true
      NSLog("Attempting to extend background running time")
      
      self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DummyTask", expirationHandler: {
        NSLog("Background task expired by iOS.")
        UIApplication.shared.endBackgroundTask(self.backgroundTask)
      })

    
      var lastLogTime = 0.0
      DispatchQueue.global().async {
        let startedTime = Int(Date().timeIntervalSince1970) % 10000000
        NSLog("*** STARTED BACKGROUND THREAD")
        while(!self.threadShouldExit) {
            DispatchQueue.main.async {
                let now = Date().timeIntervalSince1970
                let backgroundTimeRemaining = UIApplication.shared.backgroundTimeRemaining
                if abs(now - lastLogTime) >= 2.0 {
                    lastLogTime = now
                    if backgroundTimeRemaining < 10.0 {
                      NSLog("About to suspend based on background thread running out.")
                    }
                    if (backgroundTimeRemaining < 200000.0) {
                     NSLog("Thread \(startedTime) background time remaining: \(backgroundTimeRemaining)")
                    }
                    else {
                      //NSLog("Thread \(startedTime) background time remaining: INFINITE")
                    }
                }
            }
            sleep(1)
        }
        self.threadStarted = false
        NSLog("*** EXITING BACKGROUND THREAD")
      }

    }
    
    //==========================================================================================
    // Peripheral callback when service has been modified
    //==========================================================================================
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    }
    
    //==========================================================================================
    // LocationManager callback when authorization status has changed
    //==========================================================================================
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthWarnings()
    }
    
    //==========================================================================================
    // Update authorization warning message by checking current status of various authorization
    //==========================================================================================
    func updateAuthWarnings() {
        if CLLocationManager.locationServicesEnabled() {
            self.errors.remove("Location disabled in settings")
            if CLLocationManager.authorizationStatus() == .authorizedAlways {
                self.errors.remove("Location permission not set to always")
            }
            else {
                self.errors.insert("Location permission not set to always")
            }
        }
        else {
            self.errors.insert("Location disabled in settings")
        }
        if CBManager.authorization == .allowedAlways {
            self.errors.remove("Bluetooth permission denied")
        }
        else {
            self.errors.insert("Bluetooth permission denied")
        }
        UNUserNotificationCenter.current().getNotificationSettings(completionHandler: { settings in
            if settings.authorizationStatus == UNAuthorizationStatus.authorized {
                self.errors.remove("Notification permission denied")
            }
            else {
                self.errors.insert("Notification permission denied")
            }
            DispatchQueue.main.async {
                BeaconStateModel.shared.error = self.errors.first
            }
        })
    }
    
    //==========================================================================================
    //  Location manager delegate DidRangeBeacon - listener has discovered beacon
    //==========================================================================================
    func locationManager(_ manager: CLLocationManager, didRangeBeacons beacons: [CLBeacon], in region: CLBeaconRegion) {
        for beacon in beacons {
            NSLog("I just read iBeacon advert with major: \(beacon.major) minor: \(beacon.minor)")

            delegate?.didDetectBeacon(type: "iBeacon", major: beacon.major.uint16Value, minor: beacon.minor.uint16Value, rssi: beacon.rssi, proximityUuid: beacon.uuid, distance: beacon.accuracy)
        }
    }
    
}

/*
protocol OverflowDetectorDelegate {
    func didDetectBeacon(type: String, major: UInt16, minor: UInt16, rssi: Int, proximityUuid: UUID?, distance: Double?)
}
*/
