// Parent processes of a process, nearest first, on macOS, Linux and Windows. Used to tell which link
// session belongs to which Claude Code window: the session's MCP server and the window's hooks share the
// same claude process as their nearest common parent.
import { execFile } from 'node:child_process'

const run = (cmd, args) => new Promise(resolve => execFile(cmd, args, { timeout: 15_000, windowsHide: true, maxBuffer: 8 << 20 }, (err, out) => resolve(err ? '' : String(out))))

// [{ pid, name }] of pid's parents, nearest first.
export const ancestorInfo = async (pid, depth = 8) => {
  const out =
    process.platform === 'win32'
      ? await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId) $($_.ParentProcessId) $($_.Name)" }'])
      : await run('ps', ['-A', '-o', 'pid=,ppid=,comm='])
  const parent = new Map()
  const name = new Map()
  for (const line of out.split(/\r?\n/)) {
    const m = /^\s*(\d+)\s+(\d+)\s*(.*)$/.exec(line)
    if (!m) continue
    parent.set(Number(m[1]), Number(m[2]))
    name.set(Number(m[1]), m[3].trim().split(/[\\/]/).pop())
  }
  const chain = []
  let p = pid
  for (let i = 0; i < depth; i++) {
    const q = parent.get(p)
    if (!q || q <= 1 || chain.some(c => c.pid === q)) break
    chain.push({ pid: q, name: name.get(q) || '' })
    p = q
  }
  return chain
}

export const ancestors = async (pid, depth = 8) => (await ancestorInfo(pid, depth)).map(c => c.pid)
