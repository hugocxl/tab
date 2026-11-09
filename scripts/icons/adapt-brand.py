#!/usr/bin/env python3
"""Adapt reference geometry, then simplify by hand for Tab Icons.

Usage: python3 -I scripts/icons/adapt-brand.py SOURCE.svg OUT.svg
       [--box 14] [--margin 1] [--decimals 2] [--keep-subpaths] [--duo]

Fits the painted geometry in min(box, 16 - 2*margin), centered at (8, 8).
Colors become currentColor; compound contours and inherited fill rules survive.
By default only disjoint, adjacent shapes with identical rules are combined.
--keep-subpaths keeps each source element as its own editable path; holes are
never separated from their contour. --duo defaults to a 10.25-unit glyph box and
places the standard 14-unit, .2-opacity squircle behind the opaque source glyph.

Supports filled SVG primitives, affine transforms and simple CSS selectors
(tag, .class, #id, and combinations). Strokes, clips, masks, referenced geometry,
complex CSS and nested SVG viewports fail explicitly instead of losing geometry.
Only Python's standard library is used; normalize.py is loaded by explicit path.
"""

import argparse
import importlib.util
import math
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


NUMBER = re.compile(r'[+-]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][+-]?\d+)?')
COMMANDS = 'MmLlHhVvCcSsQqTtAaZz'
IDENTITY = (1, 0, 0, 1, 0, 0)
STEPS = 1024
SQUIRCLE = 'M8 0C1.42 0 0 1.42 0 8s1.42 8 8 8 8-1.42 8-8-1.42-8-8-8'


class Scanner:
    def __init__(self, text):
        self.text = text
        self.index = 0

    def peek(self):
        while self.index < len(self.text) and self.text[self.index] in ' \t\r\n,':
            self.index += 1
        return self.text[self.index:self.index + 1]

    def number(self, flag=False):
        char = self.peek()
        if flag:
            if char not in ('0', '1'):
                raise ValueError('arc flag must be 0 or 1')
            self.index += 1
            return int(char)
        match = NUMBER.match(self.text, self.index)
        if not match:
            raise ValueError(f'expected number near {self.text[self.index:self.index + 32]!r}')
        self.index = match.end()
        value = float(match.group())
        if not math.isfinite(value):
            raise ValueError('non-finite coordinate')
        return value


def numbers(text):
    scanner = Scanner(text)
    result = []
    while scanner.peek():
        result.append(scanner.number())
    return result


def multiply(left, right):
    a, b, c, d, e, f = left
    g, h, i, j, k, l = right
    return (a*g + c*h, b*g + d*h, a*i + c*j, b*i + d*j,
            a*k + c*l + e, b*k + d*l + f)


def point(matrix, x, y):
    a, b, c, d, e, f = matrix
    return a*x + c*y + e, b*x + d*y + f


def transform(text):
    result = IDENTITY
    position = 0
    for match in re.finditer(r'([A-Za-z]+)\s*\(([^()]*)\)', text):
        if text[position:match.start()].strip(' \t\r\n,'):
            raise ValueError(f'invalid transform: {text}')
        position = match.end()
        name, arguments = match.groups()
        values = numbers(arguments)
        if name == 'matrix' and len(values) == 6:
            matrix = tuple(values)
        elif name == 'translate' and len(values) in (1, 2):
            matrix = (1, 0, 0, 1, values[0], values[1] if len(values) == 2 else 0)
        elif name == 'scale' and len(values) in (1, 2):
            matrix = (values[0], 0, 0, values[-1], 0, 0)
        elif name == 'rotate' and len(values) in (1, 3):
            angle = math.radians(values[0])
            cosine, sine = math.cos(angle), math.sin(angle)
            matrix = (cosine, sine, -sine, cosine, 0, 0)
            if len(values) == 3:
                x, y = values[1:]
                matrix = multiply(multiply((1, 0, 0, 1, x, y), matrix),
                                  (1, 0, 0, 1, -x, -y))
        else:
            raise ValueError(f'unsupported transform: {name}({arguments})')
        result = multiply(result, matrix)
    if text[position:].strip(' \t\r\n,'):
        raise ValueError(f'invalid transform: {text}')
    return result


