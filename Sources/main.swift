// ClamshellAwake - menu bar toggle for `pmset disablesleep`.
// Keeps a MacBook awake with the lid closed (no external display needed),
// automatically on AC and, after a cooldown, lets it sleep normally on battery.

import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement

enum Mode: String, CaseIterable {
    case auto, awake, normal
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .awake: return "Always Awake"
        case .normal: return "Normal Sleep"
        }
    }

    /// One short line under the title. Auto's surprise (on battery it will
    /// not idle-sleep while the lid is open) is not here: the status line
    /// states it whenever it is in effect, and the tooltip always carries it.
    var subtitle: String {
        switch self {
        case .auto: return "Awake when plugged in, sleeps on battery"
        case .awake: return "Never sleeps, even on battery"
        case .normal: return "macOS sleeps as usual"
        }
    }

    /// Tooltip: the full story behind each mode, including what Auto costs.
    var tip: String {
        switch self {
        case .auto:
            return "Recommended for long-running tasks such as AI agents, builds and downloads.\n"
                + "Plugged in: never sleeps, so the Mac keeps working with the lid closed.\n"
                + "On battery: closing the lid does not sleep the Mac at once. It starts the "
                + "Sleep Delay on Battery, and the Mac sleeps if it is not plugged in before that runs out.\n"
                + "Trade-off: on battery with the lid open, the Mac will not sleep by itself, so left "
                + "unplugged and untouched it runs until the battery is empty. The display still "
                + "turns off on its own timer."
        case .awake:
            return "Never sleeps, plugged in or on battery, lid open or closed, whatever System Settings say. "
                + "Careful in a bag: on battery it runs until the battery is empty. "
                + "The display still turns off on its own timer."
        case .normal:
            return "macOS's own rules, unchanged: closing the lid sleeps the Mac, and the timers under "
                + "macOS Sleep Settings apply. Auto's lid behaviour does not affect this mode."
        }
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/clamshell-awake.log")
    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static func write(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

enum Shell {
    static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

enum Power {
    static func onAC() -> Bool {
        let snap = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let t = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() else { return true }
        return (t as String) == (kIOPSACPowerValue as String)
    }

    /// True when the lid is shut. nil on a Mac with no clamshell, and on any
    /// read failure: callers fall back to the old unplug-keyed behaviour.
    static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                                kCFAllocatorDefault, 0)?.takeRetainedValue()
        return v as? Bool
    }

    /// One line per power profile summarising the macOS idle-sleep rules from
    /// System Settings (Battery / Energy), read from `pmset -g custom`.
    static func policySummary() -> [String] {
        let (_, out) = Shell.run("/usr/bin/pmset", ["-g", "custom"])
        var profiles: [(String, [String: Int])] = []
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                profiles.append((String(line.dropLast()), [:]))
            } else if !profiles.isEmpty {
                let parts = line.split(separator: " ")
                if parts.count >= 2, let v = Int(parts.last!) {
                    profiles[profiles.count - 1].1[parts.dropLast().joined(separator: " ")] = v
                }
            }
        }
        return profiles.map { name, kv in
            let label = name == "AC Power" ? "Plugged in" : name == "Battery Power" ? "On battery" : name
            let disp = kv["displaysleep"] ?? 0
            let slp = kv["sleep"] ?? 0
            var parts: [String] = []
            parts.append(disp == 0 ? "display never off" : "display off after \(disp) min")
            if slp == 0 { parts.append("never sleeps when idle") }
            else if slp <= disp { parts.append("then sleeps") }
            else { parts.append("sleeps after \(slp) min") }
            if kv["womp"] == 1 { parts.append("wakes for network access") }
            return "\(label): " + parts.joined(separator: ", ")
        }
    }

    /// Sleeps the Mac now, as the Apple menu does. Clearing `disablesleep`
    /// with the lid already shut does not sleep the Mac: macOS only consults
    /// the flag on the lid-close transition, so after that it is down to the
    /// idle timer, and any PreventUserIdleSystemSleep assertion (audio,
    /// DaVinci Resolve's "Background Activity", a backup) holds that off
    /// indefinitely. A forced sleep ignores those assertions. No root needed.
    static func forceSleep() -> Bool {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else { return false }
        defer { IOServiceClose(port) }
        return IOPMSleepSystem(port) == kIOReturnSuccess
    }

    /// True when the sudoers rule from installSudoRule lets this user run
    /// pmset without a password. Re-writes the flag's current value through
    /// `sudo -n`, which is a no-op for pmset but exercises the exact rule.
    /// (`sudo -l` is not usable here: for an admin it approves any command.)
    static func sudoRuleInstalled(current: Bool?) -> Bool {
        guard let cur = current else { return false }
        return Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", cur ? "1" : "0"]).0 == 0
    }

    /// Reads the live SleepDisabled flag from `pmset -g`. pmset prints the
    /// line only once the key exists, i.e. once anything has ever set it; on
    /// a Mac where nothing has, the header comes alone and the flag is off.
    /// nil only when pmset printed neither.
    static func readSleepDisabled() -> Bool? {
        let (_, out) = Shell.run("/usr/bin/pmset", ["-g"])
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return out.contains("System-wide power settings:") ? false : nil
    }

    enum WriteResult { case ok, needsSetup, cancelled, failed }

    /// Writes the flag. Tries passwordless sudo (sudoers drop-in) first, then,
    /// if allowed, an admin-password prompt via osascript.
    static func writeSleepDisabled(_ on: Bool, allowPrompt: Bool) -> WriteResult {
        let v = on ? "1" : "0"
        let (code, out) = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", v])
        if code == 0 { return .ok }
        Log.write("sudo -n failed (\(code)): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard allowPrompt else { return .needsSetup }
        let (c2, o2) = runAsAdmin("/usr/bin/pmset -a disablesleep \(v)",
                                  prompt: "ClamshellAwake wants to change your Mac's sleep setting.")
        if c2 == 0 { return .ok }
        Log.write("osascript failed (\(c2)): \(o2.trimmingCharacters(in: .whitespacesAndNewlines))")
        return o2.contains("(-128)") ? .cancelled : .failed
    }

    /// Runs `cmd` with /bin/sh as root, behind the macOS admin-password
    /// dialog. The command and the dialog text reach AppleScript as argv,
    /// never spliced into its source, so neither needs AppleScript escaping.
    /// Cancel in the dialog fails with "(-128)" in the output.
    static func runAsAdmin(_ cmd: String, prompt: String) -> (Int32, String) {
        Shell.run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
            "-e", "end run",
            cmd, prompt,
        ])
    }

    static let rulePath = "/etc/sudoers.d/clamshell-awake"

    /// First-run setup: installs a sudoers rule that lets this user run the
    /// two exact commands writeSleepDisabled uses, and nothing else, without
    /// a password. Asks for the admin password once. visudo checks the file
    /// before it goes in: a broken file in sudoers.d breaks sudo entirely.
    /// True only when the rule then passes the same check as at launch.
    static func installSudoRule() -> Bool {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            Log.write("setup FAILED: user name '\(user)' is not safe to put in a sudoers rule")
            return false
        }
        let comment = "# ClamshellAwake: passwordless toggle of the lid-closed sleep override"
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        // Single-quoted for sh: the user name is checked above and the rest is
        // fixed text, so neither line holds a quote.
        let cmd = "t=$(/usr/bin/mktemp) || exit 1; "
            + "/usr/bin/printf '%s\\n' '\(comment)' '\(rule)' > \"$t\""
            + " && /usr/sbin/visudo -cf \"$t\""
            + " && /usr/bin/install -o root -g wheel -m 0440 \"$t\" \(rulePath); "
            + "s=$?; /bin/rm -f \"$t\"; exit $s"
        let (code, out) = runAsAdmin(cmd, prompt: "ClamshellAwake needs your password once so it can turn sleep on and off.")
        let detail = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0 else {
            Log.write(out.contains("(-128)") ? "setup cancelled" : "setup FAILED (\(code)): \(detail)")
            return false
        }
        // No cached sudo ticket can make this pass: the app never runs sudo
        // with a password, and the admin dialog above does not go through sudo.
        let ok = sudoRuleInstalled(current: readSleepDisabled())
        Log.write(ok ? "setup: installed \(rulePath) for \(user); passwordless pmset works"
                     : "setup FAILED: installed \(rulePath) for \(user), but passwordless pmset still fails")
        return ok
    }
}

