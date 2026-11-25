// A liquid chrome bezel around a pill button: banded reflections that flow
// along the edge, speed up on hover and bend toward the pointer.

const BEZEL = 4;

const vertex = `
attribute vec2 a;
void main() { gl_Position = vec4(a, 0.0, 1.0); }`;

const fragment = `
precision highp float;
uniform vec2 u_size;
uniform float u_ratio;
uniform float u_bezel;
uniform float u_time;
uniform float u_hover;
uniform vec2 u_pointer;
uniform float u_light;

float band(float x) {
  float s = 0.5 + 0.5 * sin(x * 6.2831853);
  s = smoothstep(0.08, 0.92, s);
  return mix(0.05, 1.0, s * s);
}

void main() {
  vec2 p = gl_FragCoord.xy / u_ratio - u_size * 0.5;
  p.y = -p.y;
  float r = u_size.y * 0.5;
  vec2 q = vec2(clamp(p.x, -(u_size.x * 0.5 - r), u_size.x * 0.5 - r), 0.0);
  vec2 n = normalize(p - q + 1e-5);
  float d = length(p - q) - r;

  // Inside the bezel: 0 on the outer edge, 1 where it meets the button.
  float depth = clamp(-d / u_bezel, 0.0, 1.0);
  float alpha = smoothstep(0.0, 1.0, -d * u_ratio) * smoothstep(0.0, 1.0, (d + u_bezel) * u_ratio);

  // Where on the outline the point sits, so the bands travel along it.
  float along = q.x / u_size.x + atan(n.y, n.x) * 0.12;
  float t = n.x * 0.55 - n.y * 0.9 + along * 1.6;
  t += (depth - 0.5) * 0.9;
  t += 0.12 * sin(along * 9.0 + u_time * 0.9) + 0.07 * sin(along * 23.0 - u_time * 1.7);
  t += u_time * 0.11;
  float reach = exp(-length(p - u_pointer) / 46.0);
  t += u_hover * reach * 0.85;

  float split = 0.035 + 0.03 * u_hover;
  vec3 metal = vec3(band(t + split), band(t), band(t - split));
  metal = mix(metal, metal * vec3(0.80, 0.70, 1.0), 0.4);
  // A light page wants a darker ring to read against it.
  metal = mix(metal, metal * 0.82 + 0.02, u_light);

  gl_FragColor = vec4(metal * alpha, alpha);
}`;

function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  return gl.getShaderParameter(shader, gl.COMPILE_STATUS) ? shader : null;
}

export function mountMetal(button, { reducedMotion = false } = {}) {
  const canvas = document.createElement('canvas');
  canvas.className = 'metal';
  canvas.setAttribute('aria-hidden', 'true');
  const gl = canvas.getContext('webgl', { premultipliedAlpha: true, antialias: false });
  if (!gl) return;
  const vs = compile(gl, gl.VERTEX_SHADER, vertex);
  const fs = compile(gl, gl.FRAGMENT_SHADER, fragment);
  if (!vs || !fs) return;
  const program = gl.createProgram();
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return;
  gl.useProgram(program);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  const position = gl.getAttribLocation(program, 'a');
  gl.enableVertexAttribArray(position);
  gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
  const u = name => gl.getUniformLocation(program, name);
  const uniforms = { size: u('u_size'), ratio: u('u_ratio'), bezel: u('u_bezel'), time: u('u_time'), hover: u('u_hover'), pointer: u('u_pointer'), light: u('u_light') };

  button.prepend(canvas);
  button.classList.add('has-metal');

  let width = 0, height = 0, ratio = 1;
  function resize() {
    width = button.offsetWidth + BEZEL * 2;
    height = button.offsetHeight + BEZEL * 2;
    ratio = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    gl.viewport(0, 0, canvas.width, canvas.height);
  }
  new ResizeObserver(() => { resize(); draw(); }).observe(button);

  let time = Math.random() * 20, hover = 0, target = 0, pointer = [0, 0];
  let visible = false, frame = 0, last = 0;

  function draw() {
    if (!width) return;
    gl.uniform2f(uniforms.size, width, height);
    gl.uniform1f(uniforms.ratio, ratio);
    gl.uniform1f(uniforms.bezel, BEZEL);
    gl.uniform1f(uniforms.time, time);
    gl.uniform1f(uniforms.hover, hover);
    gl.uniform2f(uniforms.pointer, pointer[0], pointer[1]);
    gl.uniform1f(uniforms.light, document.documentElement.dataset.theme === 'dark' ? 0 : 1);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  function tick(now) {
    const dt = Math.min(0.05, (now - last) / 1000 || 0);
    last = now;
    hover += (target - hover) * Math.min(1, dt * 7);
    time += dt * (0.35 + hover * 1.4);
    draw();
    frame = visible ? requestAnimationFrame(tick) : 0;
  }

  button.addEventListener('pointerenter', () => { target = 1; });
  button.addEventListener('pointerleave', () => { target = 0; });
  button.addEventListener('pointermove', e => {
    const r = button.getBoundingClientRect();
    pointer = [e.clientX - r.left - r.width / 2, e.clientY - r.top - r.height / 2];
  });

  resize();
  draw();
  if (reducedMotion) return;
  new IntersectionObserver(entries => {
    visible = entries[0].isIntersecting;
    if (visible && !frame) { last = performance.now(); frame = requestAnimationFrame(tick); }
  }).observe(button);
}
