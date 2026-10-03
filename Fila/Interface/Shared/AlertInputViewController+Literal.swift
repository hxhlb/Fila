import AlertController
import UIKit

extension AlertInputViewController {
    /// Takes the text exactly as typed, for a name, a path, a URL or a
    /// password. The package's field turns off only capitalisation and
    /// autocorrection, so `it's` arrived as `it’s` and `--` as `—`, and a
    /// file was given a name nobody typed.
    ///
    /// The field is the package's own and private. The card loads its
    /// content when it is made, so the field is already under `contentView`
    /// here, before it is presented and takes the keyboard. A card without
    /// one is left as it was.
    func typingLiterally() -> Self {
        var pending: [UIView] = [contentView]
        while let view = pending.popLast() {
            if let field = view as? UITextField {
                field.smartQuotesType = .no
                field.smartDashesType = .no
                field.smartInsertDeleteType = .no
                field.spellCheckingType = .no
            }
            pending.append(contentsOf: view.subviews)
        }
        return self
    }
}
