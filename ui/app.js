// Technitium's tabs on the chassis window: Blocking, Zones, Resolvers, Setup, and the HTTPS part of Site address.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  function tnUrl(st) { return ((st.app || {}).url || "").replace(/\/$/, ""); }
  function num(n) { return (n || 0).toLocaleString(); }
  function empty(tb, text, span) { var r = P.el("tr"), c = P.cell(text, "empty"); c.colSpan = span || 1; r.appendChild(c); tb.appendChild(r); }
  function apiNote(a) { return a.up && a.api === false ? "The package's API token isn't accepted by Technitium (a restore from another install?) — the window can't manage it; Technitium itself keeps working." : ""; }

  // The overview's own tiles: what Technitium did in the last 24 hours.
  P.register("overview", { tiles: function (t, st) { var s = (st.app || {}).stats || {}; P.tile(t, num(s.queries), "lookups (24 h)"); P.tile(t, num(s.blocked), "blocked (24 h)"); } });

  // ---------------------------------------------------------------- Blocking
  P.register("blocking", {
    render: function (st) {
      var a = st.app || {}, s = a.stats || {}, b = a.blocking || {}, t = $("bl-tiles");
      document.querySelectorAll(".tn-link").forEach(function (x) { x.href = tnUrl(st) || "#"; });
      P.clear(t); P.tile(t, num(s.queries), "lookups"); P.tile(t, num(s.blocked), "blocked");
      P.tile(t, (s.queries ? Math.round(s.blocked * 1000 / s.queries) / 10 : 0) + "%", "of lookups blocked"); P.tile(t, num(s.clients), "devices"); P.tile(t, num(s.list_domains), "domains on blocklists");
      var st2 = $("bl-state"), acts = $("bl-acts"); P.clear(st2); P.clear(acts);
      var paused = !b.enabled && b.until && b.until * 1000 > Date.now();
      st2.appendChild(b.enabled ? P.chip("blocking", "ok") : P.chip(paused ? "paused" : "off", "warn"));
      if (paused) st2.appendChild(document.createTextNode("  back on in " + Math.max(1, Math.ceil((b.until * 1000 - Date.now()) / 60000)) + " min"));
      else if (!b.enabled) st2.appendChild(document.createTextNode("  until you turn it on"));
      if (apiNote(a)) st2.appendChild(P.el("p", apiNote(a), "muted small"));
      if (b.enabled) {
        [[5, "Pause 5 minutes"], [30, "30 minutes"], [60, "1 hour"]].forEach(function (p) { acts.appendChild(P.btn(p[1], "", function () { P.act("pause", { minutes: p[0] }); })); });
        acts.appendChild(P.btn("Turn off", "", function () { P.act("blocking", { on: 0 }, "Turn blocking off until you turn it on again?"); }));
      } else acts.appendChild(P.btn("Turn blocking on", "primary", function () { P.act("blocking", { on: 1 }); }));
      $("ls-when").textContent = (a.lists || []).length ? "Fetched again every " + (a.list_hours || 24) + " hours." : "";
      var tl = $("ls-lists"), lists = a.lists || [], sig = JSON.stringify(lists) + "|" + P.busy + "|" + P.role; if (tl.dataset.sig !== sig) {
        tl.dataset.sig = sig; P.clear(tl);
        if (!lists.length) empty(tl, "No blocklists — nothing is blocked except your own sites below.", 2);
        lists.forEach(function (u) { P.row(tl, [P.cell(P.el("span", u, "dom")), P.cell(P.btn("Remove", "danger", function () { P.act("listdel", { url: u }, "Remove this blocklist?"); }), "n")]); });
      }
      var td = $("ls-domains"), doms = (a.blocked || []).map(function (d) { return { d: d, k: "block" }; }).concat((a.allowed || []).map(function (d) { return { d: d, k: "allow" }; }));
      var sig2 = JSON.stringify(doms) + "|" + P.busy + "|" + P.role; if (td.dataset.sig !== sig2) {
        td.dataset.sig = sig2; P.clear(td);
        if (!doms.length) empty(td, "None yet.", 3);
        doms.forEach(function (x) {
          P.row(td, [P.cell(P.el("span", x.d, "dom")), x.k === "allow" ? P.chip("always allowed", "ok") : P.chip("always blocked", "warn"),
            P.cell(P.btn("Remove", "", function () { P.act("domaindel", { kind: x.k, domain: x.d }); }), "n")]);
        });
      }
      var tt = $("bl-top"), top = a.top || [], sig3 = JSON.stringify(top); if (tt.dataset.sig !== sig3) {
        tt.dataset.sig = sig3; P.clear(tt);
        if (!top.length) empty(tt, "Nothing blocked yet — point your network at Technitium (Setup tab).");
        top.forEach(function (d) { P.row(tt, [P.cell(P.el("span", d.domain, "dom")), P.cell(P.el("span", num(d.count) + "×", "muted"), "n")]); });
      }
    }
  });
  $("ls-add").onclick = function () { P.act("listadd", { url: $("ls-url").value.trim() }).then(function () { $("ls-url").value = ""; }); };
  $("dm-allow").onclick = function () { P.act("domainadd", { kind: "allow", domain: $("dm-name").value.trim() }).then(function () { $("dm-name").value = ""; }); };
  $("dm-block").onclick = function () { P.act("domainadd", { kind: "block", domain: $("dm-name").value.trim() }).then(function () { $("dm-name").value = ""; }); };

  // ---------------------------------------------------------------- Zones
  P.register("zones", {
    render: function (st) {
      var a = st.app || {}, zones = a.zones || [], tb = $("zn-list");
      if (!$("rc-value").dataset.touched && !$("rc-value").value && (a.dns || {}).ip) $("rc-value").placeholder = a.dns.ip;
      var sig = JSON.stringify(zones) + "|" + P.busy + "|" + P.role; if (tb.dataset.sig === sig) return;
      tb.dataset.sig = sig; P.clear(tb);
      if (!zones.length) { empty(tb, "No zones yet. Add a name above — for this Synology, try nas.home → " + ((a.dns || {}).ip || "its address") + ".", 4); return; }
      zones.forEach(function (z) {
        var head = P.row(tb, [P.cell(z.name), P.cell(P.el("span", (z.type || "") + (z.disabled ? ", disabled" : ""), "muted small")), "",
          P.cell(P.btn("Delete zone", "danger", function () { P.act("zonedel", { zone: z.name }, "Delete the zone " + z.name + " and every name in it?"); }), "n")]);
        head.className = "zone-row";
        var recs = z.records || [];
        if (!recs.length) empty(tb, "No names in it.", 4);
        recs.forEach(function (r) {
          var canDel = /^(A|AAAA|CNAME)$/.test(r.type);
          var tr = P.row(tb, [P.cell(P.el("span", r.name, "dom")), r.type, P.cell(P.el("span", r.value || "–", "dom")),
            P.cell(canDel ? P.btn("Remove", "", function () { P.act("recdel", { name: r.name, type: r.type, value: r.value }, "Remove " + r.name + " → " + r.value + "?"); }) : P.el("span", "in the console", "muted small"), "n")]);
          if (r.disabled) tr.className = "muted-row";
        });
      });
    }
  });
  $("rc-value").addEventListener("input", function () { $("rc-value").dataset.touched = "1"; });
  $("rc-type").addEventListener("change", function () { $("rc-value").placeholder = $("rc-type").value === "CNAME" ? "nas.home" : $("rc-type").value === "AAAA" ? "fd00::20" : "192.168.1.20"; });
  $("rc-add").onclick = function () {
    var v = $("rc-value").value.trim() || ($("rc-type").value === "A" ? $("rc-value").placeholder : "");
    P.act("recadd", { name: $("rc-name").value.trim(), type: $("rc-type").value, value: v }).then(function () { $("rc-name").value = ""; $("rc-value").value = ""; $("rc-value").dataset.touched = ""; });
  };

  // ---------------------------------------------------------------- Resolvers
  function rvShow() {
    var fwd = $("rv-mode").value === "forward", custom = $("rv-up").value === "custom";
    $("rv-fwd").hidden = !fwd; $("rv-custom-row").hidden = !custom; $("rv-proto-row").hidden = custom;
    $("rv-hint").textContent = !fwd ? "Recursive: no single company sees all your lookups, but each website's own DNS servers see them unencrypted, and the first lookups of a name are a little slower."
      : custom ? "Your own servers are asked over plain DNS." : $("rv-proto").value === "udp" ? "Plain DNS can be read and changed on the way; the encrypted protocols can't." : "Encrypted: your internet provider can't see or change your lookups.";
  }
  ["rv-mode", "rv-up", "rv-proto", "rv-custom"].forEach(function (id) { ["input", "change"].forEach(function (e) { $(id).addEventListener(e, function () { $(id).dataset.touched = "1"; rvShow(); }); }); });
  P.register("resolvers", {
    render: function (st) {
      var r = (st.app || {}).resolver || {};
      if (!$("rv-mode").dataset.touched) $("rv-mode").value = r.mode || "forward";
      if (!$("rv-up").dataset.touched) $("rv-up").value = r.upstream || "cloudflare";
      if (!$("rv-proto").dataset.touched) $("rv-proto").value = r.proto || "https";
      if (!$("rv-custom").dataset.touched) $("rv-custom").value = (r.custom || []).join(" ");
      rvShow();
      var tb = $("rv-now"); P.clear(tb);
      var fw = r.forwarders || [];
      P.kv(tb, "Mode", fw.length ? "forwarding" : "recursive");
      if (fw.length) { P.kv(tb, "Asks", fw.join(", ")); P.kv(tb, "Protocol", { Https: "DNS-over-HTTPS (encrypted)", Tls: "DNS-over-TLS (encrypted)", Udp: "plain DNS", Tcp: "plain DNS over TCP", Quic: "DNS-over-QUIC (encrypted)" }[r.protocol] || r.protocol || "–"); }
    }
  });
  $("rv-save").onclick = function () {
    P.act("resolver", { mode: $("rv-mode").value, upstream: $("rv-up").value, proto: $("rv-proto").value, custom: $("rv-custom").value.trim() })
      .then(function () { ["rv-mode", "rv-up", "rv-proto", "rv-custom"].forEach(function (id) { $(id).dataset.touched = ""; }); });
  };

  // ---------------------------------------------------------------- Setup
  P.register("setup", {
    render: function (st) {
      var d = (st.app || {}).dns || {};
      $("su-dns").textContent = (d.ip || "") + (d.port && d.port !== 53 ? " (port " + d.port + ")" : "");
      $("su-port").textContent = d.port && d.port !== 53 ? "Technitium answers on port " + d.port + " here — most routers and devices can only use port 53." : "";
    }
  });
  P.register("secretNote", function () { return "For Technitium's web console, user admin. Keep it in your password manager."; });

  // ---------------------------------------------------------------- Site address: HTTPS
  P.register("site", {
    fill: function (st) { var a = st.app || {}, t = a.tls || {}; $("set-tls").value = t.mode || "off"; $("set-net").value = (a.net && a.net.mode) || "bridge"; },
    values: function () { return { tls: $("set-tls").value, net: $("set-net").value }; },
    render: function (st) {
      var t = (st.app && st.app.tls) || {}, c = t.cert, tb = $("tls-info"), note = $("tls-note"), acts = $("tls-actions"); P.clear(tb); P.clear(acts);
      $("tls-card").hidden = !t.mode || t.mode === "off";
      if (!t.mode || t.mode === "off") return;
      if (!c) { P.kv(tb, "Certificate", "none yet — it's made or read when Technitium starts"); note.textContent = ""; return; }
      P.kv(tb, "From", t.source === "dsm" ? "DSM (the system default certificate)" : "the package (self-signed)");
      P.kv(tb, "Issued to", c.subject || "–"); P.kv(tb, "Issued by", c.self_signed ? "itself (self-signed)" : (c.issuer || "–"));
      P.kv(tb, "Expires", (c.expires || "–") + (typeof c.days_left === "number" ? " (" + (c.days_left < 0 ? "expired" : c.days_left + " days") + ")" : ""));
      if (c.names) P.kv(tb, "Names", c.names.replace(/,/g, ", "));
      note.textContent = t.mode === "dsm" && t.source === "self" ? "DSM's certificate wasn't found on this system, so a self-signed one is in use."
        : c.self_signed ? "Self-signed: browsers warn once. For no warning, use a trusted certificate (Let's Encrypt in DSM, made the system default)."
        : "Browsers trust this certificate as long as they reach Technitium by one of its names.";
      acts.appendChild(P.btn(t.mode === "dsm" ? "Read DSM's certificate again" : "Put the certificate in place again", "", function () { P.act("refreshcert", {}); }));
    }
  });
  $("set-tls").addEventListener("change", function () { $("set-url").dataset.touched = "1"; var u = $("set-url").value.trim(); if ($("set-tls").value !== "off" && /^http:\/\//.test(u)) $("set-url").value = "https://" + u.slice(7); });

  // ---------------------------------------------------------------- Storage
  P.register("storage", { render: function (app, st, box) {
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "Technitium's data")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    [["Blocklists", app.blocklists], ["Zones", app.zones], ["Statistics", app.stats]].forEach(function (p) { P.kv(tb, p[0], P.mb(p[1] || 0), true); });
    box.appendChild(c);
  } });
})(window.Panel);
