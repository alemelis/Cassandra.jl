#!/usr/bin/env python3
"""
Dashboard for Cassandra.jl — classical engine.

Serves the static UI plus a thin JSON API:
  - /api/rating              Lichess + arena Elo history
  - /api/setups              CRUD over engine setups (setups/*.json)
  - /api/setups/<n>/deploy   atomic deploy, signals bot to /reload
  - /api/games               recent bot game log + per-game traces
  - /api/bot/*               proxies the Julia bot's control server
  - /api/arena/*             start/stop arena container, read logs
  - /api/profile/*           run/stop/list flame-graph profiles
"""
import http.server
import json
import os
import re
import random
import urllib.error
import urllib.request
from datetime import datetime, timezone

# ── Setup-name dictionary (mirrors the spirit of old run_name) ──────────────
_ADJECTIVES = [
    "brilliant","tactical","aggressive","positional","relentless","tenacious",
    "sharp","enduring","bold","ruthless","calm","precise","wild","patient",
    "cunning","fearless","legendary","electric","unstoppable","eternal","furious",
    "silent","classical","dynamic","prophylactic","hypermodern","zugzwang",
    "combinatorial","deep",
]
_PLAYERS = [
    "kasparov","fischer","tal","karpov","anand","carlsen","morphy","capablanca",
    "botvinnik","kramnik","spassky","bronstein","petrosian","smyslov","nimzowitsch",
    "larsen","topalov","polgar","alekhine","reshevsky","geller","kortchnoi","euwe",
    "lasker","steinitz",
]
def _random_setup_name():
    return f'{random.choice(_ADJECTIVES)}_{random.choice(_PLAYERS)}'

# ── Config ───────────────────────────────────────────────────────────────────
PORT             = int(os.environ.get("PORT", 8000))
ROOT             = os.path.dirname(os.path.abspath(__file__))
SETUPS_DIR       = os.environ.get("SETUPS_DIR", os.path.join(ROOT, "..", "setups"))
LOGS_DIR         = os.environ.get("LOGS_DIR",   os.path.join(ROOT, "..", "logs"))
TRACES_DIR       = os.environ.get("TRACES_DIR", os.path.join(LOGS_DIR, "game_traces"))
BOT_CONTROL      = os.environ.get("BOT_CONTROL_URL", "http://bot:8080")
LICHESS_TOKEN    = os.environ.get("LICHESS_TOKEN", "")
DASHBOARD_SECRET = os.environ.get("DASHBOARD_SECRET", "")
ARENA_IMAGE      = os.environ.get("ARENA_IMAGE",   "cassandrajl-arena")
COMPOSE_PROJECT  = os.environ.get("COMPOSE_PROJECT", "cassandrajl")
PROFILE_DIR      = os.path.join(LOGS_DIR, 'profile')

_FEN_RE = re.compile(
    r'^[rnbqkpRNBQKP1-8/]{1,71} [wb] (?:-|[KQkq]{1,4}) (?:-|[a-h][1-8]) \d+ \d+$'
)
_TS_RE = re.compile(r'^\d{8}T\d{6}$')

_bot_username = None

# ── Auth ─────────────────────────────────────────────────────────────────────

def _auth_ok(headers):
    if not DASHBOARD_SECRET:
        return True
    return headers.get("Authorization", "") == f"Bearer {DASHBOARD_SECRET}"

# ── Lichess ──────────────────────────────────────────────────────────────────

def _lichess(path):
    req = urllib.request.Request(f'https://lichess.org{path}',
                                 headers={'Authorization': f'Bearer {LICHESS_TOKEN}'})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

def _arena_series():
    """Single history-series for arena (consolidated by day, highest score wins)."""
    log_path = os.path.join(LOGS_DIR, 'arena_log.jsonl')
    if not os.path.isfile(log_path):
        return []
    by_day = {}
    with open(log_path) as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get('cassandra_elo') is None:
                continue
            day_key = (r['year'], r['month'] - 1, r['day'])
            if day_key not in by_day or r['cassandra_elo'] > by_day[day_key]['cassandra_elo']:
                by_day[day_key] = r
    if not by_day:
        return []
    points = []
    for (y, m, d), r in sorted(by_day.items()):
        points.append({
            'x': [y, m, d],
            'y': round(r['cassandra_elo']),
            'sf_strength': r.get('sf_strength'),
            'tc': r.get('tc'),
        })
    return [{'name': 'arena', 'points': points}]

