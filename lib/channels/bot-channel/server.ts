#!/usr/bin/env bun
/**
 * bot-channel: in-process MCP channel for the Zoidberg bot.
 *
 * The orchestrator (bash scheduler in watchers/) POSTs events here.
 * Each event is forwarded to Claude Code as a notifications/claude/channel
 * MCP notification, wrapped in a <channel source="bot-channel" ...> tag.
 *
 * Claude replies by calling the `reply` tool, which writes the response to
 * a file keyed by request_id. The orchestrator polls that file, and `reply`
 * ends the request: the turn is over and nothing further reaches the owner.
 * Interim updates go through the `progress` tool, which writes a sequenced
 * `<request_id>.progress.<seq>` file the orchestrator drains while it waits.
 * That distinction exists because a turn that acknowledged the owner through
 * `reply` ("checking now, will confirm shortly") silently stranded the work.
 *
 * Listens on localhost only. The orchestrator is the only client.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { mkdirSync, writeFileSync, renameSync } from 'fs'
import { join } from 'path'
import { homedir } from 'os'

const PORT = parseInt(process.env.BOT_CHANNEL_PORT ?? '8790', 10)
const REPLIES_DIR = process.env.BOT_CHANNEL_REPLIES_DIR ?? join(homedir(), '.claude', 'channels', 'bot-channel', 'replies')

mkdirSync(REPLIES_DIR, { recursive: true })

const mcp = new Server(
  { name: 'bot-channel', version: '0.0.1' },
  {
    capabilities: {
      experimental: { 'claude/channel': {} },
      tools: {},
    },
    instructions: [
      'Events from the bot-channel arrive as <channel source="bot-channel" request_id="..." kind="...">.',
      'kind="telegram" means a Telegram message from the bot owner — respond conversationally.',
      'kind="cron" means a scheduled task — the body is the full prompt; complete the task and report results.',
      'When you have finished your work for a given request_id, call the `reply` tool exactly once with that request_id and the final response text.',
      'Do not call `reply` more than once per request_id. Do not omit calling it — the orchestrator is blocked waiting for it.',
      '`reply` ENDS the request. Nothing you do after it reaches the owner, and no further message is sent unless they write again. Never call `reply` with a promise of work you have not done yet ("checking now", "will confirm shortly") — do the work first, then reply with the result.',
      'To tell the owner something mid-task without ending the request, call the `progress` tool. It delivers the text immediately and leaves the request open, so you keep working and still owe a `reply`.',
      'For cron tasks, the reply text is what the orchestrator forwards to the user; preserve any STATUS markers the prompt asks for verbatim on their own line.',
    ].join(' '),
  },
)

const REQUEST_ID_PROP = { type: 'string', description: 'The request_id from the inbound <channel> tag.' }

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description:
        'Send the FINAL response for a bot-channel event and end the request. Call once per request_id, only when the work is done — nothing you do afterwards reaches the owner. Never use it to promise work ("checking now", "will confirm shortly"); use `progress` for that.',
      inputSchema: {
        type: 'object',
        properties: {
          request_id: REQUEST_ID_PROP,
          text: { type: 'string', description: 'The final response text to deliver to the orchestrator.' },
        },
        required: ['request_id', 'text'],
      },
    },
    {
      name: 'progress',
      description:
        'Send an interim update to the owner WITHOUT ending the request. Use it for work that will take a while, or when you want to say what you found before you finish. Callable any number of times; you still owe exactly one `reply` afterwards.',
      inputSchema: {
        type: 'object',
        properties: {
          request_id: REQUEST_ID_PROP,
          text: { type: 'string', description: 'The interim update to deliver to the owner now.' },
        },
        required: ['request_id', 'text'],
      },
    },
  ],
}))

// Progress updates are ordered by a monotonic sequence baked into the filename.
// The orchestrator globs `<request_id>.progress.*` and sends them in sort order,
// so zero-padding is what keeps update 10 after update 9.
let progressSeq = 0

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const name = req.params.name
  if (name !== 'reply' && name !== 'progress') throw new Error(`unknown tool: ${name}`)
  const { request_id, text } = req.params.arguments as { request_id: string; text: string }
  if (!/^[a-zA-Z0-9_-]+$/.test(request_id)) throw new Error('invalid request_id')

  const suffix = name === 'reply' ? 'txt' : `progress.${String(++progressSeq).padStart(6, '0')}`
  const tmp = join(REPLIES_DIR, `.${request_id}.${suffix}.tmp`)
  const final = join(REPLIES_DIR, `${request_id}.${suffix}`)
  // Atomic rename: orchestrator reads only fully-written files
  writeFileSync(tmp, text)
  renameSync(tmp, final)
  return { content: [{ type: 'text', text: name === 'reply' ? 'sent' : 'progress delivered, request still open' }] }
})

await mcp.connect(new StdioServerTransport())

// HTTP listener: orchestrator POSTs events here
Bun.serve({
  port: PORT,
  hostname: '127.0.0.1',
  async fetch(req) {
    if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })

    let payload: { request_id: string; kind?: string; content: string; meta?: Record<string, string> }
    try {
      payload = await req.json()
    } catch {
      return new Response('bad json', { status: 400 })
    }
    if (!payload.request_id || typeof payload.request_id !== 'string') {
      return new Response('missing request_id', { status: 400 })
    }
    if (!/^[a-zA-Z0-9_-]+$/.test(payload.request_id)) {
      return new Response('invalid request_id', { status: 400 })
    }
    if (typeof payload.content !== 'string') {
      return new Response('missing content', { status: 400 })
    }

    // Filter meta to identifier-only keys (per MCP channel spec)
    const meta: Record<string, string> = { request_id: payload.request_id }
    if (payload.kind) meta.kind = payload.kind
    if (payload.meta) {
      for (const [k, v] of Object.entries(payload.meta)) {
        if (/^[A-Za-z0-9_]+$/.test(k) && typeof v === 'string') meta[k] = v
      }
    }

    await mcp.notification({
      method: 'notifications/claude/channel',
      params: { content: payload.content, meta },
    })
    return new Response(JSON.stringify({ ok: true, request_id: payload.request_id }), {
      headers: { 'content-type': 'application/json' },
    })
  },
})

// Log startup to stderr so it appears in the Claude session's diagnostic log
console.error(`[bot-channel] listening on 127.0.0.1:${PORT}, replies dir: ${REPLIES_DIR}`)
