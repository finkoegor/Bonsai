// Plays a batch through a copy of the Bonsai window: six files are dragged in,
// compressed two at a time, and the result is totted up. Loops while in view.

const icons = {
  upload: '<svg viewBox="0 0 24 24"><path d="M12.71 11.29a1 1 0 0 0-.33-.21 1 1 0 0 0-.76 0 1 1 0 0 0-.33.21l-2 2a1 1 0 0 0 1.42 1.42l.29-.3V17a1 1 0 0 0 2 0v-2.59l.29.3a1 1 0 0 0 1.42 0 1 1 0 0 0 0-1.42ZM19.18 7.2A7 7 0 0 0 5.6 9.02a4 4 0 0 0 .4 7.98 1 1 0 0 0 0-2 2 2 0 0 1 0-4 1 1 0 0 0 1-1 5 5 0 0 1 9.73-1.61 1 1 0 0 0 .78.67 3 3 0 0 1 2.14 4.47 1 1 0 0 0 1.71 1.04 5 5 0 0 0-2.18-7.37Z"/></svg>',
  trash: '<svg viewBox="0 0 24 24"><path d="M10 18a1 1 0 0 0 1-1v-6a1 1 0 0 0-2 0v6a1 1 0 0 0 1 1ZM20 6h-4V5a3 3 0 0 0-3-3h-2a3 3 0 0 0-3 3v1H4a1 1 0 0 0 0 2h1v11a3 3 0 0 0 3 3h8a3 3 0 0 0 3-3V8h1a1 1 0 0 0 0-2ZM10 5a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v1h-4Zm7 14a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V8h10Zm-3-1a1 1 0 0 0 1-1v-6a1 1 0 0 0-2 0v6a1 1 0 0 0 1 1Z"/></svg>',
  moon: '<svg viewBox="0 0 24 24"><path d="M21.64 13a1 1 0 0 0-1.05-.14 8.05 8.05 0 0 1-3.37.73 8.15 8.15 0 0 1-8.14-8.1 8.59 8.59 0 0 1 .25-2A1 1 0 0 0 8 2.36a10.14 10.14 0 1 0 14 11.69 1 1 0 0 0-.36-1.05Zm-9.5 6.69A8.14 8.14 0 0 1 7.08 5.22v.27a10.15 10.15 0 0 0 10.14 10.14 9.79 9.79 0 0 0 2.1-.22 8.11 8.11 0 0 1-7.18 4.32Z"/></svg>',
  gem: '<svg viewBox="0 0 24 24"><path d="m21.84 9.56-3.4-5.02A1.3 1.3 0 0 0 17.42 4H6.58a1.3 1.3 0 0 0-1.02.54l-3.4 5.02a1.3 1.3 0 0 0 .08 1.57l8.8 10.42a1.28 1.28 0 0 0 1.94 0l8.8-10.42a1.3 1.3 0 0 0 .08-1.57ZM16.88 6l2.03 3h-3.72l-1.5-3Zm-6.07 0h2.38l1.5 3H9.31Zm-3.69 0h3.19l-1.5 3H5.09ZM5.25 11h3.6l1.88 5.73ZM12 18.14 10.95 15 9.96 12 9.73 11h4.54l-.23 1-1 3Zm1.27-1.41L15.15 11h3.6Z"/></svg>',
  scale: '<svg viewBox="0 0 24 24"><path d="M22.96 13.82a.95.95 0 0 0-.03-.17l-2.3-6.14A3 3 0 0 0 22 5a1 1 0 0 0-2 0 1 1 0 0 1-1.88.47A2.89 2.89 0 0 0 15.54 4H13V3a1 1 0 0 0-2 0v1H8.46a2.89 2.89 0 0 0-2.58 1.47A1 1 0 0 1 4 5a1 1 0 0 0-2 0 3 3 0 0 0 1.37 2.51l-2.3 6.14a.95.95 0 0 0-.03.17A.95.95 0 0 0 1 14v.03a4 4 0 0 0 7.99.04V14a.95.95 0 0 0-.04-.18l-2.3-6.13A3 3 0 0 0 7.6 6.5a.9.9 0 0 1 .86-.5H11v13H8a1 1 0 0 0 0 2h8a1 1 0 0 0 0-2h-3V6h2.54a.9.9 0 0 1 .86.5 3 3 0 0 0 .95 1.19l-2.3 6.13a.95.95 0 0 0-.04.18v.03a4 4 0 0 0 7.99.04V14a.95.95 0 0 0-.04-.18ZM5 10.85 6.56 15H3.44ZM5 16a2 2 0 0 1-1.73-1h3.46A2 2 0 0 1 5 16Zm14-5.15L20.56 15h-3.12ZM19 16a2 2 0 0 1-1.73-1h3.46A2 2 0 0 1 19 16Z"/></svg>',
  bolt: '<svg viewBox="0 0 24 24"><path d="M19.87 8.6A1 1 0 0 0 19 8h-4.58l1.27-4.74a1 1 0 0 0-.17-.87A1 1 0 0 0 14.73 2h-7a1 1 0 0 0-1 .74l-2.68 10A1 1 0 0 0 5 14h3.87l-1.81 6.74a1 1 0 0 0 1.71.93l10.9-12a1 1 0 0 0 .2-1.07Zm-9.79 8.68 1.07-4a1 1 0 0 0-.17-.87A1 1 0 0 0 10.2 12H6.31l2.14-8h5l-1.26 4.74A1 1 0 0 0 13.13 10h3.6Z"/></svg>',
  info: '<svg viewBox="0 0 24 24"><path d="M12 2a10 10 0 1 0 10 10A10 10 0 0 0 12 2Zm0 18a8 8 0 1 1 8-8 8 8 0 0 1-8 8Zm0-8.5a1 1 0 0 0-1 1v3a1 1 0 0 0 2 0v-3a1 1 0 0 0-1-1Zm0-4a1.25 1.25 0 1 0 1.25 1.25A1.25 1.25 0 0 0 12 7.5Z"/></svg>',
  arrow: '<svg viewBox="0 0 24 24"><path d="M17.92 11.62a1 1 0 0 0-.21-.33l-5-5a1 1 0 0 0-1.42 1.42l3.3 3.29H7a1 1 0 0 0 0 2h7.59l-3.3 3.29a1 1 0 0 0 0 1.42 1 1 0 0 0 1.42 0l5-5a1 1 0 0 0 .21-.33 1 1 0 0 0 0-.76Z"/></svg>',
  check: '<svg viewBox="0 0 24 24"><path d="m14.72 8.79-4.29 4.3-1.65-1.65a1 1 0 1 0-1.41 1.41l2.35 2.36a1 1 0 0 0 1.41 0l5-5a1 1 0 0 0 0-1.42 1 1 0 0 0-1.41 0ZM12 2a10 10 0 1 0 10 10A10 10 0 0 0 12 2Zm0 18a8 8 0 1 1 8-8 8 8 0 0 1-8 8Z"/></svg>',
  clock: '<svg viewBox="0 0 24 24"><path d="M12 2a10 10 0 1 0 10 10A10 10 0 0 0 12 2Zm0 18a8 8 0 1 1 8-8 8 8 0 0 1-8 8Zm3.1-7.37L13 11.42V7a1 1 0 0 0-2 0v5a1 1 0 0 0 .5.87l3.1 1.79a1 1 0 0 0 1-1.73Z"/></svg>',
  cursor: '<svg viewBox="0 0 22 22"><path d="M4 2.5v15.2l4.1-3.9 2.6 6 2.7-1.2-2.6-5.9h5.7Z" fill="#fff"/><path d="M5 4.9v10.4l3.3-3.1 2.9 6.5.9-.4-2.9-6.5h4.6Z" fill="#000"/></svg>',
};