def parse_path(data):
    """Expand relative, implicit, horizontal/vertical and smooth commands."""
    scanner = Scanner(data)
    segments = []
    x = y = start_x = start_y = 0
    cubic = quadratic = None
    command = None
    while scanner.peek():
        char = scanner.peek()
        if char in COMMANDS:
            command = char
            scanner.index += 1
        elif command is None:
            raise ValueError('expected path command')
        upper = command.upper()
        relative = command.islower()
        if not segments and upper != 'M':
            raise ValueError('path must start with moveto')

        def pair():
            px, py = scanner.number(), scanner.number()
            return (px + x, py + y) if relative else (px, py)

        old_cubic, old_quadratic = cubic, quadratic
        cubic = quadratic = None
        if upper == 'Z':
            segments.append(('Z', ()))
            x, y = start_x, start_y
            command = None
            continue
        if upper == 'M':
            x, y = pair()
            start_x, start_y = x, y
            segments.append(('M', (x, y)))
            command = 'l' if relative else 'L'
        elif upper == 'L':
            x, y = pair()
            segments.append(('L', (x, y)))
        elif upper in ('H', 'V'):
            value = scanner.number()
            if upper == 'H':
                x = value + x if relative else value
            else:
                y = value + y if relative else value
            segments.append(('L', (x, y)))
        elif upper in ('C', 'S'):
            first = pair() if upper == 'C' else (
                (2*x - old_cubic[0], 2*y - old_cubic[1]) if old_cubic else (x, y))
            second, end = pair(), pair()
            cubic = second
            segments.append(('C', first + second + end))
            x, y = end
        elif upper in ('Q', 'T'):
            control = pair() if upper == 'Q' else (
                (2*x - old_quadratic[0], 2*y - old_quadratic[1]) if old_quadratic else (x, y))
            end = pair()
            quadratic = control
            segments.append(('Q', control + end))
            x, y = end
        elif upper == 'A':
            rx, ry, angle = scanner.number(), scanner.number(), scanner.number()
            large, sweep = scanner.number(flag=True), scanner.number(flag=True)
            end = pair()
            if rx < 0 or ry < 0:
                raise ValueError('arc radii must be nonnegative')
            if end != (x, y):
                segments.append(('A', (rx, ry, angle, large, sweep) + end)
                                if rx and ry else ('L', end))
            x, y = end
        else:
            raise ValueError(f'unsupported path command: {command}')
    return segments


def primitive(element, tag):
    def value(key, default=0):
        values = numbers(element.get(key, str(default)))
        if len(values) != 1:
            raise ValueError(f'{key} must be a unitless number')
        return values[0]

    if tag == 'path':
        return parse_path(element.get('d', ''))
    if tag in ('polygon', 'polyline'):
        values = numbers(element.get('points', ''))
        if len(values) % 2:
            raise ValueError('points must be coordinate pairs')
        result = [('M' if index == 0 else 'L', tuple(values[index:index + 2]))
                  for index in range(0, len(values), 2)]
        return result + ([('Z', ())] if result and tag == 'polygon' else [])
    if tag == 'line':
        return [('M', (value('x1'), value('y1'))), ('L', (value('x2'), value('y2')))]
    if tag in ('circle', 'ellipse'):
        x, y = value('cx'), value('cy')
        rx = value('r') if tag == 'circle' else value('rx')
        ry = rx if tag == 'circle' else value('ry')
        if min(rx, ry) < 0:
            raise ValueError('negative ellipse radius')
        if not rx or not ry:
            return []
        return [('M', (x + rx, y)), ('A', (rx, ry, 0, 0, 1, x - rx, y)),
                ('A', (rx, ry, 0, 0, 1, x + rx, y)), ('Z', ())]
    if tag == 'rect':
        x, y, width, height = value('x'), value('y'), value('width'), value('height')
        rx = value('rx', element.get('ry', 0))
        ry = value('ry', element.get('rx', 0))
        if min(width, height, rx, ry) < 0:
            raise ValueError('negative rectangle dimension')
        if not width or not height:
            return []
        rx, ry = min(rx, width/2), min(ry, height/2)
        if not rx or not ry:
            return [('M', (x, y)), ('L', (x + width, y)),
                    ('L', (x + width, y + height)), ('L', (x, y + height)), ('Z', ())]
        return [('M', (x + rx, y)), ('L', (x + width - rx, y)),
                ('A', (rx, ry, 0, 0, 1, x + width, y + ry)),
                ('L', (x + width, y + height - ry)),
                ('A', (rx, ry, 0, 0, 1, x + width - rx, y + height)),
                ('L', (x + rx, y + height)), ('A', (rx, ry, 0, 0, 1, x, y + height - ry)),
                ('L', (x, y + ry)), ('A', (rx, ry, 0, 0, 1, x + rx, y)), ('Z', ())]
    raise ValueError(f'unsupported geometry: {tag}')


