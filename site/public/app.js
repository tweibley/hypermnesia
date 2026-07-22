/**
 * Hypermnesia Public Website Application Logic (Formatted Terminal Edition)
 */

document.addEventListener('DOMContentLoaded', () => {
  initNavbar();
  initBrainMRICanvas();
  initPlayground();
  initInteractiveTerminal();
  initSetupTabs();
  initCopyButtons();
  initFAQAccordion();
  initScrollAnimations();
  initKeyboardShortcuts();
});

/* Navbar Scroll Listener */
function initNavbar() {
  const navbar = document.querySelector('.navbar');
  if (!navbar) return;
  window.addEventListener('scroll', () => {
    if (window.scrollY > 20) {
      navbar.classList.add('scrolled');
    } else {
      navbar.classList.remove('scrolled');
    }
  });
}

/* Brain MRI Canvas Renderer */
function initBrainMRICanvas() {
  const canvas = document.getElementById('mri-canvas');
  if (!canvas) return;

  const ctx = canvas.getContext('2d');
  let width, height;
  let isRunning = true;
  let activeFilter = 'all';

  function resize() {
    const rect = canvas.getBoundingClientRect();
    const prevWidth = width;
    const prevHeight = height;
    width = rect.width;
    height = rect.height;
    canvas.width = width * window.devicePixelRatio;
    canvas.height = height * window.devicePixelRatio;
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);
    // Nodes were laid out for the old dimensions; rescale so the graph
    // stays centered instead of bunching against one edge.
    if (prevWidth && prevHeight && (prevWidth !== width || prevHeight !== height)) {
      for (const node of nodes) {
        node.x *= width / prevWidth;
        node.y *= height / prevHeight;
      }
    }
  }

  window.addEventListener('resize', resize);
  resize();

  const NODE_TYPES = [
    { type: 'decision', color: '#c084fc' },
    { type: 'convention', color: '#a06bff' },
    { type: 'intent', color: '#e9ddff' },
    { type: 'fact', color: '#34d399' },
    { type: 'concern', color: '#f59e0b' }
  ];

  const nodes = [];
  const nodeCount = 46;

  for (let i = 0; i < nodeCount; i++) {
    const typeObj = NODE_TYPES[Math.floor(Math.random() * NODE_TYPES.length)];
    const angle = Math.random() * Math.PI * 2;
    const rx = (Math.random() * 0.38 + 0.04) * width;
    const ry = (Math.random() * 0.33 + 0.04) * height;

    nodes.push({
      x: width / 2 + Math.cos(angle) * rx,
      y: height / 2 + Math.sin(angle) * ry,
      vx: (Math.random() - 0.5) * 0.35,
      vy: (Math.random() - 0.5) * 0.35,
      radius: Math.random() * 3 + 2.5,
      type: typeObj.type,
      color: typeObj.color,
      pulse: 0,
      pulseSpeed: 0.02 + Math.random() * 0.03
    });
  }

  let mouse = { x: null, y: null, radius: 110 };
  canvas.addEventListener('mousemove', (e) => {
    const rect = canvas.getBoundingClientRect();
    mouse.x = e.clientX - rect.left;
    mouse.y = e.clientY - rect.top;
  });

  canvas.addEventListener('mouseleave', () => {
    mouse.x = null;
    mouse.y = null;
  });

  const filterChips = document.querySelectorAll('.filter-chip');
  filterChips.forEach(chip => {
    chip.addEventListener('click', () => {
      filterChips.forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      activeFilter = chip.getAttribute('data-filter');
    });
  });

  let liveEventsCount = 142;
  setInterval(() => {
    if (!isRunning || nodes.length === 0) return;
    const filteredNodes = activeFilter === 'all' ? nodes : nodes.filter(n => n.type === activeFilter);
    if (filteredNodes.length === 0) return;
    const randomNode = filteredNodes[Math.floor(Math.random() * filteredNodes.length)];
    randomNode.pulse = 1.0;
    liveEventsCount++;
    const statEvents = document.getElementById('stat-events');
    if (statEvents) statEvents.textContent = liveEventsCount;
  }, 1500);

  function draw() {
    if (!isRunning) return;
    ctx.clearRect(0, 0, width, height);

    const visibleNodes = activeFilter === 'all' ? nodes : nodes.filter(n => n.type === activeFilter);

    // Draw connecting synapses
    for (let i = 0; i < visibleNodes.length; i++) {
      for (let j = i + 1; j < visibleNodes.length; j++) {
        const dx = visibleNodes[i].x - visibleNodes[j].x;
        const dy = visibleNodes[i].y - visibleNodes[j].y;
        const dist = Math.sqrt(dx * dx + dy * dy);

        if (dist < 90) {
          const alpha = (1 - dist / 90) * 0.22;
          ctx.beginPath();
          ctx.moveTo(visibleNodes[i].x, visibleNodes[i].y);
          ctx.lineTo(visibleNodes[j].x, visibleNodes[j].y);
          ctx.strokeStyle = `rgba(168, 140, 250, ${alpha})`;
          ctx.lineWidth = 1;
          ctx.stroke();
        }
      }
    }

    // Update and draw nodes
    visibleNodes.forEach(node => {
      node.x += node.vx;
      node.y += node.vy;

      if (node.x < 20 || node.x > width - 20) node.vx *= -1;
      if (node.y < 20 || node.y > height - 20) node.vy *= -1;

      if (mouse.x !== null) {
        const dx = mouse.x - node.x;
        const dy = mouse.y - node.y;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < mouse.radius) {
          node.x += dx * 0.02;
          node.y += dy * 0.02;
        }
      }

      ctx.beginPath();
      ctx.arc(node.x, node.y, node.radius + (node.pulse * 5), 0, Math.PI * 2);
      ctx.fillStyle = node.color;
      ctx.globalAlpha = 0.85;
      ctx.fill();

      if (node.pulse > 0) {
        ctx.beginPath();
        ctx.arc(node.x, node.y, node.radius + (1 - node.pulse) * 18, 0, Math.PI * 2);
        ctx.strokeStyle = node.color;
        ctx.globalAlpha = node.pulse;
        ctx.lineWidth = 1.5;
        ctx.stroke();
        node.pulse -= node.pulseSpeed;
        if (node.pulse < 0) node.pulse = 0;
      }
    });

    ctx.globalAlpha = 1.0;
    requestAnimationFrame(draw);
  }

  draw();
}

