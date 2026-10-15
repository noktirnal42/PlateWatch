#!/usr/bin/env python3
"""Install the local PlateWatch MCP and skill for Codex, Claude Code/Desktop and OpenCode.
Only PlateWatch entries are changed; private timestamped backups preserve existing configs.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import venv

ROOT = Path(__file__).resolve().parents[2]


def write_private(path: Path, text: str, backups: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backups.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(backups, 0o700)
        name = path.name + '-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f')
        target = backups / name
        shutil.copyfile(path, target)
        os.chmod(target, 0o600)
    temp = path.with_name(path.name + '.platewatch-tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(text)
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def json_config(path: Path, group: str, entry: dict, backups: Path):
    current = json.loads(path.read_text()) if path.exists() else {}
    current.setdefault(group, {})['platewatch'] = entry
    write_private(path, json.dumps(current, indent=2) + '\n', backups)


def install(home: Path, skip_dependencies=False):
    location = home / '.local/share/platewatch-mcp'
    location.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(location, 0o700)
    env = location / 'venv'
    if not (env / 'bin/python').exists():
        venv.EnvBuilder(with_pip=True).create(env)
    python = env / 'bin/python'
    if not skip_dependencies:
        subprocess.run([str(python), '-m', 'pip', 'install', '-r', str(ROOT / 'integrations/mcp/requirements.txt')], check=True)
    script = location / 'platewatch_mcp.py'
    shutil.copyfile(ROOT / 'integrations/mcp/platewatch_mcp.py', script)
    os.chmod(script, 0o600)
    backups = location / 'config-backups'
    command = [str(python), str(script)]
    codex = home / '.codex/config.toml'
    text = codex.read_text() if codex.exists() else ''
    block = '\n[mcp_servers.platewatch]\ncommand = ' + json.dumps(command[0]) + '\nargs = [' + json.dumps(command[1]) + ']\nenabled = true\nstartup_timeout_sec = 20\ntool_timeout_sec = 30\n'
    pattern = r'(?ms)^\[mcp_servers\.platewatch\]\n.*?(?=^\[|\Z)'
    text = re.sub(pattern, lambda _: block.lstrip(), text) if re.search(pattern, text) else text.rstrip() + '\n' + block
    write_private(codex, text, backups)
    stdio = {'type': 'stdio', 'command': command[0], 'args': command[1:]}
    json_config(home / '.claude.json', 'mcpServers', stdio, backups)
    # Claude chat/desktop and Code use different configuration files; preserve the other desktop settings.
    json_config(home / 'Library/Application Support/Claude/claude_desktop_config.json', 'mcpServers',
                {'command': command[0], 'args': command[1:]}, backups)
    json_config(home / '.config/opencode/opencode.json', 'mcp',
                {'type': 'local', 'command': command, 'enabled': True, 'timeout': 20000}, backups)
    skill = ROOT / 'skills/platewatch/SKILL.md'
    skills = [home / '.codex/skills/platewatch', home / '.agents/skills/platewatch',
              home / '.claude/skills/platewatch', home / '.config/opencode/skills/platewatch']
    for folder in skills:
        folder.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(skill, folder / 'SKILL.md')
    return {'command': command, 'clients': ['Codex', 'Claude Code', 'Claude Desktop', 'OpenCode'],
            'skills': [str(x) for x in skills], 'backups': str(backups), 'reload': 'Reload MCP integrations or start a new session in each desktop app'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-dependencies', action='store_true')
    args = parser.parse_args()
    print(json.dumps(install(Path.home(), args.skip_dependencies), indent=2))
