import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Ui
import qs.Commons

// GitHub metrics panel. Fetching, history, diffs and alerts live in the daemon
// behind Service.qml; this widget renders its state.
Panel {
  id: root
  moduleName: "grivera.github"
  ipcTarget: "grivera.github"
  manageIpc: false

  // Panel commands plus status(), which voice assistants (Jarvis) and scripts
  // read: `omarchy-shell grivera.github status`.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return JSON.stringify(root.statusSummary()) }
  }

  readonly property var svc: root.bar && root.bar.shell ? root.bar.shell.serviceFor("grivera.github") : null
  readonly property var st: svc ? svc.state : ({})
  readonly property var config: svc ? svc.config : ({})
  readonly property var user: svc ? svc.user : ({})
  readonly property var contrib: svc ? svc.contrib : ({})
  readonly property var totals: svc ? svc.totals : ({})
  readonly property var repos: svc ? svc.repos : []
  readonly property var activity: svc ? svc.activity : []
  readonly property var inbox: svc ? svc.inbox : ({})
  readonly property var notes: svc ? svc.notifications : []
  readonly property var market: svc ? svc.market : []
  readonly property var mtot: svc ? svc.marketTotals : ({})
  readonly property int unseen: svc ? svc.unseen : 0
  // What changed since the panel was last closed (see look_deltas in the daemon).
  readonly property var look: st.sinceLook || ({ since: 0 })
  readonly property var lookD: look.deltas || ({})
  function lookChips() {
    var d = lookD, out = []
    function add(n, one, many, tab, glyph) { if (n) out.push({ text: (n > 0 ? "+" : "−") + fmt(Math.abs(n)) + " " + (Math.abs(n) === 1 ? one : many), tab: tab, glyph: glyph || "" }) }
    add(d.cloners, "cloner", "cloners", "repos", cloneGlyph)
    add(d.visitors, "visitor", "visitors", "repos", eyeGlyph)
    add(d.copies, "install copy", "install copies", "plugins", copyGlyph)
    add(d.hearts, "heart", "hearts", "plugins", heartGlyph)
    add(d.stars, "star", "stars", "repos", starGlyph)
    add(d.forks, "fork", "forks", "repos", forkGlyph)
    add(d.followers, "follower", "followers", "activity", followGlyph)
    add(d.contributions, "contribution", "contributions", "overview", ghGlyph)
    add(d.pageViews, "marketplace view", "marketplace views", "plugins", eyeGlyph)
    if (look.events) out.push({ text: plural(look.events, "new event"), tab: "activity", glyph: bellGlyph })
    return out
  }
  readonly property bool hasData: !!user.login

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.10)
  readonly property color wash: Qt.rgba(fg.r, fg.g, fg.b, 0.04)
  readonly property color accent: Color.accent
  readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
  readonly property color go: "#3fb950"
  readonly property color warn: "#d29922"
  readonly property color gold: "#e3b341"
  readonly property color pink: "#f778ba"
  readonly property color purple: "#a371f7"
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  readonly property string ghGlyph: String.fromCodePoint(0xF02A4)
  readonly property string starGlyph: String.fromCodePoint(0xF04CE)
  readonly property string forkGlyph: String.fromCodePoint(0xF0641)
  readonly property string eyeGlyph: String.fromCodePoint(0xF0208)
  readonly property string cloneGlyph: String.fromCodePoint(0xF01DA)
  readonly property string heartGlyph: String.fromCodePoint(0xF02D1)
  readonly property string followGlyph: String.fromCodePoint(0xF0014)
  readonly property string unfollowGlyph: String.fromCodePoint(0xF0015)
  readonly property string pullGlyph: String.fromCodePoint(0xF04C2)
  readonly property string mergeGlyph: String.fromCodePoint(0xF062D)
  readonly property string issueGlyph: String.fromCodePoint(0xF0028)
  readonly property string checkGlyph: String.fromCodePoint(0xF05E0)
  readonly property string crossGlyph: String.fromCodePoint(0xF0159)
  readonly property string clockGlyph: String.fromCodePoint(0xF0954)
  readonly property string fireGlyph: String.fromCodePoint(0xF0238)
  readonly property string bellGlyph: String.fromCodePoint(0xF009A)
  readonly property string tagGlyph: String.fromCodePoint(0xF04F9)
  readonly property string lockGlyph: String.fromCodePoint(0xF033E)
  readonly property string openGlyph: String.fromCodePoint(0xF03CC)
  readonly property string puzzleGlyph: String.fromCodePoint(0xF0431)
  readonly property string commentGlyph: String.fromCodePoint(0xF0182)
  readonly property string copyGlyph: String.fromCodePoint(0xF018F)
  readonly property string refreshGlyph: String.fromCodePoint(0xF0450)

  property string tab: "overview"
  property string metric: "uclones"
  property string repoSort: "traffic"
  property string activityFilter: "all"
  property string expanded: ""
  // `?` swaps the hover tooltips for a card that explains every number.
  property bool explain: false

  // What each number means: tooltips, and the `?` card. Plain text.
  readonly property var tips: ({
    today: "Contributions GitHub counted today: commits to a repo's default branch, pull requests, issues and reviews. Underneath: the last 7 days, today included.",
    streak: "Days in a row with at least one contribution. Today doesn't break it until the day is over. Underneath: your longest streak in the past year.",
    cloners: "Unique cloners over GitHub's last 14 days, counted per repo and added up, so someone who cloned three of your repos counts three times. Installing a plugin clones its repo, so this is the closest thing to real installs. Bots and CI count too. Underneath: all clones, repeats included.",
    visitors: "Unique visitors to your repo pages on github.com over the last 14 days, counted per repo and added up. Underneath: all page views.",
    copies: "Times someone copied an install command from your listings on omarchyplugins.com. A copy isn't always an install, and installs from a repo link aren't counted. Underneath: change over the last 7 days.",
    hearts: "Hearts people gave your listings on omarchyplugins.com. Underneath: change over the last 7 days.",
    heartsOverview: "Hearts people gave your listings on omarchyplugins.com. Underneath: views of your listing pages.",
    views: "Views of your listing pages on omarchyplugins.com. Underneath: change over the last 7 days.",
    pluginCloners: "Unique cloners of your plugin repos over GitHub's last 14 days, counted per repo and added up. Installing a plugin clones its repo, so this also counts installs the marketplace can't see, plus bots and CI.",
    week: "“+N wk” is the gain over the last 7 days. “Tracking from today” means Pulse has no week-old numbers to compare with yet.",
    verified: "The marketplace verified this listing at your newest commit.",
    updateUnverified: "Your repo has commits newer than the one the marketplace verified. File a verify request for the newest commit to get it verified.",
    unverified: "The marketplace hasn't verified this listing."
  })
  // A tile's tooltip without its "Underneath:" sentence, for the plugin cards' smaller numbers.
  function cardTip(t, weekly) {
    return t.replace(/ Underneath:.*$/, "") + (weekly ? " \u201c+N wk\u201d is the gain over the last 7 days." : "")
  }
  function rankTip(r) {
    return "Rank by install copies among the " + root.fmt(r.of || 0) + " marketplace listings with stats (#1 is the most copied). "
      + "Top N% is the share of listings at or above this rank."
  }
  function badgeText(p) {
    if (p.verification === "verified" && p.upToDate) return "VERIFIED"
    if (p.hasVerified) return "UPDATE UNVERIFIED"
    return String(p.verification || p.status || "").toUpperCase()
  }
  function badgeTip(p) {
    var t = root.badgeText(p)
    return t === "VERIFIED" ? root.tips.verified : t === "UPDATE UNVERIFIED" ? root.tips.updateUnverified
      : t === "UNVERIFIED" ? root.tips.unverified : ""
  }
  function glossary(tab) {
    var t = root.tips
    if (tab === "plugins") return [
      { term: "page views", text: t.views }, { term: "install copies", text: t.copies },
      { term: "hearts", text: t.hearts }, { term: "cloners · 14d", text: t.pluginCloners },
      { term: "#N by installs", text: root.rankTip({ of: root.market.length && root.market[0].rank ? root.market[0].rank.of : 0 }) },
      { term: "+N wk", text: t.week },
      { term: "VERIFIED", text: t.verified }, { term: "UPDATE UNVERIFIED", text: t.updateUnverified }, { term: "UNVERIFIED", text: t.unverified }
    ]
    var g = [{ term: "today", text: t.today }, { term: "day streak", text: t.streak },
             { term: "cloners · 14d", text: t.cloners }, { term: "visitors · 14d", text: t.visitors }]
    if (root.market.length) g.push({ term: "installs", text: t.copies }, { term: "hearts", text: t.heartsOverview })
    return g
  }
  property real seenAtOpen: 0
  // Spins for at least a moment after a click, then for as long as the daemon is fetching.
  readonly property bool refreshing: !!st.refreshing || refreshFeedback.running
  Timer { id: refreshFeedback; interval: 700 }

  function refresh() {
    if (!svc) return
    svc.send("refresh")
    refreshFeedback.restart()
  }

  property double nowMs: Date.now()
  readonly property double nowSec: nowMs / 1000
  Timer {
    interval: root.opened ? 15000 : 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  // ---- derived

  readonly property bool reviewsWaiting: (inbox.reviewsCount || 0) > 0
  readonly property bool ciFailing: (inbox.mine || []).some(function(p) { return p.ci === "FAILURE" || p.ci === "ERROR" })
  readonly property int inboxCount: (inbox.reviewsCount || 0) + (inbox.assignedCount || 0) + notes.length

  readonly property var metrics: [
    { value: "uclones", label: "Cloners", idx: 4, noun: "unique cloners", one: "unique cloner" },
    { value: "clones", label: "Clones", idx: 3, noun: "clones", one: "clone" },
    { value: "uviews", label: "Visitors", idx: 2, noun: "visitors", one: "visitor" },
    { value: "views", label: "Views", idx: 1, noun: "views", one: "view" }
  ]
  readonly property var metricInfo: {
    for (var i = 0; i < metrics.length; i++) if (metrics[i].value === metric) return metrics[i]
    return metrics[0]
  }

  readonly property var tabs: {
    var t = [
      { value: "overview", label: "Overview" },
      { value: "repos", label: "Repos" },
      { value: "activity", label: unseen > 0 && !opened ? "Activity •" : "Activity" },
      { value: "inbox", label: inboxCount ? "Inbox " + inboxCount : "Inbox" }
    ]
    if (market.length) t.push({ value: "plugins", label: "Plugins" })
    t.push({ value: "settings", label: "Settings" })
    return t
  }

  readonly property string barText: {
    if (!hasData || (root.bar && root.bar.vertical)) return ""
    switch (config.barMode || "activity") {
    case "activity": return unseen > 0 ? ghGlyph + "  +" + unseen : ""
    case "streak": return contrib.streak ? fireGlyph + " " + contrib.streak : ""
    case "today": return ghGlyph + "  " + (contrib.today || 0)
    case "clones": return cloneGlyph + " " + root.fmt(totals.uclones || 0)
    case "installs": return market.length ? puzzleGlyph + " " + root.fmt(mtot.copies || 0) : ""
    case "inbox": return inboxCount ? bellGlyph + " " + inboxCount : ""
    }
    return ""
  }

  implicitWidth: textButton.visible ? textButton.implicitWidth : button.implicitWidth
  implicitHeight: textButton.visible ? textButton.implicitHeight : button.implicitHeight

  // ---- helpers

  function fmt(n) {
    n = Number(n || 0)
    if (Math.abs(n) >= 10000) return (n / 1000).toFixed(n >= 100000 ? 0 : 1).replace(/\.0$/, "") + "k"
    return n.toLocaleString(Qt.locale("en_US"), "f", 0)
  }
  function signed(n) { return n > 0 ? "+" + root.fmt(n) : n < 0 ? "−" + root.fmt(-n) : "±0" }
  // "+3 this week", or a note while the daily history is younger than a day.
  function weekSub(n, since) {
    if (n > 0 || !since || since < Qt.formatDate(new Date(nowMs), "yyyy-MM-dd")) return root.signed(n) + " this week"
    return "tracking from today"
  }
  function plural(n, one, many) { return root.fmt(n) + " " + (n === 1 ? one : (many || one + "s")) }

  function agoText(ts) {
    if (!ts) return ""
    var s = Math.floor(nowSec - ts)
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    if (s < 86400 * 30) return Math.floor(s / 86400) + "d ago"
    if (s < 86400 * 365) return Math.floor(s / 86400 / 30) + "mo ago"
    return Math.floor(s / 86400 / 365) + "y ago"
  }

  function dateOf(str) { var p = String(str).split("-"); return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])) }
  function shortDate(str) { return str ? Qt.formatDate(dateOf(str), "MMM d") : "" }
  function longDate(str) { return str ? Qt.formatDate(dateOf(str), "ddd, MMM d") : "" }

  function kindGlyph(k) {
    switch (k) {
    case "star": case "unstar": return starGlyph
    case "fork": return forkGlyph
    case "follow": return followGlyph
    case "unfollow": return unfollowGlyph
    case "heart": return heartGlyph
    case "copy": return copyGlyph
    case "clone": return cloneGlyph
    case "issue": case "assigned": return issueGlyph
    case "pr": case "review": return pullGlyph
    case "check": return checkGlyph
    case "approved": return checkGlyph
    case "changes": return commentGlyph
    case "merged": return mergeGlyph
    case "release": return tagGlyph
    case "inbox": return bellGlyph
    }
    return ghGlyph
  }

  function kindColor(a) {
    switch (a.kind) {
    case "star": return gold
    case "heart": return pink
    case "follow": case "issue": case "approved": return go
    case "fork": case "copy": case "clone": case "pr": case "release": return accent
    case "review": case "assigned": case "changes": return warn
    case "check": return a.text.indexOf("failed") >= 0 ? urgent : go
    case "merged": return purple
    }
    return dim
  }

  function ciGlyph(state) {
    if (state === "SUCCESS") return checkGlyph
    if (state === "FAILURE" || state === "ERROR") return crossGlyph
    if (state === "PENDING" || state === "EXPECTED") return clockGlyph
    return ""
  }
  function ciColor(state) {
    if (state === "SUCCESS") return go
    if (state === "FAILURE" || state === "ERROR") return urgent
    return warn
  }

  function activityShown(a) {
    var f = activityFilter
    if (f === "all") return true
    if (f === "people") return ["star", "unstar", "fork", "follow", "unfollow", "heart"].indexOf(a.kind) >= 0
    if (f === "installs") return a.kind === "copy" || a.kind === "clone"
    return ["star", "unstar", "fork", "follow", "unfollow", "heart", "copy", "clone"].indexOf(a.kind) < 0
  }

  function sortedRepos() {
    var list = repos.slice()
    var key = metricInfo.value
    list.sort(function(a, b) {
      if (repoSort === "stars") return (b.stars - a.stars) || (b.forks - a.forks) || (b.pushedAt - a.pushedAt)
      if (repoSort === "recent") return b.pushedAt - a.pushedAt
      if (repoSort === "name") return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
      var ta = a.traffic ? a.traffic[key] : -1, tb = b.traffic ? b.traffic[key] : -1
      return (tb - ta) || (b.pushedAt - a.pushedAt)
    })
    return list
  }

  function repoByName(name) {
    for (var i = 0; i < repos.length; i++) if (repos[i].name.toLowerCase() === String(name).toLowerCase()) return repos[i]
    return null
  }

  function cycle(options, value, dx) {
    var i = 0
    for (var k = 0; k < options.length; k++) if (options[k].value === value) i = k
    return options[(i + dx + options.length) % options.length].value
  }

  function setTab(v) {
    tab = v
    flick.contentY = 0
  }

  function openUrl(url) { if (svc && url) svc.openUrl(url) }
  function profileUrl() { return user.url || "https://github.com/" + (user.login || "") }

  function summary() {
    if (!svc) return "SERVICE NOT LOADED"
    if (svc.lastError) return svc.lastError.toUpperCase()
    if (!svc.running) return "BACKEND STOPPED"
    if (st.status === "auth") return "SIGN IN NEEDED"
    if (!hasData) return st.status === "offline" ? "OFFLINE" : "LOADING…"
    var bits = []
    bits.push(root.plural(contrib.total || 0, "contribution") .toUpperCase() + " THIS YEAR")
    if (contrib.streak) bits.push(contrib.streak + "-DAY STREAK")
    if (st.status === "offline") bits.push("OFFLINE")
    if (st.status === "limited") bits.push("RATE LIMITED")
    return bits.join("  ·  ")
  }

  // A compact summary for status(). Private repos are counted but never named,
  // and their issue, PR and notification titles are left out.
  function statusSummary() {
    if (!svc) return { error: "GitHub Pulse isn't running" }
    if (!hasData) return { error: st.status === "auth" || st.status === "offline" ? st.error : "GitHub Pulse is still loading", status: st.status || "" }
    var privateRepos = {}
    repos.forEach(function(r) { if (r.private) privateRepos[r.full] = true })
    function item(i) {
      if (i.private || privateRepos[i.repo]) return { repo: "a private repo", kind: i.kind }
      var o = { ref: i.repo + "#" + i.number, title: i.title, kind: i.kind, updated: agoText(i.updated) }
      if (i.author) o.author = i.author
      if (i.ci) o.checks = i.ci.toLowerCase()
      if (i.review) o.review = i.review.toLowerCase().replace(/_/g, " ")
      if (i.draft) o.draft = true
      return o
    }
    var t = totals, c = contrib, u = user
    var top = repos.filter(function(r) { return !r.fork && !r.private && r.traffic })
      .sort(function(a, b) { return b.traffic.uclones - a.traffic.uclones || b.traffic.uviews - a.traffic.uviews })
      .slice(0, 6)
      .map(function(r) {
        return { repo: r.name, uniqueCloners14d: r.traffic.uclones, clones14d: r.traffic.clones,
                 visitors14d: r.traffic.uviews, views14d: r.traffic.views, stars: r.stars, forks: r.forks,
                 openIssues: r.issues, openPRs: r.prs, lastPush: agoText(r.pushedAt), checks: (r.ci || "").toLowerCase() }
      })
    var out = {
      user: u.login, name: u.name, updated: agoText((st.fetched || {}).overview),
      contributions: { today: c.today || 0, thisWeek: c.week || 0, lastWeek: c.prevWeek || 0, last30Days: c.month || 0,
                       last12Months: c.total || 0, commits12Months: c.commits || 0, pullRequests12Months: c.prs || 0,
                       issues12Months: c.issues || 0, reviews12Months: c.reviews || 0,
                       currentStreakDays: c.streak || 0, longestStreakDays: c.longest || 0,
                       bestDay: c.best ? c.best.date + " (" + c.best.count + ")" : "" },
      profile: { followers: u.followers || 0, followersThisWeek: u.followersWeek || 0, following: u.following || 0,
                 ownedRepos: u.repos || 0, privateRepos: Object.keys(privateRepos).length },
      repoTotals: { stars: t.stars || 0, starsThisWeek: t.starsWeek || 0, forks: t.forks || 0,
                    openIssues: t.issues || 0, openPRs: t.prs || 0 },
      traffic14Days: { uniqueCloners: t.uclones || 0, clones: t.clones || 0, visitors: t.uviews || 0, views: t.views || 0,
                       note: "unique counts are summed per repo; GitHub updates traffic about hourly" },
      topReposByCloners: top,
      inbox: {
        reviewRequests: (inbox.reviews || []).map(item), reviewRequestCount: inbox.reviewsCount || 0,
        yourOpenPRs: (inbox.mine || []).map(item), yourOpenPRCount: inbox.mineCount || 0,
        assignedToYou: (inbox.assigned || []).map(item),
        unreadNotifications: notes.length,
        notifications: notes.slice(0, 8).map(function(n) {
          return n.private ? { repo: "a private repo", type: n.type }
                           : { repo: n.repo, title: n.title, type: n.type, reason: n.reason, updated: agoText(n.updated) }
        })
      },
      recentActivity: activity.filter(function(a) { return !privateRepos[a.repo] }).slice(0, 10)
        .map(function(a) { return { when: agoText(a.t), what: a.text } }),
      newEventsSinceLastLook: unseen
    }
    if (market.length) {
      out.omarchyMarketplace = {
        totals: { pageViews: mtot.views, installCopies: mtot.copies, hearts: mtot.hearts,
                  installCopiesThisWeek: mtot.copiesWeek, heartsThisWeek: mtot.heartsWeek, historySince: mtot.since },
        plugins: market.map(function(p) {
          var r = repoByName(p.repoName)
          return { name: p.name, id: p.id, version: p.version, pageViews: p.views, installCopies: p.copies,
                   installCopiesToday: p.copiesToday, installCopiesThisWeek: p.copiesWeek, hearts: p.hearts,
                   rankByInstalls: p.rank && p.rank.copies ? p.rank.copies + " of " + p.rank.of : "",
                   verified: p.verification === "verified" && p.upToDate,
                   uniqueCloners14d: r && r.traffic ? r.traffic.uclones : null }
        })
      }
    }
    return out
  }

  function tooltip() {
    if (!hasData) return st.error || "GitHub"
    var l = [user.login + (user.name ? " · " + user.name : "")]
    l.push(root.plural(contrib.today || 0, "contribution") + " today · " + (contrib.streak || 0) + "-day streak")
    l.push(root.plural(totals.uclones || 0, "unique cloner") + " · " + root.plural(totals.uviews || 0, "visitor") + " (14 days)")
    if ((totals.stars || 0) || (user.followers || 0)) l.push(root.plural(totals.stars || 0, "star") + " · " + root.plural(user.followers || 0, "follower"))
    if (market.length) l.push(root.fmt(mtot.copies) + " install copies · " + root.fmt(mtot.hearts) + " ♥ on the marketplace")
    if (reviewsWaiting) l.push(root.plural(inbox.reviewsCount, "review request"))
    if (ciFailing) l.push("Checks failing on one of your PRs")
    if (unseen) l.push(root.plural(unseen, "new event"))
    return l.join("\n")
  }

  // ---- bar

  BarIconButton {
    id: button
    anchors.fill: parent
    visible: !textButton.visible
    bar: root.bar
    text: root.ghGlyph
    active: root.reviewsWaiting || root.ciFailing
    opacity: root.hasData ? 1 : 0.5
    tooltipText: root.tooltip()
    onPressed: function(b) { root.barPress(b) }
  }

  WidgetButton {
    id: textButton
    anchors.fill: parent
    visible: root.barText !== ""
    bar: root.bar
    active: root.reviewsWaiting || root.ciFailing
    text: root.barText
    tooltipText: root.tooltip()
    onPressed: function(b) { root.barPress(b) }
  }

  function barPress(b) {
    if (b === Qt.RightButton) openUrl(inboxCount ? (notes.length ? "https://github.com/notifications" : "https://github.com/pulls/review-requested") : profileUrl())
    else if (b === Qt.MiddleButton) refresh()
    else toggle()
  }

  // New-activity dot when the bar text isn't already showing it.
  Rectangle {
    visible: !textButton.visible && (root.unseen > 0 || root.reviewsWaiting || root.ciFailing)
    z: 2
    width: Math.max(5, Math.round(Style.bar.iconFont * 0.42))
    height: width
    radius: width / 2
    color: root.reviewsWaiting || root.ciFailing ? root.urgent : Color.accent
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: Math.max(0, (button.width - Style.bar.iconCanvas) / 2 - width / 3)
    anchors.topMargin: Math.max(1, (button.height - Style.bar.iconCanvas) / 2)
  }

  // ---- panel

  KeyboardPanel {
    id: panel
    anchorItem: textButton.visible ? textButton : button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(860))

    onOpenChanged: {
      if (!root.svc) return
      root.svc.send("visible", { open: open })
      if (open) {
        root.seenAtOpen = root.st.seen || 0
        root.svc.send("seen")
      } else {
        root.expanded = ""
        root.explain = false
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx && root.tab === "overview") root.metric = root.cycle(root.metrics, root.metric, dx)
        else if (dx && root.tab === "repos") root.repoSort = root.cycle(root.sorts, root.repoSort, dx)
        else if (dx && root.tab === "activity") root.activityFilter = root.cycle(root.filters, root.activityFilter, dx)
        if (dy) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * Style.space(80)))
      }
      onTextKey: function(t) {
        if (/^[1-9]$/.test(t) && Number(t) <= root.tabs.length) root.setTab(root.tabs[Number(t) - 1].value)
        else if (t === "r") root.refresh()
        else if (t === "o") root.openUrl(root.profileUrl())
        else if (t === "m" && root.svc && root.notes.length) root.svc.send("read")
        else if (t === "?") root.explain = !root.explain
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: flick.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff; width: Style.space(4) }

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.user.name || root.user.login || "GitHub"
            meta: root.summary()
            foreground: root.fg
            fontFamily: root.fontFamily
            iconComponent: Component {
              Item {
                implicitWidth: Style.font.display * 1.6
                implicitHeight: Style.font.display * 1.6
                ClippingRectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: root.faint
                  visible: avatar.status === Image.Ready
                  Image {
                    id: avatar
                    anchors.fill: parent
                    source: root.st.avatar ? "file://" + root.st.avatar : ""
                    sourceSize.width: 160
                    fillMode: Image.PreserveAspectCrop
                    smooth: true
                  }
                }
                Text {
                  anchors.centerIn: parent
                  visible: avatar.status !== Image.Ready
                  text: root.ghGlyph
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(2)
                PanelActionButton {
                  id: refreshButton
                  tooltipText: root.refreshing ? "Refreshing…"
                    : "Refresh (r)" + (root.st.fetched && root.st.fetched.overview ? " · updated " + root.agoText(root.st.fetched.overview) : "")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onClicked: root.refresh()
                  Text {
                    anchors.centerIn: parent
                    text: root.refreshGlyph
                    color: root.refreshing ? Color.accent : refreshButton._hot ? refreshButton.hoverColor : refreshButton.foreground
                    font.family: root.fontFamily
                    font.pixelSize: refreshButton.fontSize
                    NumberAnimation on rotation {
                      from: 0
                      to: 360
                      duration: 900
                      loops: Animation.Infinite
                      running: root.refreshing
                      alwaysRunToEnd: true
                    }
                  }
                }
                PanelActionButton {
                  iconText: root.openGlyph
                  tooltipText: "Open your profile (o)"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onClicked: root.openUrl(root.profileUrl())
                }
              }
            }
          }

          ButtonGroup {
            options: root.tabs
            value: root.tab
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(v) { root.setTab(v) }
          }

          // Sign-in / error banner
          Rectangle {
            visible: root.st.status === "auth" || (!root.hasData && !!root.st.error)
            width: parent.width
            implicitHeight: bannerText.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12)
            border.width: 1
            border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.5)
            Text {
              id: bannerText
              anchors.centerIn: parent
              width: parent.width - Style.space(20)
              wrapMode: Text.WordWrap
              text: root.st.status === "auth"
                ? (root.st.error || "No GitHub token") + "\n\nThe easiest way: run `gh auth login` in a terminal. The plugin picks it up within a minute."
                : root.st.error || ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Card {
            id: glossaryCard
            visible: root.explain && root.hasData && (root.tab === "overview" || root.tab === "plugins")
            width: parent.width
            Column {
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width
                text: "WHAT THESE NUMBERS MEAN  ·  ? to hide"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Repeater {
                model: glossaryCard.visible ? root.glossary(root.tab) : []
                Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(1)
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: modelData.term
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    text: modelData.text
                    color: root.fg
                    opacity: 0.8
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          Loader {
            width: parent.width
            active: root.hasData || root.tab === "settings"
            sourceComponent: root.tab === "overview" ? overviewTab
              : root.tab === "repos" ? reposTab
              : root.tab === "activity" ? activityTab
              : root.tab === "inbox" ? inboxTab
              : root.tab === "plugins" ? pluginsTab : settingsTab
          }

          Text {
            visible: !root.hasData && root.st.status !== "auth" && root.tab !== "settings"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(24)
            bottomPadding: Style.space(24)
            text: "Loading your GitHub…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            topPadding: Style.space(2)
            wrapMode: Text.WordWrap
            text: {
              var f = root.st.fetched || {}
              var bits = []
              if (f.overview) bits.push("Updated " + root.agoText(f.overview))
              var rl = (root.st.rate || {}).core
              if (rl) bits.push("API " + root.fmt(rl.remaining) + "/" + root.fmt(rl.limit) + " left")
              var errs = root.st.errors || {}
              var keys = Object.keys(errs)
              if (keys.length) bits.push(keys[0] + ": " + errs[keys[0]])
              return bits.join(" · ")
            }
            color: root.dim
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption * 0.9
          }

          Item { width: parent.width; height: Style.space(2) }
        }
      }
    }
  }

  readonly property var sorts: [
    { value: "traffic", label: "Traffic" },
    { value: "stars", label: "Stars" },
    { value: "recent", label: "Recent" },
    { value: "name", label: "Name" }
  ]
  readonly property var filters: [
    { value: "all", label: "All" },
    { value: "people", label: "Stars & people" },
    { value: "installs", label: "Installs" },
    { value: "code", label: "Code" }
  ]

  // ================================================================ tabs

  Component {
    id: overviewTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(12)

      // Since you last looked
      Card {
        width: parent.width
        Column {
          width: parent.width
          spacing: Style.space(8)
          readonly property var chips: root.lookChips()
          Text {
            width: parent.width
            text: root.look.since ? "SINCE YOU LAST LOOKED · " + root.agoText(root.look.since).toUpperCase() : "SINCE YOU LAST LOOKED"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.6
          }
          Flow {
            visible: parent.chips.length > 0
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: parent.parent.chips
              Rectangle {
                required property var modelData
                implicitWidth: chipRow.implicitWidth + Style.space(16)
                implicitHeight: chipRow.implicitHeight + Style.space(8)
                radius: height / 2
                color: chipMouse.containsMouse ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.28) : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
                border.width: 1
                border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5)
                Row {
                  id: chipRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)
                  Text { visible: modelData.glyph !== ""; text: modelData.glyph; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { text: modelData.text; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                }
                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { if (modelData.tab === "repos") root.repoSort = "traffic"; root.setTab(modelData.tab) }
                }
              }
            }
          }
          Text {
            visible: parent.chips.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.look.since ? "Nothing new yet. Fresh numbers are loading, and GitHub updates traffic about once an hour."
                                  : "From now on, this shows what changed since you last closed GitHub Pulse."
            color: root.fg
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      Grid {
        id: tiles
        width: parent.width
        columns: 4
        spacing: Style.space(8)
        readonly property real tileW: (width - 3 * spacing) / 4
        StatTile {
          width: tiles.tileW
          glyph: root.ghGlyph
          value: root.fmt(root.contrib.today || 0)
          label: "today"
          tip: root.tips.today
          sub: root.fmt(root.contrib.week || 0) + " this week"
        }
        StatTile {
          width: tiles.tileW
          glyph: root.fireGlyph
          glyphColor: root.contrib.streak ? "#f0883e" : root.dim
          value: String(root.contrib.streak || 0)
          label: "day streak"
          tip: root.tips.streak
          sub: "best " + (root.contrib.longest || 0)
        }
        StatTile {
          width: tiles.tileW
          glyph: root.cloneGlyph
          value: root.fmt(root.totals.uclones || 0)
          label: "cloners · 14d"
          tip: root.tips.cloners
          sub: root.fmt(root.totals.clones || 0) + " clones"
          onClicked: { root.metric = "uclones"; root.repoSort = "traffic"; root.setTab("repos") }
        }
        StatTile {
          width: tiles.tileW
          glyph: root.eyeGlyph
          value: root.fmt(root.totals.uviews || 0)
          label: "visitors · 14d"
          tip: root.tips.visitors
          sub: root.fmt(root.totals.views || 0) + " views"
          onClicked: { root.metric = "uviews"; root.repoSort = "traffic"; root.setTab("repos") }
        }
        StatTile {
          width: tiles.tileW
          glyph: root.starGlyph
          glyphColor: root.gold
          value: root.fmt(root.totals.stars || 0)
          label: "stars"
          sub: (root.totals.starsWeek || 0) ? root.signed(root.totals.starsWeek) + " this week" : root.fmt(root.totals.forks || 0) + " forks"
          subColor: (root.totals.starsWeek || 0) > 0 ? root.go : root.dim
          onClicked: { root.repoSort = "stars"; root.setTab("repos") }
        }
        StatTile {
          width: tiles.tileW
          glyph: root.followGlyph
          value: root.fmt(root.user.followers || 0)
          label: "followers"
          sub: (root.user.followersWeek || 0) ? root.signed(root.user.followersWeek) + " this week" : root.fmt(root.user.following || 0) + " following"
          subColor: (root.user.followersWeek || 0) > 0 ? root.go : root.dim
          onClicked: root.openUrl(root.profileUrl() + "?tab=followers")
        }
        StatTile {
          width: tiles.tileW
          glyph: root.market.length ? root.puzzleGlyph : root.pullGlyph
          value: root.market.length ? root.fmt(root.mtot.copies || 0) : root.fmt(root.inbox.mineCount || 0)
          label: root.market.length ? "installs" : "open PRs"
          tip: root.market.length ? root.tips.copies : ""
          sub: root.market.length ? root.weekSub(root.mtot.copiesWeek || 0, root.mtot.since) : root.fmt(root.inbox.reviewsCount || 0) + " to review"
          subColor: root.market.length && (root.mtot.copiesWeek || 0) > 0 ? root.go : root.dim
          onClicked: root.setTab(root.market.length ? "plugins" : "inbox")
        }
        StatTile {
          width: tiles.tileW
          glyph: root.market.length ? root.heartGlyph : root.issueGlyph
          glyphColor: root.market.length ? root.pink : root.fg
          value: root.market.length ? root.fmt(root.mtot.hearts || 0) : root.fmt(root.totals.issues || 0)
          label: root.market.length ? "hearts" : "open issues"
          tip: root.market.length ? root.tips.heartsOverview : ""
          sub: root.market.length ? root.fmt(root.mtot.views || 0) + " views" : root.fmt(root.totals.prs || 0) + " PRs on yours"
          onClicked: root.setTab(root.market.length ? "plugins" : "repos")
        }
      }

      Card {
        width: parent.width
        Heatmap { width: parent.width; days: root.contrib.days || []; weeks: root.contrib.weeks || 53 }
      }

      Card {
        width: parent.width
        Column {
          width: parent.width
          spacing: Style.space(8)
          Item {
            width: parent.width
            height: metricGroup.implicitHeight
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "TRAFFIC · 30 DAYS"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 0.6
            }
            ButtonGroup {
              id: metricGroup
              anchors.right: parent.right
              options: root.metrics
              value: root.metric
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              focusable: false
              onChanged: function(v) { root.metric = v }
            }
          }
          BarChart {
            width: parent.width
            height: Style.space(92)
            points: (root.st.traffic || []).map(function(d) { return [d[0], d[root.metricInfo.idx]] })
            one: root.metricInfo.one
            many: root.metricInfo.noun
            summary: root.plural(root.totals[root.metric] || 0, root.metricInfo.one, root.metricInfo.noun) + " in the last 14 days"
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "GitHub keeps 14 days of traffic. This widget has kept every day since " + root.shortDate(root.st.trackingSince) + ". Unique counts are summed per repo."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption * 0.9
          }
        }
      }

      Card {
        visible: (root.totals.stars || 0) > 0 && (root.st.starSeries || []).length > 0
        width: parent.width
        BarChart {
          width: parent.width
          height: Style.space(70)
          title: "NEW STARS · 90 DAYS"
          barColor: root.gold
          points: {
            var s = root.st.starSeries || []
            var out = []
            for (var i = 0; i < s.length; i++) out.push([s[i][0], i ? s[i][1] - s[i - 1][1] : 0])
            return out
          }
          one: "new star"
          many: "new stars"
          summary: root.plural(root.totals.stars || 0, "star") + " total"
        }
      }

      PanelSectionHeader { text: "TOP REPOS BY " + root.metricInfo.label.toUpperCase(); foreground: root.fg; fontFamily: root.fontFamily }
      Repeater {
        model: {
          var key = root.metric
          return root.repos.filter(function(r) { return !r.fork && r.traffic }).sort(function(a, b) {
            return b.traffic[key] - a.traffic[key] || b.pushedAt - a.pushedAt
          }).slice(0, 4)
        }
        RepoRow { required property var modelData; width: parent.width; r: modelData }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        visible: !!root.contrib.total
        text: {
          var c = root.contrib
          var bits = [root.plural(c.commits || 0, "commit"), root.plural(c.prs || 0, "pull request"), root.plural(c.issues || 0, "issue"), root.plural(c.reviews || 0, "review")]
          if (c.newRepos) bits.push(root.plural(c.newRepos, "new repo"))
          return "Last 12 months: " + bits.join(" · ") + (c.private ? " · " + root.fmt(c.private) + " private" : "")
            + (c.best ? ". Best day " + root.longDate(c.best.date) + " (" + c.best.count + ")" : "")
            + (c.activeDays ? ". " + c.activeDays + " active days, " + c.perActiveDay + " per active day." : "")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Component {
    id: reposTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(8)

      Flow {
        width: parent.width
        spacing: Style.space(10)
        ButtonGroup {
          options: root.sorts
          value: root.repoSort
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { root.repoSort = v }
        }
        ButtonGroup {
          visible: root.repoSort === "traffic"
          options: root.metrics
          value: root.metric
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { root.metric = v }
        }
      }

      Repeater {
        model: root.sortedRepos()
        RepoRow { required property var modelData; width: parent.width; r: modelData; expandable: true }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.plural(root.repos.length, "repo") + (root.config.includePrivate === false ? " (public only)" : "")
          + (root.config.includeForks ? "" : ", forks hidden") + ". Click a repo for its daily traffic, referrers and top pages. ←/→ changes the sort."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Component {
    id: activityTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(6)

      ButtonGroup {
        options: root.filters
        value: root.activityFilter
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        focusable: false
        onChanged: function(v) { root.activityFilter = v }
      }

      Item { width: 1; height: Style.space(2) }

      Repeater {
        model: root.activity.filter(root.activityShown)
        ActivityRow { required property var modelData; width: parent.width; a: modelData }
      }

      Column {
        visible: root.activity.filter(root.activityShown).length === 0
        width: parent.width
        topPadding: Style.space(20)
        bottomPadding: Style.space(12)
        spacing: Style.space(8)
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.ghGlyph
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: "Nothing yet. New stars, forks, followers, issues on your repos, review requests, CI results, marketplace hearts and install copies, and new cloners show up here as they happen."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  Component {
    id: inboxTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(8)

      SectionTitle {
        text: "REVIEW REQUESTS"
        count: root.inbox.reviewsCount || 0
        url: "https://github.com/pulls/review-requested"
      }
      Repeater {
        model: root.inbox.reviews || []
        ItemRow { required property var modelData; width: parent.width; it: modelData; showAuthor: true }
      }
      Hint { visible: !(root.inbox.reviews || []).length; text: "No one is waiting on you." }

      SectionTitle {
        text: "YOUR PULL REQUESTS"
        count: root.inbox.mineCount || 0
        url: "https://github.com/pulls"
      }
      Repeater {
        model: root.inbox.mine || []
        ItemRow { required property var modelData; width: parent.width; it: modelData }
      }
      Hint { visible: !(root.inbox.mine || []).length; text: "No open pull requests." }

      SectionTitle {
        visible: (root.inbox.assigned || []).length > 0
        text: "ASSIGNED TO YOU"
        count: root.inbox.assignedCount || 0
        url: "https://github.com/issues/assigned"
      }
      Repeater {
        model: root.inbox.assigned || []
        ItemRow { required property var modelData; width: parent.width; it: modelData; showAuthor: true }
      }

      SectionTitle {
        text: "NOTIFICATIONS"
        count: root.notes.length
        url: "https://github.com/notifications"
        action: root.notes.length ? "Mark all read (m)" : ""
        onActionClicked: if (root.svc) root.svc.send("read")
      }
      Repeater {
        model: root.notes
        NoteRow { required property var modelData; width: parent.width; n: modelData }
      }
      Hint {
        visible: !root.notes.length
        text: (root.st.notifications || {}).unavailable
          ? "This token can't read notifications. A classic token with the notifications or repo scope can (gh's default does)."
          : "Inbox zero."
      }
    }
  }

  Component {
    id: pluginsTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(8)
        readonly property real tileW: (width - 3 * spacing) / 4
        StatTile { width: parent.tileW; glyph: root.eyeGlyph; value: root.fmt(root.mtot.views || 0); label: "page views"; tip: root.tips.views; sub: root.weekSub(root.mtot.viewsWeek || 0, root.mtot.since); subColor: (root.mtot.viewsWeek || 0) > 0 ? root.go : root.dim }
        StatTile { width: parent.tileW; glyph: root.copyGlyph; value: root.fmt(root.mtot.copies || 0); label: "install copies"; tip: root.tips.copies; sub: root.weekSub(root.mtot.copiesWeek || 0, root.mtot.since); subColor: (root.mtot.copiesWeek || 0) > 0 ? root.go : root.dim }
        StatTile { width: parent.tileW; glyph: root.heartGlyph; glyphColor: root.pink; value: root.fmt(root.mtot.hearts || 0); label: "hearts"; tip: root.tips.hearts; sub: root.weekSub(root.mtot.heartsWeek || 0, root.mtot.since); subColor: (root.mtot.heartsWeek || 0) > 0 ? root.go : root.dim }
        StatTile {
          width: parent.tileW
          glyph: root.cloneGlyph
          value: {
            var n = 0
            root.market.forEach(function(p) { var r = root.repoByName(p.repoName); if (r && r.traffic) n += r.traffic.uclones })
            return root.fmt(n)
          }
          label: "cloners · 14d"
          tip: root.tips.pluginCloners
          sub: "real installs"
        }
      }

      Repeater {
        model: root.market
        PluginCard { required property var modelData; width: parent.width; p: modelData }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: "From omarchyplugins.com: views and install-command copies for each of your " + root.mtot.plugins + " listings, out of " + root.fmt(root.mtot.listings) + ". Cloners come from GitHub traffic, since `omarchy plugin add` clones the repo. Daily history since " + root.shortDate((root.market[0] || {}).tracked) + "."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Component {
    id: settingsTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(10)

      PanelSectionHeader { text: "BAR"; foreground: root.fg; fontFamily: root.fontFamily }
      Dropdown {
        width: parent.width
        label: "Next to the icon"
        value: root.config.barMode || "activity"
        options: [
          { value: "activity", label: "New activity count (+3)" },
          { value: "streak", label: "Contribution streak" },
          { value: "today", label: "Contributions today" },
          { value: "clones", label: "Unique cloners, 14 days" },
          { value: "installs", label: "Marketplace install copies" },
          { value: "inbox", label: "Inbox count (reviews + notifications)" },
          { value: "icon", label: "Nothing, icon only" }
        ]
        foreground: root.fg
        fontFamily: root.fontFamily
        onChanged: function(v) { if (root.svc) root.svc.setConfig("barMode", v) }
      }

      PanelSeparator { foreground: root.fg }
      PanelSectionHeader { text: "REPOS"; foreground: root.fg; fontFamily: root.fontFamily }
      SettingToggle { key: "includePrivate"; label: "Include private repos"; description: "In totals, traffic and the repo list. Nothing leaves your machine either way." }
      SettingToggle { key: "includeForks"; label: "Show forks"; checked: root.config.includeForks === true }
      SettingToggle { key: "marketplace"; label: "Omarchy marketplace stats"; description: "Views, install copies and hearts for listings whose repo you own." }

      PanelSeparator { foreground: root.fg }
      PanelSectionHeader { text: "ALERTS"; foreground: root.fg; fontFamily: root.fontFamily }
      SettingToggle { key: "notifyStars"; label: "New stars" }
      SettingToggle { key: "notifyFollowers"; label: "New followers" }
      SettingToggle { key: "notifyForks"; label: "Forks" }
      SettingToggle { key: "notifyIssues"; label: "Issues and PRs opened on your repos" }
      SettingToggle { key: "notifyReviews"; label: "Review requests and assignments" }
      SettingToggle { key: "notifyChecks"; label: "Your PRs: checks, reviews, merges"; description: "When CI finishes, a review approves or asks for changes, or a PR gets merged." }
      SettingToggle { key: "notifyHearts"; label: "Marketplace hearts" }
      SettingToggle { key: "notifyInstalls"; label: "Marketplace install copies"; checked: root.config.notifyInstalls === true }
      SettingToggle { key: "notifyClones"; label: "New cloners"; checked: root.config.notifyClones === true; description: "GitHub updates traffic about once an hour." }
      SettingToggle { key: "notifyInbox"; label: "Every GitHub notification"; checked: root.config.notifyInbox === true }
      SettingToggle { key: "streakReminder"; label: "Streak reminder"; checked: root.config.streakReminder === true; description: "An evening nudge when you have a streak going and nothing yet today." }
      Dropdown {
        visible: root.config.streakReminder === true
        width: parent.width
        label: "Remind me at"
        value: String(root.config.streakHour || 20)
        options: [17, 18, 19, 20, 21, 22, 23].map(function(h) { return { value: String(h), label: (h > 12 ? h - 12 : h) + " PM" } })
        foreground: root.fg
        fontFamily: root.fontFamily
        onChanged: function(v) { if (root.svc) root.svc.setConfig("streakHour", Number(v)) }
      }

      Row {
        spacing: Style.space(8)
        Button {
          text: "Test notification"
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          bordered: true
          onClicked: if (root.svc) root.svc.send("test")
        }
        Button {
          text: "Refresh"
          tooltipText: "Fetch everything now (r)"
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          bordered: true
          onClicked: root.refresh()
        }
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: {
          var a = root.st.auth || {}
          var src = a.source === "gh" ? "the GitHub CLI (gh auth token)" : a.source === "file" ? "~/.config/grivera-github/token" : a.source || "nothing yet"
          var rl = root.st.rate || {}
          return "Signed in through " + src + (a.scopes && a.scopes.length ? " · scopes: " + a.scopes.join(", ") : "") + "."
            + (rl.graphql ? " GraphQL " + root.fmt(rl.graphql.remaining) + "/" + root.fmt(rl.graphql.limit) + " left." : "")
            + "\nKeys: 1–" + root.tabs.length + " tabs · ←/→ metric, sort or filter · o profile · m mark notifications read · r refresh · ? explain the numbers"
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ================================================================ pieces

  component SettingToggle: Toggle {
    property string key: ""
    width: parent ? parent.width : 0
    foreground: root.fg
    fontFamily: root.fontFamily
    checked: root.config[key] !== false
    onClicked: if (root.svc) root.svc.setConfig(key, !checked)
  }

  component Card: Rectangle {
    default property alias content: inner.data
    implicitHeight: inner.childrenRect.height + Style.space(24)
    radius: Style.cornerRadius
    color: root.wash
    border.width: 1
    border.color: root.faint
    Item {
      id: inner
      x: Style.space(12)
      y: Style.space(12)
      width: parent.width - Style.space(24)
      height: childrenRect.height
    }
  }

  component Hint: Text {
    width: parent ? parent.width : 0
    wrapMode: Text.WordWrap
    leftPadding: Style.space(4)
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.italic: true
  }

  component SectionTitle: Item {
    id: sec
    property string text: ""
    property int count: 0
    property string url: ""
    property string action: ""
    signal actionClicked()
    implicitHeight: secLabel.implicitHeight + Style.space(8)
    width: parent ? parent.width : 0
    Text {
      id: secLabel
      anchors.bottom: parent.bottom
      text: sec.text + (sec.count ? "  " + sec.count : "")
      color: secMouse.containsMouse ? Color.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 0.6
      MouseArea {
        id: secMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openUrl(sec.url)
      }
    }
    Text {
      visible: sec.action !== ""
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      text: sec.action
      color: actMouse.containsMouse ? Color.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      MouseArea {
        id: actMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: sec.actionClicked()
      }
    }
  }

  // PanelToolTip (plain text) that wraps instead of growing one long line.
  component Tip: PanelToolTip {
    delay: 500
    width: Math.min(implicitWidth, Style.space(300))
    // ToolTip centres itself by implicitWidth, the unwrapped line, so place it by the real width.
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? -height - Style.space(4) : 0
    Component.onCompleted: contentItem.wrapMode = Text.WordWrap
  }

  component Pill: Rectangle {
    id: pill
    property string text: ""
    property color tint: Color.accent
    implicitWidth: pillText.implicitWidth + Style.space(12)
    implicitHeight: pillText.implicitHeight + Style.space(4)
    radius: height / 2
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.14)
    border.width: 1
    border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.5)
    Text {
      id: pillText
      anchors.centerIn: parent
      text: pill.text
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption * 0.9
      font.bold: true
    }
  }

  component StatTile: Rectangle {
    id: tile
    property string glyph: ""
    property color glyphColor: root.fg
    property string value: ""
    property string label: ""
    property string sub: ""
    property color subColor: root.dim
    property string tip: ""
    signal clicked()
    readonly property bool clickable: tileMouse.enabled
    implicitHeight: tileCol.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: tileMouse.containsMouse ? root.faint : root.wash
    border.width: 1
    border.color: root.faint
    Column {
      id: tileCol
      anchors.centerIn: parent
      width: parent.width - Style.space(10)
      spacing: Style.space(1)
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(5)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: tile.glyph !== ""
          text: tile.glyph
          color: tile.glyphColor
          opacity: 0.85
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }
        Text {
          text: tile.value
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }
      }
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: tile.label
        color: root.fg
        opacity: 0.8
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        visible: tile.sub !== ""
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: tile.sub
        color: tile.subColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption * 0.9
      }
    }
    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }
    Tip {
      visible: tileMouse.containsMouse && tile.tip !== "" && !root.explain
      text: tile.tip
    }
  }

  // GitHub-style contribution calendar, shaded in the theme accent.
  component Heatmap: Column {
    id: heat
    property var days: []
    property int weeks: 53
    property int hover: -1
    readonly property real labelW: Style.space(24)
    readonly property real cell: Math.max(4, (width - labelW) / Math.max(1, weeks))
    readonly property real gap: Math.max(1, Math.round(cell * 0.2))
    spacing: Style.space(6)

    function levelColor(l) {
      if (!l) return root.faint
      var a = [0, 0.32, 0.55, 0.78, 1][l]
      return Qt.rgba(root.accent.r, root.accent.g, root.accent.b, a)
    }

    Item {
      width: parent.width
      height: heatTitle.implicitHeight
      Text {
        id: heatTitle
        text: heat.hover >= 0 && heat.days[heat.hover]
          ? root.plural(heat.days[heat.hover][1], "contribution") + " on " + root.longDate(heat.days[heat.hover][0])
          : root.plural(root.contrib.total || 0, "contribution") + " in the last year"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: heat.hover < 0
      }
      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        Text { text: "Less "; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.85 }
        Repeater {
          model: 5
          Rectangle {
            required property int index
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(heat.cell - heat.gap)
            height: width
            radius: Math.min(2, width / 4)
            color: heat.levelColor(index)
          }
        }
        Text { text: " More"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.85 }
      }
    }

    Item {
      width: parent.width
      height: monthRow.height + 7 * heat.cell

      // Month labels at the first column of each month.
      Item {
        id: monthRow
        width: parent.width
        height: Style.font.caption + Style.space(3)
        Repeater {
          model: {
            var out = [], last = -1
            for (var i = 0; i < heat.days.length; i++) {
              var d = heat.days[i]
              var m = Number(String(d[0]).split("-")[1])
              if (m !== last && d[4] <= 6) {
                if (last !== -1 || d[3] === 0) out.push({ col: d[3], label: Qt.formatDate(root.dateOf(d[0]), "MMM") })
                last = m
              }
            }
            // Drop a label that would collide with the next one.
            return out.filter(function(o, k) { return k + 1 >= out.length || out[k + 1].col - o.col >= 3 })
          }
          Text {
            required property var modelData
            x: heat.labelW + modelData.col * heat.cell
            text: modelData.label
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption * 0.85
          }
        }
      }

      Repeater {
        model: [[1, "Mon"], [3, "Wed"], [5, "Fri"]]
        Text {
          required property var modelData
          y: monthRow.height + modelData[0] * heat.cell + (heat.cell - heat.gap - height) / 2
          text: modelData[1]
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption * 0.8
        }
      }

      Repeater {
        model: heat.days
        Rectangle {
          required property var modelData
          required property int index
          x: Math.round(heat.labelW + modelData[3] * heat.cell)
          y: Math.round(monthRow.height + modelData[4] * heat.cell)
          width: Math.round(heat.cell - heat.gap)
          height: width
          radius: Math.min(2, width / 4)
          color: heat.levelColor(modelData[2])
          border.width: heat.hover === index || (index === heat.days.length - 1) ? 1 : 0
          border.color: heat.hover === index ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.5)
          MouseArea {
            anchors.fill: parent
            anchors.margins: -heat.gap / 2
            hoverEnabled: true
            onEntered: heat.hover = parent.index
            onExited: if (heat.hover === parent.index) heat.hover = -1
          }
        }
      }
    }

    Text {
      width: parent.width
      text: {
        var c = root.contrib
        return "Streak " + (c.streak || 0) + " · longest " + (c.longest || 0) + " · this week " + (c.week || 0)
          + " (" + root.signed((c.week || 0) - (c.prevWeek || 0)) + " vs last) · 30 days " + (c.month || 0)
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // Daily bars with a hover readout in the header; one series, no legend.
  component BarChart: Column {
    id: chart
    property var points: []          // [[date, value], ...]
    property string title: ""
    property string summary: ""
    property string one: ""
    property string many: ""
    property color barColor: root.accent
    property bool compact: false
    property int hover: -1
    readonly property real maxV: {
      var m = 0
      for (var i = 0; i < points.length; i++) m = Math.max(m, points[i][1])
      return m
    }
    spacing: Style.space(4)

    Item {
      visible: !chart.compact
      width: parent.width
      height: visible ? readout.implicitHeight : 0
      Text {
        visible: chart.title !== ""
        text: chart.title
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.6
      }
      Text {
        id: readout
        anchors.right: chart.title !== "" ? parent.right : undefined
        text: chart.hover >= 0 && chart.points[chart.hover]
          ? root.longDate(chart.points[chart.hover][0]) + " · " + root.plural(chart.points[chart.hover][1], chart.one, chart.many)
          : chart.summary
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: chart.hover < 0
      }
    }

    Item {
      id: plot
      width: parent.width
      height: chart.height - (chart.compact ? 0 : readout.implicitHeight + chart.spacing + axis.height + chart.spacing)
      readonly property real slot: width / Math.max(1, chart.points.length)
      readonly property real gap: chart.compact ? 1 : Math.max(1, Math.min(2, slot * 0.2))

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: root.faint
      }

      Repeater {
        model: chart.points
        Item {
          required property var modelData
          required property int index
          x: index * plot.slot
          width: plot.slot
          height: plot.height
          Rectangle {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(1, plot.slot - plot.gap)
            height: chart.maxV > 0 && modelData[1] > 0 ? Math.max(2, (plot.height - 1) * modelData[1] / chart.maxV) : 0
            radius: Math.min(2, width / 3)
            color: chart.barColor
            opacity: chart.hover < 0 || chart.hover === index ? 1 : 0.45
          }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: !chart.compact
            onEntered: chart.hover = parent.index
            onExited: if (chart.hover === parent.index) chart.hover = -1
          }
        }
      }

      Text {
        visible: !chart.compact && chart.maxV > 0
        anchors.right: parent.right
        anchors.top: parent.top
        text: root.fmt(chart.maxV)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption * 0.85
      }
    }

    Item {
      id: axis
      visible: !chart.compact && chart.points.length > 0
      width: parent.width
      height: visible ? axisFirst.implicitHeight : 0
      Text {
        id: axisFirst
        text: chart.points.length ? root.shortDate(chart.points[0][0]) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption * 0.85
      }
      Text {
        anchors.right: parent.right
        text: "Today"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption * 0.85
      }
    }
  }

  component RepoRow: Rectangle {
    id: row
    property var r: ({})
    property bool expandable: false
    readonly property bool open: expandable && root.expanded === r.full
    readonly property var tr: r.traffic || null
    implicitHeight: rowCol.implicitHeight + Style.space(14)
    radius: Style.cornerRadius
    color: rowMouse.containsMouse || open ? root.faint : root.wash
    border.width: open ? 1 : 0
    border.color: root.faint

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (!row.expandable) { root.expanded = row.r.full; root.setTab("repos"); return }
        root.expanded = row.open ? "" : row.r.full
      }
    }

    Column {
      id: rowCol
      x: Style.space(10)
      y: Style.space(7)
      width: parent.width - Style.space(20)
      spacing: Style.space(3)

      Item {
        width: parent.width
        height: Math.max(nameRow.implicitHeight, spark.height)
        Row {
          id: nameRow
          anchors.left: parent.left
          anchors.right: stats.left
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(6)
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: width
            radius: width / 2
            color: row.r.langColor || root.dim
          }
          Text {
            width: Math.min(implicitWidth, nameRow.width - Style.space(60))
            text: row.r.name || ""
            elide: Text.ElideRight
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            visible: !!row.r.private
            anchors.verticalCenter: parent.verticalCenter
            text: root.lockGlyph
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: !!row.r.plugin
            anchors.verticalCenter: parent.verticalCenter
            text: root.puzzleGlyph
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            readonly property int fresh: (root.look.repos || {})[row.r.name] || 0
            visible: fresh > 0
            anchors.verticalCenter: parent.verticalCenter
            text: "+" + fresh + " new"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            visible: !!row.r.ci
            anchors.verticalCenter: parent.verticalCenter
            text: root.ciGlyph(row.r.ci)
            color: root.ciColor(row.r.ci)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Row {
          id: stats
          anchors.right: spark.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)
          Stat { glyph: root.starGlyph; n: row.r.stars || 0; tint: root.gold; visible: (row.r.stars || 0) > 0 }
          Stat { glyph: root.forkGlyph; n: row.r.forks || 0; visible: (row.r.forks || 0) > 0 }
          Stat { glyph: root.cloneGlyph; n: row.tr ? row.tr.uclones : 0; visible: !!row.tr }
          Stat { glyph: root.eyeGlyph; n: row.tr ? row.tr.uviews : 0; visible: !!row.tr }
        }
        BarChart {
          id: spark
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(56)
          height: Style.space(18)
          compact: true
          barColor: root.accent
          points: row.tr ? row.tr.days.map(function(d) { return [d[0], d[root.metricInfo.idx]] }) : []
        }
      }

      Text {
        width: parent.width
        elide: Text.ElideRight
        text: {
          var bits = []
          if (row.r.desc) bits.push(row.r.desc)
          bits.push("pushed " + root.agoText(row.r.pushedAt))
          if (row.r.release) bits.push(row.r.release.tag)
          if (row.r.issues) bits.push(root.plural(row.r.issues, "issue"))
          if (row.r.prs) bits.push(root.plural(row.r.prs, "PR"))
          return bits.join(" · ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Loader {
        width: parent.width
        active: row.open
        visible: active
        sourceComponent: Column {
          spacing: Style.space(10)
          topPadding: Style.space(8)
          BarChart {
            visible: !!row.tr
            width: parent.width
            height: Style.space(84)
            title: root.metricInfo.label.toUpperCase() + " · 14 DAYS"
            points: row.tr ? row.tr.days.map(function(d) { return [d[0], d[root.metricInfo.idx]] }) : []
            one: root.metricInfo.one
            many: root.metricInfo.noun
            summary: row.tr ? root.plural(row.tr[root.metric], root.metricInfo.one, root.metricInfo.noun) : ""
          }
          Text {
            visible: !!row.tr
            width: parent.width
            wrapMode: Text.WordWrap
            text: row.tr ? "14 days: " + root.plural(row.tr.clones, "clone") + " by " + root.plural(row.tr.uclones, "person", "people")
              + ", " + root.plural(row.tr.views, "view") + " by " + root.plural(row.tr.uviews, "visitor")
              + ". Since " + root.shortDate(row.tr.since) + ": " + root.plural(row.tr.allClones, "clone") + ", " + root.plural(row.tr.allViews, "view") + "." : ""
            color: root.fg
            opacity: 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Row {
            visible: !!row.tr && ((row.tr.referrers || []).length > 0 || (row.tr.paths || []).length > 0)
            width: parent.width
            spacing: Style.space(12)
            TopList {
              width: (parent.width - parent.spacing) / 2
              title: "REFERRERS"
              items: row.tr ? (row.tr.referrers || []).map(function(x) { return [x.name, x.uniques] }) : []
            }
            TopList {
              width: (parent.width - parent.spacing) / 2
              title: "TOP PAGES"
              items: row.tr ? (row.tr.paths || []).map(function(x) {
                var p = x.path.split("/").slice(3).join("/")
                return [p || "Overview", x.uniques]
              }) : []
            }
          }
          Row {
            spacing: Style.space(6)
            Button { text: "Repo"; foreground: root.fg; fontFamily: root.fontFamily; fontSize: Style.font.caption; bordered: true; onClicked: root.openUrl(row.r.url) }
            Button { text: "Traffic"; foreground: root.fg; fontFamily: root.fontFamily; fontSize: Style.font.caption; bordered: true; onClicked: root.openUrl(row.r.url + "/graphs/traffic") }
            Button { text: "Issues"; foreground: root.fg; fontFamily: root.fontFamily; fontSize: Style.font.caption; bordered: true; onClicked: root.openUrl(row.r.url + "/issues") }
            Button { visible: !!row.r.plugin; text: "Marketplace"; foreground: root.fg; fontFamily: root.fontFamily; fontSize: Style.font.caption; bordered: true; onClicked: root.openUrl("https://omarchyplugins.com/plugin.html?id=" + row.r.plugin) }
          }
        }
      }
    }
  }

  component Stat: Row {
    property string glyph: ""
    property int n: 0
    property color tint: root.dim
    spacing: Style.space(3)
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: parent.glyph
      color: parent.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.fmt(parent.n)
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component TopList: Column {
    id: tl
    property string title: ""
    property var items: []
    spacing: Style.space(2)
    Text { text: tl.title; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.9; font.letterSpacing: 0.6 }
    Repeater {
      model: tl.items.slice(0, 5)
      Item {
        required property var modelData
        width: tl.width
        height: tlName.implicitHeight
        Text {
          id: tlName
          width: parent.width - tlN.implicitWidth - Style.space(6)
          text: modelData[0]
          elide: Text.ElideMiddle
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text { id: tlN; anchors.right: parent.right; text: root.fmt(modelData[1]); color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      }
    }
    Text { visible: !tl.items.length; text: "—"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
  }

  component ActivityRow: Rectangle {
    id: act
    property var a: ({})
    readonly property bool fresh: a.t > root.seenAtOpen
    implicitHeight: actRow.implicitHeight + Style.space(10)
    radius: Style.cornerRadius
    color: actMouse.containsMouse ? root.faint : fresh ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08) : "transparent"
    Rectangle {
      visible: act.fresh
      width: Style.space(2)
      height: parent.height - Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      radius: 1
      color: Color.accent
    }
    MouseArea {
      id: actMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: act.a.url ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.openUrl(act.a.url)
    }
    Row {
      id: actRow
      x: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(16)
      spacing: Style.space(8)
      Text {
        width: Style.space(16)
        text: root.kindGlyph(act.a.kind)
        color: root.kindColor(act.a)
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width - Style.space(16) - when.width - 2 * parent.spacing
        text: act.a.text
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        color: act.a.kind === "unstar" || act.a.kind === "unfollow" ? root.dim : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        id: when
        text: root.agoText(act.a.t)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component ItemRow: Rectangle {
    id: item
    property var it: ({})
    property bool showAuthor: false
    implicitHeight: itemCol.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: itemMouse.containsMouse ? root.faint : root.wash
    MouseArea {
      id: itemMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openUrl(item.it.url)
    }
    Text {
      id: itemGlyph
      x: Style.space(8)
      y: Style.space(6)
      text: item.it.kind === "pr" ? root.pullGlyph : root.issueGlyph
      color: item.it.draft ? root.dim : root.go
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Column {
      id: itemCol
      x: Style.space(30)
      y: Style.space(6)
      width: parent.width - Style.space(38) - badges.width
      spacing: Style.space(2)
      Text {
        width: parent.width
        text: item.it.title || ""
        elide: Text.ElideRight
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
      Text {
        width: parent.width
        elide: Text.ElideRight
        text: {
          var i = item.it
          var bits = [i.repo + "#" + i.number]
          if (item.showAuthor) bits.push("by " + i.author)
          bits.push("updated " + root.agoText(i.updated))
          if (i.comments) bits.push(root.plural(i.comments, "comment"))
          if (i.kind === "pr" && (i.adds || i.dels)) bits.push("+" + i.adds + " −" + i.dels)
          return bits.join(" · ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    Row {
      id: badges
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)
      Pill { visible: !!item.it.draft; text: "DRAFT"; tint: root.dim }
      Pill { visible: item.it.review === "APPROVED"; text: "APPROVED"; tint: root.go }
      Pill { visible: item.it.review === "CHANGES_REQUESTED"; text: "CHANGES"; tint: root.warn }
      Pill { visible: item.it.mergeable === "CONFLICTING"; text: "CONFLICT"; tint: root.urgent }
      Text {
        visible: !!item.it.ci
        anchors.verticalCenter: parent.verticalCenter
        text: root.ciGlyph(item.it.ci)
        color: root.ciColor(item.it.ci)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  component NoteRow: Rectangle {
    id: note
    property var n: ({})
    implicitHeight: noteCol.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: noteMouse.containsMouse ? root.faint : root.wash
    MouseArea {
      id: noteMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openUrl(note.n.url)
    }
    Text {
      x: Style.space(8)
      y: Style.space(6)
      text: note.n.type === "PullRequest" ? root.pullGlyph : note.n.type === "Issue" ? root.issueGlyph
        : note.n.type === "Release" ? root.tagGlyph : note.n.type === "CheckSuite" ? root.checkGlyph : root.bellGlyph
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Column {
      id: noteCol
      x: Style.space(30)
      y: Style.space(6)
      width: parent.width - Style.space(38) - readBtn.width
      spacing: Style.space(2)
      Text {
        width: parent.width
        text: note.n.title || ""
        elide: Text.ElideRight
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        width: parent.width
        elide: Text.ElideRight
        text: note.n.repo + " · " + String(note.n.reason || "").replace(/_/g, " ") + " · " + root.agoText(note.n.updated)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    PanelActionButton {
      id: readBtn
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      iconText: root.checkGlyph
      tooltipText: "Mark as read"
      foreground: root.dim
      hoverColor: root.go
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      onClicked: if (root.svc) root.svc.send("read", { thread: note.n.id })
    }
  }

  component PluginCard: Rectangle {
    id: card
    property var p: ({})
    readonly property var repo: root.repoByName(p.repoName || "")
    readonly property var rank: p.rank || ({})
    implicitHeight: cardCol.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: cardMouse.containsMouse ? root.faint : root.wash
    border.width: 1
    border.color: root.faint
    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openUrl(card.p.url)
    }
    Column {
      id: cardCol
      x: Style.space(10)
      y: Style.space(10)
      width: parent.width - Style.space(20)
      spacing: Style.space(6)
      Item {
        width: parent.width
        height: Math.max(initials.height, titleCol.implicitHeight)
        Rectangle {
          id: initials
          width: Style.space(34)
          height: width
          radius: Style.cornerRadius
          color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
          border.width: 1
          border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5)
          Text {
            anchors.centerIn: parent
            text: card.p.initials || ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }
        Column {
          id: titleCol
          anchors.left: initials.right
          anchors.leftMargin: Style.space(10)
          anchors.right: cardSpark.left
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(2)
          Row {
            spacing: Style.space(6)
            Text {
              text: card.p.name || ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: card.p.version ? "v" + card.p.version : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Pill {
              readonly property int fresh: (root.look.plugins || {})[card.p.id] || 0
              visible: fresh > 0
              anchors.verticalCenter: parent.verticalCenter
              text: "+" + fresh + " NEW"
              tint: Color.accent
            }
            Pill {
              anchors.verticalCenter: parent.verticalCenter
              text: root.badgeText(card.p)
              tint: text === "VERIFIED" ? root.go : root.warn
              visible: text !== ""
              HoverHandler { id: badgeHover }
              Tip {
                visible: badgeHover.hovered && text !== "" && !root.explain
                text: root.badgeTip(card.p)
              }
            }
          }
          Text {
            width: parent.width
            elide: Text.ElideRight
            text: {
              var bits = [card.p.category]
              if (card.rank.copies) bits.push("#" + root.fmt(card.rank.copies) + " by installs · top " + Math.max(1, Math.ceil(100 * card.rank.copies / card.rank.of)) + "%")
              return bits.filter(function(b) { return !!b }).join(" · ")
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            HoverHandler { id: rankHover }
            Tip {
              visible: rankHover.hovered && !!card.rank.copies && !root.explain
              text: root.rankTip(card.rank)
            }
          }
        }
        BarChart {
          id: cardSpark
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(70)
          height: Style.space(22)
          compact: true
          points: (card.p.series || []).map(function(d) { return [d[0], d[1]] })
        }
      }
      Row {
        spacing: Style.space(14)
        Metric { glyph: root.eyeGlyph; n: card.p.views || 0; delta: card.p.viewsWeek || 0; label: "views"; tip: root.cardTip(root.tips.views, true) }
        Metric { glyph: root.copyGlyph; n: card.p.copies || 0; delta: card.p.copiesWeek || 0; label: "copies"; tip: root.cardTip(root.tips.copies, true) }
        Metric { glyph: root.heartGlyph; tint: root.pink; n: card.p.hearts || 0; delta: card.p.heartsWeek || 0; label: "hearts"; tip: root.cardTip(root.tips.hearts, true) }
        Metric { visible: !!card.repo && !!card.repo.traffic; glyph: root.cloneGlyph; n: card.repo && card.repo.traffic ? card.repo.traffic.uclones : 0; delta: 0; label: "cloners · 14d"; tip: root.tips.pluginCloners }
      }
    }
  }

  component Metric: Row {
    property string glyph: ""
    property color tint: root.dim
    property int n: 0
    property int delta: 0
    property string label: ""
    property string tip: ""
    spacing: Style.space(4)
    HoverHandler { id: metricHover }
    Tip {
      visible: metricHover.hovered && parent.tip !== "" && !root.explain
      text: parent.tip
    }
    Text { anchors.verticalCenter: parent.verticalCenter; text: parent.glyph; color: parent.tint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Text { anchors.verticalCenter: parent.verticalCenter; text: root.fmt(parent.n); color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
    Text { anchors.verticalCenter: parent.verticalCenter; text: parent.label; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Text {
      visible: parent.delta > 0
      anchors.verticalCenter: parent.verticalCenter
      text: "+" + root.fmt(parent.delta) + " wk"
      color: root.go
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