/* Live Playground Widget Logic */
function initPlayground() {
  const promptOptions = document.querySelectorAll('.prompt-option');
  const customInput = document.getElementById('playground-custom-input');
  const outputHydrated = document.getElementById('playground-output-hydrated');
  const outputMemoryless = document.getElementById('playground-output-memoryless');

  const SAMPLE_PRESETS = {
    "auth": {
      hydrated: `<span class="output-tag-hydrated">✓ WITH HYPERMNESIA</span><br>
[HYPERMNESIA HYDRATED CONTEXT - 2 Memories Injected]<br>
• <span style="color: #c084fc;">[decision]</span> Auth tokens use Ed25519 asymmetric signatures (retired HMAC in v0.2.1)<br>
• <span style="color: #a06bff;">[convention]</span> Store local session database in ~/Library/Application Support/Hypermnesia<br><br>
<span style="color: #cbd5e1;">Agent Output:</span> "Adding profile auth endpoint. Using Ed25519 token validation per decision #142, placing session storage in standard ~/Library path..."`,
      memoryless: `<span class="output-tag-memoryless">✕ MEMORYLESS AGENT</span><br>
[NO CONTEXT INJECTED]<br><br>
<span style="color: #cbd5e1;">Agent Output:</span> "I'll create a standard JWT auth endpoint with HMAC-SHA256 and store state in /tmp/app.db..." <span style="color: #f43f5e;">❌ (Violates project convention & retired HMAC decision)</span>`
    },
    "db": {
      hydrated: `<span class="output-tag-hydrated">✓ WITH HYPERMNESIA</span><br>
[HYPERMNESIA HYDRATED CONTEXT - 2 Memories Injected]<br>
• <span style="color: #c084fc;">[decision]</span> Database engine is GRDB + SQLite with FTS5 full-text indexing enabled<br>
• <span style="color: #e9ddff;">[intent]</span> Keep memory hydration bounded under 8 items per prompt<br><br>
<span style="color: #cbd5e1;">Agent Output:</span> "Configuring database queries using GRDB FTS5 full-text search syntax..."`,
      memoryless: `<span class="output-tag-memoryless">✕ MEMORYLESS AGENT</span><br>
[NO CONTEXT INJECTED]<br><br>
<span style="color: #cbd5e1;">Agent Output:</span> "I'll install PostgreSQL / Prisma ORM for local state persistence..." <span style="color: #f43f5e;">❌ (Adds unwanted heavyweight dependency)</span>`
    },
    "decay": {
      hydrated: `<span class="output-tag-hydrated">✓ WITH HYPERMNESIA</span><br>
[HYPERMNESIA HYDRATED CONTEXT - 1 Memory Injected]<br>
• <span style="color: #a06bff;">[convention]</span> Memories age through Fresh → Aging → Stale → Dormant unless revalidated by use<br><br>
<span style="color: #cbd5e1;">Agent Output:</span> "Updating decay engine logic using standard 4-stage health thresholding..."`,
      memoryless: `<span class="output-tag-memoryless">✕ MEMORYLESS AGENT</span><br>
[NO CONTEXT INJECTED]<br><br>
<span style="color: #cbd5e1;">Agent Output:</span> "I'll implement a simple 24-hour TTL hard deletion script..." <span style="color: #f43f5e;">❌ (Silently deletes valuable context)</span>`
    }
  };

  function updatePlayground(presetKey) {
    const data = SAMPLE_PRESETS[presetKey] || SAMPLE_PRESETS["auth"];
    if (outputHydrated) outputHydrated.innerHTML = data.hydrated;
    if (outputMemoryless) outputMemoryless.innerHTML = data.memoryless;
  }

  promptOptions.forEach(opt => {
    opt.addEventListener('click', () => {
      promptOptions.forEach(o => o.classList.remove('active'));
      opt.classList.add('active');
      const key = opt.getAttribute('data-preset');
      updatePlayground(key);
    });
  });

  if (customInput) {
    customInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        const val = customInput.value.trim();
        if (!val) return;
        if (outputHydrated) {
          outputHydrated.innerHTML = `<span class="output-tag-hydrated">✓ WITH HYPERMNESIA</span><br>[HYPERMNESIA HYDRATED CONTEXT - 1 Relevant Memory Injected]<br>• <span style="color: #a06bff;">[convention]</span> Query matches project memory index for "${val}".<br><br><span style="color: #cbd5e1;">Agent Output:</span> "Applying captured codebase conventions for ${val}..."`;
        }
        if (outputMemoryless) {
          outputMemoryless.innerHTML = `<span class="output-tag-memoryless">✕ MEMORYLESS AGENT</span><br>[NO CONTEXT INJECTED]<br><br><span style="color: #cbd5e1;">Agent Output:</span> "Guessing default implementation pattern without past session context..."`;
        }
      }
    });
  }
}

