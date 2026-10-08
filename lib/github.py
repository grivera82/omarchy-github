#!/usr/bin/env python3
"""Your GitHub at a glance, for the grivera.github Omarchy plugin.

Contributions and streaks, stars, forks and followers, repo traffic (views and
unique cloners), your review queue and PRs with their checks, GitHub
notifications, and the Omarchy plugin marketplace numbers for any plugin whose
repo you own. Counts are kept day by day under ~/.local/state/grivera-github,
so traffic history outlives GitHub's 14-day window.

Auth comes from $GH_TOKEN / $GITHUB_TOKEN, then `gh auth token`, then a token in
~/.config/grivera-github/token. The token is kept in memory only.

Standard library only.

  github status [--json]     summary from the daemon's last snapshot
  github open [URL]          open your profile (or a github.com URL) in the browser
  github daemon              JSON state lines on stdout, commands on stdin
"""

import concurrent.futures
import datetime
import gzip
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "grivera-github")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "grivera-github")
CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
TOKEN_FILE = os.path.join(CONFIG_HOME, "grivera-github", "token")
CONFIG_FILE = os.path.join(STATE_DIR, "config.json")
ACTIVITY_FILE = os.path.join(STATE_DIR, "activity.json")
HISTORY_FILE = os.path.join(STATE_DIR, "history.json")
TRAFFIC_FILE = os.path.join(STATE_DIR, "traffic.json")
MARKET_FILE = os.path.join(STATE_DIR, "market.json")
KNOWN_FILE = os.path.join(STATE_DIR, "known.json")
SNAPSHOT_FILE = os.path.join(CACHE_DIR, "snapshot.json")
AVATAR_FILE = os.path.join(CACHE_DIR, "avatar.png")
LIB = os.path.dirname(os.path.abspath(__file__))
ICON = os.path.join(os.path.dirname(LIB), "assets", "github.svg")

API = "https://api.github.com"
CATALOG_URL = "https://plugins.omarchy.org/catalog.json"
STATS_URL = "https://api.omarchyplugins.com/v1/stats"
LISTING_URL = "https://omarchyplugins.com/plugin.html?id=%s"
UA = "grivera-github/1.0 (Omarchy plugin)"
TICK = 5
ACTIVITY_KEEP = 300

DEFAULT_CONFIG = {
    "barMode": "activity",       # activity | streak | today | clones | installs | inbox | icon
    "includePrivate": True,
    "includeForks": False,
    "marketplace": True,
    "notifyStars": True,
    "notifyFollowers": True,
    "notifyForks": True,
    "notifyIssues": True,
    "notifyReviews": True,
    "notifyChecks": True,
    "notifyHearts": True,
    "notifyInstalls": False,
    "notifyClones": False,
    "notifyInbox": False,
    "streakReminder": False,
    "streakHour": 20,
}

# seconds between fetches: (normal, while the panel is open)
INTERVALS = {
    "overview": (600, 180),
    "inbox": (300, 90),
    "notifications": (60, 60),
    "traffic": (3600, 1800),
    "stats": (1800, 900),
    "catalog": (21600, 21600),
}


# ---------------------------------------------------------------- helpers

