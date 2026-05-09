#!/usr/bin/env python3
import http.server
import json
import os
import random
import shutil
import urllib.request
import urllib.error
from datetime import datetime, timezone

# Setup name dictionary — same flavour as checkpoint run names in scripts/train.jl
_SETUP_ADJECTIVES = [
    "brilliant","tactical","aggressive","positional","relentless","tenacious",
    "sharp","enduring","bold","ruthless","calm","precise","wild","patient",
    "cunning","fearless","legendary","electric","unstoppable","eternal","furious",
    "silent","classical","dynamic","prophylactic","hypermodern","zugzwang",
    "combinatorial","deep",
]
_SETUP_PLAYERS = [
    "kasparov","fischer","tal","karpov","anand","carlsen","morphy","capablanca",
    "botvinnik","kramnik","spassky","bronstein","petrosian","smyslov","nimzowitsch",
    "larsen","topalov","polgar","alekhine","reshevsky","geller","kortchnoi","euwe",
    "lasker","steinitz",
]

def _random_setup_name():
    return f'{random.choice(_SETUP_ADJECTIVES)}_{random.choice(_SETUP_PLAYERS)}'

PORT            = int(os.environ.get("PORT", 8000))
ROOT            = os.path.dirname(os.path.abspath(__file__))
CHECKPOINTS     = os.environ.get("CHECKPOINTS_DIR", os.path.join(ROOT, "..", "checkpoints"))
SETUPS_DIR      = os.environ.get("SETUPS_DIR",      os.path.join(ROOT, "..", "setups"))
LOGS_DIR        = os.environ.get("LOGS_DIR",        os.path.join(ROOT, "..", "logs"))
TRACES_DIR      = os.environ.get("TRACES_DIR",      os.path.join(LOGS_DIR, "game_traces"))
BOT_CONTROL     = os.environ.get("BOT_CONTROL_URL",  "http://bot:8080")
LICHESS_TOKEN   = os.environ.get("LICHESS_TOKEN", "")
DASHBOARD_SECRET = os.environ.get("DASHBOARD_SECRET", "")
TRAINER_IMAGE   = os.environ.get("TRAINER_IMAGE", "cassandrajl-trainer")
ARENA_IMAGE     = os.environ.get("ARENA_IMAGE",   "cassandrajl-arena")
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

def _arena_series():
    """Read arena_log.jsonl and return one history-series per opponent."""
    log_path = os.path.join(LOGS_DIR, 'arena_log.jsonl')
    if not os.path.isfile(log_path):
        return []
    by_opponent = {}
    with open(log_path) as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            opp = r.get('opponent', 'arena')
            by_opponent.setdefault(opp, []).append(r)
    series = []
    for opp, records in by_opponent.items():
        points = []
        for r in records:
            elo = r.get('cassandra_elo')
            if elo is None:
                continue
            points.append([r['year'], r['month'] - 1, r['day'], round(elo)])
        if points:
            series.append({'name': opp, 'points': points})
    return series

def _get_rating_history():
    global _bot_username
    arena = _arena_series()
    if not LICHESS_TOKEN:
        if arena:
            return {'username': 'cassandra-jl', 'history': arena}, None
        return None, 'No LICHESS_TOKEN set'
    try:
        if not _bot_username:
            profile = _lichess('/api/account')
            _bot_username = profile['username']
        history = _lichess(f'/api/user/{_bot_username}/rating-history')
        active = [p for p in history if p.get('points')]
        return {'username': _bot_username, 'history': active + arena}, None
    except urllib.error.URLError as e:
        if arena:
            return {'username': _bot_username or 'cassandra-jl', 'history': arena}, None
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

# ── Setups ────────────────────────────────────────────────────────────────────

def _setups_dir():
    os.makedirs(SETUPS_DIR, exist_ok=True)
    return SETUPS_DIR