/* Interactive macOS Terminal Simulator (Formatted Line-by-Line Edition) */
function initInteractiveTerminal() {
  const body = document.getElementById('terminal-interactive-body');
  const chips = document.querySelectorAll('.cmd-chip');

  const COMMAND_RESPONSES = {
    "doctor": `<div class="terminal-prompt-line"><span style="color: var(--violet-glow); font-weight: 600;">$ hypermnesia doctor</span></div>
<div class="terminal-divider">────────────────────────────────────────────────────────</div>
<div class="terminal-out-line"><span class="term-key">Toolchain:</span>       <span class="term-val">Swift 6.2 (Xcode 26)</span> <span class="term-ok">[OK]</span></div>
<div class="terminal-out-line"><span class="term-key">Store:</span>           <span class="term-val">SQLite 3.45.0 + FTS5</span></div>
<div class="terminal-out-line">                 <span class="term-dim">[~/Library/Application Support/Hypermnesia/memory.db]</span></div>
<div class="terminal-out-line"><span class="term-key">Classifier:</span>      <span class="term-val">Gemini 3.5 Flash</span> <span class="term-ok">[OK]</span> <span class="term-dim">(Latency: 140ms)</span></div>
<div class="terminal-out-line"><span class="term-key">Claude Hooks:</span>    <span class="term-val">Registered in ~/.claude/config.json</span> <span class="term-ok">[OK]</span></div>
<div class="terminal-out-line"><span class="term-key">Cursor Hooks:</span>    <span class="term-val">Registered in ~/.cursor/hooks.json</span> <span class="term-ok">[OK]</span></div>
<div class="terminal-out-line"><span class="term-key">Antigravity:</span>     <span class="term-val">Registered in ~/.gemini/config/hooks.json</span> <span class="term-ok">[OK]</span></div>
<div class="terminal-out-line"><span class="term-key">Confirmed:</span>       <span class="term-val">148 active memories across 4 projects</span></div>
<div class="terminal-out-line" style="margin-top: 8px;"><span class="term-key">Status:</span>          <span style="color: #34d399; font-weight: 600;">Everything operating cleanly ✓</span></div>`,

    "ask": `<div class="terminal-prompt-line"><span style="color: var(--violet-glow); font-weight: 600;">$ hypermnesia ask "Why did we pick SQLite?"</span></div>
<div class="terminal-divider">────────────────────────────────────────────────────────</div>
<div class="terminal-out-line"><span class="term-dim">Querying project memory engine...</span></div>
<div class="terminal-out-line" style="margin-top: 10px;"><span class="term-key" style="color: #f8fafc; font-weight: 600;">Answer:</span> <span class="term-val">SQLite was chosen for zero-dependency local storage, instant startup, embedded FTS5 full-text indexing, and zero network telemetry.</span></div>
<div class="terminal-out-line" style="margin-top: 8px;"><span class="term-dim">Provenance: Captured from session #84 (2026-06-12) • Confirmed decision #14</span></div>`,

    "recall": `<div class="terminal-prompt-line"><span style="color: var(--violet-glow); font-weight: 600;">$ hypermnesia recall "auth token storage"</span></div>
<div class="terminal-divider">────────────────────────────────────────────────────────</div>
<div class="terminal-out-line"><span class="term-val" style="font-weight: 600;">Ranked Relevance Matches:</span></div>
<div class="terminal-out-line">1. <span style="color: #c084fc;">[decision]</span> Auth tokens use Ed25519 asymmetric signatures <span class="term-ok">(Confidence: 0.98, Fresh)</span></div>
<div class="terminal-out-line">2. <span style="color: #a06bff;">[convention]</span> Store local session database in ~/Library/Application Support <span class="term-ok">(Confidence: 0.94, Fresh)</span></div>
<div class="terminal-out-line">3. <span style="color: #34d399;">[fact]</span> JWT bearer token header format: Authorization: Bearer &lt;token&gt; <span style="color: #f59e0b;">(Confidence: 0.89, Aging)</span></div>`,

    "backfill": `<div class="terminal-prompt-line"><span style="color: var(--violet-glow); font-weight: 600;">$ hypermnesia backfill --project ~/repo --dry-run</span></div>
<div class="terminal-divider">────────────────────────────────────────────────────────</div>
<div class="terminal-out-line"><span class="term-dim">Scanning past session transcripts...</span></div>
<div class="terminal-out-line">Found 18 past Claude Code & Antigravity transcripts.</div>
<div class="terminal-out-line" style="margin-top: 8px;"><span style="color: #c084fc; font-weight: 600;">[Dry Run]</span> Would classify:</div>
<div class="terminal-out-line">  • 12 Decisions</div>
<div class="terminal-out-line">  • 8 Conventions</div>
<div class="terminal-out-line">  • 5 Intents</div>
<div class="terminal-out-line">  • 2 Concerns (Flagged as drafts)</div>
<div class="terminal-out-line" style="margin-top: 10px;">Run '<span style="color: #f8fafc; font-weight: 600;">hypermnesia backfill --project ~/repo</span>' to persist.</div>`
  };

  function runCommand(cmdKey) {
    if (!body) return;
    const resp = COMMAND_RESPONSES[cmdKey] || COMMAND_RESPONSES["doctor"];
    body.innerHTML = resp;

    chips.forEach(chip => {
      if (chip.getAttribute('data-cmd') === cmdKey) {
        chip.classList.add('active');
      } else {
        chip.classList.remove('active');
      }
    });
  }

  chips.forEach(chip => {
    chip.addEventListener('click', () => {
      const cmdKey = chip.getAttribute('data-cmd');
      runCommand(cmdKey);
    });
  });

  runCommand('doctor');
}