def _get_rating_history():
    global _bot_username
    arena = _arena_series()
    arena_elo = arena[0]['points'][-1]['y'] if arena and arena[0].get('points') else None
    if not LICHESS_TOKEN:
        return ({'username': 'cassandra-jl', 'history': arena, 'current': {'arena': arena_elo}}, None) if arena \
               else (None, 'No LICHESS_TOKEN set')
    try:
        if not _bot_username:
            _bot_username = _lichess('/api/account')['username']
        history = _lichess(f'/api/user/{_bot_username}/rating-history')
        active = []
        current = {'arena': arena_elo}
        for p in history:
            pts = p.get('points')
            if not pts:
                continue
            active.append({
                'name': p['name'],
                'points': [{'x': pt[:3], 'y': pt[3]} for pt in pts]
            })
            if pts:
                current[p['name']] = pts[-1][3]
        return {'username': _bot_username, 'history': active + arena, 'current': current}, None
    except urllib.error.URLError as e:
        if arena:
            return {'username': _bot_username or 'cassandra-jl', 'history': arena, 'current': {'arena': arena_elo}}, None
        return None, str(e)

# ── Games / traces ───────────────────────────────────────────────────────────

def _list_games(n=200):
    log_path = os.path.join(LOGS_DIR, "bot_log.jsonl")
    if not os.path.isfile(log_path):
        return []
    games = []
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                g = json.loads(line)
                gid = g.get("game_id", "")
                if gid:
                    g["has_trace"] = os.path.isfile(os.path.join(TRACES_DIR, f"{gid}.jsonl"))
                games.append(g)
            except Exception:
                pass
    return games[-n:]

def _get_trace(game_id):
    safe = os.path.basename(game_id)
    if not safe or not safe.replace('-', '').isalnum():
        return None
    path = os.path.join(TRACES_DIR, f"{safe}.jsonl")
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return f.read()

# ── Setups (single source of truth for engine knobs) ─────────────────────────

def _setups_dir():
    os.makedirs(SETUPS_DIR, exist_ok=True)
    return SETUPS_DIR

def _list_setups():
    d = _setups_dir()
    deployed_name = None
    deployed_path = os.path.join(d, 'deployed.json')
    if os.path.isfile(deployed_path):
        try:
            with open(deployed_path) as f:
                deployed_name = json.load(f).get('name')
        except Exception:
            pass
    skip = {'deployed.json'}
    try:
        files = sorted(f for f in os.listdir(d) if f.endswith('.json') and f not in skip)
    except OSError:
        files = []
    out = []
    for fname in files:
        path = os.path.join(d, fname)
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            continue
        name = os.path.splitext(fname)[0]
        out.append({
            'name': name,
            'created_at': data.get('created_at', ''),
            'deployed': name == deployed_name,
            'mtime': os.path.getmtime(path),
            'config': data,
        })
    return out

def _get_setup(name):
    safe = os.path.basename(name)
    path = os.path.join(_setups_dir(), f'{safe}.json')
    if not os.path.isfile(path):
        raise FileNotFoundError(f'Setup not found: {safe}')
    with open(path) as f:
        return json.load(f)

def _engine_config_schema():
    """Schema is owned by the Julia engine; we only proxy it."""
    try:
        with urllib.request.urlopen(f'{BOT_CONTROL}/engine_config/schema', timeout=5) as r:
            return json.loads(r.read())
    except Exception:
        return {}

def _save_setup(name, data):
    safe = os.path.basename(name)
    if not safe:
        raise ValueError('Invalid setup name')
    data['name'] = safe
    path = os.path.join(_setups_dir(), f'{safe}.json')
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    return path