def _list_setups():
    d = _setups_dir()
    skip = {'deployed.json'}
    result = []
    deployed_name = None
    deployed_path = os.path.join(d, 'deployed.json')
    if os.path.isfile(deployed_path):
        try:
            with open(deployed_path) as f:
                deployed_name = json.load(f).get('name')
        except Exception:
            pass
    try:
        files = sorted(f for f in os.listdir(d) if f.endswith('.json') and f not in skip)
    except OSError:
        files = []
    for fname in files:
        path = os.path.join(d, fname)
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            continue
        name = os.path.splitext(fname)[0]
        mtime = os.path.getmtime(path)
        result.append({
            'name': name,
            'created_at': data.get('created_at', ''),
            'checkpoint': data.get('checkpoint', ''),
            'deployed': name == deployed_name,
            'mtime': mtime,
            'config': data,
        })
    return result

def _get_setup(name):
    safe = os.path.basename(name)
    path = os.path.join(_setups_dir(), f'{safe}.json')
    if not os.path.isfile(path):
        raise FileNotFoundError(f'Setup not found: {safe}')
    with open(path) as f:
        return json.load(f)

# Canonical defaults — all engine parameters have a definite value.
# These match the Julia SearchConfig/EvalConfig/etc. @kwdef defaults, but
# tuned for "fast yet normal-strength": all techniques on, depth/time reduced.
_SETUP_DEFAULTS = {
    'search': {
        'max_depth':               6,
        'time_limit_s':            0.5,
        'tt_size_log2':            20,
        'qsearch':                 True,
        'delta_pruning_margin_cp': 200,
        'check_extension':         True,
        'null_move_enabled':       True,
        'null_move_R':             2,
        'null_move_min_depth':     3,
        'lmr_enabled':             True,
        'lmr_min_depth':           3,
        'lmr_min_move_idx':        4,
        'lmr_reduction':           1,
        'aspiration_window_cp':    50,
    },
    'eval': {
        'bishop_pair_cp': 40,
        'rook_open_cp':   25,
        'rook_semi_cp':   12,
    },
    'ordering': {
        'use_policy_logits': False,
        'killers':           True,
        'history':           True,
    },
    'book': {
        'enabled': True,
        'max_ply': 16,
    },
}

def _normalize_setup(data):
    """Fill in missing or null fields using _SETUP_DEFAULTS."""
    for section, fields in _SETUP_DEFAULTS.items():
        sec = data.get(section)
        if not isinstance(sec, dict):
            data[section] = dict(fields)
        else:
            for k, default_v in fields.items():
                if sec.get(k) is None:
                    sec[k] = default_v
    data['ordering']['use_policy_logits'] = False  # never load NN
    return data

