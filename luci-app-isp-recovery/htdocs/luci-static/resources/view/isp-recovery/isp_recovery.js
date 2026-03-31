'use strict';
'require view';
'require rpc';
'require ui';
'require fs';

/*
 * ISP Credential Recovery Wizard
 * Migrated from Lua controller + HTM template to modern LuCI JS view.
 *
 * Architecture overview
 * ─────────────────────
 * OLD: luci.controller.isp_recovery (Lua) + template isp-recovery/wizard.htm
 *      → io.popen() → isp-recover.sh → /tmp/*.json files
 *      → luci.http AJAX endpoints
 *
 * NEW: view/isp-recovery/wizard.js  (this file)
 *      → L.rpc.declare() stubs → rpcd isp_recovery service
 *        (rpcd calls /usr/bin/isp-recover.sh unchanged)
 *      → ACL: /usr/share/rpcd/acl.d/luci-app-isp-recovery.json
 *      → No Lua controller needed at all.
 *
 * Each old Lua action_*() maps 1-to-1 to an rpc.declare() call below.
 * The shell script (isp-recover.sh) is UNCHANGED — rpcd executes it via
 * the "file" and "exec" rpcd plugins exactly as before.
 */

// ── RPC declarations (replaces all Lua action_* functions) ────────────────
//
// rpcd "file" plugin: read/tail files the shell script writes
// rpcd "exec" plugin: call isp-recover.sh with arguments
//
// All calls require the ACL entries in luci-app-isp-recovery.json.

var callDetect = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'detect',
    expect: {}
});

var callSetup = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'setup',
    params: ['port'],
    expect: {}
});

var callCapture = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'capture',
    params: ['port'],
    expect: {}
});

var callStop = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'stop',
    expect: {}
});

var callAutotest = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'autotest',
    expect: {}
});

var callAutotestResults = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'autotest_results',
    expect: {}
});

var callResults = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'results',
    expect: {}
});

var callApply = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'apply',
    params: ['auth_type','username','password','ip','gateway',
             'netmask','dns1','dns2','mac','vlan'],
    expect: {}
});

var callRestore = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'restore',
    expect: {}
});

var callCleanup = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'cleanup',
    expect: {}
});

var callGetLog = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'get_log',
    params: ['lines'],
    expect: { log: '' }
});

// ── Community DB RPC declarations ─────────────────────────────────────────

var callIspInfo = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'isp_info',
    expect: {}
});

var callDbSubmit = rpc.declare({
    object: 'luci.isp_recovery',
    method: 'db_submit',
    params: ['mac_clone', 'attempts'],
    expect: {}
});

// ── Community DB CSS additions ────────────────────────────────────────────
var DB_CSS = [
// DB hint banner (shown on Step 1 when a known config exists)
'  padding:14px 18px;margin:12px 0;position:relative;}',
'  letter-spacing:1px;text-transform:uppercase;}',
'.db-cfg-pill{background:rgba(0,0,0,.3);border:1px solid var(--border);border-radius:3px;',
'  padding:6px 12px;font-size:12px;cursor:pointer;transition:all .2s;}',
'.db-cfg-pill:hover{border-color:var(--accent2);color:var(--accent2);}',
'.db-cfg-pill.selected{border-color:var(--accent2);background:rgba(0,255,157,.1);color:var(--accent2);}',
'.db-votes{font-size:11px;color:var(--dim);margin-left:4px;}',
// Submit panel (shown on Step 6 results after success)
'.db-submit-panel{background:rgba(0,212,255,.04);border:1px solid var(--border);border-radius:4px;',
'  padding:16px 20px;margin:16px 0;}',
'.db-submit-hdr{font-family:var(--head);font-size:15px;font-weight:700;color:var(--accent);',
'  letter-spacing:1px;margin-bottom:8px;}',
'.db-submit-isp{font-size:13px;color:var(--dim);margin-bottom:12px;}',
'.db-submit-detail{display:grid;grid-template-columns:130px 1fr;gap:4px 12px;',
'  font-size:12px;margin:10px 0 14px;}',
'.db-submit-key{color:var(--dim);text-transform:uppercase;letter-spacing:.5px;}',
'.db-submit-val{color:var(--accent2);font-family:var(--mono);}',
'.db-submitted{color:var(--accent2);font-size:13px;padding:8px 0;}',
].join('\n');

