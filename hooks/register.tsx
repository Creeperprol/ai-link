import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Inbox, Me, Msg, Role, Task } from '../types'


const PANE = 'session-link'
const log = atom({ plugin: 'session-link', key: 'log' } as const, [])
const me = atom({ plugin: 'session-link', key: 'me' } as const, null)
const role = atom({ plugin: 'session-link', key: 'role' } as const, 'solo')
const tasks = atom({ plugin: 'session-link', key: 'tasks' } as const, [])
const inbox = atom({ plugin: 'session-link', key: 'inbox' } as const, [])
const target = atom({ plugin: 'session-link', key: 'target' } as const, 'all')

const T_ASSIGN = 'mcp__session-link__assign'
const T_REPORT = 'mcp__session-link__report'
const T_PEERS = 'mcp__session-link__peers'
const T_RENAME = 'mcp__session-link__rename'
const T_COMMAND = 'mcp__session-link__command'
// What the host's model is told about running workers (added to its system prompt while it is the host).
const HOST_WORKFLOW = `You are the host of a multi-window setup: other Claude sessions (workers) take tasks you give them with the assign tool and answer with a short report. Run it like this. 1) Contract first: before assigning, write the shared contract (file ownership per worker, data shapes, function signatures, constants in one place). 2) Self-contained tasks: name the files the worker may edit, the contract to read, and the exact done-when check (a command that must pass). Workers already work silently, so do not ask them to chat. 3) Share work evenly: size each task (S one small file, M one module, L several modules), give it to the least-loaded idle worker (assign with worker "auto" does this), never queue two tasks on one worker while another is idle, split a lopsided big task by file ownership, and tell the person the split in one table (worker, task, size). Use worker "all" only for tasks that are truly identical. 4) Never trust a report alone: re-run the tests yourself, run an end-to-end check, look at real output, and say what was verified for real and what was not. 5) Diagnose first: reproduce a problem, find the cause, then send the owning worker a precise task with the repro; do not edit a worker's files while it may be editing them. 6) Watch worker context: a report saying NEEDS COMPACT or ctx ~100k or more means send that worker only small tasks and tell the person to run /compact in its window. 7) Use worker names exactly as peers lists them; if assign says no session matches, call peers again. Deploy or publish only when the person asked, after the checks pass.`

const T_SPAWN = 'mcp__session-link__spawn'

type Peer = { id: string; name: string; cwd: string; seen: number; tty?: string }

const FRESH_MS = 6 * 3600 * 1000
// A task still open after this long is shown as stale and no longer counts against its worker.
const STALE_TASK_MS = 15 * 60 * 1000
const isStale = (t: Task, now: number) => t.status === 'sent' && now - t.at >= STALE_TASK_MS
// Commands that would wipe a worker's context while it still holds an unfinished task.
const DESTRUCTIVE_COMMANDS = new Set(['clear', 'compact'])

const ago = (ms: number) => {
  const m = Math.max(0, Math.floor(ms / 60000))
  return m < 1 ? 'now' : m < 60 ? `${m}m ago` : `${Math.floor(m / 60)}h ago`
}

// Folder name of a path, whether it uses / (macOS, Linux) or \\ (Windows).
const base = (cwd: string) => cwd.split(/[\\/]+/).filter(Boolean).pop() ?? 'session'

async function listPeers($: any, selfId: string): Promise<Peer[]> {
  const now = await $.clock.now()
  const out: Peer[] = []
  for (const k of await $.store.keys()) {
    if (!k.startsWith('peer:')) continue
    const p = (await $.store.get(k)) as Peer | undefined
    if (p && p.id !== selfId && now - p.seen < FRESH_MS) out.push(p)
  }
  return out.sort((a, z) => z.seen - a.seen)
}

// The one worker to give the next task: fewest open tasks, then fewest finished, so work stays even.
async function leastLoaded($: any, list: Peer[]): Promise<Peer[]> {
  const board = (await read($, tasks)) as Task[]
  const now = await $.clock.now()
  const ranked: { p: Peer; open: number; done: number }[] = []
  for (const p of list) {
    const done = ((await $.store.get(`done:${p.id}`)) as number | undefined) ?? 0
    ranked.push({ p, open: board.filter(t => t.toId === p.id && t.status === 'sent' && !isStale(t, now)).length, done })
  }
  ranked.sort((a, z) => a.open - z.open || a.done - z.done || z.p.seen - a.p.seen)
  return ranked.length ? [ranked[0].p] : []
}

const pick = (list: Peer[], q: string) => {
  const w = q.toLowerCase()
  const exact = list.filter(p => p.name.toLowerCase() === w || p.id === q)
  if (exact.length) return exact
  return list.filter(p => p.name.toLowerCase().startsWith(w) || p.id.startsWith(q))
}

// The terminal device this session runs on (e.g. ttys003), so a sibling can bring its window forward.
let myTty: string | undefined
async function ttyOf($: any): Promise<string | undefined> {
  if (myTty !== undefined) return myTty || undefined
  try {
    const r = await $.process.run(['sh', '-c', 'ps -o tty= -p $PPID'])
    const t = r.stdout.trim()
    myTty = /^ttys\d+$/.test(t) ? t : ''
  } catch {
    myTty = ''
  }
  return myTty || undefined
}

// Selects the Terminal.app tab on that tty and raises its window.
async function focusTty($: any, tty: string | undefined): Promise<string | null> {
  if (!tty || !/^ttys\d+$/.test(tty)) return 'that session has no known Terminal window'
  const script = `tell application "Terminal"
repeat with w in windows
repeat with t in tabs of w
if tty of t is "/dev/${tty}" then
set selected of t to true
set index of w to 1
activate
return "ok"
end if
end repeat
end repeat
return "none"
end tell`
  try {
    const r = await $.process.run(['osascript', '-e', script])
    return r.stdout.trim() === 'ok' ? null : r.stderr.trim() || 'no Terminal.app window found for it'
  } catch (err) {
    return String(err)
  }
}

