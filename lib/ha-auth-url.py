#!/usr/bin/env python3
"""
Get a fresh trusted_networks auth code from HA and print the auto-login URL.
Run from kiosk startup script to get a fresh URL each boot.
"""
import json
import sys
import urllib.request
import urllib.error

def get_auth_url(ha_url):
    ha_url = ha_url.rstrip('/')
    try:
        req = urllib.request.Request(
            ha_url + '/auth/login_flow',
            data=json.dumps({
                'client_id': ha_url + '/',
                'handler': ['trusted_networks', None],
                'redirect_uri': ha_url + '/?auth_callback=1'
            }).encode(),
            headers={'Content-Type': 'application/json'},
            method='POST'
        )
        result = json.loads(urllib.request.urlopen(req, timeout=5).read())
        if result.get('type') == 'create_entry':
            code = result['result']
            return ha_url + '?auth_callback=1&code=' + code + '&state=%2F'
    except Exception as e:
        sys.stderr.write('auth_url failed: ' + str(e) + '\n')
    return ha_url

if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(1)
    print(get_auth_url(sys.argv[1]))
