#!/usr/bin/env python3
import http.server
import json
import os
import shutil
import urllib.request
import urllib.error
from datetime import datetime, timezone

PORT            = int(os.environ.get("PORT", 8000))
ROOT            = os.path.dirname(os.path.abspath(__file__))
CHECKPOINTS     = os.environ.get("CHECKPOINTS_DIR", os.path.join(ROOT, "..", "checkpoints"))
LOGS_DIR        = os.environ.get("LOGS_DIR",        os.path.join(ROOT, "..", "logs"))
TRACES_DIR      = os.environ.get("TRACES_DIR",      os.path.join(LOGS_DIR, "game_traces"))
BOT_CONTROL     = os.environ.get("BOT_CONTROL_URL",  "http://bot:8080")
LICHESS_TOKEN   = os.environ.get("LICHESS_TOKEN", "")
DASHBOARD_SECRET = os.environ.get("DASHBOARD_SECRET", "")
TRAINER_IMAGE   = os.environ.get("TRAINER_IMAGE", "cassandrajl-trainer")
COMPOSE_PROJECT = os.environ.get("COMPOSE_PROJECT", "cassandrajl")
DATA_DIR        = os.environ.get("DATA_DIR", os.path.join(ROOT, "..", "data"))
DATA_DIR_HOST   = os.environ.get("DATA_DIR_HOST", os.path.abspath(DATA_DIR))

_bot_username = None

# ── Auth ──────────────────────────────────────────────────────────────────────

def _auth_ok(headers):
    if not DASHBOARD_SECRET:
        return True
    auth = headers.get("Authorization", "")
    return auth == f"Bearer {DASHBOARD_SECRET}"

# ── Lichess ───────────────────────────────────────────────────────────────────

def _lichess(path):
    req = urllib.request.Request(
        f'https://lichess.org{path}',
        headers={'Authorization': f'Bearer {LICHESS_TOKEN}'}
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

def _get_rating_history():
    global _bot_username
    if not LICHESS_TOKEN:
        return None, 'No LICHESS_TOKEN set'
    try:
        if not _bot_username:
            profile = _lichess('/api/account')
            _bot_username = profile['username']
        history = _lichess(f'/api/user/{_bot_username}/rating-history')
        active = [p for p in history if p.get('points')]
        return {'username': _bot_username, 'history': active}, None
    except urllib.error.URLError as e:
        return None, str(e)

# ── Checkpoints ───────────────────────────────────────────────────────────────

def _list_checkpoints():
    skip = {'latest.jld2', 'deployed.jld2'}
    try:
        files = [
            f for f in os.listdir(CHECKPOINTS)
            if f.endswith('.jld2') and f not in skip
        ]
        files.sort(key=lambda f: os.path.getmtime(os.path.join(CHECKPOINTS, f)))
        result = []
        for f in files:
            name = os.path.splitext(f)[0]
            entry = {'name': name}
            meta_path = os.path.join(CHECKPOINTS, f'{name}.json')
            if os.path.isfile(meta_path):
                try:
                    with open(meta_path) as mf:
                        entry.update(json.load(mf))
                except Exception:
                    pass
            result.append(entry)

        # Expose latest.jld2 as a deployable entry when it exists.
        # Only mark in_progress when the trainer container is actually running.
        latest_path = os.path.join(CHECKPOINTS, 'latest.jld2')
        if os.path.isfile(latest_path):
            trainer_running = _trainer_status().get('running', False)
            entry = {'name': 'latest', 'in_progress': trainer_running}
            run_name_path = os.path.join(CHECKPOINTS, 'run_name.txt')
            if os.path.isfile(run_name_path):
                try:
                    with open(run_name_path) as f:
                        entry['run_name'] = f.read().strip()
                except Exception:
                    pass
            result.append(entry)

        return result
    except OSError:
        return []

def _deploy(model_name):
    src = os.path.join(CHECKPOINTS, f'{model_name}.jld2')
    dst = os.path.join(CHECKPOINTS, 'deployed.jld2')
    if not os.path.isfile(src):
        raise FileNotFoundError(f'Checkpoint not found: {src}')

    # When deploying "latest", resolve the real run name
    actual_name = model_name
    if model_name == 'latest':
        run_name_path = os.path.join(CHECKPOINTS, 'run_name.txt')
        if os.path.isfile(run_name_path):
            try:
                with open(run_name_path) as f:
                    actual_name = f.read().strip()
            except Exception:
                pass

    log_path = os.path.join(LOGS_DIR, 'train_log.jsonl')
    epoch, loss = None, None
    if os.path.isfile(log_path):
        with open(log_path) as f:
            lines = [l.strip() for l in f if l.strip()]
        if lines:
            import re
            last = lines[-1]
            m = re.search(r'"epoch"\s*:\s*(\d+)', last)
            if m:
                epoch = int(m.group(1))
            m = re.search(r'"loss_policy"\s*:\s*([\d.]+)', last)
            if m:
                loss = float(m.group(1))

    shutil.copy2(src, dst)

    meta = {
        'run_name': actual_name,
        'deployed_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S'),
    }
    if epoch is not None:
        meta['epoch'] = epoch
    if loss is not None:
        meta['loss_policy'] = loss

    os.makedirs(LOGS_DIR, exist_ok=True)
    with open(os.path.join(LOGS_DIR, 'deployed.json'), 'w') as f:
        json.dump(meta, f)

    try:
        req = urllib.request.Request(
            f'{BOT_CONTROL}/reload',
            data=b'',
            method='POST',
        )
        with urllib.request.urlopen(req, timeout=5):
            pass
    except Exception as e:
        return {'ok': True, 'warn': f'Bot reload signal failed: {e}', 'model': model_name}

    return {'ok': True, 'model': model_name}

