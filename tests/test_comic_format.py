import importlib.util
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import unittest
import numpy as np
from PIL import Image, ImageDraw

spec = importlib.util.spec_from_file_location('formatter', Path(__file__).resolve().parents[1] / 'scripts/format-comics-duo.py')
formatter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(formatter)

class ReflowTests(unittest.TestCase):
    def test_single_pixel_gutter_preserves_every_pixel(self):
        image = Image.new('RGB', (600, 190), 'black')
        ImageDraw.Draw(image).line((299, 0, 299, 189), fill='white')
        split = formatter.safe_split(image)
        self.assertEqual(split, 299)
        parts = [np.asarray(image.crop((0,0,split,190))), np.asarray(image.crop((split,0,600,190)))]
        np.testing.assert_array_equal(np.concatenate(parts,axis=1), np.asarray(image))
    def test_never_splits_continuous_art(self):
        image = Image.new('RGB', (600,190),'white')
        ImageDraw.Draw(image).line((0,95,599,95), fill='black')
        self.assertIsNone(formatter.safe_split(image))
    def test_sunday_layout_stays_intact(self):
        self.assertIsNone(formatter.safe_split(Image.new('RGB',(600,420),'white')))

if __name__ == '__main__': unittest.main()