export const docs = {
  brand: '<div class="doc doc-land doc-brand"><span>2026</span><i></i><b>Brand<br>Book</b></div>',
  investor: '<div class="doc doc-land doc-investor"><span>Q3 update</span><b>+42%</b><svg viewBox="0 0 160 56" preserveAspectRatio="none"><defs><linearGradient id="dg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#34d399" stop-opacity=".45"/><stop offset="1" stop-color="#34d399" stop-opacity="0"/></linearGradient></defs><path d="M0 50 L20 44 L38 47 L58 34 L78 37 L98 24 L118 27 L138 12 L160 6 L160 56 L0 56Z" fill="url(#dg)"/><path d="M0 50 L20 44 L38 47 L58 34 L78 37 L98 24 L118 27 L138 12 L160 6" fill="none" stroke="#34d399" stroke-width="2"/></svg></div>',
  portfolio: '<div class="doc doc-land doc-portfolio"><em></em><i></i><i></i><b>Anna Kim, works</b></div>',
  lookbook: '<div class="doc doc-port doc-lookbook"><span>SS 26</span><i></i><b>Spring</b></div>',
  thesis: '<div class="doc doc-port doc-thesis"><b>Light and shade in early print</b><i></i><i></i><i></i><em></em><i></i><i></i><i></i><i></i></div>',
  lease: '<div class="doc doc-port doc-lease"><b>LEASE</b><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><em></em></div>',
};