def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, threading.get_ident())
    with open(tmp, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.replace(tmp, path)


def parse_ts(s):
    if not s:
        return 0
    try:
        return int(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def today_str(offset_days=0):
    return (datetime.date.today() + datetime.timedelta(days=offset_days)).isoformat()


def open_url(url):
    if not url or not re.match(r"^https?://", url):
        return False
    for cmd in (["omarchy-launch-browser", url], ["xdg-open", url]):
        if shutil.which(cmd[0]):
            subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
            return True
    return False


def html_url(api_url, repo_full):
    """REST subject URL -> the page a person would open."""
    base = "https://github.com/" + repo_full
    if not api_url:
        return base
    m = re.match(r"https://api\.github\.com/repos/[^/]+/[^/]+/(pulls|issues|commits|releases)/(\w+)", api_url)
    if not m:
        return base
    kind, ref = m.groups()
    if kind == "pulls":
        return "%s/pull/%s" % (base, ref)
    if kind == "issues":
        return "%s/issues/%s" % (base, ref)
    if kind == "commits":
        return "%s/commit/%s" % (base, ref)
    return base + "/releases"


def plural(n, word, many=None):
    return "%d %s" % (n, word if n == 1 else (many or word + "s"))


# ---------------------------------------------------------------- GitHub client

class AuthError(Exception):
    pass


class RateLimited(Exception):
    def __init__(self, reset):
        super().__init__("rate limited until %s" % time.strftime("%H:%M", time.localtime(reset)))
        self.reset = reset


class ApiError(Exception):
    pass


def resolve_token():
    for var in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(var, "").strip():
            return os.environ[var].strip(), "$" + var
    if shutil.which("gh"):
        try:
            out = subprocess.run(["gh", "auth", "token", "--hostname", "github.com"], capture_output=True,
                                 text=True, timeout=15, stdin=subprocess.DEVNULL)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip(), "gh"
        except (OSError, subprocess.SubprocessError):
            pass
    try:
        with open(TOKEN_FILE) as f:
            tok = f.read().strip()
        if tok:
            return tok, "file"
    except OSError:
        pass
    return None, None


class GitHub:
    def __init__(self):
        self.token, self.source = None, None
        self.scopes = None
        self.etags = {}           # url -> (etag, parsed body)
        self.rate = {}            # resource -> {remaining, limit, reset}
        self.lock = threading.Lock()

    def ensure_token(self):
        if not self.token:
            self.token, self.source = resolve_token()
        if not self.token:
            raise AuthError("no GitHub token: run `gh auth login`, or put a token in " + TOKEN_FILE.replace(HOME, "~"))

    def note(self, headers):
        if headers is None:
            return
        res = headers.get("X-RateLimit-Resource")
        if res and headers.get("X-RateLimit-Remaining") is not None:
            self.rate[res] = {"remaining": int(headers["X-RateLimit-Remaining"]),
                              "limit": int(headers.get("X-RateLimit-Limit") or 0),
                              "reset": int(headers.get("X-RateLimit-Reset") or 0)}
        if headers.get("X-OAuth-Scopes") is not None:
            self.scopes = [s.strip() for s in headers["X-OAuth-Scopes"].split(",") if s.strip()]

    def request(self, method, path, body=None, accept="application/vnd.github+json", conditional=True):
        self.ensure_token()
        url = path if path.startswith("http") else API + path
        headers = {"User-Agent": UA, "Accept": accept, "X-GitHub-Api-Version": "2022-11-28",
                   "Authorization": "Bearer " + self.token}
        cached = self.etags.get(url + accept) if method == "GET" and conditional else None
        if cached:
            headers["If-None-Match"] = cached[0]
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                payload, hdrs = r.read(), r.headers
        except urllib.error.HTTPError as e:
            self.note(e.headers)
            if e.code == 304 and cached:
                return cached[1], e.headers
            text = (e.read() or b"")[:400].decode("utf-8", "replace")
            if e.code == 401:
                self.token = None
                raise AuthError("GitHub rejected the token (401); run `gh auth login` again")
            if e.code in (403, 429) and (e.headers.get("X-RateLimit-Remaining") == "0" or "rate limit" in text.lower()):
                reset = int(e.headers.get("X-RateLimit-Reset") or 0) or int(time.time()) + int(e.headers.get("Retry-After") or 60)
                raise RateLimited(reset)
            try:
                text = json.loads(text).get("message") or text
            except ValueError:
                pass
            raise ApiError("%s %s: HTTP %d %s" % (method, url.replace(API, ""), e.code, text))
        self.note(hdrs)
        out = json.loads(payload) if payload.strip() else None
        if method == "GET" and conditional and hdrs.get("ETag"):
            self.etags[url + accept] = (hdrs["ETag"], out)
        return out, hdrs

    def get(self, path, **kw):
        return self.request("GET", path, **kw)[0]

    def pages(self, path, accept="application/vnd.github+json", max_pages=10, first_page=1):
        out, page = [], first_page
        sep = "&" if "?" in path else "?"
        while page < first_page + max_pages:
            items, hdrs = self.request("GET", "%s%sper_page=100&page=%d" % (path, sep, page), accept=accept)
            out.extend(items or [])
            if 'rel="next"' not in (hdrs.get("Link") or ""):
                break
            page += 1
        return out

    def graphql(self, query, variables=None):
        out, _ = self.request("POST", "/graphql", {"query": query, "variables": variables or {}})
        if out.get("errors") and not out.get("data"):
            err = out["errors"][0]
            if err.get("type") == "RATE_LIMITED":
                raise RateLimited(int(time.time()) + 600)
            raise ApiError("GraphQL: " + (err.get("message") or "error"))
        data = out.get("data") or {}
        rl = data.get("rateLimit")
        if rl:
            self.rate["graphql"] = {"remaining": rl["remaining"], "limit": rl.get("limit") or 5000,
                                    "reset": parse_ts(rl["resetAt"])}
        return data


def fetch_public(url, etag=None, timeout=60):
    """GET a non-GitHub JSON URL -> (data or None when unchanged, etag)."""
    headers = {"User-Agent": UA, "Accept-Encoding": "gzip"}
    if etag:
        headers["If-None-Match"] = etag
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as r:
            data, new_etag = r.read(), r.headers.get("ETag")
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return None, etag
        raise ApiError("%s: HTTP %d" % (url, e.code))
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    return json.loads(data), new_etag


# ---------------------------------------------------------------- D-Bus notifications

DBUS_ALIGN = {"y": 1, "b": 4, "i": 4, "u": 4, "x": 8, "t": 8, "d": 8,
              "s": 4, "o": 4, "g": 1, "v": 1, "a": 4, "(": 8, "{": 8}
DBUS_FIXED = {"y": "B", "b": "I", "i": "i", "u": "I", "x": "q", "t": "Q", "d": "d"}


def dbus_types(sig):
    """Split a signature into its complete types: "sa{sv}i" -> s, a{sv}, i."""
    out, i = [], 0
    while i < len(sig):
        j = i
        while sig[j] == "a":
            j += 1
        if sig[j] in "({":
            depth = 0
            while True:
                depth += sig[j] in "({"
                depth -= sig[j] in ")}"
                j += 1
                if not depth:
                    break
        else:
            j += 1
        out.append(sig[i:j])
        i = j
    return out


def dbus_pad(buf, n):
    buf.extend(b"\0" * (-len(buf) % n))


def dbus_write(buf, sig, val):
    """Append one value of complete type `sig`; variants are (signature, value)."""
    c = sig[0]
    if c in DBUS_FIXED:
        dbus_pad(buf, DBUS_ALIGN[c])
        buf.extend(struct.pack("<" + DBUS_FIXED[c], val))
    elif c in "so":
        raw = val.encode()
        dbus_pad(buf, 4)
        buf.extend(struct.pack("<I", len(raw)) + raw + b"\0")
    elif c == "g":
        buf.extend(bytes([len(val)]) + val.encode() + b"\0")
    elif c == "v":
        dbus_write(buf, "g", val[0])
        dbus_write(buf, val[0], val[1])
    elif c == "a":
        dbus_pad(buf, 4)
        at = len(buf)
        buf.extend(b"\0\0\0\0")
        dbus_pad(buf, DBUS_ALIGN[sig[1]])
        start = len(buf)
        for item in (val.items() if sig[1] == "{" else val):
            dbus_write(buf, sig[1:], item)
        struct.pack_into("<I", buf, at, len(buf) - start)
    else:
        dbus_pad(buf, 8)
        for t, v in zip(dbus_types(sig[1:-1]), val):
            dbus_write(buf, t, v)


def dbus_read(data, pos, sig, end="<"):
    """One value of complete type `sig` at `pos` -> (value, new pos)."""
    c = sig[0]
    pos += -pos % DBUS_ALIGN[c]
    if c in DBUS_FIXED:
        fmt = end + DBUS_FIXED[c]
        return struct.unpack_from(fmt, data, pos)[0], pos + struct.calcsize(fmt)
    if c in "so":
        n = struct.unpack_from(end + "I", data, pos)[0]
        return data[pos + 4:pos + 4 + n].decode("utf-8", "replace"), pos + 5 + n
    if c == "g":
        n = data[pos]
        return data[pos + 1:pos + 1 + n].decode(), pos + 2 + n
    if c == "v":
        inner, pos = dbus_read(data, pos, "g", end)
        return dbus_read(data, pos, inner, end)
    if c == "a":
        n = struct.unpack_from(end + "I", data, pos)[0]
        pos += 4
        pos += -pos % DBUS_ALIGN[sig[1]]
        stop, items = pos + n, []
        while pos < stop:
            item, pos = dbus_read(data, pos, sig[1:], end)
            items.append(item)
        return (dict(items) if sig[1] == "{" else items), pos
    vals = []
    for t in dbus_types(sig[1:-1]):
        v, pos = dbus_read(data, pos, t, end)
        vals.append(v)
    return tuple(vals), pos


class SessionBus:
    """Just enough of the D-Bus wire protocol to call methods and hear signals."""

    def __init__(self, match, on_signal):
        self.match = match              # AddMatch rule for the signals we want
        self.on_signal = on_signal      # (interface, member, args)
        self.sock = None
        self.serial = 0
        self.pending = {}               # serial -> [Event, reply args, error name]
        self.lock = threading.RLock()   # connect() calls Hello while holding it

    def connect(self):
        addrs = os.environ.get("DBUS_SESSION_BUS_ADDRESS") or \
            "unix:path=%s/bus" % (os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid())
        for addr in addrs.split(";"):
            kind, _, rest = addr.partition(":")
            opts = dict(kv.split("=", 1) for kv in rest.split(",") if "=" in kv)
            if kind != "unix" or not ("path" in opts or "abstract" in opts):
                continue
            path = opts.get("path") or "\0" + opts["abstract"]
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(5)
            try:
                sock.connect(path)
                sock.sendall(b"\0AUTH EXTERNAL " + str(os.getuid()).encode().hex().encode() + b"\r\n")
                reply = b""
                while not reply.endswith(b"\r\n"):
                    chunk = sock.recv(256)
                    if not chunk:
                        raise OSError("bus closed during auth")
                    reply += chunk
                if not reply.startswith(b"OK"):
                    raise OSError("bus refused auth")
                sock.sendall(b"BEGIN\r\n")
            except OSError:
                sock.close()
                continue
            sock.settimeout(None)
            self.sock = sock
            threading.Thread(target=self.reader, args=(sock,), daemon=True).start()
            try:
                for member, sig, args in (("Hello", "", ()), ("AddMatch", "s", [self.match])):
                    self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                              member, sig, args)
            except OSError:
                self.drop()
                raise
            return
        raise OSError("no session bus")

    def call(self, dest, path, iface, member, sig="", args=(), reply=True):
        body = bytearray()
        for t, v in zip(dbus_types(sig), args):
            dbus_write(body, t, v)
        fields = [(1, ("o", path)), (2, ("s", iface)), (3, ("s", member)), (6, ("s", dest))]
        if sig:
            fields.append((8, ("g", sig)))
        with self.lock:
            if self.sock is None:
                self.connect()
            self.serial += 1
            serial = self.serial
            msg = bytearray(struct.pack("<cBBBII", b"l", 1, 0 if reply else 1, 1, len(body), serial))
            dbus_write(msg, "a(yv)", fields)
            dbus_pad(msg, 8)
            waiter = self.pending[serial] = [threading.Event(), None, None] if reply else None
            try:
                self.sock.sendall(msg + body)
            except OSError:
                self.drop()
                raise
        if not reply:
            return None
        if not waiter[0].wait(5):
            self.pending.pop(serial, None)
            raise OSError("%s timed out" % member)
        if waiter[2]:
            raise OSError(waiter[2])
        return waiter[1]

    def drop(self):
        sock, self.sock = self.sock, None
        if sock:
            sock.close()
        for waiter in self.pending.values():
            if waiter:
                waiter[2] = "bus connection lost"
                waiter[0].set()
        self.pending.clear()

    def reader(self, sock):
        buf = b""

        def need(n):
            nonlocal buf
            while len(buf) < n:
                chunk = sock.recv(65536)
                if not chunk:
                    raise OSError("bus closed")
                buf += chunk

        try:
            while True:
                need(16)
                end = "<" if buf[:1] == b"l" else ">"
                kind = buf[1]
                body_len, _, fields_len = struct.unpack_from(end + "III", buf, 4)
                start = 16 + fields_len + (-fields_len % 8)
                need(start + body_len)
                raw, buf = buf[:start + body_len], buf[start + body_len:]
                fields = dict(dbus_read(raw, 12, "a(yv)", end)[0])
                args, pos = [], start
                for t in dbus_types(fields.get(8, "")):
                    v, pos = dbus_read(raw, pos, t, end)
                    args.append(v)
                if kind in (2, 3):          # method return, error
                    waiter = self.pending.pop(fields.get(5), None)
                    if waiter:
                        waiter[1], waiter[2] = args, (fields.get(4) if kind == 3 else None)
                        waiter[0].set()
                elif kind == 4:             # signal
                    self.on_signal(fields.get(2), fields.get(3), args)
        except (OSError, struct.error, ValueError, IndexError):
            with self.lock:
                if self.sock is sock:
                    self.drop()



class Notifier:
    DEST = "org.freedesktop.Notifications"
    PATH = "/org/freedesktop/Notifications"
    URGENCY = {"low": 0, "normal": 1, "critical": 2}

    def __init__(self):
        self.bus = SessionBus("type='signal',interface='%s'" % self.DEST, self.on_signal)
        self.urls = {}            # notification id -> URL to open on click
        self.ids = {}             # replace key -> notification id

    def send(self, summary, body, url="", key=None, urgency="normal"):
        hints = {"urgency": ("y", self.URGENCY[urgency])}
        actions = ["default", "Open"] if url else []
        try:
            nid = self.bus.call(self.DEST, self.PATH, self.DEST, "Notify", "susssasa{sv}i",
                                ["GitHub", self.ids.get(key, 0) if key else 0, ICON, summary, body,
                                 actions, hints, -1])[0]
        except (OSError, IndexError):
            return
        if key:
            self.ids[key] = nid
        if url:
            self.urls[nid] = url
            if len(self.urls) > 200:
                self.urls.pop(next(iter(self.urls)))

    def on_signal(self, iface, member, args):
        if iface != self.DEST or not args:
            return
        if member == "ActionInvoked" and args[1:2] == ["default"]:
            url = self.urls.pop(args[0], None)
            if url:
                open_url(url)
        elif member == "NotificationClosed":
            self.urls.pop(args[0], None)


# ---------------------------------------------------------------- queries

OVERVIEW_Q = """
query($from: DateTime!, $to: DateTime!, $after: String) {
  rateLimit { remaining limit resetAt }
  viewer {
    login name avatarUrl url createdAt
    followers { totalCount }
    following { totalCount }
    contributionsCollection(from: $from, to: $to) {
      totalCommitContributions totalPullRequestContributions totalIssueContributions
      totalPullRequestReviewContributions totalRepositoryContributions restrictedContributionsCount
      contributionCalendar { totalContributions weeks { contributionDays { date contributionCount contributionLevel } } }
    }
    repositories(first: 100, after: $after, ownerAffiliations: OWNER, orderBy: {field: PUSHED_AT, direction: DESC}) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes {
        name nameWithOwner url description isPrivate isFork isArchived stargazerCount forkCount pushedAt createdAt
        watchers { totalCount }
        issues(states: OPEN) { totalCount }
        pullRequests(states: OPEN) { totalCount }
        primaryLanguage { name color }
        defaultBranchRef { target { ... on Commit { statusCheckRollup { state } } } }
        latestRelease { tagName publishedAt url }
      }
    }
  }
}"""

INBOX_Q = """
query($reviews: String!, $mine: String!, $assigned: String!) {
  rateLimit { remaining limit resetAt }
  reviews: search(query: $reviews, type: ISSUE, first: 20) { issueCount nodes { ...pr } }
  mine: search(query: $mine, type: ISSUE, first: 20) { issueCount nodes { ...pr } }
  assigned: search(query: $assigned, type: ISSUE, first: 20) { issueCount nodes { ...issue ...pr } }
}
fragment pr on PullRequest {
  __typename id number title url isDraft createdAt updatedAt additions deletions reviewDecision mergeable
  repository { nameWithOwner isPrivate } author { login } comments { totalCount }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
}
fragment issue on Issue {
  __typename id number title url createdAt updatedAt
  repository { nameWithOwner isPrivate } author { login } comments { totalCount }
}"""

CLOSED_Q = """
query($ids: [ID!]!) {
  nodes(ids: $ids) { ... on PullRequest { id number title url merged state repository { nameWithOwner } } }
}"""

LEVELS = {"NONE": 0, "FIRST_QUARTILE": 1, "SECOND_QUARTILE": 2, "THIRD_QUARTILE": 3, "FOURTH_QUARTILE": 4}


def norm_repo(r):
    target = (r.get("defaultBranchRef") or {}).get("target") or {}
    rel = r.get("latestRelease") or {}
    lang = r.get("primaryLanguage") or {}
    return {
        "name": r["name"], "full": r["nameWithOwner"], "url": r["url"], "desc": r.get("description") or "",
        "private": r["isPrivate"], "fork": r["isFork"], "archived": r["isArchived"],
        "stars": r["stargazerCount"], "forks": r["forkCount"], "watchers": r["watchers"]["totalCount"],
        "issues": r["issues"]["totalCount"], "prs": r["pullRequests"]["totalCount"],
        "lang": lang.get("name") or "", "langColor": lang.get("color") or "",
        "pushedAt": parse_ts(r.get("pushedAt")), "createdAt": parse_ts(r.get("createdAt")),
        "ci": (target.get("statusCheckRollup") or {}).get("state") or "",
        "release": {"tag": rel["tagName"], "at": parse_ts(rel.get("publishedAt")), "url": rel.get("url")} if rel else None,
    }


def norm_item(n):
    if not n or not n.get("__typename"):
        return None
    commits = ((n.get("commits") or {}).get("nodes") or [])
    rollup = ((commits[0].get("commit") or {}).get("statusCheckRollup") or {}) if commits else {}
    return {
        "id": n["id"], "kind": "pr" if n["__typename"] == "PullRequest" else "issue",
        "number": n["number"], "title": n["title"], "url": n["url"],
        "repo": n["repository"]["nameWithOwner"], "private": n["repository"]["isPrivate"],
        "author": (n.get("author") or {}).get("login") or "ghost",
        "draft": bool(n.get("isDraft")), "created": parse_ts(n.get("createdAt")), "updated": parse_ts(n.get("updatedAt")),
        "comments": (n.get("comments") or {}).get("totalCount") or 0,
        "adds": n.get("additions") or 0, "dels": n.get("deletions") or 0,
        "ci": rollup.get("state") or "", "review": n.get("reviewDecision") or "", "mergeable": n.get("mergeable") or "",
    }


def contrib_stats(weeks):
    days, col = [], 0
    for w in weeks:
        for d in w["contributionDays"]:
            date = datetime.date.fromisoformat(d["date"])
            days.append([d["date"], d["contributionCount"], LEVELS.get(d["contributionLevel"], 0), col, (date.weekday() + 1) % 7])
        col += 1
    today = today_str()
    days = [d for d in days if d[0] <= today]
    counts = [d[1] for d in days]
    # The streak survives a zero today: the day isn't over yet.
    i = len(days) - 1
    if i >= 0 and days[i][0] == today and counts[i] == 0:
        i -= 1
    streak = 0
    while i >= 0 and counts[i] > 0:
        streak += 1
        i -= 1
    longest = run = 0
    for c in counts:
        run = run + 1 if c > 0 else 0
        longest = max(longest, run)
    best = max(days, key=lambda d: d[1]) if days else None
    active = sum(1 for c in counts if c)
    week, prev = sum(counts[-7:]), sum(counts[-14:-7])
    return {
        "days": days, "weeks": col, "streak": streak, "longest": longest,
        "today": counts[-1] if days and days[-1][0] == today else 0,
        "week": week, "prevWeek": prev, "month": sum(counts[-30:]),
        "best": {"date": best[0], "count": best[1]} if best and best[1] else None,
        "activeDays": active, "perActiveDay": round(sum(counts) / active, 1) if active else 0,
    }


def traffic_summary(entry):
    days = entry.get("days") or {}
    keys = sorted(days)
    last14 = []
    end = datetime.date.today()
    for k in range(13, -1, -1):
        d = (end - datetime.timedelta(days=k)).isoformat()
        last14.append([d] + list(days.get(d, [0, 0, 0, 0])))
    return {
        "views": entry.get("views", 0), "uviews": entry.get("uviews", 0),
        "clones": entry.get("clones", 0), "uclones": entry.get("uclones", 0),
        "allViews": sum(v[0] for v in days.values()), "allClones": sum(v[2] for v in days.values()),
        "since": keys[0] if keys else "", "days": last14,
        "referrers": entry.get("referrers") or [], "paths": entry.get("paths") or [],
    }


# ---------------------------------------------------------------- engine

class Engine:
    def __init__(self, emit=None, notify=True):
        self.emit = emit or (lambda obj: None)
        self.gh = GitHub()
        self.config = dict(DEFAULT_CONFIG)
        self.config.update(load_json(CONFIG_FILE, {}))
        self.known = load_json(KNOWN_FILE, {})
        self.activity = load_json(ACTIVITY_FILE, {"items": [], "seen": 0})
        self.history = load_json(HISTORY_FILE, {})
        self.traffic = load_json(TRAFFIC_FILE, {})
        self.market = load_json(MARKET_FILE, {"listings": {}, "days": {}, "ranks": {}, "etag": None, "total": 0})
        self.raw = load_json(os.path.join(CACHE_DIR, "raw.json"), {})
        self.fetched = dict(self.raw.get("fetched") or {})
        self.notifier = Notifier() if notify else None
        self.pending = []           # notifications gathered during one fetch
        self.retry_at = {}
        self.force = set()
        self.manual = set()         # feeds a manual refresh is still waiting on
        self.errors = {}
        self.status = "starting" if not self.raw.get("overview") else "ok"
        self.error = ""
        self.poll_interval = 60
        self.ui_open = False
        self.wake = threading.Event()
        self.lock = threading.RLock()
        # Fetched once per daemon run even when the cache is fresh, so the bar is current after a reboot.
        for feed in INTERVALS:
            if feed not in ("catalog", "traffic"):
                self.fetched[feed] = 0

    # ---- persistence

    def save_raw(self):
        self.raw["fetched"] = self.fetched
        try:
            save_json(os.path.join(CACHE_DIR, "raw.json"), self.raw)
        except OSError:
            pass

    def save(self, *which):
        files = {"known": (KNOWN_FILE, self.known), "activity": (ACTIVITY_FILE, self.activity),
                 "history": (HISTORY_FILE, self.history), "traffic": (TRAFFIC_FILE, self.traffic),
                 "market": (MARKET_FILE, self.market), "config": (CONFIG_FILE, self.config)}
        for name in which:
            try:
                save_json(*files[name])
            except OSError:
                pass

    @property
    def login(self):
        return ((self.raw.get("overview") or {}).get("user") or {}).get("login") or ""

    # ---- activity & notifications

    NOTIFY_KEYS = {"star": "notifyStars", "follow": "notifyFollowers", "fork": "notifyForks",
                   "issue": "notifyIssues", "pr": "notifyIssues", "review": "notifyReviews",
                   "assigned": "notifyReviews", "check": "notifyChecks", "approved": "notifyChecks",
                   "changes": "notifyChecks", "merged": "notifyChecks", "heart": "notifyHearts",
                   "copy": "notifyInstalls", "clone": "notifyClones", "inbox": "notifyInbox"}

    def add(self, kind, text, url="", repo="", actor="", t=None, key=None, notify=True, summary=None, body=None):
        items = self.activity["items"]
        item = {"kind": kind, "text": text, "url": url, "repo": repo, "actor": actor, "t": int(t or time.time())}
        if key:
            item["key"] = key
            items[:] = [i for i in items if i.get("key") != key]
        items.insert(0, item)
        items.sort(key=lambda i: -i["t"])
        del items[ACTIVITY_KEEP:]
        if notify and self.config.get(self.NOTIFY_KEYS.get(kind, ""), False):
            self.pending.append((kind, summary or text, body or "", url, key))

    def flush_notifications(self):
        pending, self.pending = self.pending, []
        if not self.notifier or not pending:
            return
        by_kind = {}
        for p in pending:
            by_kind.setdefault(p[0], []).append(p)
        for kind, group in by_kind.items():
            if len(group) > 3:
                titles = {"star": "new stars", "follow": "new followers", "fork": "new forks",
                          "issue": "new issues", "pr": "new pull requests", "inbox": "GitHub notifications"}
                self.notifier.send("%d %s" % (len(group), titles.get(kind, "updates")),
                                   "\n".join(g[1] for g in group[:6]) + ("\n…" if len(group) > 6 else ""),
                                   "https://github.com/notifications" if kind == "inbox" else
                                   "https://github.com/" + self.login)
            else:
                for _, summary, body, url, key in group:
                    self.notifier.send(summary, body, url, key=key)

    def mark_seen(self):
        items = self.activity["items"]
        if items and items[0]["t"] > self.activity.get("seen", 0):
            self.activity["seen"] = items[0]["t"]
            self.save("activity")

    # ---- feeds

    def fetch_overview(self):
        now = datetime.datetime.now().astimezone().replace(microsecond=0)
        start = (now - datetime.timedelta(days=364)).replace(hour=0, minute=0, second=0)
        repos, after, data = [], None, None
        for _ in range(5):
            data = self.gh.graphql(OVERVIEW_Q, {"from": start.isoformat(), "to": now.isoformat(), "after": after})
            page = data["viewer"]["repositories"]
            repos += [norm_repo(r) for r in page["nodes"] if r]
            if not page["pageInfo"]["hasNextPage"]:
                break
            after = page["pageInfo"]["endCursor"]
        v = data["viewer"]
        cc = v["contributionsCollection"]
        user = {"login": v["login"], "name": v.get("name") or "", "url": v["url"], "avatarUrl": v["avatarUrl"],
                "followers": v["followers"]["totalCount"], "following": v["following"]["totalCount"],
                "repos": len(repos), "createdAt": parse_ts(v.get("createdAt"))}
        contrib = contrib_stats(cc["contributionCalendar"]["weeks"])
        contrib.update({"total": cc["contributionCalendar"]["totalContributions"],
                        "commits": cc["totalCommitContributions"], "prs": cc["totalPullRequestContributions"],
                        "issues": cc["totalIssueContributions"], "reviews": cc["totalPullRequestReviewContributions"],
                        "newRepos": cc["totalRepositoryContributions"], "private": cc["restrictedContributionsCount"]})
        prev = self.raw.get("overview") or {}
        self.raw["overview"] = {"user": user, "contrib": contrib, "repos": repos}
        self.diff_followers(user)
        for r in repos:
            if r["fork"]:
                continue
            self.diff_stars(r)
            self.diff_forks(r)
            self.diff_issues(r)
            self.diff_release(r)
        self.save("known", "activity")
        today = today_str()
        totals = self.totals()
        self.history[today] = {"stars": totals["stars"], "forks": totals["forks"], "followers": user["followers"],
                               "contrib": contrib["today"], "repos": len(repos)}
        for old in sorted(self.history)[:-800]:
            del self.history[old]
        self.save("history")
        self.fetch_avatar(user["avatarUrl"], prev)

    def fetch_avatar(self, url, prev):
        try:
            fresh = time.time() - os.path.getmtime(AVATAR_FILE) < 86400
        except OSError:
            fresh = False
        if fresh and ((prev.get("user") or {}).get("avatarUrl") == url):
            return
        try:
            sep = "&" if "?" in url else "?"
            with urllib.request.urlopen(urllib.request.Request(url + sep + "s=160", headers={"User-Agent": UA}), timeout=20) as r:
                data = r.read()
            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(AVATAR_FILE + ".tmp", "wb") as f:
                f.write(data)
            os.replace(AVATAR_FILE + ".tmp", AVATAR_FILE)
        except (OSError, urllib.error.URLError):
            pass

    def diff_followers(self, user):
        known = self.known.get("followers")
        if known is not None and self.known.get("followersCount") == user["followers"]:
            return
        logins = [f["login"] for f in self.gh.pages("/user/followers", max_pages=20)]
        self.known["followersCount"] = user["followers"]
        self.known["followers"] = logins
        if known is None:
            return
        old = set(known)
        for login in logins:
            if login not in old:
                self.add("follow", "%s followed you" % login, "https://github.com/" + login, actor=login,
                         summary="New follower", body="%s followed you on GitHub" % login)
        for login in old - set(logins):
            self.add("unfollow", "%s unfollowed you" % login, "https://github.com/" + login, actor=login, notify=False)

    def diff_stars(self, r):
        stars = self.known.setdefault("stars", {})
        known = stars.get(r["full"])
        if known is not None and len(known) == r["stars"]:
            return
        if r["stars"] == 0:
            gone = known or []
            stars[r["full"]] = []
        else:
            accept = "application/vnd.github.star+json"
            first = 1
            if known and r["stars"] > len(known):
                first = len(known) // 100 + 1
            got = self.gh.pages("/repos/%s/stargazers" % r["full"], accept=accept, max_pages=30, first_page=first)
            fresh = [[s["user"]["login"], parse_ts(s["starred_at"])] for s in got if s.get("user")]
            if first > 1:
                seen = {s[0] for s in fresh}
                fresh = [s for s in known[:(first - 1) * 100] if s[0] not in seen] + fresh
            gone = [s for s in (known or []) if s[0] not in {f[0] for f in fresh}] if first == 1 else []
            stars[r["full"]] = fresh
        if known is None:
            return
        had = {s[0] for s in known}
        for login, ts in stars[r["full"]]:
            if login not in had:
                self.add("star", "%s starred %s" % (login, r["name"]), "https://github.com/" + login,
                         repo=r["full"], actor=login, t=ts,
                         summary="★ %s starred %s" % (login, r["name"]),
                         body="%s now has %s" % (r["name"], plural(r["stars"], "star")))
        for login, _ in gone:
            self.add("unstar", "%s unstarred %s" % (login, r["name"]), r["url"], repo=r["full"], actor=login, notify=False)

    def diff_forks(self, r):
        forks = self.known.setdefault("forks", {})
        known = forks.get(r["full"])
        if known is not None and len(known) >= r["forks"]:
            return
        if r["forks"] == 0:
            forks[r["full"]] = []
            return
        got = self.gh.get("/repos/%s/forks?sort=newest&per_page=100" % r["full"]) or []
        owners = [f["owner"]["login"] for f in got]
        forks[r["full"]] = sorted(set(owners) | set(known or []))
        if known is None:
            return
        for f in got:
            if f["owner"]["login"] not in known:
                self.add("fork", "%s forked %s" % (f["owner"]["login"], r["name"]), f["html_url"],
                         repo=r["full"], actor=f["owner"]["login"], t=parse_ts(f.get("created_at")),
                         summary="%s forked %s" % (f["owner"]["login"], r["name"]), body=f["full_name"])

    def diff_issues(self, r):
        counts = self.known.setdefault("issueCounts", {})
        seen = self.known.setdefault("issuesSeen", {})
        now = r["issues"] + r["prs"]
        before = counts.get(r["full"])
        counts[r["full"]] = now
        if before is None:
            seen.setdefault(r["full"], [])
            if now == 0:
                return
        elif now <= before:
            return
        got = self.gh.get("/repos/%s/issues?state=all&sort=created&direction=desc&per_page=15" % r["full"]) or []
        nums = set(seen.get(r["full"]) or [])
        for it in got:
            if it["number"] in nums:
                continue
            nums.add(it["number"])
            author = (it.get("user") or {}).get("login") or "ghost"
            if before is None or author == self.login:
                continue
            kind = "pr" if it.get("pull_request") else "issue"
            noun = "pull request" if kind == "pr" else "issue"
            self.add(kind, "%s opened #%d in %s: %s" % (author, it["number"], r["name"], it["title"]), it["html_url"],
                     repo=r["full"], actor=author, t=parse_ts(it.get("created_at")),
                     summary="New %s on %s" % (noun, r["name"]), body="#%d %s · by %s" % (it["number"], it["title"], author))
        seen[r["full"]] = sorted(nums)[-200:]

    def diff_release(self, r):
        rel = self.known.setdefault("releases", {})
        tag = (r.get("release") or {}).get("tag") or ""
        before = rel.get(r["full"])
        rel[r["full"]] = tag
        if before is not None and tag and tag != before:
            self.add("release", "Released %s %s" % (r["name"], tag), r["release"].get("url") or r["url"],
                     repo=r["full"], t=r["release"].get("at"), notify=False)

    def traffic_repos(self):
        repos = (self.raw.get("overview") or {}).get("repos") or []
        return [r for r in repos if not r["fork"] and not r["archived"]
                and (self.config.get("includePrivate", True) or not r["private"])]

    def fetch_traffic(self):
        repos = self.traffic_repos()

        def one(r):
            views = self.gh.get("/repos/%s/traffic/views" % r["full"])
            clones = self.gh.get("/repos/%s/traffic/clones" % r["full"])
            refs = paths = []
            if views.get("count"):
                refs = self.gh.get("/repos/%s/traffic/popular/referrers" % r["full"]) or []
                paths = self.gh.get("/repos/%s/traffic/popular/paths" % r["full"]) or []
            return r, views, clones, refs, paths

        with concurrent.futures.ThreadPoolExecutor(6) as pool:
            results = list(pool.map(one, repos))
        clone_days = self.known.setdefault("cloneDay", {})
        for r, views, clones, refs, paths in results:
            entry = self.traffic.setdefault(r["full"], {"days": {}})
            days = entry["days"]
            for v in views.get("views") or []:
                d = v["timestamp"][:10]
                days[d] = [v["count"], v["uniques"]] + (days.get(d) or [0, 0, 0, 0])[2:]
            for c in clones.get("clones") or []:
                d = c["timestamp"][:10]
                days[d] = (days.get(d) or [0, 0, 0, 0])[:2] + [c["count"], c["uniques"]]
            for old in sorted(days)[:-800]:
                del days[old]
            entry.update({"views": views.get("count", 0), "uviews": views.get("uniques", 0),
                          "clones": clones.get("count", 0), "uclones": clones.get("uniques", 0),
                          "referrers": [{"name": x["referrer"], "count": x["count"], "uniques": x["uniques"]} for x in refs[:6]],
                          "paths": [{"path": x["path"], "title": x["title"], "count": x["count"], "uniques": x["uniques"]} for x in paths[:6]],
                          "at": int(time.time())})
            # Unique cloners on GitHub's current (UTC) day, one activity row per repo per day.
            latest = (clones.get("clones") or [])[-1:] or [None]
            latest = latest[0]
            if not latest:
                continue
            day, uniq, count = latest["timestamp"][:10], latest["uniques"], latest["count"]
            before = clone_days.get(r["full"])
            clone_days[r["full"]] = [day, uniq]
            if before is None or uniq <= (before[1] if before[0] == day else 0):
                continue
            gained = uniq - (before[1] if before[0] == day else 0)
            self.add("clone", "%s: %s on %s" % (r["name"], plural(uniq, "unique cloner"),
                                               "today" if day == datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d") else day),
                     "%s/graphs/traffic" % r["url"], repo=r["full"], key="clone:%s:%s" % (r["full"], day),
                     summary="%s cloned %s" % (plural(gained, "new person", "new people"), r["name"]),
                     body="%s and %s clones today" % (plural(uniq, "unique cloner"), count))
        self.save("traffic", "known", "activity")

    def fetch_catalog(self):
        login = self.login.lower()
        if not login:
            return
        data, etag = fetch_public(CATALOG_URL, self.market.get("etag"), timeout=120)
        if data is None:
            return
        mine = {}
        prefix = "https://github.com/%s/" % login
        for p in data.get("plugins") or []:
            repo = (p.get("repo") or "").lower().rstrip("/")
            if repo.removesuffix(".git").startswith(prefix):
                mine[p["id"]] = {
                    "id": p["id"], "name": p.get("name") or p["id"], "version": p.get("version") or "",
                    "repo": p.get("repo"), "repoName": repo.removesuffix(".git").split("/")[-1],
                    "category": p.get("category") or "", "tags": p.get("tags") or [],
                    "verification": p.get("verificationStatus") or "", "status": p.get("status") or "",
                    "upToDate": bool(p.get("verificationCommit")) and p.get("verificationCommit") == p.get("upstreamObservedCommit"),
                    "listedAt": parse_ts(p.get("listedAt")), "accent": p.get("accent") or "", "initials": p.get("initials") or "",
                }
        self.market["listings"] = mine
        self.market["etag"] = etag
        self.market["total"] = len(data.get("plugins") or [])
        self.save("market")

    def fetch_stats(self):
        listings = self.market.get("listings") or {}
        if not listings:
            return
        data, _ = fetch_public(STATS_URL)
        stats = (data or {}).get("plugins") or {}
        today = today_str()
        last = self.known.setdefault("market", {})
        allc = sorted((s.get("copies") or 0 for s in stats.values()), reverse=True)
        allv = sorted((s.get("views") or 0 for s in stats.values()), reverse=True)
        ranks = {}
        for pid, info in listings.items():
            s = stats.get(pid)
            if not s:
                continue
            v, c, h = s.get("views") or 0, s.get("copies") or 0, s.get("hearts") or 0
            self.market["days"].setdefault(pid, {})[today] = [v, c, h]
            ranks[pid] = {"copies": 1 + sum(1 for x in allc if x > c), "views": 1 + sum(1 for x in allv if x > v),
                          "of": len(stats)}
            before = last.get(pid)
            last[pid] = [v, c, h]
            first = self.market.setdefault("first", {}).get(pid)
            if not first or first[0] != today:
                self.market["first"][pid] = [today, before[1] if before else c]
            if before is None:
                continue
            if h > before[2]:
                n = h - before[2]
                self.add("heart", "%s got %s" % (info["name"], plural(n, "heart")), LISTING_URL % pid, repo=pid,
                         summary="♥ %s" % info["name"], body="%s on the Omarchy marketplace (%d total)" % (plural(n, "new heart"), h))
            if c > before[1]:
                start = self.copies_base(pid)
                self.add("copy", "%s: %s today" % (info["name"], plural(c - start, "install copy", "install copies")),
                         LISTING_URL % pid, repo=pid, key="copy:%s:%s" % (pid, today),
                         summary="%s copied" % info["name"], body="%s today, %d all time" % (plural(c - start, "install copy", "install copies"), c))
        for pid in self.market["days"]:
            for old in sorted(self.market["days"][pid])[:-800]:
                del self.market["days"][pid][old]
        self.market["ranks"] = ranks
        self.save("market", "known", "activity")

    def copies_base(self, pid):
        """Install copies at the start of today: yesterday's last count, else the first one seen today."""
        yesterday = ((self.market.get("days") or {}).get(pid) or {}).get(today_str(-1))
        if yesterday:
            return yesterday[1]
        first = (self.market.get("first") or {}).get(pid)
        return first[1] if first and first[0] == today_str() else None

    def fetch_inbox(self):
        login = self.login
        if not login:
            return
        data = self.gh.graphql(INBOX_Q, {
            "reviews": "is:open is:pr archived:false review-requested:%s" % login,
            "mine": "is:open is:pr archived:false author:%s sort:updated-desc" % login,
            "assigned": "is:open archived:false assignee:%s sort:updated-desc" % login,
        })
        inbox = {}
        for k in ("reviews", "mine", "assigned"):
            inbox[k] = [i for i in (norm_item(n) for n in data[k]["nodes"]) if i]
            inbox[k + "Count"] = data[k]["issueCount"]
        known = self.known.get("inbox")
        self.known["inbox"] = {
            "reviews": [i["id"] for i in inbox["reviews"]],
            "assigned": [i["id"] for i in inbox["assigned"]],
            "mine": {i["id"]: [i["ci"], i["review"], i["title"], i["url"], i["number"], i["repo"]] for i in inbox["mine"]},
        }
        self.raw["inbox"] = inbox
        if known is None:
            self.save("known")
            return
        for i in inbox["reviews"]:
            if i["id"] not in known["reviews"]:
                self.add("review", "%s asked for your review on %s#%d" % (i["author"], i["repo"].split("/")[1], i["number"]),
                         i["url"], repo=i["repo"], actor=i["author"],
                         summary="Review requested by %s" % i["author"], body="%s#%d %s" % (i["repo"], i["number"], i["title"]))
        for i in inbox["assigned"]:
            if i["id"] not in known["assigned"] and i["author"] != login:
                self.add("assigned", "Assigned to you: %s#%d" % (i["repo"].split("/")[1], i["number"]), i["url"],
                         repo=i["repo"], summary="Assigned to you", body="%s#%d %s" % (i["repo"], i["number"], i["title"]))
        for i in inbox["mine"]:
            was = known["mine"].get(i["id"])
            if not was:
                continue
            short = "%s#%d" % (i["repo"].split("/")[1], i["number"])
            if i["ci"] != was[0] and i["ci"] in ("SUCCESS", "FAILURE", "ERROR"):
                ok = i["ci"] == "SUCCESS"
                self.add("check", "Checks %s on %s" % ("passed" if ok else "failed", short), i["url"] + "/checks",
                         repo=i["repo"], summary=("✓ Checks passed" if ok else "✗ Checks failed") + " · " + short,
                         body=i["title"], key="check:%s" % i["id"])
            if i["review"] != was[1] and i["review"] in ("APPROVED", "CHANGES_REQUESTED"):
                kind = "approved" if i["review"] == "APPROVED" else "changes"
                self.add(kind, "%s %s" % (short, "approved" if kind == "approved" else "needs changes"), i["url"],
                         repo=i["repo"], summary=("Approved · " if kind == "approved" else "Changes requested · ") + short,
                         body=i["title"])
        gone = [pid for pid in known["mine"] if pid not in self.known["inbox"]["mine"]]
        if gone:
            try:
                nodes = self.gh.graphql(CLOSED_Q, {"ids": gone[:20]}).get("nodes") or []
            except ApiError:
                nodes = []
            for n in nodes:
                if n and n.get("merged"):
                    short = "%s#%d" % (n["repository"]["nameWithOwner"].split("/")[1], n["number"])
                    self.add("merged", "Merged %s: %s" % (short, n["title"]), n["url"], repo=n["repository"]["nameWithOwner"],
                             summary="Merged · " + short, body=n["title"])
        self.save("known", "activity")

    def fetch_notifications(self):
        try:
            items, hdrs = self.gh.request("GET", "/notifications?per_page=50")
        except ApiError as e:
            if "HTTP 403" in str(e) or "HTTP 404" in str(e):
                self.raw["notifications"] = {"items": [], "unavailable": True}
                self.fetched["notifications"] = time.time() + 3600   # fine-grained tokens can't read these
                return
            raise
        self.poll_interval = max(60, int(hdrs.get("X-Poll-Interval") or 60))
        out = []
        for n in items or []:
            repo = n["repository"]["full_name"]
            out.append({"id": n["id"], "title": n["subject"]["title"], "type": n["subject"]["type"],
                        "reason": n.get("reason") or "", "repo": repo, "private": n["repository"].get("private", False),
                        "updated": parse_ts(n.get("updated_at")), "url": html_url(n["subject"].get("url"), repo)})
        known = self.known.get("threads")
        self.known["threads"] = {n["id"]: n["updated"] for n in out}
        self.raw["notifications"] = {"items": out}
        if known is not None:
            for n in out:
                if n["updated"] > (known.get(n["id"]) or 0):
                    self.add("inbox", "%s · %s" % (n["repo"].split("/")[1], n["title"]), n["url"], repo=n["repo"],
                             key="inbox:" + n["id"], summary=n["repo"], body=n["title"])
        self.save("known", "activity")

    def mark_read(self, thread=None):
        notes = self.raw.get("notifications") or {}
        if thread:
            self.gh.request("PATCH", "/notifications/threads/%s" % thread)
            notes["items"] = [n for n in notes.get("items") or [] if n["id"] != thread]
        else:
            self.gh.request("PUT", "/notifications", {"read": True})
            notes["items"] = []
        self.raw["notifications"] = notes
        self.save_raw()

    def check_streak(self):
        if not self.config.get("streakReminder"):
            return
        contrib = (self.raw.get("overview") or {}).get("contrib") or {}
        now = datetime.datetime.now()
        if now.hour < int(self.config.get("streakHour", 20)) or contrib.get("today") or contrib.get("streak", 0) < 1:
            return
        if self.known.get("streakReminded") == today_str():
            return
        self.known["streakReminded"] = today_str()
        self.save("known")
        if self.notifier:
            self.notifier.send("Keep your %d-day streak" % contrib["streak"],
                               "No contributions yet today. The streak ends at midnight.",
                               "https://github.com/" + self.login, key="streak")

    # ---- scheduling

    FEEDS = ("overview", "notifications", "inbox", "catalog", "stats", "traffic")

    def due(self, now):
        out = []
        for feed in self.FEEDS:
            if feed in ("catalog", "stats") and not self.config.get("marketplace", True):
                continue
            if feed != "overview" and not self.login:
                continue
            normal, opened = INTERVALS[feed]
            iv = opened if self.ui_open else normal
            if feed == "notifications":
                iv = max(iv, self.poll_interval)
            if now < self.retry_at.get(feed, 0):
                continue
            if feed in self.force or now - self.fetched.get(feed, 0) >= iv:
                out.append(feed)
        return out

    def refresh(self):
        """Fetch everything now, except the catalog and feeds fetched in the last 30 s."""
        now = time.time()
        self.retry_at = {k: v for k, v in self.retry_at.items() if v > now + 600}
        self.force.update(f for f in self.FEEDS if now - self.fetched.get(f, 0) > 30 and f != "catalog")
        # Only what will actually run, so a rate-limited feed can't leave the spinner going.
        self.manual = set(self.due(now)) & self.force

    def run(self, feed):
        self.force.discard(feed)
        try:
            getattr(self, "fetch_" + feed)()
            self.fetched[feed] = max(self.fetched.get(feed, 0), time.time())
            self.errors.pop(feed, None)
            if feed == "overview":
                self.status, self.error = "ok", ""
        except AuthError as e:
            self.status, self.error = "auth", str(e)
            for f in self.FEEDS:
                self.retry_at[f] = time.time() + 60
        except RateLimited as e:
            self.errors[feed] = str(e)
            for f in self.FEEDS:
                if f not in ("catalog", "stats"):
                    self.retry_at[f] = e.reset + 5
            if feed == "overview":
                self.status, self.error = "limited", str(e)
        except (urllib.error.URLError, socket.timeout, ConnectionError, TimeoutError) as e:
            self.errors[feed] = "network: %s" % getattr(e, "reason", e)
            self.retry_at[feed] = time.time() + 120
            if feed == "overview":
                self.status, self.error = "offline", "can't reach GitHub"
        except (ApiError, KeyError, TypeError, ValueError) as e:
            self.errors[feed] = str(e)
            self.retry_at[feed] = time.time() + 300
            if feed == "overview" and not self.raw.get("overview"):
                self.status, self.error = "error", str(e)
        self.manual.discard(feed)
        self.save_raw()
        self.flush_notifications()

    def set_config(self, changes):
        for k, v in changes.items():
            if k in DEFAULT_CONFIG and type(v) in (type(DEFAULT_CONFIG[k]), int, float):
                self.config[k] = v
        self.save("config")
        if "includePrivate" in changes:
            self.force.add("traffic")
        if changes.get("marketplace"):
            self.force.update(("catalog", "stats"))

    # ---- snapshot

    def visible_repos(self):
        repos = (self.raw.get("overview") or {}).get("repos") or []
        cfg = self.config
        return [r for r in repos if (cfg.get("includePrivate", True) or not r["private"])
                and (cfg.get("includeForks") or not r["fork"])]

    def totals(self):
        repos = [r for r in self.visible_repos() if not r["fork"]]
        stars = self.known.get("stars") or {}
        week = time.time() - 7 * 86400
        t = {"stars": sum(r["stars"] for r in repos), "forks": sum(r["forks"] for r in repos),
             "issues": sum(r["issues"] for r in repos), "prs": sum(r["prs"] for r in repos),
             "starsWeek": sum(1 for r in repos for s in stars.get(r["full"]) or [] if s[1] >= week)}
        for k in ("views", "uviews", "clones", "uclones"):
            t[k] = sum((self.traffic.get(r["full"]) or {}).get(k, 0) for r in repos)
        t["allClones"] = sum(v[2] for r in repos for v in ((self.traffic.get(r["full"]) or {}).get("days") or {}).values())
        return t

    def series(self, days=30):
        """Daily totals across visible repos: [date, views, uviews, clones, uclones]."""
        repos = [r["full"] for r in self.visible_repos() if not r["fork"]]
        out = []
        end = datetime.date.today()
        for k in range(days - 1, -1, -1):
            d = (end - datetime.timedelta(days=k)).isoformat()
            row = [d, 0, 0, 0, 0]
            for full in repos:
                v = ((self.traffic.get(full) or {}).get("days") or {}).get(d)
                if v:
                    for j in range(4):
                        row[j + 1] += v[j]
            out.append(row)
        return out

    def star_series(self, days=90):
        repos = [r["full"] for r in self.visible_repos() if not r["fork"]]
        stamps = sorted(s[1] for full in repos for s in (self.known.get("stars") or {}).get(full) or [])
        if not stamps:
            return []
        out, i, end = [], 0, datetime.date.today()
        for k in range(days - 1, -1, -1):
            d = end - datetime.timedelta(days=k)
            cutoff = datetime.datetime.combine(d + datetime.timedelta(days=1), datetime.time()).timestamp()
            while i < len(stamps) and stamps[i] < cutoff:
                i += 1
            out.append([d.isoformat(), i])
        return out

    def market_snapshot(self):
        if not self.config.get("marketplace", True):
            return [], {}
        out = []
        tv = tc = th = 0
        for pid, info in (self.market.get("listings") or {}).items():
            days = self.market["days"].get(pid) or {}
            keys = sorted(days)
            if not keys:
                continue
            v, c, h = days[keys[-1]]
            ago = lambda n: days.get(today_str(-n)) or days[keys[0]]
            series = []
            end = datetime.date.today()
            prev = None
            for k in range(29, -1, -1):
                d = (end - datetime.timedelta(days=k)).isoformat()
                cur = days.get(d)
                series.append([d, (cur[1] - prev[1]) if cur and prev else 0, (cur[0] - prev[0]) if cur and prev else 0])
                prev = cur or prev
            out.append(dict(info, views=v, copies=c, hearts=h,
                            viewsWeek=v - ago(7)[0], copiesWeek=c - ago(7)[1], heartsWeek=h - ago(7)[2],
                            copiesToday=c - (self.copies_base(pid) if self.copies_base(pid) is not None else c),
                            tracked=keys[0], series=series, rank=(self.market.get("ranks") or {}).get(pid) or {},
                            url=LISTING_URL % pid))
            tv, tc, th = tv + v, tc + c, th + h
        out.sort(key=lambda p: (-p["copies"], -p["views"]))
        return out, {"views": tv, "copies": tc, "hearts": th, "plugins": len(out),
                     "copiesWeek": sum(p["copiesWeek"] for p in out), "viewsWeek": sum(p["viewsWeek"] for p in out),
                     "heartsWeek": sum(p["heartsWeek"] for p in out), "listings": self.market.get("total", 0),
                     "since": min((p["tracked"] for p in out), default="")}

    def snapshot(self):
        ov = self.raw.get("overview") or {}
        user = dict(ov.get("user") or {})
        hist = self.history
        week_ago = hist.get(today_str(-7)) or (hist[sorted(hist)[0]] if hist else None)
        if user and week_ago:
            user["followersWeek"] = user["followers"] - week_ago.get("followers", user["followers"])
        listing_by_repo = {l["repoName"]: l["id"] for l in (self.market.get("listings") or {}).values()}
        repos = []
        for r in self.visible_repos():
            r = dict(r)
            if r["full"] in self.traffic:
                r["traffic"] = traffic_summary(self.traffic[r["full"]])
            r["plugin"] = listing_by_repo.get(r["name"].lower(), "")
            repos.append(r)
        market, mtotals = self.market_snapshot()
        items = self.activity["items"]
        seen = self.activity.get("seen", 0)
        notes = self.raw.get("notifications") or {}
        inbox = self.raw.get("inbox") or {}
        try:
            avatar = "%s?%d" % (AVATAR_FILE, int(os.path.getmtime(AVATAR_FILE)))
        except OSError:
            avatar = ""
        return {
            "status": self.status, "error": self.error, "errors": self.errors,
            "auth": {"source": self.gh.source or "", "scopes": self.gh.scopes},
            "config": self.config, "user": user, "avatar": avatar,
            "contrib": ov.get("contrib") or {}, "repos": repos, "totals": self.totals() if ov else {},
            "traffic": self.series(30), "starSeries": self.star_series(90),
            "activity": items[:120], "unseen": sum(1 for i in items if i["t"] > seen), "seen": seen,
            "inbox": inbox, "notifications": notes,
            "market": market, "marketTotals": mtotals,
            "refreshing": bool(self.manual), "rate": self.gh.rate, "fetched": {k: int(v) for k, v in self.fetched.items() if v},
            "trackingSince": sorted(hist)[0] if hist else "",
        }


# ---------------------------------------------------------------- daemon

def daemon():
    os.umask(0o077)
    lock = threading.Lock()

    def emit(obj):
        with lock:
            try:
                sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
                sys.stdout.flush()
            except BrokenPipeError:
                os._exit(0)

    engine = Engine(emit)
    last = [None]

    def publish():
        with engine.lock:
            state = engine.snapshot()
        blob = json.dumps(state, sort_keys=True)
        if blob != last[0]:
            last[0] = blob
            emit({"type": "state", "state": state})

    def loop():
        while True:
            try:
                publish()
                for feed in engine.due(time.time()):
                    with engine.lock:
                        engine.run(feed)
                    publish()
                engine.check_streak()
            except Exception as exc:  # keep the bar alive through API format changes
                emit({"type": "log", "error": "update failed: %r" % exc})
            engine.wake.wait(TICK)
            engine.wake.clear()

    threading.Thread(target=loop, daemon=True).start()

    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        cmd, ok, err = msg.get("cmd"), True, None
        try:
            if cmd == "refresh":
                with engine.lock:
                    engine.refresh()
                publish()
            elif cmd == "visible":
                engine.ui_open = bool(msg.get("open"))
            elif cmd == "seen":
                with engine.lock:
                    engine.mark_seen()
            elif cmd == "config":
                with engine.lock:
                    engine.set_config({k: v for k, v in msg.items() if k not in ("cmd", "id")})
            elif cmd == "open":
                ok = open_url(str(msg.get("url") or ""))
                err = None if ok else "no browser launcher found"
            elif cmd == "read":
                with engine.lock:
                    engine.mark_read(str(msg.get("thread") or "") or None)
            elif cmd == "test":
                if engine.notifier:
                    engine.notifier.send("GitHub", "Notifications are working", "https://github.com/" + engine.login)
            else:
                ok, err = False, "unknown command"
        except (AuthError, ApiError, RateLimited, urllib.error.URLError, OSError) as e:
            ok, err = False, str(e)
        engine.wake.set()
        emit({"type": "result", "id": msg.get("id"), "cmd": cmd, "ok": ok, "error": err})


# ---------------------------------------------------------------- CLI

def print_status(s):
    u, c, t = s["user"], s["contrib"], s["totals"]
    if not u:
        print("No data yet: %s" % (s["error"] or "the daemon hasn't fetched anything"))
        return 1
    print("%s%s · %s · %s" % (u["login"], " (%s)" % u["name"] if u.get("name") else "",
                              plural(u["followers"], "follower"), plural(u["repos"], "repo")))
    print("Contributions: %d this year · %d today · %d this week · streak %d (longest %d)"
          % (c.get("total", 0), c.get("today", 0), c.get("week", 0), c.get("streak", 0), c.get("longest", 0)))
    print("Stars %d (+%d this week) · forks %d · open issues %d · open PRs %d"
          % (t["stars"], t["starsWeek"], t["forks"], t["issues"], t["prs"]))
    print("Traffic, last 14 days: %d views (%d unique) · %d clones (%d unique cloners)"
          % (t["views"], t["uviews"], t["clones"], t["uclones"]))
    top = sorted((r for r in s["repos"] if r.get("traffic")), key=lambda r: -r["traffic"]["uclones"])[:5]
    for r in top:
        if r["traffic"]["uclones"] or r["traffic"]["uviews"]:
            print("  %-28s %4d cloners  %4d visitors  ★%d" % (r["name"], r["traffic"]["uclones"], r["traffic"]["uviews"], r["stars"]))
    if s["market"]:
        m = s["marketTotals"]
        print("Omarchy marketplace: %d plugins · %d views · %d install copies (+%d this week) · %d hearts"
              % (m["plugins"], m["views"], m["copies"], m["copiesWeek"], m["hearts"]))
        for p in s["market"]:
            print("  %-22s %4d views  %3d copies  %2d ♥  #%s by installs"
                  % (p["name"], p["views"], p["copies"], p["hearts"], (p["rank"] or {}).get("copies", "?")))
    inbox = s["inbox"]
    if inbox:
        print("Inbox: %d review requests · %d open PRs · %d assigned · %d unread notifications"
              % (inbox.get("reviewsCount", 0), inbox.get("mineCount", 0), inbox.get("assignedCount", 0),
                 len((s["notifications"] or {}).get("items") or [])))
    if s["activity"]:
        print("Recent:")
        for a in s["activity"][:8]:
            print("  %s  %s" % (time.strftime("%b %d %H:%M", time.localtime(a["t"])), a["text"]))
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    if cmd == "daemon":
        daemon()
    elif cmd == "status":
        state = Engine(notify=False).snapshot()
        if "--json" in argv:
            print(json.dumps(state, indent=2))
            return 0
        return print_status(state)
    elif cmd == "open":
        url = argv[2] if len(argv) > 2 else None
        if not url:
            login = Engine(notify=False).login
            url = "https://github.com/" + login if login else "https://github.com"
        return 0 if open_url(url) else 1
    else:
        print(__doc__.strip())
        return 0 if cmd in ("-h", "--help", "help") else 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv) or 0)
