#!/usr/bin/env python3
"""Real MCP stdio handshake + read-only live Hub acceptance. Run with the installed runtime Python."""
import asyncio
import json
from pathlib import Path
import sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    installed = Path.home() / '.local/share/platewatch-mcp/platewatch_mcp.py'
    params = StdioServerParameters(command=sys.executable, args=[str(installed)])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as client:
            initialized = await client.initialize()
            tools = await client.list_tools()
            assert len(tools.tools) == 14
            resources = await client.list_resources()
            assert any(str(r.uri) == 'platewatch://capabilities' for r in resources.resources)
            async def call(name, arguments=None):
                result = await client.call_tool(name, arguments or {})
                assert not result.isError, name
                if result.structuredContent is not None: return result.structuredContent
                return json.loads(next(c.text for c in result.content if c.type == 'text'))
            status = await call('platewatch_status')
            assert status.get('connected'), status
            feeds = await call('platewatch_feeds_list', {'limit': 2})
            review = await call('platewatch_review_list', {'limit': 1})
            records = await call('platewatch_records_list', {'limit': 1})
            draft = await call('platewatch_foia_draft', {'agency': 'Example Public Works', 'units': ['D756']})
            assert draft['submitted'] is False and draft['included_units'] == ['D756']
            assert '[Your name]' in draft['body']
            invalid = await client.call_tool('platewatch_feed_get', {'id': 123})
            assert invalid.isError, 'Invalid schema should be a tool error'
            print(json.dumps({'server': initialized.serverInfo.name, 'tools': len(tools.tools),
                'connected': True, 'catalogue_count': feeds['total'], 'queued_count': review['total'],
                'record_candidate_count': records['total'], 'foia_draft': 'validated, not submitted',
                'invalid_arguments_rejected': True, 'live_data_mutated': False}, indent=2))

if __name__ == '__main__': asyncio.run(main())
