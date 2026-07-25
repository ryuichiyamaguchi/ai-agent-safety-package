from __future__ import annotations


DASHBOARD_HTML = r"""<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="color-scheme" content="light">
  <meta name="theme-color" content="#edf3f1">
  <title>Bouncer — ローカル保護ステータス</title>
  <style>
    :root {
      --mist: #edf3f1;
      --paper: #fbfdfc;
      --ink: #17332e;
      --muted: #60736e;
      --line: #cddbd7;
      --moss: #2f7464;
      --moss-soft: #d7e8e2;
      --sky: #c9e2e7;
      --amber: #c78c2d;
      --amber-soft: #f4e7c9;
      --coral: #b9574d;
      --coral-soft: #f4deda;
      --shadow: 0 18px 55px rgba(23, 51, 46, .09);
      --display: "Avenir Next Condensed", "Hiragino Kaku Gothic ProN", "Yu Gothic", sans-serif;
      --body: "Avenir Next", "Hiragino Sans", "Yu Gothic", sans-serif;
      --utility: "SFMono-Regular", "Roboto Mono", "Hiragino Kaku Gothic ProN", monospace;
    }

    * { box-sizing: border-box; }

    html { background: var(--mist); }

    body {
      margin: 0;
      min-width: 320px;
      color: var(--ink);
      background:
        linear-gradient(90deg, transparent 0 49.8%, rgba(47, 116, 100, .045) 49.8% 50.2%, transparent 50.2%),
        var(--mist);
      font-family: var(--body);
      -webkit-font-smoothing: antialiased;
    }

    button { font: inherit; }

    .shell {
      width: min(1180px, calc(100% - 40px));
      margin: 0 auto;
      padding: 34px 0 48px;
    }

    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 24px;
      margin-bottom: 26px;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
    }

    .brand-mark {
      display: grid;
      width: 42px;
      height: 42px;
      place-items: center;
      border: 1px solid var(--ink);
      border-radius: 50%;
      background: var(--paper);
      font-family: var(--display);
      font-size: 23px;
      font-weight: 700;
      letter-spacing: -.04em;
      box-shadow: 4px 4px 0 var(--sky);
    }

    .brand-copy strong {
      display: block;
      font-family: var(--display);
      font-size: 19px;
      letter-spacing: .02em;
    }

    .eyebrow {
      margin: 0 0 3px;
      color: var(--muted);
      font-family: var(--utility);
      font-size: 10px;
      font-weight: 700;
      letter-spacing: .13em;
      text-transform: uppercase;
    }

    .connection-pill {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      min-height: 38px;
      padding: 8px 13px;
      border: 1px solid var(--line);
      border-radius: 999px;
      background: rgba(251, 253, 252, .8);
      color: var(--ink);
      font-size: 13px;
      font-weight: 700;
    }

    .status-dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: var(--moss);
      box-shadow: 0 0 0 4px var(--moss-soft);
    }

    body[data-connection="lost"] .status-dot {
      background: var(--coral);
      box-shadow: 0 0 0 4px var(--coral-soft);
    }

    .hero {
      position: relative;
      display: grid;
      grid-template-columns: minmax(0, 1.04fr) minmax(420px, .96fr);
      min-height: 388px;
      overflow: hidden;
      border: 1px solid var(--line);
      border-radius: 28px;
      background: var(--paper);
      box-shadow: var(--shadow);
    }

    .hero-copy {
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      padding: clamp(30px, 5vw, 58px);
    }

    .hero h1 {
      max-width: 620px;
      margin: 8px 0 18px;
      font-family: var(--display);
      font-size: clamp(42px, 5vw, 62px);
      font-weight: 600;
      line-height: .98;
      letter-spacing: -.045em;
    }

    .hero h1 span { color: var(--moss); }

    .hero-lead {
      max-width: 560px;
      margin: 0;
      color: var(--muted);
      font-size: 16px;
      line-height: 1.85;
    }

    .hero-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 9px;
      margin-top: 34px;
    }

    .meta-chip {
      padding: 7px 10px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--mist);
      color: var(--muted);
      font-family: var(--utility);
      font-size: 11px;
    }

    .gate-panel {
      position: relative;
      display: flex;
      flex-direction: column;
      justify-content: center;
      min-width: 0;
      padding: 44px clamp(26px, 4vw, 46px);
      border-left: 1px solid var(--line);
      background: var(--sky);
    }

    .gate-panel::after {
      position: absolute;
      right: -74px;
      bottom: -118px;
      width: 260px;
      height: 260px;
      border: 46px solid rgba(251, 253, 252, .38);
      border-radius: 50%;
      content: "";
    }

    .now-label {
      position: relative;
      z-index: 1;
      margin: 0 0 8px;
      color: var(--muted);
      font-family: var(--utility);
      font-size: 11px;
      font-weight: 700;
      letter-spacing: .1em;
    }

    .now-state {
      position: relative;
      z-index: 1;
      margin: 0;
      font-family: var(--display);
      font-size: clamp(32px, 4vw, 50px);
      font-weight: 650;
      letter-spacing: -.035em;
    }

    .now-detail {
      position: relative;
      z-index: 1;
      min-height: 50px;
      margin: 12px 0 34px;
      color: #3f5e57;
      font-size: 14px;
      line-height: 1.7;
    }

    .safety-rail {
      position: relative;
      z-index: 1;
      display: grid;
      grid-template-columns: repeat(5, 1fr);
      align-items: start;
      padding-top: 6px;
    }

    .rail-line {
      position: absolute;
      top: 13px;
      left: 9%;
      right: 9%;
      height: 2px;
      background: rgba(23, 51, 46, .28);
    }

    .rail-sentinel {
      position: absolute;
      top: 8px;
      left: 8%;
      width: 12px;
      height: 12px;
      border: 3px solid var(--paper);
      border-radius: 50%;
      background: var(--moss);
      box-shadow: 0 0 0 2px var(--moss);
      transform: translateX(-50%);
    }

    body[data-active="true"] .rail-sentinel {
      animation: patrol 2.7s cubic-bezier(.45, 0, .55, 1) infinite alternate;
    }

    .rail-stop {
      position: relative;
      display: grid;
      justify-items: center;
      gap: 11px;
      color: #3f5e57;
      font-size: 10px;
      line-height: 1.25;
      text-align: center;
    }

    .rail-stop::before {
      width: 14px;
      height: 14px;
      border: 2px solid rgba(23, 51, 46, .5);
      border-radius: 50%;
      background: var(--sky);
      content: "";
    }

    .rail-stop.guard::before {
      border-color: var(--moss);
      background: var(--paper);
      box-shadow: 0 0 0 4px rgba(47, 116, 100, .14);
    }

    .ai-note {
      position: relative;
      z-index: 1;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-top: 31px;
      padding-top: 16px;
      border-top: 1px solid rgba(23, 51, 46, .18);
      font-size: 12px;
    }

    .ai-note strong { font-size: 13px; }

    .ai-badge {
      flex: 0 0 auto;
      padding: 5px 9px;
      border-radius: 999px;
      background: var(--paper);
      color: var(--moss);
      font-size: 11px;
      font-weight: 800;
    }

    body[data-ai="offline"] .ai-badge {
      background: var(--amber-soft);
      color: #795213;
    }

    .stats {
      display: grid;
      grid-template-columns: 1.35fr repeat(4, 1fr);
      margin: 22px 0;
      overflow: hidden;
      border: 1px solid var(--line);
      border-radius: 18px;
      background: var(--paper);
    }

    .stat {
      min-height: 102px;
      padding: 20px 22px;
      border-left: 1px solid var(--line);
    }

    .stat:first-child { border-left: 0; }

    .stat-label {
      display: block;
      margin-bottom: 6px;
      color: var(--muted);
      font-size: 11px;
      font-weight: 700;
    }

    .stat-value {
      font-family: var(--display);
      font-size: 33px;
      font-weight: 650;
      letter-spacing: -.03em;
    }

    .stat-note {
      display: block;
      margin-top: 1px;
      color: var(--muted);
      font-size: 10px;
    }

    .content-grid {
      display: grid;
      grid-template-columns: minmax(0, 1.45fr) minmax(300px, .55fr);
      gap: 22px;
    }

    .panel {
      border: 1px solid var(--line);
      border-radius: 20px;
      background: var(--paper);
    }

    .panel-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 23px 24px 18px;
      border-bottom: 1px solid var(--line);
    }

    .panel-header h2,
    .side-panel h2 {
      margin: 0;
      font-family: var(--display);
      font-size: 24px;
      letter-spacing: -.02em;
    }

    .refresh-button {
      min-height: 34px;
      padding: 7px 11px;
      border: 1px solid var(--line);
      border-radius: 9px;
      background: var(--mist);
      color: var(--ink);
      cursor: pointer;
      font-size: 11px;
      font-weight: 750;
    }

    .refresh-button:hover { border-color: var(--moss); }
    .refresh-button:focus-visible { outline: 3px solid rgba(47, 116, 100, .28); outline-offset: 2px; }

    .event-list { min-height: 260px; }

    .empty-state {
      display: grid;
      min-height: 260px;
      place-items: center;
      padding: 40px;
      color: var(--muted);
      text-align: center;
    }

    .empty-state strong {
      display: block;
      margin-bottom: 6px;
      color: var(--ink);
      font-size: 15px;
    }

    .event-row {
      display: grid;
      grid-template-columns: 68px 104px minmax(0, 1fr) auto;
      align-items: center;
      gap: 14px;
      min-height: 74px;
      padding: 14px 24px;
      border-bottom: 1px solid var(--line);
    }

    .event-row:last-child { border-bottom: 0; }

    .event-time {
      color: var(--muted);
      font-family: var(--utility);
      font-size: 11px;
    }

    .decision {
      display: inline-flex;
      justify-content: center;
      width: fit-content;
      min-width: 84px;
      padding: 5px 8px;
      border-radius: 999px;
      background: var(--moss-soft);
      color: var(--moss);
      font-size: 10px;
      font-weight: 800;
    }

    .decision.allow_masked { background: #dbe8ef; color: #35627a; }
    .decision.review { background: var(--amber-soft); color: #795213; }
    .decision.block,
    .decision.error { background: var(--coral-soft); color: #7e3933; }

    .event-main { min-width: 0; }
    .event-main strong { display: block; overflow: hidden; font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
    .event-main span { color: var(--muted); font-size: 11px; }
    .event-duration { color: var(--muted); font-family: var(--utility); font-size: 10px; }

    .side-stack { display: grid; gap: 22px; align-content: start; }
    .side-panel { padding: 24px; }
    .side-panel h2 { margin-bottom: 18px; }

    .mode-line {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      padding: 13px 0;
      border-bottom: 1px solid var(--line);
      font-size: 12px;
    }

    .mode-line:last-child { border-bottom: 0; }
    .mode-line span { color: var(--muted); }
    .mode-line strong { text-align: right; }

    .privacy-card { background: var(--ink); color: var(--paper); }
    .privacy-card h2 { color: var(--paper); }

    .privacy-list { display: grid; gap: 13px; margin: 0; padding: 0; list-style: none; }
    .privacy-list li { display: grid; grid-template-columns: 22px 1fr; gap: 10px; color: #d7e8e2; font-size: 12px; line-height: 1.55; }
    .privacy-list li::before { color: #8ac1b4; content: "✓"; font-weight: 900; }

    .footer {
      display: flex;
      justify-content: space-between;
      gap: 20px;
      padding: 19px 4px 0;
      color: var(--muted);
      font-size: 10px;
    }

    .footer code { font-family: var(--utility); }

    .reveal { animation: arrive .55s both; }
    .stats.reveal { animation-delay: .08s; }
    .content-grid.reveal { animation-delay: .14s; }

    @keyframes arrive {
      from { opacity: 0; transform: translateY(10px); }
      to { opacity: 1; transform: translateY(0); }
    }

    @keyframes patrol {
      from { left: 8%; }
      to { left: 92%; }
    }

    @media (max-width: 900px) {
      .hero { grid-template-columns: 1fr; }
      .gate-panel { min-height: 330px; border-top: 1px solid var(--line); border-left: 0; }
      .stats { grid-template-columns: repeat(2, 1fr); }
      .stat { border-bottom: 1px solid var(--line); }
      .stat:nth-child(odd) { border-left: 0; }
      .stat:last-child { grid-column: 1 / -1; border-bottom: 0; }
      .content-grid { grid-template-columns: 1fr; }
    }

    @media (max-width: 620px) {
      .shell { width: min(100% - 24px, 1180px); padding-top: 20px; }
      .brand-copy .eyebrow { display: none; }
      .connection-pill { padding-inline: 10px; font-size: 11px; }
      .hero { border-radius: 20px; }
      .hero-copy { padding: 30px 24px 34px; }
      .hero h1 { font-size: 46px; }
      .gate-panel { min-width: 0; padding: 34px 22px; }
      .rail-stop { font-size: 9px; }
      .stats { border-radius: 16px; }
      .stat { min-height: 94px; padding: 17px; }
      .event-row { grid-template-columns: 60px 1fr auto; gap: 10px; padding: 15px 17px; }
      .event-row .decision { grid-column: 2; grid-row: 2; }
      .event-main { grid-column: 2 / -1; }
      .event-duration { grid-column: 3; grid-row: 2; }
      .panel-header, .side-panel { padding-inline: 18px; }
      .footer { flex-direction: column; }
    }

    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after { scroll-behavior: auto !important; animation-duration: .01ms !important; animation-iteration-count: 1 !important; }
    }
  </style>
</head>
<body data-active="false" data-ai="unknown" data-connection="ok">
  <main class="shell">
    <header class="topbar">
      <div class="brand" aria-label="Bouncer">
        <div class="brand-mark" aria-hidden="true">B</div>
        <div class="brand-copy">
          <p class="eyebrow">Local safety gateway</p>
          <strong>Bouncer</strong>
        </div>
      </div>
      <div class="connection-pill" aria-live="polite">
        <span class="status-dot" aria-hidden="true"></span>
        <span id="connection-label">接続を確認中</span>
      </div>
    </header>

    <section class="hero reveal" aria-labelledby="page-title">
      <div class="hero-copy">
        <div>
          <p class="eyebrow">Protection at a glance</p>
          <h1 id="page-title">通信の前後を、<br><span>ここで見守る。</span></h1>
          <p class="hero-lead">機密候補を伏せ、危険な指示を見つけ、応答も確認してから戻します。本文や秘密値をこの画面に残すことはありません。</p>
        </div>
        <div class="hero-meta" aria-label="接続情報">
          <span class="meta-chip" id="listen-address">127.0.0.1</span>
          <span class="meta-chip" id="upstream-host">upstream: —</span>
          <span class="meta-chip" id="uptime">稼働時間 —</span>
        </div>
      </div>

      <div class="gate-panel">
        <p class="now-label">いまの動き</p>
        <p class="now-state" id="primary-state" aria-live="polite">状態を確認中</p>
        <p class="now-detail" id="primary-detail">Bouncerから最新の状態を受け取っています。</p>

        <div class="safety-rail" aria-label="通信を保護する流れ">
          <div class="rail-line" aria-hidden="true"></div>
          <div class="rail-sentinel" aria-hidden="true"></div>
          <div class="rail-stop"><span>あなた</span></div>
          <div class="rail-stop guard"><span>送信前<br>検査</span></div>
          <div class="rail-stop"><span>Anthropic</span></div>
          <div class="rail-stop guard"><span>応答<br>検査</span></div>
          <div class="rail-stop"><span>あなたへ</span></div>
        </div>

        <div class="ai-note">
          <div>
            <strong id="ai-title">ローカルAIを確認中</strong><br>
            <span id="ai-detail">LM Studioとの接続状態を取得しています</span>
          </div>
          <span class="ai-badge" id="ai-badge">確認中</span>
        </div>
      </div>
    </section>

    <section class="stats reveal" aria-label="この起動中の検査集計">
      <div class="stat">
        <span class="stat-label">この起動中の検査</span>
        <strong class="stat-value" id="stat-total">0</strong>
        <span class="stat-note">再起動すると0に戻ります</span>
      </div>
      <div class="stat">
        <span class="stat-label">そのまま通過</span>
        <strong class="stat-value" id="stat-allow">0</strong>
      </div>
      <div class="stat">
        <span class="stat-label">マスクして通過</span>
        <strong class="stat-value" id="stat-masked">0</strong>
      </div>
      <div class="stat">
        <span class="stat-label">確認待ち</span>
        <strong class="stat-value" id="stat-review">0</strong>
      </div>
      <div class="stat">
        <span class="stat-label">遮断</span>
        <strong class="stat-value" id="stat-block">0</strong>
      </div>
    </section>

    <section class="content-grid reveal">
      <div class="panel">
        <div class="panel-header">
          <div>
            <p class="eyebrow">Content-free activity log</p>
            <h2>直近の動き</h2>
          </div>
          <button class="refresh-button" id="refresh-button" type="button">今すぐ更新</button>
        </div>
        <div class="event-list" id="event-list" aria-live="polite">
          <div class="empty-state"><div><strong>まだ検査はありません</strong>Bouncerを通る通信があると、内容を含まない結果だけを表示します。</div></div>
        </div>
      </div>

      <div class="side-stack">
        <aside class="panel side-panel" aria-labelledby="protection-heading">
          <p class="eyebrow">Guard settings</p>
          <h2 id="protection-heading">守り方</h2>
          <div class="mode-line"><span>判定モード</span><strong id="mode-ai">—</strong></div>
          <div class="mode-line"><span>要確認の扱い</span><strong id="mode-review">—</strong></div>
          <div class="mode-line"><span>AI停止時</span><strong id="mode-failure">—</strong></div>
        </aside>

        <aside class="panel side-panel privacy-card" aria-labelledby="privacy-heading">
          <p class="eyebrow">Privacy promise</p>
          <h2 id="privacy-heading">画面に残さないもの</h2>
          <ul class="privacy-list">
            <li>リクエスト・応答の本文</li>
            <li>APIキーなどの秘密値</li>
            <li>マスク値との対応表</li>
          </ul>
        </aside>
      </div>
    </section>

    <footer class="footer">
      <span>状態は2秒ごとに自動更新します。接続が切れた場合も、この画面上でお知らせします。</span>
      <code>GET /bouncer/status</code>
    </footer>
  </main>

  <script>
    const byId = (id) => document.getElementById(id);
    const decisionLabels = {
      allow: "通過",
      allow_masked: "マスク通過",
      review: "確認待ち",
      block: "遮断",
      error: "エラー"
    };
    const kindLabels = {
      gateway: "Gateway通信",
      inspect: "単独検査",
      models: "モデル確認"
    };

    function formatUptime(seconds) {
      if (seconds < 60) return `${seconds}秒`;
      if (seconds < 3600) return `${Math.floor(seconds / 60)}分`;
      const hours = Math.floor(seconds / 3600);
      const minutes = Math.floor((seconds % 3600) / 60);
      return `${hours}時間${minutes}分`;
    }

    function formatTime(epochSeconds) {
      return new Intl.DateTimeFormat("ja-JP", {
        hour: "2-digit", minute: "2-digit", second: "2-digit"
      }).format(new Date(epochSeconds * 1000));
    }

    function setText(id, value) {
      byId(id).textContent = String(value);
    }

    function renderEvents(events) {
      const list = byId("event-list");
      list.replaceChildren();
      if (!events.length) {
        const empty = document.createElement("div");
        empty.className = "empty-state";
        const copy = document.createElement("div");
        const title = document.createElement("strong");
        title.textContent = "まだ検査はありません";
        copy.append(title, "Bouncerを通る通信があると、内容を含まない結果だけを表示します。");
        empty.append(copy);
        list.append(empty);
        return;
      }

      for (const event of events.slice(0, 8)) {
        const row = document.createElement("article");
        row.className = "event-row";

        const time = document.createElement("time");
        time.className = "event-time";
        time.dateTime = new Date(event.finished_at * 1000).toISOString();
        time.textContent = formatTime(event.finished_at);

        const decision = document.createElement("span");
        decision.className = `decision ${event.decision}`;
        decision.textContent = decisionLabels[event.decision] || "完了";

        const main = document.createElement("div");
        main.className = "event-main";
        const summary = document.createElement("strong");
        summary.textContent = event.summary;
        const detail = document.createElement("span");
        const masked = event.masked_count ? ` ・ マスク${event.masked_count}件` : "";
        detail.textContent = `${kindLabels[event.kind] || "処理"}${masked}`;
        main.append(summary, detail);

        const duration = document.createElement("span");
        duration.className = "event-duration";
        duration.textContent = event.elapsed_ms >= 1000
          ? `${(event.elapsed_ms / 1000).toFixed(1)}s`
          : `${event.elapsed_ms}ms`;

        row.append(time, decision, main, duration);
        list.append(row);
      }
    }

    function applyStatus(data) {
      document.body.dataset.connection = "ok";
      const activity = data.activity;
      const active = activity.active_requests > 0;
      document.body.dataset.active = active ? "true" : "false";
      setText("connection-label", "Bouncer 稼働中");
      setText("primary-state", active ? "ただいま検査中" : "ただいま待機中");
      setText(
        "primary-detail",
        active
          ? `${activity.active_requests}件を処理中 — ${activity.active[0].stage}`
          : "新しい通信を待っています。届いた内容は送信前と応答後の両方で確認します。"
      );

      const ai = data.local_ai;
      document.body.dataset.ai = ai.available ? "online" : "offline";
      setText("ai-title", ai.available ? "ローカルAIは準備完了" : "ローカルAIは停止中");
      setText(
        "ai-detail",
        ai.available
          ? `${data.protection.local_model} で意味を判定します`
          : "AI判定が必要な通信は安全側で止めます"
      );
      setText("ai-badge", ai.available ? "利用可能" : "安全側で停止");

      setText("listen-address", data.server.listen);
      setText("upstream-host", `upstream: ${data.protection.upstream_host}`);
      setText("uptime", `稼働時間 ${formatUptime(activity.uptime_seconds)}`);

      const totals = activity.totals;
      setText("stat-total", totals.total);
      setText("stat-allow", totals.allow);
      setText("stat-masked", totals.allow_masked);
      setText("stat-review", totals.review);
      setText("stat-block", totals.block);

      const aiModes = { balanced: "必要時だけAI", strict: "すべてAI判定" };
      setText("mode-ai", aiModes[data.protection.ai_mode] || data.protection.ai_mode);
      setText("mode-review", data.protection.review_mode === "block" ? "確認まで停止" : "通過を許可");
      setText("mode-failure", data.protection.ai_failure_mode === "block" ? "安全側で停止" : "ルールのみ継続");
      renderEvents(activity.recent);
    }

    function applyDisconnected() {
      document.body.dataset.connection = "lost";
      document.body.dataset.active = "false";
      setText("connection-label", "Bouncerとの接続なし");
      setText("primary-state", "接続が切れました");
      setText("primary-detail", "Bouncerが停止したか、再起動中です。起動するとこの画面は自動で復帰します。");
    }

    let refreshing = false;
    async function refreshStatus() {
      if (refreshing) return;
      refreshing = true;
      try {
        const response = await fetch("/bouncer/status", { cache: "no-store" });
        if (!response.ok) throw new Error("status unavailable");
        applyStatus(await response.json());
      } catch (_error) {
        applyDisconnected();
      } finally {
        refreshing = false;
      }
    }

    byId("refresh-button").addEventListener("click", refreshStatus);
    refreshStatus();
    window.setInterval(refreshStatus, 2000);
  </script>
</body>
</html>
"""


def dashboard_bytes() -> bytes:
    return DASHBOARD_HTML.encode("utf-8")
