/* AskDocs chat UI. Talks to the same API the Flutter screen uses.
 *
 * Streaming note: /chat/stream is POST and needs the X-User-Id header, so the
 * native EventSource (GET only, no custom headers) can't be used. We read the
 * fetch response body as a stream and parse SSE frames ("event:" / "data:")
 * manually - same wire format, more control.
 */

const USER_KEY = "askdocs.user";
const SESSION_KEY = "askdocs.session";

const els = {
  health: document.getElementById("health"),
  uploadForm: document.getElementById("upload-form"),
  uploadInput: document.getElementById("upload-input"),
  uploadStatus: document.getElementById("upload-status"),
  docList: document.getElementById("doc-list"),
  newSession: document.getElementById("new-session"),
  talkHuman: document.getElementById("talk-human"),
  sessionStatus: document.getElementById("session-status"),
  messages: document.getElementById("messages"),
  chatForm: document.getElementById("chat-form"),
  question: document.getElementById("question"),
  send: document.getElementById("send"),
};

function getUserId() {
  let id = localStorage.getItem(USER_KEY);
  if (!id) {
    id = "web-" + Math.random().toString(36).slice(2, 10);
    localStorage.setItem(USER_KEY, id);
  }
  return id;
}

function getSessionId() {
  return localStorage.getItem(SESSION_KEY) || "";
}
function setSessionId(id) {
  localStorage.setItem(SESSION_KEY, id);
}

function authHeaders(extra = {}) {
  return { "X-User-Id": getUserId(), ...extra };
}

function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text != null) node.textContent = text;
  return node;
}

function scrollDown() {
  els.messages.scrollTop = els.messages.scrollHeight;
}

/* --------------------------- health + documents --------------------------- */

async function refreshHealth() {
  try {
    const res = await fetch("/health");
    const h = await res.json();
    els.health.textContent = `${h.llm_provider} · ${h.documents} docs · ${h.chunks_indexed} chunks`;
    els.health.className = "health ok";
  } catch {
    els.health.textContent = "backend unreachable";
    els.health.className = "health bad";
  }
}

async function refreshDocs() {
  const res = await fetch("/documents", { headers: authHeaders() });
  const data = await res.json();
  els.docList.innerHTML = "";
  if (!data.documents.length) {
    els.docList.appendChild(el("li", "empty", "No documents yet — upload one."));
    return;
  }
  for (const d of data.documents) {
    const li = el("li");
    li.appendChild(el("span", "name", d.file_name));
    const right = el("span", "meta", `${d.num_chunks} chunks`);
    li.appendChild(right);
    const del = el("button", "del", "✕");
    del.title = "Delete document";
    del.addEventListener("click", () => deleteDoc(d.id));
    li.appendChild(del);
    els.docList.appendChild(li);
  }
}

async function deleteDoc(id) {
  await fetch(`/documents/${id}`, { method: "DELETE", headers: authHeaders() });
  await Promise.all([refreshDocs(), refreshHealth()]);
}

async function upload(file) {
  const form = new FormData();
  form.append("file", file);
  els.uploadStatus.textContent = "Uploading + indexing…";
  els.uploadStatus.className = "status";
  const res = await fetch("/documents/upload", { method: "POST", headers: authHeaders(), body: form });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    els.uploadStatus.textContent = (err.error && err.error.message) || "Upload failed.";
    els.uploadStatus.className = "status error";
    return;
  }
  const doc = await res.json();
  els.uploadStatus.textContent = `Indexed ${doc.file_name} (${doc.num_chunks} chunks).`;
  els.uploadStatus.className = "status ok";
  els.uploadInput.value = "";
  await Promise.all([refreshDocs(), refreshHealth()]);
}

/* --------------------------------- chat ----------------------------------- */

function addUserMessage(text) {
  const node = el("div", "msg user", text);
  els.messages.appendChild(node);
  scrollDown();
}

function addSystemNote(text) {
  els.messages.appendChild(el("div", "msg system", text));
  scrollDown();
}

function renderCitations(container, citations) {
  if (!citations || !citations.length) return;
  const box = el("div", "citations");
  for (const c of citations) {
    const chip = el("span", "cite", `[S${c.id}] ${c.file_name} · p${c.page}`);
    chip.title = c.snippet || "";
    box.appendChild(chip);
  }
  container.appendChild(box);
}

function attachFeedback(bubble, messageId) {
  const bar = el("div", "feedback");
  const make = (rating, label) => {
    const b = el("button", null, label);
    b.title = rating === "helpful" ? "Helpful" : "Not helpful";
    b.addEventListener("click", async () => {
      b.disabled = true;
      const res = await fetch("/feedback", {
        method: "POST",
        headers: authHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify({ message_id: messageId, rating }),
      });
      if (res.ok) {
        bar.querySelectorAll("button").forEach((x) => (x.disabled = true));
        b.classList.add("chosen");
        const out = await res.json();
        if (out.handoff_job_id) addSystemNote("Noted — escalating you to a human agent.");
      } else {
        b.disabled = false;
      }
    });
    return b;
  };
  bar.appendChild(make("helpful", "👍"));
  bar.appendChild(make("not_helpful", "👎"));
  bubble.appendChild(bar);
}

