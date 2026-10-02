// Where NEO Pocket keeps its books on iOS.
//
// Same principle as everywhere else NEO runs: plain files in a folder on the
// device. When the writer has iCloud Drive switched on, that folder is the
// app's iCloud folder — still local, still offline-capable, but Apple carries
// changes to the Mac in the background, where desktop NEO can point at it via
// File → Library Folder… (it shows up as iCloud Drive → NEO Pocket → NEO
// Library). With iCloud Drive off, the folder is On My iPad → NEO Pocket.
// No account is required, no dialog is shown; the shelf simply appears.
//
// Or the writer points Pocket at any folder the Files app can reach (the
// shelf's Library button), as desktop NEO's File → Library Folder… does:
// the Mac's own library in iCloud Drive → Documents, say. iOS keeps a
// bookmark to it, so the choice outlasts a restart.

import Foundation
import UIKit
import UniformTypeIdentifiers
import ObjectiveC
import Capacitor

@objc(LibraryHomePlugin)
public class LibraryHomePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "LibraryHomePlugin"
    public let jsName = "LibraryHome"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "locate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "fetch", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setKeyboard", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "choose", returnType: CAPPluginReturnPromise)
    ]

    // the on-screen keyboard follows the page: dark for Night, light for Paper
    static var keyboardDark = true

    @objc func setKeyboard(_ call: CAPPluginCall) {
        LibraryHomePlugin.keyboardDark = call.getBool("dark") ?? true
        call.resolve()
    }

    private static let folderName = "NEO Library"
    private static let bookmarkKey = "libraryFolderBookmark"
    private static var cached: (url: URL, cloud: Bool, chosen: Bool)?
    private static var opened: URL?   // the chosen folder, while iOS lets us in
    private var picking: FolderPick?  // the picker's delegate, kept until it answers

    // The folder the writer chose, if it can still be reached
    private static func chosenFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        var isDir: ObjCBool = false
        let cloud = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        // a folder still in the cloud may not be on this iPad yet; that's fine
        guard cloud || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue) else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        opened = url
        return url
    }

    private func home() -> (url: URL, cloud: Bool, chosen: Bool) {
        if let c = LibraryHomePlugin.cached { return c }
        if let url = LibraryHomePlugin.chosenFolder() {
            let cloud = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            let result = (url: url, cloud: cloud, chosen: true)
            LibraryHomePlugin.cached = result
            return result
        }
        let fm = FileManager.default
        var base: URL
        var cloud = false
        // url(forUbiquityContainerIdentifier:) can take a moment the first
        // time; plugin methods run off the main thread, so that's fine.
        if let container = fm.url(forUbiquityContainerIdentifier: nil) {
            base = container.appendingPathComponent("Documents", isDirectory: true)
            cloud = true
        } else {
            base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        let lib = base.appendingPathComponent(LibraryHomePlugin.folderName, isDirectory: true)
        try? fm.createDirectory(at: lib, withIntermediateDirectories: true)
        let result = (url: lib, cloud: cloud, chosen: false)
        LibraryHomePlugin.cached = result
        return result
    }

    // {path: "file:///…/NEO%20Library", cloud: true|false, chosen: true|false, name}
    @objc func locate(_ call: CAPPluginCall) {
        let h = home()
        call.resolve(["path": h.url.absoluteString, "cloud": h.cloud, "chosen": h.chosen, "name": h.url.lastPathComponent])
    }

    // The shelf's Library button: say where the books are, and offer another
    // folder or Pocket's own. {changed: true} when the page should start over
    // in the new place (like desktop NEO restarting in a new library folder).
    @objc func choose(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let vc = self.bridge?.viewController else { call.resolve(["changed": false]); return }
            let h = self.home()
            let place = h.chosen ? LibraryHomePlugin.describe(h.url) : (h.cloud ? "iCloud Drive → NEO Pocket → NEO Library" : "On My iPad → NEO Pocket → NEO Library")
            let sheet = UIAlertController(title: "Library folder",
                                          message: "Your books live in:\n\(place)\n\nChoose another folder and Pocket starts over there. Books stay where they are — move the files yourself if you want them along.",
                                          preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: "Choose Folder…", style: .default) { _ in self.pick(call, from: vc, start: h.url) })
            if h.chosen {
                sheet.addAction(UIAlertAction(title: "Use NEO Pocket's Folder", style: .default) { _ in
                    UserDefaults.standard.removeObject(forKey: LibraryHomePlugin.bookmarkKey)
                    LibraryHomePlugin.forget()
                    call.resolve(["changed": true])
                })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in call.resolve(["changed": false]) })
            vc.present(sheet, animated: true)
        }
    }

    private func pick(_ call: CAPPluginCall, from vc: UIViewController, start: URL) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.directoryURL = start
        let answer = FolderPick { [weak self] picked in
            self?.picking = nil
            guard let picked = picked else { call.resolve(["changed": false]); return }
            // the picker lets us in for now; the bookmark lets us back in later
            let entered = picked.startAccessingSecurityScopedResource()
            defer { if entered { picked.stopAccessingSecurityScopedResource() } }
            // a folder one step above the library (iCloud Drive → Documents,
            // when the library is Documents → NEO Library) means the library
            let url = LibraryHomePlugin.libraryIn(picked)
            guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                call.reject("iOS wouldn't let Pocket keep that folder")
                return
            }
            UserDefaults.standard.set(data, forKey: LibraryHomePlugin.bookmarkKey)
            LibraryHomePlugin.forget()
            call.resolve(["changed": true])
        }
        picking = answer
        picker.delegate = answer
        vc.present(picker, animated: true)
    }

    // The picked folder, or the NEO Library inside it when the picked one
    // isn't a library itself (a file still in iCloud is ".name.icloud")
    static func libraryIn(_ picked: URL) -> URL {
        let fm = FileManager.default
        let has = { (dir: URL, name: String) -> Bool in
            fm.fileExists(atPath: dir.appendingPathComponent(name).path) ||
            fm.fileExists(atPath: dir.appendingPathComponent("." + name + ".icloud").path)
        }
        if has(picked, "library.json") { return picked }
        let inner = picked.appendingPathComponent(folderName, isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: inner.path, isDirectory: &isDir), isDir.boolValue, has(inner, "library.json") { return inner }
        return picked
    }

    // A folder the way the Files app names it, not as a path
    static func describe(_ url: URL) -> String {
        let fm = FileManager.default
        let parts = url.resolvingSymlinksInPath().pathComponents
        // iCloud Drive itself
        if let i = parts.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + parts[(i + 1)...]).joined(separator: " → ")
        }
        // an app's own iCloud folder (its Documents is what Files shows)
        if let i = parts.firstIndex(of: "Mobile Documents"), i + 1 < parts.count {
            let container = NSString.path(withComponents: Array(parts[...(i + 1)]))
            var rest = Array(parts[(i + 2)...])
            if rest.first == "Documents" { rest.removeFirst() }
            return (["iCloud Drive", fm.displayName(atPath: container)] + rest).joined(separator: " → ")
        }
        // Pocket's own folder on this iPad
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath().pathComponents
        if parts.count >= docs.count, Array(parts[..<docs.count]) == docs {
            return (["On My iPad", "NEO Pocket"] + parts[docs.count...]).joined(separator: " → ")
        }
        // somewhere else (another app's folder, a USB drive): its last steps
        return parts.suffix(3).filter { $0 != "/" }.joined(separator: " → ")
    }

    private static func forget() {
        opened?.stopAccessingSecurityScopedResource()
        opened = nil
        cached = nil
    }

    // Files another device wrote arrive first as placeholders. Ask iCloud to
    // bring everything under `path` (default: the whole library) down, and
    // wait up to `wait` ms for it. Harmless when not on iCloud.
    @objc func fetch(_ call: CAPPluginCall) {
        let h = home()
        guard h.cloud else { call.resolve(["ready": true]); return }
        var target = h.url
        if let p = call.getString("path"), let u = URL(string: p) { target = u }
        let wait = call.getDouble("wait") ?? 6000
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(wait / 1000)
        var pending = true
        while pending {
            pending = false
            let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]
            // Walk everything, hidden files included: a not-yet-downloaded file
            // is a hidden ".name.icloud" placeholder, and they hide inside
            // every book folder, not just at the top.
            if let en = fm.enumerator(at: target, includingPropertiesForKeys: keys, options: []) {
                for case let item as URL in en {
                    if item.lastPathComponent.hasSuffix(".icloud") {
                        pending = true
                        try? fm.startDownloadingUbiquitousItem(at: item)
                        continue
                    }
                    let v = try? item.resourceValues(forKeys: Set(keys))
                    guard v?.isUbiquitousItem == true else { continue }
                    if let status = v?.ubiquitousItemDownloadingStatus, status != .current {
                        pending = true
                        if v?.ubiquitousItemIsDownloading != true {
                            try? fm.startDownloadingUbiquitousItem(at: item)
                        }
                    }
                }
            } else if target.lastPathComponent.hasSuffix(".icloud") || !fm.fileExists(atPath: target.path) {
                // a single file that is still a placeholder
                let dir = target.deletingLastPathComponent()
                let ph = dir.appendingPathComponent("." + target.lastPathComponent + ".icloud")
                if fm.fileExists(atPath: ph.path) {
                    pending = true
                    try? fm.startDownloadingUbiquitousItem(at: ph)
                }
            }
            if !pending || Date() > deadline { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        call.resolve(["ready": !pending])
    }
}

