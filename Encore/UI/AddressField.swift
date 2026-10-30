import SwiftUI
import UIKit

/// UIKit text field so the address can be focused and fully selected on open,
/// like Safari.
struct AddressField: UIViewRepresentable {
    let initialText: String
    let placeholder: String
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSubmit: onSubmit) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.text = initialText
        field.placeholder = placeholder
        field.font = .systemFont(ofSize: 16)
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.textContentType = .URL
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onSubmit: (String) -> Void

        init(onSubmit: @escaping (String) -> Void) {
            self.onSubmit = onSubmit
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                textField.selectedTextRange = textField.textRange(from: textField.beginningOfDocument,
                                                                  to: textField.endOfDocument)
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            let text = textField.text ?? ""
            textField.resignFirstResponder()
            onSubmit(text)
            return false
        }
    }
}
