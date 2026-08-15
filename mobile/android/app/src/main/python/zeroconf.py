# Stub inteligente do zeroconf para Android (Chaquopy)
# Evita crash ao importar qualquer classe, exceção ou constante do zeroconf.

class _Dummy:
    def __init__(self, *args, **kwargs):
        pass
    def __call__(self, *args, **kwargs):
        return self
    def __getattr__(self, name):
        return self
    def __iter__(self):
        return iter([])

def __getattr__(name):
    return _Dummy