// ── CSS (inlined — same design tokens as original wizard.htm) ──────────────
var CSS = [
'@import url("https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Rajdhani:wght@400;600;700&display=swap");',
':root{--bg:#0a0e14;--panel:#0f1520;--border:#1e3a5f;--accent:#00d4ff;--accent2:#00ff9d;',
'  --warn:#ff6b35;--danger:#ff3355;--text:#c8d8e8;--dim:#4a6080;--success:#00ff9d;',
'  --mono:"Share Tech Mono",monospace;--head:"Rajdhani",sans-serif;}',
'#isp-wiz *{box-sizing:border-box;}',
'#isp-wiz{font-family:var(--mono);background:var(--bg);color:var(--text);min-height:80vh;',
'  padding:24px;border-radius:4px;position:relative;overflow:hidden;}',
'#isp-wiz::before{content:"";position:absolute;inset:0;',
'  background:repeating-linear-gradient(0deg,transparent,transparent 2px,',
'  rgba(0,212,255,.015) 2px,rgba(0,212,255,.015) 4px);pointer-events:none;z-index:0;}',
// Header
'.isp-hdr{display:flex;align-items:center;gap:16px;margin-bottom:32px;position:relative;z-index:1;}',
'.isp-logo{width:48px;height:48px;border:2px solid var(--accent);border-radius:4px;',
'  display:flex;align-items:center;justify-content:center;font-size:24px;',
'  background:rgba(0,212,255,.1);flex-shrink:0;animation:pulse-border 2s infinite;}',
'@keyframes pulse-border{0%,100%{box-shadow:0 0 0 0 rgba(0,212,255,.4)}50%{box-shadow:0 0 0 8px rgba(0,212,255,0)}}',
'.isp-logo-title h1{font-family:var(--head);font-size:28px;font-weight:700;color:var(--accent);',
'  margin:0;letter-spacing:2px;text-transform:uppercase;}',
'.isp-logo-title p{margin:2px 0 0;color:var(--dim);font-size:12px;letter-spacing:1px;}',
// Step track
'.step-track{display:flex;align-items:center;margin-bottom:32px;position:relative;z-index:1;}',
'.step-item{display:flex;flex-direction:column;align-items:center;flex:1;position:relative;}',
'.step-item:not(:last-child)::after{content:"";position:absolute;top:16px;left:50%;',
'  width:100%;height:2px;background:var(--border);transition:background .5s;}',
'.step-item.done:not(:last-child)::after,.step-item.active:not(:last-child)::after{background:var(--accent);}',
'.step-num{width:32px;height:32px;border-radius:50%;border:2px solid var(--border);',
'  display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:bold;',
'  background:var(--bg);transition:all .3s;position:relative;z-index:1;color:var(--dim);}',
'.step-item.active .step-num{border-color:var(--accent);color:var(--accent);',
'  box-shadow:0 0 12px rgba(0,212,255,.5);background:rgba(0,212,255,.1);}',
'.step-item.done .step-num{border-color:var(--accent2);background:var(--accent2);color:var(--bg);}',
'.step-label{font-size:10px;margin-top:6px;color:var(--dim);text-align:center;',
'  letter-spacing:.5px;text-transform:uppercase;}',
'.step-item.active .step-label{color:var(--accent);}.step-item.done .step-label{color:var(--accent2);}',
// Panel
'.wpanel{background:var(--panel);border:1px solid var(--border);border-radius:4px;',
'  padding:24px;margin-bottom:20px;position:relative;z-index:1;display:none;}',
'.wpanel.active{display:block;animation:fadeIn .3s ease;}',
'@keyframes fadeIn{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}',
'.panel-title{font-family:var(--head);font-size:18px;font-weight:700;color:var(--accent);',
'  text-transform:uppercase;letter-spacing:2px;margin-bottom:16px;display:flex;align-items:center;gap:10px;}',
// Info / warn boxes
'.info-box{background:rgba(0,212,255,.05);border-left:3px solid var(--accent);',
'  padding:12px 16px;margin:12px 0;border-radius:0 4px 4px 0;font-size:13px;line-height:1.7;}',
'.warn-box{background:rgba(255,107,53,.08);border-left:3px solid var(--warn);',
'  padding:12px 16px;margin:12px 0;border-radius:0 4px 4px 0;font-size:13px;color:var(--warn);}',
// Interface cards
'.iface-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:16px 0;}',
'.iface-card{background:rgba(0,212,255,.04);border:1px solid var(--border);border-radius:4px;padding:12px 16px;}',
'.iface-card label{font-size:10px;color:var(--dim);text-transform:uppercase;letter-spacing:1px;display:block;}',
'.iface-card .val{font-size:16px;color:var(--accent2);font-family:var(--mono);margin-top:4px;}',
// Radar
'.cap-status{display:flex;align-items:center;gap:16px;margin:20px 0;}',
'.radar{width:64px;height:64px;border:2px solid var(--accent);border-radius:50%;',
'  position:relative;flex-shrink:0;}',
'.radar::before{content:"";position:absolute;inset:4px;border:1px solid rgba(0,212,255,.3);border-radius:50%;}',
'.radar-sweep{position:absolute;top:50%;left:50%;width:50%;height:2px;',
'  background:linear-gradient(to right,var(--accent),transparent);',
'  transform-origin:left center;animation:sweep 2s linear infinite;}',
'@keyframes sweep{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}',
'.radar.idle .radar-sweep{display:none;}.radar.idle{border-color:var(--border);}',
'.cap-info{flex:1;}.cap-info h3{font-family:var(--head);margin:0 0 6px;color:var(--accent);',
'  font-size:16px;text-transform:uppercase;letter-spacing:1px;}',
// Timer
'.tbar-wrap{background:rgba(0,0,0,.4);border:1px solid var(--border);border-radius:2px;',
'  height:8px;margin:8px 0;overflow:hidden;}',
'.tbar{height:100%;background:linear-gradient(90deg,var(--accent2),var(--accent));',
'  transition:width 1s linear;border-radius:2px;box-shadow:0 0 8px var(--accent);}',
'.ttext{font-size:12px;color:var(--dim);}',
// Results
'.rsec{margin:16px 0;}',
'.rsec h4{font-family:var(--head);color:var(--accent);font-size:14px;text-transform:uppercase;',
'  letter-spacing:1px;margin:0 0 10px;padding-bottom:6px;border-bottom:1px solid var(--border);}',
'.rgrid{display:grid;grid-template-columns:160px 1fr;gap:6px 16px;}',
'.rkey{color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.5px;display:flex;align-items:center;}',
'.rval{font-family:var(--mono);font-size:14px;color:var(--accent2);word-break:break-all;}',
'.rval.na{color:var(--dim);font-style:italic;}.rval.warn{color:var(--warn);}',
'.auth-badge{display:inline-block;padding:3px 12px;border-radius:2px;font-size:13px;',
'  font-weight:bold;letter-spacing:1px;text-transform:uppercase;}',
'.auth-badge.pppoe{background:rgba(0,212,255,.15);color:var(--accent);border:1px solid var(--accent);}',
'.auth-badge.dhcp{background:rgba(0,255,157,.12);color:var(--accent2);border:1px solid var(--accent2);}',
'.auth-badge.static{background:rgba(255,107,53,.12);color:var(--warn);border:1px solid var(--warn);}',
'.auth-badge.unknown{background:rgba(74,96,128,.2);color:var(--dim);border:1px solid var(--dim);}',
// Buttons
'.btn-row{display:flex;gap:12px;margin-top:20px;flex-wrap:wrap;}',
'.wbtn{font-family:var(--mono);font-size:13px;padding:10px 24px;border-radius:3px;border:none;',
'  cursor:pointer;letter-spacing:1px;text-transform:uppercase;transition:all .2s;',
'  position:relative;overflow:hidden;}',
'.wbtn:disabled{opacity:.4;cursor:not-allowed;}',
'.wbtn-primary{background:var(--accent);color:var(--bg);font-weight:bold;}',
'.wbtn-primary:not(:disabled):hover{background:#33ddff;box-shadow:0 0 16px rgba(0,212,255,.5);}',
'.wbtn-success{background:var(--accent2);color:var(--bg);font-weight:bold;}',
'.wbtn-success:not(:disabled):hover{box-shadow:0 0 16px rgba(0,255,157,.5);}',
'.wbtn-danger{background:transparent;color:var(--danger);border:1px solid var(--danger);}',
'.wbtn-danger:not(:disabled):hover{background:rgba(255,51,85,.1);}',
'.wbtn-ghost{background:transparent;color:var(--dim);border:1px solid var(--border);}',
'.wbtn-ghost:not(:disabled):hover{color:var(--text);border-color:var(--text);}',
// Terminal
'.terminal{background:#060a0f;border:1px solid var(--border);border-radius:3px;padding:12px;',
'  font-size:11px;font-family:var(--mono);color:#4aff7a;max-height:180px;overflow-y:auto;',
'  line-height:1.6;margin-top:12px;}',
'.terminal .t-dim{color:var(--dim);}.terminal .t-warn{color:var(--warn);}.terminal .t-err{color:var(--danger);}',
// Status dot
'.sdot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:8px;}',
'.sdot.green{background:var(--accent2);box-shadow:0 0 6px var(--accent2);}',
'.sdot.blue{background:var(--accent);box-shadow:0 0 6px var(--accent);animation:blink 1s infinite;}',
'.sdot.red{background:var(--danger);box-shadow:0 0 6px var(--danger);}',
'.sdot.grey{background:var(--dim);}',
'@keyframes blink{0%,100%{opacity:1}50%{opacity:.3}}',
// Auto-test rows
'.at-row{display:grid;grid-template-columns:28px 1fr 80px 70px;gap:6px 12px;',
'  align-items:center;padding:7px 10px;border-radius:3px;margin-bottom:4px;font-size:13px;',
'  background:rgba(0,0,0,.2);border:1px solid var(--border);transition:all .3s;}',
'.at-row.running{border-color:var(--accent);background:rgba(0,212,255,.06);box-shadow:0 0 8px rgba(0,212,255,.15);}',
'.at-row.pass{border-color:var(--accent2);background:rgba(0,255,157,.07);}',
'.at-row.fail{border-color:rgba(255,51,85,.3);opacity:.6;}.at-row.pending{opacity:.35;}',
'.at-num{color:var(--dim);font-size:11px;text-align:right;}',
'.at-label.running{color:var(--accent);}.at-label.pass{color:var(--accent2);}',
'.at-status{font-size:12px;text-align:center;padding:2px 8px;border-radius:2px;font-weight:bold;}',
'.at-status.running{color:var(--accent);}.at-status.pass{color:var(--accent2);}',
'.at-status.fail{color:var(--danger);}.at-status.pending{color:var(--dim);}',
'.at-rtt{font-size:11px;color:var(--dim);font-family:var(--mono);}.at-rtt.pass{color:var(--accent2);}',
// Edit form
'.egrid{display:grid;grid-template-columns:160px 1fr;gap:10px 16px;align-items:center;}',
'.egrid label{font-size:12px;color:var(--dim);text-transform:uppercase;letter-spacing:.5px;line-height:1.3;}',
'.einput{background:#060a0f;border:1px solid var(--border);border-radius:3px;color:var(--accent2);',
'  font-family:var(--mono);font-size:14px;padding:7px 10px;width:100%;max-width:320px;transition:border-color .2s;}',
'.einput:focus{outline:none;border-color:var(--accent);box-shadow:0 0 8px rgba(0,212,255,.2);}',
'.einput::placeholder{color:var(--dim);}',
'.conf-badge{font-size:11px;margin-left:8px;padding:2px 8px;border-radius:2px;',
'  vertical-align:middle;white-space:nowrap;}',
'.conf-badge.high{color:var(--accent2);border:1px solid var(--accent2);background:rgba(0,255,157,.08);}',
'.conf-badge.medium{color:var(--warn);border:1px solid var(--warn);background:rgba(255,107,53,.08);}',
'.conf-badge.low{color:var(--danger);border:1px solid var(--danger);background:rgba(255,51,85,.08);}',
'.conf-badge.calc{color:var(--accent);border:1px solid var(--accent);background:rgba(0,212,255,.08);}',
'.auth-radio{cursor:pointer;display:inline-flex;align-items:center;gap:8px;}',
'.auth-radio input{display:none;}',
'.auth-radio input:checked+.auth-badge{box-shadow:0 0 12px rgba(0,212,255,.4);}',
// Scrollbar + responsive
'#isp-wiz ::-webkit-scrollbar{width:6px;}',
'#isp-wiz ::-webkit-scrollbar-track{background:var(--bg);}',
'#isp-wiz ::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px;}',
'@media(max-width:600px){.step-label{display:none;}.rgrid{grid-template-columns:1fr;}',
'  .btn-row{flex-direction:column;}.wbtn{width:100%;}}'
].join('\n');

// ── Helpers ────────────────────────────────────────────────────────────────

