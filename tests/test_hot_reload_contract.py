from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class HotReloadContractTests(unittest.TestCase):
    def test_style_sync_replaces_and_rolls_back_complete_nodes(self) -> None:
        source = (ROOT / "assets" / "hot-reload-client.fragment.html").read_text(
            encoding="utf-8"
        )
        self.assertIn("function replaceStyleNode", source)
        self.assertIn("current.replaceWith(document.importNode(next, true))", source)
        self.assertIn("function restoreStyleNode", source)
        self.assertIn("previous.cloneNode(true)", source)
        self.assertNotIn("current.textContent = next.textContent", source)
        snapshot = source.index("const previousPicoStyle = query('style[data-pico-css]')")
        fetch = source.index("await fetch('/__wireframe/document'")
        self.assertLess(snapshot, fetch)

    def test_pico_contract_is_validated_before_live_dom_mutation(self) -> None:
        source = (ROOT / "assets" / "hot-reload-client.fragment.html").read_text(
            encoding="utf-8"
        )
        validation = source.index("picoStyle.dataset.picoVersion !== expectedPicoVersion")
        mutation = source.index("replaceStyleNode(nextDocument, 'style[data-pico-css]')")
        self.assertLess(validation, mutation)
        sync_progress = source[source.index("function syncProgress") : source.index("function validateNextDocument")]
        self.assertNotIn("style[data-pico-css]", sync_progress)


if __name__ == "__main__":
    unittest.main()