const files = [
  { name: 'Brand Book 2026.pdf', doc: 'brand', size: 31.4, pages: 48, out: 5.9 },
  { name: 'Investor Update Q3.pdf', doc: 'investor', size: 18.2, pages: 22, out: 3.1 },
  { name: 'Portfolio Anna Kim.pdf', doc: 'portfolio', size: 24.6, pages: 36, out: 6.4 },
  { name: 'Lookbook Spring.pdf', doc: 'lookbook', size: 12.8, pages: 28, out: 2.9 },
  { name: 'Thesis final v7.pdf', doc: 'thesis', size: 4.3, pages: 112, out: 1.2 },
  { name: 'Lease signed scan.pdf', doc: 'lease', size: 9.6, pages: 6, out: 4.7 },
];

const mb = n => `${n.toFixed(1)} MB`;
const percent = (a, b) => `-${Math.round((1 - b / a) * 100)}%`;
const sleep = ms => new Promise(r => setTimeout(r, ms));

function markup() {
  const cards = files.map((f, i) => `
    <div class="card" data-i="${i}">
      <div class="card-thumb">${docs[f.doc]}<div class="chip"></div></div>
      <div class="card-info">
        <div class="card-name">${f.name}</div>
        <div class="card-meta">${mb(f.size)}, ${f.pages} pages</div>
        <div class="badge">${mb(f.out)}  ${percent(f.size, f.out)}</div>
      </div>
    </div>`).join('');
  return `
    <div class="app-lights"><i></i><i></i><i></i></div>
    <section class="app-files">
      <div class="app-head"><b>6 files</b><span>${mb(files.reduce((s, f) => s + f.size, 0))}</span><div class="app-clear">${icons.trash}Clear all</div></div>
      <div class="app-grid">${cards}</div>
      <div class="app-drop">${icons.upload}<b>Drop your PDFs here</b><span>Compress one file or a whole batch at once</span><small>100% local, files never leave your Mac</small></div>
    </section>
    <aside class="app-side">
      <div class="app-brand"><img src="/assets/icon-256.png" alt=""><div><b>Bonsai</b><small>PDF compressor</small></div><span class="moon">${icons.moon}</span></div>
      <div class="app-label">COMPRESSION LEVEL</div>
      <div class="preset"><i></i><div><b>Low compression</b><small>Highest quality, lighter file</small></div>${icons.gem}</div>
      <div class="preset is-on"><i></i><div><b>Recommended</b><small>Great quality, great compression</small></div>${icons.scale}</div>
      <div class="preset"><i></i><div><b>Extreme compression</b><small>Smallest file, reduced quality</small></div>${icons.bolt}</div>
      <div class="app-note">${icons.info}<span>Images stay sharp with the page filling a Retina or 5K display. Text, vectors and effects look exactly the same.</span></div>
      <div class="app-bottom">
        <div class="app-mode"><span>Save a copy</span><span>Replace original</span></div>
        <div class="app-progress"><div class="app-bar"><i></i></div><span class="app-stop">Stop</span></div>
        <div class="app-go"><span class="go-label">Compress PDF</span>${icons.arrow}</div>
        <div class="app-done"><div class="check"></div><b></b><span></span></div>
      </div>
    </aside>
    <div class="app-flock"><div class="doc-stack"></div><em>6</em></div>
    <div class="app-cursor">${icons.cursor}</div>`;
}

