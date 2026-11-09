#!/usr/bin/env python3
"""Import mapped SVGs: python3 -I scripts/icons/import-upstream.py SOURCE OUTPUT MAPPING.

Mapping lines: IconFolder -> folder (optional .svg on the source).
Also accepts file-library basenames, e.g. lang-typescript-duo -> typescript.
Class attributes are discarded; geometry, opacity and fill/clip rules survive.
Use --flatten-gradients to explicitly replace gradient paints with currentColor.
Blank lines and whole-line # comments are ignored. All inputs are validated before
any output is written; existing output is overwritten only when bytes differ.
"""
import argparse
import importlib.util
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True

# Explicit sibling loading works in Python isolated mode (-I), without sys.path edits.
spec = importlib.util.spec_from_file_location('tab_icon_normalize', Path(__file__).with_name('normalize.py'))
normalizer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(normalizer)


def prepare(data, flatten_gradients=False):
    """Adapt upstream metadata without weakening the set's normalizer."""
    if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ValueError('DOCTYPE and entity declarations are forbidden')
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise ValueError(f'invalid XML: {error}') from error
    gradients = set()
    if flatten_gradients:
        # Only flatten self-contained gradient definitions. Other defs/references
        # still reach the strict normalizer and are rejected.
        for parent in root.iter():
            for child in list(parent):
                if child.tag.split('}')[-1] != 'defs':
                    continue
                definitions = list(child)
                if definitions and all(
                    definition.tag.split('}')[-1] in {'linearGradient', 'radialGradient'}
                    and definition.get('id')
                    and all(stop.tag.split('}')[-1] == 'stop' for stop in definition)
                    for definition in definitions
                ):
                    gradients.update(definition.get('id') for definition in definitions)
                    parent.remove(child)
    for element in root.iter():
        element.attrib.pop('class', None)
        if flatten_gradients and element.get('fill') in {f'url(#{name})' for name in gradients}:
            element.set('fill', 'currentColor')
    return normalizer.normalize(ET.tostring(root, encoding='utf-8'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('mapping', type=Path)
    parser.add_argument('--flatten-gradients', action='store_true',
                        help='explicitly flatten gradient fills to currentColor (e.g. nextjs.svg)')
    args = parser.parse_args()
    pending = []
    seen = set()
    try:
        if not args.source.is_dir():
            raise ValueError(f'not a source folder: {args.source}')
        for number, line in enumerate(args.mapping.read_text(encoding='utf-8').splitlines(), 1):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = [part.strip() for part in line.split('->')]
            if len(parts) != 2:
                raise ValueError(f'{args.mapping}:{number}: expected UpstreamName -> our-name')
            source, name = parts
            if not re.fullmatch(r'[A-Za-z0-9_-]+(?:\.svg)?', source):
                raise ValueError(f'{args.mapping}:{number}: invalid source name: {source}')
            if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', name):
                raise ValueError(f'{args.mapping}:{number}: target must be kebab-case: {name}')
            if name in seen:
                raise ValueError(f'{args.mapping}:{number}: duplicate target: {name}')
            seen.add(name)
            file = args.source / (source if source.endswith('.svg') else source + '.svg')
            try:
                data = prepare(file.read_bytes(), args.flatten_gradients)
            except (OSError, ValueError) as error:
                raise ValueError(f'{file}: {error}') from error
            pending.append((args.output / (name + '.svg'), data))
        args.output.mkdir(parents=True, exist_ok=True)
        for destination, data in pending:
            if not destination.exists() or destination.read_bytes() != data:
                destination.write_bytes(data)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f'Imported {len(pending)} SVGs into {args.output}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