def _deploy_setup(name):
    safe = os.path.basename(name)
    src  = os.path.join(_setups_dir(), f'{safe}.json')
    if not os.path.isfile(src):
        raise FileNotFoundError(f'Setup not found: {safe}')
    with open(src) as f:
        data = json.load(f)
    data['name']        = safe
    data['deployed_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
    with open(os.path.join(_setups_dir(), 'deployed.json'), 'w') as f:
        json.dump(data, f, indent=2)
    with open(os.path.join(_setups_dir(), 'history.jsonl'), 'a') as f:
        f.write(json.dumps({'ts': data['deployed_at'], 'name': safe}) + '\n')
    try:
        req = urllib.request.Request(f'{BOT_CONTROL}/reload', data=b'', method='POST')
        with urllib.request.urlopen(req, timeout=5):
            pass
        return {'ok': True, 'setup': safe}
    except Exception as e:
        return {'ok': True, 'setup': safe, 'warn': f'Bot reload failed: {e}'}

def _delete_setup(name):
    safe = os.path.basename(name)
    if safe == 'deployed':
        raise ValueError(f'Cannot delete reserved setup: {safe}')
    deployed_path = os.path.join(_setups_dir(), 'deployed.json')
    if os.path.isfile(deployed_path):
        try:
            with open(deployed_path) as f:
                if json.load(f).get('name') == safe:
                    raise ValueError(f'Cannot delete deployed setup: {safe}')
        except ValueError:
            raise
        except Exception:
            pass
    path = os.path.join(_setups_dir(), f'{safe}.json')
    if not os.path.isfile(path):
        raise FileNotFoundError(f'Setup not found: {safe}')
    os.remove(path)
    return {'ok': True, 'removed': safe}

# ── Docker (arena + bot/dashboard control) ───────────────────────────────────

def _docker_client():
    import docker
    return docker.from_env()

def _container_logs(name_filter, n):
    try:
        dc = _docker_client()
        cs = dc.containers.list(filters={'name': name_filter})
        if not cs:
            return {'lines': [], 'running': False}
        raw = cs[0].logs(tail=n, timestamps=False).decode('utf-8', errors='replace')
        return {'lines': [l for l in raw.splitlines() if l.strip()][-n:], 'running': True}
    except Exception as e:
        return {'lines': [], 'running': False, 'error': str(e)}

def _restart_container(name_filter):
    dc = _docker_client()
    cs = dc.containers.list(filters={'name': name_filter})
    if not cs:
        raise RuntimeError(f'No running container matching {name_filter!r}')
    cs[0].restart(timeout=5)
    return {'ok': True, 'container': cs[0].name}

def _arena_log():
    log_path = os.path.join(LOGS_DIR, 'arena_log.jsonl')
    if not os.path.isfile(log_path):
        return []
    out = []
    with open(log_path) as f:
        for line in f:
            try:
                out.append(json.loads(line))
            except Exception:
                pass
    return out

def _arena_status():
    try:
        dc = _docker_client()
        cs = dc.containers.list(filters={'name': 'cassandrajl-arena'})
        if cs:
            return {'running': True, 'container_id': cs[0].short_id,
                    'started_at': cs[0].attrs['State']['StartedAt']}
        return {'running': False}
    except Exception as e:
        return {'running': False, 'error': str(e)}

def _start_arena(params):
    dc = _docker_client()
    if dc.containers.list(filters={'name': 'cassandrajl-arena-run'}):
        raise RuntimeError('Arena match already running')
    env = {
        'STOCKFISH_ELO': str(params.get('stockfish_elo', 1500)),
        'GAMES':         str(params.get('games', 100)),
        'MOVE_TIME':     str(params.get('move_time', 1.0)),
        'SETUPS_DIR':    '/data/setups',
        'LOGS_DIR':      '/data/logs',
    }
    volumes = {
        f'{COMPOSE_PROJECT}_logs':   {'bind': '/data/logs',   'mode': 'rw'},
        f'{COMPOSE_PROJECT}_setups': {'bind': '/data/setups', 'mode': 'rw'},
    }
    c = dc.containers.run(
        image=ARENA_IMAGE, command='python3 /app/arena/match.py',
        environment=env, volumes=volumes,
        network=f'{COMPOSE_PROJECT}_internal',
        detach=True, remove=True, name='cassandrajl-arena-run',
    )
    return {'ok': True, 'container_id': c.short_id}

def _stop_arena():
    dc = _docker_client()
    cs = dc.containers.list(filters={'name': 'cassandrajl-arena'})
    if not cs:
        raise RuntimeError('No arena container running')
    for c in cs:
        c.stop(timeout=10)
    return {'ok': True}

# ── Profile helpers ───────────────────────────────────────────────────────────

def _list_profile_runs():
    os.makedirs(PROFILE_DIR, exist_ok=True)
    metas = []
    for fname in os.listdir(PROFILE_DIR):
        if not fname.endswith('.meta.json'):
            continue
        try:
            with open(os.path.join(PROFILE_DIR, fname)) as f:
                metas.append(json.load(f))
        except Exception:
            pass
    metas.sort(key=lambda m: m.get('ts', ''), reverse=True)
    return metas

def _profile_status():
    try:
        dc = _docker_client()
        cs = dc.containers.list(all=True, filters={'name': 'cassandrajl-profile-run'})
        if not cs:
            return {'state': 'idle'}
        c = cs[0]
        status = c.status          # 'running', 'exited', 'created', …
        exit_code = c.attrs['State'].get('ExitCode', 0)
        started = c.attrs['State'].get('StartedAt', '')
        if status == 'running':
            return {'state': 'running', 'container_id': c.short_id, 'started_at': started}
        if exit_code == 0:
            return {'state': 'done', 'exit_code': exit_code, 'started_at': started}
        return {'state': 'crashed', 'exit_code': exit_code, 'started_at': started}
    except Exception as e:
        return {'state': 'idle', 'error': str(e)}

def _profile_gc():
    """Remove any exited cassandrajl-profile-run container."""
    try:
        dc = _docker_client()
        for c in dc.containers.list(all=True, filters={'name': 'cassandrajl-profile-run'}):
            if c.status != 'running':
                c.remove(force=True)
    except Exception:
        pass

def _start_profile(params):
    fen     = (params.get('fen') or '').strip()
    label   = (params.get('label') or 'custom').strip()[:64]
    seconds = float(params.get('seconds') or 5.0)
    seconds = max(1.0, min(seconds, 300.0))

    if fen and not _FEN_RE.match(fen):
        raise ValueError(f'Invalid FEN: {fen!r}')

    dc = _docker_client()
    running = dc.containers.list(filters={'name': 'cassandrajl-profile-run'})
    if running:
        raise RuntimeError('Profile already running (409)')

    _profile_gc()
    os.makedirs(PROFILE_DIR, exist_ok=True)

    env = {
        'FEN':       fen,
        'POS_LABEL': label,
        'SECONDS':   str(seconds),
        'SETUPS_DIR': '/data/setups',
        'LOGS_DIR':   '/data/logs',
    }
    volumes = {
        f'{COMPOSE_PROJECT}_logs':   {'bind': '/data/logs',   'mode': 'rw'},
        f'{COMPOSE_PROJECT}_setups': {'bind': '/data/setups', 'mode': 'rw'},
    }
    uid = os.getuid()
    gid = os.getgid()
    dc.containers.run(
        image=ARENA_IMAGE,
        command='julia --project=. arena/profile.jl',
        environment=env, volumes=volumes,
        network=f'{COMPOSE_PROJECT}_internal',
        user=f'{uid}:{gid}',
        detach=True, remove=False,
        name='cassandrajl-profile-run',
    )
    return {'ok': True}

def _stop_profile():
    dc = _docker_client()
    cs = dc.containers.list(filters={'name': 'cassandrajl-profile-run'})
    if not cs:
        raise RuntimeError('No profile container running')
    cs[0].stop(timeout=15)
    return {'ok': True}

def _delete_profile_run(ts):
    if not _TS_RE.match(ts):
        raise ValueError(f'Invalid timestamp: {ts!r}')
    removed = []
    for ext in ('.collapsed', '.meta.json'):
        p = os.path.join(PROFILE_DIR, ts + ext)
        if os.path.isfile(p):
            os.remove(p)
            removed.append(ts + ext)
    return {'ok': True, 'removed': removed}

def _get_profile_collapsed(ts):
    if not _TS_RE.match(ts):
        raise ValueError(f'Invalid timestamp: {ts!r}')
    path = os.path.join(PROFILE_DIR, ts + '.collapsed')
    if not os.path.isfile(path):
        raise FileNotFoundError(f'{ts}.collapsed not found')
    with open(path) as f:
        return f.read()

# ── HTTP handler ─────────────────────────────────────────────────────────────

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    # ── Routing ──────────────────────────────────────────────────────────────

    def do_GET(self):
        path = self.path.split('?')[0]
        routes = {
            '/api/auth/required':     self._handle_auth_required,
            '/api/rating':            self._handle_rating,
            '/api/bot/status':        self._handle_bot_status,
            '/api/bot/config':        self._handle_bot_config_get,
            '/api/bot/metrics':      self._handle_bot_metrics,
            '/api/games':             self._handle_games_list,
            '/api/book':              self._handle_book_get,
            '/api/setups':            self._handle_setups_list,
            '/api/setups/schema':     self._handle_setups_schema,
            '/api/arena':             self._handle_arena_get,
            '/api/profile':           self._handle_profile_get,
        }
        h = routes.get(path)
        if h:
            h(); return
        if path.startswith('/api/bot/logs'):
            self._json(200, _container_logs('cassandrajl-bot', self._n_param(20)))
        elif path.startswith('/api/arena/logs'):
            self._json(200, _container_logs('cassandrajl-arena', self._n_param(50)))
        elif path.startswith('/api/profile/logs'):
            self._json(200, _container_logs('cassandrajl-profile-run', self._n_param(40)))
        elif path.startswith('/api/profile/run/'):
            self._handle_profile_collapsed(path[len('/api/profile/run/'):])
        elif path.startswith('/api/games/') and path.endswith('/trace'):
            self._handle_game_trace(path[len('/api/games/'):-len('/trace')])
        elif path.startswith('/api/setups/'):
            self._handle_setup_get(path[len('/api/setups/'):])
        elif path.startswith('/docs/'):
            fname = path[len('/docs/'):]
            if '/' in fname or not fname.endswith('.md'):
                self.send_error(400); return
            self._serve_file(os.path.join(ROOT, 'docs', fname), 'text/plain; charset=utf-8')
        elif path.startswith('/logs/'):
            fname = self.path[len('/logs/'):].split('?')[0]
            self._serve_file(os.path.join(LOGS_DIR, fname), 'text/plain; charset=utf-8')
        else:
            super().do_GET()

    def do_DELETE(self):
        path = self.path.split('?')[0]
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        if path.startswith('/api/profile/run/'):
            try:
                self._json(200, _delete_profile_run(path[len('/api/profile/run/'):]))
            except (ValueError, FileNotFoundError) as e:
                self._json(400, {'ok': False, 'error': str(e)})
            except Exception as e:
                self._json(500, {'ok': False, 'error': str(e)})
        elif path.startswith('/api/setups/'):
            try:
                self._json(200, _delete_setup(path[len('/api/setups/'):]))
            except (ValueError, FileNotFoundError) as e:
                self._json(400, {'ok': False, 'error': str(e)})
            except Exception as e:
                self._json(500, {'ok': False, 'error': str(e)})
        else:
            self.send_error(404)

    def do_POST(self):
        path = self.path.split('?')[0]
        routes = {
            '/api/auth/check':         self._handle_auth_check,
            '/api/bot/restart':        self._handle_bot_restart,
            '/api/bot/pause':          self._handle_bot_pause,
            '/api/bot/resume':         self._handle_bot_resume,
            '/api/bot/config':         self._handle_bot_config_set,
            '/api/dashboard/restart':  self._handle_dashboard_restart,
            '/api/arena/run':          self._handle_arena_run,
            '/api/arena/stop':         self._handle_arena_stop,
            '/api/profile/run':        self._handle_profile_run,
            '/api/profile/stop':       self._handle_profile_stop,
            '/api/book/line':          self._handle_book_add_line,
            '/api/book/entry/delete':  self._handle_book_delete_entry,
            '/api/book/import':        self._handle_book_import,
            '/api/book/clear':         self._handle_book_clear,
            '/api/setups':             self._handle_setup_create,
        }
        h = routes.get(path)
        if h:
            h(); return
        if path.startswith('/api/setups/') and path.endswith('/deploy'):
            self._handle_setup_deploy(path[len('/api/setups/'):-len('/deploy')])
        elif path.startswith('/api/setups/'):
            self._handle_setup_update(path[len('/api/setups/'):])
        else:
            self.send_error(404)

    # ── Auth ─────────────────────────────────────────────────────────────────

    def _handle_auth_required(self):
        self._json(200, {'required': bool(DASHBOARD_SECRET)})

    def _handle_auth_check(self):
        body = self._read_json()
        if DASHBOARD_SECRET and body.get('secret', '') != DASHBOARD_SECRET:
            self._json(403, {'ok': False})
        else:
            self._json(200, {'ok': True})

    # ── Setups ───────────────────────────────────────────────────────────────

    def _handle_setups_list(self):  self._json(200, {'setups': _list_setups()})
    def _handle_setups_schema(self): self._json(200, _engine_config_schema())

    def _handle_setup_get(self, name):
        try:    self._json(200, _get_setup(name))
        except FileNotFoundError as e: self._json(404, {'ok': False, 'error': str(e)})

    def _handle_setup_create(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            data = self._read_json()
            name = (data.get('name') or '').strip() or _random_setup_name()
            existing = {s['name'] for s in _list_setups()}
            base, n = name, 1
            while name in existing:
                n += 1; name = f'{base}_{n}'
            data['name']       = name
            data['created_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
            _save_setup(name, data)
            self._json(200, {'ok': True, 'name': name})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    def _handle_setup_update(self, name):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            data = self._read_json()
            safe = os.path.basename(name)
            try:    existing = _get_setup(safe)
            except FileNotFoundError: existing = {}
            def deep_merge(base, updates):
                for k, v in updates.items():
                    if isinstance(v, dict) and isinstance(base.get(k), dict):
                        deep_merge(base[k], v)
                    else:
                        base[k] = v
            deep_merge(existing, data)
            existing['name'] = safe
            _save_setup(safe, existing)
            self._json(200, {'ok': True, 'setup': existing})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    def _handle_setup_deploy(self, name):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, _deploy_setup(name))
        except FileNotFoundError as e: self._json(404, {'ok': False, 'error': str(e)})
        except Exception as e:         self._json(500, {'ok': False, 'error': str(e)})

    def _handle_rating(self):
        data, err = _get_rating_history()
        if err: self._json(503, {'error': err})
        else:   self._json(200, data)

    # ── Games / bot proxy ────────────────────────────────────────────────────

    def _handle_bot_status(self):     self._json(200, self._bot_get('/status', {'unreachable': True}))
    def _handle_bot_config_get(self): self._json(200, self._bot_get('/config', {'unreachable': True}))

    def _handle_bot_metrics(self):
        import psutil, subprocess, os
        from datetime import datetime, timezone

        cpu = psutil.cpu_percent(interval=0.1)
        mem = psutil.virtual_memory()
        temp = None
        
        # Try sensors command first
        try:
            result = subprocess.run(['sensors', '-j'], capture_output=True, timeout=2)
            if result.returncode == 0:
                import json
                for chip in json.loads(result.stdout).values():
                    if isinstance(chip, dict):
                        for k, v in chip.items():
                            if k.startswith('temp') and isinstance(v, dict) and v.get('input'):
                                temp = round(v['input'], 1)
                                break
                        if temp: break
        except:
            pass
        
        # Fallback: read from thermal zone
        if not temp:
            try:
                for zone in os.listdir('/sys/class/thermal'):
                    path = f'/sys/class/thermal/{zone}/temp'
                    if os.path.isfile(path):
                        with open(path) as f:
                            temp = round(int(f.read()) / 1000, 1)
                        break
            except:
                pass

        self._json(200, {'cpu': round(cpu,1), 'mem_mb': mem.used//(1024*1024), 'mem_pct': round(mem.used/mem.total*100,1), 'temp': temp, 'ts': datetime.now(timezone.utc).isoformat()})

    def _handle_games_list(self):
        self._json(200, {'games': _list_games(self._n_param(200))})

    def _handle_game_trace(self, game_id):
        data = _get_trace(game_id)
        if data is None:
            self.send_error(404); return
        body = data.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    # ── Arena ────────────────────────────────────────────────────────────────

    def _handle_arena_get(self):
        self._json(200, {'records': _arena_log(), 'status': _arena_status()})

    def _handle_arena_run(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, _start_arena(self._read_json()))
        except RuntimeError as e: self._json(409, {'ok': False, 'error': str(e)})
        except Exception as e:    self._json(500, {'ok': False, 'error': str(e)})

    def _handle_arena_stop(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, _stop_arena())
        except RuntimeError as e: self._json(409, {'ok': False, 'error': str(e)})
        except Exception as e:    self._json(500, {'ok': False, 'error': str(e)})

    # ── Profile ──────────────────────────────────────────────────────────────

    def _handle_profile_get(self):
        self._json(200, {'runs': _list_profile_runs(), 'status': _profile_status()})

    def _handle_profile_collapsed(self, ts):
        try:
            text = _get_profile_collapsed(ts)
            body = text.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', len(body))
            self.send_header('Cache-Control', 'public, max-age=31536000, immutable')
            self.send_header('ETag', f'"{ts}"')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(body)
        except (ValueError, FileNotFoundError) as e:
            self._json(404, {'ok': False, 'error': str(e)})

    def _handle_profile_run(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, _start_profile(self._read_json()))
        except ValueError as e:   self._json(400, {'ok': False, 'error': str(e)})
        except RuntimeError as e: self._json(409, {'ok': False, 'error': str(e)})
        except Exception as e:    self._json(500, {'ok': False, 'error': str(e)})

    def _handle_profile_stop(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, _stop_profile())
        except RuntimeError as e: self._json(409, {'ok': False, 'error': str(e)})
        except Exception as e:    self._json(500, {'ok': False, 'error': str(e)})

    def _handle_bot_restart(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, _restart_container('cassandrajl-bot'))
        except RuntimeError as e: self._json(409, {'ok': False, 'error': str(e)})
        except Exception as e:    self._json(500, {'ok': False, 'error': str(e)})

    # ── Book proxy ───────────────────────────────────────────────────────────

    def _handle_book_get(self):
        self._json(200, self._bot_get('/book', {'count': 0, 'entries': [], 'unreachable': True}))

    def _proxy_book(self, path):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = self.rfile.read(length) if length else b'{}'
            self._json(200, self._bot_post(path, body))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_book_add_line(self):     self._proxy_book('/book/line')
    def _handle_book_delete_entry(self): self._proxy_book('/book/entry/delete')

    def _handle_book_import(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, self._bot_post('/book/import'))
        except Exception as e: self._json(502, {'ok': False, 'error': str(e)})

    def _handle_book_clear(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, self._bot_post('/book/clear'))
        except Exception as e: self._json(502, {'ok': False, 'error': str(e)})

    # ── Bot proxies ──────────────────────────────────────────────────────────

    def _bot_get(self, path, fallback):
        try:
            with urllib.request.urlopen(f'{BOT_CONTROL}{path}', timeout=3) as r:
                return json.loads(r.read())
        except Exception:
            return fallback

    def _bot_post(self, path, body=None):
        data = body if body is not None else b''
        req = urllib.request.Request(f'{BOT_CONTROL}{path}', data=data, method='POST')
        if body:
            req.add_header('Content-Type', 'application/json')
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.loads(r.read())

    def _handle_bot_pause(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, self._bot_post('/pause'))
        except Exception as e: self._json(502, {'ok': False, 'error': str(e)})

    def _handle_bot_resume(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:    self._json(200, self._bot_post('/resume'))
        except Exception as e: self._json(502, {'ok': False, 'error': str(e)})

    def _handle_bot_config_set(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = self.rfile.read(length) if length else b'{}'
            self._json(200, self._bot_post('/config', body))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_dashboard_restart(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            dc = _docker_client()
            cs = dc.containers.list(filters={'name': 'cassandrajl-dashboard'})
            if not cs:
                self._json(404, {'ok': False, 'error': 'Dashboard container not found'}); return
            self._json(200, {'ok': True, 'container': cs[0].name})
            import threading
            threading.Timer(0.5, lambda: cs[0].restart(timeout=5)).start()
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    # ── Helpers ──────────────────────────────────────────────────────────────

    def _read_json(self):
        length = int(self.headers.get('Content-Length', 0))
        return json.loads(self.rfile.read(length)) if length else {}

    def _n_param(self, default):
        if 'n=' not in self.path:
            return default
        try:    return int(self.path.split('n=')[1].split('&')[0])
        except Exception: return default

    def _serve_file(self, fpath, content_type):
        if not os.path.isfile(fpath):
            self.send_error(404); return
        with open(fpath, 'rb') as f:
            data = f.read()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', len(data))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == '__main__':
    os.makedirs(LOGS_DIR, exist_ok=True)
    os.makedirs(PROFILE_DIR, exist_ok=True)
    with http.server.HTTPServer(('', PORT), Handler) as httpd:
        print(f'Dashboard → http://localhost:{PORT}')
        httpd.serve_forever()