# ── Games / traces ────────────────────────────────────────────────────────────

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
                game_id = g.get("game_id", "")
                if game_id:
                    g["has_trace"] = os.path.isfile(
                        os.path.join(TRACES_DIR, f"{game_id}.jsonl"))
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

# ── Datasets ──────────────────────────────────────────────────────────────────

def _list_datasets():
    try:
        files = sorted(f for f in os.listdir(DATA_DIR) if f.endswith('.bin'))
    except OSError:
        return []
    result = []
    for fname in files:
        entry = {'name': os.path.splitext(fname)[0], 'file': fname}
        meta_path = os.path.join(DATA_DIR, fname + '.json')
        if os.path.isfile(meta_path):
            try:
                with open(meta_path) as mf:
                    entry.update(json.load(mf))
            except Exception:
                pass
        result.append(entry)
    return result

def _delete_dataset(name):
    safe = os.path.basename(name)
    removed = []
    for ext in ('.bin', '.bin.json'):
        path = os.path.join(DATA_DIR, safe + ext)
        if os.path.isfile(path):
            os.remove(path)
            removed.append(safe + ext)
    if not removed:
        raise FileNotFoundError(f'Dataset not found: {safe}')
    return {'ok': True, 'removed': removed}

def _delete_checkpoint(name):
    safe = os.path.basename(name)
    if safe in ('latest', 'deployed'):
        raise ValueError(f'Cannot delete reserved checkpoint: {safe}')
    # Refuse if this checkpoint is currently deployed
    deployed_meta = os.path.join(LOGS_DIR, 'deployed.json')
    if os.path.isfile(deployed_meta):
        try:
            with open(deployed_meta) as f:
                meta = json.load(f)
            if meta.get('run_name') == safe:
                raise ValueError(f'Cannot delete deployed checkpoint: {safe}')
        except ValueError:
            raise
        except Exception:
            pass
    removed = []
    for ext in ('.jld2', '.json'):
        path = os.path.join(CHECKPOINTS, safe + ext)
        if os.path.isfile(path):
            os.remove(path)
            removed.append(safe + ext)
    if not removed:
        raise FileNotFoundError(f'Checkpoint not found: {safe}')
    return {'ok': True, 'removed': removed}

# ── Trainer control ───────────────────────────────────────────────────────────

def _docker_client():
    import docker
    return docker.from_env()