/* Client Setup Tabs UI */
function initSetupTabs() {
  const tabBtns = document.querySelectorAll('.tab-btn');
  const tabContents = document.querySelectorAll('.tab-content');

  tabBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      const tabId = btn.getAttribute('data-tab');

      tabBtns.forEach(b => b.classList.remove('active'));
      tabContents.forEach(c => c.classList.remove('active'));

      btn.classList.add('active');
      const targetContent = document.getElementById(tabId);
      if (targetContent) {
        targetContent.classList.add('active');
      }
    });
  });
}

/* Copy Buttons */
function initCopyButtons() {
  const copyBtns = document.querySelectorAll('.copy-btn');

  copyBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      const targetId = btn.getAttribute('data-copy-target');
      const targetElem = document.getElementById(targetId);
      if (!targetElem) return;

      const textToCopy = Array.from(targetElem.querySelectorAll('.terminal-cmd-text'))
        .map(el => el.textContent.trim())
        .join('\n');

      navigator.clipboard.writeText(textToCopy).then(() => {
        const originalText = btn.innerHTML;
        btn.classList.add('copied');
        btn.innerHTML = `Copied!`;
        setTimeout(() => {
          btn.classList.remove('copied');
          btn.innerHTML = originalText;
        }, 2000);
      });
    });
  });
}

