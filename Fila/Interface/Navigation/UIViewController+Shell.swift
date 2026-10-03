import FilaProtocol
import Then
import UIKit

extension UIViewController {
    /// The shell, from anywhere: a column of it, a stack inside a column, or a
    /// sheet it presented. The window's root is what it is, and a sheet has no
    /// `splitViewController` to walk up to — which is exactly the case the
    /// sidebar is in on a phone.
    var shell: RootSplitViewController? {
        view.window?.rootViewController as? RootSplitViewController
    }

    /// Points a sheet or share controller at something on iPad, where a popover
    /// without an anchor is a crash rather than a layout problem.
    func anchor(_ controller: UIViewController, to view: UIView) {
        controller.popoverPresentationController?.do {
            $0.sourceView = view
            $0.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 0,
                height: 0,
            )
        }
    }

    /// Shows a file: the viewer the registry picks, pushed into the tab it was
    /// opened from.
    ///
    /// One branch, and the same one on every shape of screen. A viewer used to
    /// go into a third column beside the browser on an iPad; it fills the tab
    /// now, which is what "a tab can be covered by a preview, an editor or a
    /// terminal" means — and it is what lets Back out of a viewer land in the
    /// folder it came from rather than in a panel that never went away.
    ///
    /// A gallery lets an image viewer page through the folder's other images.
    func openFile(at path: String, session: FileSession, gallery: ImageGallery? = nil) async {
        do {
            let details = try await session.perform(retryOnDisconnect: true) { try await $0.details(of: path) }
            if details.node.isNavigable {
                session.noteVisit(directory: path)
            }
            await openFile(details, session: session, gallery: gallery)
        } catch let failure as FilaFailure {
            // Over whatever is up: a `fila://view` link arrives at the root,
            // which UIKit refuses to present from while a sheet is showing.
            TopPresenter.whenReady(from: self) { $0.report(failure) }
        } catch {}
    }

    /// The same dispatcher when the caller already holds the item's details.
    func openFile(_ details: FileDetails, session: FileSession, gallery: ImageGallery? = nil) async {
        let shell = shell
        let navigation = navigationController ?? shell?.content.navigation
        let source = navigation?.topViewController
        let viewer = await ViewerRegistry.makeViewer(for: details, link: session.link, gallery: gallery)
            ?? PropertiesViewController(details: details, link: session.link)
        // Opening may await the backend. A later tap or tab switch must not
        // put this document on a different page's navigation stack.
        guard !Task.isCancelled, let navigation,
              navigation.topViewController === source else { return }
        if navigationController != nil {
            guard navigation.viewIfLoaded?.window != nil else { return }
            navigation.pushViewController(viewer, animated: true)
        } else {
            // The shell puts its tab back on screen before it pushes, so a
            // tab overview covering it — the case for a `fila://view` link —
            // is closed rather than a reason to drop the viewer. Choosing
            // another tab meanwhile is: the push would land in that one.
            guard let shell, shell.content.navigation === navigation else { return }
            shell.push(viewer)
        }
    }
}