/** Parse one SSE block ("event: x\ndata: {...}") into {event, data}. */
function parseFrame(block) {
  let event = "message";
  const dataLines = [];
  for (const line of block.split("\n")) {
    if (line.startsWith("event:")) event = line.slice(6).trim();
    else if (line.startsWith("data:")) dataLines.push(line.slice(5).trim());
  }
  if (!dataLines.length) return { event, data: null };
  try {
    return { event, data: JSON.parse(dataLines.join("\n")) };
  } catch {
    return { event, data: null };
  }
}

async function ask(question) {
  els.send.disabled = true;
  els.sessionStatus.textContent = "";
  els.sessionStatus.className = "status";

  addUserMessage(question);
  const bubble = el("div", "msg assistant typing", "");
  els.messages.appendChild(bubble);
  scrollDown();

  let text = "";
  let pendingCitations = [];

  try {
    const res = await fetch("/chat/stream", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ session_id: getSessionId(), question }),
    });

    if (!res.ok) {
      bubble.classList.remove("typing");
      const err = await res.json().catch(() => ({}));
      const msg = (err.error && err.error.message) || `Request failed (${res.status}).`;
      bubble.textContent = msg;
      bubble.classList.add("fallback");
      if (res.status === 429) {
        const retry = res.headers.get("Retry-After");
        els.sessionStatus.textContent = retry ? `Rate limited — retry in ${retry}s.` : "Rate limited.";
        els.sessionStatus.className = "status error";
      }
      return;
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      // SSE frames are separated by a blank line.
      let sep;
      while ((sep = buffer.indexOf("\n\n")) !== -1) {
        const frame = buffer.slice(0, sep);
        buffer = buffer.slice(sep + 2);
        if (!frame.trim()) continue;
        const { event, data } = parseFrame(frame);
        handleEvent(event, data);
      }
    }
  } catch (e) {
    bubble.classList.remove("typing");
    bubble.textContent = text || "Connection error.";
    bubble.classList.add("fallback");
  } finally {
    bubble.classList.remove("typing");
    els.send.disabled = false;
    els.question.focus();
  }

  function handleEvent(event, data) {
    if (event === "session") {
      setSessionId(data.session_id);
    } else if (event === "citations") {
      pendingCitations = data || [];
    } else if (event === "token") {
      text += data.text;
      bubble.textContent = text;
      scrollDown();
    } else if (event === "done") {
      renderCitations(bubble, data.citations && data.citations.length ? data.citations : pendingCitations);
      if (data.needs_handoff) bubble.classList.add("fallback");
      if (data.ungrounded) addSystemNote("⚠ This answer wasn't grounded in your documents.");
      if (data.message_id) attachFeedback(bubble, data.message_id);
    } else if (event === "handoff") {
      if (data && data.job_id) addSystemNote("🧑‍💼 A human agent has been notified and a ticket opened.");
    }
  }
}

/* ------------------------------- controls --------------------------------- */

els.chatForm.addEventListener("submit", (e) => {
  e.preventDefault();
  const q = els.question.value.trim();
  if (!q) return;
  els.question.value = "";
  ask(q);
});

els.question.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    els.chatForm.requestSubmit();
  }
});

els.uploadForm.addEventListener("submit", (e) => {
  e.preventDefault();
  const file = els.uploadInput.files[0];
  if (file) upload(file);
});

els.newSession.addEventListener("click", () => {
  setSessionId("");
  els.messages.innerHTML = "";
  els.sessionStatus.textContent = "Started a new conversation.";
  els.sessionStatus.className = "status ok";
  addSystemNote("New conversation started. Ask a question about your documents.");
});

els.talkHuman.addEventListener("click", async () => {
  const sid = getSessionId();
  if (!sid) {
    els.sessionStatus.textContent = "Ask a question first, then escalate.";
    els.sessionStatus.className = "status error";
    return;
  }
  const res = await fetch(`/admin/api/sessions/${sid}/handoff`, { method: "POST", headers: authHeaders() });
  const out = await res.json().catch(() => ({}));
  if (out.queued) addSystemNote("🧑‍💼 Escalated to a human agent.");
  else addSystemNote("Already escalated for this conversation.");
});

/* --------------------------------- init ----------------------------------- */

async function init() {
  await refreshHealth();
  await refreshDocs();
  addSystemNote("Ask anything about your uploaded documents. Answers cite their sources.");
  setInterval(refreshHealth, 15000);
}

init();
