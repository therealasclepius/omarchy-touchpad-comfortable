import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('trackpads',Path(__file__).with_name('trackpads.py'))
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class TrackpadTests(unittest.TestCase):
    def setUp(self):
        self.groups=m.group_devices([{'name':n} for n in ['ven_06cb:00-06cb:d01d-touchpad','apple-inc.-magic-trackpad','apple-inc.-magic-trackpad-1','usb-mouse']])
        for g in self.groups.values():
            g['settings']={'enabled':True,'sensitivity':0.3 if g['id']=='dell' else 0.1,'scroll_factor':0.2,'natural_scroll':False,'tap_to_click':True,'clickfinger_behavior':True,'disable_while_typing':True}
        self.state={'version':1,'devices':self.groups}

    def test_groups_two_apple_interfaces_without_mouse(self):
        self.assertEqual(set(self.groups),{'apple','dell'})
        self.assertEqual(len(self.groups['apple']['names']),2)

    def test_acceleration_migration_preserves_existing_settings(self):
        migrated = m.migrate(self.state)
        self.assertEqual(migrated['version'], 2)
        for key in self.groups:
            settings = dict(migrated['devices'][key]['settings'])
            self.assertEqual(settings.pop('accel_profile'), 'adaptive')
            self.assertEqual(settings, self.groups[key]['settings'])
        migrated['devices']['apple']['settings']['accel_profile'] = 'flat'
        self.assertEqual(m.migrate(migrated), migrated)

    def test_acceleration_change_targets_only_selected_trackpad(self):
        state = m.migrate(self.state)
        with patch.object(m, 'hypr') as run, patch.object(m, 'save'):
            updated = m.change(state, 'apple', 'accel_profile', 'flat')
        self.assertEqual(updated['devices']['dell'], state['devices']['dell'])
        self.assertEqual(run.call_args.args[1].count('accel_profile = "flat"'), 2)
        self.assertNotIn('ven_06cb', run.call_args.args[1])
        for value in [True, None, 0, 'custom', 'bad"lua', []]:
            with self.assertRaises(ValueError):
                m.validate_setting('accel_profile', value)

    def test_change_apple_only_and_persist_both(self):
        with tempfile.TemporaryDirectory() as d, patch.object(m,'STATE',Path(d)/'settings.json'), patch.object(m,'GENERATED',Path(d)/'settings.lua'), patch.object(m,'hypr') as run:
            updated=m.change(self.state,'apple','scroll_factor',0.7)
            self.assertEqual(updated['devices']['dell'],self.state['devices']['dell'])
            self.assertEqual(updated['devices']['apple']['settings']['scroll_factor'],0.7)
            lua=run.call_args.args[1]
            self.assertFalse(lua.lstrip().startswith('-'), 'Lua must not be parsed as a hyprctl flag')
            self.assertNotIn('ven_06cb',lua)
            self.assertEqual(lua.count('hl.device('),2)
            self.assertNotIn('hl.config(',m.GENERATED.read_text())
            self.assertEqual(json.loads(m.STATE.read_text()),updated)

    def test_invalid_settings_and_names_rejected_before_apply(self):
        for key,value in [('sensitivity',9),('scroll_factor',float('nan')),('enabled','false'),('unknown',True)]:
            with patch.object(m,'hypr') as run, self.assertRaises(ValueError):m.change(self.state,'apple',key,value)
            run.assert_not_called()
        with self.assertRaises(ValueError):m.validate_name('bad" }); os.execute("x")')

    def test_disabled_or_unplugged_device_remains_selectable(self):
        state=copy.deepcopy(self.state)
        state['devices']['apple']['settings']['enabled']=False
        view=m.snapshot(state,{'dell':self.groups['dell']})
        apple=next(g for g in view['devices'] if g['id']=='apple')
        self.assertFalse(apple['connected'])
        self.assertFalse(apple['settings']['enabled'])
        self.assertEqual(len(apple['names']),2)

    def test_apply_error_does_not_persist(self):
        with patch.object(m,'hypr',side_effect=RuntimeError('rejected')),patch.object(m,'save') as save:
            with self.assertRaises(RuntimeError):m.change(self.state,'dell','sensitivity',0.9)
            save.assert_not_called()

    def test_save_failure_rolls_back(self):
        with patch.object(m,'hypr') as run,patch.object(m,'save',side_effect=[OSError('disk full'),None]):
            with self.assertRaises(OSError):m.change(self.state,'apple','sensitivity',0.5)
            self.assertIn('sensitivity = 0.1',run.call_args.args[1])
            self.assertNotIn('ven_06cb',run.call_args.args[1])

    def test_preset_preserves_direction_device_state_and_other_devices(self):
        for natural in (False, True):
            state = m.migrate(self.state)
            state['devices']['apple']['settings'].update(natural_scroll=natural, enabled=False)
            with patch.object(m, 'hypr') as run, patch.object(m, 'save'):
                updated = m.preset(state, 'apple')
            settings = updated['devices']['apple']['settings']
            self.assertEqual(settings['natural_scroll'], natural)
            self.assertFalse(settings['enabled'])
            self.assertEqual(settings['scroll_factor'], 0.65)
            self.assertEqual(updated['devices']['dell'], state['devices']['dell'])
            self.assertEqual(run.call_count, 1)
            self.assertNotIn('ven_06cb', run.call_args.args[1])

    def test_reapply_and_restore_preserve_original_and_later_direction_choice(self):
        state = m.migrate(self.state)
        with patch.object(m, 'hypr'), patch.object(m, 'save'):
            applied = m.preset(state, 'apple')
            applied = m.change(applied, 'apple', 'sensitivity', 0.8)
            applied = m.preset(applied, 'apple')
            applied = m.change(applied, 'apple', 'natural_scroll', True)
            restored = m.preset(applied, 'apple', restore=True)
        expected = copy.deepcopy(state)
        expected['devices']['apple']['settings']['natural_scroll'] = True
        self.assertEqual(restored, expected)
        with patch.object(m, 'hypr') as run, self.assertRaises(ValueError):
            m.preset(restored, 'apple', restore=True)
        run.assert_not_called()

    def test_failed_preset_save_restores_settings_and_does_not_mutate_state(self):
        state = m.migrate(self.state)
        original = copy.deepcopy(state)
        with patch.object(m, 'hypr') as run, patch.object(m, 'save', side_effect=[OSError('full'), None]):
            with self.assertRaises(OSError):
                m.preset(state, 'apple')
        self.assertEqual(state, original)
        self.assertIn('sensitivity = 0.1', run.call_args.args[1])

    def test_unknown_preset_device_is_rejected(self):
        with patch.object(m, 'hypr') as run, self.assertRaises(ValueError):
            m.preset(m.migrate(self.state), 'not-connected-before')
        run.assert_not_called()

if __name__=='__main__':unittest.main()
