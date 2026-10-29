// Claude Bridge (Előd's): the browser half. It keeps a native-messaging
// port to host.py open; host.py relays requests from Claude Code's MCP
// server (mcp.py) and this file answers them with the WebExtension APIs.
// Nothing here listens on the network: the only way in is the host
// Firefox itself started.
'use strict'

let port = null

// if the host is missing or dies, try again: soon at first, then every 30 s
let retry = 2000
function connect() {
  port = browser.runtime.connectNative('claude_bridge')
  port.onMessage.addListener(m => { retry = 2000; onRequest(m) })
  port.onDisconnect.addListener(() => {
    port = null
    setTimeout(connect, retry)
    retry = Math.min(retry * 2, 30000)
  })
}

async function onRequest(m) {
  let reply
  try {
    reply = { id: m.id, result: await handle(m.method, m.params || {}) }
  } catch (e) {
    reply = { id: m.id, error: String((e && e.message) || e) }
  }
  if (port) port.postMessage(reply)
}

const sleep = ms => new Promise(r => setTimeout(r, ms))

async function tabOf(p) {
  if (p.tab != null) return browser.tabs.get(Number(p.tab))
  const [t] = await browser.tabs.query({ active: true, lastFocusedWindow: true })
  if (!t) throw new Error('no tab')
  return t
}

async function settle(id, ms = 20000) {
  const end = Date.now() + ms
  await sleep(150)
  while (Date.now() < end) {
    const t = await browser.tabs.get(id)
    if (t.status === 'complete') return t
    await sleep(200)
  }
  return browser.tabs.get(id)
}

const brief = t => ({ tab: t.id, window: t.windowId, active: t.active, title: t.title, url: t.url })

// page.js defines window.__claudeBridge in the tab's content-script world
async function inPage(tab, call) {
  const [ready] = await browser.tabs.executeScript(tab.id, { code: 'typeof __claudeBridge !== "undefined"' })
  if (!ready) await browser.tabs.executeScript(tab.id, { file: 'page.js' })
  const [r] = await browser.tabs.executeScript(tab.id, { code: '__claudeBridge.' + call })
  return r
}
const arg = v => JSON.stringify(v === undefined ? null : v)

// Claude's code runs through executeScript, which no page CSP can block:
// in the content-script world (the page's own globals are on
// window.wrappedJSObject). An expression gives its value; statements
// give what they `return`.
async function runJs(tab, code) {
  const wrap = body => `(async () => { try { const r = await (async () => ${body})(); return JSON.stringify(r === undefined ? null : r) } catch (e) { return JSON.stringify({ error: String(e) }) } })()`
  try {
    const [r] = await browser.tabs.executeScript(tab.id, { code: wrap(`(${code}\n)`) })
    return r
  } catch (e) {
    // errors while running come back inside the JSON, so this is the parse
    // failing: not an expression, read it as statements
    const [r] = await browser.tabs.executeScript(tab.id, { code: wrap(`{\n${code}\n}`) })
    return r
  }
}

async function handle(method, p) {
  switch (method) {
    case 'tabs':
      return (await browser.tabs.query({})).map(brief)

    case 'open': {
      // no url: a new tab, like ⌘T
      const t = await browser.tabs.create(p.url ? { url: p.url, active: p.active !== false } : { active: p.active !== false })
      return brief(await settle(t.id))
    }

    case 'navigate': {
      const t = await tabOf(p)
      if (p.url === 'back') await browser.tabs.goBack(t.id)
      else if (p.url === 'forward') await browser.tabs.goForward(t.id)
      else if (p.url === 'reload') await browser.tabs.reload(t.id)
      else await browser.tabs.update(t.id, { url: p.url })
      return brief(await settle(t.id))
    }

    case 'activate': {
      const t = await tabOf(p)
      await browser.tabs.update(t.id, { active: true })
      await browser.windows.update(t.windowId, { focused: true })
      return brief(await browser.tabs.get(t.id))
    }

    case 'close': {
      const t = await tabOf(p)
      await browser.tabs.remove(t.id)
      return { closed: t.id }
    }

    case 'screenshot': {
      const t = await tabOf(p)
      if (!t.active) { await browser.tabs.update(t.id, { active: true }); await sleep(300) }
      // in CSS pixels, so the coordinates on the picture are the ones click takes
      const view = await inPage(t, 'viewport()')
      const url = await browser.tabs.captureVisibleTab(t.windowId, { format: 'png', scale: 1 / (view.dpr || 1) })
      return { png: url.slice(url.indexOf(',') + 1), width: view.width, height: view.height, scrollX: view.scrollX, scrollY: view.scrollY }
    }

    case 'read':    return inPage(await tabOf(p), `read(${arg(p.filter)}, ${arg(p.limit)})`)
    case 'text':    return inPage(await tabOf(p), `text(${arg(p.limit)})`)
    case 'find':    return inPage(await tabOf(p), `find(${arg(p.query)})`)
    case 'click':   return inPage(await tabOf(p), `click(${arg(p.ref)}, ${arg(p.x)}, ${arg(p.y)}, ${arg(p.button)}, ${arg(p.double)})`)
    case 'type':    return inPage(await tabOf(p), `type(${arg(p.ref)}, ${arg(p.text)}, ${arg(p.clear)})`)
    case 'key':     return inPage(await tabOf(p), `key(${arg(p.key)}, ${arg(p.ref)})`)
    case 'scroll':  return inPage(await tabOf(p), `scroll(${arg(p.ref)}, ${arg(p.dx)}, ${arg(p.dy)})`)
    case 'select':  return inPage(await tabOf(p), `select(${arg(p.ref)}, ${arg(p.value)})`)
    case 'js':      return runJs(await tabOf(p), String(p.code || ''))

    default:
      throw new Error('unknown method ' + method)
  }
}

connect()
