#!/usr/bin/env python3
"""Canonicalize and validate Tab Icons: python3 -I scripts/icons/normalize.py FOLDER.

Files are processed recursively, in sorted order. Invalid files are left intact;
valid files are rewritten only if their bytes change. No geometry is rewritten.
"""
import argparse
import math
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr

SVG_NS = 'http://www.w3.org/2000/svg'
ALLOWED = {'svg', 'g', 'path', 'circle', 'rect'}


def normalize(data):
    """Return canonical UTF-8 SVG bytes, or raise ValueError for invalid input."""
    if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ValueError('DOCTYPE and entity declarations are forbidden')
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise ValueError(f'invalid XML: {error}') from error
    for element in root.iter():
        tag = element.tag
        if tag.startswith('{' + SVG_NS + '}'):
            tag = tag.split('}', 1)[1]
        if tag not in ALLOWED or (tag == 'svg' and element is not root):
            raise ValueError(f'unsupported element: {tag}')
        element.tag = tag
        if element.text and element.text.strip() or element.tail and element.tail.strip():
            raise ValueError(f'text is forbidden in <{tag}>')
        for key, value in list(element.attrib.items()):
            if key in {'id', 'style'} or key.startswith('stroke'):
                raise ValueError(f'forbidden attribute on <{tag}>: {key}')
            if key.startswith('{') or key.lower().startswith('on') or key in {'href', 'class'}:
                raise ValueError(f'unsupported attribute on <{tag}>: {key}')
            if 'url(' in value.lower():
                raise ValueError(f'paint/reference URL is forbidden: {key}')
            if key == 'fill' and value == 'black':
                element.set(key, 'currentColor')
        if tag == 'path' and element.get('fill') != 'currentColor':
            raise ValueError('every path must have explicit fill="currentColor" (or input fill="black")')
        if tag in {'path', 'circle', 'rect'} and len(element):
            raise ValueError(f'<{tag}> cannot contain elements')
        if element.get('fill') not in {None, 'none', 'currentColor'}:
            raise ValueError(f'unsupported fill on <{tag}>: {element.get("fill")}')
    if root.tag != 'svg':
        raise ValueError('root must be <svg>')
    viewbox = root.get('viewBox')
    if not viewbox:
        raise ValueError('missing viewBox')
    try:
        values = [float(value) for value in viewbox.replace(',', ' ').split()]
        if len(values) != 4 or not all(math.isfinite(v) for v in values) or min(values[2:]) <= 0:
            raise ValueError()
    except ValueError as error:
        raise ValueError(f'invalid viewBox: {viewbox}') from error
    root.attrib.pop('width', None)
    root.attrib.pop('height', None)
    root.set('xmlns', SVG_NS)
    lines = []

    def emit(element, depth):
        # Alphabetical attribute order, two-space indentation, one leaf per line.
        attrs = ''.join(f' {key}={quoteattr(value)}' for key, value in sorted(element.attrib.items()))
        prefix = '  ' * depth
        if len(element) or element is root:
            lines.append(f'{prefix}<{element.tag}{attrs}>')
            for child in element:
                emit(child, depth + 1)
            lines.append(f'{prefix}</{element.tag}>')
        else:
            lines.append(f'{prefix}<{element.tag}{attrs}/>')
    emit(root, 0)
    return ('\n'.join(lines) + '\n').encode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    if not args.folder.is_dir():
        parser.error(f'not a folder: {args.folder}')
    failed = False
    files = sorted(args.folder.rglob('*.svg'))
    for file in files:
        try:
            original = file.read_bytes()
            result = normalize(original)
            if result != original:
                file.write_bytes(result)
        except (OSError, ValueError) as error:
            print(f'{file}: {error}', file=sys.stderr)
            failed = True
    print(f'Checked {len(files)} SVGs; ' + ('validation failed' if failed else 'valid'))
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
