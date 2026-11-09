#!/usr/bin/env python3
"""Geometry regression checks: python3 -I scripts/icons/test-adapt-brand.py."""

import importlib.util
import math
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('adapt_brand', Path(__file__).with_name('adapt-brand.py'))
brand = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(brand)


def svg(body, attributes=''):
    return f'<svg xmlns="http://www.w3.org/2000/svg" {attributes}>{body}</svg>'.encode()


def paths(data):
    return list(ET.fromstring(data))


class GeometryTests(unittest.TestCase):
    def assertPoint(self, actual, expected, places=7):
        for a, b in zip(actual, expected):
            self.assertAlmostEqual(a, b, places=places)

    def test_relative_repeated_and_smooth_commands(self):
        actual = brand.parse_path('m1 2 3 4 h5 v6 c1 2 3 4 5 6 s3 4 5 6 q1 2 3 4 t5 6z m1 1')
        self.assertEqual(actual, [
            ('M', (1, 2)), ('L', (4, 6)), ('L', (9, 6)), ('L', (9, 12)),
            ('C', (10, 14, 12, 16, 14, 18)), ('C', (16, 20, 17, 22, 19, 24)),
            ('Q', (20, 26, 22, 28)), ('Q', (24, 30, 27, 34)), ('Z', ()), ('M', (2, 3))])

    def test_packed_arc_flags_and_exponents(self):
        self.assertEqual(brand.parse_path('M1e1-2 A3 4 25 0110 6a2 3 0 10-1-.5')[1:], [
            ('A', (3, 4, 25, 0, 1, 10, 6)), ('A', (2, 3, 0, 1, 0, 9, 5.5))])

    def test_actual_curve_bounds_exclude_controls_and_unused_moves(self):
        self.assertPoint(brand.bounds(brand.parse_path('M0 0C0 100 10 100 10 0M999 999')), (0, 0, 10, 75))
        result = brand.adapt(svg('<path d="M0 0C0 100 10 100 10 0"/>'), decimals=6)
        fitted = brand.bounds(brand.parse_path(paths(result)[0].get('d')))
        self.assertPoint(fitted, (8 - 14/15, 1, 8 + 14/15, 15), places=5)

    def test_nested_transform_order_and_rotation_center(self):
        data = svg('<g transform="translate(10 20) scale(2)"><g transform="rotate(90 1 1)">'
                   '<polygon points="1,1 3,1 3,2"/></g></g>')
        shape = brand.read_shapes(data)[0]
        self.assertPoint(shape[0][0][1], (12, 22))
        self.assertPoint(shape[0][1][1], (12, 26))
        self.assertPoint(shape[0][2][1], (10, 26))

    def test_arcs_under_uniform_scale_keep_rotation_and_flags(self):
        arc = brand.parse_path('M1 2A3 4 25 1 0 6 7')
        result = brand.transform_path(arc, (2, 0, 0, 2, 5, 6))
        self.assertEqual(result[1], ('A', (6, 8, 25, 1, 0, 17, 20)))

    def test_affine_arcs_match_transformed_samples(self):
        matrices = [brand.transform(text) for text in (
            'translate(3 -2) rotate(33) scale(2 .7)',
            'matrix(1 .4 .7 2 3 4)', 'scale(-2 3)', 'rotate(70) scale(-2)',
            'scale(3 1)', 'matrix(0 2 1 0 0 0)')]
        # Both sweep/large flags, including radii that need SVG correction.
        for matrix in matrices:
            for large in (0, 1):
                for sweep in (0, 1):
                    for radii in ((5, 8), (.3, .8)):
                        original = [('M', (1, 2)), ('A', (*radii, 37, large, sweep, 7, 6))]
                        transformed = brand.transform_path(original, matrix)
                        source = brand.arc_parameters(original[0][1], original[1][1])
                        target = brand.arc_parameters(transformed[0][1], transformed[1][1])

                        def evaluate(parameters, t):
                            center, rx, ry, cosine, sine, theta, extent = parameters
                            angle = theta + extent*t
                            x, y = rx*math.cos(angle), ry*math.sin(angle)
                            return center[0] + cosine*x - sine*y, center[1] + sine*x + cosine*y

                        for index in range(21):
                            expected = brand.point(matrix, *evaluate(source, index/20))
                            self.assertPoint(evaluate(target, index/20), expected, places=5)

    def test_all_primitives_and_css_fill_rules(self):
        data = svg('<style>.hole { fill-rule: evenodd; clip-rule: evenodd; fill: red; }'
                   '#hidden {fill:none}</style><g transform="matrix(1 0 0 1 4 5)">'
                   '<rect class="hole" width="12" height="10" rx="2"/>'
                   '<circle cx="20" cy="2" r="2"/><ellipse cx="28" cy="3" rx="3" ry="2"/>'
                   '<polygon points="1 20 4 20 4 25"/><polyline points="8 20 10 25 12 20"/>'
                   '<line x1="0" y1="30" x2="10" y2="30"/>'
                   '<path id="hidden" d="M100 100h20v20z"/></g>')
        shapes = brand.read_shapes(data)
        self.assertEqual(len(shapes), 6)
        self.assertEqual(shapes[0][1], {'fill-rule': 'evenodd', 'clip-rule': 'evenodd'})
        self.assertPoint(shapes[0][2], (4, 5, 16, 15))
        self.assertPoint(shapes[1][2], (22, 5, 26, 9))
        result = brand.adapt(data, keep_subpaths=True)
        self.assertEqual(len(paths(result)), 6)
        self.assertNotIn(b'class=', result)
        self.assertNotIn(b'style=', result)
        self.assertNotIn(b'id=', result)

    def test_compound_holes_are_never_split(self):
        data = svg('<path d="M0 0h20v20H0z M5 5v10h10V5z"/>', 'fill-rule="evenodd"')
        for keep in (False, True):
            result = paths(brand.adapt(data, keep_subpaths=keep))
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0].get('fill-rule'), 'evenodd')
            self.assertEqual(result[0].get('d').count('M'), 2)

    def test_only_disjoint_shapes_merge(self):
        disjoint = svg('<rect width="2" height="2"/><rect x="4" width="2" height="2"/>')
        self.assertEqual(len(paths(brand.adapt(disjoint))), 1)
        self.assertEqual(len(paths(brand.adapt(disjoint, keep_subpaths=True))), 2)
        overlap = svg('<rect width="2" height="2"/><rect x="1" width="2" height="2"/>')
        self.assertEqual(len(paths(brand.adapt(overlap))), 2)

    def test_box_margin_and_rounding(self):
        data = svg('<rect width="20" height="10"/>')
        for box, margin, expected in ((14, 1, (1, 4.5, 15, 11.5)),
                                      (16, 2, (2, 5, 14, 11)), (10, 0, (3, 5.5, 13, 10.5))):
            result = brand.adapt(data, box=box, margin=margin)
            self.assertPoint(brand.bounds(brand.parse_path(paths(result)[0].get('d'))), expected)
        self.assertNotIn('-0', brand.format_path([('M', (-.00001, 1.234))], 2))

    def test_duo_frame_centers_glyph_and_preserves_holes(self):
        data = svg('<path fill-rule="evenodd" d="M0 0h20v10H0z M5 2v6h10V2z"/>')
        for box, expected in ((None, (2.88, 5.44, 13.12, 10.56)),
                              (8, (4, 6, 12, 10))):
            result = brand.adapt(data, box=box, duo=True)
            root = ET.fromstring(result)
            frame, glyph = paths(result)
            self.assertEqual(root.get('viewBox'), '0 0 16 16')
            self.assertEqual(root.get('fill'), 'none')
            self.assertEqual(frame.attrib, {'d': brand.SQUIRCLE, 'fill': 'currentColor', 'opacity': '.2'})
            self.assertEqual(glyph.get('fill'), 'currentColor')
            self.assertIsNone(glyph.get('opacity'))
            self.assertEqual(glyph.get('fill-rule'), 'evenodd')
            self.assertEqual(glyph.get('d').count('M'), 2)
            self.assertPoint(brand.bounds(brand.parse_path(glyph.get('d'))), expected)

    def test_unsupported_input_fails_before_writing(self):
        for body in ('<path d="M0 0h10v10z" stroke="red"/>', '<use href="#a"/>',
                     '<g clip-path="url(#a)"><rect width="10" height="10"/></g>',
                     '<style>g > path { fill-rule:evenodd }</style>',
                     '<path d="M0 0A1 1 0 2 0 3 4"/>', '<svg/>'):
            with self.assertRaises(ValueError):
                brand.adapt(svg(body))
        for box, margin in ((0, 1), (math.nan, 1), (14, 8), (14, -1)):
            with self.assertRaises(ValueError):
                brand.adapt(svg('<rect width="10" height="10"/>'), box, margin)


if __name__ == '__main__':
    unittest.main()
