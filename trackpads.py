#!/usr/bin/env python3
"""Per-device trackpad settings for the local Omarchy panel."""
import copy
import fcntl
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

STATE_ROOT = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state')))
DIRECTORY = STATE_ROOT / 'omarchy/local-touchpads'
STATE = DIRECTORY / 'settings.json'
GENERATED = STATE_ROOT / 'omarchy/toggles/hypr/zz-local-touchpads.lua'
BOOLS = {'enabled', 'natural_scroll', 'tap_to_click', 'disable_while_typing', 'clickfinger_behavior'}
RANGES = {'sensitivity': (-1, 1), 'scroll_factor': (0.1, 2)}
COMFORTABLE = {
    'sensitivity': 0.2, 'accel_profile': 'adaptive', 'scroll_factor': 0.65,
    'tap_to_click': True, 'clickfinger_behavior': True,
}


def hypr(*args):
    result = subprocess.run(['hyprctl', *args], text=True, capture_output=True, timeout=4, check=True)
    if args[0] == 'eval' and result.stdout.strip() != 'ok':
        raise RuntimeError(result.stdout.strip() or result.stderr.strip() or 'Hyprland rejected settings')
    return result.stdout


def validate_name(name):
    if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_.:+-]{1,128}', name):
        raise ValueError('Unsupported trackpad device name')
    return name


def validate_setting(key, value):
    if key == 'accel_profile':
        if value not in ('adaptive', 'flat'):
            raise ValueError('Expected adaptive or flat acceleration')
    elif key in BOOLS:
        if type(value) is not bool:
            raise ValueError('Expected a boolean')
    elif key in RANGES:
        low, high = RANGES[key]
        if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
            raise ValueError('Setting is outside its allowed range')
    else:
        raise ValueError('Unknown setting')
    return value


def group_devices(mice):
    groups = {}
    for mouse in mice:
        name = mouse['name']
        if not re.search('touchpad|trackpad', name, re.I):
            continue
        validate_name(name)
        if name.startswith('apple-inc.-magic-trackpad'):
            key, label = 'apple', 'Apple'
        elif name == 'ven_06cb:00-06cb:d01d-touchpad':
            key, label = 'dell', 'Dell'
        else:
            key, label = name, name
        groups.setdefault(key, {'id': key, 'label': label, 'names': []})['names'].append(name)
    return groups


def lua_for(groups):
    # hyprctl interprets an argument starting with '--' as a CLI flag.
    lines = ['do -- Managed by local.touchpads. Change settings in the Trackpads panel.']
    for group in groups.values():
        fields = []
        for key, value in sorted(group['settings'].items()):
            validate_setting(key, value)
            fields.append(f'{key} = {json.dumps(value)}')
        for name in group['names']:
            validate_name(name)
            lines.append('hl.device({ name = ' + json.dumps(name) + ', ' + ', '.join(fields) + ' })')
    return '\n'.join(lines + ['end']) + '\n'


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError('Refusing to replace a symbolic link')
    fd, temp = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def save(state):
    atomic_write(GENERATED, lua_for(state['devices']))
    atomic_write(STATE, json.dumps(state, indent=2) + '\n')


def defaults():
    values = {}
    for key in sorted(BOOLS - {'enabled'} | {'scroll_factor'}):
        option = json.loads(hypr('getoption', 'input:touchpad:' + key, '-j'))
        values[key] = option.get('bool', option.get('float'))
        validate_setting(key, values[key])
    values['sensitivity'] = json.loads(hypr('getoption', 'input:sensitivity', '-j'))['float']
    values['enabled'] = True
    values['accel_profile'] = 'adaptive'
    return values


