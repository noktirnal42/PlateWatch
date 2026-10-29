import asyncio
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import tomllib
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('pw', HERE / 'platewatch_mcp.py')
pw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pw)

class BridgeTests(unittest.TestCase):
    def test_rejects_world_readable_discovery_and_bad_port(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'connection.json'
            p.write_text(json.dumps({'version': 1, 'port': 4567, 'token': 'x' * 40}))
            p.chmod(0o644)
            with self.assertRaises(pw.BridgeError): pw.connection(p)
            p.chmod(0o600)
            self.assertEqual(pw.connection(p)['port'], 4567)
            p.write_text(json.dumps({'version': 1, 'port': 'remote.example', 'token': 'x' * 40}))
            with self.assertRaises(pw.BridgeError): pw.connection(p)

    def test_symlink_csv_cannot_escape_import_root(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / 'imports'; root.mkdir()
            outside = Path(d) / 'secret.csv'; outside.write_text('private')
            link = root / 'data.csv'; link.symlink_to(outside)
            with self.assertRaises(pw.BridgeError): pw.read_csv(str(link), root)
            p = root / 'valid.csv'; p.write_text('name,status\nExample,pending\n')
            self.assertIn('Example', pw.read_csv(str(p), root))

    def test_transport_preserves_command_and_ignores_proxy(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *a): pass
            def read(self, size): return b'{"ok":true}'
        with patch.object(pw, 'connection', return_value={'port': 12345, 'token': 'x' * 40}), \
             patch.object(pw.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = Response()
            result = pw.call('feeds.preference', id='example', favorite=False)
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, 'http://127.0.0.1:12345/v1/command')
            self.assertEqual(json.loads(request.data)['arguments']['favorite'], False)
            self.assertTrue(result['ok'])
            self.assertEqual(opener.call_args.args[0].proxies, {})

    def test_tool_surface_and_permissions(self):
        tools = asyncio.run(pw.server.list_tools())
        names = {t.name for t in tools}
        self.assertEqual(len(names), 18)
        self.assertIn('platewatch_records_import_csv', names)
        self.assertFalse(any('accept' in n or 'moderate' in n or 'terms_confirm' in n or 'pacer' in n for n in names))
        tool = next(t for t in tools if t.name == 'platewatch_feed_preference')
        self.assertFalse(tool.annotations.readOnlyHint)
        schema = tool.inputSchema
        self.assertIn('id', schema['required'])
        self.assertIn('blocked', schema['properties'])

class InstallerTests(unittest.TestCase):
    def test_preserves_other_settings_and_is_idempotent(self):
        spec = importlib.util.spec_from_file_location('install_pw', HERE / 'install.py')
        installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            fake_python = home / '.local/share/platewatch-mcp/venv/bin/python'
            fake_python.parent.mkdir(parents=True); fake_python.touch()
            codex = home / '.codex/config.toml'; codex.parent.mkdir()
            codex.write_text('model = "preserve-model"\n[mcp_servers.other]\ncommand = "preserve-command"\n')
            claude = home / '.claude.json'; claude.write_text('{"unrelated": {"keep": true}}')
            result = installer.install(home, skip_dependencies=True)
            installer.install(home, skip_dependencies=True)
            parsed = tomllib.loads(codex.read_text())
            self.assertEqual(parsed['model'], 'preserve-model')
            self.assertEqual(parsed['mcp_servers']['other']['command'], 'preserve-command')
            self.assertEqual(codex.read_text().count('[mcp_servers.platewatch]'), 1)
            self.assertTrue(json.loads(claude.read_text())['unrelated']['keep'])
            self.assertEqual(json.loads(claude.read_text())['mcpServers']['platewatch']['command'], str(fake_python))
            self.assertTrue((home / '.config/opencode/skills/platewatch/SKILL.md').is_file())
            self.assertTrue(all(p.stat().st_mode & 0o077 == 0 for p in Path(result['backups']).iterdir()))

if __name__ == '__main__': unittest.main()
