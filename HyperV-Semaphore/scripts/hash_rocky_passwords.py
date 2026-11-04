"""Hash credentials received on stdin; never include input in errors or argv."""
import json
import sys


def hash_passwords(values):
    from passlib.hash import sha512_crypt
    if not isinstance(values, dict) or set(values) not in ({'root'}, {'root', 'user'}):
        raise ValueError('invalid credential keys')
    if any(not isinstance(v, str) or not v for v in values.values()):
        raise ValueError('missing credentials')
    return {key: sha512_crypt.using(rounds=100000).hash(value) for key, value in values.items()}


if __name__ == '__main__':
    try:
        result = hash_passwords(json.load(sys.stdin))
    except Exception:
        print('No se pudieron generar los hashes Rocky. Comprobar dependencia passlib y campos requeridos.', file=sys.stderr)
        sys.exit(1)
    print(json.dumps(result))