final class Controller: NSObject, NSMenuDelegate {
    /// Battery grace: how long Auto keeps the Mac awake on battery after the
    /// lid closes (after AC drops, on a Mac that cannot read its lid).
    /// The menu calls it "Sleep Delay on Battery".
    static let graceChoices: [Int] = [60, 120, 300, 600, 900, 1800, 3600]
    static let defaultGrace = 600
    var delaySeconds: TimeInterval {
        let v = defaults.integer(forKey: "graceSeconds")
        return TimeInterval(v > 0 ? v : Self.defaultGrace)
    }

    let defaults = UserDefaults.standard
    var mode: Mode {
        get { Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    var sleepDisabled: Bool?          // last known real value of the flag
    var pending: DispatchWorkItem?    // battery cooldown
    var pendingFireAt: Date?
    var pendingStartedAt: Date?
    var lastError: String?
    var sudoOK = true
    var source: CFRunLoopSource?
    var lidClosed: Bool?              // last known lid state, nil if unreadable
    var notifyPort: IONotificationPortRef?
    var clamshellNote: io_object_t = 0

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var setupItems: [NSMenuItem] = []   // "Finish Setup…" block, shown while the rule is missing
    let header = StatusHeader()         // answers "does closing the lid sleep it?", and why
    var modeItems: [Mode: NSMenuItem] = [:]
    var delayItem = NSMenuItem()
    var graceItems: [Int: NSMenuItem] = [:]
    var policyLines: [NSMenuItem] = []
    var loginItem = NSMenuItem()
    var hideAutoItem = NSMenuItem()
    var menuTimer: Timer?
    /// Off by default: the icon always shows. When on, the icon leaves the
    /// menu bar in Auto (the mode that needs no attention) and shows in Always
    /// Awake / Normal Sleep, or whenever something is wrong. Reopening the app
    /// brings the menu back.
    var hideInAuto: Bool {
        get { defaults.object(forKey: "hideInAuto") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "hideInAuto") }
    }
    /// Set by a reopen: keeps the item on screen while its menu is open.
    var pinnedVisible = false

    // MARK: lifecycle

    func start() {
        buildMenu()
        sleepDisabled = Power.readSleepDisabled()
        let lid = Power.lidClosed().map { $0 ? "closed" : "open" } ?? "?"
        Log.write("launch: mode=\(mode.rawValue) ac=\(Power.onAC()) lid=\(lid) SleepDisabled=\(sleepDisabled.map { $0 ? "1" : "0" } ?? "?")")
        checkSudo()
        registerLoginItemOnFirstRun()

        // Fires only on AC <-> battery transitions; no polling.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSCreateLimitedPowerNotification({ ctx in
            guard let ctx else { return }
            Unmanaged<Controller>.fromOpaque(ctx).takeUnretainedValue().powerChanged()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        } else {
            Log.write("ERROR: could not register power-source notification")
        }
        watchClamshell()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)