def transform_path(segments, matrix):
    result = []
    a, b, c, d, _, _ = matrix
    determinant = a*d - b*c
    if abs(determinant) < 1e-15:
        raise ValueError('singular transform')
    for command, values in segments:
        if command != 'A':
            result.append((command, tuple(coordinate
                for index in range(0, len(values), 2)
                for coordinate in point(matrix, *values[index:index + 2]))))
            continue
        rx, ry, angle, large, sweep, x, y = values
        # Similarities preserve radii ratio and arc flags (except reflections).
        scale = math.hypot(a, b)
        if math.isclose(a*c + b*d, 0, abs_tol=1e-12 * scale**2) and math.isclose(
                scale, math.hypot(c, d), rel_tol=1e-12):
            rx, ry = rx*scale, ry*scale
            angle = math.degrees(math.atan2(b, a)) + (angle if determinant > 0 else -angle)
        else:
            # Principal axes of the affine image of an ellipse: eigenvectors of
            # B B^T, where B = linear(matrix) * rotate(angle) * diag(rx, ry).
            phi = math.radians(angle)
            cosine, sine = math.cos(phi), math.sin(phi)
            u, v = rx*(a*cosine + c*sine), rx*(b*cosine + d*sine)
            w, z = ry*(-a*sine + c*cosine), ry*(-b*sine + d*cosine)
            xx, xy, yy = u*u + w*w, u*v + w*z, v*v + z*z
            delta = math.hypot(xx - yy, 2*xy)
            major = (xx + yy + delta)/2
            # det(B B^T)/major is stable for narrow ellipses.
            minor = (u*z - v*w)**2 / major
            rx, ry = math.sqrt(major), math.sqrt(minor)
            angle = math.degrees(math.atan2(2*xy, xx - yy))/2
        result.append(('A', (rx, ry, angle, large,
                            sweep if determinant > 0 else 1 - sweep) + point(matrix, x, y)))
    return result


def arc_parameters(start, values):
    """SVG endpoint-to-center algorithm, including automatic radius correction."""
    rx, ry, angle, large, sweep, x, y = values
    phi = math.radians(angle % 360)
    cosine, sine = math.cos(phi), math.sin(phi)
    dx, dy = (start[0] - x)/2, (start[1] - y)/2
    px, py = cosine*dx + sine*dy, -sine*dx + cosine*dy
    correction = math.hypot(px/rx, py/ry)
    if correction > 1:
        rx, ry = rx*correction, ry*correction
    ux, uy = px/rx, py/ry
    denominator = ux*ux + uy*uy
    factor = math.sqrt(max(0, (1 - denominator)/denominator))
    if large == sweep:
        factor = -factor
    cx, cy = factor*rx*uy, -factor*ry*ux
    center = (cosine*cx - sine*cy + (start[0] + x)/2,
              sine*cx + cosine*cy + (start[1] + y)/2)
    first = ((px - cx)/rx, (py - cy)/ry)
    last = ((-px - cx)/rx, (-py - cy)/ry)
    theta = math.atan2(first[1], first[0])
    extent = math.atan2(first[0]*last[1] - first[1]*last[0],
                        first[0]*last[0] + first[1]*last[1])
    if sweep and extent < 0:
        extent += math.tau
    elif not sweep and extent > 0:
        extent -= math.tau
    return center, rx, ry, cosine, sine, theta, extent


