// Minimal simdjson ceiling measurement — mirrors json-mojo's corpus
// protocol: min-of-N wall time, DOM parse (their user-facing eager verb).
#include "simdjson.h"
#include <chrono>
#include <cstdio>

using namespace simdjson;

static void bench(const char* path, int reps) {
    padded_string body;
    if (padded_string::load(path).get(body)) { printf("missing %s\n", path); return; }
    dom::parser parser;
    double best = 1e30;
    for (int i = 0; i < reps; i++) {
        auto t0 = std::chrono::steady_clock::now();
        dom::element doc;
        auto err = parser.parse(body).get(doc);
        auto t1 = std::chrono::steady_clock::now();
        if (err) { printf("parse error %s\n", path); return; }
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if (ms < best) best = ms;
    }
    double mbps = (body.size() / 1e6) / (best / 1e3);
    printf("%-18s %9zu bytes  best %8.4f ms  %10.1f MB/s\n", path, body.size(), best, mbps);
}

int main() {
    const char* base = "references/EmberJson/bench_data/data/";
    char p[256];
    snprintf(p, sizeof p, "%stwitter.json", base);      bench(p, 40);
    snprintf(p, sizeof p, "%scitm_catalog.json", base); bench(p, 30);
    snprintf(p, sizeof p, "%scanada.json", base);       bench(p, 20);
    return 0;
}
