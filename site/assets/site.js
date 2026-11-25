import { mountDemo } from './demo.js';

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const root = document.documentElement;
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));

function lottieReady() {
  return new Promise(resolve => {
    if (window.lottie) return resolve(window.lottie);
    const script = document.querySelector('script[src*="lottie"]');
    script?.addEventListener('load', () => resolve(window.lottie), { once: true });
    script?.addEventListener('error', () => resolve(null), { once: true });
  });
}

const json = url => fetch(url).then(r => r.json()).catch(() => null);
const assets = Promise.all([lottieReady(), json('/assets/bonsai.json'), json('/assets/check.json')]);

// Trees: grow once, then sway on a loop. Intro and loop are marked in the file.
const INTRO = [0, 100];
const IDLE = [100, 460];

function plantTree(container, lottie, data, { whenVisible = false } = {}) {
  if (!lottie || !data || !container) return;
  const tree = lottie.loadAnimation({
    container, renderer: 'svg', loop: false, autoplay: false,
    animationData: structuredClone(data),
    rendererSettings: { preserveAspectRatio: 'xMidYMid meet', progressiveLoad: false },
  });
  let grown = false;
  tree.addEventListener('complete', () => {
    if (!grown) { grown = true; tree.loop = true; tree.playSegments(IDLE, true); }
  });
  const grow = () => {
    if (reducedMotion.matches) { tree.goToAndStop(INTRO[1], true); return; }
    tree.playSegments(INTRO, true);
  };
  tree.addEventListener('DOMLoaded', () => {
    if (!whenVisible) { grow(); return; }
    tree.goToAndStop(0, true);
    const watcher = new IntersectionObserver(entries => {
      if (entries[0].isIntersecting) { watcher.disconnect(); grow(); }
    }, { threshold: 0.4 });
    watcher.observe(container);
  });
  // Off screen the loop rests.
  new IntersectionObserver(entries => {
    if (!grown) return;
    entries[0].isIntersecting ? tree.play() : tree.pause();
  }).observe(container);
}

assets.then(([lottie, tree, check]) => {
  plantTree(document.getElementById('hero-tree'), lottie, tree);
  plantTree(document.getElementById('final-tree'), lottie, tree, { whenVisible: true });
  mountDemo(document.getElementById('demo'), { lottie, checkData: check });
});

// Header turns into a capsule once the page moves.
function setupHeader() {
  const update = () => root.classList.toggle('is-scrolled', window.scrollY > 24);
  update();
  window.addEventListener('scroll', update, { passive: true });
}

// Day and night: a stored choice wins over the system setting.
function setupTheme() {
  const button = document.getElementById('theme-toggle');
  if (!button) return;
  const label = () => button.setAttribute('aria-label', root.dataset.theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode');
  let timer;
  // Safari 26 reads the toolbar tint from the top edge once; a short band makes it look again.
  const retint = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      const band = document.createElement('div');
      band.className = 'retint';
      document.body.append(band);
      setTimeout(() => band.remove(), 50);
    }, 400);
  };
  label();
  button.addEventListener('click', () => {
    const next = root.dataset.theme === 'dark' ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem('bonsai-theme', next); } catch {}
    label();
    retint();
  });
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { label(); retint(); });
}

// Scroll-linked pieces share one frame loop.
const scrollers = [];
function onScroll(fn) { scrollers.push(fn); }
function runScrollers() {
  let queued = false;
  const tick = () => { queued = false; const h = window.innerHeight; scrollers.forEach(fn => fn(h)); };
  const queue = () => { if (!queued) { queued = true; requestAnimationFrame(tick); } };
  window.addEventListener('scroll', queue, { passive: true });
  window.addEventListener('resize', queue);
  tick();
}

// The window leans back under the hero and stands up as it comes in.
function setupWindowTilt() {
  const tilt = document.getElementById('window-tilt');
  if (!tilt || reducedMotion.matches) return;
  onScroll(h => {
    const top = tilt.getBoundingClientRect().top;
    // Leans far back under the hero and stands up by the time it nears the top.
    const p = clamp((h * 0.85 - top) / (h * 0.7));
    const e = 1 - Math.pow(1 - p, 3);
    tilt.style.transform = `rotateX(${(1 - e) * 34}deg) scale(${0.86 + e * 0.14}) translateY(${(1 - e) * 50}px)`;
  });
}

