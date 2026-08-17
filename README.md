# Flint v3

Flint v3 is the next language layer built from the original Flint design.
The original `flint.s` remains the reference assembly interpreter; v3 adds a practical module system, user functions, namespaces, local state, arrays, strings, booleans, control flow, and a five-module standard library written in Flint.

## Build

```sh
cc -O3 -march=native -flto -DNDEBUG flint.c -lm -o flint
```

For maximum portability use `cc -O3 -flto -DNDEBUG flint.c -lm -o flint`.

## Modules

User modules are ordinary `.fl` files. Put them next to the importing file:

```text
project/
  main.fl
  physics.fl
```

`main.fl`:

```flint
import physics;
print physics.square(12);
```

`physics.fl`:

```flint
fn square(x) {
    return x * x;
}
```

The importer creates a module namespace, so exported functions are called as `module.function(...)`.

## Standard library

Five standard modules are supplied as Flint source in `stdlib/`:

- `time` — `start()`, `stop()`, `now()`; uses one tiny native primitive for the monotonic clock.
- `math` — `abs`, `min`, `max`, `square`, `cube`.
- `strings` — string helpers.
- `array` — array helpers.
- `print` — printing helpers.

Example:

```flint
import time;

time.start();

let x = 0;
while (x < 100000) {
    x = x + 1;
}

print time.stop();
```

## Performance

The v3 executable is built as optimized native C (`-O3 -march=native -flto`). This improves the interpreter substantially, but it is **not scientifically valid to claim it is faster than native machine code or universally faster than C++**. Native C++ and hand-written machine code can both be compiled directly to CPU instructions. The next performance phase should replace the tree-walking evaluator with a bytecode VM and then a native x86-64 code generator/JIT. Those stages can be benchmarked fairly against optimized C/C++.