async function announce($: any, who: Me, cwd: string) {
  // A name chosen for this session (rename or auto-rename) survives a name rebuilt from the folder.
  const saved = (await $.store.get(`name:${who.id}`)) as string | undefined
  const name = saved || who.name
  const peer: Peer = { id: who.id, name, cwd, seen: await $.clock.now(), tty: await ttyOf($) }
  await $.store.set(`peer:${who.id}`, peer)
}

// `me` is set at session.start; after a plugin reload that hook has not rerun, so build it on demand.
async function getMe($: any): Promise<Me | null> {
  const known = await read($, me)
  try {
    const id = String(await $.session.id())
    if (known && known.id === id) return known
    const cwd = await $.session.cwd()
    const who: Me = { id, name: ((await $.store.get(`name:${id}`)) as string | undefined) || `${base(cwd)}-${id.slice(0, 4)}` }
    await update($, me, () => who)
    await announce($, who, cwd)
    return who
  } catch {
    return known
  }
}

async function remember($: any, m: Msg) {
  await update($, log, l => [...l, m].slice(-50))
  $.ui.invalidate('ui.render')
}

async function deliver($: any, who: Me, p: Peer, text: string): Promise<string | null> {
  const r = await $.session.send({ to: { sessionId: p.id }, text: `[from session "${who.name}"] ${text}` })
  if (r.isDelivered) {
    await remember($, { at: await $.clock.now(), dir: 'out', who: p.name, text })
    return null
  }
  if (/not running|gone/i.test(r.reason)) await $.store.delete(`peer:${p.id}`)
  return `${p.name}: ${r.reason}`
}

const TASK_RE = /\[TASK (\S+) host=(\S+) name="([^"]*)"\]\n([\s\S]*)$/
const RENAME_RE = /\[RENAME host=(\S+)\]\n([\s\S]*)$/
const COMMAND_RE = /\[COMMAND host=(\S+)\]\n([\s\S]*)$/
// Slash commands a host may run in a worker. Only ones that run without opening a picker or dialog (/model, /theme, /status... need a person at the keyboard and would leave the worker stuck). Nothing that runs code, edits files or changes permissions.
const WORKER_COMMANDS = new Set(['compact', 'clear', 'cost'])
// Splits "/cost" into its command and arguments; null unless the command is on the allowlist.
function parseWorkerCommand(raw: string): { command: string; args: string } | null {
  const m = /^\/?([a-z][a-z-]*)(?:\s+([\s\S]*))?$/.exec(raw.replace(/<[^>]*>/g, ' ').trim().split('\n')[0].trim().slice(0, 200))
  return m && WORKER_COMMANDS.has(m[1]) ? { command: m[1], args: (m[2] ?? '').trim() } : null
}
const REPORT_DONE = 'Result sent to the host. DONE: do not call report again. Your whole turn is finished. Write no text, no summary and no status line; if you must output something, output only a single period (.)'
// Task ids whose report is being or has been sent, so a repeated report call is not sent twice.
const reporting = new Set<string>()
const RESULT_RE = /\[RESULT (\S+) from="([^"]*)"\]\n([\s\S]*)$/

async function hostRecord($: any): Promise<{ id: string; name: string } | null> {
  const h = (await $.store.get('host')) as { id: string; name: string } | undefined
  return h ?? null
}

// Host-ness lives in the shared host record, and is judged against the live session id so the
// pane and the tools always agree, even if the cached identity is stale (after /clear or a reload).
async function isHost($: any, who: Me | null): Promise<boolean> {
  if (!who) return false
  const h = await hostRecord($)
  if (h === null) return false
  const live = String(await $.session.id())
  return h.id === live
}

const HANDOFF_MS = 60 * 1000

// Takes the note a just-ended session left for its /clear successor, if it is recent and from this folder.
async function takeHandoff($: any, cwd: string): Promise<{ name: string; host: boolean } | null> {
  const h = (await $.store.get('handoff')) as { fromId: string; name: string; cwd: string; host: boolean; at: number } | undefined
  if (!h) return null
  await $.store.delete('handoff')
  if (h.cwd !== cwd || (await $.clock.now()) - h.at > HANDOFF_MS) return null
  return { name: h.name, host: h.host }
}

// Turns host mode on or off; shared by the /host command and the pane (a plugin's own
// $.command.run does not reach its own hooks).
async function setHost($: any, who: Me, isOn: boolean) {
  const live = String(await $.session.id())
  const mine: Me = { id: live, name: who.name }
  await update($, role, () => (isOn ? 'host' : 'solo') as Role)
  if (isOn) {
    await $.store.set('host', { id: mine.id, name: mine.name })
  } else {
    const h = await hostRecord($)
    if (h && h.id === mine.id) await $.store.delete('host')
  }
  // Read it back: if the record did not take, say so rather than showing a host that is not.
  if ((await isHost($, mine)) !== isOn) $.ui.toast(`session-link: could not ${isOn ? 'become' : 'leave'} host`)
  $.ui.invalidate('ui.render')
}

// Names are plain text: drop any markup, such as the closing tag of the message envelope.
const cleanName = (raw: string) => raw.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60)

