// Reflowable book engine (EPUB / FB2), injected into the reader shell page.
//
// The book is one continuous document: chapters are <section class="rchap" data-chapter=N>
// inserted on demand around the reading position, so moving between chapters is seamless.
// Two layouts:
//   paged  — CSS columns, one (or two, in landscape) per screen; the native scroll view pages horizontally
//   scroll — continuous vertical scrolling
// Position is kept by anchoring to the text at the top-left of the screen, so inserting or
// removing chapters, late-loading images, rotation and font changes never move the reader.
(() => {
  'use strict';
  const R = (window.reader = {});
  const post = (m) => window.webkit.messageHandlers.reader.postMessage(m);
  const book = () => document.getElementById('book');
  const paged = () => document.documentElement.classList.contains('paged');

  let total = 0;
  let loaded = [];                 // chapter indices in document order
  let highlights = {};             // chapter -> [{id, start, end, color, text, prefix, suffix}]
  let anchor = null;               // {node, offset} at the reading position
  let touching = false, settling = false, idleTimer = 0;
  let pendingInserts = [];
  let requested = { next: -1, prev: -1 };
  let lastReport = '';
  const maxLoaded = 7;

  // ---------- geometry ----------

  const pageWidth = () => window.innerWidth;
  const sectionOf = (node) => (node && (node.nodeType === 1 ? node : node.parentElement))?.closest('.rchap');
  const chapterIndex = (sec) => Number(sec.dataset.chapter);
  const section = (index) => book().querySelector(`.rchap[data-chapter="${index}"]`);

  function readingPoint() {
    const cs = getComputedStyle(document.documentElement);
    const ph = parseFloat(cs.getPropertyValue('--ph')) || 40, pv = parseFloat(cs.getPropertyValue('--pv')) || 32;
    return paged() ? { x: ph + 8, y: pv + 8 } : { x: window.innerWidth / 2, y: 24 };
  }

  function caretAt(x, y) {
    const r = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
    if (r && book().contains(r.startContainer)) return { node: r.startContainer, offset: r.startOffset };
    const el = document.elementFromPoint(x, y);
    return el && book().contains(el) ? { node: el, offset: 0 } : null;
  }

  function recordAnchor() {
    const p = readingPoint();
    // Probe a few points: the top-left may be blank (margin, image gap).
    for (const dy of [0, 40, 120, 240]) {
      const a = caretAt(p.x, p.y + dy);
      if (a) { anchor = a; return; }
    }
  }

  function rectOf(node, offset) {
    if (!node.isConnected) return null;
    const range = document.createRange();
    try {
      if (node.nodeType === 3) {
        range.setStart(node, Math.min(offset, node.length));
        range.setEnd(node, Math.min(offset + 1, node.length));
      } else {
        range.selectNode(node);
      }
    } catch { return null; }
    const rects = range.getClientRects();
    return rects.length ? rects[0] : range.getBoundingClientRect();
  }

  function scrollToRect(rect, smooth) {
    const behavior = smooth ? 'smooth' : 'instant';
    if (paged()) {
      const w = pageWidth();
      const page = Math.floor((rect.left + window.scrollX) / w);
      window.scrollTo({ left: Math.max(0, page * w), top: 0, behavior });
    } else {
      window.scrollTo({ left: 0, top: Math.max(0, rect.top + window.scrollY - readingPoint().y), behavior });
    }
  }

  function restoreAnchor() {
    if (!anchor || !anchor.node.isConnected) return;
    const rect = rectOf(anchor.node, anchor.offset);
    if (rect) scrollToRect(rect, false);
  }

  // First and last page (paged) or top and bottom (scroll) of a chapter, in document coordinates.
  function extent(sec) {
    const first = sec.getClientRects()[0] || sec.getBoundingClientRect();
    const rects = sec.getClientRects();
    const last = rects[rects.length - 1] || first;
    if (paged()) {
      const w = pageWidth();
      return { start: Math.floor((first.left + window.scrollX) / w), end: Math.floor((last.right - 1 + window.scrollX) / w) };
    }
    const r = sec.getBoundingClientRect();
    return { start: r.top + window.scrollY, end: r.bottom + window.scrollY };
  }

  // ---------- position reporting & loading neighbours ----------

  function currentSection() {
    const p = readingPoint();
    const a = caretAt(p.x, p.y) || caretAt(p.x, p.y + 120);
    return (a && sectionOf(a.node)) || book().querySelector('.rchap');
  }

  function report() {
    const sec = currentSection();
    if (!sec) return;
    const ext = extent(sec);
    let progress, page = 0, pages = 0;
    if (paged()) {
      const cur = Math.round(window.scrollX / pageWidth());
      pages = ext.end - ext.start + 1;
      page = Math.min(Math.max(cur - ext.start, 0), pages - 1);
      progress = pages > 1 ? page / (pages - 1) : 0;
    } else {
      const h = Math.max(1, ext.end - ext.start - window.innerHeight);
      progress = Math.min(Math.max((window.scrollY - ext.start) / h, 0), 1);
    }
    const msg = { type: 'position', chapter: chapterIndex(sec), progress, page: page + 1, pages };
    const key = JSON.stringify(msg);
    if (key !== lastReport) { lastReport = key; post(msg); }
    requestNeighbours();
  }

  function requestNeighbours() {
    if (!loaded.length) return;
    const doc = document.documentElement;
    let nearEnd, nearStart;
    if (paged()) {
      const w = pageWidth();
      nearEnd = window.scrollX + w * 3 >= doc.scrollWidth;
      nearStart = window.scrollX < w * 2;
    } else {
      const h = window.innerHeight;
      nearEnd = window.scrollY + h * 3 >= doc.scrollHeight;
      nearStart = window.scrollY < h * 2;
    }
    const last = loaded[loaded.length - 1], first = loaded[0];
    if (nearEnd && last + 1 < total && requested.next !== last + 1) {
      requested.next = last + 1;
      post({ type: 'need', chapter: last + 1, where: 'append' });
    }
    if (nearStart && first > 0 && requested.prev !== first - 1) {
      requested.prev = first - 1;
      post({ type: 'need', chapter: first - 1, where: 'prepend' });
    }
  }

  // Inserting while a finger is down would yank the page; queue until the gesture settles.
  function scheduleIdle() {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      if (touching) return;
      if (!settling) recordAnchor();
      flushInserts();
      report();
    }, 180);
  }

  window.addEventListener('scroll', () => { if (!settling) scheduleIdle(); }, { passive: true });
  window.addEventListener('touchstart', () => { touching = true; }, { passive: true });
  window.addEventListener('touchend', () => { touching = false; scheduleIdle(); }, { passive: true });
  window.addEventListener('resize', () => { applyColumns(); settle(); });
  // Content size changes in scroll mode (paged mode reacts to inserts/image loads explicitly).
  new ResizeObserver(() => { if (!touching && !paged()) settle(); }).observe(book());

  // Re-pin the anchor after any layout change (insert, image load, font size, rotation).
  function settle() {
    settling = true;
    restoreAnchor();
    requestAnimationFrame(() => { restoreAnchor(); settling = false; report(); });
  }

  // ---------- chapters ----------

  function parse(text) {
    let doc = new DOMParser().parseFromString(text, 'application/xhtml+xml');
    if (!doc.body || doc.querySelector('parsererror')) doc = new DOMParser().parseFromString(text, 'text/html');
    return doc;
  }

  const absolute = (v, base) => (!v || v.startsWith('#') || /^[a-z][a-z0-9+.-]*:/i.test(v) ? v : new URL(v, base).href);

  function adoptHead(doc, base) {
    for (const link of doc.querySelectorAll('link[rel~="stylesheet"][href]')) {
      const href = absolute(link.getAttribute('href'), base);
      if (![...document.querySelectorAll('link[rel~="stylesheet"]')].some((l) => l.href === href)) {
        const el = document.createElement('link');
        el.rel = 'stylesheet';
        el.href = href;
        document.head.insertBefore(el, document.getElementById('reader-style'));
      }
    }
    for (const style of doc.querySelectorAll('style')) {
      const css = style.textContent;
      if (![...document.querySelectorAll('style[data-book]')].some((s) => s.textContent === css)) {
        const el = document.createElement('style');
        el.dataset.book = '1';
        el.textContent = css;
        document.head.insertBefore(el, document.getElementById('reader-style'));
      }
    }
  }

  function absolutize(root, base) {
    for (const el of root.querySelectorAll('[src], [href], [poster]')) {
      for (const attr of ['src', 'href', 'poster']) {
        const v = el.getAttribute(attr);
        if (v) el.setAttribute(attr, absolute(v, base));
      }
    }
    const XLINK = 'http://www.w3.org/1999/xlink';
    for (const el of root.querySelectorAll('image, use')) {
      const v = el.getAttributeNS(XLINK, 'href') || el.getAttribute('href');
      if (v) el.setAttributeNS(XLINK, 'href', absolute(v, base));
    }
    // Re-key ids per chapter so in-chapter links still work and chapters don't collide.
    return root;
  }

  R.insert = (index, text, base, where, chapterHighlights) => {
    if (where !== 'replace' && loaded.includes(index)) return;
    if (touching && where !== 'replace') { pendingInserts.push([index, text, base, where, chapterHighlights]); return; }
    if (where !== 'replace') recordAnchor();

    const doc = parse(text);
    adoptHead(doc, base);
    const sec = document.createElement('section');
    sec.className = 'rchap';
    sec.dataset.chapter = index;
    const body = doc.body || doc.documentElement;
    absolutize(body, base);
    for (const node of [...body.childNodes]) sec.appendChild(document.importNode(node, true));
    sec.addEventListener('load', settle, true);   // images finishing load change layout

    if (where === 'replace') {
      book().replaceChildren(sec);
      loaded = [index];
      requested = { next: -1, prev: -1 };
      anchor = null;
    } else if (where === 'append') {
      book().appendChild(sec);
      loaded.push(index);
    } else {
      book().prepend(sec);
      loaded.unshift(index);
    }
    highlights[index] = chapterHighlights || [];
    applyHighlights(index);
    prune();
    if (where !== 'replace') settle();
  };

  function flushInserts() {
    const queue = pendingInserts;
    pendingInserts = [];
    for (const args of queue) R.insert(...args);
  }

  // Keep memory bounded: drop the chapter farthest from the reader.
  function prune() {
    while (loaded.length > maxLoaded) {
      const sec = currentSection();
      const cur = sec ? chapterIndex(sec) : loaded[0];
      const victim = Math.abs(loaded[0] - cur) > Math.abs(loaded[loaded.length - 1] - cur) ? loaded[0] : loaded[loaded.length - 1];
      recordAnchor();
      section(victim)?.remove();
      loaded = loaded.filter((i) => i !== victim);
      if (victim < cur) requested.prev = -1; else requested.next = -1;
      settle();
    }
  }

  R.isLoaded = (index) => loaded.includes(index);

  // Jump to a loaded chapter at a fraction of its length (0…1) or to an element id inside it.
  R.goTo = (index, progress, fragment) => {
    const sec = section(index);
    if (!sec) return false;
    let target = null;
    if (fragment) target = sec.querySelector(`[id="${CSS.escape(fragment)}"], [name="${CSS.escape(fragment)}"]`);
    if (target) {
      scrollToRect(target.getBoundingClientRect(), false);
    } else if (paged()) {
      const ext = extent(sec);
      const page = ext.start + Math.round((progress || 0) * (ext.end - ext.start));
      window.scrollTo({ left: page * pageWidth(), top: 0, behavior: 'instant' });
    } else {
      const ext = extent(sec);
      window.scrollTo({ left: 0, top: ext.start + (progress || 0) * Math.max(0, ext.end - ext.start - window.innerHeight), behavior: 'instant' });
    }
    requestAnimationFrame(() => { recordAnchor(); report(); });
    return true;
  };

  // Pages one chapter takes at the current size (used by the hidden measuring view).
  // Waits for images, which change layout once decoded.
  R.measure = async () => {
    const sec = book().querySelector('.rchap');
    if (!sec) return 0;
    await Promise.all([...sec.querySelectorAll('img')].map((img) => (img.decode ? img.decode().catch(() => {}) : null)));
    await new Promise((r) => requestAnimationFrame(() => r()));
    if (paged()) {
      const ext = extent(sec);
      return Math.max(1, ext.end - ext.start + 1);
    }
    return Math.max(1, Math.ceil(sec.getBoundingClientRect().height / window.innerHeight));
  };

  R.turnPage = (delta) => {
    if (paged()) {
      const w = pageWidth();
      window.scrollTo({ left: (Math.round(window.scrollX / w) + delta) * w, behavior: 'smooth' });
    } else {
      window.scrollBy({ top: delta * (window.innerHeight - 80), behavior: 'smooth' });
    }
  };

  // ---------- layout ----------

  function applyColumns() {
    const wide = window.innerWidth > window.innerHeight && window.innerWidth >= 900;
    document.documentElement.style.setProperty('--cols', wide ? '2' : '1');
  }

  R.configure = (opts) => {
    if (opts.layout) {
      document.documentElement.classList.toggle('paged', opts.layout === 'paged');
      document.documentElement.classList.toggle('scroll', opts.layout !== 'paged');
    }
    if (opts.total != null) total = opts.total;
    if (opts.scale != null) {
      recordAnchor();
      document.documentElement.style.setProperty('--scale', String(opts.scale));
      settle();
    }
    applyColumns();
  };

  // ---------- selection, links, taps ----------

  let selTimer = 0;
  document.addEventListener('selectionchange', () => {
    clearTimeout(selTimer);
    selTimer = setTimeout(() => post({ type: 'selection', text: String(window.getSelection()) }), 250);
  });

  document.addEventListener('click', (e) => {
    const mark = e.target.closest && e.target.closest('mark.rhl');
    const link = e.target.closest && e.target.closest('a[href]');
    if (link) {
      e.preventDefault();
      post({ type: 'link', href: link.href });
      return;
    }
    if (mark && String(window.getSelection()) === '') {
      post({ type: 'tapHighlight', id: mark.dataset.hl });
      return;
    }
    if (String(window.getSelection()) !== '' || !paged()) return;
    const x = e.clientX / window.innerWidth;
    if (x < 0.22) R.turnPage(-1);
    else if (x > 0.78) R.turnPage(1);
  }, true);

  // ---------- text for the assistant ----------

  R.visibleText = () => {
    const w = window.innerWidth, h = window.innerHeight;
    const blocks = book().querySelectorAll('p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, td, dd, dt, .stanza');
    const out = [];
    for (const el of blocks) {
      if (el.querySelector('p, li, blockquote')) continue;
      const r = el.getBoundingClientRect();
      const visible = paged() ? r.right > -w && r.left < 2 * w : r.bottom > -h && r.top < 2 * h;
      if (visible) out.push(el.innerText.trim());
    }
    return out.filter(Boolean).join('\n');
  };

  // ---------- highlights ----------

  function textNodes(sec) {
    const walker = document.createTreeWalker(sec, NodeFilter.SHOW_TEXT);
    const nodes = [];
    let pos = 0;
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      nodes.push({ node: n, start: pos });
      pos += n.length;
    }
    return { nodes, text: nodes.map((n) => n.node.data).join('') };
  }

  function offsetIn(sec, container, offset) {
    const r = document.createRange();
    r.setStart(sec, 0);
    r.setEnd(container, offset);
    return r.toString().length;
  }

  R.captureSelection = () => {
    const sel = window.getSelection();
    if (!sel.rangeCount || sel.isCollapsed) return null;
    const range = sel.getRangeAt(0);
    const sec = sectionOf(range.startContainer);
    if (!sec) return null;
    const start = offsetIn(sec, range.startContainer, range.startOffset);
    let end = sec.contains(range.endContainer) ? offsetIn(sec, range.endContainer, range.endOffset) : textNodes(sec).text.length;
    const full = textNodes(sec).text;
    end = Math.min(end, full.length);
    const text = full.slice(start, end);
    if (!text.trim()) return null;
    return {
      chapter: chapterIndex(sec), start, end, text,
      prefix: full.slice(Math.max(0, start - 32), start),
      suffix: full.slice(end, end + 32),
    };
  };

  R.clearSelection = () => window.getSelection().removeAllRanges();

  const squash = (s) => s.replace(/\s+/g, ' ').trim();

  // Find where a stored highlight is now: trust offsets if the text still matches, else search.
  function locate(full, h) {
    if (squash(full.slice(h.start, h.end)) === squash(h.text)) return [h.start, h.end];
    let i = full.indexOf(h.prefix + h.text);
    if (i >= 0) return [i + h.prefix.length, i + h.prefix.length + h.text.length];
    i = full.indexOf(h.text);
    return i >= 0 ? [i, i + h.text.length] : null;
  }

  function wrap(sec, h) {
    const { nodes, text } = textNodes(sec);
    const span = locate(text, h);
    if (!span) return;
    const [s, e] = span;
    const parts = nodes.filter((n) => n.start < e && n.start + n.node.length > s);
    for (const { node, start } of parts) {
      let target = node;
      const from = Math.max(0, s - start), to = Math.min(node.length, e - start);
      if (to <= from) continue;
      if (from > 0) target = target.splitText(from);
      if (to - from < target.length) target.splitText(to - from);
      if (!target.data.trim() && parts.length > 1) continue;
      const mark = document.createElement('mark');
      mark.className = 'rhl';
      mark.dataset.hl = h.id;
      mark.style.setProperty('--hl', h.color);
      target.parentNode.insertBefore(mark, target);
      mark.appendChild(target);
    }
  }

  function unwrapAll(sec) {
    for (const mark of sec.querySelectorAll('mark.rhl')) {
      mark.replaceWith(...mark.childNodes);
    }
    sec.normalize();
  }

  function applyHighlights(index) {
    const sec = section(index);
    if (!sec) return;
    unwrapAll(sec);
    for (const h of highlights[index] || []) wrap(sec, h);
  }

  R.setHighlights = (all) => {
    highlights = {};
    for (const h of all) (highlights[h.chapter] ||= []).push(h);
    for (const index of loaded) applyHighlights(index);
  };

  R.reveal = (id) => {
    const mark = book().querySelector(`mark.rhl[data-hl="${id}"]`);
    if (!mark) return false;
    scrollToRect(mark.getBoundingClientRect(), false);
    requestAnimationFrame(() => { recordAnchor(); report(); });
    return true;
  };

  // ---------- read aloud ----------

  const SPEECH_BLOCKS = 'p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, td, dd, dt, .stanza, figcaption';
  let speechCursor = null, speechIds = 0;

  function speakableBlocks() {
    return [...book().querySelectorAll(SPEECH_BLOCKS)]
      .filter((el) => !el.querySelector('p, li, blockquote') && /\p{L}/u.test(el.textContent));
  }

  /// Next paragraphs to speak: from the top of the visible page on restart, else after the last batch.
  /// Each gets a stable id so highlights can find it again. Offsets are into textContent.
  R.speechParagraphs = (restart, count) => {
    const all = speakableBlocks();
    let start;
    if (restart || !speechCursor || !speechCursor.isConnected) {
      start = all.findIndex((el) => {
        const r = el.getBoundingClientRect();
        return paged() ? r.right > 1 && r.left < window.innerWidth : r.bottom > readingPoint().y;
      });
      if (start < 0) start = 0;
    } else {
      start = all.indexOf(speechCursor) + 1;
    }
    const batch = all.slice(start, start + (count || 20));
    if (batch.length) speechCursor = batch[batch.length - 1];
    // Running out of loaded text: ask for the next chapter so the next request finds it.
    if (start + batch.length >= all.length && loaded.length && loaded[loaded.length - 1] + 1 < total) {
      const next = loaded[loaded.length - 1] + 1;
      if (requested.next !== next) { requested.next = next; post({ type: 'need', chapter: next, where: 'append' }); }
    }
    return batch.map((el) => {
      if (!el.dataset.sid) el.dataset.sid = String(++speechIds);
      return { id: Number(el.dataset.sid), text: el.textContent };
    });
  };

  function rangeIn(el, start, end) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    let pos = 0, startSet = false;
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const next = pos + n.length;
      if (!startSet && start <= next) { range.setStart(n, Math.max(0, start - pos)); startSet = true; }
      if (startSet && end <= next) { range.setEnd(n, Math.max(0, end - pos)); return range; }
      pos = next;
    }
    if (startSet) range.setEndAfter(el.lastChild || el);
    return startSet ? range : null;
  }

  /// Highlights the sentence being spoken and keeps it on screen.
  R.speechHighlight = (id, start, length) => {
    const el = book().querySelector(`[data-sid="${id}"]`);
    if (!el) return;
    const range = rangeIn(el, start, start + length);
    if (!range) return;
    if (window.CSS && CSS.highlights) CSS.highlights.set('speech', new Highlight(range));
    const rect = range.getBoundingClientRect();
    const offscreen = paged()
      ? rect.left < 0 || rect.left >= window.innerWidth
      : rect.top < 40 || rect.bottom > window.innerHeight - 40;
    if (offscreen) {
      scrollToRect(rect, true);
      setTimeout(() => { recordAnchor(); report(); }, 400);
    }
  };

  R.speechClear = () => {
    if (window.CSS && CSS.highlights) CSS.highlights.delete('speech');
    speechCursor = null;
  };

  applyColumns();
})();
