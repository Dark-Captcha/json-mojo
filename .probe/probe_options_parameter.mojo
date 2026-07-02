# Probe: an options struct as a comptime parameter, with comptime-if on its
# fields — the zero-cost mechanism ParseOptions rests on.
# Run: pixi run mojo run .probe/probe_options_parameter.mojo


struct Flags(Copyable, Movable, TrivialRegisterPassable):
    var fast: Bool
    var depth: Int

    def __init__(out self, *, fast: Bool = False, depth: Int = 1024):
        self.fast = fast
        self.depth = depth


def run[flags: Flags]() -> Int:
    comptime if flags.fast:
        return flags.depth * 2
    return flags.depth


def main():
    print("default:", run[Flags()]())  # expected: 1024
    print("custom :", run[Flags(fast=True, depth=8)]())  # expected: 16
