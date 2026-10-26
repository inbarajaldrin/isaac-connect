// ViewerController — drives one window's WKWebView: the WebRTC stream from a single
// NVIDIA Isaac Sim workstation, plus its connect / watchdog / clean-disconnect logic.
// (One controller per window; AppDelegate owns the set.)
//
// The bundled renderer is served over a loopback HTTP server (file:// can't run its
// ES modules), then we drive its Connect form to the workstation and mute+play the
// video to autoplay.
//
// Key configuration:
//  - serve over http://127.0.0.1 (not file://)
//  - ATS NSAllowsArbitraryLoads (+InWebContent) for the insecure ws:// signaling
//  - mediaTypesRequiringUserActionForPlayback = [] and mute-then-play to autoplay
//  - WKUIDelegate.requestMediaCapturePermissionFor -> .grant
//
// Recovery: a watchdog reloads the renderer and re-drives the connect flow
// whenever the signaling WebSocket closes, the RTCPeerConnection fails, or the
// <video> stalls.

import AppKit
import WebKit

@MainActor
final class ViewerController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var webView: WKWebView!
    private let server: LocalServer
    private var serverPort: UInt16 = 0

    // The workstation whose stream this window views. 127.0.0.1 is ONLY the local
    // renderer host; the stream/signaling WebSocket targets workstation.host:port.
    // Per-controller (not global) so each window can view a different box.
    private(set) var workstation: Workstation

    // User explicitly disconnected this window — freeze the watchdog so it doesn't
    // auto-reconnect until the user switches/reconnects again.
    private var userPaused = false

    // True between a clean disconnect and the next load. The intentional pc.close()/
    // ws.close() posts pc_state=closed / ws_close health events; this flag tells the
    // handler to ignore them so a deliberate switch/reconnect/close isn't mistaken
    // for a dropped feed (which would schedule a competing reload).
    private var intentionallyDisconnecting = false

    // Fired when the target workstation changes OR the status note changes (so the
    // owning window retitles).
    var onWorkstationChange: (() -> Void)?

    // A short human note for the window title (e.g. "not running"), nil when live.
    private(set) var statusNote: String?

    // Connection lifecycle
    private var connected = false          // connect form successfully driven
    private var streaming = false          // a real video frame is flowing
    private var gotVideoTrack = false      // the media track arrived (signaling's job is done)
    private var reconnecting = false       // a reload/recover cycle is in flight
    private var reloadGeneration = 0       // bumps each reload to invalidate stale callbacks

    // Idle / event-based Linux→Mac link. The stream dropping tells us nothing about
    // WHY (sim finished vs. sim restarting), so after the blind reload retries fail
    // we ask the box `isaac-ctl status` over SSH: "stopped" → park (no more blind
    // reloading) and slow-poll for it to come back; "running" → keep re-acquiring.
    private var acquireFailures = 0        // consecutive no-video reload cycles
    private var probingStatus = false      // an isaac-ctl status probe is in flight
    private var remoteIdle = false         // parked: sim is down, heartbeat-polling
    private var heartbeat: Timer?          // slow status poll while idle
    private let probeAfter = 2             // reload failures before the first SSH probe
    private let blindGiveUp = 6            // reload failures before parking when no SSH
    private var hasSSH: Bool { !workstation.ssh.trimmingCharacters(in: .whitespaces).isEmpty }

    // Stall detection
    private var lastCurrentTime: Double = -1
    private var lastProgressAt = Date()
    private var loadedAt = Date()          // when the current renderer load happened
    private var watchdog: Timer?
    private let acquireTimeout: TimeInterval = ProcessInfo.processInfo.environment["ISAAC_ACQUIRE_TIMEOUT"].flatMap { Double($0) } ?? 8.0   // give up on a connect attempt that never yields video

    // Backoff for reconnect attempts
    private var backoff: TimeInterval = 1.0
    private let backoffMax: TimeInterval = 8.0

    private let verifyPath = ProcessInfo.processInfo.environment["ISAAC_VERIFY"]

    init(workstation: Workstation) {
        self.workstation = workstation
        let resBase = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        self.server = LocalServer(root: resBase.appendingPathComponent("Renderer", isDirectory: true))
        super.init()
    }

    func makeWebView(frame: NSRect) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = false

        let ucc = WKUserContentController()
        ucc.add(self, name: "isaac")

        // Document-start instrumentation:
        //  - mute+play the <video> so it autoplays
        //  - hook WebSocket + RTCPeerConnection and post health events to native,
        //    so the watchdog learns about drops (close 4001, ICE failed, etc.)
        let bootstrap = """
        (function(){
          function post(o){ try { window.webkit.messageHandlers.isaac.postMessage(JSON.stringify(o)); } catch(e){} }

          // Muted autoplay pump.
          setInterval(function(){
            var v = document.querySelector('video');
            if (v) { try { v.muted = true; if (v.paused) v.play().catch(function(){}); } catch(e){} }
          }, 1000);

          // WebSocket hook — report the signaling target + close/error.
          if (window.WebSocket && !window.__isaacWS) {
            window.__isaacWS = true;
            var OWS = window.WebSocket;
            window.WebSocket = function(url, protocols){
              post({ev:'ws_open_attempt', url:String(url)});
              var ws = protocols!==undefined ? new OWS(url, protocols) : new OWS(url);
              (window.__isaacWSList = window.__isaacWSList || []).push(ws);  // every signaling socket, for clean close
              ws.addEventListener('open',  function(){ post({ev:'ws_open', url:String(url)}); });
              ws.addEventListener('close', function(e){ post({ev:'ws_close', code:e.code, url:String(url)}); });
              ws.addEventListener('error', function(){ post({ev:'ws_error', url:String(url)}); });
              return ws;
            };
            window.WebSocket.prototype = OWS.prototype;
            window.WebSocket.CONNECTING=OWS.CONNECTING; window.WebSocket.OPEN=OWS.OPEN;
            window.WebSocket.CLOSING=OWS.CLOSING; window.WebSocket.CLOSED=OWS.CLOSED;
          }

          // RTCPeerConnection hook — report failed/disconnected/closed + first video track.
          if (window.RTCPeerConnection && !window.__isaacRTC) {
            window.__isaacRTC = true;
            var ORTC = window.RTCPeerConnection;
            window.RTCPeerConnection = function(cfg){
              var pc = new ORTC(cfg);
              (window.__isaacPCList = window.__isaacPCList || []).push(pc);  // every peer connection, for clean close
              pc.addEventListener('connectionstatechange', function(){
                post({ev:'pc_state', state:pc.connectionState});
              });
              pc.addEventListener('iceconnectionstatechange', function(){
                post({ev:'ice_state', state:pc.iceConnectionState});
              });
              pc.addEventListener('track', function(e){
                if (e.track && e.track.kind === 'video') post({ev:'video_track'});
              });
              return pc;
            };
            window.RTCPeerConnection.prototype = ORTC.prototype;
          }

          // Remote → Mac clipboard. NVIDIA's renderer receives the remote clipboard
          // over a WebRTC data channel but its own writeText path doesn't fire under
          // WKWebView. We intercept at the RTCDataChannel level — robust across which
          // channel the server uses — and hand the text to native (NSPasteboard needs
          // no user gesture). String fast-path only: the high-frequency cursor/stats
          // channels (binary) return immediately, so there's no per-message cost.
          if (window.RTCDataChannel && !window.__isaacDCHook) {
            window.__isaacDCHook = true;
            function findClip(v, depth){
              if (depth > 5 || v == null) return null;
              if (typeof v === 'string') {
                if (v.indexOf('clipboard_set') < 0) return null;
                // The server double-encodes; parsing the outer layer turns escaped
                // newlines into LITERAL control chars, which JSON forbids inside a
                // string — so a multi-line clipboard (e.g. the console log) throws.
                // Re-escape control chars first so multi-line copies parse.
                var safe = v.replace(/[\\u0000-\\u001F]/g, function(c){ return '\\\\u' + ('0000' + c.charCodeAt(0).toString(16)).slice(-4); });
                try { return findClip(JSON.parse(safe), depth+1); } catch(e){ return null; }
              }
              if (typeof v !== 'object') return null;
              if (typeof v.clipboard_set === 'string') return v.clipboard_set;
              var keys = ['customMessage','data','message','payload'];
              for (var i=0;i<keys.length;i++){ var f = findClip(v[keys[i]], depth+1); if (f != null) return f; }
              return null;
            }
            function inspect(ev){
              var raw = ev.data;
              if (typeof raw !== 'string') return;            // clipboard arrives as text; skip binary
              if (raw.indexOf('clipboard_set') < 0) return;
              var clip = findClip(raw, 0);
              if (clip != null) post({ev:'clipboard_write', text:clip});
              else post({ev:'clipboard_unparsed', sample:raw.slice(0,300)});
            }
            var proto = RTCDataChannel.prototype, origAdd = proto.addEventListener;
            proto.addEventListener = function(type, listener, opts){
              if (type === 'message' && !this.__isaacWatch){ this.__isaacWatch = true; origAdd.call(this, 'message', inspect); }
              return origAdd.call(this, type, listener, opts);
            };
            var omDesc = Object.getOwnPropertyDescriptor(proto, 'onmessage');
            if (omDesc && omDesc.configurable) {
              Object.defineProperty(proto, 'onmessage', {
                configurable:true, enumerable:omDesc.enumerable,
                get:function(){ return omDesc.get ? omDesc.get.call(this) : this.__isaacOnMsg; },
                set:function(fn){
                  if (!this.__isaacWatch){ this.__isaacWatch = true; origAdd.call(this, 'message', inspect); }
                  return omDesc.set ? omDesc.set.call(this, fn) : (this.__isaacOnMsg = fn);
                }
              });
            }
          }
        })();
        """
        ucc.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = ucc

        let wv = WKWebView(frame: frame, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.autoresizingMask = [.width, .height]
        // Black under-page background so load/reconnect never flashes white.
        // (Public API — replaces the old private drawsBackground KVC.)
        wv.underPageBackgroundColor = .black
        self.webView = wv
        return wv
    }

    func start() {
        guard let port = server.start() else {
            NSLog("IsaacConnect: failed to start local server")
            return
        }
        serverPort = port
        NSLog("IsaacConnect: renderer host http://127.0.0.1:\(port); stream target \(workstation.host):\(workstation.port) [\(workstation.name)]")
        loadRenderer()   // arms the watchdog
        installDropSimulatorIfRequested()
    }

    // Debug-only: when ISAAC_SIM_DROP is set, SIGUSR1 closes all PeerConnections
    // in the page to simulate a mid-stream drop (stage change / session taken),
    // so recovery can be tested without disturbing the workstation. Off by default.
    private func installDropSimulatorIfRequested() {
        guard ProcessInfo.processInfo.environment["ISAAC_SIM_DROP"] != nil else { return }
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        signal(SIGUSR1, SIG_IGN)
        src.setEventHandler { [weak self] in
            NSLog("IsaacConnect: SIGUSR1 — simulating stream drop (closing PeerConnections)")
            self?.webView.evaluateJavaScript("(()=>{try{performance.getEntries; const vs=document.querySelectorAll('video'); vs.forEach(v=>{try{v.srcObject=null;}catch(e){}}); return 'dropped';}catch(e){return String(e);}})()") { _, _ in }
        }
        src.resume()
        self.dropSimSource = src
    }
    private var dropSimSource: DispatchSourceSignal?

    private func loadRenderer() {
        // A row with no host yet (fresh "Add" in Settings) has nothing to connect
        // to — don't load + acquire-timeout-reload in a loop against "".
        let host = workstation.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            NSLog("IsaacConnect: workstation \(workstation.name) has no host configured — idle")
            watchdog?.invalidate(); watchdog = nil
            return
        }
        exitIdle()                           // any load supersedes a parked/idle state
        // NOTE: do NOT reset acquireFailures here — it must accumulate ACROSS reload
        // attempts so repeated failures reach the status-probe threshold. It's reset
        // only on a healthy frame, a user action (reconnect/retarget), or exitIdle.
        connected = false
        streaming = false
        gotVideoTrack = false                // fresh load — signaling matters again
        reconnecting = false                 // this attempt is now underway — a fresh
                                             // failure event may schedule the next one
        intentionallyDisconnecting = false   // a fresh load — health events matter again
        lastCurrentTime = -1
        lastProgressAt = Date()
        loadedAt = Date()
        reloadGeneration += 1
        startWatchdog()                      // (re)arm — it's stopped while disconnected
        let url = URL(string: "http://127.0.0.1:\(serverPort)/index.html")!
        webView.load(URLRequest(url: url))
    }

    // MARK: WKUIDelegate
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // MARK: health events from the page
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String,
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ev = obj["ev"] as? String else { return }
        switch ev {
        case "ws_open_attempt":
            if let url = obj["url"] as? String { NSLog("IsaacConnect: signaling WS -> \(url)") }
        case "ws_close":
            let code = (obj["code"] as? Int) ?? -1
            // The signaling WebSocket ONLY carries the initial SDP/ICE handshake.
            // Once the media track has arrived, the NVIDIA SDK deliberately tears
            // signaling down (its own `uninitialize(4001)`) — that close is EXPECTED,
            // not a drop, so reloading on it throws away a working peer connection
            // (the root cause of the spurious "reload once then stream" cycle). A real
            // post-connection drop surfaces as pc_state failed/disconnected or a video
            // stall. So only treat a signaling close as a failure BEFORE media is up
            // (session-not-ready / box-down), where it's the retry/probe signal.
            NSLog("IsaacConnect: WS close code=\(code)\(gotVideoTrack ? " (post-negotiation — expected, ignoring)" : "")")
            if !intentionallyDisconnecting && !gotVideoTrack { triggerRecover(reason: "ws_close \(code)") }
        case "ws_error":
            // Same rule: a signaling error only matters before media is negotiated
            // (server still down during a reconnect attempt). After that, ignore it.
            if !intentionallyDisconnecting && !gotVideoTrack { triggerRecover(reason: "ws_error") }
        case "pc_state", "ice_state":
            if let st = obj["state"] as? String,
               st == "failed" || st == "disconnected" || st == "closed" {
                NSLog("IsaacConnect: \(ev)=\(st)")
                // Ignore the close we ourselves triggered during a switch/reconnect/quit.
                if !intentionallyDisconnecting && (streaming || ev == "pc_state") {
                    triggerRecover(reason: "\(ev) \(st)")
                }
            }
        case "video_track":
            gotVideoTrack = true   // signaling has done its job; its close is now expected
            NSLog("IsaacConnect: video track received")
        case "clipboard_write":
            // Remote clipboard arrived over the data channel — write it to the Mac
            // pasteboard (the renderer's own writeText path doesn't fire in WKWebView).
            if let text = obj["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                NSLog("IsaacConnect: clipboard ← remote (\(text.count) chars)")
            }
        case "clipboard_unparsed":
            NSLog("IsaacConnect: clipboard_set seen but not parsed — sample: \(obj["sample"] ?? "?")")
        default: break
        }
    }

    // MARK: navigation
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !connected else { return }
        let gen = reloadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, gen == self.reloadGeneration else { return }
            self.driveConnect(attempt: 0, gen: gen)
        }
    }

    private func driveConnect(attempt: Int, gen: Int) {
        guard gen == reloadGeneration, !connected, attempt < 15 else { return }
        // Embed the host as a JSON string literal so a quote/backslash/odd character
        // in the host can't break (or inject into) the script.
        let hostLiteral = (try? String(data: JSONEncoder().encode(workstation.host), encoding: .utf8)) ?? "\"\""
        let js = """
        (() => { const i = document.querySelector('input[type="text"]'); if(!i) return 'no input';
          const s = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
          s.call(i, \(hostLiteral)); i.dispatchEvent(new Event('input',{bubbles:true}));
          const b=[...document.querySelectorAll('button')].find(x=>x.textContent.trim()==='Connect');
          if(!b) return 'no button'; b.click(); return 'ok'; })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, gen == self.reloadGeneration else { return }
            if (result as? String) == "ok" {
                self.connected = true
                NSLog("IsaacConnect: connect form driven -> \(self.workstation.host) [\(self.workstation.name)]")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.driveConnect(attempt: attempt + 1, gen: gen)
                }
            }
        }
    }

    // MARK: watchdog (polls <video>, detects stall / no-video, drives verify log)
    // Runs only while a stream is (supposed to be) live: armed by loadRenderer,
    // stopped on user disconnect/teardown so idle windows cost no JS evals.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let js = """
                (()=>{const v=document.querySelector('video'); if(!v) return JSON.stringify({video:false});
                  return JSON.stringify({srcObject:!!v.srcObject,paused:v.paused,readyState:v.readyState,videoWidth:v.videoWidth,videoHeight:v.videoHeight,currentTime:v.currentTime});})()
                """
                self.webView.evaluateJavaScript(js) { [weak self] result, _ in
                    guard let self = self else { return }
                    let str = (result as? String) ?? "nil"
                    if let path = self.verifyPath { self.appendVerify(path, str) }
                    if self.userPaused { return }   // user disconnected this window — no auto-recover
                    guard let data = str.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    let vw = (o["videoWidth"] as? Double) ?? (o["videoWidth"] as? Int).map(Double.init) ?? 0
                    let ct = (o["currentTime"] as? Double) ?? 0
                    let rs = (o["readyState"] as? Double) ?? (o["readyState"] as? Int).map(Double.init) ?? 0

                    let healthyFrame = vw > 0 && rs >= 2
                    if healthyFrame && ct > self.lastCurrentTime {
                        // Progressing → healthy. Mark streaming, reset stall + backoff +
                        // the acquire-failure counter (a good frame means the box is up).
                        if !self.streaming { NSLog("IsaacConnect: streaming live (\(Int(vw))x\(Int((o["videoHeight"] as? Double) ?? 0)))") }
                        self.streaming = true
                        self.reconnecting = false
                        self.backoff = 1.0
                        self.acquireFailures = 0
                        self.lastProgressAt = Date()
                    }
                    self.lastCurrentTime = ct

                    if self.streaming {
                        // Stall: we were streaming but currentTime hasn't advanced, or video vanished.
                        let stalledFor = Date().timeIntervalSince(self.lastProgressAt)
                        if stalledFor > 3.0 || !healthyFrame {
                            self.triggerRecover(reason: "video stall (\(String(format: "%.1f", stalledFor))s, vw=\(Int(vw)))")
                        }
                    } else if !self.reconnecting {
                        // Acquisition timeout: signaling connected but the server never
                        // produced a video frame. triggerRecover counts the failure and,
                        // after a few, asks the box status instead of looping forever.
                        let waitedFor = Date().timeIntervalSince(self.loadedAt)
                        if waitedFor > self.acquireTimeout {
                            self.triggerRecover(reason: "no video within \(String(format: "%.0f", waitedFor))s of load")
                        }
                    }
                }
            }
        }
    }

    // MARK: recovery
    // The single funnel for EVERY failure signal — ws_close/ws_error, pc/ice failed,
    // video stall, and no-video acquire timeout all land here. It counts consecutive
    // failures; a few blind reloads ride out a stream re-acquire or quick restart,
    // but past a threshold it stops guessing and asks the box `isaac-ctl status`
    // (the event-based Linux→Mac link) rather than redrawing at a dead endpoint.
    private func triggerRecover(reason: String) {
        guard !reconnecting, !userPaused, !remoteIdle else { return }
        reconnecting = true
        streaming = false
        acquireFailures += 1
        if hasSSH && acquireFailures >= probeAfter {
            NSLog("IsaacConnect: RECOVER — \(reason); asking \(workstation.name) status (attempt \(acquireFailures))")
            probeThenRecover(reason: reason)
        } else if !hasSSH && acquireFailures >= blindGiveUp {
            enterIdle(reason: "no signal")   // can't ask; stop looping until user acts
        } else {
            scheduleReload(reason: reason)
        }
    }

    private func scheduleReload(reason: String) {
        NSLog("IsaacConnect: RECOVER — \(reason); reloading in \(String(format: "%.1f", backoff))s")
        let delay = backoff
        backoff = min(backoff * 2, backoffMax)
        let gen = reloadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Skip if paused, if a newer user action bumped the generation, or if the
            // stream already recovered while this retry was pending (don't reload over
            // a negotiation that just succeeded).
            guard let self = self, !self.userPaused, !self.streaming, !self.remoteIdle,
                  gen == self.reloadGeneration else { return }
            // Clean-disconnect BEFORE reloading. A plain page reload tears the peer
            // connection + signaling socket down WITHOUT close frames, orphaning the
            // server's single session slot — so the next attempt signs in as a new
            // peer while the server still holds the last one, gets no video, times
            // out, and orphans again (the multi-attempt thrash before first frame).
            // Closing cleanly frees the slot so the very next attempt can acquire it.
            self.disconnectCleanly { [weak self] in self?.loadRenderer() }
        }
    }

    // MARK: event-based Linux→Mac status link

    /// Ask the box `isaac-ctl status`; "running" → the sim is up, keep re-acquiring
    /// the stream; "stopped"/unreachable → park (stop the blind reload loop). This
    /// is what turns "the stream dropped" into a definite answer instead of an
    /// endless redraw.
    private func probeThenRecover(reason: String) {
        guard !probingStatus else { return }
        probingStatus = true
        let w = workstation
        RemoteLauncher.run(verb: "status", on: w) { [weak self] r in
            guard let self = self, self.workstation.id == w.id, !self.userPaused else { return }
            self.probingStatus = false
            let out = r.output.lowercased()
            // "running" = sim is up (pidfile alive) even mid-boot before :49100 opens,
            // so keep re-acquiring. "stopped"/unreachable = park. (reconnecting is
            // still true here, so schedule the reload directly — not via triggerRecover.)
            if out.contains("running") {
                self.acquireFailures = 0
                self.scheduleReload(reason: reason + " (box up — retrying)")
            } else if out.contains("stopped") {
                self.enterIdle(reason: "not running")
            } else {
                self.enterIdle(reason: "unreachable")   // ssh error / offline box
            }
        }
    }

    /// Park the window: stop blindly reloading, note it in the title, and (when we
    /// have SSH) slow-poll so the stream is picked up automatically the moment the
    /// sim is relaunched — from the Mac menu OR directly on Linux.
    private func enterIdle(reason: String) {
        guard !remoteIdle, !userPaused else { return }
        remoteIdle = true
        reconnecting = false
        streaming = false
        statusNote = reason
        NSLog("IsaacConnect: idle (\(reason)) on \(workstation.name) — stopped blind reloads\(hasSSH ? "; heartbeat-polling for relaunch" : "")")
        onWorkstationChange?()
        watchdog?.invalidate(); watchdog = nil
        if hasSSH { startHeartbeat() }
    }

    private func exitIdle() {
        guard remoteIdle else { return }
        remoteIdle = false
        statusNote = nil
        acquireFailures = 0
        heartbeat?.invalidate(); heartbeat = nil
        onWorkstationChange?()
    }

    /// While idle, poll `isaac-ctl status` slowly; on "running" resume the stream.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.remoteIdle, !self.userPaused, !self.probingStatus else { return }
                self.probingStatus = true
                let w = self.workstation
                RemoteLauncher.run(verb: "status", on: w) { [weak self] r in
                    guard let self = self, self.workstation.id == w.id else { return }
                    self.probingStatus = false
                    if self.remoteIdle, !self.userPaused, r.output.lowercased().contains("running") {
                        NSLog("IsaacConnect: \(self.workstation.name) is up again — reconnecting")
                        self.exitIdle()
                        self.loadRenderer()   // re-arms the watchdog
                    }
                }
            }
        }
    }

    // MARK: target control (switch / reconnect / disconnect)

    /// Gracefully close the live signaling WebSocket + RTCPeerConnection so the
    /// server sees NVST_CCE_DISCONNECTED and frees its single-session slot. A plain
    /// page reload tears the same objects down WITHOUT a close frame, which orphans
    /// the slot (the bug that blocked every reconnect this session). `completion`
    /// runs after a short flush delay so the close frame actually leaves the socket.
    func disconnectCleanly(completion: (() -> Void)? = nil) {
        let js = """
        (()=>{ try{ (window.__isaacPCList||[]).forEach(function(p){ try{ p.close(); }catch(e){} }); }catch(e){}
               try{ (window.__isaacWSList||[]).forEach(function(w){ try{ w.close(1000,'client closing'); }catch(e){} }); }catch(e){}
               try{ var v=document.querySelector('video'); if(v){ v.srcObject=null; } }catch(e){}
               return 'bye'; })()
        """
        reloadGeneration += 1   // invalidate any in-flight connect/recover callbacks
        streaming = false
        connected = false
        intentionallyDisconnecting = true   // suppress recovery on our own pc/ws close
        // Closing the RTCPeerConnection sends the DTLS/ICE teardown the server keys
        // NVST_CCE_DISCONNECTED off of. Give those packets time to leave WebKit's
        // network process before we reload/quit; the 0.8s delay lets the teardown
        // flush so the server frees the session slot.
        webView?.evaluateJavaScript(js) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { completion?() }
    }

    /// Switch this window to a different workstation: clean-disconnect the current
    /// box FIRST (so its slot frees), then point the renderer at the new one.
    func retarget(to w: Workstation) {
        guard w.id != workstation.id || userPaused else { reconnect(); return }
        NSLog("IsaacConnect: retarget \(workstation.name) → \(w.name)")
        // Update the target identity synchronously so the title + menu reflect the
        // new box immediately; only the actual reconnect waits for the disconnect
        // flush. (disconnectCleanly closes the live page's JS objects — it doesn't
        // need the old workstation value.)
        workstation = w
        userPaused = false
        backoff = 1.0
        acquireFailures = 0   // fresh user intent — start the failure count over
        onWorkstationChange?()
        disconnectCleanly { [weak self] in
            self?.loadRenderer()
        }
    }

    /// Force a fresh connection to the current workstation.
    func reconnect() {
        NSLog("IsaacConnect: reconnect \(workstation.name)")
        disconnectCleanly { [weak self] in
            guard let self = self else { return }
            self.userPaused = false
            self.backoff = 1.0
            self.acquireFailures = 0   // fresh user intent — start the failure count over
            self.loadRenderer()
        }
    }

    /// Drop this window's stream and stay disconnected (watchdog + heartbeat stopped)
    /// until the user reconnects or switches.
    func disconnect(completion: (() -> Void)? = nil) {
        NSLog("IsaacConnect: disconnect \(workstation.name)")
        userPaused = true
        watchdog?.invalidate(); watchdog = nil   // idle window — no 1s JS polling
        heartbeat?.invalidate(); heartbeat = nil // and no status polling
        remoteIdle = false
        if statusNote != nil { statusNote = nil; onWorkstationChange?() }
        disconnectCleanly(completion: completion)
    }

    /// Permanently release this controller's resources (window closed / app quit).
    /// WKUserContentController strongly retains its script handler and LocalServer's
    /// accept loop runs until stopped, so without this a closed window leaks its
    /// controller, web view, and loopback server. Call AFTER a clean disconnect.
    func teardown() {
        watchdog?.invalidate(); watchdog = nil
        heartbeat?.invalidate(); heartbeat = nil
        dropSimSource?.cancel(); dropSimSource = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "isaac")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        server.stop()
    }

    private func appendVerify(_ path: String, _ line: String) {
        let entry = "[\(Date())] \(line)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(Data(entry.utf8)); try? fh.close()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
