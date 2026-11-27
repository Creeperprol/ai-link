// Which sessions are hosts. Several sessions can host at once: each has its own file
// ~/.ai-link/hosts/<id>.json ({ id, name }). The old single ~/.ai-link/host.json is still read.
// Dependency-free, Node 18+.
import fs from 'node:fs'
import path from 'node:path'

const readJson = f => { try { return JSON.parse(fs.readFileSync(f, 'utf8')) } catch { return null } }

/** Every host record in an AI Link folder (~/.ai-link), newest file format first, no duplicates. */
export function readHosts(home) {
  const out = []
  const seen = new Set()
  const add = h => { if (h && typeof h.id === 'string' && h.id && !seen.has(h.id)) { seen.add(h.id); out.push({ id: h.id, name: String(h.name || h.id) }) } }
  let names = []
  try { names = fs.readdirSync(path.join(home, 'hosts')) } catch { /* no hosts yet */ }
  for (const n of names) if (n.endsWith('.json')) add(readJson(path.join(home, 'hosts', n)))
  add(readJson(path.join(home, 'host.json')))
  return out
}

/** Set of host ids. */
export const hostIds = home => new Set(readHosts(home).map(h => h.id))

export function addHost(home, id, name) {
  fs.mkdirSync(path.join(home, 'hosts'), { recursive: true })
  fs.writeFileSync(path.join(home, 'hosts', `${id}.json`), JSON.stringify({ id, name }))
}

export function removeHost(home, id) {
  fs.rmSync(path.join(home, 'hosts', `${id}.json`), { force: true })
  if (readJson(path.join(home, 'host.json'))?.id === id) fs.rmSync(path.join(home, 'host.json'), { force: true })
}