// Opens a macOS Terminal window running `claude` in dir, optionally with a first prompt.
const shq = (v: string) => `'${v.replace(/'/g, `'\\''`)}'`
const spawnTerminal = async ($: any, dir: string, prompt: string): Promise<string | null> => {
  const cmd = `cd ${shq(dir)} && claude${prompt ? ' ' + shq(prompt) : ''}`
  const script = `tell application "Terminal"\nactivate\ndo script "${cmd.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"\nend tell`
  try {
    const r = await $.process.run(['osascript', '-e', script])
    return r.exitCode === 0 ? null : r.stderr.trim() || `osascript exited ${r.exitCode}`
  } catch (err) {
    return String(err)
  }
}

// Asks one worker to take a new session name.
async function renameWorker($: any, who: Me, p: Peer, name: string): Promise<string | null> {
  // Names stay unique among live sessions (case-insensitive); the worker's own name is a no-op.
  if (p.name.toLowerCase() === name.toLowerCase()) return null
  const clash = (await listPeers($, who.id)).find(q => q.id !== p.id && q.name.toLowerCase() === name.toLowerCase())
  if (clash || who.name.toLowerCase() === name.toLowerCase()) return `name already used by ${clash ? clash.name : who.name}`
  const failed = await deliver($, who, p, `[RENAME host=${who.id}]\n${name}`)
  // Remember a worker the host has named, so auto-rename never overrides it (the peer list can lag behind a rename).
  if (!failed) await $.store.set(`named:${p.id}`, true)
  return failed
}

// Asks one worker to run a slash command such as /cost.
async function commandWorker($: any, who: Me, p: Peer, line: string): Promise<string | null> {
  return deliver($, who, p, `[COMMAND host=${who.id}]\n${line}`)
}

// Runs a slash command line on one worker, or on every worker for "all". Returns a one-line outcome.
async function runOnWorkers($: any, who: Me, target: string, line: string): Promise<string> {
  const parsed = parseWorkerCommand(line)
  if (!parsed) return `Not allowed. Allowed commands: ${[...WORKER_COMMANDS].map(c => '/' + c).join(', ')}.`
  const peers = await listPeers($, who.id)
  const matches = target === 'all' ? peers : pick(peers, target)
  if (matches.length === 0) return `No session matches "${target}". Try /sessions.`
  if (target !== 'all' && matches.length > 1) return `"${target}" is ambiguous: ${matches.map(p => p.name).join(', ')}`
  const out: string[] = []
  const board = (await read($, tasks)) as Task[]
  const now = await $.clock.now()
  for (const p of matches) {
    const busy = board.find(t => t.toId === p.id && t.status === 'sent' && !isStale(t, now))
    if (DESTRUCTIVE_COMMANDS.has(parsed.command) && busy) {
      out.push(`${p.name}: refused (still working on task ${busy.id}; /${parsed.command} would lose it)`)
      continue
    }
    const failed = await commandWorker($, who, p, `/${parsed.command} ${parsed.args}`.trim())
    out.push(failed ? `${p.name}: failed (${failed})` : `${p.name}: asked`)
  }
  return `/${parsed.command} ${parsed.args}`.trim() + ' -> ' + out.join('; ')
}

// Empties the whole board (the pane's Clear board button).
async function clearBoard($: any) {
  await update($, tasks, () => [])
  $.ui.invalidate('ui.render')
}

// Empties the message log (the pane's Clear messages button).
async function clearLog($: any) {
  await update($, log, () => [])
  $.ui.invalidate('ui.render')
}

// Hands one task to one worker and logs it on the board.
async function assign($: any, who: Me, p: Peer, text: string): Promise<string | null> {
  const used = new Set([...(await read($, tasks)).map(t => t.id), ...(await read($, inbox)).map(i => i.id)])
  let id = ''
  do id = `t${Math.random().toString(36).slice(2, 8).padEnd(6, '0')}`
  while (used.has(id))
  const body = `[TASK ${id} host=${who.id} name="${who.name}"]\n${text}\n\nWhen you are finished, call the tool ${T_REPORT} with task_id "${id}" and a short result.`
  const failed = await deliver($, who, p, body)
  // A worker still on its random default name is renamed after its first task.
  if (!failed && /-[0-9a-f]{4}$/.test(p.name) && !(await $.store.get(`named:${p.id}`))) {
    const short = cleanName(text).split(' ').slice(0, 3).join('-').toLowerCase().replace(/[^a-z0-9-]/g, '').slice(0, 20)
    const names = new Set([...(await listPeers($, who.id)).filter(q => q.id !== p.id).map(q => q.name.toLowerCase()), who.name.toLowerCase()])
    let pickName = short
    for (let n = 2; names.has(pickName.toLowerCase()); n++) pickName = `${short}-${n === 2 ? p.id.slice(0, 2) : p.id.slice(0, 2) + n}`
    if (short) await renameWorker($, who, p, pickName)
  }
  const t: Task = { id, toId: p.id, toName: p.name, text, status: failed ? 'failed' : 'sent', at: await $.clock.now() }
  await update($, tasks, l => [...l.filter(x => x.status !== 'failed' || t.at - x.at < 600000), t].slice(-30))
  $.ui.invalidate('ui.render')
  return failed
}

// ---- session link ----
export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    const id = await $.session.id()
    const cwd = await $.session.cwd()
    let name = options.name ? String(options.name) : ((await $.store.get(`name:${id}`)) as string | undefined) || `${base(cwd)}-${id.slice(0, 4)}`
    // /clear starts a new session id: carry the name and the host role over from the one it replaced.
    const carried = (e as { source?: string }).source === 'clear' ? await takeHandoff($, cwd) : null
    if (carried && !options.name) name = carried.name
    const who: Me = { id, name }
    await update($, me, () => who)
    await announce($, who, cwd)
    if (carried?.host) await setHost($, who, true)

    const refused: string[] = []
    for (const [name, description] of [
      ['sessions', 'List your other running Claude Code sessions'],
      ['tell', 'Message another session: /tell <name> <message>'],
      ['tellall', 'Message every other session: /tellall <message>'],
      ['link', 'Open the session link pane'],
      ['host', 'Make this session the host that hands out work: /host or /host off'],
      ['assign', 'Host: give a task to a session: /assign <name|all> <task>'],
      ['spawn', 'Host: open a new Terminal window with a Claude session: /spawn [dir] [-- first task]'],
      ['board', 'Host: show the task board, or /board clear to empty the board and messages'],
      ['setname', 'Host: rename another session: /setname <session> <new name>'],
      ['run', 'Host: run a slash command in a worker: /run <session|all> /cost'],
    ]) {
      try {
        await $.command.register({ name, description })
      } catch (err) {
        refused.push(`/${name}`)
      }
    }
    if (refused.length) $.ui.toast(`session-link: could not register ${refused.join(', ')} (name taken)`)
    try {
    await $.tool.register({
      name: 'assign',
      description: 'Host only. Give a task to another Claude Code session (a worker) and carry on; its result comes back as a message. Use worker "all" for every worker, or "auto" for the least-loaded one.',
      inputSchema: {
        type: 'object',
        properties: { worker: { type: 'string', description: 'Worker session name, "auto" (least-loaded worker) or "all"' }, task: { type: 'string', description: 'What the worker should do, self-contained' } },
        required: ['worker', 'task'],
      },
    })
    await $.tool.register({
      name: 'report',
      description: 'Worker only. Send the result of a task the host assigned back to the host.',
      inputSchema: {
        type: 'object',
        properties: { task_id: { type: 'string' }, result: { type: 'string', description: 'Short result or summary' } },
        required: ['task_id', 'result'],
      },
    })
    await $.tool.register({
      name: 'rename',
      description: 'Host only. Rename another Claude Code session (a worker).',
      inputSchema: {
        type: 'object',
        properties: { worker: { type: 'string', description: 'Worker session name' }, name: { type: 'string', description: 'The new session name' } },
        required: ['worker', 'name'],
      },
    })
    await $.tool.register({
      name: 'command',
      description: `Host only. Run a slash command in a worker session, e.g. "/cost" or "/effort high". Allowed: ${[...WORKER_COMMANDS].join(', ')}. Use worker "all" for every worker.`,
      inputSchema: {
        type: 'object',
        properties: { worker: { type: 'string', description: 'Worker session name, or "all"' }, command: { type: 'string', description: 'The slash command with its arguments, e.g. "/cost"' } },
        required: ['worker', 'command'],
      },
    })
    await $.tool.register({
      name: 'spawn',
      description: 'Host only. Open a new Terminal window running a Claude Code session (it joins as a worker). Optionally start it with a first prompt.',
      inputSchema: {
        type: 'object',
        properties: { dir: { type: 'string', description: 'Working directory (default: this session\'s)' }, prompt: { type: 'string', description: 'Optional first prompt for the new session' } },
      },
    })
    await $.tool.register({ name: 'peers', description: 'List the other running Claude Code sessions you can message.' })
    } catch (err) {
      $.ui.toast('session-link: could not register its tools')
    }
    void $.ui.open({ id: PANE, title: 'Sessions' })
    return next(e)
  })

  on('command.run', { command: 'host' }, async ($, e) => {
    const who = await getMe($)
    if (!who) return { text: 'Session link is not ready yet.' }
    if (e.args.trim() === 'off') {
      await setHost($, who, false)
      return { text: 'No longer hosting.' }
    }
    await setHost($, who, true)
    return { text: `${who.name} is the host. Give work with /assign <session|all> <task>, or ask me to delegate.` }
  })

  on('command.run', { command: 'assign' }, async ($, e) => {
    const who = await getMe($)
    if (!who) return { text: 'Session link is not ready yet.' }
    if (!(await isHost($, who))) return { text: 'Run /host first to make this session the host.' }
    const [target, ...rest] = e.args.trim().split(/\s+/)
    const text = rest.join(' ')
    if (!target || !text) return { text: 'Usage: /assign <session name|auto|all> <task> (auto = the least-loaded worker)' }
    const list = await listPeers($, who.id)
    const chosen = target === 'all' ? list : target === 'auto' ? await leastLoaded($, list) : pick(list, target)
    if (chosen.length === 0) return { text: `No session matches "${target}". Try /sessions.` }
    if (target !== 'all' && chosen.length > 1) return { text: `"${target}" is ambiguous: ${chosen.map(p => p.name).join(', ')}` }
    const out: string[] = []
    for (const p of chosen) {
      const f = await assign($, who, p, text)
      out.push(f ? `✗ ${f}` : `→ ${p.name}`)
    }
    return { text: out.join('\n') }
  })

  on('command.run', { command: 'spawn' }, async ($, e) => {
    const who = await getMe($)
    if (!who) return { text: 'Session link is not ready yet.' }
    if (!(await isHost($, who))) return { text: 'Run /host first to make this session the host.' }
    const [head, ...tail] = e.args.split(/\s+--\s+/)
    const dir = head.trim() || (await $.session.cwd()) || '.'
    const failed = await spawnTerminal($, dir, tail.join(' -- ').trim())
    return { text: failed ? `Could not open Terminal: ${failed}` : `Opened a Terminal window in ${dir}.` }
  })

  on('command.run', { command: 'setname' }, async ($, e) => {
    const who = await getMe($)
    if (!who) return { text: 'Session link is not ready yet.' }
    if (!(await isHost($, who))) return { text: 'Run /host first to make this session the host.' }
    const [target, ...rest] = e.args.trim().split(/\s+/)
    const name = cleanName(rest.join(' '))
    if (!target || !name) return { text: 'Usage: /setname <session> <new name>' }
    const matches = pick(await listPeers($, who.id), target)
    if (matches.length === 0) return { text: `No session matches "${target}". Try /sessions.` }
    if (matches.length > 1) return { text: `"${target}" is ambiguous: ${matches.map(p => p.name).join(', ')}` }
    const failed = await renameWorker($, who, matches[0], name)
    return { text: failed ? `Not renamed. ${failed}` : `Asked ${matches[0].name} to rename itself to "${name}".` }
  })

  on('command.run', { command: 'run' }, async ($, e) => {
    const who = await getMe($)
    if (!who) return { text: 'Session link is not ready yet.' }
    if (!(await isHost($, who))) return { text: 'Run /host first to make this session the host.' }
    const [target, ...rest] = e.args.trim().split(/\s+/)
    const line = rest.join(' ')
    if (!target || !line) return { text: 'Usage: /run <session|all> /cost' }
    return { text: await runOnWorkers($, who, target, line) }
  })

  on('command.run', { command: 'board' }, async ($, e) => {
    if (e.args.trim() === 'clear') {
      const before = (await read($, tasks)).length
      await clearBoard($)
      await clearLog($)
      return { text: `Cleared ${before} task${before === 1 ? '' : 's'} and the messages.` }
    }
    const list = await read($, tasks)
    if (list.length === 0) return { text: 'No tasks yet.' }
    const icon = { sent: '…', done: '✓', failed: '✗' }
    const now = await $.clock.now()
    return {
      text: list
        .map(t => `${isStale(t, now) ? '⚠ stale' : icon[t.status]} ${t.id}  ${t.toName}: ${t.text.slice(0, 60)}${t.result ? `\n    ⇒ ${t.result.slice(0, 200)}` : ''}`)
        .join('\n'),
    }
  })

  // The tools the model calls.
  on('tool.call', { tool: T_PEERS }, async $ => {
    const who = await getMe($)
    const list = await listPeers($, who ? who.id : '')
    return { result: list.length ? list.map(p => `${p.name} (${base(p.cwd)})`).join('\n') : 'No other sessions running.' }
  })

  on('tool.call', { tool: T_ASSIGN }, async ($, e) => {
    const who = await getMe($)
    if (!(await isHost($, who))) return { result: `This session is not the host (host record: ${JSON.stringify(await hostRecord($))}). The person must run /host first.` }
    const input = e as unknown as { worker?: string; task?: string }
    const worker = String(input.worker ?? '')
    const task = String(input.task ?? '')
    if (!worker || !task) return { result: 'Both worker and task are required.' }
    const list = await listPeers($, who.id)
    const chosen = worker === 'all' ? list : worker === 'auto' ? await leastLoaded($, list) : pick(list, worker)
    if (chosen.length === 0) return { result: `No session matches "${worker}".` }
    if (worker !== 'all' && chosen.length > 1) return { result: `"${worker}" is ambiguous: ${chosen.map(p => p.name).join(', ')}` }
    const out: string[] = []
    for (const p of chosen) {
      const f = await assign($, who, p, task)
      out.push(f ? `failed: ${f}` : `sent to ${p.name}`)
    }
    return { result: out.join('\n') }
  })

  on('tool.call', { tool: T_SPAWN }, async ($, e) => {
    const who = await getMe($)
    if (!who || !(await isHost($, who))) return { result: `This session is not the host (host record: ${JSON.stringify(await hostRecord($))}). The person must run /host first.` }
    const input = e as unknown as { dir?: string; prompt?: string }
    const dir = String(input.dir ?? '').trim() || (await $.session.cwd()) || '.'
    const failed = await spawnTerminal($, dir, String(input.prompt ?? '').trim())
    return { result: failed ? `Could not open Terminal: ${failed}` : `Opened a Terminal window in ${dir}. It will appear in peers once it starts.` }
  })

  on('tool.call', { tool: T_COMMAND }, async ($, e) => {
    const who = await getMe($)
    if (!who || !(await isHost($, who))) return { result: 'This session is not the host. The person must run /host first.' }
    const input = e as unknown as { worker?: string; command?: string }
    const worker = String(input.worker ?? '')
    const line = String(input.command ?? '')
    if (!worker || !line) return { result: 'Both worker and command are required.' }
    return { result: await runOnWorkers($, who, worker, line) }
  })

  on('tool.call', { tool: T_RENAME }, async ($, e) => {
    const who = await getMe($)
    if (!who || !(await isHost($, who))) return { result: `This session is not the host (host record: ${JSON.stringify(await hostRecord($))}). The person must run /host first.` }
    const input = e as unknown as { worker?: string; name?: string }
    const worker = String(input.worker ?? '')
    const name = cleanName(String(input.name ?? ''))
    if (!worker || !name) return { result: 'Both worker and name are required.' }
    const matches = pick(await listPeers($, who.id), worker)
    if (matches.length !== 1) return { result: matches.length ? `"${worker}" is ambiguous.` : `No session matches "${worker}".` }
    const failed = await renameWorker($, who, matches[0], name)
    return { result: failed ? `Not renamed: ${failed}` : `Asked ${matches[0].name} to rename itself to "${name}".` }
  })

  on('tool.call', { tool: T_REPORT }, async ($, e) => {
    const who = await getMe($)
    const input = e as unknown as { task_id?: string; result?: string }
    const id = String(input.task_id ?? '')
    const found = (await read($, inbox)).find(i => i.id === id)
    if (!who || !found) return { result: `No task ${id} was assigned to this session.` }
    // A second report for the same task (even one fired in the same batch) is not sent again.
    if (reporting.has(id)) return { result: REPORT_DONE }
    reporting.add(id)
    const r = await $.session.send({
      to: { sessionId: found.hostId },
      text: `[RESULT ${id} from="${who.name}"]\n${String(input.result ?? '')}`,
    })
    // The task is done: drop it so the worker goes back to normal once nothing is left.
    if (r.isDelivered) {
      // Stay quiet until the person next types here: a stop hook's feedback can arrive after the report.
      await $.store.set(`quiet:${await $.session.id()}`, true)
      await update($, inbox, l => l.filter(i => i.id !== id))
      $.ui.invalidate('ui.render')
    }
    if (!r.isDelivered) reporting.delete(id) // a failed send may be retried
    return { result: r.isDelivered ? REPORT_DONE : `Could not reach the host: ${r.reason}` }
  })

  on('command.run', { command: 'link' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Sessions' })
    return { text: 'Session pane opened.' }
  })

  on('command.run', { command: 'sessions' }, async $ => {
    const who = await getMe($)
    const list = await listPeers($, who ? who.id : '')
    const now = await $.clock.now()
    if (list.length === 0) return { text: 'No other sessions found. Start Claude Code in another terminal with this mod loaded.' }
    return { text: list.map(p => `${p.name}  ${base(p.cwd)}  ${ago(now - p.seen)}  (${p.id.slice(0, 8)})`).join('\n') }
  })

  on('command.run', { command: 'tell' }, async ($, e) => {
    const who = await getMe($)
    if (!who) return { text: 'Session link is not ready yet.' }
    const [target, ...rest] = e.args.trim().split(/\s+/)
    const text = rest.join(' ')
    if (!target || !text) return { text: 'Usage: /tell <session name or id> <message>' }
    const matches = pick(await listPeers($, who.id), target)
    if (matches.length === 0) return { text: `No session matches "${target}". Try /sessions.` }
    if (matches.length > 1) return { text: `"${target}" is ambiguous: ${matches.map(p => p.name).join(', ')}` }
    const failed = await deliver($, who, matches[0], text)
    return { text: failed ? `Not delivered. ${failed}` : `Sent to ${matches[0].name}.` }
  })

  on('command.run', { command: 'tellall' }, async ($, e) => {
    const who = await getMe($)
    if (!who) return { text: 'Session link is not ready yet.' }
    const text = e.args.trim()
    if (!text) return { text: 'Usage: /tellall <message>' }
    const list = await listPeers($, who.id)
    if (list.length === 0) return { text: 'No other sessions to tell.' }
    const failures: string[] = []
    for (const p of list) {
      const f = await deliver($, who, p, text)
      if (f) failures.push(f)
    }
    return { text: `Sent to ${list.length - failures.length}/${list.length} sessions.${failures.length ? '\n' + failures.join('\n') : ''}` }
  })

  // Multi-window: while this session holds a host task, the model only does the work and reports.
  on('prompt.compose', async ($, e, next) => {
    const r = await next(e)
    try {
      const quiet = Boolean(await $.store.get(`quiet:${await $.session.id()}`))
      if (await isHost($, await getMe($))) return { sections: [...r.sections, { id: 'session-link:host-workflow', scope: 'session' as const, text: HOST_WORKFLOW }] }
      if ((await read($, inbox)).length === 0 && !quiet) return r
    } catch {
      return r
    }
    return {
      sections: [
        ...r.sections,
        {
          id: 'session-link:silent-worker',
          scope: 'session' as const,
          text: `You are a worker in a multi-window setup and a host session has given you a task. Do only that task. Write no chat text between tool calls and no summary or thanks at the end: your only output is tool calls. Do not ask the user questions or offer next steps. When the work is done, call ${T_REPORT} once with the task_id and a short result (one or two sentences), then stop. Hook feedback that arrives after your report (a stop hook, a design or lint finding) is not a reason to write text: act on it with tool calls only, or ignore it, and never explain, triage or summarise it in chat. Put ctx ~NNk (your best estimate of your context size) in the report and add NEEDS COMPACT at about 100k or more. Read files in parts (grep first, then offset and limit), do not re-read what you just edited, and edit only the files your task names. Never write a closing line such as "Task X is done", "Nothing is left to do", "Idle" or a restatement of your report: the report call already said it. If the harness forces you to write something after the report, write exactly one period (.) and nothing else. This holds until the person next types in this session.`,
        },
      ],
    }
  })

  // A prompt the person types ends a worker's quiet spell.
  on('prompt.submit', async ($, e, next) => {
    if ((e as { origin?: { kind?: string } }).origin?.kind === 'composer') {
      try {
        await $.store.delete(`quiet:${await $.session.id()}`)
      } catch {
        // the store is best effort
      }
    }
    return next(e)
  })

  // Record what other sessions say to this one; the model still reads it as usual.
  on('session.receive', async ($, e, next) => {
    if (e.origin.kind === 'peer' || e.origin.kind === 'peer-send-message') {
      try {
        const now = await $.clock.now()
        const task = TASK_RE.exec(e.text)
        const result = RESULT_RE.exec(e.text)
        const rename = RENAME_RE.exec(e.text)
        const cmd = COMMAND_RE.exec(e.text)
        if (task) {
          // A task is only taken from the session registered as the host.
          const h = await hostRecord($)
          if (h && h.id === task[2]) {
            const item: Inbox = { id: task[1], hostId: task[2], hostName: task[3], text: task[4].split('\n\nWhen you are finished')[0] }
            await update($, inbox, l => [...l, item].slice(-30))
            await remember($, { at: now, dir: 'in', who: `task ${item.id}`, text: item.text.slice(0, 300) })
            $.ui.toast(`Task ${item.id} from ${item.hostName}`)
            if (options.autoRun === true) {
              void $.prompt
                .submit({ text: `Task ${item.id} from host "${item.hostName}": ${item.text}\nWhen finished, call ${T_REPORT} with task_id "${item.id}" and a short result.` })
                .catch(() => {})
            }
          }
        } else if (cmd) {
          // A command is only taken from the session registered as the host, and only from the allowlist.
          const h = await hostRecord($)
          const parsed = parseWorkerCommand(cmd[2])
          if (h && h.id === cmd[1] && parsed && DESTRUCTIVE_COMMANDS.has(parsed.command) && (await read($, inbox)).length > 0) {
            await remember($, { at: now, dir: 'in', who: h.name, text: `refused /${parsed.command}: an unfinished task is still open` })
            $.ui.toast(`Refused /${parsed.command} from ${h.name}: finish the open task first`)
            return { consumed: 'command refused' }
          }
          if (h && h.id === cmd[1] && parsed) {
            await $.command.run({ command: parsed.command, args: parsed.args })
            await remember($, { at: now, dir: 'in', who: h.name, text: `ran /${parsed.command} ${parsed.args}`.trim() })
            $.ui.toast(`${h.name} ran /${parsed.command} ${parsed.args}`.trim())
            return { consumed: 'command applied' }
          }
        } else if (rename) {
          // A rename is only taken from the session registered as the host.
          const h = await hostRecord($)
          const name = cleanName(rename[2])
          const who = await getMe($)
          if (h && h.id === rename[1] && name && who) {
            await $.command.run({ command: 'rename', args: name })
            const renamed: Me = { id: who.id, name }
            await $.store.set(`name:${who.id}`, renamed.name)
            await update($, me, () => renamed)
            await announce($, renamed, await $.session.cwd())
            await remember($, { at: now, dir: 'in', who: h.name, text: `renamed this session to "${name}"` })
            $.ui.toast(`${h.name} renamed this session to "${name}"`)
            // The rename is handled here: the model never reads it, so the worker does not answer it.
            return { consumed: 'rename applied' }
          }
        } else if (result) {
          const id = result[1]
          const found = (await read($, tasks)).find(t => t.id === id)
          // Only the worker the task went to may finish it; anyone else's result is logged and ignored.
          const peer = found ? ((await $.store.get(`peer:${found.toId}`)) as Peer | undefined) : undefined
          const fromOwner = !!found && (result[2] === found.toName || result[2] === peer?.name)
          if (found && !fromOwner) {
            await remember($, { at: now, dir: 'in', who: `${result[2]} ✗ ignored ${id}`, text: result[3].slice(0, 300) })
          } else if (found) {
            await update($, tasks, l => l.filter(t => t.id !== id)) // finished tasks clear themselves; the result still lands in the log
            await $.store.set(`done:${found.toId}`, (((await $.store.get(`done:${found.toId}`)) as number | undefined) ?? 0) + 1)
            await remember($, { at: now, dir: 'in', who: `${result[2]} ✓ ${id}`, text: result[3].slice(0, 300) })
            $.ui.toast(/NEEDS COMPACT/i.test(result[3]) ? `${result[2]} finished ${id} and needs /compact` : `${result[2]} finished ${id}`)
          }
        } else {
          await remember($, { at: now, dir: 'in', who: 'peer', text: e.text.slice(0, 300) })
        }
      } catch {
        // logging must never block delivery
      }
    }
    return next(e)
  })

  // /rename carries the new name as its argument: follow it at once, unless the option fixes one.
  on('command.run', { command: 'rename' }, async ($, e, next) => {
    const r = await next(e)
    try {
      const who = await getMe($)
      const t = e.args.trim()
      if (who && t && !options.name && who.name !== t) {
        const renamed: Me = { id: who.id, name: t }
        await $.store.set(`name:${who.id}`, renamed.name)
        await update($, me, () => renamed)
        await announce($, renamed, await $.session.cwd())
        $.ui.invalidate('ui.render')
      }
    } catch {
      // the name is cosmetic; never block /rename over it
    }
    return r
  })

  // Follow the name set with /rename, unless the option fixes one.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    try {
      const who = await getMe($)
      const t = e.session_title ? String(e.session_title) : ''
      if (who && t && !options.name && who.name !== t) {
        const renamed: Me = { id: who.id, name: t }
        await $.store.set(`name:${who.id}`, renamed.name)
        await update($, me, () => renamed)
        await announce($, renamed, await $.session.cwd())
        $.ui.invalidate('ui.render')
      }
    } catch {
      // the name is cosmetic; never block a prompt over it
    }
    return next(e)
  })

  // Keep this session's listing fresh while it is in use.
  on('turn.complete', async ($, e, next) => {
    try {
      const who = await getMe($)
      if (who) await announce($, who, await $.session.cwd())
    } catch {
      // a failed heartbeat must never affect the turn
    }
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    try {
      const who = await getMe($)
      if (who) {
        // Leave a note so a /clear successor in this folder can pick up the name and the host role.
        const host = await isHost($, who)
        await $.store.set('handoff', { fromId: who.id, name: who.name, cwd: await $.session.cwd(), host, at: await $.clock.now() })
        await $.store.delete(`peer:${who.id}`)
      }
    } catch {
      // leaving quietly
    }
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Input, Select } = $.ui.resolve(e)
    const who = await getMe($)
    const msgs = await read($, log)
    const myRole: Role = (await isHost($, who)) ? 'host' : 'solo'
    const board = await read($, tasks)
    const waiting = await read($, inbox)
    const pickedId = await read($, target)
    let list: Peer[] = []
    let now = 0
    try {
      now = await $.clock.now()
      list = await listPeers($, who ? who.id : '')
    } catch (err) {
      return <Text color="red">session-link error: {String(err)}</Text>
    }

    return (
      <Box flexDirection="column" paddingX={1}>
        <Text bold color="cyan">{who ? who.name : '…'}</Text>
        <Text>
          <Text dimColor>{who ? who.id.slice(0, 8) : ''} </Text>
          <Text bold color={myRole === 'host' ? 'yellow' : 'green'}>{myRole === 'host' ? '★ HOST' : 'worker'}</Text>
        </Text>
        <Text> </Text>

        <Text bold>OTHER SESSIONS</Text>
        {list.length === 0 ? <Text dimColor>none running</Text> : null}
        {list.map(p => {
          // Only the host knows what it handed out, so only it can say who is working.
          const open = myRole === 'host' ? board.filter(t => t.toId === p.id && t.status === 'sent' && !isStale(t, now)).slice(-1)[0] : undefined
          return (
            <Box key={p.id} flexDirection="column">
              <Text>
                <Text color={open ? 'yellow' : 'green'}>● </Text>
                <Text bold>{p.name}</Text>
                <Text dimColor> {ago(now - p.seen)}</Text>
              </Text>
              {myRole === 'host' ? (
                <Text key={`state-${p.id}`} wrap="truncate" color={open ? 'yellow' : undefined} dimColor={!open}>
                  {open ? `  working · ${open.text.slice(0, 24)}` : '  idle'}
                </Text>
              ) : null}
            </Box>
          )
        })}
        <Text> </Text>

        {myRole === 'host' ? (
          <Box flexDirection="column" marginBottom={1}>
            <Text bold>TASKS</Text>
            {board.length === 0 ? <Text dimColor>none yet · /assign name task</Text> : null}
            {board.length ? <Button key="clear" label="Clear board" onPress={() => clearBoard($)} /> : null}
            {board.slice(-4).map(t => (
              <Text key={t.id} wrap="truncate">
                <Text color={t.status === 'failed' ? 'red' : 'yellow'}>{t.status === 'failed' ? '✗ ' : isStale(t, now) ? '⚠ stale ' : '… '}</Text>
                <Text bold>{t.toName.slice(0, 14)} </Text>
                <Text dimColor>{t.text.slice(0, 28)}</Text>
              </Text>
            ))}
          </Box>
        ) : waiting.length ? (
          <Box flexDirection="column" marginBottom={1}>
            <Text bold>FROM THE HOST</Text>
            {waiting.slice(-4).map(i => (
              <Text key={i.id} wrap="truncate">
                <Text color="yellow">● </Text>
                <Text bold>{i.id} </Text>
                <Text dimColor>{i.text}</Text>
              </Text>
            ))}
          </Box>
        ) : null}

        <Box flexDirection="column" marginBottom={1}>
          <Text bold>PROMPT A WORKER</Text>
          {list.length === 0 ? (
            <Text dimColor>no other sessions yet</Text>
          ) : (
            <Box flexDirection="column">
              <Select
                key="target"
                label="to "
                value={pickedId}
                options={[{ value: 'all', label: 'all workers' }, ...list.map(p => ({ value: p.id, label: p.name }))]}
                onSelect={v => update($, target, () => v)}
              />
              <Input
                key="prompt"
                placeholder="type a task, Enter to send"
                submitLabel="send"
                onSubmit={async text => {
                  const task = text.trim()
                  if (!task || !who) return
                  if (myRole !== 'host') await setHost($, who, true)
                  const chosen = pickedId === 'all' ? list : list.filter(p => p.id === pickedId)
                  let ok = 0
                  for (const p of chosen) if (!(await assign($, who, p, task))) ok += 1
                  $.ui.toast(ok ? `Sent to ${ok} session${ok === 1 ? '' : 's'}` : 'Nothing was delivered')
                }}
              />
            </Box>
          )}
        </Box>

        <Text bold>MESSAGES</Text>
        {msgs.length ? <Button key="clear-msgs" label="Clear messages" onPress={() => clearLog($)} /> : null}
        {msgs.length === 0 ? <Text dimColor>nothing yet</Text> : null}
        {msgs.slice(-8).map((m, i) => (
          <Text key={`${m.at}-${i}`} wrap="truncate">
            <Text color={m.dir === 'in' ? 'yellow' : 'cyan'}>{m.dir === 'in' ? '← ' : '→ '}</Text>
            <Text bold>{m.who} </Text>
            <Text dimColor>{m.text}</Text>
          </Text>
        ))}
        <Text> </Text>
        {list.length ? (
          <Box flexDirection="column" marginBottom={1}>
            <Text bold>SWITCH SESSION</Text>
            {list.map(p => (
              <Button
                key={`go-${p.id}`}
                label={`Switch to ${p.name}`}
                onPress={async () => {
                  const f = await focusTty($, p.tty)
                  if (f) $.ui.toast(`Could not switch: ${f}`)
                }}
              />
            ))}
          </Box>
        ) : null}
        <Box>
          <Button key="refresh" label="Refresh" hotkey="r" onPress={() => $.ui.invalidate('ui.render')} />
          <Text> </Text>
          <Button
            key="host"
            label={myRole === 'host' ? 'Stop hosting' : 'Become host'}
            onPress={() => (who ? setHost($, who, myRole !== 'host') : undefined)}
          />
        </Box>
      </Box>
    )
  })

}