export function mountDemo(stage, { lottie, checkData } = {}) {
  const app = document.createElement('div');
  app.className = 'app';
  app.setAttribute('aria-hidden', 'true');
  app.innerHTML = markup();
  stage.append(app);

  const $ = s => app.querySelector(s);
  const cards = [...app.querySelectorAll('.card')];
  const cursor = $('.app-cursor');
  const flock = $('.app-flock');
  const go = $('.app-go');
  const goLabel = $('.go-label');
  const bar = $('.app-bar i');
  const done = $('.app-done');

  const stack = flock.querySelector('.doc-stack');
  stack.innerHTML = ['lookbook', 'investor', 'brand'].map((d, i) =>
    `<div class="doc-pos" style="position:absolute;transform:translate(${i * 6}px,${-i * 5}px) rotate(${(i - 1) * 5}deg)">${docs[d]}</div>`).join('');

  let check;
  if (lottie && checkData) {
    check = lottie.loadAnimation({ container: done.querySelector('.check'), renderer: 'svg', loop: false, autoplay: false, animationData: checkData });
  }

  let scale = 1;
  function fit() {
    const width = stage.clientWidth;
    const compact = width < 640;
    app.classList.toggle('is-compact', compact);
    const base = compact ? 420 : 1000;
    scale = Math.min(1.2, width / base);
    app.style.transform = `scale(${scale})`;
    stage.style.height = `${app.offsetHeight * scale}px`;
  }
  new ResizeObserver(fit).observe(stage);
  fit();

  // Positions inside the unscaled window.
  function point(el, fx = 0.5, fy = 0.5) {
    const a = app.getBoundingClientRect(), r = el.getBoundingClientRect();
    return [(r.left - a.left + r.width * fx) / scale, (r.top - a.top + r.height * fy) / scale];
  }
  const place = (el, [x, y]) => { el.style.transform = `translate(${x}px, ${y}px)`; };
  function travel(el, to, ms = 1000) {
    el.style.transitionDuration = `${ms}ms, .3s`;
    place(el, to);
    return sleep(ms);
  }

  const chipStates = {
    wait: `<span class="ico">${icons.clock}</span>Waiting`,
    run: '<span class="spin"></span>Compressing…',
    done: `${icons.check}Saved`,
  };
  function chip(card, state) {
    const el = card.querySelector('.chip');
    el.className = 'chip is-on' + (state === 'done' ? ' is-done' : state === 'wait' ? ' is-wait' : '');
    el.innerHTML = chipStates[state];
  }

  function reset() {
    app.classList.remove('has-files', 'is-running', 'is-done', 'is-hovering');
    cards.forEach(c => {
      c.classList.remove('is-in');
      c.querySelector('.chip').className = 'chip';
      c.querySelector('.badge').classList.remove('is-on');
    });
    goLabel.textContent = 'Compress PDF';
    bar.style.width = '0';
    cursor.classList.remove('is-on');
    flock.classList.remove('is-on');
    check?.goToAndStop(0, true);
  }

  let visible = false;
  let running = false;
  const compact = () => app.classList.contains('is-compact');

  async function play() {
    if (running) return;
    running = true;
    while (visible) {
      reset();
      await sleep(500);

      // Drag six files in from outside the window.
      const drop = $('.app-drop');
      const start = compact() ? [380, 470] : [-60, 560];
      cursor.style.transitionDuration = '0s'; flock.style.transitionDuration = '0s';
      place(cursor, start); place(flock, [start[0] - 70, start[1] - 50]);
      await sleep(30);
      cursor.classList.add('is-on'); flock.classList.add('is-on');
      const target = point(drop, 0.5, compact() ? 0.5 : 0.46);
      travel(flock, [target[0] - 70, target[1] - 50], 1100);
      setTimeout(() => app.classList.add('is-hovering'), 700);
      await travel(cursor, target, 1100);
      await sleep(250);
      flock.classList.remove('is-on');
      app.classList.remove('is-hovering');
      app.classList.add('has-files');
      cards.forEach((c, i) => setTimeout(() => c.classList.add('is-in'), 60 + i * 70));
      goLabel.textContent = 'Compress 6 PDFs';
      await sleep(900);

      // Press Compress.
      await travel(cursor, point(go, 0.62, 0.55), 900);
      cursor.classList.add('is-press'); go.classList.add('is-pressed');
      await sleep(160);
      cursor.classList.remove('is-press'); go.classList.remove('is-pressed');
      app.classList.add('is-running');
      go.innerHTML = '<span class="spin"></span><span class="go-label">Compressing 1 of 6…</span>';
      cards.forEach(c => chip(c, 'wait'));
      travel(cursor, compact() ? [400, 380] : [740, 420], 1200);

      // Two at a time, the way the app spreads work over cores.
      let finished = 0;
      const total = files.reduce((s, f) => s + f.size, 0);
      let doneBytes = 0;
      async function work(i) {
        const card = cards[i];
        chip(card, 'run');
        await sleep(520 + files[i].size * 22);
        chip(card, 'done');
        card.querySelector('.badge').classList.add('is-on');
        finished += 1;
        doneBytes += files[i].size;
        bar.style.width = `${(doneBytes / total) * 100}%`;
        const label = go.querySelector('.go-label');
        if (label) label.textContent = `Compressing ${Math.min(finished + 1, 6)} of 6…`;
      }
      const queue = [0, 1, 2, 3, 4, 5];
      await Promise.all([0, 1].map(async () => {
        while (queue.length) await work(queue.shift());
      }));
      await sleep(350);

      // The result.
      const out = files.reduce((s, f) => s + f.out, 0);
      done.querySelector('b').textContent = `Saved ${mb(total - out)} (${percent(total, out)})`;
      done.querySelector('span').textContent = `6 files, ${mb(total)} to ${mb(out)}`;
      app.classList.remove('is-running');
      app.classList.add('is-done');
      check?.goToAndPlay(0, true);
      cursor.classList.remove('is-on');
      await sleep(4200);

      go.innerHTML = `<span class="go-label">Compress PDF</span>${icons.arrow}`;
      cards.forEach((c, i) => setTimeout(() => c.classList.remove('is-in'), i * 40));
      app.classList.remove('is-done');
      await sleep(600);
    }
    running = false;
  }

  new IntersectionObserver(entries => {
    visible = entries[0].isIntersecting;
    if (visible) play();
  }, { threshold: 0.35 }).observe(stage);

  return { app, fit };
}