/* FAQ Accordion */
function initFAQAccordion() {
  const faqItems = document.querySelectorAll('.faq-item');
  faqItems.forEach(item => {
    const questionBtn = item.querySelector('.faq-question');
    if (!questionBtn) return;
    questionBtn.addEventListener('click', () => {
      const isActive = item.classList.contains('active');
      faqItems.forEach(i => i.classList.remove('active'));
      if (!isActive) {
        item.classList.add('active');
      }
    });
  });
}

/* Scroll Animations */
function initScrollAnimations() {
  const observerOptions = { threshold: 0.2 };
  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting && entry.target.classList.contains('eval-metrics')) {
        const fills = document.querySelectorAll('.bar-fill');
        fills.forEach(fill => {
          const targetWidth = fill.getAttribute('data-width');
          if (targetWidth) fill.style.width = targetWidth;
        });
      }
    });
  }, observerOptions);

  const evalMetrics = document.querySelector('.eval-metrics');
  if (evalMetrics) observer.observe(evalMetrics);
}

/* Keyboard Shortcuts */
function initKeyboardShortcuts() {
  document.addEventListener('keydown', (e) => {
    if (e.key === '/' && document.activeElement.tagName !== 'INPUT' && document.activeElement.tagName !== 'TEXTAREA') {
      e.preventDefault();
      const terminalSec = document.getElementById('cli');
      if (terminalSec) terminalSec.scrollIntoView({ behavior: 'smooth' });
    }
  });
}