def _trainer_status():
    try:
        dc = _docker_client()
        containers = dc.containers.list(filters={'name': 'cassandrajl-trainer'})
        if containers:
            c = containers[0]
            status = {
                'running': True,
                'container_id': c.short_id,
                'started_at': c.attrs['State']['StartedAt'],
            }
            run_name_path = os.path.join(CHECKPOINTS, 'run_name.txt')
            if os.path.isfile(run_name_path):
                try:
                    with open(run_name_path) as f:
                        status['run_name'] = f.read().strip()
                except Exception:
                    pass
            return status
        return {'running': False}
    except Exception as e:
        return {'running': False, 'error': str(e)}

def _start_trainer(params):
    dc = _docker_client()
    existing = dc.containers.list(filters={'name': 'cassandrajl-trainer-run'})
    if existing:
        raise RuntimeError('Trainer is already running')

    dataset_file = params.get('dataset', 'puzzles.bin')
    env = {
        'CHECKPOINTS_DIR': '/data/checkpoints',
        'LOGS_DIR':        '/data/logs',
        'DATA_PATH':       f'/app/data/{dataset_file}',
        'EPOCHS':          str(params.get('epochs',       20)),
        'BATCH_SIZE':      str(params.get('batch_size',   512)),
        'LR':              str(params.get('lr',           '3e-4')),
        'LR_MIN':          str(params.get('lr_min',       '3e-6')),
        'EVAL_GAMES':      str(params.get('eval_games',   0)),
        'VALUE_WEIGHT':    str(params.get('value_weight', 0.0)),
        'WEIGHT_DECAY':    str(params.get('weight_decay', '1e-4')),
        'TRUNK_SIZES':     params.get('trunk_sizes', '256,128'),
        'DROPOUT':         str(params.get('dropout',      0.1)),
    }
    base_model = params.get('base_model', '').strip()
    if base_model:
        env['BASE_MODEL'] = base_model
    volumes = {
        f'{COMPOSE_PROJECT}_checkpoints': {'bind': '/data/checkpoints', 'mode': 'rw'},
        f'{COMPOSE_PROJECT}_logs':        {'bind': '/data/logs',        'mode': 'rw'},
        DATA_DIR_HOST:                    {'bind': '/app/data',         'mode': 'ro'},
    }
    container = dc.containers.run(
        image=TRAINER_IMAGE,
        command='julia --project=. scripts/train.jl',
        environment=env,
        volumes=volumes,
        network=f'{COMPOSE_PROJECT}_internal',
        detach=True,
        remove=True,
        name='cassandrajl-trainer-run',
    )
    return {'ok': True, 'container_id': container.short_id}

def _stop_trainer():
    dc = _docker_client()
    containers = dc.containers.list(filters={'name': 'cassandrajl-trainer'})
    if not containers:
        raise RuntimeError('No trainer containers running')
    stopped = []
    for c in containers:
        c.stop(timeout=10)
        stopped.append(c.short_id)
    return {'ok': True, 'stopped': stopped}

def _restart_container(name_filter):
    dc = _docker_client()
    containers = dc.containers.list(filters={'name': name_filter})
    if not containers:
        raise RuntimeError(f'No running container matching {name_filter!r}')
    c = containers[0]
    c.restart(timeout=5)
    return {'ok': True, 'container': c.name}


