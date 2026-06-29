defmodule LapsusAgent.UI.Layouts do
  @moduledoc "Root layout for the provider UI (no-build LiveView wiring)."
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>LAPSUS</title>
        <style>
          *{box-sizing:border-box}
          :root{
            --bg:#ffffff; --fg:#16181d; --muted:#6b7280; --line:#ededed;
            --soft:#f6f7f8; --ink:#111418; --link:#16181d; --ok:#16181d; --bad:#8a8f98;
          }
          html,body{margin:0;padding:0}
          body{
            font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
            color:var(--fg); background:var(--bg); line-height:1.6;
            -webkit-font-smoothing:antialiased; text-rendering:optimizeLegibility;
          }
          .wrap{max-width:1040px;margin:0 auto;padding:0 1.5rem}
          a{color:var(--link);text-decoration:none} a:hover{text-decoration:underline}
          h1,h2,h3{letter-spacing:-.021em;font-weight:650;color:var(--fg);margin:0}
          p{margin:.2rem 0 1rem} .muted{color:var(--muted)}

          /* nav */
          .nav{display:flex;align-items:center;gap:1.5rem;padding:1.1rem 0;border-bottom:1px solid var(--line)}
          .nav .brand{font-weight:750;letter-spacing:.04em;font-size:1.2rem;color:var(--fg);display:inline-flex;align-items:center;gap:.55rem}
          .nav .brand:hover{text-decoration:none}
          .nav .brand img{height:40px;width:40px}
          .nav .spacer{flex:1}
          .nav .lnk{color:var(--fg);font-size:.93rem;opacity:.8} .nav .lnk:hover{opacity:1;text-decoration:none}

          /* hero */
          .hero{text-align:center;padding:5rem 0 3.5rem}
          .hero .mark{margin:0 auto 1.6rem;display:block;color:var(--ink)}
          .hero .eyebrow{color:var(--muted);font-size:.95rem}
          .hero h1{font-size:clamp(2rem,4.4vw,3.05rem);line-height:1.08;margin:.7rem auto 1.1rem;max-width:18ch;text-wrap:balance}
          .hero .lede{color:#475160;font-size:1.08rem;max-width:50ch;margin:0 auto 1.8rem;text-wrap:balance}
          .cta{display:flex;gap:.8rem;justify-content:center;flex-wrap:wrap}

          /* buttons */
          .btn{display:inline-flex;align-items:center;gap:.4rem;border:1px solid transparent;border-radius:10px;
               padding:.66rem 1.15rem;font:inherit;font-weight:550;cursor:pointer;text-decoration:none}
          .btn:hover{text-decoration:none;opacity:.92}
          .btn-primary{background:var(--ink);color:#fff}
          .btn-secondary{background:#fff;color:var(--fg);border-color:#dcdfe4}
          .btn-go{background:var(--ok);color:#fff;border:0;border-radius:10px;padding:.6rem 1.05rem;font:inherit;font-weight:550;cursor:pointer}
          .btn-stop{background:var(--bad);color:#fff;border:0;border-radius:10px;padding:.6rem 1.05rem;font:inherit;cursor:pointer}

          /* sections */
          .section{display:grid;grid-template-columns:1fr 1fr;gap:3rem;align-items:center;padding:3.5rem 0;border-top:1px solid var(--line)}
          .section h2{font-size:1.65rem;margin-bottom:.5rem}
          .section p{color:#475160;margin:.2rem 0 1rem}
          @media (max-width:760px){.section{grid-template-columns:1fr;gap:1.5rem;padding:2.5rem 0}.hero{padding:3rem 0 2rem}}

          /* terminal mockup */
          .term{background:#fff;border:1px solid var(--line);border-radius:14px;box-shadow:0 1px 3px rgba(20,24,28,.05);overflow:hidden}
          .term .bar{display:flex;gap:.45rem;padding:.7rem .9rem;border-bottom:1px solid var(--line)}
          .term .bar i{width:.7rem;height:.7rem;border-radius:50%;display:inline-block}
          .term .body{padding:1.05rem 1.15rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.86rem;color:#57606a;line-height:1.85;white-space:pre-wrap}
          .term .ok{color:var(--ok)} .term .dim{color:#9aa1ab} .term .you{color:#16181d}
          /* hero motto with explicit line breaks (each line stands on its own) */
          .hero h1.motto{max-width:none;text-wrap:normal}
          /* "How it works" — full-width content blocks */
          .block{padding:3.5rem 0;border-top:1px solid var(--line)}
          .block-title{font-size:1.65rem;text-align:center;max-width:24ch;margin:.5rem auto .6rem;text-wrap:balance}
          .block-lede{color:#475160;text-align:center;max-width:62ch;margin:0 auto;text-wrap:balance}
          .diagram{display:block;width:100%;max-width:560px;height:auto;margin:0 auto}
          .trio{display:grid;grid-template-columns:repeat(3,1fr);gap:1.2rem}
          @media (max-width:760px){.trio{grid-template-columns:1fr}}
          .tcard{border:1px solid var(--line);border-radius:12px;padding:1.2rem 1.3rem;background:var(--bg)}
          .tcard h3{font-size:1.05rem;margin-bottom:.4rem}
          .tcard p{color:#475160;margin:0;font-size:.95rem}
          /* security cards (b/w, side by side) */
          .secgrid{display:grid;grid-template-columns:repeat(3,1fr);gap:1.2rem;margin-top:1.4rem}
          @media (max-width:760px){.secgrid{grid-template-columns:1fr}}
          .seccard{border:1px solid var(--line);border-radius:12px;padding:1.3rem 1.3rem;background:var(--bg)}
          .seccard.core{border-color:var(--fg);box-shadow:0 1px 3px rgba(20,24,28,.06)}
          .seccard h3{font-size:1.02rem;margin:.7rem 0 .4rem}
          .seccard p{color:#475160;margin:0;font-size:.92rem}
          .secicon{width:26px;height:26px;color:var(--fg);display:block}
          .lnk2{display:inline-block;margin-top:.7rem;font-size:.9rem;font-weight:550;color:var(--fg)}
          /* share: two-column intro/steps, big screenshot below */
          .share-head{display:grid;grid-template-columns:1fr 1fr;gap:2.2rem;align-items:start}
          @media (max-width:760px){.share-head{grid-template-columns:1fr;gap:1rem}}
          .howto{font-size:.95rem;margin:0 0 .3rem}
          ol.steps{margin:.2rem 0 1rem;padding-left:1.3rem;color:#475160}
          ol.steps li{margin:.34rem 0}
          .shotframe .shot{display:block;width:100%;height:auto}
          /* centered intro lede between hero and the showcase */
          .intro-lede{max-width:62ch;margin:0 auto;padding:.5rem 0 1rem}
          .intro-lede p{color:#475160;font-size:1.05rem;line-height:1.6;text-align:center;text-wrap:balance;margin:0}
          /* "How it works" header + App/CLI demo toggle */
          .howhead{display:flex;flex-direction:column;align-items:center;gap:.7rem;padding-top:3rem;padding-bottom:1.8rem}
          /* app-window mock (reuses the .term frame + .bar) */
          .appbody{padding:1.05rem 1.15rem;font-size:.92rem;line-height:1.5;color:var(--fg)}
          .appbody .aw-head{font-weight:600;margin-bottom:.75rem}
          .appbody .aw-row{display:flex;align-items:center;justify-content:space-between;gap:.6rem;padding:.3rem 0}
          .appbody .aw-foot{font-size:.82rem;margin-top:.75rem}
          .appbody .aw-field{border:1px solid var(--line);border-radius:8px;padding:.45rem .6rem;overflow:hidden}
          .appbody .aw-answer{margin:.4rem 0;padding:.55rem .7rem;background:var(--soft);border-radius:8px;line-height:1.5}

          /* cards / lists (app pages) */
          .card{background:#fff;border:1px solid var(--line);border-radius:14px;padding:1.2rem 1.4rem;margin-top:1rem}
          .sec h3{font-weight:680;font-size:1.05rem;color:var(--fg);margin:0 0 .7rem}
          .sec .body{padding-left:1.6rem}
          .sec .body > .muted:first-child{margin-top:0}
          .row{display:flex;justify-content:space-between;align-items:center;padding:.4rem 0}
          ul.clean{list-style:none;padding:0;margin:.5rem 0}
          ul.clean li{padding:.32rem 0 .32rem 1.6rem;position:relative}
          ul.clean li::before{content:"✓";position:absolute;left:0;color:var(--ok);font-weight:700}
          .dot{height:.62rem;width:.62rem;border-radius:50%;display:inline-block;margin-right:.5rem}
          .dot.on{background:var(--ok)} .dot.off{background:#9aa1ab}

          /* toggle switch */
          .sw{width:42px;height:24px;border-radius:999px;background:#d9dce1;border:0;position:relative;
              cursor:pointer;padding:0;flex:none;transition:background .15s ease}
          .sw .knob{position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;
                    background:#fff;box-shadow:0 1px 2px rgba(16,20,24,.25);transition:left .15s ease}
          .sw.on{background:var(--ok)} .sw.on .knob{left:21px}
          .sw:disabled{opacity:.4;cursor:not-allowed}

          /* engine picker (LM Studio ⇄ Ollama) */
          .enginerow{display:flex;align-items:center;justify-content:center;gap:1rem;margin-top:1.1rem}
          .engside{font:inherit;font-size:.9rem;background:transparent;border:0;cursor:pointer;color:var(--muted);
                   display:inline-flex;align-items:center;gap:.45rem;padding:.3rem .2rem}
          .engside.on{color:var(--fg);font-weight:600}
          .engside:disabled{opacity:.45;cursor:not-allowed}
          /* health dots (status colour is allowed here) */
          .hdot{width:.55rem;height:.55rem;border-radius:50%;display:inline-block;flex:none}
          .hdot.up{background:#16a34a} .hdot.down{background:#cbd0d6}

          /* aligned model rows */
          .mrow{display:flex;align-items:center;justify-content:space-between;gap:1rem;
                padding:.6rem 0;border-top:1px solid var(--line)}
          .mrow:first-child{border-top:0}
          .mrow.mhead{border-top:0;padding-bottom:.35rem;font-size:.78rem;text-transform:uppercase;letter-spacing:.03em}
          .mrow.mhead + .mrow{border-top:0}
          .mrow .name{font-family:ui-monospace,Menlo,monospace;font-size:.9rem;color:#24292f}
          .tag{font-size:.62rem;font-weight:700;letter-spacing:.04em;color:#fff;background:var(--ink);border-radius:5px;padding:.1rem .4rem;margin-left:.6rem;vertical-align:2px;text-transform:uppercase}
          .mrow.off .name{color:#9aa1ab}
          .mrow.picked{background:var(--soft);border-radius:9px;padding-left:.6rem;padding-right:.6rem}
          .mrow.picked .name{font-weight:700}
          .mrow:hover .name{color:#000}

          /* searchable dropdown (combobox) */
          .combo{position:relative}
          .combo-field{width:100%;display:flex;justify-content:space-between;align-items:center;
                       background:#fff;border:1px solid #dcdfe4;border-radius:9px;padding:.6rem .75rem;
                       font:inherit;cursor:pointer;text-align:left;color:var(--fg)}
          .combo-field .ph{color:var(--muted)}
          .combo-field code{background:none;padding:0}
          .combo-caret{color:var(--muted);font-size:.8rem}
          .combo-panel{position:absolute;top:calc(100% + 5px);left:0;right:0;background:#fff;
                       border:1px solid var(--line);border-radius:11px;box-shadow:0 8px 28px rgba(16,20,24,.14);
                       z-index:30;padding:.45rem;max-height:300px;overflow:auto}
          .combo-panel input{margin-bottom:.35rem}
          .combo-opt{display:flex;justify-content:space-between;align-items:center;padding:.5rem .55rem;
                     border-radius:8px;cursor:pointer}
          .combo-opt:hover{background:var(--soft)}
          .combo-opt .name{font-family:ui-monospace,Menlo,monospace;font-size:.88rem;color:#24292f}

          /* tab switcher */
          .tabs{display:flex;gap:.3rem;margin-bottom:1rem}
          .tab{font:inherit;font-size:.92rem;font-weight:550;color:var(--muted);background:transparent;border:0;border-bottom:2px solid transparent;padding:.3rem .2rem;margin-right:.8rem;cursor:pointer}
          .tab:hover{color:var(--fg)}
          .tab.on{color:var(--fg);border-bottom-color:var(--fg)}
          /* stat tiles */
          .tiles{display:grid;grid-template-columns:repeat(4,1fr);gap:.7rem;margin:.4rem 0 .2rem}
          @media (max-width:560px){.tiles{grid-template-columns:repeat(2,1fr)}}
          .tile{border:1px solid var(--line);border-radius:10px;padding:.6rem .7rem;display:flex;flex-direction:column;gap:.1rem}
          .tile strong{font-size:1.25rem;line-height:1.2}
          .tile .muted{font-size:.78rem}
          /* range pills */
          .pills{display:flex;gap:.25rem;flex-wrap:wrap}
          .pill{font:inherit;font-size:.78rem;color:var(--muted);background:transparent;border:1px solid var(--line);border-radius:999px;padding:.18rem .6rem;cursor:pointer}
          .pill:hover{border-color:var(--fg);color:var(--fg)}
          .pill.on{background:var(--fg);border-color:var(--fg);color:var(--bg)}
          .pill:disabled{opacity:.5;cursor:default}
          /* aligned key/value list for technical info (Status card) */
          .kv{display:grid;grid-template-columns:max-content 1fr;gap:.5rem 1.3rem;margin:0;font-size:.9rem;align-items:baseline}
          .kv dt{color:var(--muted)}
          .kv dd{margin:0;display:flex;align-items:center;gap:.55rem;flex-wrap:wrap;min-width:0}
          .kv dd.mono{font-family:ui-monospace,Menlo,monospace;font-size:.83rem;word-break:break-all}
          .kv .ok{color:#1f9d55}
          /* usage two-column: time chart + model donut, each its own framed panel */
          .usage-grid{display:grid;grid-template-columns:2fr 1fr;gap:1rem;margin-top:1rem;align-items:stretch}
          @media (max-width:640px){.usage-grid{grid-template-columns:1fr}}
          .panel{border:1px solid var(--line);border-radius:12px;padding:.85rem .95rem .7rem;background:var(--bg);min-width:0}
          .panel h4{margin:0 0 .5rem;font-size:.82rem;font-weight:600;color:var(--fg)}
          .panel h4 .muted{font-weight:400}
          /* Chart.js canvas containers (sized; chart fills) */
          .chartbox{position:relative;height:248px;width:100%}
          .chartbox.donut{height:210px}
          /* faint "no data" overlay shown over an empty (but still framed) chart */
          .chartbox .nodata{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
                            color:var(--muted);opacity:.5;font-size:.85rem;pointer-events:none}
          /* use-AI: file upload + estimate row */
          .uploadrow{display:flex;align-items:center;gap:.6rem;margin-top:.6rem;flex-wrap:wrap}
          .filebtn{display:inline-flex;align-items:center;gap:.3rem;font-size:.82rem;color:var(--fg);border:1px solid var(--line);border-radius:8px;padding:.32rem .6rem;cursor:pointer;width:auto}
          .filebtn:hover{border-color:var(--fg)}
          .chip{display:inline-flex;align-items:center;gap:.4rem;font-size:.78rem;font-family:ui-monospace,Menlo,monospace;background:var(--soft);border-radius:8px;padding:.22rem .5rem}
          .chip .x{border:0;background:transparent;cursor:pointer;font-size:1rem;line-height:1;color:var(--muted);padding:0}
          .chip .x:hover{color:var(--fg)}
          .est{font-size:.8rem;white-space:nowrap}
          .uperr{color:#b42318;font-size:.8rem;margin-top:.3rem}
          /* rendered markdown answer */
          .md{line-height:1.65;overflow-wrap:anywhere}
          .md > :first-child{margin-top:0}
          .md > :last-child{margin-bottom:0}
          .md h1,.md h2,.md h3{line-height:1.3;margin:1.1rem 0 .5rem;font-weight:650}
          .md h1{font-size:1.35rem} .md h2{font-size:1.18rem} .md h3{font-size:1.05rem}
          .md p{margin:.6rem 0} .md ul,.md ol{margin:.6rem 0;padding-left:1.4rem} .md li{margin:.2rem 0}
          .md a{color:var(--fg);text-decoration:underline}
          .md blockquote{margin:.6rem 0;padding:.1rem .9rem;border-left:3px solid var(--line);color:var(--muted)}
          .md code{font-family:ui-monospace,Menlo,monospace;background:var(--soft);padding:.1rem .35rem;border-radius:5px;font-size:.86em}
          .md pre{background:#16181d;color:#e6e8eb;padding:.85rem 1rem;border-radius:10px;overflow:auto;margin:.7rem 0}
          .md pre code{background:transparent;color:inherit;padding:0;font-size:.82rem;line-height:1.55}
          .md table{border-collapse:collapse;margin:.6rem 0;font-size:.9rem}
          .md th,.md td{border:1px solid var(--line);padding:.3rem .6rem;text-align:left}
          .jsonbox{background:#16181d;color:#e6e8eb;padding:.85rem 1rem;border-radius:10px;overflow:auto;margin:0;font-family:ui-monospace,Menlo,monospace;font-size:.82rem;line-height:1.55;white-space:pre-wrap;overflow-wrap:anywhere}
          .kvs .row{border-top:1px solid var(--line)} .kvs .row:first-child{border-top:0}
          code{font-family:ui-monospace,Menlo,monospace;background:var(--soft);padding:.12rem .4rem;border-radius:6px;font-size:.85em;color:#24292f}
          input,textarea,select{font:inherit;width:100%;padding:.6rem .7rem;background:#fff;color:var(--fg);border:1px solid #dcdfe4;border-radius:9px}
          input:focus,textarea:focus,select:focus{outline:none;border-color:#b9c0c9}
          label{font-size:.9rem;color:var(--muted)}
          input[type=range]{accent-color:var(--ok);width:100%;padding:0;border:0;height:1.6rem;cursor:pointer}
          .ticks{display:flex;justify-content:space-between;font-size:.78rem;font-weight:600;color:var(--fg);font-variant-numeric:tabular-nums}
          input[type=number]{max-width:150px}
          .gear{background:#fff;border:1px solid #dcdfe4;border-radius:9px;padding:.35rem .55rem;cursor:pointer;font-size:1.05rem;line-height:1}
          .gear:hover{background:var(--soft)}
          .gearbtn{background:#fff;border:1px solid #dcdfe4;border-radius:14px;padding:.55rem .8rem;cursor:pointer;font-size:2.4rem;line-height:1;color:var(--fg)}
          .gearbtn:hover{background:var(--soft)}
          .frow{display:flex;gap:1.6rem;margin-top:1.1rem;flex-wrap:wrap}

          /* footer */
          .footer{border-top:1px solid var(--line);margin-top:2.5rem;padding:2rem 0;color:var(--muted);font-size:.85rem;display:flex;gap:1.3rem;flex-wrap:wrap;align-items:center}
          .lock{color:#c2c7ce;display:block;margin:0 auto}

          /* local app shell (management console) — full-bleed out of .wrap */
          .appbar,.shell{position:relative;width:100vw;left:50%;margin-left:-50vw}
          .appbar{display:flex;align-items:center;gap:1rem;padding:.65rem 1.2rem;background:#fff;border-bottom:1px solid var(--line)}
          .appbar .brand{font-weight:750;letter-spacing:.04em;font-size:1.05rem;color:var(--fg);display:inline-flex;align-items:center;gap:.5rem}
          .appbar .brand img{height:28px;width:28px}
          .live{display:inline-flex;align-items:center;gap:.4rem;font-size:.8rem;border:1px solid var(--line);border-radius:999px;padding:.18rem .55rem;color:var(--fg)}
          .live .d{width:.5rem;height:.5rem;border-radius:50%;background:#1f9d55;display:inline-block}
          .appbar .pid{font-family:ui-monospace,Menlo,monospace;font-size:.76rem;color:var(--muted)}
          .killswitch{display:inline-flex;align-items:center;gap:.45rem;font-size:.8rem;color:var(--fg)}
          .shell{display:grid;grid-template-columns:208px 1fr;min-height:calc(100vh - 50px);background:var(--soft)}
          .rail{border-right:1px solid var(--line);background:#fff;padding:1rem .7rem;display:flex;flex-direction:column}
          .railftr{margin-top:auto;padding:.75rem .7rem .15rem;border-top:1px solid var(--line)}
          .railftr .rf-brand{font-weight:750;letter-spacing:.05em;font-size:.82rem;color:var(--fg)}
          .railftr .rf-ver{font-family:ui-monospace,Menlo,monospace;font-size:.72rem;color:var(--muted);margin-top:.12rem}
          .rail a{display:flex;align-items:center;padding:.5rem .7rem;border-radius:9px;color:var(--fg);font-size:.92rem;text-decoration:none}
          .rail a.on{background:var(--fg);color:#fff}
          .rail a:hover:not(.on){background:var(--soft);text-decoration:none}
          .rail .grp{color:var(--muted);font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;margin:.9rem .7rem .3rem}
          /* console pages: a plain white surface; content grouped into bordered cards */
          .main{padding:1.6rem 1.9rem;min-width:0;background:#fff}
          .main h1{font-size:1.4rem;margin:0 0 .25rem}
          .main .sub{color:#475160;margin:0 0 1.4rem;font-size:.92rem}
          .dcard{background:#fff;border:1px solid var(--line);border-radius:14px;padding:1.2rem 1.4rem;margin:0 0 1.2rem;overflow:hidden;box-shadow:0 1px 3px rgba(20,24,28,.06),0 1px 2px rgba(20,24,28,.04)}
          .dcard:last-child{margin-bottom:0}
          .dcard.update{display:flex;align-items:center;gap:1rem;border-color:var(--fg);box-shadow:0 1px 3px rgba(20,24,28,.1)}
          .dcard.update .u-txt{min-width:0}
          .dcard.update strong{font-size:.98rem}
          .dcard.update .muted{font-size:.85rem}
          .dcard.update .btn{margin-left:auto;flex:none}
          .dcard h3{font-size:1.05rem;margin:0}
          .dcard > h3{margin-bottom:.9rem}
          .dcard .tile{background:var(--soft);border-color:transparent}
          .dcard .panel{background:var(--soft);border-color:transparent}
          .console{font-family:ui-monospace,Menlo,monospace;font-size:.8rem;color:#57606a;line-height:1.8;overflow-wrap:anywhere}
          .console .ok{color:#1f9d55}
          @media (max-width:760px){.shell{grid-template-columns:1fr}.rail{border-right:0;border-bottom:1px solid var(--line)}}
        </style>
      </head>
      <body>
        <div class="wrap">{@inner_content}</div>
        <script src="/vendor/phoenix/phoenix.min.js"></script>
        <script src="/vendor/lv/phoenix_live_view.min.js"></script>
        <script src="/vendor/chartjs/chart.umd.min.js"></script>
        <script>
          const LAPSUS_PALETTE = ["#16181d","#3d434c","#6b7280","#9aa1ab","#c2c6cd","#dfe2e6"]

          function lapsusBuildChart(canvas, cfg) {
            const loc = cfg.locale || "en-US"
            if (cfg.kind === "bar") {
              return new Chart(canvas, {
                type: "bar",
                data: { labels: cfg.labels, datasets: [
                  { label: "out", data: cfg.out, backgroundColor: "#3d434c", stack: "s", borderRadius: 2, maxBarThickness: 56 },
                  { label: "in",  data: cfg.in,  backgroundColor: "#cfd3d8", stack: "s", borderRadius: 2, maxBarThickness: 56 }
                ]},
                options: {
                  responsive: true, maintainAspectRatio: false, animation: { duration: 350 },
                  interaction: { mode: "index", intersect: false },
                  plugins: {
                    legend: { display: true, position: "bottom", labels: { boxWidth: 10, boxHeight: 10, font: { size: 11 }, color: "#6b7280" } },
                    tooltip: { callbacks: { title: (it) => it[0].label, label: (it) => ` ${it.dataset.label}: ${it.raw.toLocaleString(loc)} tokens` } }
                  },
                  scales: {
                    x: { stacked: true, grid: { display: false }, ticks: { color: "#6b7280", font: { size: 10 }, maxRotation: 0, autoSkip: true, maxTicksLimit: 8 } },
                    y: { stacked: true, beginAtZero: true, grid: { color: "#eef0f2" }, border: { display: false }, ticks: { color: "#6b7280", font: { size: 10 }, maxTicksLimit: 4, callback: (v) => v.toLocaleString(loc) } }
                  }
                }
              })
            }
            return new Chart(canvas, {
              type: "doughnut",
              data: { labels: cfg.labels, datasets: [{ data: cfg.values, backgroundColor: cfg.colors || LAPSUS_PALETTE, borderWidth: 0, hoverOffset: 6 }] },
              options: {
                responsive: true, maintainAspectRatio: false, cutout: "72%", animation: { duration: 350 },
                plugins: {
                  legend: { display: true, position: "bottom", labels: { boxWidth: 10, boxHeight: 10, font: { size: 11 }, color: "#16181d", padding: 12 } },
                  tooltip: { callbacks: { label: (it) => {
                    const total = it.dataset.data.reduce((a, b) => a + b, 0) || 1
                    return ` ${it.label}: ${it.raw.toLocaleString(loc)} (${Math.round(it.raw / total * 100)}%)`
                  } } }
                }
              }
            })
          }

          const LapsusHooks = {
            SubmitOnCmdEnter: {
              mounted() {
                this.el.addEventListener("keydown", (e) => {
                  if ((e.metaKey || e.ctrlKey) && e.key === "Enter" && this.el.form) {
                    e.preventDefault()
                    this.el.form.requestSubmit()
                  }
                })
              }
            },
            Chart: {
              render() {
                const cfg = JSON.parse(this.el.dataset.chart)
                const canvas = this.el.querySelector("canvas")
                if (this.chart) this.chart.destroy()
                this.chart = lapsusBuildChart(canvas, cfg)
              },
              mounted() { this.render() },
              updated() { this.render() },
              destroyed() { if (this.chart) this.chart.destroy() }
            }
          }

          let csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: {_csrf_token: csrf},
            hooks: LapsusHooks
          })
          liveSocket.connect()
        </script>
      </body>
    </html>
    """
  end
end
