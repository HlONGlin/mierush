"""Exercise the real shell entry points with isolated node/config fixtures."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

SCRIPT = Path(__file__).resolve().parents[1] / "mierush.sh"


class LinksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        (self.data / "nodes").mkdir()
        (self.data / "settings.json").write_text(
            json.dumps({"host": "example.org", "mtu": 1400, "seed": 42})
        )
        self.node = dict(
            id="ab12", name="香港1(if) # &", host="120.253.251.139",
            username="user:@+", password="secret:/?#&+%", port=5102,
            protocol="TCP", enabled=True, handshake="HANDSHAKE_NO_WAIT",
            multiplexing="MULTIPLEXING_OFF",
        )
        self.save()

    def save(self):
        (self.data / "nodes" / "ab12.json").write_text(
            json.dumps(self.node), encoding="utf-8"
        )

    def run_cli(self, *args, check=True):
        return subprocess.run(
            ["sh", str(SCRIPT), *args],
            env={**os.environ, "MIERUSH_DATA_DIR": str(self.data)},
            capture_output=True, text=True, encoding="utf-8", check=check,
        )

    def test_uri_roundtrip_and_server_agreement(self):
        uri = urlsplit(self.run_cli("link", "ab12").stdout.strip())
        self.assertEqual(uri.scheme, "mierus")
        self.assertEqual(unquote(uri.username), self.node["username"])
        self.assertEqual(unquote(uri.password), self.node["password"])
        self.assertEqual(unquote(uri.fragment), self.node["name"])
        self.assertEqual(uri.hostname, self.node["host"])
        params = parse_qs(uri.query)
        self.assertEqual(params["port"], ["5102"])
        self.assertEqual(params["protocol"], ["TCP"])
        self.assertEqual(params["handshake-mode"], ["HANDSHAKE_NO_WAIT"])
        self.assertEqual(params["multiplexing"], ["MULTIPLEXING_OFF"])
        config = json.loads(self.run_cli("gen").stdout)
        self.assertEqual(config["portBindings"], [{"port": 5102, "protocol": "TCP"}])
        self.assertEqual(config["users"], [{"name": self.node["username"], "password": self.node["password"]}])
        self.assertEqual(params["mtu"], [str(config["mtu"])])
        self.assertEqual(base64.b64decode(params["traffic-pattern"][0]), bytes([8, config["trafficPattern"]["seed"]]))

    def test_ipv6_udp_and_subscription(self):
        self.node.update(host="2001:db8::1", protocol="UDP")
        self.save()
        uri = self.run_cli("link", "ab12").stdout.strip()
        self.assertIn("@[2001:db8::1]?", uri)
        self.assertEqual(parse_qs(urlsplit(uri).query)["protocol"], ["UDP"])
        self.assertEqual(base64.b64decode(self.run_cli("subscription").stdout).decode().strip(), uri)

    def test_disabled_and_empty(self):
        self.node["enabled"] = False
        self.save()
        self.assertEqual(self.run_cli("export").stdout, "")
        self.assertEqual(json.loads(self.run_cli("gen").stdout)["users"], [])
        (self.data / "nodes" / "ab12.json").unlink()
        self.assertEqual(json.loads(self.run_cli("gen").stdout)["portBindings"], [])

    def test_invalid_id_rejected(self):
        for value in ("../settings", "", "ab12;echo bad", "deadbeef"):
            self.assertNotEqual(self.run_cli("link", value, check=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
