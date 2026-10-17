"""Regression cases from the Pi hotspot/WLED setup."""
import http.client
import io
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agent'))
from synclight_agent.config import StateStore, load_config
from synclight_agent.service import SyncLightService
from synclight_agent.hyperion import HyperionUnavailable
from synclight_agent.wled import WledClient, WledUnavailable
from synclight_agent.netmgr import NetManager


class ReliabilityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        cfg = load_config(None)
        self.service = SyncLightService(cfg, StateStore(os.path.join(self.tmp.name, 'state.json')))
        self.hyp = self.service.hyperion = Mock()
        self.hyp.serverinfo.return_value = {'priorities': []}

    def tearDown(self):
        self.tmp.cleanup()

    def test_hotspot_defaults_to_channel_one(self):
        run = Mock(side_effect=[(0, '', ''), (0, '', '')])
        NetManager(run).ensure_hotspot('SyncLight-test', 'testpass')
        args = run.call_args.args[0]
        self.assertEqual(args[args.index('802-11-wireless.channel') + 1], '1')

    def test_fade_grace_restore_and_do_not_persist_zero(self):
        s = self.service
        s.signal_tick(now=0)
        s.signal_tick(now=9)
        self.hyp.set_brightness.assert_not_called()
        s.signal_tick(now=11.5)
        self.hyp.set_brightness.assert_called_with(40)
        s.signal_tick(now=13)
        self.hyp.set_brightness.assert_called_with(0)
        self.assertEqual(s.state.data['light']['brightness'], 80)
        self.hyp.serverinfo.return_value = {'priorities': [{'componentId': 'V4L', 'active': True}]}
        s.signal_tick(now=14)
        self.hyp.set_brightness.assert_called_with(80)
        self.assertIsNone(s._signal_brightness)

    def test_color_and_calibration_do_not_fade(self):
        for mode, calibrating in [('color', False), ('sync', True)]:
            self.service.state.data['light']['mode'] = mode
            self.service._calibrating = calibrating
            self.service.signal_tick(now=0)
            self.service.signal_tick(now=100)
        self.hyp.set_brightness.assert_not_called()

    def test_errors_and_missing_status_are_not_signal_loss(self):
        self.hyp.serverinfo.return_value = {}
        self.service.signal_tick(now=0)
        self.hyp.serverinfo.side_effect = HyperionUnavailable('offline')
        with self.assertRaises(HyperionUnavailable):
            self.service.signal_tick(now=100)
        self.hyp.set_brightness.assert_not_called()

    def test_leaving_sync_restores_user_brightness(self):
        self.service.signal_tick(now=0)
        self.service.signal_tick(now=13)
        self.service.mode('color', [0, 255, 0])
        self.hyp.set_brightness.assert_called_with(80)
        self.assertIsNone(self.service._signal_missing_since)

    def test_truncated_response_retries_using_dhcp_despite_stale_dns(self):
        client = WledClient('led.local')
        client.fallback_lookup = lambda: '192.168.4.99'
        payload = io.BytesIO(json.dumps({'ver': '0.15.1'}).encode())
        with patch.object(client, '_resolve', return_value='192.168.4.10'), \
                patch.object(client._opener, 'open', side_effect=[http.client.IncompleteRead(b'bad'), payload]) as request:
            self.assertEqual(client.info()['ver'], '0.15.1')
            self.assertIn('192.168.4.99', request.call_args.args[0].full_url)

    def test_truncation_reported_as_unavailable(self):
        client = WledClient('127.0.0.1')
        with patch.object(client._opener, 'open', side_effect=http.client.IncompleteRead(b'bad')):
            with self.assertRaises(WledUnavailable):
                client.info()

    def test_rechecks_hyperion_after_restart_with_same_led_ip(self):
        s = self.service
        s.wled = Mock()
        s.wled.info.return_value = {'mac': 'c82b96230272'}
        s.wled.resolve.return_value = '192.168.4.99'
        s._hyperion_led_host = '192.168.4.99'
        self.hyp.get_led_device.return_value = {'type': 'wled', 'host': '192.168.4.10'}
        s.sync_led_host()
        self.hyp.set_instance_settings.assert_called_once_with({'device': {'type': 'wled', 'host': '192.168.4.99'}})
        self.assertEqual(s._net_state()['led_mac'], 'c82b96230272')

    def test_health_explains_disabled_output(self):
        s = self.service
        s.status = Mock(return_value={'hyperion': {'reachable': True, 'led_output': False, 'capture_active': True},
                                     'wled': {'reachable': True, 'response_ms': 10}, 'layout': None})
        s.net_status = Mock(return_value={'mode': 'hotspot'})
        s.net = Mock()
        s.net.get_field.return_value = '1'
        report = s.health()
        self.assertFalse(report['ok'])
        output = next(c for c in report['checks'] if c['name'] == 'output')
        self.assertIn('Enable LED Device', output['message'])

if __name__ == '__main__':
    unittest.main()