        evaluate(reason: "launch")
        // Next run-loop turn, so the menu bar item is up behind the alert.
        DispatchQueue.main.async { [weak self] in self?.offerSetup() }
    }

    /// Re-checks only while the rule is missing, so a working install costs
    /// one sudo call at launch and nothing afterwards.
    func checkSudo() {
        let ok = Power.sudoRuleInstalled(current: sleepDisabled ?? Power.readSleepDisabled())
        if ok != sudoOK { Log.write(ok ? "sudoers rule found" : "WARNING: no passwordless sudo for pmset; Auto cannot change sleep until setup is done (Finish Setup in the menu)") }
        sudoOK = ok
    }

    /// Asks once, at launch, while the rule is missing. "Not Now" is
    /// remembered; the menu keeps a "Finish Setup…" item either way.
    func offerSetup() {
        guard !sudoOK, !defaults.bool(forKey: "setupOffered") else { return }
        let r = Self.alert("Finish setting up ClamshellAwake",
            "To keep your Mac awake with the lid closed, ClamshellAwake switches a macOS sleep setting "
                + "on and off. macOS needs your administrator password once to allow that. "
                + "After that the app can change only that one setting, and it won't ask again.",
            buttons: ["Set Up…", "Not Now"])
        if r == .alertFirstButtonReturn {
            runSetup()
        } else {
            defaults.set(true, forKey: "setupOffered")
            Log.write("setup: not now")
        }
    }

    @objc func runSetup() {
        Log.write("setup: asking for the admin password")
        let ok = Power.installSudoRule()
        if ok != sudoOK { Log.write(ok ? "sudoers rule found" : "WARNING: no passwordless sudo for pmset") }
        sudoOK = ok
        guard ok else {
            lastError = "Setup didn't finish. Choose Finish Setup… to try again."
            refreshUI()
            return
        }
        lastError = nil
        evaluate(reason: "setup")
    }

    /// Lid open/close drives the battery grace, so the countdown starts when
    /// the lid shuts rather than when AC was pulled. IOPMrootDomain's general
    /// interest channel carries kIOPMMessageClamshellStateChange; rather than
    /// hard-code that message id, re-read the lid on any message and act only
    /// on a real change. The reads are one registry lookup and cost nothing.
    func watchClamshell() {
        lidClosed = Power.lidClosed()
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.write("ERROR: no clamshell notifications; Auto falls back to the unplug timer")
            return
        }
        defer { IOObjectRelease(root) }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let r = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<Controller>.fromOpaque(ctx).takeUnretainedValue().clamshellChanged()
        }, ctx, &clamshellNote)
        if r != KERN_SUCCESS {
            Log.write("ERROR: clamshell notification failed (\(r)); Auto falls back to the unplug timer")
        }
    }

    func clamshellChanged() {
        let now = Power.lidClosed()
        guard now != lidClosed else { return }
        lidClosed = now
        Log.write("lid \(now == true ? "closed" : "open")")
        evaluate(reason: "lid")
    }

    func powerChanged() {
        Log.write("power source: \(Power.onAC() ? "AC" : "battery")")
        evaluate(reason: "power change")
    }

    @objc func willSleep() {
        Log.write("system sleeping (ac=\(Power.onAC()))")
    }

    @objc func didWake() {
        Log.write("system woke (ac=\(Power.onAC()))")
        sleepDisabled = Power.readSleepDisabled()
        evaluate(reason: "wake")
    }

    // MARK: policy

    func evaluate(reason: String) {
        let ac = Power.onAC()
        lidClosed = Power.lidClosed()
        switch mode {
        case .awake:
            cancelPending()
            apply(true, reason: reason)
        case .normal:
            cancelPending()
            apply(false, reason: reason)
        case .auto:
            if ac {
                cancelPending()
                apply(true, reason: reason)
            } else if lidClosed == false {
                // On battery with the lid open: hold the override anyway. The
                // flag has to already be 1 when the lid shuts - macOS goes from
                // clamshell-closed to sleep in about 8ms, far too fast to react
                // to - so the grace can only start at the lid close if the Mac
                // was never allowed to sleep before it. A Mac that cannot read
                // its lid state (nil) keeps the old unplug-keyed behaviour.
                cancelPending()
                apply(true, reason: reason)
            } else if sleepDisabled == false {
                cancelPending()            // already sleeping normally
            } else if pending == nil {
                schedule()
            }
        }
        refreshUI()
    }

    func schedule(startedAt: Date = Date()) {
        let fireAt = startedAt.addingTimeInterval(delaySeconds)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.pendingFireAt = nil
            self.pendingStartedAt = nil
            if Power.onAC() {
                Log.write("cooldown fired but on AC; staying awake")
            } else {
                self.apply(false, reason: "battery for \(Int(self.delaySeconds))s")
                if self.sleepDisabled == false && Power.lidClosed() == true {
                    // The flag alone does nothing now that the lid is already
                    // shut (see Power.forceSleep); put the Mac to sleep ourselves.
                    Log.write(Power.forceSleep() ? "lid closed: sleeping now"
                                                 : "WARNING: forced sleep failed; relying on idle timer")
                }
            }
            self.refreshUI()
        }
        pending = item
        pendingFireAt = fireAt
        pendingStartedAt = startedAt
        // Wall-clock deadline: a DispatchTime (.now()) deadline stops counting while the
        // Mac sleeps (mach_absolute_time pauses in sleep, on Apple silicon too), which
        // would fire the cooldown late after a wake.
        let wait = max(0, fireAt.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + wait, execute: item)
        let why = lidClosed == true ? "lid closed on battery" : "battery"
        Log.write("\(why): normal sleep in \(Int(wait))s unless AC returns")
    }

    func cancelPending() {
        if pending != nil { Log.write("cooldown cancelled") }
        pending?.cancel()
        pending = nil
        pendingFireAt = nil
        pendingStartedAt = nil
    }

    func apply(_ on: Bool, reason: String) {
        if sleepDisabled == on { return }
        let manual = reason.hasPrefix("menu")
        switch Power.writeSleepDisabled(on, allowPrompt: manual) {
        case .ok:
            sleepDisabled = on
            lastError = nil
            Log.write("SleepDisabled=\(on ? 1 : 0) (\(reason))")
        case .needsSetup:
            sleepDisabled = Power.readSleepDisabled()
            // Rule missing: "Finish Setup…" already says what to do. If it
            // passed at launch, re-check (removed since?) so the menu offers
            // setup again instead of a dead-end error.
            if sudoOK { checkSudo() }
            lastError = sudoOK ? "Couldn't change the sleep setting. Open Log for details." : nil
        case .cancelled:
            sleepDisabled = Power.readSleepDisabled()
            lastError = "Not changed: password cancelled. Choose the mode again."
        case .failed:
            sleepDisabled = Power.readSleepDisabled()
            lastError = "Couldn't change the sleep setting. Open Log for details."
        }
    }

    // MARK: menu

    func buildMenu() {
        menu.delegate = self

        let setup = NSMenuItem(title: "\u{26A0}\u{FE0E} Finish Setup\u{2026}", action: #selector(runSetup), keyEquivalent: "")
        setup.target = self
        setup.toolTip = "Asks for your administrator password once, then lets ClamshellAwake turn sleep "
            + "on and off by itself. It allows exactly two commands (pmset disablesleep 1 and 0) and nothing else."
        setupItems = Self.withSubtitle(setup, "One-time step. Auto needs it to work.") + [.separator()]
        setupItems.forEach(menu.addItem)

        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())

        let sub = NSMenu()
        for secs in Self.graceChoices {
            let it = NSMenuItem(title: Self.graceTitle(secs), action: #selector(pickGrace(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = secs
            sub.addItem(it)
            graceItems[secs] = it
        }
        delayItem.submenu = sub
        delayItem.indentationLevel = 2
        delayItem.toolTip = "On battery, how long Auto keeps the Mac awake after you close the lid. "
            + "Plug in before it runs out and the Mac stays awake. Changing it during a countdown "
            + "keeps the countdown's start time."
        for m in Mode.allCases {
            let it = NSMenuItem(title: m == .auto ? "Auto (Recommended)" : m.title,
                                action: #selector(pickMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
            it.toolTip = m.tip
            Self.withSubtitle(it, m.subtitle).forEach(menu.addItem)
            modeItems[m] = it
            // Only Auto uses the delay, so it sits under Auto and only shows in Auto.
            if m == .auto { menu.addItem(delayItem) }
        }
        menu.addItem(.separator())

        let policy = NSMenuItem(title: "macOS Sleep Settings", action: nil, keyEquivalent: "")
        policy.toolTip = "macOS's own timers, from System Settings (Battery, Lock Screen). Normal Sleep "
            + "follows them. Always Awake, and Auto while it keeps the Mac awake, override the sleep "
            + "timer; the display still turns off on its own timer."
        let policyMenu = NSMenu()
        for _ in 0..<2 {
            let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            it.isEnabled = false
            policyMenu.addItem(it)
            policyLines.append(it)
        }
        policy.submenu = policyMenu
        menu.addItem(policy)
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.toolTip = "Starts ClamshellAwake when you log in, so Auto keeps working after a restart."
        menu.addItem(loginItem)
        hideAutoItem = NSMenuItem(title: "Hide Icon in Auto Mode", action: #selector(toggleHideAuto), keyEquivalent: "")
        hideAutoItem.target = self
        hideAutoItem.toolTip = "The icon leaves the menu bar while Auto is on, and comes back when something "
            + "needs your attention. To get this menu back while it's hidden, open ClamshellAwake again "
            + "(Spotlight, Finder)."
        menu.addItem(hideAutoItem)
        let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        log.toolTip = "What the app changed, and why."
        menu.addItem(log)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit and Restore Normal Sleep", action: #selector(quitRestoringSleep), keyEquivalent: "q")
        quit.target = self
        quit.toolTip = "Turns normal sleep back on, then quits. Your mode is kept for next time. "
            + "Logging out or restarting does not do this: the Mac stays as it was."
        menu.addItem(quit)
        statusItem.menu = menu
        refreshUI()
    }

    /// A short grey line under a menu item: the native subtitle on macOS
    /// 14.4+, a separate disabled line before that. Returns what to add.
    static func withSubtitle(_ item: NSMenuItem, _ text: String) -> [NSMenuItem] {
        if #available(macOS 14.4, *) {
            item.subtitle = text
            return [item]
        }
        let n = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        n.isEnabled = false
        n.toolTip = item.toolTip
        n.attributedTitle = small(text)
        return [item, n]
    }

    static func small(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// An accessory app is never frontmost on its own; without the activate
    /// its alert can open behind the app in front.
    @discardableResult
    static func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        return a.runModal()
    }

    @objc func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) else { return }
        mode = m
        Log.write("mode -> \(m.rawValue)")
        evaluate(reason: "menu: \(m.rawValue)")
    }

    static func graceTitle(_ secs: Int) -> String {
        secs < 60 ? "\(secs) sec" : secs < 3600 ? "\(secs / 60) min" : "\(secs / 3600) hr"
    }

    @objc func pickGrace(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Int else { return }
        defaults.set(secs, forKey: "graceSeconds")
        Log.write("battery grace -> \(secs)s")
        if pending != nil, let started = pendingStartedAt {
            // Cooldown already running: keep its start time, apply the new length.
            // If that deadline is already past, the work item fires immediately.
            cancelPending()
            schedule(startedAt: started)
        }
        refreshUI()
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            Log.write("login item error: \(error)")
            lastError = "Launch at Login failed. Set it in System Settings > General."
        }
        refreshUI()
    }

    func registerLoginItemOnFirstRun() {
        guard !defaults.bool(forKey: "loginItemOffered") else { return }
        defaults.set(true, forKey: "loginItemOffered")
        do { try SMAppService.mainApp.register(); Log.write("login item registered") }
        catch { Log.write("login item register failed: \(error)") }
    }

    @objc func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    /// Quit from the menu turns normal sleep back on first, so quitting can't
    /// leave a Mac that never sleeps. Passwordless path only: no prompt on the
    /// way out. Deliberately not in applicationWillTerminate: logout, restart
    /// and shutdown must leave the flag as it is, so a Mac kept awake stays
    /// awake across them.
    @objc func quitRestoringSleep() {
        cancelPending()
        let was = Power.readSleepDisabled()
        if was == false {
            Log.write("quit: sleep already normal")
        } else if Power.writeSleepDisabled(false, allowPrompt: false) == .ok {
            Log.write("quit: SleepDisabled=0 (normal sleep restored)")
        } else {
            Log.write("WARNING quit: could not restore normal sleep without a password; SleepDisabled left at \(was.map { $0 ? "1" : "0" } ?? "?")")
        }
        NSApp.terminate(nil)
    }

    /// Launching the app while it runs (Finder, Spotlight, Alfred, `open -a`)
    /// lands here via the reopen event: show the icon and drop its menu.
    func revealMenu() {
        pinnedVisible = true
        if !statusItem.isVisible {
            statusItem.isVisible = true
            Log.write("icon shown (reopen)")
        }
        // The item needs a run-loop turn on screen before its button takes a click.
        DispatchQueue.main.async { [weak self] in self?.statusItem.button?.performClick(nil) }
    }

    @objc func toggleHideAuto() {
        hideInAuto.toggle()
        Log.write("hide icon in Auto -> \(hideInAuto)")
        refreshUI()
        guard hideInAuto else { return }
        // Otherwise the icon just vanishes and the menu seems lost.
        Self.alert("The icon will hide in Auto mode",
            "While Auto is on, ClamshellAwake stays out of the menu bar. To open its menu, open "
                + "ClamshellAwake again from Spotlight or Finder. The icon also comes "
                + "back when something needs your attention.")
    }

    func applyVisibility() {
        let attention = lastError != nil || !sudoOK
        let show = mode != .auto || attention || !hideInAuto || pinnedVisible
        guard statusItem.isVisible != show else { return }
        statusItem.isVisible = show
        Log.write("icon \(show ? "shown" : "hidden") (mode=\(mode.rawValue))")
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Re-read the real flag in case it was changed from a terminal.
        let real = Power.readSleepDisabled()
        if real != sleepDisabled {
            Log.write("flag changed externally: \(real.map { $0 ? "1" : "0" } ?? "?")")
            sleepDisabled = real
            if mode == .auto { evaluate(reason: "external change") }
        }
        if !sudoOK { checkSudo() }
        let policy = Power.policySummary()
        for (i, it) in policyLines.enumerated() {
            it.title = i < policy.count ? policy[i] : ""
            it.isHidden = i >= policy.count
        }
        refreshUI()
        guard pending != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshUI() }
        RunLoop.main.add(t, forMode: .common)   // menu tracking uses eventTracking mode
        menuTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
        guard pinnedVisible else { return }
        pinnedVisible = false
        // The picked item's action is still pending; let it run first.
        DispatchQueue.main.async { [weak self] in self?.refreshUI() }
    }

    // MARK: UI state

    /// The status line answers one question: does closing the lid now sleep
    /// the Mac? The line under it says why, or what to do about it.
    func refreshUI() {
        let ac = Power.onAC()
        let src = ac ? "Plugged in" : "On battery"
        let delay = Self.graceTitle(Int(delaySeconds))
        var badge: String
        let head: String
        let detail: String
        switch (sleepDisabled, pending) {
        case (true, .some):
            badge = "hourglass"
            let left = max(0, Int((pendingFireAt ?? Date()).timeIntervalSinceNow.rounded()))
            head = String(format: "Sleeps in %d:%02d", left / 60, left % 60)
            detail = "\(lidClosed == true ? "Lid closed on battery" : "On battery") \u{00B7} plug in to stay awake"
        case (true, nil):
            badge = "sun.max.fill"
            if mode == .auto && !ac && lidClosed == false {
                head = "Sleeps \(delay) after the lid closes"
                detail = "On battery \u{00B7} won't sleep while the lid is open"
            } else {
                head = "Stays awake with the lid closed"
                detail = mode == .awake && !ac ? "On battery \u{00B7} runs until the battery is empty"
                                               : "\(src) \u{00B7} \(mode.title)"
            }
        case (false, _):
            badge = "moon.fill"
            head = "Sleeps when the lid closes"
            detail = "\(src) \u{00B7} \(mode.title)"
        case (nil, _):
            badge = "questionmark"
            head = "Can't read the sleep setting"
            detail = "\(src) \u{00B7} Open Log for details"
        }
        if !sudoOK && mode == .auto { badge = "exclamationmark" }
        header.update(head: head, detail: detail, error: lastError.map { "\u{26A0}\u{FE0E} " + $0 })
        header.toolTip = mode.tip
        setupItems.forEach { $0.isHidden = sudoOK }
        for (m, it) in modeItems { it.state = (m == mode) ? .on : .off }
        delayItem.title = "Sleep Delay on Battery: \(delay)"
        delayItem.isHidden = mode != .auto
        let g = Int(delaySeconds)
        for (secs, it) in graceItems { it.state = (secs == g) ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        hideAutoItem.state = hideInAuto ? .on : .off
        statusItem.button?.image = Self.icon(badge: badge)
        statusItem.button?.toolTip = "ClamshellAwake: \(head)\n\(detail)"
        applyVisibility()
    }

    /// Laptop glyph with a small knocked-out badge, as a template image so it
    /// follows the menu bar's light/dark appearance. Badges: sun = stays awake,
    /// hourglass = countdown to sleep, moon = sleeps normally,
    /// ! = setup needed (Auto), ? = flag unreadable.
    static func icon(badge: String) -> NSImage {
        let img = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { rect in
            let baseCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            guard let base = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
                .withSymbolConfiguration(baseCfg) else { return false }
            let bs = base.size
            base.draw(in: NSRect(x: (rect.width - bs.width) / 2 - 1, y: (rect.height - bs.height) / 2,
                                 width: bs.width, height: bs.height))
            let badgeCfg = NSImage.SymbolConfiguration(pointSize: 7, weight: .black)
            guard let b = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
                .withSymbolConfiguration(badgeCfg) else { return true }
            let d: CGFloat = 11
            let circle = NSRect(x: rect.width - d, y: 0, width: d, height: d)
            if let ctx = NSGraphicsContext.current {
                ctx.saveGraphicsState()
                ctx.compositingOperation = .destinationOut
                NSColor.black.setFill()
                NSBezierPath(ovalIn: circle).fill()
                ctx.restoreGraphicsState()
            }
            let s = b.size
            b.draw(in: NSRect(x: circle.midX - s.width / 2, y: circle.midY - s.height / 2, width: s.width, height: s.height))
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// The status block at the top of the menu. A custom view because macOS
/// draws a disabled menu item greyed out whatever its colours, and this is
/// the one line the menu exists to answer.
final class StatusHeader: NSView {
    /// Lines the text up with the menu item titles, past the checkmark column
    /// (measured; macOS 26 menus pad wider than earlier ones).
    static var inset: CGFloat {
        if #available(macOS 26, *) { return 30 }
        return 21
    }
    let head = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let error = NSTextField(labelWithString: "")
    let stack: NSStackView

    init() {
        stack = NSStackView(views: [head, detail, error])
        super.init(frame: .zero)
        head.font = .systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold)
        detail.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        error.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        error.textColor = .systemRed
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: Self.inset, bottom: 3, right: 14)
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
        autoresizingMask = [.width]   // the menu widens it to its own width
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(head h: String, detail d: String, error e: String?) {
        head.stringValue = h
        detail.stringValue = d
        error.stringValue = e ?? ""
        error.isHidden = e == nil
        setFrameSize(stack.fittingSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller.revealMenu()
        return false
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