def bounds(segments):
    samples = []
    current = start = (0, 0)
    for command, values in segments:
        if command == 'M':
            current = start = values
            continue
        end = start if command == 'Z' else values[-2:]
        if command in ('L', 'Z'):
            samples.extend((current, end))
        elif command in ('C', 'Q'):
            controls = [current] + [values[i:i + 2] for i in range(0, len(values), 2)]
            for index in range(STEPS + 1):
                t = index/STEPS
                work = controls
                while len(work) > 1:
                    work = [((1-t)*p[0] + t*q[0], (1-t)*p[1] + t*q[1])
                            for p, q in zip(work, work[1:])]
                samples.append(work[0])
        elif command == 'A':
            center, rx, ry, cosine, sine, theta, extent = arc_parameters(current, values)
            for index in range(STEPS + 1):
                angle = theta + extent*index/STEPS
                px, py = rx*math.cos(angle), ry*math.sin(angle)
                samples.append((center[0] + cosine*px - sine*py,
                                center[1] + sine*px + cosine*py))
        current = end
    if not samples:
        return None
    xs, ys = zip(*samples)
    return min(xs), min(ys), max(xs), max(ys)


def declarations(text):
    result = {}
    for declaration in text.split(';'):
        if not declaration.strip():
            continue
        key, separator, value = declaration.partition(':')
        if not separator or '!important' in value:
            raise ValueError(f'unsupported CSS declaration: {declaration}')
        result[key.strip()] = value.strip()
    return result


def local_tag(element):
    if element.tag.startswith('{http://www.w3.org/2000/svg}'):
        return element.tag.split('}', 1)[1]
    return element.tag


def read_shapes(data):
    if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ValueError('DOCTYPE and entity declarations are forbidden')
    root = ET.fromstring(data)
    if local_tag(root) != 'svg':
        raise ValueError('root must be <svg>')
    css = []
    for element in root.iter():
        if local_tag(element) != 'style':
            continue
        text = re.sub(r'/\*.*?\*/', '', element.text or '', flags=re.S)
        position = 0
        for match in re.finditer(r'([^{}]+)\{([^{}]*)\}', text):
            if text[position:match.start()].strip():
                raise ValueError('unsupported CSS')
            position = match.end()
            for selector in match[1].split(','):
                selector = selector.strip()
                if not re.fullmatch(r'(?:[A-Za-z][\w-]*|\*)?(?:[.#][\w-]+)*', selector) or not selector:
                    raise ValueError(f'unsupported CSS selector: {selector}')
                specificity = (selector.count('#'), selector.count('.'),
                               int(selector[0] not in '.#*'))
                css.append((specificity, len(css), selector, declarations(match[2])))
        if text[position:].strip():
            raise ValueError('unsupported CSS')
    css.sort(key=lambda rule: rule[:2])

    def matches(element, selector):
        tag = re.match(r'^[\w*-]+', selector)
        if tag and tag[0] not in ('*', local_tag(element)):
            return False
        for prefix, name in re.findall(r'([.#])([\w-]+)', selector):
            if prefix == '#' and element.get('id') != name:
                return False
            if prefix == '.' and name not in element.get('class', '').split():
                return False
        return True

    shapes = []
    inherited_keys = {'fill', 'fill-rule', 'clip-rule', 'stroke', 'visibility', 'fill-opacity'}
    relevant = inherited_keys | {'display', 'opacity', 'clip-path', 'mask', 'filter', 'transform'}

    def visit(element, parent_matrix, inherited, parent_opacity=1):
        tag = local_tag(element)
        if tag in ('title', 'desc', 'metadata', 'style', 'defs'):
            return
        style = dict(inherited)
        style.update({key: value for key, value in element.attrib.items() if key in relevant})
        for _, _, selector, properties in css:
            if matches(element, selector):
                style.update(properties)
        style.update(declarations(element.get('style', '')))
        for key, value in list(style.items()):
            if value == 'inherit':
                style[key] = inherited.get(key, {'fill': 'black', 'stroke': 'none',
                                                'fill-rule': 'nonzero'}.get(key, '1'))
        if style.get('display') == 'none':
            return
        opacity = parent_opacity * float(style.get('opacity', 1))
        if opacity == 0:
            return
        if not math.isfinite(opacity) or not 0 <= opacity <= 1:
            raise ValueError('invalid opacity')
        if opacity != 1:
            raise ValueError('partial group/element opacity: adapt an opaque reference, then hand-edit Duo opacity')
        for key in ('clip-path', 'mask', 'filter'):
            if style.get(key, 'none') != 'none':
                raise ValueError(f'{key} is unsupported; flatten the reference first')
        matrix = multiply(parent_matrix, transform(style.get('transform', '')))
        if tag in ('svg', 'g'):
            if tag == 'svg' and element is not root:
                raise ValueError('nested SVG viewports are unsupported')
            for child in element:
                visit(child, matrix, {key: value for key, value in style.items() if key in inherited_keys}, opacity)
            return
        if tag not in ('path', 'polygon', 'polyline', 'rect', 'circle', 'ellipse', 'line'):
            raise ValueError(f'unsupported element: {tag}')
        if style.get('visibility') in ('hidden', 'collapse'):
            return
        if style.get('stroke', 'none') != 'none':
            raise ValueError('strokes are unsupported; expand strokes in the reference first')
        if style.get('fill', 'black') == 'none' or float(style.get('fill-opacity', 1)) == 0:
            return
        if float(style.get('fill-opacity', 1)) != 1:
            raise ValueError('partial fill-opacity: adapt an opaque reference first')
        attributes = {}
        for key in ('fill-rule', 'clip-rule'):
            if key in style:
                if style[key] not in ('evenodd', 'nonzero'):
                    raise ValueError(f'unsupported {key}: {style[key]}')
                attributes[key] = style[key]
        segments = transform_path(primitive(element, tag), matrix)
        box = bounds(segments)
        if box is not None:
            shapes.append((segments, attributes, box))

    visit(root, IDENTITY, {})
    return shapes


