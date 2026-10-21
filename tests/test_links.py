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

    def run_function(self, command, answers="", overrides="", expected_code=0):
        functions = SCRIPT.read_text(encoding="utf-8").split('case "${1:-menu}" in')[0]
        # Exercise real interactive functions without starting host services.
        harness = self.data / "harness.sh"
        harness.write_text(functions + "\napply_config() { :; }\n" + overrides + "\n" + command, encoding="utf-8", newline="\n")
        result = subprocess.run(
            ["sh", str(harness)],
            input=answers.encode("utf-8"), env={**os.environ, "MIERUSH_DATA_DIR": str(self.data)},
            capture_output=True,
        )
        result.stdout = result.stdout.decode("utf-8").replace("\r\n", "\n")
        result.stderr = result.stderr.decode("utf-8").replace("\r\n", "\n")
        self.assertEqual(result.returncode, expected_code, result.stderr)
        return result

    def test_quick_creation_default_port(self):
        result = self.run_function("create_node", "\n\n")
        nodes = [json.loads(f.read_text()) for f in (self.data / "nodes").glob("*.json")]
        created = next(n for n in nodes if n["id"] != "ab12")
        self.assertEqual(created["name"], "mieru-2")
        self.assertEqual(created["host"], "example.org")
        self.assertEqual(created["protocol"], "TCP")
        self.assertNotEqual(created["port"], 5102)
        self.assertEqual(result.stdout.count("mierus://"), 1)
        self.assertIn("监听端口 [", result.stderr)
        self.assertNotIn("创建数量 [", result.stderr)

    def test_batch_and_number_selection(self):
        self.run_function("create_node batch", "批量节点\n3\n\n")
        nodes = json.loads(self.run_cli("gen").stdout)
        self.assertEqual(len(nodes["users"]), 4)
        self.assertEqual(len({p["port"] for p in nodes["portBindings"]}), 4)
        result = self.run_function("select_node", "1\n")
        ids = sorted(f.stem for f in (self.data / "nodes").glob("*.json"))
        self.assertEqual(result.stdout.strip(), ids[0])

    def test_specified_ports_and_creation_links(self):
        result = self.run_function("create_node", "指定端口\n6200\n")
        self.assertIn("&port=6200&", result.stdout)
        result = self.run_function("create_node batch", "连续端口\n3\n6300\n")
        self.assertEqual(result.stdout.count("mierus://"), 3)
        for port in (6300, 6301, 6302):
            self.assertIn(f"&port={port}&", result.stdout)

    def test_batch_port_validation_before_creation(self):
        for answers in ("冲突\n3\n5101\n", "越界\n3\n65534\n"):
            self.run_function('create_node batch', answers, overrides='die() { printf "%s" "$*" >&2; exit 42; }', expected_code=42)
            self.assertEqual(len(list((self.data / "nodes").glob("*.json"))), 1)

    def test_auto_host_is_cached(self):
        (self.data / "settings.json").write_text(json.dumps({"host": "", "mtu": 1400, "seed": 42}))
        self.run_function("resolve_host", overrides="curl() { printf '203.0.113.10'; }")
        self.assertEqual(json.loads((self.data / "settings.json").read_text())["host"], "203.0.113.10")
        result = self.run_function("resolve_host", overrides="curl() { exit 99; }")
        self.assertNotIn("正在识别", result.stderr)

    def test_latest_and_pinned_core_version(self):
        result = self.run_function(
            'RELEASE=""; resolve_release; printf "%s" "$RELEASE"',
            overrides='curl() { printf \'{"tag_name":"v3.39.2"}\'; }',
        )
        self.assertEqual(result.stdout, "3.39.2")
        result = self.run_function(
            'RELEASE="3.38.1"; resolve_release; printf "%s" "$RELEASE"',
            overrides='curl() { exit 99; }',
        )
        self.assertEqual(result.stdout, "3.38.1")

    def test_oneclick_process_substitution_install(self):
        source = (SCRIPT.parent / "one-click.sh").read_text(encoding="utf-8")
        # Preserve the actual menu dispatch, substitute only the installer body.
        start = source.index("install_manager() (")
        end = source.index("\nrun_manager()", start)
        source = source[:start] + 'install_manager() ( printf "INSTALL_CALLED\\n"; )' + source[end:]
        harness = self.data / "oneclick-test.sh"
        harness.write_text(source, encoding="utf-8", newline="\n")
        result = subprocess.run(
            ["bash", "-c", 'bash <(cat "$1")', "test", str(harness)],
            input=b"1\n0\n", capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn(b"INSTALL_CALLED", result.stdout)


if __name__ == "__main__":
    unittest.main()