function esc(s) {
    return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function E(tag, attrs, children) {
    // Thin wrapper around document.createElement for concise DOM building.
    // attrs: plain object of attribute/property pairs (class → className handled)
    // children: string | Node | array
    var el = document.createElement(tag);
    if (attrs) {
        Object.keys(attrs).forEach(function(k) {
            if (k === 'class') el.className = attrs[k];
            else if (k === 'html')  el.innerHTML  = attrs[k];
            else if (k === 'text')  el.textContent = attrs[k];
            else if (k.startsWith('on')) el.addEventListener(k.slice(2), attrs[k]);
            else el.setAttribute(k, attrs[k]);
        });
    }
    [].concat(children || []).forEach(function(c) {
        if (c == null) return;
        el.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return el;
}

// ── View state ─────────────────────────────────────────────────────────────
var _state = {
    step:         0,
    capturePort:  'lan1',
    interfaces:   {},
    results:      {},
    timerInterval:    null,
    timerSeconds:     30,
    logPoll:          null,
    logSeenLines:     0,
    autotestPoll:     null,
    atLogSeen:        0,
    atWaitTimer:      null,
    atWaitSeconds:    0,
    atTotalSeconds:   35,
    // Community DB
    dbHint:           null,   // best config from community DB for this ISP
    ispInfo:          null,   // ip-api.com result for current WAN
    dbSubmitted:      false,  // whether we already submitted this session
    autotestWinnerMac: 'no',  // mac_clone value from winning autotest attempt
    autotestWinnerNum: 1      // attempt number of the winner
};

// ── View definition ────────────────────────────────────────────────────────
return view.extend({

    // render() is called once by LuCI when the page loads.
    // It injects CSS, builds the full DOM, wires up event handlers,
    // and returns the root element — LuCI mounts it into the page.
    render: function() {
        // Inject stylesheet
        var style = document.createElement('style');
        style.textContent = CSS + '\n' + DB_CSS;
        document.head.appendChild(style);

        var root = E('div', {id: 'isp-wiz'}, [
            this._buildHeader(),
            this._buildStepTrack(),
            this._buildPanel0(),   // Step 1 — Detect
            this._buildPanel1(),   // Step 2 — Prepare
            this._buildPanel2(),   // Step 3 — Connect
            this._buildPanel3(),   // Step 4 — Capture
            this._buildPanel4(),   // Step 5 — Auto-Test
            this._buildPanel5(),   // Step 6 — Results
            this._buildPanel6()    // Step 7 — Apply
        ]);

        return root;
    },

    // handleSaveApply / handleSave / handleReset — not used (custom Apply btn)
    handleSaveApply: null,
    handleSave:      null,
    handleReset:     null,

    // ── DOM builders ──────────────────────────────────────────────────────

    _buildHeader: function() {
        return E('div', {class: 'isp-hdr'}, [
            E('div', {class: 'isp-logo'}, '🔍'),
            E('div', {class: 'isp-logo-title'}, [
                E('h1', {text: _('ISP Credential Recovery')}),
                E('p',  {text: _('CAPTURE • ANALYSE • APPLY — Universal WAN Credential Recovery for OpenWrt')})
            ])
        ]);
    },

    _buildStepTrack: function() {
        var steps = [_('Detect'),_('Prepare'),_('Connect'),_('Capture'),_('Auto-Test'),_('Results'),_('Apply')];
        var track = E('div', {class: 'step-track', id: 'stepTrack'});
        steps.forEach(function(label, i) {
            var cls = 'step-item' + (i === 0 ? ' active' : '');
            track.appendChild(
                E('div', {class: cls, id: 'step-' + i}, [
                    E('div', {class: 'step-num', text: String(i + 1)}),
                    E('div', {class: 'step-label', text: label})
                ])
            );
        });
        return track;
    },

    // ── Panel 0: Welcome & detect ──────────────────────────────────────────
    _buildPanel0: function() {
        var self = this;
        return E('div', {class: 'wpanel active', id: 'panel-0'}, [
            E('div', {class: 'panel-title'}, [E('span', {class:'icon'}, '🖧'), ' Step 1 — Before You Begin']),

            E('div', {class: 'info-box', html:
                'This tool recovers your ISP connection credentials by briefly connecting your ISP router ' +
                'to a spare LAN port and capturing the authentication traffic.<br><br>' +
                '<strong>Port assignment — important:</strong><br><br>' +
                '<div style="display:grid;grid-template-columns:auto 1fr;gap:8px 16px;margin:8px 0">' +
                '<span style="color:var(--accent2);font-size:20px;text-align:center">🔴</span>' +
                '<span><strong style="color:var(--accent2)">LAN 1</strong> — reserved for the ISP router capture cable.</span>' +
                '<span style="color:var(--accent);font-size:20px;text-align:center">💻</span>' +
                '<span><strong style="color:var(--accent)">LAN 2 or LAN 3</strong> — use for your laptop to monitor this wizard.</span>' +
                '<span style="color:var(--dim);font-size:20px;text-align:center">📶</span>' +
                '<span><strong style="color:var(--dim)">WiFi</strong> — also fine for monitoring.</span></div>'
            }),
            E('div', {class: 'warn-box', html:
                '⚠ LAN 1 will be temporarily taken offline during capture. ' +
                'LAN 2, LAN 3 and WiFi are <strong>not affected</strong>.'
            }),

            // Interface display — hidden until detect runs
            E('div', {id: 'iface-display', style: 'display:none;margin:16px 0'}, [
                E('div', {class: 'iface-grid'}, [
                    E('div', {class: 'iface-card'}, [
                        E('label', {text: 'WAN Interface'}),
                        E('div',   {class: 'val', id: 'disp-wan', text: '—'})
                    ]),
                    E('div', {class: 'iface-card', style: 'border-color:var(--accent2)'}, [
                        E('label', {style: 'color:var(--accent2)', text: 'Capture Port (fixed)'}),
                        E('div',   {class: 'val', style: 'color:var(--accent2);font-size:20px', text: 'lan1'})
                    ]),
                    E('div', {class: 'iface-card'}, [
                        E('label', {text: 'LAN Bridge'}),
                        E('div',   {class: 'val', id: 'disp-lan', text: '—'})
                    ])
                ]),
                E('div', {class: 'warn-box', id: 'lan1-warn', style: 'display:none', html:
                    '⚠ <strong>lan1 was not found</strong> on this router. ' +
                    'Check <em>Network → Switch</em> in LuCI to find the correct port name.'
                })
            ]),

            E('div', {class: 'btn-row'}, [
                E('button', {
                    class: 'wbtn wbtn-primary', id: 'btnDetect',
                    onclick: function() { self.doDetect(); }
                }, '⚡ Check Interfaces & Continue')
            ]),
            E('div', {class: 'terminal', id: 'log-0', style: 'display:none'})
        ]);
    },

    // ── Panel 1: Prepare LAN 1 ─────────────────────────────────────────────
    _buildPanel1: function() {
        var self = this;
        return E('div', {class: 'wpanel', id: 'panel-1'}, [
            E('div', {class: 'panel-title'}, [E('span', {class:'icon'}, '🔗'), ' Step 2 — Prepare LAN 1 for Capture']),
            E('div', {class: 'info-box', html:
                'Before you plug the ISP router in, LAN 1 needs to be taken offline.<br><br>' +
                '<strong>Why?</strong> The ISP router authenticates on first link-up. ' +
                'Taking the port down first guarantees a cold-start capture.<br><br>' +
                '<strong>Nothing else on your network is affected</strong> — LAN 2, LAN 3 and WiFi stay online.'
            }),
            E('div', {id: 'prep-status', style: 'font-size:13px;color:var(--dim);margin:12px 0',
                text: 'Ready to prepare LAN 1...'}),
            E('div', {class: 'btn-row'}, [
                E('button', {
                    class: 'wbtn wbtn-primary', id: 'btnSetup',
                    onclick: function() { self.doSetup(); }
                }, '🔧 Take LAN 1 Offline & Prepare'),
                E('button', {
                    class: 'wbtn wbtn-ghost',
                    onclick: function() { self.goStep(0); }
                }, '← Back')
            ]),
            E('div', {class: 'terminal', id: 'log-1', style: 'display:none'})
        ]);
    },

    // ── Panel 2: Connect ISP router ────────────────────────────────────────
    _buildPanel2: function() {
        var self = this;
        return E('div', {class: 'wpanel', id: 'panel-2'}, [
            E('div', {class: 'panel-title'}, [E('span', {class:'icon'}, '🔌'), ' Step 3 — Connect the Old ISP Router']),

            E('div', {style: 'text-align:center;padding:16px 0 8px'}, [
                E('div', {style: 'font-size:42px;margin-bottom:6px'}, '🔆 ——→ 🖥️ ——→ 📦'),
                E('div', {style: 'font-family:var(--head);font-size:10px;letter-spacing:2px;color:var(--dim)',
                    html: 'ONT/WALL → <span style="color:var(--accent)">NEW ROUTER WAN</span>&nbsp;&nbsp;&nbsp;' +
                          '<span style="color:var(--danger)">NEW ROUTER LAN 1</span> → OLD ISP ROUTER WAN PORT'})
            ]),

            E('div', {class: 'info-box', html:
                '<strong style="color:var(--accent)">Do this now, in order:</strong><br><br>' +
                '<div style="display:grid;grid-template-columns:24px 1fr;gap:10px;line-height:1.6">' +
                '<span style="color:var(--accent2);font-weight:bold;text-align:center">1</span>' +
                '<span>Confirm your <strong>ONT / wall socket</strong> is plugged into your OpenWrt router WAN port.</span>' +
                '<span style="color:var(--accent2);font-weight:bold;text-align:center">2</span>' +
                '<span>Plug one end of an Ethernet cable into <strong style="color:var(--danger)">LAN 1</strong>. ' +
                'The link light will not come on yet — that\'s expected.</span>' +
                '<span style="color:var(--accent2);font-weight:bold;text-align:center">3</span>' +
                '<span>Plug the other end into the <strong>WAN/Internet port</strong> of your old ISP router.</span>' +
                '<span style="color:var(--accent2);font-weight:bold;text-align:center">4</span>' +
                '<span>Reboot the old ISP router (unplug power, wait 5 s, plug back in).</span>' +
                '<span style="color:var(--accent2);font-weight:bold;text-align:center">5</span>' +
                '<span>Wait 30–60 s for it to finish booting, then click the button below.</span></div>'
            }),
            E('div', {class: 'warn-box', html:
                '⚠ <strong>The old router does NOT need its phone/fibre/coax line.</strong> ' +
                'It authenticates via the Ethernet cable on LAN 1.'
            }),

            E('div', {class: 'btn-row'}, [
                E('button', {
                    class: 'wbtn wbtn-primary', id: 'btnCapture',
                    onclick: function() { self.doCapture(); }
                }, '▶ Old Router Ready — Start Capture!'),
                E('button', {
                    class: 'wbtn wbtn-ghost',
                    onclick: function() { self.goStep(1); }
                }, '← Back')
            ])
        ]);
    },

    // ── Panel 3: Capturing ─────────────────────────────────────────────────
    _buildPanel3: function() {
        var self = this;
        return E('div', {class: 'wpanel', id: 'panel-3'}, [
            E('div', {class: 'panel-title'}, [E('span', {class:'icon'}, '📡'), ' Step 4 — Capturing Traffic']),

            E('div', {class: 'cap-status'}, [
                E('div', {class: 'radar', id: 'radarAnim'}, [
                    E('div', {class: 'radar-sweep'})
                ]),
                E('div', {class: 'cap-info'}, [
                    E('h3', {id: 'cap-status-text', text: 'Waiting for ISP router...'}),
                    E('p',  {style: 'color:var(--dim);font-size:12px;margin:4px 0',
                        text: 'Capturing PPPoE, DHCP, VLAN, ARP and authentication packets'}),
                    E('div', {class: 'tbar-wrap'}, [
                        E('div', {class: 'tbar', id: 'timerBar', style: 'width:100%'})
                    ]),
                    E('div', {class: 'ttext', id: 'timerText', text: '30 seconds remaining'})
                ])
            ]),

            E('div', {class: 'info-box', html:
                '<span class="sdot blue"></span>Monitoring for: ' +
                'PPPoE authentication (PADI/PADS/CHAP/PAP) &bull; ' +
                'DHCP address assignment &bull; VLAN 802.1Q tags &bull; ' +
                'Static IPoE / ARP announcements &bull; MAC address of ISP router'
            }),
            E('div', {class: 'terminal', id: 'log-3', text: 'Capture started — monitoring port...'}),

            E('div', {class: 'btn-row', style: 'margin-top:16px'}, [
                E('button', {
                    class: 'wbtn wbtn-ghost wbtn-danger',
                    onclick: function() { self.doStopEarly(); }
                }, '⏹ Stop Early')
            ])
        ]);
    },

    // ── Panel 4: Auto-Test ─────────────────────────────────────────────────
    _buildPanel4: function() {
        var self = this;
        return E('div', {class: 'wpanel', id: 'panel-4'}, [
            E('div', {class: 'panel-title'}, [E('span', {class:'icon'}, '🔬'), ' Step 5 — Auto-Testing Connection']),

            E('div', {class: 'info-box', html:
                'LAN 1 has been released and your laptop\'s connection is restored.<br><br>' +
                'The tool is now testing your WAN port with the captured settings, ' +
                'trying each combination in order — most likely first.<br><br>' +
                '<strong style="color:var(--warn)">⏱ Each attempt waits 30 s</strong> ' +
                'for the interface to come up, then pings 8.8.8.8. ' +
                'Max wait: <strong id="at-max-time">several minutes</strong>. ' +
                '<strong>You don\'t need to do anything — just wait.</strong>'
            }),

            E('div', {style: 'margin:16px 0'}, [
                E('div', {style: 'display:flex;justify-content:space-between;font-size:12px;color:var(--dim);margin-bottom:6px'}, [
                    E('span', {id: 'at-overall-label', text: 'Preparing...'}),
                    E('span', {id: 'at-overall-count', text: '0 / 0'})
                ]),
                E('div', {class: 'tbar-wrap'}, [
                    E('div', {class: 'tbar', id: 'at-overall-bar', style: 'width:0%'})
                ])
            ]),

            E('div', {class: 'cap-status', id: 'at-current-wrap'}, [
                E('div', {class: 'radar', id: 'at-radar'}, [E('div', {class: 'radar-sweep'})]),
                E('div', {class: 'cap-info'}, [
                    E('h3', {id: 'at-current-label', style: 'font-size:15px', text: 'Starting...'}),
                    E('div', {style: 'margin:6px 0'}, [
                        E('div', {class: 'tbar-wrap'}, [
                            E('div', {class: 'tbar', id: 'at-wait-bar',
                                style: 'width:100%;background:linear-gradient(90deg,var(--dim),var(--accent))'})
                        ]),
                        E('div', {class: 'ttext', id: 'at-wait-text', text: 'Waiting for interface...'})
                    ])
                ])
            ]),

            E('div', {id: 'at-attempt-list', style: 'margin-top:16px'}),
            E('div', {class: 'terminal', id: 'log-4', style: 'max-height:140px', text: 'Auto-test starting...'}),

            E('div', {class: 'btn-row', style: 'margin-top:12px'}, [
                E('button', {
                    class: 'wbtn wbtn-ghost wbtn-danger', id: 'at-skip-btn',
                    onclick: function() { self.atSkip(); }
                }, '⏭ Skip Auto-Test (Manual)')
            ])
        ]);
    },

    // ── Panel 5: Results ───────────────────────────────────────────────────
    _buildPanel5: function() {
        var self = this;
        return E('div', {class: 'wpanel', id: 'panel-5'}, [
            E('div', {class: 'panel-title'}, [E('span', {class:'icon'}, '📋'), ' Step 6 — Results']),
            E('div', {id: 'at-outcome-banner', style: 'display:none;margin-bottom:16px'}),
            E('div', {id: 'results-guidance', style: 'display:none;margin-bottom:16px'}),
            E('div', {id: 'results-container'}, [
                E('div', {style: 'text-align:center;padding:20px;color:var(--dim)', text: 'Loading results...'})
            ]),
            // Community DB submit panel — populated by showAutoTestOutcome() on success
            E('div', {id: 'db-submit-wrap', style: 'display:none'}),
            E('div', {class: 'btn-row'}, [
                E('button', {
                    class: 'wbtn wbtn-success', id: 'btnApply',
                    onclick: function() { self.goStep(6); }
                }, '→ Review & Fine-tune Settings'),
                E('button', {
                    class: 'wbtn wbtn-ghost',
                    onclick: function() { self.downloadPcap(); }
                }, '⬇ Download PCAP'),
                E('button', {
                    class: 'wbtn wbtn-danger',
                    onclick: function() { self.doRestore(); }
                }, '✕ Restore Original Config')
            ])
        ]);
    },

    // ── Panel 6: Edit & Apply ──────────────────────────────────────────────
    _buildPanel6: function() {
        var self = this;

        var buildRadio = function(value, label) {
            return E('label', {class: 'auth-radio'}, [
                E('input', {type: 'radio', name: 'apply_auth', value: value,
                    id: 'r_' + value,
                    onchange: function() { self.updateAuthSections(value); }}),
                E('span', {class: 'auth-badge ' + value, text: label})
            ]);
        };

        var buildField = function(labelText, id, placeholder, confId, subLabel) {
            var labelEl = E('label', {}, [
                labelText,
                subLabel ? E('br') : null,
                subLabel ? E('span', {style: 'font-size:10px;color:var(--dim)', text: subLabel}) : null
            ].filter(Boolean));
            var inputWrap = E('div', {}, [
                E('input', {type: 'text', class: 'einput', id: id, placeholder: placeholder || ''}),
                confId ? E('span', {class: 'conf-badge', id: confId}) : null
            ].filter(Boolean));
            return [labelEl, inputWrap];
        };

        return E('div', {class: 'wpanel', id: 'panel-6'}, [
            E('div', {class: 'panel-title'}, [E('span', {class:'icon'}, '✏️'), ' Step 7 — Review, Edit & Apply']),

            E('div', {class: 'info-box', id: 'apply-context-success', style: 'display:none', html:
                '✅ <strong>Your router is already connected to the internet</strong> using the settings below — ' +
                'the auto-test found a working combination.<br><br>' +
                'You don\'t need to click Apply unless you want to make changes.'
            }),
            E('div', {class: 'info-box', id: 'apply-context-failed', style: 'display:none', html:
                'The auto-test could not establish a connection automatically. Common causes:<br><br>' +
                '<div style="display:grid;grid-template-columns:20px 1fr;gap:8px;margin:4px 0;line-height:1.6">' +
                '<span style="color:var(--warn)">▸</span>' +
                '<span><strong>PPPoE with CHAP</strong> — password was hashed and couldn\'t be recovered. Enter it manually.</span>' +
                '<span style="color:var(--warn)">▸</span>' +
                '<span><strong>Static IP with no ARP traffic</strong> — enter IP, gateway and netmask manually.</span>' +
                '<span style="color:var(--warn)">▸</span>' +
                '<span><strong>Unusual auth</strong> — check the PCAP in Wireshark for clues.</span></div>'
            }),
            E('div', {class: 'info-box', id: 'apply-context-skipped', style: 'display:none', html:
                'You skipped the auto-test. Review the detected settings below and click Apply.'
            }),

            // Connection type
            E('div', {class: 'rsec'}, [
                E('h4', {text: 'Connection Type'}),
                E('div', {style: 'display:flex;gap:10px;flex-wrap:wrap;margin-bottom:4px'}, [
                    buildRadio('pppoe',  'PPPoE'),
                    buildRadio('dhcp',   'DHCP'),
                    buildRadio('static', 'Static IP')
                ])
            ]),

            // PPPoE fields
            E('div', {class: 'rsec', id: 'edit-pppoe', style: 'display:none'}, [
                E('h4', {text: 'PPPoE Credentials'}),
                E('div', {class: 'egrid'}, buildField('Username', 'e_user', 'username@isp.co.uk', 'conf_user')
                    .concat(buildField('Password', 'e_pass', 'password', 'conf_pass'))
                    .concat([
                        E('label', {text: 'Auth Method'}),
                        E('div', {id: 'e_auth_method', style: 'color:var(--dim);font-size:13px', text: '—'})
                    ])
                )
            ]),

            // IP fields
            E('div', {class: 'rsec', id: 'edit-ip', style: 'display:none'}, [
                E('h4', {text: 'IP Configuration'}),
                E('div', {class: 'egrid'},
                    buildField('IP Address',    'e_ip',   'e.g. 82.68.12.6',        'conf_ip')
                    .concat(buildField('Gateway',      'e_gw',   'e.g. 82.68.12.1',        'conf_gw'))
                    .concat(buildField('Netmask',      'e_nm',   'e.g. 255.255.255.248',    'conf_nm'))
                    .concat(buildField('DNS Primary',  'e_dns1', ''))
                    .concat(buildField('DNS Secondary','e_dns2', ''))
                )
            ]),

            // Additional settings
            E('div', {class: 'rsec'}, [
                E('h4', {text: 'Additional Settings'}),
                E('div', {class: 'egrid'},
                    buildField('MAC Address', 'e_mac', 'leave blank = use own MAC', 'conf_mac', 'clone ISP router MAC')
                    .concat(buildField('VLAN ID', 'e_vlan', 'e.g. 101 (or blank)', 'conf_vlan', '802.1Q tag, blank = none'))
                )
            ]),

            E('div', {class: 'warn-box', id: 'notes-box', style: 'display:none'}),

            // Apply progress
            E('div', {id: 'apply-status', style: 'display:none;margin:16px 0'}, [
                E('div', {class: 'cap-status'}, [
                    E('div', {class: 'radar', id: 'applyRadar'}, [E('div', {class: 'radar-sweep'})]),
                    E('div', {class: 'cap-info'}, [
                        E('h3', {id: 'apply-status-text', text: 'Applying settings...'}),
                        E('p',  {style: 'color:var(--dim);font-size:12px',
                            text: 'Network restarting — reconnect in ~20 seconds'})
                    ])
                ])
            ]),

            E('div', {class: 'btn-row'}, [
                E('button', {
                    class: 'wbtn wbtn-success', id: 'btnApplyFinal',
                    onclick: function() { self.doApply(); }
                }, '⚡ Apply Settings to WAN'),
                E('button', {
                    class: 'wbtn wbtn-ghost',
                    onclick: function() { self.goStep(5); }
                }, '← Back to Results'),
                E('button', {
                    class: 'wbtn wbtn-danger',
                    onclick: function() { self.doRestore(); }
                }, '✕ Restore Original Config')
            ]),
            E('div', {class: 'terminal', id: 'log-6', style: 'display:none'})
        ]);
    },

    // ── Navigation ─────────────────────────────────────────────────────────
    goStep: function(n) {
        document.querySelectorAll('.wpanel').forEach(function(p, i) {
            p.classList.toggle('active', i === n);
        });
        document.querySelectorAll('.step-item').forEach(function(s, i) {
            s.classList.remove('active', 'done');
            if (i < n)  s.classList.add('done');
            if (i === n) s.classList.add('active');
        });
        _state.step = n;
    },

    // ── Logging ────────────────────────────────────────────────────────────
    log: function(panelId, msg, cls) {
        var el = document.getElementById('log-' + panelId);
        if (!el) return;
        el.style.display = 'block';
        var line = E('div', cls ? {class: 't-' + cls} : {},
            '[' + new Date().toLocaleTimeString() + '] ' + msg);
        el.appendChild(line);
        el.scrollTop = el.scrollHeight;
    },

    // ── Step 0: Detect ─────────────────────────────────────────────────────
    // OLD: action_detect() → run_script("detect") → reads /tmp/isp-ifaces.json
    // NEW: callDetect() → rpcd luci.isp_recovery.detect → same shell command,
    //      result returned directly as parsed JSON object
    doDetect: function() {
        var self = this;
        var btn = document.getElementById('btnDetect');
        btn.disabled = true; btn.textContent = 'Checking...';
        self.log(0, 'Checking network interfaces...');

        callDetect().then(function(data) {
            btn.disabled = false;
            btn.textContent = '⚡ Check Interfaces & Continue';

            if (!data || data.error) {
                self.log(0, 'Error: ' + (data && data.error || 'no response'), 'err');
                return;
            }

            _state.interfaces = data;
            _state.capturePort = 'lan1';

            var wanEl  = document.getElementById('disp-wan');
            var lanEl  = document.getElementById('disp-lan');
            var dispEl = document.getElementById('iface-display');
            var warnEl = document.getElementById('lan1-warn');

            if (wanEl)  wanEl.textContent  = data.wan || '—';
            if (lanEl)  lanEl.textContent  = data.lan || '—';
            if (dispEl) dispEl.style.display = 'block';

            if (data.lan1_ok === 'no') {
                if (warnEl) warnEl.style.display = 'block';
                self.log(0, 'WARNING: lan1 not found on this router', 'warn');
                return; // Don't advance — user must acknowledge
            }

            self.log(0, '✓ lan1 confirmed  |  WAN: ' + data.wan);
            setTimeout(function() { self.goStep(1); }, 800);
        }).catch(function(err) {
            btn.disabled = false;
            btn.textContent = '⚡ Check Interfaces & Continue';
            self.log(0, 'RPC error: ' + err, 'err');
        });
    },

    // ── Step 1: Setup ──────────────────────────────────────────────────────
    // OLD: action_setup() → run_script("setup lan1")
    // NEW: callSetup('lan1') → rpcd luci.isp_recovery.setup
    doSetup: function() {
        var self = this;
        var btn = document.getElementById('btnSetup');
        btn.disabled = true; btn.textContent = 'Preparing...';
        var statusEl = document.getElementById('prep-status');
        if (statusEl) statusEl.textContent = 'Setting up capture port...';
        self.log(1, 'Preparing port ' + _state.capturePort + ' — bringing link DOWN...');

        callSetup(_state.capturePort).then(function() {
            btn.disabled = false;
            btn.textContent = _('🔧 Prepare Port');
            if (statusEl) {
                statusEl.innerHTML =
                    '<span class="sdot green"></span>Port ' + _state.capturePort +
                    ' is DOWN — ISP router will detect cable disconnect';
            }
            self.log(1, _('Port down ✓ — ready for ISP router connection'));
            setTimeout(function() { self.goStep(2); }, 1200);
        }).catch(function(err) {
            btn.disabled = false;
            btn.textContent = _('🔧 Prepare Port');
            self.log(1, 'RPC error: ' + err, 'err');
        });
    },

    // ── Step 2 → 3: Start Capture ──────────────────────────────────────────
    // OLD: action_capture() → run_script("capture lan1")  (fire-and-forget)
    // NEW: callCapture('lan1') → rpcd — shell spawns tcpdump in background,
    //      returns immediately. Timer + log poll run client-side as before.
    doCapture: function() {
        var self = this;
        var btn = document.getElementById('btnCapture');
        btn.disabled = true; btn.textContent = 'Starting capture...';

        callCapture(_state.capturePort).then(function() {
            self.goStep(3);
            self.startTimer();
            self.startLogPoll(3);
        }).catch(function(err) {
            btn.disabled = false;
            self.log(3, 'RPC error: ' + err, 'err');
        });
    },

    // ── Capture timer (unchanged logic) ────────────────────────────────────
    startTimer: function() {
        var self = this;
        _state.timerSeconds = 30;
        self.updateTimer();
        _state.timerInterval = setInterval(function() {
            _state.timerSeconds--;
            self.updateTimer();
            if (_state.timerSeconds <= 0) {
                clearInterval(_state.timerInterval);
                self.stopCapture();
            }
        }, 1000);
    },

    updateTimer: function() {
        var s = _state.timerSeconds;
        var bar  = document.getElementById('timerBar');
        var txt  = document.getElementById('timerText');
        var head = document.getElementById('cap-status-text');
        if (bar)  bar.style.width  = ((s / 30) * 100) + '%';
        if (txt)  txt.textContent  = s + ' seconds remaining';
        if (head) {
            head.textContent =
                s > 20 ? 'Waiting for ISP router to send traffic...' :
                s > 8  ? 'Capturing authentication handshake...' :
                         'Finalising capture...';
        }
    },

    doStopEarly: function() {
        if (_state.timerInterval) clearInterval(_state.timerInterval);
        this.stopCapture();
    },

    // ── Stop capture + analyse ─────────────────────────────────────────────
    // OLD: action_stop() → run_script("stop") → os.execute("sleep 2") →
    //      reads /tmp/isp-results.json → returns JSON
    // NEW: callStop() → rpcd runs same logic, returns results JSON directly.
    stopCapture: function() {
        var self = this;
        if (_state.logPoll) { clearInterval(_state.logPoll); _state.logPoll = null; }
        var head = document.getElementById('cap-status-text');
        var radar = document.getElementById('radarAnim');
        if (head)  head.textContent = 'Analysing all captured packets...';
        if (radar) radar.classList.add('idle');
        self.log(3, 'Capture stopped — running full analysis...');

        callStop().then(function(data) {
            if (!data) { self.log(3, 'Analysis error: no data', 'err'); return; }
            _state.results = data;
            self.goStep(4);
            self.startAutoTest(data);
        }).catch(function(err) {
            self.log(3, 'RPC error: ' + err, 'err');
        });
    },

    // ── Log polling — reads /tmp/isp-recovery.log via rpcd ─────────────────
    // OLD: XHR to /admin/network/isp_recovery/log?lines=25
    // NEW: callGetLog({lines:25}) → rpcd luci.isp_recovery.get_log
    startLogPoll: function(panelId) {
        var self = this;
        _state.logSeenLines = 0;
        _state.logPoll = setInterval(function() {
            callGetLog(25).then(function(res) {
                var lines = (res.log || '').split('\n');
                var el = document.getElementById('log-' + panelId);
                if (!el) return;
                lines.slice(_state.logSeenLines).forEach(function(l) {
                    if (!l) return;
                    var d = E('div', {}, l);
                    el.appendChild(d);
                });
                _state.logSeenLines = lines.length;
                el.scrollTop = el.scrollHeight;
            });
        }, 2000);
    },

    // ── Auto-test ──────────────────────────────────────────────────────────
    // OLD: action_autotest() → os.execute("... autotest ... &")  (background)
    //      poll via action_autotest_results() → reads /tmp/isp-autotest.json
    // NEW: callAutotest() starts background process via rpcd (same mechanism).
    //      callAutotestResults() polls /tmp/isp-autotest.json via rpcd.
    startAutoTest: function() {
        var self = this;
        self.log(4, 'Starting auto-test sequence...');
        var labelEl = document.getElementById('at-overall-label');
        if (labelEl) labelEl.textContent = 'Launching auto-test...';

        callAutotest().then(function() {
            self.log(4, 'Auto-test running — testing each config combination...');
            _state.autotestPoll = setInterval(function() { self.pollAutoTest(); }, 3000);
            _state.atLogSeen = 0;
            setInterval(function() { self.pollAutoTestLog(); }, 3000);
        }).catch(function(err) {
            self.log(4, 'Failed to start autotest: ' + err, 'err');
        });
    },

    pollAutoTest: function() {
        var self = this;
        callAutotestResults().then(function(data) {
            if (!data || data.status === 'not_started') return;
            if (data.attempts_total > 0) self.updateMaxTimeEstimate(data.attempts_total);
            self.renderAutoTestProgress(data);

            if (data.status === 'success' || data.status === 'failed' || data.status === 'error') {
                clearInterval(_state.autotestPoll);
                if (_state.atWaitTimer) { clearInterval(_state.atWaitTimer); _state.atWaitTimer = null; }
                setTimeout(function() {
                    self.showAutoTestOutcome(data);
                    self.renderResults(_state.results);
                    self.populateEditForm(_state.results);
                    self.goStep(5);
                }, 2000);
            }
        });
    },

    pollAutoTestLog: function() {
        var self = this;
        callGetLog(50).then(function(res) {
            var lines = (res.log || '').split('\n');
            var el = document.getElementById('log-4');
            if (!el) return;
            lines.slice(_state.atLogSeen).forEach(function(l) {
                if (!l) return;
                el.appendChild(E('div', {}, l));
            });
            _state.atLogSeen = lines.length;
            el.scrollTop = el.scrollHeight;
        });
    },

    renderAutoTestProgress: function(data) {
        var self = this;
        var done  = data.attempts_done  || 0;
        var total = data.attempts_total || 1;
        var tried = data.tried || [];
        var cur   = data.current || '';

        var countEl   = document.getElementById('at-overall-count');
        var barEl     = document.getElementById('at-overall-bar');
        var labelEl   = document.getElementById('at-overall-label');
        var curLabel  = document.getElementById('at-current-label');
        var radarEl   = document.getElementById('at-radar');
        var waitBar   = document.getElementById('at-wait-bar');
        var waitText  = document.getElementById('at-wait-text');

        if (countEl) countEl.textContent = done + ' / ' + total;
        if (barEl)   barEl.style.width   = Math.round((done / total) * 100) + '%';

        if (data.status === 'success') {
            if (labelEl)  labelEl.textContent  = '✓ Connected: ' + cur;
            if (radarEl)  radarEl.classList.add('idle');
            if (waitText) waitText.textContent = 'Connection established!';
            if (waitBar)  { waitBar.style.background = 'var(--accent2)'; waitBar.style.width = '100%'; }
        } else if (data.status === 'failed') {
            if (labelEl)  labelEl.textContent = 'All attempts exhausted — last config left in place';
            if (radarEl)  radarEl.classList.add('idle');
        } else {
            if (labelEl)  labelEl.textContent  = 'Testing: ' + cur;
            if (curLabel) curLabel.textContent  = cur;

            if (_state.atWaitTimer) clearInterval(_state.atWaitTimer);
            _state.atWaitSeconds  = 0;
            _state.atTotalSeconds = 35;
            _state.atWaitTimer = setInterval(function() {
                _state.atWaitSeconds++;
                var pct = Math.min(100, Math.round((_state.atWaitSeconds / _state.atTotalSeconds) * 100));
                if (waitBar)  waitBar.style.width  = pct + '%';
                var remaining = _state.atTotalSeconds - _state.atWaitSeconds;
                if (waitText) waitText.textContent =
                    remaining > 0 ? 'Waiting ' + remaining + 's for interface...' : 'Ping testing...';
                if (_state.atWaitSeconds >= _state.atTotalSeconds) {
                    clearInterval(_state.atWaitTimer); _state.atWaitTimer = null;
                }
            }, 1000);
        }
        self.renderAttemptList(tried, done, total, cur, data.status);
    },

    renderAttemptList: function(tried, done, total, current, overallStatus) {
        var html = '';
        tried.forEach(function(a) {
            var rc   = a.status === 'pass' ? 'pass' : 'fail';
            var icon = a.status === 'pass' ? '✓' : '✗';
            var rtt  = a.rtt ? a.rtt + 'ms' : '—';
            html += '<div class="at-row ' + rc + '">' +
                '<div class="at-num">'    + esc(String(a.num))   + '</div>' +
                '<div class="at-label ' + rc + '">' + esc(a.label) + '</div>' +
                '<div class="at-status ' + rc + '">' + icon + ' ' + a.status.toUpperCase() + '</div>' +
                '<div class="at-rtt ' + (a.status === 'pass' ? 'pass' : '') + '">' + rtt + '</div>' +
                '</div>';
        });
        if (overallStatus === 'running' && current) {
            html += '<div class="at-row running">' +
                '<div class="at-num">' + (done + 1) + '</div>' +
                '<div class="at-label running">⟳ ' + esc(current) + '</div>' +
                '<div class="at-status running">TESTING</div>' +
                '<div class="at-rtt">...</div></div>';
        }
        var remaining = total - done - (overallStatus === 'running' ? 1 : 0);
        if (remaining > 0 && overallStatus === 'running') {
            html += '<div class="at-row pending">' +
                '<div class="at-num">+' + remaining + '</div>' +
                '<div class="at-label" style="color:var(--dim)">more combinations queued</div>' +
                '<div class="at-status pending">PENDING</div>' +
                '<div class="at-rtt">—</div></div>';
        }
        var el = document.getElementById('at-attempt-list');
        if (el) el.innerHTML = html;
    },

    atSkip: function() {
        var self = this;
        if (_state.autotestPoll) clearInterval(_state.autotestPoll);
        if (_state.atWaitTimer)  clearInterval(_state.atWaitTimer);

        ['apply-context-skipped','apply-context-success','apply-context-failed'].forEach(function(id, i) {
            var el = document.getElementById(id);
            if (el) el.style.display = i === 0 ? 'block' : 'none';
        });
        var guidance = document.getElementById('results-guidance');
        if (guidance) {
            guidance.style.cssText = 'display:block;font-size:13px;color:var(--dim);padding:10px 14px;' +
                'border-left:3px solid var(--accent);background:rgba(0,212,255,.04);' +
                'border-radius:0 4px 4px 0;margin-bottom:16px';
            guidance.innerHTML = 'Auto-test skipped. Review captured details below and use Step 7 to apply manually.';
        }
        self.renderResults(_state.results);
        self.populateEditForm(_state.results);
        self.goStep(5);
    },

    updateMaxTimeEstimate: function(total) {
        var el = document.getElementById('at-max-time');
        if (!el || !total) return;
        var mins = Math.ceil((total * 35) / 60);
        el.textContent = 'up to ~' + mins + ' minute' + (mins === 1 ? '' : 's') +
            ' (' + total + ' combinations)';
    },

    showAutoTestOutcome: function(data) {
        var banner   = document.getElementById('at-outcome-banner');
        var guidance = document.getElementById('results-guidance');
        var ctxOk    = document.getElementById('apply-context-success');
        var ctxFail  = document.getElementById('apply-context-failed');
        var ctxSkip  = document.getElementById('apply-context-skipped');

        var ok = data.status === 'success';

        if (banner) {
            banner.style.display = 'block';
            if (ok) {
                banner.style.cssText = 'display:block;background:rgba(0,255,157,.08);border:1px solid var(--accent2);border-radius:4px;padding:14px 18px;margin-bottom:16px';
                banner.innerHTML =
                    '<span style="color:var(--accent2);font-family:var(--head);font-size:16px;letter-spacing:1px">✓ CONNECTED — ' + esc(data.current) + '</span><br>' +
                    '<span style="font-size:13px;color:var(--text)">Your router is online. Settings are already live.</span> ' +
                    '<span style="font-size:12px;color:var(--dim)">(' + data.attempts_done + ' attempt' + (data.attempts_done === 1 ? '' : 's') + ' needed)</span>';
            } else {
                banner.style.cssText = 'display:block;background:rgba(255,51,85,.06);border:1px solid var(--danger);border-radius:4px;padding:14px 18px;margin-bottom:16px';
                banner.innerHTML =
                    '<span style="color:var(--danger);font-family:var(--head);font-size:16px;letter-spacing:1px">✗ AUTO-TEST FAILED — ' + data.attempts_done + ' combinations tried</span><br>' +
                    '<span style="font-size:13px;color:var(--text)">No combination connected. See Step 7 to fix manually.</span>';
            }
        }
        if (guidance) {
            guidance.style.display = 'block';
            if (ok) {
                guidance.style.cssText = 'display:block;font-size:13px;color:var(--dim);padding:10px 14px;border-left:3px solid var(--accent2);background:rgba(0,255,157,.04);border-radius:0 4px 4px 0;margin-bottom:16px';
                guidance.innerHTML = "<strong style=\"color:var(--accent2)\">You're done!</strong> Your internet connection is working. Use Step 7 only to adjust manually.";
            } else {
                guidance.style.cssText = 'display:block;font-size:13px;color:var(--dim);padding:10px 14px;border-left:3px solid var(--warn);background:rgba(255,107,53,.04);border-radius:0 4px 4px 0;margin-bottom:16px';
                guidance.innerHTML = '<strong style="color:var(--warn)">Action needed:</strong> Review captured details below, then go to Step 7 to fill in missing information and apply settings manually.';
            }
        }
        if (ctxOk)   ctxOk.style.display   = ok ? 'block' : 'none';
        if (ctxFail) ctxFail.style.display  = ok ? 'none'  : 'block';
        if (ctxSkip) ctxSkip.style.display  = 'none';

        // ── Community DB: WAN is now up — load hint + offer submit ──────────
        if (ok) {
            this.renderDbSubmitPanel(data);
        }
    },

    // ── Results (step 5) ───────────────────────────────────────────────────
    renderResults: function(d) {
        var at   = d.auth_type        || 'unknown';
        var conf = d.auth_confidence  || 'low';
        var ip   = d.ip    || {};
        var pp   = d.pppoe || {};

        var html  = '<div style="margin-bottom:20px;display:flex;align-items:center;gap:12px">';
        html += '<span class="auth-badge ' + at + '">' + at.toUpperCase() + '</span>';
        html += '<span class="conf-badge ' + conf + '">' + conf + ' confidence</span></div>';

        html += '<div class="rsec"><h4>🖧 Network Details</h4><div class="rgrid">';
        html += this._rrow('Auth Method',  at.toUpperCase());
        html += this._rrow('MAC Address',  d.mac_address, 'For MAC cloning on WAN');
        html += this._rrow('VLAN ID',      d.vlan_id,     '802.1Q tag — blank = untagged');
        html += '</div></div>';

        if (at === 'pppoe') {
            html += '<div class="rsec"><h4>🔐 PPPoE Credentials</h4><div class="rgrid">';
            html += this._rrow('Username',  pp.username);
            html += this._rrow('Password',  pp.password ? '••••••••' : null);
            html += this._rrow('Auth Mode', pp.auth_method);
            html += '</div>';
            if (pp.auth_method === 'CHAP') {
                html += '<div class="warn-box">⚠ CHAP detected — password is MD5-hashed. Enter it manually in the edit form.</div>';
            }
            html += '</div>';
        } else {
            html += '<div class="rsec"><h4>📡 IP Configuration</h4><div class="rgrid">';
            var nmLabel = 'Netmask' + (ip.netmask_source ? ' (' + ip.netmask_source + ')' : '');
            html += this._rrow('IP Address',    ip.address,   null, ip.ip_confidence);
            html += this._rrow('Gateway',       ip.gateway,   null, ip.gw_confidence);
            html += this._rrow(nmLabel,         ip.netmask,   null,
                ip.netmask_source === 'calculated' ? 'calc' :
                ip.netmask_source === 'dhcp'       ? 'high' : 'medium');
            html += this._rrow('DNS Primary',   ip.dns1 || '1.1.1.1');
            html += this._rrow('DNS Secondary', ip.dns2 || '1.0.0.1');
            html += '</div></div>';
        }
        if (d.notes) html += '<div class="warn-box">ℹ ' + esc(d.notes) + '</div>';
        html += '<div style="margin-top:12px;font-size:11px;color:var(--dim)">📁 PCAP: ' +
            esc(d.pcap_file || '/tmp/isp-capture.pcap') + '</div>';

        var el = document.getElementById('results-container');
        if (el) el.innerHTML = html;
    },

    _rrow: function(label, val, hint, conf) {
        var v = val
            ? '<span class="rval">' + esc(val) + '</span>'
            : '<span class="rval na">not detected</span>';
        var c = conf ? ' <span class="conf-badge ' + conf + '">' + conf + '</span>' : '';
        var h = hint ? ' title="' + esc(hint) + '"' : '';
        return '<div class="rkey"' + h + '>' + label + '</div><div>' + v + c + '</div>';
    },

    // ── Populate editable form ─────────────────────────────────────────────
    populateEditForm: function(d) {
        var at = d.auth_type || 'unknown';
        var ip = d.ip    || {};
        var pp = d.pppoe || {};

        var r = document.getElementById('r_' + at);
        if (r) r.checked = true;
        else { var rd = document.getElementById('r_static'); if (rd) rd.checked = true; at = 'static'; }

        this._setVal('e_user', pp.username);
        this._setVal('e_pass', pp.password);
        var authEl = document.getElementById('e_auth_method');
        if (authEl) authEl.textContent = pp.auth_method || '—';
        this._setBadge('conf_user', pp.username ? 'high' : 'low');
        this._setBadge('conf_pass', pp.password ? (pp.auth_method === 'CHAP' ? 'low' : 'high') : 'low');

        this._setVal('e_ip',   ip.address);
        this._setVal('e_gw',   ip.gateway);
        this._setVal('e_nm',   ip.netmask);
        this._setVal('e_dns1', ip.dns1 || '1.1.1.1');
        this._setVal('e_dns2', ip.dns2 || '1.0.0.1');
        this._setBadge('conf_ip', ip.ip_confidence || 'low');
        this._setBadge('conf_gw', ip.gw_confidence || 'low');
        this._setBadge('conf_nm',
            ip.netmask_source === 'calculated' ? 'calc' :
            ip.netmask_source === 'dhcp'       ? 'high' : 'medium');

        this._setVal('e_mac',  d.mac_address);
        this._setVal('e_vlan', d.vlan_id);
        this._setBadge('conf_mac',  d.mac_address ? 'high' : 'low');
        this._setBadge('conf_vlan', d.vlan_id     ? 'high' : '');

        if (d.notes) {
            var nb = document.getElementById('notes-box');
            if (nb) { nb.textContent = 'ℹ ' + d.notes; nb.style.display = 'block'; }
        }
        this.updateAuthSections(at);

        // Apply community DB hint — fills VLAN, username format, MAC hint
        // DB hint may override some capture values with community-confirmed ones
        if (_state.dbHint && _state.dbHint.status === 'found') {
            }
    },

    updateAuthSections: function(at) {
        var ppEl = document.getElementById('edit-pppoe');
        var ipEl = document.getElementById('edit-ip');
        if (ppEl) ppEl.style.display = at === 'pppoe' ? 'block' : 'none';
        if (ipEl) ipEl.style.display = at !== 'pppoe' ? 'block' : 'none';
    },

    _setVal: function(id, val) {
        var el = document.getElementById(id);
        if (el && val) el.value = val;
    },

    _gv: function(id) {
        var el = document.getElementById(id);
        return el ? el.value.trim() : '';
    },

    _setBadge: function(id, level) {
        var el = document.getElementById(id);
        if (!el || !level) return;
        var labels = {high: '✓ high', medium: '⚠ medium', low: '⚠ low — check!', calc: '≈ calculated'};
        el.className = 'conf-badge ' + level;
        el.textContent = labels[level] || level;
    },

    // ── Apply (step 6) ─────────────────────────────────────────────────────
    // OLD: action_apply() → builds env-var string → io.popen(env .. " isp-recover.sh apply")
    // NEW: callApply(...params) → rpcd sets env vars and calls the script.
    //      All 10 params are passed as named RPC arguments — clean, no shell injection risk.
    doApply: function() {
        var self = this;
        var btn = document.getElementById('btnApplyFinal');
        btn.disabled = true;
        var statusEl = document.getElementById('apply-status');
        if (statusEl) statusEl.style.display = 'block';

        var at = 'static';
        document.querySelectorAll('input[name="apply_auth"]').forEach(function(r) {
            if (r.checked) at = r.value;
        });

        self.log(6, 'Applying: ' + at.toUpperCase() +
            (self._gv('e_user') ? '  user=' + self._gv('e_user') : '') +
            (self._gv('e_ip')   ? '  ip='   + self._gv('e_ip')   : ''));

        callApply(
            at,
            self._gv('e_user'), self._gv('e_pass'),
            self._gv('e_ip'),   self._gv('e_gw'),
            self._gv('e_nm'),   self._gv('e_dns1'),
            self._gv('e_dns2'), self._gv('e_mac'),
            self._gv('e_vlan')
        ).then(function() {
            var statusText = document.getElementById('apply-status-text');
            if (statusText) statusText.textContent = 'Settings applied! Network restarting...';
            self.log(6, 'Done ✓ — reconnect in ~20 seconds');
            self.log(6, 'If no internet, use Restore to revert.', 'warn');
            setTimeout(function() {
                if (statusText) statusText.textContent = '✅ Complete — check Network → Interfaces for WAN status';
                var applyRadar = document.getElementById('applyRadar');
                if (applyRadar) applyRadar.classList.add('idle');
            }, 10000);
        }).catch(function(err) {
            btn.disabled = false;
            self.log(6, 'RPC error: ' + err, 'err');
        });
    },

    // ── Community DB: render submit panel after autotest success ───────────
    renderDbSubmitPanel: function(autotestData) {
        var wrap = document.getElementById('db-submit-wrap');
        if (!wrap) return;

        // Show a "waiting for ISP lookup" placeholder immediately,
        // then replace it once ispInfo arrives (polled from callIspInfo).
        // If DB is not configured the panel stays hidden.
        var self = this;

        // Poll until ispInfo is ready (fetched by lookup_isp background job)
        var tries = 0;
        var showPanel = function() {
            if (!_state.ispInfo) {
                // Not ready yet — retry up to ~12s
                if (++tries < 6) setTimeout(showPanel, 2000);
                return;
            }
            if (_state.ispInfo.error === 'not_configured' ||
                _state.ispInfo.status === 'not_configured') {
                return;  // DB not configured — hide panel entirely
            }

            var isp = _state.ispInfo.isp || _state.ispInfo.org || 'Unknown ISP';
            var asn = _state.ispInfo.as  || '';
            var at  = (_state.results.auth_type  || 'unknown').toUpperCase();
            var am  = (_state.results.pppoe && _state.results.pppoe.auth_method) || '';
            var vlan = _state.results.vlan_id || 'none';
            // mac_clone: did the winning attempt label contain "+MAC"?
            var mac  = autotestData.current && autotestData.current.indexOf('MAC') !== -1;
            // username_capturable: did the capture find a PPPoE username?
            var userFound = !!(
                _state.results.pppoe && _state.results.pppoe.username
            );

            // Build the "exactly what we send" disclosure table
            var passFound = userFound; // PAP sends both in clear; CHAP sends neither
            var rows = [
                ['Date / time',              'submission timestamp (UTC)'],
                ['ISP name',                 esc(isp)],
                ['Country',                  esc(_state.ispInfo.country || _state.ispInfo.countryCode || '?')],
                ['ASN',                      esc(asn)],
                ['Auth type',                esc(at)],
                ['Auth method',              am ? esc(am) : 'NONE'],
                ['VLAN ID',                  esc(vlan)],
                ['MAC clone needed',         mac       ? 'Yes' : 'No'],
                ['Username capturable',      userFound ? 'Yes — PAP cleartext' : 'No'],
                ['Password capturable',      passFound ? 'Yes — PAP cleartext' : 'No'],
                ['Auto-connected by wizard', 'Yes'],
                ['Attempts needed',          String(autotestData.attempts_done || 1)],
                ['OpenWrt version',          'from /etc/openwrt_release'],
            ];
            var tableHtml = rows.map(function(r) {
                return '<div class="db-submit-key">' + r[0] + '</div>' +
                       '<div class="db-submit-val">' + r[1] + '</div>';
            }).join('');

            var notSentRows = [
                'Usernames', 'Passwords', 'MAC addresses',
                'IP addresses', 'Any traffic content'
            ];

            wrap.style.display = 'block';
            wrap.innerHTML =
                '<div class="db-submit-panel">' +
                '<div class="db-submit-hdr">🌍 Share with the Community?</div>' +
                '<div class="db-submit-isp">Submitting a working config for ' +
                    '<strong style="color:var(--accent)">' + esc(isp) + '</strong>' +
                    (asn ? ' <span style="font-size:11px;color:var(--dim)">(' + esc(asn) + ')</span>' : '') +
                    ' helps others with the same ISP skip the trial-and-error.</div>' +

                '<div style="font-size:12px;color:var(--accent2);margin:10px 0 4px;' +
                    'text-transform:uppercase;letter-spacing:1px">✓ What will be sent:</div>' +
                '<div class="db-submit-detail">' + tableHtml + '</div>' +

                '<div style="font-size:12px;color:var(--danger);margin:10px 0 4px;' +
                    'text-transform:uppercase;letter-spacing:1px">✗ What will NOT be sent:</div>' +
                '<div style="font-size:12px;color:var(--dim);margin-bottom:14px">' +
                    notSentRows.join(' &bull; ') +
                '</div>' +

                '<div id="db-submit-result"></div>' +
                '<div class="btn-row" style="margin-top:0">' +
                    '<button class="wbtn wbtn-primary" onclick="window._doDbSubmit()" id="btnDbSubmit">' +
                        '📤 Submit' +
                    '</button>' +
                    '<button class="wbtn wbtn-ghost" ' +
                        'onclick="document.getElementById(\'db-submit-wrap\').style.display=\'none\'">' +
                        'No thanks' +
                    '</button>' +
                '</div>' +
                '</div>';

            window._doDbSubmit = function() {
                if (_state.dbSubmitted) return;
                var btn = document.getElementById('btnDbSubmit');
                if (btn) { btn.disabled = true; btn.textContent = 'Submitting...'; }

                callDbSubmit(
                    mac ? 'yes' : 'no',
                    autotestData.attempts_done || 1
                ).then(function() {
                    _state.dbSubmitted = true;
                    var resEl = document.getElementById('db-submit-result');
                    if (resEl) {
                        resEl.innerHTML =
                            '<div class="db-submitted">✓ Submitted — thank you! ' +
                            'Your config has been added to the community database.</div>';
                    }
                    var btnEl = document.getElementById('btnDbSubmit');
                    if (btnEl) btnEl.style.display = 'none';
                }).catch(function() {
                    var btn2 = document.getElementById('btnDbSubmit');
                    if (btn2) { btn2.disabled = false; btn2.textContent = '📤 Submit'; }
                });
            };
        };

        // ISP info arrives a few seconds after autotest success
        // (lookup_isp runs in background subshell after autotest)
        setTimeout(showPanel, 1500);
    },

    // ── Restore ────────────────────────────────────────────────────────────
    // OLD: action_restore() → run_script("restore")
    // NEW: callRestore() + callCleanup() — identical behaviour via rpcd
    doRestore: function() {
        var self = this;
        if (!confirm('Restore original WAN config and discard all captured settings?')) return;
        callRestore().then(function() {
            callCleanup();
            alert('Original configuration restored. Network restarting...');
            self.goStep(0);
        });
    },

    downloadPcap: function() {
        alert('PCAP at /tmp/isp-capture.pcap on your router.\n\nDownload:\n  scp root@192.168.1.1:/tmp/isp-capture.pcap .\n\nOpen in Wireshark for full analysis.');
    }
});
