import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1] / "examples"


class ExampleTests(unittest.TestCase):
    def test_every_example_is_closed_and_all_local_digests_match(self):
        seen = set()

        def visit(path):
            if path in seen:
                return
            seen.add(path)
            self.assertTrue(path.is_file(), str(path))
            self.assertTrue(path.is_relative_to(ROOT))
            content = path.read_bytes()
            self.assertNotIn(b"/Users/", content)
            try:
                document = json.loads(content)
            except (json.JSONDecodeError, UnicodeDecodeError):
                return

            def scan(value):
                if isinstance(value, dict):
                    uri = value.get("uri")
                    if isinstance(uri, str) and "://" not in uri:
                        self.assertFalse(Path(uri).is_absolute())
                        target = (path.parent / uri).resolve()
                        if "hash" in value and value["hash"]["alg"] == "sha256":
                            self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), value["hash"]["digest"])
                        visit(target)
                    for child in value.values():
                        scan(child)
                elif isinstance(value, list):
                    for child in value:
                        scan(child)
            scan(document)

        examples = list(ROOT.glob("*/assurance.json"))
        self.assertEqual(len(examples), 6)
        for example in examples:
            visit(example)


if __name__ == "__main__":
    unittest.main()
