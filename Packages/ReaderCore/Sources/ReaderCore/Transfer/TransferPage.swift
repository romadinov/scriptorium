import Foundation

/// The single-page web UI served at `/` by `TransferServer`.
enum TransferPage {
    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Scriptorium — Wi-Fi Transfer</title>
<style>
  :root { --bg:#f6f5f2; --card:#fff; --ink:#1c1c1e; --muted:#6e6e73; --line:#e3e1dc; --accent:#2f6fde; --danger:#c4382d; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#151517; --card:#1f1f22; --ink:#f2f2f4; --muted:#9b9ba1; --line:#2e2e33; --accent:#6b9bff; --danger:#ff6b5e; }
  }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  main { max-width: 860px; margin: 0 auto; padding: 32px 20px 80px; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .sub { color: var(--muted); margin: 0 0 24px; }
  .bar { display:flex; gap:8px; align-items:center; flex-wrap:wrap; margin-bottom: 12px; }
  .crumbs { flex:1; min-width: 200px; font-weight:600; }
  .crumbs a { color: var(--accent); text-decoration:none; cursor:pointer; }
  .crumbs span.sep { color: var(--muted); margin: 0 6px; font-weight:400; }
  button { font:inherit; border:1px solid var(--line); background:var(--card); color:var(--ink); padding:7px 12px; border-radius:8px; cursor:pointer; }
  button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
  button:hover { filter: brightness(0.97); }
  #drop { border:2px dashed var(--line); border-radius:12px; padding:22px; text-align:center; color:var(--muted); margin-bottom:16px; transition: .15s; }
  #drop.over { border-color: var(--accent); color: var(--accent); background: color-mix(in srgb, var(--accent) 8%, transparent); }
  .list { background:var(--card); border:1px solid var(--line); border-radius:12px; overflow:hidden; }
  .row { display:flex; align-items:center; gap:12px; padding:10px 14px; border-top:1px solid var(--line); }
  .row:first-child { border-top:none; }
  .icon { width:22px; text-align:center; }
  .name { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .name a { color:inherit; text-decoration:none; cursor:pointer; }
  .name a.dir { font-weight:600; }
  .meta { color:var(--muted); font-size:13px; white-space:nowrap; }
  .actions { display:flex; gap:6px; }
  .actions button { padding:4px 9px; font-size:13px; }
  .actions .del { color: var(--danger); }
  .empty { padding:28px; text-align:center; color:var(--muted); }
  .uploads { margin-bottom:16px; }
  .up { display:flex; gap:10px; align-items:center; font-size:13px; padding:4px 0; }
  .up progress { flex: 0 0 180px; }
  .up .err { color: var(--danger); }
  @media (max-width: 560px) { .meta { display:none; } }
</style>
</head>
<body>
<main>
  <h1>Scriptorium — Wi-Fi Transfer</h1>
  <p class="sub">PDF, DjVu, EPUB and FB2. Keep Scriptorium open on the iPad while transferring.</p>
  <div class="bar">
    <div class="crumbs" id="crumbs"></div>
    <button id="mkdir">New folder</button>
    <button class="primary" id="pick">Upload files…</button>
    <input type="file" id="files" multiple hidden accept=".pdf,.djvu,.djv,.epub,.fb2,.zip">
  </div>
  <div id="drop">Drop books here to upload them into this folder</div>
  <div class="uploads" id="uploads"></div>
  <div class="list" id="list"></div>
</main>
<script>
let path = decodeURIComponent(location.hash.slice(1));
const $ = id => document.getElementById(id);
const enc = encodeURIComponent;

function fmtSize(n) {
  if (n < 1024) return n + " B";
  const u = ["KB","MB","GB"]; let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return n.toFixed(n < 10 ? 1 : 0) + " " + u[i];
}
function join(a, b) { return a ? a + "/" + b : b; }
function el(tag, props = {}, ...kids) {
  const e = Object.assign(document.createElement(tag), props);
  for (const k of kids) e.append(k);
  return e;
}

async function api(method, url) {
  const r = await fetch(url, { method });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || r.statusText);
  return body;
}

function go(p) { path = p; location.hash = enc(p); load(); }

function renderCrumbs() {
  const c = $("crumbs"); c.textContent = "";
  c.append(el("a", { textContent: "Library", onclick: () => go("") }));
  let acc = "";
  for (const part of path.split("/").filter(Boolean)) {
    acc = join(acc, part);
    const target = acc;
    c.append(el("span", { className: "sep", textContent: "/" }), el("a", { textContent: part, onclick: () => go(target) }));
  }
}

async function load() {
  renderCrumbs();
  const list = $("list");
  let data;
  try { data = await api("GET", "/api/list?path=" + enc(path)); }
  catch (e) { list.innerHTML = ""; list.append(el("div", { className: "empty", textContent: e.message })); return; }
  list.textContent = "";
  if (!data.entries.length) list.append(el("div", { className: "empty", textContent: "This folder is empty." }));
  for (const f of data.entries) {
    const full = join(path, f.name);
    const link = el("a", { textContent: f.name, className: f.isDirectory ? "dir" : "" });
    if (f.isDirectory) link.onclick = () => go(full);
    else link.href = "/api/download?path=" + enc(full);
    const del = el("button", { className: "del", textContent: "Delete" });
    del.onclick = async () => {
      if (!confirm(`Delete “${f.name}”${f.isDirectory ? " and everything in it" : ""}?`)) return;
      try { await api("POST", "/api/delete?path=" + enc(full)); load(); } catch (e) { alert(e.message); }
    };
    const actions = el("div", { className: "actions" });
    if (!f.isDirectory) actions.append(el("button", { textContent: "Download", onclick: () => location.href = "/api/download?path=" + enc(full) }));
    actions.append(del);
    list.append(el("div", { className: "row" },
      el("div", { className: "icon", textContent: f.isDirectory ? "📁" : "📖" }),
      el("div", { className: "name" }, link),
      el("div", { className: "meta", textContent: f.isDirectory ? "" : fmtSize(f.size) + " · " + new Date(f.modified * 1000).toLocaleDateString() }),
      actions));
  }
}

function upload(file) {
  const progress = el("progress", { max: 1, value: 0 });
  const status = el("span", { textContent: "" });
  const row = el("div", { className: "up" }, progress, el("span", { textContent: file.name }), status);
  $("uploads").append(row);
  return new Promise(resolve => {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", `/api/upload?path=${enc(path)}&name=${enc(file.name)}`);
    xhr.upload.onprogress = e => { if (e.lengthComputable) progress.value = e.loaded / e.total; };
    xhr.onload = () => {
      let body = {}; try { body = JSON.parse(xhr.responseText); } catch {}
      if (xhr.status === 200) { progress.value = 1; status.textContent = body.name !== file.name ? `saved as ${body.name}` : "done"; setTimeout(() => row.remove(), 2500); }
      else { status.className = "err"; status.textContent = body.error || xhr.statusText; }
      resolve();
    };
    xhr.onerror = () => { status.className = "err"; status.textContent = "Connection lost — is Scriptorium still open?"; resolve(); };
    xhr.send(file);
  });
}

async function uploadAll(files) {
  for (const f of files) await upload(f);   // sequential: the server handles one request per connection
  load();
}

$("pick").onclick = () => $("files").click();
$("files").onchange = e => { uploadAll([...e.target.files]); e.target.value = ""; };
$("mkdir").onclick = async () => {
  const name = prompt("Folder name");
  if (!name) return;
  try { await api("POST", `/api/mkdir?path=${enc(path)}&name=${enc(name)}`); load(); } catch (e) { alert(e.message); }
};
const drop = $("drop");
for (const t of ["dragenter", "dragover"]) document.addEventListener(t, e => { e.preventDefault(); drop.classList.add("over"); });
for (const t of ["dragleave", "drop"]) document.addEventListener(t, e => { e.preventDefault(); if (t === "drop" || !e.relatedTarget) drop.classList.remove("over"); });
document.addEventListener("drop", e => { if (e.dataTransfer.files.length) uploadAll([...e.dataTransfer.files]); });
window.onhashchange = () => { path = decodeURIComponent(location.hash.slice(1)); load(); };
load();
</script>
</body>
</html>
"""#
}