// The folder picker's answer, handed back to choose()
private class FolderPick: NSObject, UIDocumentPickerDelegate {
    let done: (URL?) -> Void
    init(_ done: @escaping (URL?) -> Void) { self.done = done }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(nil) }
}

// Registers the plugin above with Capacitor. SceneDelegate creates this
// instead of the stock CAPBridgeViewController.
class NeoBridgeViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(LibraryHomePlugin())
    }

    // With a hardware keyboard attached, iPadOS floats a little bar above the
    // page whenever text has focus: a keyboard button, bold/italic, the
    // microphone, ⌘ hints. NEO has its own formatting and its bar is the
    // page's. WebKit's content view is given, at runtime, a subclass that
    // answers "no accessory view, no assistant items, dark keyboard" — the
    // one place iOS asks before drawing any of that.
    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        quietKeyboard()
    }

    private func quietKeyboard() {
        guard let scroll = webView?.scrollView else { return }
        for sub in scroll.subviews where String(describing: type(of: sub)).hasPrefix("WKContent") {
            NeoBridgeViewController.quieten(sub)
        }
    }

    private static func quieten(_ view: UIView) {
        let name = "NEOQuiet_" + String(cString: class_getName(object_getClass(view)))
        var cls: AnyClass? = NSClassFromString(name)
        if cls == nil {
            guard let made = objc_allocateClassPair(object_getClass(view), name, 0) else { return }
            let noView: @convention(block) (AnyObject) -> UIView? = { _ in nil }
            class_addMethod(made, #selector(getter: UIResponder.inputAccessoryView),
                            imp_implementationWithBlock(noView), "@@:")
            let noItems: @convention(block) (AnyObject) -> UITextInputAssistantItem = { _ in
                let item = UITextInputAssistantItem()
                item.leadingBarButtonGroups = []
                item.trailingBarButtonGroups = []
                return item
            }
            class_addMethod(made, #selector(getter: UIResponder.inputAssistantItem),
                            imp_implementationWithBlock(noItems), "@@:")
            let appearance: @convention(block) (AnyObject) -> Int = { _ in
                (LibraryHomePlugin.keyboardDark ? UIKeyboardAppearance.dark : UIKeyboardAppearance.light).rawValue
            }
            class_addMethod(made, NSSelectorFromString("keyboardAppearance"),
                            imp_implementationWithBlock(appearance), "q@:")
            // the long-press bubble keeps Cut, Copy, Paste and the selecting
            // that goes with them (a writer without a keyboard has no other
            // way), and drops AutoFill, Format, Look Up, Translate and the rest:
            // NEO's page has its own ways. WebKit still says when each applies.
            let canPerform = #selector(UIResponder.canPerformAction(_:withSender:))
            typealias CanPerform = @convention(c) (AnyObject, Selector, Selector, AnyObject?) -> Bool
            let webKitSays = unsafeBitCast(class_getMethodImplementation(object_getClass(view), canPerform), to: CanPerform.self)
            let editing: Set<String> = ["cut:", "copy:", "paste:", "select:", "selectAll:"]
            let editOnly: @convention(block) (AnyObject, Selector, AnyObject?) -> Bool = { me, action, sender in
                editing.contains(NSStringFromSelector(action)) && webKitSays(me, canPerform, action, sender)
            }
            class_addMethod(made, canPerform, imp_implementationWithBlock(editOnly), "B@::@")
            objc_registerClassPair(made)
            cls = made
        }
        if let cls = cls { object_setClass(view, cls) }
    }
}