# ── HTTP handler ──────────────────────────────────────────────────────────────

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def do_GET(self):
        path = self.path.split('?')[0]
        if   path.startswith('/api/auth/required'):   self._handle_auth_required()
        elif path.startswith('/api/rating'):           self._handle_rating()
        elif path.startswith('/api/checkpoints'):      self._handle_checkpoints()
        elif path.startswith('/api/datasets'):         self._handle_datasets_get()
        elif path.startswith('/api/train/status'):     self._handle_train_status()
        elif path == '/api/bot/challenge/status':      self._handle_challenge_status()
        elif path == '/api/bot/games/status':          self._handle_games_status()
        elif path == '/api/bot/search/config':         self._handle_search_config_get()
        elif path.startswith('/api/bot/logs'):         self._handle_bot_logs()
        elif path.startswith('/api/arenas'):           self._handle_arenas()
        elif path == '/api/games':                      self._handle_games_list()
        elif path.startswith('/api/games/') and path.endswith('/trace'):
            gid = path[len('/api/games/'):-len('/trace')]
            self._handle_game_trace(gid)
        elif path.startswith('/docs/'):
            fname = path[len('/docs/'):]
            if '/' in fname or not fname.endswith('.md'):
                self.send_error(400); return
            fpath = os.path.join(ROOT, 'docs', fname)
            self._serve_file(fpath, 'text/plain; charset=utf-8')
        elif path.startswith('/logs/'):
            fname = self.path[len('/logs/'):].split('?')[0]
            self._serve_file(os.path.join(LOGS_DIR, fname), 'text/plain; charset=utf-8')
        else:
            super().do_GET()

    def do_DELETE(self):
        path = self.path.split('?')[0]
        if path.startswith('/api/datasets/'):
            if not _auth_ok(self.headers):
                self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
            name = path[len('/api/datasets/'):]
            try:
                self._json(200, _delete_dataset(name))
            except FileNotFoundError as e:
                self._json(404, {'ok': False, 'error': str(e)})
            except Exception as e:
                self._json(500, {'ok': False, 'error': str(e)})
        elif path.startswith('/api/checkpoints/'):
            if not _auth_ok(self.headers):
                self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
            name = path[len('/api/checkpoints/'):]
            try:
                self._json(200, _delete_checkpoint(name))
            except (ValueError, FileNotFoundError) as e:
                self._json(400, {'ok': False, 'error': str(e)})
            except Exception as e:
                self._json(500, {'ok': False, 'error': str(e)})
        else:
            self.send_error(404)

    def do_POST(self):
        path = self.path.split('?')[0]
        if   path == '/api/auth/check':        self._handle_auth_check()
        elif path == '/api/deploy':            self._handle_deploy()
        elif path == '/api/train/start':       self._handle_train_start()
        elif path == '/api/train/stop':        self._handle_train_stop()
        elif path == '/api/bot/restart':           self._handle_bot_restart()
        elif path == '/api/bot/challenge/pause':   self._handle_challenge_pause()
        elif path == '/api/bot/challenge/resume':  self._handle_challenge_resume()
        elif path == '/api/bot/games/pause':       self._handle_games_pause()
        elif path == '/api/bot/games/resume':      self._handle_games_resume()
        elif path == '/api/bot/search/config':     self._handle_search_config_set()
        elif path == '/api/dashboard/restart':     self._handle_dashboard_restart()
        else:
            self.send_error(404)

    # ── Auth ──────────────────────────────────────────────────────────────────

    def _handle_auth_required(self):
        self._json(200, {'required': bool(DASHBOARD_SECRET)})

    def _handle_auth_check(self):
        length = int(self.headers.get('Content-Length', 0))
        body   = json.loads(self.rfile.read(length)) if length else {}
        secret = body.get('secret', '')
        if DASHBOARD_SECRET and secret != DASHBOARD_SECRET:
            self._json(403, {'ok': False})
        else:
            self._json(200, {'ok': True})

    # ── Checkpoints / deploy ──────────────────────────────────────────────────

    def _handle_deploy(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = json.loads(self.rfile.read(length)) if length else {}
            model  = body.get('model', '').strip()
            if not model:
                self._json(400, {'ok': False, 'error': 'model name required'}); return
            self._json(200, _deploy(model))
        except FileNotFoundError as e:
            self._json(404, {'ok': False, 'error': str(e)})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    def _handle_checkpoints(self):
        self._json(200, {'checkpoints': _list_checkpoints()})

    def _handle_rating(self):
        data, err = _get_rating_history()
        if err:
            self._json(503, {'error': err})
        else:
            self._json(200, data)

    # ── Datasets ──────────────────────────────────────────────────────────────

    def _handle_datasets_get(self):
        self._json(200, {'datasets': _list_datasets()})

    # ── Training control ──────────────────────────────────────────────────────

    def _handle_arenas(self):
        try:
            req = urllib.request.Request(f'{BOT_CONTROL}/arenas')
            with urllib.request.urlopen(req, timeout=5) as r:
                arenas = json.loads(r.read())
            self._json(200, {'arenas': arenas})
        except Exception as e:
            self._json(200, {'arenas': [], 'error': str(e)})

    def _handle_games_list(self):
        n = 200
        if 'n=' in self.path:
            try: n = int(self.path.split('n=')[1].split('&')[0])
            except Exception: pass
        self._json(200, {'games': _list_games(n)})

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

    def _handle_train_status(self):
        self._json(200, _trainer_status())

    def _handle_bot_logs(self):
        try:
            n = 20
            if 'n=' in self.path:
                try: n = int(self.path.split('n=')[1].split('&')[0])
                except Exception: pass
            dc = _docker_client()
            containers = dc.containers.list(filters={'name': 'cassandrajl-bot'})
            if not containers:
                self._json(200, {'lines': [], 'running': False}); return
            c = containers[0]
            raw = c.logs(tail=n, timestamps=True).decode('utf-8', errors='replace')
            lines = [l for l in raw.splitlines() if l.strip()][-n:]
            self._json(200, {'lines': lines, 'running': True})
        except Exception as e:
            self._json(200, {'lines': [], 'running': False, 'error': str(e)})

    def _handle_train_start(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            params = json.loads(self.rfile.read(length)) if length else {}
            self._json(200, _start_trainer(params))
        except RuntimeError as e:
            self._json(409, {'ok': False, 'error': str(e)})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    def _handle_train_stop(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, _stop_trainer())
        except RuntimeError as e:
            self._json(409, {'ok': False, 'error': str(e)})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    def _handle_bot_restart(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, _restart_container('cassandrajl-bot'))
        except RuntimeError as e:
            self._json(409, {'ok': False, 'error': str(e)})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    def _bot_get(self, path, fallback):
        try:
            req = urllib.request.Request(f'{BOT_CONTROL}{path}')
            with urllib.request.urlopen(req, timeout=3) as r:
                return json.loads(r.read())
        except Exception:
            return fallback

    def _bot_post(self, path, body=None):
        data = body if body is not None else b''
        headers = {'Content-Type': 'application/json'} if body else {}
        req = urllib.request.Request(f'{BOT_CONTROL}{path}', data=data, method='POST')
        for k, v in headers.items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.loads(r.read())

    def _handle_games_status(self):
        self._json(200, self._bot_get('/games/status', {'paused': False, 'unreachable': True}))

    def _handle_games_pause(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, self._bot_post('/games/pause'))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_games_resume(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, self._bot_post('/games/resume'))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_challenge_status(self):
        self._json(200, self._bot_get('/challenge/status', {'paused': False, 'unreachable': True}))

    def _handle_challenge_pause(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, self._bot_post('/challenge/pause'))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_challenge_resume(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, self._bot_post('/challenge/resume'))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_search_config_get(self):
        self._json(200, self._bot_get('/search/config', {'max_depth': None, 'unreachable': True}))

    def _handle_search_config_set(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = self.rfile.read(length) if length else b'{}'
            self._json(200, self._bot_post('/search/config', body))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_dashboard_restart(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            # Find own container, respond first, then restart in background
            dc = _docker_client()
            containers = dc.containers.list(filters={'name': 'cassandrajl-dashboard'})
            if not containers:
                self._json(404, {'ok': False, 'error': 'Dashboard container not found'}); return
            c = containers[0]
            self._json(200, {'ok': True, 'container': c.name})
            import threading
            threading.Timer(0.5, lambda: c.restart(timeout=5)).start()
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _serve_file(self, fpath, content_type):
        if os.path.isfile(fpath):
            with open(fpath, 'rb') as f:
                data = f.read()
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', len(data))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_error(404)

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
    with http.server.HTTPServer(('', PORT), Handler) as httpd:
        print(f'Dashboard → http://localhost:{PORT}')
        httpd.serve_forever()