def disjoint(a, b):
    return a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1]


def format_path(segments, decimals):
    def number(value):
        if not math.isfinite(value):
            raise ValueError('non-finite transformed coordinate')
        text = f'{value:.{decimals}f}'.rstrip('0').rstrip('.') if decimals else f'{value:.0f}'
        return '0' if text in ('-0', '') else text
    return ' '.join(command + ' '.join(number(v) for v in values) for command, values in segments)


def adapt(data, box=None, margin=1, decimals=2, keep_subpaths=False, duo=False):
    if box is None:
        box = 10.25 if duo else 14
    if not math.isfinite(box) or not math.isfinite(margin) or box <= 0 or not 0 <= margin < 8:
        raise ValueError('box must be positive and margin must be in [0, 8)')
    if not 0 <= decimals <= 10:
        raise ValueError('decimals must be in 0...10')
    shapes = read_shapes(data)
    if not shapes:
        raise ValueError('no visible geometry')
    low_x = min(shape[2][0] for shape in shapes)
    low_y = min(shape[2][1] for shape in shapes)
    high_x = max(shape[2][2] for shape in shapes)
    high_y = max(shape[2][3] for shape in shapes)
    extent = max(high_x - low_x, high_y - low_y)
    if extent <= 0:
        raise ValueError('geometry has zero extent')
    scale = min(box, 16 - 2*margin)/extent
    matrix = (scale, 0, 0, scale, 8 - scale*(low_x + high_x)/2, 8 - scale*(low_y + high_y)/2)
    output = ET.Element('svg', {'fill': 'none', 'viewBox': '0 0 16 16',
                               'xmlns': 'http://www.w3.org/2000/svg'})
    if duo:
        ET.SubElement(output, 'path', {'d': SQUIRCLE, 'fill': 'currentColor', 'opacity': '.2'})
    groups = []
    for segments, attributes, geometry_box in shapes:
        if (not keep_subpaths and groups and groups[-1][1] == attributes
                and all(disjoint(geometry_box, other) for other in groups[-1][2])):
            groups[-1][0].extend(segments)
            groups[-1][2].append(geometry_box)
        else:
            groups.append((list(segments), attributes, [geometry_box]))
    for segments, attributes, _ in groups:
        ET.SubElement(output, 'path', {**attributes, 'fill': 'currentColor',
                      'd': format_path(transform_path(segments, matrix), decimals)})
    spec = importlib.util.spec_from_file_location('tab_icon_normalize', Path(__file__).with_name('normalize.py'))
    normalizer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(normalizer)
    return normalizer.normalize(ET.tostring(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--box', type=float)
    parser.add_argument('--margin', type=float, default=1)
    parser.add_argument('--decimals', type=int, default=2)
    parser.add_argument('--keep-subpaths', action='store_true')
    parser.add_argument('--duo', action='store_true')
    args = parser.parse_args()
    try:
        result = adapt(args.source.read_bytes(), args.box, args.margin, args.decimals, args.keep_subpaths, args.duo)
        args.output.write_bytes(result)
    except (OSError, ValueError, ET.ParseError) as error:
        parser.exit(1, f'{args.source}: {error}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
