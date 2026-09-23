import AppKit
import SwiftUI

/// A compact, scrolling composer with predictable Return handling on macOS.
struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onMoveSuggestion: (Int) -> Bool
    let onCompleteSuggestion: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 112))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.font = NSFont.preferredFont(forTextStyle: .body)
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("チャット入力")
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? NSTextView else { return }
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
        }
        if isFocused, let window = scrollView.window, window.firstResponder !== editor {
            window.makeFirstResponder(editor)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer

        init(_ parent: ChatComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }

        func textDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func textDidEndEditing(_ notification: Notification) { parent.isFocused = false }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            if selector == #selector(NSResponder.moveDown(_:)) { return parent.onMoveSuggestion(1) }
            if selector == #selector(NSResponder.moveUp(_:)) { return parent.onMoveSuggestion(-1) }
            if selector == #selector(NSResponder.insertTab(_:)) { return parent.onCompleteSuggestion() }
            let isReturn = selector == #selector(NSResponder.insertNewline(_:))
            let isLineBreak = selector == #selector(NSResponder.insertLineBreak(_:))
            guard isReturn || isLineBreak else { return false }
            // Return first commits a Japanese IME composition. Only a completed
            // keystroke can send or insert a line break.
            if isLineBreak || NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                parent.onSubmit()
            }
            return true
        }
    }
}
