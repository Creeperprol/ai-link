// AI Link cloud relay: lets the AI Remote app reach your Mac from anywhere.
// The app speaks the same /api/* the LAN server does; the Mac's cloud-agent.mjs syncs to /agent/sync.
// Secret: KEY (wrangler secret put KEY). State lives in one Durable Object and is rebuilt by the agent.

const J = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { 'content-type': 'application/json' } })

const sameKey = (a, b) => {
  if (!a || !b || a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

export default {
  async fetch(req, env) {
    const auth = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim()
    if (!sameKey(auth, env.KEY)) return J({ error: 'unauthorized' }, 401)
    return env.HUB.get(env.HUB.idFromName('hub')).fetch(req)
  },
}

const STALE_MS = 20000
const MAX_QUEUE = 50

export class Hub {
  constructor() {
    this.status = null // last sync from the Mac
    this.updatedAt = 0
    this.panes = new Map() // id -> { output, at }
    this.watch = new Map() // id -> until (ms), set when the app opens a pane
    this.queue = [] // commands waiting for the agent
    this.seq = 0
  }

  enqueue(cmd) {
    if (this.queue.length >= MAX_QUEUE) this.queue.shift()
    this.queue.push({ cid: ++this.seq, at: Date.now(), ...cmd })
    return this.seq
  }

  async fetch(req) {
    const url = new URL(req.url)
    const p = url.pathname
    const now = Date.now()
    const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {}

    if (p === '/agent/sync' && req.method === 'POST') {
      this.status = { machine: body.machine, mid: body.mid, httpPort: 0, peers: body.peers || [], tasks: [] }
      this.updatedAt = now
      for (const [id, output] of Object.entries(body.panes || {})) this.panes.set(id, { output: String(output).slice(-20000), at: now })
      const cmds = this.queue
      this.queue = []
      const watch = [...this.watch].filter(([, until]) => until > now).map(([id]) => id)
      return J({ cmds, watch })
    }

    if (p === '/api/status') {
      if (!this.status) return J({ error: 'agent offline' }, 503)
      const fresh = now - this.updatedAt < STALE_MS
      return J({ ...this.status, updatedAt: this.updatedAt, agentOnline: fresh }, fresh ? 200 : 503)
    }

    if (p === '/api/prompt' && req.method === 'POST') {
      const text = String(body.text || '').slice(0, 8000)
      if (!text) return J({ error: 'empty' }, 400)
      this.enqueue({ type: 'prompt', to: String(body.to || 'all'), text, kind: String(body.kind || 'raw') })
      return J({ ok: true, delivered: [{ id: String(body.to || 'all'), name: 'queued', via: 'cloud' }] })
    }

    let m = p.match(/^\/api\/nudge\/([\w-]+)$/)
    if (m && req.method === 'POST') {
      this.enqueue({ type: 'nudge', to: m[1], action: String(body.action || '') })
      return J({ ok: true })
    }

    if (p === '/api/spawn' && req.method === 'POST') {
      this.enqueue({ type: 'spawn', cli: String(body.cli || 'claude') })
      return J({ ok: true })
    }

    m = p.match(/^\/api\/pane\/([\w-]+)$/)
    if (m) {
      this.watch.set(m[1], now + 30000)
      const peer = this.status?.peers?.find(x => x.id === m[1])
      const pane = this.panes.get(m[1])
      return J({ id: m[1], name: peer?.name || '', pane: peer?.pane || '', output: pane ? pane.output : 'Waiting for the Mac…' })
    }

    return J({ error: 'not found' }, 404)
  }
}
