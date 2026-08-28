import AppKit
import UserNotifications

// Launched via `open`, stdout goes nowhere, so mirror everything to a file.
let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("notifprobe.log")
var transcript = ""
func print(_ line: String) {
    transcript += line + "\n"
    try? transcript.write(to: logURL, atomically: true, encoding: .utf8)
    Swift.print(line)
}

// Settles a claim rather than assuming it: can an ad-hoc signed, unnotarised
// .app actually obtain notification authorisation and deliver an alert?

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

print("bundle id   : \(Bundle.main.bundleIdentifier ?? "nil")")
print("bundle path : \(Bundle.main.bundlePath)")

let center = UNUserNotificationCenter.current()
var done = false

func name(_ s: UNAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .denied:        return "denied"
    case .authorized:    return "authorized"
    case .provisional:   return "provisional"
    default:             return "other(\(s.rawValue))"
    }
}

center.getNotificationSettings { settings in
    print("initial     : \(name(settings.authorizationStatus))")
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
        print("requested   : granted=\(granted) error=\(error?.localizedDescription ?? "none")")
        guard granted else { done = true; return }
        let content = UNMutableNotificationContent()
        content.title = "Pomodoro"
        content.body  = "Notifications work on an ad-hoc signed build."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "probe",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        center.add(req) { err in
            print("delivered   : \(err == nil ? "queued ok" : "FAILED — \(err!.localizedDescription)")")
            done = true
        }
    }
}

let deadline = Date().addingTimeInterval(25)
while !done && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
print(done ? "RESULT: probe completed" : "RESULT: timed out (no response to the authorisation request)")
