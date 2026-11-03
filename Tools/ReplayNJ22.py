#!/usr/bin/env python3
"""Replay captured native reports through WaveBird's profile/pair/output pipeline."""
import argparse,subprocess,gzip
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('capture',nargs='?',type=Path);a=p.parse_args()
root=Path(__file__).resolve().parent.parent;b=root/'.nj22-build';b.mkdir(exist_ok=True)
sdk=Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
if not sdk.exists():sdk=Path(subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip())
files=[str(x) for x in sorted((root/'WaveBird').rglob('*.swift')) if x.name!='WaveBirdApp.swift']
subprocess.run(['xcrun','swiftc','-swift-version','6','-sdk',str(sdk),'-module-cache-path',str(b/'cache-replay'),'-target','arm64-apple-macosx26.0',*files,str(root/'Tools/NJ22Replay.swift'),'-o',str(b/'nj22-replay')],check=True)
capture=(a.capture or root/'Fixtures/NJ22-native.jsonl.gz').resolve()
if capture.suffix=='.gz':
    unpacked=b/'replay-capture.jsonl';unpacked.write_bytes(gzip.decompress(capture.read_bytes()));capture=unpacked
subprocess.run([str(b/'nj22-replay'),str(capture)],check=True)