def initialize(live):
    base = defaults()
    devices = copy.deepcopy(live)
    # Import the old panel's Dell-only pointer setting without executing its Lua.
    legacy = STATE_ROOT / 'omarchy/toggles/hypr/touchpad-settings.lua'
    text = legacy.read_text() if legacy.is_file() else ''
    overrides = dict(re.findall(r'hl\.device\(\{ name = "([A-Za-z0-9_.:+-]+)", sensitivity = (-?[0-9.]+) \}\)', text))
    for group in devices.values():
        group['settings'] = dict(base)
        for name in group['names']:
            if name in overrides:
                group['settings']['sensitivity'] = validate_setting('sensitivity', float(overrides[name]))
    return {'version': 1, 'devices': devices}


def snapshot(state, live):
    rows = []
    for key in sorted(state['devices'], key=lambda k: (k != 'apple', k != 'dell', k)):
        group = copy.deepcopy(state['devices'][key])
        group['connected'] = key in live
        rows.append(group)
    return {'devices': rows}


def migrate(state):
    """The previous panel inherited the driver's default adaptive profile."""
    updated = copy.deepcopy(state)
    for group in updated['devices'].values():
        group['settings'].setdefault('accel_profile', 'adaptive')
    updated['version'] = 2
    return updated


def change(state, key, option, value):
    validate_setting(option, value)
    if key not in state['devices']:
        raise ValueError('Unknown trackpad')
    updated = copy.deepcopy(state)
    updated['devices'][key]['settings'][option] = value
    return apply_change(state, updated, key)


def preset(state, key, restore=False):
    if key not in state['devices']:
        raise ValueError('Unknown trackpad')
    updated = copy.deepcopy(state)
    group = updated['devices'][key]
    if restore:
        if 'before_comfortable' not in group:
            raise ValueError('No previous preset settings to restore')
        values = group.pop('before_comfortable')
        if set(values) != set(COMFORTABLE):
            raise ValueError('Invalid preset backup')
    else:
        # Reapplying must not replace the original undo point.
        group.setdefault('before_comfortable', {
            option: group['settings'][option] for option in COMFORTABLE
        })
        values = COMFORTABLE
    for option, value in values.items():
        validate_setting(option, value)
    group['settings'].update(values)
    return apply_change(state, updated, key)


def apply_change(state, updated, key):
    # Only the selected trackpad receives a live update.
    hypr('eval', lua_for({key: updated['devices'][key]}))
    try:
        save(updated)
    except Exception:
        hypr('eval', lua_for({key: state['devices'][key]}))
        save(state)
        raise
    return updated


def main():
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(DIRECTORY / 'settings.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        live = group_devices(json.loads(hypr('devices', '-j'))['mice'])
        command = sys.argv[1] if len(sys.argv) > 1 else 'state'
        if STATE.exists():
            state = json.loads(STATE.read_text())
        elif command in ('state', 'init'):
            state = initialize(live)
            save(state)
        else:
            raise ValueError('Trackpads have not been initialized')
        upgraded = migrate(state)
        if upgraded != state:
            save(upgraded)
            state = upgraded
        # Keep saved settings while discovering trackpads attached after first run.
        previous = copy.deepcopy(state)
        new_devices = {key: group for key, group in live.items() if key not in state['devices']}
        if new_devices:
            state['devices'].update(initialize(new_devices)['devices'])
            state = migrate(state)
        for key, group in live.items():
            if key in state['devices']:
                state['devices'][key]['names'] = sorted(set(state['devices'][key]['names'] + group['names']))
        if state != previous:
            save(state)
        if command == 'set':
            if len(sys.argv) != 5:
                raise ValueError('Usage: trackpads.py set DEVICE OPTION JSON_VALUE')
            state = change(state, sys.argv[2], sys.argv[3], json.loads(sys.argv[4]))
        elif command in ('preset', 'restore'):
            if len(sys.argv) != 3:
                raise ValueError('Usage: trackpads.py preset|restore DEVICE')
            state = preset(state, sys.argv[2], restore=command == 'restore')
        elif command not in ('state', 'init'):
            raise ValueError('Unknown command')
        print(json.dumps(snapshot(state, live)))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(json.dumps({'error': str(exc)}))
        sys.exit(1)
