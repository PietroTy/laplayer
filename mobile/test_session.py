import json
import base64
from librespot.core import Session

content = '{"username": "314zrpdbivs6ossniiogrsj7ln3y", "credentials": "QWdCbHpuc2VDS04yVEV5VGFnUDJIVDhqRTVPdGR6enVxdjVrZTdaX3ZhTlNUWlZkX3lMRENIX3VLNTd1cWpMOE1ITFRvTmlwanlrT0h6Y3haSG0xYy1zRjA2TUF5Z0lXa1pDVHBjSmNjMEtZdWYwektVemtBTWdKVEhzZkJEc2Ffc3lHb3NuZlRyQllCeGYzaHQtZDhrUURKRUhFSTZHSjRQLUdSQTZuYWRKMVdEX3Z5c0dSdlRaQmkxUUZSeHMy", "type": "AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS"}'
map_obj = json.loads(content)

for k in ['credentials', 'auth_data']:
    if k in map_obj and isinstance(map_obj[k], str):
        b64 = map_obj[k]
        b64 = b64.replace('-', '+').replace('_', '/')
        while len(b64) % 4 != 0:
            b64 += '='
        map_obj[k] = b64

with open('test_creds.json', 'w') as f:
    json.dump(map_obj, f)

try:
    print("Iniciando sessao...")
    session = Session.Builder().stored_file('test_creds.json').create()
    print("Sessao criada com sucesso!")
except Exception as e:
    import traceback
    traceback.print_exc()
