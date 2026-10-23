"""Read saved Java-edition NBT and Anvil chunks without external packages."""
import gzip
import io
import struct
import zlib
from pathlib import Path


class Reader:
    def __init__(self, data):
        self.stream = io.BytesIO(data)

    def take(self, n):
        value = self.stream.read(n)
        if len(value) != n:
            raise ValueError('Truncated NBT')
        return value

    def number(self, fmt):
        return struct.unpack('>' + fmt, self.take(struct.calcsize(fmt)))[0]

    def string(self):
        return self.take(self.number('H')).decode('utf-8', errors='replace')

    def payload(self, tag):
        if tag in (1, 2, 3, 4, 5, 6):
            return self.number({1:'b', 2:'h', 3:'i', 4:'q', 5:'f', 6:'d'}[tag])
        if tag == 7:
            return list(self.take(self.number('i')))
        if tag == 8:
            return self.string()
        if tag == 9:
            kind, count = self.number('B'), self.number('i')
            if not 0 <= count <= 16777216:
                raise ValueError('Invalid NBT list length')
            return [self.payload(kind) for _ in range(count)]
        if tag == 10:
            result = {}
            while True:
                kind = self.number('B')
                if not kind:
                    return result
                name = self.string()
                result[name] = self.payload(kind)
        if tag in (11, 12):
            count = self.number('i')
            if not 0 <= count <= 16777216:
                raise ValueError('Invalid NBT array length')
            return [self.number('i' if tag == 11 else 'q') for _ in range(count)]
        raise ValueError('Unknown NBT tag ' + str(tag))


def loads(data):
    if data[:2] == b'\x1f\x8b':
        data = gzip.decompress(data)
    reader = Reader(data)
    kind = reader.number('B')
    reader.string()
    return reader.payload(kind)


def chunk(world, cx, cz):
    path = Path(world) / 'region' / f'r.{cx // 32}.{cz // 32}.mca'
    with path.open('rb') as stream:
        stream.seek(4 * ((cx % 32) + (cz % 32) * 32))
        location = stream.read(4)
        offset = int.from_bytes(location[:3], 'big') * 4096
        if not offset:
            return {}
        stream.seek(offset)
        length = int.from_bytes(stream.read(4), 'big')
        compression = stream.read(1)[0]
        if compression & 128:
            data = (path.parent / f'c.{cx}.{cz}.mcc').read_bytes()
            compression &= 127
        else:
            data = stream.read(length - 1)
        if compression == 1:
            data = gzip.decompress(data)
        elif compression == 2:
            data = zlib.decompress(data)
        elif compression != 3:
            raise ValueError('Unsupported Anvil compression ' + str(compression))
        return loads(data)


def block(world, pos, chunks=None):
    x, y, z = map(int, pos)
    key = (x // 16, z // 16)
    if chunks is None:
        data = chunk(world, *key)
    else:
        if key not in chunks:
            chunks[key] = chunk(world, *key)
        data = chunks[key]
    state = {'Name':'minecraft:air'}
    for section in data.get('sections', []):
        if section['Y'] != y // 16:
            continue
        states = section.get('block_states', {})
        palette = states.get('palette', [state])
        index = (y % 16) * 256 + (z % 16) * 16 + x % 16
        bits = max(4, (len(palette) - 1).bit_length())
        per_long = 64 // bits
        packed = states.get('data', [])
        choice = ((packed[index // per_long] & ((1 << 64) - 1)) >> ((index % per_long) * bits)) & ((1 << bits) - 1) if packed else 0
        state = palette[choice]
        break
    entity = next((v for v in data.get('block_entities', []) if [v.get('x'),v.get('y'),v.get('z')] == [x,y,z]), {})
    return {'pos':[x,y,z], 'block':state, 'nbt':entity}


def computers(world, near=None):
    """Scan existing region chunks for native computer IDs and positions."""
    rx0,rz0=(near[0]//512,near[2]//512) if near else (0,0)
    paths=list((Path(world)/'region').glob('r.*.*.mca'))
    paths.sort(key=lambda p: (abs(int(p.name.split('.')[1])-rx0)+abs(int(p.name.split('.')[2])-rz0),p.name))
    for path in paths:
        _, rx, rz, _ = path.name.split('.')
        with path.open('rb') as stream:
            locations = stream.read(4096)
        for i in range(1024):
            if not int.from_bytes(locations[i*4:i*4+3], 'big'):
                continue
            cx, cz = int(rx)*32+i%32, int(rz)*32+i//32
            data = chunk(world, cx, cz)
            for entity in data.get('block_entities', []):
                if 'ComputerId' in entity:
                    pos = [entity['x'],entity['y'],entity['z']]
                    yield entity['ComputerId'], block(world, pos)
