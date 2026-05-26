import requests

url = "http://127.0.0.1:8000/api/download"
data = {
    "title": "Crystal Dolphin",
    "artist": "Engelwood",
    "album": "",
    "duration_ms": 0
}

print("Iniciando requisicao...")
r = requests.post(url, json=data)
if r.status_code == 200:
    with open("test_download.m4a", "wb") as f:
        f.write(r.content)
    print("Download sucesso! Tamanho:", len(r.content))
else:
    print("Erro:", r.status_code, r.text)
