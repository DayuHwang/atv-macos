// SPDX-License-Identifier: GPL-2.0-or-later
// atv-macos: a tiny HTTP page on the Apple TV (port 8080) so the host can be
// followed from the PC with no TV attached: GET / (a page), /status (JSON),
// /log (the last 64 KB of atv.log). It reveals no secrets.
import Foundation
import Network

final class StatusServer {
    static let shared = StatusServer()
    static let port: UInt16 = 8080
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "atv.status")

    func start() {
        guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            Log.line("status", "cannot listen on \(Self.port)")
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
        listener = l
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let (type, body): (String, Data)
            switch path {
            case "/status":
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                (type, body) = ("application/json", (try? enc.encode(Host.shared.status)) ?? Data())
            case "/log":
                (type, body) = ("text/plain; charset=utf-8", Data(Log.tail().utf8))
            default:
                (type, body) = ("text/html; charset=utf-8", Data(Self.page.utf8))
            }
            var head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            var out = Data(head.utf8); out.append(body)
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    private static let page = """
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>atv-macos</title>
    <style>body{font:15px -apple-system,system-ui,sans-serif;margin:24px;background:#111318;color:#e8e8ea}
    h1{font-size:20px}pre{background:#1b1e25;padding:12px;border-radius:8px;overflow:auto;max-height:60vh;font-size:12px}
    .bar{height:10px;background:#333;border-radius:5px;overflow:hidden;max-width:520px}.bar div{height:100%;background:#5a9eff}</style>
    <h1>atv-macos</h1><div id="s">…</div><div class="bar"><div id="p" style="width:0"></div></div>
    <h2 style="font-size:16px">Log</h2><pre id="l"></pre>
    <script>
    async function tick(){try{const s=await (await fetch('/status')).json();
    document.getElementById('s').textContent=s.phase+' — '+s.detail+' (free '+s.freeGB.toFixed(1)+' GB'+(s.guestRAMMB?', RAM '+s.guestRAMMB+' MB':'')+(s.cpusOn?', CPUs on '+s.cpusOn:'')+')';
    document.getElementById('p').style.width=((s.progress||0)*100)+'%';
    const l=document.getElementById('l');const at=l.scrollTop+l.clientHeight>=l.scrollHeight-4;
    l.textContent=await (await fetch('/log')).text();if(at)l.scrollTop=l.scrollHeight;}catch(e){}}
    tick();setInterval(tick,2000);
    </script>
    """
}