def _save_setup(name, data):
    safe = os.path.basename(name)
    if not safe:
        raise ValueError('Invalid setup name')
    data['name'] = safe
    _normalize_setup(data)
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
    data['name'] = safe  # always ensure name is present
    # Strip NN flag — classical engine only
    if isinstance(data.get('ordering'), dict):
        data['ordering']['use_policy_logits'] = False
    data['deployed_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
    dst = os.path.join(_setups_dir(), 'deployed.json')
    with open(dst, 'w') as f:
        json.dump(data, f, indent=2)

    # Audit log
    history_path = os.path.join(_setups_dir(), 'history.jsonl')
    with open(history_path, 'a') as f:
        f.write(json.dumps({'ts': data['deployed_at'], 'name': safe}) + '\n')

    # Signal bot to reload
    try:
        req = urllib.request.Request(f'{BOT_CONTROL}/reload', data=b'', method='POST')
        with urllib.request.urlopen(req, timeout=5):
            pass
        return {'ok': True, 'setup': safe}
    except Exception as e:
        return {'ok': True, 'setup': safe, 'warn': f'Bot reload failed: {e}'}

def _delete_setup(name):
    safe = os.path.basename(name)
    if safe in ('deployed',):
        raise ValueError(f'Cannot delete reserved setup: {safe}')
    # Refuse if deployed
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

def _engine_config_schema():
    """Return schema served from the bot control server."""
    try:
        with urllib.request.urlopen(f'{BOT_CONTROL}/engine_config/schema', timeout=5) as r:
            return json.loads(r.read())
    except Exception:
        return {}

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
        'VALUE_WEIGHT':    str(params.get('value_weight', 0.5)),
        'WEIGHT_DECAY':    str(params.get('weight_decay', '1e-4')),
        'ARCH':            params.get('arch', 'conv'),
        'N_CHANNELS':      str(params.get('n_channels', 32)),
        'N_BLOCKS':        str(params.get('n_blocks',   2)),
        'TRUNK_SIZES':     params.get('trunk_sizes', '256,128'),
        'DROPOUT':         str(params.get('dropout',      0.0)),
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

def _arena_log():
    log_path = os.path.join(LOGS_DIR, 'arena_log.jsonl')
    records = []
    if os.path.isfile(log_path):
        with open(log_path) as f:
            for line in f:
                try:
                    records.append(json.loads(line))
                except Exception:
                    pass
    return records

def _arena_status():
    try:
        dc = _docker_client()
        containers = dc.containers.list(filters={'name': 'cassandrajl-arena'})
        if containers:
            c = containers[0]
            return {'running': True, 'container_id': c.short_id,
                    'started_at': c.attrs['State']['StartedAt']}
        return {'running': False}
    except Exception as e:
        return {'running': False, 'error': str(e)}

def _start_arena(params):
    dc = _docker_client()
    if dc.containers.list(filters={'name': 'cassandrajl-arena-run'}):
        raise RuntimeError('Arena match already running')
    env = {
        'STOCKFISH_ELO':  str(params.get('stockfish_elo', 1500)),
        'GAMES':          str(params.get('games', 100)),
        'MOVE_TIME':      str(params.get('move_time', 1.0)),
        'CHECKPOINTS_DIR': '/data/checkpoints',
        'SETUPS_DIR':     '/data/setups',
        'LOGS_DIR':       '/data/logs',
    }
    volumes = {
        f'{COMPOSE_PROJECT}_checkpoints': {'bind': '/data/checkpoints', 'mode': 'rw'},
        f'{COMPOSE_PROJECT}_logs':        {'bind': '/data/logs',        'mode': 'rw'},
        f'{COMPOSE_PROJECT}_setups':      {'bind': '/data/setups',      'mode': 'rw'},
    }
    container = dc.containers.run(
        image=ARENA_IMAGE,
        command='python3 /app/arena/match.py',
        environment=env,
        volumes=volumes,
        network=f'{COMPOSE_PROJECT}_internal',
        detach=True,
        remove=True,
        name='cassandrajl-arena-run',
    )
    return {'ok': True, 'container_id': container.short_id}

def _stop_arena():
    dc = _docker_client()
    containers = dc.containers.list(filters={'name': 'cassandrajl-arena'})
    if not containers:
        raise RuntimeError('No arena container running')
    for c in containers:
        c.stop(timeout=10)
    return {'ok': True}

def _arena_logs(n=50):
    try:
        dc = _docker_client()
        containers = dc.containers.list(filters={'name': 'cassandrajl-arena'})
        if not containers:
            return {'lines': [], 'running': False}
        c = containers[0]
        raw = c.logs(tail=n, timestamps=False).decode('utf-8', errors='replace')
        lines = [l for l in raw.splitlines() if l.strip()][-n:]
        return {'lines': lines, 'running': True}
    except Exception as e:
        return {'lines': [], 'running': False, 'error': str(e)}

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
        elif path == '/api/bot/status':                self._handle_bot_status()
        elif path == '/api/bot/config':               self._handle_bot_config_get()
        elif path.startswith('/api/bot/logs'):        self._handle_bot_logs()
        elif path == '/api/arena':                      self._handle_arena_get()
        elif path.startswith('/api/arena/logs'):        self._handle_arena_logs()
        elif path == '/api/games':                      self._handle_games_list()
        elif path.startswith('/api/games/') and path.endswith('/trace'):
            gid = path[len('/api/games/'):-len('/trace')]
            self._handle_game_trace(gid)
        elif path == '/api/book':                      self._handle_book_get()
        elif path == '/api/setups':                    self._handle_setups_list()
        elif path == '/api/setups/schema':             self._handle_setups_schema()
        elif path.startswith('/api/setups/') and not path.endswith('/deploy'):
            self._handle_setup_get(path[len('/api/setups/'):])
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
        elif path.startswith('/api/setups/'):
            if not _auth_ok(self.headers):
                self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
            name = path[len('/api/setups/'):]
            try:
                self._json(200, _delete_setup(name))
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
        elif path == '/api/bot/pause':             self._handle_bot_pause()
        elif path == '/api/bot/resume':            self._handle_bot_resume()
        elif path == '/api/bot/config':            self._handle_bot_config_set()
        elif path == '/api/dashboard/restart':     self._handle_dashboard_restart()
        elif path == '/api/arena/run':             self._handle_arena_run()
        elif path == '/api/arena/stop':            self._handle_arena_stop()
        elif path == '/api/book/line':             self._handle_book_add_line()
        elif path == '/api/book/entry/delete':     self._handle_book_delete_entry()
        elif path == '/api/book/import':           self._handle_book_import()
        elif path == '/api/book/clear':            self._handle_book_clear()
        elif path == '/api/setups':                self._handle_setup_create()
        elif path.startswith('/api/setups/') and path.endswith('/deploy'):
            self._handle_setup_deploy(path[len('/api/setups/'):-len('/deploy')])
        elif path.startswith('/api/setups/'):
            self._handle_setup_update(path[len('/api/setups/'):])
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

    # ── Setups ────────────────────────────────────────────────────────────────

    def _handle_setups_list(self):
        self._json(200, {'setups': _list_setups()})

    def _handle_setups_schema(self):
        self._json(200, _engine_config_schema())

    def _handle_setup_get(self, name):
        try:
            self._json(200, _get_setup(name))
        except FileNotFoundError as e:
            self._json(404, {'ok': False, 'error': str(e)})

    def _handle_setup_create(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            data   = json.loads(self.rfile.read(length)) if length else {}
            name   = (data.get('name') or '').strip() or _random_setup_name()
            # Avoid collisions
            existing = {s['name'] for s in _list_setups()}
            base = name; n = 1
            while name in existing:
                n += 1
                name = f'{base}_{n}'
            data['name'] = name
            data['created_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
            _save_setup(name, data)
            self._json(200, {'ok': True, 'name': name})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    def _handle_setup_update(self, name):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            data   = json.loads(self.rfile.read(length)) if length else {}
            safe   = os.path.basename(name)
            # Deep-merge into existing
            try:
                existing = _get_setup(safe)
            except FileNotFoundError:
                existing = {}
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
        try:
            self._json(200, _deploy_setup(name))
        except FileNotFoundError as e:
            self._json(404, {'ok': False, 'error': str(e)})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

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

    def _handle_bot_status(self):
        self._json(200, self._bot_get('/status', {'unreachable': True}))

    def _handle_bot_config_get(self):
        self._json(200, self._bot_get('/config', {'unreachable': True}))

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

    def _handle_arena_get(self):
        self._json(200, {'records': _arena_log(), 'status': _arena_status()})

    def _handle_arena_logs(self):
        n = 50
        if 'n=' in self.path:
            try: n = int(self.path.split('n=')[1].split('&')[0])
            except Exception: pass
        self._json(200, _arena_logs(n))

    def _handle_arena_run(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            params = json.loads(self.rfile.read(length)) if length else {}
            self._json(200, _start_arena(params))
        except RuntimeError as e:
            self._json(409, {'ok': False, 'error': str(e)})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    def _handle_arena_stop(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, _stop_arena())
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

    # ── Book ──────────────────────────────────────────────────────────────────

    def _handle_book_get(self):
        self._json(200, self._bot_get('/book', {'count': 0, 'entries': [], 'unreachable': True}))

    def _handle_book_add_line(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = self.rfile.read(length) if length else b'{}'
            self._json(200, self._bot_post('/book/line', body))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_book_delete_entry(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = self.rfile.read(length) if length else b'{}'
            self._json(200, self._bot_post('/book/entry/delete', body))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_book_import(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, self._bot_post('/book/import'))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_book_clear(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, self._bot_post('/book/clear'))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

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

    def _handle_bot_pause(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, self._bot_post('/pause'))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

    def _handle_bot_resume(self):
        if not _auth_ok(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'}); return
        try:
            self._json(200, self._bot_post('/resume'))
        except Exception as e:
            self._json(502, {'ok': False, 'error': str(e)})

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
