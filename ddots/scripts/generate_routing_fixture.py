#!/usr/bin/env python3
"""Generate synthetic expectations with the real, pure Hermes router (gateway Python)."""
from pathlib import Path
import tempfile,json,argparse
from export_config import export,atomic_json

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    fixture=Path(__file__).resolve().parents[1]/'Tests/Fixtures/router-input.json'
    with tempfile.TemporaryDirectory() as tmp:
        home=Path(tmp);(home/'config.yaml').write_text(fixture.read_text())
        (home/'profile.yaml').write_text('display_name: Example\n')
        for profile in ['guide','helper','support','doctor','assistant']:
            root=home/'profiles'/profile;root.mkdir(parents=True);(root/'profile.yaml').write_text('display_name: '+profile.title()+'\n')
        atomic_json(args.output,export(home))
if __name__=='__main__':main()
