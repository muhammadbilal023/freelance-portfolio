/* SyncFlow admin dashboard — vanilla JS, no build step, talks to /admin/api. */
(() => {
  'use strict';

  const REFRESH_MS = 5000;
  const LIMIT = 30;

  const $ = (selector) => document.querySelector(selector);

  async function getJson(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`${url} -> HTTP ${response.status}`);
    return response.json();
  }

  async function postJson(url) {
    const response = await fetch(url, { method: 'POST' });
    if (!response.ok) throw new Error(`${url} -> HTTP ${response.status}`);
    return response.json();
  }

  function el(tag, attrs, text) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs ?? {})) node.setAttribute(key, value);
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function row(...cells) {
    const tr = document.createElement('tr');
    tr.append(...cells);
    return tr;
  }

  function statusCell(status) {
    const td = el('td');
    td.appendChild(el('span', { class: `badge ${status}` }, status));
    return td;
  }

  function fillTable(tableId, rows, buildRow, emptyText) {
    const tbody = $(`#${tableId} tbody`);
    tbody.replaceChildren();
    if (rows.length === 0) {
      const td = el('td', { class: 'empty', colspan: '7' }, emptyText);
      tbody.appendChild(el('tr')).appendChild(td);
      return;
    }
    for (const item of rows) tbody.appendChild(buildRow(item));
  }

  function retryButton(label, onClick) {
    const button = el('button', { class: 'retry' }, label);
    button.addEventListener('click', async () => {
      button.disabled = true;
      try {
        await onClick();
        button.textContent = 'retried ✓';
        button.classList.add('done');
        await refresh();
      } catch (err) {
        button.textContent = 'failed — try again';
        button.disabled = false;
        console.error(err);
      }
    });
    return button;
  }

  // ---- Renderers ---------------------------------------------------------

  function renderQueueCards(counts) {
    const container = $('#queue-cards');
    container.replaceChildren();
    for (const status of ['queued', 'running', 'succeeded', 'dead']) {
      const card = el('div', { class: `card ${status}` });
      card.appendChild(el('div', { class: 'count' }, String(counts[status] ?? 0)));
      card.appendChild(el('div', { class: 'label' }, status));
      container.appendChild(card);
    }
  }

  function renderDeadLetters(deadLetters) {
    fillTable(
      'dead-letters',
      deadLetters,
      (dl) => {
        const actionCell = el('td');
        if (dl.retriedAt) {
          actionCell.appendChild(
            el('span', { class: 'badge duplicate' }, `retried ${dl.retriedAt}`),
          );
        } else {
          actionCell.appendChild(
            retryButton('Retry', () => postJson(`/admin/api/dead-letters/${dl.id}/retry`)),
          );
        }
        return row(
          el('td', {}, String(dl.id)),
          el('td', {}, dl.type),
          el('td', { class: 'error' }, dl.error),
          el('td', {}, String(dl.attempts)),
          el('td', {}, dl.diedAt),
          actionCell,
        );
      },
      'No failures 🎉',
    );
  }

  function renderJobs(jobs) {
    fillTable(
      'jobs',
      jobs,
      (job) => {
        const actionCell = el('td');
        if (job.status === 'dead' || job.status === 'succeeded') {
          actionCell.appendChild(
            retryButton('Re-run', () => postJson(`/admin/api/jobs/${job.id}/retry`)),
          );
        }
        return row(
          el('td', {}, String(job.id)),
          el('td', {}, job.type),
          statusCell(job.status),
          el('td', {}, `${job.attempts}/${job.maxAttempts}`),
          el('td', { class: 'error' }, job.lastError ?? ''),
          el('td', {}, job.updatedAt),
          actionCell,
        );
      },
      'No jobs yet',
    );
  }

  function renderEvents(events) {
    fillTable(
      'events',
      events,
      (event) =>
        row(
          el('td', {}, String(event.id)),
          el('td', {}, event.provider),
          el('td', {}, event.externalEventId),
          el('td', {}, event.eventType),
          statusCell(event.status),
          el('td', {}, event.receivedAt),
        ),
      'No webhook events yet',
    );
  }

  async function refresh() {
    try {
      const [health, jobsData, deadLettersData, eventsData] = await Promise.all([
        getJson('/health'),
        getJson(`/admin/api/jobs?limit=${LIMIT}`),
        getJson(`/admin/api/dead-letters?limit=${LIMIT}`),
        getJson(`/admin/api/events?limit=${LIMIT}`),
      ]);

      $('#health').textContent = `status: ${health.status} · uptime ${health.uptimeSeconds}s`;
      renderQueueCards(jobsData.counts);
      renderDeadLetters(deadLettersData.deadLetters);
      renderJobs(jobsData.jobs);
      renderEvents(eventsData.events);
    } catch (err) {
      $('#health').textContent = `dashboard refresh failed: ${err.message}`;
    }
  }

  setInterval(() => { refresh().catch(console.error); }, REFRESH_MS);
  refresh().catch(console.error);
})();
