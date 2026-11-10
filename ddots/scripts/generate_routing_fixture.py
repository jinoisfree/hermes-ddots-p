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
        agents={'default':{'name':'Example'}}
        for profile,alias in [('guide','Wiki'),('helper','Assistant'),('support','Support'),('doctor','Doctor'),('assistant','General')]:
            (home/'profiles'/profile).mkdir(parents=True)
            agents[profile]={'name':profile.title(),'aliases':[alias]}
        (home/'owner').mkdir()
        (home/'owner/team.yaml').write_text(json.dumps({'agents':agents}))
        atomic_json(args.output,export(home))
if __name__=='__main__':main()
