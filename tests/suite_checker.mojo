# tests/suite_checker.mojo — JSONTestSuite harness: read one file, attempt a
# default-options parse, print the verdict. Driven by tests/run_suite.sh over
# the y_/n_/i_ corpus (ARCHITECTURE.md, Measurement Discipline: the
# correctness gate speed never buys out of).
#
# Input files are read as raw bytes — some n_ cases are deliberately invalid
# UTF-8, and the verdict on those belongs to OUR validator, not the file API.

from std.sys import argv

from json import dumps, loads


def main():
    var args = argv()
    if len(args) < 2:
        print("usage: suite_checker <file.json> [roundtrip]")
        return
    var text: String
    try:
        with open(String(args[1]), "r") as f:
            var data = f.read_bytes()
            text = String(unsafe_from_utf8=data)
    except _:
        print("READ-ERROR")
        return
    try:
        var doc = loads(text^)
        if len(args) > 2:
            # dumps∘loads idempotence: the second emission must equal the
            # first byte-for-byte (raw-span re-emission is a fixed point).
            var once = dumps(doc)
            var again = loads(once.copy())
            if dumps(again) == once:
                print("ACCEPT")
            else:
                print("ROUNDTRIP-MISMATCH")
        else:
            _ = doc.kind()
            print("ACCEPT")
    except _:
        print("REJECT")
