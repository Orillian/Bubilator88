import AppKit
import SwiftUI

/// An editable monospaced text view that leaves what is typed alone.
///
/// `TextEditor` follows the system's smart quotes and dashes, which turn the
/// `"` and `--` of a shell command into characters the shell does not know.
struct PlainTextEditor: NSViewRepresentable {
  @Binding var text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.borderType = .bezelBorder
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.delegate = context.coordinator
    textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.textContainerInset = NSSize(width: 2, height: 4)
    textView.string = text
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
    textView.string = text
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    private let text: Binding<String>

    init(text: Binding<String>) { self.text = text }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }
}
