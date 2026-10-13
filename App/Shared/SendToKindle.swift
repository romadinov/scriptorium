import ReaderCore
import SwiftUI
#if os(iOS)
import MessageUI
#endif

/// "Send to Kindle": e-mails the book to your Send to Kindle address (Amazon accepts EPUB, PDF and Word
/// by e-mail, up to 50 MB, from addresses approved in your Amazon account). Bigger files, or no Mail
/// account, go through the share sheet instead (Amazon's Kindle / Send to Kindle apps take up to 200 MB).
@MainActor @Observable
final class KindleSender {
    static let shared = KindleSender()

    /// The book waiting for the iPad/iPhone send sheet.
    var pending: Pending?

    struct Pending: Identifiable {
        let id = UUID()
        let book: URL
    }

    static let formats: Set<String> = ["epub", "pdf", "docx", "doc"]
    static let emailLimit: Int64 = 50 * 1_000_000

    static func supports(_ url: URL) -> Bool { formats.contains(url.pathExtension.lowercased()) }

    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static var address: String { UserDefaults.standard.string(forKey: "kindleEmail") ?? "" }

    #if os(iOS)
    /// Mail when it can (address known, a Mail account, ≤ 50 MB); the address form first if it's unknown;
    /// otherwise straight to the share sheet.
    func request(_ book: URL) {
        let canMail = MFMailComposeViewController.canSendMail() && Self.size(of: book) <= Self.emailLimit
        if Self.address.isEmpty || canMail {
            pending = .init(book: book)
        } else {
            Self.presentShareSheet(for: book)
        }
    }

    /// The system share sheet, presented from the top view controller (as a popover on iPad).
    static func presentShareSheet(for book: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [book], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
    #endif

    static let approvedSendersHelp = "Amazon only accepts mail from addresses you approve: amazon.com › Manage Your Content and Devices › Preferences › Personal Document Settings › Approved Personal Document E-mail List."

    #if os(macOS)
    /// Mac: a Mail message to the Kindle address with the book attached; over 50 MB, Amazon's Send to Kindle app.
    static func sendOnMac(_ book: URL, status: (String) -> Void) {
        let title = book.deletingPathExtension().lastPathComponent
        if size(of: book) > emailLimit {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.amazon.SendToKindle") {
                NSWorkspace.shared.open([book], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                status("“\(title)” is over 50 MB, so it went to Amazon's Send to Kindle app.")
            } else {
                status("“\(title)” is over 50 MB, more than Send to Kindle by e-mail allows. Amazon's Send to Kindle app for Mac takes up to 200 MB.")
            }
            return
        }
        guard !address.isEmpty else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            status("Enter your Send to Kindle address in Settings › Kindle first.")
            return
        }
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [book]) else {
            status("Mail isn't set up on this Mac.")
            return
        }
        service.recipients = [address]
        service.subject = title
        service.perform(withItems: [book])
    }
    #endif
}

/// The menu item (library book menu, reader menus) — only for formats Amazon accepts.
struct SendToKindleButton: View {
    let book: URL
    #if os(macOS)
    @Environment(DeviceTransfers.self) private var transfers
    #endif

    var body: some View {
        if KindleSender.supports(book) {
            Button("Send to Kindle", systemImage: "book.closed") {
                #if os(macOS)
                KindleSender.sendOnMac(book) { transfers.status = $0 }
                #else
                KindleSender.shared.request(book)
                #endif
            }
        }
    }
}

#if os(iOS)
/// iPad/iPhone: asks for the Kindle address the first time, then opens Mail (or the share sheet).
struct SendToKindleSheet: View {
    let book: URL
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var confirmed = false

    private var title: String { book.deletingPathExtension().lastPathComponent }
    private var tooBig: Bool { KindleSender.size(of: book) > KindleSender.emailLimit }

    var body: some View {
        if (confirmed || !settings.kindleEmail.isEmpty) && !tooBig && MFMailComposeViewController.canSendMail() {
            MailComposer(recipient: settings.kindleEmail, subject: title, attachment: book) { dismiss() }
                .ignoresSafeArea()
        } else {
            NavigationStack {
                Form {
                    Section {
                        TextField("name@kindle.com", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    } header: {
                        Text("Your Send to Kindle address")
                    } footer: {
                        Text("Find it on amazon.com › Manage Your Content and Devices › Preferences › Personal Document Settings. "
                             + KindleSender.approvedSendersHelp)
                    }
                }
                .navigationTitle("Send to Kindle")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Continue") {
                            settings.kindleEmail = address.trimmingCharacters(in: .whitespaces)
                            confirmed = true
                            // No Mail account (or too big for e-mail): hand over to the share sheet.
                            if tooBig || !MFMailComposeViewController.canSendMail() {
                                let book = book
                                dismiss()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(500))
                                    KindleSender.presentShareSheet(for: book)
                                }
                            }
                        }
                        .disabled(!address.contains("@"))
                    }
                }
            }
        }
    }
}

/// Mail compose with the book attached.
struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let attachment: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = context.coordinator
        mail.setToRecipients([recipient])
        mail.setSubject(subject)
        mail.setMessageBody("Sent from Scriptorium.", isHTML: false)
        if let data = try? Data(contentsOf: attachment) {
            let mime = switch attachment.pathExtension.lowercased() {
            case "pdf": "application/pdf"
            case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            case "doc": "application/msword"
            default: "application/epub+zip"
            }
            mail.addAttachmentData(data, mimeType: mime, fileName: attachment.lastPathComponent)
        }
        return mail
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}

#endif
