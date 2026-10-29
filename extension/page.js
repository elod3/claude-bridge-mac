// Claude Bridge: the part that runs in a tab (content-script world).
// Elements Claude may act on get a ref, `data-claude-ref="ref_N"`, which
// click/type/scroll take back; coordinates are CSS pixels of the viewport,
// the same ones the screenshot is taken in.
'use strict'

var __claudeBridge = (() => {
  let next = 1
  const INTERACTIVE = 'a[href], button, input, select, textarea, summary, label, [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=option], [role=switch], [role=combobox], [role=textbox], [contenteditable=""], [contenteditable=true], [onclick], [tabindex]:not([tabindex="-1"])'

  function refOf(el) {
    if (!el.dataset.claudeRef) el.dataset.claudeRef = 'ref_' + next++
    return el.dataset.claudeRef
  }
  function byRef(ref) {
    const el = document.querySelector(`[data-claude-ref="${CSS.escape(ref)}"]`)
    if (!el) throw new Error(`${ref} is not on the page any more; read it again`)
    return el
  }
  function visible(el) {
    const r = el.getBoundingClientRect()
    if (r.width < 1 || r.height < 1) return false
    const s = getComputedStyle(el)
    return s.visibility !== 'hidden' && s.display !== 'none' && Number(s.opacity) > 0.05
  }
  function name(el) {
    const t = el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('alt') ||
      (el.labels && el.labels[0] && el.labels[0].innerText) || el.getAttribute('placeholder') ||
      (el.tagName === 'INPUT' && ['submit', 'button'].includes(el.type) ? el.value : '') ||
      el.innerText || el.textContent || ''
    return t.replace(/\s+/g, ' ').trim().slice(0, 100)
  }
  function kind(el) {
    const role = el.getAttribute('role')
    if (role) return role
    const tag = el.tagName.toLowerCase()
    if (tag === 'a') return 'link'
    if (tag === 'input') return 'input:' + (el.type || 'text')
    if (el.isContentEditable) return 'editable'
    return tag
  }
  function centre(el) {
    const r = el.getBoundingClientRect()
    return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)]
  }
  function line(el) {
    const [x, y] = centre(el)
    let s = `${refOf(el)} ${kind(el)} "${name(el)}" @${x},${y}`
    if ('value' in el && el.value && !['submit', 'button'].includes(el.type) && el.type !== 'password') s += ` value="${String(el.value).slice(0, 80)}"`
    if (el.type === 'password' && el.value) s += ' value=(hidden)'
    if (el.checked) s += ' checked'
    if (el.disabled) s += ' disabled'
    if (el.tagName === 'A') s += ` -> ${el.getAttribute('href').slice(0, 120)}`
    return s
  }
  function inView(el) {
    const r = el.getBoundingClientRect()
    return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth
  }

  function viewport() {
    return { width: innerWidth, height: innerHeight, dpr: devicePixelRatio, scrollX: Math.round(scrollX), scrollY: Math.round(scrollY) }
  }

  // filter: "interactive" (default) = what can be clicked or typed in;
  // "all" adds headings and text blocks, for the page's outline
  function read(filter, limit) {
    const sel = filter === 'all' ? INTERACTIVE + ', h1, h2, h3, h4, p, li, td, th, img[alt]' : INTERACTIVE
    const out = [`${document.title} — ${location.href}`, `viewport ${innerWidth}x${innerHeight}, scrolled to ${Math.round(scrollX)},${Math.round(scrollY)} of ${document.documentElement.scrollWidth}x${document.documentElement.scrollHeight}`]
    let n = 0
    for (const el of document.querySelectorAll(sel)) {
      if (!visible(el)) continue
      if (filter !== 'all' && el.closest('[aria-hidden=true]')) continue
      out.push((inView(el) ? '' : '(offscreen) ') + line(el))
      if (++n >= (limit || 400)) { out.push('… more; scroll or use find'); break }
    }
    return out.join('\n')
  }

  function text(limit) {
    const t = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n')
    return `${document.title} — ${location.href}\n\n` + t.slice(0, limit || 60000)
  }

  // what matches, the things you can click first and the closest names
  // first; text inside a button or link counts as that button or link
  function find(query) {
    const q = String(query || '').toLowerCase()
    const seen = new Set()
    const hits = []
    for (let el of document.querySelectorAll(INTERACTIVE + ', h1, h2, h3, h4, p, li, span, div, td')) {
      if (!visible(el)) continue
      const n = name(el).toLowerCase()
      if (!n.includes(q)) continue
      // the innermost match, not every ancestor that contains it
      if ([...el.children].some(c => name(c).toLowerCase().includes(q) && visible(c))) continue
      el = el.closest(INTERACTIVE) || el
      if (seen.has(el)) continue
      seen.add(el)
      const act = el.matches(INTERACTIVE)
      hits.push({ el, rank: (act ? 0 : 1e6) + (name(el).toLowerCase() === q ? 0 : 1000) + name(el).length })
    }
    hits.sort((a, b) => a.rank - b.rank)
    return hits.length ? hits.slice(0, 30).map(h => line(h.el)).join('\n') : 'nothing matches ' + JSON.stringify(query)
  }

  function target(ref, x, y) {
    if (ref) {
      const el = byRef(ref)
      if (!inView(el)) el.scrollIntoView({ block: 'center', inline: 'center' })
      const [cx, cy] = centre(el)
      return { el, x: cx, y: cy }
    }
    if (x == null || y == null) throw new Error('give a ref or x and y')
    const el = document.elementFromPoint(x, y)
    if (!el) throw new Error(`nothing at ${x},${y}`)
    return { el, x, y }
  }

  function click(ref, x, y, button, double) {
    const t = target(ref, x, y)
    // the element that is really on top at that point gets the events
    const el = document.elementFromPoint(t.x, t.y) || t.el
    const b = button === 'right' ? 2 : button === 'middle' ? 1 : 0
    const o = { bubbles: true, cancelable: true, composed: true, clientX: t.x, clientY: t.y, button: b, buttons: 1 << b, view: window }
    el.dispatchEvent(new PointerEvent('pointerover', o))
    el.dispatchEvent(new MouseEvent('mouseover', o))
    el.dispatchEvent(new PointerEvent('pointerdown', { ...o, pointerType: 'mouse', isPrimary: true }))
    el.dispatchEvent(new MouseEvent('mousedown', o))
    if (el.focus) el.focus({ preventScroll: true })
    el.dispatchEvent(new PointerEvent('pointerup', { ...o, pointerType: 'mouse', isPrimary: true, buttons: 0 }))
    el.dispatchEvent(new MouseEvent('mouseup', { ...o, buttons: 0 }))
    if (b === 2) el.dispatchEvent(new MouseEvent('contextmenu', o))
    else if (b === 0) {
      // .click() so links and form buttons do their default action
      if (typeof el.click === 'function') el.click()
      else el.dispatchEvent(new MouseEvent('click', { ...o, buttons: 0 }))
      if (double) { el.click(); el.dispatchEvent(new MouseEvent('dblclick', { ...o, buttons: 0, detail: 2 })) }
    }
    return `clicked ${line(t.el)}`
  }

  // React and co. watch the native value setter, so set it through that
  function setValue(el, v) {
    const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype
    const set = Object.getOwnPropertyDescriptor(proto, 'value').set
    set.call(el, v)
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
  }

  function type(ref, s, clear) {
    const el = ref ? byRef(ref) : document.activeElement
    if (!el || el === document.body) throw new Error('nothing focused to type into; give a ref')
    el.focus()
    if (el.isContentEditable) {
      if (clear) document.execCommand('selectAll')
      document.execCommand('insertText', false, s)
    } else if ('value' in el) {
      setValue(el, (clear ? '' : el.value) + s)
    } else throw new Error(`${ref} does not take text`)
    return `typed into ${line(el)}`
  }

  const KEYS = { enter: 'Enter', return: 'Enter', tab: 'Tab', escape: 'Escape', esc: 'Escape', backspace: 'Backspace', delete: 'Delete',
    up: 'ArrowUp', down: 'ArrowDown', left: 'ArrowLeft', right: 'ArrowRight', space: ' ', home: 'Home', end: 'End', pageup: 'PageUp', pagedown: 'PageDown' }
  function key(k, ref) {
    const el = ref ? byRef(ref) : (document.activeElement || document.body)
    const parts = String(k).split('+')
    const base = parts.pop()
    const mods = new Set(parts.map(p => p.toLowerCase()))
    const keyName = KEYS[base.toLowerCase()] || base
    const o = { key: keyName, code: keyName.length === 1 ? 'Key' + keyName.toUpperCase() : keyName, bubbles: true, cancelable: true, composed: true,
      ctrlKey: mods.has('ctrl') || mods.has('control'), shiftKey: mods.has('shift'), altKey: mods.has('alt'), metaKey: mods.has('meta') || mods.has('cmd') }
    const go = el.dispatchEvent(new KeyboardEvent('keydown', o))
    el.dispatchEvent(new KeyboardEvent('keyup', o))
    // what the browser would have done itself
    if (go && keyName === 'Enter' && el.form && el.tagName === 'INPUT') el.form.requestSubmit()
    if (go && keyName === 'Tab') {
      const all = [...document.querySelectorAll(INTERACTIVE)].filter(visible)
      const i = all.indexOf(el); const n = all[(i + (o.shiftKey ? -1 : 1) + all.length) % all.length]
      if (n) n.focus()
    }
    if (go && keyName === 'Backspace' && 'value' in el && !el.isContentEditable) setValue(el, el.value.slice(0, -1))
    return `pressed ${k} on ${el.tagName.toLowerCase()}`
  }

  function scroll(ref, dx, dy) {
    if (ref) {
      const el = byRef(ref)
      if (dx || dy) el.scrollBy(dx || 0, dy || 0)
      else el.scrollIntoView({ block: 'center' })
    } else window.scrollBy(dx || 0, dy == null ? innerHeight * 0.8 : dy)
    return viewport()
  }

  function select(ref, value) {
    const el = byRef(ref)
    if (el.tagName !== 'SELECT') throw new Error(`${ref} is not a <select>`)
    const opt = [...el.options].find(o => o.value === value || o.text.trim() === value)
    if (!opt) throw new Error(`no option ${JSON.stringify(value)}; there are: ${[...el.options].map(o => o.text.trim()).join(', ')}`)
    setValue(el, opt.value)
    return `selected ${opt.text.trim()}`
  }

  return { viewport, read, text, find, click, type, key, scroll, select }
})()
