const vm = require('node:vm');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const qml = fs.readFileSync(path.join(__dirname, 'Panel.qml'), 'utf8');

// Execute the real QML functions; callback ordering is controlled by each test.
function context() {
  const settings = { enabled: true, natural_scroll: false, tap_to_click: true,
    disable_while_typing: true, clickfinger_behavior: true, accel_profile: 'adaptive',
    scroll_factor: 0.2, sensitivity: 0.1 };
  const ctx = {
    devices: [
      { id: 'apple', label: 'Apple', connected: true, names: ['apple'], settings: { ...settings } },
      { id: 'dell', label: 'Dell', connected: true, names: ['dell'], settings: { ...settings, sensitivity: 0.3 } }
    ],
    selectedDevice: 'apple', pendingActions: [], settingsError: '',
    presetPending: false, canRestorePreset: false,
    editGeneration: 0, stateGeneration: 0, refreshPending: false,
    actionProc: { running: false }, stateProc: { running: false }, backend: 'trackpads.py',
    Model: { clampSensitivity: x => x },
    scrollDebounce: { running: false, stop() { this.running = false; } },
    pointerDebounce: { running: false, stop() { this.running = false; } }
  };
  vm.createContext(ctx);
  const functions = qml.match(/^  function \w+\([^\n]*\) \{[^\n]*\}$|^  function \w+\([^\n]*\) \{\n[\s\S]*?^  \}/gm);
  for (const source of functions) vm.runInContext(source, ctx);
  ctx.loadSelection();
  return ctx;
}

{
  const ctx = context();
  ctx.selectDevice('dell');
  ctx.actionProc.running = true;
  ctx.scrollDebounce.running = ctx.pointerDebounce.running = true;
  ctx.pendingScrollFactor = 0.6;
  ctx.pendingPointerSpeed = 0.8;
  ctx.selectDevice('apple');
  assert.equal(ctx.pendingActions.length, 2);
  assert.ok(ctx.pendingActions.every(x => x.device === 'dell'));
  assert.equal(ctx.pendingActions[0].value, 0.6);
  assert.equal(ctx.pendingActions[1].value, 0.8);
  assert.equal(ctx.pointerSpeed, 0.1);
  ctx.togglePointerAcceleration();
  assert.equal(ctx.pendingActions[2].device, 'apple');
  assert.equal(ctx.pendingActions[2].value, 'flat');
  ctx.selectDevice('dell');
  assert.equal(ctx.pointerAcceleration, true);
}

{
  const ctx = context();
  const oldRead = JSON.stringify({ devices: ctx.devices });
  ctx.refresh();
  ctx.toggleNaturalScroll();
  assert.equal(ctx.naturalScroll, true);
  ctx.actionProc.running = false;
  ctx.finishAction(0); // The old state process is still running.
  ctx.receiveState(oldRead);
  assert.equal(ctx.naturalScroll, true, 'late read must not revert the successful edit');
  ctx.stateProc.running = false;
  ctx.finishStateRead(0);
  assert.equal(ctx.stateProc.running, true, 'discarding a stale read must schedule a fresh read');
  ctx.receiveState(JSON.stringify({ devices: ctx.devices }));
  ctx.stateProc.running = false;
  ctx.finishStateRead(0);
  assert.equal(ctx.stateProc.running, false, 'a successful read must not poll in a tight loop');
  ctx.toggleNaturalScroll();
  assert.equal(JSON.parse(ctx.actionProc.command.at(-1)), false, 'next click must reverse the edit');
}

{
  const ctx = context();
  ctx.refresh();
  ctx.scrollDebounce.running = true;
  ctx.receiveState(JSON.stringify({ devices: ctx.devices }));
  ctx.stateProc.running = false;
  ctx.finishStateRead(0);
  assert.equal(ctx.stateProc.running, false, 'refresh must wait for pending slider edits');
  ctx.scrollDebounce.running = false;
  ctx.pendingScrollFactor = 0.7;
  ctx.commitScrollFactor();
  ctx.actionProc.running = false;
  ctx.finishAction(0);
  assert.equal(ctx.stateProc.running, true);
}

{
  const ctx = context();
  ctx.toggleNaturalScroll();
  ctx.togglePointerAcceleration();
  ctx.actionProc.running = false;
  ctx.finishAction(124);
  assert.match(ctx.settingsError, /Could not save/);
  assert.equal(ctx.actionProc.running, true, 'a timed-out write must release the next queued write');
  assert.equal(ctx.actionProc.command.at(-2), 'accel_profile');
  ctx.actionProc.running = false;
  ctx.finishAction(0);
  assert.equal(ctx.stateProc.running, true);
  ctx.stateProc.running = false;
  ctx.settingsError = '';
  ctx.finishStateRead(124);
  assert.match(ctx.settingsError, /Could not read/);
  assert.equal(ctx.stateProc.running, false, 'a failed read must not immediately retry forever');
  ctx.refresh();
  assert.equal(ctx.stateProc.running, true, 'a subsequent poll must recover after a read timeout');
}

{
  const ctx = context();
  const argv = ctx.bounded(0.05, ['python3', '-c', 'import time; time.sleep(60)']);
  const result = spawnSync(argv[0], Array.from(argv.slice(1)), { timeout: 4000 });
  assert.ifError(result.error);
  assert.equal(result.status, 124, 'the actual timeout wrapper must reap a stalled helper');
  assert.match(qml, /command: root\.bounded\(15, \["python3", root\.backend, "state"\]\)/);
  ctx.toggleNaturalScroll();
  assert.deepEqual(Array.from(ctx.actionProc.command.slice(0, 4)), ['timeout', '-k', '2', '10']);
}

{
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  assert.equal(manifest.id, 'awkent01.touchpad');
  assert.match(qml, /ipcTarget: "awkent01\.touchpad"/);
  assert.match(qml, /manageIpc: true/);
  assert.match(qml, /root\.receiveState\(String\(text\)\)/);
  assert.match(qml, /Qt\.callLater\(function\(\) \{ root\.finishStateRead\(code\) \}\)/);
  assert.match(qml, /Qt\.callLater\(function\(\) \{ root\.finishAction\(code\) \}\)/);
}
console.log('Passed: device selection, stale-read rejection, debounce ordering, timeout recovery, and IPC configuration.');

{
  const ctx = context();
  ctx.scrollDebounce.running = true;
  ctx.pendingScrollFactor = 0.9;
  ctx.applyPreset(false);
  assert.equal(ctx.actionProc.command.at(-2), 'scroll_factor');
  assert.equal(ctx.pendingActions[0].command, 'preset');
  assert.equal(ctx.pendingActions[0].device, 'apple');
  ctx.applyPreset(false);
  assert.equal(ctx.pendingActions.length, 1, 'ignore double activation');
  ctx.actionProc.running = false;
  ctx.finishAction(0);
  assert.deepEqual(Array.from(ctx.actionProc.command.slice(-2)), ['preset', 'apple']);
  ctx.actionProc.running = false;
  ctx.finishAction(0);
  ctx.devices[0].before_comfortable = { sensitivity: 0.1 };
  ctx.receiveState(JSON.stringify({ devices: ctx.devices }));
  assert.equal(ctx.presetPending, false);
  assert.equal(ctx.canRestorePreset, true);
  ctx.applyPreset(true);
  assert.deepEqual(Array.from(ctx.actionProc.command.slice(-2)), ['restore', 'apple']);
  ctx.finishStateRead(124);
  assert.equal(ctx.presetPending, false, 'read failure must not leave controls disabled');
}
console.log('Passed: preset queue ordering, double-click protection, persistent undo state and error recovery.');
