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
    const p = clamp((h - top) / (h * 0.75));
    const e = 1 - Math.pow(1 - p, 3);
    tilt.style.transform = `rotateX(${(1 - e) * 18}deg) scale(${0.92 + e * 0.08}) translateY(${(1 - e) * 30}px)`;
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

// Numbers: three beats on a pinned stage.
function setupNumbers() {
  const section = document.getElementById('numbers');
  if (!section) return;
  const beats = [...section.querySelectorAll('.big')];
  const counter = beats[1].querySelector('.js-count');
  let current = 0;
  let counting = 0;

  function count() {
    const from = 31.4, to = 5.9, start = performance.now(), run = ++counting;
    const step = now => {
      if (run !== counting) return;
      const p = clamp((now - start) / 1300);
      const e = 1 - Math.pow(1 - p, 4);
      counter.textContent = (from + (to - from) * e).toFixed(1);
      if (p < 1) requestAnimationFrame(step);
    };
    if (reducedMotion.matches) { counter.textContent = to.toFixed(1); return; }
    requestAnimationFrame(step);
  }

  function show(index) {
    if (index === current) return;
    beats.forEach((b, i) => {
      b.classList.toggle('is-on', i === index);
      b.classList.toggle('is-past', i < index);
    });
    if (index === 1 && current < 1) count();
    if (index < 1) { counting++; counter.textContent = '31.4'; }
    section.style.setProperty('--glow-on', index === 2 ? '1' : '.4');
    current = index;
  }

  onScroll(h => {
    const r = section.getBoundingClientRect();
    const p = clamp(-r.top / (r.height - h));
    show(p < 0.3 ? 0 : p < 0.66 ? 1 : 2);
  });
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
setupWindowTilt();
setupStatement();
setupNumbers();
setupSlider();
setupPresets();
setupCommand();
setupDownload();
setupReveal();
runScrollers();

// Wheel scrolling glides on desktop; touch keeps the native feel.
window.addEventListener('load', () => {
  if (!window.Lenis || reducedMotion.matches || window.matchMedia('(pointer: coarse)').matches) return;
  const lenis = new window.Lenis({ lerp: 0.1, smoothWheel: true });
  const raf = time => { lenis.raf(time); requestAnimationFrame(raf); };
  requestAnimationFrame(raf);
  document.querySelectorAll('a[href^="#"]').forEach(a => a.addEventListener('click', e => {
    const target = document.querySelector(a.getAttribute('href'));
    if (!target) return;
    e.preventDefault();
    lenis.scrollTo(target, { offset: -40, duration: 1.2 });
  }));
});