// The statement lights up word by word while it crosses the screen.
function setupStatement() {
  const lit = document.querySelector('.lit');
  if (!lit) return;
  const words = lit.textContent.trim().split(/\s+/);
  lit.innerHTML = words.map(w => `<span class="w">${w}</span>`).join(' ');
  const spans = [...lit.querySelectorAll('.w')];
  if (reducedMotion.matches) { spans.forEach(s => s.classList.add('is-on')); return; }
  onScroll(h => {
    const r = lit.getBoundingClientRect();
    const p = clamp((h * 0.82 - r.top) / (r.height + h * 0.3));
    const count = Math.round(p * spans.length);
    spans.forEach((s, i) => s.classList.toggle('is-on', i < count));
  });
}

// Small dots that fly off and fade: no blur, a couple of pixels each.
function sparks(host, count, place) {
  if (reducedMotion.matches) return;
  for (let i = 0; i < count; i++) {
    const dot = document.createElement('i');
    dot.className = 'spark';
    const s = place(i);
    dot.style.cssText = `--l:${Math.round(s.x)}px;--t:${Math.round(s.y)}px;--sx:${Math.round(s.dx)}px;--sy:${Math.round(s.dy)}px;--sd:${Math.round(s.ms)}ms;--delay:${Math.round(s.delay || 0)}ms;--size:${Math.round(s.size || 2)}px`;
    host.append(dot);
    setTimeout(() => dot.remove(), s.ms + (s.delay || 0) + 100);
  }
}
const rand = (a, b) => a + Math.random() * (b - a);

