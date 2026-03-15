import Cocoa
import Quartz
import ServiceManagement
import Carbon.HIToolbox

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSUserNotificationCenterDelegate, BLEDelegate {
    struct IconPoint {
        let x: Int
        let y: Int
    }

    struct NowPlayingIconMask {
        let size: Int
        let ringPoints: [IconPoint]
        let trianglePoints: [IconPoint]
        let backgroundPoints: [IconPoint]
    }

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let ble = BLE()
    let mainMenu = NSMenu()
    let deviceMenu = NSMenu()
    let lockRSSIMenu = NSMenu()
    let unlockRSSIMenu = NSMenu()
    let timeoutMenu = NSMenu()
    let lockDelayMenu = NSMenu()
    var deviceDict: [UUID: NSMenuItem] = [:]
    var monitorMenuItem : NSMenuItem?
    let prefs = UserDefaults.standard
    var displaySleep = false
    var systemSleep = false
    var connected = false
    var userNotification: NSUserNotification?
    var nowPlayingWasPlaying = false
    var aboutBox: AboutBox? = nil
    var wakeTimer: Timer?
    var manualLock = false
    var unlockedAt = 0.0
    var inScreensaver = false
    var lastRSSI: Int? = nil
    let mediaKeyPlayPause: Int32 = 16
    let nowPlayingIconMasks: [NowPlayingIconMask] = AppDelegate.makeNowPlayingIconMasks()
    var displaySleepTimer: Timer?
    var displaySleepRetryTimer: Timer?
    var displaySleepRequestID = 0
    var lockSequenceActive = false
    var pendingUnlockAttempt = false
    var nowPlayingIconDetectedOnLock = false
    var nowPlayingResumePendingFromUncertainState = false
    var screenCaptureAccessRequestTriggered = false
    var screenCapturePermissionGuideShown = false

    func menuWillOpen(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.startScanning()
        } else if menu == lockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.lockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == unlockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.unlockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == timeoutMenu {
            for item in menu.items {
                if item.tag == Int(ble.signalTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == lockDelayMenu {
            for item in menu.items {
                if item.tag == Int(ble.proximityTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.menu == lockRSSIMenu {
            return menuItem.tag <= ble.unlockRSSI
        } else if menuItem.menu == unlockRSSIMenu {
            return menuItem.tag >= ble.lockRSSI
        }
        return true
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.stopScanning()
        }
    }
    
    func menuItemTitle(device: Device) -> String {
        var desc : String!
        if let mac = device.macAddr {
            let prettifiedMac = mac.replacingOccurrences(of: "-", with: ":").uppercased()
            desc = String(format: "%@ (%@)", device.description, prettifiedMac)
        } else {
            desc = device.description
        }
        return String(format: "%@ (%ddBm)", desc, device.rssi)
    }
    
    func newDevice(device: Device) {
        let menuItem = deviceMenu.addItem(withTitle: menuItemTitle(device: device), action:#selector(selectDevice), keyEquivalent: "")
        deviceDict[device.uuid] = menuItem
        if (device.uuid == ble.monitoredUUID) {
            menuItem.state = .on
        }
    }
    
    func updateDevice(device: Device) {
        if let menu = deviceDict[device.uuid] {
            menu.title = menuItemTitle(device: device)
        }
    }
    
    func removeDevice(device: Device) {
        if let menuItem = deviceDict[device.uuid] {
            menuItem.menu?.removeItem(menuItem)
        }
        deviceDict.removeValue(forKey: device.uuid)
    }

    func updateRSSI(rssi: Int?, active: Bool) {
        if let r = rssi {
            lastRSSI = r
            monitorMenuItem?.title = String(format:"%ddBm", r) + (active ? " (Active)" : "")
            if (!connected) {
                connected = true
                statusItem.button?.image = NSImage(named: "StatusBarConnected")
            }
        } else {
            monitorMenuItem?.title = t("not_detected")
            if (connected) {
                connected = false
                statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
            }
        }
    }

    func bluetoothPowerWarn() {
        errorModal(t("bluetooth_power_warn"))
    }

    func notifyUser(_ reason: String) {
        let un = NSUserNotification()
        un.title = "BLEUnlock"
        if reason == "lost" {
            un.subtitle = t("notification_lost_signal")
        } else if reason == "away" {
            un.subtitle = t("notification_device_away")
        }
        un.informativeText = t("notification_locked")
        un.deliveryDate = Date().addingTimeInterval(1)
        NSUserNotificationCenter.default.scheduleNotification(un)
        userNotification = un
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        if notification != userNotification {
            NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock/releases")!)
            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
        }
    }

    func runScript(_ arg: String) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        if let r = lastRSSI {
            process.arguments = [arg, String(r)]
        } else {
            process.arguments = [arg]
        }
        try? process.run()
    }

    func getNowPlayingIsPlaying(_ completion: @escaping (Bool) -> Void) {
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(DispatchQueue.main) { playing in
            completion(playing)
        }
    }

    static func pointInTriangle(x: Double, y: Double, a: (Double, Double), b: (Double, Double), c: (Double, Double)) -> Bool {
        let p = (x, y)
        let sign = { (p1: (Double, Double), p2: (Double, Double), p3: (Double, Double)) -> Double in
            return (p1.0 - p3.0) * (p2.1 - p3.1) - (p2.0 - p3.0) * (p1.1 - p3.1)
        }
        let d1 = sign(p, a, b)
        let d2 = sign(p, b, c)
        let d3 = sign(p, c, a)
        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)
        return !(hasNeg && hasPos)
    }

    static func makeNowPlayingIconMasks() -> [NowPlayingIconMask] {
        var masks: [NowPlayingIconMask] = []
        for size in 14...21 {
            var ringPoints: [IconPoint] = []
            var trianglePoints: [IconPoint] = []
            var backgroundPoints: [IconPoint] = []

            let center = (Double(size) - 1.0) / 2.0
            let outerRadius = Double(size) * 0.46
            let innerRadius = Double(size) * 0.31
            let triangleA = (Double(size) * 0.42, Double(size) * 0.30)
            let triangleB = (Double(size) * 0.42, Double(size) * 0.70)
            let triangleC = (Double(size) * 0.72, Double(size) * 0.50)

            for y in 0..<size {
                for x in 0..<size {
                    let px = Double(x) + 0.5
                    let py = Double(y) + 0.5
                    let d = hypot(px - center, py - center)
                    let point = IconPoint(x: x, y: y)

                    if d <= outerRadius && d >= innerRadius {
                        ringPoints.append(point)
                        continue
                    }
                    if pointInTriangle(x: px, y: py, a: triangleA, b: triangleB, c: triangleC) {
                        trianglePoints.append(point)
                        continue
                    }
                    if d <= innerRadius - 1.0 || (d >= outerRadius + 0.8 && d <= outerRadius + 2.2) {
                        backgroundPoints.append(point)
                    }
                }
            }

            guard !ringPoints.isEmpty, !trianglePoints.isEmpty, !backgroundPoints.isEmpty else { continue }
            masks.append(NowPlayingIconMask(size: size, ringPoints: ringPoints, trianglePoints: trianglePoints, backgroundPoints: backgroundPoints))
        }
        return masks
    }

    func openScreenCaptureSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]
        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        print("Failed to open Screen Recording settings URL")
    }

    func showScreenCapturePermissionGuideIfNeeded() {
        guard !screenCapturePermissionGuideShown else { return }
        screenCapturePermissionGuideShown = true

        let msg = NSAlert()
        msg.messageText = "Screen Recording permission is required"
        msg.informativeText = "To use \"Pause \\\"Now Playing\\\" while Locked\", allow BLEUnlock in:\n\nSystem Settings > Privacy & Security > Screen Recording\n\nAfter granting permission, quit and reopen BLEUnlock."
        msg.alertStyle = .warning
        msg.addButton(withTitle: "Open System Settings")
        msg.addButton(withTitle: "Later")
        msg.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)

        if msg.runModal() == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    func ensureScreenCaptureAccessForNowPlaying() -> Bool {
        if #available(macOS 10.15, *) {
            if CGPreflightScreenCaptureAccess() {
                return true
            }
            if !screenCaptureAccessRequestTriggered {
                screenCaptureAccessRequestTriggered = true
                print("Requesting Screen Recording permission for Now Playing icon detection.")
                if CGRequestScreenCaptureAccess() {
                    return true
                }
            }
            if CGPreflightScreenCaptureAccess() {
                return true
            }
            showScreenCapturePermissionGuideIfNeeded()
            return false
        }
        return false
    }

    func grayscalePixels(from image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return (pixels, width, height)
    }

    func sampleMean(_ points: [IconPoint], atX x: Int, y: Int, pixels: [UInt8], width: Int) -> Double {
        var total = 0.0
        for point in points {
            total += Double(pixels[(y + point.y) * width + (x + point.x)])
        }
        return total / Double(points.count)
    }

    func sampleRatio(_ points: [IconPoint], atX x: Int, y: Int, pixels: [UInt8], width: Int, matcher: (Double) -> Bool) -> Double {
        var matched = 0
        for point in points {
            let value = Double(pixels[(y + point.y) * width + (x + point.x)])
            if matcher(value) {
                matched += 1
            }
        }
        return Double(matched) / Double(points.count)
    }

    func matchesNowPlayingIconMask(_ mask: NowPlayingIconMask, atX x: Int, y: Int, pixels: [UInt8], width: Int) -> Bool {
        let ringMean = sampleMean(mask.ringPoints, atX: x, y: y, pixels: pixels, width: width)
        let triangleMean = sampleMean(mask.trianglePoints, atX: x, y: y, pixels: pixels, width: width)
        let bgMean = sampleMean(mask.backgroundPoints, atX: x, y: y, pixels: pixels, width: width)

        let fgWeight = Double(mask.ringPoints.count + mask.trianglePoints.count)
        let fgMean = (ringMean * Double(mask.ringPoints.count) + triangleMean * Double(mask.trianglePoints.count)) / fgWeight
        let contrast = abs(fgMean - bgMean)
        guard contrast >= 30.0 else { return false }

        let brightIcon = fgMean > bgMean
        let delta = max(8.0, contrast * 0.24)
        let ringRatio = sampleRatio(mask.ringPoints, atX: x, y: y, pixels: pixels, width: width) { value in
            brightIcon ? (value >= bgMean + delta) : (value <= bgMean - delta)
        }
        guard ringRatio >= 0.62 else { return false }

        let triangleRatio = sampleRatio(mask.trianglePoints, atX: x, y: y, pixels: pixels, width: width) { value in
            brightIcon ? (value >= bgMean + delta) : (value <= bgMean - delta)
        }
        guard triangleRatio >= 0.58 else { return false }

        let backgroundRatio = sampleRatio(mask.backgroundPoints, atX: x, y: y, pixels: pixels, width: width) { value in
            brightIcon ? (value <= fgMean - delta) : (value >= fgMean + delta)
        }
        return backgroundRatio >= 0.56
    }

    func containsNowPlayingIcon(in image: CGImage) -> Bool {
        guard let gray = grayscalePixels(from: image) else { return false }
        let width = gray.width
        let height = gray.height
        let pixels = gray.pixels

        for mask in nowPlayingIconMasks {
            guard width >= mask.size, height >= mask.size else { continue }
            let maxX = width - mask.size
            let maxY = height - mask.size
            for y in 0...maxY {
                for x in 0...maxX {
                    if matchesNowPlayingIconMask(mask, atX: x, y: y, pixels: pixels, width: width) {
                        return true
                    }
                }
            }
        }
        return false
    }

    func isNowPlayingIconVisibleInMenuBar() -> Bool {
        guard ensureScreenCaptureAccessForNowPlaying() else {
            print("Skip Now Playing control: screen recording permission is not granted.")
            return false
        }

        let displayID = CGMainDisplayID()
        let displayWidth = Int(CGDisplayPixelsWide(displayID))
        let displayHeight = Int(CGDisplayPixelsHigh(displayID))
        guard displayWidth > 0, displayHeight > 0 else { return false }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let searchWidth = min(Int(460 * scale), displayWidth)
        let menuBarHeight = max(Int(ceil(NSStatusBar.system.thickness * scale)), 1)
        let searchHeight = min(max(menuBarHeight + Int(10 * scale), menuBarHeight), displayHeight)

        let topRightRect = CGRect(
            x: CGFloat(displayWidth - searchWidth),
            y: 0,
            width: CGFloat(searchWidth),
            height: CGFloat(searchHeight)
        )
        let bottomRightRect = CGRect(
            x: CGFloat(displayWidth - searchWidth),
            y: CGFloat(displayHeight - searchHeight),
            width: CGFloat(searchWidth),
            height: CGFloat(searchHeight)
        )

        if let topImage = CGDisplayCreateImage(displayID, rect: topRightRect), containsNowPlayingIcon(in: topImage) {
            return true
        }
        if let bottomImage = CGDisplayCreateImage(displayID, rect: bottomRightRect), containsNowPlayingIcon(in: bottomImage) {
            return true
        }
        return false
    }

    func detectNowPlayingIconVisibleWithRetry(context: String, retries: Int, interval: TimeInterval, completion: @escaping (Bool) -> Void) {
        let maxRetries = max(retries, 0)
        func attempt(_ remainingRetries: Int, attemptNumber: Int) {
            let visible = isNowPlayingIconVisibleInMenuBar()
            print("Now Playing menu icon visible \(context) [attempt \(attemptNumber)]: \(visible)")
            if visible || remainingRetries == 0 {
                completion(visible)
                return
            }
            Timer.scheduledTimer(withTimeInterval: interval, repeats: false, block: { _ in
                attempt(remainingRetries - 1, attemptNumber: attemptNumber + 1)
            })
        }
        attempt(maxRetries, attemptNumber: 1)
    }

    func getNowPlayingPlaybackRate(_ completion: @escaping (Double?) -> Void) {
        MRMediaRemoteGetNowPlayingInfo(DispatchQueue.main) { info in
            guard let dict = info as? [AnyHashable: Any] else {
                completion(nil)
                return
            }
            for key in ["kMRMediaRemoteNowPlayingInfoPlaybackRate", "PlaybackRate"] {
                if let number = dict[key] as? NSNumber {
                    completion(number.doubleValue)
                    return
                }
            }
            for (key, value) in dict {
                if String(describing: key).localizedCaseInsensitiveContains("PlaybackRate"),
                   let number = value as? NSNumber {
                    completion(number.doubleValue)
                    return
                }
            }
            completion(nil)
        }
    }

    func detectNowPlayingState(_ completion: @escaping (Bool, Bool) -> Void) {
        getNowPlayingIsPlaying { playing in
            if playing {
                completion(true, true)
                return
            }
            self.getNowPlayingPlaybackRate { rate in
                if let r = rate {
                    completion(r > 0, true)
                } else {
                    completion(false, false)
                }
            }
        }
    }

    func hasNowPlayingContext(_ completion: @escaping (Bool) -> Void) {
        MRMediaRemoteGetNowPlayingInfo(DispatchQueue.main) { info in
            guard let dict = info as? [AnyHashable: Any], !dict.isEmpty else {
                completion(false)
                return
            }

            let stringKeys = [
                "kMRMediaRemoteNowPlayingInfoTitle", "Title",
                "kMRMediaRemoteNowPlayingInfoArtist", "Artist",
                "kMRMediaRemoteNowPlayingInfoAlbum", "Album",
            ]
            for key in stringKeys {
                if let value = dict[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(true)
                    return
                }
            }

            let numericKeys = [
                "kMRMediaRemoteNowPlayingInfoDuration", "Duration",
                "kMRMediaRemoteNowPlayingInfoElapsedTime", "ElapsedTime",
            ]
            for key in numericKeys {
                if let number = dict[key] as? NSNumber, number.doubleValue > 0 {
                    completion(true)
                    return
                }
            }

            for (key, value) in dict {
                let keyDesc = String(describing: key)
                if keyDesc.localizedCaseInsensitiveContains("Title")
                    || keyDesc.localizedCaseInsensitiveContains("Artist")
                    || keyDesc.localizedCaseInsensitiveContains("Album") {
                    if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        completion(true)
                        return
                    }
                }
            }

            completion(false)
        }
    }

    @discardableResult
    func sendNowPlayingCommand(_ command: MRCommand, name: String) -> Bool {
        let ok = MRMediaRemoteSendCommand(command, nil)
        print("MediaRemote \(name): \(ok ? "ok" : "failed")")
        return ok
    }

    func sendPlayPauseMediaKey() {
        let keyDownData1 = Int((mediaKeyPlayPause << 16) | (0xA << 8))
        let keyUpData1 = Int((mediaKeyPlayPause << 16) | (0xB << 8))

        let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: NSPoint.zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: Int16(8),
            data1: keyDownData1,
            data2: -1
        )
        let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: NSPoint.zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xB00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: Int16(8),
            data1: keyUpData1,
            data2: -1
        )
        keyDown?.cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp?.cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
        print("Sent play/pause media key fallback")
    }

    func requestDisplaySleepViaPMSet() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
            print("Requested display sleep via pmset fallback")
        } catch {
            print("Failed pmset displaysleepnow: \(error)")
        }
    }

    func cancelPendingDisplaySleepRequests() {
        displaySleepTimer?.invalidate()
        displaySleepTimer = nil
        displaySleepRetryTimer?.invalidate()
        displaySleepRetryTimer = nil
        displaySleepRequestID += 1
    }

    func canExecuteDisplaySleep(useScreensaver: Bool, requestID: Int) -> Bool {
        guard requestID == displaySleepRequestID else { return false }
        guard lockSequenceActive else { return false }
        guard !ble.presence else { return false }
        if useScreensaver {
            return inScreensaver
        }
        return isScreenLocked()
    }

    func fallbackToggleNowPlaying(after delay: TimeInterval, expectPlaying: Bool) {
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false, block: { _ in
            self.getNowPlayingIsPlaying { isPlaying in
                guard isPlaying != expectPlaying else { return }
                print("Now playing state mismatch. expected=\(expectPlaying) actual=\(isPlaying)")

                if !self.sendNowPlayingCommand(MRCommandTogglePlayPause, name: "toggle") {
                    self.sendPlayPauseMediaKey()
                    return
                }

                Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false, block: { _ in
                    self.getNowPlayingIsPlaying { toggledState in
                        guard toggledState != expectPlaying else { return }
                        self.sendPlayPauseMediaKey()
                    }
                })
            }
        })
    }

    func pauseNowPlaying(_ completion: (() -> Void)? = nil) {
        guard prefs.bool(forKey: "pauseItunes") else {
            completion?()
            return
        }
        nowPlayingIconDetectedOnLock = false
        nowPlayingWasPlaying = false
        nowPlayingResumePendingFromUncertainState = false
        detectNowPlayingIconVisibleWithRetry(context: "before lock", retries: 2, interval: 0.12) { iconVisible in
            guard iconVisible else {
                completion?()
                return
            }
            self.nowPlayingIconDetectedOnLock = true

            self.detectNowPlayingState { playing, confident in
                self.nowPlayingWasPlaying = playing

                // Always issue pause once. Some players are controllable from Control Center
                // but may not report the playing state through the old boolean API.
                print("pause")
                var pausedByCommand = self.sendNowPlayingCommand(MRCommandPause, name: "pause")
                if !pausedByCommand {
                    pausedByCommand = self.sendNowPlayingCommand(MRCommandTogglePlayPause, name: "toggle")
                }
                if !pausedByCommand {
                    self.sendPlayPauseMediaKey()
                    pausedByCommand = true
                }

                if self.nowPlayingWasPlaying || !confident {
                    self.fallbackToggleNowPlaying(after: 0.35, expectPlaying: false)
                }
                if !self.nowPlayingWasPlaying && !confident && pausedByCommand {
                    self.nowPlayingResumePendingFromUncertainState = true
                    print("Playback state uncertain; will try resume on unlock if menu icon is still visible.")
                }
                Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false, block: { _ in
                    completion?()
                })
            }
        }
    }
    
    func playNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        guard nowPlayingIconDetectedOnLock else {
            nowPlayingWasPlaying = false
            nowPlayingResumePendingFromUncertainState = false
            return
        }
        let shouldAttemptResume = nowPlayingWasPlaying || nowPlayingResumePendingFromUncertainState
        guard shouldAttemptResume else {
            nowPlayingIconDetectedOnLock = false
            return
        }

        detectNowPlayingIconVisibleWithRetry(context: "before resume", retries: 5, interval: 0.2) { iconVisibleOnUnlock in
            guard iconVisibleOnUnlock else {
                print("Skip resume: Now Playing icon is not visible on unlock.")
                self.nowPlayingWasPlaying = false
                self.nowPlayingResumePendingFromUncertainState = false
                self.nowPlayingIconDetectedOnLock = false
                return
            }

            print("play")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
                if !self.sendNowPlayingCommand(MRCommandPlay, name: "play") {
                    self.sendPlayPauseMediaKey()
                }
                // Do a gentle retry with Play only (no toggle) to avoid
                // play->toggle interruptions when the state callback lags.
                Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false, block: { _ in
                    self.getNowPlayingIsPlaying { isPlaying in
                        guard !isPlaying else { return }
                        if !self.sendNowPlayingCommand(MRCommandPlay, name: "play-retry") {
                            self.sendPlayPauseMediaKey()
                        }
                    }
                })
                self.nowPlayingWasPlaying = false
                self.nowPlayingResumePendingFromUncertainState = false
                self.nowPlayingIconDetectedOnLock = false
            })
        }
    }

    func lockOrSaveScreen() {
        let useScreensaver = prefs.bool(forKey: "screensaver")
        let shouldSleepDisplay = prefs.bool(forKey: "sleepDisplay")
        lockSequenceActive = true

        if useScreensaver {
            NSWorkspace.shared.launchApplication("ScreenSaverEngine")
        } else {
            if SACLockScreenImmediate() != 0 {
                print("Failed to lock screen")
            }
        }

        if shouldSleepDisplay {
            cancelPendingDisplaySleepRequests()
            let requestID = displaySleepRequestID
            if useScreensaver {
                // For screensaver mode: keep screensaver first, then sleep display once after 3s.
                displaySleepTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false, block: { _ in
                    guard self.canExecuteDisplaySleep(useScreensaver: true, requestID: requestID) else { return }
                    print("sleep display (screensaver mode)")
                    sleepDisplay()
                    if !self.displaySleep {
                        self.requestDisplaySleepViaPMSet()
                    }
                })
            } else {
                displaySleepTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false, block: { _ in
                    guard self.canExecuteDisplaySleep(useScreensaver: false, requestID: requestID) else { return }

                    print("sleep display")
                    sleepDisplay()
                    // Tahoe sometimes drops the first request during lock transition.
                    self.displaySleepRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false, block: { _ in
                        guard self.canExecuteDisplaySleep(useScreensaver: false, requestID: requestID) else { return }

                        sleepDisplay()
                        if !self.displaySleep {
                            self.requestDisplaySleepViaPMSet()
                        }
                    })
                })
            }
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        if presence {
            if ble.unlockRSSI != ble.UNLOCK_DISABLED {
                cancelPendingDisplaySleepRequests()
                if !isScreenLocked() && !inScreensaver {
                    lockSequenceActive = false
                }
                if let un = userNotification {
                    NSUserNotificationCenter.default.removeDeliveredNotification(un)
                    userNotification = nil
                }
                if displaySleep && !systemSleep && prefs.bool(forKey: "wakeOnProximity") {
                    print("Waking display")
                    wakeDisplay()
                    wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { _ in
                        print("Retrying waking display")
                        wakeDisplay()
                    })
                }
                tryUnlockScreen()
            }
        } else {
            if !lockSequenceActive && !isScreenLocked() && !inScreensaver && !displaySleep && ble.lockRSSI != ble.LOCK_DISABLED {
                pauseNowPlaying {
                    self.lockOrSaveScreen()
                    self.notifyUser(reason)
                    self.runScript(reason)
                }
            }
            manualLock = false
        }
    }

    func postKeyPress(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }

    func fakeKeyStrokes(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        // Send 20 characters per keyboard event. That seems to be the limit.
        let PER = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: PER) {
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
            buffer.deallocate()
        }
        
        // Press both Return and keypad Enter for better compatibility on Tahoe lock screen.
        postKeyPress(CGKeyCode(kVK_Return))
        postKeyPress(CGKeyCode(kVK_ANSI_KeypadEnter))
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }
    
    func tryUnlockScreen() {
        guard !manualLock else { return }
        guard ble.presence else { return }
        guard ble.unlockRSSI != ble.UNLOCK_DISABLED else { return }
        guard !systemSleep else { return }
        guard !displaySleep else { return }
        guard !pendingUnlockAttempt else { return }

        guard !self.prefs.bool(forKey: "wakeWithoutUnlocking") else { return }

        pendingUnlockAttempt = true
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
            self.pendingUnlockAttempt = false
            guard self.isScreenLocked() || self.inScreensaver else { return }

            let inputPassword = {
                guard let password = self.fetchPassword(warn: true) else { return }
                print("Entering password")
                self.unlockedAt = Date().timeIntervalSince1970
                self.fakeKeyStrokes(password)
                self.runScript("unlocked")
            }

            if self.inScreensaver {
                // In screensaver mode, first reveal the login panel.
                self.postKeyPress(CGKeyCode(kVK_Shift))
                Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false, block: { _ in
                    guard self.ble.presence else { return }
                    guard !self.displaySleep else { return }
                    guard !self.systemSleep else { return }
                    guard self.isScreenLocked() || self.inScreensaver else { return }
                    inputPassword()
                })
                return
            }

            inputPassword()
        })
    }

    @objc func onDisplayWake() {
        print("display wake")
        //unlockedAt = Date().timeIntervalSince1970
        displaySleep = false
        cancelPendingDisplaySleepRequests()
        wakeTimer?.invalidate()
        wakeTimer = nil
        tryUnlockScreen()
    }

    @objc func onDisplaySleep() {
        print("display sleep")
        displaySleep = true
    }

    @objc func onSystemWake() {
        print("system wake")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            print("delayed system wake job")
            NSApp.setActivationPolicy(.accessory) // Hide Dock icon again
            self.systemSleep = false
            self.tryUnlockScreen()
        })
    }
    
    @objc func onSystemSleep() {
        print("system sleep")
        systemSleep = true
        // Set activation policy to regular, so the CBCentralManager can scan for peripherals
        // when the Bluetooth will become on again.
        // This enables Dock icon but the screen is off anyway.
        NSApp.setActivationPolicy(.regular)
    }

    @objc func onUnlock() {
        cancelPendingDisplaySleepRequests()
        pendingUnlockAttempt = false
        lockSequenceActive = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            print("onUnlock")
            let autoUnlockRecently = Date().timeIntervalSince1970 < self.unlockedAt + 10
            if !autoUnlockRecently {
                if self.ble.unlockRSSI != self.ble.UNLOCK_DISABLED {
                    self.runScript("intruded")
                }
            }
            if self.nowPlayingWasPlaying || self.nowPlayingResumePendingFromUncertainState {
                self.playNowPlaying()
            }
        })
        manualLock = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            checkUpdate()
        })
    }

    @objc func onScreensaverStart() {
        print("screensaver start")
        inScreensaver = true
    }

    @objc func onScreensaverStop() {
        print("screensaver stop")
        inScreensaver = false
        cancelPendingDisplaySleepRequests()
    }

    @objc func selectDevice(item: NSMenuItem) {
        for (uuid, menuItem) in deviceDict {
            if menuItem == item {
                monitorDevice(uuid: uuid)
                prefs.set(uuid.uuidString, forKey: "device")
                menuItem.state = .on
            } else {
                menuItem.state = .off
            }
        }
    }

    func monitorDevice(uuid: UUID) {
        connected = false
        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        monitorMenuItem?.title = t("not_detected")
        ble.startMonitor(uuid: uuid)
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    func storePassword(_ password: String) {
        let pw = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecAttrLabel): "BLEUnlock",
            String(kSecValueData): pw,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            let err = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to store password to Keychain", info: err as String? ?? "Status \(status)")
            return
        }
    }

    func fetchPassword(warn: Bool = false) -> String? {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecReturnData): kCFBooleanTrue!,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if (status == errSecItemNotFound) {
            print("Password is not stored")
            if warn {
                errorModal(t("password_not_set"))
            }
            return nil
        }
        guard status == errSecSuccess else {
            let info = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to retrieve password", info: info as String? ?? "Status \(status)")
            return nil
        }
        guard let data = item as? Data else {
            errorModal("Failed to convert password")
            return nil
        }
        return String(data: data, encoding: .utf8)!
    }
    
    @objc func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_password")
        msg.informativeText = t("password_info")
        msg.window.title = "BLEUnlock"

        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let pw = txt.stringValue
            storePassword(pw)
        }
    }
    
    @objc func setRSSIThreshold() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_rssi_threshold")
        msg.informativeText = t("enter_rssi_threshold_info")
        msg.window.title = "BLEUnlock"
        
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        txt.placeholderString = String(ble.thresholdRSSI)
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let val = txt.intValue
            ble.thresholdRSSI = Int(val)
            prefs.set(val, forKey: "thresholdRSSI")
        }
    }

    @objc func toggleWakeOnProximity(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "wakeOnProximity")
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: "wakeOnProximity")
    }

    @objc func setLockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockRSSI")
        ble.lockRSSI = value
    }
    
    @objc func setUnlockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "unlockRSSI")
        ble.unlockRSSI = value
    }

    @objc func setTimeout(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "timeout")
        ble.signalTimeout = Double(value)
    }

    @objc func setLockDelay(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockDelay")
        ble.proximityTimeout = Double(value)
    }

    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        let launchAtLogin = !prefs.bool(forKey: "launchAtLogin")
        prefs.set(launchAtLogin, forKey: "launchAtLogin")
        menuItem.state = launchAtLogin ? .on : .off
        SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! + ".Launcher" as CFString, launchAtLogin)
    }

    @objc func togglePauseNowPlaying(_ menuItem: NSMenuItem) {
        let pauseNowPlaying = !prefs.bool(forKey: "pauseItunes")
        prefs.set(pauseNowPlaying, forKey: "pauseItunes")
        menuItem.state = pauseNowPlaying ? .on : .off
    }
    
    @objc func toggleUseScreensaver(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "screensaver")
        prefs.set(value, forKey: "screensaver")
        menuItem.state = value ? .on : .off
    }

    @objc func toggleSleepDisplay(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "sleepDisplay")
        prefs.set(value, forKey: "sleepDisplay")
        menuItem.state = value ? .on : .off
    }
    
    @objc func togglePassiveMode(_ menuItem: NSMenuItem) {
        let passiveMode = !prefs.bool(forKey: "passiveMode")
        prefs.set(passiveMode, forKey: "passiveMode")
        menuItem.state = passiveMode ? .on : .off
        ble.setPassiveMode(passiveMode)
    }

    @objc func toggleWakeWithoutUnlocking(_ menuItem: NSMenuItem) {
        let wakeWithoutUnlocking = !prefs.bool(forKey: "wakeWithoutUnlocking")
        prefs.set(wakeWithoutUnlocking, forKey: "wakeWithoutUnlocking")
        menuItem.state = wakeWithoutUnlocking ? .on : .off
    }

    @objc func lockNow() {
        guard !isScreenLocked() else { return }
        manualLock = true
        pauseNowPlaying {
            self.lockOrSaveScreen()
        }
    }
    
    @objc func showAboutBox() {
        AboutBox.showAboutBox()
    }

    func constructRSSIMenu(_ menu: NSMenu, _ action: Selector) {
        menu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            let item = menu.addItem(withTitle: String(format: "%ddBm", proximity), action: action, keyEquivalent: "")
            item.tag = proximity
        }
        menu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        menu.delegate = self
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("device_not_set"), action: nil, keyEquivalent: "")
        
        var item: NSMenuItem

        item = mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())

        item = mainMenu.addItem(withTitle: t("device"), action: nil, keyEquivalent: "")
        item.submenu = deviceMenu
        deviceMenu.delegate = self
        deviceMenu.addItem(withTitle: t("scanning"), action: nil, keyEquivalent: "")

        let unlockRSSIItem = mainMenu.addItem(withTitle: t("unlock_rssi"), action: nil, keyEquivalent: "")
        unlockRSSIItem.submenu = unlockRSSIMenu
        item = unlockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setUnlockRSSI), keyEquivalent: "")
        item.tag = ble.UNLOCK_DISABLED
        constructRSSIMenu(unlockRSSIMenu, #selector(setUnlockRSSI))

        let lockRSSIItem = mainMenu.addItem(withTitle: t("lock_rssi"), action: nil, keyEquivalent: "")
        lockRSSIItem.submenu = lockRSSIMenu
        constructRSSIMenu(lockRSSIMenu, #selector(setLockRSSI))
        item = lockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setLockRSSI), keyEquivalent: "")
        item.tag = ble.LOCK_DISABLED

        let lockDelayItem = mainMenu.addItem(withTitle: t("lock_delay"), action: nil, keyEquivalent: "")
        lockDelayItem.submenu = lockDelayMenu
        lockDelayMenu.addItem(withTitle: "2 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 2
        lockDelayMenu.addItem(withTitle: "5 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 5
        lockDelayMenu.addItem(withTitle: "15 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 15
        lockDelayMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 30
        lockDelayMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setLockDelay), keyEquivalent: "").tag = 60
        lockDelayMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 120
        lockDelayMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 300
        lockDelayMenu.delegate = self

        let timeoutItem = mainMenu.addItem(withTitle: t("timeout"), action: nil, keyEquivalent: "")
        timeoutItem.submenu = timeoutMenu
        timeoutMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setTimeout), keyEquivalent: "").tag = 30
        timeoutMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setTimeout), keyEquivalent: "").tag = 60
        timeoutMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 120
        timeoutMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 300
        timeoutMenu.addItem(withTitle: "10 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 600
        timeoutMenu.delegate = self

        item = mainMenu.addItem(withTitle: t("wake_on_proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        if prefs.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("wake_without_unlocking"), action: #selector(toggleWakeWithoutUnlocking), keyEquivalent: "")
        if prefs.bool(forKey: "wakeWithoutUnlocking") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("pause_now_playing"), action: #selector(togglePauseNowPlaying), keyEquivalent: "")
        if prefs.bool(forKey: "pauseItunes") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("use_screensaver_to_lock"), action: #selector(toggleUseScreensaver), keyEquivalent: "")
        if prefs.bool(forKey: "screensaver") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("sleep_display"), action: #selector(toggleSleepDisplay), keyEquivalent: "")
        if prefs.bool(forKey: "sleepDisplay") {
            item.state = .on
        }
        
        mainMenu.addItem(withTitle: t("set_password"), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: t("passive_mode"), action: #selector(togglePassiveMode), keyEquivalent: "")
        item.state = prefs.bool(forKey: "passiveMode") ? .on : .off
        
        item = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off
        
        mainMenu.addItem(withTitle: t("set_rssi_threshold"), action: #selector(setRSSIThreshold),
                         keyEquivalent: "")

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = mainMenu
    }

    func checkAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        if (!AXIsProcessTrustedWithOptions([key: true] as CFDictionary)) {
            // Sometimes Prompt option above doesn't work.
            // Actually trying to send key may open that dialog.
            let src = CGEventSource(stateID: .hidSystemState)
            // "Fn" key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            constructMenu()
        }
        ble.delegate = self
        if let str = prefs.string(forKey: "device") {
            if let uuid = UUID(uuidString: str) {
                monitorDevice(uuid: uuid)
            }
        }
        let lockRSSI = prefs.integer(forKey: "lockRSSI")
        if lockRSSI != 0 {
            ble.lockRSSI = lockRSSI
        }
        let unlockRSSI = prefs.integer(forKey: "unlockRSSI")
        if unlockRSSI != 0 {
            ble.unlockRSSI = unlockRSSI
        }
        let timeout = prefs.integer(forKey: "timeout")
        if timeout != 0 {
            ble.signalTimeout = Double(timeout)
        }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI")
        if thresholdRSSI != 0 {
            ble.thresholdRSSI = thresholdRSSI
        }
        let lockDelay = prefs.integer(forKey: "lockDelay")
        if lockDelay != 0 {
            ble.proximityTimeout = Double(lockDelay)
        }

        NSUserNotificationCenter.default.delegate = self

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStart), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStop), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)

        if ble.unlockRSSI != ble.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") && fetchPassword() == nil {
            askPassword()
        }
        checkAccessibility()
        checkUpdate()

        // Hide dock icon.
        // This is required because we can't have LSUIElement set to true in Info.plist,
        // otherwise CBCentralManager.scanForPeripherals won't work.
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
}
