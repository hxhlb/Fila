import AlertController
import UIKit

@MainActor
enum PermanentDeleteConfirmation {
    static func present(
        from presenter: UIViewController,
        title: String,
        message: String,
        confirmTitle: String = String(localized: "Delete Permanently"),
        confirm: @escaping () -> Void,
    ) {
        let accent = AlertControllerConfiguration.accentColor
        AlertControllerConfiguration.accentColor = .systemRed
        defer { AlertControllerConfiguration.accentColor = accent }
        let alert = AlertViewController(title: .init(title), message: .init(message)) { context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: .init(confirmTitle), attribute: .accent) {
                context.dispose { confirm() }
            }
        }
        presenter.present(alert, animated: true)
    }
}