// Numbers: the size falls while the page is pinned. One dot is 0.1 MB.
function setupNumbers() {
  const section = document.getElementById('numbers');
  if (!section) return;
  const [size, percent] = section.querySelectorAll('.big');
  const counter = size.querySelector('.js-count');
  const dots = document.getElementById('dots');
  const FULL = 314, KEPT = 59;
  dots.innerHTML = Array.from({ length: FULL }, (_, i) => `<i class="${i >= KEPT ? 'is-gone' : ''}"></i>`).join('');
  // Rows go out from the bottom up, each from right to left.
  function order() {
    const cols = getComputedStyle(dots).gridTemplateColumns.split(' ').length;
    const rows = Math.ceil(FULL / cols);
    const first = Math.floor(KEPT / cols);
    [...dots.children].forEach((dot, i) => {
      const row = Math.floor(i / cols), col = i % cols;
      dot.style.setProperty('--d', Math.round((rows - 1 - row) * 110 + (cols - 1 - col) * 11));
      // Coming back they light up the other way: top down, left to right.
      dot.style.setProperty('--r', Math.max(0, Math.round((row - first) * 110 + col * 11)));
    });
  }
  order();
  window.addEventListener('resize', order);
  let current = 0;
  let value = 31.4;
  let run = 0;

  function count(to) {
    const from = value, start = performance.now(), id = ++run;
    if (reducedMotion.matches) { value = to; counter.textContent = to.toFixed(1); return; }
    const step = now => {
      if (id !== run) return;
      const p = clamp((now - start) / 1300);
      value = from + (to - from) * (1 - Math.pow(1 - p, 4));
      counter.textContent = value.toFixed(1);
      if (p < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  function show(index) {
    if (index === current) return;
    if (index >= 1 && current === 0) count(5.9);
    if (index === 0) count(31.4);
    dots.classList.toggle('is-small', index >= 1);
    dots.classList.toggle('is-green', index === 2);
    size.classList.toggle('is-on', index < 2);
    size.classList.toggle('is-past', index === 2);
    percent.classList.toggle('is-on', index === 2);
    if (index === 2) {
      const stack = percent.parentElement, w = stack.clientWidth, h = stack.clientHeight;
      stack.style.setProperty('--spark', 'var(--green)');
      sparks(stack, 22, i => {
        const a = rand(0, Math.PI * 2), r = rand(40, 120);
        return { x: w / 2 + Math.cos(a) * w * 0.16, y: h / 2 + Math.sin(a) * h * 0.3, dx: Math.cos(a) * r, dy: Math.sin(a) * r, ms: rand(800, 1300), delay: 250 + i * 14, size: rand(2, 3) };
      });
    }
    current = index;
  }

  onScroll(h => {
    const r = section.getBoundingClientRect();
    const p = clamp(-r.top / (r.height - h));
    show(p < 0.28 ? 0 : p < 0.66 ? 1 : 2);
  });
}

// Accent buttons: letters roll over one by one.
function setupButtons() {
  document.querySelectorAll('.pill').forEach(pill => {
    const text = [...pill.childNodes].find(n => n.nodeType === 3 && n.textContent.trim());
    if (text) {
      const label = text.textContent.trim();
      const roll = document.createElement('span');
      roll.className = 'roll';
      roll.setAttribute('aria-label', label);
      roll.innerHTML = [...label].map((c, i) => `<i aria-hidden="true" data-c="${c}" style="--i:${i}">${c}</i>`).join('');
      text.replaceWith(roll);
    }
  });
}

// Small drawings above the three facts.
function setupFacts() {
  const mb = document.querySelector('.art-mb');
  if (!mb) return;
  // 32 dots for 323 MB, 13 stay for 128 MB; the rest go out right to left.
  mb.innerHTML = Array.from({ length: 32 }, (_, i) => `<i class="${i >= 13 ? 'is-gone' : ''}" style="--d:${i >= 13 ? 300 + (31 - i) * 45 : 300}"></i>`).join('');
  // Each row is a core: its dots come on left to right, then the row clears for the next file.
  const cores = document.querySelector('.art-cores');
  cores.innerHTML = Array.from({ length: 4 }, () => `<div>${'<i></i>'.repeat(16)}</div>`).join('');
  const rows = [...cores.children].map(row => [...row.children]);
  const offsets = [0, 9, 4, 13];
  const CYCLE = 20; // 16 steps to fill, 4 to hold, of 200 ms each: four seconds a file
  let step = 0, timer = 0;
  const tick = () => {
    rows.forEach((dots, r) => {
      const at = (step + offsets[r]) % CYCLE;
      dots.forEach((dot, i) => dot.classList.toggle('is-on', at < 17 ? i < at : at < CYCLE - 1));
    });
    step++;
  };
  tick();
  if (!reducedMotion.matches) {
    new IntersectionObserver(entries => {
      clearInterval(timer);
      if (entries[0].isIntersecting) timer = setInterval(tick, 200);
    }).observe(cores);
  }
  document.querySelector('.art-engines').innerHTML = Array.from({ length: 7 }, (_, i) => `<i style="--d:${300 + i * 160}"><b></b><b></b><b></b></i>`).join('');
}

// Before and after.
function setupSlider() {
  const slider = document.getElementById('slider');
  if (!slider) return;
  const handle = slider.querySelector('.slider-handle');
  const left = slider.querySelector('.is-left');
  const right = slider.querySelector('.is-right');
  const set = fraction => {
    const f = clamp(fraction, 0.02, 0.98);
    slider.style.setProperty('--split', `${f * 100}%`);
    handle.setAttribute('aria-valuenow', Math.round(f * 100));
    left.style.opacity = f < 0.22 ? 0 : 1;
    right.style.opacity = f > 0.78 ? 0 : 1;
  };
  const fromEvent = e => {
    const r = slider.getBoundingClientRect();
    set((e.clientX - r.left) / r.width);
  };
  let dragging = false;
  slider.addEventListener('pointerdown', e => { dragging = true; slider.setPointerCapture(e.pointerId); fromEvent(e); });
  slider.addEventListener('pointermove', e => { if (dragging) fromEvent(e); });
  slider.addEventListener('pointerup', () => { dragging = false; });
  slider.addEventListener('pointercancel', () => { dragging = false; });
  handle.addEventListener('keydown', e => {
    const now = parseFloat(getComputedStyle(slider).getPropertyValue('--split')) / 100 || 0.5;
    if (e.key === 'ArrowLeft') { set(now - 0.05); e.preventDefault(); }
    if (e.key === 'ArrowRight') { set(now + 0.05); e.preventDefault(); }
  });

  // Pictures load as the section comes near.
  const loader = new IntersectionObserver(entries => {
    if (!entries[0].isIntersecting) return;
    loader.disconnect();
    slider.querySelector('.slider-page').style.backgroundImage = `url(${slider.dataset.original})`;
    slider.querySelector('.slider-after').style.backgroundImage = `url(${slider.dataset.compressed})`;
  }, { rootMargin: '900px 0px' });
  loader.observe(slider);

  // A short sweep the first time it comes into view hints that it moves.
  const watcher = new IntersectionObserver(entries => {
    if (!entries[0].isIntersecting) return;
    watcher.disconnect();
    slider.classList.add('is-in');
    if (reducedMotion.matches) return;
    const start = performance.now();
    const sweep = now => {
      if (dragging) return;
      const t = clamp((now - start) / 1800);
      set(0.5 + Math.sin(t * Math.PI * 2) * 0.16 * (1 - t));
      if (t < 1) requestAnimationFrame(sweep);
    };
    setTimeout(() => requestAnimationFrame(sweep), 400);
  }, { threshold: 0.6 });
  watcher.observe(slider);
}

function setupPresets() {
  const buttons = [...document.querySelectorAll('.pp')];
  const fill = document.querySelector('.meter-fill');
  const size = document.querySelector('.js-preset-size');
  const pct = document.querySelector('.js-preset-pct');
  const note = document.querySelector('.js-preset-note');
  const ppi = document.querySelector('.js-preset-ppi');
  const total = 31.4;
  buttons.forEach(button => button.addEventListener('click', () => {
    buttons.forEach(b => { b.classList.toggle('is-on', b === button); b.setAttribute('aria-checked', b === button); });
    const value = parseFloat(button.dataset.size);
    fill.style.width = `${(value / total) * 100}%`;
    size.textContent = `${value.toFixed(1)} MB`;
    pct.textContent = `-${Math.round((1 - value / total) * 100)}%`;
    note.textContent = button.dataset.note;
    ppi.textContent = button.dataset.ppi;
  }));
}

function setupCommand() {
  const button = document.getElementById('command');
  if (!button) return;
  const label = button.querySelector('em');
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(button.querySelector('span').textContent);
      button.classList.add('is-copied');
      label.textContent = 'Copied';
      setTimeout(() => { button.classList.remove('is-copied'); label.textContent = 'Copy'; }, 1800);
    } catch {}
  });
}

// Links go straight to the zip of the latest release.
function setupDownload() {
  fetch('https://api.github.com/repos/finkoegor/Bonsai/releases/latest')
    .then(r => r.ok ? r.json() : null)
    .then(release => {
      const zip = release?.assets?.find(a => a.name.endsWith('.zip'));
      if (!zip) return;
      document.querySelectorAll('.js-download').forEach(a => { a.href = zip.browser_download_url; });
      document.querySelectorAll('.js-version').forEach(v => { v.textContent = release.tag_name.replace(/^v/, ''); });
    })
    .catch(() => {});
}

function setupReveal() {
  const nodes = document.querySelectorAll('.reveal');
  if (reducedMotion.matches) { nodes.forEach(n => n.classList.add('is-in')); return; }
  const watcher = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-in');
      watcher.unobserve(entry.target);
    });
  }, { threshold: 0.15, rootMargin: '0px 0px -8% 0px' });
  nodes.forEach(n => watcher.observe(n));
}

setupHeader();
setupTheme();
setupWindowTilt();
setupStatement();
setupNumbers();
setupFacts();
setupButtons();
setupSlider();
setupPresets();
setupCommand();
setupDownload();
setupReveal();
runScrollers();
