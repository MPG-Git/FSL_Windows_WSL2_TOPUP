import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('metadata',Path(__file__).resolve().parents[1]/'topup_metadata.py')
metadata=importlib.util.module_from_spec(spec); spec.loader.exec_module(metadata)

class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.root=Path(self.directory.name)
    def tearDown(self):
        self.directory.cleanup()
    def write(self,name,direction,readout=.05):
        path=self.root/(name+'.nii.gz')
        (self.root/(name+'.json')).write_text(json.dumps({'PhaseEncodingDirection':direction,'TotalReadoutTime':readout}))
        return str(path)
    def test_direction_is_read_from_json(self):
        a=self.write('a','j'); b=self.write('b','j-'); bold=self.write('bold','j-')
        self.assertEqual(metadata.acquisition(a,b,bold)[2],2)
    def test_reject_unsupported_axis(self):
        with self.assertRaises(ValueError): metadata.read_metadata(self.write('a','i'))
    def test_reject_same_direction(self):
        a=self.write('a','j'); b=self.write('b','j'); bold=self.write('bold','j')
        with self.assertRaises(ValueError): metadata.acquisition(a,b,bold)
    def test_reject_unmatched_readout(self):
        a=self.write('a','j'); b=self.write('b','j-'); bold=self.write('bold','j',.07)
        with self.assertRaises(ValueError): metadata.acquisition(a,b,bold)
    def test_reject_nonphysical_readout(self):
        for value in [0,-.1,float('nan'),True]:
            with self.assertRaises(ValueError): metadata.read_metadata(self.write('bad','j',value))

if __name__=='__main__': unittest.main()
